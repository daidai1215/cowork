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
    [string[]]$Exclude = @(),
    [switch]$AllowEscalation,
    [string]$RegistryPath,
    [string]$StateDir
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

function Expand-RNames {
    param([string[]]$Names)
    @(
        foreach ($name in $Names) {
            foreach ($part in ($name -split ',')) {
                $value = $part.Trim()
                if ($value.Length -gt 0) { $value }
            }
        }
    ) | Sort-Object -Unique
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

    if ($selected.OtherVendor -eq 0) {
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

function Resolve-REffort {
    param(
        $Model,
        [string]$ModeName,
        [string[]]$TagList,
        [bool]$Escalated,
        $Policy,
        [bool]$AllowBoost
    )
    if ($null -eq $Model) { return $null }
    $invokeObj = Get-RValue $Model 'invoke'
    $fallbackEffort = [string](Get-RValue $Policy 'default_effort' 'high')
    $baseEffort = [string](Get-RValue $invokeObj 'default_effort' $fallbackEffort)
    if (-not $AllowBoost) { return $baseEffort }

    $peakEffort = [string](Get-RValue $invokeObj 'peak_effort' '')
    if ([string]::IsNullOrWhiteSpace($peakEffort)) { return $baseEffort }
    $supported = @(
        Get-RValue $invokeObj 'efforts' @() | ForEach-Object { [string]$_ }
    )
    if ($supported -notcontains $peakEffort) { return $baseEffort }

    $peakTags = @(
        Get-RValue $Policy 'peak_effort_tags' @() | ForEach-Object { [string]$_ }
    )
    $hitsPeakTag = (
        @($TagList | Where-Object { $peakTags -contains $_ }).Count -gt 0
    )
    if ($Escalated -or ($ModeName -eq 'peak' -and $hitsPeakTag)) {
        return $peakEffort
    }
    return $baseEffort
}

try {
    $paths = Get-OrchestraPaths `
        -RegistryPath $RegistryPath -StateDir $StateDir

    $snapshot = Invoke-WithLock -Paths $paths -Name registry -ScriptBlock {
        $registrySnapshot = Read-Registry -Paths $paths
        Invoke-WithLock -Paths $paths -Name state -ScriptBlock {
            [pscustomobject]@{
                Registry = $registrySnapshot
                State = Read-State -Paths $paths
            }
        }
    }
    $registry = $snapshot.Registry
    $state = $snapshot.State

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
    $modesTable = Get-RValue $registry 'modes'
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
    if (Test-Path -LiteralPath $paths.Usage -PathType Leaf) {
        $events = @(
            Read-UsageEvents -Paths $paths -SinceDays $windowDays
        )
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

            $stats = Get-OutcomeStats `
                -Events $events -ModelId $id `
                -Tags $tagNames -WindowDays $windowDays
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

            foreach ($rule in $rules) {
                $channels = @(
                    Get-RValue $rule 'primary_channel_only' @()
                )
                if (
                    $channels.Count -gt 0 -and
                    $channels -notcontains $model.channel
                ) {
                    [void]$rejections.Add(
                        "primary channel must be $($channels -join ',')"
                    )
                }

                foreach ($tool in @(
                    Get-RValue $rule 'primary_requires_tool' @()
                )) {
                    if (@(Get-RValue $model 'tools' @()) -notcontains $tool) {
                        [void]$rejections.Add("primary requires tool $tool")
                    }
                }
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
    $result.primary = [string]$primary.id
    $result.fallback = @(
        $primaryPool |
            Where-Object { $_.Id -ne $primary.id } |
            Select-Object -First 2 |
            ForEach-Object { $_.Id }
    )

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
                -PreferredIds $preferredReviewerIds -Reasons $reasons
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
            $result.polisher = [string]$polisher.id
            break
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

    $result.primary_effort = Resolve-REffort `
        -Model $primary -ModeName $Mode -TagList @($tagNames) `
        -Escalated ([bool]$AllowEscalation) -Policy $policy -AllowBoost $true
    if ($null -ne $reviewer) {
        $result.reviewer_effort = Resolve-REffort `
            -Model $reviewer -ModeName $Mode -TagList @($tagNames) `
            -Escalated $false -Policy $policy -AllowBoost $false
    }

    $dualTags = @(
        Get-RValue $policy 'dual_draft_tags' @() | ForEach-Object { [string]$_ }
    )
    $hitsDualTag = (
        @($tagNames | Where-Object { $dualTags -contains $_ }).Count -gt 0
    )
    $coDrafterId = $null
    $coDrafterEffort = $null
    if ($Mode -eq 'peak' -and $hitsDualTag) {
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
            $coDrafterId = [string]$coModel.id
            $coDrafterEffort = Resolve-REffort `
                -Model $coModel -ModeName $Mode -TagList @($tagNames) `
                -Escalated $false -Policy $policy -AllowBoost $true
        }
    }
    $result.orchestration = [ordered]@{
        recon_gate = 'read_only_required'
        handoff_contract = 'plan_contract.md'
        replan_circuit_breaker = $true
        active_verifier = ($null -ne $reviewer)
        dual_draft_eligible = ($null -ne $coDrafterId)
        co_drafter = $coDrafterId
        co_drafter_effort = $coDrafterEffort
    }

    [void]$reasons.Add(
        "Selected $($primary.id) ($($result.primary_effort)) with score $($primaryPool[0].Score)."
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
