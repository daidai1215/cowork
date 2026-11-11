[CmdletBinding()]
param([string]$RegistryPath, [string]$StateDir)

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $root 'scripts\lib\common.ps1')
$script:probePassed = 0
$script:probeFailures = New-Object 'System.Collections.Generic.List[string]'
$testDirectory = $null
$testParent = $null
$testPaths = $null

function Assert-PTest {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:probePassed++ }
    else { $null = $script:probeFailures.Add($Name) }
}

function Invoke-PTestPlan {
    param(
        [string]$Name, [string]$Question = '',
        [string]$Channel, [string]$ModelFlag
    )
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $root 'scripts\probe-model.ps1'),
        '-DryRun', '-ModelId', $Name,
        '-RegistryPath', $testPaths.Registry, '-StateDir', $testPaths.StateDir
    )
    if (-not [string]::IsNullOrWhiteSpace($Question)) {
        $arguments += @('-Only', $Question)
    }
    if (-not [string]::IsNullOrWhiteSpace($Channel)) {
        $arguments += @('-Channel', $Channel)
    }
    if (-not [string]::IsNullOrWhiteSpace($ModelFlag)) {
        $arguments += @('-ModelFlag', $ModelFlag)
    }
    $child = Invoke-OrchestraProcess -FilePath 'powershell.exe' `
        -Arguments $arguments -WorkDir $root -TimeoutSec 45 -CaptureStdout
    if ($child.timeout -or $child.truncated) {
        throw 'Probe dry-run process timed out or output was truncated.'
    }
    $lines = @($child.stdout | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    if ($lines.Count -ne 1) {
        throw "Probe dry-run emitted $($lines.Count) nonempty stdout lines."
    }
    $result = [string]$lines[0] | ConvertFrom-Json
    return [pscustomobject]@{ Exit = [int]$child.exit_code; Result = $result }
}

try {
    $sourcePaths = Get-OrchestraPaths -RegistryPath $RegistryPath -StateDir $null
    $testParent = $StateDir
    if ([string]::IsNullOrWhiteSpace($testParent)) {
        $testParent = [IO.Path]::GetTempPath()
    }
    $testParent = [IO.Path]::GetFullPath($testParent)
    $testDirectory = Join-Path $testParent (
        'model-orchestra-probe-test-' + [Guid]::NewGuid().ToString('N')
    )
    $null = [IO.Directory]::CreateDirectory($testDirectory)
    $testPaths = Get-OrchestraPaths `
        -RegistryPath (Join-Path $testDirectory 'registry\models.json') `
        -StateDir (Join-Path $testDirectory 'state')
    $null = [IO.Directory]::CreateDirectory($testPaths.RegistryDir)
    $null = [IO.File]::Copy($sourcePaths.Registry, $testPaths.Registry, $false)
    $registryBefore = [IO.File]::ReadAllText($testPaths.Registry, $script:OrchestraUtf8)
    $expectedFiles = @(
        '01-code-rigor.md', '02-math.md', '03-prose.md',
        '04-frontend-aesthetic.md', '05-world-knowledge.md'
    )
    foreach ($name in $expectedFiles) {
        $file = Join-Path $root ('evals\probe\' + $name)
        $exists = [IO.File]::Exists($file)
        Assert-PTest $exists ('Probe exists: ' + $name)
        $nonempty = $false
        if ($exists) {
            $text = [IO.File]::ReadAllText($file, $script:OrchestraUtf8)
            $nonempty = -not [string]::IsNullOrWhiteSpace($text)
        }
        Assert-PTest $nonempty ('Probe is nonempty: ' + $name)
    }
    try {
        $run = Invoke-PTestPlan -Name 'gemini-4-carbon'
        Assert-PTest ($run.Exit -eq 0) 'Full dry-run exits 0'
        $plans = Get-OrchestraProperty $run.Result 'planned' @()
        Assert-PTest (
            $plans -is [array] -and $plans.Count -eq 5
        ) 'Full dry-run returns five planned probes'
        $answers = Get-OrchestraProperty $run.Result 'results' @()
        Assert-PTest (
            $answers -is [array] -and $answers.Count -eq 0
        ) 'Dry-run has no invocation results'
        Assert-PTest (
            (Get-OrchestraProperty $run.Result 'model') -eq 'gemini-4-carbon'
        ) 'Dry-run reports the canonical model ID'
    }
    catch { $null = $script:probeFailures.Add('Full dry-run: ' + $_.Exception.Message) }

    try {
        $run = Invoke-PTestPlan -Name 'gemini-4-carbon' -Question '2'
        Assert-PTest ($run.Exit -eq 0) 'Only 2 exits 0'
        $plans = Get-OrchestraProperty $run.Result 'planned' @()
        $onePlan = $plans -is [array] -and $plans.Count -eq 1
        Assert-PTest $onePlan 'Only 2 returns one planned probe'
        if ($onePlan) {
            Assert-PTest (
                (Get-OrchestraProperty $plans[0] 'probe') -eq '02-math.md'
            ) 'Only 2 selects the math question'
        }
    }
    catch { $null = $script:probeFailures.Add('Only 2: ' + $_.Exception.Message) }

    try {
        $unknown = 'unknown-probe-model-' + [Guid]::NewGuid().ToString('N')
        $run = Invoke-PTestPlan -Name $unknown
        Assert-PTest ($run.Exit -ne 0) 'Unknown model exits nonzero'
    }
    catch {
        $null = $script:probeFailures.Add('Unknown model test: ' + $_.Exception.Message)
    }

    $registry = Read-JsonFile -Path $testPaths.Registry
    $aliases = Get-OrchestraProperty $registry 'aliases'
    $aliasNames = Get-OrchestraNames $aliases
    if (@($aliasNames).Count -gt 0) {
        try {
            $alias = [string](@($aliasNames)[0])
            $expectedId = Resolve-ModelId -Registry $registry -Name $alias
            $run = Invoke-PTestPlan -Name $alias -Question '2'
            Assert-PTest (
                $run.Exit -eq 0 -and
                (Get-OrchestraProperty $run.Result 'model') -eq $expectedId
            ) 'Model aliases resolve in probe plans'
        }
        catch { $null = $script:probeFailures.Add('Alias test: ' + $_.Exception.Message) }
    }

    try {
        $run = Invoke-PTestPlan -Name 'unregistered-probe-9' -Channel 'agy'
        $plans = Get-OrchestraProperty $run.Result 'planned' @()
        Assert-PTest (
            $run.Exit -eq 0 -and @($plans).Count -eq 5
        ) 'Unregistered agy model plans five probes'
        $badPlans = @($plans | Where-Object {
            $_.ad_hoc -ne $true -or $_.channel -ne 'agy' -or
            $_.model_flag -ne 'unregistered-probe-9-high'
        })
        Assert-PTest (
            $badPlans.Count -eq 0
        ) 'AdHoc plans retain channel and constructed slug'
        $run = Invoke-PTestPlan -Name 'unregistered-probe-9' -Channel 'agy' `
            -ModelFlag 'unregistered-probe-9-low'
        $plans = Get-OrchestraProperty $run.Result 'planned' @()
        Assert-PTest (
            $run.Exit -eq 0 -and $plans[0].model_flag -eq 'unregistered-probe-9-low' -and
            $plans[0].effort -eq 'low'
        ) 'Explicit AdHoc slug retains its effort'
    }
    catch { $null = $script:probeFailures.Add('AdHoc dry-run: ' + $_.Exception.Message) }

    $registryAfter = [IO.File]::ReadAllText($testPaths.Registry, $script:OrchestraUtf8)
    Assert-PTest (
        $registryBefore -ceq $registryAfter
    ) 'Dry-runs preserve the registry'
    Assert-PTest (
        -not [IO.Directory]::Exists($testPaths.StateDir)
    ) 'Dry-runs do not create runtime state'
}
catch { $null = $script:probeFailures.Add('Harness: ' + $_.Exception.Message) }
finally {
    if ($null -ne $testDirectory -and [IO.Directory]::Exists($testDirectory)) {
        try {
            $absolute = [IO.Path]::GetFullPath($testDirectory)
            $parentPrefix = $testParent.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            $leaf = [IO.Path]::GetFileName($absolute)
            if (-not $absolute.StartsWith($parentPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                $leaf -notmatch '^model-orchestra-probe-test-[a-f0-9]{32}$') {
                throw 'Refusing cleanup outside the unique test directory.'
            }
            $null = [IO.Directory]::Delete($absolute, $true)
        }
        catch { $null = $script:probeFailures.Add('Cleanup: ' + $_.Exception.Message) }
    }
}
Write-OrchestraResult -Object @{
    suite = 'probe'; passed = $script:probePassed
    failed = $script:probeFailures.Count; failures = $script:probeFailures.ToArray()
}
if ($script:probeFailures.Count -gt 0) { exit 1 }
exit 0
