[CmdletBinding()]
param([string]$RegistryPath, [string]$StateDir)

. (Join-Path $PSScriptRoot '..\scripts\lib\common.ps1')
$script:Passed = 0
$script:Failed = 0
$script:Failures = New-Object 'System.Collections.Generic.List[string]'
$sandbox = $null
$parentDirectory = $null
$environmentNames = @(
    'MODEL_ORCHESTRA_AGY_WRAPPER', 'MODEL_ORCHESTRA_NOW',
    'MODEL_ORCHESTRA_CODEX', 'MODEL_ORCHESTRA_CODEX_HOME',
    'MODEL_ORCHESTRA_ROTATION_WAIT_MS', 'MODEL_ORCHESTRA_PROXY',
    'MODEL_ORCHESTRA_SKIP_PROXY_PRECHECK'
)
$savedEnvironment = @{}
foreach ($name in $environmentNames) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}

function Assert-Test {
    param([string]$Name, [bool]$Condition)
    if ($Condition) { $script:Passed++ }
    else {
        $script:Failed++
        [void]$script:Failures.Add($Name)
    }
}

function Invoke-TestScript {
    param([string]$Script, [string[]]$Arguments)
    $callArguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Script
    ) + $Arguments
    $execution = Invoke-OrchestraProcess -FilePath $script:TestHost `
        -Arguments $callArguments -WorkDir $sandbox -TimeoutSec 60 -CaptureStdout
    $objects = @(foreach ($line in $execution.stdout) {
        try { $line | ConvertFrom-Json } catch {}
    })
    $lastObject = $null
    if ($objects.Count -gt 0) { $lastObject = $objects[$objects.Count - 1] }
    return @{
        code = $execution.exit_code; json = $lastObject
        events = $objects; stderr = $execution.stderr
    }
}

function New-TestModel {
    param(
        [string]$Id, [string]$Channel, [string]$Status = 'active',
        [bool]$Locked = $false
    )
    $caps = [ordered]@{}
    foreach ($dimension in $script:Dimensions) {
        $caps[$dimension] = [ordered]@{
            score = 8; approved_score = 8; source = 'public'; locked = $Locked
            confidence = $(if ($Locked) { 0.8 } else { 0.7 })
        }
    }
    $flag = $Id
    $efforts = @('low', 'medium', 'high', 'xhigh')
    if ($Channel -eq 'agy') {
        $flag = $Id + '-{effort}'
        $efforts = @('low', 'medium', 'high')
    }
    $invocation = [pscustomobject]@{
        model_flag = $flag; default_effort = 'high'; efforts = $efforts
    }
    if ($Id -eq 'gpt-6-astra') {
        Set-OrchestraProperty $invocation 'account_rotation' $true
        Set-OrchestraProperty $invocation 'rotation_max_retries' 2
        Set-OrchestraProperty $invocation 'rotation_wait_sec' 10
        Set-OrchestraProperty $invocation 'exhausted_minutes' 30
    }
    return [pscustomobject]@{
        id = $Id; channel = $Channel; status = $Status
        escalation_only = $false; invoke = $invocation
        caps = [pscustomobject]$caps
    }
}

function Add-TestInvocation {
    param(
        [string]$Id, [string]$ModelId, [string[]]$InvocationTags,
        [string]$Session = ''
    )
    Add-UsageEvent -Paths $script:TestPaths -Event @{
        type = 'invocation'; invocation_id = $Id
        ts = (Get-OrchestraNow).ToString('o')
        model = $ModelId; channel = 'codex'; tags = $InvocationTags
        access = 'read'; duration_sec = 0.1; exit = 0
        quota_error = $false; session_id = $Session
    }
}

function Get-TestHistoryCount {
    if (-not [IO.Directory]::Exists($script:TestPaths.History)) { return 0 }
    return [IO.Directory]::GetFiles($script:TestPaths.History, 'models-*.json').Length
}

function Get-TestRegistryBytes {
    return [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixtureRegistry))
}

function Invoke-CodexCase {
    param([string]$Case, [string]$ResumeId = '', [switch]$MissingAuth)
    $caseRoot = Join-Path $sandbox (
        'codex-' + $Case + '-' + [Guid]::NewGuid().ToString('N')
    )
    $caseHome = Join-Path $caseRoot 'home'
    [void][IO.Directory]::CreateDirectory($caseHome)
    if (-not $MissingAuth) {
        [IO.File]::WriteAllBytes(
            (Join-Path $caseHome 'auth.json'),
            $script:OrchestraUtf8.GetBytes('{"fixture":"synthetic-auth-a"}')
        )
    }
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX_HOME', $caseHome)
    $casePaths = Get-OrchestraPaths -RegistryPath $fixtureRegistry `
        -StateDir (Join-Path $caseRoot 'state')
    $caseArguments = @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $casePaths.StateDir,
        '-WorkDir', $sandbox, '-Model', 'gpt-6-astra', '-Prompt', $Case
    )
    if (-not [string]::IsNullOrWhiteSpace($ResumeId)) {
        $caseArguments += @('-Resume', $ResumeId)
    }
    $run = Invoke-TestScript -Script $invokeScript -Arguments $caseArguments
    return @{ run = $run; paths = $casePaths; home = $caseHome }
}

function Assert-CodexUsage {
    param($CaseResult, [string]$Name)
    $run = $CaseResult.run
    $events = @(Read-UsageEvents -Paths $CaseResult.paths)
    Assert-Test ($Name + ' logs one final invocation') (
        $events.Count -eq 1 -and $events[0].type -eq 'invocation' -and
        $events[0].invocation_id -eq $run.json.invocation_id -and
        $events[0].attempts -eq $run.json.attempts -and
        $events[0].account_switched -eq $run.json.account_switched -and
        $events[0].resume_invalidated -eq $run.json.resume_invalidated -and
        $events[0].quota_error -eq $run.json.quota_error -and
        $events[0].exit -eq $run.code
    )
}

function Assert-NoAstraExhaustion {
    param($CaseResult, [string]$Name)
    $state = Read-State -Paths $CaseResult.paths
    Assert-Test $Name (
        $null -eq (Get-OrchestraProperty $state.exhausted 'gpt-6-astra')
    )
}

try {
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_NOW', '2026-11-10T12:00:00Z')
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX', $null)
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_ROTATION_WAIT_MS', '10')
    $parentDirectory = $StateDir
    if ([string]::IsNullOrWhiteSpace($parentDirectory)) {
        $parentDirectory = [IO.Path]::GetTempPath()
    }
    $parentDirectory = [IO.Path]::GetFullPath($parentDirectory)
    $sandbox = Join-Path $parentDirectory (
        'orchestra invoke tests ' + [Guid]::NewGuid().ToString('N')
    )
    [void][IO.Directory]::CreateDirectory($sandbox)
    $script:TestHost = Join-Path $PSHOME 'powershell.exe'
    if (-not [IO.File]::Exists($script:TestHost)) {
        $script:TestHost = Join-Path $PSHOME 'pwsh.exe'
    }
    if (-not [IO.File]::Exists($script:TestHost)) {
        throw 'Cannot locate the current PowerShell executable.'
    }
    $root = Resolve-Root
    $invokeScript = Join-Path $root 'scripts\invoke-model.ps1'
    $outcomeScript = Join-Path $root 'scripts\record-outcome.ps1'
    $fixtureRegistry = Join-Path $sandbox 'registry\models.json'
    $fixtureState = Join-Path $sandbox 'state'
    $script:TestPaths = Get-OrchestraPaths `
        -RegistryPath $fixtureRegistry -StateDir $fixtureState
    $script:Dimensions = @(
        'code_rigor', 'backend', 'math', 'image_gen', 'frontend_aesthetic',
        'prose', 'world_knowledge', 'long_context', 'agentic_coding', 'office_docs'
    )
    if (-not [string]::IsNullOrWhiteSpace($RegistryPath)) {
        $fixture = Read-JsonFile -Path $RegistryPath
        if ($null -eq $fixture) { throw 'Registry template was not found.' }
    }
    else {
        $fixture = [pscustomobject]@{
            schema_version = 1; registry_rev = 1; updated = '2026-11-10'
            cap_dimensions = $script:Dimensions; models = @()
            aliases = [pscustomobject]@{}
            tags = [pscustomobject]@{}
            policy = [pscustomobject]@{}
        }
    }
    $policy = Get-OrchestraProperty $fixture 'policy'
    if ($null -eq $policy) {
        $policy = [pscustomobject]@{}
        Set-OrchestraProperty $fixture 'policy' $policy
    }
    $testPolicy = @{
        redo_window_days = 30; promote_after_ok = 3
        promote_min_distinct_tags = 2; promote_max_bad = 1
        promote_min_confidence = 0.6; reject_after_consecutive_fail = 2
        exhausted_hours = 5
    }
    foreach ($key in $testPolicy.Keys) {
        Set-OrchestraProperty $policy $key $testPolicy[$key]
    }
    $testModels = @(
        New-TestModel 'gpt-6-astra' 'codex'
        New-TestModel 'gemini-4-carbon' 'agy'
        New-TestModel 'claude-opus-5-5' 'agy'
        New-TestModel 'candidate-good' 'codex' 'candidate'
        New-TestModel 'candidate-bad' 'codex' 'candidate'
        New-TestModel 'locked-test' 'codex' 'active' $true
    )
    $goodFixture = @($testModels | Where-Object { $_.id -eq 'candidate-good' })[0]
    Set-OrchestraProperty $goodFixture.caps.math 'confidence' 0.2
    Set-OrchestraProperty $fixture 'models' $testModels
    Set-OrchestraProperty $fixture 'cap_dimensions' $script:Dimensions
    Set-OrchestraProperty $fixture 'aliases' ([pscustomobject]@{
        'best-rigor' = 'gpt-6-astra'; 'best-math' = 'gpt-6-astra'
        'best-image' = 'gpt-6-astra'; 'best-prose' = 'gemini-4-carbon'
        'best-knowledge' = 'gemini-4-carbon'; 'best-aesthetic' = 'claude-opus-5-5'
    })
    $definitions = Get-OrchestraProperty $fixture 'tags'
    if ($null -eq $definitions) {
        $definitions = [pscustomobject]@{}
        Set-OrchestraProperty $fixture 'tags' $definitions
    }
    Set-OrchestraProperty $definitions 'backend' (
        [pscustomobject]@{ caps = @('backend', 'code_rigor') }
    )
    Set-OrchestraProperty $definitions 'math' ([pscustomobject]@{ caps = @('math') })
    Set-OrchestraProperty $definitions 'prose' ([pscustomobject]@{ caps = @('prose') })
    Write-JsonAtomic -Path $fixtureRegistry -Object $fixture
    $baseArguments = @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $fixtureState,
        '-WorkDir', $sandbox
    )

    foreach ($id in @('gpt-6-astra', 'gemini-4-carbon', 'claude-opus-5-5')) {
        $run = Invoke-TestScript -Script $invokeScript -Arguments (
            $baseArguments + @('-Model', $id, '-Prompt', 'TEST', '-DryRun')
        )
        Assert-Test "$id dry-run succeeds with high effort" (
            $run.code -eq 0 -and $run.json.model -eq $id -and
            $run.json.dry_run -eq $true -and $run.json.effort -eq 'high'
        )
        Assert-Test "$id dry-run uses ordinary attempt metadata" (
            $run.json.attempts -eq 1 -and -not $run.json.account_switched -and
            -not $run.json.resume_invalidated
        )
        $argv = @($run.json.arguments)
        if ($id -like 'gpt-*') {
            $modelIndex = [Array]::IndexOf($argv, '-m')
            Assert-Test "$id uses model flag and stdin" (
                $modelIndex -ge 0 -and $argv[$modelIndex + 1] -eq $id -and
                $argv[$argv.Count - 1] -eq '-' -and $run.json.stdin -eq 'TEST' -and
                $argv -contains 'model_reasoning_effort="high"'
            )
        }
        else {
            $modeIndex = [Array]::IndexOf($argv, '--mode')
            Assert-Test "$id uses wrapper plan mode" (
                $argv -contains '-File' -and $modeIndex -ge 0 -and
                $argv[$modeIndex + 1] -eq 'plan' -and
                $argv -contains ($id + '-high') -and $argv -notcontains '--sandbox'
            )
        }
    }
    foreach ($case in @(
        @{ Channel = 'agy'; Flag = 'unregistered-9-low'; Effort = 'low' },
        @{ Channel = 'codex'; Flag = 'unregistered-gpt-9'; Effort = 'high' }
    )) {
        $run = Invoke-TestScript -Script $invokeScript -Arguments (
            $baseArguments + @(
                '-AdHocChannel', $case.Channel, '-AdHocModelFlag', $case.Flag,
                '-Effort', $case.Effort, '-Prompt', 'TEST', '-DryRun'
            )
        )
        $argv = @($run.json.arguments)
        $flagName = '-m'
        if ($case.Channel -eq 'agy') { $flagName = '--model' }
        $flagIndex = [Array]::IndexOf($argv, $flagName)
        Assert-Test ('AdHoc DryRun passes exact slug: ' + $case.Channel) (
            $run.code -eq 0 -and $run.json.ad_hoc -eq $true -and
            $run.json.model -eq $case.Flag -and $flagIndex -ge 0 -and
            $argv[$flagIndex + 1] -eq $case.Flag
        )
    }

    $burstPath = Join-Path $sandbox 'burst.ps1'
    $burstText = @'
for ($i = 0; $i -lt 2000; $i++) {
    [Console]::Out.WriteLine(('out-{0}' -f $i))
    [Console]::Error.WriteLine(('err-{0}' -f $i))
}
exit 0
'@
    [IO.File]::WriteAllText($burstPath, $burstText, $script:OrchestraUtf8)
    $burst = Invoke-OrchestraProcess -FilePath $script:TestHost `
        -Arguments @('-NoProfile', '-File', $burstPath) `
        -WorkDir $sandbox -TimeoutSec 30 -CaptureStdout
    Assert-Test 'Burst drains all 2000 stdout and stderr lines through EOF' (
        $burst.exit_code -eq 0 -and -not $burst.timeout -and -not $burst.truncated -and
        $burst.stdout.Count -eq 2000 -and $burst.stderr.Count -eq 2000 -and
        $burst.stdout[1999] -ceq 'out-1999' -and $burst.stderr[1999] -ceq 'err-1999'
    )
    Assert-Test 'DryRun does not write state or usage' (
        -not [IO.File]::Exists($script:TestPaths.State) -and
        -not [IO.File]::Exists($script:TestPaths.Usage)
    )
    $aliasRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'best-aesthetic', '-Prompt', 'TEST', '-DryRun')
    )
    Assert-Test 'Alias resolves to Opus' (
        $aliasRun.code -eq 0 -and $aliasRun.json.model -eq 'claude-opus-5-5'
    )
    $resumeRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @(
            '-Model', 'gpt-6-astra', '-Prompt', 'TEST',
            '-Resume', 'explicit-session', '-DryRun'
        )
    )
    $resumeArgv = @($resumeRun.json.arguments)
    $resumeIndex = [Array]::IndexOf($resumeArgv, 'resume')
    Assert-Test 'Codex resume has explicit session and parent options' (
        $resumeRun.code -eq 0 -and $resumeIndex -gt 0 -and
        $resumeArgv[$resumeIndex + 1] -eq 'explicit-session' -and
        $resumeArgv[$resumeIndex + 2] -eq '-' -and
        [Array]::IndexOf($resumeArgv, '-C') -lt $resumeIndex -and
        $resumeArgv -notcontains '--last'
    )
    $invalidRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'does-not-exist', '-Prompt', 'TEST', '-DryRun')
    )
    Assert-Test 'Unknown model returns 2' ($invalidRun.code -eq 2)

    $wrapperPath = Join-Path $sandbox 'fake agy wrapper.ps1'
    $wrapperText = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$promptIndex = [Array]::IndexOf($args, '-p')
$case = ''
if ($promptIndex -ge 0) { $case = [string]$args[$promptIndex + 1] }
if ($case -eq 'TEST_AUTH') {
    [Console]::Error.WriteLine('You are not logged into Antigravity')
    exit 1
}
if ($case -eq 'TEST_TIMEOUT') {
    Start-Sleep -Seconds 10
    exit 0
}
if ($case -ne 'TEST_NO_INIT') {
    [Console]::WriteLine('{"event":"init","conversation_id":"mock-session","init":{"model":"mock"}}')
}
$result = [ordered]@{ status = 'SUCCESS'; response = $case }
if ($case -ne 'TEST_NO_INIT') { $result.conversation_id = 'mock-session' }
if ($case -eq 'TEST_SUCCESS') {
    $result.response = 'Successful prose mentioning quota and 429.'
}
if ($case -eq 'TEST_QUOTA') {
    $result.status = 'ERROR'
    $result.error = @{ code = 'insufficient_quota'; status = 429 }
    $result.response = 'Quota exhausted.'
}
[Console]::WriteLine((ConvertTo-Json -InputObject @{
    event = 'result'; result = $result
} -Depth 8 -Compress))
exit 0
'@
    [IO.File]::WriteAllText($wrapperPath, $wrapperText, $script:OrchestraUtf8)
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER', $wrapperPath)
    $answerPath = Join-Path $sandbox 'answer.txt'
    $successRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @(
            '-Model', 'gemini-4-carbon', '-Prompt', 'TEST_SUCCESS', '-OutFile', $answerPath
        )
    )
    Assert-Test 'Successful answer text does not trigger quota' (
        $successRun.code -eq 0 -and -not $successRun.json.quota_error -and
        $successRun.json.session_id -eq 'mock-session' -and
        $successRun.json.attempts -eq 1 -and
        -not $successRun.json.account_switched -and -not $successRun.json.resume_invalidated
    )
    Assert-Test 'Agy OutFile contains only final response' (
        [IO.File]::ReadAllText($answerPath, $script:OrchestraUtf8) -ceq
            'Successful prose mentioning quota and 429.'
    )
    $answerBytes = [IO.File]::ReadAllBytes($answerPath)
    Assert-Test 'OutFile has no UTF-8 BOM' (
        $answerBytes.Length -lt 3 -or
        -not ($answerBytes[0] -eq 239 -and $answerBytes[1] -eq 187 -and
            $answerBytes[2] -eq 191)
    )
    Assert-Test 'Provider events precede exactly one final result' (
        @($successRun.events | Where-Object {
            (Get-OrchestraProperty $_ 'orchestra_result' $false) -eq $true
        }).Count -eq 1 -and
        (Get-OrchestraProperty $successRun.events[0] 'event') -eq 'init' -and
        $successRun.json.orchestra_result -eq $true
    )
    $noInitRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gemini-4-carbon', '-Prompt', 'TEST_NO_INIT')
    )
    Assert-Test 'Missing session remains null' (
        $noInitRun.code -eq 0 -and $null -eq $noInitRun.json.session_id
    )
    $literalPrompt = 'quote " and trailing \ and dollars $literal'
    $literalPath = Join-Path $sandbox 'literal answer.txt'
    $literalRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @(
            '-Model', 'gemini-4-carbon', '-Prompt', $literalPrompt, '-OutFile', $literalPath
        )
    )
    Assert-Test 'Windows argv preserves literal prompt characters' (
        $literalRun.code -eq 0 -and
        [IO.File]::ReadAllText($literalPath, $script:OrchestraUtf8) -ceq $literalPrompt
    )
    $longPromptPath = Join-Path $sandbox 'long prompt.md'
    [IO.File]::WriteAllText($longPromptPath, ('x' * 25001), $script:OrchestraUtf8)
    $longRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @(
            '-Model', 'gemini-4-carbon', '-PromptFile', $longPromptPath, '-DryRun'
        )
    )
    Assert-Test 'Long agy prompt is planned as a temporary file' (
        $longRun.code -eq 0 -and $longRun.json.prompt_in_file -eq $true -and
        -not [IO.File]::Exists([string]$longRun.json.prompt_file)
    )

    $nestedError = [pscustomobject]@{
        type = 'error'
        message = '{"status":400,"error":{"code":"model_not_found","message":"model not supported"}}'
    }
    Assert-Test 'Nested model_not_found preserves model classification' (
        (Get-OrchestraErrorKind $nestedError) -eq 'model'
    )
    Assert-Test 'Structured status 429 is quota' (
        (Get-OrchestraErrorKind ([pscustomobject]@{ status = 429 })) -eq 'quota'
    )
    Assert-Test 'Auth remains external in the legacy classifier' (
        (Get-OrchestraErrorKind '401 Unauthorized') -eq 'external'
    )
    Assert-Test 'Resume mismatch remains external in the legacy classifier' (
        (Get-OrchestraErrorKind 'invalid_encrypted_content') -eq 'external'
    )
    foreach ($text in @(
        '401 Unauthorized', 'HTTP status 403', 'invalid_api_key',
        'token has expired', 'authentication failed'
    )) {
        Assert-Test ("Codex auth classification: $text") (
            (Get-OrchestraCodexInterruption $text) -eq 'auth'
        )
    }
    foreach ($text in @(
        'invalid_encrypted_content', 'cannot decrypt content', 'organization mismatch',
        'thread not found', 'conversation not found', 'session not found', 'rollout not found'
    )) {
        Assert-Test ("Codex resume classification: $text") (
            (Get-OrchestraCodexInterruption $text) -eq 'resume_incompatible'
        )
    }
    Assert-Test 'Nested resume incompatibility wins over auth' (
        (Get-OrchestraCodexInterruption ([pscustomobject]@{
            status = 401; error = @{ message = 'invalid_encrypted_content' }
        })) -eq 'resume_incompatible'
    )
    Assert-Test 'Numeric boundaries avoid incidental 4010 and 1403' (
        $null -eq (Get-OrchestraCodexInterruption '1403 4010')
    )

    $quotaRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gemini-4-carbon', '-Prompt', 'TEST_QUOTA')
    )
    $quotaState = Read-State -Paths $script:TestPaths
    $entry = Get-OrchestraProperty $quotaState.exhausted 'gemini-4-carbon'
    Assert-Test 'Agy quota uses five-hour policy without retry' (
        $quotaRun.code -eq 4 -and $quotaRun.json.quota_error -eq $true -and
        $quotaRun.json.attempts -eq 1 -and
        (ConvertTo-OrchestraUtc $entry.until) -eq (Get-OrchestraNow).AddHours(5)
    )
    $blockedRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @(
            '-Model', 'gemini-4-carbon', '-Prompt', 'TEST_SUCCESS', '-DryRun'
        )
    )
    Assert-Test 'Exhausted model is refused without fallback' (
        $blockedRun.code -eq 4 -and $blockedRun.json.model -eq 'gemini-4-carbon'
    )
    $stateBeforeAdHoc = [IO.File]::ReadAllText($script:TestPaths.State, $script:OrchestraUtf8)
    $adHocQuota = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @(
            '-AdHocChannel', 'agy', '-AdHocModelFlag', 'unregistered-9-low',
            '-Prompt', 'TEST_QUOTA'
        )
    )
    $stateAfterAdHoc = [IO.File]::ReadAllText($script:TestPaths.State, $script:OrchestraUtf8)
    Assert-Test 'AdHoc quota is reported without changing state' (
        $adHocQuota.code -eq 4 -and $adHocQuota.json.quota_error -eq $true -and
        $stateBeforeAdHoc -ceq $stateAfterAdHoc
    )
    $adHocEvents = @(Read-UsageEvents -Paths $script:TestPaths | Where-Object {
        (Get-OrchestraProperty $_ 'invocation_id') -eq $adHocQuota.json.invocation_id
    })
    Assert-Test 'AdHoc usage records the full slug and flag' (
        $adHocEvents.Count -eq 1 -and $adHocEvents[0].model -eq 'unregistered-9-low' -and
        $adHocEvents[0].ad_hoc -eq $true
    )
    $authRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'claude-opus-5-5', '-Prompt', 'TEST_AUTH')
    )
    Assert-Test 'Agy credential isolation returns 3 without retry' (
        $authRun.code -eq 3 -and $authRun.json.attempts -eq 1
    )
    $timeoutRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @(
            '-Model', 'claude-opus-5-5', '-Prompt', 'TEST_TIMEOUT', '-TimeoutSec', '1'
        )
    )
    Assert-Test 'Timeout returns 3 and timeout true' (
        $timeoutRun.code -eq 3 -and $timeoutRun.json.timeout -eq $true -and
        $timeoutRun.json.attempts -eq 1
    )

    $fakeCodexPath = Join-Path $sandbox 'fake codex.ps1'
    $fakeCodexText = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
if (@($args) -contains '--version') {
    [Console]::WriteLine('codex-cli 0.153.0')
    exit 0
}
$case = [Console]::In.ReadToEnd().Trim()
$caseHome = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_CODEX_HOME')
$countPath = Join-Path $caseHome 'attempt.count'
$count = 0
if ([IO.File]::Exists($countPath)) {
    $count = [int][IO.File]::ReadAllText($countPath)
}
$count++
[IO.File]::WriteAllText($countPath, [string]$count, $utf8)
$authPath = Join-Path $caseHome 'auth.json'
if ($count -eq 1 -and $case -in @(
    'QUOTA_SWITCH', 'CRASH_SWITCH', 'RESUME_AFTER_SWITCH', 'AUTH_APPEARS'
)) {
    $lockDir = Join-Path $caseHome '.cockpit-profile-mutation-locks'
    [void][IO.Directory]::CreateDirectory($lockDir)
    $lockPath = Join-Path $lockDir 'fixture.lock'
    [IO.File]::WriteAllBytes($lockPath, [byte[]]@(1))
    try {
        [IO.File]::WriteAllBytes(
            $authPath, $utf8.GetBytes('{"fixture":"synthetic-auth-b"}')
        )
        Start-Sleep -Milliseconds 10
    }
    finally { [IO.File]::Delete($lockPath) }
}
if ($case -eq 'AUTH_DISAPPEARS' -and $count -eq 1) {
    [IO.File]::Delete($authPath)
}
if ($case -eq 'RESUME_BAD') {
    [Console]::WriteLine('{"type":"turn.failed","error":{"code":"invalid_encrypted_content"}}')
    exit 1
}
if ($case -eq 'MODEL_BAD') {
    [Console]::WriteLine('{"type":"turn.failed","error":{"code":"model_not_found"}}')
    exit 1
}
if ($case -eq 'RESUME_AFTER_SWITCH' -and $count -ge 2) {
    [Console]::Error.WriteLine('stream closed without completion')
    exit 1
}
if ($case -eq 'ALL_QUOTA' -or
    ($count -eq 1 -and $case -in @('QUOTA_SWITCH', 'RESUME_AFTER_SWITCH', 'QUOTA_THEN_AUTH'))) {
    [Console]::WriteLine('{"type":"turn.failed","error":{"status":429,"code":"usage_limit"}}')
    exit 1
}
if ($case -eq 'QUOTA_THEN_AUTH' -or ($case -eq 'AUTH_ONCE' -and $count -eq 1)) {
    [Console]::Error.WriteLine('HTTP 401 Unauthorized')
    exit 1
}
if ($count -eq 1 -and $case -in @('CRASH_SWITCH', 'AUTH_APPEARS', 'AUTH_DISAPPEARS')) {
    [Console]::Error.WriteLine('stream disconnected')
    exit 17
}
if ($case -eq 'SUCCESS_TEXT') {
    [Console]::Error.WriteLine('Successful diagnostic about 429 quota and 401.')
    [Console]::WriteLine('{"type":"item.completed","item":{"type":"agent_message","text":"quota 429 invalid_encrypted_content"}}')
}
[Console]::WriteLine(('{"type":"thread.started","thread_id":"mock-codex-' + $count + '"}'))
[Console]::WriteLine('{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}')
exit 0
'@
    [IO.File]::WriteAllText($fakeCodexPath, $fakeCodexText, $script:OrchestraUtf8)
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX', $fakeCodexPath)

    $caseA = Invoke-CodexCase 'QUOTA_SWITCH'
    $run = $caseA.run
    Assert-Test 'Quota then Cockpit switch succeeds on attempt two' (
        $run.code -eq 0 -and $run.json.exit -eq 0 -and $run.json.attempts -eq 2 -and
        $run.json.account_switched -eq $true -and -not $run.json.quota_error -and
        -not $run.json.resume_invalidated -and $null -eq $run.json.error -and
        $run.json.session_id -eq 'mock-codex-2'
    )
    Assert-NoAstraExhaustion $caseA 'Recovered quota does not exhaust Astra'
    Assert-CodexUsage $caseA 'Recovered quota'
    Assert-Test 'Retries still produce exactly one final result' (
        @($run.events | Where-Object {
            (Get-OrchestraProperty $_ 'orchestra_result' $false) -eq $true
        }).Count -eq 1
    )

    $caseB = Invoke-CodexCase 'CRASH_SWITCH'
    $run = $caseB.run
    Assert-Test 'Nonzero incomplete attempt retries after fingerprint change' (
        $run.code -eq 0 -and $run.json.attempts -eq 2 -and
        $run.json.account_switched -eq $true -and -not $run.json.quota_error
    )
    Assert-NoAstraExhaustion $caseB 'Recovered stream interruption does not exhaust Astra'
    Assert-CodexUsage $caseB 'Recovered stream interruption'

    $caseC = Invoke-CodexCase 'ALL_QUOTA'
    $run = $caseC.run
    $quotaState = Read-State -Paths $caseC.paths
    $entry = Get-OrchestraProperty $quotaState.exhausted 'gpt-6-astra'
    Assert-Test 'Three quota attempts produce a thirty-minute exhaustion' (
        $run.code -eq 4 -and $run.json.exit -eq 4 -and $run.json.attempts -eq 3 -and
        $run.json.quota_error -eq $true -and -not $run.json.account_switched -and
        (ConvertTo-OrchestraUtc $entry.until) -eq (Get-OrchestraNow).AddMinutes(30)
    )
    Assert-CodexUsage $caseC 'All accounts exhausted'

    $caseD = Invoke-CodexCase 'RESUME_BAD' -ResumeId 'sid'
    $run = $caseD.run
    Assert-Test 'Incompatible resume stops on the first attempt' (
        $run.code -eq 3 -and $run.json.attempts -eq 1 -and
        $run.json.resume_invalidated -eq $true -and
        $run.json.error -ceq
            'Codex session cannot be resumed after Cockpit account switch; re-run without -Resume.'
    )
    Assert-NoAstraExhaustion $caseD 'Incompatible resume does not exhaust Astra'
    Assert-CodexUsage $caseD 'Incompatible resume'

    $caseE = Invoke-CodexCase 'RESUME_AFTER_SWITCH' -ResumeId 'sid'
    Assert-Test 'Resume stops after a switched retry fails generically' (
        $caseE.run.code -eq 3 -and $caseE.run.json.attempts -eq 2 -and
        $caseE.run.json.account_switched -and $caseE.run.json.resume_invalidated
    )
    Assert-NoAstraExhaustion $caseE 'Resume retry failure does not exhaust Astra'
    Assert-CodexUsage $caseE 'Switched resume'

    $caseF = Invoke-CodexCase 'ALL_QUOTA' -ResumeId 'sid'
    Assert-Test 'Resume with no switch retains normal quota retries' (
        $caseF.run.code -eq 4 -and $caseF.run.json.attempts -eq 3 -and
        -not $caseF.run.json.resume_invalidated
    )
    $caseG = Invoke-CodexCase 'QUOTA_THEN_AUTH'
    Assert-Test 'Earlier quota does not survive a terminal auth failure' (
        $caseG.run.code -eq 3 -and $caseG.run.json.attempts -eq 3 -and
        -not $caseG.run.json.quota_error
    )
    Assert-NoAstraExhaustion $caseG 'Terminal auth failure does not exhaust Astra'
    Assert-CodexUsage $caseG 'Terminal auth failure'

    $caseH = Invoke-CodexCase 'AUTH_ONCE'
    Assert-Test 'Auth interruption retries without requiring a fingerprint change' (
        $caseH.run.code -eq 0 -and $caseH.run.json.attempts -eq 2 -and
        -not $caseH.run.json.account_switched
    )
    $caseI = Invoke-CodexCase 'MODEL_BAD'
    Assert-Test 'Unsupported model never retries' (
        $caseI.run.code -eq 3 -and $caseI.run.json.attempts -eq 1
    )
    $caseJ = Invoke-CodexCase 'SUCCESS_TEXT'
    Assert-Test 'Successful stdout and stderr cannot trigger error classification' (
        $caseJ.run.code -eq 0 -and $caseJ.run.json.attempts -eq 1 -and
        -not $caseJ.run.json.quota_error -and -not $caseJ.run.json.resume_invalidated
    )
    $caseK = Invoke-CodexCase 'AUTH_APPEARS' -MissingAuth
    $caseL = Invoke-CodexCase 'AUTH_DISAPPEARS'
    foreach ($transition in @($caseK, $caseL)) {
        Assert-Test 'Auth file presence transition is a switch' (
            $transition.run.code -eq 0 -and $transition.run.json.attempts -eq 2 -and
            $transition.run.json.account_switched
        )
    }

    $quietHome = Join-Path $sandbox 'quiet home'
    [void][IO.Directory]::CreateDirectory($quietHome)
    $quietWatch = [Diagnostics.Stopwatch]::StartNew()
    $quietOutput = @(Wait-CockpitQuiet -CodexHome $quietHome -RotationWaitMs 10)
    $quietWatch.Stop()
    Assert-Test 'Missing lock directories return without sleep or pipeline output' (
        $quietOutput.Count -eq 0 -and $quietWatch.Elapsed.TotalMilliseconds -lt 1000
    )
    foreach ($lockName in @(
        '.cockpit-profile-mutation-locks', '.cockpit-token-locks'
    )) {
        $lockDirectory = Join-Path $quietHome $lockName
        [void][IO.Directory]::CreateDirectory($lockDirectory)
        $quietOutput = @(Wait-CockpitQuiet -CodexHome $quietHome -RotationWaitMs 10)
        Assert-Test "$lockName empty directory has no output" ($quietOutput.Count -eq 0)
        $lockPath = Join-Path $lockDirectory 'recent.lock'
        [IO.File]::WriteAllBytes($lockPath, [byte[]]@(1))
        $quietWatch.Restart()
        $quietOutput = @(Wait-CockpitQuiet -CodexHome $quietHome -RotationWaitMs 10)
        $quietWatch.Stop()
        Assert-Test "$lockName recent lock uses the bounded wait" (
            $quietOutput.Count -eq 0 -and
            $quietWatch.Elapsed.TotalMilliseconds -ge 170 -and
            $quietWatch.Elapsed.TotalMilliseconds -lt 1500
        )
        [IO.File]::SetLastWriteTimeUtc($lockPath, [DateTime]::UtcNow.AddSeconds(-20))
        $quietWatch.Restart()
        Wait-CockpitQuiet -CodexHome $quietHome -RotationWaitMs 10
        $quietWatch.Stop()
        Assert-Test "$lockName stale lock returns promptly" (
            $quietWatch.Elapsed.TotalMilliseconds -lt 1000
        )
        [IO.File]::Delete($lockPath)
    }
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX_HOME', $quietHome)
    Assert-Test 'Codex home override is honored' (
        (Get-OrchestraCodexHome) -eq [IO.Path]::GetFullPath($quietHome)
    )
    Assert-Test 'Missing auth fingerprint is null' (
        $null -eq (Get-CodexAuthFingerprint -CodexHome $quietHome)
    )
    $fingerprintPath = Join-Path $quietHome 'auth.json'
    [IO.File]::WriteAllBytes($fingerprintPath, [byte[]]@(1, 2, 3))
    $fingerprintA = Get-CodexAuthFingerprint -CodexHome $quietHome
    [IO.File]::WriteAllBytes($fingerprintPath, [byte[]]@(4, 5, 6))
    $fingerprintB = Get-CodexAuthFingerprint -CodexHome $quietHome
    Assert-Test 'Fingerprint accepts opaque bytes without JSON parsing' (
        $fingerprintA -match '^[a-f0-9]{64}$' -and
        $fingerprintB -match '^[a-f0-9]{64}$' -and $fingerprintA -ne $fingerprintB
    )
    $authHandle = [IO.File]::Open(
        $fingerprintPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
    $unreadableThrew = $false
    try {
        try { $null = Get-CodexAuthFingerprint -CodexHome $quietHome }
        catch { $unreadableThrew = $true }
    }
    finally { $authHandle.Dispose() }
    Assert-Test 'Unreadable auth is distinct from absent auth' $unreadableThrew
    foreach ($waitText in @('0', '10')) {
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_ROTATION_WAIT_MS', $waitText)
        Assert-Test "Wait override accepts $waitText" (
            (Get-OrchestraRotationWaitMs -Invoke @{ rotation_wait_sec = 10 }) -eq [int]$waitText
        )
    }
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_ROTATION_WAIT_MS', '-1')
    $invalidWaitThrew = $false
    try { $null = Get-OrchestraRotationWaitMs -Invoke @{} }
    catch { $invalidWaitThrew = $true }
    Assert-Test 'Negative wait override is rejected' $invalidWaitThrew
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_ROTATION_WAIT_MS', '10')

    $nowText = (Get-OrchestraNow).ToString('o')
    $oldText = (Get-OrchestraNow).AddDays(-31).ToString('o')
    $statEvents = @(
        [pscustomobject]@{
            type = 'invocation'; invocation_id = 'stats-a'
            ts = $nowText; model = 'stats-model'; tags = @('backend', 'math')
        },
        [pscustomobject]@{
            type = 'invocation'; invocation_id = 'stats-b'
            ts = $nowText; model = 'stats-model'; tags = @('prose')
        },
        [pscustomobject]@{
            type = 'invocation'; invocation_id = 'stats-old'
            ts = $oldText; model = 'stats-model'; tags = @('old')
        },
        [pscustomobject]@{
            type = 'invocation'; invocation_id = 'stats-a'
            ts = $nowText; model = 'stats-model'; tags = @('duplicate')
        },
        [pscustomobject]@{
            type = 'outcome'; invocation_id = 'stats-a'; ts = $nowText; outcome = 'fail'
        },
        [pscustomobject]@{
            type = 'outcome'; invocation_id = 'stats-a'; ts = $nowText; outcome = 'ok'
        },
        [pscustomobject]@{
            type = 'outcome'; invocation_id = 'stats-a'; ts = $nowText; outcome = 'ok'
        },
        [pscustomobject]@{
            type = 'outcome'; invocation_id = 'stats-b'; ts = $nowText; outcome = 'redo'
        },
        [pscustomobject]@{
            type = 'outcome'; invocation_id = 'stats-old'; ts = $nowText; outcome = 'ok'
        },
        [pscustomobject]@{
            type = 'outcome'; invocation_id = 'stats-orphan'; ts = $nowText; outcome = 'ok'
        }
    )
    $joinedStats = Get-OutcomeStats -Events $statEvents -ModelId 'stats-model' -WindowDays 30
    Assert-Test 'Latest outcomes and distinct invocation IDs control counts' (
        $joinedStats.n -eq 2 -and $joinedStats.ok_invocations -eq 1 -and
        $joinedStats.redo -eq 1 -and $joinedStats.fail -eq 0
    )
    Assert-Test 'Multiple tags remain separate and old tags are excluded' (
        @($joinedStats.ok_tags).Count -eq 2 -and 'backend' -in $joinedStats.ok_tags -and
        'math' -in $joinedStats.ok_tags -and 'old' -notin $joinedStats.ok_tags -and
        'duplicate' -notin $joinedStats.ok_tags
    )
    $mathStats = Get-OutcomeStats -Events $statEvents -ModelId 'stats-model' `
        -Tags @('math') -WindowDays 30
    Assert-Test 'Tag filter matches an individual tag in a multi-tag invocation' (
        $mathStats.n -eq 1 -and $mathStats.ok_invocations -eq 1
    )

    $outcomeBase = @('-RegistryPath', $fixtureRegistry, '-StateDir', $fixtureState)
    $registryBeforeOutcomes = Read-Registry -Paths $script:TestPaths
    $revisionBeforeOutcomes = [long]$registryBeforeOutcomes.registry_rev
    $bytesBeforeOutcomes = Get-TestRegistryBytes
    $goodBefore = @($registryBeforeOutcomes.models | Where-Object {
        $_.id -eq 'candidate-good'
    })[0]
    $capsBeforeOutcomes = ConvertTo-Json -InputObject $goodBefore.caps -Depth 32 -Compress
    foreach ($number in 1..3) {
        $tagsForInvocation = @('backend')
        if ($number -eq 3) { $tagsForInvocation = @('math') }
        Add-TestInvocation -Id "good-$number" -ModelId 'candidate-good' `
            -InvocationTags $tagsForInvocation -Session "good-session-$number"
        $outcomeRun = Invoke-TestScript -Script $outcomeScript -Arguments (
            $outcomeBase + @('-SessionId', "good-session-$number", '-Outcome', 'ok')
        )
        Assert-Test "Candidate outcome $number succeeds" ($outcomeRun.code -eq 0)
        if ($number -lt 3) {
            Assert-Test "Candidate is not promoted after $number successes" (
                $outcomeRun.json.status -eq 'candidate'
            )
            Assert-Test "Ordinary outcome $number does not write registry history" (
                (Get-TestRegistryBytes) -ceq $bytesBeforeOutcomes -and
                (Get-TestHistoryCount) -eq 0 -and
                -not [IO.File]::Exists($script:TestPaths.Changelog) -and
                $null -eq $outcomeRun.json.backup
            )
        }
    }
    Assert-Test 'Three distinct successes across two tags promote' (
        $outcomeRun.json.status -eq 'active' -and $outcomeRun.json.action -eq 'promoted' -and
        $outcomeRun.json.stats.ok_invocations -eq 3
    )
    Assert-Test 'Promotion creates a backup and changelog' (
        [IO.File]::Exists([string]$outcomeRun.json.backup) -and
        [IO.File]::Exists($script:TestPaths.Changelog)
    )
    $promotedRegistry = Read-Registry -Paths $script:TestPaths
    $promotedModel = @($promotedRegistry.models | Where-Object {
        $_.id -eq 'candidate-good'
    })[0]
    $capsAfterPromotion = ConvertTo-Json -InputObject $promotedModel.caps -Depth 32 -Compress
    Assert-Test 'Promotion uses average confidence and preserves every cap' (
        $promotedModel.status -eq 'active' -and $promotedModel.caps.math.confidence -eq 0.2 -and
        $capsAfterPromotion -ceq $capsBeforeOutcomes
    )
    Assert-Test 'Promotion writes exactly one registry revision and backup' (
        [long]$promotedRegistry.registry_rev -eq ($revisionBeforeOutcomes + 1) -and
        (Get-TestHistoryCount) -eq 1
    )
    $bytesAfterPromotion = Get-TestRegistryBytes
    $countBefore = @(Read-UsageEvents -Paths $script:TestPaths).Count
    $repeatRun = Invoke-TestScript -Script $outcomeScript -Arguments (
        $outcomeBase + @('-SessionId', 'good-session-3', '-Outcome', 'ok')
    )
    $countAfter = @(Read-UsageEvents -Paths $script:TestPaths).Count
    Assert-Test 'Repeated outcome is idempotent' (
        $repeatRun.code -eq 0 -and $repeatRun.json.appended -eq $false -and
        $countAfter -eq $countBefore
    )
    Assert-Test 'Repeated outcome does not rewrite the registry' (
        (Get-TestRegistryBytes) -ceq $bytesAfterPromotion -and (Get-TestHistoryCount) -eq 1
    )
    Invoke-WithLock -Paths $script:TestPaths -Name state -ScriptBlock {
        $fresh = Read-State -Paths $script:TestPaths
        Set-OrchestraProperty $fresh 'rejected_slugs' @('already-rejected')
        Save-State -Paths $script:TestPaths -State $fresh
    }
    foreach ($number in 1..2) {
        Add-TestInvocation -Id "bad-$number" -ModelId 'candidate-bad' `
            -InvocationTags @('backend') -Session "bad-session-$number"
        $badRun = Invoke-TestScript -Script $outcomeScript -Arguments (
            $outcomeBase + @('-SessionId', "bad-session-$number", '-Outcome', 'fail')
        )
        if ($number -eq 1) {
            Assert-Test 'First failure does not write registry history' (
                $badRun.code -eq 0 -and $badRun.json.status -eq 'candidate' -and
                (Get-TestRegistryBytes) -ceq $bytesAfterPromotion -and
                (Get-TestHistoryCount) -eq 1
            )
        }
    }
    Assert-Test 'Two distinct consecutive failures reject candidate' (
        $badRun.code -eq 0 -and $badRun.json.status -eq 'rejected'
    )
    $afterReject = Read-State -Paths $script:TestPaths
    Assert-Test 'Rejected candidate is persisted in state' (
        'candidate-bad' -in @($afterReject.rejected_slugs)
    )
    Assert-Test 'Rejected slugs remain flat and preserve existing entries' (
        @($afterReject.rejected_slugs).Count -eq 2 -and
        'already-rejected' -in $afterReject.rejected_slugs
    )
    $rejectedRegistry = Read-Registry -Paths $script:TestPaths
    Assert-Test 'Rejection writes exactly one further revision and backup' (
        [long]$rejectedRegistry.registry_rev -eq ($revisionBeforeOutcomes + 2) -and
        (Get-TestHistoryCount) -eq 2
    )
    $bytesAfterRejection = Get-TestRegistryBytes
    Add-TestInvocation -Id 'locked-1' -ModelId 'locked-test' `
        -InvocationTags @('backend') -Session 'locked-session'
    $lockedRun = Invoke-TestScript -Script $outcomeScript -Arguments (
        $outcomeBase + @('-Last', '-Outcome', 'fail', '-Note', 'test')
    )
    $afterRegistry = Read-Registry -Paths $script:TestPaths
    $lockedModel = @($afterRegistry.models | Where-Object { $_.id -eq 'locked-test' })[0]
    Assert-Test 'Last selects the last invocation' (
        $lockedRun.code -eq 0 -and $lockedRun.json.invocation_id -eq 'locked-1'
    )
    Assert-Test 'Locked capability score and confidence remain unchanged' (
        $lockedModel.caps.backend.score -eq 8 -and
        $lockedModel.caps.backend.approved_score -eq 8 -and
        $lockedModel.caps.backend.confidence -eq 0.8
    )
    Assert-Test 'Active-model outcome does not write registry history' (
        (Get-TestRegistryBytes) -ceq $bytesAfterRejection -and (Get-TestHistoryCount) -eq 2
    )
    $events = @(Read-UsageEvents -Paths $script:TestPaths)
    $badStats = Get-OutcomeStats -Events $events -ModelId 'candidate-bad'
    Assert-Test 'Outcome stats join by invocation_id' (
        $badStats.n -eq 2 -and $badStats.fail -eq 2 -and $badStats.consecutive_fail -eq 2
    )
    $usageLines = [IO.File]::ReadAllLines($script:TestPaths.Usage, $script:OrchestraUtf8)
    $allValid = $true
    foreach ($line in $usageLines) {
        try {
            $event = $line | ConvertFrom-Json
            if ($event.type -notin @('invocation', 'outcome')) { $allValid = $false }
        }
        catch { $allValid = $false }
    }
    Assert-Test 'Usage contains valid append-only event records' $allValid
    Assert-Test 'Custom paths keep registry history beside fixture registry' (
        [IO.Directory]::Exists(
            (Join-Path ([IO.Path]::GetDirectoryName($fixtureRegistry)) 'history')
        ) -and [IO.Directory]::Exists((Join-Path $fixtureState 'locks'))
    )

    # Peak effort auto-boost, pure-brain flags, proxy injection, handshake/reconnect watchdogs, heartbeat, and extract-files tests
    $peakReg = Read-JsonFile -Path $fixtureRegistry
    $peakPol = Get-OrchestraProperty $peakReg 'policy'
    Set-OrchestraProperty $peakPol 'peak_effort_tags' @('math')
    $astraFixture = @($peakReg.models | Where-Object { $_.id -eq 'gpt-6-astra' })[0]
    Set-OrchestraProperty $astraFixture.invoke 'peak_effort' 'xhigh'
    Set-OrchestraProperty $astraFixture.invoke 'connect_timeout_sec' 25
    Set-OrchestraProperty $astraFixture.invoke 'reconnect_abort_count' 2
    Write-JsonAtomic -Path $fixtureRegistry -Object $peakReg

    $boostRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gpt-6-astra', '-Tags', 'math,algorithm', '-Prompt', 'TEST', '-DryRun')
    )
    $boostArgs = @($boostRun.json.arguments)
    Assert-Test 'Peak math tag auto-boosts Astra effort to xhigh and enables pure-brain flags' (
        $boostRun.code -eq 0 -and $boostRun.json.effort -eq 'xhigh' -and
        $boostArgs -contains 'model_reasoning_effort="xhigh"' -and
        $boostArgs -contains 'unbounded_connection_retries' -and
        $boostArgs -contains 'shell_tool' -and
        $boostArgs -contains 'unified_exec' -and
        $boostRun.json.codex_shell_enabled -eq $false
    )
    $nonPeakRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gpt-6-astra', '-Tags', 'bugfix', '-Prompt', 'TEST', '-DryRun')
    )
    Assert-Test 'Routine bugfix tag preserves fast high effort' (
        $nonPeakRun.code -eq 0 -and $nonPeakRun.json.effort -eq 'high'
    )

    $subWorkDir = Join-Path $sandbox 'workdir-sub'
    $extScratchDir = Join-Path $sandbox 'external-scratch'
    [void][IO.Directory]::CreateDirectory($subWorkDir)
    [void][IO.Directory]::CreateDirectory($extScratchDir)
    $extOutFile = Join-Path $extScratchDir 'draft.md'
    $shellOptInRun = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $fixtureState,
        '-WorkDir', $subWorkDir, '-Model', 'gpt-6-astra',
        '-Prompt', 'TEST', '-OutFile', $extOutFile, '-AllowCodexShell', '-DryRun'
    )
    $shellOptInArgs = @($shellOptInRun.json.arguments)
    $addDirIdx = [Array]::IndexOf($shellOptInArgs, '--add-dir')
    Assert-Test 'AllowCodexShell re-enables shell tools and mounts external scratch via --add-dir' (
        $shellOptInRun.code -eq 0 -and
        $shellOptInRun.json.codex_shell_enabled -eq $true -and
        $shellOptInArgs -notcontains 'shell_tool' -and
        $addDirIdx -ge 0 -and
        $shellOptInArgs[$addDirIdx + 1] -ieq $extScratchDir
    )

    # Test local proxy precheck on an unused loopback port
    $ephemeralListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $ephemeralListener.Start()
    $closedPort = ([System.Net.IPEndPoint]$ephemeralListener.LocalEndpoint).Port
    $ephemeralListener.Stop()
    $deadProxyCheck = Test-OrchestraLocalProxy -ProxyUrl ("http://127.0.0.1:$closedPort") -TimeoutMs 600
    Assert-Test 'Test-OrchestraLocalProxy detects unreachable local proxy port quickly' (
        $deadProxyCheck.checked -eq $true -and $deadProxyCheck.reachable -eq $false
    )

    # Test Codex startup handshake timeout, reconnect storm abort, proxy env injection, and live heartbeat JSON
    $watchdogCodexPath = Join-Path $sandbox 'watchdog codex.ps1'
    $watchdogCodexText = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
if (@($args) -contains '--version') {
    [Console]::WriteLine('codex-cli 0.167.0')
    exit 0
}
$case = [Console]::In.ReadToEnd().Trim()
if ($case -eq 'HANG_BEFORE_FIRST_EVENT') {
    Start-Sleep -Seconds 15
    exit 0
}
if ($case -eq 'RECONNECT_STORM') {
    [Console]::Error.WriteLine('Reconnecting... 1/5 (stream disconnected before completion)')
    Start-Sleep -Milliseconds 150
    [Console]::Error.WriteLine('Reconnecting... 2/5 (stream disconnected before completion)')
    Start-Sleep -Seconds 15
    exit 1
}
$seenProxy = [string][Environment]::GetEnvironmentVariable('HTTPS_PROXY')
[Console]::WriteLine('{"type":"thread.started","thread_id":"live-hb-session"}')
[Console]::WriteLine('{"type":"item.started","item":{"type":"reasoning"}}')
[Console]::WriteLine(('{"type":"item.completed","item":{"type":"agent_message","text":"PROXY=' + $seenProxy + '"}}'))
[Console]::WriteLine('{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}')
exit 0
'@
    [IO.File]::WriteAllText($watchdogCodexPath, $watchdogCodexText, $script:OrchestraUtf8)
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX', $watchdogCodexPath)
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_PROXY', 'http://127.0.0.1:17900')

    $wdHome = Join-Path $sandbox 'wd-home'
    [void][IO.Directory]::CreateDirectory($wdHome)
    [IO.File]::WriteAllBytes((Join-Path $wdHome 'auth.json'), $script:OrchestraUtf8.GetBytes('{"fixture":"wd"}'))
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX_HOME', $wdHome)
    $wdState = Join-Path $sandbox 'wd-state'

    $hangWatch = [Diagnostics.Stopwatch]::StartNew()
    $hangRun = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $wdState,
        '-WorkDir', $sandbox, '-Model', 'gpt-6-astra',
        '-Prompt', 'HANG_BEFORE_FIRST_EVENT', '-ConnectTimeoutSec', '1', '-TimeoutSec', '20'
    )
    $hangWatch.Stop()
    Assert-Test 'Startup handshake timeout aborts silent connect hang within ConnectTimeoutSec' (
        $hangRun.code -eq 3 -and
        $hangRun.json.timeout -eq $true -and
        $hangRun.json.startup_timeout -eq $true -and
        $hangWatch.Elapsed.TotalSeconds -lt 8
    )

    $stormWatch = [Diagnostics.Stopwatch]::StartNew()
    $stormRun = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $wdState,
        '-WorkDir', $sandbox, '-Model', 'gpt-6-astra',
        '-Prompt', 'RECONNECT_STORM', '-TimeoutSec', '20'
    )
    $stormWatch.Stop()
    Assert-Test 'Reconnect storm circuit breaker aborts hung Codex retry loop early' (
        $stormRun.code -eq 3 -and
        $stormRun.json.reconnect_aborted -eq $true -and
        $stormWatch.Elapsed.TotalSeconds -lt 8
    )

    $hbOutPath = Join-Path $sandbox 'hb-out.txt'
    $hbRun = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $wdState,
        '-WorkDir', $sandbox, '-Model', 'gpt-6-astra',
        '-Prompt', 'PROXY_AND_HEARTBEAT_OK', '-OutFile', $hbOutPath
    )
    $latestCodexStatusPath = Join-Path $wdState 'live\latest-codex.json'
    $latestCodexStatus = Read-JsonFile -Path $latestCodexStatusPath
    Assert-Test 'Codex invocation injects dynamic proxy and writes live heartbeat JSON' (
        $hbRun.code -eq 0 -and
        $hbRun.json.proxy -eq 'http://127.0.0.1:17900' -and
        $null -ne $latestCodexStatus -and
        $latestCodexStatus.phase -eq 'completed' -and
        $latestCodexStatus.session_id -eq 'live-hb-session' -and
        $latestCodexStatus.proxy -eq 'http://127.0.0.1:17900'
    )
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_PROXY', $null)

    # Clear exhaustion state before testing live agy fake wrapper replan signal
    Invoke-WithLock -Paths $script:TestPaths -Name state -ScriptBlock {
        $stClean = Read-State -Paths $script:TestPaths
        Set-OrchestraProperty $stClean 'exhausted' ([pscustomobject]@{})
        Save-State -Paths $script:TestPaths -State $stClean
    }
    $replanPrompt = "=====ORCHESTRA_REPLAN_REQUIRED=====`ntrigger: signature mismatch`nevidence: expected foo(a,b), found foo(a)`n=====END ORCHESTRA_REPLAN_REQUIRED====="
    $replanRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gemini-4-carbon', '-Prompt', $replanPrompt)
    )
    Assert-Test 'Invoke detects ORCHESTRA_REPLAN_REQUIRED circuit breaker cleanly' (
        $replanRun.code -eq 0 -and
        $replanRun.json.replan_required -eq $true -and
        $replanRun.json.replan_detail -match 'signature mismatch'
    )

    $extractScript = Join-Path $root 'scripts\extract-files.ps1'
    $extractRoot = Join-Path $sandbox 'extract-root'
    [void][IO.Directory]::CreateDirectory($extractRoot)

    $replanPayloadPath = Join-Path $sandbox 'replan-out.md'
    $replanPayload = @(
        '=====FILE: src/auth/ok.txt====='
        'should not write'
        '=====END FILE====='
        '=====ORCHESTRA_REPLAN_REQUIRED====='
        'trigger: contract invalid'
        '=====END ORCHESTRA_REPLAN_REQUIRED====='
    ) -join "`r`n"
    [IO.File]::WriteAllText($replanPayloadPath, $replanPayload, $script:OrchestraUtf8)
    $extReplan = Invoke-OrchestraProcess -FilePath $script:TestHost -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $extractScript,
        '-InputFile', $replanPayloadPath, '-Root', $extractRoot, '-AllowedPrefixes', 'src/auth/'
    ) -WorkDir $sandbox -TimeoutSec 30 -CaptureStdout
    Assert-Test 'extract-files blocks writes with exit 3 on replan signal' (
        $extReplan.exit_code -eq 3 -and
        -not [IO.File]::Exists((Join-Path $extractRoot 'src\auth\ok.txt'))
    )

    $atomicPayloadPath = Join-Path $sandbox 'atomic-violation.md'
    $atomicPayload = @(
        '=====FILE: src/auth/allowed.txt====='
        'valid shard file'
        '=====END FILE====='
        '=====FILE: src/auth/secret/blocked.txt====='
        'touches forbidden prefix'
        '=====END FILE====='
    ) -join "`r`n"
    [IO.File]::WriteAllText($atomicPayloadPath, $atomicPayload, $script:OrchestraUtf8)
    $extAtomic = Invoke-OrchestraProcess -FilePath $script:TestHost -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $extractScript,
        '-InputFile', $atomicPayloadPath, '-Root', $extractRoot,
        '-AllowedPrefixes', 'src/auth/', '-ForbiddenPrefixes', 'src/auth/secret/'
    ) -WorkDir $sandbox -TimeoutSec 30 -CaptureStdout
    Assert-Test 'extract-files enforces all-or-nothing shard rollback on ForbiddenPrefixes' (
        $extAtomic.exit_code -eq 2 -and
        -not [IO.File]::Exists((Join-Path $extractRoot 'src\auth\allowed.txt')) -and
        -not [IO.File]::Exists((Join-Path $extractRoot 'src\auth\secret\blocked.txt'))
    )

    $cleanPayloadPath = Join-Path $sandbox 'clean-shard.md'
    $cleanPayload = @(
        '=====FILE: src/auth/allowed.txt====='
        'clean shard content'
        '=====END FILE====='
        '=====NOTES====='
        'shard ok'
    ) -join "`r`n"
    [IO.File]::WriteAllText($cleanPayloadPath, $cleanPayload, $script:OrchestraUtf8)
    $extClean = Invoke-OrchestraProcess -FilePath $script:TestHost -Arguments @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $extractScript,
        '-InputFile', $cleanPayloadPath, '-Root', $extractRoot,
        '-AllowedPrefixes', 'src/auth/', '-ForbiddenPrefixes', 'src/auth/secret/'
    ) -WorkDir $sandbox -TimeoutSec 30 -CaptureStdout
    Assert-Test 'extract-files writes valid shard files cleanly' (
        $extClean.exit_code -eq 0 -and
        [IO.File]::Exists((Join-Path $extractRoot 'src\auth\allowed.txt'))
    )
}
catch {
    $script:Failed++
    [void]$script:Failures.Add('Unhandled test error: ' + $_.Exception.Message)
}
finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
    }
    if ($null -ne $sandbox -and [IO.Directory]::Exists($sandbox)) {
        try {
            $resolved = [IO.Path]::GetFullPath($sandbox)
            $parentPrefix = $parentDirectory.TrimEnd(
                [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar
            ) + [IO.Path]::DirectorySeparatorChar
            $leaf = [IO.Path]::GetFileName($resolved)
            if (-not $resolved.StartsWith($parentPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                $leaf -notmatch '^orchestra invoke tests [a-f0-9]{32}$') {
                throw 'Refusing cleanup outside the unique test directory.'
            }
            [IO.Directory]::Delete($resolved, $true)
        }
        catch {
            $script:Failed++
            [void]$script:Failures.Add('Cleanup failed: ' + $_.Exception.Message)
        }
    }
}
Write-OrchestraResult -Object @{
    suite = 'invoke'; passed = $script:Passed; failed = $script:Failed
    failures = $script:Failures.ToArray()
}
if ($script:Failed -gt 0) { exit 1 }
exit 0
