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

function Invoke-CleanRoute {
    param(
        [string]$RouteScript,
        [string]$TagsCsv,
        [string]$RegistryFile,
        [string]$EmptyStateDir
    )
    $savedOut = [Console]::Out
    $writer = New-Object IO.StringWriter
    [Console]::SetOut($writer)
    try {
        & $RouteScript -Tags $TagsCsv -Mode 'balanced' -RegistryPath $RegistryFile -StateDir $EmptyStateDir
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
    if ($Kind -eq 'quota') {
        switch ($Rank) {
            1 { return ('1 (' + (U '\u7a00\u7f3a') + ')') }
            2 { return ('2 (' + (U '\u4e2d\u7b49') + ')') }
            3 { return ('3 (' + (U '\u5145\u88d5') + ')') }
            default { return [string]$Rank }
        }
    }
    else {
        switch ($Rank) {
            1 { return ('1 (' + (U '\u8f83\u6162') + ')') }
            2 { return ('2 (' + (U '\u5c45\u4e2d') + ')') }
            3 { return ('3 (' + (U '\u6700\u5feb') + ')') }
            default { return [string]$Rank }
        }
    }
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
    [void]$lines.Add((
        '> ' + (U '\u81ea\u52a8\u540c\u6b65\u81ea') +
        ' `registry/models.json` (`registry_rev: ' + $rev + '`, ' +
        (U '\u6d3b\u8dc3\u6a21\u578b') + ': ' + $active.Count + ')'
    ))
    [void]$lines.Add('')
    [void]$lines.Add((
        '| ' + (U '\u6a21\u578b') + ' | ID / ' + (U '\u901a\u9053') +
        ' | ' + (U '\u9ed8\u8ba4\u6863\u4f4d') +
        ' | ' + (U '\u9876\u7ea7\u957f\u677f\uff08>=9\uff09') +
        ' | ' + (U '\u989d\u5ea6') + ' (`quota_rank`) | ' +
        (U '\u901f\u5ea6') + ' (`speed_rank`) | ' +
        (U '\u8fd0\u884c\u7279\u6027') + ' |'
    ))
    [void]$lines.Add('|---|---|---|---|---|---|---|')

    foreach ($model in $active) {
        $id = [string](Get-OrchestraProperty $model 'id')
        $display = [string](Get-OrchestraProperty $model 'display_name' $id)
        $channel = [string](Get-OrchestraProperty $model 'channel')
        $invoke = Get-OrchestraProperty $model 'invoke'
        $effort = [string](Get-OrchestraProperty $invoke 'default_effort' 'high')
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
                ForEach-Object { '{0} ({1})' -f $_.dim, $_.score }
        )
        $capText = if ($orderedCaps.Count -gt 0) { $orderedCaps -join ', ' } else { '-' }

        $traits = New-Object 'System.Collections.Generic.List[string]'
        if ([bool](Get-OrchestraProperty $invoke 'account_rotation' $false)) {
            [void]$traits.Add((U 'Cockpit \u81ea\u52a8\u5207\u53f7\u81ea\u6108'))
        }
        $tools = @(Get-OrchestraArray $model 'tools')
        if ($tools.Count -gt 0) {
            [void]$traits.Add(('tools: `' + ($tools -join '`, `') + '`'))
        }
        $traitText = if ($traits.Count -gt 0) { $traits -join '; ' } else { '-' }

        [void]$lines.Add((
            '| **{0}** | `{1}` (`{2}`) | `{3}` | {4} | {5} | {6} | {7} |' -f
            $display, $id, $channel, $effort, $capText,
            (Format-RankLabel $qRank 'quota'),
            (Format-RankLabel $sRank 'speed'),
            $traitText
        ))
    }

    $quotaOrder = @(
        $active |
            Sort-Object @{ Expression = { [int](Get-OrchestraProperty $_ 'quota_rank' 2) }; Ascending = $true }, @{ Expression = { [string]$_.id }; Ascending = $true } |
            ForEach-Object {
                $disp = [string](Get-OrchestraProperty $_ 'display_name' $_.id)
                '{0} (`{1}`)' -f $disp, $_.id
            }
    ) -join ' < '

    $speedOrder = @(
        $active |
            Sort-Object @{ Expression = { [int](Get-OrchestraProperty $_ 'speed_rank' 2) }; Descending = $true }, @{ Expression = { [string]$_.id }; Ascending = $true } |
            ForEach-Object {
                $disp = [string](Get-OrchestraProperty $_ 'display_name' $_.id)
                '{0} (`{1}`)' -f $disp, $_.id
            }
    ) -join ' > '

    [void]$lines.Add('')
    [void]$lines.Add(('- **' + (U '\u53ef\u7528\u989d\u5ea6\u6392\u5e8f\uff08\u4f4e \u2192 \u9ad8\uff09') + '**: ' + $quotaOrder))
    [void]$lines.Add(('- **' + (U '\u54cd\u5e94\u901f\u5ea6\u6392\u5e8f\uff08\u5feb \u2192 \u6162\uff09') + '**: ' + $speedOrder))
    return ($lines.ToArray() -join "`n")
}

function Build-RoutingBlock {
    param($Registry, [string]$RouteScript, [string]$RegistryFile, [string]$EmptyStateDir)
    $aliasesObj = Get-OrchestraProperty $Registry 'aliases'
    $aliasPairs = @(
        @(Get-OrchestraNames $aliasesObj) |
            Sort-Object |
            ForEach-Object {
                $target = [string](Get-OrchestraProperty $aliasesObj $_)
                '`{0}` -> `{1}`' -f $_, $target
            }
    )

    $scenarios = @(
        [pscustomobject]@{ label = (U '\u524d\u7aef\u9875\u9762 / \u843d\u5730\u9875'); tags = 'frontend,landing_page' }
        [pscustomobject]@{ label = (U '\u540e\u7aef / API / \u5e76\u53d1'); tags = 'backend,concurrency' }
        [pscustomobject]@{ label = (U '\u6570\u5b66\u63a8\u5bfc / \u7b97\u6cd5'); tags = 'math,algorithm' }
        [pscustomobject]@{ label = (U '\u8bba\u6587 / \u957f\u6587 / \u6587\u6848'); tags = 'prose,paper' }
        [pscustomobject]@{ label = (U '\u914d\u56fe / \u63d2\u753b / Mockup'); tags = 'image_gen' }
        [pscustomobject]@{ label = 'PPT / Word / Excel'; tags = 'office,ppt' }
        [pscustomobject]@{ label = (U '\u68c0\u7d22 / \u7efc\u8ff0 / \u5927\u4ed3\u5e93\u7406\u89e3'); tags = 'research,long_context' }
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add(('- **' + (U '\u6807\u51c6\u80fd\u529b\u522b\u540d') + '**: ' + ($aliasPairs -join ', ')))
    [void]$lines.Add('')
    [void]$lines.Add((
        '| ' + (U '\u5178\u578b\u573a\u666f') + ' | ' + (U '\u6807\u7b7e') +
        ' (`-Tags`) | ' + (U '\u4e3b\u6267\u884c') + ' (`primary`) | ' +
        (U '\u5ba1\u67e5') + ' (`reviewer`) | ' +
        (U '\u6da6\u8272') + ' (`polisher`) | ' +
        (U '\u534f\u4f5c\u6a21\u5f0f') + ' (`pattern`) |'
    ))
    [void]$lines.Add('|---|---|---|---|---|---|')

    foreach ($sc in $scenarios) {
        $route = Invoke-CleanRoute -RouteScript $RouteScript -TagsCsv $sc.tags -RegistryFile $RegistryFile -EmptyStateDir $EmptyStateDir
        $primaryCell = if ([bool](Get-OrchestraProperty $route 'blocked' $false) -or $null -eq $route.primary) { 'BLOCKED' } else { '`' + [string]$route.primary + '`' }
        $reviewerCell = if ($null -eq $route.reviewer) { '-' } else { '`' + [string]$route.reviewer + '`' }
        $polisherCell = if ($null -eq $route.polisher) { '-' } else { '`' + [string]$route.polisher + '`' }
        $patternCell = '`' + [string](Get-OrchestraProperty $route 'pattern' 'solo') + '`'
        [void]$lines.Add((
            '| {0} | `{1}` | {2} | {3} | {4} | {5} |' -f
            $sc.label, $sc.tags, $primaryCell, $reviewerCell, $polisherCell, $patternCell
        ))
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

        $step1 = Update-ManagedSection -Content $original -MarkerName 'ROSTER' -NewInner $rosterBlock -Newline $newline
        if (-not $step1.ok) {
            [void]$drifted.Add($rel)
            [void]$details.Add([pscustomobject]@{ file = $rel; status = 'missing_marker'; detail = $step1.reason })
            continue
        }
        $step2 = Update-ManagedSection -Content $step1.content -MarkerName 'ROUTING' -NewInner $routingBlock -Newline $newline
        if (-not $step2.ok) {
            [void]$drifted.Add($rel)
            [void]$details.Add([pscustomobject]@{ file = $rel; status = 'missing_marker'; detail = $step2.reason })
            continue
        }

        if ($step2.content -cne $original) {
            [void]$drifted.Add($rel)
            if ($Check) {
                [void]$details.Add([pscustomobject]@{ file = $rel; status = 'drift'; detail = 'Managed block differs from models.json.' })
            }
            else {
                Write-DocAtomic -Path $fullPath -Text $step2.content
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
