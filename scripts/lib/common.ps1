[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:OrchestraUtf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $script:OrchestraUtf8
$OutputEncoding = $script:OrchestraUtf8

$EXIT_OK = 0
$EXIT_ARGS = 2
$EXIT_EXTERNAL = 3
$EXIT_QUOTA = 4
$EXIT_LOCK = 5
$script:OrchestraRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$script:OrchestraHeldLocks = @{}

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

function Set-OrchestraProperty {
    param($Object, [string]$Name, $Value)
    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
    }
    else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
    }
}

function Get-OrchestraNames {
    param($Object)
    if ($null -eq $Object) { return }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { [string]$key }
    }
    else {
        foreach ($property in $Object.PSObject.Properties) { $property.Name }
    }
}

function Get-OrchestraNow {
    $value = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_NOW')
    if ([string]::IsNullOrWhiteSpace($value)) { return [DateTime]::UtcNow }
    try {
        $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor
            [Globalization.DateTimeStyles]::AdjustToUniversal
        return [DateTime]::Parse(
            $value, [Globalization.CultureInfo]::InvariantCulture, $styles
        ).ToUniversalTime()
    }
    catch { throw 'ORCHESTRA_ARGS: MODEL_ORCHESTRA_NOW must be ISO 8601.' }
}

function ConvertTo-OrchestraUtc {
    param([string]$Value)
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor
        [Globalization.DateTimeStyles]::AdjustToUniversal
    return [DateTime]::Parse(
        $Value, [Globalization.CultureInfo]::InvariantCulture, $styles
    ).ToUniversalTime()
}

function Resolve-Root { return $script:OrchestraRoot }

function Get-OrchestraPaths {
    param([string]$RegistryPath, [string]$StateDir)
    if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
        $RegistryPath = Join-Path $script:OrchestraRoot 'registry\models.json'
    }
    if ([string]::IsNullOrWhiteSpace($StateDir)) {
        $StateDir = Join-Path $HOME '.cowork'
    }
    $registry = [IO.Path]::GetFullPath($RegistryPath)
    $stateDirectory = [IO.Path]::GetFullPath($StateDir)
    $registryDirectory = [IO.Path]::GetDirectoryName($registry)
    return @{
        Root = $script:OrchestraRoot
        Registry = $registry
        RegistryDir = $registryDirectory
        History = Join-Path $registryDirectory 'history'
        Proposals = Join-Path $registryDirectory 'proposals'
        Changelog = Join-Path $registryDirectory 'CHANGELOG.md'
        StateDir = $stateDirectory
        State = Join-Path $stateDirectory 'state.json'
        Usage = Join-Path $stateDirectory 'usage.jsonl'
        Locks = Join-Path $stateDirectory 'locks'
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $null }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "ORCHESTRA_EXTERNAL: Empty JSON file: $Path"
    }
    return ($text | ConvertFrom-Json)
}

function Read-Json {
    param([string]$Path)
    return Read-JsonFile -Path $Path
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Object
    )
    $target = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($target)
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary = Join-Path $directory (
        '.' + [IO.Path]::GetFileName($target) + '.' +
        [Guid]::NewGuid().ToString('N') + '.tmp'
    )
    try {
        $text = ConvertTo-Json -InputObject $Object -Depth 32
        [IO.File]::WriteAllText($temporary, $text, $script:OrchestraUtf8)
        if ([IO.File]::Exists($target)) {
            [IO.File]::Replace($temporary, $target, [NullString]::Value)
        }
        else { [IO.File]::Move($temporary, $target) }
    }
    finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Get-OrchestraLockKey {
    param([hashtable]$Paths, [string]$Name)
    return [IO.Path]::GetFullPath(
        (Join-Path $Paths.Locks ($Name + '.lock'))
    ).ToLowerInvariant()
}

function Test-OrchestraLockHeld {
    param([hashtable]$Paths, [string]$Name)
    return $script:OrchestraHeldLocks.ContainsKey(
        (Get-OrchestraLockKey -Paths $Paths -Name $Name)
    )
}

function Assert-OrchestraLockHeld {
    param([hashtable]$Paths, [string]$Name)
    if (-not (Test-OrchestraLockHeld -Paths $Paths -Name $Name)) {
        throw "ORCHESTRA_LOCK_REQUIRED: Hold the $Name lock first."
    }
}

function Invoke-WithLock {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [int]$TimeoutSec = 10
    )
    $ranks = @{ registry = 1; state = 2; usage = 3 }
    if (-not $ranks.ContainsKey($Name) -or $TimeoutSec -lt 0) {
        throw 'ORCHESTRA_ARGS: Invalid lock name or timeout.'
    }
    $key = Get-OrchestraLockKey -Paths $Paths -Name $Name
    if ($script:OrchestraHeldLocks.ContainsKey($key)) {
        throw "ORCHESTRA_LOCK_TIMEOUT: Reentrant lock: $Name"
    }
    foreach ($held in $script:OrchestraHeldLocks.Values) {
        if ([int]$held -gt [int]$ranks[$Name]) {
            throw 'ORCHESTRA_LOCK_ORDER: Use registry, state, usage order.'
        }
    }
    [void][IO.Directory]::CreateDirectory($Paths.Locks)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $handle = $null
    while ($null -eq $handle) {
        try {
            $handle = [IO.File]::Open(
                $key, [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite, [IO.FileShare]::None
            )
        }
        catch [IO.IOException] {
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSec) {
                throw "ORCHESTRA_LOCK_TIMEOUT: $Name"
            }
            Start-Sleep -Milliseconds 100
        }
    }
    $script:OrchestraHeldLocks[$key] = $ranks[$Name]
    try { & $ScriptBlock }
    finally {
        [void]$script:OrchestraHeldLocks.Remove($key)
        $handle.Dispose()
        $watch.Stop()
    }
}

function With-FileLock {
    param(
        [hashtable]$Paths, [string]$Name,
        [scriptblock]$ScriptBlock, [int]$TimeoutSec = 10
    )
    Invoke-WithLock -Paths $Paths -Name $Name `
        -ScriptBlock $ScriptBlock -TimeoutSec $TimeoutSec
}

function Read-Registry {
    param([hashtable]$Paths)
    $registry = Read-JsonFile -Path $Paths.Registry
    if ($null -eq $registry) {
        throw "ORCHESTRA_EXTERNAL: Registry not found: $($Paths.Registry)"
    }
    if ($null -eq (Get-OrchestraProperty $registry 'models')) {
        throw 'ORCHESTRA_EXTERNAL: Registry has no models array.'
    }
    return $registry
}

function Add-ChangelogEntry {
    param([hashtable]$Paths, [string]$Title, [string[]]$Lines = @())
    Assert-OrchestraLockHeld -Paths $Paths -Name registry
    [void][IO.Directory]::CreateDirectory($Paths.RegistryDir)
    $isNew = -not [IO.File]::Exists($Paths.Changelog)
    $stamp = (Get-OrchestraNow).ToString('o')
    $safeTitle = $Title -replace '[\r\n]+', ' '
    $builder = New-Object Text.StringBuilder
    if ($isNew) {
        [void]$builder.AppendLine('# Model orchestra changelog')
        [void]$builder.AppendLine()
    }
    [void]$builder.AppendLine("## $stamp - $safeTitle")
    foreach ($line in $Lines) {
        [void]$builder.AppendLine('- ' + ($line -replace '[\r\n]+', ' '))
    }
    [void]$builder.AppendLine()
    [IO.File]::AppendAllText(
        $Paths.Changelog, $builder.ToString(), $script:OrchestraUtf8
    )
}

function Save-Registry {
    param(
        [hashtable]$Paths, $Registry,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    Assert-OrchestraLockHeld -Paths $Paths -Name registry
    $existing = Read-JsonFile -Path $Paths.Registry
    $oldRevision = 0
    if ($null -ne $existing) {
        $oldRevision = [long](Get-OrchestraProperty $existing 'registry_rev' 0)
    }
    $baseRevision = [long](Get-OrchestraProperty $Registry 'registry_rev' 0)
    if ($oldRevision -ne $baseRevision) {
        throw 'ORCHESTRA_REV_CONFLICT: Reload the registry before saving.'
    }
    $backup = $null
    if ($null -ne $existing) {
        [void][IO.Directory]::CreateDirectory($Paths.History)
        $stamp = (Get-OrchestraNow).ToString('yyyyMMdd-HHmmss')
        $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 4)
        $backup = Join-Path $Paths.History "models-$stamp-$oldRevision-$suffix.json"
        [IO.File]::Copy($Paths.Registry, $backup, $false)
    }
    Set-OrchestraProperty $Registry 'registry_rev' ($oldRevision + 1)
    Set-OrchestraProperty $Registry 'updated' ((Get-OrchestraNow).ToString('o'))
    Write-JsonAtomic -Path $Paths.Registry -Object $Registry
    Add-ChangelogEntry -Paths $Paths -Title $Reason -Lines @(
        "registry_rev: $oldRevision -> $($oldRevision + 1)"
        "backup: $backup"
    )
    return $backup
}

function Read-State {
    param([hashtable]$Paths)
    $state = Read-JsonFile -Path $Paths.State
    if ($null -eq $state) { $state = [pscustomobject]@{} }
    foreach ($name in @(
        'sources', 'exhausted', 'low', 'research_leases', 'codex_exe_cache'
    )) {
        if ($null -eq (Get-OrchestraProperty $state $name)) {
            Set-OrchestraProperty $state $name ([pscustomobject]@{})
        }
    }
    foreach ($name in @('agy', 'codex')) {
        $sources = Get-OrchestraProperty $state 'sources'
        $source = Get-OrchestraProperty $sources $name
        if ($null -eq $source) {
            $source = [pscustomobject]@{}
            Set-OrchestraProperty $sources $name $source
        }
        $defaults = @{
            baseline_slugs = @()
            raw_slugs = @()
            baseline_initialized = $false
            last_success = $null
            last_attempt = $null
            consecutive_failures = 0
            missing_counts = [pscustomobject]@{}
        }
        foreach ($key in $defaults.Keys) {
            if ($null -eq (Get-OrchestraProperty $source $key)) {
                Set-OrchestraProperty $source $key $defaults[$key]
            }
        }
    }
    if ($null -eq (Get-OrchestraProperty $state 'rejected_slugs')) {
        Set-OrchestraProperty $state 'rejected_slugs' @()
    }
    foreach ($name in @('last_scan', 'scan_lease')) {
        if ($null -eq $state.PSObject.Properties[$name]) {
            Set-OrchestraProperty $state $name $null
        }
    }
    return $state
}

function Get-State {
    param([hashtable]$Paths)
    return Read-State -Paths $Paths
}

function Save-State {
    param([hashtable]$Paths, $State)
    Assert-OrchestraLockHeld -Paths $Paths -Name state
    Write-JsonAtomic -Path $Paths.State -Object $State
}

function ConvertTo-BaseSlug {
    param([string]$Slug)
    if ([string]::IsNullOrWhiteSpace($Slug)) { return $null }
    return ($Slug.Trim() -replace '-(low|medium|high|xhigh|max)$', '')
}

function Resolve-ModelId {
    param($Registry, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $current = $Name.Trim()
    $visited = @{}
    for ($i = 0; $i -lt 32; $i++) {
        if ($visited.ContainsKey($current)) { return $null }
        $visited[$current] = $true
        $registryModels = Get-OrchestraProperty $Registry 'models' @()
        foreach ($model in $registryModels) {
            if ([string](Get-OrchestraProperty $model 'id') -eq $current) {
                return [string](Get-OrchestraProperty $model 'id')
            }
        }
        $alias = Get-OrchestraProperty (
            Get-OrchestraProperty $Registry 'aliases'
        ) $current
        if (-not [string]::IsNullOrWhiteSpace([string]$alias)) {
            $current = [string]$alias
            continue
        }
        $base = ConvertTo-BaseSlug -Slug $current
        if ($base -eq $current) { return $null }
        $current = $base
    }
    return $null
}

function Get-ModelAvailability {
    param($Registry, $State, $Model)
    $status = [string](Get-OrchestraProperty $Model 'status')
    if ($status -notin @('active', 'candidate')) { return 'unavailable' }
    $id = [string](Get-OrchestraProperty $Model 'id')
    $entry = Get-OrchestraProperty (Get-OrchestraProperty $State 'exhausted') $id
    if ($null -ne $entry) {
        try {
            $until = ConvertTo-OrchestraUtc (
                [string](Get-OrchestraProperty $entry 'until')
            )
            if ($until -gt (Get-OrchestraNow)) { return 'exhausted' }
        }
        catch { return 'exhausted' }
    }
    $low = Get-OrchestraProperty (Get-OrchestraProperty $State 'low') $id
    if ($low -is [bool] -and $low) { return 'low' }
    return 'normal'
}

function Add-UsageEvent {
    param([hashtable]$Paths, [hashtable]$Event)
    if ([string](Get-OrchestraProperty $Event 'type') -eq 'invocation') {
        if (-not $Event.ContainsKey('attempts')) { $Event.attempts = 1 }
        if (-not $Event.ContainsKey('account_switched')) {
            $Event.account_switched = $false
        }
        if (-not $Event.ContainsKey('resume_invalidated')) {
            $Event.resume_invalidated = $false
        }
        $Event.attempts = [int]$Event.attempts
        $Event.account_switched = [bool]$Event.account_switched
        $Event.resume_invalidated = [bool]$Event.resume_invalidated
    }
    $append = {
        [void][IO.Directory]::CreateDirectory($Paths.StateDir)
        $line = ConvertTo-Json -InputObject $Event -Depth 32 -Compress
        $stream = [IO.File]::Open(
            $Paths.Usage, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::Write, [IO.FileShare]::Read
        )
        $writer = $null
        try {
            [void]$stream.Seek(0, [IO.SeekOrigin]::End)
            $writer = New-Object IO.StreamWriter($stream, $script:OrchestraUtf8)
            $writer.WriteLine($line)
            $writer.Flush()
            $stream.Flush()
        }
        finally {
            if ($null -ne $writer) { $writer.Dispose() }
            else { $stream.Dispose() }
        }
    }
    if (Test-OrchestraLockHeld -Paths $Paths -Name usage) { & $append }
    else { Invoke-WithLock -Paths $Paths -Name usage -ScriptBlock $append }
}

function Read-UsageEvents {
    param([hashtable]$Paths, [int]$SinceDays = 0)
    if ($SinceDays -lt 0) { throw 'ORCHESTRA_ARGS: SinceDays cannot be negative.' }
    if (-not [IO.File]::Exists($Paths.Usage)) { return }
    $cutoff = (Get-OrchestraNow).AddDays(-$SinceDays)
    $stream = [IO.File]::Open(
        $Paths.Usage, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite
    )
    $reader = New-Object IO.StreamReader($stream, $script:OrchestraUtf8, $true)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $event = $line | ConvertFrom-Json
                if ($SinceDays -gt 0) {
                    $stamp = ConvertTo-OrchestraUtc (
                        [string](Get-OrchestraProperty $event 'ts')
                    )
                    if ($stamp -lt $cutoff) { continue }
                }
                Write-Output $event
            }
            catch {
                [Console]::Error.WriteLine(
                    'Ignoring an invalid or incomplete usage JSONL record.'
                )
            }
        }
    }
    finally { $reader.Dispose() }
}

function Get-OutcomeStats {
    param(
        [object[]]$Events = @(), [string]$ModelId,
        [string[]]$Tags = @(), [int]$WindowDays = 30
    )
    $invocations = @{}
    $outcomes = @{}
    $sequence = 0
    foreach ($event in $Events) {
        $sequence++
        $id = [string](Get-OrchestraProperty $event 'invocation_id')
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $type = [string](Get-OrchestraProperty $event 'type')
        if ($type -eq 'invocation') {
            if (-not $invocations.ContainsKey($id)) { $invocations[$id] = $event }
        }
        elseif ($type -eq 'outcome') {
            $value = [string](Get-OrchestraProperty $event 'outcome')
            if ($value -in @('ok', 'redo', 'fail')) {
                $outcomes[$id] = @{ event = $event; sequence = $sequence }
            }
        }
    }
    $stats = @{
        n = 0; ok = 0; redo = 0; fail = 0
        ok_invocations = 0; ok_tags = @(); consecutive_fail = 0
    }
    $okTags = @{}
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $now = Get-OrchestraNow
    $cutoff = $now.AddDays(-$WindowDays)
    foreach ($id in $invocations.Keys) {
        $invocation = $invocations[$id]
        if ([string](Get-OrchestraProperty $invocation 'model') -ne $ModelId) { continue }
        if (-not $outcomes.ContainsKey($id)) { continue }
        try {
            $stamp = ConvertTo-OrchestraUtc (
                [string](Get-OrchestraProperty $invocation 'ts')
            )
        }
        catch { continue }
        if ($stamp -lt $cutoff -or $stamp -gt $now) { continue }
        $tagValues = Get-OrchestraProperty $invocation 'tags' @()
        $invocationTags = @($tagValues)
        if (@($Tags).Count -gt 0) {
            $matches = @($invocationTags | Where-Object { $_ -in $Tags })
            if ($matches.Count -eq 0) { continue }
        }
        $row = $outcomes[$id]
        $value = [string](Get-OrchestraProperty $row.event 'outcome')
        $stats.n++
        $stats[$value]++
        if ($value -eq 'ok') {
            $stats.ok_invocations++
            foreach ($tag in $invocationTags) {
                if (-not [string]::IsNullOrWhiteSpace([string]$tag)) {
                    $okTags[[string]$tag] = $true
                }
            }
        }
        [void]$rows.Add([pscustomobject]@{
            outcome = $value; sequence = $row.sequence
        })
    }
    foreach ($row in @($rows | Sort-Object sequence -Descending)) {
        if ($row.outcome -ne 'fail') { break }
        $stats.consecutive_fail++
    }
    $stats.ok_tags = @($okTags.Keys | Sort-Object)
    return $stats
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
        $stdoutTask = $killer.StandardOutput.ReadToEndAsync()
        $stderrTask = $killer.StandardError.ReadToEndAsync()
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

function Get-OrchestraSystemProxy {
    $override = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_PROXY')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $trimmedOverride = $override.Trim()
        if ($trimmedOverride -ieq 'NONE') {
            return @{ proxy = $null; host = $null; port = 0; source = 'disabled' }
        }
        if ($trimmedOverride -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
            $trimmedOverride = 'http://' + $trimmedOverride
        }
        $u = $null
        if ([Uri]::TryCreate($trimmedOverride, [UriKind]::Absolute, [ref]$u)) {
            return @{ proxy = $trimmedOverride; host = $u.Host; port = $u.Port; source = 'override' }
        }
        return @{ proxy = $trimmedOverride; host = $null; port = 0; source = 'override' }
    }

    try {
        $inet = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        if ($null -ne $inet -and [int]$inet.ProxyEnable -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$inet.ProxyServer)) {
            $rawProxy = ([string]$inet.ProxyServer).Trim()
            if ($rawProxy -match '(?:^|;)https=([^;]+)') {
                $rawProxy = $Matches[1].Trim()
            }
            elseif ($rawProxy -match '(?:^|;)http=([^;]+)') {
                $rawProxy = $Matches[1].Trim()
            }
            elseif ($rawProxy.Contains(';')) {
                $rawProxy = ($rawProxy -split ';')[0].Trim()
            }
            if (-not [string]::IsNullOrWhiteSpace($rawProxy)) {
                if ($rawProxy -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
                    $rawProxy = 'http://' + $rawProxy
                }
                $u = $null
                if ([Uri]::TryCreate($rawProxy, [UriKind]::Absolute, [ref]$u)) {
                    return @{ proxy = $rawProxy; host = $u.Host; port = $u.Port; source = 'hkcu' }
                }
                return @{ proxy = $rawProxy; host = $null; port = 0; source = 'hkcu' }
            }
        }
    }
    catch {}

    foreach ($envName in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy')) {
        $val = [Environment]::GetEnvironmentVariable($envName)
        if (-not [string]::IsNullOrWhiteSpace($val)) {
            $cleanVal = $val.Trim()
            if ($cleanVal -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
                $cleanVal = 'http://' + $cleanVal
            }
            $u = $null
            if ([Uri]::TryCreate($cleanVal, [UriKind]::Absolute, [ref]$u)) {
                return @{ proxy = $cleanVal; host = $u.Host; port = $u.Port; source = 'env' }
            }
            return @{ proxy = $cleanVal; host = $null; port = 0; source = 'env' }
        }
    }
    return @{ proxy = $null; host = $null; port = 0; source = 'none' }
}

function Test-OrchestraLocalProxy {
    param(
        [string]$ProxyUrl,
        [int]$TimeoutMs = 1200
    )
    if ([string]::IsNullOrWhiteSpace($ProxyUrl)) {
        return @{ checked = $false; reachable = $true; detail = 'No proxy configured.' }
    }
    $uri = $null
    if (-not [Uri]::TryCreate($ProxyUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Port -le 0) {
        return @{ checked = $false; reachable = $true; detail = $ProxyUrl }
    }
    $hostLower = ([string]$uri.Host).Trim('[', ']').ToLowerInvariant()
    if ($hostLower -notin @('127.0.0.1', 'localhost', '::1')) {
        return @{ checked = $false; reachable = $true; detail = $ProxyUrl }
    }
    $connectHost = if ($hostLower -eq 'localhost') { '127.0.0.1' } else { $hostLower }
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $connectTask = $tcp.ConnectAsync($connectHost, $uri.Port)
        $completed = $false
        try {
            $completed = $connectTask.Wait($TimeoutMs)
        }
        catch {
            $completed = $false
        }
        if ($completed -and $tcp.Connected -and -not $connectTask.IsFaulted) {
            return @{ checked = $true; reachable = $true; detail = $ProxyUrl }
        }
        return @{
            checked = $true
            reachable = $false
            detail = ('Local proxy ' + $ProxyUrl + ' is unreachable (TCP connect failed within ' + $TimeoutMs + 'ms).')
        }
    }
    catch {
        return @{
            checked = $true
            reachable = $false
            detail = ('Local proxy ' + $ProxyUrl + ' check failed: ' + $_.Exception.Message)
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
        [int]$TimeoutSec = 1800,
        [int]$StartupTimeoutSec = 0,
        [hashtable]$Environment = @{},
        [scriptblock]$OnStdout,
        [scriptblock]$OnStderr,
        [scriptblock]$ShouldAbort,
        [switch]$ForwardStderr,
        [switch]$CaptureStdout
    )
    # A .ps1 override is an explicit offline/provider shim, not a shell expression.
    $rawQuoted = @(foreach ($argument in $Arguments) {
        ConvertTo-OrchestraArgument -Value $argument
    })
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
                [Convert]::ToBase64String(
                    $script:OrchestraUtf8.GetBytes([string]$argument)
                )
            }) -join ',')
        }
        $launchArguments = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', (Join-Path $PSScriptRoot 'ps1-shim-runner.ps1')
        )
    }
    $quoted = @(foreach ($argument in $launchArguments) {
        ConvertTo-OrchestraArgument -Value $argument
    })
    $argumentText = $quoted -join ' '
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $launchFile
    $info.Arguments = $argumentText
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
        if (-not $started) {
            throw 'ORCHESTRA_EXTERNAL: Process did not start.'
        }
        $outputTask = $process.StandardOutput.ReadLineAsync()
        $errorTask = $process.StandardError.ReadLineAsync()
        $outputDone = $false
        $errorDone = $false
        $inputTask = $null
        if ($null -ne $InputText) {
            $writer = New-Object IO.StreamWriter(
                $process.StandardInput.BaseStream, $script:OrchestraUtf8
            )
            try {
                $inputTask = $writer.WriteAsync($InputText + [Environment]::NewLine)
            }
            catch {
                # A provider may reject authentication before reading stdin.
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
            for ($batch = 0; $batch -lt 256 -and
                -not $outputDone -and $outputTask.IsCompleted; $batch++) {
                $line = $outputTask.GetAwaiter().GetResult()
                $progress = $true
                if ($null -eq $line) { $outputDone = $true; break }
                $firstStdoutSeen = $true
                if ($CaptureStdout) { [void]$stdout.Add($line) }
                if ($null -ne $OnStdout) { $null = & $OnStdout $line }
                $outputTask = $process.StandardOutput.ReadLineAsync()
            }
            for ($batch = 0; $batch -lt 256 -and
                -not $errorDone -and $errorTask.IsCompleted; $batch++) {
                $line = $errorTask.GetAwaiter().GetResult()
                $progress = $true
                if ($null -eq $line) { $errorDone = $true; break }
                [void]$stderr.Add($line)
                if ($ForwardStderr) { [Console]::Error.WriteLine($line) }
                if ($null -ne $OnStderr) { $null = & $OnStderr $line }
                $errorTask = $process.StandardError.ReadLineAsync()
            }
            if (-not $process.HasExited -and -not $timedOut -and -not $aborted -and
                $null -ne $ShouldAbort) {
                if ([bool](& $ShouldAbort)) {
                    $aborted = $true
                    Stop-OrchestraProcessTree -Process $process
                }
            }
            if ($process.HasExited) {
                if ($null -eq $exitSeenAt) {
                    $exitSeenAt = $watch.Elapsed.TotalSeconds
                }
                if ($outputDone -and $errorDone) { break }
                $ready = (-not $outputDone -and $outputTask.IsCompleted) -or
                    (-not $errorDone -and $errorTask.IsCompleted)
                if (-not $ready -and
                    ($watch.Elapsed.TotalSeconds - $exitSeenAt) -ge 10) {
                    $truncated = $true
                    break
                }
            }
            if (-not $progress) { Start-Sleep -Milliseconds 10 }
        }
        $exitCode = 3
        if ($process.HasExited) { $exitCode = $process.ExitCode }
        return @{
            exit_code = $exitCode; timeout = $timedOut
            startup_timeout = $startupTimedOut; aborted = $aborted
            truncated = $truncated
            stdout = $stdout.ToArray(); stderr = $stderr.ToArray()
        }
    }
    finally {
        if ($null -ne $writer) {
            try { $writer.Dispose() } catch {}
        }
        if ($started) {
            try {
                if (-not $process.HasExited) {
                    Stop-OrchestraProcessTree -Process $process
                }
            }
            catch {}
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
        if ($text -match '(?i)model_not_found|model.{0,120}not supported|not supported.{0,120}model') {
            return 'model'
        }
        if ($text -match '(?i)rate[ _-]?limit|quota|(?<!\d)429(?!\d)|exceeded|insufficient|usage[ _-]?limit') {
            return 'quota'
        }
        return 'external'
    }
    $status = [string](Get-OrchestraProperty $ErrorObject 'status')
    $code = [string](Get-OrchestraProperty $ErrorObject 'code')
    $type = [string](Get-OrchestraProperty $ErrorObject 'type')
    if ($code -match '(?i)model_not_found' -or $type -match '(?i)model_not_found') {
        return 'model'
    }
    if ($status -eq '429' -or
        ($code + ' ' + $type) -match '(?i)rate[ _-]?limit|quota|usage[ _-]?limit') {
        return 'quota'
    }
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

function Get-OrchestraCodexInterruption {
    param($ErrorObject, [int]$Depth = 0)
    if ($null -eq $ErrorObject -or $Depth -gt 12) { return $null }
    if ($ErrorObject -is [string] -or $ErrorObject -is [ValueType]) {
        $text = [string]$ErrorObject
        if ($text -match '(?i)invalid_encrypted_content|encrypted_content|decrypt|organization.{0,40}mismatch|thread.{0,30}not found|conversation.{0,30}not found|session.{0,30}not found|rollout.{0,30}not found') {
            return 'resume_incompatible'
        }
        if ($ErrorObject -is [string]) {
            try {
                $decoded = $text | ConvertFrom-Json
                if ($null -ne $decoded -and $decoded -isnot [string]) {
                    $nested = Get-OrchestraCodexInterruption $decoded ($Depth + 1)
                    if ($null -ne $nested) { return $nested }
                }
            }
            catch {}
        }
        if ($text -match '(?i)\bunauthorized\b|invalid[ _-]?api[ _-]?key|token.{0,30}(expired|invalid|revoked)|authentication.{0,30}failed|(?<!\d)(401|403)(?!\d)') {
            return 'auth'
        }
        return $null
    }
    $found = $null
    if ($ErrorObject -is [array]) {
        foreach ($part in $ErrorObject) {
            $kind = Get-OrchestraCodexInterruption $part ($Depth + 1)
            if ($kind -eq 'resume_incompatible') { return $kind }
            if ($kind -eq 'auth') { $found = $kind }
        }
        return $found
    }
    foreach ($name in @(
        'status', 'status_code', 'code', 'type', 'error', 'errors',
        'message', 'error_message', 'detail', 'response'
    )) {
        $value = Get-OrchestraProperty $ErrorObject $name
        if ($null -eq $value) { continue }
        foreach ($part in @($value)) {
            $kind = Get-OrchestraCodexInterruption $part ($Depth + 1)
            if ($kind -eq 'resume_incompatible') { return $kind }
            if ($kind -eq 'auth') { $found = $kind }
        }
    }
    return $found
}

function Get-OrchestraCodexHome {
    $value = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_CODEX_HOME')
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = Join-Path $HOME '.codex'
    }
    return [IO.Path]::GetFullPath($value)
}

function Get-OrchestraRotationWaitMs {
    param($Invoke)
    $override = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_ROTATION_WAIT_MS')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $parsed = 0
        if ($override -notmatch '^\d+$' -or
            -not [int]::TryParse($override, [ref]$parsed)) {
            throw 'ORCHESTRA_ARGS: MODEL_ORCHESTRA_ROTATION_WAIT_MS must be a nonnegative Int32.'
        }
        return $parsed
    }
    try { $seconds = [double](Get-OrchestraProperty $Invoke 'rotation_wait_sec' 10) }
    catch { throw 'ORCHESTRA_ARGS: Invalid rotation_wait_sec.' }
    if ([double]::IsNaN($seconds) -or [double]::IsInfinity($seconds) -or
        $seconds -lt 0 -or $seconds -gt ([int]::MaxValue / 1000.0)) {
        throw 'ORCHESTRA_ARGS: Invalid rotation_wait_sec.'
    }
    return [int][Math]::Ceiling($seconds * 1000.0)
}

function Get-CodexAuthFingerprint {
    param([string]$CodexHome = (Get-OrchestraCodexHome))
    # Never decode, deserialize, display, or persist authentication bytes.
    # Missing is distinct from unreadable: callers must not infer a switch
    # from a sharing/access error.
    $stream = $null
    $sha = $null
    try {
        $path = Join-Path $CodexHome 'auth.json'
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.File]::Open(
            $path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share
        )
        $sha = [Security.Cryptography.SHA256]::Create()
        $digest = $sha.ComputeHash($stream)
        return ([BitConverter]::ToString($digest)).Replace('-', '').ToLowerInvariant()
    }
    catch [IO.FileNotFoundException] { return $null }
    catch [IO.DirectoryNotFoundException] { return $null }
    catch {
        throw 'ORCHESTRA_EXTERNAL: Codex authentication fingerprint is temporarily unavailable.'
    }
    finally {
        if ($null -ne $sha) { $sha.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Wait-CockpitQuiet {
    param(
        [string]$CodexHome = (Get-OrchestraCodexHome),
        [ValidateRange(0, 2147483647)][int]$RotationWaitMs = 10000
    )
    $limit = [int][Math]::Min(5000, [Math]::Max(200, $RotationWaitMs))
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($watch.Elapsed.TotalMilliseconds -lt $limit) {
            $active = $false
            $cutoff = [DateTime]::UtcNow.AddSeconds(-10)
            foreach ($name in @(
                '.cockpit-profile-mutation-locks', '.cockpit-token-locks'
            )) {
                $directory = Join-Path $CodexHome $name
                if (-not [IO.Directory]::Exists($directory)) { continue }
                $queue = New-Object 'System.Collections.Generic.Queue[string]'
                $queue.Enqueue($directory)
                while ($queue.Count -gt 0 -and -not $active -and
                    $watch.Elapsed.TotalMilliseconds -lt $limit) {
                    $current = $queue.Dequeue()
                    try {
                        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($current)) {
                            if ($watch.Elapsed.TotalMilliseconds -ge $limit) { break }
                            try {
                                $attributes = [IO.File]::GetAttributes($entry)
                                if ([IO.File]::GetLastWriteTimeUtc($entry) -ge $cutoff) {
                                    $active = $true
                                    break
                                }
                                $isDirectory = (
                                    $attributes -band [IO.FileAttributes]::Directory
                                ) -ne 0
                                $isLink = (
                                    $attributes -band [IO.FileAttributes]::ReparsePoint
                                ) -ne 0
                                if ($isDirectory -and -not $isLink) {
                                    $queue.Enqueue($entry)
                                }
                            }
                            catch [IO.FileNotFoundException] {}
                            catch [IO.DirectoryNotFoundException] {}
                            catch { $active = $true; break }
                        }
                    }
                    catch [IO.DirectoryNotFoundException] {}
                    catch { $active = $true }
                }
                if ($active) { break }
            }
            if (-not $active) { return }
            $remaining = $limit - $watch.Elapsed.TotalMilliseconds
            if ($remaining -lt 1) { return }
            $sleepMs = [int][Math]::Min(150, [Math]::Floor($remaining))
            if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
        }
    }
    finally { $watch.Stop() }
}

function Resolve-CodexExe {
    param(
        [hashtable]$Paths,
        [switch]$NoStateCache,
        [switch]$AccountRotation,
        [string]$CodexHome = (Get-OrchestraCodexHome),
        [int]$RotationWaitMs = 10000
    )
    $override = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_CODEX')
    $candidates = @{}
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $full = [IO.Path]::GetFullPath($override)
        if (-not [IO.File]::Exists($full)) {
            throw "ORCHESTRA_EXTERNAL: MODEL_ORCHESTRA_CODEX not found: $full"
        }
        $candidates[$full.ToLowerInvariant()] = $full
    }
    else {
        $local = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
        if (-not [string]::IsNullOrWhiteSpace($local)) {
            $modern = Join-Path $local 'OpenAI\Codex\bin'
            if ([IO.Directory]::Exists($modern)) {
                foreach ($directory in [IO.Directory]::GetDirectories($modern)) {
                    $file = Join-Path $directory 'codex.exe'
                    if ([IO.File]::Exists($file)) {
                        $candidates[$file.ToLowerInvariant()] = $file
                    }
                }
                $file = Join-Path $modern 'codex.exe'
                if ([IO.File]::Exists($file)) {
                    $candidates[$file.ToLowerInvariant()] = $file
                }
            }
            $legacy = Join-Path $local 'Programs\OpenAI\Codex\bin\codex.exe'
            if ([IO.File]::Exists($legacy)) {
                $candidates[$legacy.ToLowerInvariant()] = $legacy
            }
        }
        foreach ($command in @(
            Get-Command codex.exe -CommandType Application -All -ErrorAction SilentlyContinue
        )) {
            $file = [string]$command.Source
            if ([IO.File]::Exists($file)) {
                $candidates[$file.ToLowerInvariant()] = $file
            }
        }
    }
    $cache = $null
    if (-not $NoStateCache) {
        $state = Read-State -Paths $Paths
        $cache = Get-OrchestraProperty $state 'codex_exe_cache'
    }
    $valid = New-Object 'System.Collections.Generic.List[object]'
    foreach ($file in $candidates.Values) {
        $item = Get-Item -LiteralPath $file
        $version = $null
        $cachedPath = [string](Get-OrchestraProperty $cache 'path')
        if ($cachedPath -eq $file -and
            [long](Get-OrchestraProperty $cache 'length' -1) -eq $item.Length -and
            [string](Get-OrchestraProperty $cache 'last_write_utc') -eq
                $item.LastWriteTimeUtc.ToString('o')) {
            $parsed = [version]'0.0.0'
            if ([version]::TryParse(
                [string](Get-OrchestraProperty $cache 'version'), [ref]$parsed
            )) { $version = $parsed }
        }
        if ($null -eq $version) {
            try {
                if ($AccountRotation) {
                    Wait-CockpitQuiet -CodexHome $CodexHome -RotationWaitMs $RotationWaitMs
                }
                $probe = Invoke-OrchestraProcess -FilePath $file `
                    -Arguments @('--version') -TimeoutSec 3 -CaptureStdout
                if ($probe.timeout -or $probe.truncated -or $probe.exit_code -ne 0) {
                    continue
                }
                $match = [regex]::Match(
                    ($probe.stdout -join "`n"),
                    '(?<!\d)(\d+\.\d+\.\d+)(?:[-+][^\s]+)?'
                )
                if (-not $match.Success) { continue }
                $version = [version]$match.Groups[1].Value
            }
            catch { continue }
        }
        if ($version -lt [version]'0.153.0') { continue }
        [void]$valid.Add([pscustomobject]@{
            path = $file; version = $version; length = $item.Length
            last_write_utc = $item.LastWriteTimeUtc.ToString('o')
        })
    }
    $ordered = @($valid | Sort-Object -Property @{
        Expression = { $_.version }; Descending = $true
    }, @{
        Expression = { $_.last_write_utc }; Descending = $true
    })
    if ($ordered.Count -eq 0) {
        throw 'ORCHESTRA_EXTERNAL: No usable Codex >= 0.153.0 found.'
    }
    $winner = $ordered[0]
    if (-not $NoStateCache) {
        Invoke-WithLock -Paths $Paths -Name state -ScriptBlock {
            $fresh = Read-State -Paths $Paths
            Set-OrchestraProperty $fresh 'codex_exe_cache' ([pscustomobject]@{
                path = $winner.path; version = $winner.version.ToString()
                length = $winner.length; last_write_utc = $winner.last_write_utc
                checked_utc = (Get-OrchestraNow).ToString('o')
            })
            Save-State -Paths $Paths -State $fresh
        }
    }
    return [string]$winner.path
}

function Get-AgyWrapperPath {
    $override = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        return [IO.Path]::GetFullPath($override)
    }
    return [IO.Path]::GetFullPath((Join-Path $HOME '.gemini\bin\agy-exec.ps1'))
}

function Resolve-AgyWrapper {
    $path = Get-AgyWrapperPath
    if (-not [IO.File]::Exists($path)) {
        throw "ORCHESTRA_EXTERNAL: Agy wrapper not found: $path"
    }
    return $path
}

function Write-OrchestraResult {
    param($Object)
    $text = ConvertTo-Json -InputObject $Object -Depth 32 -Compress
    [Console]::Out.WriteLine($text)
    [Console]::Out.Flush()
}

function Get-OrchestraExitCode {
    param([string]$Message)
    if ($Message -match '^ORCHESTRA_ARGS:') { return 2 }
    if ($Message -match '^ORCHESTRA_QUOTA:') { return 4 }
    if ($Message -match '^ORCHESTRA_LOCK') { return 5 }
    return 3
}

function Get-OrchestraEventKey {
    param($Event)
    if ($null -eq $Event) { return $null }
    $type = [string](Get-OrchestraProperty $Event 'type')
    $id = [string](Get-OrchestraProperty $Event 'invocation_id')
    $ts = [string](Get-OrchestraProperty $Event 'ts')
    if ($type -eq 'invocation' -and -not [string]::IsNullOrWhiteSpace($id)) {
        return ('invocation:' + $id)
    }
    if ($type -eq 'outcome' -and -not [string]::IsNullOrWhiteSpace($id)) {
        $outcome = [string](Get-OrchestraProperty $Event 'outcome')
        $note = [string](Get-OrchestraProperty $Event 'note')
        return ('outcome:{0}:{1}:{2}:{3}' -f $id, $ts, $outcome, $note)
    }
    return ('raw:' + (ConvertTo-Json -InputObject $Event -Depth 32 -Compress))
}

function Write-LinesAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyCollection()][string[]]$Lines = @()
    )
    $target = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($target)
    [void][IO.Directory]::CreateDirectory($directory)
    $temporary = Join-Path $directory (
        '.' + [IO.Path]::GetFileName($target) + '.' +
        [Guid]::NewGuid().ToString('N') + '.tmp'
    )
    try {
        $content = ''
        if ($Lines.Count -gt 0) {
            $content = ($Lines -join "`n") + "`n"
        }
        [IO.File]::WriteAllText($temporary, $content, $script:OrchestraUtf8)
        if ([IO.File]::Exists($target)) {
            [IO.File]::Replace($temporary, $target, [NullString]::Value)
        }
        else {
            [IO.File]::Move($temporary, $target)
        }
    }
    finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Compact-UsageLedger {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [long]$MaxBytes = 2097152,
        [int]$RetainDays = 90,
        [switch]$Force
    )
    if ($MaxBytes -lt 0 -or $RetainDays -lt 1) {
        throw 'ORCHESTRA_ARGS: Invalid usage compaction thresholds.'
    }
    $work = {
        if (-not [IO.File]::Exists($Paths.Usage)) {
            return @{
                compacted = $false; archived_count = 0
                cold_removed_count = 0; hot_count = 0; archive_files = @()
            }
        }
        $usageInfo = Get-Item -LiteralPath $Paths.Usage
        if (-not $Force -and $usageInfo.Length -le $MaxBytes) {
            return @{
                compacted = $false; archived_count = 0
                cold_removed_count = 0; hot_count = 0; archive_files = @()
            }
        }

        $cutoff = (Get-OrchestraNow).AddDays(-$RetainDays)
        $records = New-Object 'System.Collections.Generic.List[object]'
        $hotIds = @{}
        $stream = [IO.File]::Open(
            $Paths.Usage, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite
        )
        $reader = New-Object IO.StreamReader($stream, $script:OrchestraUtf8, $true)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $parsed = $null
                $tsUtc = $null
                $hasTs = $false
                try {
                    $parsed = $line | ConvertFrom-Json
                }
                catch {
                    $parsed = $null
                }
                if ($null -eq $parsed) {
                    [void]$records.Add([pscustomobject]@{
                        raw = $line; key = ('corrupt:' + $line)
                        id = ''; month = 'unknown'; always_hot = $true
                    })
                    continue
                }
                $id = [string](Get-OrchestraProperty $parsed 'invocation_id')
                $rawTs = [string](Get-OrchestraProperty $parsed 'ts')
                $month = 'unknown'
                if (-not [string]::IsNullOrWhiteSpace($rawTs)) {
                    try {
                        $tsUtc = ConvertTo-OrchestraUtc $rawTs
                        $hasTs = $true
                        $month = $tsUtc.ToString('yyyyMM')
                    }
                    catch { $hasTs = $false }
                }
                $isRecent = (-not $hasTs) -or ($tsUtc -ge $cutoff)
                if ($isRecent -and -not [string]::IsNullOrWhiteSpace($id)) {
                    $hotIds[$id] = $true
                }
                $normalizedLine = ConvertTo-Json -InputObject $parsed -Depth 32 -Compress
                [void]$records.Add([pscustomobject]@{
                    raw = $normalizedLine
                    key = (Get-OrchestraEventKey $parsed)
                    id = $id
                    month = $month
                    always_hot = $isRecent
                })
            }
        }
        finally { $reader.Dispose() }

        $hotCandidates = New-Object 'System.Collections.Generic.List[object]'
        $coldByMonth = @{}
        $coldRemovedCount = 0

        foreach ($rec in $records) {
            $keepHot = [bool]$rec.always_hot -or (
                -not [string]::IsNullOrWhiteSpace($rec.id) -and
                $hotIds.ContainsKey($rec.id)
            )
            if ($keepHot) {
                [void]$hotCandidates.Add($rec)
            }
            else {
                $coldRemovedCount++
                if (-not $coldByMonth.ContainsKey($rec.month)) {
                    $coldByMonth[$rec.month] = New-Object 'System.Collections.Generic.List[object]'
                }
                [void]$coldByMonth[$rec.month].Add($rec)
            }
        }

        $lastHotIdx = @{}
        for ($hi = 0; $hi -lt $hotCandidates.Count; $hi++) {
            $lastHotIdx[$hotCandidates[$hi].key] = $hi
        }
        $hotLines = New-Object 'System.Collections.Generic.List[string]'
        for ($hi = 0; $hi -lt $hotCandidates.Count; $hi++) {
            if ($lastHotIdx[$hotCandidates[$hi].key] -eq $hi) {
                [void]$hotLines.Add([string]$hotCandidates[$hi].raw)
            }
        }

        $archiveDir = Join-Path $Paths.StateDir 'archive'
        $touchedArchives = New-Object 'System.Collections.Generic.List[string]'
        $newlyArchived = 0

        foreach ($month in @($coldByMonth.Keys | Sort-Object)) {
            $archivePath = Join-Path $archiveDir ("usage-$month.jsonl")
            $combinedArch = New-Object 'System.Collections.Generic.List[object]'
            $preExistingKeys = @{}
            if ([IO.File]::Exists($archivePath)) {
                $archStream = [IO.File]::Open(
                    $archivePath, [IO.FileMode]::Open,
                    [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite
                )
                $archReader = New-Object IO.StreamReader($archStream, $script:OrchestraUtf8, $true)
                try {
                    while ($null -ne ($aLine = $archReader.ReadLine())) {
                        if ([string]::IsNullOrWhiteSpace($aLine)) { continue }
                        $aKey = 'corrupt:' + $aLine
                        try {
                            $aObj = $aLine | ConvertFrom-Json
                            if ($null -ne $aObj) { $aKey = Get-OrchestraEventKey $aObj }
                        }
                        catch {}
                        $preExistingKeys[$aKey] = $true
                        [void]$combinedArch.Add([pscustomobject]@{ key = $aKey; raw = $aLine })
                    }
                }
                finally { $archReader.Dispose() }
            }
            $addedKeysThisBatch = @{}
            foreach ($coldRec in $coldByMonth[$month]) {
                if (-not $preExistingKeys.ContainsKey($coldRec.key) -and -not $addedKeysThisBatch.ContainsKey($coldRec.key)) {
                    $addedKeysThisBatch[$coldRec.key] = $true
                    $newlyArchived++
                }
                [void]$combinedArch.Add([pscustomobject]@{ key = $coldRec.key; raw = [string]$coldRec.raw })
            }
            $lastArchIdx = @{}
            for ($ai = 0; $ai -lt $combinedArch.Count; $ai++) {
                $lastArchIdx[$combinedArch[$ai].key] = $ai
            }
            $mergedLines = New-Object 'System.Collections.Generic.List[string]'
            for ($ai = 0; $ai -lt $combinedArch.Count; $ai++) {
                if ($lastArchIdx[$combinedArch[$ai].key] -eq $ai) {
                    [void]$mergedLines.Add([string]$combinedArch[$ai].raw)
                }
            }
            Write-LinesAtomic -Path $archivePath -Lines $mergedLines.ToArray()
            [void]$touchedArchives.Add($archivePath)
        }

        Write-LinesAtomic -Path $Paths.Usage -Lines $hotLines.ToArray()
        return @{
            compacted = $true
            archived_count = [int]$newlyArchived
            cold_removed_count = [int]$coldRemovedCount
            hot_count = [int]$hotLines.Count
            archive_files = $touchedArchives.ToArray()
        }
    }
    if (Test-OrchestraLockHeld -Paths $Paths -Name usage) { return (& $work) }
    return (Invoke-WithLock -Paths $Paths -Name usage -ScriptBlock $work)
}

function Remove-OldRegistryHistory {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [int]$KeepCount = 30
    )
    if ($KeepCount -lt 1) {
        throw 'ORCHESTRA_ARGS: KeepCount must be at least 1.'
    }
    $work = {
        if (-not [IO.Directory]::Exists($Paths.History)) {
            return @{ removed_count = 0; kept_count = 0; removed = @() }
        }
        $protectedRev = -1L
        if ([IO.File]::Exists($Paths.Registry)) {
            try {
                $reg = Read-JsonFile -Path $Paths.Registry
                if ($null -ne $reg) {
                    $protectedRev = [long](Get-OrchestraProperty $reg 'registry_rev' 0) - 1L
                }
            }
            catch {}
        }
        $files = @(
            Get-ChildItem -LiteralPath $Paths.History -Filter 'models-*.json' -File |
                Sort-Object `
                    @{ Expression = { if ($_.Name -match '^models-(\d{8}-\d{6})-') { $Matches[1] } else { '' } }; Descending = $true },
                    @{ Expression = { if ($_.Name -match '^models-\d{8}-\d{6}-(\d+)-') { [long]$Matches[1] } else { -1L } }; Descending = $true },
                    @{ Expression = { $_.Name }; Descending = $true }
        )
        $removed = New-Object 'System.Collections.Generic.List[string]'
        $keptCount = 0
        for ($i = 0; $i -lt $files.Count; $i++) {
            $file = $files[$i]
            if ($i -lt $KeepCount) {
                $keptCount++
                continue
            }
            $snapRev = -999L
            if ($file.Name -match '^models-\d{8}-\d{6}-(\d+)-') {
                $snapRev = [long]$Matches[1]
            }
            else {
                try {
                    $snap = Read-JsonFile -Path $file.FullName
                    if ($null -ne $snap) {
                        $snapRev = [long](Get-OrchestraProperty $snap 'registry_rev' -999)
                    }
                }
                catch {}
            }
            if ($protectedRev -ge 0 -and $snapRev -eq $protectedRev) {
                $keptCount++
                continue
            }
            Remove-Item -LiteralPath $file.FullName -Force
            [void]$removed.Add($file.FullName)
        }
        return @{
            removed_count = [int]$removed.Count
            kept_count = [int]$keptCount
            removed = $removed.ToArray()
        }
    }
    if (Test-OrchestraLockHeld -Paths $Paths -Name registry) { return (& $work) }
    return (Invoke-WithLock -Paths $Paths -Name registry -ScriptBlock $work)
}

function Test-PendingProposalConflict {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [Parameter(Mandatory = $true)][string]$ModelId,
        [string[]]$PatchPaths = @()
    )
    if (-not [IO.Directory]::Exists($Paths.Proposals)) { return $false }
    $wanted = @{}
    foreach ($p in @($PatchPaths)) {
        if (-not [string]::IsNullOrWhiteSpace($p)) { $wanted[$p] = $true }
    }
    $files = @(Get-ChildItem -LiteralPath $Paths.Proposals -Filter '*.json' -File)
    foreach ($file in $files) {
        if ($file.Name -match '\.approved\.json$') { continue }
        $proposal = $null
        try { $proposal = Read-JsonFile -Path $file.FullName } catch { continue }
        if ($null -eq $proposal) { continue }
        if ([string](Get-OrchestraProperty $proposal 'status') -ne 'pending') { continue }
        if ($wanted.Count -eq 0) {
            if ([string](Get-OrchestraProperty $proposal 'model_id') -ceq $ModelId) { return $true }
            continue
        }
        foreach ($op in @(Get-OrchestraArray $proposal 'patch')) {
            $opType = [string](Get-OrchestraProperty $op 'op')
            $opKey = ''
            if ($opType -eq 'add_hard_rule') {
                $ruleVal = Get-OrchestraProperty $op 'value'
                $opKey = 'hard_rules/' + [string](Get-OrchestraProperty $ruleVal 'id')
            }
            else {
                $opKey = [string](Get-OrchestraProperty $op 'path')
            }
            if (-not [string]::IsNullOrWhiteSpace($opKey) -and $wanted.ContainsKey($opKey)) {
                return $true
            }
        }
    }
    return $false
}
