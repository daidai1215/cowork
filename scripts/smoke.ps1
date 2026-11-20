<#
.SYNOPSIS
Fast (<5s) offline smoke check for Cowork Lite: AST syntax, models.json, subagent_tiers, preferences, presets, line slicing, read-only guard, and batch <=3 cap.
#>
[CmdletBinding()]
param([string]$RegistryPath = '')

. (Join-Path $PSScriptRoot 'lib\common.ps1')

$watch = [Diagnostics.Stopwatch]::StartNew()
$passed = 0
$failed = 0
$failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-Smoke {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { $script:passed++ }
    else {
        $script:failed++
        $msg = if ([string]::IsNullOrWhiteSpace($Detail)) { $Name } else { "$Name ($Detail)" }
        [void]$script:failures.Add($msg)
        [Console]::Error.WriteLine("FAIL: $msg")
    }
}

try {
    $root = Resolve-Root
    $scriptsDir = Join-Path $root 'scripts'
    $psFiles = @(Get-ChildItem -LiteralPath $scriptsDir -Filter '*.ps1' -Recurse -File | Sort-Object FullName)
    Assert-Smoke 'scripts exist' ($psFiles.Count -ge 4) "count=$($psFiles.Count)"

    foreach ($file in $psFiles) {
        $tokens = $null; $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        $errCount = if ($null -eq $errors) { 0 } else { $errors.Count }
        $detail = if ($errCount -gt 0) { ($errors | ForEach-Object { $_.Message }) -join '; ' } else { '' }
        Assert-Smoke ("AST parse: " + $file.Name) ($errCount -eq 0) $detail
    }

    $regPath = Get-RegistryPath -RegistryPath $RegistryPath
    $reg = Read-JsonFile -Path $regPath
    Assert-Smoke 'models.json parses' ($null -ne $reg) $regPath

    $subTiers = Get-OrchestraProperty $reg 'subagent_tiers' $null
    $tiersObj = Get-OrchestraProperty $subTiers 'tiers' $null
    $recResearch = [string](Get-OrchestraProperty $subTiers 'recommended_research_tier' '')
    Assert-Smoke 'subagent_tiers calibrated' (
        $null -ne $subTiers -and $null -ne $tiersObj -and
        $recResearch -in @('flash', 'inherit', 'pro') -and
        -not [string]::IsNullOrWhiteSpace([string](Get-OrchestraProperty (Get-OrchestraProperty $tiersObj 'flash') 'resolved_model' ''))
    )
    Assert-Smoke 'preferences.md exists' ([IO.File]::Exists((Join-Path $root 'registry\preferences.md')))

    $models = @(Get-OrchestraArray $reg 'models')
    Assert-Smoke 'models non-empty' ($models.Count -gt 0)
    $ids = @{}
    foreach ($m in $models) {
        $id = [string](Get-OrchestraProperty $m 'id' '')
        $ch = [string](Get-OrchestraProperty $m 'channel' '')
        $inv = Get-OrchestraProperty $m 'invoke'
        $def = [string](Get-OrchestraProperty $inv 'default_effort' '')
        $effs = @(Get-OrchestraArray $inv 'efforts' | ForEach-Object { [string]$_ })
        $flag = [string](Get-OrchestraProperty $inv 'model_flag' '')
        Assert-Smoke "model valid: $id" (
            -not [string]::IsNullOrWhiteSpace($id) -and
            -not $ids.ContainsKey($id) -and
            $ch -in @('codex', 'agy') -and
            -not [string]::IsNullOrWhiteSpace($flag) -and
            $effs -contains $def
        )
        if (-not [string]::IsNullOrWhiteSpace($id)) { $ids[$id] = $true }
    }

    $astra = Resolve-ModelEntry -Registry $reg -Name 'gpt-6.2-astra'
    $opus = Resolve-ModelEntry -Registry $reg -Name 'claude-opus-5-5'
    Assert-Smoke 'astra fast service_tier & rotation' (
        [string](Get-OrchestraProperty (Get-OrchestraProperty $astra 'invoke') 'service_tier' '') -eq 'fast' -and
        [bool](Get-OrchestraProperty (Get-OrchestraProperty $astra 'invoke') 'account_rotation' $false)
    )
    Assert-Smoke 'opus read_only enforced in registry' ([bool](Get-OrchestraProperty $opus 'read_only' $false))

    $aliases = Get-OrchestraProperty $reg 'aliases'
    if ($null -ne $aliases) {
        foreach ($prop in $aliases.PSObject.Properties) {
            Assert-Smoke "alias resolves: $($prop.Name)->$($prop.Value)" ($ids.ContainsKey([string]$prop.Value))
        }
    }

    $invokeScript = Join-Path $scriptsDir 'invoke-model.ps1'
    $batchScript = Join-Path $scriptsDir 'invoke-batch.ps1'
    $psExe = Join-Path $PSHOME 'powershell.exe'
    if (-not [IO.File]::Exists($psExe)) { $psExe = 'powershell.exe' }

    # 1. Preset code -> Astra high + fast + ephemeral + no unstable warning flag
    $r1 = Invoke-OrchestraProcess -FilePath $psExe -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $invokeScript,
        '-Preset', 'code', '-Prompt', 'OK', '-ContextFiles', 'registry\models.json:1-5', '-DryRun', '-RegistryPath', $regPath
    ) -WorkDir $root -TimeoutSec 15 -CaptureStdout
    $j1 = if ($r1.stdout.Count -gt 0) { ($r1.stdout[-1] | ConvertFrom-Json) } else { $null }
    Assert-Smoke 'dry-run preset code + fast + slice' (
        $r1.exit_code -eq 0 -and $null -ne $j1 -and
        $j1.model -eq 'gpt-6.2-astra' -and $j1.effort -eq 'high' -and
        $j1.service_tier -eq 'fast' -and [bool]$j1.codex_ephemeral -and
        (@($j1.arguments) -contains 'service_tier="fast"') -and
        -not (@($j1.arguments) -contains 'suppress_unstable_features_warning=true') -and
        ([string]$j1.stdin -match 'models\.json:L1-L5')
    )

    # 2. Preset math + NoFast -> Astra xhigh + default service_tier
    $r2 = Invoke-OrchestraProcess -FilePath $psExe -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $invokeScript,
        '-Preset', 'math', '-NoFast', '-Prompt', 'OK', '-DryRun', '-RegistryPath', $regPath
    ) -WorkDir $root -TimeoutSec 15 -CaptureStdout
    $j2 = if ($r2.stdout.Count -gt 0) { ($r2.stdout[-1] | ConvertFrom-Json) } else { $null }
    Assert-Smoke 'dry-run preset math xhigh + NoFast' (
        $r2.exit_code -eq 0 -and $null -ne $j2 -and
        $j2.model -eq 'gpt-6.2-astra' -and $j2.effort -eq 'xhigh' -and $j2.service_tier -eq 'default'
    )

    # 3. Preset ui -> Opus high read-only; reject write access
    $r3 = Invoke-OrchestraProcess -FilePath $psExe -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $invokeScript,
        '-Preset', 'ui', '-Prompt', 'OK', '-DryRun', '-RegistryPath', $regPath
    ) -WorkDir $root -TimeoutSec 15 -CaptureStdout
    $j3 = if ($r3.stdout.Count -gt 0) { ($r3.stdout[-1] | ConvertFrom-Json) } else { $null }
    Assert-Smoke 'dry-run preset ui (opus read-only)' (
        $r3.exit_code -eq 0 -and $null -ne $j3 -and
        $j3.model -eq 'claude-opus-5-5' -and $j3.effort -eq 'high' -and $j3.access -eq 'read'
    )
    $r4 = Invoke-OrchestraProcess -FilePath $psExe -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $invokeScript,
        '-Model', 'claude-opus-5-5', '-Access', 'write', '-Prompt', 'OK', '-DryRun', '-RegistryPath', $regPath
    ) -WorkDir $root -TimeoutSec 15 -CaptureStdout
    Assert-Smoke 'reject opus write access' ($r4.exit_code -eq 2) "exit=$($r4.exit_code)"

    # 4. Reject invalid line range
    $r5 = Invoke-OrchestraProcess -FilePath $psExe -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $invokeScript,
        '-Model', 'gpt-6.2-astra', '-ContextFiles', 'registry\models.json:5-1', '-Prompt', 'OK', '-DryRun', '-RegistryPath', $regPath
    ) -WorkDir $root -TimeoutSec 15 -CaptureStdout
    Assert-Smoke 'reject reversed line range' ($r5.exit_code -eq 2) "exit=$($r5.exit_code)"

    # 5. Batch runner: 2 tasks pass dry-run, 4 tasks rejected (>3 hard cap)
    $batchOkJson = '[{"id":"a","preset":"code","prompt":"OK"},{"id":"b","preset":"ui","prompt":"OK"}]'
    $r6 = Invoke-OrchestraProcess -FilePath $psExe -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $batchScript,
        '-TasksJson', $batchOkJson, '-DryRun', '-RegistryPath', $regPath
    ) -WorkDir $root -TimeoutSec 15 -CaptureStdout
    $j6 = if ($r6.stdout.Count -gt 0) { ($r6.stdout[-1] | ConvertFrom-Json) } else { $null }
    Assert-Smoke 'batch dry-run 2 tasks' (
        $r6.exit_code -eq 0 -and $null -ne $j6 -and $j6.total -eq 2 -and $j6.succeeded -eq 2 -and $j6.failed -eq 0
    )

    $batchTooMany = '[{"preset":"code","prompt":"1"},{"preset":"code","prompt":"2"},{"preset":"code","prompt":"3"},{"preset":"code","prompt":"4"}]'
    $r7 = Invoke-OrchestraProcess -FilePath $psExe -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $batchScript,
        '-TasksJson', $batchTooMany, '-DryRun', '-RegistryPath', $regPath
    ) -WorkDir $root -TimeoutSec 15 -CaptureStdout
    Assert-Smoke 'batch hard-caps >3 tasks' ($r7.exit_code -eq 2) "exit=$($r7.exit_code)"
}
catch {
    $failed++
    [void]$failures.Add($_.Exception.Message)
    [Console]::Error.WriteLine('Smoke runner error: ' + $_.Exception.Message)
}

$watch.Stop()
$sec = [Math]::Round($watch.Elapsed.TotalSeconds, 2)
[Console]::Error.WriteLine("Smoke: $passed passed, $failed failed in ${sec}s.")
Write-OrchestraResult -Object ([ordered]@{
    passed = $passed
    failed = $failed
    duration_sec = $sec
    failures = $failures.ToArray()
})
if ($failed -gt 0) { exit 1 }
exit 0
