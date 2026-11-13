<#
.SYNOPSIS
  Extract "=====FILE: <relpath>=====" ... "=====END FILE=====" blocks from a model answer and write them under a root directory.
.DESCRIPTION
  Used when an executor model (e.g. GPT via codex exec, whose shell tool may be unavailable) delivers code as text.
  Enforces two safety gates borrowed from Orchestrator/Swarm:
    1. Re-plan circuit breaker: if the output contains an =====ORCHESTRA_REPLAN_REQUIRED===== block, zero files are written (exit 3).
    2. Atomic shard ownership: all file paths are validated upfront against root confinement, AllowedPrefixes, ForbiddenPrefixes,
       and reparse-point traversal; if ANY block violates boundaries, zero files are written (exit 2).
  .ps1/.psm1/.psd1 files are written as UTF-8 WITH BOM (Windows PowerShell 5.1 reads BOM-less scripts as ANSI);
  everything else is written as UTF-8 without BOM.
.EXAMPLE
  extract-files.ps1 -InputFile out.md -Root C:\proj -AllowedPrefixes scripts/,tests/ -ForbiddenPrefixes registry/
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$InputFile,
  [Parameter(Mandatory)][string]$Root,
  [string[]]$AllowedPrefixes = @(),
  [string[]]$ForbiddenPrefixes = @(),
  [switch]$AllowReplan,
  [switch]$DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# powershell -File passes "a,b" as a single string; split on commas so both call styles work
$AllowedPrefixes = @(
  $AllowedPrefixes |
    ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim().Replace('\', '/') } |
    Where-Object { $_ }
)
$ForbiddenPrefixes = @(
  $ForbiddenPrefixes |
    ForEach-Object { $_ -split ',' } |
    ForEach-Object { $_.Trim().Replace('\', '/') } |
    Where-Object { $_ }
)

$text = [IO.File]::ReadAllText($InputFile, [Text.Encoding]::UTF8)
$notes = $null
$ni = $text.IndexOf('=====NOTES=====')
if ($ni -ge 0) { $notes = $text.Substring($ni + 15).Trim() }

$replanPattern = '(?ms)^=====ORCHESTRA_REPLAN_REQUIRED=====\s*\r?\n(?<body>.*?)\r?\n=====END ORCHESTRA_REPLAN_REQUIRED=====\s*$'
$replanMatch = [regex]::Match($text, $replanPattern)
$replanRequired = $replanMatch.Success
$replanDetail = if ($replanMatch.Success) { $replanMatch.Groups['body'].Value.Trim() } else { $null }

if ($replanRequired -and -not $AllowReplan) {
  [pscustomobject]@{
    written = @()
    rejected = @()
    replan_required = $true
    replan_detail = $replanDetail
    notes = $notes
  } | ConvertTo-Json -Depth 5
  exit 3
}

$rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
$pattern = '(?ms)^=====FILE:\s*(?<path>[^\r\n=]+?)\s*=====\r?\n(?<body>.*?)\r?\n=====END FILE=====\s*$'
$staged = New-Object 'System.Collections.Generic.List[object]'
$rejected = @()

foreach ($m in [regex]::Matches($text, $pattern)) {
  $rel = $m.Groups['path'].Value.Trim().Replace('/', '\')
  $body = $m.Groups['body'].Value
  # strip an accidental surrounding markdown fence
  if ($body -match '^\s*```[^\r\n]*\r?\n(?<inner>.*)\r?\n```\s*$') { $body = $Matches['inner'] }
  $full = [IO.Path]::GetFullPath((Join-Path $rootFull $rel))
  $inside = $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)
  # check allow-list and deny-list against the NORMALIZED relative path (blocks scripts/../registry/... tricks)
  $relNorm = if ($inside) { $full.Substring($rootFull.Length).Replace('\', '/') } else { $rel.Replace('\', '/') }
  $okPrefix = ($AllowedPrefixes.Count -eq 0) -or (
    @($AllowedPrefixes | Where-Object { $relNorm.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
  )
  $hitForbidden = ($ForbiddenPrefixes.Count -gt 0) -and (
    @($ForbiddenPrefixes | Where-Object { $relNorm.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
  )
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
  if (-not $inside -or -not $okPrefix -or $hitForbidden -or $reparse) {
    $rejected += $relNorm
    continue
  }
  [void]$staged.Add([pscustomobject]@{
    full = $full
    relNorm = $relNorm
    body = $body
  })
}

if ($rejected.Count -gt 0) {
  [pscustomobject]@{
    written = @()
    rejected = $rejected
    replan_required = [bool]$replanRequired
    replan_detail = $replanDetail
    notes = $notes
  } | ConvertTo-Json -Depth 5
  exit 2
}

$written = @()
foreach ($entry in $staged) {
  $normalizedBody = $entry.body -replace "`r?`n", "`r`n"
  if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path (Split-Path $entry.full) | Out-Null
    $bom = $entry.full -match '\.(ps1|psm1|psd1)$'
    [IO.File]::WriteAllText($entry.full, $normalizedBody + "`r`n", (New-Object Text.UTF8Encoding $bom))
  }
  $written += [pscustomobject]@{ path = $entry.relNorm; chars = $normalizedBody.Length }
}

[pscustomobject]@{
  written = $written
  rejected = @()
  replan_required = [bool]$replanRequired
  replan_detail = $replanDetail
  notes = $notes
} | ConvertTo-Json -Depth 5
exit 0
