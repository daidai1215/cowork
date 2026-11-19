<#
.SYNOPSIS
Synchronize or verify managed roster and routing blocks across cowork docs.
.DESCRIPTION
Reads registry/models.json and clean-state route.ps1 outputs to deterministically
render <!-- AUTO:ROSTER:START/END --> and <!-- AUTO:ROUTING:START/END --> blocks
in SKILL.md, references/model-profiles.md, and README.md.
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [string]$RegistryPath,
    [string]$Root
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function U {
    param([string]$Escaped)
    return [regex]::Unescape($Escaped)
}

$script:RouteCapabilityCache = @{}

function Get-RouteCapabilities {
    param([string]$RouteScript)
    $key = [IO.Path]::GetFullPath($RouteScript)
    if ($script:RouteCapabilityCache.ContainsKey($key)) {
        return $script:RouteCapabilityCache[$key]
    }
    $supportsFast = $false
    $cmd = Get-Command -Name $key -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and $null -ne $cmd.Parameters -and $cmd.Parameters.Count -gt 0) {
        $supportsFast = ($cmd.Parameters.ContainsKey('RegistryObject') -and $cmd.Parameters.ContainsKey('SkipTelemetry'))
    }
    else {
        $parseTokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($key, [ref]$parseTokens, [ref]$parseErrors)
        if ($null -ne $ast -and $null -ne $ast.ParamBlock) {
            $paramNames = @($ast.ParamBlock.Parameters | ForEach-Object { [string]$_.Name.VariablePath.UserPath })
            $supportsFast = (($paramNames -contains 'RegistryObject') -and ($paramNames -contains 'SkipTelemetry'))
        }
    }
    $script:RouteCapabilityCache[$key] = $supportsFast
    return $supportsFast
}

function Invoke-CleanRoute {
    param(
        [string]$RouteScript,
        [string]$TagsCsv,
        [string]$RegistryFile,
        [string]$EmptyStateDir,
        [string]$ModeName = '',
        $Registry = $null
    )
    $supportsFast = Get-RouteCapabilities -RouteScript $RouteScript
    $routeArgs = @{
        Tags = $TagsCsv
        RegistryPath = $RegistryFile
        StateDir = $EmptyStateDir
    }
    if (-not [string]::IsNullOrWhiteSpace($ModeName)) {
        $routeArgs['Mode'] = $ModeName
    }
    if ($supportsFast -and $null -ne $Registry) {
        $routeArgs['RegistryObject'] = $Registry
        $routeArgs['SkipTelemetry'] = $true
    }
    $savedOut = [Console]::Out
    $writer = New-Object IO.StringWriter
    [Console]::SetOut($writer)
    try {
        & $RouteScript @routeArgs
    }
    finally {
        [Console]::SetOut($savedOut)
    }
    $raw = $writer.ToString().Trim()
    $writer.Dispose()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "ORCHESTRA_EXTERNAL: route.ps1 produced empty output for tags '$TagsCsv'."
    }
    $lines = @($raw -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return ($lines[$lines.Count - 1] | ConvertFrom-Json)
}

function Format-RankLabel {
    param([int]$Rank, [string]$Kind)
    return [string]$Rank
}

function Build-RosterBlock {
    param($Registry)
    $rev = [long](Get-OrchestraProperty $Registry 'registry_rev' 0)
    $dimensions = @(Get-OrchestraArray $Registry 'cap_dimensions')
    $active = @(
        @(Get-OrchestraArray $Registry 'models') |
            Where-Object { [string](Get-OrchestraProperty $_ 'status') -eq 'active' }
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add(
        '> Auto-synced from `registry/models.json` (`registry_rev: ' + $rev + '`, active: ' + $active.Count + ')'
    )
    [void]$lines.Add('')
    [void]$lines.Add(
        '|Model|ID (Ch)|Effort|Strengths (>=9)|Q|S|Traits|'
    )
    [void]$lines.Add('|---|---|---|---|---|---|---|')

    foreach ($model in $active) {
        $id = [string](Get-OrchestraProperty $model 'id')
        $display = [string](Get-OrchestraProperty $model 'display_name' $id)
        $channel = [string](Get-OrchestraProperty $model 'channel')
        $invoke = Get-OrchestraProperty $model 'invoke'
        $effort = [string](Get-OrchestraProperty $invoke 'default_effort' 'high')
        $peakEffort = [string](Get-OrchestraProperty $invoke 'peak_effort' '')
        $effortCell = if (-not [string]::IsNullOrWhiteSpace($peakEffort) -and $peakEffort -cne $effort) {
            '`{0}`/`{1}`' -f $effort, $peakEffort
        }
        else {
            '`{0}`' -f $effort
        }
        $qRank = [int](Get-OrchestraProperty $model 'quota_rank' 2)
        $sRank = [int](Get-OrchestraProperty $model 'speed_rank' 2)
        $capsObj = Get-OrchestraProperty $model 'caps'
        $topCaps = New-Object 'System.Collections.Generic.List[object]'
        foreach ($dim in $dimensions) {
            $capEntry = Get-OrchestraProperty $capsObj ([string]$dim)
            if ($null -eq $capEntry) { continue }
            $score = [double](Get-OrchestraProperty $capEntry 'score' 0)
            if ($score -ge 9.0) {
                [void]$topCaps.Add([pscustomobject]@{ dim = [string]$dim; score = $score })
            }
        }
        $orderedCaps = @(
            $topCaps.ToArray() |
                Sort-Object @{ Expression = { $_.score }; Descending = $true }, @{ Expression = { $_.dim }; Ascending = $true } |
                ForEach-Object { '{0}({1})' -f $_.dim, $_.score }
        )
        $capText = if ($orderedCaps.Count -gt 0) { $orderedCaps -join ', ' } else { '-' }

        $traits = New-Object 'System.Collections.Generic.List[string]'
        if ([bool](Get-OrchestraProperty $model 'primary_disabled' $false)) {
            [void]$traits.Add('Review only')
        }
        if ([bool](Get-OrchestraProperty $invoke 'account_rotation' $false)) {
            [void]$traits.Add('Cockpit')
        }
        $tools = @(Get-OrchestraArray $model 'tools')
        if ($tools.Count -gt 0) {
            [void]$traits.Add(('`' + ($tools -join '`, `') + '`'))
        }
        $traitText = if ($traits.Count -gt 0) { $traits -join '; ' } else { '-' }

        [void]$lines.Add((
            '|**{0}**|`{1}` (`{2}`)|{3}|{4}|{5}|{6}|{7}|' -f
            $display, $id, $channel, $effortCell, $capText,
            (Format-RankLabel $qRank 'quota'),
            (Format-RankLabel $sRank 'speed'),
            $traitText
        ))
    }

    $policyObj = Get-OrchestraProperty $Registry 'policy'
    $poolLimitsObj = Get-OrchestraProperty $policyObj 'pool_concurrency_limits'
    if ($null -ne $poolLimitsObj) {
        $poolPairs = @(
            foreach ($pKey in @('codex_openai', 'agy_anthropic', 'agy_google')) {
                $pVal = Get-OrchestraProperty $poolLimitsObj $pKey
                if ($null -ne $pVal) { '`{0}`<={1}' -f $pKey, [int]$pVal }
            }
        )
        if ($poolPairs.Count -gt 0) {
            [void]$lines.Add('')
            [void]$lines.Add(('- **Pools**: ' + ($poolPairs -join ', ')))
        }
    }
    return ($lines.ToArray() -join "`n")
}

function Format-RouteModelCell {
    param($ModelName, [string]$Effort, [bool]$IsBlocked = $false, [bool]$CheckBlocked = $false)
    if ($CheckBlocked -and ($IsBlocked -or $null -eq $ModelName)) {
        return 'BLOCKED'
    }
    if ($null -eq $ModelName) { return '-' }
    if (-not [string]::IsNullOrWhiteSpace($Effort)) {
        return ('`{0}` (`{1}`)' -f [string]$ModelName, $Effort)
    }
    return ('`' + [string]$ModelName + '`')
}

function Build-RoutingBlock {
    param($Registry, [string]$RouteScript, [string]$RegistryFile, [string]$EmptyStateDir)
    $aliasesObj = Get-OrchestraProperty $Registry 'aliases'
    $aliasPairs = @(
        @(Get-OrchestraNames $aliasesObj) |
            Sort-Object |
            ForEach-Object {
                $target = [string](Get-OrchestraProperty $aliasesObj $_)
                '`{0}`->`{1}`' -f $_, $target
            }
    )

    $scenarios = @(
        [pscustomobject]@{ label = 'Frontend/UI'; tags = 'frontend,landing_page' }
        [pscustomobject]@{ label = 'Backend/API'; tags = 'backend,concurrency' }
        [pscustomobject]@{ label = 'Math/Algo'; tags = 'math,algorithm' }
        [pscustomobject]@{ label = 'Bugfix'; tags = 'bugfix' }
        [pscustomobject]@{ label = 'Paper/Prose'; tags = 'prose,paper' }
        [pscustomobject]@{ label = 'Image Gen'; tags = 'image_gen' }
        [pscustomobject]@{ label = 'Office/PPT'; tags = 'office,ppt' }
        [pscustomobject]@{ label = 'Research'; tags = 'research,long_context' }
    )

    $policyObj = Get-OrchestraProperty $Registry 'policy'
    $defaultEffort = [string](Get-OrchestraProperty $policyObj 'default_effort' 'high')
    $defaultMode = [string](Get-OrchestraProperty $policyObj 'default_mode' 'peak')

    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add(('- **Mode**: `' + $defaultMode + '` | **Aliases**: ' + ($aliasPairs -join ', ')))
    [void]$lines.Add('')

    $peakRows = New-Object 'System.Collections.Generic.List[object]'
    $hasPolisher = $false
    foreach ($sc in $scenarios) {
        $route = Invoke-CleanRoute -RouteScript $RouteScript -TagsCsv $sc.tags -RegistryFile $RegistryFile -EmptyStateDir $EmptyStateDir -Registry $Registry
        $pEffort = [string](Get-OrchestraProperty $route 'primary_effort' '')
        $primaryCell = if ([bool](Get-OrchestraProperty $route 'blocked' $false) -or $null -eq $route.primary) {
            'BLOCKED'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($pEffort) -and $pEffort -cne $defaultEffort) {
            '`{0}` (`{1}`)' -f [string]$route.primary, $pEffort
        }
        else {
            '`' + [string]$route.primary + '`'
        }
        $reviewerCell = if ($null -eq $route.reviewer) { '-' } else { '`' + [string]$route.reviewer + '`' }
        $polisherCell = if ($null -eq $route.polisher) { '-' } else { $hasPolisher = $true; '`' + [string]$route.polisher + '`' }
        $patternCell = '`' + [string](Get-OrchestraProperty $route 'pattern' 'solo') + '`'
        [void]$peakRows.Add([pscustomobject]@{
            label = $sc.label; tags = $sc.tags; primary = $primaryCell; reviewer = $reviewerCell; polisher = $polisherCell; pattern = $patternCell
        })
    }

    if ($hasPolisher) {
        [void]$lines.Add('|`-Tags`|Primary|Reviewer|Polisher|Pattern|')
        [void]$lines.Add('|---|---|---|---|---|')
        foreach ($pr in $peakRows) {
            [void]$lines.Add(('|`{0}`|{1}|{2}|{3}|{4}|' -f $pr.tags, $pr.primary, $pr.reviewer, $pr.polisher, $pr.pattern))
        }
    }
    else {
        [void]$lines.Add('|`-Tags`|Primary|Reviewer|Pattern|')
        [void]$lines.Add('|---|---|---|---|')
        foreach ($pr in $peakRows) {
            [void]$lines.Add(('|`{0}`|{1}|{2}|{3}|' -f $pr.tags, $pr.primary, $pr.reviewer, $pr.pattern))
        }
    }

    $modesObj = Get-OrchestraProperty $Registry 'modes'
    $fastMapObj = Get-OrchestraProperty $policyObj 'fast_workhorse_map'
    if ($null -ne (Get-OrchestraProperty $modesObj 'fast_4h') -and $null -ne $fastMapObj) {
        $toM = [string](Get-OrchestraProperty $fastMapObj 'to_model' 'gemini-4-hydrogen')
        $fromM = [string](Get-OrchestraProperty $fastMapObj 'from_model' 'gemini-4-carbon')
        $retainP = @(Get-OrchestraArray $fastMapObj 'retain_primary_tags' | ForEach-Object { [string]$_ }) -join '/'
        $retainR = @(Get-OrchestraArray $fastMapObj 'retain_reviewer_tags' | ForEach-Object { [string]$_ }) -join '/'
        [void]$lines.Add('')
        [void]$lines.Add(('- **`-Mode fast_4h`**: `' + $fromM + '`->`' + $toM + '` (`xhigh`), except `' + $retainP + '` (`' + $retainR + '` rev) & `-AllowEscalation`.'))
    }

    $hostTierRows = @(
        [pscustomobject]@{ host = 'orchestrator'; mode = 'orchestrator_fast'; tags = 'frontend,landing_page' }
        [pscustomobject]@{ host = 'orchestrator'; mode = 'orchestrator_fast'; tags = 'architecture' }
        [pscustomobject]@{ host = 'neon'; mode = 'neon_peak'; tags = 'frontend,landing_page' }
        [pscustomobject]@{ host = 'neon'; mode = 'neon_peak'; tags = 'bulk,scan' }
        [pscustomobject]@{ host = 'carbon'; mode = 'carbon_peak'; tags = 'frontend,landing_page' }
        [pscustomobject]@{ host = 'carbon'; mode = 'carbon_peak'; tags = 'bulk,scan' }
        [pscustomobject]@{ host = 'hydrogen'; mode = 'hydrogen_max'; tags = 'bugfix' }
        [pscustomobject]@{ host = 'hydrogen'; mode = 'hydrogen_max'; tags = 'prose,paper' }
    ) | Where-Object { $null -ne (Get-OrchestraProperty $modesObj $_.mode) }

    if (@($hostTierRows).Count -gt 0) {
        $tierModeNames = New-Object 'System.Collections.Generic.List[string]'
        foreach ($row in $hostTierRows) {
            if (-not $tierModeNames.Contains($row.mode)) { [void]$tierModeNames.Add($row.mode) }
        }
        $tierModeList = ($tierModeNames.ToArray() | ForEach-Object { '`' + $_ + '`' }) -join '/'
        $tierNote = if ($tierModeNames.Contains('neon_peak')) {
            '`Neon`: `high` (`math`/`arch` `xhigh`, `bulk`/`scan`->`4H`); `4H`: `scan`->`med`, `bulk`/`boilerplate`/`test_gen`->`high`, else `xhigh`'
        }
        else {
            '`4H`: `scan`->`med`, `bulk`/`boilerplate`/`test_gen`->`high`, else `xhigh`'
        }
        [void]$lines.Add('')
        [void]$lines.Add(
            ('- **Host Tiers (`-HostModel`)**: {0} ({1}):' -f $tierModeList, $tierNote)
        )
        [void]$lines.Add('')
        [void]$lines.Add('|Host|`-Tags`|Primary|Reviewer|Gate|')
        [void]$lines.Add('|---|---|---|---|---|')
        foreach ($row in $hostTierRows) {
            $hr = Invoke-CleanRoute -RouteScript $RouteScript -TagsCsv $row.tags -ModeName $row.mode -RegistryFile $RegistryFile -EmptyStateDir $EmptyStateDir -Registry $Registry
            $hpEff = [string](Get-OrchestraProperty $hr 'primary_effort' '')
            $hpCell = Format-RouteModelCell -ModelName $hr.primary -Effort $hpEff -IsBlocked ([bool](Get-OrchestraProperty $hr 'blocked' $false)) -CheckBlocked $true
            $hrEff = [string](Get-OrchestraProperty $hr 'reviewer_effort' '')
            $hrCell = Format-RouteModelCell -ModelName $hr.reviewer -Effort $hrEff
            $orchObj = Get-OrchestraProperty $hr 'orchestration'
            $finRev = [string](Get-OrchestraProperty $orchObj 'final_reviewer' '')
            $hfCell = if ([string]::IsNullOrWhiteSpace($finRev)) { '-' } else { '`' + $finRev + '`' }
            $modeCell = '`{0}`' -f $row.host
            [void]$lines.Add(('|{0}|`{1}`|{2}|{3}|{4}|' -f $modeCell, $row.tags, $hpCell, $hrCell, $hfCell))
        }
    }
    return ($lines.ToArray() -join "`n")
}

function Build-ProfilesBlock {
    param($Registry)
    $rev = [long](Get-OrchestraProperty $Registry 'registry_rev' 0)
    $dimensions = @(Get-OrchestraArray $Registry 'cap_dimensions')
    $active = @(
        @(Get-OrchestraArray $Registry 'models') |
            Where-Object { [string](Get-OrchestraProperty $_ 'status') -eq 'active' }
    )
    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add(
        '> Auto-synced from `registry/models.json` (`registry_rev: ' + $rev + '`, active: ' + $active.Count + ')'
    )
    [void]$lines.Add('')
    $idx = 0
    foreach ($model in $active) {
        $idx++
        if ($idx -gt 1) {
            [void]$lines.Add('')
            [void]$lines.Add('---')
            [void]$lines.Add('')
        }
        $id = [string](Get-OrchestraProperty $model 'id')
        $display = [string](Get-OrchestraProperty $model 'display_name' $id)
        $vendor = [string](Get-OrchestraProperty $model 'vendor' 'unknown')
        $channel = [string](Get-OrchestraProperty $model 'channel' 'agy')
        $invoke = Get-OrchestraProperty $model 'invoke'
        $effort = [string](Get-OrchestraProperty $invoke 'default_effort' 'high')
        $peakEffort = [string](Get-OrchestraProperty $invoke 'peak_effort' '')
        $effortTag = if (-not [string]::IsNullOrWhiteSpace($peakEffort) -and $peakEffort -cne $effort) {
            '`{0}` / peak `{1}`' -f $effort, $peakEffort
        }
        else {
            '`{0}`' -f $effort
        }
        $qRank = [int](Get-OrchestraProperty $model 'quota_rank' 2)
        $sRank = [int](Get-OrchestraProperty $model 'speed_rank' 2)
        $roleNote = if ([bool](Get-OrchestraProperty $model 'primary_disabled' $false)) {
            ' | Review/gate only (primary disabled)'
        }
        else { '' }

        [void]$lines.Add(('## {0}. {1} ({2}) -- `{3}` / `{4}`{5}' -f $idx, $display, $effortTag, $vendor, $channel, $roleNote))
        [void]$lines.Add('')

        $capsObj = Get-OrchestraProperty $model 'caps'
        $scoreItems = New-Object 'System.Collections.Generic.List[string]'
        foreach ($dim in $dimensions) {
            $capEntry = Get-OrchestraProperty $capsObj ([string]$dim)
            if ($null -eq $capEntry) { continue }
            $sc = [double](Get-OrchestraProperty $capEntry 'score' 0)
            $lk = if ([bool](Get-OrchestraProperty $capEntry 'locked' $false)) { '*' } else { '' }
            [void]$scoreItems.Add(('`{0}`: {1}{2}' -f $dim, $sc, $lk))
        }
        [void]$lines.Add(('- **10-Dim Scores** (`*`=locked): ' + ($scoreItems -join ', ')))
        [void]$lines.Add(('- **Quota / Speed**: `quota_rank=' + (Format-RankLabel $qRank 'quota') + '`, `speed_rank=' + (Format-RankLabel $sRank 'speed') + '`'))

        $strengths = @(Get-OrchestraArray $model 'strengths')
        if ($strengths.Count -gt 0) {
            [void]$lines.Add('')
            [void]$lines.Add('**Core Strengths**:')
            foreach ($s in $strengths) {
                [void]$lines.Add(('- ' + [string]$s))
            }
        }
        $weaknesses = @(Get-OrchestraArray $model 'weaknesses')
        if ($weaknesses.Count -gt 0) {
            [void]$lines.Add('')
            [void]$lines.Add('**Weaknesses & Pitfalls**:')
            foreach ($w in $weaknesses) {
                [void]$lines.Add(('- ' + [string]$w))
            }
        }
    }
    return ($lines.ToArray() -join "`n")
}

function Update-ManagedSection {
    param(
        [string]$Content,
        [string]$MarkerName,
        [string]$NewInner,
        [string]$Newline
    )
    $startTag = "<!-- AUTO:${MarkerName}:START -->"
    $endTag = "<!-- AUTO:${MarkerName}:END -->"
    $pattern = '(?s)' + [regex]::Escape($startTag) + '.*?' + [regex]::Escape($endTag)
    $matches = [regex]::Matches($Content, $pattern)
    if ($matches.Count -ne 1) {
        return [pscustomobject]@{
            ok = $false
            reason = "Expected exactly 1 $startTag ... $endTag block, found $($matches.Count)."
            content = $Content
        }
    }
    $normalizedInner = ($NewInner -replace '\r?\n', $Newline)
    $replacement = $startTag + $Newline + $normalizedInner + $Newline + $endTag
    $updated = [regex]::Replace($Content, $pattern, { param($m) $replacement }, 1)
    return [pscustomobject]@{
        ok = $true
        reason = ''
        content = $updated
    }
}

function Write-DocAtomic {
    param([string]$Path, [string]$Text)
    $target = [IO.Path]::GetFullPath($Path)
    $dir = [IO.Path]::GetDirectoryName($target)
    [void][IO.Directory]::CreateDirectory($dir)
    $tmp = Join-Path $dir ('.' + [IO.Path]::GetFileName($target) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($tmp, $Text, $script:OrchestraUtf8)
        if ([IO.File]::Exists($target)) {
            [IO.File]::Replace($tmp, $target, [NullString]::Value)
        }
        else {
            [IO.File]::Move($tmp, $target)
        }
    }
    finally {
        if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) }
    }
}

$tempStateDir = Join-Path ([IO.Path]::GetTempPath()) ('cowork-syncdocs-' + [Guid]::NewGuid().ToString('N'))
try {
    $paths = Get-OrchestraPaths -RegistryPath $RegistryPath
    $docRoot = if ([string]::IsNullOrWhiteSpace($Root)) { $paths.Root } else { [IO.Path]::GetFullPath($Root) }
    if (-not [IO.Directory]::Exists($docRoot)) {
        throw "ORCHESTRA_ARGS: Document root does not exist: $docRoot"
    }

    $registry = Read-Registry -Paths $paths
    [void][IO.Directory]::CreateDirectory($tempStateDir)
    $routeScript = Join-Path $PSScriptRoot 'route.ps1'

    $rosterBlock = Build-RosterBlock -Registry $registry
    $routingBlock = Build-RoutingBlock -Registry $registry -RouteScript $routeScript -RegistryFile $paths.Registry -EmptyStateDir $tempStateDir
    $profilesBlock = Build-ProfilesBlock -Registry $registry

    $relativeDocs = @(
        'SKILL.md',
        'references\model-profiles.md',
        'README.md'
    )

    $drifted = New-Object 'System.Collections.Generic.List[string]'
    $updatedFiles = New-Object 'System.Collections.Generic.List[string]'
    $details = New-Object 'System.Collections.Generic.List[object]'

    foreach ($rel in $relativeDocs) {
        $fullPath = Join-Path $docRoot $rel
        if (-not [IO.File]::Exists($fullPath)) {
            [void]$drifted.Add($rel)
            [void]$details.Add([pscustomobject]@{ file = $rel; status = 'missing_file'; detail = 'Target markdown file not found.' })
            continue
        }
        $original = [IO.File]::ReadAllText($fullPath, $script:OrchestraUtf8)
        $newline = if ($original.Contains("`r`n")) { "`r`n" } else { "`n" }
        $finalDocContent = $original
        $markerBlocks = @{
            ROSTER = $rosterBlock
            ROUTING = $routingBlock
            PROFILES = $profilesBlock
        }
        $requiredMarkers = if ($rel -eq 'references\model-profiles.md') { @('PROFILES') } else { @('ROSTER', 'ROUTING') }
        $optionalMarkers = if ($rel -eq 'references\model-profiles.md') { @('ROSTER', 'ROUTING') } else { @('PROFILES') }
        $markerFailed = $false

        foreach ($mName in $requiredMarkers) {
            $step = Update-ManagedSection -Content $finalDocContent -MarkerName $mName -NewInner $markerBlocks[$mName] -Newline $newline
            if (-not $step.ok) {
                [void]$drifted.Add($rel)
                [void]$details.Add([pscustomobject]@{ file = $rel; status = 'missing_marker'; detail = $step.reason })
                $markerFailed = $true
                break
            }
            $finalDocContent = $step.content
        }
        if ($markerFailed) { continue }

        foreach ($mName in $optionalMarkers) {
            $startTag = "<!-- AUTO:${mName}:START -->"
            $endTag = "<!-- AUTO:${mName}:END -->"
            if ($original.Contains($startTag) -or $original.Contains($endTag)) {
                $step = Update-ManagedSection -Content $finalDocContent -MarkerName $mName -NewInner $markerBlocks[$mName] -Newline $newline
                if (-not $step.ok) {
                    [void]$drifted.Add($rel)
                    [void]$details.Add([pscustomobject]@{ file = $rel; status = 'missing_marker'; detail = $step.reason })
                    $markerFailed = $true
                    break
                }
                $finalDocContent = $step.content
            }
        }
        if ($markerFailed) { continue }

        if ($finalDocContent -cne $original) {
            [void]$drifted.Add($rel)
            if ($Check) {
                [void]$details.Add([pscustomobject]@{ file = $rel; status = 'drift'; detail = 'Managed block differs from models.json.' })
            }
            else {
                Write-DocAtomic -Path $fullPath -Text $finalDocContent
                [void]$updatedFiles.Add($rel)
                [void]$details.Add([pscustomobject]@{ file = $rel; status = 'updated'; detail = 'Synchronized managed blocks.' })
            }
        }
        else {
            [void]$details.Add([pscustomobject]@{ file = $rel; status = 'in_sync'; detail = '' })
        }
    }

    $missingMarkerCount = @($details | Where-Object { $_.status -in @('missing_file', 'missing_marker') }).Count
    if (-not $Check -and $missingMarkerCount -gt 0) {
        throw ('ORCHESTRA_EXTERNAL: Managed markers missing in ' + (($details | Where-Object { $_.status -in @('missing_file', 'missing_marker') } | ForEach-Object { $_.file }) -join ', '))
    }

    $driftDetected = ($drifted.Count -gt 0)
    $driftedOut = if ($Check) { [string[]]$drifted.ToArray() } else { [string[]]@() }
    Write-OrchestraResult -Object ([ordered]@{
        check_only = [bool]$Check
        drift_detected = $(if ($Check) { $driftDetected } else { $false })
        drifted_files = $driftedOut
        updated_files = [string[]]$updatedFiles.ToArray()
        registry_rev = [long](Get-OrchestraProperty $registry 'registry_rev' 0)
        files = $details.ToArray()
    })
    if ($Check -and $driftDetected) { exit 1 }
    exit 0
}
catch {
    $message = $_.Exception.Message
    $code = Get-OrchestraExitCode -Message $message
    [Console]::Error.WriteLine($message)
    Write-OrchestraResult -Object @{
        error = $message
        exit = $code
    }
    exit $code
}
finally {
    if ([IO.Directory]::Exists($tempStateDir)) {
        try { Remove-Item -LiteralPath $tempStateDir -Recurse -Force } catch {}
    }
}
