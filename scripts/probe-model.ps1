[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ModelId,
    [ValidateSet('agy', 'codex')][string]$Channel,
    [string]$ModelFlag,
    [string[]]$Only = @(),
    [switch]$Grade,
    [switch]$EmitProposals,
    [switch]$DryRun,
    [string]$ProbeDir,
    [string]$ReportDir,
    [string]$GradeSchemaPath,
    [string]$RegistryPath,
    [string]$StateDir,
    [string]$Effort
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Write-ProbeSection {
    param(
        [IO.StreamWriter]$Writer, [string]$Probe,
        [AllowEmptyString()][string]$Answer, [bool]$AnswerExists,
        $Summary, [int]$ProcessExit, [string]$RunnerError,
        $GradeResult = $null
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
    if ($null -ne $GradeResult) {
        $null = $Writer.WriteLine()
        $null = $Writer.WriteLine('### Blind evaluation')
        $null = $Writer.WriteLine()
        $null = $Writer.WriteLine('```json')
        $null = $Writer.WriteLine((ConvertTo-Json -InputObject $GradeResult -Depth 32))
        $null = $Writer.WriteLine('```')
    }
    if (-not [string]::IsNullOrWhiteSpace($RunnerError)) {
        $null = $Writer.WriteLine()
        $null = $Writer.WriteLine('Runner error: ' + ($RunnerError -replace '[\r\n]+', ' '))
    }
    $null = $Writer.Flush()
}

function Get-ProbeDimension {
    param([int]$Number)
    switch ($Number) {
        1 { return 'code_rigor' }
        2 { return 'math' }
        3 { return 'prose' }
        4 { return 'frontend_aesthetic' }
        5 { return 'world_knowledge' }
        default { throw "ORCHESTRA_ARGS: Unsupported probe number: $Number" }
    }
}

function Split-ProbeContent {
    param([string]$FileName, [string]$RawText)
    $pattern = '(?ms)\A(?<task>.+?)\r?\nScoring by (?<judge>[a-z0-9][a-z0-9.-]*),\s*15 points:\s*\r?\n(?<rubric>.+)\z'
    $match = [regex]::Match($RawText, $pattern)
    if (-not $match.Success) {
        throw "ORCHESTRA_EXTERNAL: Probe $FileName is missing a valid Scoring rubric boundary."
    }
    $taskText = $match.Groups['task'].Value.Trim()
    $judgeAlias = $match.Groups['judge'].Value.Trim()
    $rubricBody = $match.Groups['rubric'].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($taskText) -or [string]::IsNullOrWhiteSpace($rubricBody)) {
        throw "ORCHESTRA_EXTERNAL: Probe $FileName has empty task or rubric content."
    }
    return [pscustomobject]@{
        task = $taskText
        judge_alias = $judgeAlias
        rubric = $rubricBody
    }
}

function Select-BlindJudge {
    param(
        $Registry,
        $State,
        [string]$CandidateId,
        [string]$CandidateVendor,
        [string]$JudgeAlias,
        [string]$Dimension
    )
    $models = @(Get-OrchestraArray $Registry 'models')
    $preferredId = Resolve-ModelId -Registry $Registry -Name $JudgeAlias
    if (-not [string]::IsNullOrWhiteSpace($preferredId) -and $preferredId -cne $CandidateId) {
        $prefMatch = @($models | Where-Object { [string]$_.id -ceq $preferredId }) | Select-Object -First 1
        if ($null -ne $prefMatch -and [string](Get-OrchestraProperty $prefMatch 'status') -eq 'active') {
            $prefVendor = [string](Get-OrchestraProperty $prefMatch 'vendor' '')
            $avail = Get-ModelAvailability -Registry $Registry -State $State -Model $prefMatch
            $crossVendorOk = ([string]::IsNullOrWhiteSpace($CandidateVendor) -or ($prefVendor -ne $CandidateVendor))
            if ($crossVendorOk -and $avail -in @('normal', 'low')) {
                return $prefMatch
            }
        }
    }

    $eligibleCross = @(
        foreach ($m in $models) {
            $mId = [string](Get-OrchestraProperty $m 'id')
            if ($mId -ceq $CandidateId) { continue }
            if ([string](Get-OrchestraProperty $m 'status') -ne 'active') { continue }
            $avail = Get-ModelAvailability -Registry $Registry -State $State -Model $m
            if ($avail -notin @('normal', 'low')) { continue }
            $mVendor = [string](Get-OrchestraProperty $m 'vendor' '')
            if (-not [string]::IsNullOrWhiteSpace($CandidateVendor) -and $mVendor -eq $CandidateVendor) { continue }
            $capObj = Get-OrchestraProperty (Get-OrchestraProperty $m 'caps') $Dimension
            [pscustomobject]@{
                Model = $m
                CapScore = [double](Get-OrchestraProperty $capObj 'score' 0)
                QuotaRank = [int](Get-OrchestraProperty $m 'quota_rank' 1)
                SpeedRank = [int](Get-OrchestraProperty $m 'speed_rank' 1)
                Id = $mId
            }
        }
    )
    if ($eligibleCross.Count -gt 0) {
        $sorted = @(
            $eligibleCross | Sort-Object `
                @{ Expression = { $_.CapScore }; Descending = $true },
                @{ Expression = { $_.QuotaRank }; Descending = $true },
                @{ Expression = { $_.SpeedRank }; Descending = $true },
                @{ Expression = { $_.Id }; Ascending = $true }
        )
        return $sorted[0].Model
    }

    # Explicit test-only same-vendor fallback (disabled in production to guarantee independent cross-vendor grading)
    if ([Environment]::GetEnvironmentVariable('MODEL_ORCHESTRA_ALLOW_SAME_VENDOR_JUDGE') -eq '1') {
        $fallbackPool = @(
            foreach ($m in $models) {
                $mId = [string](Get-OrchestraProperty $m 'id')
                if ($mId -ceq $CandidateId) { continue }
                if ([string](Get-OrchestraProperty $m 'status') -ne 'active') { continue }
                $avail = Get-ModelAvailability -Registry $Registry -State $State -Model $m
                if ($avail -notin @('normal', 'low')) { continue }
                $capObj = Get-OrchestraProperty (Get-OrchestraProperty $m 'caps') $Dimension
                [pscustomobject]@{
                    Model = $m
                    CapScore = [double](Get-OrchestraProperty $capObj 'score' 0)
                    Id = $mId
                }
            }
        )
        if ($fallbackPool.Count -gt 0) {
            return (@($fallbackPool | Sort-Object @{ Expression = { $_.CapScore }; Descending = $true }, Id))[0].Model
        }
    }
    throw "ORCHESTRA_EXTERNAL: No eligible cross-vendor active judge model for candidate '$CandidateId' (vendor '$candVendor')."
}

function Write-ProposalPair {
    param([hashtable]$Paths, $Proposal, [System.Text.Encoding]$Encoding)
    [void][IO.Directory]::CreateDirectory($Paths.Proposals)
    $stem = Join-Path $Paths.Proposals ([string]$Proposal.proposal_id)
    $jsonPath = $stem + '.json'
    Write-JsonAtomic -Path $jsonPath -Object $Proposal
    $md = @(
        ('# Proposal: ' + $Proposal.model_id)
        ''
        ('Base revision: ' + $Proposal.base_rev)
        ''
        [string]$Proposal.reason
        ''
        'Approval preserves cap locks. Set unlock:true only for a permanent cap unlock.'
        ''
        '```json'
        (ConvertTo-Json -InputObject $Proposal.patch -Depth 32)
        '```'
        ''
    ) -join "`n"
    [IO.File]::WriteAllText(($stem + '.md'), $md, $Encoding)
    return $jsonPath
}

$planned = New-Object 'System.Collections.Generic.List[object]'
$results = New-Object 'System.Collections.Generic.List[object]'
$proposalFiles = New-Object 'System.Collections.Generic.List[string]'
$skippedConflicts = 0
$utf8 = New-Object System.Text.UTF8Encoding($false)
$resolvedId = $null
$selectedModel = $null
$reportPath = $null
$jsonReportPath = $null
$reportWriter = $null
$temporaryDirectory = $null
$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$adHoc = $false
$effectiveFlag = $null
$exitCode = 0
$fatalError = $null

try {
    if ($EmitProposals -and -not $Grade) {
        throw 'ORCHESTRA_ARGS: -EmitProposals requires -Grade.'
    }
    $paths = Get-OrchestraPaths -RegistryPath $RegistryPath -StateDir $StateDir
    $registry = Read-Registry -Paths $paths
    $policy = Get-OrchestraProperty $registry 'policy'
    $policyDefaultEffort = [string](Get-OrchestraProperty $policy 'default_effort' 'high')
    if ([string]::IsNullOrWhiteSpace($policyDefaultEffort)) { $policyDefaultEffort = 'high' }

    $resolvedId = Resolve-ModelId -Registry $registry -Name $ModelId
    $adHoc = [string]::IsNullOrWhiteSpace($resolvedId)
    if ($EmitProposals -and $adHoc) {
        throw 'ORCHESTRA_ARGS: -EmitProposals requires a registered model.'
    }

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
            else { $effectiveEffort = $policyDefaultEffort }
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
        $supportedEfforts = @(Get-OrchestraArray $invoke 'efforts')
        if ($effectiveEffort -notin @('low', 'medium', 'high', 'xhigh', 'max') -or
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

    $effectiveSchemaPath = if ([string]::IsNullOrWhiteSpace($GradeSchemaPath)) {
        Join-Path $paths.Root 'registry\probe-grade.schema.json'
    }
    else {
        [IO.Path]::GetFullPath($GradeSchemaPath)
    }
    if ($Grade -and -not [IO.File]::Exists($effectiveSchemaPath)) {
        throw "ORCHESTRA_EXTERNAL: Grade schema not found: $effectiveSchemaPath"
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
    $probeDirectory = if ([string]::IsNullOrWhiteSpace($ProbeDir)) {
        Join-Path $paths.Root 'evals\probe'
    }
    else {
        [IO.Path]::GetFullPath($ProbeDir)
    }
    if (-not [IO.Directory]::Exists($probeDirectory)) {
        throw "ORCHESTRA_EXTERNAL: Probe directory not found: $probeDirectory"
    }
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
        $parsedProbe = Split-ProbeContent -FileName $file.Name -RawText $text
        $questions[$number] = [pscustomobject]@{
            file = $file
            task = $parsedProbe.task
            judge_alias = $parsedProbe.judge_alias
            rubric = $parsedProbe.rubric
            dimension = (Get-ProbeDimension -Number $number)
        }
    }
    if ($questions.Count -ne 5) {
        throw 'ORCHESTRA_EXTERNAL: Exactly five probe files numbered 01 through 05 are required.'
    }
    foreach ($number in 1..5) {
        if ($requestedNumbers.Count -gt 0 -and
            -not $requestedNumbers.ContainsKey($number)) { continue }
        $q = $questions[$number]
        $null = $planned.Add([pscustomobject]@{
            probe = $q.file.Name; number = $number; dimension = $q.dimension
            judge_alias = $q.judge_alias; prompt_file = $q.file.FullName
            rubric_stripped = $true
            access = 'read'; tags = @('probe'); effort = $effectiveEffort
            ad_hoc = $adHoc; channel = $Channel; model_flag = $effectiveFlag
        })
    }

    $candidateVendor = ''
    if (-not $adHoc -and $null -ne $selectedModel) {
        $candidateVendor = [string](Get-OrchestraProperty $selectedModel 'vendor' '')
    }
    else {
        if ($Channel -eq 'codex') { $candidateVendor = 'openai' }
        elseif ($resolvedId -match '(?i)^gemini') { $candidateVendor = 'google' }
        elseif ($resolvedId -match '(?i)^claude') { $candidateVendor = 'anthropic' }
    }

    $reportDirectory = if ([string]::IsNullOrWhiteSpace($ReportDir)) {
        Join-Path $paths.Root 'evals\results'
    }
    else {
        [IO.Path]::GetFullPath($ReportDir)
    }
    $stampNow = (Get-OrchestraNow).ToString('yyyyMMdd-HHmmss')
    $reportPath = Join-Path $reportDirectory ('{0}-{1}.md' -f $resolvedId, $stampNow)
    if ([IO.File]::Exists($reportPath)) {
        $reportPath = Join-Path $reportDirectory ('{0}-{1}-{2}.md' -f $resolvedId, $stampNow, [Guid]::NewGuid().ToString('N').Substring(0, 4))
    }

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
            $qData = $questions[[int]$probe.number]
            $candidatePromptFile = Join-Path $temporaryDirectory ('prompt-' + $probe.number + '.md')
            [IO.File]::WriteAllText($candidatePromptFile, ($qData.task + "`n"), $utf8)
            $answerFile = Join-Path $temporaryDirectory ('answer-' + $probe.number + '.txt')
            $summary = $null
            $answer = ''
            $answerExists = $false
            $runnerError = $null
            $probeExit = 3
            $processExit = 3
            $sessionId = $null
            $gradeObject = $null

            try {
                $arguments = @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', (Join-Path $PSScriptRoot 'invoke-model.ps1'),
                    '-Model', $resolvedId, '-Access', 'read',
                    '-PromptFile', $candidatePromptFile, '-OutFile', $answerFile,
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

            if ($Grade -and $probeExit -eq 0 -and $answerExists) {
                try {
                    $curState = Read-State -Paths $paths
                    $curRegistry = Read-Registry -Paths $paths
                    $judgeModel = Select-BlindJudge `
                        -Registry $curRegistry -State $curState `
                        -CandidateId $resolvedId -CandidateVendor $candidateVendor `
                        -JudgeAlias $probe.judge_alias -Dimension $probe.dimension
                    $judgeId = [string](Get-OrchestraProperty $judgeModel 'id')

                    $gradePromptFile = Join-Path $temporaryDirectory ('grade-prompt-' + $probe.number + '.md')
                    $gradeOutFile = Join-Path $temporaryDirectory ('grade-out-' + $probe.number + '.json')
                    $gradePromptText = @(
                        'You are an anonymous blind evaluator. Grade the anonymous candidate response strictly against the task and 15-point scoring rubric below.'
                        'Do not invoke any shell, file, or web tools. Return ONLY valid JSON matching the schema with keys: parts (array of 3 numbers in 0..5), fatal_cap_triggered (boolean: true if any cap/disqualifier rule in the rubric applies), and rationale (concise justification).'
                        ''
                        '### Task'
                        $qData.task
                        ''
                        '### Scoring Rubric (15 points)'
                        $qData.rubric
                        ''
                        '### Anonymous Candidate Response'
                        $answer
                        ''
                    ) -join "`n"
                    [IO.File]::WriteAllText($gradePromptFile, $gradePromptText, $utf8)

                    $gradeArgs = @(
                        '-NoProfile', '-ExecutionPolicy', 'Bypass',
                        '-File', (Join-Path $PSScriptRoot 'invoke-model.ps1'),
                        '-Model', $judgeId, '-Access', 'read',
                        '-PromptFile', $gradePromptFile,
                        '-JsonSchema', $effectiveSchemaPath,
                        '-OutFile', $gradeOutFile,
                        '-Tags', 'probe_grade',
                        '-RegistryPath', $paths.Registry,
                        '-StateDir', $paths.StateDir,
                        '-WorkDir', $paths.Root
                    )
                    $gradeChild = Invoke-OrchestraProcess -FilePath 'powershell.exe' `
                        -Arguments $gradeArgs -WorkDir $paths.Root `
                        -TimeoutSec 900 -CaptureStdout -ForwardStderr
                    if ($gradeChild.exit_code -ne 0 -or $gradeChild.timeout -or -not [IO.File]::Exists($gradeOutFile)) {
                        throw "ORCHESTRA_EXTERNAL: Blind judge ($judgeId) failed with exit $($gradeChild.exit_code)."
                    }
                    $parsedGrade = Read-JsonFile -Path $gradeOutFile
                    $partsArr = @(Get-OrchestraArray $parsedGrade 'parts')
                    if ($partsArr.Count -ne 3) {
                        throw 'ORCHESTRA_EXTERNAL: Judge parts must contain exactly 3 numbers.'
                    }
                    $numericParts = New-Object 'System.Collections.Generic.List[double]'
                    foreach ($pVal in $partsArr) {
                        $dVal = [double]$pVal
                        if ([double]::IsNaN($dVal) -or [double]::IsInfinity($dVal) -or $dVal -lt 0.0 -or $dVal -gt 5.0) {
                            throw 'ORCHESTRA_EXTERNAL: Judge part score out of 0..5 range.'
                        }
                        [void]$numericParts.Add($dVal)
                    }
                    $fatalCap = Get-OrchestraProperty $parsedGrade 'fatal_cap_triggered'
                    if ($fatalCap -isnot [bool]) {
                        throw 'ORCHESTRA_EXTERNAL: Judge fatal_cap_triggered must be boolean.'
                    }
                    $rationale = [string](Get-OrchestraProperty $parsedGrade 'rationale' '')
                    if ([string]::IsNullOrWhiteSpace($rationale)) {
                        throw 'ORCHESTRA_EXTERNAL: Judge rationale cannot be empty.'
                    }
                    $rawSum = $numericParts[0] + $numericParts[1] + $numericParts[2]
                    $effectiveTotal = if ($fatalCap) { [Math]::Min($rawSum, 5.0) } else { $rawSum }
                    $effectiveTotal = [Math]::Round($effectiveTotal, 2)
                    $capScore10 = [Math]::Round(($effectiveTotal * 10.0) / 15.0, 1)

                    $gradeObject = [pscustomobject]@{
                        judge = $judgeId
                        dimension = $probe.dimension
                        parts = $numericParts.ToArray()
                        raw_total_15 = [Math]::Round($rawSum, 2)
                        fatal_cap_triggered = [bool]$fatalCap
                        total_15 = $effectiveTotal
                        cap_score_10 = $capScore10
                        rationale = $rationale
                    }
                }
                catch {
                    $probeExit = Get-OrchestraExitCode -Message $_.Exception.Message
                    $runnerError = $_.Exception.Message
                    [Console]::Error.WriteLine($probe.probe + ' (grade): ' + $runnerError)
                }
            }

            $itemObj = [ordered]@{
                probe = $probe.probe
                dimension = $probe.dimension
                exit = $probeExit
                session_id = $sessionId
            }
            if ($null -ne $gradeObject) {
                $itemObj['grade'] = $gradeObject
            }
            $null = $results.Add([pscustomobject]$itemObj)
            Write-ProbeSection -Writer $reportWriter -Probe $probe.probe `
                -Answer $answer -AnswerExists $answerExists -Summary $summary `
                -ProcessExit $processExit -RunnerError $runnerError -GradeResult $gradeObject
            if ($exitCode -eq 0 -and $probeExit -ne 0) { $exitCode = $probeExit }
        }

        if ($Grade) {
            $jsonReportPath = [IO.Path]::ChangeExtension($reportPath, '.json')
            Write-JsonAtomic -Path $jsonReportPath -Object ([pscustomobject]@{
                model = $resolvedId
                effort = $effectiveEffort
                created_utc = (Get-OrchestraNow).ToString('o')
                results = $results.ToArray()
            })
        }

        if ($EmitProposals -and $exitCode -eq 0) {
            Invoke-WithLock -Paths $paths -Name registry -ScriptBlock {
                $freshReg = Read-Registry -Paths $paths
                $baseRev = [long](Get-OrchestraProperty $freshReg 'registry_rev' 0)
                $targetModel = @($freshReg.models | Where-Object { [string]$_.id -ceq $resolvedId }) | Select-Object -First 1
                if ($null -eq $targetModel) {
                    throw "ORCHESTRA_ARGS: Model disappeared before proposal creation: $resolvedId"
                }
                foreach ($resItem in $results.ToArray()) {
                    $g = Get-OrchestraProperty $resItem 'grade'
                    if ($null -eq $g) { continue }
                    $dim = [string]$g.dimension
                    $capObj = Get-OrchestraProperty (Get-OrchestraProperty $targetModel 'caps') $dim
                    if ($null -eq $capObj) { continue }
                    $oldScore = [double](Get-OrchestraProperty $capObj 'score' 0)
                    $newScore = [double]$g.cap_score_10
                    if ([Math]::Abs($newScore - $oldScore) -lt 0.1) { continue }

                    $scorePath = "models[id=$resolvedId].caps.$dim.score"
                    if (Test-PendingProposalConflict -Paths $paths -ModelId $resolvedId -PatchPaths @($scorePath)) {
                        $script:skippedConflicts++
                        continue
                    }
                    $propStamp = (Get-OrchestraNow).ToString('yyyyMMdd-HHmmss')
                    $propId = '{0}-{1}-probe-{2}-{3}' -f $propStamp, $resolvedId, $dim, [Guid]::NewGuid().ToString('N').Substring(0, 4)
                    $oldSource = Get-OrchestraProperty $capObj 'source' 'public'
                    $oldConf = Get-OrchestraProperty $capObj 'confidence' 0.6
                    $oldEvidence = Get-OrchestraProperty $capObj 'evidence' $null
                    $newEvidence = @([pscustomobject]@{
                        url = ('probe://evals/probe/' + [string]$resItem.probe)
                        claim = ("Blind probe score $($g.total_15)/15 ($newScore/10) judged by $($g.judge): " + [string]$g.rationale)
                        date = (Get-OrchestraNow).ToString('yyyy-MM-dd')
                    })
                    $patch = @(
                        [pscustomobject]@{ op = 'set'; path = $scorePath; old_value = $oldScore; value = $newScore; unlock = $false }
                        [pscustomobject]@{ op = 'set'; path = "models[id=$resolvedId].caps.$dim.source"; old_value = $oldSource; value = 'probe'; unlock = $false }
                        [pscustomobject]@{ op = 'set'; path = "models[id=$resolvedId].caps.$dim.confidence"; old_value = $oldConf; value = 0.75; unlock = $false }
                        [pscustomobject]@{ op = 'set'; path = "models[id=$resolvedId].caps.$dim.evidence"; old_value = $oldEvidence; value = $newEvidence; unlock = $false }
                    )
                    $proposal = [pscustomobject]@{
                        proposal_id = $propId
                        model_id = $resolvedId
                        base_rev = $baseRev
                        created_at = (Get-OrchestraNow).ToString('o')
                        status = 'pending'
                        reason = "Blind probe ($($resItem.probe)) judged by $($g.judge): $($g.total_15)/15 -> $newScore/10. $($g.rationale)"
                        patch = $patch
                    }
                    $savedPath = Write-ProposalPair -Paths $paths -Proposal $proposal -Encoding $utf8
                    [void]$proposalFiles.Add($savedPath)
                }
            }
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
$output = [ordered]@{
    model = $resolvedId
    ad_hoc = [bool]$adHoc
    planned = $planned.ToArray()
    results = $results.ToArray()
    out_file = $reportPath
}
if ($Grade) {
    $output['json_report'] = $jsonReportPath
    $output['proposals'] = [string[]]$proposalFiles.ToArray()
    $output['skipped_conflicts'] = [int]$skippedConflicts
}
if ($DryRun) { $output['dry_run'] = $true }
if ($null -ne $fatalError) { $output['error'] = $fatalError }
Write-OrchestraResult -Object $output
exit $exitCode
