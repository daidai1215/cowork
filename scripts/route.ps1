<#
.SYNOPSIS
Select a primary model, reviewer, polisher, and fallbacks.
.DESCRIPTION
Candidates may be primary or fallback, but cannot review or polish.
Reviewers use review_caps. Within 1.5 points, prefer another vendor.
Explicit aesthetic reviewer rules retain their configured precedence.
Writes one JSON object without changing registry or state.
#>
[CmdletBinding()]
param(
    [string[]]$Tags = @(),
    [string]$Mode = '',
    [string]$HostModel = '',
    [switch]$Fast4H,
    [string[]]$Exclude = @(),
    [switch]$AllowEscalation,
    [string[]]$BusyAgents = @(),
    [switch]$PreferIdle,
    [string]$RegistryPath,
    [string]$StateDir,
    $RegistryObject = $null,
    [switch]$SkipTelemetry
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Get-RValue {
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

function Expand-RList {
    param([string[]]$Items)
    @(
        foreach ($item in $Items) {
            foreach ($part in ($item -split ',')) {
                $value = $part.Trim()
                if ($value.Length -gt 0) { $value }
            }
        }
    )
}

function Expand-RNames {
    param([string[]]$Names)
    @(Expand-RList -Items $Names) | Sort-Object -Unique
}

function Resolve-RPoolName {
    param($Model, [string]$Channel = '')
    if (Get-Command Get-OrchestraPoolName -ErrorAction SilentlyContinue) {
        return [string](Get-OrchestraPoolName -Model $Model -Channel $Channel)
    }
    $ch = if (-not [string]::IsNullOrWhiteSpace($Channel)) {
        $Channel.Trim().ToLowerInvariant()
    }
    else {
        ([string](Get-RValue $Model 'channel' '')).Trim().ToLowerInvariant()
    }
    $vendor = ([string](Get-RValue $Model 'vendor' '')).Trim().ToLowerInvariant()
    $id = ([string](Get-RValue $Model 'id' '')).Trim().ToLowerInvariant()
    if ($ch -eq 'codex') { return 'codex_openai' }
    if ($vendor -eq 'anthropic' -or $id -match '^claude-') { return 'agy_anthropic' }
    return 'agy_google'
}

function Get-RPoolLoad {
    param(
        [hashtable]$Paths,
        $Policy,
        $Registry,
        [string[]]$BusyAgents = @()
    )
    $defaultLimits = [ordered]@{ codex_openai = 4; agy_anthropic = 3; agy_google = 7 }
    $limitsObj = Get-RValue $Policy 'pool_concurrency_limits' $null
    $limits = [ordered]@{}
    foreach ($pKey in @('codex_openai', 'agy_anthropic', 'agy_google')) {
        $rawLim = Get-RValue $limitsObj $pKey $null
        $limits[$pKey] = if ($null -ne $rawLim -and [int]$rawLim -gt 0) { [int]$rawLim } else { [int]$defaultLimits[$pKey] }
    }

    $pools = [ordered]@{}
    $totalActive = 0
    $activeLeaseIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if (Get-Command Get-ActivePoolSlotStatus -ErrorAction SilentlyContinue) {
        $rawStatus = Get-ActivePoolSlotStatus -Paths $Paths -Policy $Policy
        $rawPools = Get-RValue $rawStatus 'pools' $null
        foreach ($pKey in @('codex_openai', 'agy_anthropic', 'agy_google')) {
            $rp = Get-RValue $rawPools $pKey $null
            $lim = if ($null -ne $rp) { [int](Get-RValue $rp 'limit' $limits[$pKey]) } else { [int]$limits[$pKey] }
            $cfgLim = if ($null -ne $rp) { [int](Get-RValue $rp 'configured_limit' $limits[$pKey]) } else { [int]$limits[$pKey] }
            $rotCd = if ($null -ne $rp) { [bool](Get-RValue $rp 'rotation_cooldown' $false) } else { $false }
            $act = if ($null -ne $rp) { [int](Get-RValue $rp 'active' 0) } else { 0 }
            $avail = if ($null -ne $rp) { [int](Get-RValue $rp 'available' ([Math]::Max(0, $lim - $act))) } else { [Math]::Max(0, $lim - $act) }
            $mods = New-Object 'System.Collections.Generic.List[string]'
            if ($null -ne $rp) {
                foreach ($m in @(Get-RValue $rp 'models' @())) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$m)) { [void]$mods.Add([string]$m) }
                }
            }
            $pools[$pKey] = [ordered]@{
                active = $act
                limit = $lim
                configured_limit = $cfgLim
                available = $avail
                rotation_cooldown = $rotCd
                models = $mods
            }
            $totalActive += $act
        }
        $rawActiveInvIds = Get-RValue $rawStatus 'active_invocation_ids' $null
        $rawActiveLeases = Get-RValue $rawStatus 'active_leases' $null
        if ($null -ne $rawActiveInvIds) {
            foreach ($invItem in @($rawActiveInvIds)) {
                $leaseInvId = ([string]$invItem).Trim()
                if (-not [string]::IsNullOrWhiteSpace($leaseInvId)) {
                    [void]$activeLeaseIds.Add($leaseInvId)
                }
            }
        }
        elseif ($null -ne $rawActiveLeases) {
            foreach ($leaseItem in @($rawActiveLeases)) {
                if ($null -eq $leaseItem) { continue }
                $leaseInvId = if ($leaseItem -is [string]) {
                    [string]$leaseItem
                }
                else {
                    [string](Get-RValue $leaseItem 'invocation_id' '')
                }
                $leaseInvId = $leaseInvId.Trim()
                if (-not [string]::IsNullOrWhiteSpace($leaseInvId)) {
                    [void]$activeLeaseIds.Add($leaseInvId)
                }
            }
        }
        elseif ($totalActive -gt 0) {
            $slotsDir = [string](Get-RValue $Paths 'Slots' '')
            if (-not [string]::IsNullOrWhiteSpace($slotsDir) -and [IO.Directory]::Exists($slotsDir)) {
                foreach ($leaseFile in [IO.Directory]::GetFiles($slotsDir, '*.json')) {
                    try {
                        $leaseDoc = Read-JsonFile -Path $leaseFile
                        $rawPid = Get-RValue $leaseDoc 'pid' $null
                        $leasePid = 0
                        if (
                            $null -ne $leaseDoc -and
                            $null -ne $rawPid -and
                            [int]::TryParse([string]$rawPid, [ref]$leasePid) -and
                            $leasePid -gt 0 -and
                            (-not (Get-Command Test-OrchestraPidAlive -ErrorAction SilentlyContinue) -or (Test-OrchestraPidAlive -ProcessId $leasePid))
                        ) {
                            $leaseInvId = ([string](Get-RValue $leaseDoc 'invocation_id' '')).Trim()
                            if (-not [string]::IsNullOrWhiteSpace($leaseInvId)) {
                                [void]$activeLeaseIds.Add($leaseInvId)
                            }
                        }
                    }
                    catch {}
                }
            }
        }
    }
    else {
        foreach ($pKey in @('codex_openai', 'agy_anthropic', 'agy_google')) {
            $lim = [int]$limits[$pKey]
            $pools[$pKey] = [ordered]@{
                active = 0
                limit = $lim
                configured_limit = $lim
                available = $lim
                rotation_cooldown = $false
                models = (New-Object 'System.Collections.Generic.List[string]')
            }
        }
    }

    foreach ($busy in @(Expand-RList -Items $BusyAgents)) {
        $leaseToken = if ($busy -match '^inv:(.+)$') { $Matches[1].Trim() } else { $busy.Trim() }
        if (-not [string]::IsNullOrWhiteSpace($leaseToken) -and $activeLeaseIds.Contains($leaseToken)) {
            continue
        }
        $lowerBusy = $busy.ToLowerInvariant()
        $targetPool = $null
        $modelLabel = $null
        if ($pools.Contains($lowerBusy)) {
            $targetPool = $lowerBusy
        }
        else {
            $resolvedBusyId = Resolve-RModel $Registry $busy
            if (-not [string]::IsNullOrWhiteSpace($resolvedBusyId)) {
                $busyModel = @(Get-RValue $Registry 'models' @() | Where-Object { [string]$_.id -eq $resolvedBusyId }) | Select-Object -First 1
                if ($null -ne $busyModel) {
                    $targetPool = Resolve-RPoolName -Model $busyModel
                    $modelLabel = $resolvedBusyId
                }
            }
            elseif ($lowerBusy -match '^(gpt-|o\d|codex)') {
                $targetPool = 'codex_openai'
                $modelLabel = $busy
            }
            elseif ($lowerBusy -match '^claude-') {
                $targetPool = 'agy_anthropic'
                $modelLabel = $busy
            }
            elseif ($lowerBusy -match '^gemini-') {
                $targetPool = 'agy_google'
                $modelLabel = $busy
            }
            else {
                throw "ORCHESTRA_ARGS: Unknown busy agent or pool: $busy"
            }
        }
        if ($null -ne $targetPool -and $pools.Contains($targetPool)) {
            $entry = $pools[$targetPool]
            $entry.active = [int]$entry.active + 1
            $entry.available = [Math]::Max(0, [int]$entry.limit - [int]$entry.active)
            if (-not [string]::IsNullOrWhiteSpace($modelLabel)) {
                [void]$entry.models.Add($modelLabel)
            }
            $totalActive++
        }
    }

    $finalPools = [ordered]@{}
    foreach ($pKey in @('codex_openai', 'agy_anthropic', 'agy_google')) {
        $ep = $pools[$pKey]
        $finalPools[$pKey] = [ordered]@{
            active = [int]$ep.active
            limit = [int]$ep.limit
            configured_limit = [int]$ep.configured_limit
            available = [int]$ep.available
            rotation_cooldown = [bool]$ep.rotation_cooldown
            models = @($ep.models.ToArray())
        }
    }
    return [ordered]@{
        total_active = [int]$totalActive
        underutilized = ($totalActive -lt 2)
        pools = $finalPools
    }
}

function Test-RPoolAvailable {
    param($PoolLoad, $Model)
    if ($null -eq $PoolLoad -or $null -eq $Model) { return $true }
    $pName = Resolve-RPoolName -Model $Model
    $pEntry = Get-RValue $PoolLoad.pools $pName $null
    if ($null -eq $pEntry) { return $true }
    return ([int]$pEntry.available -gt 0)
}

function Get-RCap {
    param($Model, [string[]]$Dimensions)
    if (@($Dimensions).Count -eq 0) { return 0.0 }
    $caps = Get-RValue $Model 'caps'
    $sum = 0.0
    foreach ($dimension in $Dimensions) {
        $cap = Get-RValue $caps $dimension
        $sum += [double](Get-RValue $cap 'score' 0)
    }
    return $sum / @($Dimensions).Count
}

function Resolve-RModel {
    param($Registry, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    $resolved = Resolve-ModelId -Registry $Registry -Name $Name
    if ($null -eq $resolved) { return $null }
    if ($resolved -is [string]) { return $resolved }
    return [string](Get-RValue $resolved 'id')
}

function Select-RReviewer {
    param(
        [object[]]$Candidates,
        $Primary,
        [string[]]$Dimensions,
        [string[]]$PreferredIds = @(),
        [string[]]$HardPreferredIds = @(),
        [System.Collections.Generic.List[string]]$Reasons
    )

    # Review capability is independent of the primary routing score.
    # Ties prefer another vendor, then quota, speed, and a stable ID.
    $ranked = @(
        foreach ($reviewRecord in $Candidates) {
            if ($reviewRecord.Model.status -ne 'active') { continue }
            if ($reviewRecord.Id -eq $Primary.id) { continue }
            [pscustomobject]@{
                Model = $reviewRecord.Model
                Cap = Get-RCap $reviewRecord.Model $Dimensions
                OtherVendor = [int](
                    $reviewRecord.Model.vendor -ne $Primary.vendor
                )
                QuotaRank = [int]$reviewRecord.Model.quota_rank
                SpeedRank = [int]$reviewRecord.Model.speed_rank
                Id = $reviewRecord.Id
            }
        }
    )
    $ranked = @(
        $ranked | Sort-Object `
            @{ Expression = { $_.Cap }; Descending = $true },
            @{ Expression = { $_.OtherVendor }; Descending = $true },
            @{ Expression = { $_.QuotaRank }; Descending = $true },
            @{ Expression = { $_.SpeedRank }; Descending = $true },
            @{ Expression = { $_.Id }; Descending = $false }
    )
    if ($ranked.Count -eq 0) { return $null }

    $selected = $ranked[0]

    # Explicit reviewer/fallback rules take precedence over generic ranking.
    foreach ($preferredId in $PreferredIds) {
        $preferredMatches = @(
            $ranked | Where-Object { $_.Id -eq $preferredId }
        )
        if ($preferredMatches.Count -gt 0) {
            $selected = $preferredMatches[0]
            break
        }
    }

    $skipDiversityOverride = (
        $HardPreferredIds.Count -gt 0 -and
        ($HardPreferredIds -contains [string]$selected.Model.id) -and
        ([string]$selected.Model.id -ne [string]$Primary.id)
    )

    if (-not $skipDiversityOverride -and $selected.OtherVendor -eq 0) {
        $alternatives = @(
            $ranked | Where-Object {
                $_.OtherVendor -eq 1 -and
                ($selected.Cap - $_.Cap) -le 1.5
            }
        )
        if ($alternatives.Count -gt 0) {
            $alternative = $alternatives[0]
            if ($null -ne $Reasons) {
                [void]$Reasons.Add(
                    "Reviewer vendor diversity: selected $($alternative.Id) " +
                    "(review cap $($alternative.Cap)) over $($selected.Id) " +
                    "(review cap $($selected.Cap)); gap is within 1.5."
                )
            }
            $selected = $alternative
        }
    }
    return $selected.Model
}

function Select-RPolisher {
    param(
        [object[]]$Candidates,
        $Primary
    )
    $ranked = @(
        foreach ($polishRecord in $Candidates) {
            if ($polishRecord.Model.status -ne 'active') { continue }
            if ($polishRecord.Id -eq $Primary.id) { continue }
            [pscustomobject]@{
                Model = $polishRecord.Model
                Cap = Get-RCap $polishRecord.Model @('prose')
                QuotaRank = [int]$polishRecord.Model.quota_rank
                SpeedRank = [int]$polishRecord.Model.speed_rank
                Id = $polishRecord.Id
            }
        }
    )
    $ranked = @(
        $ranked | Sort-Object `
            @{ Expression = { $_.Cap }; Descending = $true },
            @{ Expression = { $_.QuotaRank }; Descending = $true },
            @{ Expression = { $_.SpeedRank }; Descending = $true },
            @{ Expression = { $_.Id }; Descending = $false }
    )
    if ($ranked.Count -gt 0) { return $ranked[0].Model }
    return $null
}

function Get-RHardRuleRejections {
    param($Model, [object[]]$Rules)
    $rejections = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rule in $Rules) {
        $channels = @(
            Get-RValue $rule 'primary_channel_only' @() |
                ForEach-Object { if ($null -ne $_) { ([string]$_).Trim() } } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        if ($channels.Count -gt 0 -and $channels -notcontains $Model.channel) {
            [void]$rejections.Add("primary channel must be $($channels -join ',')")
        }
        $requiredTools = @(
            Get-RValue $rule 'primary_requires_tool' @() |
                ForEach-Object { if ($null -ne $_) { ([string]$_).Trim() } } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        foreach ($tool in $requiredTools) {
            if (@(Get-RValue $Model 'tools' @()) -notcontains $tool) {
                [void]$rejections.Add("primary requires tool $tool")
            }
        }
    }
    return @($rejections.ToArray())
}

function Resolve-REffort {
    param(
        $Model,
        [string]$ModeName,
        [string[]]$TagList,
        [bool]$Escalated,
        $Policy,
        [bool]$AllowBoost,
        [string]$FastWorkhorseId = ''
    )
    if ($null -eq $Model) { return $null }
    $invokeObj = Get-RValue $Model 'invoke'
    $fallbackEffort = [string](Get-RValue $Policy 'default_effort' 'high')
    $baseEffort = [string](Get-RValue $invokeObj 'default_effort' $fallbackEffort)
    $supported = @(
        Get-RValue $invokeObj 'efforts' @() | ForEach-Object { [string]$_ }
    )
    $modelId = [string](Get-RValue $Model 'id' '')
    $modelTier = [string](Get-RValue $Model 'tier' '')
    $isFastWorkhorse = (
        (-not [string]::IsNullOrWhiteSpace($FastWorkhorseId) -and $modelId -eq $FastWorkhorseId) -or
        ($modelId -eq 'gemini-4-hydrogen') -or
        ($modelTier -eq 'fast' -and $baseEffort -eq 'xhigh')
    )
    $mechanicalTags = @(
        Get-RValue $Policy 'mechanical_fast_tags' @() | ForEach-Object { [string]$_ }
    )
    $hitsMechanicalTag = (
        @($TagList | Where-Object { $mechanicalTags -contains $_ }).Count -gt 0
    )
    $ultraFastTags = @(
        Get-RValue $Policy 'ultra_fast_tags' @() |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $hitsUltraFastOnly = (
        $ultraFastTags.Count -gt 0 -and
        @($TagList).Count -gt 0 -and
        @($TagList | Where-Object { $ultraFastTags -notcontains $_ }).Count -eq 0
    )
    $peakTags = @(
        Get-RValue $Policy 'peak_effort_tags' @() | ForEach-Object { [string]$_ }
    )
    $hitsPeakTag = (
        @($TagList | Where-Object { $peakTags -contains $_ }).Count -gt 0
    )
    if (
        $isFastWorkhorse -and
        -not $Escalated -and
        $hitsUltraFastOnly -and
        -not $hitsPeakTag -and
        ($supported -contains 'medium')
    ) {
        return 'medium'
    }
    if (
        $isFastWorkhorse -and
        -not $Escalated -and
        $hitsMechanicalTag -and
        -not $hitsPeakTag -and
        ($supported -contains 'high')
    ) {
        return 'high'
    }

    if (-not $AllowBoost) { return $baseEffort }

    $peakEffort = [string](Get-RValue $invokeObj 'peak_effort' '')
    if ([string]::IsNullOrWhiteSpace($peakEffort)) { return $baseEffort }
    if ($supported -notcontains $peakEffort) { return $baseEffort }

    if ($Escalated -or ($ModeName -in @('peak', 'fast_4h', 'orchestrator_fast', 'carbon_peak', 'hydrogen_max') -and $hitsPeakTag)) {
        return $peakEffort
    }
    return $baseEffort
}

try {
    $paths = Get-OrchestraPaths `
        -RegistryPath $RegistryPath -StateDir $StateDir

    $registry = if ($null -ne $RegistryObject) {
        $RegistryObject
    }
    else {
        Read-Registry -Paths $paths
    }
    $state = Read-State -Paths $paths

    $tagNames = @(Expand-RNames $Tags)
    if ($tagNames.Count -eq 0) {
        throw 'ORCHESTRA_ARGS: At least one tag is required.'
    }

    $tagTable = Get-RValue $registry 'tags'
    foreach ($tag in $tagNames) {
        if ($null -eq (Get-RValue $tagTable $tag)) {
            throw "ORCHESTRA_ARGS: Unknown tag: $tag"
        }
    }

    $policy = Get-RValue $registry 'policy'
    $poolLoad = Get-RPoolLoad -Paths $paths -Policy $policy -Registry $registry -BusyAgents $BusyAgents
    $modesTable = Get-RValue $registry 'modes'
    $hostModeMap = Get-RValue $policy 'host_mode_map' $null
    if ([string]::IsNullOrWhiteSpace($Mode)) {
        if ($Fast4H -and $null -ne (Get-RValue $modesTable 'fast_4h')) {
            $Mode = 'fast_4h'
        }
        elseif ($Fast4H) {
            $Mode = 'fast'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($HostModel)) {
            $hm = $HostModel.Trim()
            $hostKey = $null
            if ($hm -match 'orchestrator') { $hostKey = 'orchestrator' }
            elseif ($hm -match 'carbon') { $hostKey = 'carbon' }
            elseif ($hm -match 'hydrogen|\b4h(?:extra)?\b') { $hostKey = 'hydrogen' }
            if ($null -ne $hostKey) {
                $mappedHostMode = ''
                if ($null -ne $hostModeMap) {
                    $mappedHostMode = [string](Get-RValue $hostModeMap $hostKey '')
                }
                if ([string]::IsNullOrWhiteSpace($mappedHostMode)) {
                    $mappedHostMode = switch ($hostKey) {
                        'orchestrator' { 'orchestrator_fast' }
                        'carbon' { 'carbon_peak' }
                        'hydrogen' { 'hydrogen_max' }
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace($mappedHostMode) -and $null -ne (Get-RValue $modesTable $mappedHostMode)) {
                    $Mode = $mappedHostMode
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($Mode)) {
            $configuredMode = [string](Get-RValue $policy 'default_mode' '')
            if (
                -not [string]::IsNullOrWhiteSpace($configuredMode) -and
                $null -ne (Get-RValue $modesTable $configuredMode)
            ) {
                $Mode = $configuredMode
            }
            elseif ($null -ne (Get-RValue $modesTable 'peak')) {
                $Mode = 'peak'
            }
            else {
                $Mode = 'balanced'
            }
        }
    }
    $knownHostModes = New-Object 'System.Collections.Generic.List[string]'
    foreach ($hmName in @('orchestrator_fast', 'carbon_peak', 'hydrogen_max')) {
        [void]$knownHostModes.Add($hmName)
    }
    if ($null -ne $hostModeMap) {
        foreach ($hmKey in @(Get-OrchestraNames $hostModeMap)) {
            $hmVal = [string](Get-RValue $hostModeMap $hmKey '')
            if (-not [string]::IsNullOrWhiteSpace($hmVal) -and -not $knownHostModes.Contains($hmVal)) {
                [void]$knownHostModes.Add($hmVal)
            }
        }
    }
    $hostModeOut = if ($knownHostModes.Contains($Mode)) { $Mode } else { $null }
    $modeConfig = Get-RValue $modesTable $Mode
    if ($null -eq $modeConfig) {
        throw "ORCHESTRA_ARGS: Unknown mode: $Mode"
    }

    $excluded = @(
        foreach ($name in @(Expand-RNames $Exclude)) {
            $resolved = Resolve-RModel $registry $name
            if ($null -eq $resolved) {
                throw "ORCHESTRA_ARGS: Unknown excluded model: $name"
            }
            $resolved
        }
    )

    $dimensions = @(
        foreach ($tag in $tagNames) {
            @(Get-RValue (Get-RValue $tagTable $tag) 'caps' @())
        }
    ) | Sort-Object -Unique
    $reviewDimensions = @(
        foreach ($tag in $tagNames) {
            @(Get-RValue (Get-RValue $tagTable $tag) 'review_caps' @())
        }
    ) | Sort-Object -Unique

    $windowDays = [int](Get-RValue $policy 'redo_window_days' 30)
    $events = @()
    $statsIndex = $null
    if (-not $SkipTelemetry -and (Test-Path -LiteralPath $paths.Usage -PathType Leaf)) {
        $events = @(
            Read-UsageEvents -Paths $paths -SinceDays $windowDays
        )
        if ($events.Count -gt 0 -and (Get-Command New-OutcomeStatsIndex -ErrorAction SilentlyContinue)) {
            $statsIndex = New-OutcomeStatsIndex -Events $events -WindowDays $windowDays
        }
    }

    $rules = @(
        foreach ($rule in @(Get-RValue $registry 'hard_rules' @())) {
            $matchingTags = @(
                foreach ($tag in @(
                    Get-RValue $rule 'when_tags_any' @()
                )) {
                    if ($tagNames -contains $tag) { $tag }
                }
            )
            if ($matchingTags.Count -gt 0) { $rule }
        }
    )

    $reasons = New-Object 'System.Collections.Generic.List[string]'
    $applied = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rule in $rules) {
        $ruleId = [string](Get-RValue $rule 'id' 'unnamed-rule')
        if (-not $applied.Contains($ruleId)) {
            [void]$applied.Add($ruleId)
        }
    }

    $scoreMap = [ordered]@{}
    $records = @(
        foreach ($model in @(Get-RValue $registry 'models' @())) {
            $id = [string]$model.id
            if ($excluded -contains $id) { continue }

            $status = [string](Get-RValue $model 'status')
            if ($status -notin @('active', 'candidate')) { continue }

            $availability = Get-ModelAvailability `
                -Registry $registry -State $state -Model $model
            if ($availability -in @('exhausted', 'unavailable')) {
                [void]$reasons.Add("$id excluded: $availability.")
                continue
            }

            $escalationOnly = [bool](
                Get-RValue $model 'escalation_only' $false
            )
            foreach ($rule in @(
                Get-RValue $registry 'hard_rules' @()
            )) {
                if (
                    (Get-RValue $rule 'model') -eq $id -and
                    [bool](Get-RValue $rule 'escalation_only' $false)
                ) {
                    $escalationOnly = $true
                }
            }
            if ($escalationOnly -and -not $AllowEscalation) {
                [void]$reasons.Add(
                    "$id excluded: escalation requires AllowEscalation."
                )
                continue
            }

            $cap = Get-RCap $model @($dimensions)
            $quotaCost = 3.0 - [double]$model.quota_rank
            $latency = 3.0 - [double]$model.speed_rank
            $quotaPenalty = [double]$modeConfig.lambda_q * $quotaCost
            $speedPenalty = [double]$modeConfig.lambda_s * $latency
            $candidatePenalty = 0.0
            $lowPenalty = 0.0
            $redoPenalty = 0.0

            if ($status -eq 'candidate') {
                $candidatePenalty = [double](
                    Get-RValue $policy 'candidate_penalty' 1.0
                )
            }
            if ($availability -eq 'low') {
                $lowPenalty = [double](
                    Get-RValue $policy 'low_quota_penalty' 1.5
                )
            }

            $stats = $null
            if ($null -ne $statsIndex) {
                $stats = Get-OutcomeStats `
                    -Index $statsIndex -ModelId $id `
                    -Tags $tagNames -WindowDays $windowDays
            }
            elseif ($events.Count -gt 0) {
                $stats = Get-OutcomeStats `
                    -Events $events -ModelId $id `
                    -Tags $tagNames -WindowDays $windowDays
            }
            if ($null -ne $stats) {
                $n = [int](Get-RValue $stats 'n' 0)
                $minimumSamples = [int](
                    Get-RValue $policy 'redo_min_samples' 3
                )
                if ($n -ge $minimumSamples -and $n -gt 0) {
                    $bad = [int](Get-RValue $stats 'redo' 0) +
                        [int](Get-RValue $stats 'fail' 0)
                    $redoPenalty = [double](
                        Get-RValue $policy 'redo_penalty_scale' 3.0
                    ) * $bad / $n
                }
            }

            $score = $cap - $quotaPenalty - $speedPenalty -
                $candidatePenalty - $lowPenalty - $redoPenalty

            $scoreMap[$id] = [ordered]@{
                cap = $cap
                score = $score
                penalties = [ordered]@{
                    quota = $quotaPenalty
                    latency = $speedPenalty
                    candidate = $candidatePenalty
                    low_quota = $lowPenalty
                    redo = $redoPenalty
                }
            }
            [pscustomobject]@{
                Id = $id
                Model = $model
                Cap = $cap
                Score = $score
            }
        }
    )

    # The primary/fallback pool retains candidates. Review roles do not.
    $activeRecords = @(
        $records | Where-Object { $_.Model.status -eq 'active' }
    )

    $aestheticRule = $null
    foreach ($rule in $rules) {
        if ((Get-RValue $rule 'pattern') -eq 'aesthetic_gate') {
            $aestheticRule = $rule
            break
        }
    }

    $reservedReviewer = $null
    if (
        $null -ne $aestheticRule -and
        [bool](Get-RValue $aestheticRule `
            'exclude_reviewer_from_primary' $false)
    ) {
        $reviewerId = Resolve-RModel $registry (
            [string](Get-RValue $aestheticRule 'reviewer')
        )
        $reservedMatches = @(
            $activeRecords | Where-Object { $_.Id -eq $reviewerId }
        )
        if ($reservedMatches.Count -gt 0) {
            $reservedReviewer = $reviewerId
        }
    }

    $primaryPool = @(
        foreach ($record in $records) {
            $model = $record.Model
            $rejections = New-Object 'System.Collections.Generic.List[string]'

            if ($record.Id -eq $reservedReviewer) {
                [void]$rejections.Add('reserved as aesthetic reviewer')
            }
            if ([bool](Get-RValue $model 'primary_disabled' $false)) {
                [void]$rejections.Add(
                    'reserved for review/arbitration (primary_disabled)'
                )
            }

            foreach ($tag in $tagNames) {
                $tagConfig = Get-RValue $tagTable $tag
                $minimum = Get-RValue $tagConfig 'min_cap'
                if (
                    $null -eq $minimum -and
                    $tag -in @(
                        'math', 'backend', 'concurrency', 'algorithm', 'api'
                    )
                ) {
                    $minimum = 9
                }
                if ($null -eq $minimum) { continue }

                foreach ($dimension in @(
                    Get-RValue $tagConfig 'caps' @()
                )) {
                    $value = Get-RCap $model @($dimension)
                    if ($value -lt [double]$minimum) {
                        [void]$rejections.Add(
                            "$tag requires $dimension >= $minimum; got $value"
                        )
                    }
                }
            }

            foreach ($ruleRejection in @(Get-RHardRuleRejections -Model $model -Rules $rules)) {
                [void]$rejections.Add($ruleRejection)
            }

            if ($rejections.Count -gt 0) {
                foreach ($reason in $rejections) {
                    [void]$reasons.Add(
                        "$($record.Id) excluded as primary: $reason."
                    )
                }
                continue
            }
            $record
        }
    )
    $primaryPool = @(
        $primaryPool | Sort-Object `
            @{ Expression = { $_.Score }; Descending = $true },
            @{ Expression = { $_.Cap }; Descending = $true },
            @{ Expression = { $_.Model.quota_rank }; Descending = $true },
            @{ Expression = { $_.Model.speed_rank }; Descending = $true },
            @{ Expression = { $_.Id }; Descending = $false }
    )

    $result = [ordered]@{
        tags = @($tagNames)
        mode = $Mode
        primary = $null
        primary_effort = $null
        reviewer = $null
        reviewer_effort = $null
        polisher = $null
        fallback = @()
        escalate_to = $null
        pattern = 'solo'
        self_review = $false
        blocked = $false
        orchestration = $null
        scores = $scoreMap
        applied_rules = @($applied.ToArray())
        reasons = @()
    }

    if ($primaryPool.Count -eq 0) {
        $result.blocked = $true
        [void]$reasons.Add(
            'No available primary satisfies the routing constraints.'
        )
        $result.reasons = @($reasons.ToArray())
        Write-OrchestraResult -Object $result
        exit 0
    }

    $primary = $primaryPool[0].Model
    $fastTierOffloaded = $false
    $fastWorkhorseModel = $null
    $fastPrimaryPoolMatch = $null
    $fastFromModel = $null
    $fastFromId = $null
    $fastToId = $null
    $retainPrimaryHit = $false
    $retainReviewerHit = $false
    $retainPolisherHit = $false

    $fastWorkhorseMap = Get-RValue $policy 'fast_workhorse_map' $null
    $hydrogenMaxPolicy = Get-RValue $policy 'hydrogen_max_policy' $null
    $carbonPeakOffloadTags = @(
        Get-RValue $policy 'carbon_peak_offload_tags' @() | ForEach-Object { [string]$_ }
    )
    $hitsCarbonPeakOffload = (
        @($tagNames | Where-Object { $carbonPeakOffloadTags -contains $_ }).Count -gt 0
    )

    $rawFromName = ''
    $rawToName = ''
    if ($Mode -eq 'hydrogen_max' -and $null -ne $hydrogenMaxPolicy) {
        $rawFromName = [string](Get-RValue $hydrogenMaxPolicy 'from_model' '')
        $rawToName = [string](Get-RValue $hydrogenMaxPolicy 'to_model' '')
    }
    if ([string]::IsNullOrWhiteSpace($rawFromName) -and $null -ne $fastWorkhorseMap) {
        $rawFromName = [string](Get-RValue $fastWorkhorseMap 'from_model' '')
    }
    if ([string]::IsNullOrWhiteSpace($rawToName) -and $null -ne $fastWorkhorseMap) {
        $rawToName = [string](Get-RValue $fastWorkhorseMap 'to_model' '')
    }
    if ([string]::IsNullOrWhiteSpace($rawFromName) -and $Mode -in @('carbon_peak', 'hydrogen_max')) {
        $rawFromName = 'gemini-4-carbon'
    }
    if ([string]::IsNullOrWhiteSpace($rawToName) -and $Mode -in @('carbon_peak', 'hydrogen_max')) {
        $rawToName = 'gemini-4-hydrogen'
    }
    $fastFromId = Resolve-RModel $registry $rawFromName
    $fastToId = Resolve-RModel $registry $rawToName

    $isFastWorkhorseMode = ($Mode -in @('fast_4h', 'orchestrator_fast'))
    $isCarbonPeakOffload = ($Mode -eq 'carbon_peak' -and $hitsCarbonPeakOffload)
    $isHydrogenMaxMode = ($Mode -eq 'hydrogen_max')

    if (-not [string]::IsNullOrWhiteSpace($fastFromId) -and -not [string]::IsNullOrWhiteSpace($fastToId) -and $fastFromId -cne $fastToId) {
        if ($null -ne $fastWorkhorseMap) {
            $retainPrimaryTags = @(Get-RValue $fastWorkhorseMap 'retain_primary_tags' @() | ForEach-Object { [string]$_ })
            $retainReviewerTags = @(Get-RValue $fastWorkhorseMap 'retain_reviewer_tags' @() | ForEach-Object { [string]$_ })
            $retainPolisherTags = @(Get-RValue $fastWorkhorseMap 'retain_polisher_tags' @() | ForEach-Object { [string]$_ })
            $retainPrimaryHit = (@($tagNames | Where-Object { $retainPrimaryTags -contains $_ }).Count -gt 0)
            $retainReviewerHit = (@($tagNames | Where-Object { $retainReviewerTags -contains $_ }).Count -gt 0)
            $retainPolisherHit = (@($tagNames | Where-Object { $retainPolisherTags -contains $_ }).Count -gt 0)
        }

        $fastActiveMatch = @(
            $activeRecords | Where-Object { $_.Id -eq $fastToId -and -not [bool](Get-RValue $_.Model 'primary_disabled' $false) }
        ) | Select-Object -First 1
        if ($null -ne $fastActiveMatch) {
            $fastWorkhorseModel = $fastActiveMatch.Model
        }
        $fastFromMatch = @(
            $activeRecords | Where-Object { $_.Id -eq $fastFromId }
        ) | Select-Object -First 1
        if ($null -ne $fastFromMatch) {
            $fastFromModel = $fastFromMatch.Model
        }
        $fastPrimaryPoolMatch = @($primaryPool | Where-Object { $_.Id -eq $fastToId }) | Select-Object -First 1

        if (-not $AllowEscalation -and $primary.id -eq $fastFromId) {
            if ($isFastWorkhorseMode -and -not $retainPrimaryHit -and $null -ne $fastPrimaryPoolMatch) {
                $primary = $fastPrimaryPoolMatch.Model
                $fastTierOffloaded = $true
                [void]$reasons.Add("$Mode tier: offloaded routine $fastFromId primary task to $fastToId (retaining $fastFromId for high-bar tags).")
            }
            elseif ($isCarbonPeakOffload -and $null -ne $fastPrimaryPoolMatch) {
                $primary = $fastPrimaryPoolMatch.Model
                $fastTierOffloaded = $true
                [void]$reasons.Add("carbon_peak tier: offloaded mechanical $fastFromId primary task to $fastToId.")
            }
            elseif ($isHydrogenMaxMode -and $null -ne $fastPrimaryPoolMatch) {
                $primary = $fastPrimaryPoolMatch.Model
                $fastTierOffloaded = $true
                [void]$reasons.Add("hydrogen_max tier: offloaded $fastFromId primary task to $fastToId.")
            }
        }
    }

    if ($PreferIdle -and -not (Test-RPoolAvailable -PoolLoad $poolLoad -Model $primary)) {
        $idlePrimaryMatch = @(
            $primaryPool | Where-Object { Test-RPoolAvailable -PoolLoad $poolLoad -Model $_.Model }
        ) | Select-Object -First 1
        if ($null -ne $idlePrimaryMatch -and $idlePrimaryMatch.Id -ne $primary.id) {
            $primary = $idlePrimaryMatch.Model
            if (
                -not $AllowEscalation -and
                -not [string]::IsNullOrWhiteSpace($fastFromId) -and
                $primary.id -eq $fastFromId -and
                $null -ne $fastPrimaryPoolMatch -and
                (Test-RPoolAvailable -PoolLoad $poolLoad -Model $fastPrimaryPoolMatch.Model) -and
                (($isFastWorkhorseMode -and -not $retainPrimaryHit) -or $isCarbonPeakOffload -or $isHydrogenMaxMode)
            ) {
                $primary = $fastPrimaryPoolMatch.Model
                $fastTierOffloaded = $true
            }
            [void]$reasons.Add("load_balance: shifted primary from saturated pool to idle pool ($($primary.id)).")
        }
    }

    $result.primary = [string]$primary.id
    $fallbackList = New-Object 'System.Collections.Generic.List[string]'
    if ($fastTierOffloaded -and ($primaryPool | Where-Object { $_.Id -eq $fastFromId })) {
        [void]$fallbackList.Add($fastFromId)
    }
    foreach ($rec in $primaryPool) {
        if ($rec.Id -eq $primary.id -or $fallbackList.Contains($rec.Id)) { continue }
        [void]$fallbackList.Add([string]$rec.Id)
        if ($fallbackList.Count -ge 2) { break }
    }
    $result.fallback = @($fallbackList.ToArray())

    $preferredReviewerIds = @()
    $hardPreferredReviewerIds = @()
    $reviewer = $null
    if ($null -ne $aestheticRule) {
        $result.pattern = 'aesthetic_gate'
        foreach ($name in @(
            Get-RValue $aestheticRule 'reviewer'
            Get-RValue $aestheticRule 'reviewer_fallback'
        )) {
            $id = Resolve-RModel $registry ([string]$name)
            if ($null -eq $id) { continue }
            $reviewMatches = @(
                $activeRecords | Where-Object { $_.Id -eq $id }
            )
            if ($reviewMatches.Count -gt 0) {
                $reviewer = $reviewMatches[0].Model
                break
            }
            [void]$reasons.Add(
                "Configured aesthetic reviewer $id is not eligible as active."
            )
        }
        if ($null -eq $reviewer) {
            $reviewer = Select-RReviewer `
                -Candidates $activeRecords -Primary $primary `
                -Dimensions @($reviewDimensions) -Reasons $reasons
        }
        if ($null -eq $reviewer) {
            $result.blocked = $true
            [void]$reasons.Add(
                'The aesthetic gate has no eligible active reviewer.'
            )
        }
    }
    else {
        $hardPreferredReviewerIds = @(
            foreach ($rule in $rules) {
                $id = Resolve-RModel $registry ([string](Get-RValue $rule 'reviewer'))
                if ($null -ne $id) { $id }
            }
        )
        $preferredReviewerIds = @(
            foreach ($rule in $rules) {
                foreach ($name in @(
                    Get-RValue $rule 'reviewer'
                    Get-RValue $rule 'reviewer_fallback'
                )) {
                    $id = Resolve-RModel $registry ([string]$name)
                    if ($null -ne $id) { $id }
                }
            }
        )
        if (
            @($reviewDimensions).Count -gt 0 -or
            $preferredReviewerIds.Count -gt 0
        ) {
            $reviewer = Select-RReviewer `
                -Candidates $activeRecords -Primary $primary `
                -Dimensions @($reviewDimensions) `
                -PreferredIds $preferredReviewerIds `
                -HardPreferredIds $hardPreferredReviewerIds -Reasons $reasons
        }
    }

    if ($null -ne $reviewer -and -not $AllowEscalation -and $null -ne $fastWorkhorseModel) {
        if ($isFastWorkhorseMode) {
            if (
                $reviewer.id -eq $fastFromId -and
                -not $retainReviewerHit -and
                $primary.id -ne $fastToId -and
                ($fastWorkhorseModel.vendor -ne $primary.vendor -or $reviewer.vendor -eq $primary.vendor)
            ) {
                $reviewer = $fastWorkhorseModel
                $fastTierOffloaded = $true
                [void]$reasons.Add("$Mode tier: offloaded routine $fastFromId review to $fastToId (high-bar tags retain $fastFromId).")
            }
            elseif (
                $retainReviewerHit -and
                $null -ne $fastFromModel -and
                $reviewer.id -eq $fastToId -and
                $primary.id -ne $fastFromId
            ) {
                $reviewer = $fastFromModel
                [void]$reasons.Add("$Mode tier: retained $fastFromId for high-bar review ($($tagNames -join ',')).")
            }
        }
        elseif ($isHydrogenMaxMode -and $reviewer.id -eq $fastFromId) {
            if (
                $primary.id -ne $fastToId -and
                ($fastWorkhorseModel.vendor -ne $primary.vendor -or $reviewer.vendor -eq $primary.vendor)
            ) {
                $reviewer = $fastWorkhorseModel
                $fastTierOffloaded = $true
                [void]$reasons.Add("hydrogen_max tier: offloaded $fastFromId review to $fastToId.")
            }
            elseif ($primary.id -eq $fastToId) {
                $reselected = Select-RReviewer `
                    -Candidates @($activeRecords | Where-Object { $_.Id -ne $fastFromId -and $_.Id -ne $primary.id }) `
                    -Primary $primary -Dimensions @($reviewDimensions) `
                    -PreferredIds $preferredReviewerIds -HardPreferredIds $hardPreferredReviewerIds -Reasons $reasons
                if ($null -ne $reselected) {
                    $reviewer = $reselected
                    [void]$reasons.Add("hydrogen_max tier: replaced $fastFromId reviewer with independent $($reviewer.id) while $fastToId owns primary.")
                }
                else {
                    [void]$reasons.Add("hydrogen_max tier: retained $fastFromId reviewer to avoid self-review while $fastToId owns primary.")
                }
            }
        }
    }
    if ($PreferIdle -and $null -ne $reviewer -and $null -eq $aestheticRule -and -not $retainReviewerHit -and -not (Test-RPoolAvailable -PoolLoad $poolLoad -Model $reviewer)) {
        $idleRevCandidates = @(
            $activeRecords | Where-Object {
                $_.Id -ne $primary.id -and
                (Test-RPoolAvailable -PoolLoad $poolLoad -Model $_.Model)
            }
        )
        if ($isHydrogenMaxMode -and -not $AllowEscalation -and -not [string]::IsNullOrWhiteSpace($fastFromId)) {
            $nonCarbonIdle = @($idleRevCandidates | Where-Object { $_.Id -ne $fastFromId })
            if ($nonCarbonIdle.Count -gt 0) { $idleRevCandidates = $nonCarbonIdle }
        }
        if ($idleRevCandidates.Count -gt 0) {
            $idleRev = Select-RReviewer `
                -Candidates $idleRevCandidates -Primary $primary `
                -Dimensions @($reviewDimensions) -PreferredIds $preferredReviewerIds -HardPreferredIds $hardPreferredReviewerIds -Reasons $reasons
            if ($null -ne $idleRev -and $idleRev.id -ne $reviewer.id) {
                $oldRevId = [string]$reviewer.id
                $reviewer = $idleRev
                [void]$reasons.Add("load_balance: shifted reviewer from saturated pool ($oldRevId) to $($reviewer.id) on idle pool.")
            }
        }
    }
    if ($null -ne $reviewer) {
        $result.reviewer = [string]$reviewer.id
        $result.self_review = $reviewer.id -eq $primary.id
    }

    foreach ($rule in $rules) {
        $name = [string](Get-RValue $rule 'polisher')
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $id = Resolve-RModel $registry $name
        if ($id -eq $primary.id) { continue }

        $polisher = $null
        foreach ($polishName in @(
            $name
            Get-RValue $rule 'polisher_fallback'
        )) {
            $polishId = Resolve-RModel $registry ([string]$polishName)
            if ($null -eq $polishId -or $polishId -eq $primary.id) {
                continue
            }
            $polishMatches = @(
                $activeRecords | Where-Object { $_.Id -eq $polishId }
            )
            if ($polishMatches.Count -gt 0) {
                $polisher = $polishMatches[0].Model
                break
            }
        }
        if ($null -eq $polisher) {
            $polisher = Select-RPolisher `
                -Candidates $activeRecords -Primary $primary
            [void]$reasons.Add(
                'Configured polisher is ineligible; reselected among active models.'
            )
        }
        if ($null -ne $polisher) {
            $shouldOffloadPolisher = (
                -not $AllowEscalation -and
                $null -ne $fastWorkhorseModel -and
                $polisher.id -eq $fastFromId -and
                (($isFastWorkhorseMode -and -not $retainPolisherHit) -or $isHydrogenMaxMode)
            )
            if ($shouldOffloadPolisher) {
                if ($primary.id -eq $fastToId) {
                    $polisher = $null
                    [void]$reasons.Add("$Mode tier: skipped $fastFromId polisher since $fastToId already owns primary.")
                    break
                }
                else {
                    $polisher = $fastWorkhorseModel
                    $fastTierOffloaded = $true
                    [void]$reasons.Add("$Mode tier: offloaded $fastFromId polish to $fastToId.")
                }
            }
            if ($null -ne $polisher) {
                $result.polisher = [string]$polisher.id
                break
            }
        }
    }

    if ($null -eq $aestheticRule) {
        $delegationTags = @(
            $tagNames | Where-Object {
                $_ -in @('image_gen', 'office', 'ppt')
            }
        )
        if (
            $primary.vendor -eq 'openai' -and
            $delegationTags.Count -gt 0
        ) {
            $result.pattern = 'strength_delegation'
        }
        elseif ($null -ne $reviewer) {
            $result.pattern = 'pipelined_review'
        }
    }

    $escalationId = Resolve-RModel $registry (
        [string](Get-RValue $primary 'escalate_to')
    )
    if ($null -ne $escalationId -and $excluded -notcontains $escalationId) {
        $target = @(
            $registry.models | Where-Object {
                $_.id -eq $escalationId -and
                $_.status -in @('active', 'candidate')
            }
        )
        if ($target.Count -gt 0) {
            $availability = Get-ModelAvailability `
                -Registry $registry -State $state -Model $target[0]
            if ($availability -in @('normal', 'low')) {
                $result.escalate_to = $escalationId
            }
        }
    }

    $workhorseIdForEffort = [string]$fastToId
    $result.primary_effort = Resolve-REffort `
        -Model $primary -ModeName $Mode -TagList @($tagNames) `
        -Escalated ([bool]$AllowEscalation) -Policy $policy -AllowBoost $true `
        -FastWorkhorseId $workhorseIdForEffort
    if ($null -ne $reviewer) {
        $result.reviewer_effort = Resolve-REffort `
            -Model $reviewer -ModeName $Mode -TagList @($tagNames) `
            -Escalated ([bool]$AllowEscalation) -Policy $policy -AllowBoost $false `
            -FastWorkhorseId $workhorseIdForEffort
    }

    $dualTags = @(
        Get-RValue $policy 'dual_draft_tags' @() | ForEach-Object { [string]$_ }
    )
    $hitsDualTag = (
        @($tagNames | Where-Object { $dualTags -contains $_ }).Count -gt 0
    )
    $coDrafterId = $null
    $coDrafterEffort = $null
    if ($Mode -in @('peak', 'fast_4h', 'orchestrator_fast', 'carbon_peak', 'hydrogen_max') -and $hitsDualTag) {
        $coCandidates = @(
            $activeRecords | Where-Object {
                $_.Id -ne $primary.id -and
                $_.Model.vendor -ne $primary.vendor -and
                -not [bool](Get-RValue $_.Model 'primary_disabled' $false)
            } | Sort-Object `
                @{ Expression = { $_.Score }; Descending = $true },
                @{ Expression = { $_.Cap }; Descending = $true },
                @{ Expression = { $_.Id }; Descending = $false }
        )
        if ($coCandidates.Count -gt 0) {
            $coModel = $coCandidates[0].Model
            $shouldOffloadCoDrafter = (
                -not $AllowEscalation -and
                $null -ne $fastWorkhorseModel -and
                $coModel.id -eq $fastFromId -and
                $fastWorkhorseModel.vendor -ne $primary.vendor -and
                (($isFastWorkhorseMode -and -not $retainReviewerHit) -or $isCarbonPeakOffload -or $isHydrogenMaxMode)
            )
            if ($shouldOffloadCoDrafter) {
                $coModel = $fastWorkhorseModel
                $fastTierOffloaded = $true
            }
            if ($PreferIdle -and -not (Test-RPoolAvailable -PoolLoad $poolLoad -Model $coModel)) {
                $idleCoCandidates = @($coCandidates | Where-Object { Test-RPoolAvailable -PoolLoad $poolLoad -Model $_.Model })
                if ($idleCoCandidates.Count -gt 0) {
                    $coModel = $idleCoCandidates[0].Model
                    if (
                        -not $AllowEscalation -and
                        $null -ne $fastWorkhorseModel -and
                        $coModel.id -eq $fastFromId -and
                        $fastWorkhorseModel.vendor -ne $primary.vendor -and
                        (Test-RPoolAvailable -PoolLoad $poolLoad -Model $fastWorkhorseModel) -and
                        (($isFastWorkhorseMode -and -not $retainReviewerHit) -or $isCarbonPeakOffload -or $isHydrogenMaxMode)
                    ) {
                        $coModel = $fastWorkhorseModel
                        $fastTierOffloaded = $true
                    }
                    [void]$reasons.Add("load_balance: shifted co_drafter to $($coModel.id) on idle pool.")
                }
            }
            $coDrafterId = [string]$coModel.id
            $coDrafterEffort = Resolve-REffort `
                -Model $coModel -ModeName $Mode -TagList @($tagNames) `
                -Escalated ([bool]$AllowEscalation) -Policy $policy -AllowBoost $true `
                -FastWorkhorseId $workhorseIdForEffort
        }
    }

    $finalReviewerId = $null
    $finalReviewTriggersOut = @()
    if ($isHydrogenMaxMode) {
        $hTriggers = @()
        if ($null -ne $hydrogenMaxPolicy) {
            $hTriggers = @(Get-RValue $hydrogenMaxPolicy 'final_review_triggers' @() | ForEach-Object { [string]$_ })
        }
        $finalReviewTriggersOut = @($hTriggers)
        $hitsFinalTrigger = (@($tagNames | Where-Object { $hTriggers -contains $_ }).Count -gt 0)
        if (($AllowEscalation -or $hitsFinalTrigger) -and -not [string]::IsNullOrWhiteSpace($fastFromId) -and $fastFromId -ne $primary.id) {
            $carbonActive = @($activeRecords | Where-Object { $_.Id -eq $fastFromId }) | Select-Object -First 1
            if ($null -ne $carbonActive) {
                $finalReviewerId = $fastFromId
                [void]$reasons.Add("hydrogen_max gate: assigned final_reviewer=$finalReviewerId.")
            }
        }
    }

    $parallelLanes = New-Object 'System.Collections.Generic.List[object]'
    [void]$parallelLanes.Add([ordered]@{
        lane = 'critical_primary'
        role = 'primary_implementation'
        model = [string]$primary.id
        pool = (Resolve-RPoolName -Model $primary)
        timing = 'T0_immediate_LPT'
        scope = 'primary shard'
    })

    if (@($tagNames | Where-Object { $_ -in @('frontend', 'ui', 'landing_page') }).Count -gt 0) {
        $codexLaneMatch = @($activeRecords | Where-Object { $_.Id -eq 'gpt-6.2-astra' -and $_.Id -ne $primary.id }) | Select-Object -First 1
        if ($null -eq $codexLaneMatch) {
            $codexLaneMatch = @(
                $activeRecords |
                    Where-Object { (Resolve-RPoolName -Model $_.Model) -eq 'codex_openai' -and $_.Id -ne $primary.id } |
                    Sort-Object @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Id }; Descending = $false }
            ) | Select-Object -First 1
        }
        if ($null -ne $codexLaneMatch -and (Test-RPoolAvailable -PoolLoad $poolLoad -Model $codexLaneMatch.Model)) {
            [void]$parallelLanes.Add([ordered]@{
                lane = 'parallel_codex_contract'
                role = 'parallel_assets_or_contract'
                model = [string]$codexLaneMatch.Id
                pool = 'codex_openai'
                timing = 'T0_parallel_if_needed'
                scope = 'assets / backend contract / verification'
            })
        }

        $opusLaneModel = $null
        if ($null -ne $reviewer -and (Resolve-RPoolName -Model $reviewer) -eq 'agy_anthropic') {
            $opusLaneModel = $reviewer
        }
        else {
            $opusLaneMatch = @($activeRecords | Where-Object { $_.Id -eq 'claude-opus-5-5' }) | Select-Object -First 1
            if ($null -eq $opusLaneMatch) {
                $opusLaneMatch = @($activeRecords | Where-Object { (Resolve-RPoolName -Model $_.Model) -eq 'agy_anthropic' }) | Select-Object -First 1
            }
            if ($null -ne $opusLaneMatch) { $opusLaneModel = $opusLaneMatch.Model }
        }
        if ($null -ne $opusLaneModel) {
            [void]$parallelLanes.Add([ordered]@{
                lane = 'aesthetic_gate'
                role = 'aesthetic_gate_tokens_and_viewport'
                model = [string]$opusLaneModel.id
                pool = 'agy_anthropic'
                timing = 'T1_overlap_slice1_screenshots'
                scope = '1440/768/390 screenshots + tokens'
            })
        }
    }

    if (@($tagNames | Where-Object { $_ -in @('backend', 'api', 'concurrency', 'bugfix', 'algorithm', 'refactor') }).Count -gt 0) {
        $googleLaneMatch = @($activeRecords | Where-Object {
            $_.Id -eq 'gemini-4-hydrogen' -and $_.Id -ne $primary.id -and -not [bool](Get-RValue $_.Model 'primary_disabled' $false)
        }) | Select-Object -First 1
        if ($null -eq $googleLaneMatch) {
            $googleLaneMatch = @(
                $activeRecords |
                    Where-Object {
                        (Resolve-RPoolName -Model $_.Model) -eq 'agy_google' -and
                        $_.Id -ne $primary.id -and
                        -not [bool](Get-RValue $_.Model 'primary_disabled' $false) -and
                        (-not ($isHydrogenMaxMode -and -not $AllowEscalation -and -not [string]::IsNullOrWhiteSpace($fastFromId) -and $_.Id -eq $fastFromId))
                    } |
                    Sort-Object @{ Expression = { [int]$_.Model.speed_rank }; Descending = $true }, @{ Expression = { $_.Score }; Descending = $true }, @{ Expression = { $_.Id }; Descending = $false }
            ) | Select-Object -First 1
        }
        if ($null -ne $googleLaneMatch) {
            $googlePoolInfo = $poolLoad.pools['agy_google']
            $googleUsed = [int]$googlePoolInfo.active
            $googleLimit = [int]$googlePoolInfo.limit
            $googleHasCapacity = if ((Resolve-RPoolName -Model $primary) -eq 'agy_google') {
                ($googleUsed + 1) -lt $googleLimit
            }
            else {
                Test-RPoolAvailable -PoolLoad $poolLoad -Model $googleLaneMatch.Model
            }
            if ($googleHasCapacity) {
                [void]$parallelLanes.Add([ordered]@{
                    lane = 'parallel_fast_google'
                    role = 'parallel_disjoint_tests_and_recon'
                    model = [string]$googleLaneMatch.Id
                    pool = 'agy_google'
                    timing = 'T0_parallel_disjoint_tests_prefix'
                    scope = 'tests/ & context_pack.md'
                })
            }
        }
        if ($null -ne $reviewer) {
            $tieBreakMatch = @($activeRecords | Where-Object { $_.Id -eq 'claude-opus-5-5' }) | Select-Object -First 1
            if ($null -eq $tieBreakMatch) {
                $tieBreakMatch = @($activeRecords | Where-Object { (Resolve-RPoolName -Model $_.Model) -eq 'agy_anthropic' }) | Select-Object -First 1
            }
            $reviewScope = 'delta diff + <=20 test log lines'
            if ($null -ne $coDrafterId) {
                $tieHint = if ($null -ne $tieBreakMatch) { "$($tieBreakMatch.Id) <=800w tie-break arbitration" } else { '<=800w tie-break arbitration' }
                $reviewScope = "$reviewScope; $tieHint"
            }
            [void]$parallelLanes.Add([ordered]@{
                lane = 'micro_slice_review'
                role = $(if ($null -ne $coDrafterId) { 'delta_review_and_tie_break' } else { 'delta_review' })
                model = [string]$reviewer.id
                pool = (Resolve-RPoolName -Model $reviewer)
                timing = 'T1_micro_slice_TDM_delta_review'
                scope = $reviewScope
            })
        }
    }

    $selectedRoleIds = New-Object 'System.Collections.Generic.List[string]'
    foreach ($roleId in @($primary.id, $result.reviewer, $result.polisher, $coDrafterId, $finalReviewerId)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$roleId) -and -not $selectedRoleIds.Contains([string]$roleId)) {
            [void]$selectedRoleIds.Add([string]$roleId)
        }
    }
    foreach ($lane in $parallelLanes) {
        $laneModelId = [string](Get-RValue $lane 'model' '')
        if (-not [string]::IsNullOrWhiteSpace($laneModelId) -and -not $selectedRoleIds.Contains($laneModelId)) {
            [void]$selectedRoleIds.Add($laneModelId)
        }
    }
    $selectedRoleLabels = @(
        foreach ($rid in $selectedRoleIds) {
            switch ($rid) {
                'gpt-6.2-astra' { 'Astra' }
                'claude-opus-5-5' { 'Opus' }
                'gemini-4-carbon' { 'Carbon' }
                'gemini-4-hydrogen' { '4H' }
                default { $rid }
            }
        }
    )
    $selectedRolesText = if ($selectedRoleLabels.Count -gt 0) { $selectedRoleLabels -join ' + ' } else { [string]$primary.id }
    $underutilScope = if ($parallelLanes.Count -gt 1) {
        'across selected parallel lanes & TDM micro-slices'
    }
    else {
        'across selected role & TDM micro-slices'
    }

    $codexAvail = [int]$poolLoad.pools['codex_openai'].available
    $scaleOutHint = if ([bool]$poolLoad.underutilized) {
        "underutilized_capacity: activate selected idle roles ($selectedRolesText) $underutilScope"
    }
    elseif ($codexAvail -le 0) {
        'codex_pool_saturated: queue TDM <=4 slots (AIMD 1 during rotation) or offload non-min_cap slices to 4H Extra'
    }
    else {
        'balanced_multi_pool'
    }

    $selectedEntry = ($primaryPool | Where-Object { $_.Id -eq $primary.id } | Select-Object -First 1)
    if ($null -eq $selectedEntry) {
        $selectedEntry = ($records | Where-Object { $_.Id -eq $primary.id } | Select-Object -First 1)
    }
    $selectedScore = if ($null -ne $selectedEntry) { $selectedEntry.Score } else { $null }
    $result.orchestration = [ordered]@{
        recon_gate = 'read_only_required'
        handoff_contract = 'plan_contract.md'
        replan_circuit_breaker = $true
        active_verifier = (($null -ne $reviewer -and -not $result.self_review) -or $null -ne $finalReviewerId)
        dual_draft_eligible = ($null -ne $coDrafterId)
        co_drafter = $coDrafterId
        co_drafter_effort = $coDrafterEffort
        fast_tier_offload = [bool]$fastTierOffloaded
        fast_workhorse = $(if ($fastTierOffloaded) { $fastToId } else { $null })
        escalate_to_model = $result.escalate_to
        host_mode = $hostModeOut
        final_reviewer = $finalReviewerId
        final_review_triggers = @($finalReviewTriggersOut)
        pool_load = $poolLoad
        scale_out_hint = $scaleOutHint
        parallel_lanes = @($parallelLanes.ToArray())
    }

    [void]$reasons.Add(
        "Selected $($primary.id) ($($result.primary_effort)) with score $selectedScore."
    )
    if ($result.self_review) {
        [void]$reasons.Add(
            'The configured aesthetic fallback reviews its own primary output.'
        )
    }
    $result.reasons = @($reasons.ToArray())
    Write-OrchestraResult -Object $result
    exit 0
}
catch {
    $message = $_.Exception.Message
    $code = 3
    if ($message -match 'ORCHESTRA_ARGS:') { $code = 2 }
    if ($message -match 'ORCHESTRA_LOCK_TIMEOUT') { $code = 5 }
    [Console]::Error.WriteLine($message)
    Write-OrchestraResult -Object @{
        error = $message
        exit = $code
    }
    exit $code
}
