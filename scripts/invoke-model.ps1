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
    [string[]]$ContextFiles = @(),
    [switch]$StreamStdout,
    [int]$TimeoutSec = 1800,
    [int]$ConnectTimeoutSec = 0,
    [int]$SlotWaitSec = 300,
    [switch]$NoSlotWait,
    [switch]$AllowCodexShell,
    [switch]$AutoRecordOk,
    [switch]$FullCodexConfig,
    [switch]$Ephemeral,
    [switch]$KeepSession,
    [switch]$EnableAgySlashCommands,
    [string]$AgySettings = '',
    [string]$StatusFile,
    [switch]$DryRun,
    [string]$RegistryPath,
    [string]$StateDir
)

. (Join-Path $PSScriptRoot 'lib\common.ps1')

function New-InvocationCapture {
    return @{
        session_id = $null; quota = $false; model_error = $false
        failed = $false; saw_completion = $false; agy_response = $null
        codex_messages = New-Object 'System.Collections.Generic.List[string]'
        timeout = $false; startup_timeout = $false; truncated = $false
        reconnect_count = 0; reconnect_aborted = $false; events_count = 0
        first_event_ms = $null
        phase = 'starting'; last_event_type = $null
        auth_interrupted = $false; resume_incompatible = $false
        agy_not_logged_in = $false
        input_tokens = $null; output_tokens = $null; thinking_tokens = $null
        cached_tokens = $null; total_tokens = $null
        diagnostics = New-Object 'System.Collections.Generic.List[string]'
    }
}

function ConvertTo-NullableLong {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return $null }
    try { return [long]$Value }
    catch { return $null }
}

function Set-ChildProxyEnvironment {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Environment,
        [switch]$ForAgy
    )
    $proxyInfo = Get-OrchestraSystemProxy
    $rawProxy = [string]$proxyInfo.proxy
    $redactedProxy = $null
    if (-not [string]::IsNullOrWhiteSpace($rawProxy)) {
        $redactedProxy = ConvertTo-RedactedProxyUrl $rawProxy
        $isOverride = ([string]$proxyInfo.source -eq 'override')
        foreach ($pair in @(
            @{ Upper = 'HTTP_PROXY'; Lower = 'http_proxy'; Value = $rawProxy },
            @{ Upper = 'HTTPS_PROXY'; Lower = 'https_proxy'; Value = $rawProxy },
            @{ Upper = 'ALL_PROXY'; Lower = 'all_proxy'; Value = $rawProxy },
            @{ Upper = 'NO_PROXY'; Lower = 'no_proxy'; Value = 'localhost,127.0.0.1,::1' }
        )) {
            $shouldSet = ($isOverride -and $pair.Upper -ne 'NO_PROXY')
            if (-not $shouldSet) {
                $hasExisting = (
                    -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($pair.Upper)) -or
                    -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($pair.Lower))
                )
                $shouldSet = -not $hasExisting
            }
            if ($shouldSet) {
                $Environment[$pair.Upper] = $pair.Value
            }
        }
    }
    else {
        $rawProxy = $null
    }
    if ($ForAgy -and [string]$proxyInfo.source -ne 'disabled') {
        $hasAnyProxy = (
            $null -ne $rawProxy -or
            $Environment.ContainsKey('HTTP_PROXY') -or
            $Environment.ContainsKey('HTTPS_PROXY') -or
            $Environment.ContainsKey('ALL_PROXY') -or
            -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('HTTP_PROXY')) -or
            -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('http_proxy')) -or
            -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('HTTPS_PROXY')) -or
            -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('https_proxy')) -or
            -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('ALL_PROXY')) -or
            -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('all_proxy'))
        )
        if ($hasAnyProxy -and [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('NODE_USE_ENV_PROXY'))) {
            $Environment['NODE_USE_ENV_PROXY'] = '1'
        }
    }
    return @{ raw = $rawProxy; redacted = $redactedProxy }
}

function Get-ReplanCircuitBreaker {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @{ triggered = $false; detail = $null }
    }
    $pattern = '(?ms)^=====ORCHESTRA_REPLAN_REQUIRED=====\s*\r?\n(?<body>.*?)\r?\n=====END ORCHESTRA_REPLAN_REQUIRED=====\s*$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) {
        return @{ triggered = $false; detail = $null }
    }
    return @{
        triggered = $true
        detail = $match.Groups['body'].Value.Trim()
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
$replanRequired = $false
$replanDetail = $null
$codexShellEnabled = $false
$codexFastConfig = $false
$codexStealthTrimmed = $false
$codexModelCatalogCached = $false
$codexEphemeral = $false
$agyDirectExe = $false
$agySlashCommandsDisabled = $false
$effectiveConnectTimeout = 0
$reconnectAbortLimit = 2
$proxyUrl = $null
$reportedProxyUrl = $null
$liveStatusPath = $null
$latestChannelStatusPath = $null
$explicitStatusPath = $null
$reportedStatusFile = $null
$liveDir = $null
$eventsLogPath = $null
$eventsWriter = $null
$hasExplicitOutFile = $false
$inlineResponse = $null
$responseTruncated = $false
$outcomeRecorded = $null
$poolName = $null
$poolLimits = $null
$slotLease = $null
$slotWaitedSec = 0.0
$slotWaitMs = 0.0
$spawnToFirstEventMs = $null
$firstEventToDoneMs = $null
$slotStaggerMs = 0
$state = $null
$contextFilesList = New-Object 'System.Collections.Generic.List[string]'
$startedUtc = (Get-OrchestraNow).ToString('o')
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
    if ($Ephemeral -and -not [string]::IsNullOrWhiteSpace($Resume)) {
        throw 'ORCHESTRA_ARGS: Cannot combine -Ephemeral with -Resume.'
    }
    if ($Ephemeral -and $KeepSession) {
        throw 'ORCHESTRA_ARGS: Cannot combine -Ephemeral with -KeepSession.'
    }
    if ($Access -notin @('read', 'write') -or $TimeoutSec -lt 0 -or $ConnectTimeoutSec -lt 0 -or $SlotWaitSec -lt 0) {
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
    $seenCtx = @{}
    foreach ($rawCtx in @($ContextFiles)) {
        if ($null -eq $rawCtx) { continue }
        foreach ($part in ([string]$rawCtx -split ',')) {
            $trimmedCtx = $part.Trim()
            if ($trimmedCtx.Length -eq 0) { continue }
            $resolvedCtx = $trimmedCtx
            if (-not [IO.Path]::IsPathRooted($resolvedCtx)) {
                $resolvedCtx = Join-Path $WorkDir $resolvedCtx
            }
            $resolvedCtx = [IO.Path]::GetFullPath($resolvedCtx)
            if (-not [IO.File]::Exists($resolvedCtx)) {
                throw 'ORCHESTRA_ARGS: ContextFile does not exist.'
            }
            $ctxKey = $resolvedCtx.ToLowerInvariant()
            if (-not $seenCtx.ContainsKey($ctxKey)) {
                $seenCtx[$ctxKey] = $true
                [void]$contextFilesList.Add($resolvedCtx)
            }
        }
    }
    if ($contextFilesList.Count -gt 0) {
        $ctxBlocks = New-Object 'System.Collections.Generic.List[string]'
        foreach ($ctxPath in $contextFilesList) {
            $rawBytes = [IO.File]::ReadAllBytes($ctxPath)
            $ctxText = if (
                $rawBytes.Length -ge 3 -and
                $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF
            ) {
                [System.Text.Encoding]::UTF8.GetString($rawBytes, 3, $rawBytes.Length - 3)
            }
            else {
                [System.Text.Encoding]::UTF8.GetString($rawBytes)
            }
            if ($ctxText.Length -gt 0 -and $ctxText[0] -eq [char]0xFEFF) {
                $ctxText = $ctxText.Substring(1)
            }
            $ctxText = ($ctxText -replace "\r\n?", "`n").TrimEnd("`n")
            $ctxFileName = [IO.Path]::GetFileName($ctxPath)
            [void]$ctxBlocks.Add(("=====CONTEXT_PACK: $ctxFileName=====`n$ctxText`n=====END_CONTEXT_PACK====="))
        }
        $staticPrefix = ($ctxBlocks.ToArray() -join "`n`n")
        $Prompt = $staticPrefix + "`n`n=====TASK_INSTRUCTIONS=====`n" + $Prompt
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
        $adHocEfforts = @('low', 'medium', 'high', 'xhigh', 'max', 'ultra')
        if ($channel -eq 'agy') {
            if ($AdHocModelFlag -match '-(low|medium|high|xhigh|max|ultra)$') {
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
        if ($null -ne $paths -and [IO.File]::Exists($paths.Registry)) {
            try {
                $adHocReg = Read-JsonFile -Path $paths.Registry
                if ($null -ne $adHocReg) {
                    $policy = Get-OrchestraProperty $adHocReg 'policy' $null
                }
            }
            catch {}
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
    if ($Ephemeral -and $channel -ne 'codex') {
        throw 'ORCHESTRA_ARGS: -Ephemeral is only supported on the codex channel.'
    }
    if (-not [string]::IsNullOrWhiteSpace($AgySettings) -and $channel -ne 'agy') {
        throw 'ORCHESTRA_ARGS: -AgySettings is only supported on the agy channel.'
    }

    $Tags = @(
        foreach ($rawTag in @($Tags)) {
            foreach ($part in ([string]$rawTag -split ',')) {
                $trimmed = $part.Trim()
                if ($trimmed.Length -gt 0) { $trimmed }
            }
        }
    )
    $invoke = Get-OrchestraProperty $modelObject 'invoke'
    $supportedEfforts = @(
        Get-OrchestraArray $invoke 'efforts' | ForEach-Object { [string]$_ }
    )
    if ([string]::IsNullOrWhiteSpace($Effort)) {
        $Effort = [string](Get-OrchestraProperty $invoke 'default_effort')
        if (-not $adHoc -and $Tags.Count -gt 0) {
            $peakTags = @(
                if ($null -ne $policy) {
                    Get-OrchestraArray $policy 'peak_effort_tags' |
                        ForEach-Object { [string]$_ }
                }
            )
            $hitsPeak = (
                @($Tags | Where-Object { $peakTags -contains $_ }).Count -gt 0
            )
            if ($null -ne $policy) {
                $peakEffort = [string](Get-OrchestraProperty $invoke 'peak_effort' '')
                if (
                    -not [string]::IsNullOrWhiteSpace($peakEffort) -and
                    $hitsPeak -and
                    ($supportedEfforts -contains $peakEffort)
                ) {
                    $Effort = $peakEffort
                }
            }
            $modelTier = [string](Get-OrchestraProperty $modelObject 'tier' '')
            $downshiftEligible = (
                ($modelTier -eq 'fast' -and $Effort -eq 'xhigh') -or
                ($Effort -eq 'xhigh') -or
                ($supportedEfforts -contains 'xhigh')
            )
            if ($downshiftEligible -and -not $hitsPeak) {
                $rawUltra = if ($null -ne $policy) {
                    Get-OrchestraProperty $policy 'ultra_fast_tags' $null
                }
                else { $null }
                $ultraTags = @(
                    if ($null -ne $rawUltra) {
                        $rawUltra | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                    }
                )
                $hitsUltraOnly = (
                    $ultraTags.Count -gt 0 -and
                    $Tags.Count -gt 0 -and
                    (@($Tags | Where-Object { $ultraTags -notcontains $_ }).Count -eq 0)
                )
                if ($hitsUltraOnly -and ($supportedEfforts -contains 'medium')) {
                    $Effort = 'medium'
                }
                elseif ($Effort -eq 'xhigh' -and ($supportedEfforts -contains 'high')) {
                    $rawMech = if ($null -ne $policy) {
                        Get-OrchestraProperty $policy 'mechanical_fast_tags' $null
                    }
                    else { $null }
                    $mechTags = if ($null -eq $rawMech) {
                        @('bulk', 'boilerplate', 'scan', 'test_gen')
                    }
                    else {
                        @($rawMech | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                    }
                    $hitsMech = (@($Tags | Where-Object { $mechTags -contains $_ }).Count -gt 0)
                    if ($hitsMech) {
                        $Effort = 'high'
                    }
                }
            }
        }
    }
    if ($Effort -notin @('low', 'medium', 'high', 'xhigh', 'max', 'ultra') -or
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
    $hasExplicitOutFile = ($null -ne $outputPath)
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

    if (-not [string]::IsNullOrWhiteSpace($StatusFile)) {
        $explicitStatusPath = $StatusFile
        if (-not [IO.Path]::IsPathRooted($explicitStatusPath)) {
            $explicitStatusPath = Join-Path $WorkDir $explicitStatusPath
        }
        $explicitStatusPath = [IO.Path]::GetFullPath($explicitStatusPath)
    }

    $childEnvironment = @{}
    if ($ConnectTimeoutSec -gt 0) {
        $effectiveConnectTimeout = $ConnectTimeoutSec
    }
    elseif ($channel -eq 'codex') {
        $effectiveConnectTimeout = [int](Get-OrchestraProperty $invoke 'connect_timeout_sec' 25)
    }
    if ($TimeoutSec -gt 0 -and $effectiveConnectTimeout -gt $TimeoutSec) {
        $effectiveConnectTimeout = $TimeoutSec
    }
    $reconnectAbortLimit = [int](Get-OrchestraProperty $invoke 'reconnect_abort_count' 2)

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    $stdinText = $null
    $promptInFile = $false
    if ($channel -eq 'codex') {
        $proxySet = Set-ChildProxyEnvironment -Environment $childEnvironment
        $proxyUrl = $proxySet.raw
        $reportedProxyUrl = $proxySet.redacted
        $needsPluginTools = (
            @($Tags | Where-Object { @('image_gen', 'office', 'ppt') -contains $_ }).Count -gt 0
        )
        $directWorkspaceWrite = ($Access -eq 'write' -and $null -eq $outputPath)
        $codexShellEnabled = ([bool]$AllowCodexShell -or $needsPluginTools -or $directWorkspaceWrite)

        if ($DryRun) {
            $executable = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_CODEX')
            if ([string]::IsNullOrWhiteSpace($executable)) { $executable = 'codex.exe' }
        }
        else {
            $resolveOptions = @{
                Paths = $paths; NoStateCache = $adHoc
                AccountRotation = $rotationEnabled
                State = $state
            }
            if ($rotationEnabled) {
                $resolveOptions.CodexHome = $codexHomePath
                $resolveOptions.RotationWaitMs = $rotationWaitMs
            }
            $executable = Resolve-CodexExe @resolveOptions
            if (
                -not [string]::IsNullOrWhiteSpace($proxyUrl) -and
                [IO.Path]::GetExtension($executable) -ieq '.exe' -and
                [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_SKIP_PROXY_PRECHECK') -ne '1'
            ) {
                $proxyCheck = Test-OrchestraLocalProxy -ProxyUrl $proxyUrl -TimeoutMs 1200
                if (-not $proxyCheck.reachable) {
                    throw ('ORCHESTRA_EXTERNAL: ' + $proxyCheck.detail)
                }
            }
        }
        $codexFastConfig = $false
        $codexCfgOverrides = $null
        if ((-not [bool]$FullCodexConfig) -and (-not $codexShellEnabled)) {
            $cfgHome = if (-not [string]::IsNullOrWhiteSpace($codexHomePath)) {
                $codexHomePath
            }
            else {
                Get-OrchestraCodexHome
            }
            $codexCfgOverrides = Get-CodexEssentialConfigOverrides -CodexHome $cfgHome
            if ([bool]$codexCfgOverrides.fast_config_supported) {
                $codexFastConfig = $true
            }
        }
        $codexEphemeral = (
            [bool]$Ephemeral -or (
                [bool]$AutoRecordOk -and
                [string]::IsNullOrWhiteSpace($Resume) -and
                -not [bool]$KeepSession
            )
        )

        foreach ($argument in @(
            'exec', '--json', '-s',
            $(if ($Access -eq 'read') { 'read-only' } else { 'workspace-write' }),
            '--disable', 'unbounded_connection_retries',
            '--skip-git-repo-check'
        )) { [void]$arguments.Add([string]$argument) }
        if ($codexFastConfig) {
            [void]$arguments.Add('--ignore-user-config')
            [void]$arguments.Add('--ignore-rules')
            foreach ($cfgArg in @($codexCfgOverrides.config_args)) {
                [void]$arguments.Add([string]$cfgArg)
            }
            $supportedCodexFeatures = if ($DryRun) { $null } else {
                Get-CodexSupportedFeatures -Executable $executable -Paths $paths -State $state -NoStateCache:$adHoc
            }
            $stealthArgs = @(Get-CodexStealthArguments -SupportedFeatures $supportedCodexFeatures -Tags $Tags)
            foreach ($sArg in $stealthArgs) {
                [void]$arguments.Add([string]$sArg)
            }
            $codexStealthTrimmed = ($stealthArgs.Count -gt 0)
        }
        if (-not [bool]$FullCodexConfig) {
            $catalogHome = if (-not [string]::IsNullOrWhiteSpace($codexHomePath)) {
                $codexHomePath
            }
            else {
                Get-OrchestraCodexHome
            }
            $catalogOverride = Get-CodexModelCatalogOverride -CodexHome $catalogHome -ModelSlug $flag
            if ([bool]$catalogOverride.applied) {
                foreach ($catArg in @($catalogOverride.config_args)) {
                    [void]$arguments.Add([string]$catArg)
                }
                $codexModelCatalogCached = $true
            }
        }
        if ($codexEphemeral) {
            [void]$arguments.Add('--ephemeral')
        }
        foreach ($argument in @(
            '-C', $WorkDir,
            '-m', $flag, '-c', ('model_reasoning_effort="' + $Effort + '"')
        )) { [void]$arguments.Add([string]$argument) }
        if (-not $codexShellEnabled) {
            foreach ($disableFlag in @('--disable', 'shell_tool', '--disable', 'unified_exec')) {
                [void]$arguments.Add([string]$disableFlag)
            }
        }
        $normWorkRoot = $WorkDir.TrimEnd('\', '/') + '\'
        $addedDirs = @{}
        $extraDirCandidates = New-Object 'System.Collections.Generic.List[string]'
        if ($hasPromptFile) {
            [void]$extraDirCandidates.Add([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($PromptFile)))
        }
        foreach ($ctxPath in $contextFilesList) {
            [void]$extraDirCandidates.Add([IO.Path]::GetDirectoryName($ctxPath))
        }
        if ($null -ne $outputPath) {
            [void]$extraDirCandidates.Add([IO.Path]::GetDirectoryName($outputPath))
        }
        foreach ($candDir in $extraDirCandidates) {
            if ([string]::IsNullOrWhiteSpace($candDir)) { continue }
            $fullCand = [IO.Path]::GetFullPath($candDir)
            $normCand = $fullCand.TrimEnd('\', '/') + '\'
            $candKey = $fullCand.ToLowerInvariant()
            if (-not $normCand.StartsWith($normWorkRoot, [StringComparison]::OrdinalIgnoreCase) -and
                -not $addedDirs.ContainsKey($candKey) -and
                ($DryRun -or [IO.Directory]::Exists($fullCand))) {
                $addedDirs[$candKey] = $true
                [void]$arguments.Add('--add-dir')
                [void]$arguments.Add($fullCand)
            }
        }
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
        $proxySet = Set-ChildProxyEnvironment -Environment $childEnvironment -ForAgy
        $proxyUrl = $proxySet.raw
        $reportedProxyUrl = $proxySet.redacted
        $agyTarget = if ($DryRun) { Get-AgyExecutablePath } else { Resolve-AgyExecutable }
        if ([IO.Path]::GetExtension($agyTarget) -ieq '.ps1') {
            $agyDirectExe = $false
            $executable = 'powershell.exe'
            foreach ($argument in @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $agyTarget
            )) { [void]$arguments.Add([string]$argument) }
        }
        else {
            $agyDirectExe = $true
            $executable = $agyTarget
        }
        foreach ($argument in @(
            '--model', $flag, '--output-format', 'stream-json'
        )) { [void]$arguments.Add([string]$argument) }
        if (-not $EnableAgySlashCommands) {
            $agySlashCommandsDisabled = $true
            [void]$arguments.Add('--disable-slash-commands')
        }
        if (-not [string]::IsNullOrWhiteSpace($AgySettings)) {
            [void]$arguments.Add('--settings')
            [void]$arguments.Add($AgySettings)
        }
        foreach ($argument in @(
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

    $poolName = Get-OrchestraPoolName -Model $modelObject -Channel $channel
    $poolLimits = Get-OrchestraPoolLimits -Policy $policy
    $rawCooldownSec = Get-OrchestraProperty $policy 'codex_rotation_cooldown_sec' $null
    $cooldownSec = if ($null -ne $rawCooldownSec) { [int]$rawCooldownSec } else { 15 }
    if ($cooldownSec -lt 0) { $cooldownSec = 15 }
    $rawStaggerMs = Get-OrchestraProperty $policy 'launch_stagger_ms' $null
    $staggerMs = if ($null -ne $rawStaggerMs) { [int]$rawStaggerMs } else { 200 }
    if ($staggerMs -lt 0) { $staggerMs = 0 }

    if ($DryRun) {
        $dryData = @{
            dry_run = $true; executable = $executable; executable_resolved = $false
            arguments = $arguments.ToArray(); stdin = $stdinText
            prompt_in_file = $promptInFile; prompt_file = $temporaryPrompt
            access = $Access; work_dir = $WorkDir; effort = $Effort
            connect_timeout_sec = $effectiveConnectTimeout
            codex_shell_enabled = $codexShellEnabled
            codex_fast_config = $codexFastConfig
            codex_stealth_trimmed = [bool]$codexStealthTrimmed
            codex_model_catalog_cached = [bool]$codexModelCatalogCached
            codex_ephemeral = $codexEphemeral
            agy_direct_exe = $agyDirectExe
            agy_slash_commands_disabled = $agySlashCommandsDisabled
            pool = $poolName
            pool_limit = [int]$poolLimits[$poolName]
        }
    }
    else {
        if ($null -ne $outputPath) {
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outputPath))
        }
        if (-not $adHoc -and $null -ne $paths) {
            $liveDir = Join-Path $paths.StateDir 'live'
            $liveStatusPath = Join-Path $liveDir ($invocationId + '.json')
            $latestChannelStatusPath = if ($channel -eq 'codex') {
                Join-Path $liveDir 'latest-codex.json'
            }
            else {
                Join-Path $liveDir 'latest-agy.json'
            }
            try {
                [void][IO.Directory]::CreateDirectory($liveDir)
                $pruneCutoff = (Get-OrchestraNow).AddDays(-7)
                $guidLivePattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\.(json|response\.md|events\.jsonl)$'
                $protectedLivePaths = @{}
                foreach ($pCandidate in @($liveStatusPath, $latestChannelStatusPath, $explicitStatusPath, $outputPath)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$pCandidate)) {
                        $protectedLivePaths[[IO.Path]::GetFullPath([string]$pCandidate).ToLowerInvariant()] = $true
                    }
                }
                foreach ($prunePattern in @('*.events.jsonl', '*.json', '*.response.md')) {
                    foreach ($oldLiveFile in [IO.Directory]::GetFiles($liveDir, $prunePattern)) {
                        $leafName = [IO.Path]::GetFileName($oldLiveFile)
                        if ($leafName -notmatch $guidLivePattern) { continue }
                        $fullLiveCandidate = [IO.Path]::GetFullPath($oldLiveFile).ToLowerInvariant()
                        if ($protectedLivePaths.ContainsKey($fullLiveCandidate)) { continue }
                        try {
                            if ([IO.File]::GetLastWriteTimeUtc($oldLiveFile) -lt $pruneCutoff) {
                                [IO.File]::Delete($oldLiveFile)
                            }
                        }
                        catch {}
                    }
                }
            }
            catch {}
            $eventsLogPath = Join-Path $liveDir ($invocationId + '.events.jsonl')
            $eventsStream = $null
            try {
                $eventsStream = [IO.File]::Open(
                    $eventsLogPath, [IO.FileMode]::OpenOrCreate,
                    [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite
                )
                [void]$eventsStream.Seek(0, [IO.SeekOrigin]::End)
                $eventsWriter = New-Object IO.StreamWriter($eventsStream, $script:OrchestraUtf8)
                $eventsWriter.AutoFlush = $true
            }
            catch {
                if ($null -ne $eventsWriter) {
                    try { $eventsWriter.Dispose() } catch {}
                    $eventsWriter = $null
                }
                elseif ($null -ne $eventsStream) {
                    try { $eventsStream.Dispose() } catch {}
                }
                $eventsLogPath = $null
            }
        }
        $reportedStatusFile = if ($null -ne $explicitStatusPath) {
            $explicitStatusPath
        }
        else {
            $liveStatusPath
        }

        $writeStatus = {
            param([string]$Phase, [string]$LastEvent = $null, [string]$Detail = $null)
            $capture.phase = $Phase
            if (-not [string]::IsNullOrWhiteSpace($LastEvent)) {
                $capture.last_event_type = $LastEvent
            }
            $targets = @(
                foreach ($p in @($liveStatusPath, $latestChannelStatusPath, $explicitStatusPath)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$p)) { [string]$p }
                }
            ) | Select-Object -Unique
            if (@($targets).Count -eq 0) { return }
            $payload = [ordered]@{
                invocation_id = $invocationId
                model = $modelId
                channel = $channel
                pool = $poolName
                effort = $Effort
                attempt = [int]$attempts
                phase = $Phase
                slot_wait_sec = [double]$slotWaitedSec
                session_id = $capture.session_id
                proxy = $reportedProxyUrl
                codex_shell_enabled = [bool]$codexShellEnabled
                started_utc = $startedUtc
                updated_utc = (Get-OrchestraNow).ToString('o')
                elapsed_sec = [Math]::Round($watch.Elapsed.TotalSeconds, 3)
                events_count = [int]$capture.events_count
                reconnect_count = [int]$capture.reconnect_count
                last_event_type = $capture.last_event_type
                detail = $Detail
            }
            foreach ($targetPath in $targets) {
                try { Write-JsonAtomic -Path $targetPath -Object $payload } catch {}
            }
        }

        $checkReconnectLine = {
            param([string]$TextLine)
            if ($channel -ne 'codex' -or [string]::IsNullOrWhiteSpace($TextLine)) { return }
            if ($TextLine -match '(?i)(?:\breconnecting\s*\.\.\.|\bstream disconnected\b|\berror sending request for url\b)') {
                $capture.reconnect_count++
                $null = & $writeStatus 'reconnecting' 'reconnect_warning' $TextLine
                if ($reconnectAbortLimit -gt 0 -and $capture.reconnect_count -ge $reconnectAbortLimit) {
                    $capture.reconnect_aborted = $true
                    $capture.failed = $true
                }
            }
        }

        $onStderr = {
            param([string]$ErrLine)
            $null = & $checkReconnectLine $ErrLine
        }

        $shouldAbort = {
            return [bool]$capture.reconnect_aborted
        }

        $onLine = {
            param([string]$Line)
            try { $eventObject = $Line | ConvertFrom-Json }
            catch {
                [void]$capture.diagnostics.Add($Line)
                [Console]::Error.WriteLine($Line)
                $null = & $checkReconnectLine $Line
                return
            }
            if ($null -eq $eventObject -or $eventObject -is [string] -or
                $eventObject -is [ValueType] -or $eventObject -is [array]) {
                [void]$capture.diagnostics.Add($Line)
                [Console]::Error.WriteLine($Line)
                $null = & $checkReconnectLine $Line
                return
            }
            $capture.events_count++
            if ($null -eq $capture.first_event_ms) {
                $capture.first_event_ms = [Math]::Round($attemptWatch.Elapsed.TotalMilliseconds, 1)
            }
            if ($null -ne $eventsWriter) {
                try { $eventsWriter.WriteLine($Line) } catch {}
            }
            if ($StreamStdout) {
                [Console]::Out.WriteLine($Line)
                [Console]::Out.Flush()
            }
            if ($channel -eq 'codex') {
                $type = [string](Get-OrchestraProperty $eventObject 'type')
                if ($type -eq 'thread.started') {
                    if ($null -ne $paths -and -not $adHoc) {
                        try { Clear-OrchestraCodexRotationCooldown -Paths $paths } catch {}
                    }
                    $session = [string](Get-OrchestraProperty $eventObject 'thread_id')
                    if (-not [string]::IsNullOrWhiteSpace($session)) {
                        $capture.session_id = $session
                    }
                    $null = & $writeStatus 'connected' 'thread.started' $null
                }
                elseif ($type -eq 'turn.started') {
                    $null = & $writeStatus 'connected' 'turn.started' $null
                }
                elseif ($type -eq 'item.started') {
                    $startedItem = Get-OrchestraProperty $eventObject 'item'
                    $startedItemType = [string](Get-OrchestraProperty $startedItem 'type' '')
                    $nextPhase = switch ($startedItemType) {
                        'reasoning' { 'reasoning' }
                        'agent_message' { 'responding' }
                        default {
                            if (-not [string]::IsNullOrWhiteSpace($startedItemType)) { 'tool_exec' }
                            else { 'connected' }
                        }
                    }
                    $null = & $writeStatus $nextPhase ('item.started:' + $startedItemType) $null
                }
                if ($type -eq 'item.completed') {
                    $itemObj = Get-OrchestraProperty $eventObject 'item'
                    $completedType = [string](Get-OrchestraProperty $itemObj 'type' '')
                    if (
                        $null -ne $itemObj -and
                        $completedType -eq 'agent_message'
                    ) {
                        $msgText = [string](Get-OrchestraProperty $itemObj 'text' '')
                        if (-not [string]::IsNullOrWhiteSpace($msgText)) {
                            [void]$capture.codex_messages.Add($msgText)
                        }
                        $null = & $writeStatus 'responding' 'item.completed:agent_message' $null
                    }
                }
                if ($type -eq 'turn.completed') {
                    $usageObj = Get-OrchestraProperty $eventObject 'usage'
                    if ($null -ne $usageObj) {
                        $capture.input_tokens = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'input_tokens')
                        $capture.output_tokens = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'output_tokens')
                        $capture.thinking_tokens = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'thinking_tokens')
                        $cachedVal = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'cached_input_tokens')
                        if ($null -eq $cachedVal) {
                            $cachedVal = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'cached_tokens')
                        }
                        $capture.cached_tokens = $cachedVal
                        $capture.total_tokens = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'total_tokens')
                        if (
                            $null -eq $capture.total_tokens -and
                            $null -ne $capture.input_tokens -and
                            $null -ne $capture.output_tokens
                        ) {
                            $capture.total_tokens = [long]$capture.input_tokens + [long]$capture.output_tokens
                        }
                    }
                    $capture.saw_completion = $true
                    $null = & $writeStatus 'completed' 'turn.completed' $null
                }
                if ($type -in @('error', 'turn.failed')) {
                    $errMsgText = ConvertTo-Json -InputObject $eventObject -Depth 8 -Compress
                    $null = & $checkReconnectLine $errMsgText
                    if ($type -eq 'turn.failed' -or -not $capture.reconnect_aborted) {
                        $capture.failed = $true
                        Set-InvocationError -Capture $capture -ErrorObject $eventObject -Codex $true
                    }
                }
            }
            else {
                $eventName = [string](Get-OrchestraProperty $eventObject 'event')
                if ($eventName -eq 'init') {
                    $session = [string](Get-OrchestraProperty $eventObject 'conversation_id')
                    if (-not [string]::IsNullOrWhiteSpace($session)) {
                        $capture.session_id = $session
                    }
                    $null = & $writeStatus 'connected' 'init' $null
                }
                elseif ($eventName -eq 'result') {
                    $resultObject = Get-OrchestraProperty $eventObject 'result'
                    $usageObj = Get-OrchestraProperty $resultObject 'usage'
                    if ($null -eq $usageObj) {
                        $usageObj = Get-OrchestraProperty $eventObject 'usage'
                    }
                    if ($null -ne $usageObj) {
                        $capture.input_tokens = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'input_tokens')
                        $capture.output_tokens = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'output_tokens')
                        $capture.thinking_tokens = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'thinking_tokens')
                        $cacheRead = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'cache_read_tokens')
                        if ($null -eq $cacheRead) {
                            $cacheRead = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'cached_tokens')
                        }
                        if ($null -eq $cacheRead) {
                            $cacheRead = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'cached_input_tokens')
                        }
                        $capture.cached_tokens = $cacheRead
                        $capture.total_tokens = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'total_tokens')
                        if (
                            $null -eq $capture.total_tokens -and
                            $null -ne $capture.input_tokens -and
                            $null -ne $capture.output_tokens
                        ) {
                            $thinkAdd = if ($null -ne $capture.thinking_tokens) { [long]$capture.thinking_tokens } else { 0L }
                            $capture.total_tokens = [long]$capture.input_tokens + [long]$capture.output_tokens + $thinkAdd
                        }
                    }
                    $session = [string](Get-OrchestraProperty $resultObject 'conversation_id')
                    if (-not [string]::IsNullOrWhiteSpace($session)) {
                        $capture.session_id = $session
                    }
                    $status = [string](Get-OrchestraProperty $resultObject 'status')
                    if ($status -ceq 'SUCCESS') {
                        $capture.saw_completion = $true
                        $capture.agy_response = Get-OrchestraProperty $resultObject 'response'
                        $null = & $writeStatus 'completed' 'result:SUCCESS' $null
                    }
                    else {
                        $capture.failed = $true
                        Set-InvocationError -Capture $capture -ErrorObject $resultObject
                        Set-InvocationError -Capture $capture -ErrorObject (
                            Get-OrchestraProperty $resultObject 'response'
                        )
                        $null = & $writeStatus 'failed' ('result:' + $status) $null
                    }
                }
            }
        }

        if ($null -ne $paths -and -not [string]::IsNullOrWhiteSpace($poolName)) {
            $poolLimit = [int]$poolLimits[$poolName]
            $slotAcquireWatch = [Diagnostics.Stopwatch]::StartNew()
            try {
                $slotLease = Acquire-OrchestraPoolSlot -Paths $paths -Pool $poolName `
                    -Limit $poolLimit -InvocationId $invocationId -ModelId $modelId `
                    -Channel $channel -WaitSec $SlotWaitSec -StaggerMs $staggerMs -NoWait:$NoSlotWait `
                    -OnQueued {
                        $null = & $writeStatus 'queued_slot' 'slot.wait' ("Waiting for free $poolName slot")
                    }
            }
            finally {
                $slotAcquireWatch.Stop()
                $slotWaitMs = [Math]::Round($slotAcquireWatch.Elapsed.TotalMilliseconds, 1)
                $slotWaitedSec = if ($null -ne $slotLease) {
                    [double]$slotLease.waited_sec
                }
                else {
                    [Math]::Round($slotAcquireWatch.Elapsed.TotalSeconds, 3)
                }
                $slotStaggerMs = if ($null -ne $slotLease) {
                    [int]$slotLease.stagger_ms
                }
                else { 0 }
            }
        }

        $previousAuthAfter = $null
        $previousAuthKnown = $false
        for ($attempt = 1; $attempt -le (1 + $maxRetries); $attempt++) {
            $attempts = $attempt
            $capture = New-InvocationCapture
            $spawnToFirstEventMs = $null
            $firstEventToDoneMs = $null
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
            $null = & $writeStatus 'connecting' 'process.start' $null
            $attemptWatch = [Diagnostics.Stopwatch]::StartNew()
            try {
                $processResult = Invoke-OrchestraProcess -FilePath $executable `
                    -Arguments $arguments.ToArray() -InputText $stdinText `
                    -WorkDir $WorkDir -TimeoutSec $TimeoutSec `
                    -StartupTimeoutSec $effectiveConnectTimeout `
                    -Environment $childEnvironment `
                    -OnStdout $onLine -OnStderr $onStderr `
                    -ShouldAbort $shouldAbort -ForwardStderr
            }
            catch {
                $processException = $_.Exception.Message
                $capture.failed = $true
                [void]$capture.diagnostics.Add($processException)
            }
            finally {
                $attemptWatch.Stop()
                $attemptDoneMs = [Math]::Round($attemptWatch.Elapsed.TotalMilliseconds, 1)
                if ($null -ne $capture.first_event_ms) {
                    $spawnToFirstEventMs = [Math]::Round([double]$capture.first_event_ms, 1)
                    $firstEventToDoneMs = [Math]::Round([Math]::Max(0.0, ($attemptDoneMs - [double]$capture.first_event_ms)), 1)
                }
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
                $capture.startup_timeout = [bool](Get-OrchestraProperty $processResult 'startup_timeout' $false)
                $capture.truncated = [bool]$processResult.truncated
                if ([bool](Get-OrchestraProperty $processResult 'aborted' $false)) {
                    $capture.failed = $true
                }
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
            if ($capture.startup_timeout) {
                $errorMessage = (
                    'Startup handshake timed out after ' + $effectiveConnectTimeout +
                    's without receiving initial provider event (check proxy/network).'
                )
                $null = & $writeStatus 'failed' 'startup_timeout' $errorMessage
                break
            }
            if ($capture.timeout) {
                $errorMessage = 'Invocation timed out; process tree was terminated.'
                $null = & $writeStatus 'failed' 'timeout' $errorMessage
                break
            }
            if ($capture.reconnect_aborted -and -not $AttemptSwitched) {
                $errorMessage = (
                    'Connection aborted after ' + $capture.reconnect_count +
                    ' repeated stream disconnect/reconnect failures.'
                )
                $null = & $writeStatus 'failed' 'reconnect_aborted' $errorMessage
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
                if ($channel -eq 'codex' -and $null -ne $paths -and -not $adHoc) {
                    try {
                        Set-OrchestraCodexRotationCooldown -Paths $paths -CooldownSec $cooldownSec -Reason 'cockpit_rotation_or_429'
                    }
                    catch {}
                }
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
            if ($channel -eq 'codex' -and $null -ne $paths) {
                try {
                    Set-OrchestraCodexRotationCooldown -Paths $paths -CooldownSec $cooldownSec -Reason 'cockpit_rotation_or_429'
                }
                catch {}
            }
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
        if ($exitCode -eq 0) {
            $inspectText = ''
            if ($channel -eq 'agy' -and $null -ne $capture.agy_response) {
                $inspectText = if ($capture.agy_response -is [string]) {
                    $capture.agy_response
                }
                else {
                    ConvertTo-Json -InputObject $capture.agy_response -Depth 32
                }
            }
            elseif ($channel -eq 'codex') {
                if ($capture.codex_messages.Count -gt 0) {
                    $inspectText = ($capture.codex_messages.ToArray() -join "`n")
                }
                elseif ($null -ne $outputPath -and [IO.File]::Exists($outputPath)) {
                    $inspectText = [IO.File]::ReadAllText($outputPath, $script:OrchestraUtf8)
                }
            }
            $replanCheck = Get-ReplanCircuitBreaker -Text $inspectText
            if ($replanCheck.triggered) {
                $replanRequired = $true
                $replanDetail = $replanCheck.detail
            }
            if (-not $hasExplicitOutFile) {
                if ($inspectText.Length -gt 64000) {
                    if ($null -ne $liveDir) {
                        try {
                            [void][IO.Directory]::CreateDirectory($liveDir)
                            $spillPath = Join-Path $liveDir ($invocationId + '.response.md')
                            [IO.File]::WriteAllText($spillPath, $inspectText, $script:OrchestraUtf8)
                            $outputPath = $spillPath
                        }
                        catch {}
                    }
                    $inlineResponse = $inspectText.Substring(0, 64000)
                    $responseTruncated = $true
                }
                else {
                    $inlineResponse = $inspectText
                }
            }
        }
    }
}
catch {
    $exitCode = Get-OrchestraExitCode -Message $_.Exception.Message
    $errorMessage = $_.Exception.Message
    [Console]::Error.WriteLine($errorMessage)
}
finally {
    if ($null -ne $slotLease -and $null -ne $paths) {
        try {
            Release-OrchestraPoolSlot -Paths $paths `
                -LeasePath ([string]$slotLease.lease_path) `
                -InvocationId $invocationId
        }
        catch {}
        $slotLease = $null
    }
    if ($null -ne $eventsWriter) {
        try {
            $eventsWriter.Flush()
            $eventsWriter.Dispose()
        }
        catch {}
        $eventsWriter = $null
    }
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
$timingsMs = [ordered]@{
    slot_wait_ms = [Math]::Round(([double]$slotWaitedSec * 1000.0), 1)
    stagger_ms = [int]$slotStaggerMs
    spawn_to_first_event_ms = $spawnToFirstEventMs
    first_event_to_done_ms = $firstEventToDoneMs
    total_ms = [Math]::Round($watch.Elapsed.TotalMilliseconds, 1)
}
$cacheHitRate = if (
    $null -ne $capture.input_tokens -and
    [long]$capture.input_tokens -gt 0 -and
    $null -ne $capture.cached_tokens
) {
    [Math]::Round(([double]$capture.cached_tokens / [double]$capture.input_tokens), 4)
}
else {
    $null
}
$usageSummary = [ordered]@{
    input_tokens = $capture.input_tokens
    output_tokens = $capture.output_tokens
    thinking_tokens = $capture.thinking_tokens
    cached_tokens = $capture.cached_tokens
    total_tokens = $capture.total_tokens
    cache_hit_rate = $cacheHitRate
}
if (-not $DryRun -and $null -ne $paths -and $null -ne $modelObject) {
    try {
        Add-UsageEvent -Paths $paths -Event @{
            type = 'invocation'; ad_hoc = $adHoc; invocation_id = $invocationId
            ts = (Get-OrchestraNow).ToString('o')
            model = $modelId; channel = $channel; effort = $Effort
            tags = @($Tags); access = $Access
            duration_sec = $duration; exit = $exitCode
            quota_error = [bool]$capture.quota; session_id = $capture.session_id
            attempts = [int]$attempts
            account_switched = [bool]$accountSwitched
            resume_invalidated = [bool]$resumeInvalidated
            replan_required = [bool]$replanRequired
            pool = $poolName
            slot_wait_sec = [double]$slotWaitedSec
            usage = $usageSummary
        }
    }
    catch {
        $exitCode = Get-OrchestraExitCode -Message $_.Exception.Message
        $errorMessage = 'Usage logging failed: ' + $_.Exception.Message
        [Console]::Error.WriteLine($errorMessage)
    }
}
if (
    $AutoRecordOk -and -not $DryRun -and -not $adHoc -and
    $exitCode -eq 0 -and -not $replanRequired -and
    $null -ne $paths -and $null -ne $modelObject
) {
    $autoModelStatus = [string](Get-OrchestraProperty $modelObject 'status' '')
    if ($autoModelStatus -ne 'candidate') {
        try {
            Add-UsageEvent -Paths $paths -Event @{
                type = 'outcome'
                invocation_id = $invocationId
                ts = (Get-OrchestraNow).ToString('o')
                outcome = 'ok'
                note = ''
            }
            $outcomeRecorded = 'ok'
        }
        catch {}
    }
    else {
        $recordScript = Join-Path $PSScriptRoot 'record-outcome.ps1'
        if ([IO.File]::Exists($recordScript)) {
            try {
                $psHostExe = Join-Path $PSHOME 'powershell.exe'
                if (-not [IO.File]::Exists($psHostExe)) { $psHostExe = Join-Path $PSHOME 'pwsh.exe' }
                if (-not [IO.File]::Exists($psHostExe)) { $psHostExe = 'powershell.exe' }
                $recExec = Invoke-OrchestraProcess -FilePath $psHostExe -Arguments @(
                    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                    '-File', $recordScript,
                    '-InvocationId', $invocationId,
                    '-Outcome', 'ok',
                    '-RegistryPath', $paths.Registry,
                    '-StateDir', $paths.StateDir
                ) -WorkDir $WorkDir -TimeoutSec 20 -CaptureStdout
                if (-not $recExec.timeout -and $recExec.exit_code -eq 0) {
                    $outcomeRecorded = 'ok'
                }
            }
            catch {}
        }
    }
}
$finalStatusTargets = @(
    foreach ($p in @($liveStatusPath, $latestChannelStatusPath, $explicitStatusPath)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$p)) { [string]$p }
    }
) | Select-Object -Unique
if (-not $DryRun -and @($finalStatusTargets).Count -gt 0) {
    $finalPhase = if ($exitCode -eq 0) { 'completed' } else { 'failed' }
    $finalStatusPayload = [ordered]@{
        invocation_id = $invocationId
        model = $modelId
        channel = $channel
        pool = $poolName
        effort = $Effort
        attempt = [int]$attempts
        phase = $finalPhase
        slot_wait_sec = [double]$slotWaitedSec
        exit = [int]$exitCode
        session_id = $capture.session_id
        proxy = $reportedProxyUrl
        codex_shell_enabled = [bool]$codexShellEnabled
        started_utc = $startedUtc
        updated_utc = (Get-OrchestraNow).ToString('o')
        elapsed_sec = $duration
        events_count = [int]$capture.events_count
        reconnect_count = [int]$capture.reconnect_count
        startup_timeout = [bool]$capture.startup_timeout
        reconnect_aborted = [bool]$capture.reconnect_aborted
        last_event_type = $capture.last_event_type
        detail = $errorMessage
    }
    foreach ($targetPath in $finalStatusTargets) {
        try { Write-JsonAtomic -Path $targetPath -Object $finalStatusPayload } catch {}
    }
}

$finalResult = @{
    orchestra_result = $true; invocation_id = $invocationId
    model = $modelId; channel = $channel; effort = $Effort
    session_id = $capture.session_id
    exit = $exitCode; duration_sec = $duration; out_file = $outputPath
    quota_error = [bool]$capture.quota; timeout = [bool]$capture.timeout
    startup_timeout = [bool]$capture.startup_timeout
    reconnect_aborted = [bool]$capture.reconnect_aborted
    truncated = [bool]$capture.truncated; ad_hoc = $adHoc
    provider_exit = $providerExit; error = $errorMessage
    attempts = [int]$attempts
    account_switched = [bool]$accountSwitched
    resume_invalidated = [bool]$resumeInvalidated
    replan_required = [bool]$replanRequired
    replan_detail = $replanDetail
    proxy = $reportedProxyUrl
    codex_shell_enabled = [bool]$codexShellEnabled
    codex_fast_config = [bool]$codexFastConfig
    codex_stealth_trimmed = [bool]($codexStealthTrimmed -and ($exitCode -eq 0 -or $capture.events_count -gt 0))
    codex_model_catalog_cached = [bool]$codexModelCatalogCached
    codex_ephemeral = [bool]$codexEphemeral
    agy_direct_exe = [bool]$agyDirectExe
    agy_slash_commands_disabled = [bool]$agySlashCommandsDisabled
    status_file = $reportedStatusFile
    events_file = $eventsLogPath
    context_files_count = [int]$contextFilesList.Count
    pool = $poolName
    slot_wait_sec = [double]$slotWaitedSec
    stagger_ms = [int]$slotStaggerMs
    response = $inlineResponse
    response_truncated = [bool]$responseTruncated
    outcome_recorded = $outcomeRecorded
    usage = $usageSummary
    timings_ms = $timingsMs
}
foreach ($key in $dryData.Keys) { $finalResult[$key] = $dryData[$key] }
Write-OrchestraResult -Object $finalResult
exit $exitCode
