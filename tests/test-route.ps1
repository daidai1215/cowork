<#
.SYNOPSIS
Run isolated, model-ID-agnostic route regression tests.
.DESCRIPTION
Part A validates live registry structural invariants and dynamic alias/tag routing
without hardcoding any current production model IDs.
Part B validates escalation, candidate restrictions, fallback rules, and the 1.5-point
vendor diversity threshold on a deterministic synthetic 3-model fixture.
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
        [string]$HostModel = '',
        [switch]$Escalate,
        [string]$Excluded = '',
        [string]$BusyAgents = '',
        [switch]$PreferIdle
    )
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $root 'scripts\route.ps1'),
        '-RegistryPath', $script:routePaths.Registry,
        '-StateDir', $script:routePaths.StateDir,
        '-Tags', $TagText
    )
    if (-not [string]::IsNullOrWhiteSpace($ModeName)) { $arguments += @('-Mode', $ModeName) }
    if (-not [string]::IsNullOrWhiteSpace($HostModel)) { $arguments += @('-HostModel', $HostModel) }
    if ($Escalate) { $arguments += '-AllowEscalation' }
    if ($Excluded.Length -gt 0) { $arguments += @('-Exclude', $Excluded) }
    if ($BusyAgents.Length -gt 0) { $arguments += @('-BusyAgents', $BusyAgents) }
    if ($PreferIdle) { $arguments += '-PreferIdle' }
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
    $models = @($Registry.models | Where-Object { [string]$_.id -eq $Id })
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

function New-SyntheticCapMap {
    param([string[]]$Dimensions, [hashtable]$Scores)
    $caps = [ordered]@{}
    foreach ($dim in $Dimensions) {
        $val = if ($Scores.ContainsKey($dim)) { [double]$Scores[$dim] } else { 7.0 }
        $caps[$dim] = [ordered]@{
            score = $val
            approved_score = $val
            source = 'public'
            locked = $false
            confidence = 0.8
        }
    }
    return ([pscustomobject]$caps)
}

function New-SyntheticFixture {
    param($TemplateRegistry)
    $dims = @($TemplateRegistry.cap_dimensions | ForEach-Object { [string]$_ })
    $syn = Copy-RTestFixture $TemplateRegistry
    $models = @(
        [pscustomobject]@{
            id = 'syn-rigor'
            display_name = 'Synthetic Rigor'
            vendor = 'openai'
            family = 'openai-syn'
            generation = '1'
            tier = 'flagship'
            status = 'active'
            channel = 'codex'
            invoke = [pscustomobject]@{
                model_flag = 'syn-rigor'
                default_effort = 'high'
                efforts = @('low', 'medium', 'high')
                account_rotation = $true
                rotation_max_retries = 2
                rotation_wait_sec = 10
                exhausted_minutes = 30
            }
            tools = @('image_gen', 'office_plugins', 'latex', 'browser')
            quota_rank = 2
            speed_rank = 1
            ranks_locked = $true
            escalation_only = $false
            escalate_to = $null
            fallback = @('syn-prose', 'syn-aesthetic')
            caps = (New-SyntheticCapMap -Dimensions $dims -Scores @{
                code_rigor = 10; backend = 10; math = 10; image_gen = 10
                frontend_aesthetic = 7; prose = 6; world_knowledge = 8
                long_context = 8; agentic_coding = 9.5; office_docs = 9
            })
        },
        [pscustomobject]@{
            id = 'syn-aesthetic'
            display_name = 'Synthetic Aesthetic'
            vendor = 'anthropic'
            family = 'anthropic-syn'
            generation = '1'
            tier = 'flagship'
            status = 'active'
            channel = 'agy'
            invoke = [pscustomobject]@{
                model_flag = 'syn-aesthetic-{effort}'
                default_effort = 'high'
                efforts = @('low', 'medium', 'high')
            }
            tools = @('web_search', 'browser')
            quota_rank = 1
            speed_rank = 2
            ranks_locked = $true
            escalation_only = $false
            escalate_to = $null
            fallback = @('syn-prose')
            caps = (New-SyntheticCapMap -Dimensions $dims -Scores @{
                code_rigor = 8.5; backend = 8; math = 8; image_gen = 0
                frontend_aesthetic = 10; prose = 8.5; world_knowledge = 7
                long_context = 8; agentic_coding = 9.5; office_docs = 5
            })
        },
        [pscustomobject]@{
            id = 'syn-prose'
            display_name = 'Synthetic Prose'
            vendor = 'google'
            family = 'google-syn'
            generation = '1'
            tier = 'flagship'
            status = 'active'
            channel = 'agy'
            invoke = [pscustomobject]@{
                model_flag = 'syn-prose-{effort}'
                default_effort = 'high'
                efforts = @('low', 'medium', 'high')
            }
            tools = @('web_search', 'browser', 'long_context_1m')
            quota_rank = 3
            speed_rank = 3
            ranks_locked = $true
            escalation_only = $false
            escalate_to = $null
            fallback = @('syn-rigor')
            caps = (New-SyntheticCapMap -Dimensions $dims -Scores @{
                code_rigor = 8.5; backend = 8.5; math = 8.5; image_gen = 0
                frontend_aesthetic = 8.5; prose = 9.5; world_knowledge = 9.5
                long_context = 9.5; agentic_coding = 9; office_docs = 7
            })
        }
    )
    Set-OrchestraProperty $syn 'models' $models
    Set-OrchestraProperty $syn 'aliases' ([pscustomobject]@{
        'best-rigor' = 'syn-rigor'
        'best-math' = 'syn-rigor'
        'best-image' = 'syn-rigor'
        'best-prose' = 'syn-prose'
        'best-knowledge' = 'syn-prose'
        'best-aesthetic' = 'syn-aesthetic'
    })
    Set-OrchestraProperty $syn 'hard_rules' @(
        [pscustomobject]@{
            id = 'image-gen-tool-only'
            when_tags_any = @('image_gen')
            primary_requires_tool = 'image_gen'
            locked = $true
        },
        [pscustomobject]@{
            id = 'frontend-aesthetic-gate'
            when_tags_any = @('frontend', 'ui', 'landing_page')
            pattern = 'aesthetic_gate'
            reviewer = 'best-aesthetic'
            reviewer_fallback = 'syn-prose'
            exclude_reviewer_from_primary = $true
            locked = $true
        },
        [pscustomobject]@{
            id = 'prose-polish-when-rigor-primary'
            when_primary_vendor = 'openai'
            when_tags_any = @('prose', 'essay', 'paper', 'copywriting', 'office', 'ppt')
            polisher = 'best-prose'
            locked = $false
        }
    )
    return (Copy-RTestFixture $syn)
}

function Add-SynCandidate {
    param($Registry)
    $candidate = Copy-RTestFixture (Get-RTestModel $Registry 'syn-prose')
    Set-OrchestraProperty $candidate 'id' 'syn-candidate'
    Set-OrchestraProperty $candidate 'display_name' 'Synthetic Candidate'
    Set-OrchestraProperty $candidate 'status' 'candidate'
    Set-OrchestraProperty $candidate 'escalation_only' $false
    Set-RTestScore $candidate 'prose' 8.5
    Set-RTestScore $candidate 'world_knowledge' 10
    Set-OrchestraProperty $Registry 'models' (@($Registry.models) + @($candidate))
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

    # =========================================================================
    # Part A: Live Registry Dynamic Invariants (Zero Hardcoded Model IDs)
    # =========================================================================
    $fixture = Read-JsonFile -Path $sourcePaths.Registry
    if ($null -eq $fixture) { throw 'Registry template was not found.' }
    $policyObj = Get-OrchestraProperty $fixture 'policy'
    $expectedEffort = [string](Get-OrchestraProperty $policyObj 'default_effort' 'high')

    $activeModels = @($fixture.models | Where-Object { [string]$_.status -eq 'active' })
    Assert-RTest ($activeModels.Count -ge 2) 'live registry has at least two active models'

    foreach ($profile in $activeModels) {
        $profId = [string]$profile.id
        $profTier = [string](Get-OrchestraProperty $profile 'tier' 'flagship')
        $profDefault = [string]$profile.invoke.default_effort
        $profSupported = @(Get-OrchestraArray $profile.invoke 'efforts' | ForEach-Object { [string]$_ })
        $validEffort = (
            ($profSupported -contains $profDefault) -and
            (
                ($profDefault -eq $expectedEffort) -or
                ($profTier -eq 'fast' -and $profDefault -eq 'xhigh')
            )
        )
        Assert-RTest (
            $validEffort -and
            -not [bool](Get-OrchestraProperty $profile 'escalation_only' $false)
        ) "active model $profId declares valid default effort ($profDefault) without escalation_only"

        if ([string]$profile.channel -eq 'codex' -and [bool](Get-OrchestraProperty $profile.invoke 'account_rotation' $false)) {
            Assert-RTest (
                [int](Get-OrchestraProperty $profile.invoke 'rotation_max_retries' -1) -ge 1 -and
                [double](Get-OrchestraProperty $profile.invoke 'rotation_wait_sec' -1) -ge 1 -and
                [double](Get-OrchestraProperty $profile.invoke 'exhausted_minutes' -1) -gt 0
            ) "codex model $profId declares valid Cockpit rotation policy"
        }
    }

    $bestRigor = Resolve-ModelId -Registry $fixture -Name 'best-rigor'
    $bestProse = Resolve-ModelId -Registry $fixture -Name 'best-prose'
    $bestAesthetic = Resolve-ModelId -Registry $fixture -Name 'best-aesthetic'
    $bestImage = Resolve-ModelId -Registry $fixture -Name 'best-image'
    Assert-RTest (
        -not [string]::IsNullOrWhiteSpace($bestRigor) -and
        -not [string]::IsNullOrWhiteSpace($bestProse) -and
        -not [string]::IsNullOrWhiteSpace($bestAesthetic) -and
        -not [string]::IsNullOrWhiteSpace($bestImage)
    ) 'core capability aliases resolve dynamically'

    Save-RTestFixture $fixture
    Set-RTestExhaustion

    $run = Invoke-RTest 'frontend,landing_page'
    $r = $run.Result
    Assert-RTest ($run.Exit -eq 0) 'live frontend exits 0'
    Assert-RTest ($r.pattern -eq 'aesthetic_gate') 'live frontend uses aesthetic_gate'
    Assert-RTest ($r.reviewer -eq $bestAesthetic) 'live frontend reviewer matches best-aesthetic'
    if ($activeModels.Count -ge 2) {
        Assert-RTest ($r.primary -ne $bestAesthetic) 'live frontend excludes aesthetic reviewer from primary'
    }
    Assert-RTest (
        ($r.primary -eq $bestProse -and $null -eq $r.polisher) -or
        ($r.polisher -eq $bestProse -or $null -eq $r.polisher)
    ) 'live frontend polisher is valid without duplicating primary'

    $run = Invoke-RTest 'image_gen'
    $imgPrimaryModel = Get-RTestModel $fixture ([string]$run.Result.primary)
    Assert-RTest (
        $run.Exit -eq 0 -and (@(Get-OrchestraArray $imgPrimaryModel 'tools') -contains 'image_gen')
    ) 'live image_gen selects a primary with image_gen tool'
    if ([string]$imgPrimaryModel.vendor -eq 'openai') {
        Assert-RTest ($run.Result.pattern -eq 'strength_delegation') 'live image_gen uses strength_delegation for openai primary'
    }

    $run = Invoke-RTest 'backend,concurrency'
    $backendPrimary = Get-RTestModel $fixture ([string]$run.Result.primary)
    Assert-RTest (
        $run.Exit -eq 0 -and
        [double]$backendPrimary.caps.backend.score -ge 9 -and
        [double]$backendPrimary.caps.code_rigor.score -ge 9 -and
        $run.Result.reviewer -ne $run.Result.primary -and
        $run.Result.self_review -eq $false
    ) 'live backend selects min_cap >= 9 primary and independent reviewer'

    foreach ($modeName in @('balanced', 'economy')) {
        $run = Invoke-RTest 'math' -ModeName $modeName
        $mathPrimary = Get-RTestModel $fixture ([string]$run.Result.primary)
        Assert-RTest (
            $run.Exit -eq 0 -and
            [double]$mathPrimary.caps.math.score -ge 9 -and
            $run.Result.reviewer -ne $run.Result.primary -and
            $run.Result.self_review -eq $false
        ) "live math primary and independent reviewer in $modeName"
        Assert-RTest (
            ($run.Result.reasons -join ' ') -match 'math >= 9'
        ) "live math min_cap reason in $modeName"
    }

    foreach ($tagText in @('prose,essay', 'prose', 'refactor')) {
        $run = Invoke-RTest $tagText
        Assert-RTest (
            $run.Exit -eq 0 -and
            -not [string]::IsNullOrWhiteSpace([string]$run.Result.primary) -and
            $run.Result.reviewer -ne $run.Result.primary -and
            $run.Result.self_review -eq $false
        ) "live $tagText selects distinct primary and reviewer"
    }

    Set-RTestExhaustion @($bestAesthetic)
    $run = Invoke-RTest 'frontend'
    Assert-RTest (
        $run.Exit -eq 0 -and
        $run.Result.blocked -eq $false -and
        -not [string]::IsNullOrWhiteSpace([string]$run.Result.reviewer) -and
        $run.Result.self_review -eq ($run.Result.primary -eq $run.Result.reviewer)
    ) 'live aesthetic fallback unblocks cleanly when best-aesthetic is exhausted'

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
    $imageProviders = @(
        $fixture.models |
            Where-Object { @(Get-OrchestraArray $_ 'tools') -contains 'image_gen' } |
            ForEach-Object { [string]$_.id }
    )
    if ($imageProviders.Count -gt 0) {
        $run = Invoke-RTest 'image_gen' -Excluded ($imageProviders -join ',')
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.blocked -eq $true
        ) 'tool requirement blocks when all eligible tool providers are excluded'
    }

    $stateBefore = Get-Content -LiteralPath $script:routePaths.State -Raw -Encoding UTF8
    $run = Invoke-RTest 'research'
    $stateAfter = Get-Content -LiteralPath $script:routePaths.State -Raw -Encoding UTF8
    Assert-RTest ($stateBefore -ceq $stateAfter) 'routing does not mutate state'

    # =========================================================================
    # Part B: Deterministic Synthetic 3-Model Fixture (Algorithmic Edge Cases)
    # =========================================================================
    $synBase = New-SyntheticFixture -TemplateRegistry $fixture
    try {
        # 1. Escalation-only fixture
        $caseRegistry = Copy-RTestFixture $synBase
        $escalationModel = Copy-RTestFixture (Get-RTestModel $caseRegistry 'syn-rigor')
        Set-OrchestraProperty $escalationModel 'id' 'syn-escalation'
        Set-OrchestraProperty $escalationModel 'display_name' 'Synthetic Escalation'
        Set-OrchestraProperty $escalationModel 'escalation_only' $true
        Set-OrchestraProperty $caseRegistry 'models' (@($caseRegistry.models) + @($escalationModel))
        Save-RTestFixture $caseRegistry
        Set-RTestExhaustion

        foreach ($tag in @('frontend', 'math', 'refactor', 'research')) {
            $run = Invoke-RTest $tag
            Assert-RTest (
                $run.Exit -eq 0 -and
                $run.Result.primary -ne 'syn-escalation' -and
                $run.Result.reviewer -ne 'syn-escalation' -and
                $run.Result.polisher -ne 'syn-escalation' -and
                @($run.Result.fallback) -notcontains 'syn-escalation'
            ) "escalation fixture is excluded without permission for $tag"
        }
        Set-RTestExhaustion @('syn-rigor')
        $run = Invoke-RTest 'math'
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.blocked -eq $true
        ) 'math blocks when only escalation satisfies min_cap'
        $run = Invoke-RTest 'math' -Escalate
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.primary -eq 'syn-escalation'
        ) 'AllowEscalation permits the explicit escalation fixture'
        $run = Invoke-RTest 'math' -Escalate -Excluded 'syn-escalation'
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.blocked -eq $true
        ) 'explicit exclusion still overrides escalation permission'

        # 2. Candidate restrictions & fallback eligibility
        Set-RTestExhaustion
        $caseRegistry = Copy-RTestFixture $synBase
        Add-SynCandidate $caseRegistry
        Save-RTestFixture $caseRegistry
        $run = Invoke-RTest 'prose'
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.primary -eq 'syn-prose' -and
            $run.Result.reviewer -eq 'syn-rigor' -and
            $run.Result.reviewer -ne 'syn-candidate'
        ) 'highest review_caps candidate cannot become reviewer'
        Assert-RTest (
            @($run.Result.fallback) -contains 'syn-candidate'
        ) 'candidate remains eligible for primary fallbacks'
        $candidateScore = Get-OrchestraProperty $run.Result.scores 'syn-candidate'
        Assert-RTest (
            $null -ne $candidateScore -and
            (Get-OrchestraProperty $candidateScore.penalties 'candidate' 0) -gt 0
        ) 'candidate retains its primary score penalty'

        # 3. Candidate reviewer alias falls back to active reviewer_fallback
        $caseRegistry = Copy-RTestFixture $synBase
        Add-SynCandidate $caseRegistry
        Set-OrchestraProperty $caseRegistry.aliases 'syn-reviewer-alias' 'syn-candidate'
        $rules = Get-OrchestraProperty $caseRegistry 'hard_rules' @()
        Set-OrchestraProperty $caseRegistry 'hard_rules' (@($rules) + @(
            [pscustomobject]@{
                id = 'test-candidate-reviewer'; when_tags_any = @('prose')
                reviewer = 'syn-reviewer-alias'; reviewer_fallback = 'syn-aesthetic'
                locked = $false
            }
        ))
        Save-RTestFixture $caseRegistry
        $run = Invoke-RTest 'prose'
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.primary -eq 'syn-prose' -and
            $run.Result.reviewer -eq 'syn-aesthetic'
        ) 'candidate reviewer alias uses its active rule fallback'

        # 4. Aesthetic candidate alias uses active fallback
        $caseRegistry = Copy-RTestFixture $synBase
        Add-SynCandidate $caseRegistry
        Set-OrchestraProperty $caseRegistry.aliases 'best-aesthetic' 'syn-candidate'
        Save-RTestFixture $caseRegistry
        $run = Invoke-RTest 'frontend,landing_page'
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.primary -eq 'syn-prose' -and
            $run.Result.reviewer -eq 'syn-prose' -and
            $run.Result.self_review -eq $true -and $run.Result.blocked -eq $false
        ) 'aesthetic candidate alias uses its active fallback'

        # 5. Candidate polisher alias reselects active polisher
        $caseRegistry = Copy-RTestFixture $synBase
        Add-SynCandidate $caseRegistry
        Set-OrchestraProperty $caseRegistry.aliases 'best-prose' 'syn-candidate'
        Save-RTestFixture $caseRegistry
        $run = Invoke-RTest 'prose'
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.primary -eq 'syn-prose' -and
            $run.Result.polisher -eq 'syn-aesthetic'
        ) 'candidate polisher alias reselects an active polisher'

        # 6. Vendor diversity 1.5-point inclusive threshold
        $caseRegistry = Copy-RTestFixture $synBase
        $sameVendorModel = Copy-RTestFixture (Get-RTestModel $caseRegistry 'syn-prose')
        Set-OrchestraProperty $sameVendorModel 'id' 'syn-same-vendor-reviewer'
        Set-OrchestraProperty $sameVendorModel 'display_name' 'Synthetic Same Vendor Reviewer'
        Set-OrchestraProperty $sameVendorModel 'status' 'active'
        Set-OrchestraProperty $sameVendorModel 'escalation_only' $false
        Set-RTestScore $sameVendorModel 'prose' 0
        Set-RTestScore $sameVendorModel 'world_knowledge' 9.5
        Set-OrchestraProperty $caseRegistry 'models' (@($caseRegistry.models) + @($sameVendorModel))
        Save-RTestFixture $caseRegistry
        $run = Invoke-RTest 'prose'
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.primary -eq 'syn-prose' -and
            $run.Result.reviewer -eq 'syn-rigor' -and
            ($run.Result.reasons -join ' ') -match 'vendor diversity'
        ) 'different vendor is preferred at the inclusive 1.5 gap'

        Set-RTestScore $sameVendorModel 'world_knowledge' 9.6
        Save-RTestFixture $caseRegistry
        $run = Invoke-RTest 'prose'
        Assert-RTest (
            $run.Exit -eq 0 -and $run.Result.primary -eq 'syn-prose' -and
            $run.Result.reviewer -eq 'syn-same-vendor-reviewer'
        ) 'vendor preference does not exceed the 1.5 gap'

        # 7. All-candidate registry allows primary while leaving review roles empty
        foreach ($caseModel in @($caseRegistry.models)) {
            Set-OrchestraProperty $caseModel 'status' 'candidate'
        }
        Save-RTestFixture $caseRegistry
        $run = Invoke-RTest 'prose'
        Assert-RTest (
            $run.Exit -eq 0 -and $null -ne $run.Result.primary -and
            $null -eq $run.Result.reviewer -and $null -eq $run.Result.polisher
        ) 'candidate primary is allowed while candidate review roles remain empty'

        # 8. Peak mode (zero quota/speed tax), auto xhigh effort boost, primary_disabled guard, and dual-draft metadata
        Set-RTestExhaustion
        $peakRegistry = Copy-RTestFixture $synBase
        $modesObj = Get-OrchestraProperty $peakRegistry 'modes'
        Set-OrchestraProperty $modesObj 'peak' ([pscustomobject]@{ lambda_q = 0.0; lambda_s = 0.0 })
        $polObj = Get-OrchestraProperty $peakRegistry 'policy'
        Set-OrchestraProperty $polObj 'default_mode' 'peak'
        Set-OrchestraProperty $polObj 'peak_effort_tags' @('math')
        Set-OrchestraProperty $polObj 'dual_draft_tags' @('algorithm', 'concurrency', 'bugfix', 'math')
        $rigorModel = Get-RTestModel $peakRegistry 'syn-rigor'
        Set-OrchestraProperty $rigorModel.invoke 'efforts' @('low', 'medium', 'high', 'xhigh')
        Set-OrchestraProperty $rigorModel.invoke 'peak_effort' 'xhigh'
        $aesModel = Get-RTestModel $peakRegistry 'syn-aesthetic'
        Set-OrchestraProperty $aesModel 'primary_disabled' $true
        Save-RTestFixture $peakRegistry

        $defaultModeExec = Invoke-OrchestraProcess -FilePath $engine -Arguments @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $root 'scripts\route.ps1'),
            '-RegistryPath', $script:routePaths.Registry,
            '-StateDir', $script:routePaths.StateDir,
            '-Tags', 'bugfix'
        ) -WorkDir $temp -TimeoutSec 60 -CaptureStdout
        $defaultOutLines = @($defaultModeExec.stdout | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $defaultPeakRes = [string]$defaultOutLines[0] | ConvertFrom-Json
        Assert-RTest (
            $defaultModeExec.exit_code -eq 0 -and
            $defaultPeakRes.mode -eq 'peak' -and
            $defaultPeakRes.primary -eq 'syn-rigor' -and
            $defaultPeakRes.primary_effort -eq 'high' -and
            $defaultPeakRes.orchestration.replan_circuit_breaker -eq $true -and
            $defaultPeakRes.orchestration.dual_draft_eligible -eq $true -and
            $defaultPeakRes.orchestration.co_drafter -eq 'syn-prose'
        ) 'default peak mode selects highest raw cap at fast high effort on routine bugfix'

        $mathPeakRun = Invoke-RTest 'math' -ModeName 'peak'
        $escalatedBugfixRun = Invoke-RTest 'bugfix' -ModeName 'peak' -Escalate
        Assert-RTest (
            $mathPeakRun.Exit -eq 0 -and
            $mathPeakRun.Result.primary -eq 'syn-rigor' -and
            $mathPeakRun.Result.primary_effort -eq 'xhigh' -and
            $escalatedBugfixRun.Exit -eq 0 -and
            $escalatedBugfixRun.Result.primary_effort -eq 'xhigh'
        ) 'math tag or -AllowEscalation boosts rigor primary_effort to xhigh'

        $balancedBugfix = Invoke-RTest 'bugfix' -ModeName 'balanced'
        Assert-RTest (
            $balancedBugfix.Exit -eq 0 -and
            $balancedBugfix.Result.primary -eq 'syn-prose' -and
            $balancedBugfix.Result.primary_effort -eq 'high'
        ) 'legacy balanced mode retains quota/speed penalty behavior'

        Set-RTestExhaustion @('syn-rigor')
        $opusGuardRun = Invoke-RTest 'bugfix' -ModeName 'peak'
        Assert-RTest (
            $opusGuardRun.Exit -eq 0 -and
            $opusGuardRun.Result.primary -eq 'syn-prose' -and
            @($opusGuardRun.Result.fallback) -notcontains 'syn-aesthetic'
        ) 'primary_disabled prevents aesthetic model from becoming primary even when rigor is exhausted'

        # 9. fast_4h tier offload: 4H Extra (xhigh) absorbs routine Carbon tasks while high-bar & escalation retain Carbon
        Set-RTestExhaustion
        $fastRegistry = Copy-RTestFixture $synBase
        $fastModes = Get-OrchestraProperty $fastRegistry 'modes'
        Set-OrchestraProperty $fastModes 'fast_4h' ([pscustomobject]@{ lambda_q = 0.0; lambda_s = 0.2 })
        $fastPolicy = Get-OrchestraProperty $fastRegistry 'policy'
        Set-OrchestraProperty $fastPolicy 'dual_draft_tags' @('algorithm', 'concurrency', 'bugfix', 'math')
        Set-OrchestraProperty $fastPolicy 'fast_workhorse_map' ([pscustomobject]@{
            from_model = 'syn-prose'
            to_model = 'syn-fast'
            retain_primary_tags = @('paper', 'essay', 'copywriting')
            retain_reviewer_tags = @('math', 'algorithm')
            retain_polisher_tags = @('paper', 'essay', 'copywriting')
        })
        $synFastModel = Copy-RTestFixture (Get-RTestModel $fastRegistry 'syn-prose')
        Set-OrchestraProperty $synFastModel 'id' 'syn-fast'
        Set-OrchestraProperty $synFastModel 'display_name' 'Synthetic Fast 4H'
        Set-OrchestraProperty $synFastModel 'quota_rank' 3
        Set-OrchestraProperty $synFastModel 'speed_rank' 3
        Set-OrchestraProperty $synFastModel 'escalate_to' 'syn-prose'
        Set-OrchestraProperty $synFastModel.invoke 'model_flag' 'syn-fast-{effort}'
        Set-OrchestraProperty $synFastModel.invoke 'default_effort' 'xhigh'
        Set-OrchestraProperty $synFastModel.invoke 'efforts' @('low', 'medium', 'high', 'xhigh')
        Set-RTestScore $synFastModel 'code_rigor' 8.0
        Set-RTestScore $synFastModel 'backend' 8.0
        Set-RTestScore $synFastModel 'math' 8.0
        Set-RTestScore $synFastModel 'frontend_aesthetic' 7.5
        Set-RTestScore $synFastModel 'prose' 8.0
        Set-RTestScore $synFastModel 'world_knowledge' 8.5
        Set-RTestScore $synFastModel 'long_context' 9.5
        Set-RTestScore $synFastModel 'agentic_coding' 8.5
        $synProseRef = Get-RTestModel $fastRegistry 'syn-prose'
        Set-OrchestraProperty $synProseRef 'speed_rank' 2
        $synAestheticFastRef = Get-RTestModel $fastRegistry 'syn-aesthetic'
        # Mirror production aesthetic-gate reservation so bugfix co-drafting tests the Carbon -> 4H offload path.
        Set-OrchestraProperty $synAestheticFastRef 'primary_disabled' $true
        $synRigorFastRef = Get-RTestModel $fastRegistry 'syn-rigor'
        Set-OrchestraProperty $synRigorFastRef.invoke 'efforts' @('low', 'medium', 'high', 'xhigh')
        Set-OrchestraProperty $synRigorFastRef.invoke 'peak_effort' 'xhigh'
        Set-OrchestraProperty $fastRegistry 'models' (@($fastRegistry.models) + @($synFastModel))
        Save-RTestFixture $fastRegistry

        $fastFrontend = Invoke-RTest 'frontend,landing_page' -ModeName 'fast_4h'
        $fastResearch = Invoke-RTest 'research,long_context' -ModeName 'fast_4h'
        $fastPaper = Invoke-RTest 'prose,paper' -ModeName 'fast_4h'
        $fastBugfix = Invoke-RTest 'bugfix' -ModeName 'fast_4h'
        $fastMath = Invoke-RTest 'math,algorithm' -ModeName 'fast_4h'
        $fastEscResearch = Invoke-RTest 'research,long_context' -ModeName 'fast_4h' -Escalate
        $fastSwitchExec = Invoke-OrchestraProcess -FilePath $engine -Arguments @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $root 'scripts\route.ps1'),
            '-RegistryPath', $script:routePaths.Registry,
            '-StateDir', $script:routePaths.StateDir,
            '-Tags', 'prose', '-Fast4H'
        ) -WorkDir $temp -TimeoutSec 60 -CaptureStdout
        $fastSwitchRes = [string](@($fastSwitchExec.stdout | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })[0]) | ConvertFrom-Json

        Assert-RTest (
            $fastFrontend.Exit -eq 0 -and
            $fastFrontend.Result.primary -eq 'syn-fast' -and
            $fastFrontend.Result.primary_effort -eq 'xhigh' -and
            $fastFrontend.Result.reviewer -eq 'syn-aesthetic' -and
            $fastFrontend.Result.escalate_to -eq 'syn-prose' -and
            $null -eq $fastFrontend.Result.polisher -and
            [bool]$fastFrontend.Result.orchestration.fast_tier_offload -eq $true
        ) 'fast_4h offloads routine frontend draft to 4H Extra while keeping aesthetic gate'

        Assert-RTest (
            $fastResearch.Exit -eq 0 -and
            $fastResearch.Result.primary -eq 'syn-fast' -and
            $fastResearch.Result.primary_effort -eq 'xhigh' -and
            $fastSwitchExec.exit_code -eq 0 -and
            $fastSwitchRes.mode -eq 'fast_4h' -and
            $fastSwitchRes.primary -eq 'syn-fast'
        ) 'fast_4h and -Fast4H switch offload routine research and prose to 4H Extra'

        Assert-RTest (
            $fastPaper.Exit -eq 0 -and
            $fastPaper.Result.primary -eq 'syn-prose' -and
            $fastEscResearch.Exit -eq 0 -and
            $fastEscResearch.Result.primary -eq 'syn-prose'
        ) 'fast_4h retains Carbon for high-bar paper and AllowEscalation tasks'

        Assert-RTest (
            $fastBugfix.Exit -eq 0 -and
            $fastBugfix.Result.primary -eq 'syn-rigor' -and
            $fastBugfix.Result.reviewer -eq 'syn-fast' -and
            $fastBugfix.Result.orchestration.co_drafter -eq 'syn-fast' -and
            $fastMath.Exit -eq 0 -and
            $fastMath.Result.primary -eq 'syn-rigor' -and
            $fastMath.Result.primary_effort -eq 'xhigh' -and
            $fastMath.Result.reviewer -eq 'syn-prose'
        ) 'fast_4h keeps rigor primary while offloading routine bugfix review to 4H and math review to Carbon'

        # 10. Host-aware three-tier routing (-HostModel, orchestrator_fast, carbon_peak, hydrogen_max, mechanical high, final_reviewer)
        Set-RTestExhaustion
        $hostRegistry = Copy-RTestFixture $fastRegistry
        $hostModes = Get-OrchestraProperty $hostRegistry 'modes'
        Set-OrchestraProperty $hostModes 'orchestrator_fast' ([pscustomobject]@{ lambda_q = 0.0; lambda_s = 0.2 })
        Set-OrchestraProperty $hostModes 'carbon_peak' ([pscustomobject]@{ lambda_q = 0.0; lambda_s = 0.0 })
        Set-OrchestraProperty $hostModes 'hydrogen_max' ([pscustomobject]@{ lambda_q = 0.0; lambda_s = 0.25 })
        $hostPolicy = Get-OrchestraProperty $hostRegistry 'policy'
        Set-OrchestraProperty $hostPolicy 'host_mode_map' ([pscustomobject]@{
            orchestrator = 'orchestrator_fast'
            carbon = 'carbon_peak'
            hydrogen = 'hydrogen_max'
        })
        Set-OrchestraProperty $hostPolicy 'mechanical_fast_tags' @('bulk', 'boilerplate', 'scan', 'test_gen')
        Set-OrchestraProperty $hostPolicy 'carbon_peak_offload_tags' @('bulk', 'boilerplate', 'scan', 'test_gen')
        Set-OrchestraProperty $hostPolicy 'hydrogen_max_policy' ([pscustomobject]@{
            from_model = 'syn-prose'
            to_model = 'syn-fast'
            final_review_triggers = @('paper', 'essay', 'copywriting', 'architecture')
        })
        Set-OrchestraProperty $hostPolicy.fast_workhorse_map 'retain_primary_tags' @('paper', 'essay', 'copywriting', 'architecture')
        Set-OrchestraProperty $hostPolicy.fast_workhorse_map 'retain_reviewer_tags' @('math', 'algorithm', 'architecture')
        $synFastHostRef = Get-RTestModel $hostRegistry 'syn-fast'
        Set-OrchestraProperty $synFastHostRef 'tier' 'fast'
        $synRigorHostRef = Get-RTestModel $hostRegistry 'syn-rigor'
        Set-RTestScore $synRigorHostRef 'long_context' 9.0
        Save-RTestFixture $hostRegistry

        $hOrchFront = Invoke-RTest 'frontend,landing_page' -ModeName '' -HostModel 'Orchestrator (Carbon)'
        $hOrchArch = Invoke-RTest 'architecture' -ModeName '' -HostModel 'orchestrator'
        $hOrchPaper = Invoke-RTest 'prose,paper' -ModeName 'orchestrator_fast'
        $hOrchEsc = Invoke-RTest 'research,long_context' -ModeName 'orchestrator_fast' -Escalate
        Assert-RTest (
            $hOrchFront.Exit -eq 0 -and
            $hOrchFront.Result.mode -eq 'orchestrator_fast' -and
            $hOrchFront.Result.orchestration.host_mode -eq 'orchestrator_fast' -and
            $hOrchFront.Result.primary -eq 'syn-fast' -and
            $hOrchFront.Result.primary_effort -eq 'xhigh' -and
            $hOrchFront.Result.reviewer -eq 'syn-aesthetic' -and
            $null -eq $hOrchFront.Result.polisher -and
            $null -eq $hOrchFront.Result.orchestration.final_reviewer -and
            @($hOrchFront.Result.orchestration.final_review_triggers).Count -eq 0
        ) 'HostModel orchestrator resolves orchestrator_fast and offloads routine tasks to 4H Extra'
        Assert-RTest (
            $hOrchArch.Exit -eq 0 -and
            $hOrchArch.Result.primary -eq 'syn-rigor' -and
            $hOrchArch.Result.reviewer -eq 'syn-prose' -and
            $hOrchPaper.Exit -eq 0 -and
            $hOrchPaper.Result.primary -eq 'syn-prose' -and
            $hOrchEsc.Exit -eq 0 -and
            $hOrchEsc.Result.primary -eq 'syn-prose'
        ) 'orchestrator_fast retains Carbon for architecture, paper, and AllowEscalation'

        $hCarbNormal = Invoke-RTest 'frontend,landing_page' -ModeName '' -HostModel 'Gemini 4 Carbon'
        $hCarbMath = Invoke-RTest 'math' -ModeName 'carbon_peak'
        $hCarbBulk = Invoke-RTest 'bulk,scan' -ModeName 'carbon_peak'
        $hCarbBulkEsc = Invoke-RTest 'bulk,scan' -ModeName 'carbon_peak' -Escalate
        $hCarbCoDraft = Invoke-RTest 'bugfix,bulk' -ModeName 'carbon_peak'
        Assert-RTest (
            $hCarbNormal.Exit -eq 0 -and
            $hCarbNormal.Result.mode -eq 'carbon_peak' -and
            $hCarbNormal.Result.orchestration.host_mode -eq 'carbon_peak' -and
            $hCarbNormal.Result.primary -eq 'syn-prose' -and
            $hCarbNormal.Result.primary_effort -eq 'high' -and
            $hCarbNormal.Result.orchestration.fast_tier_offload -eq $false -and
            $hCarbMath.Exit -eq 0 -and
            $hCarbMath.Result.primary -eq 'syn-rigor' -and
            $hCarbMath.Result.primary_effort -eq 'xhigh'
        ) 'HostModel carbon resolves carbon_peak with flagship ownership and peak_effort on math'
        Assert-RTest (
            $hCarbBulk.Exit -eq 0 -and
            $hCarbBulk.Result.primary -eq 'syn-fast' -and
            $hCarbBulk.Result.primary_effort -eq 'high' -and
            $hCarbBulk.Result.orchestration.fast_tier_offload -eq $true -and
            $hCarbBulk.Result.reviewer -eq 'syn-rigor' -and
            $hCarbBulkEsc.Exit -eq 0 -and
            $hCarbBulkEsc.Result.primary -eq 'syn-prose' -and
            $hCarbCoDraft.Exit -eq 0 -and
            $hCarbCoDraft.Result.orchestration.co_drafter -eq 'syn-fast' -and
            $hCarbCoDraft.Result.orchestration.co_drafter_effort -eq 'high'
        ) 'carbon_peak offloads bulk,scan and mechanical co_drafter to 4H at high effort unless escalated'

        $hHydBug = Invoke-RTest 'bugfix' -ModeName '' -HostModel '4H Extra'
        $hHydScan = Invoke-RTest 'scan' -ModeName '' -HostModel 'hydrogen'
        $hHydTestGen = Invoke-RTest 'test_gen' -ModeName 'hydrogen_max'
        $hHydPaper = Invoke-RTest 'prose,paper' -ModeName 'hydrogen_max'
        $hHydArch = Invoke-RTest 'architecture' -ModeName 'hydrogen_max'
        $hHydProseArch = Invoke-RTest 'prose,architecture' -ModeName 'hydrogen_max'
        $hHydArchNoRigor = Invoke-RTest 'architecture' -ModeName 'hydrogen_max' -Excluded 'syn-rigor'
        $hHydFrontNoAes = Invoke-RTest 'frontend' -ModeName 'hydrogen_max' -Excluded 'syn-aesthetic'
        $hHydFrontOnlyGemini = Invoke-RTest 'frontend' -ModeName 'hydrogen_max' -Excluded 'syn-aesthetic,syn-rigor'
        $hHydFrontSolo = Invoke-RTest 'frontend' -ModeName 'hydrogen_max' -Excluded 'syn-aesthetic,syn-rigor,syn-prose'
        $hCarbSelfReview = Invoke-RTest 'frontend' -ModeName 'carbon_peak' -Excluded 'syn-aesthetic'
        $hHydPaperEsc = Invoke-RTest 'prose,paper' -ModeName 'hydrogen_max' -Escalate
        Assert-RTest (
            $hHydBug.Exit -eq 0 -and
            $hHydBug.Result.mode -eq 'hydrogen_max' -and
            $hHydBug.Result.orchestration.host_mode -eq 'hydrogen_max' -and
            $hHydBug.Result.primary -eq 'syn-rigor' -and
            $hHydBug.Result.reviewer -eq 'syn-fast' -and
            $hHydBug.Result.reviewer_effort -eq 'xhigh' -and
            $hHydBug.Result.orchestration.co_drafter -eq 'syn-fast' -and
            $null -eq $hHydBug.Result.orchestration.final_reviewer -and
            @($hHydBug.Result.orchestration.final_review_triggers) -contains 'paper'
        ) 'HostModel hydrogen/4H resolves hydrogen_max, offloads Carbon bugfix roles, and sets final_reviewer to null on normal tasks'
        Assert-RTest (
            $hHydScan.Exit -eq 0 -and
            $hHydScan.Result.mode -eq 'hydrogen_max' -and
            $hHydScan.Result.primary -eq 'syn-fast' -and
            $hHydScan.Result.primary_effort -eq 'high' -and
            $null -eq $hHydScan.Result.orchestration.final_reviewer -and
            $hHydTestGen.Exit -eq 0 -and
            $hHydTestGen.Result.reviewer -eq 'syn-fast' -and
            $hHydTestGen.Result.reviewer_effort -eq 'high'
        ) 'hydrogen_max runs mechanical scan/test_gen 4H primary and reviewer at high effort'
        Assert-RTest (
            $hHydPaper.Exit -eq 0 -and
            $hHydPaper.Result.primary -eq 'syn-fast' -and
            $hHydPaper.Result.primary_effort -eq 'xhigh' -and
            $null -eq $hHydPaper.Result.polisher -and
            $hHydPaper.Result.orchestration.final_reviewer -eq 'syn-prose' -and
            $hHydArch.Exit -eq 0 -and
            $hHydArch.Result.primary -eq 'syn-rigor' -and
            $hHydArch.Result.reviewer -eq 'syn-fast' -and
            $hHydArch.Result.orchestration.final_reviewer -eq 'syn-prose' -and
            $hHydProseArch.Exit -eq 0 -and
            $hHydProseArch.Result.primary -eq 'syn-prose' -and
            $null -eq $hHydProseArch.Result.orchestration.final_reviewer -and
            $hHydArchNoRigor.Exit -eq 0 -and
            $hHydArchNoRigor.Result.primary -eq 'syn-prose' -and
            $null -eq $hHydArchNoRigor.Result.orchestration.final_reviewer -and
            $hHydPaperEsc.Exit -eq 0 -and
            $hHydPaperEsc.Result.primary -eq 'syn-prose' -and
            $null -eq $hHydPaperEsc.Result.orchestration.final_reviewer
        ) 'hydrogen_max sets final_reviewer on final_review_triggers while honoring min_cap and avoiding self-review on Carbon primary'
        Assert-RTest (
            $hHydFrontNoAes.Exit -eq 0 -and
            $hHydFrontNoAes.Result.primary -eq 'syn-fast' -and
            $hHydFrontNoAes.Result.reviewer -eq 'syn-rigor' -and
            $hHydFrontNoAes.Result.self_review -eq $false -and
            $hHydFrontNoAes.Result.orchestration.active_verifier -eq $true -and
            $hHydFrontOnlyGemini.Exit -eq 0 -and
            $hHydFrontOnlyGemini.Result.primary -eq 'syn-fast' -and
            $hHydFrontOnlyGemini.Result.reviewer -eq 'syn-prose' -and
            $hHydFrontOnlyGemini.Result.self_review -eq $false -and
            $hHydFrontOnlyGemini.Result.orchestration.active_verifier -eq $true -and
            $hHydFrontSolo.Exit -eq 0 -and
            $hHydFrontSolo.Result.primary -eq 'syn-fast' -and
            $null -eq $hHydFrontSolo.Result.reviewer -and
            $hHydFrontSolo.Result.blocked -eq $true -and
            $hHydFrontSolo.Result.orchestration.active_verifier -eq $false -and
            $hCarbSelfReview.Exit -eq 0 -and
            $hCarbSelfReview.Result.primary -eq 'syn-prose' -and
            $hCarbSelfReview.Result.reviewer -eq 'syn-prose' -and
            $hCarbSelfReview.Result.self_review -eq $true -and
            $hCarbSelfReview.Result.orchestration.active_verifier -eq $false
        ) 'hydrogen_max avoids 4H self-review when aesthetic gate falls back and sets active_verifier false on self-review or blocked'

        # 11. Multi-pool concurrency load balancing (-BusyAgents, -PreferIdle, pool_load, scale_out_hint, parallel_lanes, live Slots)
        Set-RTestExhaustion
        Set-OrchestraProperty $hostPolicy 'pool_concurrency_limits' ([pscustomobject]@{
            codex_openai = 2
            agy_anthropic = 2
            agy_google = 6
        })
        Set-OrchestraProperty $hostPolicy 'default_mode' 'peak'
        Save-RTestFixture $hostRegistry

        $pFront = Invoke-RTest 'frontend,landing_page' -ModeName '' -HostModel 'orchestrator'
        $pFrontLanes = @($pFront.Result.orchestration.parallel_lanes)
        $pFrontPrim = @($pFrontLanes | Where-Object { $_.lane -eq 'critical_primary' }) | Select-Object -First 1
        $pFrontCodex = @($pFrontLanes | Where-Object { $_.role -eq 'parallel_assets_or_contract' }) | Select-Object -First 1
        $pFrontAes = @($pFrontLanes | Where-Object { $_.role -eq 'aesthetic_gate_tokens_and_viewport' }) | Select-Object -First 1
        Assert-RTest (
            $pFront.Exit -eq 0 -and
            $pFront.Result.orchestration.pool_load.total_active -eq 0 -and
            $pFront.Result.orchestration.pool_load.underutilized -eq $true -and
            $pFront.Result.orchestration.pool_load.pools.codex_openai.limit -eq 2 -and
            $pFront.Result.orchestration.pool_load.pools.agy_anthropic.limit -eq 2 -and
            $pFront.Result.orchestration.pool_load.pools.agy_google.limit -eq 6 -and
            ($pFront.Result.orchestration.scale_out_hint -like 'underutilized_capacity:*') -and
            $null -ne $pFrontPrim -and $pFrontPrim.model -eq 'syn-fast' -and $pFrontPrim.pool -eq 'agy_google' -and
            $null -ne $pFrontCodex -and $pFrontCodex.model -eq 'syn-rigor' -and $pFrontCodex.pool -eq 'codex_openai' -and
            $null -ne $pFrontAes -and $pFrontAes.model -eq 'syn-aesthetic' -and $pFrontAes.pool -eq 'agy_anthropic'
        ) 'frontend orchestrator emits pool_load, underutilized scale_out_hint, and 3-pool parallel_lanes'

        $pBug = Invoke-RTest 'bugfix' -ModeName 'peak'
        $pBugLanes = @($pBug.Result.orchestration.parallel_lanes)
        $pBugPrim = @($pBugLanes | Where-Object { $_.lane -eq 'critical_primary' }) | Select-Object -First 1
        $pBugFast = @($pBugLanes | Where-Object { $_.role -eq 'parallel_disjoint_tests_and_recon' }) | Select-Object -First 1
        $pBugRev = @($pBugLanes | Where-Object { $_.timing -eq 'T1_micro_slice_TDM_delta_review' }) | Select-Object -First 1
        Assert-RTest (
            $pBug.Exit -eq 0 -and
            $null -ne $pBugPrim -and $pBugPrim.model -eq 'syn-rigor' -and $pBugPrim.timing -eq 'T0_immediate_LPT' -and
            $null -ne $pBugFast -and $pBugFast.model -eq 'syn-fast' -and $pBugFast.pool -eq 'agy_google' -and
            $null -ne $pBugRev -and $pBugRev.model -eq 'syn-prose' -and ($pBugRev.scope -match 'tie-break')
        ) 'backend/bugfix emits LPT critical_primary, parallel fast Google tests lane, and TDM delta review lane'

        $pSatNoPref = Invoke-RTest 'bugfix' -ModeName 'peak' -BusyAgents 'syn-rigor,syn-rigor'
        $pSatBug = Invoke-RTest 'bugfix' -ModeName 'peak' -BusyAgents 'syn-rigor,syn-rigor' -PreferIdle
        $pSatMath = Invoke-RTest 'math' -ModeName 'peak' -BusyAgents 'syn-rigor,syn-rigor' -PreferIdle
        Assert-RTest (
            $pSatNoPref.Exit -eq 0 -and
            $pSatNoPref.Result.primary -eq 'syn-rigor' -and
            $pSatNoPref.Result.orchestration.pool_load.total_active -eq 2 -and
            $pSatNoPref.Result.orchestration.pool_load.underutilized -eq $false -and
            $pSatNoPref.Result.orchestration.pool_load.pools.codex_openai.available -eq 0 -and
            ($pSatNoPref.Result.orchestration.scale_out_hint -like 'codex_pool_saturated:*') -and
            $pSatBug.Exit -eq 0 -and
            $pSatBug.Result.primary -eq 'syn-prose' -and
            $pSatBug.Result.reviewer -eq 'syn-aesthetic' -and
            (($pSatBug.Result.reasons -join ' ') -match 'load_balance: shifted primary from saturated pool to idle pool') -and
            $pSatMath.Exit -eq 0 -and
            $pSatMath.Result.primary -eq 'syn-rigor'
        ) 'BusyAgents + PreferIdle shifts non-min_cap bugfix off saturated codex_openai while preserving math min_cap=9'

        $slotLease1 = $null
        $slotLease2 = $null
        try {
            $slotLease1 = Acquire-OrchestraPoolSlot -Paths $script:routePaths -Pool 'codex_openai' -Limit 2 -InvocationId 'route-slot-1' -ModelId 'syn-rigor' -Channel 'codex' -NoWait
            $slotLease2 = Acquire-OrchestraPoolSlot -Paths $script:routePaths -Pool 'codex_openai' -Limit 2 -InvocationId 'route-slot-2' -ModelId 'syn-rigor' -Channel 'codex' -NoWait
            $pLiveSlot = Invoke-RTest 'bugfix' -ModeName 'peak' -PreferIdle
            Assert-RTest (
                $pLiveSlot.Exit -eq 0 -and
                $pLiveSlot.Result.orchestration.pool_load.pools.codex_openai.active -eq 2 -and
                $pLiveSlot.Result.orchestration.pool_load.pools.codex_openai.available -eq 0 -and
                ($pLiveSlot.Result.orchestration.scale_out_hint -like 'codex_pool_saturated:*') -and
                $pLiveSlot.Result.primary -eq 'syn-prose'
            ) 'live Slots lease saturation triggers PreferIdle load balance without BusyAgents'
        }
        finally {
            if ($null -ne $slotLease1) {
                Release-OrchestraPoolSlot -Paths $script:routePaths -LeasePath $slotLease1.lease_path -InvocationId 'route-slot-1'
            }
            if ($null -ne $slotLease2) {
                Release-OrchestraPoolSlot -Paths $script:routePaths -LeasePath $slotLease2.lease_path -InvocationId 'route-slot-2'
            }
        }

        $noFastRegistry = Copy-RTestFixture $hostRegistry
        Set-OrchestraProperty $noFastRegistry 'models' @($noFastRegistry.models | Where-Object { [string]$_.id -ne 'syn-fast' })
        Save-RTestFixture $noFastRegistry
        $pNoFastShift = Invoke-RTest 'bugfix' -ModeName 'carbon_peak' -BusyAgents 'syn-rigor,syn-rigor' -PreferIdle
        Assert-RTest (
            $pNoFastShift.Exit -eq 0 -and
            $pNoFastShift.Result.primary -eq 'syn-prose' -and
            $pNoFastShift.Result.reviewer -eq 'syn-aesthetic'
        ) 'PreferIdle in carbon_peak handles missing fast workhorse ($fastToId=$null) without StrictMode crash'
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
