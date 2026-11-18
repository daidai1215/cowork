<#
.SYNOPSIS
Pack static context files or incremental git diff + test log tail into a deterministic UTF-8 (no BOM) file for KV prefix caching and delta reviews.
#>
[CmdletBinding()]
param(
    [string]$WorkDir = (Get-Location).Path,
    [string[]]$Files = @(),
    [string]$OutFile,
    [switch]$GitDiff,
    [string]$BaseRef = '',
    [string[]]$AllowedPrefixes = @(),
    [string]$TestLogFile = '',
    [int]$MaxLinesPerFile = 400,
    [int]$MaxLogTailLines = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Expand-PackCsv {
    param([string[]]$Values = @())
    return @(
        foreach ($raw in @($Values)) {
            if ($null -eq $raw) { continue }
            foreach ($piece in ([string]$raw -split ',')) {
                $trimmed = $piece.Trim()
                if ($trimmed.Length -gt 0) { $trimmed }
            }
        }
    )
}

function Read-NormalizedUtf8Text {
    param([Parameter(Mandatory = $true)][string]$Path)
    $rawBytes = [IO.File]::ReadAllBytes($Path)
    $text = if (
        $rawBytes.Length -ge 3 -and
        $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF
    ) {
        [System.Text.Encoding]::UTF8.GetString($rawBytes, 3, $rawBytes.Length - 3)
    }
    else {
        [System.Text.Encoding]::UTF8.GetString($rawBytes)
    }
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
        $text = $text.Substring(1)
    }
    return ($text -replace "\r\n?", "`n")
}

function Split-NormalizedLines {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    $lines = @($Text -split "`n")
    if ($lines.Count -gt 0 -and $Text.EndsWith("`n") -and $lines[$lines.Count - 1] -eq '') {
        if ($lines.Count -eq 1) { return @() }
        return @($lines[0..($lines.Count - 2)])
    }
    return $lines
}

function Write-PackTextAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
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
        if ([IO.File]::Exists($tmp)) {
            try { [IO.File]::Delete($tmp) } catch {}
        }
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($OutFile)) {
        throw 'ORCHESTRA_ARGS: Specify -OutFile.'
    }
    if ($MaxLinesPerFile -lt 1 -or $MaxLogTailLines -lt 0) {
        throw 'ORCHESTRA_ARGS: Invalid line limit parameter.'
    }
    if (-not [IO.Directory]::Exists($WorkDir)) {
        throw 'ORCHESTRA_ARGS: WorkDir does not exist.'
    }
    $WorkDir = [IO.Path]::GetFullPath($WorkDir)
    $workPrefix = $WorkDir.TrimEnd('\', '/') + '\'

    $outPath = $OutFile
    if (-not [IO.Path]::IsPathRooted($outPath)) {
        $outPath = Join-Path $WorkDir $outPath
    }
    $outPath = [IO.Path]::GetFullPath($outPath)

    $expandedFiles = @(Expand-PackCsv -Values $Files)
    $expandedPrefixes = @(
        Expand-PackCsv -Values $AllowedPrefixes |
            ForEach-Object { ($_.Replace('\', '/') -replace '^\./+', '') } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    $resolvedTestLog = $null
    if (-not [string]::IsNullOrWhiteSpace($TestLogFile)) {
        $candLog = $TestLogFile.Trim()
        if (-not [IO.Path]::IsPathRooted($candLog)) {
            $candLog = Join-Path $WorkDir $candLog
        }
        $resolvedTestLog = [IO.Path]::GetFullPath($candLog)
        if (-not [IO.File]::Exists($resolvedTestLog)) {
            throw 'ORCHESTRA_ARGS: TestLogFile does not exist.'
        }
    }

    if ($GitDiff) {
        $gitCmd = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $gitExe = if ($null -ne $gitCmd) { [string]$gitCmd.Source } else { 'git' }

        $pathSpecs = New-Object 'System.Collections.Generic.List[string]'
        foreach ($p in $expandedPrefixes) {
            [void]$pathSpecs.Add($p)
        }
        if ($pathSpecs.Count -eq 0 -and $expandedFiles.Count -gt 0) {
            foreach ($f in $expandedFiles) {
                $normF = ($f.Replace('\', '/') -replace '^\./+', '')
                if (-not [string]::IsNullOrWhiteSpace($normF)) {
                    [void]$pathSpecs.Add($normF)
                }
            }
        }

        $resolvedBaseSha = $null
        if (-not [string]::IsNullOrWhiteSpace($BaseRef)) {
            $trimmedRef = $BaseRef.Trim()
            if ($trimmedRef.StartsWith('-')) {
                throw "ORCHESTRA_ARGS: Invalid BaseRef: $trimmedRef"
            }
            $revRes = Invoke-OrchestraProcess -FilePath $gitExe -Arguments @(
                '-C', $WorkDir, 'rev-parse', '--verify', '--end-of-options', $trimmedRef
            ) -WorkDir $WorkDir -TimeoutSec 30 -CaptureStdout
            if ($revRes.timeout -or $revRes.truncated -or $revRes.exit_code -ne 0) {
                throw "ORCHESTRA_ARGS: Invalid BaseRef: $trimmedRef"
            }
            $resolvedBaseSha = @(
                $revRes.stdout | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            ) | Select-Object -First 1
            if ([string]::IsNullOrWhiteSpace($resolvedBaseSha) -or $resolvedBaseSha -notmatch '^[0-9a-fA-F]{40,64}$') {
                throw "ORCHESTRA_ARGS: Invalid BaseRef: $trimmedRef"
            }
        }

        $statusArgs = New-Object 'System.Collections.Generic.List[string]'
        foreach ($a in @('-C', $WorkDir, '-c', 'core.quotePath=false', 'status', '--short', '-uall', '--')) { [void]$statusArgs.Add($a) }
        foreach ($ps in $pathSpecs) { [void]$statusArgs.Add($ps) }
        $statusRes = Invoke-OrchestraProcess -FilePath $gitExe -Arguments $statusArgs.ToArray() -WorkDir $WorkDir -TimeoutSec 60 -CaptureStdout
        if ($statusRes.timeout -or $statusRes.truncated -or $statusRes.exit_code -ne 0) {
            throw ('ORCHESTRA_EXTERNAL: git status failed or truncated: ' + ($statusRes.stderr -join ' '))
        }

        $diffArgs = New-Object 'System.Collections.Generic.List[string]'
        foreach ($a in @('-C', $WorkDir, '-c', 'core.quotePath=false', 'diff', '--unified=3')) { [void]$diffArgs.Add($a) }
        if ($null -ne $resolvedBaseSha) {
            [void]$diffArgs.Add($resolvedBaseSha)
        }
        [void]$diffArgs.Add('--')
        foreach ($ps in $pathSpecs) { [void]$diffArgs.Add($ps) }
        $diffRes = Invoke-OrchestraProcess -FilePath $gitExe -Arguments $diffArgs.ToArray() -WorkDir $WorkDir -TimeoutSec 60 -CaptureStdout
        if ($diffRes.timeout -or $diffRes.truncated -or $diffRes.exit_code -ne 0) {
            throw ('ORCHESTRA_EXTERNAL: git diff failed or truncated: ' + ($diffRes.stderr -join ' '))
        }

        $statusLines = @($statusRes.stdout | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $diffLines = @($diffRes.stdout | ForEach-Object { [string]$_ })

        $touchedSet = @{}
        foreach ($sLine in $statusLines) {
            if ($sLine.Length -gt 3) {
                $pText = $sLine.Substring(3).Trim().Trim('"')
                if ($pText -match ' -> (.+)$') { $pText = $Matches[1].Trim().Trim('"') }
                if (-not [string]::IsNullOrWhiteSpace($pText)) {
                    $touchedSet[$pText.Replace('\', '/').ToLowerInvariant()] = $true
                }
            }
        }
        foreach ($dLine in $diffLines) {
            if ($dLine -match '^diff --git "?a/.+?"? "?b/(.+?)"?$') {
                $dPath = $Matches[1].Trim().Trim('"')
                if (-not [string]::IsNullOrWhiteSpace($dPath)) {
                    $touchedSet[$dPath.Replace('\', '/').ToLowerInvariant()] = $true
                }
            }
        }

        $sections = New-Object 'System.Collections.Generic.List[string]'
        $statusBody = if ($statusLines.Count -gt 0) { $statusLines -join "`n" } else { '(clean)' }
        [void]$sections.Add("## Git Status`n$statusBody")

        $diffBody = if ($diffLines.Count -gt 0) { $diffLines -join "`n" } else { '(no diff)' }
        [void]$sections.Add("## Git Diff`n$diffBody")

        $truncated = $false
        if ($null -ne $resolvedTestLog) {
            $logText = Read-NormalizedUtf8Text -Path $resolvedTestLog
            $logLines = @(Split-NormalizedLines -Text $logText)
            $tailLines = @()
            $logLabel = [IO.Path]::GetFileName($resolvedTestLog)
            $tailHeader = "## Test Log Tail ($logLabel)"
            if ($MaxLogTailLines -eq 0) {
                if ($logLines.Count -gt 0) {
                    $truncated = $true
                    $tailHeader = "## Test Log Tail ($logLabel; omitted $($logLines.Count) lines)"
                }
            }
            elseif ($logLines.Count -gt $MaxLogTailLines) {
                $truncated = $true
                $startIdx = $logLines.Count - $MaxLogTailLines
                $tailLines = @($logLines[$startIdx..($logLines.Count - 1)])
                $tailHeader = "## Test Log Tail ($logLabel; showing last $MaxLogTailLines of $($logLines.Count) lines)"
            }
            else {
                $tailLines = $logLines
            }
            $logBody = if ($tailLines.Count -gt 0) { $tailLines -join "`n" } else { '(empty log)' }
            [void]$sections.Add("$tailHeader`n$logBody")
        }

        $finalContent = (($sections.ToArray() -join "`n`n") -replace "\r\n?", "`n") + "`n"
        Write-PackTextAtomic -Path $outPath -Text $finalContent
        $bytes = [long]([IO.FileInfo]::new($outPath)).Length
        Write-OrchestraResult -Object ([ordered]@{
            mode = 'delta_diff'
            out_file = $outPath
            bytes = $bytes
            files_count = [int]$touchedSet.Count
            truncated = [bool]$truncated
        })
        exit 0
    }
    else {
        $seenFiles = @{}
        $resolvedEntries = New-Object 'System.Collections.Generic.List[object]'
        foreach ($f in $expandedFiles) {
            $cand = $f
            if (-not [IO.Path]::IsPathRooted($cand)) {
                $cand = Join-Path $WorkDir $cand
            }
            $full = [IO.Path]::GetFullPath($cand)
            if (-not [IO.File]::Exists($full)) {
                throw "ORCHESTRA_ARGS: Context source file does not exist: $f"
            }
            $key = $full.ToLowerInvariant()
            if ($seenFiles.ContainsKey($key)) { continue }
            $seenFiles[$key] = $true
            $rel = if ($full.StartsWith($workPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                $full.Substring($workPrefix.Length).Replace('\', '/')
            }
            else {
                $full.Replace('\', '/')
            }
            [void]$resolvedEntries.Add([pscustomobject]@{
                FullPath = $full
                RelPath = $rel
            })
        }
        if ($resolvedEntries.Count -eq 0) {
            throw 'ORCHESTRA_ARGS: Specify at least one file via -Files for static_pack mode (or pass -GitDiff).'
        }
        $orderedEntries = @($resolvedEntries.ToArray() | Sort-Object -Property RelPath)

        $sections = New-Object 'System.Collections.Generic.List[string]'
        $anyTruncated = $false
        foreach ($entry in $orderedEntries) {
            $rawText = Read-NormalizedUtf8Text -Path $entry.FullPath
            $fileLines = @(Split-NormalizedLines -Text $rawText)
            if ($fileLines.Count -gt $MaxLinesPerFile) {
                $anyTruncated = $true
                $omitted = $fileLines.Count - $MaxLinesPerFile
                $kept = @($fileLines[0..($MaxLinesPerFile - 1)]) + @("... [truncated $omitted lines]")
                $body = $kept -join "`n"
            }
            else {
                $body = $fileLines -join "`n"
            }
            [void]$sections.Add(("## File: $($entry.RelPath)`n$body"))
        }

        if ($null -ne $resolvedTestLog) {
            $logText = Read-NormalizedUtf8Text -Path $resolvedTestLog
            $logLines = @(Split-NormalizedLines -Text $logText)
            $tailLines = @()
            $logLabel = [IO.Path]::GetFileName($resolvedTestLog)
            $tailHeader = "## Test Log Tail ($logLabel)"
            if ($MaxLogTailLines -eq 0) {
                if ($logLines.Count -gt 0) {
                    $anyTruncated = $true
                    $tailHeader = "## Test Log Tail ($logLabel; omitted $($logLines.Count) lines)"
                }
            }
            elseif ($logLines.Count -gt $MaxLogTailLines) {
                $anyTruncated = $true
                $startIdx = $logLines.Count - $MaxLogTailLines
                $tailLines = @($logLines[$startIdx..($logLines.Count - 1)])
                $tailHeader = "## Test Log Tail ($logLabel; showing last $MaxLogTailLines of $($logLines.Count) lines)"
            }
            else {
                $tailLines = $logLines
            }
            $logBody = if ($tailLines.Count -gt 0) { $tailLines -join "`n" } else { '(empty log)' }
            [void]$sections.Add("$tailHeader`n$logBody")
        }

        $finalContent = (($sections.ToArray() -join "`n`n") -replace "\r\n?", "`n") + "`n"
        Write-PackTextAtomic -Path $outPath -Text $finalContent
        $bytes = [long]([IO.FileInfo]::new($outPath)).Length
        Write-OrchestraResult -Object ([ordered]@{
            mode = 'static_pack'
            out_file = $outPath
            files_count = [int]$orderedEntries.Count
            bytes = $bytes
            truncated = [bool]$anyTruncated
        })
        exit 0
    }
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
