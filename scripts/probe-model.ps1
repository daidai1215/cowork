[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ModelId,
    [ValidateSet('agy', 'codex')][string]$Channel,
    [string]$ModelFlag,
    [string[]]$Only = @(),
    [switch]$DryRun,
    [string]$RegistryPath,
    [string]$StateDir,
    [string]$Effort
)

. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Write-ProbeSection {
    param(
        [IO.StreamWriter]$Writer, [string]$Probe,
        [AllowEmptyString()][string]$Answer, [bool]$AnswerExists,
        $Summary, [int]$ProcessExit, [string]$RunnerError
    )
    $null = $Writer.WriteLine()
    $null = $Writer.WriteLine('## ' + $Probe)
    $null = $Writer.WriteLine()
    $null = $Writer.WriteLine('Question file: ' + $Probe)
    $null = $Writer.WriteLine('Process exit: ' + $ProcessExit)
    $null = $Writer.WriteLine()
    $null = $Writer.WriteLine('### Raw answer')
    $null = $Writer.WriteLine()
    if ($AnswerExists) {
        $fenceLength = 3
        foreach ($match in [regex]::Matches($Answer, '`+')) {
            $fenceLength = [Math]::Max($fenceLength, $match.Length + 1)
        }
        $fence = '`' * $fenceLength
        $null = $Writer.WriteLine($fence + 'text')
        $null = $Writer.Write($Answer)
        if (-not $Answer.EndsWith("`n")) { $null = $Writer.WriteLine() }
        $null = $Writer.WriteLine($fence)
    }
    else { $null = $Writer.WriteLine('No response file was produced.') }
    $null = $Writer.WriteLine()
    $null = $Writer.WriteLine('### Invocation summary JSON')
    $null = $Writer.WriteLine()
    $null = $Writer.WriteLine('```json')
    $summaryText = ConvertTo-Json -InputObject $Summary -Depth 32
    $null = $Writer.WriteLine($summaryText)
    $null = $Writer.WriteLine('```')
    if (-not [string]::IsNullOrWhiteSpace($RunnerError)) {
        $null = $Writer.WriteLine()
        $null = $Writer.WriteLine('Runner error: ' + ($RunnerError -replace '[\r\n]+', ' '))
    }
    $null = $Writer.Flush()
}

$planned = New-Object 'System.Collections.Generic.List[object]'
$results = New-Object 'System.Collections.Generic.List[object]'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$resolvedId = $null
$reportPath = $null
$reportWriter = $null
$temporaryDirectory = $null
$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$adHoc = $false
$effectiveFlag = $null
$exitCode = 0
$fatalError = $null

try {
    $paths = Get-OrchestraPaths -RegistryPath $RegistryPath -StateDir $StateDir
    $registry = Read-Registry -Paths $paths
    $resolvedId = Resolve-ModelId -Registry $registry -Name $ModelId
    $adHoc = [string]::IsNullOrWhiteSpace($resolvedId)
    if ($adHoc) {
        if ([string]::IsNullOrWhiteSpace($Channel)) {
            throw "ORCHESTRA_ARGS: Unknown model requires -Channel: $ModelId"
        }
        $resolvedId = $ModelId
        $effectiveFlag = $ModelFlag
        $effectiveEffort = $Effort
        if ([string]::IsNullOrWhiteSpace($effectiveFlag)) { $effectiveFlag = $ModelId }
        $slugEffort = $null
        if ($Channel -eq 'agy' -and
            $effectiveFlag -match '-(low|medium|high|xhigh|max)$') {
            $slugEffort = $Matches[1]
        }
        if ([string]::IsNullOrWhiteSpace($effectiveEffort)) {
            if ($null -ne $slugEffort) { $effectiveEffort = $slugEffort }
            elseif ($Channel -eq 'agy') { $effectiveEffort = 'high' }
            else { $effectiveEffort = 'xhigh' }
        }
        if ($effectiveEffort -notin @('low', 'medium', 'high', 'xhigh', 'max') -or
            ($Channel -eq 'codex' -and $effectiveEffort -eq 'max')) {
            throw 'ORCHESTRA_ARGS: Unsupported AdHoc effort.'
        }
        if ($null -ne $slugEffort -and $slugEffort -ne $effectiveEffort) {
            throw 'ORCHESTRA_ARGS: Effort conflicts with the explicit agy slug.'
        }
        if ($Channel -eq 'agy' -and [string]::IsNullOrWhiteSpace($ModelFlag) -and
            $null -eq $slugEffort) {
            $effectiveFlag += '-' + $effectiveEffort
        }
        if ($effectiveFlag -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            throw 'ORCHESTRA_ARGS: Invalid AdHoc model flag.'
        }
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($Channel) -or
            -not [string]::IsNullOrWhiteSpace($ModelFlag)) {
            throw 'ORCHESTRA_ARGS: Channel/ModelFlag are only for unregistered models.'
        }
        $registryModels = Get-OrchestraProperty $registry 'models' @()
        $selectedModel = $null
        foreach ($model in $registryModels) {
            if ((Get-OrchestraProperty $model 'id') -eq $resolvedId) {
                $selectedModel = $model
                break
            }
        }
        $invoke = Get-OrchestraProperty $selectedModel 'invoke'
        $effectiveEffort = $Effort
        if ([string]::IsNullOrWhiteSpace($effectiveEffort)) {
            $effectiveEffort = [string](Get-OrchestraProperty $invoke 'default_effort')
        }
        $supportedEfforts = Get-OrchestraProperty $invoke 'efforts' @()
        if ($effectiveEffort -notin @('low', 'medium', 'high', 'xhigh') -or
            $effectiveEffort -notin $supportedEfforts) {
            throw "ORCHESTRA_ARGS: Unsupported effort for $resolvedId."
        }
        $Channel = [string](Get-OrchestraProperty $selectedModel 'channel')
        $effectiveFlag = (
            [string](Get-OrchestraProperty $invoke 'model_flag')
        ).Replace('{effort}', $effectiveEffort)
    }
    if ($resolvedId -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') {
        throw 'ORCHESTRA_ARGS: Model ID is not safe for an output filename.'
    }

    $requestedNumbers = @{}
    foreach ($value in $Only) {
        foreach ($part in ($value -split ',')) {
            $part = $part.Trim()
            if ($part -notmatch '^0?([1-5])$') {
                throw "ORCHESTRA_ARGS: Invalid probe number: $part"
            }
            $requestedNumbers[[int]$Matches[1]] = $true
        }
    }
    $probeDirectory = Join-Path $paths.Root 'evals\probe'
    $files = @(Get-ChildItem -LiteralPath $probeDirectory -Filter '0*.md' -File |
        Sort-Object Name)
    $questions = @{}
    foreach ($file in $files) {
        if ($file.Name -notmatch '^0([1-5])[-_.].*\.md$') {
            throw "ORCHESTRA_EXTERNAL: Unexpected probe filename: $($file.Name)"
        }
        $number = [int]$Matches[1]
        if ($questions.ContainsKey($number)) {
            throw "ORCHESTRA_EXTERNAL: Duplicate probe number: $number"
        }
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($text)) {
            throw "ORCHESTRA_EXTERNAL: Empty probe: $($file.Name)"
        }
        $questions[$number] = $file
    }
    if ($questions.Count -ne 5) {
        throw 'ORCHESTRA_EXTERNAL: Exactly five probe files numbered 01 through 05 are required.'
    }
    foreach ($number in 1..5) {
        if ($requestedNumbers.Count -gt 0 -and
            -not $requestedNumbers.ContainsKey($number)) { continue }
        $file = $questions[$number]
        $null = $planned.Add([pscustomobject]@{
            probe = $file.Name; number = $number; prompt_file = $file.FullName
            access = 'read'; tags = @('probe'); effort = $effectiveEffort
            ad_hoc = $adHoc; channel = $Channel; model_flag = $effectiveFlag
        })
    }
    $reportDirectory = Join-Path $paths.Root 'evals\results'
    $reportPath = Join-Path $reportDirectory (
        '{0}-{1}.md' -f $resolvedId, (Get-OrchestraNow).ToString('yyyyMMdd-HHmmss')
    )
    if (-not $DryRun) {
        $null = [IO.Directory]::CreateDirectory($reportDirectory)
        $temporaryDirectory = Join-Path $temporaryParent (
            'model-orchestra-probe-' + [Guid]::NewGuid().ToString('N')
        )
        $null = [IO.Directory]::CreateDirectory($temporaryDirectory)
        $reportStream = [IO.File]::Open(
            $reportPath, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::Read
        )
        try { $reportWriter = New-Object IO.StreamWriter($reportStream, $utf8) }
        catch { $reportStream.Dispose(); throw }
        $null = $reportWriter.WriteLine('# Model probe report: ' + $resolvedId)
        $null = $reportWriter.WriteLine()
        $null = $reportWriter.WriteLine('UTC: ' + (Get-OrchestraNow).ToString('o'))
        $null = $reportWriter.WriteLine('Access: read')
        $null = $reportWriter.WriteLine('Effort: ' + $effectiveEffort)
        $null = $reportWriter.Flush()

        foreach ($probe in $planned.ToArray()) {
            $answerFile = Join-Path $temporaryDirectory ('answer-' + $probe.number + '.txt')
            $summary = $null
            $answer = ''
            $answerExists = $false
            $runnerError = $null
            $probeExit = 3
            $processExit = 3
            $sessionId = $null
            try {
                $arguments = @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', (Join-Path $PSScriptRoot 'invoke-model.ps1'),
                    '-Model', $resolvedId, '-Access', 'read',
                    '-PromptFile', $probe.prompt_file, '-OutFile', $answerFile,
                    '-Tags', 'probe', '-RegistryPath', $paths.Registry,
                    '-StateDir', $paths.StateDir, '-WorkDir', $paths.Root,
                    '-Effort', $effectiveEffort
                )
                if ($adHoc) {
                    $arguments += @(
                        '-AdHocChannel', $Channel, '-AdHocModelFlag', $effectiveFlag
                    )
                }
                $child = Invoke-OrchestraProcess -FilePath 'powershell.exe' `
                    -Arguments $arguments -WorkDir $paths.Root `
                    -TimeoutSec 1860 -CaptureStdout -ForwardStderr
                $processExit = [int]$child.exit_code
                $probeExit = $processExit
                $lines = @($child.stdout | Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_)
                })
                if ($lines.Count -eq 0) {
                    throw 'ORCHESTRA_EXTERNAL: Invocation emitted no summary.'
                }
                $summary = [string]$lines[$lines.Count - 1] | ConvertFrom-Json
                if ((Get-OrchestraProperty $summary 'orchestra_result') -ne $true) {
                    $summary = $null
                    throw 'ORCHESTRA_EXTERNAL: Final record is not an invocation summary.'
                }
                $summaryExit = Get-OrchestraProperty $summary 'exit'
                if ($null -eq $summaryExit -or [string]$summaryExit -notmatch '^[0-5]$' -or
                    [int]$summaryExit -ne $processExit) {
                    throw 'ORCHESTRA_EXTERNAL: Invocation exit code and summary disagree.'
                }
                $sessionValue = Get-OrchestraProperty $summary 'session_id'
                if ($sessionValue -is [string] -and
                    -not [string]::IsNullOrWhiteSpace($sessionValue)) {
                    $sessionId = $sessionValue
                }
                if ($child.timeout -or $child.truncated) {
                    throw 'ORCHESTRA_EXTERNAL: Probe child process timed out or output was truncated.'
                }
                if ($probeExit -notin @(0, 2, 3, 4, 5)) { $probeExit = 3 }
                if ($probeExit -eq 0 -and -not [IO.File]::Exists($answerFile)) {
                    throw 'ORCHESTRA_EXTERNAL: Successful invocation produced no answer file.'
                }
            }
            catch {
                $probeExit = Get-OrchestraExitCode -Message $_.Exception.Message
                $runnerError = $_.Exception.Message
                [Console]::Error.WriteLine($probe.probe + ': ' + $runnerError)
            }
            if ([IO.File]::Exists($answerFile)) {
                try {
                    $answer = [IO.File]::ReadAllText($answerFile, $utf8)
                    $answerExists = $true
                }
                catch {
                    $probeExit = 3
                    $runnerError = 'Cannot read answer file: ' + $_.Exception.Message
                    [Console]::Error.WriteLine($runnerError)
                }
            }
            $null = $results.Add([pscustomobject]@{
                probe = $probe.probe; exit = $probeExit; session_id = $sessionId
            })
            Write-ProbeSection -Writer $reportWriter -Probe $probe.probe `
                -Answer $answer -AnswerExists $answerExists -Summary $summary `
                -ProcessExit $processExit -RunnerError $runnerError
            if ($exitCode -eq 0 -and $probeExit -ne 0) { $exitCode = $probeExit }
        }
    }
}
catch {
    $exitCode = Get-OrchestraExitCode -Message $_.Exception.Message
    $fatalError = $_.Exception.Message
    [Console]::Error.WriteLine($fatalError)
}
finally {
    if ($null -ne $reportWriter) {
        try { $reportWriter.Dispose() }
        catch {
            $exitCode = 3
            $fatalError = 'Report close failed: ' + $_.Exception.Message
            [Console]::Error.WriteLine($fatalError)
        }
    }
    if ($null -ne $temporaryDirectory -and [IO.Directory]::Exists($temporaryDirectory)) {
        try {
            $absolute = [IO.Path]::GetFullPath($temporaryDirectory)
            $prefix = $temporaryParent.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            $leaf = [IO.Path]::GetFileName($absolute)
            if (-not $absolute.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
                $leaf -notmatch '^model-orchestra-probe-[a-f0-9]{32}$') {
                throw 'Refusing cleanup outside the unique probe directory.'
            }
            $null = [IO.Directory]::Delete($absolute, $true)
        }
        catch {
            $exitCode = 3
            $fatalError = 'Probe cleanup failed: ' + $_.Exception.Message
            [Console]::Error.WriteLine($fatalError)
        }
    }
}
$output = @{
    model = $resolvedId; planned = $planned.ToArray()
    results = $results.ToArray(); out_file = $reportPath
}
if ($DryRun) { $output.dry_run = $true }
if ($null -ne $fatalError) { $output.error = $fatalError }
Write-OrchestraResult -Object $output
exit $exitCode
