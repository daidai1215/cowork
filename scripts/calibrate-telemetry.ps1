<#
.SYNOPSIS
Analyze local usage telemetry and emit human-reviewed capability and speed_rank proposals.
.DESCRIPTION
Reads usage.jsonl outside locks, computes outcome coverage, Cockpit rotation statistics,
capability drift, and speed_rank inversions, and saves deduplicated proposals under registry/proposals.
#>
[CmdletBinding()]
param(
    [int]$WindowDays = 30,
    [switch]$DryRun,
    [string]$RegistryPath,
    [string]$StateDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Get-Median {
    param([double[]]$Values)
    $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) { return [double]$sorted[$middle] }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2.0
}

function New-Patch {
    param([string]$Path, $OldValue, $Value)
    return [pscustomobject]@{
        op = 'set'
        path = $Path
        old_value = $OldValue
        value = $Value
        unlock = $false
    }
}

try {
    if ($WindowDays -lt 1) {
        throw 'ORCHESTRA_ARGS: WindowDays must be at least 1.'
    }
    $paths = Get-OrchestraPaths -RegistryPath $RegistryPath -StateDir $StateDir
    $registry = Read-Registry -Paths $paths
    $events = @(Read-UsageEvents -Paths $paths -SinceDays 0)
    $now = Get-OrchestraNow
    $since = $now.AddDays(-$WindowDays)
    $policy = Get-OrchestraProperty $registry 'policy' $null
    $minSamples = [int](Get-OrchestraProperty $policy 'telemetry_min_samples' 5)
    if ($minSamples -lt 1) { $minSamples = 1 }
    $badThreshold = [double](Get-OrchestraProperty $policy 'telemetry_bad_rate_threshold' 0.4)

    $active = @($registry.models | Where-Object { [string]$_.status -eq 'active' })
    $invocations = @{}
    $successfulInvocations = @{}
    $outcomes = @{}
    $durations = @{}
    foreach ($model in $active) {
        $durations[[string]$model.id] = @{}
    }

    foreach ($ev in $events) {
        $rawTime = [string](Get-OrchestraProperty $ev 'ts' '')
        if ([string]::IsNullOrWhiteSpace($rawTime)) { continue }
        $time = $null
        try { $time = ConvertTo-OrchestraUtc $rawTime } catch { continue }
        if ($null -eq $time -or $time -gt $now) { continue }

        $evType = [string](Get-OrchestraProperty $ev 'type' '')
        $iid = [string](Get-OrchestraProperty $ev 'invocation_id' '')
        if ($evType -eq 'outcome') {
            $result = [string](Get-OrchestraProperty $ev 'outcome' '')
            if (-not [string]::IsNullOrWhiteSpace($iid) -and $result -in @('ok', 'redo', 'fail')) {
                if (-not $outcomes.ContainsKey($iid) -or $time -ge $outcomes[$iid].time) {
                    $outcomes[$iid] = @{ time = $time; event = $ev }
                }
            }
            continue
        }
        if ($evType -ne 'invocation' -or $time -lt $since) { continue }
        if ([bool](Get-OrchestraProperty $ev 'ad_hoc' $false)) { continue }

        if (-not [string]::IsNullOrWhiteSpace($iid) -and -not $invocations.ContainsKey($iid)) {
            $invocations[$iid] = @{ time = $time; event = $ev }
            $evExit = Get-OrchestraProperty $ev 'exit' $null
            if ($null -ne $evExit -and [int]$evExit -eq 0) {
                $successfulInvocations[$iid] = @{ time = $time; event = $ev }
            }
        }

        $id = [string](Get-OrchestraProperty $ev 'model' '')
        if (-not $durations.ContainsKey($id)) { continue }
        if ([string](Get-OrchestraProperty $ev 'access' '') -ne 'read') { continue }
        $exitValue = Get-OrchestraProperty $ev 'exit' $null
        if ($null -eq $exitValue -or [int]$exitValue -ne 0) { continue }
        if ([bool](Get-OrchestraProperty $ev 'account_switched' $false)) { continue }

        $duration = 0.0
        $durRaw = [string](Get-OrchestraProperty $ev 'duration_sec' '')
        if (-not [double]::TryParse($durRaw, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$duration)) {
            continue
        }
        if ($duration -le 0 -or [double]::IsNaN($duration) -or [double]::IsInfinity($duration)) { continue }

        $bucket = ((@(Get-OrchestraArray $ev 'tags') | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique) -join ',')
        if ([string]::IsNullOrWhiteSpace($bucket)) { $bucket = '__untagged__' }
        if (-not $durations[$id].ContainsKey($bucket)) {
            $durations[$id][$bucket] = New-Object 'System.Collections.Generic.List[double]'
        }
        [void]$durations[$id][$bucket].Add($duration)
    }

    $recorded = 0
    foreach ($iid in $successfulInvocations.Keys) {
        if ($outcomes.ContainsKey($iid)) { $recorded++ }
    }

    $rotation = [ordered]@{}
    $rotationIds = @{}
    foreach ($model in @($registry.models)) {
        $invBlock = Get-OrchestraProperty $model 'invoke' $null
        if ([bool](Get-OrchestraProperty $invBlock 'account_rotation' $false)) {
            $rotationIds[[string]$model.id] = $true
        }
    }
    foreach ($entry in $invocations.Values) {
        $ev = $entry.event
        $mId = [string](Get-OrchestraProperty $ev 'model' '')
        $attemptsVal = [int](Get-OrchestraProperty $ev 'attempts' 1)
        if (-not [string]::IsNullOrWhiteSpace($mId) -and (
            [bool](Get-OrchestraProperty $ev 'account_switched' $false) -or $attemptsVal -gt 1
        )) {
            $rotationIds[$mId] = $true
        }
    }
    foreach ($id in @($rotationIds.Keys | Sort-Object)) {
        $rows = @($invocations.Values | Where-Object { [string](Get-OrchestraProperty $_.event 'model' '') -eq $id })
        $switched = @($rows | Where-Object { [bool](Get-OrchestraProperty $_.event 'account_switched' $false) }).Count
        $exhausted = @($rows | Where-Object { [bool](Get-OrchestraProperty $_.event 'quota_error' $false) }).Count
        $switchRate = 0.0
        $poolRate = 0.0
        if ($rows.Count -gt 0) {
            $switchRate = [Math]::Round(($switched / [double]$rows.Count), 4)
            $poolRate = [Math]::Round(($exhausted / [double]$rows.Count), 4)
        }
        $rotation[$id] = [pscustomobject]@{
            invocations = [int]$rows.Count
            switched_count = [int]$switched
            switch_rate = [double]$switchRate
            quota_exhausted_count = [int]$exhausted
            pool_exhaustion_rate = [double]$poolRate
        }
    }

    $candidates = New-Object 'System.Collections.Generic.List[object]'
    $registryTags = Get-OrchestraProperty $registry 'tags' $null
    $allTagNames = @(Get-OrchestraNames $registryTags)

    foreach ($model in $active) {
        $id = [string]$model.id
        foreach ($dim in @($registry.cap_dimensions)) {
            $cap = Get-OrchestraProperty $model.caps $dim $null
            if ($null -eq $cap) { continue }
            $dimTags = @(
                foreach ($tag in $allTagNames) {
                    $definition = Get-OrchestraProperty $registryTags $tag $null
                    if (@(Get-OrchestraArray $definition 'caps') -contains $dim) { [string]$tag }
                }
            )
            if ($dimTags.Count -eq 0) { continue }

            $stats = Get-OutcomeStats -Events $events -ModelId $id -Tags $dimTags -WindowDays $WindowDays
            if ([int]$stats.n -lt $minSamples -or [int]$stats.n -le 0) { continue }

            $badRate = ([int]$stats.redo + [int]$stats.fail) / [double]$stats.n
            $okRate = [int]$stats.ok / [double]$stats.n
            $curScore = [double](Get-OrchestraProperty $cap 'score' 0)
            $isLocked = [bool](Get-OrchestraProperty $cap 'locked' $false)
            $newScore = $null
            $direction = ''

            if ($badRate -ge $badThreshold -and $curScore -ge 7.5) {
                $newScore = [Math]::Max(5.0, [Math]::Round($curScore - 1.0, 1))
                $direction = 'downward'
            }
            elseif (-not $isLocked -and [int]$stats.n -ge [Math]::Max(8, $minSamples) -and $okRate -ge 0.90 -and $curScore -lt 9.0 -and $curScore -gt 0) {
                $newScore = [Math]::Min(9.5, [Math]::Round($curScore + 0.5, 1))
                $direction = 'upward'
            }
            if ($null -eq $newScore -or [Math]::Abs($newScore - $curScore) -lt 0.1) { continue }

            $claimText = "Telemetry ($direction, ${WindowDays}d): n=$($stats.n), ok=$($stats.ok), redo=$($stats.redo), fail=$($stats.fail) -> $curScore to $newScore."
            $evidence = @([pscustomobject]@{
                url = "telemetry://usage/$id/$dim"
                claim = $claimText
                date = $now.ToString('yyyy-MM-dd')
            })
            $patch = @(
                (New-Patch "models[id=$id].caps.$dim.score" $curScore $newScore),
                (New-Patch "models[id=$id].caps.$dim.source" (Get-OrchestraProperty $cap 'source' $null) 'telemetry'),
                (New-Patch "models[id=$id].caps.$dim.confidence" (Get-OrchestraProperty $cap 'confidence' $null) 0.7),
                (New-Patch "models[id=$id].caps.$dim.evidence" (Get-OrchestraProperty $cap 'evidence' $null) $evidence)
            )
            [void]$candidates.Add([pscustomobject]@{
                kind = 'cap'
                model_id = $id
                dimension = [string]$dim
                direction = $direction
                expected_score = $curScore
                slug = "telemetry-$dim"
                reason = $claimText
                patch = $patch
            })
        }
    }

    # Speed rank inversion check: higher speed_rank means FASTER (shorter duration).
    # If model A is ranked slower than model B (A.speed_rank < B.speed_rank),
    # yet B's median duration is >= 1.5x A's median duration across shared read-only tag buckets,
    # propose swapping their speed_rank values.
    foreach ($a in $active) {
        foreach ($b in $active) {
            if ([int]$a.speed_rank -ge [int]$b.speed_rank) { continue }
            $da = $durations[[string]$a.id]
            $db = $durations[[string]$b.id]
            $shared = @($da.Keys | Where-Object { $db.ContainsKey($_) })
            if ($shared.Count -eq 0) { continue }
            $durA = [double[]]@(foreach ($key in $shared) { $da[$key].ToArray() })
            $durB = [double[]]@(foreach ($key in $shared) { $db[$key].ToArray() })
            if ($durA.Count -lt $minSamples -or $durB.Count -lt $minSamples) { continue }

            $medA = [Math]::Round((Get-Median -Values $durA), 3)
            $medB = [Math]::Round((Get-Median -Values $durB), 3)
            if (($medA * 1.5) -gt $medB) { continue }

            $reasonText = "Telemetry speed_rank inversion (${WindowDays}d): $($a.id) (speed_rank=$($a.speed_rank), median=${medA}s) was >=1.5x faster than $($b.id) (speed_rank=$($b.speed_rank), median=${medB}s) across shared read-only tag buckets."
            $patch = @(
                (New-Patch "models[id=$($a.id)].speed_rank" ([int]$a.speed_rank) ([int]$b.speed_rank)),
                (New-Patch "models[id=$($b.id)].speed_rank" ([int]$b.speed_rank) ([int]$a.speed_rank))
            )
            [void]$candidates.Add([pscustomobject]@{
                kind = 'speed_rank'
                model_id = [string]$a.id
                partner_id = [string]$b.id
                expected_a_rank = [int]$a.speed_rank
                expected_b_rank = [int]$b.speed_rank
                dimension = $null
                slug = "telemetry-speed-rank-$($b.id)"
                reason = $reasonText
                patch = $patch
            })
        }
    }

    $createdPaths = New-Object 'System.Collections.Generic.List[string]'
    $script:skippedConflicts = 0

    if (-not $DryRun -and $candidates.Count -gt 0) {
        Invoke-WithLock -Paths $paths -Name registry -ScriptBlock {
            $freshReg = Read-Registry -Paths $paths
            $baseRev = [long](Get-OrchestraProperty $freshReg 'registry_rev' 0)
            [void][IO.Directory]::CreateDirectory($paths.Proposals)

            foreach ($candidate in $candidates.ToArray()) {
                $modelId = [string]$candidate.model_id
                $patchPaths = [string[]]@($candidate.patch | ForEach-Object { [string]$_.path })
                if (Test-PendingProposalConflict -Paths $paths -ModelId $modelId -PatchPaths $patchPaths) {
                    $script:skippedConflicts++
                    continue
                }

                $freshModel = @($freshReg.models | Where-Object { [string]$_.id -eq $modelId }) | Select-Object -First 1
                if ($null -eq $freshModel) { continue }

                $freshPatch = $null
                if ($candidate.kind -eq 'cap') {
                    $freshCap = Get-OrchestraProperty $freshModel.caps ([string]$candidate.dimension) $null
                    if ($null -eq $freshCap) { continue }
                    $freshScore = [double](Get-OrchestraProperty $freshCap 'score' -1)
                    $freshLocked = [bool](Get-OrchestraProperty $freshCap 'locked' $false)
                    if (
                        [Math]::Abs($freshScore - [double]$candidate.expected_score) -gt 0.0001 -or
                        ([string]$candidate.direction -eq 'upward' -and $freshLocked)
                    ) {
                        $script:skippedConflicts++
                        continue
                    }
                    $freshPatch = @(
                        foreach ($op in $candidate.patch) {
                            $field = $op.path.Substring($op.path.LastIndexOf('.') + 1)
                            New-Patch $op.path (Get-OrchestraProperty $freshCap $field $null) $op.value
                        }
                    )
                }
                else {
                    $partnerId = [string]$candidate.partner_id
                    $partnerModel = @($freshReg.models | Where-Object { [string]$_.id -eq $partnerId }) | Select-Object -First 1
                    if ($null -eq $partnerModel) { continue }
                    if (
                        [int]$freshModel.speed_rank -ne [int]$candidate.expected_a_rank -or
                        [int]$partnerModel.speed_rank -ne [int]$candidate.expected_b_rank
                    ) {
                        $script:skippedConflicts++
                        continue
                    }
                    $freshPatch = @(
                        (New-Patch "models[id=$modelId].speed_rank" ([int]$freshModel.speed_rank) ([int]$partnerModel.speed_rank)),
                        (New-Patch "models[id=$partnerId].speed_rank" ([int]$partnerModel.speed_rank) ([int]$freshModel.speed_rank))
                    )
                }

                $stamp = (Get-OrchestraNow).ToString('yyyyMMdd-HHmmss')
                $shortGuid = [Guid]::NewGuid().ToString('N').Substring(0, 6)
                $propId = "$stamp-$modelId-$($candidate.slug)-$shortGuid"
                $proposal = [ordered]@{
                    proposal_id = $propId
                    model_id = $modelId
                    base_rev = $baseRev
                    created_at = (Get-OrchestraNow).ToString('o')
                    status = 'pending'
                    source = 'telemetry'
                    reason = [string]$candidate.reason
                    patch = $freshPatch
                }
                $jsonPath = Join-Path $paths.Proposals ($propId + '.json')
                $mdPath = Join-Path $paths.Proposals ($propId + '.md')
                Write-JsonAtomic -Path $jsonPath -Object $proposal
                $mdText = @(
                    ("# Proposal: " + $modelId)
                    ''
                    ("Base revision: " + $baseRev)
                    ''
                    [string]$candidate.reason
                    ''
                    'Approval preserves cap locks. Set unlock:true only for a permanent cap unlock.'
                    ''
                    '```json'
                    (ConvertTo-Json -InputObject $freshPatch -Depth 32)
                    '```'
                    ''
                ) -join "`n"
                [IO.File]::WriteAllText($mdPath, $mdText, $script:OrchestraUtf8)
                [void]$createdPaths.Add($jsonPath)
            }
        }
    }

    $coverage = if ($successfulInvocations.Count -gt 0) {
        [Math]::Round(($recorded / [double]$successfulInvocations.Count), 4)
    }
    else {
        1.0
    }

    Write-OrchestraResult -Object ([ordered]@{
        dry_run = [bool]$DryRun
        window_days = [int]$WindowDays
        total_invocations = [int]$invocations.Count
        successful_invocations = [int]$successfulInvocations.Count
        recorded_outcomes = [int]$recorded
        outcome_coverage_rate = [double]$coverage
        rotation_stats = [pscustomobject]$rotation
        proposals_created = [string[]]$createdPaths.ToArray()
        proposed_preview = $candidates.ToArray()
        skipped_conflicts = [int]$script:skippedConflicts
    })
    exit 0
}
catch {
    $message = $_.Exception.Message
    $code = Get-OrchestraExitCode -Message $message
    [Console]::Error.WriteLine($message)
    Write-OrchestraResult -Object @{
        error = $message
        proposals_created = @()
        exit = $code
    }
    exit $code
}
