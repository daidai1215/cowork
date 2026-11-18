[CmdletBinding()]
param([string]$RegistryPath, [string]$StateDir)

. (Join-Path $PSScriptRoot '..\scripts\lib\common.ps1')
$script:Passed = 0
$script:Failed = 0
$script:Failures = New-Object 'System.Collections.Generic.List[string]'
$sandbox = $null
$parentDirectory = $null
$environmentNames = @(
    'MODEL_ORCHESTRA_AGY_WRAPPER', 'MODEL_ORCHESTRA_AGY_EXE', 'AGY_EXEC_BIN',
    'MODEL_ORCHESTRA_NOW',
    'MODEL_ORCHESTRA_CODEX', 'MODEL_ORCHESTRA_CODEX_HOME',
    'MODEL_ORCHESTRA_ROTATION_WAIT_MS', 'MODEL_ORCHESTRA_PROXY',
    'MODEL_ORCHESTRA_SKIP_PROXY_PRECHECK', 'MODEL_ORCHESTRA_FAKE_ALIVE_PIDS',
    'MODEL_ORCHESTRA_TEST_STAGGER_MS',
    'HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy',
    'ALL_PROXY', 'all_proxy', 'NODE_USE_ENV_PROXY'
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
        events = $objects; stdout = $execution.stdout; stderr = $execution.stderr
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
        exhausted_hours = 5; ultra_fast_tags = @()
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
            $targetOk = if ($run.json.agy_direct_exe) {
                $run.json.executable -match 'agy(\.exe)?$' -and ($argv -notcontains '-File')
            }
            else {
                $argv -contains '-File'
            }
            Assert-Test "$id uses agy plan mode with slash commands disabled" (
                $targetOk -and $modeIndex -ge 0 -and
                $argv[$modeIndex + 1] -eq 'plan' -and
                $argv -contains ($id + '-high') -and $argv -notcontains '--sandbox' -and
                $argv -contains '--disable-slash-commands' -and
                $run.json.agy_slash_commands_disabled -eq $true
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
    $result.usage = @{
        input_tokens = 1200
        output_tokens = 300
        thinking_tokens = 80
        cache_read_tokens = 900
        total_tokens = 1580
    }
}
if ($case -eq 'TEST_ZERO_USAGE') {
    $result.usage = @{
        input_tokens = 0
        output_tokens = 10
        cache_read_tokens = 0
        total_tokens = 10
    }
}
if ($case -eq 'TEST_LARGE_INLINE') {
    $result.response = ('L' * 65000)
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
    $successStdoutLines = @($successRun.stdout | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $eventsFileExists = (-not [string]::IsNullOrWhiteSpace([string]$successRun.json.events_file)) -and [IO.File]::Exists([string]$successRun.json.events_file)
    $persistedEvents = @()
    if ($eventsFileExists) {
        $persistedEvents = @(
            [IO.File]::ReadAllLines([string]$successRun.json.events_file, $script:OrchestraUtf8) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_ | ConvertFrom-Json }
        )
    }
    Assert-Test 'Default invocation emits single stdout result and persists raw events to events_file' (
        $successStdoutLines.Count -eq 1 -and
        $successRun.events.Count -eq 1 -and
        $successRun.json.orchestra_result -eq $true -and
        $eventsFileExists -and
        $persistedEvents.Count -eq 2 -and
        (Get-OrchestraProperty $persistedEvents[0] 'event') -eq 'init' -and
        (Get-OrchestraProperty $persistedEvents[1] 'event') -eq 'result'
    )
    $agyUsageEvt = @(Read-UsageEvents -Paths $script:TestPaths | Where-Object {
        (Get-OrchestraProperty $_ 'invocation_id') -eq $successRun.json.invocation_id
    })
    Assert-Test 'Agy usage and cache_read_tokens telemetry extracted into result and usage.jsonl' (
        $null -ne $successRun.json.usage -and
        $successRun.json.usage.input_tokens -eq 1200 -and
        $successRun.json.usage.output_tokens -eq 300 -and
        $successRun.json.usage.thinking_tokens -eq 80 -and
        $successRun.json.usage.cached_tokens -eq 900 -and
        $successRun.json.usage.total_tokens -eq 1580 -and
        $successRun.json.usage.cache_hit_rate -eq 0.75 -and
        $agyUsageEvt.Count -eq 1 -and
        $agyUsageEvt[0].usage.cached_tokens -eq 900 -and
        $agyUsageEvt[0].usage.cache_hit_rate -eq 0.75
    )

    $streamRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @(
            '-Model', 'gemini-4-carbon', '-Prompt', 'TEST_SUCCESS', '-StreamStdout'
        )
    )
    Assert-Test 'Provider events precede exactly one final result with -StreamStdout' (
        $streamRun.code -eq 0 -and
        @($streamRun.events | Where-Object {
            (Get-OrchestraProperty $_ 'orchestra_result' $false) -eq $true
        }).Count -eq 1 -and
        (Get-OrchestraProperty $streamRun.events[0] 'event') -eq 'init' -and
        $streamRun.json.orchestra_result -eq $true
    )

    $zeroUsageRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gemini-4-carbon', '-Prompt', 'TEST_ZERO_USAGE')
    )
    Assert-Test 'Zero input tokens keeps cache_hit_rate null without division error' (
        $zeroUsageRun.code -eq 0 -and
        $zeroUsageRun.json.usage.input_tokens -eq 0 -and
        $null -eq $zeroUsageRun.json.usage.cache_hit_rate
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
if ($case -eq 'USAGE_CACHE') {
    [Console]::WriteLine('{"type":"turn.completed","usage":{"input_tokens":800,"cached_input_tokens":600,"output_tokens":200}}')
}
else {
    [Console]::WriteLine('{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}')
}
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
    $caseUsage = Invoke-CodexCase 'USAGE_CACHE'
    $codexUsageEvents = @(Read-UsageEvents -Paths $caseUsage.paths)
    Assert-Test 'Codex cached_input_tokens telemetry extracted and persisted to usage.jsonl' (
        $caseUsage.run.code -eq 0 -and
        $null -ne $caseUsage.run.json.usage -and
        $caseUsage.run.json.usage.input_tokens -eq 800 -and
        $caseUsage.run.json.usage.cached_tokens -eq 600 -and
        $caseUsage.run.json.usage.output_tokens -eq 200 -and
        $caseUsage.run.json.usage.total_tokens -eq 1000 -and
        $caseUsage.run.json.usage.cache_hit_rate -eq 0.75 -and
        $codexUsageEvents.Count -eq 1 -and
        $codexUsageEvents[0].usage.cached_tokens -eq 600 -and
        $codexUsageEvents[0].usage.total_tokens -eq 1000
    )

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

    # -ContextFiles tests: BOM stripping, CRLF->LF, static prefix top, TASK_INSTRUCTIONS, Codex --add-dir dedup, missing error
    $ctxWork = Join-Path $sandbox 'ctx-work'
    $ctxRelDir = Join-Path $ctxWork 'rel'
    $ctxExtDir = Join-Path $sandbox 'ctx-ext'
    [void][IO.Directory]::CreateDirectory($ctxRelDir)
    [void][IO.Directory]::CreateDirectory($ctxExtDir)
    $ctxFile1 = Join-Path $ctxExtDir 'pack1.md'
    $ctxFile2 = Join-Path $ctxExtDir 'pack2.md'
    $ctxFile3 = Join-Path $ctxRelDir 'local.md'
    $bomBytes = [byte[]](0xEF, 0xBB, 0xBF) + $script:OrchestraUtf8.GetBytes("alpha`r`nbeta`r`n")
    [IO.File]::WriteAllBytes($ctxFile1, $bomBytes)
    [IO.File]::WriteAllText($ctxFile2, "gamma`r`ndelta", $script:OrchestraUtf8)
    [IO.File]::WriteAllText($ctxFile3, "relone`r`nreltwo`r`n", $script:OrchestraUtf8)
    $ctxOut = Join-Path $ctxExtDir 'ctx-out.md'

    $ctxCodexRun = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $fixtureState,
        '-WorkDir', $ctxWork, '-Model', 'gpt-6-astra',
        '-ContextFiles', "$ctxFile1,$ctxFile2,rel\local.md",
        '-OutFile', $ctxOut, '-Prompt', 'DYNAMIC_TASK_BODY', '-DryRun'
    )
    $ctxStdin = [string]$ctxCodexRun.json.stdin
    $ctxArgv = @($ctxCodexRun.json.arguments)
    $ctxAddDirValues = @(
        for ($ai = 0; $ai -lt ($ctxArgv.Count - 1); $ai++) {
            if ($ctxArgv[$ai] -eq '--add-dir') { $ctxArgv[$ai + 1] }
        }
    )
    $expectedPrefix = @(
        "=====CONTEXT_PACK: pack1.md====="
        "alpha"
        "beta"
        "=====END_CONTEXT_PACK====="
        ""
        "=====CONTEXT_PACK: pack2.md====="
        "gamma"
        "delta"
        "=====END_CONTEXT_PACK====="
        ""
        "=====CONTEXT_PACK: local.md====="
        "relone"
        "reltwo"
        "=====END_CONTEXT_PACK====="
        ""
        "=====TASK_INSTRUCTIONS====="
        "DYNAMIC_TASK_BODY"
    ) -join "`n"
    Assert-Test 'ContextFiles builds deterministic top prefix, strips BOM/CR, and deduplicates Codex --add-dir' (
        $ctxCodexRun.code -eq 0 -and
        $ctxCodexRun.json.context_files_count -eq 3 -and
        $ctxStdin -ceq $expectedPrefix -and
        -not $ctxStdin.Contains("`r") -and
        -not $ctxStdin.Contains([char]0xFEFF) -and
        $ctxAddDirValues.Count -eq 1 -and
        $ctxAddDirValues[0] -ieq $ctxExtDir
    )

    $ctxAgyRun = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $fixtureState,
        '-WorkDir', $ctxWork, '-Model', 'claude-opus-5-5',
        '-ContextFiles', $ctxFile1,
        '-Prompt', 'AGY_DYNAMIC', '-DryRun'
    )
    $agyPIdx = [Array]::IndexOf(@($ctxAgyRun.json.arguments), '-p')
    $agyPromptArg = if ($agyPIdx -ge 0) { [string]$ctxAgyRun.json.arguments[$agyPIdx + 1] } else { '' }
    Assert-Test 'ContextFiles prepends static pack on agy channel too' (
        $ctxAgyRun.code -eq 0 -and
        $ctxAgyRun.json.context_files_count -eq 1 -and
        $agyPromptArg.StartsWith("=====CONTEXT_PACK: pack1.md=====`nalpha`nbeta`n=====END_CONTEXT_PACK=====`n`n=====TASK_INSTRUCTIONS=====`nAGY_DYNAMIC")
    )

    $ctxMissingRun = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $fixtureState,
        '-WorkDir', $ctxWork, '-Model', 'gpt-6-astra',
        '-ContextFiles', 'does-not-exist.md', '-Prompt', 'TEST', '-DryRun'
    )
    Assert-Test 'Missing ContextFile fails closed with exit 2' (
        $ctxMissingRun.code -eq 2 -and
        [string]$ctxMissingRun.json.error -match 'ORCHESTRA_ARGS: ContextFile does not exist\.'
    )

    # .events.jsonl 7-day pruning test (honor Get-OrchestraNow)
    $pruneState = Join-Path $sandbox 'prune-state'
    $pruneLive = Join-Path $pruneState 'live'
    [void][IO.Directory]::CreateDirectory($pruneLive)
    $staleEventLog = Join-Path $pruneLive 'stale-run.events.jsonl'
    $freshEventLog = Join-Path $pruneLive 'fresh-run.events.jsonl'
    [IO.File]::WriteAllText($staleEventLog, '{"event":"init"}' + "`n", $script:OrchestraUtf8)
    [IO.File]::WriteAllText($freshEventLog, '{"event":"init"}' + "`n", $script:OrchestraUtf8)
    [IO.File]::SetLastWriteTimeUtc($staleEventLog, (Get-OrchestraNow).AddDays(-8))
    [IO.File]::SetLastWriteTimeUtc($freshEventLog, (Get-OrchestraNow).AddDays(-2))
    $pruneRun = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $pruneState,
        '-WorkDir', $sandbox, '-Model', 'claude-opus-5-5', '-Prompt', 'TEST_SUCCESS'
    )
    Assert-Test 'Invoke prunes .events.jsonl older than 7 days while keeping recent logs' (
        $pruneRun.code -eq 0 -and
        -not [IO.File]::Exists($staleEventLog) -and
        [IO.File]::Exists($freshEventLog) -and
        [IO.File]::Exists([string]$pruneRun.json.events_file)
    )

    # 4H Mechanical high auto-downgrade tests (with default fallback tags and configured mechanical_fast_tags)
    $h4Reg = Read-JsonFile -Path $fixtureRegistry
    $h4Model = New-TestModel 'gemini-4-hydrogen' 'agy'
    Set-OrchestraProperty $h4Model 'tier' 'fast'
    Set-OrchestraProperty $h4Model.invoke 'efforts' @('low', 'medium', 'high', 'xhigh')
    Set-OrchestraProperty $h4Model.invoke 'default_effort' 'xhigh'
    Set-OrchestraProperty $h4Model.invoke 'peak_effort' 'xhigh'
    Set-OrchestraProperty $h4Reg 'models' (@($h4Reg.models) + @($h4Model))
    Write-JsonAtomic -Path $fixtureRegistry -Object $h4Reg

    $h4ScanRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gemini-4-hydrogen', '-Tags', 'scan', '-Prompt', 'TEST', '-DryRun')
    )
    $h4BulkRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gemini-4-hydrogen', '-Tags', 'bulk', '-Prompt', 'TEST', '-DryRun')
    )
    $h4BugfixRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gemini-4-hydrogen', '-Tags', 'bugfix', '-Prompt', 'TEST', '-DryRun')
    )
    $h4PeakOverrideRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gemini-4-hydrogen', '-Tags', 'scan,math', '-Prompt', 'TEST', '-DryRun')
    )
    $h4ExplicitRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gemini-4-hydrogen', '-Tags', 'scan', '-Effort', 'xhigh', '-Prompt', 'TEST', '-DryRun')
    )
    Assert-Test '4H fast model auto-downgrades mechanical scan/bulk tags to high while keeping bugfix/peak/explicit at xhigh' (
        $h4ScanRun.code -eq 0 -and $h4ScanRun.json.effort -eq 'high' -and
        (@($h4ScanRun.json.arguments) -contains 'gemini-4-hydrogen-high') -and
        $h4BulkRun.code -eq 0 -and $h4BulkRun.json.effort -eq 'high' -and
        $h4BugfixRun.code -eq 0 -and $h4BugfixRun.json.effort -eq 'xhigh' -and
        $h4PeakOverrideRun.code -eq 0 -and $h4PeakOverrideRun.json.effort -eq 'xhigh' -and
        $h4ExplicitRun.code -eq 0 -and $h4ExplicitRun.json.effort -eq 'xhigh'
    )

    # Multi-pool concurrency slot lease tests:
    # (a) Pool resolution & simultaneous non-blocking acquisition across distinct pools
    Assert-Test 'Pool resolution maps codex, anthropic, and google models accurately' (
        (Get-OrchestraPoolName ([pscustomobject]@{ id = 'gpt-6-astra'; channel = 'codex' })) -eq 'codex_openai' -and
        (Get-OrchestraPoolName ([pscustomobject]@{ id = 'claude-opus-5-5'; channel = 'agy' })) -eq 'agy_anthropic' -and
        (Get-OrchestraPoolName ([pscustomobject]@{ id = 'gemini-4-hydrogen'; channel = 'agy' })) -eq 'agy_google'
    )
    $dryCodexPool = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gpt-6-astra', '-Prompt', 'TEST', '-DryRun')
    )
    $dryAnthropicPool = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'claude-opus-5-5', '-Prompt', 'TEST', '-DryRun')
    )
    $dryGooglePool = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gemini-4-hydrogen', '-Prompt', 'TEST', '-DryRun')
    )
    Assert-Test 'DryRun exposes pool and pool_limit for all three provider pools' (
        $dryCodexPool.json.pool -eq 'codex_openai' -and $dryCodexPool.json.pool_limit -eq 4 -and
        $dryAnthropicPool.json.pool -eq 'agy_anthropic' -and $dryAnthropicPool.json.pool_limit -eq 3 -and
        $dryGooglePool.json.pool -eq 'agy_google' -and $dryGooglePool.json.pool_limit -eq 7
    )

    $slotTestState = Join-Path $sandbox 'slot-unit-state'
    $slotPaths = Get-OrchestraPaths -RegistryPath $fixtureRegistry -StateDir $slotTestState
    $acquiredLeases = New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach ($idx in 1..4) {
            [void]$acquiredLeases.Add((Acquire-OrchestraPoolSlot -Paths $slotPaths -Pool 'codex_openai' -Limit 4 -InvocationId "u-c$idx" -ModelId 'gpt-6-astra' -Channel 'codex' -NoWait))
        }
        foreach ($idx in 1..3) {
            [void]$acquiredLeases.Add((Acquire-OrchestraPoolSlot -Paths $slotPaths -Pool 'agy_anthropic' -Limit 3 -InvocationId "u-a$idx" -ModelId 'claude-opus-5-5' -Channel 'agy' -NoWait))
        }
        foreach ($idx in 1..2) {
            [void]$acquiredLeases.Add((Acquire-OrchestraPoolSlot -Paths $slotPaths -Pool 'agy_google' -Limit 7 -InvocationId "u-g$idx" -ModelId 'gemini-4-hydrogen' -Channel 'agy' -NoWait))
        }
        $activeSnap = Get-ActivePoolSlotStatus -Paths $slotPaths
        Assert-Test 'Simultaneous slots acquire across all pools (4/3/7) without cross-blocking' (
            $activeSnap.total_active -eq 9 -and
            $activeSnap.underutilized -eq $false -and
            $activeSnap.pools.codex_openai.active -eq 4 -and
            $activeSnap.pools.codex_openai.available -eq 0 -and
            $activeSnap.pools.agy_anthropic.active -eq 3 -and
            $activeSnap.pools.agy_anthropic.available -eq 0 -and
            $activeSnap.pools.agy_google.active -eq 2 -and
            $activeSnap.pools.agy_google.available -eq 5
        )
    }
    finally {
        $pairIdx = 0
        foreach ($leaseObj in $acquiredLeases) {
            $pairIdx++
            Release-OrchestraPoolSlot -Paths $slotPaths -LeasePath ([string]$leaseObj.lease_path) -InvocationId ([string](Read-JsonFile ([string]$leaseObj.lease_path)).invocation_id)
        }
    }
    $afterRelSnap = Get-ActivePoolSlotStatus -Paths $slotPaths
    Assert-Test 'Release-OrchestraPoolSlot removes leases and restores underutilized status' (
        $afterRelSnap.total_active -eq 0 -and
        $afterRelSnap.underutilized -eq $true -and
        [IO.Directory]::GetFiles($slotPaths.Slots, '*.json').Length -eq 0
    )

    # (b) Dead-PID and >7200s stale lease auto-reclamation
    $staleSlotState = Join-Path $sandbox 'slot-stale-state'
    $staleSlotPaths = Get-OrchestraPaths -RegistryPath $fixtureRegistry -StateDir $staleSlotState
    [void][IO.Directory]::CreateDirectory($staleSlotPaths.Slots)
    $deadPidLease = Join-Path $staleSlotPaths.Slots 'codex_openai-1.json'
    $expiredAgeLease = Join-Path $staleSlotPaths.Slots 'agy_google-1.json'
    $liveLease = Join-Path $staleSlotPaths.Slots 'agy_anthropic-1.json'
    Write-JsonAtomic -Path $deadPidLease -Object @{
        invocation_id = 'dead-1'; pid = 999991; pool = 'codex_openai'; slot = 1
        model = 'gpt-6-astra'; channel = 'codex'; started_utc = (Get-OrchestraNow).ToString('o')
    }
    Write-JsonAtomic -Path $expiredAgeLease -Object @{
        invocation_id = 'old-1'; pid = [int]$PID; pool = 'agy_google'; slot = 1
        model = 'gemini-4-hydrogen'; channel = 'agy'; started_utc = (Get-OrchestraNow).AddSeconds(-7300).ToString('o')
    }
    Write-JsonAtomic -Path $liveLease -Object @{
        invocation_id = 'live-1'; pid = [int]$PID; pool = 'agy_anthropic'; slot = 1
        model = 'claude-opus-5-5'; channel = 'agy'; started_utc = (Get-OrchestraNow).ToString('o')
    }
    $reclaimedSnap = Get-ActivePoolSlotStatus -Paths $staleSlotPaths -CleanupStale
    Assert-Test 'Dead-PID and >7200s stale leases are reclaimed while live leases stay intact' (
        $reclaimedSnap.reclaimed_stale -eq 2 -and
        $reclaimedSnap.total_active -eq 1 -and
        -not [IO.File]::Exists($deadPidLease) -and
        -not [IO.File]::Exists($expiredAgeLease) -and
        [IO.File]::Exists($liveLease)
    )
    Release-OrchestraPoolSlot -Paths $staleSlotPaths -LeasePath $liveLease -InvocationId 'live-1'

    # (c) MODEL_ORCHESTRA_FAKE_ALIVE_PIDS full pool -> -NoSlotWait exits 5, distinct pool succeeds, queued wait acquires on release
    $capHome = Join-Path $sandbox 'cap-codex-home'
    [void][IO.Directory]::CreateDirectory($capHome)
    [IO.File]::WriteAllBytes((Join-Path $capHome 'auth.json'), $script:OrchestraUtf8.GetBytes('{"fixture":"cap"}'))
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX_HOME', $capHome)
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX', $fakeCodexPath)
    $capState = Join-Path $sandbox 'cap-state'
    $capPaths = Get-OrchestraPaths -RegistryPath $fixtureRegistry -StateDir $capState
    [void][IO.Directory]::CreateDirectory($capPaths.Slots)
    $fakeLease1 = Join-Path $capPaths.Slots 'codex_openai-1.json'
    $fakeLease2 = Join-Path $capPaths.Slots 'codex_openai-2.json'
    $fakeLease3 = Join-Path $capPaths.Slots 'codex_openai-3.json'
    $fakeLease4 = Join-Path $capPaths.Slots 'codex_openai-4.json'
    foreach ($pair in @(
        @{ Path = $fakeLease1; Id = 'fake-c1'; Pid = 999901; Slot = 1 },
        @{ Path = $fakeLease2; Id = 'fake-c2'; Pid = 999902; Slot = 2 },
        @{ Path = $fakeLease3; Id = 'fake-c3'; Pid = 999903; Slot = 3 },
        @{ Path = $fakeLease4; Id = 'fake-c4'; Pid = 999904; Slot = 4 }
    )) {
        Write-JsonAtomic -Path $pair.Path -Object @{
            invocation_id = $pair.Id; pid = $pair.Pid; pool = 'codex_openai'; slot = $pair.Slot
            model = 'gpt-6-astra'; channel = 'codex'; started_utc = (Get-OrchestraNow).ToString('o')
        }
    }
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_FAKE_ALIVE_PIDS', '999901,999902,999903,999904')

    $noWaitFail = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $capState,
        '-WorkDir', $sandbox, '-Model', 'gpt-6-astra', '-Prompt', 'SUCCESS_TEXT', '-NoSlotWait'
    )
    $otherPoolOk = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $capState,
        '-WorkDir', $sandbox, '-Model', 'claude-opus-5-5', '-Prompt', 'TEST_SUCCESS', '-NoSlotWait'
    )
    $googlePoolOk = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $capState,
        '-WorkDir', $sandbox, '-Model', 'gemini-4-hydrogen', '-Prompt', 'TEST_SUCCESS', '-NoSlotWait'
    )
    Assert-Test 'Full codex_openai pool (4/4) fails fast (exit 5) with -NoSlotWait while agy_anthropic (3) and agy_google (7) stay unblocked' (
        $noWaitFail.code -eq 5 -and
        [string]$noWaitFail.json.error -match 'ORCHESTRA_LOCK_TIMEOUT' -and
        $otherPoolOk.code -eq 0 -and
        $otherPoolOk.json.pool -eq 'agy_anthropic' -and
        $googlePoolOk.code -eq 0 -and
        $googlePoolOk.json.pool -eq 'agy_google' -and
        [IO.File]::Exists($fakeLease1) -and [IO.File]::Exists($fakeLease4)
    )

    $queueStatusPath = Join-Path $sandbox 'queued-status.json'
    $qInfo = New-Object Diagnostics.ProcessStartInfo
    $qInfo.FileName = $script:TestHost
    $qArgs = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $invokeScript,
        '-RegistryPath', $fixtureRegistry, '-StateDir', $capState,
        '-WorkDir', $sandbox, '-Model', 'gpt-6-astra', '-Prompt', 'SUCCESS_TEXT',
        '-SlotWaitSec', '15', '-StatusFile', $queueStatusPath
    )
    $qInfo.Arguments = (@($qArgs | ForEach-Object { ConvertTo-OrchestraArgument $_ }) -join ' ')
    $qInfo.UseShellExecute = $false
    $qInfo.CreateNoWindow = $true
    $qInfo.RedirectStandardOutput = $true
    $qInfo.RedirectStandardError = $true
    $qInfo.StandardOutputEncoding = $script:OrchestraUtf8
    $qInfo.StandardErrorEncoding = $script:OrchestraUtf8
    $qInfo.WorkingDirectory = $sandbox
    $qProc = [Diagnostics.Process]::Start($qInfo)
    $qStdoutTask = $qProc.StandardOutput.ReadToEndAsync()
    $qStderrTask = $qProc.StandardError.ReadToEndAsync()
    $sawQueued = $false
    $qWaitSw = [Diagnostics.Stopwatch]::StartNew()
    while ($qWaitSw.Elapsed.TotalSeconds -lt 8 -and -not $qProc.HasExited) {
        if ([IO.File]::Exists($queueStatusPath)) {
            try {
                $qSt = Read-JsonFile -Path $queueStatusPath
                if ($null -ne $qSt -and [string](Get-OrchestraProperty $qSt 'phase' '') -eq 'queued_slot') {
                    $sawQueued = $true
                    break
                }
            }
            catch {}
        }
        Start-Sleep -Milliseconds 100
    }
    if ([IO.File]::Exists($fakeLease1)) { [IO.File]::Delete($fakeLease1) }
    $qExited = $qProc.WaitForExit(15000)
    if (-not $qExited) { try { Stop-OrchestraProcessTree -Process $qProc } catch {} }
    $qOutText = $qStdoutTask.GetAwaiter().GetResult()
    $null = $qStderrTask.GetAwaiter().GetResult()
    $qJson = $null
    $qNonEmpty = @($qOutText -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($qNonEmpty.Count -gt 0) {
        try { $qJson = $qNonEmpty[$qNonEmpty.Count - 1] | ConvertFrom-Json } catch {}
    }
    $postQueueSnap = Get-ActivePoolSlotStatus -Paths $capPaths
    Assert-Test 'Queued invocation enters queued_slot phase, acquires released slot, succeeds, and cleans up lease' (
        $sawQueued -and $qExited -and $qProc.ExitCode -eq 0 -and
        $null -ne $qJson -and $qJson.pool -eq 'codex_openai' -and
        [double]$qJson.slot_wait_sec -gt 0 -and
        $postQueueSnap.pools.codex_openai.active -eq 3
    )
    $qProc.Dispose()
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_FAKE_ALIVE_PIDS', $null)

    # (d) pack-context.ps1 static_pack and -GitDiff + -TestLogFile (<=20 lines)
    $packScript = Join-Path $root 'scripts\pack-context.ps1'
    $packScriptBytes = [IO.File]::ReadAllBytes($packScript)
    Assert-Test 'pack-context.ps1 is saved as UTF-8 with BOM for PS 5.1' (
        $packScriptBytes.Length -ge 3 -and
        $packScriptBytes[0] -eq 239 -and $packScriptBytes[1] -eq 187 -and $packScriptBytes[2] -eq 191
    )

    $packRepo = Join-Path $sandbox 'pack-repo'
    [void][IO.Directory]::CreateDirectory($packRepo)
    $null = Invoke-OrchestraProcess -FilePath 'git' -Arguments @('-C', $packRepo, 'init') -WorkDir $packRepo -TimeoutSec 15 -CaptureStdout
    $null = Invoke-OrchestraProcess -FilePath 'git' -Arguments @('-C', $packRepo, 'config', 'user.email', 'test@example.com') -WorkDir $packRepo -TimeoutSec 15 -CaptureStdout
    $null = Invoke-OrchestraProcess -FilePath 'git' -Arguments @('-C', $packRepo, 'config', 'user.name', 'Test') -WorkDir $packRepo -TimeoutSec 15 -CaptureStdout
    $packA = Join-Path $packRepo 'a.txt'
    $packB = Join-Path $packRepo 'b.txt'
    $packLong = Join-Path $packRepo 'long.txt'
    [IO.File]::WriteAllBytes($packA, ([byte[]](0xEF, 0xBB, 0xBF) + $script:OrchestraUtf8.GetBytes("alpha`r`nbeta`r`n")))
    [IO.File]::WriteAllText($packB, "b1`r`nb2`r`n", $script:OrchestraUtf8)
    [IO.File]::WriteAllText($packLong, ((1..15 | ForEach-Object { "line-$_" }) -join "`r`n") + "`r`n", $script:OrchestraUtf8)
    $null = Invoke-OrchestraProcess -FilePath 'git' -Arguments @('-C', $packRepo, 'add', '.') -WorkDir $packRepo -TimeoutSec 15 -CaptureStdout
    $null = Invoke-OrchestraProcess -FilePath 'git' -Arguments @('-C', $packRepo, 'commit', '-m', 'init') -WorkDir $packRepo -TimeoutSec 15 -CaptureStdout

    $staticOut = Join-Path $sandbox 'static-pack.md'
    $staticRun = Invoke-TestScript -Script $packScript -Arguments @(
        '-WorkDir', $packRepo, '-Files', 'b.txt,a.txt,long.txt',
        '-OutFile', $staticOut, '-MaxLinesPerFile', '5'
    )
    $staticBytes = [IO.File]::ReadAllBytes($staticOut)
    $staticText = [IO.File]::ReadAllText($staticOut, $script:OrchestraUtf8)
    Assert-Test 'pack-context static_pack sorts deterministically, strips BOM/CR, truncates, and writes BOM-less UTF-8' (
        $staticRun.code -eq 0 -and
        $staticRun.json.mode -eq 'static_pack' -and
        $staticRun.json.files_count -eq 3 -and
        $staticRun.json.truncated -eq $true -and
        ($staticBytes.Length -lt 3 -or -not ($staticBytes[0] -eq 239 -and $staticBytes[1] -eq 187 -and $staticBytes[2] -eq 191)) -and
        -not $staticText.Contains("`r") -and
        -not $staticText.Contains([char]0xFEFF) -and
        $staticText.IndexOf('## File: a.txt') -ge 0 -and
        $staticText.IndexOf('## File: a.txt') -lt $staticText.IndexOf('## File: b.txt') -and
        $staticText.IndexOf('## File: b.txt') -lt $staticText.IndexOf('## File: long.txt') -and
        $staticText.Contains('... [truncated 10 lines]')
    )

    [IO.File]::WriteAllText($packA, "alpha`r`nbeta`r`ngamma-added`r`n", $script:OrchestraUtf8)
    [IO.File]::WriteAllText((Join-Path $packRepo 'untracked.txt'), "fresh`r`n", $script:OrchestraUtf8)
    $sampleLog = Join-Path $sandbox 'sample-test.log'
    [IO.File]::WriteAllText($sampleLog, ((1..50 | ForEach-Object { "log-$_" }) -join "`r`n") + "`r`n", $script:OrchestraUtf8)
    $deltaOut = Join-Path $sandbox 'delta-pack.md'
    $deltaRun = Invoke-TestScript -Script $packScript -Arguments @(
        '-WorkDir', $packRepo, '-GitDiff', '-AllowedPrefixes', 'a.txt,untracked.txt',
        '-TestLogFile', $sampleLog, '-OutFile', $deltaOut, '-MaxLogTailLines', '20'
    )
    $deltaText = [IO.File]::ReadAllText($deltaOut, $script:OrchestraUtf8)
    $tailIdx = $deltaText.IndexOf('## Test Log Tail')
    $tailSectionLines = @()
    if ($tailIdx -ge 0) {
        $tailSectionLines = @(($deltaText.Substring($tailIdx) -split "`n") | Select-Object -Skip 1 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    Assert-Test 'pack-context -GitDiff emits delta diff and <=20 test log tail lines' (
        $deltaRun.code -eq 0 -and
        $deltaRun.json.mode -eq 'delta_diff' -and
        $deltaRun.json.files_count -eq 2 -and
        $deltaRun.json.truncated -eq $true -and
        -not $deltaText.Contains("`r") -and
        $deltaText.Contains('## Git Status') -and
        $deltaText.Contains('## Git Diff') -and
        $deltaText.Contains('+gamma-added') -and
        $tailSectionLines.Count -eq 20 -and
        $deltaText.Contains('log-31') -and
        $deltaText.Contains('log-50') -and
        -not $deltaText.Contains("log-30`n")
    )

    # (e) doctor.ps1 slot_hygiene check & -Repair dead-PID reclamation
    $docSlotState = Join-Path $sandbox 'doc-slot-state'
    $docSlotPaths = Get-OrchestraPaths -RegistryPath $fixtureRegistry -StateDir $docSlotState
    [void][IO.Directory]::CreateDirectory($docSlotPaths.Slots)
    $docDeadLease = Join-Path $docSlotPaths.Slots 'codex_openai-1.json'
    Write-JsonAtomic -Path $docDeadLease -Object @{
        invocation_id = 'doc-dead-1'; pid = 999992; pool = 'codex_openai'; slot = 1
        model = 'gpt-6-astra'; channel = 'codex'; started_utc = (Get-OrchestraNow).ToString('o')
    }
    $doctorScript = Join-Path $root 'scripts\doctor.ps1'
    $docInspect = Invoke-TestScript -Script $doctorScript -Arguments @(
        '-NoNetwork', '-CodexDestination', '', '-RegistryPath', $fixtureRegistry, '-StateDir', $docSlotState
    )
    $docInspectSlotCheck = @($docInspect.json.checks | Where-Object { $_.name -eq 'slot_hygiene' }) | Select-Object -First 1
    $existsAfterInspect = [IO.File]::Exists($docDeadLease)
    $docRepair = Invoke-TestScript -Script $doctorScript -Arguments @(
        '-Repair', '-NoNetwork', '-CodexDestination', '', '-RegistryPath', $fixtureRegistry, '-StateDir', $docSlotState
    )
    $docRepairSlotCheck = @($docRepair.json.checks | Where-Object { $_.name -eq 'slot_hygiene' }) | Select-Object -First 1
    Assert-Test 'doctor.ps1 slot_hygiene reports stale slots read-only and reclaims them under -Repair' (
        $docInspect.code -eq 0 -and $null -ne $docInspectSlotCheck -and
        $docInspectSlotCheck.passed -eq $true -and $docInspectSlotCheck.detail -match 'reclaimed=0;stale_detected=1' -and
        $existsAfterInspect -and
        $docRepair.code -eq 0 -and $null -ne $docRepairSlotCheck -and
        $docRepairSlotCheck.passed -eq $true -and $docRepairSlotCheck.detail -match 'reclaimed=1;stale_detected=1' -and
        @($docRepair.json.repairs) -contains 'stale_pool_slots_cleaned' -and
        -not [IO.File]::Exists($docDeadLease)
    )

    # (f) Rev 9 hardening regressions: Release-OrchestraPoolSlot ownership, ad-hoc pool limits + slot_wait_sec on timeout, pack-context BaseRef + -uall
    $ownState = Join-Path $sandbox 'slot-own-state'
    $ownPaths = Get-OrchestraPaths -RegistryPath $fixtureRegistry -StateDir $ownState
    [void][IO.Directory]::CreateDirectory($ownPaths.Slots)
    $ownLease = Join-Path $ownPaths.Slots 'codex_openai-1.json'
    $corruptLease = Join-Path $ownPaths.Slots 'agy_google-1.json'
    Write-JsonAtomic -Path $ownLease -Object @{
        invocation_id = 'owner-1'; pid = [int]$PID; pool = 'codex_openai'; slot = 1
        model = 'gpt-6-astra'; channel = 'codex'; started_utc = (Get-OrchestraNow).ToString('o')
    }
    [IO.File]::WriteAllText($corruptLease, '{not-valid-json', $script:OrchestraUtf8)
    Release-OrchestraPoolSlot -Paths $ownPaths -LeasePath $ownLease -InvocationId ''
    Release-OrchestraPoolSlot -Paths $ownPaths -LeasePath $ownLease -InvocationId 'wrong-owner'
    Release-OrchestraPoolSlot -Paths $ownPaths -LeasePath $corruptLease -InvocationId 'any-owner'
    $afterUnsafeRel = ([IO.File]::Exists($ownLease) -and [IO.File]::Exists($corruptLease))
    Release-OrchestraPoolSlot -Paths $ownPaths -LeasePath $ownLease -InvocationId 'owner-1'
    Assert-Test 'Release-OrchestraPoolSlot enforces non-empty matching invocation_id and refuses blind delete on corrupt lease' (
        $afterUnsafeRel -and (-not [IO.File]::Exists($ownLease)) -and [IO.File]::Exists($corruptLease)
    )

    $adhocPoolReg = Join-Path $sandbox 'adhoc-pool-models.json'
    $adhocRegObj = Read-JsonFile -Path $fixtureRegistry
    Set-OrchestraProperty $adhocRegObj.policy 'pool_concurrency_limits' ([pscustomobject]@{
        codex_openai = 1; agy_anthropic = 2; agy_google = 6
    })
    Write-JsonAtomic -Path $adhocPoolReg -Object $adhocRegObj
    $adhocDryLimit = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $adhocPoolReg, '-StateDir', (Join-Path $sandbox 'adhoc-limit-state'),
        '-WorkDir', $sandbox, '-AdHocChannel', 'codex', '-AdHocModelFlag', 'custom-codex',
        '-Prompt', 'TEST', '-DryRun'
    )
    $timeoutState = Join-Path $sandbox 'slot-timeout-state'
    $timeoutPaths = Get-OrchestraPaths -RegistryPath $adhocPoolReg -StateDir $timeoutState
    [void][IO.Directory]::CreateDirectory($timeoutPaths.Slots)
    Write-JsonAtomic -Path (Join-Path $timeoutPaths.Slots 'codex_openai-1.json') -Object @{
        invocation_id = 'busy-1'; pid = 999901; pool = 'codex_openai'; slot = 1
        model = 'gpt-6-astra'; channel = 'codex'; started_utc = (Get-OrchestraNow).ToString('o')
    }
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_FAKE_ALIVE_PIDS', '999901')
    $timeoutSlotRun = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $adhocPoolReg, '-StateDir', $timeoutState,
        '-WorkDir', $sandbox, '-AdHocChannel', 'codex', '-AdHocModelFlag', 'custom-codex',
        '-Prompt', 'SUCCESS_TEXT', '-SlotWaitSec', '1'
    )
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_FAKE_ALIVE_PIDS', $null)
    $timeoutUsageEvents = @(Read-UsageEvents -Paths $timeoutPaths)
    Assert-Test 'Ad-hoc invocations honor policy.pool_concurrency_limits and populate slot_wait_sec on slot timeout' (
        $adhocDryLimit.code -eq 0 -and
        $adhocDryLimit.json.pool -eq 'codex_openai' -and
        $adhocDryLimit.json.pool_limit -eq 1 -and
        $timeoutSlotRun.code -eq 5 -and
        [double]$timeoutSlotRun.json.slot_wait_sec -ge 0.8 -and
        $timeoutUsageEvents.Count -eq 1 -and
        [double]$timeoutUsageEvents[0].slot_wait_sec -ge 0.8
    )

    $badRefRun = Invoke-TestScript -Script $packScript -Arguments @(
        '-WorkDir', $packRepo, '-GitDiff', '-BaseRef', '--output=pwned', '-OutFile', (Join-Path $sandbox 'bad-ref.md')
    )
    $untrackedSubDir = Join-Path $packRepo 'newdir'
    [void][IO.Directory]::CreateDirectory($untrackedSubDir)
    [IO.File]::WriteAllText((Join-Path $untrackedSubDir 'sub1.txt'), "s1`n", $script:OrchestraUtf8)
    [IO.File]::WriteAllText((Join-Path $untrackedSubDir 'sub2.txt'), "s2`n", $script:OrchestraUtf8)
    $uallOut = Join-Path $sandbox 'uall-delta.md'
    $uallRun = Invoke-TestScript -Script $packScript -Arguments @(
        '-WorkDir', $packRepo, '-GitDiff', '-BaseRef', 'HEAD', '-OutFile', $uallOut
    )
    $uallText = [IO.File]::ReadAllText($uallOut, $script:OrchestraUtf8)
    Assert-Test 'pack-context rejects flag-like BaseRef and expands untracked directories via -uall' (
        $badRefRun.code -eq 2 -and
        [string]$badRefRun.json.error -match 'ORCHESTRA_ARGS: Invalid BaseRef' -and
        $uallRun.code -eq 0 -and
        $uallRun.json.files_count -eq 4 -and
        $uallText.Contains('newdir/sub1.txt') -and
        $uallText.Contains('newdir/sub2.txt')
    )

    # (g) AIMD Codex Rotation Cooldown: caps codex_openai to 1, blocks 2nd -NoSlotWait with exit 5, clears on thread.started and expires cleanly
    $aimdState = Join-Path $sandbox 'aimd-state'
    $aimdPaths = Get-OrchestraPaths -RegistryPath $fixtureRegistry -StateDir $aimdState
    Set-OrchestraCodexRotationCooldown -Paths $aimdPaths -CooldownSec 15 -Reason 'test_aimd'
    $aimdStatus = Get-ActivePoolSlotStatus -Paths $aimdPaths
    $aimdMetaFile = Join-Path $aimdPaths.Slots '_codex_rotation_cooldown.meta'
    $aimdJsonFiles = [IO.Directory]::GetFiles($aimdPaths.Slots, '*.json').Length
    $aimdFakeLease = Join-Path $aimdPaths.Slots 'codex_openai-1.json'
    Write-JsonAtomic -Path $aimdFakeLease -Object @{
        invocation_id = 'aimd-busy-1'; pid = 999911; pool = 'codex_openai'; slot = 1
        model = 'gpt-6-astra'; channel = 'codex'; started_utc = (Get-OrchestraNow).ToString('o')
    }
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_FAKE_ALIVE_PIDS', '999911')
    $aimdBlockedRun = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $aimdState,
        '-WorkDir', $sandbox, '-Model', 'gpt-6-astra', '-Prompt', 'SUCCESS_TEXT', '-NoSlotWait'
    )
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_NOW', '2026-11-10T12:00:20Z')
    $aimdExpiredSnap = Get-ActivePoolSlotStatus -Paths $aimdPaths
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_NOW', '2026-11-10T12:00:00Z')
    [IO.File]::Delete($aimdFakeLease)
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_FAKE_ALIVE_PIDS', $null)

    # Also verify live thread.started clears cooldown and terminal quota re-arms cooldown
    Set-OrchestraCodexRotationCooldown -Paths $aimdPaths -CooldownSec 15 -Reason 'pre_thread_started'
    $aimdHome = Join-Path $sandbox 'aimd-codex-home'
    [void][IO.Directory]::CreateDirectory($aimdHome)
    [IO.File]::WriteAllBytes((Join-Path $aimdHome 'auth.json'), $script:OrchestraUtf8.GetBytes('{"fixture":"aimd"}'))
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX_HOME', $aimdHome)
    $aimdClearedRun = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $aimdState,
        '-WorkDir', $sandbox, '-Model', 'gpt-6-astra', '-Prompt', 'SUCCESS_TEXT', '-NoSlotWait'
    )
    $afterClearCooldown = Test-OrchestraCodexRotationCooldown -Paths $aimdPaths
    $aimdQuotaRun = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $aimdState,
        '-WorkDir', $sandbox, '-Model', 'gpt-6-astra', '-Prompt', 'ALL_QUOTA', '-NoSlotWait'
    )
    $afterQuotaCooldown = Test-OrchestraCodexRotationCooldown -Paths $aimdPaths
    $afterQuotaStatus = Get-ActivePoolSlotStatus -Paths $aimdPaths
    Assert-Test 'AIMD rotation cooldown caps codex_openai to 1, keeps .meta outside *.json, auto-expires, clears on thread.started, and sets on quota' (
        $aimdStatus.pools.codex_openai.limit -eq 1 -and
        $aimdStatus.pools.codex_openai.configured_limit -eq 4 -and
        $aimdStatus.pools.codex_openai.rotation_cooldown -eq $true -and
        [IO.File]::Exists($aimdMetaFile) -and
        $aimdJsonFiles -eq 0 -and
        $aimdBlockedRun.code -eq 5 -and
        $aimdExpiredSnap.pools.codex_openai.limit -eq 4 -and
        $aimdExpiredSnap.pools.codex_openai.rotation_cooldown -eq $false -and
        $aimdExpiredSnap.pools.codex_openai.available -eq 3 -and
        $aimdClearedRun.code -eq 0 -and
        (-not $afterClearCooldown) -and
        $aimdQuotaRun.code -eq 4 -and
        $afterQuotaCooldown -and
        $afterQuotaStatus.pools.codex_openai.limit -eq 1
    )

    # (h) Launch Stagger: 1st slot has 0ms stagger; 2nd concurrent slot in agy_google staggers by ~180ms without leaving .json junk
    $staggerState = Join-Path $sandbox 'stagger-state'
    $staggerPaths = Get-OrchestraPaths -RegistryPath $fixtureRegistry -StateDir $staggerState
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_TEST_STAGGER_MS', '180')
    $stg1 = $null
    $stg2 = $null
    try {
        $stg1 = Acquire-OrchestraPoolSlot -Paths $staggerPaths -Pool 'agy_google' -Limit 7 -InvocationId 'stg-1' -ModelId 'gemini-4-hydrogen' -Channel 'agy' -NoWait
        $stgSw = [Diagnostics.Stopwatch]::StartNew()
        $stg2 = Acquire-OrchestraPoolSlot -Paths $staggerPaths -Pool 'agy_google' -Limit 7 -InvocationId 'stg-2' -ModelId 'gemini-4-hydrogen' -Channel 'agy' -NoWait
        $stgSw.Stop()
    }
    finally {
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_TEST_STAGGER_MS', $null)
        if ($null -ne $stg1) { Release-OrchestraPoolSlot -Paths $staggerPaths -LeasePath ([string]$stg1.lease_path) -InvocationId 'stg-1' }
        if ($null -ne $stg2) { Release-OrchestraPoolSlot -Paths $staggerPaths -LeasePath ([string]$stg2.lease_path) -InvocationId 'stg-2' }
    }
    $staggerMetaFile = Join-Path $staggerPaths.Slots '_stagger_agy_google.meta'
    Assert-Test 'Launch stagger skips 1st active slot (0ms) and staggers 2nd concurrent slot via .meta without .json junk' (
        $null -ne $stg1 -and [int]$stg1.stagger_ms -eq 0 -and
        $null -ne $stg2 -and [int]$stg2.stagger_ms -ge 100 -and
        $stgSw.ElapsedMilliseconds -ge 90 -and
        [IO.File]::Exists($staggerMetaFile) -and
        [IO.Directory]::GetFiles($staggerPaths.Slots, '*.json').Length -eq 0
    )

    # (i) Rev 11: Inline response when -OutFile omitted, >64000 spill to .response.md, and -AutoRecordOk single-step outcome logging
    $rev11State = Join-Path $sandbox 'rev11-state'
    $rev11Paths = Get-OrchestraPaths -RegistryPath $fixtureRegistry -StateDir $rev11State
    $rev11Home = Join-Path $sandbox 'rev11-codex-home'
    [void][IO.Directory]::CreateDirectory($rev11Home)
    [IO.File]::WriteAllBytes((Join-Path $rev11Home 'auth.json'), $script:OrchestraUtf8.GetBytes('{"fixture":"rev11"}'))
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX_HOME', $rev11Home)
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX', $fakeCodexPath)
    [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER', $wrapperPath)

    $explicitOutPath = Join-Path $sandbox 'rev11-explicit.txt'
    $agyWithOutRun = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $rev11State,
        '-WorkDir', $sandbox, '-Model', 'gemini-4-carbon',
        '-Prompt', 'TEST_SUCCESS', '-OutFile', $explicitOutPath
    )
    $agyInlineRun = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $rev11State,
        '-WorkDir', $sandbox, '-Model', 'gemini-4-carbon',
        '-Prompt', 'TEST_SUCCESS'
    )
    $codexInlineRun = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $rev11State,
        '-WorkDir', $sandbox, '-Model', 'gpt-6-astra',
        '-Prompt', 'SUCCESS_TEXT'
    )
    $agyLargeRun = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $rev11State,
        '-WorkDir', $sandbox, '-Model', 'gemini-4-carbon',
        '-Prompt', 'TEST_LARGE_INLINE'
    )
    $spillFile = [string]$agyLargeRun.json.out_file
    $spillExists = (-not [string]::IsNullOrWhiteSpace($spillFile)) -and [IO.File]::Exists($spillFile)
    $spillBytes = if ($spillExists) { [IO.File]::ReadAllBytes($spillFile) } else { [byte[]]@() }
    $spillText = if ($spillExists) { [IO.File]::ReadAllText($spillFile, $script:OrchestraUtf8) } else { '' }
    Assert-Test 'Inline response returned when -OutFile omitted, suppressed when -OutFile passed, and >64000 spills to .response.md' (
        $agyWithOutRun.code -eq 0 -and $null -eq $agyWithOutRun.json.response -and $agyWithOutRun.json.response_truncated -eq $false -and
        $agyInlineRun.code -eq 0 -and $agyInlineRun.json.response -ceq 'Successful prose mentioning quota and 429.' -and $agyInlineRun.json.response_truncated -eq $false -and
        $codexInlineRun.code -eq 0 -and $codexInlineRun.json.response -ceq 'quota 429 invalid_encrypted_content' -and $codexInlineRun.json.response_truncated -eq $false -and
        $agyLargeRun.code -eq 0 -and $agyLargeRun.json.response_truncated -eq $true -and
        $agyLargeRun.json.response.Length -eq 64000 -and
        $spillFile -like '*.response.md' -and
        $spillExists -and
        ($spillBytes.Length -lt 3 -or -not ($spillBytes[0] -eq 239 -and $spillBytes[1] -eq 187 -and $spillBytes[2] -eq 191)) -and
        $spillText.Length -eq 65000
    )

    $autoRecState = Join-Path $sandbox 'autorec-state'
    $autoRecPaths = Get-OrchestraPaths -RegistryPath $fixtureRegistry -StateDir $autoRecState
    $autoRecRun = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $autoRecState,
        '-WorkDir', $sandbox, '-Model', 'gemini-4-carbon',
        '-Prompt', 'TEST_SUCCESS', '-AutoRecordOk'
    )
    $autoRecFailRun = Invoke-TestScript -Script $invokeScript -Arguments @(
        '-RegistryPath', $fixtureRegistry, '-StateDir', $autoRecState,
        '-WorkDir', $sandbox, '-Model', 'gemini-4-carbon',
        '-Prompt', 'TEST_AUTH', '-AutoRecordOk'
    )
    $autoRecEvents = @(Read-UsageEvents -Paths $autoRecPaths)
    $autoRecOutcomes = @($autoRecEvents | Where-Object {
        (Get-OrchestraProperty $_ 'type') -eq 'outcome' -and
        (Get-OrchestraProperty $_ 'invocation_id') -eq $autoRecRun.json.invocation_id
    })
    Assert-Test '-AutoRecordOk records outcome=ok in usage.jsonl on exit 0 and skips failed runs' (
        $autoRecRun.code -eq 0 -and
        $autoRecRun.json.outcome_recorded -eq 'ok' -and
        $autoRecOutcomes.Count -eq 1 -and
        $autoRecOutcomes[0].outcome -eq 'ok' -and
        $autoRecFailRun.code -eq 3 -and
        $null -eq $autoRecFailRun.json.outcome_recorded
    )

    # (j) Rev 12: Codex pure-brain --ignore-user-config --ignore-rules + TOML scalar overrides
    $rev12CfgHome = Join-Path $sandbox 'rev12-codex-home'
    [void][IO.Directory]::CreateDirectory($rev12CfgHome)
    $rev12Toml = @'
# Top-level scalar settings
model_provider = "custom-proxy"
forced_login_method = 'chatgpt'
service_tier = "fast" # inline comment

[windows]
sandbox = "elevated"

[plugins."heavy"]
enabled = true
model_provider = "ignored-plugin-provider"

[mcp_servers.mega]
command = "npx"
sandbox = "ignored-mcp-sandbox"

[[hooks]]
service_tier = "ignored-hook-tier"
'@
    [IO.File]::WriteAllText((Join-Path $rev12CfgHome 'config.toml'), $rev12Toml, $script:OrchestraUtf8)
    $parsedCfg = Get-CodexEssentialConfigOverrides -CodexHome $rev12CfgHome
    $prevCodexHomeForCfg = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_CODEX_HOME')
    $cfgDryRun = $null
    try {
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX_HOME', $rev12CfgHome)
        $cfgDryRun = Invoke-TestScript -Script $invokeScript -Arguments (
            $baseArguments + @('-Model', 'gpt-6-astra', '-Prompt', 'TEST', '-DryRun')
        )
    }
    finally {
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX_HOME', $prevCodexHomeForCfg)
    }
    $cfgDryArgv = @($cfgDryRun.json.arguments)
    $ignoreCfgIdx = [Array]::IndexOf($cfgDryArgv, '--ignore-user-config')
    $ignoreRulesIdx = [Array]::IndexOf($cfgDryArgv, '--ignore-rules')
    $cDirIdx = [Array]::IndexOf($cfgDryArgv, '-C')
    Assert-Test 'Codex pure-brain extracts scalar config.toml overrides, ignores plugins/MCP/auth.json, and passes --ignore-user-config --ignore-rules' (
        $parsedCfg.model_provider -eq 'custom-proxy' -and
        $parsedCfg.forced_login_method -eq 'chatgpt' -and
        $parsedCfg.service_tier -eq 'fast' -and
        $parsedCfg.windows_sandbox -eq 'elevated' -and
        $cfgDryRun.code -eq 0 -and
        $cfgDryRun.json.codex_fast_config -eq $true -and
        $ignoreCfgIdx -ge 0 -and $ignoreRulesIdx -gt $ignoreCfgIdx -and $cDirIdx -gt $ignoreRulesIdx -and
        ($cfgDryArgv -contains 'model_provider="custom-proxy"') -and
        ($cfgDryArgv -contains 'forced_login_method="chatgpt"') -and
        ($cfgDryArgv -contains 'service_tier="fast"') -and
        ($cfgDryArgv -contains 'windows.sandbox="elevated"') -and
        ($cfgDryArgv -contains 'shell_tool') -and
        ($cfgDryArgv -contains 'unified_exec') -and
        (-not ($cfgDryArgv -match 'plugins|mcp_servers|ignored-'))
    )

    # (k) Rev 12: -AllowCodexShell, -Tags image_gen, and -FullCodexConfig suppress codex_fast_config
    $suppShellRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gpt-6-astra', '-AllowCodexShell', '-Prompt', 'TEST', '-DryRun')
    )
    $suppImgRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gpt-6-astra', '-Tags', 'image_gen', '-Prompt', 'TEST', '-DryRun')
    )
    $suppFullRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gpt-6-astra', '-FullCodexConfig', '-Prompt', 'TEST', '-DryRun')
    )
    Assert-Test '-AllowCodexShell, -Tags image_gen, and -FullCodexConfig suppress codex_fast_config' (
        $suppShellRun.code -eq 0 -and $suppShellRun.json.codex_fast_config -eq $false -and
        (@($suppShellRun.json.arguments) -notcontains '--ignore-user-config') -and
        (@($suppShellRun.json.arguments) -notcontains '--ignore-rules') -and
        $suppImgRun.code -eq 0 -and $suppImgRun.json.codex_fast_config -eq $false -and
        (@($suppImgRun.json.arguments) -notcontains '--ignore-user-config') -and
        (@($suppImgRun.json.arguments) -notcontains '--ignore-rules') -and
        $suppFullRun.code -eq 0 -and $suppFullRun.json.codex_fast_config -eq $false -and
        $suppFullRun.json.codex_shell_enabled -eq $false -and
        (@($suppFullRun.json.arguments) -contains 'shell_tool') -and
        (@($suppFullRun.json.arguments) -notcontains '--ignore-user-config') -and
        (@($suppFullRun.json.arguments) -notcontains '--ignore-rules')
    )

    # (l) Rev 12: -Ephemeral, -AutoRecordOk --ephemeral, -KeepSession, conflicts, and -AutoRecordOk on null session_id
    $ephPlainRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gpt-6-astra', '-Prompt', 'TEST', '-DryRun')
    )
    $ephFlagRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gpt-6-astra', '-Ephemeral', '-Prompt', 'TEST', '-DryRun')
    )
    $ephAutoRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gpt-6-astra', '-AutoRecordOk', '-Prompt', 'TEST', '-DryRun')
    )
    $ephKeepRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gpt-6-astra', '-AutoRecordOk', '-KeepSession', '-Prompt', 'TEST', '-DryRun')
    )
    $ephResumeAutoRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gpt-6-astra', '-AutoRecordOk', '-Resume', 'sess-123', '-Prompt', 'TEST', '-DryRun')
    )
    $ephBadResume = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gpt-6-astra', '-Ephemeral', '-Resume', 'sess-123', '-Prompt', 'TEST', '-DryRun')
    )
    $ephBadKeep = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gpt-6-astra', '-Ephemeral', '-KeepSession', '-Prompt', 'TEST', '-DryRun')
    )
    Assert-Test 'Codex ephemeral flag activates on -Ephemeral or non-resumed -AutoRecordOk, respects -KeepSession, and rejects conflicts' (
        $ephPlainRun.code -eq 0 -and $ephPlainRun.json.codex_ephemeral -eq $false -and
        (@($ephPlainRun.json.arguments) -notcontains '--ephemeral') -and
        $ephFlagRun.code -eq 0 -and $ephFlagRun.json.codex_ephemeral -eq $true -and
        (@($ephFlagRun.json.arguments) -contains '--ephemeral') -and
        $ephAutoRun.code -eq 0 -and $ephAutoRun.json.codex_ephemeral -eq $true -and
        (@($ephAutoRun.json.arguments) -contains '--ephemeral') -and
        $ephKeepRun.code -eq 0 -and $ephKeepRun.json.codex_ephemeral -eq $false -and
        (@($ephKeepRun.json.arguments) -notcontains '--ephemeral') -and
        $ephResumeAutoRun.code -eq 0 -and $ephResumeAutoRun.json.codex_ephemeral -eq $false -and
        (@($ephResumeAutoRun.json.arguments) -notcontains '--ephemeral') -and
        $ephBadResume.code -eq 2 -and
        $ephBadKeep.code -eq 2
    )

    $noInitAutoState = Join-Path $sandbox 'rev12-noinit-state'
    $noInitAutoPaths = Get-OrchestraPaths -RegistryPath $fixtureRegistry -StateDir $noInitAutoState
    $prevWrapperForNoInit = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER')
    $noInitAutoRun = $null
    try {
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER', $wrapperPath)
        $noInitAutoRun = Invoke-TestScript -Script $invokeScript -Arguments @(
            '-RegistryPath', $fixtureRegistry, '-StateDir', $noInitAutoState,
            '-WorkDir', $sandbox, '-Model', 'gemini-4-carbon',
            '-Prompt', 'TEST_NO_INIT', '-AutoRecordOk'
        )
    }
    finally {
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER', $prevWrapperForNoInit)
    }
    $noInitEvents = @(Read-UsageEvents -Paths $noInitAutoPaths)
    $noInitOutcomes = @($noInitEvents | Where-Object {
        (Get-OrchestraProperty $_ 'type') -eq 'outcome' -and
        (Get-OrchestraProperty $_ 'invocation_id') -eq $noInitAutoRun.json.invocation_id
    })
    Assert-Test '-AutoRecordOk records outcome=ok via InvocationId even when session_id is null (TEST_NO_INIT)' (
        $noInitAutoRun.code -eq 0 -and
        $null -eq $noInitAutoRun.json.session_id -and
        $noInitAutoRun.json.outcome_recorded -eq 'ok' -and
        $noInitOutcomes.Count -eq 1 -and
        $noInitOutcomes[0].outcome -eq 'ok'
    )

    # (m) Rev 12: Direct agy.exe path resolution and -EnableAgySlashCommands toggle
    $dummyAgyExe = Join-Path $sandbox 'agy.exe'
    [IO.File]::WriteAllBytes($dummyAgyExe, [byte[]]@(0))
    $prevAgyWrapper = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER')
    $prevAgyExe = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_AGY_EXE')
    $prevAgyExecBin = [Environment]::GetEnvironmentVariable('AGY_EXEC_BIN')
    $directDefRun = $null
    $directSlashRun = $null
    try {
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER', $null)
        [Environment]::SetEnvironmentVariable('AGY_EXEC_BIN', $null)
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_AGY_EXE', $dummyAgyExe)
        $directDefRun = Invoke-TestScript -Script $invokeScript -Arguments (
            $baseArguments + @('-Model', 'gemini-4-carbon', '-Prompt', 'TEST', '-DryRun')
        )
        $directSlashRun = Invoke-TestScript -Script $invokeScript -Arguments (
            $baseArguments + @('-Model', 'gemini-4-carbon', '-Prompt', 'TEST', '-EnableAgySlashCommands', '-DryRun')
        )
    }
    finally {
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER', $prevAgyWrapper)
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_AGY_EXE', $prevAgyExe)
        [Environment]::SetEnvironmentVariable('AGY_EXEC_BIN', $prevAgyExecBin)
    }
    Assert-Test 'MODEL_ORCHESTRA_AGY_EXE invokes agy.exe directly without -File and toggles --disable-slash-commands cleanly' (
        $directDefRun.code -eq 0 -and
        $directDefRun.json.agy_direct_exe -eq $true -and
        $directDefRun.json.executable -ieq $dummyAgyExe -and
        (@($directDefRun.json.arguments) -notcontains '-File') -and
        $directDefRun.json.agy_slash_commands_disabled -eq $true -and
        (@($directDefRun.json.arguments) -contains '--disable-slash-commands') -and
        $directSlashRun.code -eq 0 -and
        $directSlashRun.json.agy_direct_exe -eq $true -and
        $directSlashRun.json.executable -ieq $dummyAgyExe -and
        (@($directSlashRun.json.arguments) -notcontains '-File') -and
        $directSlashRun.json.agy_slash_commands_disabled -eq $false -and
        (@($directSlashRun.json.arguments) -notcontains '--disable-slash-commands')
    )

    # (n) Rev 12: policy.ultra_fast_tags routes 4H scan -> medium, scan+bulk -> high, bugfix -> xhigh
    $ultraReg = Read-JsonFile -Path $fixtureRegistry
    Set-OrchestraProperty $ultraReg.policy 'ultra_fast_tags' @('scan')
    $ultraRegistry = Join-Path $sandbox 'registry\models-ultra.json'
    Write-JsonAtomic -Path $ultraRegistry -Object $ultraReg
    $ultraBase = @('-RegistryPath', $ultraRegistry, '-StateDir', $fixtureState, '-WorkDir', $sandbox)
    $uScanRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $ultraBase + @('-Model', 'gemini-4-hydrogen', '-Tags', 'scan', '-Prompt', 'TEST', '-DryRun')
    )
    $uMixedRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $ultraBase + @('-Model', 'gemini-4-hydrogen', '-Tags', 'scan,bulk', '-Prompt', 'TEST', '-DryRun')
    )
    $uBugfixRun = Invoke-TestScript -Script $invokeScript -Arguments (
        $ultraBase + @('-Model', 'gemini-4-hydrogen', '-Tags', 'bugfix', '-Prompt', 'TEST', '-DryRun')
    )
    Assert-Test 'policy.ultra_fast_tags routes 4H -Tags scan to medium, scan+bulk to high, and bugfix to xhigh' (
        $uScanRun.code -eq 0 -and $uScanRun.json.effort -eq 'medium' -and
        (@($uScanRun.json.arguments) -contains 'gemini-4-hydrogen-medium') -and
        $uMixedRun.code -eq 0 -and $uMixedRun.json.effort -eq 'high' -and
        (@($uMixedRun.json.arguments) -contains 'gemini-4-hydrogen-high') -and
        $uBugfixRun.code -eq 0 -and $uBugfixRun.json.effort -eq 'xhigh' -and
        (@($uBugfixRun.json.arguments) -contains 'gemini-4-hydrogen-xhigh')
    )

    # (o) Rev 12 fix: Codex pure-brain fallback on unsupported config.toml shapes and backslash/quote escaping
    $cfgTestCases = @(
        @{ Name = 'openai_base_url'; Toml = "openai_base_url = ""https://example.invalid/v1""" },
        @{ Name = 'model_providers'; Toml = "[model_providers.custom]`nbase_url = ""https://example.invalid/v1""" },
        @{ Name = 'inline_windows'; Toml = "windows = { sandbox = ""elevated"" }" },
        @{ Name = 'bad_escape'; Toml = "service_tier = ""bad\u0041""" }
    )
    $prevCfgHomeFallback = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_CODEX_HOME')
    $fallbackChecksOk = $true
    try {
        foreach ($cfgCase in $cfgTestCases) {
            $caseCfgDir = Join-Path $sandbox ('rev12-fb-' + $cfgCase.Name)
            [void][IO.Directory]::CreateDirectory($caseCfgDir)
            [IO.File]::WriteAllText((Join-Path $caseCfgDir 'config.toml'), $cfgCase.Toml, $script:OrchestraUtf8)
            $parsedFb = Get-CodexEssentialConfigOverrides -CodexHome $caseCfgDir
            [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX_HOME', $caseCfgDir)
            $fbRun = Invoke-TestScript -Script $invokeScript -Arguments (
                $baseArguments + @('-Model', 'gpt-6-astra', '-Prompt', 'TEST', '-DryRun')
            )
            if (
                $parsedFb.fast_config_supported -ne $false -or
                $fbRun.code -ne 0 -or
                $fbRun.json.codex_fast_config -ne $false -or
                (@($fbRun.json.arguments) -contains '--ignore-user-config')
            ) {
                $fallbackChecksOk = $false
            }
        }
        $escCfgDir = Join-Path $sandbox 'rev12-esc-cfg'
        [void][IO.Directory]::CreateDirectory($escCfgDir)
        $escToml = "model_provider = 'corp\team'`nservice_tier = 'foo\bar'"
        [IO.File]::WriteAllText((Join-Path $escCfgDir 'config.toml'), $escToml, $script:OrchestraUtf8)
        $parsedEsc = Get-CodexEssentialConfigOverrides -CodexHome $escCfgDir
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX_HOME', $escCfgDir)
        $escRun = Invoke-TestScript -Script $invokeScript -Arguments (
            $baseArguments + @('-Model', 'gpt-6-astra', '-Prompt', 'TEST', '-DryRun')
        )
    }
    finally {
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX_HOME', $prevCfgHomeFallback)
    }
    Assert-Test 'Unsupported config.toml constructs fall back to full config and literal backslashes escape cleanly' (
        $fallbackChecksOk -and
        $parsedEsc.fast_config_supported -eq $true -and
        $parsedEsc.model_provider -eq 'corp\team' -and
        $parsedEsc.service_tier -eq 'foo\bar' -and
        $escRun.code -eq 0 -and
        $escRun.json.codex_fast_config -eq $true -and
        (@($escRun.json.arguments) -contains 'model_provider="corp\\team"') -and
        (@($escRun.json.arguments) -contains 'service_tier="foo\\bar"')
    )

    # (p) Rev 12 fix: Proxy URL redaction in telemetry vs unredacted child env, plus per-scheme agy proxy preservation
    Assert-Test 'ConvertTo-RedactedProxyUrl masks credentials and leaves plain URLs intact' (
        (ConvertTo-RedactedProxyUrl 'http://alice:secret@127.0.0.1:17901') -eq 'http://***@127.0.0.1:17901' -and
        (ConvertTo-RedactedProxyUrl 'http://127.0.0.1:7890') -eq 'http://127.0.0.1:7890'
    )
    $credState = Join-Path $sandbox 'rev12-cred-state'
    $credHome = Join-Path $sandbox 'rev12-cred-home'
    [void][IO.Directory]::CreateDirectory($credHome)
    [IO.File]::WriteAllBytes((Join-Path $credHome 'auth.json'), $script:OrchestraUtf8.GetBytes('{"fixture":"cred"}'))
    $prevCodexBinCred = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_CODEX')
    $prevCodexHomeCred = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_CODEX_HOME')
    $prevProxyCred = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_PROXY')
    $credRun = $null
    try {
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX', $watchdogCodexPath)
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX_HOME', $credHome)
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_PROXY', 'http://alice:secret@127.0.0.1:17901')
        $credRun = Invoke-TestScript -Script $invokeScript -Arguments @(
            '-RegistryPath', $fixtureRegistry, '-StateDir', $credState,
            '-WorkDir', $sandbox, '-Model', 'gpt-6-astra',
            '-Prompt', 'PROXY_CRED_TEST'
        )
    }
    finally {
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX', $prevCodexBinCred)
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_CODEX_HOME', $prevCodexHomeCred)
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_PROXY', $prevProxyCred)
    }
    $credStatus = Read-JsonFile -Path (Join-Path $credState 'live\latest-codex.json')
    Assert-Test 'Credential-bearing MODEL_ORCHESTRA_PROXY is redacted in finalResult/status_file while unredacted in child env' (
        $credRun.code -eq 0 -and
        $credRun.json.proxy -eq 'http://***@127.0.0.1:17901' -and
        $null -ne $credStatus -and
        $credStatus.proxy -eq 'http://***@127.0.0.1:17901' -and
        $credRun.json.response -match 'PROXY=http://alice:secret@127\.0\.0\.1:17901'
    )

    $agyProxyWrapper = Join-Path $sandbox 'fake agy proxy wrapper.ps1'
    $agyProxyWrapperText = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
[Console]::WriteLine('{"event":"init","conversation_id":"proxy-agy-sess","init":{"model":"mock"}}')
$resp = "HTTP=$($env:HTTP_PROXY)|HTTPS=$($env:HTTPS_PROXY)|NODE=$($env:NODE_USE_ENV_PROXY)"
$res = [ordered]@{ event = 'result'; result = [ordered]@{ status = 'SUCCESS'; conversation_id = 'proxy-agy-sess'; response = $resp } }
[Console]::WriteLine(($res | ConvertTo-Json -Compress))
exit 0
'@
    [IO.File]::WriteAllText($agyProxyWrapper, $agyProxyWrapperText, $script:OrchestraUtf8)
    $agyProxyEnvState = Join-Path $sandbox 'rev12-agyproxy-state'
    $savedProxyVars = @{}
    foreach ($pn in @('MODEL_ORCHESTRA_AGY_WRAPPER', 'MODEL_ORCHESTRA_PROXY', 'HTTP_PROXY', 'http_proxy', 'HTTPS_PROXY', 'https_proxy', 'ALL_PROXY', 'all_proxy', 'NODE_USE_ENV_PROXY')) {
        $savedProxyVars[$pn] = [Environment]::GetEnvironmentVariable($pn)
    }
    $agyProxyRun = $null
    try {
        foreach ($pn in $savedProxyVars.Keys) {
            [Environment]::SetEnvironmentVariable($pn, $null)
        }
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER', $agyProxyWrapper)
        [Environment]::SetEnvironmentVariable('HTTP_PROXY', 'http://127.0.0.1:17801')
        [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://127.0.0.1:17802')
        $agyProxyRun = Invoke-TestScript -Script $invokeScript -Arguments @(
            '-RegistryPath', $fixtureRegistry, '-StateDir', $agyProxyEnvState,
            '-WorkDir', $sandbox, '-Model', 'gemini-4-carbon',
            '-Prompt', 'TEST_PROXY_PRESERVE'
        )
    }
    finally {
        foreach ($pn in $savedProxyVars.Keys) {
            [Environment]::SetEnvironmentVariable($pn, $savedProxyVars[$pn])
        }
    }
    Assert-Test 'Agy preserves pre-set per-scheme HTTP_PROXY/HTTPS_PROXY and sets NODE_USE_ENV_PROXY=1' (
        $agyProxyRun.code -eq 0 -and
        $agyProxyRun.json.response -eq 'HTTP=http://127.0.0.1:17801|HTTPS=http://127.0.0.1:17802|NODE=1'
    )

    # (q) Rev 12 fix: Explicit -Ephemeral rejects non-codex channels (exit 2) while -AutoRecordOk stays valid on agy
    $agyEphReject = Invoke-TestScript -Script $invokeScript -Arguments (
        $baseArguments + @('-Model', 'gemini-4-carbon', '-Prompt', 'TEST', '-Ephemeral', '-DryRun')
    )
    $agyAutoOkState = Join-Path $sandbox 'rev12-agy-autook-state'
    $prevWrapperAgyOk = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER')
    $agyAutoOkRun = $null
    try {
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER', $wrapperPath)
        $agyAutoOkRun = Invoke-TestScript -Script $invokeScript -Arguments @(
            '-RegistryPath', $fixtureRegistry, '-StateDir', $agyAutoOkState,
            '-WorkDir', $sandbox, '-Model', 'gemini-4-carbon',
            '-Prompt', 'TEST_SUCCESS', '-AutoRecordOk'
        )
    }
    finally {
        [Environment]::SetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER', $prevWrapperAgyOk)
    }
    Assert-Test 'Explicit -Ephemeral fails with ORCHESTRA_ARGS exit 2 on agy while -AutoRecordOk without -Ephemeral succeeds' (
        $agyEphReject.code -eq 2 -and
        $agyEphReject.json.error -match 'ORCHESTRA_ARGS' -and
        $agyAutoOkRun.code -eq 0 -and
        $agyAutoOkRun.json.outcome_recorded -eq 'ok' -and
        $agyAutoOkRun.json.codex_ephemeral -eq $false
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
            foreach ($roFile in [IO.Directory]::EnumerateFiles($resolved, '*', [IO.SearchOption]::AllDirectories)) {
                try {
                    $attrs = [IO.File]::GetAttributes($roFile)
                    if (($attrs -band [IO.FileAttributes]::ReadOnly) -ne 0) {
                        [IO.File]::SetAttributes($roFile, ($attrs -band (-bnot [IO.FileAttributes]::ReadOnly)))
                    }
                }
                catch {}
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
