<#
.SYNOPSIS
Environment health check, Junction self-repair, and Codex shell evolution probe.
.DESCRIPTION
Executes all external checks outside locks; acquires the state lock only briefly
when persisting repairs or Codex non-interactive shell probe metadata.
#>
[CmdletBinding()]
param(
    [switch]$Repair,
    [switch]$ProbeCodexShell,
    [switch]$NoNetwork,
    [string]$CodexDestination = (Join-Path $HOME '.codex\skills\cowork'),
    [string]$RegistryPath,
    [string]$StateDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Add-DoctorCheck {
    param(
        [System.Collections.Generic.List[object]]$List,
        [string]$Name,
        [bool]$Passed,
        [string]$Detail = ''
    )
    [void]$List.Add([pscustomobject]@{
        name = $Name
        passed = $Passed
        detail = $Detail
    })
}

function Test-JunctionPointsToRoot {
    param([string]$LinkPath, [string]$ExpectedRoot)
    if ([string]::IsNullOrWhiteSpace($LinkPath)) {
        return [pscustomobject]@{ skipped = $true; exists = $false; valid = $true; detail = 'CodexDestination disabled.' }
    }
    if (-not (Test-Path -LiteralPath $LinkPath)) {
        return [pscustomobject]@{ skipped = $false; exists = $false; valid = $false; detail = "Missing Junction: $LinkPath" }
    }
    $item = Get-Item -LiteralPath $LinkPath -Force
    $isReparse = (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    if (-not $isReparse) {
        return [pscustomobject]@{ skipped = $false; exists = $true; valid = $false; detail = "Path exists without ReparsePoint attribute: $LinkPath" }
    }
    $expectedNorm = [IO.Path]::GetFullPath($ExpectedRoot).TrimEnd('\', '/')
    $targets = @()
    $targetProp = $item.PSObject.Properties['Target']
    if ($null -ne $targetProp -and $null -ne $targetProp.Value) {
        $targets = @($targetProp.Value)
    }
    if ($targets.Count -gt 0) {
        foreach ($t in $targets) {
            $cleanTarget = ([string]$t) -replace '^\\\?\?\\', ''
            if ([IO.Path]::GetFullPath($cleanTarget).TrimEnd('\', '/') -ieq $expectedNorm) {
                return [pscustomobject]@{ skipped = $false; exists = $true; valid = $true; detail = $LinkPath }
            }
        }
        return [pscustomobject]@{ skipped = $false; exists = $true; valid = $false; detail = ("Reparse target mismatch: " + ($targets -join ', ')) }
    }
    # Fallback for environments without Item.Target: verify sentinel file identity
    $sentinelLink = Join-Path $LinkPath 'scripts\lib\common.ps1'
    $sentinelRoot = Join-Path $ExpectedRoot 'scripts\lib\common.ps1'
    if ([IO.File]::Exists($sentinelLink) -and [IO.File]::Exists($sentinelRoot)) {
        return [pscustomobject]@{ skipped = $false; exists = $true; valid = $true; detail = $LinkPath }
    }
    return [pscustomobject]@{ skipped = $false; exists = $true; valid = $false; detail = "Unable to verify reparse target: $LinkPath" }
}

try {
    $paths = Get-OrchestraPaths -RegistryPath $RegistryPath -StateDir $StateDir
    $checks = New-Object 'System.Collections.Generic.List[object]'
    $repairs = New-Object 'System.Collections.Generic.List[string]'
    $warnings = New-Object 'System.Collections.Generic.List[string]'

    # 1. Registry readability
    $registry = $null
    $registryOk = $false
    try {
        $registry = Read-Registry -Paths $paths
        $registryOk = $true
        Add-DoctorCheck $checks 'registry_parses' $true ("registry_rev=" + [long](Get-OrchestraProperty $registry 'registry_rev' 0))
    }
    catch {
        Add-DoctorCheck $checks 'registry_parses' $false $_.Exception.Message
    }

    # 2. Managed documentation sync check (only when checking canonical registry)
    $docsOk = $true
    $canonicalRegistry = [IO.Path]::GetFullPath((Join-Path $paths.Root 'registry\models.json'))
    $syncScript = Join-Path $PSScriptRoot 'sync-docs.ps1'
    if ($registryOk -and ([IO.Path]::GetFullPath($paths.Registry) -ieq $canonicalRegistry) -and [IO.File]::Exists($syncScript)) {
        $syncProc = Invoke-OrchestraProcess -FilePath 'powershell.exe' -Arguments @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $syncScript, '-Check',
            '-RegistryPath', $paths.Registry,
            '-Root', $paths.Root
        ) -WorkDir $paths.Root -TimeoutSec 60 -CaptureStdout
        if ($syncProc.exit_code -ne 0 -and $Repair) {
            $repairSync = Invoke-OrchestraProcess -FilePath 'powershell.exe' -Arguments @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', $syncScript,
                '-RegistryPath', $paths.Registry,
                '-Root', $paths.Root
            ) -WorkDir $paths.Root -TimeoutSec 60 -CaptureStdout
            if ($repairSync.exit_code -eq 0) {
                [void]$repairs.Add('managed_docs_synced')
                $syncProc = $repairSync
            }
        }
        $docsOk = ($syncProc.exit_code -eq 0 -and -not $syncProc.timeout)
        Add-DoctorCheck $checks 'docs_sync' $docsOk ($(if ($docsOk) { 'Managed docs match models.json.' } else { 'Managed docs drifted from models.json.' }))
    }
    else {
        Add-DoctorCheck $checks 'docs_sync' $true 'Skipped for non-canonical registry.'
    }

    # 3. Pending proposals count
    $pendingProposals = 0
    if ([IO.Directory]::Exists($paths.Proposals)) {
        $pendingProposals = @(
            Get-ChildItem -LiteralPath $paths.Proposals -Filter '*.json' -File |
                Where-Object { $_.Name -notmatch '\.approved\.json$' }
        ).Count
    }
    if ($pendingProposals -gt 0) {
        [void]$warnings.Add("$pendingProposals pending proposal(s) awaiting user review in registry/proposals.")
    }

    # 4. Codex Junction check & optional repair
    $junctionStatus = Test-JunctionPointsToRoot -LinkPath $CodexDestination -ExpectedRoot $paths.Root
    if (-not $junctionStatus.valid -and -not $junctionStatus.exists -and $Repair -and -not [string]::IsNullOrWhiteSpace($CodexDestination)) {
        $syncCodexScript = Join-Path $PSScriptRoot 'sync-to-codex.ps1'
        $jProc = Invoke-OrchestraProcess -FilePath 'powershell.exe' -Arguments @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $syncCodexScript, '-Destination', $CodexDestination
        ) -WorkDir $paths.Root -TimeoutSec 30 -CaptureStdout
        if ($jProc.exit_code -eq 0) {
            $junctionStatus = Test-JunctionPointsToRoot -LinkPath $CodexDestination -ExpectedRoot $paths.Root
            if ($junctionStatus.valid) {
                [void]$repairs.Add('codex_junction_repaired')
            }
        }
    }
    Add-DoctorCheck $checks 'codex_junction' ([bool]$junctionStatus.valid) $junctionStatus.detail

    # 5. Channel executables (outside locks)
    $codexPath = $null
    $codexOk = $false
    try {
        $codexPath = Resolve-CodexExe -Paths $paths
        $codexOk = $true
        Add-DoctorCheck $checks 'codex_exe' $true $codexPath
    }
    catch {
        Add-DoctorCheck $checks 'codex_exe' $false $_.Exception.Message
        [void]$warnings.Add('Codex executable unavailable: ' + $_.Exception.Message)
    }

    $agyOk = $false
    try {
        $agyPath = Resolve-AgyWrapper
        $agyOk = $true
        Add-DoctorCheck $checks 'agy_wrapper' $true $agyPath
    }
    catch {
        Add-DoctorCheck $checks 'agy_wrapper' $false $_.Exception.Message
        [void]$warnings.Add('Antigravity wrapper unavailable: ' + $_.Exception.Message)
    }

    # 6. Expired state hygiene (exhausted / scan_lease / research_leases)
    $now = Get-OrchestraNow
    $expiredCount = 0
    if ($Repair) {
        $expiredCount = Invoke-WithLock -Paths $paths -Name state -ScriptBlock {
            if (-not [IO.File]::Exists($paths.State)) { return 0 }
            $st = Read-State -Paths $paths
            $cleaned = 0
            $exObj = Get-OrchestraProperty $st 'exhausted'
            foreach ($mKey in @(Get-OrchestraNames $exObj)) {
                $entry = Get-OrchestraProperty $exObj $mKey
                try {
                    if ((ConvertTo-OrchestraUtc ([string](Get-OrchestraProperty $entry 'until'))) -le $now) {
                        [void]$exObj.PSObject.Properties.Remove($mKey)
                        $cleaned++
                    }
                }
                catch {
                    [void]$exObj.PSObject.Properties.Remove($mKey)
                    $cleaned++
                }
            }
            $scanLease = Get-OrchestraProperty $st 'scan_lease'
            if ($null -ne $scanLease) {
                try {
                    if ((ConvertTo-OrchestraUtc ([string](Get-OrchestraProperty $scanLease 'until'))) -le $now) {
                        Set-OrchestraProperty $st 'scan_lease' $null
                        $cleaned++
                    }
                }
                catch {
                    Set-OrchestraProperty $st 'scan_lease' $null
                    $cleaned++
                }
            }
            $rLeases = Get-OrchestraProperty $st 'research_leases'
            foreach ($rKey in @(Get-OrchestraNames $rLeases)) {
                $rEntry = Get-OrchestraProperty $rLeases $rKey
                try {
                    if ((ConvertTo-OrchestraUtc ([string](Get-OrchestraProperty $rEntry 'until'))) -le $now) {
                        [void]$rLeases.PSObject.Properties.Remove($rKey)
                        $cleaned++
                    }
                }
                catch {
                    [void]$rLeases.PSObject.Properties.Remove($rKey)
                    $cleaned++
                }
            }
            if ($cleaned -gt 0) {
                Save-State -Paths $paths -State $st
            }
            return $cleaned
        }
        if ($expiredCount -gt 0) {
            [void]$repairs.Add('expired_state_cleaned')
        }
    }
    else {
        if ([IO.File]::Exists($paths.State)) {
            $stSnap = Read-State -Paths $paths
            $exObj = Get-OrchestraProperty $stSnap 'exhausted'
            foreach ($mKey in @(Get-OrchestraNames $exObj)) {
                $entry = Get-OrchestraProperty $exObj $mKey
                try {
                    if ((ConvertTo-OrchestraUtc ([string](Get-OrchestraProperty $entry 'until'))) -le $now) { $expiredCount++ }
                }
                catch { $expiredCount++ }
            }
            $scanLease = Get-OrchestraProperty $stSnap 'scan_lease'
            if ($null -ne $scanLease) {
                try {
                    if ((ConvertTo-OrchestraUtc ([string](Get-OrchestraProperty $scanLease 'until'))) -le $now) { $expiredCount++ }
                }
                catch { $expiredCount++ }
            }
            $rLeases = Get-OrchestraProperty $stSnap 'research_leases'
            foreach ($rKey in @(Get-OrchestraNames $rLeases)) {
                $rEntry = Get-OrchestraProperty $rLeases $rKey
                try {
                    if ((ConvertTo-OrchestraUtc ([string](Get-OrchestraProperty $rEntry 'until'))) -le $now) { $expiredCount++ }
                }
                catch { $expiredCount++ }
            }
        }
    }
    Add-DoctorCheck $checks 'state_hygiene' $true ("expired_entries=" + $expiredCount)

    # 7. Codex non-interactive shell evolution probe
    $stateAfter = Read-State -Paths $paths
    $exeCache = Get-OrchestraProperty $stateAfter 'codex_exe_cache'
    $codexVersion = [string](Get-OrchestraProperty $exeCache 'version' '')
    $shellProbe = Get-OrchestraProperty $stateAfter 'codex_shell_probe'
    $probedVersion = [string](Get-OrchestraProperty $shellProbe 'version' '')
    $codexVersionChanged = (-not [string]::IsNullOrWhiteSpace($codexVersion)) -and ($probedVersion -ne $codexVersion)

    $codexOverrideSet = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_CODEX'))
    if ($ProbeCodexShell -and $codexOk -and (-not $NoNetwork -or $codexOverrideSet)) {
        $probeRun = Invoke-OrchestraProcess -FilePath $codexPath -Arguments @(
            'exec', '--json', '-s', 'read-only', '--skip-git-repo-check', '-C', $paths.Root, '-'
        ) -InputText 'Run a shell command that prints COWORK_SHELL_OK and reply with COWORK_SHELL_OK.' -WorkDir $paths.Root -TimeoutSec 8 -CaptureStdout
        $hasShellToolMarker = $false
        foreach ($rawLine in @($probeRun.stdout)) {
            if ([string]::IsNullOrWhiteSpace([string]$rawLine)) { continue }
            $evObj = $null
            try { $evObj = ([string]$rawLine | ConvertFrom-Json) } catch { continue }
            if ($null -eq $evObj) { continue }
            $evType = [string](Get-OrchestraProperty $evObj 'type')
            $item = Get-OrchestraProperty $evObj 'item' $null
            if ($null -ne $item) {
                $itemType = [string](Get-OrchestraProperty $item 'type')
                if ($evType -eq 'item.completed' -and $itemType -in @('command_execution', 'local_shell_call', 'shell_call', 'mcp_tool_call')) {
                    $exitProp = $item.PSObject.Properties['exit_code']
                    $exitOk = ($null -eq $exitProp) -or ($null -eq $exitProp.Value) -or ([int]$exitProp.Value -eq 0)
                    $toolOut = @(
                        [string](Get-OrchestraProperty $item 'aggregated_output' ''),
                        [string](Get-OrchestraProperty $item 'output' ''),
                        [string](ConvertTo-Json -InputObject (Get-OrchestraProperty $item 'result' '') -Depth 8 -Compress)
                    ) -join "`n"
                    if ($exitOk -and ($toolOut -match 'COWORK_SHELL_OK')) {
                        $hasShellToolMarker = $true
                        break
                    }
                }
            }
            elseif ($evType -in @('exec_command_end', 'command_execution')) {
                $exitProp = $evObj.PSObject.Properties['exit_code']
                $exitOk = ($null -eq $exitProp) -or ($null -eq $exitProp.Value) -or ([int]$exitProp.Value -eq 0)
                $toolOut = @(
                    [string](Get-OrchestraProperty $evObj 'aggregated_output' ''),
                    [string](Get-OrchestraProperty $evObj 'stdout' ''),
                    [string](Get-OrchestraProperty $evObj 'output' '')
                ) -join "`n"
                if ($exitOk -and ($toolOut -match 'COWORK_SHELL_OK')) {
                    $hasShellToolMarker = $true
                    break
                }
            }
        }
        $shellWorks = (
            -not $probeRun.timeout -and
            -not $probeRun.truncated -and
            $probeRun.exit_code -eq 0 -and
            $hasShellToolMarker
        )
        $shellProbe = [pscustomobject]@{
            version = $codexVersion
            shell_works = [bool]$shellWorks
            checked_utc = (Get-OrchestraNow).ToString('o')
        }
        Invoke-WithLock -Paths $paths -Name state -ScriptBlock {
            $freshState = Read-State -Paths $paths
            Set-OrchestraProperty $freshState 'codex_shell_probe' $shellProbe
            Save-State -Paths $paths -State $freshState
        }
        $codexVersionChanged = $false
    }

    # 8. 30-day outcome recording coverage
    $events30 = @()
    if ([IO.File]::Exists($paths.Usage)) {
        $events30 = @(Read-UsageEvents -Paths $paths -SinceDays 30)
    }
    $invIds = @{}
    $outIds = @{}
    foreach ($ev in $events30) {
        $evType = [string](Get-OrchestraProperty $ev 'type')
        $id = [string](Get-OrchestraProperty $ev 'invocation_id')
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if ($evType -eq 'invocation') {
            $isAdHoc = [bool](Get-OrchestraProperty $ev 'ad_hoc' $false)
            $evExit = [int](Get-OrchestraProperty $ev 'exit' -1)
            if (-not $isAdHoc -and $evExit -eq 0) {
                $invIds[$id] = $true
            }
        }
        elseif ($evType -eq 'outcome') {
            $val = [string](Get-OrchestraProperty $ev 'outcome')
            if ($val -in @('ok', 'redo', 'fail')) {
                $outIds[$id] = $true
            }
        }
    }
    $totalInv = $invIds.Count
    $coveredInv = 0
    foreach ($k in $invIds.Keys) {
        if ($outIds.ContainsKey($k)) { $coveredInv++ }
    }
    $unrecorded = $totalInv - $coveredInv
    $coverageRate = if ($totalInv -eq 0) { 1.0 } else { [Math]::Round(($coveredInv / [double]$totalInv), 4) }
    if ($totalInv -ge 5 -and $coverageRate -lt 0.5) {
        [void]$warnings.Add("Low outcome recording coverage ($coverageRate across $totalInv invocations); remember to call record-outcome.ps1.")
    }

    $healthy = ($registryOk -and $docsOk -and [bool]$junctionStatus.valid)
    Write-OrchestraResult -Object ([ordered]@{
        healthy = [bool]$healthy
        checks = $checks.ToArray()
        repairs = [string[]]$repairs.ToArray()
        warnings = [string[]]$warnings.ToArray()
        pending_proposals = [int]$pendingProposals
        unrecorded_outcomes = [int]$unrecorded
        outcome_coverage_rate = [double]$coverageRate
        codex_version_changed = [bool]$codexVersionChanged
        codex_shell_probe = $shellProbe
    })
    if (-not $healthy) { exit 1 }
    exit 0
}
catch {
    $message = $_.Exception.Message
    $code = Get-OrchestraExitCode -Message $message
    [Console]::Error.WriteLine($message)
    Write-OrchestraResult -Object @{
        healthy = $false
        error = $message
        exit = $code
    }
    exit $code
}
