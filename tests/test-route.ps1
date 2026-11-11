<#
.SYNOPSIS
Run isolated, offline route regression tests for the three active models.
.DESCRIPTION
Copies the supplied registry into a unique temporary directory.
Uses explicit synthetic escalation and candidate fixtures.
Writes one suite JSON object and exits 1 on assertion failure.
#>
[CmdletBinding()]
param([string]$RegistryPath, [string]$StateDir)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $root 'scripts\lib\common.ps1')

$script:routePassed = 0
$script:routeFailures = New-Object 'System.Collections.Generic.List[string]'
$engine = (Get-Process -Id $PID).Path
$oldNow = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_NOW')
$temp = $null
$parent = $null

function Assert-RTest {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:routePassed++ }
    else { [void]$script:routeFailures.Add($Name) }
}

function Invoke-RTest {
    param(
        [string]$TagText,
        [string]$ModeName = 'balanced',
        [switch]$Escalate,
        [string]$Excluded = ''
    )
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $root 'scripts\route.ps1'),
        '-RegistryPath', $script:routePaths.Registry,
        '-StateDir', $script:routePaths.StateDir,
        '-Tags', $TagText, '-Mode', $ModeName
    )
    if ($Escalate) { $arguments += '-AllowEscalation' }
    if ($Excluded.Length -gt 0) { $arguments += @('-Exclude', $Excluded) }
    $execution = Invoke-OrchestraProcess -FilePath $engine `
        -Arguments $arguments -WorkDir $temp -TimeoutSec 60 -CaptureStdout
    $lines = @($execution.stdout | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    if ($lines.Count -ne 1) {
        throw "route emitted $($lines.Count) nonempty stdout lines."
    }
    return [pscustomobject]@{
        Exit = $execution.exit_code
        Result = ([string]$lines[0] | ConvertFrom-Json)
    }
}

function Save-RTestFixture {
    param($Registry)
    Invoke-WithLock -Paths $script:routePaths -Name registry -ScriptBlock {
        Write-JsonAtomic -Path $script:routePaths.Registry -Object $Registry
    } | Out-Null
}

function Copy-RTestFixture {
    param($Registry)
    $json = ConvertTo-Json -InputObject $Registry -Depth 32
    return ($json | ConvertFrom-Json)
}

function Get-RTestModel {
    param($Registry, [string]$Id)
    $models = @($Registry.models | Where-Object { $_.id -eq $Id })
    if ($models.Count -ne 1) { throw "Expected exactly one model: $Id" }
    return $models[0]
}

function Set-RTestScore {
    param($Model, [string]$Dimension, [double]$Score)
    $cap = Get-OrchestraProperty $Model.caps $Dimension
    if ($null -eq $cap) { throw "Missing capability: $Dimension" }
    Set-OrchestraProperty $cap 'score' $Score
    Set-OrchestraProperty $cap 'approved_score' $Score
}

function Add-RTestCandidate {
    param($Registry)
    $candidate = Copy-RTestFixture (Get-RTestModel $Registry 'gemini-4-carbon')
    Set-OrchestraProperty $candidate 'id' 'test-candidate'
    Set-OrchestraProperty $candidate 'display_name' 'Test Candidate'
    Set-OrchestraProperty $candidate 'status' 'candidate'
    Set-OrchestraProperty $candidate 'escalation_only' $false
    Set-RTestScore $candidate 'prose' 8.5
    Set-RTestScore $candidate 'world_knowledge' 10
    Set-OrchestraProperty $Registry 'models' (@($Registry.models) + @($candidate))
}

function Set-RTestExhaustion {
    param([string[]]$Ids = @(), [switch]$All)
    $exhaustedIds = @($Ids)
    if ($All) {
        $registryCopy = Invoke-WithLock `
            -Paths $script:routePaths -Name registry -ScriptBlock {
                Read-Registry -Paths $script:routePaths
            }
        $exhaustedIds = @(
            $registryCopy.models | ForEach-Object { [string]$_.id }
        )
    }
    Invoke-WithLock -Paths $script:routePaths -Name state -ScriptBlock {
        $state = Read-State -Paths $script:routePaths
        $entries = @{}
        foreach ($modelId in $exhaustedIds) {
            $entries[$modelId] = @{ until = '2026-11-10T17:00:00Z' }
        }
        Set-OrchestraProperty $state 'exhausted' $entries
        Save-State -Paths $script:routePaths -State $state
    } | Out-Null
}

try {
    $env:MODEL_ORCHESTRA_NOW = '2026-11-10T12:00:00Z'
    $sourcePaths = Get-OrchestraPaths -RegistryPath $RegistryPath -StateDir $null
    $parent = $StateDir
    if ([string]::IsNullOrWhiteSpace($parent)) {
        $parent = [IO.Path]::GetTempPath()
    }
    $parent = [IO.Path]::GetFullPath($parent)
    $temp = Join-Path $parent (
        'model-orchestra-route-' + [guid]::NewGuid().ToString('N')
    )
    [void][IO.Directory]::CreateDirectory($temp)
    $script:routePaths = Get-OrchestraPaths `
        -RegistryPath (Join-Path $temp 'registry\models.json') `
        -StateDir (Join-Path $temp 'state')
    [void][IO.Directory]::CreateDirectory($script:routePaths.RegistryDir)

    $fixture = Read-JsonFile -Path $sourcePaths.Registry
    if ($null -eq $fixture) { throw 'Registry template was not found.' }
    $expectedIds = @('gpt-6-astra', 'gemini-4-carbon', 'claude-opus-5-5')
    $actualIds = @($fixture.models | ForEach-Object { [string]$_.id })
    Assert-RTest (
        $actualIds.Count -eq 3 -and
        @($actualIds | Where-Object { $_ -notin $expectedIds }).Count -eq 0
    ) 'registry contains exactly the three primary models'
    foreach ($id in $expectedIds) {
        $profile = Get-RTestModel $fixture $id
        Assert-RTest (
            $profile.status -eq 'active' -and
            $profile.invoke.default_effort -eq 'high' -and
            -not [bool](Get-OrchestraProperty $profile 'escalation_only' $false)
        ) "$id is active at high effort without escalation"
    }
    $astra = Get-RTestModel $fixture 'gpt-6-astra'
    Assert-RTest (
        (Get-OrchestraProperty $astra.invoke 'account_rotation' $false) -eq $true -and
        (Get-OrchestraProperty $astra.invoke 'rotation_max_retries' -1) -eq 2 -and
        (Get-OrchestraProperty $astra.invoke 'rotation_wait_sec' -1) -eq 10 -and
        (Get-OrchestraProperty $astra.invoke 'exhausted_minutes' -1) -eq 30
    ) 'Astra declares the Cockpit rotation policy'

    Save-RTestFixture $fixture
    Set-RTestExhaustion

    $run = Invoke-RTest 'frontend,landing_page'
    $r = $run.Result
    Assert-RTest ($run.Exit -eq 0) 'frontend exits 0'
    Assert-RTest ($r.primary -eq 'gemini-4-carbon') 'frontend primary'
    Assert-RTest ($r.reviewer -eq 'claude-opus-5-5') 'frontend reviewer'
    Assert-RTest ($null -eq $r.polisher) 'primary is not duplicated as polisher'
    Assert-RTest ($r.pattern -eq 'aesthetic_gate') 'frontend aesthetic gate'

    $run = Invoke-RTest 'image_gen'
    Assert-RTest (
        $run.Exit -eq 0 -and $run.Result.primary -eq 'gpt-6-astra'
    ) 'image generation primary'
    Assert-RTest (
        $run.Result.reviewer -eq 'claude-opus-5-5' -and
        $run.Result.pattern -eq 'strength_delegation'
    ) 'image generation reviewer and pattern'

    $run = Invoke-RTest 'backend,concurrency'
    Assert-RTest (
        $run.Exit -eq 0 -and $run.Result.primary -eq 'gpt-6-astra' -and
        $run.Result.reviewer -eq 'gemini-4-carbon'
    ) 'backend primary and independent reviewer'

    foreach ($modeName in @('balanced', 'economy')) {
        $run = Invoke-RTest 'math' -ModeName $modeName
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.primary -eq 'gpt-6-astra' -and
            $run.Result.reviewer -eq 'gemini-4-carbon'
        ) "math primary and reviewer in $modeName"
        Assert-RTest (
            ($run.Result.reasons -join ' ') -match 'math >= 9'
        ) "math min_cap reason in $modeName"
    }
    foreach ($tagText in @('prose,essay', 'prose', 'refactor')) {
        $run = Invoke-RTest $tagText
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.primary -eq 'gemini-4-carbon' -and
            $run.Result.reviewer -eq 'gpt-6-astra' -and
            $run.Result.self_review -eq $false
        ) "$tagText primary and reviewer"
    }

    Set-RTestExhaustion @('claude-opus-5-5')
    $run = Invoke-RTest 'frontend'
    Assert-RTest (
        $run.Exit -eq 0 -and $run.Result.primary -eq 'gemini-4-carbon' -and
        $run.Result.reviewer -eq 'gemini-4-carbon' -and
        $run.Result.self_review -eq $true -and $run.Result.blocked -eq $false
    ) 'aesthetic fallback may self-review'

    Set-RTestExhaustion
    $run = Invoke-RTest 'not_a_registered_tag'
    Assert-RTest ($run.Exit -eq 2) 'unknown tag exits 2'
    $run = Invoke-RTest 'frontend' -ModeName 'not_a_mode'
    Assert-RTest ($run.Exit -eq 2) 'unknown mode exits 2'

    Set-RTestExhaustion -All
    $run = Invoke-RTest 'frontend'
    Assert-RTest (
        $run.Exit -eq 0 -and $run.Result.blocked -eq $true -and
        $null -eq $run.Result.primary
    ) 'all exhausted returns blocked with exit 0'

    Set-RTestExhaustion
    $run = Invoke-RTest 'image_gen' -Excluded 'gpt-6-astra'
    Assert-RTest (
        $run.Exit -eq 0 -and $run.Result.blocked -eq $true
    ) 'tool requirement blocks when eligible tool provider is excluded'
    $stateBefore = Get-Content -LiteralPath $script:routePaths.State -Raw -Encoding UTF8
    $run = Invoke-RTest 'research'
    $stateAfter = Get-Content -LiteralPath $script:routePaths.State -Raw -Encoding UTF8
    Assert-RTest ($stateBefore -ceq $stateAfter) 'routing does not mutate state'

    try {
        # Production Astra is active. A separate fixture exercises escalation.
        $caseRegistry = Copy-RTestFixture $fixture
        $escalationModel = Copy-RTestFixture (Get-RTestModel $caseRegistry 'gpt-6-astra')
        Set-OrchestraProperty $escalationModel 'id' 'test-escalation'
        Set-OrchestraProperty $escalationModel 'display_name' 'Test Escalation'
        Set-OrchestraProperty $escalationModel 'escalation_only' $true
        Set-OrchestraProperty $caseRegistry 'models' (
            @($caseRegistry.models) + @($escalationModel)
        )
        Save-RTestFixture $caseRegistry
        foreach ($tag in @('frontend', 'math', 'refactor', 'research')) {
            $run = Invoke-RTest $tag
            Assert-RTest (
                $run.Exit -eq 0 -and
                $run.Result.primary -ne 'test-escalation' -and
                $run.Result.reviewer -ne 'test-escalation' -and
                $run.Result.polisher -ne 'test-escalation' -and
                @($run.Result.fallback) -notcontains 'test-escalation'
            ) "escalation fixture is excluded without permission for $tag"
        }
        Set-RTestExhaustion @('gpt-6-astra')
        $run = Invoke-RTest 'math'
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.blocked -eq $true
        ) 'math blocks when only escalation satisfies min_cap'
        $run = Invoke-RTest 'math' -Escalate
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.primary -eq 'test-escalation'
        ) 'AllowEscalation permits the explicit escalation fixture'
        $run = Invoke-RTest 'math' -Escalate -Excluded 'test-escalation'
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.blocked -eq $true
        ) 'explicit exclusion still overrides escalation permission'

        Set-RTestExhaustion
        Save-RTestFixture $fixture

        # Candidate is the unique strongest knowledge reviewer but has weak prose.
        $caseRegistry = Copy-RTestFixture $fixture
        Add-RTestCandidate $caseRegistry
        Set-RTestScore (Get-RTestModel $caseRegistry 'gpt-6-astra') 'world_knowledge' 8
        Set-RTestScore (Get-RTestModel $caseRegistry 'claude-opus-5-5') 'world_knowledge' 7
        Save-RTestFixture $caseRegistry
        $run = Invoke-RTest 'prose'
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.primary -eq 'gemini-4-carbon' -and
            $run.Result.reviewer -eq 'gpt-6-astra' -and
            $run.Result.reviewer -ne 'test-candidate'
        ) 'highest review_caps candidate cannot become reviewer'
        Assert-RTest (
            @($run.Result.fallback) -contains 'test-candidate'
        ) 'candidate remains eligible for primary fallbacks'
        $candidateScore = Get-OrchestraProperty $run.Result.scores 'test-candidate'
        Assert-RTest (
            $null -ne $candidateScore -and
            (Get-OrchestraProperty $candidateScore.penalties 'candidate' 0) -gt 0
        ) 'candidate retains its primary score penalty'

        $caseRegistry = Copy-RTestFixture $fixture
        Add-RTestCandidate $caseRegistry
        Set-OrchestraProperty $caseRegistry.aliases 'test-reviewer' 'test-candidate'
        $rules = Get-OrchestraProperty $caseRegistry 'hard_rules' @()
        Set-OrchestraProperty $caseRegistry 'hard_rules' (@($rules) + @(
            [pscustomobject]@{
                id = 'test-candidate-reviewer'; when_tags_any = @('prose')
                reviewer = 'test-reviewer'; reviewer_fallback = 'claude-opus-5-5'
                locked = $false
            }
        ))
        Save-RTestFixture $caseRegistry
        $run = Invoke-RTest 'prose'
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.primary -eq 'gemini-4-carbon' -and
            $run.Result.reviewer -eq 'claude-opus-5-5'
        ) 'candidate reviewer alias uses its active rule fallback'

        $caseRegistry = Copy-RTestFixture $fixture
        Add-RTestCandidate $caseRegistry
        Set-OrchestraProperty $caseRegistry.aliases 'best-aesthetic' 'test-candidate'
        Save-RTestFixture $caseRegistry
        $run = Invoke-RTest 'frontend,landing_page'
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.primary -eq 'gemini-4-carbon' -and
            $run.Result.reviewer -eq 'gemini-4-carbon' -and
            $run.Result.self_review -eq $true -and $run.Result.blocked -eq $false
        ) 'aesthetic candidate alias uses its active fallback'

        $caseRegistry = Copy-RTestFixture $fixture
        Add-RTestCandidate $caseRegistry
        Set-OrchestraProperty $caseRegistry.aliases 'best-prose' 'test-candidate'
        Save-RTestFixture $caseRegistry
        $run = Invoke-RTest 'prose'
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.primary -eq 'gemini-4-carbon' -and
            $run.Result.polisher -eq 'claude-opus-5-5'
        ) 'candidate polisher alias reselects an active polisher'

        # Keep the diversity threshold measurable after Astra knowledge rose to 9.
        $caseRegistry = Copy-RTestFixture $fixture
        Set-RTestScore (Get-RTestModel $caseRegistry 'gpt-6-astra') 'world_knowledge' 8
        Set-RTestScore (Get-RTestModel $caseRegistry 'claude-opus-5-5') 'world_knowledge' 7
        $sameVendorModel = Copy-RTestFixture (
            Get-RTestModel $caseRegistry 'gemini-4-carbon'
        )
        Set-OrchestraProperty $sameVendorModel 'id' 'test-same-vendor-reviewer'
        Set-OrchestraProperty $sameVendorModel 'display_name' 'Test Same Vendor Reviewer'
        Set-OrchestraProperty $sameVendorModel 'status' 'active'
        Set-OrchestraProperty $sameVendorModel 'escalation_only' $false
        Set-RTestScore $sameVendorModel 'prose' 0
        Set-RTestScore $sameVendorModel 'world_knowledge' 9.5
        Set-OrchestraProperty $caseRegistry 'models' (
            @($caseRegistry.models) + @($sameVendorModel)
        )
        Save-RTestFixture $caseRegistry
        $run = Invoke-RTest 'prose'
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.primary -eq 'gemini-4-carbon' -and
            $run.Result.reviewer -eq 'gpt-6-astra' -and
            ($run.Result.reasons -join ' ') -match 'vendor diversity'
        ) 'different vendor is preferred at the inclusive 1.5 gap'

        Set-RTestScore $sameVendorModel 'world_knowledge' 9.6
        Save-RTestFixture $caseRegistry
        $run = Invoke-RTest 'prose'
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.primary -eq 'gemini-4-carbon' -and
            $run.Result.reviewer -eq 'test-same-vendor-reviewer'
        ) 'vendor preference does not exceed the 1.5 gap'

        foreach ($caseModel in @($caseRegistry.models)) {
            Set-OrchestraProperty $caseModel 'status' 'candidate'
        }
        Save-RTestFixture $caseRegistry
        $run = Invoke-RTest 'prose'
        Assert-RTest (
            $run.Exit -eq 0 -and $null -ne $run.Result.primary -and
            $null -eq $run.Result.reviewer -and $null -eq $run.Result.polisher
        ) 'candidate primary is allowed while candidate review roles remain empty'
    }
    finally {
        Save-RTestFixture $fixture
        Set-RTestExhaustion
    }
}
catch {
    [void]$script:routeFailures.Add('Harness: ' + $_.Exception.Message)
}
finally {
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_NOW', $oldNow, 'Process')
    if ($null -ne $temp -and [IO.Directory]::Exists($temp)) {
        try {
            $resolvedTemp = [IO.Path]::GetFullPath($temp)
            $parentPrefix = $parent.TrimEnd(
                [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar
            ) + [IO.Path]::DirectorySeparatorChar
            $leaf = [IO.Path]::GetFileName($resolvedTemp)
            if (-not $resolvedTemp.StartsWith(
                    $parentPrefix, [StringComparison]::OrdinalIgnoreCase
                ) -or $leaf -notmatch '^model-orchestra-route-[a-f0-9]{32}$') {
                throw 'Refusing cleanup outside the unique test directory.'
            }
            [IO.Directory]::Delete($resolvedTemp, $true)
        }
        catch {
            [void]$script:routeFailures.Add('Cleanup: ' + $_.Exception.Message)
        }
    }
}
Write-OrchestraResult -Object @{
    suite = 'route'; passed = $script:routePassed
    failed = $script:routeFailures.Count
    failures = $script:routeFailures.ToArray()
}
if ($script:routeFailures.Count -gt 0) { exit 1 }
exit 0
