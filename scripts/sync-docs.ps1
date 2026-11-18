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
        [string]$EmptyStateDir,
        [string]$ModeName = ''
    )
    $savedOut = [Console]::Out
    $writer = New-Object IO.StringWriter
    [Console]::SetOut($writer)
    try {
        if ([string]::IsNullOrWhiteSpace($ModeName)) {
            & $RouteScript -Tags $TagsCsv -RegistryPath $RegistryFile -StateDir $EmptyStateDir
        }
        else {
            & $RouteScript -Tags $TagsCsv -Mode $ModeName -RegistryPath $RegistryFile -StateDir $EmptyStateDir
        }
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
        $peakEffort = [string](Get-OrchestraProperty $invoke 'peak_effort' '')
        $effortCell = if (-not [string]::IsNullOrWhiteSpace($peakEffort) -and $peakEffort -cne $effort) {
            ('`{0}` (' + (U '\u653b\u575a') + ' `{1}`)') -f $effort, $peakEffort
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
                ForEach-Object { '{0} ({1})' -f $_.dim, $_.score }
        )
        $capText = if ($orderedCaps.Count -gt 0) { $orderedCaps -join ', ' } else { '-' }

        $traits = New-Object 'System.Collections.Generic.List[string]'
        if ([bool](Get-OrchestraProperty $model 'primary_disabled' $false)) {
            [void]$traits.Add((U '\u4ec5\u5ba1\u67e5/\u628a\u5173\uff08\u7981\u4e3b\u5199\uff09'))
        }
        if ([bool](Get-OrchestraProperty $invoke 'account_rotation' $false)) {
            [void]$traits.Add((U 'Cockpit \u81ea\u52a8\u5207\u53f7\u81ea\u6108'))
        }
        $tools = @(Get-OrchestraArray $model 'tools')
        if ($tools.Count -gt 0) {
            [void]$traits.Add(('tools: `' + ($tools -join '`, `') + '`'))
        }
        $traitText = if ($traits.Count -gt 0) { $traits -join '; ' } else { '-' }

        [void]$lines.Add((
            '| **{0}** | `{1}` (`{2}`) | {3} | {4} | {5} | {6} | {7} |' -f
            $display, $id, $channel, $effortCell, $capText,
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
                '`{0}` -> `{1}`' -f $_, $target
            }
    )

    $scenarios = @(
        [pscustomobject]@{ label = (U '\u524d\u7aef\u9875\u9762 / \u843d\u5730\u9875'); tags = 'frontend,landing_page' }
        [pscustomobject]@{ label = (U '\u540e\u7aef / API / \u5e76\u53d1'); tags = 'backend,concurrency' }
        [pscustomobject]@{ label = (U '\u6570\u5b66\u63a8\u5bfc / \u7b97\u6cd5'); tags = 'math,algorithm' }
        [pscustomobject]@{ label = (U '\u7591\u96be Bug / \u6839\u56e0\u5b9a\u4f4d'); tags = 'bugfix' }
        [pscustomobject]@{ label = (U '\u8bba\u6587 / \u957f\u6587 / \u6587\u6848'); tags = 'prose,paper' }
        [pscustomobject]@{ label = (U '\u914d\u56fe / \u63d2\u753b / Mockup'); tags = 'image_gen' }
        [pscustomobject]@{ label = 'PPT / Word / Excel'; tags = 'office,ppt' }
        [pscustomobject]@{ label = (U '\u68c0\u7d22 / \u7efc\u8ff0 / \u5927\u4ed3\u5e93\u7406\u89e3'); tags = 'research,long_context' }
    )

    $policyObj = Get-OrchestraProperty $Registry 'policy'
    $defaultEffort = [string](Get-OrchestraProperty $policyObj 'default_effort' 'high')
    $defaultMode = [string](Get-OrchestraProperty $policyObj 'default_mode' 'peak')

    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add(('- **' + (U '\u6807\u51c6\u80fd\u529b\u522b\u540d') + '**: ' + ($aliasPairs -join ', ')))
    [void]$lines.Add(('- **' + (U '\u9ed8\u8ba4\u8def\u7531\u6a21\u5f0f') + '**: `' + $defaultMode + '` (' + (U '\u96f6\u989d\u5ea6/\u901f\u5ea6\u6263\u5206\uff0c\u7eaf\u80fd\u529b\u4e0a\u9650\u4f18\u5148') + ')'))
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
        $polisherCell = if ($null -eq $route.polisher) { '-' } else { '`' + [string]$route.polisher + '`' }
        $patternCell = '`' + [string](Get-OrchestraProperty $route 'pattern' 'solo') + '`'
        [void]$lines.Add((
            '| {0} | `{1}` | {2} | {3} | {4} | {5} |' -f
            $sc.label, $sc.tags, $primaryCell, $reviewerCell, $polisherCell, $patternCell
        ))
    }

    $modesObj = Get-OrchestraProperty $Registry 'modes'
    $fastMapObj = Get-OrchestraProperty $policyObj 'fast_workhorse_map'
    if ($null -ne (Get-OrchestraProperty $modesObj 'fast_4h') -and $null -ne $fastMapObj) {
        $toM = [string](Get-OrchestraProperty $fastMapObj 'to_model' 'gemini-4-hydrogen')
        $fromM = [string](Get-OrchestraProperty $fastMapObj 'from_model' 'gemini-4-carbon')
        $retainP = @(Get-OrchestraArray $fastMapObj 'retain_primary_tags' | ForEach-Object { [string]$_ }) -join '`, `'
        $retainR = @(Get-OrchestraArray $fastMapObj 'retain_reviewer_tags' | ForEach-Object { [string]$_ }) -join '`, `'
        [void]$lines.Add('')
        [void]$lines.Add((
            '- **' + (U '4H Extra \u5feb\u901f\u6a21\u5f0f (`-Mode fast_4h`)') + '**: ' +
            (U '\u5c06\u5927\u90e8\u5206') + ' `' + $fromM + '` ' + (U '\u4efb\u52a1\u4e0b\u653e') + ' `' + $toM + '` (`xhigh`)' +
            (U '\uff0c\u4ec5\u9ad8\u8981\u6c42\u4e3b\u5199') + ' (`' + $retainP + '`), ' +
            (U '\u9ad8\u8981\u6c42\u5ba1\u67e5') + ' (`' + $retainR + '`) ' + (U '\u53ca') + ' `-AllowEscalation` ' +
            (U '\u4fdd\u7559\u7ed9') + ' `' + $fromM + '` (' + (U '\u540e\u7aef/\u6570\u5b66/\u751f\u56fe/Office \u4e3b\u653b\u4ecd\u7531 GPT-6.2 Astra \u627f\u62c5') + '):'
        ))
        [void]$lines.Add('')
        [void]$lines.Add((
            '| ' + (U '\u5feb\u901f\u573a\u666f') + ' (`fast_4h`) | `' + '-Tags' + '` | ' +
            (U '\u4e3b\u6267\u884c') + ' | ' + (U '\u5ba1\u67e5') + ' | ' +
            (U '\u5347\u7ea7\u515c\u5e95') + ' |'
        ))
        [void]$lines.Add('|---|---|---|---|---|')
        $fastScenarios = @(
            [pscustomobject]@{ label = (U '\u524d\u7aef / UI / \u843d\u5730\u9875'); tags = 'frontend,landing_page' }
            [pscustomobject]@{ label = (U '\u68c0\u7d22 / \u5927\u4ed3\u5e93\u9884\u8bfb'); tags = 'research,long_context' }
            [pscustomobject]@{ label = (U '\u65e5\u5e38\u6587\u6863 / \u603b\u7ed3'); tags = 'prose' }
            [pscustomobject]@{ label = (U '\u9ad8\u8981\u6c42\u8bba\u6587 / \u6df1\u5ea6\u957f\u6587'); tags = 'prose,paper' }
            [pscustomobject]@{ label = (U '\u5e38\u89c4\u540e\u7aef / Bugfix'); tags = 'bugfix' }
            [pscustomobject]@{ label = (U '\u6570\u5b66 / \u7b97\u6cd5\u9a8c\u7b97'); tags = 'math,algorithm' }
        )
        foreach ($fsc in $fastScenarios) {
            $fr = Invoke-CleanRoute -RouteScript $RouteScript -TagsCsv $fsc.tags -ModeName 'fast_4h' -RegistryFile $RegistryFile -EmptyStateDir $EmptyStateDir
            $fpEff = [string](Get-OrchestraProperty $fr 'primary_effort' '')
            $fpCell = Format-RouteModelCell -ModelName $fr.primary -Effort $fpEff -IsBlocked ([bool](Get-OrchestraProperty $fr 'blocked' $false)) -CheckBlocked $true
            $frEff = [string](Get-OrchestraProperty $fr 'reviewer_effort' '')
            $frCell = Format-RouteModelCell -ModelName $fr.reviewer -Effort $frEff
            $feCell = if ($null -eq $fr.escalate_to) { '-' } else { '`' + [string]$fr.escalate_to + '`' }
            [void]$lines.Add(('| {0} | `{1}` | {2} | {3} | {4} |' -f $fsc.label, $fsc.tags, $fpCell, $frCell, $feCell))
        }
    }

    $hostTierRows = @(
        [pscustomobject]@{ host = 'orchestrator'; mode = 'orchestrator_fast'; label = (U '\u524d\u7aef / \u5e38\u89c4\u7814\u53d1'); tags = 'frontend,landing_page' }
        [pscustomobject]@{ host = 'orchestrator'; mode = 'orchestrator_fast'; label = (U '\u67b6\u6784\u8bbe\u8ba1 / \u590d\u6742\u540e\u7aef'); tags = 'architecture' }
        [pscustomobject]@{ host = 'carbon'; mode = 'carbon_peak'; label = (U '\u5e38\u89c4\u65d7\u8230\u4e3b\u63a7'); tags = 'frontend,landing_page' }
        [pscustomobject]@{ host = 'carbon'; mode = 'carbon_peak'; label = (U '\u6279\u91cf\u673a\u68b0\u5206\u7247 / \u4ed3\u626b'); tags = 'bulk,scan' }
        [pscustomobject]@{ host = 'hydrogen'; mode = 'hydrogen_max'; label = (U '\u5e38\u89c4 Bugfix'); tags = 'bugfix' }
        [pscustomobject]@{ host = 'hydrogen'; mode = 'hydrogen_max'; label = (U '\u8bba\u6587 / \u957f\u6587\u7ec8\u5ba1\u95e8\u7981'); tags = 'prose,paper' }
    ) | Where-Object { $null -ne (Get-OrchestraProperty $modesObj $_.mode) }

    if (@($hostTierRows).Count -gt 0) {
        [void]$lines.Add('')
        [void]$lines.Add((
            '- **' + (U '\u4e3b\u63a7\u611f\u77e5\u4e09\u6863\u81ea\u52a8\u5206\u5c42') +
            ' (`-HostModel orchestrator|carbon|hydrogen`)**: ' +
            (U '\u4f9d\u636e\u4e3b\u63a7\u73af\u5883\u81ea\u52a8\u5207\u6362') +
            ' `orchestrator_fast` / `carbon_peak` / `hydrogen_max` (' +
            (U '\u5728') + ' `bulk`/`boilerplate`/`scan`/`test_gen` ' +
            (U '\u81ea\u52a8\u964d\u4e3a') + ' `high` ' +
            (U '\u63d0\u901f\uff0c\u5176\u4f59\u4fdd\u6301') + ' `xhigh`):'
        ))
        [void]$lines.Add('')
        [void]$lines.Add((
            '| ' + (U '\u4e3b\u63a7\u6a21\u5f0f') + ' (`-HostModel`) | ' +
            (U '\u5178\u578b\u573a\u666f') + ' | `-Tags` | ' +
            (U '\u4e3b\u6267\u884c') + ' (`primary`) | ' +
            (U '\u5ba1\u67e5') + ' (`reviewer`) | ' +
            (U '\u7ec8\u5ba1') + ' (`final_reviewer`) |'
        ))
        [void]$lines.Add('|---|---|---|---|---|---|')
        foreach ($row in $hostTierRows) {
            $hr = Invoke-CleanRoute -RouteScript $RouteScript -TagsCsv $row.tags -ModeName $row.mode -RegistryFile $RegistryFile -EmptyStateDir $EmptyStateDir
            $hpEff = [string](Get-OrchestraProperty $hr 'primary_effort' '')
            $hpCell = Format-RouteModelCell -ModelName $hr.primary -Effort $hpEff -IsBlocked ([bool](Get-OrchestraProperty $hr 'blocked' $false)) -CheckBlocked $true
            $hrEff = [string](Get-OrchestraProperty $hr 'reviewer_effort' '')
            $hrCell = Format-RouteModelCell -ModelName $hr.reviewer -Effort $hrEff
            $orchObj = Get-OrchestraProperty $hr 'orchestration'
            $finRev = [string](Get-OrchestraProperty $orchObj 'final_reviewer' '')
            $hfCell = if ([string]::IsNullOrWhiteSpace($finRev)) { '-' } else { '`' + $finRev + '`' }
            $modeCell = '`{0}` -> `{1}`' -f $row.host, $row.mode
            [void]$lines.Add(('| {0} | {1} | `{2}` | {3} | {4} | {5} |' -f $modeCell, $row.label, $row.tags, $hpCell, $hrCell, $hfCell))
        }
    }
    return ($lines.ToArray() -join "`n")
}

function Build-ProfilesBlock {
    param($Registry)
    $dimensions = @(Get-OrchestraArray $Registry 'cap_dimensions')
    $active = @(
        @(Get-OrchestraArray $Registry 'models') |
            Where-Object { [string](Get-OrchestraProperty $_ 'status') -eq 'active' }
    )
    $lines = New-Object 'System.Collections.Generic.List[string]'
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
            ('`{0}` / ' + (U '\u653b\u575a') + ' `{1}`') -f $effort, $peakEffort
        }
        else {
            '`{0}`' -f $effort
        }
        $qRank = [int](Get-OrchestraProperty $model 'quota_rank' 2)
        $sRank = [int](Get-OrchestraProperty $model 'speed_rank' 2)
        $roleNote = if ([bool](Get-OrchestraProperty $model 'primary_disabled' $false)) {
            ' | ' + (U '\u4ec5\u5ba1\u67e5/\u628a\u5173\uff08\u7981\u4e3b\u5199\uff09')
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
        [void]$lines.Add(('- **' + (U '10 \u7ef4\u80fd\u529b\u5206') + '** (`*`=' + (U '\u9501\u5b9a') + '): ' + ($scoreItems -join ', ')))
        [void]$lines.Add(('- **' + (U '\u989d\u5ea6 / \u901f\u5ea6') + '**: `quota_rank=' + (Format-RankLabel $qRank 'quota') + '`, `speed_rank=' + (Format-RankLabel $sRank 'speed') + '`'))

        $strengths = @(Get-OrchestraArray $model 'strengths')
        if ($strengths.Count -gt 0) {
            [void]$lines.Add('')
            [void]$lines.Add(('**' + (U '\u6838\u5fc3\u957f\u677f') + '**:'))
            foreach ($s in $strengths) {
                [void]$lines.Add(('- ' + [string]$s))
            }
        }
        $weaknesses = @(Get-OrchestraArray $model 'weaknesses')
        if ($weaknesses.Count -gt 0) {
            [void]$lines.Add('')
            [void]$lines.Add(('**' + (U '\u77ed\u677f\u4e0e\u907f\u5751') + '**:'))
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
        $finalDocContent = $step2.content
        if ($original.Contains('<!-- AUTO:PROFILES:START -->')) {
            $step3 = Update-ManagedSection -Content $finalDocContent -MarkerName 'PROFILES' -NewInner $profilesBlock -Newline $newline
            if (-not $step3.ok) {
                [void]$drifted.Add($rel)
                [void]$details.Add([pscustomobject]@{ file = $rel; status = 'missing_marker'; detail = $step3.reason })
                continue
            }
            $finalDocContent = $step3.content
        }

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
