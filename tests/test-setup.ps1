<#
.SYNOPSIS
Offline regression tests for setup.ps1: discovery, shorthand selection, custom model bootstrap, post-selection evaluation (research + probe), alias rebinding, baseline sync, and doc sync.
#>
[CmdletBinding()]
param([string]$RegistryPath, [string]$StateDir)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $root 'scripts\lib\common.ps1')

$script:setupPassed = 0
$script:setupFailures = New-Object 'System.Collections.Generic.List[string]'
$tempRoot = $null
$tempParent = $null
$envNames = @(
    'MODEL_ORCHESTRA_AGY_WRAPPER', 'MODEL_ORCHESTRA_CODEX',
    'MODEL_ORCHESTRA_CODEX_HOME', 'MODEL_ORCHESTRA_NOW',
    'MODEL_ORCHESTRA_PROXY', 'COWORK_SKIP_GLOBAL_PLUGIN'
)
$savedEnv = @{}
foreach ($n in $envNames) {
    $savedEnv[$n] = [Environment]::GetEnvironmentVariable($n)
}

function Assert-STest {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:setupPassed++ }
    else { [void]$script:setupFailures.Add($Name) }
}

function Invoke-SScript {
    param([string]$RelScript, [string[]]$ScriptArgs = @(), [int]$TimeoutSec = 120)
    $full = Join-Path $root $RelScript
    $proc = Invoke-OrchestraProcess -FilePath 'powershell.exe' -Arguments (
        @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $full) + $ScriptArgs
    ) -WorkDir $root -TimeoutSec $TimeoutSec -CaptureStdout
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

try {
    $env:MODEL_ORCHESTRA_NOW = '2026-11-16T00:00:00Z'
    $env:MODEL_ORCHESTRA_PROXY = 'NONE'
    $sourcePaths = Get-OrchestraPaths -RegistryPath $RegistryPath -StateDir $null
    $tempParent = if ([string]::IsNullOrWhiteSpace($StateDir)) { [IO.Path]::GetTempPath() } else { $StateDir }
    $tempParent = [IO.Path]::GetFullPath($tempParent)
    $tempRoot = Join-Path $tempParent ('model-orchestra-setup-test-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($tempRoot)

    $caseRepo = Join-Path $tempRoot 'repo'
    [void][IO.Directory]::CreateDirectory((Join-Path $caseRepo 'registry'))
    [void][IO.Directory]::CreateDirectory((Join-Path $caseRepo 'references'))
    $caseReg = Join-Path $caseRepo 'registry\models.json'
    $caseState = Join-Path $tempRoot 'state'
    [IO.File]::Copy($sourcePaths.Registry, $caseReg, $true)
    [IO.File]::Copy($sourcePaths.Changelog, (Join-Path $caseRepo 'registry\CHANGELOG.md'), $true)
    foreach ($relDoc in @('SKILL.md', 'references\model-profiles.md', 'README.md')) {
        [IO.File]::Copy((Join-Path $root $relDoc), (Join-Path $caseRepo $relDoc), $true)
    }

    $initialCaseRegObj = Read-JsonFile -Path $caseReg
    $initialActiveCount = @($initialCaseRegObj.models | Where-Object { [string]$_.status -eq 'active' }).Count

    $agyFixture = Join-Path $tempRoot 'agy-models.txt'
    $agyLines = @(
        "gemini-4-carbon-low`tGemini 4 Carbon Low"
        "gemini-4-carbon-medium`tGemini 4 Carbon Medium"
        "gemini-4-carbon-high`tGemini 4 Carbon High"
        "gemini-4-hydrogen-low`tGemini 4 Hydrogen Low"
        "gemini-4-hydrogen-medium`tGemini 4 Hydrogen Medium"
        "gemini-4-hydrogen-high`tGemini 4 Hydrogen High"
        "gemini-4-hydrogen-xhigh`tGemini 4 Hydrogen XHigh"
        "gemini-4-neon-low`tGemini 4 Neon Low"
        "gemini-4-neon-medium`tGemini 4 Neon Medium"
        "gemini-4-neon-high`tGemini 4 Neon High"
        "gemini-4-neon-xhigh`tGemini 4 Neon XHigh"
        "claude-opus-5-5-low`tClaude Opus 5.5 Low"
        "claude-opus-5-5-medium`tClaude Opus 5.5 Medium"
        "claude-opus-5-5-high`tClaude Opus 5.5 High"
        "claude-sonnet-5-5-low`tClaude Sonnet 5.5 Low"
        "claude-sonnet-5-5-medium`tClaude Sonnet 5.5 Medium"
        "claude-sonnet-5-5-high`tClaude Sonnet 5.5 High"
    ) -join "`n"
    [IO.File]::WriteAllText($agyFixture, $agyLines, $script:OrchestraUtf8)

    $codexFixture = Join-Path $tempRoot 'codex-catalog.json'
    $codexJson = '{"models":[{"slug":"gpt-6.2-astra"},{"slug":"gpt-6-sol"}]}'
    [IO.File]::WriteAllText($codexFixture, $codexJson, $script:OrchestraUtf8)

    # 1. -ListAvailable discovers both agy and codex models and effort tiers
    $listRun = Invoke-SScript 'scripts\setup.ps1' @(
        '-ListAvailable', '-NoNetwork',
        '-AgyListFile', $agyFixture, '-CodexCatalogFile', $codexFixture,
        '-RegistryPath', $caseReg, '-StateDir', $caseState
    )
    $availItems = @(Get-OrchestraArray $listRun.Json 'available')
    $neonItem = @($availItems | Where-Object { [string]$_.id -eq 'gemini-4-neon' })
    $solItem = @($availItems | Where-Object { [string]$_.id -eq 'gpt-6-sol' })
    Assert-STest (
        $listRun.Exit -eq 0 -and
        $neonItem.Count -eq 1 -and
        @($neonItem[0].efforts) -contains 'xhigh' -and
        $solItem.Count -eq 1 -and
        [string]$solItem[0].channel -eq 'codex' -and
        -not [bool]$solItem[0].evaluated
    ) 'setup -ListAvailable discovers agy and codex models with effort metadata'

    # 2. Shorthand -DryRun for carbon,6.2astra,4hextra,opus5.5 resolves cleanly with zero planned evaluations under auto
    $dryRun = Invoke-SScript 'scripts\setup.ps1' @(
        '-Models', 'carbon,6.2astra,4hextra,opus5.5', '-ReviewOnlyModels', 'opus5.5',
        '-Evaluate', 'auto', '-DryRun', '-NoNetwork',
        '-AgyListFile', $agyFixture, '-CodexCatalogFile', $codexFixture,
        '-RegistryPath', $caseReg, '-StateDir', $caseState
    )
    $selDry = @(Get-OrchestraArray $dryRun.Json 'selected_models')
    Assert-STest (
        $dryRun.Exit -eq 0 -and
        $selDry.Count -eq 4 -and
        $selDry -contains 'gemini-4-carbon' -and
        $selDry -contains 'gpt-6.2-astra' -and
        $selDry -contains 'gemini-4-hydrogen' -and
        $selDry -contains 'claude-opus-5-5' -and
        @(Get-OrchestraArray $dryRun.Json 'planned_evaluations').Count -eq 0 -and
        -not [IO.Directory]::Exists($caseState)
    ) 'setup shorthand DryRun resolves carbon,6.2astra,4hextra,opus5.5 without touching state'

    # 3. Ambiguous shorthand and all-review-only fail closed with exit 2
    $ambigRun = Invoke-SScript 'scripts\setup.ps1' @(
        '-Models', 'gpt-6', '-DryRun', '-NoNetwork',
        '-AgyListFile', $agyFixture, '-CodexCatalogFile', $codexFixture,
        '-RegistryPath', $caseReg, '-StateDir', $caseState
    )
    Assert-STest ($ambigRun.Exit -eq 2) 'ambiguous shorthand gpt-6 fails closed with exit 2'

    $allRoRun = Invoke-SScript 'scripts\setup.ps1' @(
        '-Models', 'opus5.5', '-ReviewOnlyModels', 'opus5.5', '-DryRun', '-NoNetwork',
        '-AgyListFile', $agyFixture, '-CodexCatalogFile', $codexFixture,
        '-RegistryPath', $caseReg, '-StateDir', $caseState
    )
    Assert-STest ($allRoRun.Exit -eq 2) 'marking all selected models as ReviewOnlyModels fails closed'

    # 4. Select custom new models (neon, sonnet5.5, sol) and run full evaluation (research + probe)
    $fakeCodexHome = Join-Path $tempRoot 'codex-home'
    [void][IO.Directory]::CreateDirectory($fakeCodexHome)
    [IO.File]::WriteAllBytes((Join-Path $fakeCodexHome 'auth.json'), $script:OrchestraUtf8.GetBytes('{"fixture":"setup"}'))
    $env:MODEL_ORCHESTRA_CODEX_HOME = $fakeCodexHome

    $fakeAgy = Join-Path $tempRoot 'fake-agy.ps1'
    $fakeCodex = Join-Path $tempRoot 'fake-codex.ps1'

    $mockHelperCode = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8

function Build-MockResponse([string]$PromptText, [string]$SchemaPath) {
    if (-not [string]::IsNullOrWhiteSpace($SchemaPath)) {
        $schemaRaw = [IO.File]::ReadAllText($SchemaPath, $utf8)
        if ($schemaRaw -match '"notable_strengths"') {
            $mId = 'unknown-model'
            if ($PromptText -match 'slug[^`]*`([a-z0-9.-]+)`') { $mId = $Matches[1] }
            $isCodex = ($mId -like 'gpt-*')
            $vendor = if ($mId -like 'gemini-*') { 'google' } elseif ($mId -like 'claude-*') { 'anthropic' } else { 'openai' }
            $chan = if ($isCodex) { 'codex' } else { 'agy' }
            $rigor = if ($isCodex) { 9.6 } else { 8.8 }
            $prose = if ($mId -like 'gemini-*') { 9.7 } else { 8.4 }
            $aes = if ($mId -like 'claude-*') { 9.8 } else { 8.2 }
            $img = if ($isCodex) { 9.5 } else { 0.0 }
            $dims = @('code_rigor','backend','math','image_gen','frontend_aesthetic','prose','world_knowledge','long_context','agentic_coding','office_docs')
            $caps = [ordered]@{}
            foreach ($d in $dims) {
                $sc = switch ($d) {
                    'code_rigor' { $rigor }
                    'math' { $rigor }
                    'prose' { $prose }
                    'world_knowledge' { $prose }
                    'frontend_aesthetic' { $aes }
                    'image_gen' { $img }
                    default { 8.5 }
                }
                $caps[$d] = [ordered]@{
                    score = $sc; vs_incumbent = 0; confidence = 0.8
                    evidence = @(@{ url = 'https://example.org/bench'; claim = "Mock $d = $sc"; date = '2026-11-16' })
                }
            }
            $obj = [ordered]@{
                model_id = $mId; family = ($vendor + '-family'); generation = '6'
                vendor = $vendor; channel = $chan; tier = 'flagship'; supersedes = $null
                caps = $caps; speed_rank_hint = 3; quota_rank_hint = 2
                notable_strengths = @("Evaluated strength for $mId")
                notable_weaknesses = @("Evaluated weakness for $mId")
                suggested_hard_rules = @()
                sources_checked = @('https://example.org/bench')
            }
            return (ConvertTo-Json -InputObject $obj -Depth 12 -Compress)
        }
        if ($schemaRaw -match '"disputed"') {
            return '{"disputed":[]}'
        }
        if ($schemaRaw -match '"fatal_cap_triggered"') {
            return '{"parts":[5,4.5,4.5],"fatal_cap_triggered":false,"rationale":"Strong blind probe performance."}'
        }
    }
    return 'Mock probe task answer.'
}
'@

    $fakeAgyText = $mockHelperCode + @'
$pIdx = [Array]::IndexOf($args, '-p')
$sIdx = [Array]::IndexOf($args, '--json-schema')
$promptVal = if ($pIdx -ge 0) { [string]$args[$pIdx + 1] } else { '' }
if ($promptVal -match 'Read the complete UTF-8 file at "([^"]+)"') {
    $promptVal = [IO.File]::ReadAllText($Matches[1], $utf8)
}
$schemaVal = if ($sIdx -ge 0) { [string]$args[$sIdx + 1] } else { '' }
$resp = Build-MockResponse -PromptText $promptVal -SchemaPath $schemaVal
[Console]::WriteLine('{"event":"init","conversation_id":"mock-agy-setup","init":{"model":"mock"}}')
[Console]::WriteLine((ConvertTo-Json -InputObject @{
    event = 'result'
    result = @{ status = 'SUCCESS'; conversation_id = 'mock-agy-setup'; response = $resp }
} -Depth 8 -Compress))
exit 0
'@

    $fakeCodexText = $mockHelperCode + @'
if (@($args) -contains '--version') {
    [Console]::WriteLine('codex-cli 0.167.0')
    exit 0
}
$sIdx = [Array]::IndexOf($args, '--output-schema')
$oIdx = [Array]::IndexOf($args, '-o')
$schemaVal = if ($sIdx -ge 0) { [string]$args[$sIdx + 1] } else { '' }
$outVal = if ($oIdx -ge 0) { [string]$args[$oIdx + 1] } else { '' }
$stdinPrompt = [Console]::In.ReadToEnd()
$resp = Build-MockResponse -PromptText $stdinPrompt -SchemaPath $schemaVal
if (-not [string]::IsNullOrWhiteSpace($outVal)) {
    [IO.File]::WriteAllText($outVal, $resp, $utf8)
}
[Console]::WriteLine('{"type":"thread.started","thread_id":"mock-codex-setup"}')
[Console]::WriteLine((ConvertTo-Json -InputObject @{
    type = 'item.completed'
    item = @{ type = 'agent_message'; text = $resp }
} -Depth 8 -Compress))
[Console]::WriteLine('{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}')
exit 0
'@

    [IO.File]::WriteAllText($fakeAgy, $fakeAgyText, $script:OrchestraUtf8)
    [IO.File]::WriteAllText($fakeCodex, $fakeCodexText, $script:OrchestraUtf8)
    $env:MODEL_ORCHESTRA_AGY_WRAPPER = $fakeAgy
    $env:MODEL_ORCHESTRA_CODEX = $fakeCodex

    $fullSetup = Invoke-SScript 'scripts\setup.ps1' @(
        '-Models', 'neon,sonnet5.5,sol',
        '-ReviewOnlyModels', 'sonnet5.5',
        '-Evaluate', 'full',
        '-SkipJunction', '-NoNetwork',
        '-AgyListFile', $agyFixture, '-CodexCatalogFile', $codexFixture,
        '-RegistryPath', $caseReg, '-StateDir', $caseState
    ) 240

    $targetCustomIds = @('gemini-4-neon', 'claude-sonnet-5-5', 'gpt-6-sol')
    $initialIds = @($initialCaseRegObj.models | ForEach-Object { [string]$_.id })
    $expectedAddedCount = @($targetCustomIds | Where-Object { $initialIds -notcontains $_ }).Count
    $expectedRetiredCount = @($initialCaseRegObj.models | Where-Object {
        [string]$_.status -eq 'active' -and ($targetCustomIds -notcontains [string]$_.id)
    }).Count
    Assert-STest (
        $fullSetup.Exit -eq 0 -and
        [bool]$fullSetup.Json.docs_synced -eq $true -and
        [bool]$fullSetup.Json.doctor_healthy -eq $true -and
        -not [string]::IsNullOrWhiteSpace([string]$fullSetup.Json.backup) -and
        @(Get-OrchestraArray $fullSetup.Json 'added_models').Count -eq $expectedAddedCount -and
        @(Get-OrchestraArray $fullSetup.Json 'retired_models').Count -eq $expectedRetiredCount
    ) 'setup custom roster (neon, sonnet5.5, sol) with full evaluation exits 0'

    $updatedReg = Read-JsonFile -Path $caseReg
    $activeAfter = @($updatedReg.models | Where-Object { [string]$_.status -eq 'active' })
    $sonnetObj = @($activeAfter | Where-Object { [string]$_.id -eq 'claude-sonnet-5-5' })[0]
    $solObj = @($activeAfter | Where-Object { [string]$_.id -eq 'gpt-6-sol' })[0]
    $neonObj = @($activeAfter | Where-Object { [string]$_.id -eq 'gemini-4-neon' })[0]

    Assert-STest (
        $activeAfter.Count -eq 3 -and
        [bool]$sonnetObj.primary_disabled -eq $true -and
        -not [bool]$solObj.primary_disabled -and
        [string]$solObj.caps.code_rigor.source -eq 'research+probe' -and
        [double]$solObj.caps.code_rigor.score -gt 8.5 -and
        [string]$updatedReg.aliases.'best-rigor' -eq 'gpt-6-sol' -and
        [string]$updatedReg.aliases.'best-prose' -eq 'gemini-4-neon' -and
        [string]$updatedReg.aliases.'best-aesthetic' -eq 'claude-sonnet-5-5'
    ) 'post-selection full evaluation populates research+probe scores and rebinds best-* aliases'

    # Verify unselected pre-existing models are in baseline_slugs so detect-models reports zero new
    $detectAfter = Invoke-SScript 'scripts\detect-models.ps1' @(
        '-Force', '-NoNetwork',
        '-AgyListFile', $agyFixture, '-CodexCatalogFile', $codexFixture,
        '-RegistryPath', $caseReg, '-StateDir', $caseState
    )
    Assert-STest (
        $detectAfter.Exit -eq 0 -and
        @(Get-OrchestraArray $detectAfter.Json 'new').Count -eq 0
    ) 'unselected local models are recorded in baseline_slugs without false new-model alerts'

    # Verify managed docs including model-profiles AUTO:PROFILES are in sync
    $profilesText = [IO.File]::ReadAllText((Join-Path $caseRepo 'references\model-profiles.md'), $script:OrchestraUtf8)
    $checkSyncAfter = Invoke-SScript 'scripts\sync-docs.ps1' @('-Check', '-RegistryPath', $caseReg, '-Root', $caseRepo)
    Assert-STest (
        $checkSyncAfter.Exit -eq 0 -and
        $profilesText.Contains('gpt-6-sol') -and
        $profilesText.Contains('gemini-4-neon') -and
        $profilesText.Contains('claude-sonnet-5-5') -and
        -not $profilesText.Contains('gpt-6.2-astra')
    ) 'sync-docs renders custom roster into model-profiles.md with zero drift'

    # Verify global_plugin_synced is skipped for isolated paths by default, synced when -GlobalPluginDestination is targeted, and blocked by -SkipGlobalPlugin / COWORK_SKIP_GLOBAL_PLUGIN
    $pluginSrcDir = Join-Path $caseRepo 'integrations\cowork-orchestrator-plugin'
    [void][IO.Directory]::CreateDirectory((Join-Path $pluginSrcDir 'rules'))
    $mockPluginJson = '{"name":"cowork-orchestrator","version":"1.0.0"}'
    $mockAgentsMd = "# Mock Orchestrator Rules`n"
    [IO.File]::WriteAllText((Join-Path $pluginSrcDir 'plugin.json'), $mockPluginJson, $script:OrchestraUtf8)
    [IO.File]::WriteAllText((Join-Path $pluginSrcDir 'rules\AGENTS.md'), $mockAgentsMd, $script:OrchestraUtf8)
    $fakeGlobalDest = Join-Path $tempRoot 'plugins\cowork-orchestrator'

    Assert-STest (-not [bool]$fullSetup.Json.global_plugin_synced) 'isolated setup with non-default RegistryPath/StateDir skips global plugin sync by default'

    $pluginSyncRun = Invoke-SScript 'scripts\setup.ps1' @(
        '-Models', 'neon,sonnet5.5,sol',
        '-ReviewOnlyModels', 'sonnet5.5',
        '-Evaluate', 'none',
        '-SkipJunction', '-NoNetwork',
        '-GlobalPluginDestination', $fakeGlobalDest,
        '-AgyListFile', $agyFixture, '-CodexCatalogFile', $codexFixture,
        '-RegistryPath', $caseReg, '-StateDir', $caseState
    ) 120
    $copiedPlugin = Join-Path $fakeGlobalDest 'plugin.json'
    $copiedRules = Join-Path $fakeGlobalDest 'rules\AGENTS.md'
    Assert-STest (
        $pluginSyncRun.Exit -eq 0 -and
        [bool]$pluginSyncRun.Json.global_plugin_synced -eq $true -and
        [IO.File]::Exists($copiedPlugin) -and
        [IO.File]::Exists($copiedRules) -and
        ([IO.File]::ReadAllText($copiedPlugin, $script:OrchestraUtf8) -ceq $mockPluginJson) -and
        ([IO.File]::ReadAllText($copiedRules, $script:OrchestraUtf8) -ceq $mockAgentsMd)
    ) 'setup syncs cowork-orchestrator plugin.json and rules\AGENTS.md atomically to GlobalPluginDestination'

    $fakeSkippedDest = Join-Path $tempRoot 'plugins\skipped-dest'
    $pluginSkipFlagRun = Invoke-SScript 'scripts\setup.ps1' @(
        '-Models', 'neon,sonnet5.5,sol',
        '-ReviewOnlyModels', 'sonnet5.5',
        '-Evaluate', 'none',
        '-SkipJunction', '-SkipGlobalPlugin', '-NoNetwork',
        '-GlobalPluginDestination', $fakeSkippedDest,
        '-AgyListFile', $agyFixture, '-CodexCatalogFile', $codexFixture,
        '-RegistryPath', $caseReg, '-StateDir', $caseState
    ) 120
    $env:COWORK_SKIP_GLOBAL_PLUGIN = '1'
    $pluginSkipEnvRun = Invoke-SScript 'scripts\setup.ps1' @(
        '-Models', 'neon,sonnet5.5,sol',
        '-ReviewOnlyModels', 'sonnet5.5',
        '-Evaluate', 'none',
        '-SkipJunction', '-NoNetwork',
        '-GlobalPluginDestination', $fakeSkippedDest,
        '-AgyListFile', $agyFixture, '-CodexCatalogFile', $codexFixture,
        '-RegistryPath', $caseReg, '-StateDir', $caseState
    ) 120
    $env:COWORK_SKIP_GLOBAL_PLUGIN = $savedEnv['COWORK_SKIP_GLOBAL_PLUGIN']
    Assert-STest (
        $pluginSkipFlagRun.Exit -eq 0 -and
        -not [bool]$pluginSkipFlagRun.Json.global_plugin_synced -and
        $pluginSkipEnvRun.Exit -eq 0 -and
        -not [bool]$pluginSkipEnvRun.Json.global_plugin_synced -and
        -not [IO.Directory]::Exists($fakeSkippedDest)
    ) '-SkipGlobalPlugin and COWORK_SKIP_GLOBAL_PLUGIN=1 prevent syncing global plugin'
}
catch {
    [void]$script:setupFailures.Add('Unhandled setup test error: ' + $_.Exception.Message)
}
finally {
    foreach ($n in $envNames) {
        [Environment]::SetEnvironmentVariable($n, $savedEnv[$n])
    }
    if ($null -ne $tempRoot -and [IO.Directory]::Exists($tempRoot)) {
        try {
            $res = [IO.Path]::GetFullPath($tempRoot)
            $pref = $tempParent.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            $leaf = [IO.Path]::GetFileName($res)
            if ($res.StartsWith($pref, [StringComparison]::OrdinalIgnoreCase) -and $leaf -match '^model-orchestra-setup-test-[a-f0-9]{32}$') {
                [IO.Directory]::Delete($res, $true)
            }
        }
        catch {
            [void]$script:setupFailures.Add('Cleanup error: ' + $_.Exception.Message)
        }
    }
}

Write-OrchestraResult -Object @{
    suite = 'setup'
    passed = $script:setupPassed
    failed = $script:setupFailures.Count
    failures = $script:setupFailures.ToArray()
}
if ($script:setupFailures.Count -gt 0) { exit 1 }
exit 0
