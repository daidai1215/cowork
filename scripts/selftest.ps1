<#
.SYNOPSIS
Validate registry inputs and aggregate independent offline test suites.
.DESCRIPTION
Runs each tests/test-*.ps1 in a separate Windows PowerShell process.
Human-readable diagnostics go to stderr; stdout contains one JSON summary.
#>
[CmdletBinding()]
param(
    [string]$RegistryPath,
    [string]$StateDir,
    [int]$MaxParallel = 7,
    [switch]$Serial,
    [switch]$SkipTests
)

. (Join-Path $PSScriptRoot 'lib\common.ps1')

$script:selftestStaticPassed = 0
$script:selftestStaticFailed = 0
$script:selftestStaticChecks = New-Object 'System.Collections.Generic.List[object]'
$suites = New-Object 'System.Collections.Generic.List[object]'

function Add-SelftestStaticCheck {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')

    if ($Condition) {
        $script:selftestStaticPassed++
    }
    else {
        $script:selftestStaticFailed++
        [Console]::Error.WriteLine('STATIC FAIL: ' + $Name + ' ' + $Detail)
    }
    $null = $script:selftestStaticChecks.Add([pscustomobject]@{
        name = $Name
        passed = $Condition
        detail = $Detail
    })
}

function Test-SelftestNumber {
    param($Value, [double]$Minimum, [double]$Maximum, [switch]$Integer)

    $numeric = (
        $Value -is [int] -or $Value -is [long] -or
        $Value -is [double] -or $Value -is [decimal] -or
        $Value -is [single] -or $Value -is [short] -or
        $Value -is [byte] -or $Value -is [uint32] -or
        $Value -is [uint64]
    )
    if (-not $numeric) { return $false }
    $number = [double]$Value
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or
        $number -lt $Minimum -or $number -gt $Maximum) {
        return $false
    }
    if ($Integer -and $number -ne [Math]::Floor($number)) {
        return $false
    }
    return $true
}

function Test-SelftestReference {
    param($Registry, [hashtable]$Ids, $Reference)

    if ($Reference -isnot [string] -or
        [string]::IsNullOrWhiteSpace($Reference)) {
        return $false
    }
    $resolved = Resolve-ModelId -Registry $Registry -Name $Reference
    return (
        -not [string]::IsNullOrWhiteSpace($resolved) -and
        $Ids.ContainsKey($resolved)
    )
}

function Test-SelftestDeclaresParam {
    param([string]$ScriptPath, [string]$ParamName)

    try {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $ScriptPath, [ref]$tokens, [ref]$parseErrors
        )
        if ($null -eq $ast -or $null -eq $ast.ParamBlock) { return $false }
        foreach ($p in @($ast.ParamBlock.Parameters)) {
            if ($null -ne $p.Name -and $null -ne $p.Name.VariablePath -and
                [string]$p.Name.VariablePath.UserPath -ieq $ParamName) {
                return $true
            }
        }
    }
    catch {}
    return $false
}

function Start-SelftestSuiteProcess {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$WorkDir
    )

    $quoted = @(foreach ($argument in $Arguments) {
        ConvertTo-OrchestraArgument -Value $argument
    })
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = ($quoted -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $script:OrchestraUtf8
    $info.StandardErrorEncoding = $script:OrchestraUtf8
    $info.WorkingDirectory = $WorkDir

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $stdout = New-Object 'System.Collections.Generic.List[string]'
    $stderr = New-Object 'System.Collections.Generic.List[string]'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) {
            throw 'Suite process failed to start.'
        }
        try { $process.StandardInput.Close() } catch {}
        $outTask = $process.StandardOutput.ReadLineAsync()
        $errTask = $process.StandardError.ReadLineAsync()
        return @{
            process = $process
            watch = $watch
            output_task = $outTask
            error_task = $errTask
            output_done = $false
            error_done = $false
            stdout = $stdout
            stderr = $stderr
            timed_out = $false
            truncated = $false
            exit_seen_at = $null
            exit_code = 3
            completed = $false
            start_error = $null
        }
    }
    catch {
        $watch.Stop()
        try { $process.Dispose() } catch {}
        return @{
            process = $null
            watch = $watch
            output_task = $null
            error_task = $null
            output_done = $true
            error_done = $true
            stdout = $stdout
            stderr = $stderr
            timed_out = $false
            truncated = $false
            exit_seen_at = $null
            exit_code = 3
            completed = $true
            start_error = $_.Exception.Message
        }
    }
}

function Invoke-SelftestSuitePool {
    param(
        [object[]]$TestFiles,
        [hashtable]$Paths,
        [int]$ParallelLimit,
        [string]$SuiteStateRoot = '',
        [int]$TimeoutSec = 300
    )

    $weights = @{
        'test-invoke.ps1' = 10
        'test-setup.ps1' = 20
        'test-apply.ps1' = 30
        'test-route.ps1' = 40
        'test-maintain.ps1' = 50
        'test-probe.ps1' = 60
        'test-detect.ps1' = 70
    }
    $indexed = @(
        for ($idx = 0; $idx -lt $TestFiles.Count; $idx++) {
            $tf = $TestFiles[$idx]
            $w = if ($weights.ContainsKey($tf.Name)) { [int]$weights[$tf.Name] } else { 100 }
            [pscustomobject]@{
                Index = $idx
                File = $tf
                Weight = $w
                Length = [long]$tf.Length
                HasStateDir = (Test-SelftestDeclaresParam -ScriptPath $tf.FullName -ParamName 'StateDir')
            }
        }
    )
    $launchQueue = @(
        $indexed | Sort-Object -Property @{ Expression = { $_.Weight }; Ascending = $true },
            @{ Expression = { $_.Length }; Descending = $true },
            @{ Expression = { $_.File.Name }; Ascending = $true }
    )

    $psExe = Join-Path $PSHOME 'powershell.exe'
    if (-not [IO.File]::Exists($psExe)) { $psExe = 'powershell.exe' }

    $hasExplicitStateRoot = -not [string]::IsNullOrWhiteSpace($SuiteStateRoot)
    $resolvedStateRoot = if ($hasExplicitStateRoot) {
        [IO.Path]::GetFullPath($SuiteStateRoot)
    }
    else { $null }
    $createdStateDirs = New-Object 'System.Collections.Generic.List[string]'
    $resultsByIndex = New-Object 'object[]' $TestFiles.Count
    $active = New-Object 'System.Collections.Generic.List[object]'
    $nextIdx = 0

    try {
        if ($hasExplicitStateRoot) {
            [void][IO.Directory]::CreateDirectory($resolvedStateRoot)
        }
        while ($nextIdx -lt $launchQueue.Count -or $active.Count -gt 0) {
            while ($active.Count -lt $ParallelLimit -and $nextIdx -lt $launchQueue.Count) {
                $spec = $launchQueue[$nextIdx]
                $nextIdx++
                $suiteArgs = @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', $spec.File.FullName,
                    '-RegistryPath', $Paths.Registry
                )
                if ($hasExplicitStateRoot -and $spec.HasStateDir) {
                    $suiteState = Join-Path $resolvedStateRoot ('s' + $spec.Index)
                    if (-not [IO.Directory]::Exists($suiteState)) {
                        [void][IO.Directory]::CreateDirectory($suiteState)
                        [void]$createdStateDirs.Add($suiteState)
                    }
                    $suiteArgs += @('-StateDir', $suiteState)
                }
                $job = Start-SelftestSuiteProcess -Executable $psExe -Arguments $suiteArgs -WorkDir $Paths.Root
                $job['spec'] = $spec
                if ($job.completed) {
                    $resultsByIndex[$spec.Index] = $job
                }
                else {
                    [void]$active.Add($job)
                }
            }

            if ($active.Count -eq 0) { continue }

            $progress = $false
            for ($i = $active.Count - 1; $i -ge 0; $i--) {
                $job = $active[$i]
                $proc = $job.process
                $watch = $job.watch

                if (-not $job.timed_out -and $TimeoutSec -gt 0 -and
                    $watch.Elapsed.TotalSeconds -ge $TimeoutSec) {
                    $job.timed_out = $true
                    Stop-OrchestraProcessTree -Process $proc
                }
                if ($proc.HasExited -and $null -eq $job.exit_seen_at) {
                    $job.exit_seen_at = $watch.Elapsed.TotalSeconds
                }

                for ($b = 0; $b -lt 256 -and -not $job.output_done -and $job.output_task.IsCompleted; $b++) {
                    $line = $job.output_task.GetAwaiter().GetResult()
                    $progress = $true
                    if ($null -eq $line) { $job.output_done = $true; break }
                    [void]$job.stdout.Add($line)
                    $job.output_task = $proc.StandardOutput.ReadLineAsync()
                }
                for ($b = 0; $b -lt 256 -and -not $job.error_done -and $job.error_task.IsCompleted; $b++) {
                    $line = $job.error_task.GetAwaiter().GetResult()
                    $progress = $true
                    if ($null -eq $line) { $job.error_done = $true; break }
                    [void]$job.stderr.Add($line)
                    $job.error_task = $proc.StandardError.ReadLineAsync()
                }

                $finishNow = $false
                if ($proc.HasExited) {
                    if ($job.output_done -and $job.error_done) {
                        $finishNow = $true
                    }
                    else {
                        $ready = (-not $job.output_done -and $job.output_task.IsCompleted) -or
                            (-not $job.error_done -and $job.error_task.IsCompleted)
                        if (-not $ready -and $null -ne $job.exit_seen_at -and
                            ($watch.Elapsed.TotalSeconds - $job.exit_seen_at) -ge 10) {
                            $job.truncated = $true
                            $finishNow = $true
                        }
                    }
                }

                if ($finishNow) {
                    try { $proc.WaitForExit() } catch {}
                    $job.exit_code = if ($proc.HasExited) { [int]$proc.ExitCode } else { 3 }
                    $watch.Stop()
                    try { $proc.Dispose() } catch {}
                    $job.process = $null
                    $job.completed = $true
                    $resultsByIndex[$job.spec.Index] = $job
                    $active.RemoveAt($i)
                    $progress = $true
                }
            }

            if (-not $progress -and $active.Count -gt 0) {
                $waitTasks = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task]'
                foreach ($job in $active) {
                    if (-not $job.output_done -and $null -ne $job.output_task) {
                        [void]$waitTasks.Add($job.output_task)
                    }
                    if (-not $job.error_done -and $null -ne $job.error_task) {
                        [void]$waitTasks.Add($job.error_task)
                    }
                }
                if ($waitTasks.Count -gt 0) {
                    [void][System.Threading.Tasks.Task]::WaitAny(
                        [System.Threading.Tasks.Task[]]$waitTasks.ToArray(), 25
                    )
                }
                else {
                    Start-Sleep -Milliseconds 10
                }
            }
        }
    }
    finally {
        foreach ($job in $active) {
            if ($null -ne $job.process) {
                try {
                    if (-not $job.process.HasExited) {
                        Stop-OrchestraProcessTree -Process $job.process
                    }
                }
                catch {}
                try { $job.process.Dispose() } catch {}
                $job.process = $null
            }
            if ($null -ne $job.watch) { $job.watch.Stop() }
        }
        foreach ($dirPath in $createdStateDirs) {
            if ([IO.Directory]::Exists($dirPath)) {
                try {
                    if (@([IO.Directory]::GetFileSystemEntries($dirPath)).Count -eq 0) {
                        [IO.Directory]::Delete($dirPath, $false)
                    }
                }
                catch {}
            }
        }
    }

    return $resultsByIndex
}

function Invoke-SelftestRegistryChecks {
    param([hashtable]$Paths)

    try {
        $registry = Read-JsonFile -Path $Paths.Registry
        if ($null -eq $registry -or $registry -isnot [pscustomobject]) {
            throw 'Registry must be a JSON object.'
        }
        Add-SelftestStaticCheck 'models.json parses' $true
    }
    catch {
        Add-SelftestStaticCheck 'models.json parses' $false $_.Exception.Message
        return
    }

    $dimensions = Get-OrchestraProperty $registry 'cap_dimensions' @()
    $dimensionSet = @{}
    $dimensionsValid = ($dimensions -is [array] -and $dimensions.Count -gt 0)
    foreach ($dimension in $dimensions) {
        if ($dimension -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$dimension) -or
            $dimensionSet.ContainsKey([string]$dimension)) {
            $dimensionsValid = $false
        }
        else {
            $dimensionSet[[string]$dimension] = $true
        }
    }
    Add-SelftestStaticCheck 'cap_dimensions are nonempty and unique' $dimensionsValid

    $models = Get-OrchestraProperty $registry 'models' @()
    Add-SelftestStaticCheck 'models is a nonempty array' (
        $models -is [array] -and $models.Count -gt 0
    )
    $ids = @{}
    foreach ($model in $models) {
        $id = [string](Get-OrchestraProperty $model 'id')
        $validId = (
            -not [string]::IsNullOrWhiteSpace($id) -and
            -not $ids.ContainsKey($id)
        )
        Add-SelftestStaticCheck "model ID is present and unique: $id" $validId
        if (-not [string]::IsNullOrWhiteSpace($id)) { $ids[$id] = $true }

        $caps = Get-OrchestraProperty $model 'caps'
        $capNames = Get-OrchestraNames $caps
        foreach ($dimension in $dimensions) {
            $cap = Get-OrchestraProperty $caps ([string]$dimension)
            $present = (@($capNames) -contains $dimension -and $null -ne $cap)
            Add-SelftestStaticCheck "$id covers cap $dimension" $present
        }
        foreach ($dimension in $capNames) {
            $cap = Get-OrchestraProperty $caps $dimension
            $score = Get-OrchestraProperty $cap 'score'
            Add-SelftestStaticCheck "$id.$dimension.score is 0..10" (
                Test-SelftestNumber $score 0 10
            )
            $fields = Get-OrchestraNames $cap
            $approved = Get-OrchestraProperty $cap 'approved_score'
            Add-SelftestStaticCheck "$id.$dimension.approved_score exists" (
                @($fields) -contains 'approved_score' -and $null -ne $approved
            )
        }
        foreach ($rank in @('quota_rank', 'speed_rank')) {
            $value = Get-OrchestraProperty $model $rank
            Add-SelftestStaticCheck "$id.$rank is an integer in 1..3" (
                Test-SelftestNumber $value 1 3 -Integer
            )
        }
    }

    $aliases = Get-OrchestraProperty $registry 'aliases'
    Add-SelftestStaticCheck 'aliases is an object' (
        $aliases -is [pscustomobject]
    )
    $aliasNames = Get-OrchestraNames $aliases
    foreach ($alias in $aliasNames) {
        $reference = Get-OrchestraProperty $aliases $alias
        Add-SelftestStaticCheck "alias resolves: $alias" (
            Test-SelftestReference $registry $ids $reference
        )
    }

    $rules = Get-OrchestraProperty $registry 'hard_rules' @()
    Add-SelftestStaticCheck 'hard_rules is an array' ($rules -is [array])
    foreach ($rule in $rules) {
        $ruleId = [string](Get-OrchestraProperty $rule 'id' '<unnamed>')
        $ruleFields = Get-OrchestraNames $rule
        foreach ($field in @(
            'model', 'reviewer', 'reviewer_fallback', 'polisher', 'escalate_to'
        )) {
            if (@($ruleFields) -notcontains $field) { continue }
            $reference = Get-OrchestraProperty $rule $field
            if ($field -eq 'escalate_to' -and $null -eq $reference) { continue }
            Add-SelftestStaticCheck "hard rule $ruleId.$field resolves" (
                Test-SelftestReference $registry $ids $reference
            )
        }
        if (@($ruleFields) -contains 'fallback') {
            $references = Get-OrchestraProperty $rule 'fallback' @()
            foreach ($reference in $references) {
                Add-SelftestStaticCheck "hard rule $ruleId fallback resolves: $reference" (
                    Test-SelftestReference $registry $ids $reference
                )
            }
        }
    }

    $tags = Get-OrchestraProperty $registry 'tags'
    Add-SelftestStaticCheck 'tags is an object' ($tags -is [pscustomobject])
    $tagNames = Get-OrchestraNames $tags
    foreach ($tag in $tagNames) {
        $definition = Get-OrchestraProperty $tags $tag
        $tagCaps = Get-OrchestraProperty $definition 'caps' @()
        Add-SelftestStaticCheck "$tag.caps is a nonempty array" (
            $tagCaps -is [array] -and $tagCaps.Count -gt 0
        )
        foreach ($field in @('caps', 'review_caps')) {
            $references = Get-OrchestraProperty $definition $field @()
            foreach ($dimension in $references) {
                Add-SelftestStaticCheck "$tag.$field references $dimension" (
                    $dimensionSet.ContainsKey([string]$dimension)
                )
            }
        }
        $fields = Get-OrchestraNames $definition
        if (@($fields) -contains 'min_cap') {
            $minimum = Get-OrchestraProperty $definition 'min_cap'
            Add-SelftestStaticCheck "$tag.min_cap is 0..10" (
                Test-SelftestNumber $minimum 0 10
            )
        }
    }
}

try {
    if ($MaxParallel -lt 1) {
        throw 'ORCHESTRA_ARGS: MaxParallel must be at least 1.'
    }
    $paths = Get-OrchestraPaths -RegistryPath $RegistryPath -StateDir $StateDir
    try {
        Invoke-SelftestRegistryChecks -Paths $paths
    }
    catch {
        Add-SelftestStaticCheck 'registry validation completes' $false $_.Exception.Message
    }

    $jsonInputs = @(
        @{
            name = 'research.schema.json parses'
            path = Join-Path $paths.Root 'registry\research.schema.json'
        },
        @{
            name = 'probe-grade.schema.json parses'
            path = Join-Path $paths.Root 'registry\probe-grade.schema.json'
        },
        @{
            name = 'research-sample.json parses'
            path = Join-Path $paths.Root 'evals\fixtures\research-sample.json'
        }
    )
    foreach ($inputFile in $jsonInputs) {
        try {
            $document = Read-JsonFile -Path $inputFile.path
            if ($null -eq $document -or $document -isnot [pscustomobject]) {
                throw 'Expected a non-null JSON object.'
            }
            Add-SelftestStaticCheck $inputFile.name $true
        }
        catch {
            Add-SelftestStaticCheck $inputFile.name $false $_.Exception.Message
        }
    }

    $canonicalRegistry = [IO.Path]::GetFullPath((Join-Path $paths.Root 'registry\models.json'))
    if ([IO.Path]::GetFullPath($paths.Registry) -ieq $canonicalRegistry) {
        $syncScript = Join-Path $paths.Root 'scripts\sync-docs.ps1'
        try {
            $syncCheck = Invoke-OrchestraProcess -FilePath 'powershell.exe' `
                -Arguments @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', $syncScript, '-Check',
                    '-RegistryPath', $paths.Registry,
                    '-Root', $paths.Root
                ) -WorkDir $paths.Root -TimeoutSec 60 -CaptureStdout
            $syncOk = ($syncCheck.exit_code -eq 0 -and -not $syncCheck.timeout)
            $syncDetail = ''
            if (-not $syncOk) {
                $syncDetail = ($syncCheck.stdout + $syncCheck.stderr) -join ' '
            }
            Add-SelftestStaticCheck 'managed docs match models.json (sync-docs -Check)' $syncOk $syncDetail
        }
        catch {
            Add-SelftestStaticCheck 'managed docs match models.json (sync-docs -Check)' $false $_.Exception.Message
        }
    }

    if (-not $SkipTests) {
        $testDirectory = Join-Path $paths.Root 'tests'
        $testFiles = @(
            Get-ChildItem -LiteralPath $testDirectory -Filter 'test-*.ps1' -File |
                Sort-Object Name
        )
        if ($testFiles.Count -eq 0) {
            throw 'No tests/test-*.ps1 suites were found.'
        }

        $parallelLimit = if ($Serial) { 1 } else { [Math]::Max(1, $MaxParallel) }
        $jobsByIndex = @(Invoke-SelftestSuitePool `
            -TestFiles $testFiles -Paths $paths -ParallelLimit $parallelLimit `
            -SuiteStateRoot $StateDir -TimeoutSec 300)

        for ($idx = 0; $idx -lt $testFiles.Count; $idx++) {
            $testFile = $testFiles[$idx]
            $child = $jobsByIndex[$idx]
            $durationMs = if ($null -ne $child -and $null -ne $child.watch) {
                [Math]::Round($child.watch.Elapsed.TotalMilliseconds, 1)
            }
            else { 0.0 }
            try {
                if ($null -eq $child) {
                    throw 'Suite runner returned no execution record.'
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$child.start_error)) {
                    throw $child.start_error
                }

                $lines = @(
                    $child.stdout | Where-Object {
                        -not [string]::IsNullOrWhiteSpace([string]$_)
                    }
                )
                if ($lines.Count -eq 0) { throw 'Suite emitted no JSON summary.' }
                $summary = [string]$lines[$lines.Count - 1] | ConvertFrom-Json
                if ($summary -isnot [pscustomobject]) {
                    throw 'Suite summary must be a JSON object.'
                }

                $name = Get-OrchestraProperty $summary 'suite'
                $suitePassed = Get-OrchestraProperty $summary 'passed'
                $suiteFailed = Get-OrchestraProperty $summary 'failed'
                $fields = Get-OrchestraNames $summary
                if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name)) {
                    throw 'Suite summary has no valid suite name.'
                }
                if (-not (Test-SelftestNumber $suitePassed 0 2147483647 -Integer) -or
                    -not (Test-SelftestNumber $suiteFailed 0 2147483647 -Integer)) {
                    throw 'Suite passed/failed must be nonnegative integers.'
                }
                if (@($fields) -notcontains 'failures' -and
                    @($fields) -notcontains 'tests') {
                    throw 'Suite summary must contain failures or tests.'
                }

                $infrastructureErrors = New-Object 'System.Collections.Generic.List[string]'
                if ($child.timed_out) {
                    $null = $infrastructureErrors.Add('Suite process timed out.')
                }
                elseif ($child.exit_code -ne 0 -and [int]$suiteFailed -eq 0) {
                    $null = $infrastructureErrors.Add(
                        'Suite exited nonzero without reporting a failed test.'
                    )
                }
                if ($infrastructureErrors.Count -gt 0) {
                    Set-OrchestraProperty $summary 'failed' (
                        [long]$suiteFailed + $infrastructureErrors.Count
                    )
                    Set-OrchestraProperty $summary 'runner_failures' (
                        $infrastructureErrors.ToArray()
                    )
                }
                Set-OrchestraProperty $summary 'duration_ms' $durationMs
                Set-OrchestraProperty $summary 'process_exit' ([int]$child.exit_code)
                Set-OrchestraProperty $summary 'timeout' ([bool]$child.timed_out)
                $null = $suites.Add($summary)

                [Console]::Error.WriteLine((
                    '{0}: {1} passed, {2} failed.' -f
                    $name, $summary.passed, $summary.failed
                ))
                if ([long]$summary.failed -gt 0) {
                    foreach ($line in $child.stderr) {
                        if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
                            [Console]::Error.WriteLine([string]$line)
                        }
                    }
                    $details = Get-OrchestraProperty $summary 'failures' @()
                    foreach ($detail in $details) {
                        [Console]::Error.WriteLine(
                            '  ' + (ConvertTo-Json -InputObject $detail -Depth 32 -Compress)
                        )
                    }
                    foreach ($detail in $infrastructureErrors.ToArray()) {
                        [Console]::Error.WriteLine('  ' + $detail)
                    }
                }
            }
            catch {
                $message = $_.Exception.Message
                $processExit = $null
                $timedOut = $false
                if ($null -ne $child) {
                    $processExit = $child.exit_code
                    $timedOut = [bool]$child.timed_out
                    foreach ($line in $child.stderr) {
                        [Console]::Error.WriteLine([string]$line)
                    }
                }
                $null = $suites.Add([pscustomobject]@{
                    suite = $testFile.BaseName
                    passed = 0
                    failed = 1
                    failures = @($message)
                    duration_ms = $durationMs
                    process_exit = $processExit
                    timeout = $timedOut
                })
                [Console]::Error.WriteLine(
                    $testFile.Name + ': runner failure: ' + $message
                )
            }
        }
    }
}
catch {
    $null = $suites.Add([pscustomobject]@{
        suite = 'selftest-runner'
        passed = 0
        failed = 1
        failures = @($_.Exception.Message)
    })
    [Console]::Error.WriteLine('Selftest runner: ' + $_.Exception.Message)
}

$totalPassed = [long]$script:selftestStaticPassed
$totalFailed = [long]$script:selftestStaticFailed
foreach ($suite in $suites.ToArray()) {
    $totalPassed += [long]$suite.passed
    $totalFailed += [long]$suite.failed
}
[Console]::Error.WriteLine((
    'Selftest total: {0} passed, {1} failed.' -f $totalPassed, $totalFailed
))
Write-OrchestraResult -Object @{
    passed = $totalPassed
    failed = $totalFailed
    static = @{
        passed = $script:selftestStaticPassed
        failed = $script:selftestStaticFailed
        checks = $script:selftestStaticChecks.ToArray()
    }
    suites = $suites.ToArray()
}
if ($totalFailed -gt 0) { exit 1 }
exit 0
