[CmdletBinding()]
param(
    [switch]$Force,
    [string]$AgyListFile,
    [string]$CodexCatalogFile,
    [switch]$NoNetwork,
    [int]$AgyTimeoutSec = 60,
    [string]$RegistryPath,
    [string]$StateDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Get-DValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $Default
}

function Set-DValue {
    param($Object, [string]$Name, $Value)
    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
        return
    }
    if ($null -ne $Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else {
        Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Convert-DDate {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    try {
        $parsed = [datetimeoffset]::Parse(
            [string]$Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal
        )
        return $parsed.UtcDateTime
    }
    catch { return $null }
}

function Initialize-DSource {
    param($State, [string]$Name)
    $sources = Get-DValue $State 'sources'
    if ($null -eq $sources) {
        $sources = [pscustomobject]@{}
        Set-DValue $State 'sources' $sources
    }
    $source = Get-DValue $sources $Name
    if ($null -eq $source) {
        $source = [pscustomobject]@{}
        Set-DValue $sources $Name $source
    }
    foreach ($entry in @(
        @{ Name = 'baseline_slugs'; Value = @() },
        @{ Name = 'raw_slugs'; Value = @() },
        @{ Name = 'last_success'; Value = $null },
        @{ Name = 'last_attempt'; Value = $null },
        @{ Name = 'consecutive_failures'; Value = 0 },
        @{ Name = 'missing_counts'; Value = [pscustomobject]@{} }
    )) {
        if ($null -eq (Get-DValue $source $entry.Name)) {
            Set-DValue $source $entry.Name $entry.Value
        }
    }
    return $source
}

function Get-DAgySlugs {
    param([string]$Text)
    $found = @(
        foreach ($line in ($Text -split '\r?\n')) {
            if ($line -match '^\s*(?<slug>[A-Za-z0-9][A-Za-z0-9._-]*)\t[^\r\n]+$') {
                $Matches['slug'].ToLowerInvariant()
            }
        }
    ) | Sort-Object -Unique
    if (@($found).Count -eq 0) {
        throw 'No valid tab-separated model rows in agy output.'
    }
    return $found
}

function Get-DCodexSlugs {
    param([string]$Text)
    $matches = [regex]::Matches(
        $Text, '"slug"\s*:\s*"(?<slug>[A-Za-z0-9][A-Za-z0-9._-]*)"'
    )
    $found = @(
        foreach ($match in $matches) {
            $match.Groups['slug'].Value.ToLowerInvariant()
        }
    ) | Sort-Object -Unique
    if (@($found).Count -eq 0) { throw 'No valid slug fields in the Codex catalog.' }
    return $found
}

function Get-DSourceData {
    param(
        [string]$Name, [string]$AgyFile, [string]$CodexFile,
        [bool]$Offline, [int]$TimeoutSec
    )
    if ($Name -eq 'agy') {
        if (-not [string]::IsNullOrWhiteSpace($AgyFile)) {
            $content = Get-Content -LiteralPath $AgyFile -Raw -Encoding UTF8
        }
        elseif ($Offline) {
            return [pscustomobject]@{
                Attempted = $false; Ids = @(); RawSlugs = @()
            }
        }
        else {
            $wrapper = Resolve-AgyWrapper
            $processResult = Invoke-OrchestraProcess -FilePath 'powershell.exe' `
                -Arguments @(
                    '-NoProfile', '-NonInteractive', '-ExecutionPolicy',
                    'Bypass', '-File', $wrapper, 'models'
                ) -WorkDir (Resolve-Root) -TimeoutSec $TimeoutSec -CaptureStdout
            if ($processResult.timeout) {
                throw "agy models timed out after $TimeoutSec seconds."
            }
            if ($processResult.truncated) {
                throw 'agy models output was truncated before EOF.'
            }
            $content = $processResult.stdout -join "`n"
            if ($processResult.exit_code -ne 0) {
                $diagnostic = $content + "`n" + ($processResult.stderr -join "`n")
                if ($diagnostic -match '(?i)not logged into Antigravity') {
                    throw 'agy authentication failed. Run the wrapper from the authorized main-user elevated host.'
                }
                throw "agy models failed with exit code $($processResult.exit_code)."
            }
        }
        $rawSlugs = @(Get-DAgySlugs -Text $content)
        return [pscustomobject]@{
            Attempted = $true
            Ids = @(
                $rawSlugs | ForEach-Object { ConvertTo-BaseSlug -Slug $_ } |
                    Sort-Object -Unique
            )
            RawSlugs = @($rawSlugs)
        }
    }
    if ([string]::IsNullOrWhiteSpace($CodexFile)) {
        $CodexFile = Join-Path $HOME '.codex\cockpit-model-catalog.json'
        if (-not [IO.File]::Exists($CodexFile)) {
            foreach ($altCatalog in @(
                (Join-Path $HOME '.codex\models_cache.json'),
                (Join-Path $HOME '.codex\cockpit-model-catalog.json.bak')
            )) {
                if ([IO.File]::Exists($altCatalog)) {
                    $CodexFile = $altCatalog
                    break
                }
            }
        }
    }
    $content = Get-Content -LiteralPath $CodexFile -Raw -Encoding UTF8
    $rawSlugs = @(Get-DCodexSlugs -Text $content)
    return [pscustomobject]@{
        Attempted = $true; Ids = @($rawSlugs); RawSlugs = @($rawSlugs)
    }
}

$paths = $null
$leaseToken = $null
$owner = '{0}-{1}' -f [Environment]::MachineName, $PID
$exitCode = 0
$finalResult = $null

try {
    if ($AgyTimeoutSec -lt 1) {
        throw 'ORCHESTRA_ARGS: AgyTimeoutSec must be positive.'
    }
    $paths = Get-OrchestraPaths -RegistryPath $RegistryPath -StateDir $StateDir
    $now = (Get-OrchestraNow).ToUniversalTime()
    $nowText = $now.ToString('o')
    $lease = Invoke-WithLock -Paths $paths -Name registry -ScriptBlock {
        $registry = Read-Registry -Paths $paths
        Invoke-WithLock -Paths $paths -Name state -ScriptBlock {
            $state = Read-State -Paths $paths
            $currentLease = Get-DValue $state 'scan_lease'
            $leaseUntil = Convert-DDate (Get-DValue $currentLease 'until')
            if ($null -ne $leaseUntil -and $leaseUntil -gt $now) {
                return [pscustomobject]@{
                    Skipped = $true; Due = @(); Token = $null
                    Reason = 'An unexpired scan lease is held.'
                }
            }
            $policy = Get-DValue $registry 'policy'
            $scanHours = [double](Get-DValue $policy 'scan_interval_hours' 24)
            $backoffHours = [double](Get-DValue $policy 'scan_failure_backoff_hours' 1)
            $due = @(
                foreach ($name in @('agy', 'codex')) {
                    $source = Initialize-DSource $state $name
                    $failures = [int](Get-DValue $source 'consecutive_failures' 0)
                    $lastSuccess = Convert-DDate (Get-DValue $source 'last_success')
                    $lastAttempt = Convert-DDate (Get-DValue $source 'last_attempt')
                    $shouldScan = [bool]$Force
                    if (-not $shouldScan) {
                        if ($failures -gt 0 -and $null -ne $lastAttempt) {
                            $shouldScan = $now -ge $lastAttempt.AddHours($backoffHours)
                        }
                        elseif ($null -eq $lastSuccess) { $shouldScan = $true }
                        else { $shouldScan = $now -ge $lastSuccess.AddHours($scanHours) }
                    }
                    if ($shouldScan) { $name }
                }
            )
            if ($due.Count -eq 0) {
                return [pscustomobject]@{
                    Skipped = $true; Due = @(); Token = $null
                    Reason = 'All sources are within their scan or retry interval.'
                }
            }
            $token = $now.AddMinutes(10).ToString('o')
            Set-DValue $state 'scan_lease' ([pscustomobject]@{
                owner = $owner; until = $token
            })
            Save-State -Paths $paths -State $state | Out-Null
            [pscustomobject]@{
                Skipped = $false; Due = @($due); Token = $token; Reason = $null
            }
        }
    }

    if ($lease.Skipped) {
        $finalResult = [ordered]@{
            skipped = $true
            new = @(); removed = @(); restored = @(); stale = @()
            source_errors = @()
            baseline_initialized = $false
            baseline_added = [ordered]@{ agy = @(); codex = @() }
            reason = $lease.Reason
        }
    }
    else {
        $leaseToken = $lease.Token
        $sourceResults = @{}
        foreach ($name in @($lease.Due)) {
            try {
                $data = Get-DSourceData -Name $name -AgyFile $AgyListFile `
                    -CodexFile $CodexCatalogFile -Offline ([bool]$NoNetwork) `
                    -TimeoutSec $AgyTimeoutSec
                $sourceResults[$name] = [pscustomobject]@{
                    Attempted = $data.Attempted; Success = $true
                    Ids = @($data.Ids); RawSlugs = @($data.RawSlugs); Error = $null
                }
            }
            catch {
                $sourceResults[$name] = [pscustomobject]@{
                    Attempted = $true; Success = $false
                    Ids = @(); RawSlugs = @(); Error = $_.Exception.Message
                }
            }
        }

        $finalResult = Invoke-WithLock -Paths $paths -Name registry -ScriptBlock {
            $registry = Read-Registry -Paths $paths
            Invoke-WithLock -Paths $paths -Name state -ScriptBlock {
                $state = Read-State -Paths $paths
                $currentLease = Get-DValue $state 'scan_lease'
                if ((Get-DValue $currentLease 'owner') -ne $owner -or
                    (Get-DValue $currentLease 'until') -ne $leaseToken) {
                    throw 'The scan lease was replaced before commit.'
                }
                $newIds = New-Object 'System.Collections.Generic.List[string]'
                $removed = New-Object 'System.Collections.Generic.List[string]'
                $restored = New-Object 'System.Collections.Generic.List[string]'
                $stale = New-Object 'System.Collections.Generic.List[string]'
                $errors = New-Object 'System.Collections.Generic.List[object]'
                $changes = New-Object 'System.Collections.Generic.List[string]'
                $initialized = $false
                $baselineAdded = [ordered]@{ agy = @(); codex = @() }
                $changed = $false
                $attempted = 0
                $policy = Get-DValue $registry 'policy'
                $missingThreshold = [int](
                    Get-DValue $policy 'missing_scans_before_unavailable' 2
                )
                if ($missingThreshold -lt 2) { $missingThreshold = 2 }
                $registeredIds = @($registry.models | ForEach-Object { [string]$_.id })
                $rejected = @(Get-DValue $state 'rejected_slugs' @())

                foreach ($name in @($lease.Due)) {
                    $data = $sourceResults[$name]
                    if (-not $data.Attempted) { continue }
                    $attempted++
                    $source = Initialize-DSource $state $name
                    Set-DValue $source 'last_attempt' $nowText
                    if (-not $data.Success) {
                        $failures = [int](Get-DValue $source 'consecutive_failures' 0)
                        Set-DValue $source 'consecutive_failures' ($failures + 1)
                        $errors.Add([pscustomobject]@{
                            source = $name; error = $data.Error
                        })
                        continue
                    }
                    $ids = @($data.Ids | Sort-Object -Unique)
                    Set-DValue $source 'raw_slugs' @(
                        $data.RawSlugs | Sort-Object -Unique
                    )
                    $firstSuccess = $null -eq (
                        Convert-DDate (Get-DValue $source 'last_success')
                    )
                    if ($firstSuccess) {
                        $newBaseline = @(
                            $ids | Where-Object { $registeredIds -notcontains $_ }
                        )
                        Set-DValue $source 'baseline_slugs' $newBaseline
                        Set-DValue $source 'baseline_initialized' $true
                        $baselineAdded[$name] = $newBaseline
                        $initialized = $true
                    }
                    else {
                        $baseline = @(Get-DValue $source 'baseline_slugs' @())
                        foreach ($id in $ids) {
                            if ($registeredIds -notcontains $id -and
                                $baseline -notcontains $id -and
                                $rejected -notcontains $id -and
                                -not $newIds.Contains($id)) {
                                $newIds.Add($id)
                            }
                        }
                    }
                    Set-DValue $source 'last_success' $nowText
                    Set-DValue $source 'consecutive_failures' 0
                    $missingCounts = Get-DValue $source 'missing_counts'
                    foreach ($model in @($registry.models)) {
                        if ($model.channel -ne $name) { continue }
                        $id = [string]$model.id
                        $status = [string]$model.status
                        if ($ids -contains $id) {
                            Set-DValue $missingCounts $id 0
                            if ($status -eq 'unavailable') {
                                $previous = [string](Get-DValue $model 'previous_status')
                                if ($previous -notin @('active', 'candidate')) {
                                    $previous = 'candidate'
                                }
                                Set-DValue $model 'status' $previous
                                Set-DValue $model 'previous_status' $null
                                $restored.Add($id)
                                $changes.Add("$id restored to $previous.")
                                $changed = $true
                            }
                            continue
                        }
                        if ($status -notin @('active', 'candidate')) { continue }
                        $count = [int](Get-DValue $missingCounts $id 0) + 1
                        Set-DValue $missingCounts $id $count
                        if ($count -ge $missingThreshold) {
                            Set-DValue $model 'previous_status' $status
                            Set-DValue $model 'status' 'unavailable'
                            $removed.Add($id)
                            $changes.Add(
                                "$id unavailable after $count successful missing scans."
                            )
                            $changed = $true
                        }
                    }
                }

                $refreshDays = [double](Get-DValue $policy 'refresh_days' 30)
                foreach ($model in @($registry.models)) {
                    if ($model.status -notin @('active', 'candidate')) { continue }
                    $researched = Convert-DDate (Get-DValue $model 'last_researched')
                    if ($null -eq $researched -or
                        $now -gt $researched.AddDays($refreshDays)) {
                        $stale.Add([string]$model.id)
                    }
                }
                if ($changed) {
                    Save-Registry -Paths $paths -Registry $registry `
                        -Reason 'Catalog availability update' | Out-Null
                    Add-ChangelogEntry -Paths $paths `
                        -Title 'Catalog availability update' `
                        -Lines @($changes.ToArray()) | Out-Null
                }
                if ($attempted -gt 0) { Set-DValue $state 'last_scan' $nowText }
                Set-DValue $state 'scan_lease' $null
                Save-State -Paths $paths -State $state | Out-Null
                [ordered]@{
                    skipped = ($attempted -eq 0)
                    new = @($newIds.ToArray() | Sort-Object -Unique)
                    removed = @($removed.ToArray() | Sort-Object -Unique)
                    restored = @($restored.ToArray() | Sort-Object -Unique)
                    stale = @($stale.ToArray() | Sort-Object -Unique)
                    source_errors = @($errors.ToArray())
                    baseline_initialized = $initialized
                    baseline_added = $baselineAdded
                }
            }
        }
        if (@($finalResult.source_errors).Count -gt 0) { $exitCode = 3 }
    }
}
catch {
    $message = $_.Exception.Message
    $exitCode = 3
    if ($message -match 'ORCHESTRA_ARGS:') { $exitCode = 2 }
    if ($message -match 'ORCHESTRA_LOCK_TIMEOUT') { $exitCode = 5 }
    [Console]::Error.WriteLine($message)
    $finalResult = @{
        skipped = $false
        new = @(); removed = @(); restored = @(); stale = @()
        source_errors = @(@{ source = 'detector'; error = $message })
        baseline_initialized = $false
        baseline_added = [ordered]@{ agy = @(); codex = @() }
        exit = $exitCode
    }
}
finally {
    if ($null -ne $paths -and $null -ne $leaseToken) {
        try {
            Invoke-WithLock -Paths $paths -Name state -ScriptBlock {
                $state = Read-State -Paths $paths
                $currentLease = Get-DValue $state 'scan_lease'
                if ((Get-DValue $currentLease 'owner') -eq $owner -and
                    (Get-DValue $currentLease 'until') -eq $leaseToken) {
                    Set-DValue $state 'scan_lease' $null
                    Save-State -Paths $paths -State $state | Out-Null
                }
            } | Out-Null
        }
        catch {
            [Console]::Error.WriteLine($_.Exception.Message)
            if ($exitCode -eq 0) {
                if ($_.Exception.Message -match 'ORCHESTRA_LOCK_TIMEOUT') {
                    $exitCode = 5
                }
                else { $exitCode = 3 }
                $finalResult = @{
                    skipped = $false
                    new = @(); removed = @(); restored = @(); stale = @()
                    source_errors = @(@{
                        source = 'detector'; error = $_.Exception.Message
                    })
                    baseline_initialized = $false
                    baseline_added = [ordered]@{ agy = @(); codex = @() }
                    exit = $exitCode
                }
            }
        }
    }
}
Write-OrchestraResult -Object $finalResult
exit $exitCode
