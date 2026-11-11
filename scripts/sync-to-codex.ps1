[CmdletBinding()]
param(
    [switch]$Copy,
    [string]$Destination = (Join-Path $HOME '.codex\skills\cowork')
)
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Assert-NoReparseAncestors {
    param([string]$Path)
    $candidate = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($candidate)) {
        try {
            $attributes = [IO.File]::GetAttributes($candidate)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw [ArgumentException]::new(
                    "Refusing destination reparse point: $candidate"
                )
            }
        }
        catch {
            $cause = $_.Exception.GetBaseException()
            if ($cause -isnot [IO.FileNotFoundException] -and
                $cause -isnot [IO.DirectoryNotFoundException]) { throw }
        }
        $parent = [IO.Directory]::GetParent($candidate)
        if ($null -eq $parent) { break }
        $candidate = $parent.FullName
    }
}

try {
    $root = [IO.Path]::GetFullPath((Resolve-Root)).TrimEnd('\')
    $target = [IO.Path]::GetFullPath($Destination)
    if ($target.TrimEnd('\') -eq [IO.Path]::GetPathRoot($target).TrimEnd('\')) {
        throw [ArgumentException]::new('Destination must not be a filesystem root.')
    }
    $target = $target.TrimEnd('\')
    if ($target.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $target.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $root.StartsWith($target + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw [ArgumentException]::new('Source and destination must not overlap.')
    }
    if ($Copy) { Assert-NoReparseAncestors $target }
    $existing = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing -and
        ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        $linkTargets = @($existing.Target)
        if ($linkTargets.Count -eq 1 -and
            [IO.Path]::GetFullPath([string]$linkTargets[0]).TrimEnd('\').Equals(
                $root, [StringComparison]::OrdinalIgnoreCase)) {
            Write-OrchestraResult @{
                mode = 'junction'; destination = $target; unchanged = $true
            }
            exit 0
        }
        throw [ArgumentException]::new('Existing destination is a different reparse point.')
    }
    if (-not $Copy) {
        if ($null -ne $existing) {
            throw [ArgumentException]::new(
                'Destination exists. Use -Copy for an ordinary directory.'
            )
        }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        New-Item -ItemType Junction -Path $target -Target $root | Out-Null
        Write-OrchestraResult @{ mode = 'junction'; source = $root; destination = $target }
        exit 0
    }
    if ($null -ne $existing -and -not $existing.PSIsContainer) {
        throw [ArgumentException]::new('Copy destination is not a directory.')
    }

    # Preflight the copy entries. Destination-only files are never enumerated or deleted.
    $plan = New-Object 'System.Collections.Generic.List[object]'
    $queue = New-Object 'System.Collections.Generic.Queue[string]'
    $queue.Enqueue($root)
    while ($queue.Count -gt 0) {
        $directory = $queue.Dequeue()
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
            $relative = $item.FullName.Substring($root.Length).TrimStart('\')
            if ($relative -match '^(registry\\history|registry\\proposals|evals\\results)(\\|$)' -or
                $relative -match '^(\.git|locks)(\\|$)' -or
                $item.Name -in @('state.json', 'usage.jsonl')) { continue }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw [ArgumentException]::new(
                    "Refusing source reparse point: $($item.FullName)"
                )
            }
            $destinationPath = Join-Path $target $relative
            Assert-NoReparseAncestors $destinationPath
            $destinationItem = Get-Item -LiteralPath $destinationPath -Force `
                -ErrorAction SilentlyContinue
            if ($null -ne $destinationItem -and
                [bool]$destinationItem.PSIsContainer -ne [bool]$item.PSIsContainer) {
                throw [ArgumentException]::new(
                    "Destination type conflicts with source: $destinationPath"
                )
            }
            [void]$plan.Add([pscustomobject]@{
                Source = $item.FullName
                Destination = $destinationPath
                Directory = [bool]$item.PSIsContainer
            })
            if ($item.PSIsContainer) { $queue.Enqueue($item.FullName) }
        }
    }
    Assert-NoReparseAncestors $target
    [void][IO.Directory]::CreateDirectory($target)
    $count = 0
    foreach ($entry in $plan) {
        Assert-NoReparseAncestors $entry.Destination
        if ($entry.Directory) {
            [void][IO.Directory]::CreateDirectory($entry.Destination)
        }
        else {
            [void][IO.Directory]::CreateDirectory(
                (Split-Path -Parent $entry.Destination)
            )
            Assert-NoReparseAncestors $entry.Destination
            Copy-Item -LiteralPath $entry.Source -Destination $entry.Destination -Force
            $count++
        }
    }
    Write-OrchestraResult @{
        mode = 'copy'; source = $root; destination = $target; files = $count
        deletes = 0; preserved_destination_only = $true
        warning = '复制模式下两端的档案会分叉，建议用 junction'
        excluded = @(
            'registry/history', 'registry/proposals', 'evals/results',
            'state.json', 'usage.jsonl', 'locks'
        )
    }
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    $code = Get-OrchestraExitCode -Message $_.Exception.Message
    if ($_.Exception -is [ArgumentException]) { $code = 2 }
    Write-OrchestraResult @{ error = $_.Exception.Message; exit = $code }
    exit $code
}
