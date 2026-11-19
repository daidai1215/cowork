<#
.SYNOPSIS
Interactive or declarative installer, default model roster selector, and post-selection capability evaluator for cowork.
.DESCRIPTION
Discovers available models across Antigravity (agy) and Codex CLI, lets the user pick
their active default roster (by number, full ID, or shorthand such as carbon, astra, opus5.5),
scaffolds any newly selected models, retires unselected models, aligns baseline_slugs,
evaluates selected models' capabilities (research, live 5-task blind probe, or both),
rebinds best-* aliases and fallback chains, creates the Codex Junction, and syncs docs.
#>
[CmdletBinding()]
param(
    [switch]$ListAvailable,
    [switch]$Interactive,
    [string[]]$Models = @(),
    [string[]]$ReviewOnlyModels = @(),
    [ValidateSet('auto', 'none', 'research', 'probe', 'full')]
    [string]$Evaluate = 'auto',
    [switch]$ForceEvaluate,
    [string]$DefaultEffort = 'high',
    [switch]$SkipJunction,
    [string]$CodexDestination = (Join-Path $HOME '.codex\skills\cowork'),
    [switch]$SkipGlobalPlugin,
    [string]$GlobalPluginDestination = (Join-Path $HOME '.gemini\config\plugins\cowork-orchestrator'),
    [string]$AgyListFile,
    [string]$CodexCatalogFile,
    [switch]$NoNetwork,
    [switch]$DryRun,
    [string]$RegistryPath,
    [string]$StateDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Normalize-ModelToken {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    return (($Text.Trim().ToLowerInvariant()) -replace '[-._\s]+', '')
}

function Copy-FileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $destFull = [IO.Path]::GetFullPath($Destination)
    $destDir = [IO.Path]::GetDirectoryName($destFull)
    [void][IO.Directory]::CreateDirectory($destDir)
    $tmpPath = Join-Path $destDir (
        '.' + [IO.Path]::GetFileName($destFull) + '.' +
        [Guid]::NewGuid().ToString('N') + '.tmp'
    )
    try {
        [IO.File]::Copy($Source, $tmpPath, $true)
        if ([IO.File]::Exists($destFull)) {
            [IO.File]::Replace($tmpPath, $destFull, [NullString]::Value)
        }
        else {
            [IO.File]::Move($tmpPath, $destFull)
        }
    }
    finally {
        if ([IO.File]::Exists($tmpPath)) {
            try { [IO.File]::Delete($tmpPath) } catch {}
        }
    }
}

function Format-DisplayTitle {
    param([string]$ModelId)
    $parts = @($ModelId -split '[-_]+' | Where-Object { $_.Length -gt 0 })
    if ($parts.Count -eq 0) { return $ModelId }
    $out = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $p = $parts[$i]
        if ($p -ieq 'gpt') { [void]$out.Add('GPT') }
        elseif ($p -ieq 'oss') { [void]$out.Add('OSS') }
        elseif ($p -match '^\d+$' -and ($i + 1) -lt $parts.Count -and $parts[$i + 1] -match '^\d+$' -and $parts[0] -in @('claude', 'gemini')) {
            [void]$out.Add($p + '.' + $parts[$i + 1])
            $i++
        }
        elseif ($p.Length -gt 1) {
            [void]$out.Add($p.Substring(0, 1).ToUpperInvariant() + $p.Substring(1))
        }
        else {
            [void]$out.Add($p.ToUpperInvariant())
        }
    }
    $joined = ($out.ToArray() -join ' ')
    $joined = $joined -replace '^GPT (\d)', 'GPT-$1'
    return $joined
}

function Infer-ModelMetadata {
    param([string]$ModelId, [string]$Channel)
    $lower = $ModelId.ToLowerInvariant()
    $vendor = 'other'
    $family = $lower
    if ($lower -match '^gemini') {
        $vendor = 'google'
        $family = 'google-gemini'
    }
    elseif ($lower -match '^claude-opus') {
        $vendor = 'anthropic'
        $family = 'anthropic-claude-opus'
    }
    elseif ($lower -match '^claude-sonnet') {
        $vendor = 'anthropic'
        $family = 'anthropic-claude-sonnet'
    }
    elseif ($lower -match '^claude') {
        $vendor = 'anthropic'
        $family = 'anthropic-claude'
    }
    elseif ($lower -match '^gpt-oss') {
        $vendor = 'openai'
        $family = 'openai-gpt-oss'
    }
    elseif ($Channel -eq 'codex' -or $lower -match '^(gpt|o\d|codex)') {
        $vendor = 'openai'
        $family = 'openai-gpt'
    }
    $gen = '1'
    if ($lower -match 'claude-[a-z]+-(\d+)-(\d+)') {
        $gen = $Matches[1] + '.' + $Matches[2]
    }
    elseif ($lower -match '(\d+(?:\.\d+)?)') {
        $gen = $Matches[1]
    }
    $tier = if ($lower -match 'flash|mini|nano|haiku|lite|hydrogen|argon|sol') { 'fast' } else { 'flagship' }
    return @{
        vendor = $vendor
        family = $family
        generation = $gen
        tier = $tier
    }
}

function Test-ModelNeedsEvaluation {
    param($ModelObj)
    if ($null -eq $ModelObj) { return $true }
    $lastRes = [string](Get-OrchestraProperty $ModelObj 'last_researched' '')
    if ([string]::IsNullOrWhiteSpace($lastRes)) { return $true }
    $capsObj = Get-OrchestraProperty $ModelObj 'caps'
    foreach ($dimName in @(Get-OrchestraNames $capsObj)) {
        $cap = Get-OrchestraProperty $capsObj $dimName
        if ([string](Get-OrchestraProperty $cap 'source' '') -eq 'bootstrap') {
            return $true
        }
    }
    return $false
}

function Invoke-ChildScriptJson {
    param(
        [string]$ScriptPath,
        [string[]]$Arguments = @(),
        [string]$WorkDir,
        [int]$TimeoutSec = 1800
    )
    $proc = Invoke-OrchestraProcess -FilePath 'powershell.exe' -Arguments (
        @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $Arguments
    ) -WorkDir $WorkDir -TimeoutSec $TimeoutSec -CaptureStdout
    $json = $null
    $nonEmpty = @($proc.stdout | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($nonEmpty.Count -gt 0) {
        try { $json = ([string]$nonEmpty[$nonEmpty.Count - 1] | ConvertFrom-Json) } catch { $json = $null }
    }
    return [pscustomobject]@{
        exit_code = [int]$proc.exit_code
        timeout = [bool]$proc.timeout
        json = $json
        stdout = $proc.stdout
        stderr = $proc.stderr
    }
}

function Get-DiscoveredCatalog {
    param(
        $Registry,
        [string]$AgyFile,
        [string]$CodexFile,
        [bool]$Offline,
        [string]$WorkRoot
    )
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $agyByBase = @{}
    $agyRawIds = @()
    $codexIds = @()

    # 1. Scan Antigravity models
    $agyText = $null
    if (-not [string]::IsNullOrWhiteSpace($AgyFile)) {
        if (-not [IO.File]::Exists($AgyFile)) {
            throw "ORCHESTRA_ARGS: AgyListFile not found: $AgyFile"
        }
        $agyText = Get-Content -LiteralPath $AgyFile -Raw -Encoding UTF8
    }
    elseif (-not $Offline) {
        try {
            $wrapper = Resolve-AgyWrapper
            $pRes = Invoke-OrchestraProcess -FilePath 'powershell.exe' -Arguments @(
                '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $wrapper, 'models'
            ) -WorkDir $WorkRoot -TimeoutSec 45 -CaptureStdout
            if ($pRes.exit_code -eq 0 -and -not $pRes.timeout) {
                $agyText = ($pRes.stdout -join "`n")
            }
            else {
                [void]$warnings.Add('Could not query live agy models (exit=' + $pRes.exit_code + ').')
            }
        }
        catch {
            [void]$warnings.Add('Antigravity wrapper unavailable during scan: ' + $_.Exception.Message)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($agyText)) {
        foreach ($line in ($agyText -split '\r?\n')) {
            if ($line -match '^\s*(?<slug>[A-Za-z0-9][A-Za-z0-9._-]*)\t[^\r\n]+$') {
                $raw = $Matches['slug'].ToLowerInvariant()
                $base = ConvertTo-BaseSlug -Slug $raw
                if (-not $agyByBase.ContainsKey($base)) {
                    $agyByBase[$base] = @{
                        efforts = New-Object 'System.Collections.Generic.List[string]'
                        has_effort_suffix = $false
                    }
                }
                if ($raw -match '-(low|medium|high|xhigh|max|ultra)$') {
                    $eff = $Matches[1]
                    $agyByBase[$base].has_effort_suffix = $true
                    if (-not $agyByBase[$base].efforts.Contains($eff)) {
                        [void]$agyByBase[$base].efforts.Add($eff)
                    }
                }
            }
        }
        $agyRawIds = @($agyByBase.Keys | Sort-Object -Unique)
    }

    # 2. Scan Codex catalog
    $resolvedCodexFile = $CodexFile
    if ([string]::IsNullOrWhiteSpace($resolvedCodexFile)) {
        foreach ($cand in @(
            (Join-Path $HOME '.codex\cockpit-model-catalog.json'),
            (Join-Path $HOME '.codex\models_cache.json'),
            (Join-Path $HOME '.codex\cockpit-model-catalog.json.bak')
        )) {
            if ([IO.File]::Exists($cand)) {
                $resolvedCodexFile = $cand
                break
            }
        }
    }
    elseif (-not [IO.File]::Exists($resolvedCodexFile)) {
        throw "ORCHESTRA_ARGS: CodexCatalogFile not found: $resolvedCodexFile"
    }

    if (-not [string]::IsNullOrWhiteSpace($resolvedCodexFile) -and [IO.File]::Exists($resolvedCodexFile)) {
        $codexText = Get-Content -LiteralPath $resolvedCodexFile -Raw -Encoding UTF8
        $mList = [regex]::Matches($codexText, '"slug"\s*:\s*"(?<slug>[A-Za-z0-9][A-Za-z0-9._-]*)"')
        $codexIds = @(
            foreach ($m in $mList) { $m.Groups['slug'].Value.ToLowerInvariant() }
        ) | Sort-Object -Unique
    }

    # 3. Merge registry entries + discovered entries
    $regMap = @{}
    foreach ($rm in @(Get-OrchestraArray $Registry 'models')) {
        $regMap[[string]$rm.id] = $rm
    }

    $allIds = New-Object 'System.Collections.Generic.List[string]'
    $seen = @{}
    foreach ($id in (@($regMap.Keys) + $agyRawIds + $codexIds)) {
        $sId = [string]$id
        if ([string]::IsNullOrWhiteSpace($sId) -or $seen.ContainsKey($sId)) { continue }
        $seen[$sId] = $true
        [void]$allIds.Add($sId)
    }

    $catalog = New-Object 'System.Collections.Generic.List[object]'
    $orderedIds = @($allIds.ToArray() | Sort-Object)
    $menuIndex = 0
    foreach ($id in $orderedIds) {
        $menuIndex++
        $existing = if ($regMap.ContainsKey($id)) { $regMap[$id] } else { $null }
        $inAgy = $agyByBase.ContainsKey($id)
        $inCodex = ($codexIds -contains $id)
        $channel = if ($null -ne $existing) {
            [string](Get-OrchestraProperty $existing 'channel' 'agy')
        }
        elseif ($inCodex -and -not $inAgy) {
            'codex'
        }
        else {
            'agy'
        }

        $meta = Infer-ModelMetadata -ModelId $id -Channel $channel
        $vendor = if ($null -ne $existing) { [string](Get-OrchestraProperty $existing 'vendor' $meta.vendor) } else { $meta.vendor }
        $efforts = @('low', 'medium', 'high')
        $hasSuffix = ($channel -eq 'agy')
        if ($null -ne $existing) {
            $inv = Get-OrchestraProperty $existing 'invoke'
            $regEff = @(Get-OrchestraArray $inv 'efforts' | ForEach-Object { [string]$_ })
            if ($regEff.Count -gt 0) { $efforts = $regEff }
            $mFlag = [string](Get-OrchestraProperty $inv 'model_flag' '')
            $hasSuffix = $mFlag.Contains('{effort}')
        }
        elseif ($inAgy) {
            $discEff = @($agyByBase[$id].efforts.ToArray())
            $hasSuffix = [bool]$agyByBase[$id].has_effort_suffix
            if ($discEff.Count -gt 0) {
                $effOrder = @('low', 'medium', 'high', 'xhigh', 'max', 'ultra')
                $efforts = @($effOrder | Where-Object { $discEff -contains $_ })
            }
            else {
                $efforts = @('high')
            }
        }
        elseif ($channel -eq 'codex') {
            $efforts = @('low', 'medium', 'high', 'xhigh', 'max', 'ultra')
            $hasSuffix = $false
        }

        $curStatus = if ($null -ne $existing) { [string](Get-OrchestraProperty $existing 'status' 'candidate') } else { 'unregistered' }
        $revOnly = if ($null -ne $existing) { [bool](Get-OrchestraProperty $existing 'primary_disabled' $false) } else { $false }
        $evaluated = ($null -ne $existing) -and (-not (Test-ModelNeedsEvaluation -ModelObj $existing))

        [void]$catalog.Add([pscustomobject]@{
            index = $menuIndex
            id = $id
            display_name = $(if ($null -ne $existing) { [string](Get-OrchestraProperty $existing 'display_name' (Format-DisplayTitle $id)) } else { Format-DisplayTitle $id })
            channel = $channel
            vendor = $vendor
            efforts = [string[]]$efforts
            has_effort_suffix = [bool]$hasSuffix
            installed = [bool]($inAgy -or $inCodex)
            in_registry = ($null -ne $existing)
            current_status = $curStatus
            primary_disabled = $revOnly
            evaluated = [bool]$evaluated
        })
    }

    return [pscustomobject]@{
        items = $catalog.ToArray()
        agy_discovered = [string[]]$agyRawIds
        codex_discovered = [string[]]$codexIds
        warnings = [string[]]$warnings.ToArray()
    }
}

function Expand-SelectionTokens {
    param([string[]]$RawValues)
    return @(
        foreach ($raw in @($RawValues)) {
            foreach ($piece in ([string]$raw -split ',')) {
                $trimmed = $piece.Trim()
                if ($trimmed.Length -gt 0) { $trimmed }
            }
        }
    )
}

function Resolve-CatalogToken {
    param([string]$Token, [object[]]$CatalogItems)
    $clean = $Token.Trim()
    if ($clean -match '^\d+$') {
        $idx = [int]$clean
        $byIdx = @($CatalogItems | Where-Object { [int]$_.index -eq $idx })
        if ($byIdx.Count -eq 1) { return [string]$byIdx[0].id }
        throw "ORCHESTRA_ARGS: Model menu index out of range: $Token"
    }
    $lower = $clean.ToLowerInvariant()
    $exact = @($CatalogItems | Where-Object { ([string]$_.id).ToLowerInvariant() -ceq $lower })
    if ($exact.Count -eq 1) { return [string]$exact[0].id }

    $norm = Normalize-ModelToken $clean
    $normExact = @($CatalogItems | Where-Object { (Normalize-ModelToken ([string]$_.id)) -ceq $norm })
    if ($normExact.Count -eq 1) { return [string]$normExact[0].id }

    $substrHits = @(
        $CatalogItems | Where-Object {
            ((Normalize-ModelToken ([string]$_.id)).Contains($norm)) -or
            ((Normalize-ModelToken ([string]$_.display_name)).Contains($norm))
        }
    )
    if ($substrHits.Count -eq 0) {
        $strippedNorm = $norm -replace '(?:extra|ultra|xhigh|high|medium|low|max)$', ''
        if (-not [string]::IsNullOrWhiteSpace($strippedNorm) -and $strippedNorm -cne $norm) {
            $substrHits = @(
                $CatalogItems | Where-Object {
                    ((Normalize-ModelToken ([string]$_.id)).Contains($strippedNorm)) -or
                    ((Normalize-ModelToken ([string]$_.display_name)).Contains($strippedNorm))
                }
            )
        }
    }
    if ($substrHits.Count -eq 1) { return [string]$substrHits[0].id }
    if ($substrHits.Count -gt 1) {
        $names = @($substrHits | ForEach-Object { [string]$_.id }) -join ', '
        throw "ORCHESTRA_ARGS: Ambiguous model shorthand '$Token' matches multiple models: $names"
    }
    throw "ORCHESTRA_ARGS: Unknown model '$Token'. Run setup.ps1 -ListAvailable to inspect available models."
}

function New-BootstrapModelProfile {
    param($CatalogEntry, [string[]]$Dimensions, [string]$PreferredEffort)
    $id = [string]$CatalogEntry.id
    $channel = [string]$CatalogEntry.channel
    $meta = Infer-ModelMetadata -ModelId $id -Channel $channel
    $efforts = @($CatalogEntry.efforts | ForEach-Object { [string]$_ })
    if ($efforts.Count -eq 0) { $efforts = @('high') }
    $chosenEffort = if ($efforts -contains $PreferredEffort) {
        $PreferredEffort
    }
    elseif ($efforts -contains 'high') {
        'high'
    }
    else {
        $efforts[$efforts.Count - 1]
    }
    $modelFlag = if ($channel -eq 'agy' -and [bool]$CatalogEntry.has_effort_suffix) {
        ($id + '-{effort}')
    }
    else {
        $id
    }
    $invokeObj = [ordered]@{
        model_flag = $modelFlag
        default_effort = $chosenEffort
        efforts = [string[]]$efforts
    }
    if ($channel -eq 'codex') {
        if ($efforts -contains 'xhigh') { $invokeObj['peak_effort'] = 'xhigh' }
        $invokeObj['account_rotation'] = $true
        $invokeObj['rotation_max_retries'] = 2
        $invokeObj['rotation_wait_sec'] = 10
        $invokeObj['exhausted_minutes'] = 30
        $invokeObj['connect_timeout_sec'] = 25
        $invokeObj['reconnect_abort_count'] = 2
    }
    elseif ($efforts -contains 'xhigh') {
        $invokeObj['peak_effort'] = 'xhigh'
    }

    $tools = switch ($meta.vendor) {
        'openai' {
            if ($channel -eq 'codex') { @('image_gen', 'office_plugins', 'latex', 'browser', 'computer_use') }
            else { @('web_search') }
        }
        'google' { @('web_search', 'browser', 'long_context_1m') }
        'anthropic' { @('web_search', 'browser') }
        default { @('web_search') }
    }

    $caps = [ordered]@{}
    foreach ($dim in $Dimensions) {
        $initScore = 7.5
        if ($dim -eq 'image_gen' -and ($tools -notcontains 'image_gen')) {
            $initScore = 0.0
        }
        elseif ($dim -eq 'office_docs' -and ($tools -notcontains 'office_plugins')) {
            $initScore = 5.5
        }
        $caps[$dim] = [ordered]@{
            score = $initScore
            approved_score = $initScore
            source = 'bootstrap'
            locked = $false
            confidence = 0.3
            evidence = @()
        }
    }

    return ([pscustomobject]@{
        id = $id
        display_name = [string]$CatalogEntry.display_name
        vendor = [string]$meta.vendor
        family = [string]$meta.family
        generation = [string]$meta.generation
        tier = [string]$meta.tier
        status = 'active'
        channel = $channel
        invoke = ([pscustomobject]$invokeObj)
        tools = [string[]]$tools
        quota_rank = $(if ($meta.vendor -eq 'google') { 3 } elseif ($meta.vendor -eq 'anthropic') { 1 } else { 2 })
        speed_rank = $(if ($meta.tier -eq 'fast' -or $meta.vendor -eq 'google') { 3 } elseif ($channel -eq 'codex') { 1 } else { 2 })
        ranks_locked = $false
        primary_disabled = $false
        escalation_only = $false
        escalate_to = $null
        fallback = @()
        caps = ([pscustomobject]$caps)
        strengths = @('Selected during setup; awaiting or completed capability evaluation.')
        weaknesses = @('Verify factual claims via Truth Gate.')
        last_researched = $null
        evidence = @()
    })
}

function Get-ModelCapScore {
    param($ModelObj, [string]$Dimension)
    $capsObj = Get-OrchestraProperty $ModelObj 'caps'
    $entry = Get-OrchestraProperty $capsObj $Dimension
    if ($null -eq $entry) { return 0.0 }
    return [double](Get-OrchestraProperty $entry 'score' 0.0)
}

function Get-ModelAverageScore {
    param($ModelObj, [string[]]$Dimensions)
    if ($Dimensions.Count -eq 0) { return 0.0 }
    $sum = 0.0
    foreach ($d in $Dimensions) {
        $sum += (Get-ModelCapScore -ModelObj $ModelObj -Dimension $d)
    }
    return ($sum / $Dimensions.Count)
}

function Update-RosterBindings {
    param($Registry)
    $dims = @(Get-OrchestraArray $Registry 'cap_dimensions' | ForEach-Object { [string]$_ })
    $active = @(
        @(Get-OrchestraArray $Registry 'models') |
            Where-Object { [string](Get-OrchestraProperty $_ 'status') -eq 'active' }
    )
    if ($active.Count -eq 0) { return }
    $primaryEligible = @(
        $active | Where-Object { -not [bool](Get-OrchestraProperty $_ 'primary_disabled' $false) }
    )
    if ($primaryEligible.Count -eq 0) { $primaryEligible = $active }

    function Pick-BestModel($Pool, [string]$Dim, [string]$RequiredTool = '') {
        $filtered = @($Pool)
        if (-not [string]::IsNullOrWhiteSpace($RequiredTool)) {
            $withTool = @(
                $Pool | Where-Object {
                    @(Get-OrchestraArray $_ 'tools' | ForEach-Object { [string]$_ }) -contains $RequiredTool
                }
            )
            if ($withTool.Count -gt 0) { $filtered = $withTool }
        }
        $ranked = @(
            $filtered | Sort-Object `
                @{ Expression = { Get-ModelCapScore -ModelObj $_ -Dimension $Dim }; Descending = $true },
                @{ Expression = { [int](Get-OrchestraProperty $_ 'quota_rank' 2) }; Descending = $true },
                @{ Expression = { [string]$_.id }; Ascending = $true }
        )
        return [string]$ranked[0].id
    }

    $aliasesObj = [ordered]@{
        'best-rigor' = (Pick-BestModel $primaryEligible 'code_rigor')
        'best-math' = (Pick-BestModel $primaryEligible 'math')
        'best-image' = (Pick-BestModel $primaryEligible 'image_gen' 'image_gen')
        'best-prose' = (Pick-BestModel $primaryEligible 'prose')
        'best-knowledge' = (Pick-BestModel $primaryEligible 'world_knowledge')
        'best-aesthetic' = (Pick-BestModel $active 'frontend_aesthetic')
    }
    Set-OrchestraProperty $Registry 'aliases' ([pscustomobject]$aliasesObj)

    foreach ($rule in @(Get-OrchestraArray $Registry 'hard_rules')) {
        if ([string](Get-OrchestraProperty $rule 'id') -eq 'frontend-aesthetic-gate') {
            $aesBestId = [string]$aliasesObj['best-aesthetic']
            $fbPool = @($primaryEligible | Where-Object { [string]$_.id -cne $aesBestId })
            if ($fbPool.Count -eq 0) { $fbPool = $primaryEligible }
            $aesFallback = Pick-BestModel $fbPool 'frontend_aesthetic'
            Set-OrchestraProperty $rule 'reviewer_fallback' $aesFallback
        }
    }

    foreach ($m in $active) {
        $mId = [string]$m.id
        $others = @(
            $primaryEligible |
                Where-Object { [string]$_.id -cne $mId } |
                Sort-Object `
                    @{ Expression = { if ([string]$_.vendor -cne [string]$m.vendor) { 1 } else { 0 } }; Descending = $true },
                    @{ Expression = { Get-ModelAverageScore -ModelObj $_ -Dimensions $dims }; Descending = $true },
                    @{ Expression = { [string]$_.id }; Ascending = $true } |
                ForEach-Object { [string]$_.id }
        )
        Set-OrchestraProperty $m 'fallback' ([string[]]$others)
    }
}

$tempEvalDir = Join-Path ([IO.Path]::GetTempPath()) ('cowork-setup-eval-' + [Guid]::NewGuid().ToString('N'))
try {
    $paths = Get-OrchestraPaths -RegistryPath $RegistryPath -StateDir $StateDir
    $canonicalReg = [IO.Path]::GetFullPath((Join-Path $paths.Root 'registry\models.json'))
    $isCanonicalRepo = ([IO.Path]::GetFullPath($paths.Registry) -ieq $canonicalReg)
    $docRoot = if ($isCanonicalRepo) { $paths.Root } else { Split-Path -Parent $paths.RegistryDir }
    $explicitSkipPlugin = $PSBoundParameters.ContainsKey('SkipGlobalPlugin')
    $explicitPluginDest = $PSBoundParameters.ContainsKey('GlobalPluginDestination')
    $envSkipPlugin = ([Environment]::GetEnvironmentVariable('COWORK_SKIP_GLOBAL_PLUGIN') -eq '1')
    $canonicalStateDir = [IO.Path]::GetFullPath((Join-Path $HOME '.cowork'))
    $isNonDefaultRegistry = (-not [string]::IsNullOrWhiteSpace($RegistryPath)) -and (-not $isCanonicalRepo)
    $isNonDefaultState = (-not [string]::IsNullOrWhiteSpace($StateDir)) -and ([IO.Path]::GetFullPath($StateDir) -ine $canonicalStateDir)
    $hasNonDefaultTarget = $isNonDefaultRegistry -or $isNonDefaultState
    $effectiveSkipGlobalPlugin = $false
    if ($SkipGlobalPlugin) {
        $effectiveSkipGlobalPlugin = $true
    }
    elseif ($envSkipPlugin -and -not ($explicitSkipPlugin -and -not [bool]$SkipGlobalPlugin)) {
        $effectiveSkipGlobalPlugin = $true
    }
    elseif ($hasNonDefaultTarget -and -not $explicitSkipPlugin -and -not $explicitPluginDest) {
        $effectiveSkipGlobalPlugin = $true
    }

    $initialRegistry = Read-Registry -Paths $paths
    $catalogResult = Get-DiscoveredCatalog -Registry $initialRegistry -AgyFile $AgyListFile -CodexFile $CodexCatalogFile -Offline ([bool]$NoNetwork) -WorkRoot $paths.Root
    $catalogItems = @($catalogResult.items)

    $currentActive = @(
        $catalogItems | Where-Object { $_.current_status -eq 'active' } | ForEach-Object { [string]$_.id }
    )
    $currentReviewOnly = @(
        $catalogItems | Where-Object { $_.current_status -eq 'active' -and [bool]$_.primary_disabled } | ForEach-Object { [string]$_.id }
    )

    if ($ListAvailable) {
        Write-OrchestraResult -Object ([ordered]@{
            available = $catalogItems
            current_active = [string[]]$currentActive
            current_review_only = [string[]]$currentReviewOnly
            warnings = $catalogResult.warnings
        })
        exit 0
    }

    $defaultEffortExplicit = $PSBoundParameters.ContainsKey('DefaultEffort')
    $reviewOnlyExplicit = $PSBoundParameters.ContainsKey('ReviewOnlyModels')
    $rawModelTokens = @(Expand-SelectionTokens $Models)
    $rawReviewTokens = @(Expand-SelectionTokens $ReviewOnlyModels)

    $canPromptConsole = $Interactive -or (
        $rawModelTokens.Count -eq 0 -and
        [Environment]::UserInteractive -and
        -not [Console]::IsInputRedirected
    )

    if ($canPromptConsole -and $rawModelTokens.Count -eq 0) {
        [Console]::Error.WriteLine('')
        [Console]::Error.WriteLine('=== Cowork Default Model Roster Setup ===')
        foreach ($item in $catalogItems) {
            $tags = New-Object 'System.Collections.Generic.List[string]'
            if ($item.current_status -eq 'active') { [void]$tags.Add('active') }
            elseif ($item.in_registry) { [void]$tags.Add([string]$item.current_status) }
            else { [void]$tags.Add('new') }
            if ($item.primary_disabled) { [void]$tags.Add('review-only') }
            if ($item.evaluated) { [void]$tags.Add('evaluated') }
            $tagStr = '[' + ($tags.ToArray() -join ', ') + ']'
            [Console]::Error.WriteLine((
                '  [{0,2}] {1,-26} ({2,-5} / {3,-9}) {4}' -f
                $item.index, $item.id, $item.channel, $item.vendor, $tagStr
            ))
        }
        [Console]::Error.WriteLine('')
        $defaultHint = if ($currentActive.Count -gt 0) { $currentActive -join ',' } else { '' }
        [Console]::Error.Write("Select active models by number or shorthand (e.g. carbon,astra,opus5.5) [$defaultHint]: ")
        $inputLine = [Console]::ReadLine()
        if ([string]::IsNullOrWhiteSpace($inputLine)) {
            $rawModelTokens = @($currentActive)
        }
        else {
            $rawModelTokens = @(Expand-SelectionTokens @($inputLine))
        }

        if (-not $reviewOnlyExplicit) {
            $roHint = if ($currentReviewOnly.Count -gt 0) { $currentReviewOnly -join ',' } else { 'none' }
            [Console]::Error.Write("Review-only protected models (never bulk primary, e.g. opus5.5 or 'none') [$roHint]: ")
            $roLine = [Console]::ReadLine()
            if (-not [string]::IsNullOrWhiteSpace($roLine)) {
                $reviewOnlyExplicit = $true
                if ($roLine.Trim() -ieq 'none') {
                    $rawReviewTokens = @()
                }
                else {
                    $rawReviewTokens = @(Expand-SelectionTokens @($roLine))
                }
            }
        }

        if (-not $PSBoundParameters.ContainsKey('Evaluate')) {
            [Console]::Error.Write('Capability evaluation mode after selection [auto/research/probe/full/none] [auto]: ')
            $evLine = [Console]::ReadLine()
            if (-not [string]::IsNullOrWhiteSpace($evLine)) {
                $evTrim = $evLine.Trim().ToLowerInvariant()
                if ($evTrim -notin @('auto', 'none', 'research', 'probe', 'full')) {
                    throw "ORCHESTRA_ARGS: Invalid interactive Evaluate choice: $evTrim"
                }
                $Evaluate = $evTrim
            }
        }
    }

    if ($rawModelTokens.Count -eq 0) {
        throw 'ORCHESTRA_ARGS: Specify -Models <m1,m2,...> (e.g. -Models carbon,astra,opus5.5), -ListAvailable, or run interactively.'
    }

    $selectedIds = New-Object 'System.Collections.Generic.List[string]'
    foreach ($tok in $rawModelTokens) {
        $resId = Resolve-CatalogToken -Token $tok -CatalogItems $catalogItems
        if (-not $selectedIds.Contains($resId)) {
            [void]$selectedIds.Add($resId)
        }
    }

    $resolvedReviewOnly = New-Object 'System.Collections.Generic.List[string]'
    if ($reviewOnlyExplicit) {
        foreach ($rtok in $rawReviewTokens) {
            if ($rtok -ieq 'none') { continue }
            $rId = Resolve-CatalogToken -Token $rtok -CatalogItems $catalogItems
            if (-not $selectedIds.Contains($rId)) {
                throw "ORCHESTRA_ARGS: ReviewOnlyModel '$rId' must also be included in -Models."
            }
            if (-not $resolvedReviewOnly.Contains($rId)) {
                [void]$resolvedReviewOnly.Add($rId)
            }
        }
    }
    else {
        foreach ($sId in $selectedIds) {
            if ($currentReviewOnly -contains $sId) {
                [void]$resolvedReviewOnly.Add($sId)
            }
        }
    }

    $primaryCapableCount = @($selectedIds | Where-Object { -not $resolvedReviewOnly.Contains($_) }).Count
    if ($primaryCapableCount -lt 1) {
        throw 'ORCHESTRA_ARGS: At least one selected model must allow primary execution (cannot mark all selected models as ReviewOnlyModels).'
    }

    # Plan which selected models need capability evaluation
    $catalogById = @{}
    foreach ($ci in $catalogItems) { $catalogById[[string]$ci.id] = $ci }

    $plannedEvalIds = New-Object 'System.Collections.Generic.List[string]'
    if ($Evaluate -ne 'none') {
        foreach ($sId in $selectedIds) {
            $cEntry = $catalogById[$sId]
            $needsEval = (-not [bool]$cEntry.evaluated)
            if ($ForceEvaluate -or $Evaluate -in @('research', 'probe', 'full') -or $needsEval) {
                [void]$plannedEvalIds.Add($sId)
            }
        }
    }

    if ($DryRun) {
        Write-OrchestraResult -Object ([ordered]@{
            dry_run = $true
            selected_models = [string[]]$selectedIds.ToArray()
            review_only_models = [string[]]$resolvedReviewOnly.ToArray()
            evaluate_mode = $Evaluate
            planned_evaluations = [string[]]$plannedEvalIds.ToArray()
            skip_junction = [bool]$SkipJunction
            codex_destination = $CodexDestination
            skip_global_plugin = [bool]$effectiveSkipGlobalPlugin
            global_plugin_destination = $GlobalPluginDestination
        })
        exit 0
    }

    # Step 1: Ensure Codex Junction if requested
    $junctionSynced = $false
    if (-not $SkipJunction -and -not [string]::IsNullOrWhiteSpace($CodexDestination)) {
        $syncCodexScript = Join-Path $PSScriptRoot 'sync-to-codex.ps1'
        if ([IO.File]::Exists($syncCodexScript)) {
            $jRun = Invoke-ChildScriptJson -ScriptPath $syncCodexScript -Arguments @('-Destination', $CodexDestination) -WorkDir $paths.Root -TimeoutSec 30
            $junctionSynced = ($jRun.exit_code -eq 0)
        }
    }

    # Step 1b: Sync always-active cowork-orchestrator global plugin if present and not skipped
    $globalPluginSynced = $false
    if (-not $effectiveSkipGlobalPlugin -and -not [string]::IsNullOrWhiteSpace($GlobalPluginDestination)) {
        $pluginSrcRoot = Join-Path $docRoot 'integrations\cowork-orchestrator-plugin'
        if (-not [IO.File]::Exists((Join-Path $pluginSrcRoot 'plugin.json')) -and $docRoot -ne $paths.Root) {
            $pluginSrcRoot = Join-Path $paths.Root 'integrations\cowork-orchestrator-plugin'
        }
        $srcPluginJson = Join-Path $pluginSrcRoot 'plugin.json'
        if ([IO.File]::Exists($srcPluginJson)) {
            $destPluginRoot = [IO.Path]::GetFullPath($GlobalPluginDestination)
            Copy-FileAtomic -Source $srcPluginJson -Destination (Join-Path $destPluginRoot 'plugin.json')
            $srcAgentsMd = Join-Path $pluginSrcRoot 'rules\AGENTS.md'
            if ([IO.File]::Exists($srcAgentsMd)) {
                Copy-FileAtomic -Source $srcAgentsMd -Destination (Join-Path $destPluginRoot 'rules\AGENTS.md')
            }
            $globalPluginSynced = $true
        }
    }

    # Step 2: Apply roster activation, bootstrap new models, retire unselected, sync state baselines
    $addedModels = New-Object 'System.Collections.Generic.List[string]'
    $retiredModels = New-Object 'System.Collections.Generic.List[string]'

    $backupRelPath = Invoke-WithLock -Paths $paths -Name registry -ScriptBlock {
        $reg = Read-Registry -Paths $paths
        $prevText = [IO.File]::ReadAllText($paths.Registry, $script:OrchestraUtf8)
        $oldRev = [long](Get-OrchestraProperty $reg 'registry_rev' 0)
        $dims = @(Get-OrchestraArray $reg 'cap_dimensions' | ForEach-Object { [string]$_ })

        $modelsList = New-Object 'System.Collections.Generic.List[object]'
        $existingIds = @{}
        foreach ($m in @(Get-OrchestraArray $reg 'models')) {
            $mId = [string]$m.id
            $existingIds[$mId] = $true
            if ($selectedIds.Contains($mId)) {
                Set-OrchestraProperty $m 'status' 'active'
                $inv = Get-OrchestraProperty $m 'invoke'
                $effs = @(Get-OrchestraArray $inv 'efforts' | ForEach-Object { [string]$_ })
                if ($defaultEffortExplicit -and ($effs -contains $DefaultEffort)) {
                    Set-OrchestraProperty $inv 'default_effort' $DefaultEffort
                }
                Set-OrchestraProperty $m 'primary_disabled' ([bool]$resolvedReviewOnly.Contains($mId))
            }
            else {
                if ([string](Get-OrchestraProperty $m 'status') -eq 'active') {
                    [void]$retiredModels.Add($mId)
                }
                Set-OrchestraProperty $m 'status' 'retired'
            }
            [void]$modelsList.Add($m)
        }

        foreach ($sId in $selectedIds) {
            if (-not $existingIds.ContainsKey($sId)) {
                $boot = New-BootstrapModelProfile -CatalogEntry $catalogById[$sId] -Dimensions $dims -PreferredEffort $DefaultEffort
                Set-OrchestraProperty $boot 'primary_disabled' ([bool]$resolvedReviewOnly.Contains($sId))
                [void]$modelsList.Add($boot)
                [void]$addedModels.Add($sId)
            }
        }

        Set-OrchestraProperty $reg 'models' ($modelsList.ToArray())
        Update-RosterBindings -Registry $reg

        $nowUtc = Get-OrchestraNow
        $stamp = $nowUtc.ToString('yyyyMMdd-HHmmss')
        $newRev = $oldRev + 1
        Set-OrchestraProperty $reg 'registry_rev' $newRev
        Set-OrchestraProperty $reg 'updated' ($nowUtc.ToString('o'))

        [void][IO.Directory]::CreateDirectory($paths.History)
        $backupName = ('models-{0}-{1}-setup.json' -f $stamp, $oldRev)
        $backupFull = Join-Path $paths.History $backupName
        [IO.File]::WriteAllText($backupFull, $prevText, $script:OrchestraUtf8)
        $createdBackupRel = 'registry/history/' + $backupName

        Write-JsonAtomic -Path $paths.Registry -Object $reg

        $changeEntry = @(
            ('## {0} - Roster setup: {1}' -f $nowUtc.ToString('o'), ($selectedIds.ToArray() -join ', '))
            ('- registry_rev: {0} -> {1}' -f $oldRev, $newRev)
            ('- active models: {0}' -f ($selectedIds.ToArray() -join ', '))
            ('- review-only models: {0}' -f $(if ($resolvedReviewOnly.Count -gt 0) { $resolvedReviewOnly.ToArray() -join ', ' } else { 'none' }))
            ('- backup: {0}' -f $createdBackupRel)
            ''
        ) -join "`n"
        $existingLog = if ([IO.File]::Exists($paths.Changelog)) { [IO.File]::ReadAllText($paths.Changelog, $script:OrchestraUtf8) } else { "# Cowork changelog`n`n" }
        $updatedLog = if ($existingLog -match '^# [^\r\n]+\r?\n\r?\n?') {
            $header = $Matches[0]
            $header + $changeEntry + "`n" + $existingLog.Substring($header.Length)
        }
        else {
            "# Cowork changelog`n`n" + $changeEntry + "`n" + $existingLog
        }
        [IO.File]::WriteAllText($paths.Changelog, $updatedLog, $script:OrchestraUtf8)

        # Align state baselines so unselected pre-existing local models do not trigger false new alerts
        Invoke-WithLock -Paths $paths -Name state -ScriptBlock {
            $st = Read-State -Paths $paths
            $exObj = Get-OrchestraProperty $st 'exhausted'
            foreach ($sId in $selectedIds) {
                if ($null -ne $exObj -and $null -ne $exObj.PSObject.Properties[$sId]) {
                    [void]$exObj.PSObject.Properties.Remove($sId)
                }
            }
            $rejList = @(
                Get-OrchestraArray $st 'rejected_slugs' |
                    ForEach-Object { [string]$_ } |
                    Where-Object { -not $selectedIds.Contains($_) }
            )
            Set-OrchestraProperty $st 'rejected_slugs' ([string[]]$rejList)

            $sourcesObj = Get-OrchestraProperty $st 'sources'
            if ($null -eq $sourcesObj) {
                $sourcesObj = [pscustomobject]@{}
                Set-OrchestraProperty $st 'sources' $sourcesObj
            }
            foreach ($srcPair in @(
                @{ Name = 'agy'; Discovered = $catalogResult.agy_discovered },
                @{ Name = 'codex'; Discovered = $catalogResult.codex_discovered }
            )) {
                $sName = $srcPair.Name
                $discIds = @($srcPair.Discovered)
                if ($discIds.Count -eq 0) { continue }
                $srcEntry = Get-OrchestraProperty $sourcesObj $sName
                if ($null -eq $srcEntry) {
                    $srcEntry = [pscustomobject]@{}
                    Set-OrchestraProperty $sourcesObj $sName $srcEntry
                }
                $unselected = @(
                    $discIds | Where-Object { -not $selectedIds.Contains([string]$_) } | Sort-Object -Unique
                )
                $prevBase = @(Get-OrchestraArray $srcEntry 'baseline_slugs' | ForEach-Object { [string]$_ })
                $mergedBase = @(
                    ($prevBase + $unselected) |
                        Where-Object { -not $selectedIds.Contains([string]$_) } |
                        Sort-Object -Unique
                )
                Set-OrchestraProperty $srcEntry 'baseline_slugs' ([string[]]$mergedBase)
                Set-OrchestraProperty $srcEntry 'baseline_initialized' $true
            }
            Save-State -Paths $paths -State $st
        }
        return $createdBackupRel
    }

    # Step 3: Post-selection capability evaluation
    $evaluationResults = New-Object 'System.Collections.Generic.List[object]'
    $hasProviderOverrides = (
        -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_AGY_WRAPPER')) -or
        -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_CODEX'))
    )
    if ($plannedEvalIds.Count -gt 0 -and (-not $NoNetwork -or $hasProviderOverrides)) {
        [void][IO.Directory]::CreateDirectory($tempEvalDir)
        $doResearch = ($Evaluate -in @('auto', 'research', 'full'))
        $doProbe = ($Evaluate -in @('probe', 'full'))

        $crossSchemaObj = [pscustomobject]@{
            '$schema' = 'http://json-schema.org/draft-07/schema#'
            type = 'object'
            additionalProperties = $false
            required = @('disputed')
            properties = [pscustomobject]@{
                disputed = [pscustomobject]@{
                    type = 'array'
                    items = [pscustomobject]@{
                        type = 'object'
                        additionalProperties = $false
                        required = @('cap', 'reason', 'suggested_score')
                        properties = [pscustomobject]@{
                            cap = [pscustomobject]@{ type = 'string'; minLength = 1 }
                            reason = [pscustomobject]@{ type = 'string'; minLength = 1 }
                            suggested_score = [pscustomobject]@{ type = @('number', 'null'); minimum = 0; maximum = 10 }
                        }
                    }
                }
            }
        }

        foreach ($evalId in $plannedEvalIds) {
            $evalRecord = [ordered]@{
                model_id = $evalId
                research_status = 'skipped'
                probe_status = 'skipped'
                updated_dimensions = @()
            }
            $updatedDims = New-Object 'System.Collections.Generic.List[string]'
            $researchScoresThisRun = @{}

            if ($doResearch) {
                $modelWork = Join-Path $tempEvalDir ('res-' + ($evalId -replace '[^A-Za-z0-9._-]', '_'))
                [void][IO.Directory]::CreateDirectory($modelWork)
                $promptFile = Join-Path $modelWork 'research-prompt.md'
                $resOutFile = Join-Path $modelWork 'research.json'
                $crossPromptFile = Join-Path $modelWork 'crosscheck-prompt.md'
                $crossSchemaFile = Join-Path $modelWork 'crosscheck.schema.json'
                $crossOutFile = Join-Path $modelWork 'crosscheck.json'

                $curRegSnap = Read-Registry -Paths $paths
                $activeSnap = @(
                    @(Get-OrchestraArray $curRegSnap 'models') |
                        Where-Object { [string](Get-OrchestraProperty $_ 'status') -eq 'active' }
                )
                # Prefer an active model with web_search (and already evaluated if possible) as researcher
                $researcherCandidates = @(
                    $activeSnap | Sort-Object `
                        @{ Expression = { if (@(Get-OrchestraArray $_ 'tools') -contains 'web_search') { 1 } else { 0 } }; Descending = $true },
                        @{ Expression = { if (-not (Test-ModelNeedsEvaluation $_)) { 1 } else { 0 } }; Descending = $true },
                        @{ Expression = { Get-ModelCapScore -ModelObj $_ -Dimension 'world_knowledge' }; Descending = $true }
                )
                $researcherId = [string]$researcherCandidates[0].id
                $researcherVendor = [string]$researcherCandidates[0].vendor

                $leaseAcquired = $false
                try {
                    $pRun = Invoke-ChildScriptJson -ScriptPath (Join-Path $PSScriptRoot 'research-prompt.ps1') -Arguments @(
                        '-ModelId', $evalId, '-Mode', 'new', '-OutFile', $promptFile,
                        '-RegistryPath', $paths.Registry, '-StateDir', $paths.StateDir
                    ) -WorkDir $paths.Root -TimeoutSec 60
                    if ($pRun.exit_code -eq 0 -and [IO.File]::Exists($promptFile)) {
                        $leaseAcquired = $true
                        $invRun = Invoke-ChildScriptJson -ScriptPath (Join-Path $PSScriptRoot 'invoke-model.ps1') -Arguments @(
                            '-Model', $researcherId, '-Access', 'read',
                            '-PromptFile', $promptFile,
                            '-JsonSchema', (Join-Path $paths.Root 'registry\research.schema.json'),
                            '-OutFile', $resOutFile,
                            '-Tags', 'research',
                            '-WorkDir', $modelWork,
                            '-RegistryPath', $paths.Registry, '-StateDir', $paths.StateDir
                        ) -WorkDir $modelWork -TimeoutSec 900

                        if ($invRun.exit_code -eq 0 -and [IO.File]::Exists($resOutFile)) {
                            $resDoc = Read-JsonFile -Path $resOutFile
                            $disputedMap = @{}
                            $auditorPool = @(
                                $activeSnap |
                                    Where-Object { [string]$_.vendor -cne $researcherVendor -and -not [bool](Get-OrchestraProperty $_ 'primary_disabled' $false) } |
                                    Sort-Object @{ Expression = { Get-ModelCapScore -ModelObj $_ -Dimension 'code_rigor' }; Descending = $true }
                            )
                            if ($auditorPool.Count -gt 0) {
                                $auditorId = [string]$auditorPool[0].id
                                Write-JsonAtomic -Path $crossSchemaFile -Object $crossSchemaObj
                                $rawResJson = [IO.File]::ReadAllText($resOutFile, $script:OrchestraUtf8)
                                $crossPrompt = @(
                                    'Audit the following model evaluation JSON strictly for unsupported capability scores, missing/invalid evidence URLs, or benchmark exaggerations.'
                                    'Do NOT invoke any shell or file tools. Output ONLY valid JSON matching: {"disputed":[{"cap":"...","reason":"...","suggested_score":7.0}]}. Return {"disputed":[]} if well-supported.'
                                    ''
                                    '```json'
                                    $rawResJson
                                    '```'
                                ) -join "`n"
                                [IO.File]::WriteAllText($crossPromptFile, $crossPrompt, $script:OrchestraUtf8)
                                $cRun = Invoke-ChildScriptJson -ScriptPath (Join-Path $PSScriptRoot 'invoke-model.ps1') -Arguments @(
                                    '-Model', $auditorId, '-Access', 'read',
                                    '-PromptFile', $crossPromptFile,
                                    '-JsonSchema', $crossSchemaFile,
                                    '-OutFile', $crossOutFile,
                                    '-Tags', 'research',
                                    '-WorkDir', $modelWork,
                                    '-RegistryPath', $paths.Registry, '-StateDir', $paths.StateDir
                                ) -WorkDir $modelWork -TimeoutSec 600
                                if ($cRun.exit_code -eq 0 -and [IO.File]::Exists($crossOutFile)) {
                                    $cDoc = Read-JsonFile -Path $crossOutFile
                                    foreach ($dItem in @(Get-OrchestraArray $cDoc 'disputed')) {
                                        $dCap = [string](Get-OrchestraProperty $dItem 'cap' '')
                                        $dSug = Get-OrchestraProperty $dItem 'suggested_score' $null
                                        if (-not [string]::IsNullOrWhiteSpace($dCap) -and $null -ne $dSug) {
                                            $disputedMap[$dCap] = [double]$dSug
                                        }
                                    }
                                }
                            }

                            Invoke-WithLock -Paths $paths -Name registry -ScriptBlock {
                                $fReg = Read-Registry -Paths $paths
                                $tModel = @($fReg.models | Where-Object { [string]$_.id -ceq $evalId })[0]
                                if ($null -ne $tModel) {
                                    $tCaps = Get-OrchestraProperty $tModel 'caps'
                                    $rCaps = Get-OrchestraProperty $resDoc 'caps'
                                    foreach ($dim in @(Get-OrchestraArray $fReg 'cap_dimensions' | ForEach-Object { [string]$_ })) {
                                        $rCap = Get-OrchestraProperty $rCaps $dim
                                        $tCap = Get-OrchestraProperty $tCaps $dim
                                        if ($null -eq $rCap -or $null -eq $tCap) { continue }
                                        $isLocked = [bool](Get-OrchestraProperty $tCap 'locked' $false)
                                        $isBoot = ([string](Get-OrchestraProperty $tCap 'source' '') -eq 'bootstrap')
                                        if ($isLocked -and -not $isBoot) { continue }
                                        $val = [double](Get-OrchestraProperty $rCap 'score' 7.0)
                                        if ($disputedMap.ContainsKey($dim)) {
                                            $val = [Math]::Min($val, [double]$disputedMap[$dim])
                                        }
                                        $val = [Math]::Round([Math]::Max(0.0, [Math]::Min(10.0, $val)), 1)
                                        $conf = [double](Get-OrchestraProperty $rCap 'confidence' 0.6)
                                        $evArr = @(Get-OrchestraArray $rCap 'evidence')
                                        Set-OrchestraProperty $tCap 'score' $val
                                        Set-OrchestraProperty $tCap 'approved_score' $val
                                        Set-OrchestraProperty $tCap 'source' 'research'
                                        Set-OrchestraProperty $tCap 'confidence' $conf
                                        Set-OrchestraProperty $tCap 'evidence' $evArr
                                        $researchScoresThisRun[$dim] = $val
                                        if (-not $updatedDims.Contains($dim)) { [void]$updatedDims.Add($dim) }
                                    }
                                    if (-not [bool](Get-OrchestraProperty $tModel 'ranks_locked' $false)) {
                                        $sHint = Get-OrchestraProperty $resDoc 'speed_rank_hint' $null
                                        $qHint = Get-OrchestraProperty $resDoc 'quota_rank_hint' $null
                                        if ($null -ne $sHint) { Set-OrchestraProperty $tModel 'speed_rank' ([int]$sHint) }
                                        if ($null -ne $qHint) { Set-OrchestraProperty $tModel 'quota_rank' ([int]$qHint) }
                                    }
                                    $nStr = @(Get-OrchestraArray $resDoc 'notable_strengths' | ForEach-Object { [string]$_ })
                                    $nWeak = @(Get-OrchestraArray $resDoc 'notable_weaknesses' | ForEach-Object { [string]$_ })
                                    if ($nStr.Count -gt 0) { Set-OrchestraProperty $tModel 'strengths' ([string[]]$nStr) }
                                    if ($nWeak.Count -gt 0) { Set-OrchestraProperty $tModel 'weaknesses' ([string[]]$nWeak) }
                                    Set-OrchestraProperty $tModel 'last_researched' ((Get-OrchestraNow).ToString('yyyy-MM-dd'))
                                    Update-RosterBindings -Registry $fReg
                                    Write-JsonAtomic -Path $paths.Registry -Object $fReg
                                }
                            }
                            $evalRecord['research_status'] = 'ok'
                        }
                        else {
                            $evalRecord['research_status'] = 'failed'
                        }
                    }
                    else {
                        $evalRecord['research_status'] = 'prompt_failed'
                    }
                }
                finally {
                    if ($leaseAcquired) {
                        $null = Invoke-ChildScriptJson -ScriptPath (Join-Path $PSScriptRoot 'research-prompt.ps1') -Arguments @(
                            '-ModelId', $evalId, '-ReleaseLease',
                            '-RegistryPath', $paths.Registry, '-StateDir', $paths.StateDir
                        ) -WorkDir $paths.Root -TimeoutSec 30
                    }
                }
            }

            if ($doProbe) {
                $probeArgs = @(
                    '-ModelId', $evalId, '-Grade',
                    '-RegistryPath', $paths.Registry, '-StateDir', $paths.StateDir
                )
                if (-not $isCanonicalRepo) {
                    $probeArgs += @('-ReportDir', (Join-Path $paths.StateDir 'probe-results'))
                }
                $prRun = Invoke-ChildScriptJson -ScriptPath (Join-Path $PSScriptRoot 'probe-model.ps1') -Arguments $probeArgs -WorkDir $paths.Root -TimeoutSec 2400
                if ($prRun.exit_code -eq 0 -and $null -ne $prRun.json) {
                    Invoke-WithLock -Paths $paths -Name registry -ScriptBlock {
                        $fReg = Read-Registry -Paths $paths
                        $tModel = @($fReg.models | Where-Object { [string]$_.id -ceq $evalId })[0]
                        if ($null -ne $tModel) {
                            $tCaps = Get-OrchestraProperty $tModel 'caps'
                            foreach ($rItem in @(Get-OrchestraArray $prRun.json 'results')) {
                                $g = Get-OrchestraProperty $rItem 'grade'
                                if ($null -eq $g) { continue }
                                $dim = [string](Get-OrchestraProperty $g 'dimension' '')
                                $tCap = Get-OrchestraProperty $tCaps $dim
                                if ($null -eq $tCap) { continue }
                                $isLocked = [bool](Get-OrchestraProperty $tCap 'locked' $false)
                                $isBoot = ([string](Get-OrchestraProperty $tCap 'source' '') -eq 'bootstrap')
                                if ($isLocked -and -not $isBoot) { continue }
                                $pScore = [double](Get-OrchestraProperty $g 'cap_score_10' 7.0)
                                $blended = if ($researchScoresThisRun.ContainsKey($dim)) {
                                    [Math]::Round((0.5 * [double]$researchScoresThisRun[$dim]) + (0.5 * $pScore), 1)
                                }
                                else {
                                    [Math]::Round($pScore, 1)
                                }
                                $blended = [Math]::Max(0.0, [Math]::Min(10.0, $blended))
                                $probeEv = [pscustomobject]@{
                                    url = ('probe://evals/probe/' + [string]$rItem.probe)
                                    claim = ('Setup blind probe ' + [string]$g.total_15 + '/15 (' + $pScore + '/10) judged by ' + [string]$g.judge + ': ' + [string]$g.rationale)
                                    date = (Get-OrchestraNow).ToString('yyyy-MM-dd')
                                }
                                $existingEv = @(Get-OrchestraArray $tCap 'evidence')
                                Set-OrchestraProperty $tCap 'score' $blended
                                Set-OrchestraProperty $tCap 'approved_score' $blended
                                Set-OrchestraProperty $tCap 'source' $(if ($researchScoresThisRun.ContainsKey($dim)) { 'research+probe' } else { 'probe' })
                                Set-OrchestraProperty $tCap 'confidence' 0.8
                                Set-OrchestraProperty $tCap 'evidence' ($existingEv + @($probeEv))
                                if (-not $updatedDims.Contains($dim)) { [void]$updatedDims.Add($dim) }
                            }
                            if ([string]::IsNullOrWhiteSpace([string](Get-OrchestraProperty $tModel 'last_researched' ''))) {
                                Set-OrchestraProperty $tModel 'last_researched' ((Get-OrchestraNow).ToString('yyyy-MM-dd'))
                            }
                            Update-RosterBindings -Registry $fReg
                            Write-JsonAtomic -Path $paths.Registry -Object $fReg
                        }
                    }
                    $evalRecord['probe_status'] = 'ok'
                }
                else {
                    $evalRecord['probe_status'] = 'failed'
                }
            }

            $evalRecord['updated_dimensions'] = [string[]]$updatedDims.ToArray()
            [void]$evaluationResults.Add([pscustomobject]$evalRecord)
        }
    }

    # Step 4: Sync managed docs if target docRoot contains SKILL.md
    $docsSynced = $false
    if ([IO.File]::Exists((Join-Path $docRoot 'SKILL.md'))) {
        $syncRun = Invoke-ChildScriptJson -ScriptPath (Join-Path $PSScriptRoot 'sync-docs.ps1') -Arguments @(
            '-RegistryPath', $paths.Registry, '-Root', $docRoot
        ) -WorkDir $paths.Root -TimeoutSec 60
        $docsSynced = ($syncRun.exit_code -eq 0)
    }

    # Step 5: Doctor verification
    $docArgs = @('-Repair', '-NoNetwork', '-CodexDestination', $(if ($SkipJunction) { '' } else { $CodexDestination }), '-RegistryPath', $paths.Registry, '-StateDir', $paths.StateDir)
    $docCheck = Invoke-ChildScriptJson -ScriptPath (Join-Path $PSScriptRoot 'doctor.ps1') -Arguments $docArgs -WorkDir $paths.Root -TimeoutSec 60

    $finalReg = Read-Registry -Paths $paths
    Write-OrchestraResult -Object ([ordered]@{
        registry_rev = [long](Get-OrchestraProperty $finalReg 'registry_rev' 0)
        active_models = [string[]]$selectedIds.ToArray()
        review_only_models = [string[]]$resolvedReviewOnly.ToArray()
        added_models = [string[]]$addedModels.ToArray()
        retired_models = [string[]]$retiredModels.ToArray()
        aliases = (Get-OrchestraProperty $finalReg 'aliases')
        evaluate_mode = $Evaluate
        evaluations = $evaluationResults.ToArray()
        junction_synced = [bool]$junctionSynced
        global_plugin_synced = [bool]$globalPluginSynced
        docs_synced = [bool]$docsSynced
        doctor_healthy = $(if ($null -ne $docCheck.json) { [bool](Get-OrchestraProperty $docCheck.json 'healthy' $false) } else { $false })
        backup = $backupRelPath
    })
    exit 0
}
catch {
    $msg = $_.Exception.Message
    $code = Get-OrchestraExitCode -Message $msg
    [Console]::Error.WriteLine($msg)
    Write-OrchestraResult -Object @{
        error = $msg
        exit = $code
    }
    exit $code
}
finally {
    if ([IO.Directory]::Exists($tempEvalDir)) {
        try { Remove-Item -LiteralPath $tempEvalDir -Recurse -Force } catch {}
    }
}
