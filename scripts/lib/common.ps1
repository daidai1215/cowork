[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:OrchestraUtf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $script:OrchestraUtf8
$OutputEncoding = $script:OrchestraUtf8

$script:OrchestraRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))

function Get-OrchestraProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return ,$Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return ,$Object[$Name] }
    }
    else {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { return ,$property.Value }
    }
    return ,$Default
}

function Get-OrchestraArray {
    param($Object, [string]$Name)
    $value = Get-OrchestraProperty $Object $Name @()
    foreach ($item in $value) {
        if ($null -ne $item) { $item }
    }
}

function Resolve-Root { return $script:OrchestraRoot }

function Get-RegistryPath {
    param([string]$RegistryPath = '')
    if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
        return [IO.Path]::GetFullPath((Join-Path $script:OrchestraRoot 'registry\models.json'))
    }
    return [IO.Path]::GetFullPath($RegistryPath)
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $null }
    $fs = $null
    $sr = $null
    try {
        $fs = New-Object IO.FileStream(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        )
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8, $true)
        $text = $sr.ReadToEnd()
    }
    finally {
        if ($null -ne $sr) { $sr.Dispose() }
        elseif ($null -ne $fs) { $fs.Dispose() }
    }
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "ORCHESTRA_EXTERNAL: Empty JSON file: $Path"
    }
    return ($text | ConvertFrom-Json)
}

function Resolve-ModelEntry {
    param(
        [Parameter(Mandatory = $true)]$Registry,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $candidate = $Name.Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $null }

    $aliases = Get-OrchestraProperty $Registry 'aliases'
    $aliased = Get-OrchestraProperty $aliases $candidate
    if ($aliased -is [string] -and -not [string]::IsNullOrWhiteSpace($aliased)) {
        $candidate = $aliased.Trim()
    }

    $models = @(Get-OrchestraArray $Registry 'models')
    foreach ($m in $models) {
        if ([string](Get-OrchestraProperty $m 'id' '') -ieq $candidate) { return $m }
    }

    $baseSlug = [regex]::Replace($candidate, '-(low|medium|high|xhigh|max|ultra)$', '')
    if ($baseSlug -ne $candidate) {
        foreach ($m in $models) {
            if ([string](Get-OrchestraProperty $m 'id' '') -ieq $baseSlug) { return $m }
        }
    }
    return $null
}

function ConvertTo-OrchestraArgument {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value) { $Value = '' }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Stop-OrchestraProcessTree {
    param([Diagnostics.Process]$Process)
    if ($Process.HasExited) { return }
    $killer = $null
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = 'taskkill.exe'
        $info.Arguments = '/T /F /PID ' + $Process.Id
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $killer = [Diagnostics.Process]::Start($info)
        $null = $killer.StandardOutput.ReadToEndAsync()
        $null = $killer.StandardError.ReadToEndAsync()
        if (-not $killer.WaitForExit(3000)) {
            try { $killer.Kill() } catch {}
        }
    }
    catch { [Console]::Error.WriteLine('taskkill failed: ' + $_.Exception.Message) }
    finally { if ($null -ne $killer) { $killer.Dispose() } }
    if (-not $Process.HasExited) {
        try { $Process.Kill() } catch {}
    }
}

function ConvertTo-RedactedProxyUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    return ([regex]::Replace($Url, '^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@]+@', '${1}***@'))
}

function Get-OrchestraSystemProxy {
    $override = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_PROXY')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $trimmed = $override.Trim()
        if ($trimmed -ieq 'NONE') {
            return @{ proxy = $null; host = $null; port = 0; source = 'disabled' }
        }
        if ($trimmed -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $trimmed = 'http://' + $trimmed }
        $u = $null
        if ([Uri]::TryCreate($trimmed, [UriKind]::Absolute, [ref]$u)) {
            return @{ proxy = $trimmed; host = $u.Host; port = $u.Port; source = 'override' }
        }
        return @{ proxy = $trimmed; host = $null; port = 0; source = 'override' }
    }

    try {
        $regKey = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        $proxyEnable = [Microsoft.Win32.Registry]::GetValue($regKey, 'ProxyEnable', 0)
        $proxyServer = [Microsoft.Win32.Registry]::GetValue($regKey, 'ProxyServer', $null)
        if ($null -ne $proxyEnable -and [int]$proxyEnable -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$proxyServer)) {
            $raw = ([string]$proxyServer).Trim()
            if ($raw -match '(?:^|;)https=([^;]+)') { $raw = $Matches[1].Trim() }
            elseif ($raw -match '(?:^|;)http=([^;]+)') { $raw = $Matches[1].Trim() }
            elseif ($raw.Contains(';')) { $raw = ($raw -split ';')[0].Trim() }
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                if ($raw -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $raw = 'http://' + $raw }
                $u = $null
                if ([Uri]::TryCreate($raw, [UriKind]::Absolute, [ref]$u)) {
                    return @{ proxy = $raw; host = $u.Host; port = $u.Port; source = 'hkcu' }
                }
                return @{ proxy = $raw; host = $null; port = 0; source = 'hkcu' }
            }
        }
    }
    catch {}

    foreach ($envName in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy')) {
        $val = [Environment]::GetEnvironmentVariable($envName)
        if (-not [string]::IsNullOrWhiteSpace($val)) {
            $clean = $val.Trim()
            if ($clean -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') { $clean = 'http://' + $clean }
            $u = $null
            if ([Uri]::TryCreate($clean, [UriKind]::Absolute, [ref]$u)) {
                return @{ proxy = $clean; host = $u.Host; port = $u.Port; source = 'env' }
            }
            return @{ proxy = $clean; host = $null; port = 0; source = 'env' }
        }
    }
    return @{ proxy = $null; host = $null; port = 0; source = 'none' }
}

function Test-OrchestraLocalProxy {
    param([string]$ProxyUrl, [int]$TimeoutMs = 1200)
    if ([string]::IsNullOrWhiteSpace($ProxyUrl)) {
        return @{ checked = $false; reachable = $true; detail = 'No proxy configured.' }
    }
    $safeDetailUrl = ConvertTo-RedactedProxyUrl -Url $ProxyUrl
    $uri = $null
    if (-not [Uri]::TryCreate($ProxyUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Port -le 0) {
        return @{ checked = $false; reachable = $true; detail = $safeDetailUrl }
    }
    $hostLower = ([string]$uri.Host).Trim('[', ']').ToLowerInvariant()
    if ($hostLower -notin @('127.0.0.1', 'localhost', '::1')) {
        return @{ checked = $false; reachable = $true; detail = $safeDetailUrl }
    }
    $connectHost = if ($hostLower -eq 'localhost') { '127.0.0.1' } else { $hostLower }
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $connectTask = $tcp.ConnectAsync($connectHost, $uri.Port)
        $completed = $false
        try { $completed = $connectTask.Wait($TimeoutMs) } catch { $completed = $false }
        if ($completed -and $tcp.Connected -and -not $connectTask.IsFaulted) {
            return @{ checked = $true; reachable = $true; detail = $safeDetailUrl }
        }
        return @{
            checked = $true
            reachable = $false
            detail = "Local proxy $safeDetailUrl is unreachable (TCP connect failed within ${TimeoutMs}ms)."
        }
    }
    catch {
        return @{
            checked = $true
            reachable = $false
            detail = "Local proxy $safeDetailUrl check failed: $($_.Exception.Message)"
        }
    }
    finally {
        try { $tcp.Dispose() } catch {}
    }
}

function Invoke-OrchestraProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [AllowNull()][string]$InputText = $null,
        [string]$WorkDir,
        [int]$TimeoutSec = 600,
        [int]$StartupTimeoutSec = 0,
        [hashtable]$Environment = @{},
        [scriptblock]$OnStdout,
        [scriptblock]$OnStderr,
        [scriptblock]$ShouldAbort,
        [switch]$ForwardStderr,
        [switch]$CaptureStdout
    )
    $rawQuoted = @(foreach ($argument in $Arguments) { ConvertTo-OrchestraArgument -Value $argument })
    if (($rawQuoted -join ' ').Length -gt 30000) {
        throw 'ORCHESTRA_ARGS: Windows command line exceeds safe length.'
    }
    $launchFile = $FilePath
    $launchArguments = @($Arguments)
    $shimScript = $null
    $shimArgv = $null
    if ([IO.Path]::GetExtension($FilePath) -ieq '.ps1') {
        $launchFile = Join-Path $PSHOME 'powershell.exe'
        if (-not [IO.File]::Exists($launchFile)) { $launchFile = 'powershell.exe' }
        $shimScript = [IO.Path]::GetFullPath($FilePath)
        $shimArgv = ''
        if ($launchArguments.Count -gt 0) {
            $shimArgv = ':' + (@(foreach ($argument in $launchArguments) {
                [Convert]::ToBase64String($script:OrchestraUtf8.GetBytes([string]$argument))
            }) -join ',')
        }
        $launchArguments = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $PSScriptRoot 'ps1-shim-runner.ps1')
        )
    }
    $quoted = @(foreach ($argument in $launchArguments) { ConvertTo-OrchestraArgument -Value $argument })
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $launchFile
    $info.Arguments = ($quoted -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    if ($null -ne $Environment) {
        foreach ($envKey in $Environment.Keys) {
            $envVal = $Environment[$envKey]
            if ($null -eq $envVal) {
                if ($info.EnvironmentVariables.ContainsKey([string]$envKey)) {
                    $info.EnvironmentVariables.Remove([string]$envKey)
                }
            }
            else {
                $info.EnvironmentVariables[[string]$envKey] = [string]$envVal
            }
        }
    }
    if ($null -ne $shimScript) {
        $info.EnvironmentVariables['ORCHESTRA_SHIM_SCRIPT'] = $shimScript
        $info.EnvironmentVariables['ORCHESTRA_SHIM_ARGV'] = $shimArgv
    }
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $script:OrchestraUtf8
    $info.StandardErrorEncoding = $script:OrchestraUtf8
    if (-not [string]::IsNullOrWhiteSpace($WorkDir)) {
        $info.WorkingDirectory = $WorkDir
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $stdout = New-Object 'System.Collections.Generic.List[string]'
    $stderr = New-Object 'System.Collections.Generic.List[string]'
    $writer = $null
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $startupTimedOut = $false
    $aborted = $false
    $firstStdoutSeen = $false
    $truncated = $false
    $exitSeenAt = $null
    $started = $false
    try {
        $started = $process.Start()
        if (-not $started) { throw 'ORCHESTRA_EXTERNAL: Process did not start.' }
        $outputTask = $process.StandardOutput.ReadLineAsync()
        $errorTask = $process.StandardError.ReadLineAsync()
        $outputDone = $false
        $errorDone = $false
        $inputTask = $null
        if ($null -ne $InputText) {
            $writer = New-Object IO.StreamWriter($process.StandardInput.BaseStream, $script:OrchestraUtf8)
            try { $inputTask = $writer.WriteAsync($InputText + [Environment]::NewLine) }
            catch {
                try { $writer.Dispose() } catch {}
                $writer = $null
            }
        }
        else { $process.StandardInput.Close() }

        while ($true) {
            if (-not $timedOut -and -not $aborted -and $TimeoutSec -gt 0 -and
                $watch.Elapsed.TotalSeconds -ge $TimeoutSec) {
                $timedOut = $true
                Stop-OrchestraProcessTree -Process $process
            }
            if (-not $timedOut -and -not $aborted -and -not $firstStdoutSeen -and
                $StartupTimeoutSec -gt 0 -and
                $watch.Elapsed.TotalSeconds -ge $StartupTimeoutSec) {
                $startupTimedOut = $true
                $timedOut = $true
                Stop-OrchestraProcessTree -Process $process
            }
            if ($process.HasExited -and $null -eq $exitSeenAt) {
                $exitSeenAt = $watch.Elapsed.TotalSeconds
            }
            $progress = $false
            if ($null -ne $inputTask -and $inputTask.IsCompleted) {
                try { $null = $inputTask.GetAwaiter().GetResult() } catch {}
                try { $writer.Dispose() } catch {}
                $writer = $null
                $inputTask = $null
                $progress = $true
            }
            for ($batch = 0; $batch -lt 256 -and -not $outputDone -and $outputTask.IsCompleted; $batch++) {
                $line = $outputTask.GetAwaiter().GetResult()
                $progress = $true
                if ($null -eq $line) { $outputDone = $true; break }
                $firstStdoutSeen = $true
                if ($CaptureStdout) { [void]$stdout.Add($line) }
                if ($null -ne $OnStdout) { $null = & $OnStdout $line }
                $outputTask = $process.StandardOutput.ReadLineAsync()
            }
            for ($batch = 0; $batch -lt 256 -and -not $errorDone -and $errorTask.IsCompleted; $batch++) {
                $line = $errorTask.GetAwaiter().GetResult()
                $progress = $true
                if ($null -eq $line) { $errorDone = $true; break }
                [void]$stderr.Add($line)
                if ($ForwardStderr) { [Console]::Error.WriteLine($line) }
                if ($null -ne $OnStderr) { $null = & $OnStderr $line }
                $errorTask = $process.StandardError.ReadLineAsync()
            }
            if (-not $process.HasExited -and -not $timedOut -and -not $aborted -and $null -ne $ShouldAbort) {
                if ([bool](& $ShouldAbort)) {
                    $aborted = $true
                    Stop-OrchestraProcessTree -Process $process
                }
            }
            if ($process.HasExited) {
                if ($null -eq $exitSeenAt) { $exitSeenAt = $watch.Elapsed.TotalSeconds }
                if ($outputDone -and $errorDone) { break }
                $ready = (-not $outputDone -and $outputTask.IsCompleted) -or (-not $errorDone -and $errorTask.IsCompleted)
                if (-not $ready -and ($watch.Elapsed.TotalSeconds - $exitSeenAt) -ge 10.0) {
                    $truncated = $true
                    break
                }
            }
            if (-not $progress) {
                $pendingTasks = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task]'
                if (-not $outputDone -and $null -ne $outputTask) { [void]$pendingTasks.Add([System.Threading.Tasks.Task]$outputTask) }
                if (-not $errorDone -and $null -ne $errorTask) { [void]$pendingTasks.Add([System.Threading.Tasks.Task]$errorTask) }
                if ($null -ne $inputTask) { [void]$pendingTasks.Add([System.Threading.Tasks.Task]$inputTask) }
                if ($pendingTasks.Count -gt 0) {
                    try { $null = [System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]$pendingTasks.ToArray(), 25) } catch {}
                }
                else { Start-Sleep -Milliseconds 5 }
            }
        }
        $exitCode = if ($process.HasExited) { $process.ExitCode } else { 3 }
        return @{
            exit_code = $exitCode; timeout = $timedOut
            startup_timeout = $startupTimedOut; aborted = $aborted
            truncated = $truncated
            stdout = $stdout.ToArray(); stderr = $stderr.ToArray()
        }
    }
    finally {
        if ($null -ne $writer) { try { $writer.Dispose() } catch {} }
        if ($started) {
            try { if (-not $process.HasExited) { Stop-OrchestraProcessTree -Process $process } } catch {}
        }
        $process.Dispose()
        $watch.Stop()
    }
}

function Get-OrchestraErrorKind {
    param($ErrorObject, [int]$Depth = 0)
    if ($null -eq $ErrorObject -or $Depth -gt 12) { return 'external' }
    if ($ErrorObject -is [string]) {
        $text = [string]$ErrorObject
        try {
            $decoded = $text | ConvertFrom-Json
            if ($decoded -isnot [string] -and $null -ne $decoded) {
                return Get-OrchestraErrorKind $decoded ($Depth + 1)
            }
        }
        catch {}
        if ($text -match '(?i)model_not_found|model.{0,120}not supported|not supported.{0,120}model') { return 'model' }
        if ($text -match '(?i)rate[ _-]?limit|quota|(?<!\d)429(?!\d)|exceeded|insufficient|usage[ _-]?limit') { return 'quota' }
        return 'external'
    }
    $status = [string](Get-OrchestraProperty $ErrorObject 'status')
    $code = [string](Get-OrchestraProperty $ErrorObject 'code')
    $type = [string](Get-OrchestraProperty $ErrorObject 'type')
    if ($code -match '(?i)model_not_found' -or $type -match '(?i)model_not_found') { return 'model' }
    if ($status -eq '429' -or ($code + ' ' + $type) -match '(?i)rate[ _-]?limit|quota|usage[ _-]?limit') { return 'quota' }
    $found = 'external'
    foreach ($name in @('error', 'errors', 'message', 'error_message', 'detail')) {
        $value = Get-OrchestraProperty $ErrorObject $name
        if ($null -eq $value) { continue }
        foreach ($part in @($value)) {
            $kind = Get-OrchestraErrorKind $part ($Depth + 1)
            if ($kind -eq 'model') { return 'model' }
            if ($kind -eq 'quota') { $found = 'quota' }
        }
    }
    return $found
}

function Get-OrchestraCodexAuthInterrupted {
    param($ErrorObject, [int]$Depth = 0)
    if ($null -eq $ErrorObject -or $Depth -gt 12) { return $false }
    if ($ErrorObject -is [string] -or $ErrorObject -is [ValueType]) {
        $text = [string]$ErrorObject
        if ($ErrorObject -is [string]) {
            try {
                $decoded = $text | ConvertFrom-Json
                if ($null -ne $decoded -and $decoded -isnot [string]) {
                    if (Get-OrchestraCodexAuthInterrupted $decoded ($Depth + 1)) { return $true }
                }
            }
            catch {}
        }
        return ($text -match '(?i)\bunauthorized\b|invalid[ _-]?api[ _-]?key|token.{0,30}(expired|invalid|revoked)|authentication.{0,30}failed|(?<!\d)(401|403)(?!\d)')
    }
    if ($ErrorObject -is [array]) {
        foreach ($part in $ErrorObject) {
            if (Get-OrchestraCodexAuthInterrupted $part ($Depth + 1)) { return $true }
        }
        return $false
    }
    foreach ($name in @('status', 'status_code', 'code', 'type', 'error', 'errors', 'message', 'error_message', 'detail', 'response')) {
        $value = Get-OrchestraProperty $ErrorObject $name
        if ($null -eq $value) { continue }
        foreach ($part in @($value)) {
            if (Get-OrchestraCodexAuthInterrupted $part ($Depth + 1)) { return $true }
        }
    }
    return $false
}

function Get-OrchestraCodexHome {
    $value = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_CODEX_HOME')
    if ([string]::IsNullOrWhiteSpace($value)) { $value = Join-Path $HOME '.codex' }
    return [IO.Path]::GetFullPath($value)
}

function Get-OrchestraRotationWaitMs {
    param($Invoke)
    $override = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_ROTATION_WAIT_MS')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $parsed = 0
        if ($override -notmatch '^\d+$' -or -not [int]::TryParse($override, [ref]$parsed)) {
            throw 'ORCHESTRA_ARGS: MODEL_ORCHESTRA_ROTATION_WAIT_MS must be a nonnegative Int32.'
        }
        return $parsed
    }
    $seconds = [double](Get-OrchestraProperty $Invoke 'rotation_wait_sec' 10)
    return [int][Math]::Ceiling([Math]::Max(0.0, $seconds) * 1000.0)
}

function Get-CodexAuthFingerprint {
    param([string]$CodexHome = (Get-OrchestraCodexHome))
    $stream = $null
    $sha = $null
    try {
        $path = Join-Path $CodexHome 'auth.json'
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        $sha = [Security.Cryptography.SHA256]::Create()
        $digest = $sha.ComputeHash($stream)
        return ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
    }
    catch [IO.FileNotFoundException] { return $null }
    catch [IO.DirectoryNotFoundException] { return $null }
    catch { throw 'ORCHESTRA_EXTERNAL: Codex authentication fingerprint is temporarily unavailable.' }
    finally {
        if ($null -ne $sha) { $sha.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Wait-CockpitQuiet {
    param([string]$CodexHome = (Get-OrchestraCodexHome), [int]$RotationWaitMs = 10000)
    $limit = [int][Math]::Min(5000, [Math]::Max(200, $RotationWaitMs))
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($watch.Elapsed.TotalMilliseconds -lt $limit) {
            $active = $false
            $cutoff = [DateTime]::UtcNow.AddSeconds(-10)
            foreach ($name in @('.cockpit-profile-mutation-locks', '.cockpit-token-locks')) {
                $directory = Join-Path $CodexHome $name
                if (-not [IO.Directory]::Exists($directory)) { continue }
                try {
                    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($directory, '*', [IO.SearchOption]::AllDirectories)) {
                        if ([IO.File]::GetLastWriteTimeUtc($entry) -ge $cutoff) { $active = $true; break }
                    }
                }
                catch { $active = $true }
                if ($active) { break }
            }
            if (-not $active) { return }
            $sleepMs = [int][Math]::Min(150, [Math]::Floor($limit - $watch.Elapsed.TotalMilliseconds))
            if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs } else { return }
        }
    }
    finally { $watch.Stop() }
}

function Get-CodexConfigCliPath {
    param([string]$CodexHome = (Get-OrchestraCodexHome))
    if ([string]::IsNullOrWhiteSpace($CodexHome)) { return $null }
    $cfgFile = Join-Path $CodexHome 'config.toml'
    if (-not [IO.File]::Exists($cfgFile)) { return $null }
    try {
        foreach ($rawLine in [IO.File]::ReadAllLines($cfgFile, $script:OrchestraUtf8)) {
            $trimmed = ([string]$rawLine).Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }
            if ($trimmed -match '^CODEX_CLI_PATH\s*=\s*(.+)$') {
                $rhs = $Matches[1].Trim()
                $decoded = $null
                if ($rhs -match "^'([^']*)'\s*(?:#.*)?$") { $decoded = $Matches[1] }
                elseif ($rhs -match '^"((?:[^"\\]|\\.)*)"\s*(?:#.*)?$') {
                    $decoded = $Matches[1].Replace('\\', '\').Replace('\"', '"')
                }
                if (-not [string]::IsNullOrWhiteSpace($decoded) -and [IO.Path]::IsPathRooted($decoded)) {
                    $full = [IO.Path]::GetFullPath($decoded)
                    if ([IO.Path]::GetFileName($full) -ieq 'codex.exe' -and [IO.File]::Exists($full)) { return $full }
                }
            }
        }
    }
    catch {}
    return $null
}

function Get-CodexModelCatalogOverride {
    param([string]$CodexHome = (Get-OrchestraCodexHome), [string]$ModelSlug = '', [double]$MaxAgeHours = 24.0)
    if ([string]::IsNullOrWhiteSpace($CodexHome) -or $MaxAgeHours -le 0) {
        return [ordered]@{ applied = $false; path = $null; config_args = @() }
    }
    $cachePath = Join-Path $CodexHome 'models_cache.json'
    if (-not [IO.File]::Exists($cachePath)) {
        return [ordered]@{ applied = $false; path = $null; config_args = @() }
    }
    $fullPath = [IO.Path]::GetFullPath($cachePath)
    try {
        $doc = Read-JsonFile -Path $fullPath
        $modelsArr = @(Get-OrchestraArray $doc 'models')
        if ($modelsArr.Count -eq 0) { return [ordered]@{ applied = $false; path = $fullPath; config_args = @() } }
        if (-not [string]::IsNullOrWhiteSpace($ModelSlug)) {
            $hasSlug = $false
            foreach ($entry in $modelsArr) {
                if ([string](Get-OrchestraProperty $entry 'slug' '') -ceq $ModelSlug) { $hasSlug = $true; break }
            }
            if (-not $hasSlug) { return [ordered]@{ applied = $false; path = $fullPath; config_args = @() } }
        }
        $stampUtc = [IO.File]::GetLastWriteTimeUtc($fullPath)
        $fetchedText = [string](Get-OrchestraProperty $doc 'fetched_at' '')
        if (-not [string]::IsNullOrWhiteSpace($fetchedText)) {
            try {
                $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
                $stampUtc = [DateTime]::Parse($fetchedText, [Globalization.CultureInfo]::InvariantCulture, $styles).ToUniversalTime()
            }
            catch {}
        }
        $ageHours = ([DateTime]::UtcNow - $stampUtc).TotalHours
        if ($ageHours -gt $MaxAgeHours -or $ageHours -lt -1.0) {
            return [ordered]@{ applied = $false; path = $fullPath; config_args = @() }
        }
        $escapedPath = $fullPath.Replace('\', '\\').Replace('"', '\"')
        return [ordered]@{
            applied = $true; path = $fullPath
            config_args = @('-c', ('model_catalog_json="' + $escapedPath + '"'))
        }
    }
    catch {
        return [ordered]@{ applied = $false; path = $fullPath; config_args = @() }
    }
}

function Resolve-CodexExe {
    param([string]$CodexHome = (Get-OrchestraCodexHome))
    # Fast path 1: explicit env override
    $override = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_CODEX')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $full = [IO.Path]::GetFullPath($override)
        if (-not [IO.File]::Exists($full)) {
            throw "ORCHESTRA_EXTERNAL: MODEL_ORCHESTRA_CODEX not found: $full"
        }
        return $full
    }
    # Fast path 2: official CODEX_CLI_PATH in config.toml (zero directory scan / zero --version probe)
    $cfgCliPath = Get-CodexConfigCliPath -CodexHome $CodexHome
    if (-not [string]::IsNullOrWhiteSpace($cfgCliPath) -and [IO.File]::Exists($cfgCliPath)) {
        return $cfgCliPath
    }

    # Fallback discovery across standard install paths
    $candidates = @{}
    $local = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    if (-not [string]::IsNullOrWhiteSpace($local)) {
        $modern = Join-Path $local 'OpenAI\Codex\bin'
        if ([IO.Directory]::Exists($modern)) {
            foreach ($directory in [IO.Directory]::GetDirectories($modern)) {
                $file = Join-Path $directory 'codex.exe'
                if ([IO.File]::Exists($file)) { $candidates[$file.ToLowerInvariant()] = $file }
            }
            $file = Join-Path $modern 'codex.exe'
            if ([IO.File]::Exists($file)) { $candidates[$file.ToLowerInvariant()] = $file }
        }
        $legacy = Join-Path $local 'Programs\OpenAI\Codex\bin\codex.exe'
        if ([IO.File]::Exists($legacy)) { $candidates[$legacy.ToLowerInvariant()] = $legacy }
    }
    foreach ($extRoot in @((Join-Path $HOME '.vscode\extensions'), (Join-Path $HOME '.antigravity\extensions'))) {
        if ([IO.Directory]::Exists($extRoot)) {
            try {
                foreach ($extDir in [IO.Directory]::GetDirectories($extRoot, 'openai.chatgpt-*')) {
                    $file = Join-Path $extDir 'bin\windows-x86_64\codex.exe'
                    if ([IO.File]::Exists($file)) { $candidates[$file.ToLowerInvariant()] = $file }
                }
            }
            catch {}
        }
    }
    foreach ($cmd in @(Get-Command codex.exe -CommandType Application -All -ErrorAction SilentlyContinue)) {
        $file = [string]$cmd.Source
        if ([IO.File]::Exists($file)) { $candidates[$file.ToLowerInvariant()] = $file }
    }

    $valid = New-Object 'System.Collections.Generic.List[object]'
    foreach ($file in $candidates.Values) {
        try {
            $probe = Invoke-OrchestraProcess -FilePath $file -Arguments @('--version') -TimeoutSec 3 -CaptureStdout
            if ($probe.timeout -or $probe.truncated -or $probe.exit_code -ne 0) { continue }
            $match = [regex]::Match(($probe.stdout -join "`n"), '(?<!\d)(\d+\.\d+\.\d+)(?:[-+][^\s]+)?')
            if (-not $match.Success) { continue }
            $ver = [version]$match.Groups[1].Value
            if ($ver -lt [version]'0.153.0') { continue }
            $item = Get-Item -LiteralPath $file
            [void]$valid.Add([pscustomobject]@{ path = $file; version = $ver; mtime = $item.LastWriteTimeUtc })
        }
        catch { continue }
    }
    $ordered = @($valid | Sort-Object -Property @{ Expression = { $_.version }; Descending = $true }, @{ Expression = { $_.mtime }; Descending = $true })
    if ($ordered.Count -eq 0) {
        throw 'ORCHESTRA_EXTERNAL: No usable Codex >= 0.153.0 found.'
    }
    return [string]$ordered[0].path
}

function Get-CodexEssentialConfigOverrides {
    param([string]$CodexHome = (Get-OrchestraCodexHome))
    $modelProvider = 'openai'
    $forcedLoginMethod = ''
    $windowsSandbox = 'unelevated'
    $fastConfigSupported = $true

    if (-not [string]::IsNullOrWhiteSpace($CodexHome)) {
        $cfgFile = Join-Path $CodexHome 'config.toml'
        if ([IO.File]::Exists($cfgFile)) {
            $section = ''
            foreach ($rawLine in [IO.File]::ReadAllLines($cfgFile, $script:OrchestraUtf8)) {
                $trimmed = ([string]$rawLine).Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }
                if ($trimmed -match '^\[+([^\[\]]+)\]+\s*(?:#.*)?$') {
                    $section = $Matches[1].Trim().Replace('"', '').Replace("'", '').ToLowerInvariant()
                    if ($section -eq 'model_providers' -or $section -like 'model_providers.*' -or
                        $section -eq 'profiles' -or $section -like 'profiles.*') {
                        $fastConfigSupported = $false; break
                    }
                    continue
                }
                if ($trimmed -match '^([A-Za-z0-9_.-]+)\s*=\s*(.+)$') {
                    $keyLower = $Matches[1].Trim().ToLowerInvariant()
                    $rhs = $Matches[2].Trim()
                    if ($section -eq '' -and (
                        $keyLower -in @('openai_base_url', 'forced_chatgpt_workspace_id', 'cli_auth_credentials_store', 'chatgpt_base_url', 'profile', 'model_providers', 'profiles') -or
                        $keyLower -like 'model_providers.*' -or $keyLower -like 'profiles.*'
                    )) {
                        $fastConfigSupported = $false; break
                    }
                    $isEssential = (
                        ($section -eq '' -and $keyLower -in @('model_provider', 'forced_login_method', 'windows.sandbox')) -or
                        ($section -eq 'windows' -and $keyLower -eq 'sandbox')
                    )
                    if (-not $isEssential) { continue }
                    $decoded = $null
                    if ($rhs -match "^'([^']*)'\s*(?:#.*)?$") { $decoded = $Matches[1] }
                    elseif ($rhs -match '^"((?:[^"\\]|\\.)*)"\s*(?:#.*)?$') {
                        $decoded = $Matches[1].Replace('\\', '\').Replace('\"', '"')
                    }
                    if ($null -eq $decoded) { $fastConfigSupported = $false; break }
                    $val = $decoded.Trim()
                    if ($section -eq '') {
                        switch ($keyLower) {
                            'model_provider' { if (-not [string]::IsNullOrWhiteSpace($val)) { $modelProvider = $val } }
                            'forced_login_method' { $forcedLoginMethod = $val }
                            'windows.sandbox' { if (-not [string]::IsNullOrWhiteSpace($val)) { $windowsSandbox = $val } }
                        }
                    }
                    elseif ($section -eq 'windows' -and $keyLower -eq 'sandbox') {
                        if (-not [string]::IsNullOrWhiteSpace($val)) { $windowsSandbox = $val }
                    }
                }
            }
        }
    }

    $configArgs = New-Object 'System.Collections.Generic.List[string]'
    if ($fastConfigSupported) {
        [void]$configArgs.Add('-c'); [void]$configArgs.Add(('model_provider="' + ($modelProvider.Replace('\', '\\').Replace('"', '\"')) + '"'))
        if (-not [string]::IsNullOrWhiteSpace($forcedLoginMethod)) {
            [void]$configArgs.Add('-c'); [void]$configArgs.Add(('forced_login_method="' + ($forcedLoginMethod.Replace('\', '\\').Replace('"', '\"')) + '"'))
        }
        [void]$configArgs.Add('-c'); [void]$configArgs.Add(('windows.sandbox="' + ($windowsSandbox.Replace('\', '\\').Replace('"', '\"')) + '"'))
    }
    return [ordered]@{ fast_config_supported = [bool]$fastConfigSupported; config_args = @($configArgs.ToArray()) }
}

function Get-AgyWrapperPath {
    $override = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER')
    if (-not [string]::IsNullOrWhiteSpace($override)) { return [IO.Path]::GetFullPath($override) }
    return [IO.Path]::GetFullPath((Join-Path $HOME '.gemini\bin\agy-exec.ps1'))
}

function Get-AgyExecutablePath {
    $wrapperOverride = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER')
    if (-not [string]::IsNullOrWhiteSpace($wrapperOverride)) { return [IO.Path]::GetFullPath($wrapperOverride) }
    foreach ($envName in @('MODEL_ORCHESTRA_AGY_EXE', 'AGY_EXEC_BIN')) {
        $exeOverride = [Environment]::GetEnvironmentVariable($envName)
        if (-not [string]::IsNullOrWhiteSpace($exeOverride)) { return [IO.Path]::GetFullPath($exeOverride) }
    }
    $homeAgyExe = [IO.Path]::GetFullPath((Join-Path $HOME '.gemini\bin\agy.exe'))
    if ([IO.File]::Exists($homeAgyExe)) { return $homeAgyExe }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $localAppAgyExe = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'))
        if ([IO.File]::Exists($localAppAgyExe)) { return $localAppAgyExe }
    }
    return (Get-AgyWrapperPath)
}

function Resolve-AgyExecutable {
    $path = Get-AgyExecutablePath
    if (-not [IO.File]::Exists($path)) { throw "ORCHESTRA_EXTERNAL: Agy executable not found: $path" }
    return $path
}

function Write-OrchestraResult {
    param($Object)
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $Object -Depth 32 -Compress))
    [Console]::Out.Flush()
}

function Get-OrchestraExitCode {
    param([string]$Message)
    if ($Message -match '^ORCHESTRA_ARGS:') { return 2 }
    if ($Message -match '^ORCHESTRA_QUOTA:') { return 4 }
    return 3
}
