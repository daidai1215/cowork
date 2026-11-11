<#
.SYNOPSIS
Run isolated detector regression tests.
.DESCRIPTION
Builds source catalogs from every model in the copied registry.
Uses fixture files, an injected clock, and a local timeout wrapper.
Writes one suite JSON object and exits 1 on assertion failure.
#>
[CmdletBinding()]
param([string]$RegistryPath, [string]$StateDir)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $root 'scripts\lib\common.ps1')
$script:detectPassed = 0
$script:detectFailures = New-Object 'System.Collections.Generic.List[string]'
$engine = (Get-Process -Id $PID).Path
$oldNow = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_NOW')
$oldWrapper = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER')
$temp = $null
$utf8 = New-Object System.Text.UTF8Encoding $false

function Assert-DTest {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:detectPassed++ }
    else { [void]$script:detectFailures.Add($Name) }
}

function Write-DText {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Read-DTestState {
    Invoke-WithLock -Paths $script:detectPaths -Name state -ScriptBlock {
        Read-State -Paths $script:detectPaths
    }
}

function Read-DTestRegistry {
    Invoke-WithLock -Paths $script:detectPaths -Name registry -ScriptBlock {
        Read-Registry -Paths $script:detectPaths
    }
}

function Get-DTestModel {
    param([string]$Id)
    $registryCopy = Read-DTestRegistry
    $modelMatches = @(
        $registryCopy.models | Where-Object { $_.id -eq $Id }
    )
    if ($modelMatches.Count -ne 1) {
        throw "Expected exactly one fixture model: $Id"
    }
    return $modelMatches[0]
}

function Write-DAgyFixture {
    param([switch]$Fake, [switch]$WithoutOpus)
    $registryCopy = Read-DTestRegistry
    $lines = @(
        'Fetching available models...'
        foreach ($catalogModel in @($registryCopy.models)) {
            if ($catalogModel.channel -ne 'agy') { continue }
            if ($WithoutOpus -and $catalogModel.id -eq 'claude-opus-5-5') {
                continue
            }
            foreach ($effortName in @('low', 'medium', 'high')) {
                '{0}-{1}{2}{0} ({1})' -f (
                    [string]$catalogModel.id
                ), $effortName, "`t"
            }
        }
        "baseline-agy-model-high`tBaseline Agy Model (High)"
        "baseline-agy-model-medium`tBaseline Agy Model (Medium)"
        "baseline-agy-secondary-high`tBaseline Agy Secondary (High)"
        if ($Fake) {
            "fake-model-9-high`tFake Model 9 (High)"
            "fake-model-9-medium`tFake Model 9 (Medium)"
        }
    )
    Write-DText $script:agyFixture ($lines -join "`r`n")
}

function Get-DCodexFixtureText {
    $registryCopy = Read-DTestRegistry
    $slugLines = @(
        foreach ($catalogModel in @($registryCopy.models)) {
            if ($catalogModel.channel -eq 'codex') {
                '"slug": "' + [string]$catalogModel.id + '",'
            }
        }
        '"slug": "baseline-codex-model" trailing text'
    )
    return (
        'not valid JSON; ' + ('x' * 620000) + "`n" +
        ($slugLines -join "`n")
    )
}

function Invoke-DTest {
    param(
        [switch]$Forced, [switch]$OfflineOnly,
        [switch]$LiveAgy, [int]$AgyTimeoutSec = 60
    )
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $root 'scripts\detect-models.ps1'),
        '-RegistryPath', $script:detectPaths.Registry,
        '-StateDir', $script:detectPaths.StateDir,
        '-CodexCatalogFile', $script:codexFixture,
        '-AgyTimeoutSec', ([string]$AgyTimeoutSec)
    )
    if (-not $LiveAgy) { $arguments += '-NoNetwork' }
    if (-not $OfflineOnly -and -not $LiveAgy) {
        $arguments += @('-AgyListFile', $script:agyFixture)
    }
    if ($Forced) { $arguments += '-Force' }
    $stderrFile = Join-Path $temp ('stderr-' + [guid]::NewGuid() + '.txt')
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $engine @arguments 2> $stderrFile)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    $lines = @($output | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    if ($lines.Count -ne 1) {
        throw "detect emitted $($lines.Count) nonempty stdout lines."
    }
    [pscustomobject]@{
        Exit = $code
        Result = ([string]$lines[0] | ConvertFrom-Json)
    }
}

try {
    $env:MODEL_ORCHESTRA_NOW = '2026-11-10T12:00:00Z'
    $sourcePaths = Get-OrchestraPaths -RegistryPath $RegistryPath -StateDir $null
    $parent = $StateDir
    if ([string]::IsNullOrWhiteSpace($parent)) {
        $parent = [IO.Path]::GetTempPath()
    }
    $temp = Join-Path $parent (
        'model-orchestra-detect-' + [guid]::NewGuid().ToString('N')
    )
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $localRegistry = Join-Path $temp 'registry\models.json'
    $script:detectPaths = Get-OrchestraPaths `
        -RegistryPath $localRegistry -StateDir (Join-Path $temp 'state')
    New-Item -ItemType Directory `
        -Path $script:detectPaths.RegistryDir -Force | Out-Null
    $script:agyFixture = Join-Path $temp 'agy-models.txt'
    $script:codexFixture = Join-Path $temp 'codex-catalog.txt'

    $fixture = Read-JsonFile -Path $sourcePaths.Registry
    foreach ($fixtureModel in @($fixture.models)) {
        if ($fixtureModel.id -eq 'gpt-6-astra') {
            $fixtureModel.last_researched = $null
        }
        elseif ($fixtureModel.id -eq 'gemini-4-carbon') {
            $fixtureModel.last_researched = '2026-09-01'
        }
    }
    Invoke-WithLock -Paths $script:detectPaths -Name registry -ScriptBlock {
        Write-JsonAtomic -Path $localRegistry -Object $fixture
    } | Out-Null

    Write-DAgyFixture
    $codexText = Get-DCodexFixtureText
    Write-DText $script:codexFixture $codexText

    $run = Invoke-DTest -Forced
    $r = $run.Result
    Assert-DTest ($run.Exit -eq 0) 'initial scan exits 0'
    Assert-DTest ($r.baseline_initialized -eq $true) 'initial source baselines'
    Assert-DTest (@($r.new).Count -eq 0) 'baseline models are not new'
    Assert-DTest (
        @($r.source_errors).Count -eq 0
    ) 'large non-JSON catalog is supported'
    Assert-DTest (
        @($r.stale) -contains 'gpt-6-astra' -and
        @($r.stale) -contains 'gemini-4-carbon' -and
        @($r.stale) -notcontains 'claude-opus-5-5'
    ) 'missing and old research dates are stale'

    $state = Read-DTestState
    Assert-DTest (
        @($state.sources.agy.baseline_slugs) -contains 'baseline-agy-model' -and
        @($state.sources.agy.baseline_slugs) -contains 'baseline-agy-secondary' -and
        @($state.sources.codex.baseline_slugs) -contains 'baseline-codex-model'
    ) 'baselines are independent and normalize agy efforts'

    $registeredExcluded = $true
    $rawComplete = $true
    foreach ($fixtureModel in @($fixture.models)) {
        $modelId = [string]$fixtureModel.id
        if ($fixtureModel.channel -eq 'agy') {
            if (@($state.sources.agy.baseline_slugs) -contains $modelId) {
                $registeredExcluded = $false
            }
            foreach ($effortName in @('low', 'medium', 'high')) {
                if (
                    @($state.sources.agy.raw_slugs) -notcontains
                    ($modelId + '-' + $effortName)
                ) {
                    $rawComplete = $false
                }
            }
        }
        elseif ($fixtureModel.channel -eq 'codex') {
            if (@($state.sources.codex.baseline_slugs) -contains $modelId) {
                $registeredExcluded = $false
            }
            if (@($state.sources.codex.raw_slugs) -notcontains $modelId) {
                $rawComplete = $false
            }
        }
    }
    Assert-DTest $registeredExcluded 'Registered IDs are excluded from initial baselines'
    Assert-DTest (
        @($r.baseline_added.agy).Count -eq
            @($state.sources.agy.baseline_slugs).Count -and
        @($r.baseline_added.codex).Count -eq 1 -and
        $r.baseline_added.codex[0] -eq 'baseline-codex-model'
    ) 'baseline_added reports independently initialized source baselines'
    Assert-DTest $rawComplete 'Successful scans preserve every registered raw slug'
    Assert-DTest ($null -eq $state.scan_lease) 'scan lease is released'

    $env:MODEL_ORCHESTRA_NOW = '2026-11-10T13:00:00Z'
    Write-DAgyFixture -Fake
    $run = Invoke-DTest
    Assert-DTest (
        $run.Exit -eq 0 -and $run.Result.skipped -eq $true
    ) 'successful sources skip within 24 hours'

    $run = Invoke-DTest -Forced
    Assert-DTest (
        $run.Exit -eq 0 -and @($run.Result.new).Count -eq 1 -and
        $run.Result.new[0] -eq 'fake-model-9'
    ) 'Force bypasses interval and deduplicates effort variants'
    $state = Read-DTestState
    Assert-DTest (
        @($state.sources.agy.baseline_slugs) -notcontains 'fake-model-9'
    ) 'later discovery does not overwrite the original baseline'

    Write-DAgyFixture -Fake -WithoutOpus
    $run = Invoke-DTest -Forced
    Assert-DTest (
        @($run.Result.removed).Count -eq 0 -and
        (Get-DTestModel 'claude-opus-5-5').status -eq 'active'
    ) 'first successful missing scan does not remove a model'
    $state = Read-DTestState
    Assert-DTest (
        $state.sources.agy.missing_counts.'claude-opus-5-5' -eq 1
    ) 'first successful miss is counted'

    Write-DText $script:agyFixture (
        'Fetching available models...' + "`n" +
        'ERROR: not logged into Antigravity'
    )
    $run = Invoke-DTest -Forced
    Assert-DTest (
        $run.Exit -eq 3 -and @($run.Result.source_errors).Count -eq 1 -and
        $run.Result.source_errors[0].source -eq 'agy'
    ) 'invalid agy output is a source failure'
    Assert-DTest (
        @($run.Result.removed).Count -eq 0 -and
        (Get-DTestModel 'claude-opus-5-5').status -eq 'active'
    ) 'failed agy source cannot remove models'
    $state = Read-DTestState
    Assert-DTest (
        $state.sources.agy.missing_counts.'claude-opus-5-5' -eq 1 -and
        $state.sources.agy.consecutive_failures -eq 1
    ) 'failure preserves missing count and increments failure count'
    $lastAttempt = $state.sources.agy.last_attempt

    $env:MODEL_ORCHESTRA_NOW = '2026-11-10T13:30:00Z'
    Write-DAgyFixture -Fake -WithoutOpus
    $run = Invoke-DTest
    $state = Read-DTestState
    Assert-DTest (
        $run.Exit -eq 0 -and $run.Result.skipped -eq $true -and
        $state.sources.agy.last_attempt -eq $lastAttempt
    ) 'failed source backs off for one hour'

    $env:MODEL_ORCHESTRA_NOW = '2026-11-10T14:01:00Z'
    $run = Invoke-DTest
    Assert-DTest (
        $run.Exit -eq 0 -and
        @($run.Result.removed).Count -eq 1 -and
        @($run.Result.removed) -contains 'claude-opus-5-5' -and
        (Get-DTestModel 'claude-opus-5-5').status -eq 'unavailable'
    ) 'retry after one hour removes only the deliberately missing model'

    $opus = Get-DTestModel 'claude-opus-5-5'
    Assert-DTest ($opus.previous_status -eq 'active') 'removal preserves previous status'
    $registryCopy = Read-DTestRegistry
    Assert-DTest (
        [int]$registryCopy.registry_rev -eq ([int]$fixture.registry_rev + 1)
    ) 'removal increments registry revision once'
    $history = @(
        Get-ChildItem -LiteralPath $script:detectPaths.History `
            -Filter 'models-*.json' -File
    )
    Assert-DTest ($history.Count -ge 1) 'removal creates a history backup'
    Assert-DTest (
        Test-Path -LiteralPath $script:detectPaths.Changelog -PathType Leaf
    ) 'removal writes changelog'

    Write-DAgyFixture -Fake
    $run = Invoke-DTest -Forced
    Assert-DTest (
        $run.Exit -eq 0 -and
        @($run.Result.restored).Count -eq 1 -and
        @($run.Result.restored) -contains 'claude-opus-5-5' -and
        (Get-DTestModel 'claude-opus-5-5').status -eq 'active'
    ) 'returning model restores previous status'
    $state = Read-DTestState
    Assert-DTest (
        $state.sources.agy.missing_counts.'claude-opus-5-5' -eq 0 -and
        $state.sources.agy.consecutive_failures -eq 0
    ) 'successful presence resets missing and failure counters'
    $registryCopy = Read-DTestRegistry
    Assert-DTest (
        [int]$registryCopy.registry_rev -eq ([int]$fixture.registry_rev + 2)
    ) 'restoration increments registry revision once'

    $unaffectedModelsPreserved = $true
    foreach ($originalModel in @($fixture.models)) {
        if ($originalModel.id -eq 'claude-opus-5-5') { continue }
        $currentModel = Get-DTestModel ([string]$originalModel.id)
        if ($currentModel.status -ne $originalModel.status) {
            $unaffectedModelsPreserved = $false
        }
    }
    Assert-DTest $unaffectedModelsPreserved 'other registered models retain their status'

    Invoke-WithLock -Paths $script:detectPaths -Name state -ScriptBlock {
        $state = Read-State -Paths $script:detectPaths
        $state.rejected_slugs = @('rejected-test-model')
        Save-State -Paths $script:detectPaths -State $state | Out-Null
    } | Out-Null
    $agyText = Get-Content -LiteralPath $script:agyFixture -Raw -Encoding UTF8
    Write-DText $script:agyFixture (
        $agyText + "`nrejected-test-model-high`tRejected Test Model"
    )
    $run = Invoke-DTest -Forced
    Assert-DTest (
        @($run.Result.new) -notcontains 'rejected-test-model'
    ) 'rejected slugs are excluded from discoveries'

    $codexWithNew = $codexText + "`n" + '"slug": "new-codex-model"'
    Write-DText $script:codexFixture $codexWithNew
    $run = Invoke-DTest -Forced
    Assert-DTest (
        $run.Exit -eq 0 -and @($run.Result.new) -contains 'new-codex-model'
    ) 'Codex source detects later slugs independently'

    Write-DText $script:codexFixture 'catalog unavailable'
    $run = Invoke-DTest -Forced
    Assert-DTest (
        $run.Exit -eq 3 -and @($run.Result.source_errors).Count -eq 1 -and
        $run.Result.source_errors[0].source -eq 'codex' -and
        @($run.Result.removed) -notcontains 'gpt-6-astra' -and
        (Get-DTestModel 'gpt-6-astra').status -eq 'active'
    ) 'invalid Codex source cannot remove Codex models'

    Write-DText $script:codexFixture $codexText
    $beforeOffline = Read-DTestState
    $agyAttemptBefore = $beforeOffline.sources.agy.last_attempt
    $env:MODEL_ORCHESTRA_NOW = '2026-11-10T15:00:00Z'
    $run = Invoke-DTest -Forced -OfflineOnly
    $afterOffline = Read-DTestState
    Assert-DTest (
        $run.Exit -eq 0 -and @($run.Result.source_errors).Count -eq 0 -and
        $afterOffline.sources.agy.last_attempt -eq $agyAttemptBefore
    ) 'NoNetwork without an agy fixture leaves the agy source untouched'

    $env:MODEL_ORCHESTRA_NOW = '2026-11-11T15:01:00Z'
    $run = Invoke-DTest
    Assert-DTest (
        $run.Exit -eq 0 -and $run.Result.skipped -eq $false
    ) 'successful sources scan again after 24 hours'
    $state = Read-DTestState
    Assert-DTest ($null -eq $state.scan_lease) 'final scan lease is released'

    $slowWrapper = Join-Path $temp 'slow-wrapper.ps1'
    Write-DText $slowWrapper "Start-Sleep -Seconds 120`r`nexit 0"
    [Environment]::SetEnvironmentVariable(
        'MODEL_ORCHESTRA_AGY_WRAPPER', $slowWrapper
    )
    $stateBeforeTimeout = Read-DTestState
    $rawBeforeTimeout = @($stateBeforeTimeout.sources.agy.raw_slugs) -join '|'
    $env:MODEL_ORCHESTRA_NOW = '2026-11-11T15:02:00Z'
    Write-DText $script:codexFixture (
        $codexText + "`n" + '"slug": "after-timeout-codex"'
    )
    $timeoutWatch = [Diagnostics.Stopwatch]::StartNew()
    $run = Invoke-DTest -Forced -LiveAgy -AgyTimeoutSec 3
    $timeoutWatch.Stop()
    Assert-DTest (
        $run.Exit -eq 3 -and @($run.Result.source_errors).Count -eq 1 -and
        $run.Result.source_errors[0].source -eq 'agy' -and
        $run.Result.source_errors[0].error -match 'timed out' -and
        $timeoutWatch.Elapsed.TotalSeconds -lt 30
    ) 'Agy timeout is a bounded source failure'
    $stateAfterTimeout = Read-DTestState
    Assert-DTest (
        @($run.Result.new) -contains 'after-timeout-codex' -and
        $stateAfterTimeout.sources.codex.consecutive_failures -eq 0 -and
        $stateAfterTimeout.sources.agy.consecutive_failures -eq 1 -and
        (@($stateAfterTimeout.sources.agy.raw_slugs) -join '|') -ceq
            $rawBeforeTimeout -and
        (Get-DTestModel 'claude-opus-5-5').status -eq 'active'
    ) 'Timeout preserves agy raw slugs and availability while Codex succeeds'

    $env:MODEL_ORCHESTRA_NOW = '2026-11-11T15:03:00Z'
    $run = Invoke-DTest
    Assert-DTest (
        $run.Exit -eq 0 -and $run.Result.skipped -eq $true
    ) 'Agy timeout enters failure backoff'
    [Environment]::SetEnvironmentVariable(
        'MODEL_ORCHESTRA_AGY_WRAPPER', $oldWrapper
    )

    $revisionBeforeLeaseTest = (Read-DTestRegistry).registry_rev
    Invoke-WithLock -Paths $script:detectPaths -Name state -ScriptBlock {
        $state = Read-State -Paths $script:detectPaths
        $state.scan_lease = [pscustomobject]@{
            owner = 'other-host-99999'
            until = '2026-11-11T15:10:00Z'
        }
        Save-State -Paths $script:detectPaths -State $state | Out-Null
    } | Out-Null
    $run = Invoke-DTest -Forced
    Assert-DTest (
        $run.Exit -eq 0 -and $run.Result.skipped -eq $true -and
        (Read-DTestRegistry).registry_rev -eq $revisionBeforeLeaseTest
    ) 'Force does not steal an active scan lease'
}
catch {
    [void]$script:detectFailures.Add('Harness: ' + $_.Exception.Message)
}
finally {
    [Environment]::SetEnvironmentVariable(
        'MODEL_ORCHESTRA_AGY_WRAPPER', $oldWrapper
    )
    [Environment]::SetEnvironmentVariable(
        'MODEL_ORCHESTRA_NOW', $oldNow, 'Process'
    )
    if ($null -ne $temp -and (Test-Path -LiteralPath $temp)) {
        try {
            $resolvedTemp = [IO.Path]::GetFullPath($temp)
            $leaf = Split-Path -Leaf $resolvedTemp
            if ($leaf -notmatch '^model-orchestra-detect-[a-f0-9]{32}$') {
                throw 'Refusing cleanup of an unexpected test directory.'
            }
            Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
        }
        catch {
            [void]$script:detectFailures.Add('Cleanup: ' + $_.Exception.Message)
        }
    }
}

Write-OrchestraResult -Object @{
    suite = 'detect'
    passed = $script:detectPassed
    failed = $script:detectFailures.Count
    failures = @($script:detectFailures.ToArray())
}
if ($script:detectFailures.Count -gt 0) { exit 1 }
exit 0
