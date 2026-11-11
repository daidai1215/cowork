[CmdletBinding()]
param(
    [string]$Model,
    [string]$AdHocChannel,
    [string]$AdHocModelFlag,
    [AllowEmptyString()][string]$Prompt,
    [string]$PromptFile,
    [string]$Access = 'read',
    [string]$WorkDir = (Get-Location).Path,
    [string]$Effort,
    [string]$Resume,
    [string]$OutFile,
    [string]$JsonSchema,
    [string[]]$Tags = @(),
    [int]$TimeoutSec = 1800,
    [switch]$DryRun,
    [string]$RegistryPath,
    [string]$StateDir
)

. (Join-Path $PSScriptRoot 'lib\common.ps1')

function New-InvocationCapture {
    return @{
        session_id = $null; quota = $false; model_error = $false
        failed = $false; saw_completion = $false; agy_response = $null
        timeout = $false; truncated = $false
        auth_interrupted = $false; resume_incompatible = $false
        agy_not_logged_in = $false
        diagnostics = New-Object 'System.Collections.Generic.List[string]'
    }
}

function Set-InvocationError {
    param([hashtable]$Capture, $ErrorObject, [bool]$Codex = $false)
    $kind = Get-OrchestraErrorKind $ErrorObject
    if ($kind -eq 'quota') { $Capture.quota = $true }
    if ($kind -eq 'model') { $Capture.model_error = $true }
    if ($Codex) {
        $interruption = Get-OrchestraCodexInterruption $ErrorObject
        if ($interruption -eq 'auth') { $Capture.auth_interrupted = $true }
        if ($interruption -eq 'resume_incompatible') {
            $Capture.resume_incompatible = $true
        }
    }
}

$watch = [Diagnostics.Stopwatch]::StartNew()
$invocationId = [Guid]::NewGuid().ToString()
$paths = $null
$modelObject = $null
$temporaryPrompt = $null
$exitCode = 0
$errorMessage = $null
$providerExit = $null
$outputPath = $null
$dryData = @{}
$capture = New-InvocationCapture
$modelId = $null
$channel = $null
$policy = $null
$invoke = $null
$attempts = 1
$accountSwitched = $false
$resumeInvalidated = $false
$rotationEnabled = $false
$rotationWaitMs = 0
$maxRetries = 0
$codexHomePath = $null
$adHoc = -not [string]::IsNullOrWhiteSpace($AdHocChannel)

try {
    if (-not $adHoc -and [string]::IsNullOrWhiteSpace($Model)) {
        throw 'ORCHESTRA_ARGS: Specify -Model.'
    }
    $hasPrompt = $PSBoundParameters.ContainsKey('Prompt')
    $hasPromptFile = $PSBoundParameters.ContainsKey('PromptFile')
    if ($hasPrompt -eq $hasPromptFile) {
        throw 'ORCHESTRA_ARGS: Specify exactly one of -Prompt or -PromptFile.'
    }
    if ($Access -notin @('read', 'write') -or $TimeoutSec -lt 0) {
        throw 'ORCHESTRA_ARGS: Invalid access or timeout.'
    }
    if (-not [IO.Directory]::Exists($WorkDir)) {
        throw 'ORCHESTRA_ARGS: WorkDir does not exist.'
    }
    $WorkDir = [IO.Path]::GetFullPath($WorkDir)
    if ($hasPromptFile) {
        if (-not [IO.File]::Exists($PromptFile)) {
            throw 'ORCHESTRA_ARGS: PromptFile does not exist.'
        }
        $Prompt = Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8
    }
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        throw 'ORCHESTRA_ARGS: Prompt cannot be empty.'
    }
    $paths = Get-OrchestraPaths -RegistryPath $RegistryPath -StateDir $StateDir
    if ($adHoc) {
        if ($AdHocChannel -notin @('agy', 'codex') -or
            $AdHocModelFlag -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            throw 'ORCHESTRA_ARGS: AdHoc requires a channel and a complete model slug.'
        }
        $channel = $AdHocChannel
        $modelId = $AdHocModelFlag
        $adHocDefault = 'high'
        $adHocEfforts = @('low', 'medium', 'high', 'xhigh')
        if ($channel -eq 'agy') {
            $adHocEfforts += 'max'
            if ($AdHocModelFlag -match '-(low|medium|high|xhigh|max)$') {
                $adHocDefault = $Matches[1]
                if (-not [string]::IsNullOrWhiteSpace($Effort) -and
                    $Effort -ne $adHocDefault) {
                    throw 'ORCHESTRA_ARGS: Effort conflicts with the explicit agy slug.'
                }
            }
        }
        $modelObject = [pscustomobject]@{
            id = $modelId; channel = $channel
            invoke = [pscustomobject]@{
                model_flag = $AdHocModelFlag
                default_effort = $adHocDefault; efforts = $adHocEfforts
            }
        }
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($AdHocModelFlag)) {
            throw 'ORCHESTRA_ARGS: AdHocModelFlag requires AdHocChannel.'
        }
        $registry = Read-Registry -Paths $paths
        $policy = Get-OrchestraProperty $registry 'policy'
        $state = Read-State -Paths $paths
        $modelId = Resolve-ModelId -Registry $registry -Name $Model
        if ($null -eq $modelId) {
            throw "ORCHESTRA_ARGS: Unknown model or alias: $Model"
        }
        $modelObject = @($registry.models | Where-Object { $_.id -eq $modelId })[0]
        $channel = [string](Get-OrchestraProperty $modelObject 'channel')
        $availability = Get-ModelAvailability -Registry $registry -State $state -Model $modelObject
        if ($availability -in @('unavailable', 'exhausted')) {
            throw "ORCHESTRA_QUOTA: Model $modelId is $availability; no fallback was invoked."
        }
    }

    $invoke = Get-OrchestraProperty $modelObject 'invoke'
    if ([string]::IsNullOrWhiteSpace($Effort)) {
        $Effort = [string](Get-OrchestraProperty $invoke 'default_effort')
    }
    $supportedEfforts = Get-OrchestraProperty $invoke 'efforts' @()
    $supportedEfforts = @($supportedEfforts)
    if ($Effort -notin @('low', 'medium', 'high', 'xhigh', 'max') -or
        $Effort -notin $supportedEfforts) {
        throw "ORCHESTRA_ARGS: Unsupported effort for $modelId."
    }
    $rotationSetting = Get-OrchestraProperty $invoke 'account_rotation' $false
    $rotationEnabled = $channel -eq 'codex' -and
        $rotationSetting -is [bool] -and $rotationSetting -eq $true -and -not $DryRun
    if ($rotationEnabled) {
        $codexHomePath = Get-OrchestraCodexHome
        $rotationWaitMs = Get-OrchestraRotationWaitMs -Invoke $invoke
        $retryText = [string](Get-OrchestraProperty $invoke 'rotation_max_retries' 2)
        if ($retryText -notmatch '^\d+$' -or
            -not [int]::TryParse($retryText, [ref]$maxRetries) -or
            $maxRetries -eq [int]::MaxValue) {
            throw 'ORCHESTRA_ARGS: Invalid rotation_max_retries.'
        }
    }
    $flag = [string](Get-OrchestraProperty $invoke 'model_flag')
    if ([string]::IsNullOrWhiteSpace($flag)) {
        throw 'ORCHESTRA_EXTERNAL: Missing invoke.model_flag.'
    }
    $flag = $flag.Replace('{effort}', $Effort)
    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        $outputPath = $OutFile
        if (-not [IO.Path]::IsPathRooted($outputPath)) {
            $outputPath = Join-Path $WorkDir $outputPath
        }
        $outputPath = [IO.Path]::GetFullPath($outputPath)
    }
    $schemaPath = $null
    if (-not [string]::IsNullOrWhiteSpace($JsonSchema)) {
        $schemaPath = $JsonSchema
        if (-not [IO.Path]::IsPathRooted($schemaPath)) {
            $schemaPath = Join-Path $WorkDir $schemaPath
        }
        $schemaPath = [IO.Path]::GetFullPath($schemaPath)
        if (-not [IO.File]::Exists($schemaPath)) {
            throw 'ORCHESTRA_ARGS: JsonSchema does not exist.'
        }
    }

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    $stdinText = $null
    $promptInFile = $false
    if ($channel -eq 'codex') {
        if ($DryRun) {
            $executable = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_CODEX')
            if ([string]::IsNullOrWhiteSpace($executable)) { $executable = 'codex.exe' }
        }
        else {
            $resolveOptions = @{
                Paths = $paths; NoStateCache = $adHoc
                AccountRotation = $rotationEnabled
            }
            if ($rotationEnabled) {
                $resolveOptions.CodexHome = $codexHomePath
                $resolveOptions.RotationWaitMs = $rotationWaitMs
            }
            $executable = Resolve-CodexExe @resolveOptions
        }
        foreach ($argument in @(
            'exec', '--json', '-s',
            $(if ($Access -eq 'read') { 'read-only' } else { 'workspace-write' }),
            '--skip-git-repo-check', '-C', $WorkDir,
            '-m', $flag, '-c', ('model_reasoning_effort="' + $Effort + '"')
        )) { [void]$arguments.Add([string]$argument) }
        if ($null -ne $outputPath) {
            [void]$arguments.Add('-o')
            [void]$arguments.Add($outputPath)
        }
        if ($null -ne $schemaPath) {
            [void]$arguments.Add('--output-schema')
            [void]$arguments.Add($schemaPath)
        }
        if (-not [string]::IsNullOrWhiteSpace($Resume)) {
            [void]$arguments.Add('resume')
            [void]$arguments.Add($Resume)
        }
        [void]$arguments.Add('-')
        $stdinText = $Prompt
    }
    elseif ($channel -eq 'agy') {
        $executable = 'powershell.exe'
        $wrapper = Get-AgyWrapperPath
        if (-not $DryRun) { $wrapper = Resolve-AgyWrapper }
        foreach ($argument in @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper,
            '--model', $flag, '--output-format', 'stream-json',
            '--print-timeout', (
                $TimeoutSec.ToString([Globalization.CultureInfo]::InvariantCulture) + 's'
            )
        )) { [void]$arguments.Add([string]$argument) }
        if ($Access -eq 'read') {
            [void]$arguments.Add('--mode')
            [void]$arguments.Add('plan')
        }
        else { [void]$arguments.Add('--dangerously-skip-permissions') }
        if (-not [string]::IsNullOrWhiteSpace($Resume)) {
            [void]$arguments.Add('--conversation')
            [void]$arguments.Add($Resume)
        }
        if ($null -ne $schemaPath) {
            [void]$arguments.Add('--json-schema')
            [void]$arguments.Add($schemaPath)
        }
        $prefixLength = (
            @($arguments | ForEach-Object { ConvertTo-OrchestraArgument $_ }) -join ' '
        ).Length
        $promptArgument = $Prompt
        if ($Prompt.Length -gt 24000 -or
            ($prefixLength + (ConvertTo-OrchestraArgument $Prompt).Length) -gt 24000) {
            $promptInFile = $true
            $temporaryPrompt = Join-Path $WorkDir (
                '.orchestra-prompt-' + [Guid]::NewGuid().ToString('N') + '.md'
            )
            $promptArgument = (
                'Read the complete UTF-8 file at "' + $temporaryPrompt +
                '" and execute its instructions as the user prompt. ' +
                'Do not summarize or omit its instructions. ' +
                'If the file cannot be read, report an error.'
            )
            if (-not $DryRun) {
                [IO.File]::WriteAllText($temporaryPrompt, $Prompt, $script:OrchestraUtf8)
            }
        }
        [void]$arguments.Add('-p')
        [void]$arguments.Add($promptArgument)
    }
    else { throw "ORCHESTRA_EXTERNAL: Unsupported channel: $channel" }

    if ($DryRun) {
        $dryData = @{
            dry_run = $true; executable = $executable; executable_resolved = $false
            arguments = $arguments.ToArray(); stdin = $stdinText
            prompt_in_file = $promptInFile; prompt_file = $temporaryPrompt
            access = $Access; work_dir = $WorkDir; effort = $Effort
        }
    }
    else {
        if ($null -ne $outputPath) {
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outputPath))
        }
        $onLine = {
            param([string]$Line)
            try { $eventObject = $Line | ConvertFrom-Json }
            catch {
                [void]$capture.diagnostics.Add($Line)
                [Console]::Error.WriteLine($Line)
                return
            }
            if ($null -eq $eventObject -or $eventObject -is [string] -or
                $eventObject -is [ValueType] -or $eventObject -is [array]) {
                [void]$capture.diagnostics.Add($Line)
                [Console]::Error.WriteLine($Line)
                return
            }
            [Console]::Out.WriteLine($Line)
            [Console]::Out.Flush()
            if ($channel -eq 'codex') {
                $type = [string](Get-OrchestraProperty $eventObject 'type')
                if ($type -eq 'thread.started') {
                    $session = [string](Get-OrchestraProperty $eventObject 'thread_id')
                    if (-not [string]::IsNullOrWhiteSpace($session)) {
                        $capture.session_id = $session
                    }
                }
                if ($type -eq 'turn.completed') { $capture.saw_completion = $true }
                if ($type -in @('error', 'turn.failed')) {
                    $capture.failed = $true
                    Set-InvocationError -Capture $capture -ErrorObject $eventObject -Codex $true
                }
            }
            else {
                $eventName = [string](Get-OrchestraProperty $eventObject 'event')
                if ($eventName -eq 'init') {
                    $session = [string](Get-OrchestraProperty $eventObject 'conversation_id')
                    if (-not [string]::IsNullOrWhiteSpace($session)) {
                        $capture.session_id = $session
                    }
                }
                elseif ($eventName -eq 'result') {
                    $resultObject = Get-OrchestraProperty $eventObject 'result'
                    $session = [string](Get-OrchestraProperty $resultObject 'conversation_id')
                    if (-not [string]::IsNullOrWhiteSpace($session)) {
                        $capture.session_id = $session
                    }
                    $status = [string](Get-OrchestraProperty $resultObject 'status')
                    if ($status -ceq 'SUCCESS') {
                        $capture.saw_completion = $true
                        $capture.agy_response = Get-OrchestraProperty $resultObject 'response'
                    }
                    else {
                        $capture.failed = $true
                        Set-InvocationError -Capture $capture -ErrorObject $resultObject
                        Set-InvocationError -Capture $capture -ErrorObject (
                            Get-OrchestraProperty $resultObject 'response'
                        )
                    }
                }
            }
        }

        $previousAuthAfter = $null
        $previousAuthKnown = $false
        for ($attempt = 1; $attempt -le (1 + $maxRetries); $attempt++) {
            $attempts = $attempt
            $capture = New-InvocationCapture
            $providerExit = $null
            $exitCode = 3
            $errorMessage = $null
            $AttemptSwitched = $false
            $authBefore = $null
            $authAfter = $null
            $authBeforeKnown = $false
            $authAfterKnown = $false

            if ($rotationEnabled) {
                Wait-CockpitQuiet -CodexHome $codexHomePath -RotationWaitMs $rotationWaitMs
                try {
                    $authBefore = Get-CodexAuthFingerprint -CodexHome $codexHomePath
                    $authBeforeKnown = $true
                }
                catch {
                    # Unreadable is unknown, not an absent credential file.
                }
                if ($previousAuthKnown -and $authBeforeKnown -and
                    -not [string]::Equals(
                        [string]$previousAuthAfter, [string]$authBefore,
                        [StringComparison]::Ordinal
                    )) {
                    $AttemptSwitched = $true
                    $accountSwitched = $true
                }
            }

            $processException = $null
            $processResult = $null
            try {
                $processResult = Invoke-OrchestraProcess -FilePath $executable `
                    -Arguments $arguments.ToArray() -InputText $stdinText `
                    -WorkDir $WorkDir -TimeoutSec $TimeoutSec -OnStdout $onLine -ForwardStderr
            }
            catch {
                $processException = $_.Exception.Message
                $capture.failed = $true
                [void]$capture.diagnostics.Add($processException)
            }
            finally {
                if ($rotationEnabled) {
                    try {
                        $authAfter = Get-CodexAuthFingerprint -CodexHome $codexHomePath
                        $authAfterKnown = $true
                    }
                    catch {}
                    if ($authBeforeKnown -and $authAfterKnown -and
                        -not [string]::Equals(
                            [string]$authBefore, [string]$authAfter,
                            [StringComparison]::Ordinal
                        )) {
                        $AttemptSwitched = $true
                        $accountSwitched = $true
                    }
                    $previousAuthAfter = $authAfter
                    $previousAuthKnown = $authAfterKnown
                }
            }

            $stderrText = ''
            if ($null -ne $processResult) {
                $providerExit = $processResult.exit_code
                $capture.timeout = [bool]$processResult.timeout
                $capture.truncated = [bool]$processResult.truncated
                $stderrText = $processResult.stderr -join "`n"
            }
            if ($channel -eq 'agy' -and
                $stderrText -match '(?i)not logged into Antigravity') {
                $capture.agy_not_logged_in = $true
                $capture.failed = $true
            }
            if ($capture.timeout -or $capture.truncated) { $capture.failed = $true }

            $attemptFailed = $null -eq $providerExit -or $providerExit -ne 0 -or
                $capture.failed -or -not $capture.saw_completion
            if ($attemptFailed) {
                # Never classify ordinary successful response text as an error.
                if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
                    Set-InvocationError -Capture $capture -ErrorObject $stderrText `
                        -Codex ($channel -eq 'codex')
                }
                foreach ($diagnostic in $capture.diagnostics) {
                    Set-InvocationError -Capture $capture -ErrorObject $diagnostic `
                        -Codex ($channel -eq 'codex')
                }
            }

            if ($providerExit -eq 0 -and -not $capture.failed -and
                $capture.saw_completion) {
                $capture.quota = $false
                $exitCode = 0
                $errorMessage = $null
                break
            }
            if ($capture.timeout) {
                $errorMessage = 'Invocation timed out; process tree was terminated.'
                break
            }
            if ($capture.model_error) {
                $errorMessage = 'Model is unsupported by the selected executable/account.'
                if ($channel -eq 'codex') {
                    [Console]::Error.WriteLine('Selected Codex executable: ' + $executable)
                }
                break
            }
            if ($capture.agy_not_logged_in) {
                $errorMessage = (
                    'Antigravity credentials are unavailable. Launch through the ' +
                    'authorized main-user wrapper outside the restricted sandbox.'
                )
                [Console]::Error.WriteLine($errorMessage)
                break
            }

            if ($rotationEnabled -and -not [string]::IsNullOrWhiteSpace($Resume) -and
                ($capture.resume_incompatible -or
                    ($accountSwitched -and $attempt -ge 2))) {
                $resumeInvalidated = $true
                $exitCode = 3
                $errorMessage = 'Codex session cannot be resumed after Cockpit account switch; re-run without -Resume.'
                break
            }

            $retryable = $rotationEnabled -and $attempt -le $maxRetries -and
                ($capture.quota -or $AttemptSwitched -or $capture.auth_interrupted)
            if ($retryable) {
                if ($rotationWaitMs -gt 0) {
                    Start-Sleep -Milliseconds $rotationWaitMs
                }
                # The next iteration waits for Cockpit immediately before launch,
                # then compares its fingerprint with this attempt's final one.
                continue
            }

            if ($capture.quota) {
                $exitCode = 4
                $errorMessage = 'Provider quota exhausted after the available attempts.'
            }
            elseif ($capture.truncated) {
                $errorMessage = 'Provider output was truncated: inherited pipes did not reach EOF.'
            }
            elseif ($null -ne $processException) {
                $exitCode = Get-OrchestraExitCode -Message $processException
                $errorMessage = $processException
            }
            else {
                $errorMessage = 'Provider failed or returned no completion event.'
            }
            break
        }

        # Only the terminal quota result may affect model availability.
        if ($exitCode -eq 4 -and $capture.quota -and -not $adHoc) {
            $exhaustedMinutes = 0.0
            try {
                $exhaustedMinutes = [double](Get-OrchestraProperty $invoke 'exhausted_minutes' 0)
            }
            catch { throw 'ORCHESTRA_ARGS: Invalid exhausted_minutes.' }
            if ([double]::IsNaN($exhaustedMinutes) -or
                [double]::IsInfinity($exhaustedMinutes)) {
                throw 'ORCHESTRA_ARGS: Invalid exhausted_minutes.'
            }
            if ($exhaustedMinutes -gt 0) {
                $exhaustedUntil = (Get-OrchestraNow).AddMinutes($exhaustedMinutes)
            }
            else {
                $exhaustedHours = 5.0
                try {
                    $exhaustedHours = [double](Get-OrchestraProperty $policy 'exhausted_hours' 5)
                }
                catch { throw 'ORCHESTRA_ARGS: Invalid policy.exhausted_hours.' }
                if ([double]::IsNaN($exhaustedHours) -or
                    [double]::IsInfinity($exhaustedHours) -or $exhaustedHours -le 0) {
                    throw 'ORCHESTRA_ARGS: Invalid policy.exhausted_hours.'
                }
                $exhaustedUntil = (Get-OrchestraNow).AddHours($exhaustedHours)
            }
            Invoke-WithLock -Paths $paths -Name state -ScriptBlock {
                $freshState = Read-State -Paths $paths
                $exhausted = Get-OrchestraProperty $freshState 'exhausted'
                Set-OrchestraProperty $exhausted $modelId ([pscustomobject]@{
                    until = $exhaustedUntil.ToString('o')
                })
                Save-State -Paths $paths -State $freshState
            }
        }
        if ($exitCode -eq 0 -and $channel -eq 'agy' -and $null -ne $outputPath) {
            if ($null -eq $capture.agy_response) {
                throw 'ORCHESTRA_EXTERNAL: Successful agy result has no response.'
            }
            $responseText = $capture.agy_response
            if ($responseText -isnot [string]) {
                $responseText = ConvertTo-Json -InputObject $responseText -Depth 32
            }
            [IO.File]::WriteAllText(
                $outputPath, [string]$responseText, $script:OrchestraUtf8
            )
        }
    }
}
catch {
    $exitCode = Get-OrchestraExitCode -Message $_.Exception.Message
    $errorMessage = $_.Exception.Message
    [Console]::Error.WriteLine($errorMessage)
}
finally {
    if ($null -ne $temporaryPrompt -and [IO.File]::Exists($temporaryPrompt)) {
        try { [IO.File]::Delete($temporaryPrompt) }
        catch {
            $exitCode = 3
            $errorMessage = 'Could not remove temporary prompt: ' + $temporaryPrompt
            [Console]::Error.WriteLine($errorMessage)
        }
    }
}

$watch.Stop()
$duration = [Math]::Round($watch.Elapsed.TotalSeconds, 3)
if (-not $DryRun -and $null -ne $paths -and $null -ne $modelObject) {
    try {
        Add-UsageEvent -Paths $paths -Event @{
            type = 'invocation'; ad_hoc = $adHoc; invocation_id = $invocationId
            ts = (Get-OrchestraNow).ToString('o')
            model = $modelId; channel = $channel; tags = @($Tags); access = $Access
            duration_sec = $duration; exit = $exitCode
            quota_error = [bool]$capture.quota; session_id = $capture.session_id
            attempts = [int]$attempts
            account_switched = [bool]$accountSwitched
            resume_invalidated = [bool]$resumeInvalidated
        }
    }
    catch {
        $exitCode = Get-OrchestraExitCode -Message $_.Exception.Message
        $errorMessage = 'Usage logging failed: ' + $_.Exception.Message
        [Console]::Error.WriteLine($errorMessage)
    }
}
$finalResult = @{
    orchestra_result = $true; invocation_id = $invocationId
    model = $modelId; channel = $channel; session_id = $capture.session_id
    exit = $exitCode; duration_sec = $duration; out_file = $outputPath
    quota_error = [bool]$capture.quota; timeout = [bool]$capture.timeout
    truncated = [bool]$capture.truncated; ad_hoc = $adHoc
    provider_exit = $providerExit; error = $errorMessage
    attempts = [int]$attempts
    account_switched = [bool]$accountSwitched
    resume_invalidated = [bool]$resumeInvalidated
}
foreach ($key in $dryData.Keys) { $finalResult[$key] = $dryData[$key] }
Write-OrchestraResult -Object $finalResult
exit $exitCode
