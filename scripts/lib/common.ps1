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
$script:CodexFeaturesMemCache = @{}

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
        Slots = Join-Path $stateDirectory 'slots'
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $null }
    $text = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
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
            break
        }
        catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
            return $null
        }
        catch [IO.IOException] {
            if ($attempt -ge 3) { throw }
            Start-Sleep -Milliseconds 5
        }
        finally {
            if ($null -ne $sr) { $sr.Dispose() }
            elseif ($null -ne $fs) { $fs.Dispose() }
        }
    }
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
    if ($Name -eq 'registry') {
        $regDir = [string](Get-OrchestraProperty $Paths 'RegistryDir' '')
        if ([string]::IsNullOrWhiteSpace($regDir)) {
            $regDir = [IO.Path]::GetDirectoryName([string]$Paths.Registry)
        }
        return [IO.Path]::GetFullPath((Join-Path $regDir '.registry.lock')).ToLowerInvariant()
    }
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
    $ranks = @{ registry = 1; state = 2; usage = 3; slots = 4 }
    if (-not $ranks.ContainsKey($Name) -or $TimeoutSec -lt 0) {
        throw 'ORCHESTRA_ARGS: Invalid lock name or timeout.'
    }
    $key = Get-OrchestraLockKey -Paths $Paths -Name $Name
    if ($script:OrchestraHeldLocks.ContainsKey($key)) {
        throw "ORCHESTRA_LOCK_TIMEOUT: Reentrant lock: $Name"
    }
    foreach ($held in $script:OrchestraHeldLocks.Values) {
        if ([int]$held -gt [int]$ranks[$Name]) {
            throw 'ORCHESTRA_LOCK_ORDER: Use registry, state, usage, slots order.'
        }
    }
    $lockParent = [IO.Path]::GetDirectoryName($key)
    if (-not [string]::IsNullOrWhiteSpace($lockParent)) {
        [void][IO.Directory]::CreateDirectory($lockParent)
    }
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
            $hr = $_.Exception.HResult
            if ($hr -notin @(-2147024864, -2147024863)) {
                throw
            }
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSec) {
                throw "ORCHESTRA_LOCK_TIMEOUT: $Name"
            }
            Start-Sleep -Milliseconds (Get-Random -Minimum 8 -Maximum 36)
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
    $nl = "`n"
    $existingText = ''
    if (-not $isNew) {
        $existingText = [IO.File]::ReadAllText($Paths.Changelog, $script:OrchestraUtf8)
        if ($existingText.Contains("`r`n")) {
            $nl = "`r`n"
        }
    }
    $stamp = (Get-OrchestraNow).ToString('o')
    $safeTitle = $Title -replace '[\r\n]+', ' '
    $builder = New-Object Text.StringBuilder
    if ($isNew) {
        [void]$builder.Append('# Model orchestra changelog' + $nl + $nl)
    }
    elseif ($existingText.Length -gt 0 -and -not $existingText.EndsWith("`n")) {
        [void]$builder.Append($nl)
    }
    [void]$builder.Append("## $stamp - $safeTitle" + $nl)
    foreach ($line in $Lines) {
        [void]$builder.Append('- ' + ($line -replace '[\r\n]+', ' ') + $nl)
    }
    [void]$builder.Append($nl)
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
        'sources', 'exhausted', 'low', 'research_leases', 'codex_exe_cache', 'codex_features_cache'
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
    return ($Slug.Trim() -replace '-(low|medium|high|xhigh|max|ultra)$', '')
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

function New-OutcomeStatsIndex {
    param(
        [AllowEmptyCollection()][object[]]$Events = @(),
        [int]$WindowDays = 30
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
    $rawByModel = @{}
    $now = Get-OrchestraNow
    $cutoff = $now.AddDays(-$WindowDays)
    foreach ($id in $invocations.Keys) {
        $invocation = $invocations[$id]
        if (-not $outcomes.ContainsKey($id)) { continue }
        $modelKey = [string](Get-OrchestraProperty $invocation 'model')
        if ([string]::IsNullOrWhiteSpace($modelKey)) { continue }
        try {
            $stamp = ConvertTo-OrchestraUtc (
                [string](Get-OrchestraProperty $invocation 'ts')
            )
        }
        catch { continue }
        if ($stamp -lt $cutoff -or $stamp -gt $now) { continue }
        $tagValues = Get-OrchestraProperty $invocation 'tags' @()
        $invocationTags = @(
            foreach ($t in @($tagValues)) {
                [string]$t
            }
        )
        $row = $outcomes[$id]
        $value = [string](Get-OrchestraProperty $row.event 'outcome')
        if (-not $rawByModel.ContainsKey($modelKey)) {
            $rawByModel[$modelKey] = New-Object 'System.Collections.Generic.List[object]'
        }
        [void]$rawByModel[$modelKey].Add([pscustomobject]@{
            outcome = $value
            sequence = [int]$row.sequence
            ts = $stamp
            tags = $invocationTags
        })
    }
    $sortedByModel = @{}
    foreach ($modelKey in $rawByModel.Keys) {
        $sortedByModel[$modelKey] = @($rawByModel[$modelKey].ToArray() | Sort-Object sequence -Descending)
    }
    return @{
        window_days = $WindowDays
        by_model = $sortedByModel
    }
}

function Get-OutcomeStats {
    param(
        [AllowEmptyCollection()][object[]]$Events = @(), [string]$ModelId,
        [string[]]$Tags = @(), [int]$WindowDays = 30, $Index = $null
    )
    if ($null -eq $Index) {
        $Index = New-OutcomeStatsIndex -Events $Events -WindowDays $WindowDays
    }
    else {
        $indexWindow = [int](Get-OrchestraProperty $Index 'window_days' 0)
        if ($WindowDays -gt $indexWindow) {
            throw "ORCHESTRA_ARGS: Requested WindowDays ($WindowDays) exceeds OutcomeStatsIndex window_days ($indexWindow)."
        }
    }
    $stats = @{
        n = 0; ok = 0; redo = 0; fail = 0
        ok_invocations = 0; ok_tags = @(); consecutive_fail = 0
    }
    if (-not $Index.by_model.ContainsKey($ModelId)) {
        return $stats
    }
    $now = Get-OrchestraNow
    $cutoff = $now.AddDays(-$WindowDays)
    $okTags = @{}
    $streakOpen = $true
    $filterTags = (@($Tags).Count -gt 0)
    foreach ($row in @($Index.by_model[$ModelId])) {
        $rowTs = Get-OrchestraProperty $row 'ts' $null
        if ($null -ne $rowTs -and ($rowTs -lt $cutoff -or $rowTs -gt $now)) {
            continue
        }
        if ($filterTags) {
            $matched = $false
            foreach ($tg in $row.tags) {
                if ($Tags -contains $tg) { $matched = $true; break }
            }
            if (-not $matched) { continue }
        }
        $value = [string]$row.outcome
        $stats.n++
        $stats[$value]++
        if ($streakOpen) {
            if ($value -eq 'fail') { $stats.consecutive_fail++ }
            else { $streakOpen = $false }
        }
        if ($value -eq 'ok') {
            $stats.ok_invocations++
            foreach ($tg in $row.tags) {
                if (-not [string]::IsNullOrWhiteSpace($tg)) {
                    $okTags[$tg] = $true
                }
            }
        }
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
        $regKey = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        $proxyEnable = [Microsoft.Win32.Registry]::GetValue($regKey, 'ProxyEnable', 0)
        $proxyServer = [Microsoft.Win32.Registry]::GetValue($regKey, 'ProxyServer', $null)
        if ($null -ne $proxyEnable -and [int]$proxyEnable -eq 1 -and -not [string]::IsNullOrWhiteSpace([string]$proxyServer)) {
            $rawProxy = ([string]$proxyServer).Trim()
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
        try {
            $completed = $connectTask.Wait($TimeoutMs)
        }
        catch {
            $completed = $false
        }
        if ($completed -and $tcp.Connected -and -not $connectTask.IsFaulted) {
            return @{ checked = $true; reachable = $true; detail = $safeDetailUrl }
        }
        return @{
            checked = $true
            reachable = $false
            detail = ('Local proxy ' + $safeDetailUrl + ' is unreachable (TCP connect failed within ' + $TimeoutMs + 'ms).')
        }
    }
    catch {
        return @{
            checked = $true
            reachable = $false
            detail = ('Local proxy ' + $safeDetailUrl + ' check failed: ' + $_.Exception.Message)
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
                    ($watch.Elapsed.TotalSeconds - $exitSeenAt) -ge 10.0) {
                    $truncated = $true
                    break
                }
            }
            if (-not $progress) {
                $pendingTasks = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task]'
                if (-not $outputDone -and $null -ne $outputTask) {
                    [void]$pendingTasks.Add([System.Threading.Tasks.Task]$outputTask)
                }
                if (-not $errorDone -and $null -ne $errorTask) {
                    [void]$pendingTasks.Add([System.Threading.Tasks.Task]$errorTask)
                }
                if ($null -ne $inputTask) {
                    [void]$pendingTasks.Add([System.Threading.Tasks.Task]$inputTask)
                }
                if ($pendingTasks.Count -gt 0) {
                    try {
                        $null = [System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]$pendingTasks.ToArray(), 25)
                    }
                    catch {}
                }
                else {
                    Start-Sleep -Milliseconds 5
                }
            }
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

function Get-CodexConfigCliPath {
    param(
        [string]$CodexHome = (Get-OrchestraCodexHome)
    )
    if ([string]::IsNullOrWhiteSpace($CodexHome)) { return $null }
    $cfgFile = Join-Path $CodexHome 'config.toml'
    if (-not [IO.File]::Exists($cfgFile)) { return $null }
    try {
        $lines = [IO.File]::ReadAllLines($cfgFile, $script:OrchestraUtf8)
        foreach ($rawLine in $lines) {
            $trimmed = ([string]$rawLine).Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }
            if ($trimmed -match '^CODEX_CLI_PATH\s*=\s*(.+)$') {
                $rhs = $Matches[1].Trim()
                $decoded = $null
                if ($rhs -match "^'([^']*)'\s*(?:#.*)?$") {
                    $decoded = $Matches[1]
                }
                elseif ($rhs -match '^"((?:[^"\\]|\\.)*)"\s*(?:#.*)?$') {
                    $decoded = $Matches[1].Replace('\\', '\').Replace('\"', '"')
                }
                if ([string]::IsNullOrWhiteSpace($decoded)) { continue }
                $hasCtrl = $false
                foreach ($c in $decoded.ToCharArray()) {
                    $cc = [int][char]$c
                    if ($cc -lt 32 -or $cc -eq 127) { $hasCtrl = $true; break }
                }
                if ($hasCtrl) { continue }
                if (-not [IO.Path]::IsPathRooted($decoded)) { continue }
                $full = [IO.Path]::GetFullPath($decoded)
                if ([IO.Path]::GetFileName($full) -ieq 'codex.exe' -and [IO.File]::Exists($full)) {
                    return $full
                }
            }
        }
    }
    catch {}
    return $null
}

function Get-CodexModelCatalogOverride {
    param(
        [string]$CodexHome = (Get-OrchestraCodexHome),
        [string]$ModelSlug = '',
        [double]$MaxAgeHours = 24.0
    )
    if ([string]::IsNullOrWhiteSpace($CodexHome) -or $MaxAgeHours -le 0) {
        return [ordered]@{ applied = $false; path = $null; config_args = @(); reason = 'disabled' }
    }
    $cachePath = Join-Path $CodexHome 'models_cache.json'
    if (-not [IO.File]::Exists($cachePath)) {
        return [ordered]@{ applied = $false; path = $null; config_args = @(); reason = 'missing' }
    }
    $fullPath = [IO.Path]::GetFullPath($cachePath)
    foreach ($c in $fullPath.ToCharArray()) {
        $cc = [int][char]$c
        if ($cc -lt 32 -or $cc -eq 127) {
            return [ordered]@{ applied = $false; path = $null; config_args = @(); reason = 'invalid_path' }
        }
    }
    try {
        $rawText = [IO.File]::ReadAllText($fullPath, $script:OrchestraUtf8)
        if ([string]::IsNullOrWhiteSpace($rawText)) {
            return [ordered]@{ applied = $false; path = $fullPath; config_args = @(); reason = 'empty' }
        }
        $doc = $rawText | ConvertFrom-Json
        if ($null -eq $doc) {
            return [ordered]@{ applied = $false; path = $fullPath; config_args = @(); reason = 'invalid_json' }
        }
        $modelsArr = @(Get-OrchestraArray $doc 'models')
        if ($modelsArr.Count -eq 0) {
            return [ordered]@{ applied = $false; path = $fullPath; config_args = @(); reason = 'no_models' }
        }
        if (-not [string]::IsNullOrWhiteSpace($ModelSlug)) {
            $hasSlug = $false
            foreach ($entry in $modelsArr) {
                if ([string](Get-OrchestraProperty $entry 'slug' '') -ceq $ModelSlug) {
                    $hasSlug = $true
                    break
                }
            }
            if (-not $hasSlug) {
                return [ordered]@{ applied = $false; path = $fullPath; config_args = @(); reason = 'model_not_in_catalog' }
            }
        }
        $nowUtc = Get-OrchestraNow
        $stampUtc = $null
        $fetchedText = [string](Get-OrchestraProperty $doc 'fetched_at' '')
        if (-not [string]::IsNullOrWhiteSpace($fetchedText)) {
            try { $stampUtc = ConvertTo-OrchestraUtc $fetchedText } catch { $stampUtc = $null }
        }
        if ($null -eq $stampUtc) {
            $stampUtc = [IO.File]::GetLastWriteTimeUtc($fullPath)
        }
        $ageHours = ($nowUtc - $stampUtc).TotalHours
        if ($ageHours -gt $MaxAgeHours -or $ageHours -lt -1.0) {
            return [ordered]@{ applied = $false; path = $fullPath; config_args = @(); reason = 'stale' }
        }
        $escapedPath = $fullPath.Replace('\', '\\').Replace('"', '\"')
        return [ordered]@{
            applied = $true
            path = $fullPath
            config_args = @('-c', ('model_catalog_json="' + $escapedPath + '"'))
            reason = 'fresh'
        }
    }
    catch {
        return [ordered]@{ applied = $false; path = $fullPath; config_args = @(); reason = 'parse_error' }
    }
}

function Resolve-CodexExe {
    param(
        [hashtable]$Paths,
        [object]$State = $null,
        [switch]$NoStateCache,
        [switch]$AccountRotation,
        [string]$CodexHome = (Get-OrchestraCodexHome),
        [int]$RotationWaitMs = 10000
    )
    $override = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_CODEX')
    $hasOverride = -not [string]::IsNullOrWhiteSpace($override)
    $cacheState = $State
    if (-not $hasOverride -and -not $NoStateCache) {
        if ($null -eq $cacheState -and $null -ne $Paths) {
            $cacheState = Read-State -Paths $Paths
        }
        $quickCache = Get-OrchestraProperty $cacheState 'codex_exe_cache'
        $quickPath = [string](Get-OrchestraProperty $quickCache 'path' '')
        $quickSource = [string](Get-OrchestraProperty $quickCache 'source' '')
        if (
            $quickSource -eq 'discovered' -and
            -not [string]::IsNullOrWhiteSpace($quickPath) -and
            [IO.File]::Exists($quickPath)
        ) {
            $quickItem = Get-Item -LiteralPath $quickPath
            $quickVer = [string](Get-OrchestraProperty $quickCache 'version' '')
            $parsedQuick = [version]'0.0.0'
            if (
                [long](Get-OrchestraProperty $quickCache 'length' -1) -eq $quickItem.Length -and
                [string](Get-OrchestraProperty $quickCache 'last_write_utc' '') -ceq $quickItem.LastWriteTimeUtc.ToString('o') -and
                [version]::TryParse($quickVer, [ref]$parsedQuick) -and
                $parsedQuick -ge [version]'0.153.0'
            ) {
                return $quickPath
            }
        }
    }

    $candidates = @{}
    if ($hasOverride) {
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
        foreach ($extRoot in @(
            (Join-Path $HOME '.vscode\extensions'),
            (Join-Path $HOME '.antigravity\extensions')
        )) {
            if ([IO.Directory]::Exists($extRoot)) {
                try {
                    foreach ($extDir in [IO.Directory]::GetDirectories($extRoot, 'openai.chatgpt-*')) {
                        $file = Join-Path $extDir 'bin\windows-x86_64\codex.exe'
                        if ([IO.File]::Exists($file)) {
                            $candidates[$file.ToLowerInvariant()] = $file
                        }
                    }
                }
                catch {}
            }
        }
        $cfgCliPath = Get-CodexConfigCliPath -CodexHome $CodexHome
        if (-not [string]::IsNullOrWhiteSpace($cfgCliPath) -and [IO.File]::Exists($cfgCliPath)) {
            $candidates[$cfgCliPath.ToLowerInvariant()] = $cfgCliPath
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
    if (-not $hasOverride -and -not $NoStateCache) {
        if ($null -eq $cacheState -and $null -ne $Paths) {
            $cacheState = Read-State -Paths $Paths
        }
        $cache = Get-OrchestraProperty $cacheState 'codex_exe_cache'
    }
    $valid = New-Object 'System.Collections.Generic.List[object]'
    foreach ($file in $candidates.Values) {
        $item = Get-Item -LiteralPath $file
        $version = $null
        $cachedPath = [string](Get-OrchestraProperty $cache 'path')
        $cachedSource = [string](Get-OrchestraProperty $cache 'source' '')
        if ($cachedSource -eq 'discovered' -and
            $cachedPath -eq $file -and
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
    if (-not $hasOverride -and -not $NoStateCache) {
        Invoke-WithLock -Paths $Paths -Name state -ScriptBlock {
            $fresh = Read-State -Paths $Paths
            Set-OrchestraProperty $fresh 'codex_exe_cache' ([pscustomobject]@{
                path = $winner.path; version = $winner.version.ToString()
                length = $winner.length; last_write_utc = $winner.last_write_utc
                source = 'discovered'
                checked_utc = (Get-OrchestraNow).ToString('o')
            })
            Save-State -Paths $Paths -State $fresh
        }
    }
    return [string]$winner.path
}

function Get-CodexSupportedFeatures {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [hashtable]$Paths = $null,
        [object]$State = $null,
        [switch]$NoStateCache
    )
    if (
        [string]::IsNullOrWhiteSpace($Executable) -or
        [IO.Path]::GetExtension($Executable) -ieq '.ps1' -or
        -not [IO.File]::Exists($Executable)
    ) {
        return $null
    }
    $item = Get-Item -LiteralPath $Executable
    $fullPath = $item.FullName
    $len = [long]$item.Length
    $mtime = $item.LastWriteTimeUtc.ToString('o')
    $memKey = ($fullPath + '|' + $len + '|' + $mtime).ToLowerInvariant()
    if ($script:CodexFeaturesMemCache.ContainsKey($memKey)) {
        return $script:CodexFeaturesMemCache[$memKey]
    }

    if ($null -ne $State -or $null -ne $Paths) {
        try {
            $st = if ($null -ne $State) { $State } else { Read-State -Paths $Paths }
            $fc = Get-OrchestraProperty $st 'codex_features_cache'
            if (
                $null -ne $fc -and
                [string](Get-OrchestraProperty $fc 'path' '') -ceq $fullPath -and
                [long](Get-OrchestraProperty $fc 'length' -1) -eq $len -and
                [string](Get-OrchestraProperty $fc 'last_write_utc' '') -ceq $mtime
            ) {
                $cachedArr = @(Get-OrchestraArray $fc 'features')
                if ($cachedArr.Count -gt 0) {
                    $cachedSet = @{}
                    foreach ($f in $cachedArr) {
                        $fs = ([string]$f).Trim()
                        if ($fs.Length -gt 0) { $cachedSet[$fs] = $true }
                    }
                    $script:CodexFeaturesMemCache[$memKey] = $cachedSet
                    return $cachedSet
                }
            }
        }
        catch {}
    }

    try {
        $probe = Invoke-OrchestraProcess -FilePath $fullPath `
            -Arguments @('features', 'list') -TimeoutSec 5 -CaptureStdout
        if ($probe.timeout -or $probe.truncated -or $probe.exit_code -ne 0) {
            return @{}
        }
        $list = New-Object 'System.Collections.Generic.List[string]'
        $map = @{}
        foreach ($line in @($probe.stdout)) {
            if ([string]$line -match '^\s*([a-z0-9_]+)\s+(.+?)\s+(?:true|false)\s*$') {
                $feat = $Matches[1]
                $stage = $Matches[2].Trim().ToLowerInvariant()
                if ($stage -ne 'removed' -and -not $map.ContainsKey($feat)) {
                    $map[$feat] = $true
                    [void]$list.Add($feat)
                }
            }
        }
        if ($list.Count -eq 0) { return @{} }
        $script:CodexFeaturesMemCache[$memKey] = $map
        if (-not $NoStateCache -and $null -ne $Paths) {
            try {
                Invoke-WithLock -Paths $Paths -Name state -ScriptBlock {
                    $fresh = Read-State -Paths $Paths
                    Set-OrchestraProperty $fresh 'codex_features_cache' ([pscustomobject]@{
                        path = $fullPath
                        length = $len
                        last_write_utc = $mtime
                        features = @($list.ToArray())
                        checked_utc = (Get-OrchestraNow).ToString('o')
                    })
                    Save-State -Paths $Paths -State $fresh
                }
            }
            catch {}
        }
        return $map
    }
    catch {
        return @{}
    }
}

function Get-CodexStealthArguments {
    param(
        [hashtable]$SupportedFeatures = $null,
        [string[]]$Tags = @()
    )
    $out = New-Object 'System.Collections.Generic.List[string]'
    $enableCandidates = @('skip_host_skill_discovery', 'omit_skill_descriptions')
    $enabledUnstable = $false
    foreach ($feat in $enableCandidates) {
        if ($null -eq $SupportedFeatures -or $SupportedFeatures.ContainsKey($feat)) {
            $enabledUnstable = $true
            break
        }
    }
    if ($enabledUnstable) {
        [void]$out.Add('-c')
        [void]$out.Add('suppress_unstable_features_warning=true')
    }
    foreach ($feat in $enableCandidates) {
        if ($null -eq $SupportedFeatures -or $SupportedFeatures.ContainsKey($feat)) {
            [void]$out.Add('--enable')
            [void]$out.Add($feat)
        }
    }
    $disableCandidates = @(
        'plugins', 'plugin_discovery_prefetch', 'remote_plugin',
        'apps', 'browser_use', 'browser_use_external', 'computer_use',
        'in_app_browser', 'in_app_chat', 'in_app_dictation',
        'in_app_local_automation', 'in_app_updates', 'in_app_voice',
        'multi_agent', 'shell_snapshot', 'skill_search',
        'skill_mcp_dependency_install', 'tool_suggest',
        'tool_call_mcp_elicitation', 'deferred_tool_world_state',
        'image_generation', 'guardian_approval',
        'hooks', 'sleep_tool', 'plugin_sharing',
        'browser_annotation_api', 'browser_use_full_cdp_access',
        'goals', 'bedrock_setup_wizard',
        'mcp_oauth_refresh_coordination', 'workspace_dependencies',
        'view_image'
    )
    $keepViewImage = (@($Tags | Where-Object { $_ -in @('image_gen', 'frontend', 'ui', 'landing_page', 'office', 'ppt') }).Count -gt 0)
    foreach ($feat in $disableCandidates) {
        if ($feat -eq 'image_generation' -and (@($Tags) -contains 'image_gen')) {
            continue
        }
        if ($feat -eq 'view_image' -and $keepViewImage) {
            continue
        }
        if ($null -eq $SupportedFeatures -or $SupportedFeatures.ContainsKey($feat)) {
            [void]$out.Add('--disable')
            [void]$out.Add($feat)
        }
    }
    return @($out.ToArray())
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

function Get-AgyExecutablePath {
    $wrapperOverride = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER')
    if (-not [string]::IsNullOrWhiteSpace($wrapperOverride)) {
        return [IO.Path]::GetFullPath($wrapperOverride)
    }

    foreach ($envName in @('MODEL_ORCHESTRA_AGY_EXE', 'AGY_EXEC_BIN')) {
        $exeOverride = [Environment]::GetEnvironmentVariable($envName)
        if (-not [string]::IsNullOrWhiteSpace($exeOverride)) {
            return [IO.Path]::GetFullPath($exeOverride)
        }
    }

    $homeAgyExe = [IO.Path]::GetFullPath((Join-Path $HOME '.gemini\bin\agy.exe'))
    if ([IO.File]::Exists($homeAgyExe)) {
        return $homeAgyExe
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $localAppAgyExe = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'))
        if ([IO.File]::Exists($localAppAgyExe)) {
            return $localAppAgyExe
        }
    }

    return (Get-AgyWrapperPath)
}

function Resolve-AgyExecutable {
    $path = Get-AgyExecutablePath
    if (-not [IO.File]::Exists($path)) {
        throw "ORCHESTRA_EXTERNAL: Agy executable not found: $path"
    }
    return $path
}

function ConvertTo-RedactedProxyUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    return ([regex]::Replace($Url, '^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@]+@', '${1}***@'))
}

function Get-CodexEssentialConfigOverrides {
    param(
        [string]$CodexHome = (Get-OrchestraCodexHome)
    )

    $modelProvider = 'openai'
    $forcedLoginMethod = ''
    $serviceTier = ''
    $windowsSandbox = 'unelevated'
    $fastConfigSupported = $true
    $fallbackReason = $null

    if (-not [string]::IsNullOrWhiteSpace($CodexHome)) {
        $cfgFile = Join-Path $CodexHome 'config.toml'
        if ([IO.File]::Exists($cfgFile)) {
            $section = ''
            $lines = [IO.File]::ReadAllLines($cfgFile, (New-Object System.Text.UTF8Encoding($false)))
            $inTripleQuote = $false
            $tripleDelimiter = ''
            foreach ($rawLine in $lines) {
                $lineStr = [string]$rawLine
                if ($inTripleQuote) {
                    $closeIdx = $lineStr.IndexOf($tripleDelimiter, [StringComparison]::Ordinal)
                    if ($closeIdx -ge 0) {
                        $inTripleQuote = $false
                        $tripleDelimiter = ''
                    }
                    continue
                }

                $trimmed = $lineStr.Trim()
                if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
                    continue
                }
                if ($trimmed -match '^\[+([^\[\]]+)\]+\s*(?:#.*)?$') {
                    $section = $Matches[1].Trim().Replace('"', '').Replace("'", '').ToLowerInvariant()
                    if (
                        $section -eq 'model_providers' -or
                        $section -like 'model_providers.*' -or
                        $section -eq 'profiles' -or
                        $section -like 'profiles.*'
                    ) {
                        $fastConfigSupported = $false
                        $fallbackReason = "Unsupported config.toml section [$section]."
                        break
                    }
                    continue
                }

                if ($trimmed -match '^([A-Za-z0-9_.-]+)\s*=\s*(.+)$') {
                    $key = $Matches[1].Trim()
                    $keyLower = $key.ToLowerInvariant()
                    $rhs = $Matches[2].Trim()

                    $isEssential = (
                        ($section -eq '' -and $keyLower -in @('model_provider', 'forced_login_method', 'service_tier', 'windows.sandbox')) -or
                        ($section -eq 'windows' -and $keyLower -eq 'sandbox')
                    )

                    if (
                        $section -eq '' -and (
                            $keyLower -in @('openai_base_url', 'forced_chatgpt_workspace_id', 'cli_auth_credentials_store', 'chatgpt_base_url', 'profile', 'model_providers', 'profiles') -or
                            $keyLower -like 'model_providers.*' -or
                            $keyLower -like 'profiles.*'
                        )
                    ) {
                        $fastConfigSupported = $false
                        $fallbackReason = "Unsupported top-level key '$keyLower' in config.toml."
                        break
                    }
                    if ($section -eq '' -and $keyLower -eq 'windows' -and $rhs -match '^\{') {
                        $fastConfigSupported = $false
                        $fallbackReason = 'Inline [windows] table in config.toml is not supported.'
                        break
                    }

                    if ($rhs.StartsWith('"""') -or $rhs.StartsWith("'''")) {
                        $delim = $rhs.Substring(0, 3)
                        $rest = $rhs.Substring(3)
                        if ($isEssential) {
                            $fastConfigSupported = $false
                            $fallbackReason = "Multiline string in essential key '$keyLower' is not supported."
                            break
                        }
                        $closedOnLine = if ($delim -eq '"""') { $rest -match '(?<!\\)"""' } else { $rest.Contains("'''") }
                        if (-not $closedOnLine) {
                            $inTripleQuote = $true
                            $tripleDelimiter = $delim
                        }
                        continue
                    }

                    if (-not $isEssential) {
                        continue
                    }

                    $decoded = $null
                    if ($rhs -match "^'([^']*)'\s*(?:#.*)?$") {
                        $decoded = $Matches[1]
                    }
                    elseif ($rhs -match '^"((?:[^"\\]|\\.)*)"\s*(?:#.*)?$') {
                        $rawInner = $Matches[1]
                        $sb = New-Object System.Text.StringBuilder
                        $parseOk = $true
                        for ($idx = 0; $idx -lt $rawInner.Length; $idx++) {
                            $ch = $rawInner[$idx]
                            $code = [int][char]$ch
                            if ($code -lt 32 -or $code -eq 127) {
                                $parseOk = $false
                                break
                            }
                            if ($ch -eq '\') {
                                if ($idx + 1 -ge $rawInner.Length) {
                                    $parseOk = $false
                                    break
                                }
                                $nextCh = $rawInner[$idx + 1]
                                if ($nextCh -eq '\' -or $nextCh -eq '"') {
                                    [void]$sb.Append($nextCh)
                                    $idx++
                                }
                                else {
                                    $parseOk = $false
                                    break
                                }
                            }
                            else {
                                [void]$sb.Append($ch)
                            }
                        }
                        if ($parseOk) {
                            $decoded = $sb.ToString()
                        }
                    }

                    if ($null -eq $decoded) {
                        $fastConfigSupported = $false
                        $fallbackReason = "Unsupported scalar value or escape sequence for '$keyLower' in config.toml."
                        break
                    }
                    foreach ($c in $decoded.ToCharArray()) {
                        $cc = [int][char]$c
                        if ($cc -lt 32 -or $cc -eq 127) {
                            $fastConfigSupported = $false
                            $fallbackReason = "Control character in '$keyLower' value in config.toml."
                            break
                        }
                    }
                    if (-not $fastConfigSupported) { break }

                    $val = $decoded.Trim()
                    if ($section -eq '') {
                        switch ($keyLower) {
                            'model_provider' {
                                if (-not [string]::IsNullOrWhiteSpace($val)) { $modelProvider = $val }
                            }
                            'forced_login_method' { $forcedLoginMethod = $val }
                            'service_tier' { $serviceTier = $val }
                            'windows.sandbox' {
                                if (-not [string]::IsNullOrWhiteSpace($val)) { $windowsSandbox = $val }
                            }
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
        [void]$configArgs.Add('-c')
        [void]$configArgs.Add(('model_provider="' + ($modelProvider.Replace('\', '\\').Replace('"', '\"')) + '"'))
        if (-not [string]::IsNullOrWhiteSpace($forcedLoginMethod)) {
            [void]$configArgs.Add('-c')
            [void]$configArgs.Add(('forced_login_method="' + ($forcedLoginMethod.Replace('\', '\\').Replace('"', '\"')) + '"'))
        }
        if (-not [string]::IsNullOrWhiteSpace($serviceTier)) {
            [void]$configArgs.Add('-c')
            [void]$configArgs.Add(('service_tier="' + ($serviceTier.Replace('\', '\\').Replace('"', '\"')) + '"'))
        }
        [void]$configArgs.Add('-c')
        [void]$configArgs.Add(('windows.sandbox="' + ($windowsSandbox.Replace('\', '\\').Replace('"', '\"')) + '"'))
    }

    return [ordered]@{
        fast_config_supported = [bool]$fastConfigSupported
        fallback_reason       = $fallbackReason
        model_provider        = $modelProvider
        forced_login_method   = $forcedLoginMethod
        service_tier          = $serviceTier
        windows_sandbox       = $windowsSandbox
        config_args           = @($configArgs.ToArray())
    }
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

function Get-OrchestraPoolName {
    param($Model, [string]$Channel = '')
    $ch = if (-not [string]::IsNullOrWhiteSpace($Channel)) {
        $Channel.Trim().ToLowerInvariant()
    }
    else {
        ([string](Get-OrchestraProperty $Model 'channel' '')).Trim().ToLowerInvariant()
    }
    $vendor = ([string](Get-OrchestraProperty $Model 'vendor' '')).Trim().ToLowerInvariant()
    $id = ([string](Get-OrchestraProperty $Model 'id' '')).Trim().ToLowerInvariant()
    if ($ch -eq 'codex') { return 'codex_openai' }
    if ($vendor -eq 'anthropic' -or $id -match '^claude-') { return 'agy_anthropic' }
    return 'agy_google'
}

function Get-OrchestraPoolLimits {
    param($Policy = $null)
    $limits = [ordered]@{
        codex_openai = 4
        agy_anthropic = 3
        agy_google = 7
    }
    if ($null -ne $Policy) {
        $cfg = Get-OrchestraProperty $Policy 'pool_concurrency_limits' $null
        if ($null -ne $cfg) {
            foreach ($poolName in @('codex_openai', 'agy_anthropic', 'agy_google')) {
                $rawVal = Get-OrchestraProperty $cfg $poolName $null
                if ($null -ne $rawVal) {
                    $parsed = 0
                    if ([int]::TryParse([string]$rawVal, [ref]$parsed) -and $parsed -ge 1) {
                        $limits[$poolName] = $parsed
                    }
                }
            }
        }
    }
    return $limits
}

function Test-OrchestraPidAlive {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    $fakeRaw = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_FAKE_ALIVE_PIDS')
    if (-not [string]::IsNullOrWhiteSpace($fakeRaw)) {
        foreach ($part in ($fakeRaw -split ',')) {
            $trimmed = $part.Trim()
            $fakePid = 0
            if ([int]::TryParse($trimmed, [ref]$fakePid) -and $fakePid -eq $ProcessId) {
                return $true
            }
        }
    }
    return ($null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue))
}

function Set-OrchestraCodexRotationCooldown {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [int]$CooldownSec = 15,
        [string]$Reason = 'cockpit_rotation_or_429'
    )
    if ($CooldownSec -le 0) {
        Clear-OrchestraCodexRotationCooldown -Paths $Paths
        return
    }
    $slotsDir = [string](Get-OrchestraProperty $Paths 'Slots' '')
    if ([string]::IsNullOrWhiteSpace($slotsDir)) { return }
    $work = {
        [void][IO.Directory]::CreateDirectory($slotsDir)
        $cooldownPath = Join-Path $slotsDir '_codex_rotation_cooldown.meta'
        $until = (Get-OrchestraNow).AddSeconds($CooldownSec)
        Write-JsonAtomic -Path $cooldownPath -Object ([ordered]@{
            until_utc = $until.ToString('o')
            reason = $Reason
        })
    }
    if (Test-OrchestraLockHeld -Paths $Paths -Name slots) { & $work }
    else { Invoke-WithLock -Paths $Paths -Name slots -ScriptBlock $work }
}

function Clear-OrchestraCodexRotationCooldown {
    param([Parameter(Mandatory = $true)][hashtable]$Paths)
    $slotsDir = [string](Get-OrchestraProperty $Paths 'Slots' '')
    if ([string]::IsNullOrWhiteSpace($slotsDir)) { return }
    $cooldownPath = Join-Path $slotsDir '_codex_rotation_cooldown.meta'
    if (-not [IO.File]::Exists($cooldownPath)) { return }
    $work = {
        if ([IO.File]::Exists($cooldownPath)) {
            try { [IO.File]::Delete($cooldownPath) } catch {}
        }
    }
    if (Test-OrchestraLockHeld -Paths $Paths -Name slots) { & $work }
    else { Invoke-WithLock -Paths $Paths -Name slots -ScriptBlock $work }
}

function Test-OrchestraCodexRotationCooldown {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [switch]$ReadOnly
    )
    $slotsDir = [string](Get-OrchestraProperty $Paths 'Slots' '')
    if ([string]::IsNullOrWhiteSpace($slotsDir)) { return $false }
    $cooldownPath = Join-Path $slotsDir '_codex_rotation_cooldown.meta'
    if (-not [IO.File]::Exists($cooldownPath)) { return $false }
    if ($ReadOnly) {
        try {
            $doc = Read-JsonFile -Path $cooldownPath
            if ($null -eq $doc) { return $false }
            $untilText = [string](Get-OrchestraProperty $doc 'until_utc' '')
            if ([string]::IsNullOrWhiteSpace($untilText)) { return $false }
            $untilDt = ConvertTo-OrchestraUtc $untilText
            return ($untilDt -gt (Get-OrchestraNow))
        }
        catch {
            return $false
        }
    }
    $checkWork = {
        if (-not [IO.File]::Exists($cooldownPath)) { return $false }
        $expiredOrCorrupt = $false
        try {
            $doc = Read-JsonFile -Path $cooldownPath
            if ($null -eq $doc) {
                $expiredOrCorrupt = $true
            }
            else {
                $untilText = [string](Get-OrchestraProperty $doc 'until_utc' '')
                if ([string]::IsNullOrWhiteSpace($untilText)) {
                    $expiredOrCorrupt = $true
                }
                else {
                    $untilDt = ConvertTo-OrchestraUtc $untilText
                    if ($untilDt -le (Get-OrchestraNow)) {
                        $expiredOrCorrupt = $true
                    }
                    else {
                        return $true
                    }
                }
            }
        }
        catch {
            $expiredOrCorrupt = $true
        }
        if ($expiredOrCorrupt -and [IO.File]::Exists($cooldownPath)) {
            try { [IO.File]::Delete($cooldownPath) } catch {}
        }
        return $false
    }
    if (Test-OrchestraLockHeld -Paths $Paths -Name slots) {
        return [bool](& $checkWork)
    }
    else {
        return [bool](Invoke-WithLock -Paths $Paths -Name slots -ScriptBlock $checkWork)
    }
}

function Get-ActivePoolSlotStatus {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        $Policy = $null,
        [switch]$CleanupStale
    )
    $limits = Get-OrchestraPoolLimits -Policy $Policy
    $inspect = {
        $poolNames = @('codex_openai', 'agy_anthropic', 'agy_google')
        $counts = @{ codex_openai = 0; agy_anthropic = 0; agy_google = 0 }
        $modelsMap = @{
            codex_openai = (New-Object 'System.Collections.Generic.List[string]')
            agy_anthropic = (New-Object 'System.Collections.Generic.List[string]')
            agy_google = (New-Object 'System.Collections.Generic.List[string]')
        }
        $slotsMap = @{
            codex_openai = (New-Object 'System.Collections.Generic.List[int]')
            agy_anthropic = (New-Object 'System.Collections.Generic.List[int]')
            agy_google = (New-Object 'System.Collections.Generic.List[int]')
        }
        $activeInvocationIds = New-Object 'System.Collections.Generic.List[string]'
        $reclaimed = 0
        $staleDetected = 0
        $slotsDir = [string](Get-OrchestraProperty $Paths 'Slots' '')
        if (-not [string]::IsNullOrWhiteSpace($slotsDir) -and [IO.Directory]::Exists($slotsDir)) {
            $now = Get-OrchestraNow
            $cutoff = $now.AddSeconds(-7200)
            foreach ($filePath in [IO.Directory]::GetFiles($slotsDir, '*.json')) {
                $lease = $null
                $isStale = $false
                try {
                    $lease = Read-JsonFile -Path $filePath
                }
                catch {
                    $isStale = $true
                }
                if ($null -eq $lease) {
                    $isStale = $true
                }
                else {
                    $rawPid = Get-OrchestraProperty $lease 'pid' $null
                    $leasePid = 0
                    if ($null -eq $rawPid -or -not [int]::TryParse([string]$rawPid, [ref]$leasePid) -or $leasePid -le 0) {
                        $isStale = $true
                    }
                    elseif (-not (Test-OrchestraPidAlive -ProcessId $leasePid)) {
                        $isStale = $true
                    }
                    else {
                        $startedText = [string](Get-OrchestraProperty $lease 'started_utc' '')
                        if ([string]::IsNullOrWhiteSpace($startedText)) {
                            $isStale = $true
                        }
                        else {
                            try {
                                $startedDt = ConvertTo-OrchestraUtc $startedText
                                if ($startedDt -lt $cutoff) { $isStale = $true }
                            }
                            catch { $isStale = $true }
                        }
                    }
                }
                if ($isStale) {
                    $staleDetected++
                    if ($CleanupStale) {
                        try {
                            if ([IO.File]::Exists($filePath)) {
                                [IO.File]::Delete($filePath)
                                $reclaimed++
                            }
                        }
                        catch {}
                    }
                    continue
                }
                $leasePool = [string](Get-OrchestraProperty $lease 'pool' '')
                if ([string]::IsNullOrWhiteSpace($leasePool)) {
                    $leasePool = Get-OrchestraPoolName -Model $null -Channel ([string](Get-OrchestraProperty $lease 'channel' ''))
                }
                if ($counts.ContainsKey($leasePool)) {
                    $counts[$leasePool]++
                    $leaseInvId = [string](Get-OrchestraProperty $lease 'invocation_id' '')
                    if (-not [string]::IsNullOrWhiteSpace($leaseInvId)) {
                        [void]$activeInvocationIds.Add($leaseInvId)
                    }
                    $leaseModel = [string](Get-OrchestraProperty $lease 'model' '')
                    if (-not [string]::IsNullOrWhiteSpace($leaseModel)) {
                        [void]$modelsMap[$leasePool].Add($leaseModel)
                    }
                    $rawSlot = Get-OrchestraProperty $lease 'slot' $null
                    $slotNum = 0
                    if ($null -ne $rawSlot -and [int]::TryParse([string]$rawSlot, [ref]$slotNum) -and $slotNum -ge 1) {
                        [void]$slotsMap[$leasePool].Add($slotNum)
                    }
                }
            }
        }
        $codexCooldownActive = Test-OrchestraCodexRotationCooldown -Paths $Paths -ReadOnly:(-not $CleanupStale)
        $totalActive = 0
        $poolsOut = [ordered]@{}
        foreach ($p in $poolNames) {
            $act = [int]$counts[$p]
            $cfgLim = [int]$limits[$p]
            $isCooldown = ($p -eq 'codex_openai' -and $codexCooldownActive)
            $effLim = if ($isCooldown) { 1 } else { $cfgLim }
            $avail = [int][Math]::Max(0, $effLim - $act)
            $totalActive += $act
            $poolsOut[$p] = [ordered]@{
                active = $act
                limit = $effLim
                configured_limit = $cfgLim
                rotation_cooldown = [bool]$isCooldown
                available = $avail
                models = @($modelsMap[$p].ToArray())
                slots = @($slotsMap[$p].ToArray())
            }
        }
        return [ordered]@{
            total_active = [int]$totalActive
            underutilized = ($totalActive -lt 2)
            pools = $poolsOut
            active_invocation_ids = @($activeInvocationIds.ToArray())
            reclaimed_stale = [int]$reclaimed
            stale_detected = [int]$staleDetected
        }
    }
    if ($CleanupStale -and -not (Test-OrchestraLockHeld -Paths $Paths -Name slots)) {
        $slotsDirCheck = [string](Get-OrchestraProperty $Paths 'Slots' '')
        if (-not [string]::IsNullOrWhiteSpace($slotsDirCheck) -and [IO.Directory]::Exists($slotsDirCheck)) {
            return (Invoke-WithLock -Paths $Paths -Name slots -ScriptBlock $inspect)
        }
    }
    return (& $inspect)
}

function Acquire-OrchestraPoolSlot {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [Parameter(Mandatory = $true)][string]$Pool,
        [Parameter(Mandatory = $true)][int]$Limit,
        [Parameter(Mandatory = $true)][string]$InvocationId,
        [string]$ModelId = '',
        [string]$Channel = '',
        [int]$WaitSec = 300,
        [int]$StaggerMs = 200,
        [switch]$NoWait,
        [scriptblock]$OnQueued = $null
    )
    if ($Pool -notin @('codex_openai', 'agy_anthropic', 'agy_google')) {
        throw "ORCHESTRA_ARGS: Unknown pool: $Pool"
    }
    if ($Limit -lt 1) {
        throw 'ORCHESTRA_ARGS: Pool limit must be at least 1.'
    }
    $slotsDir = [string](Get-OrchestraProperty $Paths 'Slots' '')
    if ([string]::IsNullOrWhiteSpace($slotsDir)) {
        throw 'ORCHESTRA_ARGS: Missing Paths.Slots.'
    }
    $effectiveStaggerMs = if ($StaggerMs -gt 0) { $StaggerMs } else { 0 }
    $envTestStagger = [Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_TEST_STAGGER_MS')
    $hasTestStaggerEnv = $false
    if (-not [string]::IsNullOrWhiteSpace($envTestStagger)) {
        $parsedStagger = 0
        if ([int]::TryParse($envTestStagger.Trim(), [ref]$parsedStagger) -and $parsedStagger -ge 0) {
            $effectiveStaggerMs = $parsedStagger
            $hasTestStaggerEnv = $true
        }
    }
    $staggerAllowed = ($effectiveStaggerMs -gt 0) -and (
        $hasTestStaggerEnv -or
        [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_NOW'))
    )

    $slotWatch = [Diagnostics.Stopwatch]::StartNew()
    $notifiedQueued = $false
    $lastEffectiveLimit = $Limit
    try {
        while ($true) {
            $lockTimeout = if ($NoWait -or $WaitSec -le 0) { 1 } else { [Math]::Min(10, $WaitSec) }
            $attemptRes = Invoke-WithLock -Paths $Paths -Name slots -TimeoutSec $lockTimeout -ScriptBlock {
                [void][IO.Directory]::CreateDirectory($slotsDir)
                $status = Get-ActivePoolSlotStatus -Paths $Paths -CleanupStale
                $poolInfo = $status.pools[$Pool]
                $effectiveLimit = if ($Pool -eq 'codex_openai' -and [bool]$poolInfo.rotation_cooldown) {
                    1
                }
                else {
                    $Limit
                }
                if ([int]$poolInfo.active -lt $effectiveLimit) {
                    $takenSlots = @($poolInfo.slots)
                    $chosenSlot = 0
                    for ($i = 1; $i -le $effectiveLimit; $i++) {
                        $candPath = Join-Path $slotsDir ("$Pool-$i.json")
                        if (($takenSlots -notcontains $i) -and -not [IO.File]::Exists($candPath)) {
                            $chosenSlot = $i
                            break
                        }
                    }
                    if ($chosenSlot -ge 1) {
                        $leasePath = Join-Path $slotsDir ("$Pool-$chosenSlot.json")
                        $leaseObj = [ordered]@{
                            invocation_id = $InvocationId
                            pid = [int]$PID
                            pool = $Pool
                            slot = [int]$chosenSlot
                            model = $ModelId
                            channel = $Channel
                            started_utc = (Get-OrchestraNow).ToString('o')
                        }
                        Write-JsonAtomic -Path $leasePath -Object $leaseObj

                        $delayMs = 0
                        if ($staggerAllowed) {
                            $staggerPath = Join-Path $slotsDir ("_stagger_$Pool.meta")
                            $nowTicks = [DateTime]::UtcNow.Ticks
                            if ([int]$poolInfo.active -ge 1) {
                                $lastLaunchTicks = $nowTicks
                                if ([IO.File]::Exists($staggerPath)) {
                                    try {
                                        $staggerDoc = Read-JsonFile -Path $staggerPath
                                        $rawLast = Get-OrchestraProperty $staggerDoc 'last_launch_ticks' $null
                                        $parsedTicks = 0L
                                        if ($null -ne $rawLast -and [long]::TryParse([string]$rawLast, [ref]$parsedTicks) -and $parsedTicks -gt 0L) {
                                            $lastLaunchTicks = $parsedTicks
                                        }
                                    }
                                    catch {}
                                }
                                $staggerTicks = [long]$effectiveStaggerMs * 10000L
                                $reservedTicks = [Math]::Max($nowTicks, ($lastLaunchTicks + $staggerTicks))
                                $delayMs = [int][Math]::Max(0, [Math]::Ceiling(($reservedTicks - $nowTicks) / 10000.0))
                                Write-JsonAtomic -Path $staggerPath -Object ([ordered]@{
                                    last_launch_ticks = [long]$reservedTicks
                                })
                            }
                            else {
                                Write-JsonAtomic -Path $staggerPath -Object ([ordered]@{
                                    last_launch_ticks = [long]$nowTicks
                                })
                            }
                        }

                        return [ordered]@{
                            acquired = $true
                            effective_limit = [int]$effectiveLimit
                            lease_path = $leasePath
                            pool = $Pool
                            slot = [int]$chosenSlot
                            waited_sec = [Math]::Round($slotWatch.Elapsed.TotalSeconds, 3)
                            stagger_ms = [int]$delayMs
                        }
                    }
                }
                return [ordered]@{
                    acquired = $false
                    effective_limit = [int]$effectiveLimit
                }
            }
            $lastEffectiveLimit = [int]$attemptRes.effective_limit
            if ([bool]$attemptRes.acquired) {
                $delayToSleep = [int]$attemptRes.stagger_ms
                if ($delayToSleep -gt 0) {
                    Start-Sleep -Milliseconds $delayToSleep
                }
                return [ordered]@{
                    lease_path = $attemptRes.lease_path
                    pool = $attemptRes.pool
                    slot = [int]$attemptRes.slot
                    waited_sec = [double]$attemptRes.waited_sec
                    stagger_ms = $delayToSleep
                }
            }
            if ($NoWait -or $WaitSec -le 0 -or $slotWatch.Elapsed.TotalSeconds -ge $WaitSec) {
                throw "ORCHESTRA_LOCK_TIMEOUT: Pool $Pool is at capacity ($lastEffectiveLimit/$lastEffectiveLimit)."
            }
            if (-not $notifiedQueued) {
                $notifiedQueued = $true
                if ($null -ne $OnQueued) {
                    & $OnQueued
                }
            }
            Start-Sleep -Milliseconds 250
        }
    }
    finally {
        $slotWatch.Stop()
    }
}

function Release-OrchestraPoolSlot {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Paths,
        [string]$LeasePath,
        [string]$InvocationId
    )
    if ([string]::IsNullOrWhiteSpace($LeasePath) -or [string]::IsNullOrWhiteSpace($InvocationId)) { return }
    $releaseWork = {
        if (-not [IO.File]::Exists($LeasePath)) { return }
        try {
            $existing = Read-JsonFile -Path $LeasePath
            if ($null -eq $existing) { return }
            $ownerId = [string](Get-OrchestraProperty $existing 'invocation_id' '')
            if (-not [string]::IsNullOrWhiteSpace($ownerId) -and $ownerId -ceq $InvocationId) {
                [IO.File]::Delete($LeasePath)
            }
        }
        catch {
            # Leave unreadable/corrupt leases for Get-ActivePoolSlotStatus -CleanupStale rather than deleting blindly.
        }
    }
    if (Test-OrchestraLockHeld -Paths $Paths -Name slots) {
        & $releaseWork
    }
    else {
        Invoke-WithLock -Paths $Paths -Name slots -ScriptBlock $releaseWork
    }
}
