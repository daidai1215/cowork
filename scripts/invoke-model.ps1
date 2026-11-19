<#
.SYNOPSIS
Lightweight, stateless one-shot cross-platform model invocation (Codex CLI / AGY CLI).
.DESCRIPTION
Zero file locks, zero slot leases, zero state.json / usage.jsonl writes.
Supports -Preset (code|math|review|ui|office|image), official Codex Fast mode (-ServiceTier / -NoFast),
-ContextFiles line-range slicing (path:start-end), direct CODEX_CLI_PATH resolution,
read-only model enforcement (Opus 5.5), system proxy injection, and passive Cockpit rotation retry.
#>
[CmdletBinding()]
param(
    [string]$Model = '',
    [string]$Preset = '',
    [AllowEmptyString()][string]$Prompt,
    [string]$PromptFile,
    [string]$Access = 'read',
    [string]$WorkDir = (Get-Location).Path,
    [string]$Effort = '',
    [string]$ServiceTier = '',
    [switch]$NoFast,
    [string]$OutFile = '',
    [string]$JsonSchema = '',
    [string[]]$ContextFiles = @(),
    [string[]]$Tags = @(),
    [switch]$StreamStdout,
    [int]$TimeoutSec = 600,
    [int]$ConnectTimeoutSec = 0,
    [switch]$AllowCodexShell,
    [switch]$FullCodexConfig,
    [switch]$KeepSession,
    [switch]$EnableAgySlashCommands,
    [string]$AgySettings = '',
    [switch]$DryRun,
    [string]$RegistryPath = ''
)

. (Join-Path $PSScriptRoot 'lib\common.ps1')

function New-InvocationCapture {
    return @{
        quota = $false; model_error = $false; failed = $false; saw_completion = $false
        agy_response = $null
        codex_messages = New-Object 'System.Collections.Generic.List[string]'
        timeout = $false; startup_timeout = $false; truncated = $false
        reconnect_count = 0; reconnect_aborted = $false; events_count = 0
        first_event_ms = $null
        auth_interrupted = $false; agy_not_logged_in = $false
        input_tokens = $null; output_tokens = $null; thinking_tokens = $null
        cached_tokens = $null; total_tokens = $null
        diagnostics = New-Object 'System.Collections.Generic.List[string]'
    }
}

function ConvertTo-NullableLong {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return $null }
    try { return [long]$Value } catch { return $null }
}

function Get-PresetSpec {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    switch ($Name.Trim().ToLowerInvariant()) {
        'code' {
            return @{
                name = 'code'; model = 'gpt-6.2-astra'; effort = 'high'
                prefix = 'Return production-ready code/diff and critical edge cases only. Omit filler or verbose recap.'
                shell = $false; full_cfg = $false; tag = $null
            }
        }
        'math' {
            return @{
                name = 'math'; model = 'gpt-6.2-astra'; effort = 'xhigh'
                prefix = 'Provide rigorous derivation, boundary/stability verification, and a concise final conclusion.'
                shell = $false; full_cfg = $false; tag = $null
            }
        }
        'review' {
            return @{
                name = 'review'; model = 'gpt-6.2-astra'; effort = 'high'
                prefix = 'Return ONLY concrete issues in `[P0|P1|P2] file:line - issue + 1-sentence fix` format (<=500 words). If none, reply `NO_BLOCKERS`.'
                shell = $false; full_cfg = $false; tag = $null
            }
        }
        'ui' {
            return @{
                name = 'ui'; model = 'claude-opus-5-5'; effort = 'high'
                prefix = 'Review the final UI strictly for visual craft (layout, hierarchy, spacing, typography, color contrast). Output at most Top 5 concrete, high-impact visual fixes (<=500 words).'
                shell = $false; full_cfg = $false; tag = $null
            }
        }
        'office' {
            return @{
                name = 'office'; model = 'gpt-6.2-astra'; effort = 'high'
                prefix = 'Use native Office plugins/tools directly to produce or repair the document. Never hand-roll raw OOXML.'
                shell = $true; full_cfg = $true; tag = 'office'
            }
        }
        'image' {
            return @{
                name = 'image'; model = 'gpt-6.2-astra'; effort = 'high'
                prefix = 'Use native image generation to produce the requested asset cleanly.'
                shell = $true; full_cfg = $true; tag = 'image_gen'
            }
        }
        default {
            throw "ORCHESTRA_ARGS: Unsupported -Preset '$Name'. Use code, math, review, ui, office, or image."
        }
    }
}

function Set-ChildProxyEnvironment {
    param([Parameter(Mandatory = $true)][hashtable]$Environment, [switch]$ForAgy)
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
            if ($shouldSet) { $Environment[$pair.Upper] = $pair.Value }
        }
    }
    else { $rawProxy = $null }

    if ($ForAgy -and [string]$proxyInfo.source -ne 'disabled') {
        $hasAnyProxy = (
            $null -ne $rawProxy -or
            $Environment.ContainsKey('HTTP_PROXY') -or $Environment.ContainsKey('HTTPS_PROXY') -or $Environment.ContainsKey('ALL_PROXY') -or
            -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('HTTP_PROXY')) -or
            -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('http_proxy')) -or
            -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('HTTPS_PROXY')) -or
            -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('https_proxy'))
        )
        if ($hasAnyProxy -and [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('NODE_USE_ENV_PROXY'))) {
            $Environment['NODE_USE_ENV_PROXY'] = '1'
        }
    }
    return @{ raw = $rawProxy; redacted = $redactedProxy }
}

function Set-InvocationError {
    param([hashtable]$Capture, $ErrorObject, [bool]$Codex = $false)
    $kind = Get-OrchestraErrorKind $ErrorObject
    if ($kind -eq 'quota') { $Capture.quota = $true }
    if ($kind -eq 'model') { $Capture.model_error = $true }
    if ($Codex -and (Get-OrchestraCodexAuthInterrupted $ErrorObject)) {
        $Capture.auth_interrupted = $true
    }
}

$watch = [Diagnostics.Stopwatch]::StartNew()
$invocationId = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$temporaryPrompt = $null
$exitCode = 0
$errorMessage = $null
$providerExit = $null
$outputPath = $null
$hasExplicitOutFile = $false
$dryData = @{}
$capture = New-InvocationCapture
$modelId = $null
$channel = $null
$presetName = $null
$effectiveServiceTier = $null
$attempts = 1
$accountSwitched = $false
$codexShellEnabled = $false
$codexFastConfig = $false
$codexModelCatalogCached = $false
$codexEphemeral = $false
$agyDirectExe = $false
$agySlashCommandsDisabled = $false
$effectiveConnectTimeout = 0
$reconnectAbortLimit = 2
$proxyUrl = $null
$reportedProxyUrl = $null
$inlineResponse = $null
$responseTruncated = $false
$spawnToFirstEventMs = $null
$firstEventToDoneMs = $null
$contextEntries = New-Object 'System.Collections.Generic.List[object]'
$rotationEnabled = $false
$rotationWaitMs = 0
$maxRetries = 0
$codexHomePath = $null

try {
    $presetSpec = Get-PresetSpec -Name $Preset
    if ($null -ne $presetSpec) {
        $presetName = [string]$presetSpec.name
        if ([string]::IsNullOrWhiteSpace($Model)) { $Model = [string]$presetSpec.model }
        if ([string]::IsNullOrWhiteSpace($Effort)) { $Effort = [string]$presetSpec.effort }
        if ([bool]$presetSpec.shell) { $AllowCodexShell = $true }
        if ([bool]$presetSpec.full_cfg) { $FullCodexConfig = $true }
        if ($null -ne $presetSpec.tag) { $Tags = @($Tags) + @([string]$presetSpec.tag) }
    }

    if ([string]::IsNullOrWhiteSpace($Model)) {
        throw 'ORCHESTRA_ARGS: Specify -Model or -Preset.'
    }
    $hasPrompt = $PSBoundParameters.ContainsKey('Prompt')
    $hasPromptFile = $PSBoundParameters.ContainsKey('PromptFile')
    if ($hasPrompt -eq $hasPromptFile) {
        throw 'ORCHESTRA_ARGS: Specify exactly one of -Prompt or -PromptFile.'
    }
    if ($Access -notin @('read', 'write') -or $TimeoutSec -lt 0 -or $ConnectTimeoutSec -lt 0) {
        throw 'ORCHESTRA_ARGS: Invalid -Access or timeout.'
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
    if ($null -ne $presetSpec -and -not [string]::IsNullOrWhiteSpace([string]$presetSpec.prefix)) {
        $Prompt = "[Output Contract] $($presetSpec.prefix)`n`n$Prompt"
    }

    # Parse -ContextFiles with optional :start-end (1-based inclusive) line slicing
    $seenCtx = @{}
    foreach ($rawCtx in @($ContextFiles)) {
        if ($null -eq $rawCtx) { continue }
        foreach ($part in ([string]$rawCtx -split ',')) {
            $trimmedCtx = $part.Trim()
            if ($trimmedCtx.Length -eq 0) { continue }
            $filePart = $trimmedCtx
            $lineStart = 0
            $lineEnd = 0
            if ($trimmedCtx -match '^(?<file>.+):(?<start>\d+)(?:-(?<end>\d+))?$') {
                $filePart = $Matches['file']
                $lineStart = [int]$Matches['start']
                $lineEnd = if ([string]::IsNullOrEmpty($Matches['end'])) { $lineStart } else { [int]$Matches['end'] }
                if ($lineStart -lt 1 -or $lineEnd -lt $lineStart) {
                    throw "ORCHESTRA_ARGS: Invalid line range in ContextFile: $trimmedCtx"
                }
            }
            $resolvedCtx = if ([IO.Path]::IsPathRooted($filePart)) { $filePart } else { Join-Path $WorkDir $filePart }
            $resolvedCtx = [IO.Path]::GetFullPath($resolvedCtx)
            if (-not [IO.File]::Exists($resolvedCtx)) {
                throw "ORCHESTRA_ARGS: ContextFile does not exist: $resolvedCtx"
            }
            $ctxKey = "$($resolvedCtx.ToLowerInvariant())|$lineStart|$lineEnd"
            if (-not $seenCtx.ContainsKey($ctxKey)) {
                $seenCtx[$ctxKey] = $true
                [void]$contextEntries.Add([pscustomobject]@{
                    path = $resolvedCtx; start = $lineStart; end = $lineEnd
                })
            }
        }
    }
    if ($contextEntries.Count -gt 0) {
        $ctxBlocks = New-Object 'System.Collections.Generic.List[string]'
        $totalCtxBytes = 0
        foreach ($entry in $contextEntries) {
            $rawBytes = [IO.File]::ReadAllBytes($entry.path)
            $ctxText = if ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF) {
                [System.Text.Encoding]::UTF8.GetString($rawBytes, 3, $rawBytes.Length - 3)
            }
            else { [System.Text.Encoding]::UTF8.GetString($rawBytes) }
            if ($ctxText.Length -gt 0 -and $ctxText[0] -eq [char]0xFEFF) { $ctxText = $ctxText.Substring(1) }
            $ctxText = ($ctxText -replace "\r\n?", "`n").TrimEnd("`n")
            $ctxLabel = [IO.Path]::GetFileName($entry.path)
            if ($entry.start -gt 0) {
                $allLines = @($ctxText -split "`n")
                if ($entry.start -gt $allLines.Count) {
                    throw "ORCHESTRA_ARGS: Start line $($entry.start) exceeds line count ($($allLines.Count)) of $($entry.path)."
                }
                $clampedEnd = [Math]::Min($entry.end, $allLines.Count)
                $slice = New-Object 'System.Collections.Generic.List[string]'
                for ($ln = $entry.start; $ln -le $clampedEnd; $ln++) {
                    [void]$slice.Add("L${ln}: $($allLines[$ln - 1])")
                }
                $ctxText = ($slice.ToArray() -join "`n")
                $ctxLabel = "${ctxLabel}:L$($entry.start)-L${clampedEnd}"
            }
            $totalCtxBytes += $script:OrchestraUtf8.GetByteCount($ctxText)
            [void]$ctxBlocks.Add("=====CONTEXT_PACK: $ctxLabel=====`n$ctxText`n=====END_CONTEXT_PACK=====")
        }
        if ($totalCtxBytes -gt 40960) {
            $kb = [Math]::Round($totalCtxBytes / 1024.0, 1)
            [Console]::Error.WriteLine("Note: Context pack is ${kb}KB (>40KB); consider slicing with path:start-end.")
        }
        $Prompt = ($ctxBlocks.ToArray() -join "`n`n") + "`n`n=====TASK_INSTRUCTIONS=====`n" + $Prompt
    }

    $regPath = Get-RegistryPath -RegistryPath $RegistryPath
    $registry = Read-JsonFile -Path $regPath
    if ($null -eq $registry) {
        throw "ORCHESTRA_EXTERNAL: Missing registry file: $regPath"
    }
    $modelObject = Resolve-ModelEntry -Registry $registry -Name $Model
    if ($null -eq $modelObject) {
        throw "ORCHESTRA_ARGS: Unknown model or alias: $Model"
    }
    $modelId = [string](Get-OrchestraProperty $modelObject 'id')
    $channel = [string](Get-OrchestraProperty $modelObject 'channel')
    $isReadOnlyModel = [bool](Get-OrchestraProperty $modelObject 'read_only' $false)
    $invoke = Get-OrchestraProperty $modelObject 'invoke'

    if ($isReadOnlyModel -and $Access -ne 'read') {
        throw "ORCHESTRA_ARGS: Model $modelId is read-only; use -Access read."
    }
    if (-not [string]::IsNullOrWhiteSpace($AgySettings) -and $channel -ne 'agy') {
        throw 'ORCHESTRA_ARGS: -AgySettings is only supported on the agy channel.'
    }

    $Tags = @(
        foreach ($rawTag in @($Tags)) {
            foreach ($part in ([string]$rawTag -split ',')) {
                $t = $part.Trim()
                if ($t.Length -gt 0) { $t }
            }
        }
    )

    $supportedEfforts = @(Get-OrchestraArray $invoke 'efforts' | ForEach-Object { [string]$_ })
    if ([string]::IsNullOrWhiteSpace($Effort)) {
        $Effort = [string](Get-OrchestraProperty $invoke 'default_effort' 'high')
    }
    if ($Effort -notin @('low', 'medium', 'high', 'xhigh', 'max', 'ultra') -or $Effort -notin $supportedEfforts) {
        throw "ORCHESTRA_ARGS: Unsupported effort '$Effort' for $modelId (supported: $($supportedEfforts -join ', '))."
    }

    $flag = [string](Get-OrchestraProperty $invoke 'model_flag')
    if ([string]::IsNullOrWhiteSpace($flag)) {
        throw 'ORCHESTRA_EXTERNAL: Missing invoke.model_flag.'
    }
    $flag = $flag.Replace('{effort}', $Effort)

    if ($channel -eq 'codex') {
        if ($NoFast) { $effectiveServiceTier = 'default' }
        elseif (-not [string]::IsNullOrWhiteSpace($ServiceTier)) { $effectiveServiceTier = $ServiceTier.Trim().ToLowerInvariant() }
        else { $effectiveServiceTier = [string](Get-OrchestraProperty $invoke 'service_tier' '') }
        if (-not [string]::IsNullOrWhiteSpace($effectiveServiceTier) -and
            $effectiveServiceTier -notin @('default', 'fast', 'flex', 'priority')) {
            throw "ORCHESTRA_ARGS: Unsupported -ServiceTier '$effectiveServiceTier'."
        }
    }

    $rotationSetting = Get-OrchestraProperty $invoke 'account_rotation' $false
    $rotationEnabled = ($channel -eq 'codex' -and $rotationSetting -is [bool] -and $rotationSetting -and -not $DryRun)
    if ($rotationEnabled) {
        $codexHomePath = Get-OrchestraCodexHome
        $rotationWaitMs = Get-OrchestraRotationWaitMs -Invoke $invoke
        $maxRetries = [int](Get-OrchestraProperty $invoke 'rotation_max_retries' 2)
        if ($maxRetries -lt 0) { $maxRetries = 0 }
    }

    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        $outputPath = if ([IO.Path]::IsPathRooted($OutFile)) { $OutFile } else { Join-Path $WorkDir $OutFile }
        $outputPath = [IO.Path]::GetFullPath($outputPath)
        $hasExplicitOutFile = $true
    }
    $schemaPath = $null
    if (-not [string]::IsNullOrWhiteSpace($JsonSchema)) {
        $schemaPath = if ([IO.Path]::IsPathRooted($JsonSchema)) { $JsonSchema } else { Join-Path $WorkDir $JsonSchema }
        $schemaPath = [IO.Path]::GetFullPath($schemaPath)
        if (-not [IO.File]::Exists($schemaPath)) {
            throw 'ORCHESTRA_ARGS: JsonSchema does not exist.'
        }
    }

    $childEnvironment = @{}
    if ($ConnectTimeoutSec -gt 0) { $effectiveConnectTimeout = $ConnectTimeoutSec }
    elseif ($channel -eq 'codex') { $effectiveConnectTimeout = [int](Get-OrchestraProperty $invoke 'connect_timeout_sec' 25) }
    if ($TimeoutSec -gt 0 -and $effectiveConnectTimeout -gt $TimeoutSec) { $effectiveConnectTimeout = $TimeoutSec }
    $reconnectAbortLimit = [int](Get-OrchestraProperty $invoke 'reconnect_abort_count' 2)

    $arguments = New-Object 'System.Collections.Generic.List[string]'
    $stdinText = $null
    $promptInFile = $false

    if ($channel -eq 'codex') {
        $proxySet = Set-ChildProxyEnvironment -Environment $childEnvironment
        $proxyUrl = $proxySet.raw
        $reportedProxyUrl = $proxySet.redacted
        $needsPluginTools = (@($Tags | Where-Object { @('image_gen', 'office', 'ppt') -contains $_ }).Count -gt 0)
        $directWorkspaceWrite = ($Access -eq 'write' -and $null -eq $outputPath)
        $codexShellEnabled = ([bool]$AllowCodexShell -or $needsPluginTools -or $directWorkspaceWrite)
        $codexEphemeral = (-not [bool]$KeepSession)

        $codexHomeForCfg = if (-not [string]::IsNullOrWhiteSpace($codexHomePath)) { $codexHomePath } else { Get-OrchestraCodexHome }
        if ($DryRun) {
            $executable = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_CODEX')
            if ([string]::IsNullOrWhiteSpace($executable)) { $executable = Get-CodexConfigCliPath -CodexHome $codexHomeForCfg }
            if ([string]::IsNullOrWhiteSpace($executable)) { $executable = 'codex.exe' }
        }
        else {
            $executable = Resolve-CodexExe -CodexHome $codexHomeForCfg
            if (-not [string]::IsNullOrWhiteSpace($proxyUrl) -and
                [IO.Path]::GetExtension($executable) -ieq '.exe' -and
                [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_SKIP_PROXY_PRECHECK') -ne '1') {
                $proxyCheck = Test-OrchestraLocalProxy -ProxyUrl $proxyUrl -TimeoutMs 1200
                if (-not $proxyCheck.reachable) {
                    throw ('ORCHESTRA_EXTERNAL: ' + $proxyCheck.detail)
                }
            }
        }

        $codexCfgOverrides = $null
        if ((-not [bool]$FullCodexConfig) -and (-not $codexShellEnabled)) {
            $codexCfgOverrides = Get-CodexEssentialConfigOverrides -CodexHome $codexHomeForCfg
            if ([bool]$codexCfgOverrides.fast_config_supported) { $codexFastConfig = $true }
        }

        foreach ($arg in @(
            'exec', '--json', '-s',
            $(if ($Access -eq 'read') { 'read-only' } else { 'workspace-write' }),
            '--disable', 'unbounded_connection_retries',
            '--skip-git-repo-check'
        )) { [void]$arguments.Add([string]$arg) }

        if ($codexFastConfig) {
            [void]$arguments.Add('--ignore-user-config')
            [void]$arguments.Add('--ignore-rules')
            foreach ($cfgArg in @($codexCfgOverrides.config_args)) { [void]$arguments.Add([string]$cfgArg) }
        }
        if (-not [string]::IsNullOrWhiteSpace($effectiveServiceTier)) {
            [void]$arguments.Add('-c')
            [void]$arguments.Add(('service_tier="' + $effectiveServiceTier + '"'))
        }
        if (-not [bool]$FullCodexConfig) {
            $catalogOverride = Get-CodexModelCatalogOverride -CodexHome $codexHomeForCfg -ModelSlug $flag
            if ([bool]$catalogOverride.applied) {
                foreach ($catArg in @($catalogOverride.config_args)) { [void]$arguments.Add([string]$catArg) }
                $codexModelCatalogCached = $true
            }
        }
        if ($codexEphemeral) { [void]$arguments.Add('--ephemeral') }

        foreach ($arg in @('-C', $WorkDir, '-m', $flag, '-c', ('model_reasoning_effort="' + $Effort + '"'))) {
            [void]$arguments.Add([string]$arg)
        }
        if (-not $codexShellEnabled) {
            foreach ($disableFlag in @('--disable', 'shell_tool', '--disable', 'unified_exec')) {
                [void]$arguments.Add([string]$disableFlag)
            }
        }

        $normWorkRoot = $WorkDir.TrimEnd('\', '/') + '\'
        $addedDirs = @{}
        $extraDirs = New-Object 'System.Collections.Generic.List[string]'
        if ($hasPromptFile) { [void]$extraDirs.Add([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($PromptFile))) }
        foreach ($entry in $contextEntries) { [void]$extraDirs.Add([IO.Path]::GetDirectoryName($entry.path)) }
        if ($null -ne $outputPath) { [void]$extraDirs.Add([IO.Path]::GetDirectoryName($outputPath)) }
        foreach ($candDir in $extraDirs) {
            if ([string]::IsNullOrWhiteSpace($candDir)) { continue }
            $fullCand = [IO.Path]::GetFullPath($candDir)
            $normCand = $fullCand.TrimEnd('\', '/') + '\'
            $candKey = $fullCand.ToLowerInvariant()
            if (-not $normCand.StartsWith($normWorkRoot, [StringComparison]::OrdinalIgnoreCase) -and
                -not $addedDirs.ContainsKey($candKey) -and
                ($DryRun -or [IO.Directory]::Exists($fullCand))) {
                $addedDirs[$candKey] = $true
                [void]$arguments.Add('--add-dir'); [void]$arguments.Add($fullCand)
            }
        }
        if ($null -ne $outputPath) { [void]$arguments.Add('-o'); [void]$arguments.Add($outputPath) }
        if ($null -ne $schemaPath) { [void]$arguments.Add('--output-schema'); [void]$arguments.Add($schemaPath) }
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
            foreach ($arg in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $agyTarget)) {
                [void]$arguments.Add([string]$arg)
            }
        }
        else {
            $agyDirectExe = $true
            $executable = $agyTarget
        }
        foreach ($arg in @('--model', $flag, '--output-format', 'stream-json')) { [void]$arguments.Add([string]$arg) }
        if (-not $EnableAgySlashCommands) {
            $agySlashCommandsDisabled = $true
            [void]$arguments.Add('--disable-slash-commands')
        }
        if (-not [string]::IsNullOrWhiteSpace($AgySettings)) {
            [void]$arguments.Add('--settings'); [void]$arguments.Add($AgySettings)
        }
        [void]$arguments.Add('--print-timeout')
        [void]$arguments.Add($TimeoutSec.ToString([Globalization.CultureInfo]::InvariantCulture) + 's')
        if ($Access -eq 'read') { [void]$arguments.Add('--mode'); [void]$arguments.Add('plan') }
        else { [void]$arguments.Add('--dangerously-skip-permissions') }
        if ($null -ne $schemaPath) { [void]$arguments.Add('--json-schema'); [void]$arguments.Add($schemaPath) }

        $prefixLength = (@($arguments | ForEach-Object { ConvertTo-OrchestraArgument $_ }) -join ' ').Length
        $promptArgument = $Prompt
        if ($Prompt.Length -gt 24000 -or ($prefixLength + (ConvertTo-OrchestraArgument $Prompt).Length) -gt 24000) {
            $promptInFile = $true
            $temporaryPrompt = Join-Path $WorkDir ('.cowork-prompt-' + $invocationId + '.md')
            $promptArgument = 'Read the complete UTF-8 file at "' + $temporaryPrompt + '" and execute its instructions as the user prompt. Do not summarize or omit its instructions. If the file cannot be read, report an error.'
            if (-not $DryRun) {
                [IO.File]::WriteAllText($temporaryPrompt, $Prompt, $script:OrchestraUtf8)
            }
        }
        [void]$arguments.Add('-p'); [void]$arguments.Add($promptArgument)
    }
    else { throw "ORCHESTRA_EXTERNAL: Unsupported channel: $channel" }

    if ($DryRun) {
        $dryData = @{
            dry_run = $true; executable = $executable
            arguments = $arguments.ToArray(); stdin = $stdinText
            prompt_in_file = $promptInFile; access = $Access; work_dir = $WorkDir
            connect_timeout_sec = $effectiveConnectTimeout
        }
    }
    else {
        if ($null -ne $outputPath) {
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outputPath))
        }

        $checkReconnectLine = {
            param([string]$TextLine)
            if ($channel -ne 'codex' -or [string]::IsNullOrWhiteSpace($TextLine)) { return }
            if ($TextLine -match '(?i)(?:\breconnecting\s*\.\.\.|\bstream disconnected\b|\berror sending request for url\b)') {
                $capture.reconnect_count++
                if ($reconnectAbortLimit -gt 0 -and $capture.reconnect_count -ge $reconnectAbortLimit) {
                    $capture.reconnect_aborted = $true
                    $capture.failed = $true
                }
            }
        }
        $onStderr = { param([string]$ErrLine) $null = & $checkReconnectLine $ErrLine }
        $shouldAbort = { return [bool]$capture.reconnect_aborted }

        $onLine = {
            param([string]$Line)
            try { $eventObject = $Line | ConvertFrom-Json }
            catch {
                [void]$capture.diagnostics.Add($Line)
                [Console]::Error.WriteLine($Line)
                $null = & $checkReconnectLine $Line
                return
            }
            if ($null -eq $eventObject -or $eventObject -is [string] -or $eventObject -is [ValueType] -or $eventObject -is [array]) {
                [void]$capture.diagnostics.Add($Line)
                [Console]::Error.WriteLine($Line)
                $null = & $checkReconnectLine $Line
                return
            }
            $capture.events_count++
            if ($null -eq $capture.first_event_ms) {
                $capture.first_event_ms = [Math]::Round($attemptWatch.Elapsed.TotalMilliseconds, 1)
            }
            if ($StreamStdout) { [Console]::Out.WriteLine($Line); [Console]::Out.Flush() }

            if ($channel -eq 'codex') {
                $type = [string](Get-OrchestraProperty $eventObject 'type')
                if ($type -eq 'item.completed') {
                    $itemObj = Get-OrchestraProperty $eventObject 'item'
                    if ($null -ne $itemObj -and [string](Get-OrchestraProperty $itemObj 'type' '') -eq 'agent_message') {
                        $msgText = [string](Get-OrchestraProperty $itemObj 'text' '')
                        if (-not [string]::IsNullOrWhiteSpace($msgText)) { [void]$capture.codex_messages.Add($msgText) }
                    }
                }
                elseif ($type -eq 'turn.completed') {
                    $usageObj = Get-OrchestraProperty $eventObject 'usage'
                    if ($null -ne $usageObj) {
                        $capture.input_tokens = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'input_tokens')
                        $capture.output_tokens = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'output_tokens')
                        $capture.thinking_tokens = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'thinking_tokens')
                        $cachedVal = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'cached_input_tokens')
                        if ($null -eq $cachedVal) { $cachedVal = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'cached_tokens') }
                        $capture.cached_tokens = $cachedVal
                        $capture.total_tokens = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'total_tokens')
                        if ($null -eq $capture.total_tokens -and $null -ne $capture.input_tokens -and $null -ne $capture.output_tokens) {
                            $capture.total_tokens = [long]$capture.input_tokens + [long]$capture.output_tokens
                        }
                    }
                    $capture.saw_completion = $true
                }
                elseif ($type -in @('error', 'turn.failed')) {
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
                if ($eventName -eq 'result') {
                    $resultObject = Get-OrchestraProperty $eventObject 'result'
                    $usageObj = Get-OrchestraProperty $resultObject 'usage'
                    if ($null -eq $usageObj) { $usageObj = Get-OrchestraProperty $eventObject 'usage' }
                    if ($null -ne $usageObj) {
                        $capture.input_tokens = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'input_tokens')
                        $capture.output_tokens = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'output_tokens')
                        $capture.thinking_tokens = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'thinking_tokens')
                        $cacheRead = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'cache_read_tokens')
                        if ($null -eq $cacheRead) { $cacheRead = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'cached_tokens') }
                        if ($null -eq $cacheRead) { $cacheRead = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'cached_input_tokens') }
                        $capture.cached_tokens = $cacheRead
                        $capture.total_tokens = ConvertTo-NullableLong (Get-OrchestraProperty $usageObj 'total_tokens')
                        if ($null -eq $capture.total_tokens -and $null -ne $capture.input_tokens -and $null -ne $capture.output_tokens) {
                            $thinkAdd = if ($null -ne $capture.thinking_tokens) { [long]$capture.thinking_tokens } else { 0L }
                            $capture.total_tokens = [long]$capture.input_tokens + [long]$capture.output_tokens + $thinkAdd
                        }
                    }
                    if ([string](Get-OrchestraProperty $resultObject 'status') -ceq 'SUCCESS') {
                        $capture.saw_completion = $true
                        $capture.agy_response = Get-OrchestraProperty $resultObject 'response'
                    }
                    else {
                        $capture.failed = $true
                        Set-InvocationError -Capture $capture -ErrorObject $resultObject
                        Set-InvocationError -Capture $capture -ErrorObject (Get-OrchestraProperty $resultObject 'response')
                    }
                }
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
            $attemptSwitched = $false
            $authBefore = $null; $authAfter = $null
            $authBeforeKnown = $false; $authAfterKnown = $false

            if ($rotationEnabled) {
                Wait-CockpitQuiet -CodexHome $codexHomePath -RotationWaitMs $rotationWaitMs
                try { $authBefore = Get-CodexAuthFingerprint -CodexHome $codexHomePath; $authBeforeKnown = $true } catch {}
                if ($previousAuthKnown -and $authBeforeKnown -and
                    -not [string]::Equals([string]$previousAuthAfter, [string]$authBefore, [StringComparison]::Ordinal)) {
                    $attemptSwitched = $true; $accountSwitched = $true
                }
            }

            $processException = $null
            $processResult = $null
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
                    try { $authAfter = Get-CodexAuthFingerprint -CodexHome $codexHomePath; $authAfterKnown = $true } catch {}
                    if ($authBeforeKnown -and $authAfterKnown -and
                        -not [string]::Equals([string]$authBefore, [string]$authAfter, [StringComparison]::Ordinal)) {
                        $attemptSwitched = $true; $accountSwitched = $true
                    }
                    $previousAuthAfter = $authAfter; $previousAuthKnown = $authAfterKnown
                }
            }

            $stderrText = ''
            if ($null -ne $processResult) {
                $providerExit = $processResult.exit_code
                $capture.timeout = [bool]$processResult.timeout
                $capture.startup_timeout = [bool](Get-OrchestraProperty $processResult 'startup_timeout' $false)
                $capture.truncated = [bool]$processResult.truncated
                if ([bool](Get-OrchestraProperty $processResult 'aborted' $false)) { $capture.failed = $true }
                $stderrText = $processResult.stderr -join "`n"
            }
            if ($channel -eq 'agy' -and $stderrText -match '(?i)not logged into Antigravity') {
                $capture.agy_not_logged_in = $true; $capture.failed = $true
            }
            if ($capture.timeout -or $capture.truncated) { $capture.failed = $true }

            $attemptFailed = ($null -eq $providerExit -or $providerExit -ne 0 -or $capture.failed -or -not $capture.saw_completion)
            if ($attemptFailed) {
                if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
                    Set-InvocationError -Capture $capture -ErrorObject $stderrText -Codex ($channel -eq 'codex')
                }
                foreach ($diagnostic in $capture.diagnostics) {
                    Set-InvocationError -Capture $capture -ErrorObject $diagnostic -Codex ($channel -eq 'codex')
                }
            }

            if ($providerExit -eq 0 -and -not $capture.failed -and $capture.saw_completion) {
                $capture.quota = $false; $exitCode = 0; $errorMessage = $null; break
            }
            if ($capture.startup_timeout) {
                $errorMessage = "Startup handshake timed out after ${effectiveConnectTimeout}s (check proxy/network)."
                break
            }
            if ($capture.timeout) { $errorMessage = 'Invocation timed out; process tree terminated.'; break }
            if ($capture.reconnect_aborted -and -not $attemptSwitched) {
                $errorMessage = "Connection aborted after $($capture.reconnect_count) repeated disconnect failures."
                break
            }
            if ($capture.model_error) { $errorMessage = 'Model is unsupported by the selected executable/account.'; break }
            if ($capture.agy_not_logged_in) {
                $errorMessage = 'Antigravity credentials unavailable. Run outside sandbox.'
                break
            }

            $retryable = ($rotationEnabled -and $attempt -le $maxRetries -and ($capture.quota -or $attemptSwitched -or $capture.auth_interrupted))
            if ($retryable) {
                if ($rotationWaitMs -gt 0) { Start-Sleep -Milliseconds $rotationWaitMs }
                continue
            }

            if ($capture.quota) { $exitCode = 4; $errorMessage = 'Provider quota exhausted.' }
            elseif ($capture.truncated) { $errorMessage = 'Provider output was truncated.' }
            elseif ($null -ne $processException) { $exitCode = Get-OrchestraExitCode -Message $processException; $errorMessage = $processException }
            else { $errorMessage = 'Provider failed or returned no completion event.' }
            break
        }

        if ($exitCode -eq 0 -and $channel -eq 'agy' -and $null -ne $outputPath) {
            if ($null -eq $capture.agy_response) { throw 'ORCHESTRA_EXTERNAL: Successful agy result has no response.' }
            $responseText = if ($capture.agy_response -is [string]) { $capture.agy_response } else { ConvertTo-Json -InputObject $capture.agy_response -Depth 32 }
            [IO.File]::WriteAllText($outputPath, [string]$responseText, $script:OrchestraUtf8)
        }
        if ($exitCode -eq 0 -and -not $hasExplicitOutFile) {
            $inspectText = ''
            if ($channel -eq 'agy' -and $null -ne $capture.agy_response) {
                $inspectText = if ($capture.agy_response -is [string]) { $capture.agy_response } else { ConvertTo-Json -InputObject $capture.agy_response -Depth 32 }
            }
            elseif ($channel -eq 'codex' -and $capture.codex_messages.Count -gt 0) {
                $inspectText = ($capture.codex_messages.ToArray() -join "`n")
            }
            if ($inspectText.Length -gt 64000) {
                try {
                    $spillPath = Join-Path ([IO.Path]::GetTempPath()) ("cowork-response-$invocationId.md")
                    [IO.File]::WriteAllText($spillPath, $inspectText, $script:OrchestraUtf8)
                    $outputPath = $spillPath
                }
                catch {}
                $inlineResponse = $inspectText.Substring(0, 64000)
                $responseTruncated = $true
            }
            else { $inlineResponse = $inspectText }
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
        try { [IO.File]::Delete($temporaryPrompt) } catch {}
    }
}

$watch.Stop()
$duration = [Math]::Round($watch.Elapsed.TotalSeconds, 3)
$finalResult = [ordered]@{
    model = $modelId
    preset = $presetName
    channel = $channel
    effort = $Effort
    service_tier = $effectiveServiceTier
    exit = $exitCode
    duration_sec = $duration
    response = $inlineResponse
    response_truncated = [bool]$responseTruncated
    out_file = $outputPath
    proxy = $reportedProxyUrl
    quota_error = [bool]$capture.quota
    timeout = [bool]$capture.timeout
    startup_timeout = [bool]$capture.startup_timeout
    attempts = [int]$attempts
    account_switched = [bool]$accountSwitched
    codex_fast_config = [bool]$codexFastConfig
    codex_model_catalog_cached = [bool]$codexModelCatalogCached
    codex_ephemeral = [bool]$codexEphemeral
    agy_direct_exe = [bool]$agyDirectExe
    agy_slash_commands_disabled = [bool]$agySlashCommandsDisabled
    context_files_count = [int]$contextEntries.Count
    provider_exit = $providerExit
    error = $errorMessage
    usage = [ordered]@{
        input_tokens = $capture.input_tokens
        output_tokens = $capture.output_tokens
        thinking_tokens = $capture.thinking_tokens
        cached_tokens = $capture.cached_tokens
        total_tokens = $capture.total_tokens
    }
    timings_ms = [ordered]@{
        spawn_to_first_event_ms = $spawnToFirstEventMs
        first_event_to_done_ms = $firstEventToDoneMs
        total_ms = [Math]::Round($watch.Elapsed.TotalMilliseconds, 1)
    }
}
foreach ($key in $dryData.Keys) { $finalResult[$key] = $dryData[$key] }
Write-OrchestraResult -Object $finalResult
exit $exitCode
