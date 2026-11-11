<#
.SYNOPSIS
Run isolated, model-ID-agnostic probe dry-run, rubric de-spoiling, and blind grading tests.
#>
[CmdletBinding()]
param([string]$RegistryPath, [string]$StateDir)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $root 'scripts\lib\common.ps1')

$script:probePassed = 0
$script:probeFailures = New-Object 'System.Collections.Generic.List[string]'
$testDirectory = $null
$testParent = $null
$testPaths = $null
$oldAgy = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER')
$oldCodex = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_CODEX')
$oldNow = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_NOW')

function Assert-PTest {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:probePassed++ }
    else { [void]$script:probeFailures.Add($Name) }
}

function Invoke-PTestPlan {
    param(
        [string]$Name,
        [string]$Question = '',
        [string]$Channel = '',
        [string]$ModelFlag = '',
        [string]$ProbeDir = ''
    )
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $root 'scripts\probe-model.ps1'),
        '-DryRun', '-ModelId', $Name,
        '-RegistryPath', $testPaths.Registry, '-StateDir', $testPaths.StateDir
    )
    if (-not [string]::IsNullOrWhiteSpace($Question)) {
        $arguments += @('-Only', $Question)
    }
    if (-not [string]::IsNullOrWhiteSpace($Channel)) {
        $arguments += @('-Channel', $Channel)
    }
    if (-not [string]::IsNullOrWhiteSpace($ModelFlag)) {
        $arguments += @('-ModelFlag', $ModelFlag)
    }
    if (-not [string]::IsNullOrWhiteSpace($ProbeDir)) {
        $arguments += @('-ProbeDir', $ProbeDir)
    }
    $child = Invoke-OrchestraProcess -FilePath 'powershell.exe' `
        -Arguments $arguments -WorkDir $root -TimeoutSec 45 -CaptureStdout
    if ($child.timeout -or $child.truncated) {
        throw 'Probe dry-run process timed out or output was truncated.'
    }
    $lines = @($child.stdout | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    if ($lines.Count -ne 1) {
        throw "Probe dry-run emitted $($lines.Count) nonempty stdout lines."
    }
    $result = [string]$lines[0] | ConvertFrom-Json
    return [pscustomobject]@{ Exit = [int]$child.exit_code; Result = $result }
}

function New-ProbeSyntheticRegistry {
    param($Template)
    $dims = @($Template.cap_dimensions | ForEach-Object { [string]$_ })
    $copy = (ConvertTo-Json -InputObject $Template -Depth 32 | ConvertFrom-Json)
    function Make-Caps([double]$DefaultScore) {
        $c = [ordered]@{}
        foreach ($d in $dims) {
            $c[$d] = [ordered]@{
                score = $DefaultScore
                approved_score = $DefaultScore
                source = 'public'
                locked = $false
                confidence = 0.7
                evidence = @()
            }
        }
        return ([pscustomobject]$c)
    }
    $models = @(
        [pscustomobject]@{
            id = 'alpha-codex'
            display_name = 'Alpha Codex'
            vendor = 'openai'
            family = 'openai-alpha'
            generation = '1'
            tier = 'flagship'
            status = 'active'
            channel = 'codex'
            invoke = [pscustomobject]@{
                model_flag = 'alpha-codex'
                default_effort = 'high'
                efforts = @('low', 'medium', 'high')
            }
            tools = @('image_gen')
            quota_rank = 2
            speed_rank = 1
            ranks_locked = $false
            escalation_only = $false
            escalate_to = $null
            fallback = @('beta-agy')
            caps = (Make-Caps 9.0)
        },
        [pscustomobject]@{
            id = 'beta-agy'
            display_name = 'Beta Agy'
            vendor = 'google'
            family = 'google-beta'
            generation = '1'
            tier = 'flagship'
            status = 'active'
            channel = 'agy'
            invoke = [pscustomobject]@{
                model_flag = 'beta-agy-{effort}'
                default_effort = 'high'
                efforts = @('low', 'medium', 'high')
            }
            tools = @('web_search')
            quota_rank = 3
            speed_rank = 3
            ranks_locked = $false
            escalation_only = $false
            escalate_to = $null
            fallback = @('alpha-codex')
            caps = (Make-Caps 8.5)
        },
        [pscustomobject]@{
            id = 'gamma-agy'
            display_name = 'Gamma Agy'
            vendor = 'anthropic'
            family = 'anthropic-gamma'
            generation = '1'
            tier = 'flagship'
            status = 'active'
            channel = 'agy'
            invoke = [pscustomobject]@{
                model_flag = 'gamma-agy-{effort}'
                default_effort = 'high'
                efforts = @('low', 'medium', 'high')
            }
            tools = @('web_search')
            quota_rank = 1
            speed_rank = 2
            ranks_locked = $false
            escalation_only = $false
            escalate_to = $null
            fallback = @('beta-agy')
            caps = (Make-Caps 9.5)
        },
        [pscustomobject]@{
            id = 'beta-next'
            display_name = 'Beta Next Candidate'
            vendor = 'google'
            family = 'google-beta'
            generation = '2'
            tier = 'flagship'
            status = 'candidate'
            channel = 'agy'
            invoke = [pscustomobject]@{
                model_flag = 'beta-next-{effort}'
                default_effort = 'high'
                efforts = @('low', 'medium', 'high')
            }
            tools = @('web_search')
            quota_rank = 3
            speed_rank = 3
            ranks_locked = $false
            escalation_only = $false
            escalate_to = $null
            fallback = @('beta-agy')
            caps = (Make-Caps 7.0)
        }
    )
    Set-OrchestraProperty $copy 'models' $models
    Set-OrchestraProperty $copy 'aliases' ([pscustomobject]@{
        'best-rigor' = 'alpha-codex'
        'best-math' = 'alpha-codex'
        'best-image' = 'alpha-codex'
        'best-prose' = 'beta-agy'
        'best-knowledge' = 'beta-agy'
        'best-aesthetic' = 'gamma-agy'
    })
    return $copy
}

try {
    $env:MODEL_ORCHESTRA_NOW = '2026-11-10T12:00:00Z'
    $sourcePaths = Get-OrchestraPaths -RegistryPath $RegistryPath -StateDir $null
    $testParent = $StateDir
    if ([string]::IsNullOrWhiteSpace($testParent)) {
        $testParent = [IO.Path]::GetTempPath()
    }
    $testParent = [IO.Path]::GetFullPath($testParent)
    $testDirectory = Join-Path $testParent (
        'model-orchestra-probe-test-' + [Guid]::NewGuid().ToString('N')
    )
    $null = [IO.Directory]::CreateDirectory($testDirectory)
    $testPaths = Get-OrchestraPaths `
        -RegistryPath (Join-Path $testDirectory 'registry\models.json') `
        -StateDir (Join-Path $testDirectory 'state')
    $null = [IO.Directory]::CreateDirectory($testPaths.RegistryDir)
    $null = [IO.File]::Copy($sourcePaths.Registry, $testPaths.Registry, $false)
    $registryBefore = [IO.File]::ReadAllText($testPaths.Registry, $script:OrchestraUtf8)

    $liveReg = Read-JsonFile -Path $testPaths.Registry
    $activeModels = @($liveReg.models | Where-Object { [string]$_.status -eq 'active' })
    Assert-PTest ($activeModels.Count -ge 1) 'Registry contains at least one active model for probe planning'
    $activeId = [string]$activeModels[0].id

    $expectedFiles = @(
        '01-code-rigor.md', '02-math.md', '03-prose.md',
        '04-frontend-aesthetic.md', '05-world-knowledge.md'
    )
    foreach ($name in $expectedFiles) {
        $file = Join-Path $root ('evals\probe\' + $name)
        $exists = [IO.File]::Exists($file)
        Assert-PTest $exists ('Probe exists: ' + $name)
        $nonempty = $false
        if ($exists) {
            $text = [IO.File]::ReadAllText($file, $script:OrchestraUtf8)
            $nonempty = -not [string]::IsNullOrWhiteSpace($text)
        }
        Assert-PTest $nonempty ('Probe is nonempty: ' + $name)
    }

    # 1. Dynamic dry-run checks
    $run = Invoke-PTestPlan -Name $activeId
    Assert-PTest ($run.Exit -eq 0) 'Full dry-run exits 0'
    $plans = @(Get-OrchestraArray $run.Result 'planned')
    Assert-PTest ($plans.Count -eq 5) 'Full dry-run returns five planned probes'
    Assert-PTest ([bool]$plans[0].rubric_stripped) 'Planned probes mark rubric_stripped=true'
    $answers = @(Get-OrchestraArray $run.Result 'results')
    Assert-PTest ($answers.Count -eq 0) 'Dry-run has no invocation results'
    Assert-PTest ((Get-OrchestraProperty $run.Result 'model') -eq $activeId) 'Dry-run reports canonical model ID'

    $run = Invoke-PTestPlan -Name $activeId -Question '2'
    Assert-PTest ($run.Exit -eq 0) 'Only 2 exits 0'
    $plans = @(Get-OrchestraArray $run.Result 'planned')
    Assert-PTest ($plans.Count -eq 1 -and $plans[0].probe -eq '02-math.md') 'Only 2 selects 02-math.md'

    $unknown = 'unknown-probe-model-' + [Guid]::NewGuid().ToString('N')
    $run = Invoke-PTestPlan -Name $unknown
    Assert-PTest ($run.Exit -ne 0) 'Unknown model without channel exits nonzero'

    $aliasNames = @(Get-OrchestraNames (Get-OrchestraProperty $liveReg 'aliases'))
    if ($aliasNames.Count -gt 0) {
        $alias = [string]$aliasNames[0]
        $expectedId = Resolve-ModelId -Registry $liveReg -Name $alias
        $run = Invoke-PTestPlan -Name $alias -Question '2'
        Assert-PTest (
            $run.Exit -eq 0 -and (Get-OrchestraProperty $run.Result 'model') -eq $expectedId
        ) 'Model aliases resolve in probe plans'
    }

    # 2. AdHoc agy & codex effort defaults (both must default to high!)
    $run = Invoke-PTestPlan -Name 'unregistered-probe-9' -Channel 'agy'
    $plans = @(Get-OrchestraArray $run.Result 'planned')
    Assert-PTest (
        $run.Exit -eq 0 -and $plans.Count -eq 5 -and
        @($plans | Where-Object {
            $_.ad_hoc -ne $true -or $_.channel -ne 'agy' -or
            $_.model_flag -ne 'unregistered-probe-9-high' -or $_.effort -ne 'high'
        }).Count -eq 0
    ) 'Unregistered agy model plans five probes at high effort'

    $runCodexAdHoc = Invoke-PTestPlan -Name 'unregistered-codex-7' -Channel 'codex'
    $codexPlans = @(Get-OrchestraArray $runCodexAdHoc.Result 'planned')
    Assert-PTest (
        $runCodexAdHoc.Exit -eq 0 -and $codexPlans.Count -eq 5 -and
        $codexPlans[0].effort -eq 'high' -and $codexPlans[0].channel -eq 'codex'
    ) 'Unregistered codex model defaults to high effort (not xhigh)'

    $run = Invoke-PTestPlan -Name 'unregistered-probe-9' -Channel 'agy' -ModelFlag 'unregistered-probe-9-low'
    $plans = @(Get-OrchestraArray $run.Result 'planned')
    Assert-PTest (
        $run.Exit -eq 0 -and $plans[0].model_flag -eq 'unregistered-probe-9-low' -and $plans[0].effort -eq 'low'
    ) 'Explicit AdHoc slug retains its effort'

    $registryAfter = [IO.File]::ReadAllText($testPaths.Registry, $script:OrchestraUtf8)
    Assert-PTest ($registryBefore -ceq $registryAfter) 'Dry-runs preserve the registry'
    Assert-PTest (-not [IO.Directory]::Exists($testPaths.StateDir)) 'Dry-runs do not create runtime state'

    # 3. Fail-closed check when a probe file lacks 'Scoring by ..., 15 points:'
    $badProbeDir = Join-Path $testDirectory 'bad-probes'
    [void][IO.Directory]::CreateDirectory($badProbeDir)
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $root 'evals\probe') -Filter '0*.md' -File)) {
        [IO.File]::Copy($f.FullName, (Join-Path $badProbeDir $f.Name), $true)
    }
    [IO.File]::WriteAllText((Join-Path $badProbeDir '01-code-rigor.md'), "Task without scoring header.`nRubric text.", $script:OrchestraUtf8)
    $badRun = Invoke-PTestPlan -Name $activeId -ProbeDir $badProbeDir
    Assert-PTest ($badRun.Exit -ne 0) 'Malformed probe missing Scoring rubric boundary fails closed'

    # 4. Offline execution: Rubric de-spoiling, cross-vendor blind judge, fatal cap <= 5.0, proposals
    $synDir = Join-Path $testDirectory 'syn'
    $synPaths = Get-OrchestraPaths `
        -RegistryPath (Join-Path $synDir 'registry\models.json') `
        -StateDir (Join-Path $synDir 'state')
    [void][IO.Directory]::CreateDirectory($synPaths.RegistryDir)
    $synReg = New-ProbeSyntheticRegistry -Template $liveReg
    Write-JsonAtomic -Path $synPaths.Registry -Object $synReg

    $captureDir = Join-Path $testDirectory 'captures'
    [void][IO.Directory]::CreateDirectory($captureDir)
    $env:COWORK_TEST_CAPTURE_DIR = $captureDir

    $fakeAgy = Join-Path $testDirectory 'fake-agy.ps1'
    $fakeCodex = Join-Path $testDirectory 'fake-codex.ps1'

    $fakeAgyCode = @'
$capDir = $env:COWORK_TEST_CAPTURE_DIR
$modelVal = 'unknown'
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '--model' -and ($i + 1) -lt $args.Count) {
        $modelVal = [string]$args[$i + 1]
    }
}
$promptVal = [string]$args[$args.Count - 1]
$idx = @(Get-ChildItem -LiteralPath $capDir -Filter 'agy-*.txt' -ErrorAction SilentlyContinue).Count + 1
[IO.File]::WriteAllText((Join-Path $capDir ("agy-$idx-$modelVal.txt")), $promptVal, (New-Object Text.UTF8Encoding($false)))

if ($promptVal -match 'blind evaluator') {
    $resp = '{"parts":[4.5,4.5,4.5],"fatal_cap_triggered":false,"rationale":"Clear cross-vendor prose assessment."}'
}
else {
    $resp = 'Candidate prose memo response referencing March 7, 2027.'
}
$evt = @{
    event = 'result'
    result = @{
        status = 'SUCCESS'
        conversation_id = ('agy-sess-' + $idx)
        response = $resp
    }
} | ConvertTo-Json -Compress -Depth 10
[Console]::Out.WriteLine($evt)
exit 0
'@
    [IO.File]::WriteAllText($fakeAgy, $fakeAgyCode, $script:OrchestraUtf8)

    $fakeCodexCode = @'
if ($args.Count -gt 0 -and $args[0] -eq '--version') {
    [Console]::Out.WriteLine('codex-cli 0.188.0')
    exit 0
}
$capDir = $env:COWORK_TEST_CAPTURE_DIR
$outPath = $null
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq '-o' -and ($i + 1) -lt $args.Count) {
        $outPath = [string]$args[$i + 1]
    }
}
$stdinText = [Console]::In.ReadToEnd()
$idx = @(Get-ChildItem -LiteralPath $capDir -Filter 'codex-*.txt' -ErrorAction SilentlyContinue).Count + 1
[IO.File]::WriteAllText((Join-Path $capDir ("codex-$idx.txt")), $stdinText, (New-Object Text.UTF8Encoding($false)))

if ($stdinText -match 'blind evaluator') {
    $resp = '{"parts":[4,4,4],"fatal_cap_triggered":true,"rationale":"Invented quote triggered fatal rubric cap."}'
}
else {
    $resp = 'Candidate code rigor response.'
}
if (-not [string]::IsNullOrWhiteSpace($outPath)) {
    [IO.File]::WriteAllText($outPath, $resp, (New-Object Text.UTF8Encoding($false)))
}
[Console]::Out.WriteLine('{"type":"thread.started","thread_id":"codex-thread-1"}')
[Console]::Out.WriteLine('{"type":"turn.completed"}')
exit 0
'@
    [IO.File]::WriteAllText($fakeCodex, $fakeCodexCode, $script:OrchestraUtf8)

    $env:MODEL_ORCHESTRA_AGY_WRAPPER = $fakeAgy
    $env:MODEL_ORCHESTRA_CODEX = $fakeCodex

    $reportDir = Join-Path $testDirectory 'results'
    $gradeArgs = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $root 'scripts\probe-model.ps1'),
        '-ModelId', 'beta-next', '-Only', '1,3',
        '-Grade', '-EmitProposals',
        '-ReportDir', $reportDir,
        '-RegistryPath', $synPaths.Registry,
        '-StateDir', $synPaths.StateDir
    )
    $execRun = Invoke-OrchestraProcess -FilePath 'powershell.exe' `
        -Arguments $gradeArgs -WorkDir $root -TimeoutSec 90 -CaptureStdout
    $execLines = @($execRun.stdout | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    Assert-PTest ($execRun.exit_code -eq 0 -and $execLines.Count -eq 1) 'Offline probe + blind grade exits 0 with 1 JSON line'

    if ($execLines.Count -eq 1) {
        $execJson = [string]$execLines[0] | ConvertFrom-Json
        $resItems = @(Get-OrchestraArray $execJson 'results')
        Assert-PTest ($resItems.Count -eq 2) 'Two probes executed and returned'

        # Verify rubric de-spoiling on candidate prompt for probe 3 (03-prose.md)
        $candCaptures = @(Get-ChildItem -LiteralPath $captureDir -Filter 'agy-*-beta-next-high.txt' -File | Sort-Object Name)
        Assert-PTest ($candCaptures.Count -eq 2) 'Candidate beta-next received exactly two prompts'
        if ($candCaptures.Count -eq 2) {
            $proseCandidatePrompt = [IO.File]::ReadAllText($candCaptures[1].FullName, $script:OrchestraUtf8)
            Assert-PTest (
                $proseCandidatePrompt -match 'Riverside Library' -and
                $proseCandidatePrompt -match 'March 7, 2027' -and
                $proseCandidatePrompt -notmatch 'Scoring by' -and
                $proseCandidatePrompt -notmatch 'calendar inconsistency'
            ) 'Candidate prompt preserves task facts while stripping Scoring rubric and trap hints'
        }

        # Verify fatal_cap_triggered <= 5.0 cap on probe 1 (judged by alpha-codex)
        $g1 = $resItems[0].grade
        Assert-PTest (
            $g1.judge -eq 'alpha-codex' -and
            $g1.fatal_cap_triggered -eq $true -and
            [double]$g1.total_15 -eq 5.0 -and
            [double]$g1.cap_score_10 -eq 3.3
        ) 'Fatal cap rule caps 12/15 raw sum to 5.0/15 (3.3/10) locally in PowerShell'

        # Verify cross-vendor judge selection on probe 3 (best-prose is beta-agy [google], same vendor as beta-next [google]!)
        $g3 = $resItems[1].grade
        Assert-PTest (
            $g3.judge -ne 'beta-next' -and
            $g3.judge -ne 'beta-agy' -and
            $g3.judge -eq 'gamma-agy' -and
            [double]$g3.total_15 -eq 13.5 -and
            [double]$g3.cap_score_10 -eq 9.0
        ) 'Blind judge skips same-vendor best-prose alias and selects cross-vendor gamma-agy'

        # Verify anonymous judge prompt does not leak candidate model ID
        $judgeCaptures = @(Get-ChildItem -LiteralPath $captureDir -Filter 'agy-*-gamma-agy-high.txt' -File)
        Assert-PTest ($judgeCaptures.Count -eq 1) 'Cross-vendor judge gamma-agy invoked once'
        if ($judgeCaptures.Count -eq 1) {
            $judgePromptText = [IO.File]::ReadAllText($judgeCaptures[0].FullName, $script:OrchestraUtf8)
            Assert-PTest ($judgePromptText -notmatch 'beta-next') 'Blind judge prompt is anonymous and omits candidate ID'
        }

        # Verify JSON report and proposals
        $jsonReportPath = [string](Get-OrchestraProperty $execJson 'json_report' '')
        Assert-PTest (-not [string]::IsNullOrWhiteSpace($jsonReportPath) -and [IO.File]::Exists($jsonReportPath)) 'Structured JSON grade report created'

        $createdProps = @(Get-OrchestraArray $execJson 'proposals')
        Assert-PTest ($createdProps.Count -eq 2) 'EmitProposals wrote two probe capability proposals'

        # Re-run to verify Test-PendingProposalConflict deduplication
        $execRun2 = Invoke-OrchestraProcess -FilePath 'powershell.exe' `
            -Arguments $gradeArgs -WorkDir $root -TimeoutSec 90 -CaptureStdout
        $execJson2 = ([string](@($execRun2.stdout | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })[-1])) | ConvertFrom-Json
        Assert-PTest (
            @(Get-OrchestraArray $execJson2 'proposals').Count -eq 0 -and
            [int](Get-OrchestraProperty $execJson2 'skipped_conflicts' 0) -eq 2
        ) 'Repeated probe run deduplicates conflicting pending proposals'

        # Verify apply-research.ps1 -Approve accepts probe proposal cleanly
        if ($createdProps.Count -ge 1) {
            $appRun = Invoke-OrchestraProcess -FilePath 'powershell.exe' -Arguments @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', (Join-Path $root 'scripts\apply-research.ps1'),
                '-Approve', [string]$createdProps[0],
                '-RegistryPath', $synPaths.Registry,
                '-StateDir', $synPaths.StateDir
            ) -WorkDir $root -TimeoutSec 45 -CaptureStdout
            $updatedSyn = Read-JsonFile -Path $synPaths.Registry
            $updatedNext = @($updatedSyn.models | Where-Object { $_.id -eq 'beta-next' })[0]
            Assert-PTest (
                $appRun.exit_code -eq 0 -and
                [double]$updatedNext.caps.code_rigor.score -eq 3.3 -and
                [string]$updatedNext.caps.code_rigor.source -eq 'probe'
            ) 'apply-research.ps1 -Approve cleanly applies probe proposal'
        }
    }
}
catch {
    [void]$script:probeFailures.Add('Harness: ' + $_.Exception.Message)
}
finally {
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER', $oldAgy, 'Process')
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX', $oldCodex, 'Process')
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_NOW', $oldNow, 'Process')
    [Environment]::SetEnvironmentVariable('COWORK_TEST_CAPTURE_DIR', $null, 'Process')
    if ($null -ne $testDirectory -and [IO.Directory]::Exists($testDirectory)) {
        try {
            $absolute = [IO.Path]::GetFullPath($testDirectory)
            $parentPrefix = $testParent.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            $leaf = [IO.Path]::GetFileName($absolute)
            if (-not $absolute.StartsWith($parentPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                $leaf -notmatch '^model-orchestra-probe-test-[a-f0-9]{32}$') {
                throw 'Refusing cleanup outside the unique test directory.'
            }
            $null = [IO.Directory]::Delete($absolute, $true)
        }
        catch {
            [void]$script:probeFailures.Add('Cleanup: ' + $_.Exception.Message)
        }
    }
}
Write-OrchestraResult -Object @{
    suite = 'probe'; passed = $script:probePassed
    failed = $script:probeFailures.Count; failures = $script:probeFailures.ToArray()
}
if ($script:probeFailures.Count -gt 0) { exit 1 }
exit 0
