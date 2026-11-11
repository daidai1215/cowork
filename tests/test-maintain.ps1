<#
.SYNOPSIS
Offline regression suite for cowork v2 self-maintenance and self-upgrade scripts.
.DESCRIPTION
Covers sync-docs.ps1, doctor.ps1 (-Repair & -ProbeCodexShell), calibrate-telemetry.ps1,
Compact-UsageLedger, Remove-OldRegistryHistory, and maintain.ps1 (Git commit, -Push,
selftest failure rollback, and dirty managed-path guard) entirely in %TEMP%.
#>
[CmdletBinding()]
param([string]$RegistryPath, [string]$StateDir)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $root 'scripts\lib\common.ps1')

$script:maintPassed = 0
$script:maintFailures = New-Object 'System.Collections.Generic.List[string]'
$tempRoot = $null
$tempParent = $null
$tempJunctionPath = $null

$oldNow = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_NOW')
$oldCodex = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_CODEX')
$oldAgy = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER')
$oldSelftest = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_SELFTEST_SCRIPT')
$oldGit = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_GIT')

function Assert-MTest {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:maintPassed++ }
    else { [void]$script:maintFailures.Add($Name) }
}

function Invoke-MScript {
    param([string]$RelScript, [string[]]$Arguments = @(), [string]$WorkDir = $root)
    $proc = Invoke-OrchestraProcess -FilePath 'powershell.exe' -Arguments (
        @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root $RelScript)) + $Arguments
    ) -WorkDir $WorkDir -TimeoutSec 120 -CaptureStdout
    $nonEmpty = @($proc.stdout | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $json = $null
    if ($nonEmpty.Count -gt 0) {
        try { $json = ([string]$nonEmpty[$nonEmpty.Count - 1] | ConvertFrom-Json) } catch { $json = $null }
    }
    return [pscustomobject]@{
        Exit = [int]$proc.exit_code
        Json = $json
        Stdout = $proc.stdout
        Stderr = $proc.stderr
    }
}

function Resolve-TestGit {
    $cmd = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and [IO.File]::Exists([string]$cmd.Source)) { return [string]$cmd.Source }
    $localApp = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    if (-not [string]::IsNullOrWhiteSpace($localApp)) {
        $wingetPkgs = Join-Path $localApp 'Microsoft\WinGet\Packages'
        if ([IO.Directory]::Exists($wingetPkgs)) {
            $minGit = Get-ChildItem -LiteralPath $wingetPkgs -Filter 'Git.MinGit*' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $minGit) {
                $cand = Join-Path $minGit.FullName 'cmd\git.exe'
                if ([IO.File]::Exists($cand)) { return $cand }
            }
        }
    }
    foreach ($fb in @('C:\Program Files\Git\cmd\git.exe', 'C:\Program Files (x86)\Git\cmd\git.exe')) {
        if ([IO.File]::Exists($fb)) { return $fb }
    }
    return $null
}

function Remove-ReparseLinkSafe {
    param([string]$LinkPath)
    if ([string]::IsNullOrWhiteSpace($LinkPath) -or -not (Test-Path -LiteralPath $LinkPath)) { return }
    $item = Get-Item -LiteralPath $LinkPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        $null = Invoke-OrchestraProcess -FilePath 'cmd.exe' -Arguments @('/d', '/c', 'rmdir', $LinkPath) -WorkDir ([IO.Path]::GetTempPath()) -TimeoutSec 15 -CaptureStdout
    }
}

try {
    $env:MODEL_ORCHESTRA_NOW = '2026-11-10T12:00:00Z'
    $sourcePaths = Get-OrchestraPaths -RegistryPath $RegistryPath -StateDir $null
    $tempParent = if ([string]::IsNullOrWhiteSpace($StateDir)) { [IO.Path]::GetTempPath() } else { $StateDir }
    $tempParent = [IO.Path]::GetFullPath($tempParent)
    $tempRoot = Join-Path $tempParent ('model-orchestra-maintain-test-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($tempRoot)

    # =========================================================================
    # 1. sync-docs.ps1: drift detection and deterministic sync
    # =========================================================================
    $docDir = Join-Path $tempRoot 'docs-case'
    [void][IO.Directory]::CreateDirectory((Join-Path $docDir 'registry'))
    [void][IO.Directory]::CreateDirectory((Join-Path $docDir 'references'))
    $docRegPath = Join-Path $docDir 'registry\models.json'
    [IO.File]::Copy($sourcePaths.Registry, $docRegPath, $true)
    foreach ($relDoc in @('SKILL.md', 'references\model-profiles.md', 'README.md')) {
        [IO.File]::Copy((Join-Path $root $relDoc), (Join-Path $docDir $relDoc), $true)
    }

    $docReg = Read-JsonFile -Path $docRegPath
    Set-OrchestraProperty $docReg 'registry_rev' 999
    Write-JsonAtomic -Path $docRegPath -Object $docReg

    $chkDrift = Invoke-MScript 'scripts\sync-docs.ps1' @('-Check', '-RegistryPath', $docRegPath, '-Root', $docDir)
    Assert-MTest (
        $chkDrift.Exit -eq 1 -and
        [bool]$chkDrift.Json.drift_detected -eq $true -and
        @(Get-OrchestraArray $chkDrift.Json 'drifted_files').Count -eq 3
    ) 'sync-docs -Check detects drift with exit 1'

    $doSync = Invoke-MScript 'scripts\sync-docs.ps1' @('-RegistryPath', $docRegPath, '-Root', $docDir)
    Assert-MTest (
        $doSync.Exit -eq 0 -and
        @(Get-OrchestraArray $doSync.Json 'updated_files').Count -eq 3
    ) 'sync-docs updates all 3 managed doc files'

    $chkClean = Invoke-MScript 'scripts\sync-docs.ps1' @('-Check', '-RegistryPath', $docRegPath, '-Root', $docDir)
    Assert-MTest (
        $chkClean.Exit -eq 0 -and [bool]$chkClean.Json.drift_detected -eq $false
    ) 'sync-docs -Check exits 0 after synchronization'

    # =========================================================================
    # 2. doctor.ps1: Junction repair, expired state hygiene, Codex shell probe
    # =========================================================================
    $docHealthDir = Join-Path $tempRoot 'doctor-case'
    $dhPaths = Get-OrchestraPaths -RegistryPath (Join-Path $docHealthDir 'registry\models.json') -StateDir (Join-Path $docHealthDir 'state')
    [void][IO.Directory]::CreateDirectory($dhPaths.RegistryDir)
    [IO.File]::Copy($sourcePaths.Registry, $dhPaths.Registry, $true)

    $fakeCodex = Join-Path $docHealthDir 'fake-codex.ps1'
    $fakeCodexScript = @'
if ($args.Count -gt 0 -and $args[0] -eq '--version') {
    [Console]::Out.WriteLine('codex-cli 0.188.0')
    exit 0
}
$null = [Console]::In.ReadToEnd()
[Console]::Out.WriteLine('{"type":"thread.started","thread_id":"probe-thread"}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"type":"command_execution","command":"echo COWORK_SHELL_OK","aggregated_output":"COWORK_SHELL_OK\n","exit_code":0,"status":"completed"}}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"type":"agent_message","text":"COWORK_SHELL_OK"}}')
[Console]::Out.WriteLine('{"type":"turn.completed"}')
exit 0
'@
    [IO.File]::WriteAllText($fakeCodex, $fakeCodexScript, $script:OrchestraUtf8)

    $fakeAgy = Join-Path $docHealthDir 'fake-agy.ps1'
    [IO.File]::WriteAllText($fakeAgy, "[Console]::Out.WriteLine('ok')`nexit 0`n", $script:OrchestraUtf8)

    $env:MODEL_ORCHESTRA_CODEX = $fakeCodex
    $env:MODEL_ORCHESTRA_AGY_WRAPPER = $fakeAgy

    Invoke-WithLock -Paths $dhPaths -Name state -ScriptBlock {
        $st = Read-State -Paths $dhPaths
        Set-OrchestraProperty $st 'exhausted' ([pscustomobject]@{
            'expired-model' = [pscustomobject]@{ until = '2026-11-10T01:00:00Z' }
        })
        Set-OrchestraProperty $st 'scan_lease' ([pscustomobject]@{
            owner = 'old'; until = '2026-11-10T01:00:00Z'
        })
        Set-OrchestraProperty $st 'research_leases' ([pscustomobject]@{
            'stale-cand' = [pscustomobject]@{ owner = 'old'; until = '2026-11-10T01:00:00Z' }
        })
        Save-State -Paths $dhPaths -State $st
    }

    $tempJunctionPath = Join-Path $tempRoot 'codex-junction-link'
    $docRes = Invoke-MScript 'scripts\doctor.ps1' @(
        '-Repair', '-ProbeCodexShell',
        '-CodexDestination', $tempJunctionPath,
        '-RegistryPath', $dhPaths.Registry,
        '-StateDir', $dhPaths.StateDir
    )
    $repairs = @(Get-OrchestraArray $docRes.Json 'repairs')
    $afterState = Read-State -Paths $dhPaths
    $jItem = if (Test-Path -LiteralPath $tempJunctionPath) { Get-Item -LiteralPath $tempJunctionPath -Force } else { $null }
    Assert-MTest (
        $docRes.Exit -eq 0 -and
        [bool]$docRes.Json.healthy -eq $true -and
        ($repairs -contains 'codex_junction_repaired') -and
        ($repairs -contains 'expired_state_cleaned') -and
        $null -ne $jItem -and (($jItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -and
        $null -eq $afterState.scan_lease -and
        @(Get-OrchestraNames $afterState.exhausted).Count -eq 0 -and
        [bool]$afterState.codex_shell_probe.shell_works -eq $true -and
        [string]$afterState.codex_shell_probe.version -eq '0.188.0'
    ) 'doctor -Repair repairs missing Junction, cleans expired state, and caches Codex shell probe'

    # Assistant echoing COWORK_SHELL_OK without a shell tool execution item must NOT mark shell_works=true
    $fakeCodexNoShell = Join-Path $docHealthDir 'fake-codex-noshell.ps1'
    $fakeNoShellScript = @'
if ($args.Count -gt 0 -and $args[0] -eq '--version') {
    [Console]::Out.WriteLine('codex-cli 0.189.0')
    exit 0
}
$null = [Console]::In.ReadToEnd()
[Console]::Out.WriteLine('{"type":"thread.started","thread_id":"probe-noshell"}')
[Console]::Out.WriteLine('{"type":"item.completed","item":{"type":"agent_message","text":"COWORK_SHELL_OK"}}')
[Console]::Out.WriteLine('{"type":"turn.completed"}')
exit 0
'@
    [IO.File]::WriteAllText($fakeCodexNoShell, $fakeNoShellScript, $script:OrchestraUtf8)
    $env:MODEL_ORCHESTRA_CODEX = $fakeCodexNoShell
    $docNoShell = Invoke-MScript 'scripts\doctor.ps1' @(
        '-ProbeCodexShell', '-CodexDestination', $tempJunctionPath,
        '-RegistryPath', $dhPaths.Registry, '-StateDir', $dhPaths.StateDir
    )
    $stateNoShell = Read-State -Paths $dhPaths
    Assert-MTest (
        $docNoShell.Exit -eq 0 -and
        [bool]$stateNoShell.codex_shell_probe.shell_works -eq $false -and
        [string]$stateNoShell.codex_shell_probe.version -eq '0.189.0'
    ) 'doctor -ProbeCodexShell rejects assistant-only marker without shell tool execution'
    $env:MODEL_ORCHESTRA_CODEX = $fakeCodex
    Remove-ReparseLinkSafe -LinkPath $tempJunctionPath
    $tempJunctionPath = $null

    # =========================================================================
    # 3. calibrate-telemetry.ps1: downward, upward, speed_rank swap, dedup, approve
    # =========================================================================
    $calDir = Join-Path $tempRoot 'calibrate-case'
    $calPaths = Get-OrchestraPaths -RegistryPath (Join-Path $calDir 'registry\models.json') -StateDir (Join-Path $calDir 'state')
    [void][IO.Directory]::CreateDirectory($calPaths.RegistryDir)
    $calReg = (ConvertTo-Json -InputObject (Read-JsonFile -Path $sourcePaths.Registry) -Depth 32 | ConvertFrom-Json)
    $calActive = @($calReg.models | Where-Object { [string]$_.status -eq 'active' })
    $mSlow = @($calActive | Sort-Object { [int]$_.speed_rank })[0]
    $mFast = @($calActive | Sort-Object { [int]$_.speed_rank } -Descending)[0]
    $slowId = [string]$mSlow.id
    $fastId = [string]$mFast.id

    Set-OrchestraProperty $mSlow 'speed_rank' 1
    Set-OrchestraProperty $mFast 'speed_rank' 3
    $mSlow.caps.long_context.score = 8.0
    $mSlow.caps.long_context.approved_score = 8.0
    $mSlow.caps.long_context.locked = $false
    $mFast.caps.prose.score = 8.0
    $mFast.caps.prose.approved_score = 8.0
    $mFast.caps.prose.locked = $false
    Set-OrchestraProperty $mSlow.invoke 'account_rotation' $true
    Write-JsonAtomic -Path $calPaths.Registry -Object $calReg

    # Seed downward badRate >= 0.40 on mSlow (long_context: 5 bad / 6) + rotation switches & quota error
    for ($i = 1; $i -le 6; $i++) {
        $iid = "slow-lc-$i"
        Add-UsageEvent -Paths $calPaths -Event @{
            type = 'invocation'; ad_hoc = $false; invocation_id = $iid
            ts = ('2026-11-0{0}T10:00:00Z' -f $i)
            model = $slowId; channel = [string]$mSlow.channel
            tags = @('long_context'); access = 'read'
            duration_sec = 4.0; exit = 0; quota_error = $false
            session_id = "s-$i"; attempts = $(if ($i -le 2) { 2 } else { 1 })
            account_switched = ($i -le 2); resume_invalidated = $false
        }
        Add-UsageEvent -Paths $calPaths -Event @{
            type = 'outcome'; invocation_id = $iid
            ts = ('2026-11-0{0}T10:05:00Z' -f $i)
            outcome = $(if ($i -eq 1) { 'ok' } elseif ($i -le 4) { 'redo' } else { 'fail' })
            note = 'test'
        }
    }
    # Add 1 terminal quota exhaustion event on mSlow and 1 extra clean read duration on long_context so mSlow has >=5 unswitched read samples
    Add-UsageEvent -Paths $calPaths -Event @{
        type = 'invocation'; ad_hoc = $false; invocation_id = 'slow-quota-1'
        ts = '2026-11-07T10:00:00Z'; model = $slowId; channel = [string]$mSlow.channel
        tags = @('long_context'); access = 'read'; duration_sec = 3.5; exit = 4; quota_error = $true
        session_id = $null; attempts = 3; account_switched = $true; resume_invalidated = $false
    }
    Add-UsageEvent -Paths $calPaths -Event @{
        type = 'invocation'; ad_hoc = $false; invocation_id = 'slow-lc-extra'
        ts = '2026-11-08T10:00:00Z'; model = $slowId; channel = [string]$mSlow.channel
        tags = @('long_context'); access = 'read'; duration_sec = 4.0; exit = 0; quota_error = $false
        session_id = 's-extra'; attempts = 1; account_switched = $false; resume_invalidated = $false
    }

    # Seed upward okRate >= 0.90 on mFast (prose: 8 ok / 8)
    for ($i = 1; $i -le 8; $i++) {
        $iid = "fast-prose-$i"
        Add-UsageEvent -Paths $calPaths -Event @{
            type = 'invocation'; ad_hoc = $false; invocation_id = $iid
            ts = ('2026-11-0{0}T11:00:00Z' -f $i)
            model = $fastId; channel = [string]$mFast.channel
            tags = @('prose'); access = 'read'
            duration_sec = 5.0; exit = 0; quota_error = $false
            session_id = "fp-$i"; attempts = 1; account_switched = $false; resume_invalidated = $false
        }
        Add-UsageEvent -Paths $calPaths -Event @{
            type = 'outcome'; invocation_id = $iid
            ts = ('2026-11-0{0}T11:05:00Z' -f $i)
            outcome = 'ok'; note = 'clean'
        }
    }
    # Seed 5 shared 'long_context' read durations on mFast that are >= 1.5x slower (12.0s vs 4.0s)
    for ($i = 1; $i -le 5; $i++) {
        Add-UsageEvent -Paths $calPaths -Event @{
            type = 'invocation'; ad_hoc = $false; invocation_id = "fast-lc-dur-$i"
            ts = ('2026-11-0{0}T12:00:00Z' -f $i)
            model = $fastId; channel = [string]$mFast.channel
            tags = @('long_context'); access = 'read'
            duration_sec = 12.0; exit = 0; quota_error = $false
            session_id = "flc-$i"; attempts = 1; account_switched = $false; resume_invalidated = $false
        }
    }

    $calRun1 = Invoke-MScript 'scripts\calibrate-telemetry.ps1' @(
        '-RegistryPath', $calPaths.Registry, '-StateDir', $calPaths.StateDir
    )
    $createdCalProps = @(Get-OrchestraArray $calRun1.Json 'proposals_created')
    $rotSlow = Get-OrchestraProperty $calRun1.Json.rotation_stats $slowId
    Assert-MTest (
        $calRun1.Exit -eq 0 -and
        $createdCalProps.Count -eq 3 -and
        [int]$rotSlow.switched_count -eq 3 -and
        [int]$rotSlow.quota_exhausted_count -eq 1
    ) 'calibrate-telemetry emits downward, upward, and speed_rank proposals plus rotation stats'

    $calRun2 = Invoke-MScript 'scripts\calibrate-telemetry.ps1' @(
        '-RegistryPath', $calPaths.Registry, '-StateDir', $calPaths.StateDir
    )
    Assert-MTest (
        $calRun2.Exit -eq 0 -and
        @(Get-OrchestraArray $calRun2.Json 'proposals_created').Count -eq 0 -and
        [int]$calRun2.Json.skipped_conflicts -eq 3
    ) 'calibrate-telemetry deduplicates existing pending proposals'

    $allApproveOk = ($createdCalProps.Count -eq 3)
    foreach ($cp in $createdCalProps) {
        $appOne = Invoke-MScript 'scripts\apply-research.ps1' @(
            '-Approve', [string]$cp, '-RegistryPath', $calPaths.Registry, '-StateDir', $calPaths.StateDir
        )
        if ($appOne.Exit -ne 0) { $allApproveOk = $false }
    }
    $afterCalReg = Read-JsonFile -Path $calPaths.Registry
    $afterSlow = @($afterCalReg.models | Where-Object { [string]$_.id -eq $slowId })[0]
    $afterFast = @($afterCalReg.models | Where-Object { [string]$_.id -eq $fastId })[0]
    Assert-MTest (
        $allApproveOk -and
        [double]$afterSlow.caps.long_context.score -eq 7.0 -and
        [string]$afterSlow.caps.long_context.source -eq 'telemetry' -and
        [double]$afterFast.caps.prose.score -eq 8.5 -and
        [string]$afterFast.caps.prose.source -eq 'telemetry' -and
        [int]$afterSlow.speed_rank -eq 3 -and
        [int]$afterFast.speed_rank -eq 1
    ) 'apply-research -Approve applies downward, upward, and speed_rank swap proposals'

    # =========================================================================
    # 4. Compact-UsageLedger (paired retention + idempotent archive) & History GC
    # =========================================================================
    $gcDir = Join-Path $tempRoot 'gc-case'
    $gcPaths = Get-OrchestraPaths -RegistryPath (Join-Path $gcDir 'registry\models.json') -StateDir (Join-Path $gcDir 'state')
    [void][IO.Directory]::CreateDirectory($gcPaths.RegistryDir)
    [void][IO.Directory]::CreateDirectory($gcPaths.History)
    $gcReg = Read-JsonFile -Path $sourcePaths.Registry
    Set-OrchestraProperty $gcReg 'registry_rev' 11
    Write-JsonAtomic -Path $gcPaths.Registry -Object $gcReg

    # Old pair (2026-07-05, >90d before 2026-11-10) -> archived
    Add-UsageEvent -Paths $gcPaths -Event @{
        type = 'invocation'; ad_hoc = $false; invocation_id = 'old-pair-1'
        ts = '2026-07-05T10:00:00Z'; model = $slowId; channel = 'agy'; tags = @('prose'); access = 'read'
        duration_sec = 2.0; exit = 0; quota_error = $false; session_id = 'so1'
    }
    Add-UsageEvent -Paths $gcPaths -Event @{
        type = 'outcome'; invocation_id = 'old-pair-1'; ts = '2026-07-05T10:01:00Z'; outcome = 'ok'; note = ''
    }
    # Straddling pair (invocation 95d old, outcome 5d old) -> BOTH retained in hot usage.jsonl!
    Add-UsageEvent -Paths $gcPaths -Event @{
        type = 'invocation'; ad_hoc = $false; invocation_id = 'straddle-1'
        ts = '2026-08-01T10:00:00Z'; model = $slowId; channel = 'agy'; tags = @('prose'); access = 'read'
        duration_sec = 2.0; exit = 0; quota_error = $false; session_id = 'ss1'
    }
    Add-UsageEvent -Paths $gcPaths -Event @{
        type = 'outcome'; invocation_id = 'straddle-1'; ts = '2026-11-05T10:00:00Z'; outcome = 'ok'; note = ''
    }

    $comp1 = Compact-UsageLedger -Paths $gcPaths -RetainDays 90 -Force
    $archiveJuly = Join-Path $gcPaths.StateDir 'archive\usage-202607.jsonl'
    $archiveLines1 = @([IO.File]::ReadAllLines($archiveJuly, $script:OrchestraUtf8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $hotLines1 = @([IO.File]::ReadAllLines($gcPaths.Usage, $script:OrchestraUtf8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-MTest (
        [bool]$comp1.compacted -eq $true -and
        [int]$comp1.archived_count -eq 2 -and
        [int]$comp1.hot_count -eq 2 -and
        $archiveLines1.Count -eq 2 -and
        $hotLines1.Count -eq 2
    ) 'Compact-UsageLedger retains straddling invocation+outcome pair and archives old pair'

    # Re-append identical old invocation and compact again -> verify zero duplicate lines in archive
    [IO.File]::AppendAllText($gcPaths.Usage, ($archiveLines1[0] + "`n"), $script:OrchestraUtf8)
    $null = Compact-UsageLedger -Paths $gcPaths -RetainDays 90 -Force
    $archiveLines2 = @([IO.File]::ReadAllLines($archiveJuly, $script:OrchestraUtf8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-MTest ($archiveLines2.Count -eq 2) 'Compact-UsageLedger archive write is idempotent without duplicate events'

    # Same-timestamp ok -> fail -> ok sequence MUST preserve authoritative final 'ok' outcome after compaction
    Add-UsageEvent -Paths $gcPaths -Event @{
        type = 'invocation'; ad_hoc = $false; invocation_id = 'flip-1'
        ts = '2026-11-09T10:00:00Z'; model = $slowId; channel = 'agy'; tags = @('prose'); access = 'read'
        duration_sec = 2.0; exit = 0; quota_error = $false; session_id = 'sf1'
    }
    Add-UsageEvent -Paths $gcPaths -Event @{
        type = 'outcome'; invocation_id = 'flip-1'; ts = '2026-11-09T10:01:00Z'; outcome = 'ok'; note = ''
    }
    Add-UsageEvent -Paths $gcPaths -Event @{
        type = 'outcome'; invocation_id = 'flip-1'; ts = '2026-11-09T10:01:00Z'; outcome = 'fail'; note = ''
    }
    Add-UsageEvent -Paths $gcPaths -Event @{
        type = 'outcome'; invocation_id = 'flip-1'; ts = '2026-11-09T10:01:00Z'; outcome = 'ok'; note = ''
    }
    $null = Compact-UsageLedger -Paths $gcPaths -RetainDays 90 -Force
    $afterFlipEvents = @(Read-UsageEvents -Paths $gcPaths -SinceDays 30)
    $flipStats = Get-OutcomeStats -Events $afterFlipEvents -ModelId $slowId -Tags @('prose') -WindowDays 30
    Assert-MTest (
        [int]$flipStats.ok -ge 1 -and [int]$flipStats.fail -eq 0
    ) 'Compact-UsageLedger preserves authoritative final outcome in same-second ok->fail->ok sequence'

    # History GC: same-second rev 9 vs 11, 12, 13 -> numeric revision sort keeps 13 & 12 plus protected rev 10 (registry_rev = 11), deleting 9 & 11
    foreach ($revNum in @(9, 10, 11, 12, 13)) {
        $snapObj = (ConvertTo-Json -InputObject $gcReg -Depth 32 | ConvertFrom-Json)
        Set-OrchestraProperty $snapObj 'registry_rev' $revNum
        $snapFile = Join-Path $gcPaths.History ("models-20261101-120000-{0}-aaaa.json" -f $revNum)
        Write-JsonAtomic -Path $snapFile -Object $snapObj
    }
    $histGc = Remove-OldRegistryHistory -Paths $gcPaths -KeepCount 2
    $remainingSnaps = @(Get-ChildItem -LiteralPath $gcPaths.History -Filter 'models-*.json' -File | ForEach-Object { $_.Name })
    Assert-MTest (
        [int]$histGc.kept_count -eq 3 -and
        [int]$histGc.removed_count -eq 2 -and
        @($remainingSnaps | Where-Object { $_ -match '-10-aaaa\.json$' }).Count -eq 1 -and
        @($remainingSnaps | Where-Object { $_ -match '-13-aaaa\.json$' }).Count -eq 1 -and
        @($remainingSnaps | Where-Object { $_ -match '-12-aaaa\.json$' }).Count -eq 1 -and
        @($remainingSnaps | Where-Object { $_ -match '-9-aaaa\.json$' }).Count -eq 0
    ) 'Remove-OldRegistryHistory sorts numeric revisions accurately and preserves registry_rev - 1 rollback target'

    # =========================================================================
    # 5. maintain.ps1: selftest rollback, isolated Git commit, -Push, dirty guard
    # =========================================================================
    $gitExe = Resolve-TestGit
    Assert-MTest ($null -ne $gitExe) 'git.exe available for maintain.ps1 Git integration tests'
    if ($null -ne $gitExe) {
        $env:MODEL_ORCHESTRA_GIT = $gitExe
        $bareDir = Join-Path $tempRoot 'origin.git'
        $repoDir = Join-Path $tempRoot 'repo'
        [void][IO.Directory]::CreateDirectory($bareDir)
        [void][IO.Directory]::CreateDirectory((Join-Path $repoDir 'registry'))
        [void][IO.Directory]::CreateDirectory((Join-Path $repoDir 'references'))
        [void][IO.Directory]::CreateDirectory((Join-Path $repoDir 'notes'))

        $null = Invoke-OrchestraProcess -FilePath $gitExe -Arguments @('init', '--bare', $bareDir) -WorkDir $tempRoot -TimeoutSec 30 -CaptureStdout
        $null = Invoke-OrchestraProcess -FilePath $gitExe -Arguments @('init', $repoDir) -WorkDir $tempRoot -TimeoutSec 30 -CaptureStdout
        $null = Invoke-OrchestraProcess -FilePath $gitExe -Arguments @('config', 'user.name', 'Cowork Test') -WorkDir $repoDir -TimeoutSec 15 -CaptureStdout
        $null = Invoke-OrchestraProcess -FilePath $gitExe -Arguments @('config', 'user.email', 'cowork@example.invalid') -WorkDir $repoDir -TimeoutSec 15 -CaptureStdout
        $null = Invoke-OrchestraProcess -FilePath $gitExe -Arguments @('remote', 'add', 'origin', $bareDir) -WorkDir $repoDir -TimeoutSec 15 -CaptureStdout

        $repoRegPath = Join-Path $repoDir 'registry\models.json'
        $repoStateDir = Join-Path $tempRoot 'repo-state'
        $repoReg = Read-JsonFile -Path $sourcePaths.Registry
        Set-OrchestraProperty $repoReg 'registry_rev' 77
        Write-JsonAtomic -Path $repoRegPath -Object $repoReg
        foreach ($relDoc in @('SKILL.md', 'references\model-profiles.md', 'README.md')) {
            [IO.File]::Copy((Join-Path $root $relDoc), (Join-Path $repoDir $relDoc), $true)
        }
        [IO.File]::WriteAllText((Join-Path $repoDir 'notes\unrelated.txt'), "v1`n", $script:OrchestraUtf8)

        $null = Invoke-OrchestraProcess -FilePath $gitExe -Arguments @('add', '-A') -WorkDir $repoDir -TimeoutSec 30 -CaptureStdout
        $null = Invoke-OrchestraProcess -FilePath $gitExe -Arguments @('commit', '-m', 'initial drifted docs') -WorkDir $repoDir -TimeoutSec 30 -CaptureStdout
        $null = Invoke-OrchestraProcess -FilePath $gitExe -Arguments @('push', '-u', 'origin', 'HEAD') -WorkDir $repoDir -TimeoutSec 30 -CaptureStdout

        $passShim = Join-Path $tempRoot 'selftest-pass.ps1'
        $failShim = Join-Path $tempRoot 'selftest-fail.ps1'
        [IO.File]::WriteAllText($passShim, "param([string]`$RegistryPath,[string]`$StateDir)`n[Console]::Out.WriteLine('{""passed"":1,""failed"":0}')`nexit 0`n", $script:OrchestraUtf8)
        [IO.File]::WriteAllText($failShim, "param([string]`$RegistryPath,[string]`$StateDir)`n[Console]::Out.WriteLine('{""passed"":0,""failed"":1}')`nexit 1`n", $script:OrchestraUtf8)

        # 5a. Failing selftest rolls back synced docs byte-for-byte
        $readmeBefore = [IO.File]::ReadAllText((Join-Path $repoDir 'README.md'), $script:OrchestraUtf8)
        $env:MODEL_ORCHESTRA_SELFTEST_SCRIPT = $failShim
        $mFail = Invoke-MScript 'scripts\maintain.ps1' @(
            '-SkipResearch', '-CodexDestination', '',
            '-RegistryPath', $repoRegPath, '-StateDir', $repoStateDir
        )
        $readmeAfterFail = [IO.File]::ReadAllText((Join-Path $repoDir 'README.md'), $script:OrchestraUtf8)
        Assert-MTest (
            $mFail.Exit -eq 3 -and
            [bool]$mFail.Json.rolled_back -eq $true -and
            ($readmeBefore -ceq $readmeAfterFail)
        ) 'maintain.ps1 atomically rolls back managed files when selftest gate fails'

        # 5b. Stage an unrelated file in .git/index, run passing maintain.ps1 WITHOUT -Push
        [IO.File]::WriteAllText((Join-Path $repoDir 'notes\unrelated.txt'), "staged-unrelated-change`n", $script:OrchestraUtf8)
        $null = Invoke-OrchestraProcess -FilePath $gitExe -Arguments @('add', 'notes/unrelated.txt') -WorkDir $repoDir -TimeoutSec 15 -CaptureStdout
        $originBefore = ([string]((Invoke-OrchestraProcess -FilePath $gitExe -Arguments @('rev-parse', 'HEAD') -WorkDir $bareDir -TimeoutSec 15 -CaptureStdout).stdout[0])).Trim()

        $env:MODEL_ORCHESTRA_SELFTEST_SCRIPT = $passShim
        $mPass = Invoke-MScript 'scripts\maintain.ps1' @(
            '-SkipResearch', '-CodexDestination', '',
            '-RegistryPath', $repoRegPath, '-StateDir', $repoStateDir
        )
        $localHead = ([string]((Invoke-OrchestraProcess -FilePath $gitExe -Arguments @('rev-parse', 'HEAD') -WorkDir $repoDir -TimeoutSec 15 -CaptureStdout).stdout[0])).Trim()
        $originAfterLocal = ([string]((Invoke-OrchestraProcess -FilePath $gitExe -Arguments @('rev-parse', 'HEAD') -WorkDir $bareDir -TimeoutSec 15 -CaptureStdout).stdout[0])).Trim()
        $stagedFiles = @((Invoke-OrchestraProcess -FilePath $gitExe -Arguments @('diff', '--cached', '--name-only') -WorkDir $repoDir -TimeoutSec 15 -CaptureStdout).stdout | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        Assert-MTest (
            $mPass.Exit -eq 0 -and
            [bool]$mPass.Json.git_committed -eq $true -and
            [bool]$mPass.Json.git_pushed -eq $false -and
            ($localHead -ne $originBefore) -and
            ($originAfterLocal -eq $originBefore) -and
            ($stagedFiles -contains 'notes/unrelated.txt')
        ) 'maintain.ps1 commits only managed paths via GIT_INDEX_FILE without pushing or touching unrelated staged files'

        # 5c. Explicit -Push pushes HEAD to origin
        $mPush = Invoke-MScript 'scripts\maintain.ps1' @(
            '-SkipResearch', '-Push', '-CodexDestination', '',
            '-RegistryPath', $repoRegPath, '-StateDir', $repoStateDir
        )
        $originAfterPush = ([string]((Invoke-OrchestraProcess -FilePath $gitExe -Arguments @('rev-parse', 'HEAD') -WorkDir $bareDir -TimeoutSec 15 -CaptureStdout).stdout[0])).Trim()
        Assert-MTest (
            $mPush.Exit -eq 0 -and
            [bool]$mPush.Json.git_pushed -eq $true -and
            ($originAfterPush -eq $localHead)
        ) 'maintain.ps1 -Push pushes committed HEAD to origin'

        # 5d. Pre-dirty managed path skips auto-commit safely
        [IO.File]::AppendAllText((Join-Path $repoDir 'README.md'), "`nmanual uncommitted note`n", $script:OrchestraUtf8)
        $mDirty = Invoke-MScript 'scripts\maintain.ps1' @(
            '-SkipResearch', '-CodexDestination', '',
            '-RegistryPath', $repoRegPath, '-StateDir', $repoStateDir
        )
        Assert-MTest (
            $mDirty.Exit -eq 0 -and
            [bool]$mDirty.Json.git_committed -eq $false -and
            [string]$mDirty.Json.git_skip_reason -eq 'dirty_managed_paths'
        ) 'maintain.ps1 skips auto-commit when managed paths have pre-existing uncommitted edits'
    }
}
catch {
    [void]$script:maintFailures.Add('Harness: ' + $_.Exception.Message)
}
finally {
    Remove-ReparseLinkSafe -LinkPath $tempJunctionPath
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_NOW', $oldNow, 'Process')
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX', $oldCodex, 'Process')
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER', $oldAgy, 'Process')
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_SELFTEST_SCRIPT', $oldSelftest, 'Process')
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_GIT', $oldGit, 'Process')

    if ($null -ne $tempRoot -and [IO.Directory]::Exists($tempRoot)) {
        try {
            $abs = [IO.Path]::GetFullPath($tempRoot)
            $prefix = $tempParent.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            $leaf = [IO.Path]::GetFileName($abs)
            if (-not $abs.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
                $leaf -notmatch '^model-orchestra-maintain-test-[a-f0-9]{32}$') {
                throw 'Refusing cleanup outside unique maintain test directory.'
            }
            Get-ChildItem -LiteralPath $abs -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                if (($_.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
                    $_.Attributes = ($_.Attributes -bxor [IO.FileAttributes]::ReadOnly)
                }
            }
            Remove-Item -LiteralPath $abs -Recurse -Force
        }
        catch {
            [void]$script:maintFailures.Add('Cleanup: ' + $_.Exception.Message)
        }
    }
}

Write-OrchestraResult -Object @{
    suite = 'maintain'
    passed = $script:maintPassed
    failed = $script:maintFailures.Count
    failures = $script:maintFailures.ToArray()
}
if ($script:maintFailures.Count -gt 0) { exit 1 }
exit 0
