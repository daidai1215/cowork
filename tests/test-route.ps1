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
        Assert-RTest (
            [string]$profile.invoke.default_effort -eq $expectedEffort -and
            -not [bool](Get-OrchestraProperty $profile 'escalation_only' $false)
        ) "active model $profId defaults to $expectedEffort effort without escalation_only"

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
        Set-OrchestraProperty $polObj 'peak_effort_tags' @('math', 'concurrency', 'algorithm', 'bugfix')
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
            $defaultPeakRes.primary_effort -eq 'xhigh' -and
            $defaultPeakRes.orchestration.replan_circuit_breaker -eq $true -and
            $defaultPeakRes.orchestration.dual_draft_eligible -eq $true -and
            $defaultPeakRes.orchestration.co_drafter -eq 'syn-prose'
        ) 'default peak mode selects highest raw cap with xhigh boost and co_drafter on bugfix'

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
