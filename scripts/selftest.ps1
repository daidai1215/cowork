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
    [string]$StateDir
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

    $testDirectory = Join-Path $paths.Root 'tests'
    $testFiles = @(
        Get-ChildItem -LiteralPath $testDirectory -Filter 'test-*.ps1' -File |
            Sort-Object Name
    )
    if ($testFiles.Count -eq 0) {
        throw 'No tests/test-*.ps1 suites were found.'
    }

    foreach ($testFile in $testFiles) {
        $child = $null
        try {
            $child = Invoke-OrchestraProcess -FilePath 'powershell.exe' `
                -Arguments @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', $testFile.FullName,
                    '-RegistryPath', $paths.Registry
                ) -WorkDir $paths.Root -TimeoutSec 300 -CaptureStdout

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
            if ($child.timeout) {
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
            Set-OrchestraProperty $summary 'process_exit' ([int]$child.exit_code)
            Set-OrchestraProperty $summary 'timeout' ([bool]$child.timeout)
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
                $timedOut = [bool]$child.timeout
                foreach ($line in $child.stderr) {
                    [Console]::Error.WriteLine([string]$line)
                }
            }
            $null = $suites.Add([pscustomobject]@{
                suite = $testFile.BaseName
                passed = 0
                failed = 1
                failures = @($message)
                process_exit = $processExit
                timeout = $timedOut
            })
            [Console]::Error.WriteLine(
                $testFile.Name + ': runner failure: ' + $message
            )
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
