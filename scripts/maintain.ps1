<#
.SYNOPSIS
Self-maintenance and self-upgrade orchestrator for cowork.
.DESCRIPTION
Runs doctor -> detect -> optional web research & cross-check -> optional manual probe ->
telemetry calibration -> doc sync -> selftest gate (with full atomic rollback on failure) ->
usage ledger compaction & history GC -> isolated Git commit (and opt-in push).
#>
[CmdletBinding()]
param(
    [switch]$SkipResearch,
    [switch]$ForceDetect,
    [int]$MaxResearch = 2,
    [switch]$RunProbe,
    [string[]]$ProbeModels = @(),
    [switch]$CompactUsage,
    [switch]$NoGitCommit,
    [switch]$Push,
    [switch]$DryRun,
    [string]$CodexDestination = (Join-Path $HOME '.codex\skills\cowork'),
    [string]$AgyListFile,
    [string]$CodexCatalogFile,
    [string]$RegistryPath,
    [string]$StateDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Resolve-GitExecutable {
    $override = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_GIT')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $full = [IO.Path]::GetFullPath($override)
        if ([IO.File]::Exists($full)) { return $full }
        return $null
    }
    $cmd = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd -and [IO.File]::Exists([string]$cmd.Source)) {
        return [string]$cmd.Source
    }
    $localApp = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    if (-not [string]::IsNullOrWhiteSpace($localApp)) {
        $wingetPkgs = Join-Path $localApp 'Microsoft\WinGet\Packages'
        if ([IO.Directory]::Exists($wingetPkgs)) {
            $minGit = Get-ChildItem -LiteralPath $wingetPkgs -Filter 'Git.MinGit*' -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $minGit) {
                $candidate = Join-Path $minGit.FullName 'cmd\git.exe'
                if ([IO.File]::Exists($candidate)) { return $candidate }
            }
        }
    }
    foreach ($fallback in @('C:\Program Files\Git\cmd\git.exe', 'C:\Program Files (x86)\Git\cmd\git.exe')) {
        if ([IO.File]::Exists($fallback)) { return $fallback }
    }
    return $null
}

function Invoke-GitCommand {
    param(
        [string]$GitExe,
        [string]$RepoRoot,
        [string[]]$Arguments,
        [string]$IndexFile = '',
        [switch]$WithSystemProxy
    )
    $oldIndex = [Environment]::GetEnvironmentVariable('GIT_INDEX_FILE')
    $oldHttpProxy = [Environment]::GetEnvironmentVariable('HTTP_PROXY')
    $oldHttpsProxy = [Environment]::GetEnvironmentVariable('HTTPS_PROXY')
    try {
        if (-not [string]::IsNullOrWhiteSpace($IndexFile)) {
            [Environment]::SetEnvironmentVariable('GIT_INDEX_FILE', $IndexFile, 'Process')
        }
        if ($WithSystemProxy -and [string]::IsNullOrWhiteSpace($oldHttpsProxy)) {
            try {
                $inet = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
                if ($null -ne $inet -and [int]$inet.ProxyEnable -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$inet.ProxyServer)) {
                    $proxyVal = [string]$inet.ProxyServer
                    if ($proxyVal -notmatch '^https?://') { $proxyVal = 'http://' + $proxyVal }
                    [Environment]::SetEnvironmentVariable('HTTP_PROXY', $proxyVal, 'Process')
                    [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $proxyVal, 'Process')
                }
            }
            catch {}
        }
        return (Invoke-OrchestraProcess -FilePath $GitExe -Arguments $Arguments -WorkDir $RepoRoot -TimeoutSec 120 -CaptureStdout)
    }
    finally {
        [Environment]::SetEnvironmentVariable('GIT_INDEX_FILE', $oldIndex, 'Process')
        [Environment]::SetEnvironmentVariable('HTTP_PROXY', $oldHttpProxy, 'Process')
        [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $oldHttpsProxy, 'Process')
    }
}

function Invoke-ChildJsonScript {
    param(
        [string]$ScriptPath,
        [string[]]$Arguments = @(),
        [string]$WorkDir,
        [int]$TimeoutSec = 1800
    )
    $proc = Invoke-OrchestraProcess -FilePath 'powershell.exe' -Arguments (
        @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $Arguments
    ) -WorkDir $WorkDir -TimeoutSec $TimeoutSec -CaptureStdout
    $json = $null
    $nonEmpty = @($proc.stdout | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($nonEmpty.Count -gt 0) {
        try { $json = ([string]$nonEmpty[$nonEmpty.Count - 1] | ConvertFrom-Json) } catch { $json = $null }
    }
    return [pscustomobject]@{
        exit_code = [int]$proc.exit_code
        timeout = [bool]$proc.timeout
        json = $json
        stdout = $proc.stdout
        stderr = $proc.stderr
    }
}

function Get-FileSignature {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return 'MISSING' }
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '')
    }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Copy-FileAtomic {
    param([string]$Source, [string]$Destination)
    $destFull = [IO.Path]::GetFullPath($Destination)
    $dir = [IO.Path]::GetDirectoryName($destFull)
    [void][IO.Directory]::CreateDirectory($dir)
    $tmp = Join-Path $dir ('.' + [IO.Path]::GetFileName($destFull) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::Copy($Source, $tmp, $true)
        if ([IO.File]::Exists($destFull)) {
            [IO.File]::Replace($tmp, $destFull, [NullString]::Value)
        }
        else {
            [IO.File]::Move($tmp, $destFull)
        }
    }
    finally {
        if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
    }
}

function Save-MaintainSnapshot {
    param([string]$TxDir, [string[]]$TrackedFiles, [hashtable]$Paths)
    return (Invoke-WithLock -Paths $Paths -Name registry -ScriptBlock {
        $fileStates = @{}
        $idx = 0
        foreach ($f in $TrackedFiles) {
            $idx++
            $exists = [IO.File]::Exists($f)
            $backupFile = Join-Path $TxDir ("file-$idx.bak")
            if ($exists) { [IO.File]::Copy($f, $backupFile, $true) }
            $fileStates[$f] = [pscustomobject]@{
                exists = $exists
                backup = $backupFile
                sig = (Get-FileSignature -Path $f)
            }
        }
        $preProposals = @{}
        if ([IO.Directory]::Exists($Paths.Proposals)) {
            foreach ($item in @(Get-ChildItem -LiteralPath $Paths.Proposals -File)) {
                $bak = Join-Path $TxDir ('prop-' + [Guid]::NewGuid().ToString('N') + '.bak')
                [IO.File]::Copy($item.FullName, $bak, $true)
                $preProposals[$item.FullName] = [pscustomobject]@{
                    sig = (Get-FileSignature -Path $item.FullName)
                    backup = $bak
                }
            }
        }
        $preHistory = @{}
        if ([IO.Directory]::Exists($Paths.History)) {
            foreach ($item in @(Get-ChildItem -LiteralPath $Paths.History -File)) {
                $preHistory[$item.FullName] = $true
            }
        }
        return [pscustomobject]@{
            files = $fileStates
            proposals = $preProposals
            history = $preHistory
        }
    })
}

function Register-OwnedProposals {
    param([System.Collections.Generic.HashSet[string]]$Set, [object[]]$ProposalPaths)
    if ($null -eq $Set -or $null -eq $ProposalPaths) { return }
    foreach ($p in $ProposalPaths) {
        $sp = [string]$p
        if ([string]::IsNullOrWhiteSpace($sp)) { continue }
        $full = [IO.Path]::GetFullPath($sp)
        [void]$Set.Add($full)
        if ($full -match '\.json$') {
            [void]$Set.Add([IO.Path]::ChangeExtension($full, '.md'))
        }
    }
}

function Test-MaintainChanged {
    param($Snapshot, [hashtable]$Paths)
    foreach ($f in $Snapshot.files.Keys) {
        if ((Get-FileSignature -Path $f) -ne $Snapshot.files[$f].sig) { return $true }
    }
    $curProps = @{}
    if ([IO.Directory]::Exists($Paths.Proposals)) {
        foreach ($item in @(Get-ChildItem -LiteralPath $Paths.Proposals -File)) {
            $curProps[$item.FullName] = (Get-FileSignature -Path $item.FullName)
        }
    }
    if ($curProps.Count -ne $Snapshot.proposals.Count) { return $true }
    foreach ($k in $curProps.Keys) {
        if (-not $Snapshot.proposals.ContainsKey($k)) { return $true }
        if ($curProps[$k] -ne $Snapshot.proposals[$k].sig) { return $true }
    }
    return $false
}

function Restore-MaintainSnapshot {
    param(
        $Snapshot,
        [hashtable]$Paths,
        [System.Collections.Generic.HashSet[string]]$OwnedProposals
    )
    Invoke-WithLock -Paths $Paths -Name registry -ScriptBlock {
        foreach ($f in $Snapshot.files.Keys) {
            $entry = $Snapshot.files[$f]
            if ((Get-FileSignature -Path $f) -eq $entry.sig) { continue }
            if ($entry.exists) {
                Copy-FileAtomic -Source $entry.backup -Destination $f
            }
            elseif ([IO.File]::Exists($f)) {
                [IO.File]::Delete($f)
            }
        }
        if ([IO.Directory]::Exists($Paths.Proposals)) {
            foreach ($item in @(Get-ChildItem -LiteralPath $Paths.Proposals -File)) {
                $full = [IO.Path]::GetFullPath($item.FullName)
                if ($Snapshot.proposals.ContainsKey($full)) { continue }
                # Never remove a concurrent user approval (.approved.json)
                if ($item.Name -match '\.approved\.json$') { continue }
                if (($null -ne $OwnedProposals -and $OwnedProposals.Contains($full)) -or (-not $Snapshot.proposals.ContainsKey($full))) {
                    Remove-Item -LiteralPath $full -Force
                }
            }
            foreach ($origPath in $Snapshot.proposals.Keys) {
                $origEntry = $Snapshot.proposals[$origPath]
                if (-not [IO.File]::Exists($origPath)) {
                    # Preserve concurrent user approval if user approved P.json -> P.approved.json during run
                    $approvedCompanion = ($origPath -replace '\.json$', '.approved.json')
                    if (($origPath -match '\.json$') -and [IO.File]::Exists($approvedCompanion)) { continue }
                    Copy-FileAtomic -Source $origEntry.backup -Destination $origPath
                }
                elseif ((Get-FileSignature -Path $origPath) -ne $origEntry.sig) {
                    Copy-FileAtomic -Source $origEntry.backup -Destination $origPath
                }
            }
        }
        if ([IO.Directory]::Exists($Paths.History)) {
            foreach ($item in @(Get-ChildItem -LiteralPath $Paths.History -File)) {
                if (-not $Snapshot.history.ContainsKey($item.FullName)) {
                    Remove-Item -LiteralPath $item.FullName -Force
                }
            }
        }
    }
}

$txParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$txDir = Join-Path $txParent ('cowork-maintain-tx-' + [Guid]::NewGuid().ToString('N'))
$paths = $null
$snapshot = $null
$gitCommitted = $false
$script:keepTxBackup = $false
$txOwnedProposals = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

try {
    if ($MaxResearch -lt 0) {
        throw 'ORCHESTRA_ARGS: MaxResearch cannot be negative.'
    }
    $paths = Get-OrchestraPaths -RegistryPath $RegistryPath -StateDir $StateDir
    $canonicalReg = [IO.Path]::GetFullPath((Join-Path $paths.Root 'registry\models.json'))
    $isCanonicalRepo = ([IO.Path]::GetFullPath($paths.Registry) -ieq $canonicalReg)
    $repoRoot = if ($isCanonicalRepo) { $paths.Root } else { Split-Path -Parent $paths.RegistryDir }

    $trackedFiles = @(
        $paths.Registry,
        $paths.Changelog,
        (Join-Path $repoRoot 'SKILL.md'),
        (Join-Path $repoRoot 'references\model-profiles.md'),
        (Join-Path $repoRoot 'README.md')
    )

    $managedRelCandidates = @('registry', 'SKILL.md', 'references/model-profiles.md', 'README.md')
    $existingManagedRels = @(
        foreach ($rel in $managedRelCandidates) {
            $abs = Join-Path $repoRoot ($rel -replace '/', '\')
            if (Test-Path -LiteralPath $abs) { $rel }
        }
    )

    $gitExe = Resolve-GitExecutable
    $hasGit = ($null -ne $gitExe) -and (Test-Path -LiteralPath (Join-Path $repoRoot '.git'))
    $gitCommitAllowed = (-not $NoGitCommit -and -not $DryRun -and $hasGit)
    $gitSkipReason = $null
    if ($DryRun) { $gitSkipReason = 'dry_run' }
    elseif ($NoGitCommit) { $gitSkipReason = 'no_git_commit_flag' }
    elseif (-not $hasGit) { $gitSkipReason = 'no_git_repo' }

    if ($hasGit -and $existingManagedRels.Count -gt 0) {
        $preStatus = Invoke-GitCommand -GitExe $gitExe -RepoRoot $repoRoot -Arguments (@('status', '--porcelain', '--') + $existingManagedRels)
        $dirtyLines = @($preStatus.stdout | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($dirtyLines.Count -gt 0) {
            $gitCommitAllowed = $false
            $gitSkipReason = 'dirty_managed_paths'
        }
    }

    $snapshot = $null
    if (-not $DryRun) {
        [void][IO.Directory]::CreateDirectory($txDir)
        $snapshot = Save-MaintainSnapshot -TxDir $txDir -TrackedFiles $trackedFiles -Paths $paths
    }

    # Step 1: doctor.ps1
    $doctorArgs = @(
        '-CodexDestination', $CodexDestination,
        '-RegistryPath', $paths.Registry,
        '-StateDir', $paths.StateDir
    )
    if (-not $DryRun) { $doctorArgs += '-Repair' }
    if ($SkipResearch -or $DryRun) { $doctorArgs += '-NoNetwork' }
    $doctorRun = Invoke-ChildJsonScript -ScriptPath (Join-Path $PSScriptRoot 'doctor.ps1') -Arguments $doctorArgs -WorkDir $paths.Root -TimeoutSec 120
    $doctorSummary = $doctorRun.json
    if ($null -ne $doctorSummary -and [bool](Get-OrchestraProperty $doctorSummary 'codex_version_changed' $false) -and -not $SkipResearch -and -not $DryRun) {
        $probeShellRun = Invoke-ChildJsonScript -ScriptPath (Join-Path $PSScriptRoot 'doctor.ps1') -Arguments @(
            '-ProbeCodexShell', '-CodexDestination', $CodexDestination,
            '-RegistryPath', $paths.Registry, '-StateDir', $paths.StateDir
        ) -WorkDir $paths.Root -TimeoutSec 30
        if ($null -ne $probeShellRun.json) { $doctorSummary = $probeShellRun.json }
    }

    # Step 2: detect-models.ps1
    $detectSummary = $null
    if (-not $DryRun) {
        $detectArgs = @('-RegistryPath', $paths.Registry, '-StateDir', $paths.StateDir)
        if ($ForceDetect) { $detectArgs += '-Force' }
        if (-not [string]::IsNullOrWhiteSpace($AgyListFile)) { $detectArgs += @('-AgyListFile', $AgyListFile) }
        if (-not [string]::IsNullOrWhiteSpace($CodexCatalogFile)) { $detectArgs += @('-CodexCatalogFile', $CodexCatalogFile) }
        $agyWrapperOverride = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER')
        if ($SkipResearch -and [string]::IsNullOrWhiteSpace($AgyListFile) -and [string]::IsNullOrWhiteSpace($agyWrapperOverride)) {
            $detectArgs += '-NoNetwork'
        }
        $detectRun = Invoke-ChildJsonScript -ScriptPath (Join-Path $PSScriptRoot 'detect-models.ps1') -Arguments $detectArgs -WorkDir $paths.Root -TimeoutSec 180
        $detectSummary = $detectRun.json
    }

    # Step 3: Automated web research + cross-vendor rigor cross-check (NO probe execution here!)
    $researchResults = New-Object 'System.Collections.Generic.List[object]'
    if (-not $SkipResearch -and -not $DryRun -and $MaxResearch -gt 0 -and $null -ne $detectSummary) {
        $newIds = @(Get-OrchestraArray $detectSummary 'new')
        $staleIds = @(Get-OrchestraArray $detectSummary 'stale')
        $queue = New-Object 'System.Collections.Generic.List[string]'
        $seenQ = @{}
        foreach ($cid in ($newIds + $staleIds)) {
            $sCid = [string]$cid
            if ([string]::IsNullOrWhiteSpace($sCid) -or $seenQ.ContainsKey($sCid)) { continue }
            $seenQ[$sCid] = $true
            [void]$queue.Add($sCid)
            if ($queue.Count -ge $MaxResearch) { break }
        }

        $crossSchemaObj = [pscustomobject]@{
            '$schema' = 'http://json-schema.org/draft-07/schema#'
            type = 'object'
            additionalProperties = $false
            required = @('disputed')
            properties = [pscustomobject]@{
                disputed = [pscustomobject]@{
                    type = 'array'
                    items = [pscustomobject]@{
                        type = 'object'
                        additionalProperties = $false
                        required = @('cap', 'reason', 'suggested_score')
                        properties = [pscustomobject]@{
                            cap = [pscustomobject]@{ type = 'string'; minLength = 1 }
                            reason = [pscustomobject]@{ type = 'string'; minLength = 1 }
                            suggested_score = [pscustomobject]@{ type = @('number', 'null'); minimum = 0; maximum = 10 }
                        }
                    }
                }
            }
        }

        foreach ($candId in $queue.ToArray()) {
            $mode = if ($newIds -contains $candId) { 'new' } else { 'refresh' }
            $workDir = Join-Path $txDir ('research-' + ($candId -replace '[^A-Za-z0-9._-]', '_'))
            [void][IO.Directory]::CreateDirectory($workDir)
            $promptPath = Join-Path $workDir 'prompt.md'
            $resJsonPath = Join-Path $workDir 'research.json'
            $crossPromptPath = Join-Path $workDir 'crosscheck-prompt.md'
            $crossSchemaPath = Join-Path $workDir 'crosscheck.schema.json'
            $crossJsonPath = Join-Path $workDir 'crosscheck.json'

            $pRun = Invoke-ChildJsonScript -ScriptPath (Join-Path $PSScriptRoot 'research-prompt.ps1') -Arguments @(
                '-ModelId', $candId, '-Mode', $mode, '-OutFile', $promptPath,
                '-RegistryPath', $paths.Registry, '-StateDir', $paths.StateDir
            ) -WorkDir $paths.Root -TimeoutSec 60
            if ($pRun.exit_code -eq 4) {
                [void]$researchResults.Add([pscustomobject]@{ model_id = $candId; mode = $mode; status = 'skipped_lease' })
                continue
            }
            if ($pRun.exit_code -ne 0 -or -not [IO.File]::Exists($promptPath)) {
                [void]$researchResults.Add([pscustomobject]@{ model_id = $candId; mode = $mode; status = 'prompt_failed'; exit = $pRun.exit_code })
                continue
            }

            $invRes = Invoke-ChildJsonScript -ScriptPath (Join-Path $PSScriptRoot 'invoke-model.ps1') -Arguments @(
                '-Model', 'best-knowledge', '-Access', 'read',
                '-PromptFile', $promptPath,
                '-JsonSchema', (Join-Path $paths.Root 'registry\research.schema.json'),
                '-OutFile', $resJsonPath,
                '-Tags', 'research',
                '-WorkDir', $workDir,
                '-RegistryPath', $paths.Registry, '-StateDir', $paths.StateDir
            ) -WorkDir $workDir -TimeoutSec 1800
            if ($invRes.exit_code -ne 0 -or -not [IO.File]::Exists($resJsonPath)) {
                $null = Invoke-ChildJsonScript -ScriptPath (Join-Path $PSScriptRoot 'research-prompt.ps1') -Arguments @(
                    '-ModelId', $candId, '-ReleaseLease',
                    '-RegistryPath', $paths.Registry, '-StateDir', $paths.StateDir
                ) -WorkDir $paths.Root -TimeoutSec 30
                [void]$researchResults.Add([pscustomobject]@{ model_id = $candId; mode = $mode; status = 'research_failed'; exit = $invRes.exit_code })
                continue
            }

            Write-JsonAtomic -Path $crossSchemaPath -Object $crossSchemaObj
            $rawResearchText = [IO.File]::ReadAllText($resJsonPath, $script:OrchestraUtf8)
            $crossPromptText = @(
                'Audit the following candidate model research JSON strictly for unsupported capability scores, missing/non-HTTP evidence URLs, or benchmark exaggerations.'
                'Do NOT invoke any shell or file tools. Output ONLY valid JSON matching the schema: {"disputed":[{"cap":"...","reason":"...","suggested_score":7.0}]}. Return {"disputed":[]} if all claims are well-supported.'
                ''
                '```json'
                $rawResearchText
                '```'
            ) -join "`n"
            [IO.File]::WriteAllText($crossPromptPath, $crossPromptText, $script:OrchestraUtf8)

            $crossRes = Invoke-ChildJsonScript -ScriptPath (Join-Path $PSScriptRoot 'invoke-model.ps1') -Arguments @(
                '-Model', 'best-rigor', '-Access', 'read',
                '-PromptFile', $crossPromptPath,
                '-JsonSchema', $crossSchemaPath,
                '-OutFile', $crossJsonPath,
                '-Tags', 'research',
                '-WorkDir', $workDir,
                '-RegistryPath', $paths.Registry, '-StateDir', $paths.StateDir
            ) -WorkDir $workDir -TimeoutSec 900

            $crossValid = $false
            if ($crossRes.exit_code -eq 0 -and [IO.File]::Exists($crossJsonPath)) {
                try {
                    $parsedCross = Read-JsonFile -Path $crossJsonPath
                    if ($null -ne $parsedCross -and $null -ne $parsedCross.PSObject.Properties['disputed']) {
                        $crossValid = $true
                    }
                }
                catch { $crossValid = $false }
            }
            if (-not $crossValid) {
                $null = Invoke-ChildJsonScript -ScriptPath (Join-Path $PSScriptRoot 'research-prompt.ps1') -Arguments @(
                    '-ModelId', $candId, '-ReleaseLease',
                    '-RegistryPath', $paths.Registry, '-StateDir', $paths.StateDir
                ) -WorkDir $paths.Root -TimeoutSec 30
                [void]$researchResults.Add([pscustomobject]@{ model_id = $candId; mode = $mode; status = 'crosscheck_failed'; exit = $crossRes.exit_code })
                continue
            }

            $applyArgs = @('-ResearchFile', $resJsonPath, '-CrossCheckFile', $crossJsonPath, '-RegistryPath', $paths.Registry, '-StateDir', $paths.StateDir)
            $applyRun = Invoke-ChildJsonScript -ScriptPath (Join-Path $PSScriptRoot 'apply-research.ps1') -Arguments $applyArgs -WorkDir $paths.Root -TimeoutSec 120
            if ($applyRun.exit_code -ne 0) {
                $null = Invoke-ChildJsonScript -ScriptPath (Join-Path $PSScriptRoot 'research-prompt.ps1') -Arguments @(
                    '-ModelId', $candId, '-ReleaseLease',
                    '-RegistryPath', $paths.Registry, '-StateDir', $paths.StateDir
                ) -WorkDir $paths.Root -TimeoutSec 30
                [void]$researchResults.Add([pscustomobject]@{ model_id = $candId; mode = $mode; status = 'apply_failed'; exit = $applyRun.exit_code })
                continue
            }
            $appliedProps = @(Get-OrchestraArray $applyRun.json 'proposals')
            Register-OwnedProposals -Set $txOwnedProposals -ProposalPaths $appliedProps
            [void]$researchResults.Add([pscustomobject]@{
                model_id = $candId
                mode = $mode
                status = $(if ([bool](Get-OrchestraProperty $applyRun.json 'rejected' $false)) { 'rejected' } else { 'applied' })
                proposals = $appliedProps
            })
        }
    }

    # Step 4: Manual-only Probe Branch (ONLY when -RunProbe is explicitly set!)
    $probeResults = New-Object 'System.Collections.Generic.List[object]'
    if ($RunProbe -and -not $DryRun) {
        $probeTargets = New-Object 'System.Collections.Generic.List[string]'
        foreach ($pm in @($ProbeModels)) {
            foreach ($piece in ($pm -split ',')) {
                $trimmed = $piece.Trim()
                if (-not [string]::IsNullOrWhiteSpace($trimmed) -and -not $probeTargets.Contains($trimmed)) {
                    [void]$probeTargets.Add($trimmed)
                }
            }
        }
        if ($probeTargets.Count -eq 0 -and $null -ne $detectSummary) {
            foreach ($nid in @(Get-OrchestraArray $detectSummary 'new')) {
                if (-not [string]::IsNullOrWhiteSpace([string]$nid)) { [void]$probeTargets.Add([string]$nid) }
            }
        }
        foreach ($targetPm in $probeTargets.ToArray()) {
            $prRun = Invoke-ChildJsonScript -ScriptPath (Join-Path $PSScriptRoot 'probe-model.ps1') -Arguments @(
                '-ModelId', $targetPm, '-Grade', '-EmitProposals',
                '-RegistryPath', $paths.Registry, '-StateDir', $paths.StateDir
            ) -WorkDir $paths.Root -TimeoutSec 3600
            $probeProps = @(Get-OrchestraArray $prRun.json 'proposals')
            Register-OwnedProposals -Set $txOwnedProposals -ProposalPaths $probeProps
            [void]$probeResults.Add([pscustomobject]@{
                model_id = $targetPm
                exit = $prRun.exit_code
                proposals = $probeProps
            })
        }
    }

    # Step 5: calibrate-telemetry.ps1
    $calScript = Join-Path $PSScriptRoot 'calibrate-telemetry.ps1'
    $telemetrySummary = $null
    if ([IO.File]::Exists($calScript)) {
        $calArgs = @('-RegistryPath', $paths.Registry, '-StateDir', $paths.StateDir)
        if ($DryRun) { $calArgs += '-DryRun' }
        $calRun = Invoke-ChildJsonScript -ScriptPath $calScript -Arguments $calArgs -WorkDir $paths.Root -TimeoutSec 120
        $telemetrySummary = $calRun.json
        if ($null -ne $telemetrySummary) {
            Register-OwnedProposals -Set $txOwnedProposals -ProposalPaths @(Get-OrchestraArray $telemetrySummary 'proposals_created')
        }
    }

    # Step 6: sync-docs.ps1
    $syncSummary = $null
    $skillMdInRepo = Join-Path $repoRoot 'SKILL.md'
    if ([IO.File]::Exists($skillMdInRepo)) {
        $syncArgs = @('-RegistryPath', $paths.Registry, '-Root', $repoRoot)
        if ($DryRun) { $syncArgs += '-Check' }
        $syncRun = Invoke-ChildJsonScript -ScriptPath (Join-Path $PSScriptRoot 'sync-docs.ps1') -Arguments $syncArgs -WorkDir $paths.Root -TimeoutSec 60
        $syncSummary = $syncRun.json
    }

    # Step 7: selftest gate & atomic rollback on failure
    $managedChanged = $false
    $selftestPassed = $true
    if (-not $DryRun -and $null -ne $snapshot) {
        $managedChanged = Test-MaintainChanged -Snapshot $snapshot -Paths $paths
        if ($managedChanged) {
            $selftestOverride = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_SELFTEST_SCRIPT')
            $selftestScript = if (-not [string]::IsNullOrWhiteSpace($selftestOverride)) {
                [IO.Path]::GetFullPath($selftestOverride)
            }
            else {
                Join-Path $PSScriptRoot 'selftest.ps1'
            }
            $stRun = Invoke-ChildJsonScript -ScriptPath $selftestScript -Arguments @(
                '-RegistryPath', $paths.Registry, '-StateDir', $paths.StateDir
            ) -WorkDir $paths.Root -TimeoutSec 600
            if ($stRun.exit_code -ne 0 -or $stRun.timeout) {
                $selftestPassed = $false
                Restore-MaintainSnapshot -Snapshot $snapshot -Paths $paths -OwnedProposals $txOwnedProposals
                Write-OrchestraResult -Object ([ordered]@{
                    dry_run = $false
                    managed_changed = $true
                    selftest_passed = $false
                    rolled_back = $true
                    error = 'ORCHESTRA_EXTERNAL: selftest gate failed; restored pre-run snapshot.'
                    selftest_exit = $stRun.exit_code
                    exit = 3
                })
                exit 3
            }
        }
    }

    # Step 8: Post-gate usage ledger compaction & registry history GC
    $compactionSummary = $null
    $historyGcSummary = $null
    if (-not $DryRun) {
        $finalReg = Read-Registry -Paths $paths
        $pol = Get-OrchestraProperty $finalReg 'policy'
        $maxBytes = [long](Get-OrchestraProperty $pol 'usage_compact_bytes' 2097152)
        $retainDays = [int](Get-OrchestraProperty $pol 'usage_retain_days' 90)
        $keepCount = [int](Get-OrchestraProperty $pol 'history_keep_count' 30)
        $compactionSummary = Compact-UsageLedger -Paths $paths -MaxBytes $maxBytes -RetainDays $retainDays -Force:$CompactUsage
        $historyGcSummary = Remove-OldRegistryHistory -Paths $paths -KeepCount $keepCount
    }

    # Step 9: Isolated Git commit (and opt-in -Push)
    $gitCommitSha = $null
    $gitPushed = $false
    $finalRegistry = Read-Registry -Paths $paths
    $finalRev = [long](Get-OrchestraProperty $finalRegistry 'registry_rev' 0)

    $effectiveManagedRels = @(
        foreach ($rel in $managedRelCandidates) {
            $abs = Join-Path $repoRoot ($rel -replace '/', '\')
            if (Test-Path -LiteralPath $abs) { $rel }
        }
    )
    $historyRemovedAny = ($null -ne $historyGcSummary -and [int]$historyGcSummary.removed_count -gt 0)

    if (($managedChanged -or $historyRemovedAny) -and -not $DryRun -and $hasGit) {
        if ($gitCommitAllowed -and $effectiveManagedRels.Count -gt 0) {
            $headCheck = Invoke-GitCommand -GitExe $gitExe -RepoRoot $repoRoot -Arguments @('rev-parse', '--verify', 'HEAD')
            # Revalidate caller's real index on managed paths before committing so post-commit reset cannot clobber intervening staged edits
            $callerStagedDuringRun = $false
            if ($headCheck.exit_code -eq 0) {
                $callerIdxCheck = Invoke-GitCommand -GitExe $gitExe -RepoRoot $repoRoot -Arguments (@('diff', '--cached', '--quiet', 'HEAD', '--') + $effectiveManagedRels)
                if ($callerIdxCheck.exit_code -ne 0) { $callerStagedDuringRun = $true }
            }
            else {
                $callerIdxCheck = Invoke-GitCommand -GitExe $gitExe -RepoRoot $repoRoot -Arguments (@('ls-files', '--stage', '--') + $effectiveManagedRels)
                $stagedLines = @($callerIdxCheck.stdout | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
                if ($stagedLines.Count -gt 0) { $callerStagedDuringRun = $true }
            }

            if ($callerStagedDuringRun) {
                $gitCommitAllowed = $false
                $gitSkipReason = 'intervening_staged_changes'
            }
            else {
                $tempIndex = Join-Path $txDir 'maintain.git.index'
                if ($headCheck.exit_code -eq 0) {
                    $rt = Invoke-GitCommand -GitExe $gitExe -RepoRoot $repoRoot -IndexFile $tempIndex -Arguments @('read-tree', 'HEAD')
                    if ($rt.exit_code -ne 0) {
                        throw 'ORCHESTRA_EXTERNAL: git read-tree HEAD failed.'
                    }
                }
                $addRun = Invoke-GitCommand -GitExe $gitExe -RepoRoot $repoRoot -IndexFile $tempIndex -Arguments (@('add', '-A', '--') + $effectiveManagedRels)
                if ($addRun.exit_code -ne 0) {
                    throw 'ORCHESTRA_EXTERNAL: git add on isolated index failed.'
                }
                $diffArgs = if ($headCheck.exit_code -eq 0) { @('diff', '--cached', '--quiet', 'HEAD') } else { @('status', '--porcelain') }
                $diffRun = Invoke-GitCommand -GitExe $gitExe -RepoRoot $repoRoot -IndexFile $tempIndex -Arguments $diffArgs
                $hasStagedChanges = if ($headCheck.exit_code -eq 0) { ($diffRun.exit_code -eq 1) } else { (@($diffRun.stdout | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) }
                if ($hasStagedChanges) {
                    $commitMsg = "chore(maintain): sync registry rev $finalRev and managed docs"
                    $commitRun = Invoke-GitCommand -GitExe $gitExe -RepoRoot $repoRoot -IndexFile $tempIndex -Arguments @('commit', '-m', $commitMsg)
                    if ($commitRun.exit_code -ne 0) {
                        throw ('ORCHESTRA_EXTERNAL: git commit failed: ' + (($commitRun.stderr + $commitRun.stdout) -join ' '))
                    }
                    $gitCommitted = $true
                    $resetRun = Invoke-GitCommand -GitExe $gitExe -RepoRoot $repoRoot -Arguments (@('reset', '-q', 'HEAD', '--') + $effectiveManagedRels)
                    if ($resetRun.exit_code -ne 0) {
                        throw ('ORCHESTRA_EXTERNAL: post-commit git reset failed: ' + (($resetRun.stderr + $resetRun.stdout) -join ' '))
                    }
                    $revRun = Invoke-GitCommand -GitExe $gitExe -RepoRoot $repoRoot -Arguments @('rev-parse', '--short', 'HEAD')
                    if ($revRun.exit_code -eq 0 -and @($revRun.stdout).Count -gt 0) {
                        $gitCommitSha = ([string]$revRun.stdout[0]).Trim()
                    }
                }
                else {
                    $gitSkipReason = 'nothing_to_commit'
                }
            }
        }
    }
    elseif (-not $DryRun -and $hasGit -and [string]::IsNullOrWhiteSpace($gitSkipReason)) {
        $gitSkipReason = 'no_managed_changes'
    }

    if ($Push -and -not $DryRun) {
        if (-not $hasGit) {
            throw 'ORCHESTRA_EXTERNAL: -Push requested, but no Git repository was found.'
        }
        if ($gitSkipReason -in @('dirty_managed_paths', 'intervening_staged_changes')) {
            throw "ORCHESTRA_EXTERNAL: Refusing -Push because managed paths had uncommitted/staged manual changes ($gitSkipReason)."
        }
        $pushRun = Invoke-GitCommand -GitExe $gitExe -RepoRoot $repoRoot -WithSystemProxy -Arguments @('push', 'origin', 'HEAD')
        if ($pushRun.exit_code -ne 0) {
            throw ('ORCHESTRA_EXTERNAL: git push failed: ' + (($pushRun.stderr + $pushRun.stdout) -join ' '))
        }
        $gitPushed = $true
    }

    Write-OrchestraResult -Object ([ordered]@{
        dry_run = [bool]$DryRun
        registry_rev = $finalRev
        managed_changed = [bool]$managedChanged
        selftest_passed = [bool]$selftestPassed
        rolled_back = $false
        doctor = $doctorSummary
        detect = $detectSummary
        research_results = $researchResults.ToArray()
        probe_results = $probeResults.ToArray()
        telemetry = $telemetrySummary
        docs_sync = $syncSummary
        compaction = $compactionSummary
        history_gc = $historyGcSummary
        git_committed = [bool]$gitCommitted
        git_commit = $gitCommitSha
        git_pushed = [bool]$gitPushed
        git_skip_reason = $gitSkipReason
    })
    exit 0
}
catch {
    $message = $_.Exception.Message
    $code = Get-OrchestraExitCode -Message $message
    $rolledBackOnCatch = $false
    if (-not $DryRun -and $null -ne $snapshot -and -not $gitCommitted -and $null -ne $paths) {
        try {
            Restore-MaintainSnapshot -Snapshot $snapshot -Paths $paths -OwnedProposals $txOwnedProposals
            $rolledBackOnCatch = $true
        }
        catch {
            $script:keepTxBackup = $true
        }
    }
    [Console]::Error.WriteLine($message)
    $errPayload = [ordered]@{
        error = $message
        rolled_back = [bool]$rolledBackOnCatch
        exit = $code
    }
    if ($script:keepTxBackup) {
        $errPayload['recovery_backup_dir'] = $txDir
    }
    Write-OrchestraResult -Object $errPayload
    exit $code
}
finally {
    if (-not $script:keepTxBackup -and [IO.Directory]::Exists($txDir)) {
        try {
            $fullTx = [IO.Path]::GetFullPath($txDir)
            if ([IO.Path]::GetFileName($fullTx) -match '^cowork-maintain-tx-[a-f0-9]{32}$') {
                Remove-Item -LiteralPath $fullTx -Recurse -Force
            }
        }
        catch {}
    }
}
