<#
.SYNOPSIS
Applies bounded research updates and manages review proposals.
.DESCRIPTION
Lock order is registry, then state. Usage history is never rewritten.
Disputed capabilities remain frozen until explicit approval.
ApproveAll takes a model id or alias and processes its pending proposals
in filename order while holding one registry lock.
Conflicting proposals remain pending; unrelated proposals continue.
A batch with rejected proposals exits 2 and reports rejected_proposals.
DryRun does not create locks, leases, backups, or proposals.
#>
[CmdletBinding(DefaultParameterSetName = 'Research')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Research')]
    [string]$ResearchFile,

    [Parameter(ParameterSetName = 'Research')]
    [string]$CrossCheckFile,

    [Parameter(Mandatory = $true, ParameterSetName = 'Approve')]
    [string]$Approve,

    [Parameter(Mandatory = $true, ParameterSetName = 'ApproveAll')]
    [string]$ApproveAll,

    [Parameter(Mandatory = $true, ParameterSetName = 'Rollback')]
    [string]$Rollback,

    [Parameter(Mandatory = $true, ParameterSetName = 'List')]
    [switch]$ListProposals,

    [Parameter(ParameterSetName = 'Approve')]
    [Parameter(ParameterSetName = 'ApproveAll')]
    [Parameter(ParameterSetName = 'Rollback')]
    [switch]$Force,

    [switch]$DryRun,

    [string]$RegistryPath,
    [string]$StateDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false

. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Get-V {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return ,$Default }
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return ,$Object[$Name] }
    }
    else {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { return ,$property.Value }
    }
    return ,$Default
}

function Get-A {
    param($Object, [string]$Name)
    $value = Get-V $Object $Name @()
    foreach ($item in $value) {
        if ($null -ne $item) { $item }
    }
}

function Get-Keys {
    param($Object)
    if ($Object -is [Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { [string]$key }
    }
    elseif ($null -ne $Object) {
        foreach ($property in $Object.PSObject.Properties) { $property.Name }
    }
}

function Set-V {
    param($Object, [string]$Name, $Value)
    if ($Object -is [Collections.IDictionary]) {
        $Object[$Name] = $Value
    }
    else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
    }
}

function Remove-V {
    param($Object, [string]$Name)
    if ($Object -is [Collections.IDictionary]) {
        [void]$Object.Remove($Name)
    }
    else {
        [void]$Object.PSObject.Properties.Remove($Name)
    }
}

function Copy-Json {
    param($Object)
    return ($Object | ConvertTo-Json -Depth 32 | ConvertFrom-Json)
}

function Test-Number {
    param($Value)
    return (
        $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or
        $Value -is [decimal]
    )
}

function Test-Same {
    param($Left, $Right)

    if ($null -eq $Left -or $null -eq $Right) {
        return ($null -eq $Left -and $null -eq $Right)
    }

    if ((Test-Number $Left) -and (Test-Number $Right)) {
        return ([decimal]$Left -eq [decimal]$Right)
    }

    $leftObject = (
        $Left -is [Collections.IDictionary] -or
        $Left -is [pscustomobject]
    )
    $rightObject = (
        $Right -is [Collections.IDictionary] -or
        $Right -is [pscustomobject]
    )
    if ($leftObject -or $rightObject) {
        if (-not ($leftObject -and $rightObject)) { return $false }
        $leftKeys = @(Get-Keys $Left | Sort-Object -CaseSensitive)
        $rightKeys = @(Get-Keys $Right | Sort-Object -CaseSensitive)
        if ($leftKeys.Count -ne $rightKeys.Count) { return $false }
        for ($i = 0; $i -lt $leftKeys.Count; $i++) {
            if ($leftKeys[$i] -cne $rightKeys[$i]) { return $false }
            if (-not (Test-Same (Get-V $Left $leftKeys[$i]) (Get-V $Right $rightKeys[$i]))) {
                return $false
            }
        }
        return $true
    }

    if ($Left -is [array] -or $Right -is [array]) {
        if (-not ($Left -is [array] -and $Right -is [array])) {
            return $false
        }
        if ($Left.Count -ne $Right.Count) { return $false }
        for ($i = 0; $i -lt $Left.Count; $i++) {
            if (-not (Test-Same $Left[$i] $Right[$i])) { return $false }
        }
        return $true
    }

    if ($Left.GetType() -ne $Right.GetType()) { return $false }
    return ($Left -ceq $Right)
}

function Fail-Args {
    param([string]$Message)
    throw ('ORCHESTRA_ARGS: ' + $Message)
}

function Assert-Schema {
    param($Value, $Schema, $Document, [string]$At = '$')

    $reference = Get-V $Schema '$ref'
    if ($null -ne $reference) {
        if ($reference -notmatch '^#/definitions/([A-Za-z0-9_-]+)$') {
            Fail-Args ('Unsupported schema reference at ' + $At)
        }
        $definition = Get-V (Get-V $Document 'definitions') $Matches[1]
        if ($null -eq $definition) { Fail-Args 'Missing schema definition.' }
        Assert-Schema $Value $definition $Document $At
        return
    }

    $alternatives = @(Get-A $Schema 'anyOf')
    if ($alternatives.Count -gt 0) {
        foreach ($alternative in $alternatives) {
            try {
                Assert-Schema $Value $alternative $Document $At
                return
            }
            catch {
                if ($_.Exception.Message -notmatch '^ORCHESTRA_ARGS:') { throw }
            }
        }
        Fail-Args ('No schema alternative matches ' + $At)
    }

    $types = @(Get-A $Schema 'type')
    $validType = ($types.Count -eq 0)
    foreach ($type in $types) {
        switch ($type) {
            'null' { if ($null -eq $Value) { $validType = $true } }
            'object' {
                if ($Value -is [pscustomobject] -or $Value -is [Collections.IDictionary]) {
                    $validType = $true
                }
            }
            'array' { if ($Value -is [array]) { $validType = $true } }
            'string' { if ($Value -is [string]) { $validType = $true } }
            'boolean' { if ($Value -is [bool]) { $validType = $true } }
            'number' { if (Test-Number $Value) { $validType = $true } }
            'integer' {
                if ((Test-Number $Value) -and [math]::Floor([double]$Value) -eq $Value) {
                    $validType = $true
                }
            }
            default { Fail-Args ('Unsupported schema type: ' + $type) }
        }
    }
    if (-not $validType) { Fail-Args ('Wrong JSON type at ' + $At) }

    $enum = @(Get-A $Schema 'enum')
    if ($enum.Count -gt 0) {
        $matched = $false
        foreach ($option in $enum) {
            if (Test-Same $Value $option) { $matched = $true }
        }
        if (-not $matched) { Fail-Args ('Invalid enum at ' + $At) }
    }

    if ($null -eq $Value) { return }

    if ($Value -is [pscustomobject] -or $Value -is [Collections.IDictionary]) {
        $keys = @(Get-Keys $Value)
        foreach ($required in (Get-A $Schema 'required')) {
            if ($keys -cnotcontains $required) {
                Fail-Args ('Missing ' + $At + '.' + $required)
            }
        }
        $properties = Get-V $Schema 'properties'
        $propertyNames = @(Get-Keys $properties)
        $additional = Get-V $Schema 'additionalProperties' $true
        foreach ($key in $keys) {
            if ($propertyNames -ccontains $key) {
                Assert-Schema (Get-V $Value $key) (Get-V $properties $key) $Document ($At + '.' + $key)
            }
            elseif ($additional -is [bool]) {
                if (-not $additional) {
                    Fail-Args ('Unexpected property ' + $At + '.' + $key)
                }
            }
            else {
                Assert-Schema (Get-V $Value $key) $additional $Document ($At + '.' + $key)
            }
        }
    }
    elseif ($Value -is [array]) {
        $minimum = Get-V $Schema 'minItems'
        if ($null -ne $minimum -and $Value.Count -lt $minimum) {
            Fail-Args ('Too few items at ' + $At)
        }
        $items = Get-V $Schema 'items'
        if ($null -ne $items) {
            for ($i = 0; $i -lt $Value.Count; $i++) {
                Assert-Schema $Value[$i] $items $Document ($At + '[' + $i + ']')
            }
        }
    }
    elseif ($Value -is [string]) {
        $minimum = Get-V $Schema 'minLength'
        if ($null -ne $minimum -and $Value.Length -lt $minimum) {
            Fail-Args ('String too short at ' + $At)
        }
        $pattern = Get-V $Schema 'pattern'
        if ($null -ne $pattern -and -not [regex]::IsMatch($Value, $pattern)) {
            Fail-Args ('Invalid string at ' + $At)
        }
        switch (Get-V $Schema 'format') {
            'date' {
                $date = [datetime]::MinValue
                if (-not [datetime]::TryParseExact(
                    $Value, 'yyyy-MM-dd',
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::None, [ref]$date
                )) {
                    Fail-Args ('Invalid date at ' + $At)
                }
            }
            'uri' {
                $uri = $null
                if (-not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) {
                    Fail-Args ('Invalid URI at ' + $At)
                }
            }
        }
    }
    elseif (Test-Number $Value) {
        $number = [double]$Value
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
            Fail-Args ('Non-finite number at ' + $At)
        }
        $minimum = Get-V $Schema 'minimum'
        $maximum = Get-V $Schema 'maximum'
        if ($null -ne $minimum -and $number -lt $minimum) {
            Fail-Args ('Number below minimum at ' + $At)
        }
        if ($null -ne $maximum -and $number -gt $maximum) {
            Fail-Args ('Number above maximum at ' + $At)
        }
    }
}

function Read-InputJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail-Args ('JSON file not found: ' + $Path)
    }
    try {
        $value = Read-JsonFile -Path $Path
    }
    catch {
        Fail-Args ('Invalid JSON: ' + $Path)
    }
    if ($null -eq $value) { Fail-Args ('Empty JSON: ' + $Path) }
    return $value
}

function Get-Model {
    param($Registry, [string]$Id)
    foreach ($model in (Get-A $Registry 'models')) {
        if ((Get-V $model 'id') -ceq $Id) { return $model }
    }
    return $null
}

function Get-PublicEvidence {
    param($Capability)
    foreach ($evidence in (Get-A $Capability 'evidence')) {
        $uri = $null
        $url = [string](Get-V $evidence 'url' '')
        if (
            [uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -and
            $uri.Scheme -in @('http', 'https') -and
            -not [string]::IsNullOrWhiteSpace($uri.Host) -and
            -not [string]::IsNullOrWhiteSpace([string](Get-V $evidence 'claim' ''))
        ) {
            $evidence
        }
    }
}

function Get-Generation {
    param($Model)
    $version = [version]'0.0'
    $text = [string](Get-V $Model 'generation' '0')
    if ($text -notmatch '\.') { $text += '.0' }
    $parsed = $null
    if ([version]::TryParse($text, [ref]$parsed)) { $version = $parsed }
    return $version
}

function Get-EffectiveCaps {
    param($Registry, $Research, [string]$Id, [hashtable]$Disputes = @{})

    $donor = @(
        Get-A $Registry 'models' |
            Where-Object {
                (Get-V $_ 'status') -eq 'active' -and
                (Get-V $_ 'family') -eq (Get-V $Research 'family') -and
                (Get-V $_ 'id') -ne $Id -and
                (Get-Generation $_) -le (Get-Generation $Research)
            } |
            Sort-Object -Property @{
                Expression = { Get-Generation $_ }
                Descending = $true
            }, id
    ) | Select-Object -First 1

    $result = [pscustomobject]@{}
    foreach ($dimension in (Get-A $Registry 'cap_dimensions')) {
        $inputCap = Get-V (Get-V $Research 'caps') $dimension
        $evidence = @()
        if (-not $Disputes.ContainsKey($dimension)) {
            $evidence = @(Get-PublicEvidence $inputCap)
        }
        $score = [double](Get-V $inputCap 'score')
        if ($evidence.Count -gt 0) {
            $cap = [pscustomobject]@{
                score = $score
                source = 'public'
                confidence = [math]::Min(0.8, [double](Get-V $inputCap 'confidence'))
                evidence = $evidence
                supported = $true
            }
        }
        else {
            $donorCap = Get-V (Get-V $donor 'caps') $dimension
            if ($null -ne $donorCap) {
                $score = [math]::Min($score, [double](Get-V $donorCap 'score'))
                $confidence = 0.4
            }
            else {
                $score = [math]::Min($score, 5.0)
                $confidence = 0.2
            }
            $cap = [pscustomobject]@{
                score = $score
                source = 'inherited'
                confidence = $confidence
                evidence = @()
                supported = $false
            }
        }
        Set-V $result $dimension $cap
    }
    return $result
}

function New-SetPatch {
    param([string]$Path, $Old, $Value, [bool]$Unlock = $false)
    return [pscustomobject]@{
        op = 'set'
        path = $Path
        old_value = $Old
        value = $Value
        unlock = $Unlock
    }
}

function New-Proposal {
    param([string]$Id, [string]$Topic, [string]$Reason, [object[]]$Patch)
    $stamp = (Get-OrchestraNow).ToString('yyyyMMdd-HHmmss')
    $name = '{0}-{1}-{2}-{3}' -f $stamp, $Id, $Topic, [guid]::NewGuid().ToString('N').Substring(0, 4)
    return [pscustomobject]@{
        proposal_id = $name
        model_id = $Id
        base_rev = 0
        created_at = (Get-OrchestraNow).ToString('o')
        status = 'pending'
        reason = $Reason
        patch = $Patch
    }
}

function Get-AgyEfforts {
    param($State, [string]$Id)
    $source = Get-V (Get-V $State 'sources') 'agy'
    $found = @{}
    foreach ($slug in (Get-A $source 'raw_slugs')) {
        if ($slug -isnot [string]) { continue }
        if ((ConvertTo-BaseSlug -Slug $slug) -cne $Id) { continue }
        if ($slug -cmatch '-(low|medium|high|xhigh|max)$') {
            $found[$Matches[1]] = $true
        }
    }
    if ($found.Count -eq 0) {
        'low'
        'medium'
        'high'
        return
    }
    foreach ($effort in @('low', 'medium', 'high', 'xhigh', 'max')) {
        if ($found.ContainsKey($effort)) { $effort }
    }
}

function New-DisputedProposal {
    param([string]$Id, [string]$Dimension, $Cap, $Desired, $Dispute)
    $selected = Get-V $Dispute 'suggested_score'
    if ($null -eq $selected) { $selected = Get-V $Dispute 'research_score' }
    $patch = @(
        New-SetPatch "models[id=$Id].caps.$Dimension.score" (Get-V $Cap 'score') $selected
        New-SetPatch "models[id=$Id].caps.$Dimension.source" (Get-V $Cap 'source') $Desired.source
        New-SetPatch "models[id=$Id].caps.$Dimension.confidence" (Get-V $Cap 'confidence') ([math]::Min(0.6, [double]$Desired.confidence))
        New-SetPatch "models[id=$Id].caps.$Dimension.evidence" (Get-V $Cap 'evidence') $Desired.evidence
    )
    $proposal = New-Proposal $Id ('disputed-' + $Dimension) 'Disputed capability is frozen until explicit approval. Review research_score, suggested_score, and reason.' $patch
    Set-V $proposal 'cross_check' $Dispute
    return $proposal
}

function Get-ResearchPlan {
    param($Paths, $Registry, $Research, $State, [hashtable]$Disputes = @{})

    $working = Copy-Json $Registry
    $id = [string](Get-V $Research 'model_id')
    $model = Get-Model $working $id
    $existing = $null -ne $model
    $effective = Get-EffectiveCaps $Registry $Research $id $Disputes
    $dimensions = @(Get-A $Registry 'cap_dimensions')
    $confidence = 0.0
    foreach ($dimension in $dimensions) {
        $confidence += [double](Get-V (Get-V $effective $dimension) 'confidence')
    }
    if ($dimensions.Count -eq 0) { Fail-Args 'Registry has no cap dimensions.' }
    $confidence /= $dimensions.Count

    $policy = Get-V $Registry 'policy'
    $auto = New-Object 'System.Collections.Generic.List[object]'
    $proposals = New-Object 'System.Collections.Generic.List[object]'
    $rejected = $confidence -lt [double](Get-V $policy 'reject_below_confidence' 0.4)

    if ($rejected) {
        return [pscustomobject]@{
            registry = $working
            model_id = $id
            confidence = $confidence
            rejected = $true
            auto = @()
            proposals = @()
        }
    }

    if (-not $existing) {
        $generation = [string](Get-V $Research 'generation' '')
        if ([string]::IsNullOrWhiteSpace($generation)) {
            $match = [regex]::Match($id, '[0-9]+(?:\.[0-9]+)*')
            if ($match.Success) { $generation = $match.Value }
            else { $generation = '0' }
        }

        $channel = [string](Get-V $Research 'channel')
        $configuredEffort = [string](Get-V $policy 'default_effort' 'high')
        if ([string]::IsNullOrWhiteSpace($configuredEffort)) { $configuredEffort = 'high' }
        $modelFlag = $id
        $defaultEffort = $configuredEffort
        $efforts = @('low', 'medium', 'high', 'xhigh')
        $tools = @()
        if ($channel -eq 'agy') {
            $modelFlag = $id + '-{effort}'
            $efforts = @(Get-AgyEfforts $State $id)
            if ($efforts -notcontains $defaultEffort) {
                $defaultEffort = $efforts[$efforts.Count - 1]
            }
            $tools = @('web_search', 'browser')
        }
        elseif ($efforts -notcontains $defaultEffort) {
            $defaultEffort = 'high'
        }

        $invokeObject = [pscustomobject]@{
            model_flag = $modelFlag
            default_effort = $defaultEffort
            efforts = $efforts
        }
        if ($channel -eq 'codex') {
            $rotationDonor = @(
                Get-A $Registry 'models' |
                    Where-Object {
                        (Get-V $_ 'status') -eq 'active' -and
                        (Get-V $_ 'channel') -eq 'codex' -and
                        [bool](Get-V (Get-V $_ 'invoke') 'account_rotation' $false)
                    } |
                    Sort-Object -Property @{
                        Expression = { if ((Get-V $_ 'family') -eq (Get-V $Research 'family')) { 0 } else { 1 } }
                    }, @{
                        Expression = { Get-Generation $_ }
                        Descending = $true
                    }, id
            ) | Select-Object -First 1
            if ($null -ne $rotationDonor) {
                $donorInvoke = Get-V $rotationDonor 'invoke'
                Set-V $invokeObject 'account_rotation' $true
                foreach ($rotProp in @('rotation_max_retries', 'rotation_wait_sec', 'exhausted_minutes')) {
                    $rotVal = Get-V $donorInvoke $rotProp
                    if ($null -ne $rotVal) {
                        Set-V $invokeObject $rotProp $rotVal
                    }
                }
            }
        }

        $caps = [pscustomobject]@{}
        foreach ($dimension in $dimensions) {
            $cap = Get-V $effective $dimension
            Set-V $caps $dimension ([pscustomobject]@{
                score = $cap.score
                approved_score = $cap.score
                source = $cap.source
                locked = $false
                confidence = $cap.confidence
                evidence = $cap.evidence
            })
        }

        $model = [pscustomobject]@{
            id = $id
            display_name = $id
            vendor = Get-V $Research 'vendor'
            family = Get-V $Research 'family'
            generation = $generation
            tier = Get-V $Research 'tier'
            status = 'candidate'
            channel = $channel
            invoke = $invokeObject
            tools = $tools
            quota_rank = Get-V $Research 'quota_rank_hint'
            speed_rank = Get-V $Research 'speed_rank_hint'
            ranks_locked = $false
            escalation_only = $false
            escalate_to = $null
            fallback = @()
            caps = $caps
            strengths = @(Get-A $Research 'notable_strengths')
            weaknesses = @(Get-A $Research 'notable_weaknesses')
            last_researched = (Get-OrchestraNow).ToString('yyyy-MM-dd')
            evidence = @()
        }
        Set-V $working 'models' (@(Get-A $working 'models') + @($model))
        [void]$auto.Add([pscustomobject]@{ op = 'add_model'; model = $id })
    }
    else {
        if (
            (Get-V $model 'family') -cne (Get-V $Research 'family') -or
            (Get-V $model 'vendor') -cne (Get-V $Research 'vendor') -or
            (Get-V $model 'channel') -cne (Get-V $Research 'channel')
        ) {
            Fail-Args 'Refresh cannot change model identity, vendor, family, or channel.'
        }

        $limit = [double](Get-V $policy 'auto_apply_max_delta' 2)
        foreach ($dimension in $dimensions) {
            $cap = Get-V (Get-V $model 'caps') $dimension
            if ($null -eq $cap) {
                Fail-Args ('Existing model is missing cap: ' + $dimension)
            }

            # Freeze the entire existing capability while cross-check is disputed.
            if ($Disputes.ContainsKey($dimension)) { continue }
            $incoming = Get-V $effective $dimension
            if (-not $incoming.supported) { continue }

            $oldScore = [double](Get-V $cap 'score')
            $anchor = Get-V $cap 'approved_score'
            $locked = [bool](Get-V $cap 'locked' $false)
            if ($null -eq $anchor -and -not $locked) {
                Set-V $cap 'approved_score' $oldScore
                $anchor = $oldScore
                [void]$auto.Add((New-SetPatch "models[id=$id].caps.$dimension.approved_score" $null $oldScore))
            }

            if ($null -eq $anchor) { $anchor = $oldScore }
            $delta = [math]::Abs([double]$incoming.score - [double]$anchor)
            if ($locked -or $delta -gt $limit) {
                if ($oldScore -ne $incoming.score) {
                    $patch = @(
                        New-SetPatch "models[id=$id].caps.$dimension.score" $oldScore $incoming.score
                        New-SetPatch "models[id=$id].caps.$dimension.source" (Get-V $cap 'source') $incoming.source
                        New-SetPatch "models[id=$id].caps.$dimension.confidence" (Get-V $cap 'confidence') $incoming.confidence
                        # Preserve null for an absent field; do not invent an empty array.
                        New-SetPatch "models[id=$id].caps.$dimension.evidence" (Get-V $cap 'evidence') $incoming.evidence
                    )
                    $reason = 'Score exceeds the approved-score drift limit.'
                    if ($locked) {
                        $reason = 'Approval changes this locked capability once. Only unlock:true permanently unlocks it.'
                    }
                    [void]$proposals.Add((New-Proposal $id $dimension $reason $patch))
                }
                continue
            }

            foreach ($field in @('score', 'source', 'confidence', 'evidence')) {
                $old = Get-V $cap $field
                $new = Get-V $incoming $field
                if (-not (Test-Same $old $new)) {
                    Set-V $cap $field $new
                    [void]$auto.Add((New-SetPatch "models[id=$id].caps.$dimension.$field" $old $new))
                }
            }
        }

        foreach ($rank in @('speed_rank', 'quota_rank')) {
            $old = Get-V $model $rank
            $new = Get-V $Research ($rank + '_hint')
            if (-not (Test-Same $old $new)) {
                $patch = New-SetPatch "models[id=$id].$rank" $old $new
                if ([bool](Get-V $model 'ranks_locked' $false)) {
                    [void]$proposals.Add((New-Proposal $id $rank 'Ranks are locked; explicit approval is required.' @($patch)))
                }
                else {
                    Set-V $model $rank $new
                    [void]$auto.Add($patch)
                }
            }
        }

        foreach ($mapping in @(
            @('strengths', 'notable_strengths'),
            @('weaknesses', 'notable_weaknesses')
        )) {
            $new = @(Get-A $Research $mapping[1])
            $old = Get-V $model $mapping[0] @()
            if (-not (Test-Same $old $new)) {
                Set-V $model $mapping[0] $new
                [void]$auto.Add((New-SetPatch "models[id=$id].$($mapping[0])" $old $new))
            }
        }
        $oldDate = Get-V $model 'last_researched'
        $today = (Get-OrchestraNow).ToString('yyyy-MM-dd')
        Set-V $model 'last_researched' $today
        [void]$auto.Add((New-SetPatch "models[id=$id].last_researched" $oldDate $today))
    }

    # New models keep inherited caps; refreshes keep their original caps.
    # Proposals carry the original research and the cross-check recommendation.
    if ($Disputes.Count -gt 0) {
        $desiredCaps = Get-EffectiveCaps $Registry $Research $id
        foreach ($dimension in $dimensions) {
            if (-not $Disputes.ContainsKey($dimension)) { continue }
            $currentCap = Get-V (Get-V $model 'caps') $dimension
            $desiredCap = Get-V $desiredCaps $dimension
            [void]$proposals.Add((New-DisputedProposal $id $dimension $currentCap $desiredCap $Disputes[$dimension]))
        }
    }

    $allEvidence = New-Object 'System.Collections.Generic.List[object]'
    foreach ($dimension in $dimensions) {
        foreach ($evidence in (Get-A (Get-V (Get-V $model 'caps') $dimension) 'evidence')) {
            [void]$allEvidence.Add($evidence)
        }
    }
    Set-V $model 'evidence' $allEvidence.ToArray()

    $aliasCaps = @{
        'best-rigor' = 'code_rigor'
        'best-math' = 'math'
        'best-image' = 'image_gen'
        'best-prose' = 'prose'
        'best-knowledge' = 'world_knowledge'
        'best-aesthetic' = 'frontend_aesthetic'
    }
    foreach ($alias in @($aliasCaps.Keys | Sort-Object)) {
        $dimension = $aliasCaps[$alias]
        if ($Disputes.ContainsKey($dimension)) { continue }
        $incoming = Get-V $effective $dimension
        $researchCap = Get-V (Get-V $Research 'caps') $dimension
        $incumbentId = Get-V (Get-V $Registry 'aliases') $alias
        $incumbent = Get-Model $Registry $incumbentId
        if ($incumbentId -eq $id -or $null -eq $incumbent) { continue }
        $incumbentScore = [double](Get-V (Get-V (Get-V $incumbent 'caps') $dimension) 'score' 0)
        if (
            $incoming.supported -and
            $incoming.confidence -ge 0.6 -and
            [double](Get-V $researchCap 'vs_incumbent') -gt 0 -and
            $incoming.score -ge $incumbentScore
        ) {
            $patch = New-SetPatch "aliases.$alias" $incumbentId $id
            [void]$proposals.Add((New-Proposal $id $alias 'Alias changes require approval.' @($patch)))
        }
    }

    $supersedes = Get-V $Research 'supersedes'
    if ($null -ne $supersedes -and $supersedes -ne $id) {
        $previous = Get-Model $Registry $supersedes
        if ($null -ne $previous -and (Get-V $previous 'status') -eq 'active') {
            $patch = New-SetPatch "models[id=$supersedes].status" 'active' 'legacy'
            [void]$proposals.Add((New-Proposal $id 'supersedes' 'Retiring an active model requires approval.' @($patch)))
        }
    }

    foreach ($rule in (Get-A $Research 'suggested_hard_rules')) {
        $oldRule = $null
        foreach ($current in (Get-A $Registry 'hard_rules')) {
            if ((Get-V $current 'id') -ceq (Get-V $rule 'id')) {
                $oldRule = $current
                break
            }
        }
        if (Test-Same $oldRule $rule) { continue }
        $patch = [pscustomobject]@{
            op = 'add_hard_rule'
            old_value = $oldRule
            value = $rule
            unlock = $false
        }
        [void]$proposals.Add((New-Proposal $id ('rule-' + (Get-V $rule 'id')) 'Hard-rule changes require approval.' @($patch)))
    }

    return [pscustomobject]@{
        registry = $working
        model_id = $id
        confidence = $confidence
        rejected = $false
        auto = $auto.ToArray()
        proposals = $proposals.ToArray()
    }
}

function Save-WithBackup {
    param($Paths, $Registry, [string]$Reason)
    $before = @()
    if (Test-Path -LiteralPath $Paths.History) {
        $before = @(Get-ChildItem -LiteralPath $Paths.History -Filter 'models-*.json' -File | ForEach-Object { $_.Name })
    }
    $oldRev = [long](Get-V $Registry 'registry_rev')
    $null = Save-Registry -Paths $Paths -Registry $Registry -Reason $Reason
    $saved = Read-Registry -Paths $Paths
    if ([long](Get-V $saved 'registry_rev') -ne $oldRev + 1) {
        throw 'Save-Registry violated the registry_rev contract.'
    }
    $created = @(
        Get-ChildItem -LiteralPath $Paths.History -Filter 'models-*.json' -File |
            Where-Object { $before -cnotcontains $_.Name }
    )
    if ($created.Count -ne 1) {
        throw 'Save-Registry did not create exactly one history snapshot.'
    }
    return [pscustomobject]@{
        backup = $created[0].FullName
        rev = [long](Get-V $saved 'registry_rev')
    }
}

function Write-TextAtomic {
    param([string]$Path, [string]$Text)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding $false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Save-Proposal {
    param($Paths, $Proposal)
    $stem = Join-Path $Paths.Proposals $Proposal.proposal_id
    $jsonPath = $stem + '.json'
    Write-JsonAtomic -Path $jsonPath -Object $Proposal
    $markdown = @(
        ('# Proposal: ' + $Proposal.model_id)
        ''
        ('Base revision: ' + $Proposal.base_rev)
        ''
        $Proposal.reason
        ''
        'Approval preserves cap locks. Set unlock:true only for a permanent cap unlock.'
        $(if ($null -ne (Get-V $Proposal 'cross_check')) {
            'Cross-check: ' + (ConvertTo-Json -InputObject $Proposal.cross_check -Depth 32 -Compress)
        })
        ''
        '```json'
        (ConvertTo-Json -InputObject $Proposal.patch -Depth 32)
        '```'
        ''
    ) -join "`n"
    Write-TextAtomic ($stem + '.md') $markdown
    return $jsonPath
}

function Resolve-ProposalPath {
    param($Paths, [string]$InputPath)
    $candidate = $InputPath
    if ([IO.Path]::GetExtension($candidate) -eq '.md') {
        $candidate = [IO.Path]::ChangeExtension($candidate, '.json')
    }
    if (-not [IO.Path]::IsPathRooted($candidate)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $candidate = Join-Path $Paths.Proposals $candidate
        }
    }
    $full = [IO.Path]::GetFullPath($candidate)
    $parent = [IO.Path]::GetFullPath($Paths.Proposals).TrimEnd('\', '/')
    if ([IO.Path]::GetDirectoryName($full).TrimEnd('\', '/') -ne $parent) {
        Fail-Args 'Proposal must be directly inside RegistryDir\proposals.'
    }
    if ($full -match '\.approved\.json$' -or [IO.Path]::GetExtension($full) -ne '.json') {
        Fail-Args 'Expected a pending proposal JSON file.'
    }
    return $full
}

function Get-PatchTarget {
    param($Registry, [string]$Path)

    if ($Path -cmatch '^aliases\.([a-z0-9][a-z0-9.-]*)$') {
        $alias = $Matches[1]
        if (@(Get-Keys (Get-V $Registry 'aliases')) -cnotcontains $alias) {
            Fail-Args ('Unknown alias: ' + $alias)
        }
        return [pscustomobject]@{
            object = Get-V $Registry 'aliases'
            property = $alias
            kind = 'alias'
            model = $null
            cap = $null
        }
    }

    if ($Path -cmatch '^models\[id=([a-z0-9][a-z0-9.-]*)\]\.caps\.([a-z_]+)\.(score|confidence|source|evidence)$') {
        $id = $Matches[1]
        $dimension = $Matches[2]
        $field = $Matches[3]
        if (@(Get-A $Registry 'cap_dimensions') -cnotcontains $dimension) {
            Fail-Args ('Unknown cap: ' + $dimension)
        }
        $model = Get-Model $Registry $id
        $cap = Get-V (Get-V $model 'caps') $dimension
        if ($null -eq $cap) { Fail-Args ('Missing cap target: ' + $Path) }
        return [pscustomobject]@{
            object = $cap
            property = $field
            kind = 'cap'
            model = $model
            cap = $dimension
        }
    }

    if ($Path -cmatch '^models\[id=([a-z0-9][a-z0-9.-]*)\]\.(status|speed_rank|quota_rank)$') {
        $model = Get-Model $Registry $Matches[1]
        $field = $Matches[2]
        if ($null -eq $model) { Fail-Args ('Missing model target: ' + $Path) }
        return [pscustomobject]@{
            object = $model
            property = $field
            kind = 'model'
            model = $model
            cap = $null
        }
    }
    Fail-Args ('Unsupported patch path: ' + $Path)
}

function Assert-PatchValue {
    param($Registry, $Target, $Value)

    switch ($Target.kind) {
        'alias' {
            if ($Value -isnot [string] -or $null -eq (Get-Model $Registry $Value)) {
                Fail-Args 'Alias target is not a registered model.'
            }
        }
        'model' {
            if ($Target.property -eq 'status') {
                if ($Value -isnot [string] -or $Value -cnotin @('active', 'candidate', 'legacy', 'rejected', 'unavailable')) {
                    Fail-Args 'Invalid model status.'
                }
            }
            elseif (
                -not (Test-Number $Value) -or
                $Value -lt 1 -or $Value -gt 3 -or
                [math]::Floor([double]$Value) -ne $Value
            ) {
                Fail-Args 'Invalid rank.'
            }
        }
        'cap' {
            switch ($Target.property) {
                'score' {
                    if (-not (Test-Number $Value) -or $Value -lt 0 -or $Value -gt 10) {
                        Fail-Args 'Invalid cap score.'
                    }
                }
                'confidence' {
                    if (-not (Test-Number $Value) -or $Value -lt 0 -or $Value -gt 0.8) {
                        Fail-Args 'Confidence must be between 0 and 0.8.'
                    }
                }
                'source' {
                    if ($Value -isnot [string] -or $Value -cnotin @('public', 'inherited', 'user', 'probe', 'telemetry')) {
                        Fail-Args 'Invalid cap source.'
                    }
                }
                'evidence' {
                    $evidenceSchema = [pscustomobject]@{
                        type = 'array'
                        items = [pscustomobject]@{ '$ref' = '#/definitions/evidence' }
                    }
                    Assert-Schema $Value $evidenceSchema $script:ResearchSchema '$.patch.evidence'
                    foreach ($evItem in @($Value)) {
                        $evUrl = [string](Get-V $evItem 'url' '')
                        if ($evUrl -ceq 'user') { continue }
                        $parsedUri = $null
                        if (
                            -not [uri]::TryCreate($evUrl, [UriKind]::Absolute, [ref]$parsedUri) -or
                            $parsedUri.Scheme -notin @('http', 'https', 'probe', 'telemetry')
                        ) {
                            Fail-Args ('Invalid evidence URI scheme at $.patch.evidence: ' + $evUrl)
                        }
                    }
                }
            }
        }
    }
}

function Apply-Proposal {
    param($Registry, $Proposal, [bool]$ForceApproval)

    if ((Get-V $Proposal 'status') -ne 'pending') {
        Fail-Args 'Proposal is not pending.'
    }
    $base = Get-V $Proposal 'base_rev'
    if (-not (Test-Number $base) -or [math]::Floor([double]$base) -ne $base) {
        Fail-Args 'Invalid proposal base_rev.'
    }

    # Revisions may differ when all old_value checks below still match.
    $operations = @(Get-A $Proposal 'patch')
    if ($operations.Count -eq 0) { Fail-Args 'Proposal has no operations.' }
    $unlocks = @{}
    $seen = @{}

    foreach ($operation in $operations) {
        if (@(Get-Keys $operation) -cnotcontains 'old_value') {
            Fail-Args 'Every operation must include old_value.'
        }
        $unlock = Get-V $operation 'unlock' $false
        if ($unlock -isnot [bool]) { Fail-Args 'unlock must be a JSON boolean.' }
        $op = Get-V $operation 'op'

        if ($op -eq 'set') {
            $path = [string](Get-V $operation 'path' '')
            if ($seen.ContainsKey($path)) { Fail-Args ('Duplicate patch path: ' + $path) }
            $seen[$path] = $true
            $target = Get-PatchTarget $Registry $path
            Assert-PatchValue $Registry $target (Get-V $operation 'value')
            if (
                -not $ForceApproval -and
                -not (Test-Same (Get-V $target.object $target.property) (Get-V $operation 'old_value'))
            ) {
                Fail-Args ('old_value conflict: ' + $path)
            }
            if ($target.kind -eq 'cap' -and $unlock) {
                $key = (Get-V $target.model 'id') + '/' + $target.cap
                $unlocks[$key] = $true
            }
        }
        elseif ($op -eq 'add_hard_rule') {
            $rule = Get-V $operation 'value'
            $ruleId = Get-V $rule 'id'
            if ($ruleId -isnot [string] -or $ruleId -notmatch '^[a-z0-9][a-z0-9.-]*$') {
                Fail-Args 'Invalid hard-rule id.'
            }
            $ruleKey = 'hard_rules/' + $ruleId
            if ($seen.ContainsKey($ruleKey)) { Fail-Args 'Duplicate hard-rule operation.' }
            $seen[$ruleKey] = $true
            $old = $null
            foreach ($item in (Get-A $Registry 'hard_rules')) {
                if ((Get-V $item 'id') -ceq $ruleId) { $old = $item; break }
            }
            if (-not $ForceApproval -and -not (Test-Same $old (Get-V $operation 'old_value'))) {
                Fail-Args ('old_value conflict for rule: ' + $ruleId)
            }
            if ([bool](Get-V $old 'locked' $false) -and -not $unlock) {
                Fail-Args ('Locked rule requires unlock:true: ' + $ruleId)
            }
        }
        else {
            Fail-Args 'Unsupported proposal operation.'
        }
    }

    # All operations were checked before modifying the cloned registry.
    $working = Copy-Json $Registry
    foreach ($operation in $operations) {
        if ((Get-V $operation 'op') -eq 'set') {
            $target = Get-PatchTarget $working (Get-V $operation 'path')
            $value = Get-V $operation 'value'
            Set-V $target.object $target.property $value
            if ($target.kind -eq 'cap') {
                $key = (Get-V $target.model 'id') + '/' + $target.cap
                if ($unlocks.ContainsKey($key)) {
                    Set-V $target.object 'locked' $false
                }
                if ($target.property -eq 'score') {
                    Set-V $target.object 'approved_score' $value
                }
            }
        }
        else {
            $rule = Copy-Json (Get-V $operation 'value')
            if ([bool](Get-V $operation 'unlock' $false)) {
                Set-V $rule 'locked' $false
            }
            $ruleId = Get-V $rule 'id'
            $others = @(
                Get-A $working 'hard_rules' |
                    Where-Object { (Get-V $_ 'id') -cne $ruleId }
            )
            Set-V $working 'hard_rules' ($others + @($rule))
        }
    }
    return $working
}

function Invoke-ApproveOne {
    param($Paths, $Registry, [string]$ProposalPath, [bool]$ForceApproval, [bool]$Preview)

    $archive = [IO.Path]::ChangeExtension($ProposalPath, 'approved.json')
    if (Test-Path -LiteralPath $archive) {
        Fail-Args 'Proposal already has an approved archive.'
    }
    $proposal = Read-InputJson $ProposalPath
    $updated = Apply-Proposal $Registry $proposal $ForceApproval
    $originalBase = [long](Get-V $proposal 'base_rev')
    $currentRev = [long](Get-V $Registry 'registry_rev')
    $rebased = $originalBase -ne $currentRev
    $backup = $null

    if ($Preview) {
        Set-V $updated 'registry_rev' ($currentRev + 1)
    }
    else {
        $commit = Save-WithBackup $Paths $updated ('Approved proposal: ' + $proposal.proposal_id)
        $backup = $commit.backup
        Set-V $proposal 'original_base_rev' $originalBase
        Set-V $proposal 'base_rev' $currentRev
        Set-V $proposal 'rebased' $rebased
        Set-V $proposal 'status' 'approved'
        Set-V $proposal 'approved_at' ((Get-OrchestraNow).ToString('o'))
        Set-V $proposal 'applied_rev' $commit.rev
        Set-V $proposal 'forced' $ForceApproval
        Write-JsonAtomic -Path $archive -Object $proposal
        Remove-Item -LiteralPath $ProposalPath -Force
        $null = Add-ChangelogEntry -Paths $Paths -Title ('Approved: ' + $proposal.proposal_id) -Lines @(
            ('Registry revision: ' + $commit.rev)
            ('Rebased: ' + $rebased)
            ('Forced: ' + $ForceApproval)
            ('Backup: ' + $backup)
        )
    }

    return [pscustomobject]@{
        registry = $updated
        result = [ordered]@{
            dry_run = $Preview
            auto_applied = @(Get-A $proposal 'patch')
            proposals = @()
            rejected = $false
            backup = $backup
            registry_rev = Get-V $updated 'registry_rev'
            approved = $(if ($Preview) { $null } else { $archive })
            proposal = $ProposalPath
            original_base_rev = $originalBase
            base_rev = $currentRev
            rebased = $rebased
        }
    }
}

function Invoke-ApprovalAction {
    param(
        $Paths,
        $Registry,
        [string]$Single,
        [string]$ModelName,
        [bool]$ForceApproval,
        [bool]$Preview
    )

    if (-not [string]::IsNullOrWhiteSpace($Single)) {
        $path = Resolve-ProposalPath $Paths $Single
        $one = Invoke-ApproveOne $Paths $Registry $path $ForceApproval $Preview
        return $one.result
    }

    $id = Resolve-ModelId -Registry $Registry -Name $ModelName
    if ($null -eq $id) {
        Fail-Args 'ApproveAll requires a registered model id or alias.'
    }

    $pending = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path -LiteralPath $Paths.Proposals) {
        foreach ($file in (Get-ChildItem -LiteralPath $Paths.Proposals -Filter '*.json' -File | Sort-Object Name)) {
            if ($file.Name -match '\.approved\.json$') { continue }
            $proposal = Read-InputJson $file.FullName
            if ((Get-V $proposal 'model_id') -ceq $id -and (Get-V $proposal 'status') -eq 'pending') {
                [void]$pending.Add($file.FullName)
            }
        }
    }

    $approvals = New-Object 'System.Collections.Generic.List[object]'
    $failures = New-Object 'System.Collections.Generic.List[object]'
    $changes = New-Object 'System.Collections.Generic.List[object]'
    $working = $Registry
    $lastBackup = $null

    foreach ($path in $pending) {
        # Each proposal is atomic; an argument/conflict error leaves it pending.
        # Continue so unrelated proposals can still be approved in this lock.
        try {
            $one = Invoke-ApproveOne $Paths $working $path $ForceApproval $Preview
        }
        catch {
            if ($_.Exception.Message -notmatch '^ORCHESTRA_ARGS:') { throw }
            [void]$failures.Add([pscustomobject]@{
                proposal = $path
                error = $_.Exception.Message
            })
            continue
        }

        $working = $one.registry
        $lastBackup = $one.result.backup
        [void]$approvals.Add($one.result)
        foreach ($change in $one.result.auto_applied) {
            [void]$changes.Add($change)
        }
    }

    return [ordered]@{
        dry_run = $Preview
        model_id = $id
        auto_applied = $changes.ToArray()
        proposals = @()
        approvals = $approvals.ToArray()
        rejected_proposals = $failures.ToArray()
        rejected = $false
        backup = $lastBackup
        registry_rev = Get-V $working 'registry_rev'
    }
}

function Get-Snapshot {
    param($Paths, [string]$Token)
    if (-not (Test-Path -LiteralPath $Paths.History)) {
        Fail-Args 'History directory not found.'
    }
    $files = @(Get-ChildItem -LiteralPath $Paths.History -Filter 'models-*.json' -File)
    $matches = @()
    if ($Token -match '^[0-9]+$') {
        foreach ($file in $files) {
            $snapshot = Read-InputJson $file.FullName
            if ([long](Get-V $snapshot 'registry_rev') -eq [long]$Token) {
                $matches += $file
            }
        }
    }
    elseif ($Token -match '^[0-9]{8}-[0-9]{6}$') {
        $matches = @($files | Where-Object { $_.Name -like ('models-' + $Token + '-*.json') })
    }
    else {
        $leaf = [IO.Path]::GetFileName($Token)
        if ($Token -ne $leaf -and [IO.Path]::IsPathRooted($Token)) {
            $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Token))
            if ($parent -ne [IO.Path]::GetFullPath($Paths.History).TrimEnd('\', '/')) {
                Fail-Args 'Snapshot is outside the history directory.'
            }
        }
        elseif ($Token -ne $leaf) {
            Fail-Args 'Use a snapshot basename, absolute history path, or revision.'
        }
        $matches = @($files | Where-Object { $_.Name -ceq $leaf })
    }
    if ($matches.Count -ne 1) {
        Fail-Args 'Snapshot selector must match exactly one history file.'
    }
    return $matches[0].FullName
}

function Invoke-Research {
    param($Paths, $Registry, $State, $Research, [hashtable]$Disputes = @{})

    $id = [string](Get-V $Research 'model_id')

    # Prompt and merge normally run in different processes. The state lock
    # serializes the merge; completing it consumes the model's prompt lease.
    $leases = Get-V $State 'research_leases'
    $plan = Get-ResearchPlan $Paths $Registry $Research $State $Disputes

    if ($plan.rejected) {
        $rejected = @(Get-A $State 'rejected_slugs')
        if ($rejected -cnotcontains $id) {
            Set-V $State 'rejected_slugs' ($rejected + @($id))
        }
        Remove-V $leases $id
        $null = Save-State -Paths $Paths -State $State
        $null = Add-ChangelogEntry -Paths $Paths -Title ('Rejected research: ' + $id) -Lines @(
            ('Mean effective confidence: ' + $plan.confidence)
            'Registry model records were not changed.'
        )
        return [ordered]@{
            auto_applied = @()
            proposals = @()
            rejected = $true
            confidence = $plan.confidence
            backup = $null
        }
    }

    $commit = Save-WithBackup $Paths $plan.registry ('Research: ' + $id)
    $proposalPaths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($proposal in $plan.proposals) {
        $patchPaths = @(foreach ($op in @(Get-A $proposal 'patch')) {
            if ((Get-V $op 'op') -eq 'add_hard_rule') {
                'hard_rules/' + [string](Get-V (Get-V $op 'value') 'id')
            }
            else {
                [string](Get-V $op 'path')
            }
        })
        if (Test-PendingProposalConflict -Paths $Paths -ModelId ([string]$proposal.model_id) -PatchPaths $patchPaths) {
            continue
        }
        Set-V $proposal 'base_rev' $commit.rev
        [void]$proposalPaths.Add((Save-Proposal $Paths $proposal))
    }
    Set-V $State 'rejected_slugs' @(
        Get-A $State 'rejected_slugs' | Where-Object { $_ -cne $id }
    )
    Remove-V $leases $id
    $null = Save-State -Paths $Paths -State $State
    $null = Add-ChangelogEntry -Paths $Paths -Title ('Applied research: ' + $id) -Lines @(
        ('Registry revision: ' + $commit.rev)
        ('Automatic changes: ' + @($plan.auto).Count)
        ('Proposals: ' + $proposalPaths.Count)
        ('Backup: ' + $commit.backup)
    )
    return [ordered]@{
        auto_applied = $plan.auto
        proposals = $proposalPaths.ToArray()
        rejected = $false
        confidence = $plan.confidence
        backup = $commit.backup
        registry_rev = $commit.rev
    }
}

try {
    $paths = Get-OrchestraPaths -RegistryPath $RegistryPath -StateDir $StateDir
    $schemaPath = Join-Path $paths.Root 'registry\research.schema.json'
    $script:ResearchSchema = Read-InputJson $schemaPath
    $action = $PSCmdlet.ParameterSetName

    if ($action -eq 'List') {
        $items = @()
        if (Test-Path -LiteralPath $paths.Proposals) {
            $items = @(
                Get-ChildItem -LiteralPath $paths.Proposals -Filter '*.json' -File |
                    Where-Object { $_.Name -notmatch '\.approved\.json$' } |
                    Sort-Object Name |
                    ForEach-Object {
                        $proposal = Read-InputJson $_.FullName
                        [pscustomobject]@{
                            file = $_.FullName
                            model_id = Get-V $proposal 'model_id'
                            base_rev = Get-V $proposal 'base_rev'
                            status = Get-V $proposal 'status'
                            reason = Get-V $proposal 'reason'
                        }
                    }
            )
        }
        Write-OrchestraResult -Object @{ proposals = $items }
        exit 0
    }

    $research = $null
    $disputes = @{}
    if ($action -eq 'Research') {
        $research = Read-InputJson $ResearchFile
        Assert-Schema $research $script:ResearchSchema $script:ResearchSchema
        $baseId = ConvertTo-BaseSlug -Slug $research.model_id
        if ($baseId -cne $research.model_id) {
            Fail-Args 'model_id must be a base slug without an effort suffix.'
        }

        if (-not [string]::IsNullOrWhiteSpace($CrossCheckFile)) {
            $crossCheck = Read-InputJson $CrossCheckFile
            if (
                $crossCheck -isnot [pscustomobject] -or
                @(Get-Keys $crossCheck) -cnotcontains 'disputed' -or
                (Get-V $crossCheck 'disputed') -isnot [array]
            ) {
                Fail-Args 'Cross-check requires a disputed array.'
            }

            $seenCaps = @{}
            foreach ($dispute in (Get-A $crossCheck 'disputed')) {
                foreach ($required in @('cap', 'reason', 'suggested_score')) {
                    if (@(Get-Keys $dispute) -cnotcontains $required) {
                        Fail-Args ('Cross-check entry missing ' + $required)
                    }
                }
                $dimension = Get-V $dispute 'cap'
                if (
                    $dimension -isnot [string] -or
                    @(Get-Keys $research.caps) -cnotcontains $dimension -or
                    $seenCaps.ContainsKey($dimension)
                ) {
                    Fail-Args 'Unknown or duplicate disputed cap.'
                }
                if ([string]::IsNullOrWhiteSpace([string](Get-V $dispute 'reason'))) {
                    Fail-Args 'Cross-check reason is empty.'
                }

                $seenCaps[$dimension] = $true
                $suggestion = Get-V $dispute 'suggested_score'
                if ($null -ne $suggestion) {
                    if (-not (Test-Number $suggestion) -or $suggestion -lt 0 -or $suggestion -gt 10) {
                        Fail-Args 'suggested_score must be null or a number from 0 to 10.'
                    }
                }

                # Keep original research intact. Disputes are proposal metadata.
                $disputes[$dimension] = [pscustomobject]@{
                    cap = $dimension
                    research_score = Get-V (Get-V $research.caps $dimension) 'score'
                    suggested_score = $suggestion
                    reason = Get-V $dispute 'reason'
                }
            }
            Assert-Schema $research $script:ResearchSchema $script:ResearchSchema
        }
    }

    if ($DryRun) {
        $registry = Read-Registry -Paths $paths
        if ($action -eq 'Research') {
            $state = Read-State -Paths $paths
            $plan = Get-ResearchPlan $paths $registry $research $state $disputes
            foreach ($proposal in $plan.proposals) {
                Set-V $proposal 'base_rev' ([long]$registry.registry_rev + 1)
            }
            Write-OrchestraResult -Object @{
                dry_run = $true
                auto_applied = $plan.auto
                proposals = @()
                proposal_preview = $plan.proposals
                rejected = $plan.rejected
                confidence = $plan.confidence
                backup = $null
            }
        }
        elseif ($action -in @('Approve', 'ApproveAll')) {
            $approvalResult = Invoke-ApprovalAction $paths $registry $Approve $ApproveAll ([bool]$Force) $true
            Write-OrchestraResult -Object $approvalResult
            if (@(Get-A $approvalResult 'rejected_proposals').Count -gt 0) { exit 2 }
        }
        else {
            $snapshotPath = Get-Snapshot $paths $Rollback
            $snapshot = Read-InputJson $snapshotPath
            if (-not $Force -and [long]$registry.registry_rev -ne [long]$snapshot.registry_rev + 1) {
                Fail-Args 'Rollback would overwrite later revisions. Review and explicitly use -Force.'
            }
            Write-OrchestraResult -Object @{
                dry_run = $true
                auto_applied = @()
                proposals = @()
                rejected = $false
                backup = $null
                restore_from = $snapshotPath
            }
        }
        exit 0
    }

    $result = Invoke-WithLock -Paths $paths -Name registry -ScriptBlock {
        $registry = Read-Registry -Paths $paths

        if ($action -eq 'Research') {
            Invoke-WithLock -Paths $paths -Name state -ScriptBlock {
                $state = Read-State -Paths $paths
                Invoke-Research $paths $registry $state $research $disputes
            }
        }
        elseif ($action -in @('Approve', 'ApproveAll')) {
            Invoke-ApprovalAction $paths $registry $Approve $ApproveAll ([bool]$Force) $false
        }
        else {
            $snapshotPath = Get-Snapshot $paths $Rollback
            $snapshot = Read-InputJson $snapshotPath
            $snapshotRev = Get-V $snapshot 'registry_rev'
            if (
                -not (Test-Number $snapshotRev) -or
                $null -eq (Get-V $snapshot 'models') -or
                $null -eq (Get-V $snapshot 'aliases') -or
                $null -eq (Get-V $snapshot 'policy')
            ) {
                Fail-Args 'Invalid registry snapshot.'
            }
            if (-not $Force -and [long]$registry.registry_rev -ne [long]$snapshotRev + 1) {
                Fail-Args 'Rollback would overwrite later revisions. Review and explicitly use -Force.'
            }
            Set-V $snapshot 'registry_rev' ([long]$registry.registry_rev)
            $commit = Save-WithBackup $paths $snapshot ('Rollback to: ' + [IO.Path]::GetFileName($snapshotPath))
            $null = Add-ChangelogEntry -Paths $paths -Title 'Registry rollback' -Lines @(
                ('Restored snapshot: ' + $snapshotPath)
                ('Snapshot revision: ' + $snapshotRev)
                ('New registry revision: ' + $commit.rev)
                ('Forced: ' + [bool]$Force)
                ('Backup: ' + $commit.backup)
            )
            [ordered]@{
                auto_applied = @([pscustomobject]@{ op = 'rollback'; snapshot = $snapshotPath })
                proposals = @()
                rejected = $false
                backup = $commit.backup
                registry_rev = $commit.rev
                restore_from = $snapshotPath
            }
        }
    }

    Write-OrchestraResult -Object $result
    if (@(Get-A $result 'rejected_proposals').Count -gt 0) { exit 2 }
    exit 0
}
catch {
    $message = $_.Exception.Message
    [Console]::Error.WriteLine($message)
    Write-OrchestraResult -Object @{
        error = $message
        auto_applied = @()
        proposals = @()
        rejected = $false
        backup = $null
    }
    if ($message -match 'ORCHESTRA_LOCK_TIMEOUT') { exit 5 }
    if ($message -match '^ORCHESTRA_ARGS:') { exit 2 }
    exit 3
}
