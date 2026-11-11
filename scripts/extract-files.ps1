<#
.SYNOPSIS
  Extract "=====FILE: <relpath>=====" ... "=====END FILE=====" blocks from a model answer and write them under a root directory.
.DESCRIPTION
  Used when an executor model (e.g. GPT via codex exec, whose shell tool may be unavailable) delivers code as text.
  .ps1/.psm1 files are written as UTF-8 WITH BOM (Windows PowerShell 5.1 reads BOM-less scripts as ANSI);
  everything else is written as UTF-8 without BOM. Paths escaping the root are rejected.
.EXAMPLE
  extract-files.ps1 -InputFile out.md -Root C:\proj -AllowedPrefixes scripts/,tests/
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$InputFile,
  [Parameter(Mandatory)][string]$Root,
  [string[]]$AllowedPrefixes = @(),
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
# powershell -File passes "a,b" as a single string; split on commas so both call styles work
$AllowedPrefixes = @($AllowedPrefixes | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().Replace('\', '/') } | Where-Object { $_ })
$text = [IO.File]::ReadAllText($InputFile, [Text.Encoding]::UTF8)
$rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
$pattern = '(?ms)^=====FILE:\s*(?<path>[^\r\n=]+?)\s*=====\r?\n(?<body>.*?)\r?\n=====END FILE=====\s*$'
$written = @(); $rejected = @()
foreach ($m in [regex]::Matches($text, $pattern)) {
  $rel = $m.Groups['path'].Value.Trim().Replace('/', '\')
  $body = $m.Groups['body'].Value
  # strip an accidental surrounding markdown fence
  if ($body -match '^\s*```[^\r\n]*\r?\n(?<inner>.*)\r?\n```\s*$') { $body = $Matches['inner'] }
  $full = [IO.Path]::GetFullPath((Join-Path $rootFull $rel))
  $inside = $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)
  # check the allow-list against the NORMALIZED relative path (blocks scripts/../registry/... tricks)
  $relNorm = if ($inside) { $full.Substring($rootFull.Length).Replace('\', '/') } else { $rel.Replace('\', '/') }
  $okPrefix = ($AllowedPrefixes.Count -eq 0) -or (@($AllowedPrefixes | Where-Object { $relNorm.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)
  # refuse to write through junctions/symlinks anywhere between root and target
  $reparse = $false
  if ($inside) {
    $probe = $full
    while ($probe.Length -gt $rootFull.Length) {
      if (Test-Path -LiteralPath $probe) {
        if (((Get-Item -LiteralPath $probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $reparse = $true; break }
      }
      $probe = [IO.Path]::GetDirectoryName($probe)
    }
  }
  if (-not $inside -or -not $okPrefix -or $reparse) { $rejected += $relNorm; continue }
  if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path (Split-Path $full) | Out-Null
    $bom = $full -match '\.(ps1|psm1|psd1)$'
    $body = $body -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText($full, $body + "`r`n", (New-Object Text.UTF8Encoding $bom))
  }
  $written += [pscustomobject]@{ path = $relNorm; chars = $body.Length }
}
$notes = $null
$ni = $text.IndexOf('=====NOTES=====')
if ($ni -ge 0) { $notes = $text.Substring($ni + 15).Trim() }
[pscustomobject]@{ written = $written; rejected = $rejected; notes = $notes } | ConvertTo-Json -Depth 5
if ($rejected.Count -gt 0) { exit 2 }
