<#
.SYNOPSIS
Runs isolated, offline research-application acceptance tests.
.DESCRIPTION
Uses temporary RegistryPath and StateDir values.
Never calls Codex, Antigravity, or network services.
Emits exactly one JSON suite result to stdout.
#>
[CmdletBinding()]
param(
    [string]$RegistryPath,
    [string]$StateDir,
    [switch]$KeepTemp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\lib\common.ps1')

# Preserve the source before a function creates its local $registryPath.
$script:SourceRegistryPath = if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
    Join-Path $root 'registry\models.json'
}
else {
    [IO.Path]::GetFullPath($RegistryPath)
}

$engine = (Get-Process -Id $PID).Path
$temporaryRoot = [IO.Path]::GetFullPath(
    (Join-Path ([IO.Path]::GetTempPath()) ('orchestra-apply-' + [guid]::NewGuid().ToString('N')))
)
[void][IO.Directory]::CreateDirectory($temporaryRoot)
$results = New-Object 'System.Collections.Generic.List[object]'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Clone-Json {
    param($Object)
    return ($Object | ConvertTo-Json -Depth 32 | ConvertFrom-Json)
}

function Quote-NativeArgument {
    param([string]$Text)
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Text.ToCharArray()) {
        if ($character -eq '\') {
            $slashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * ($slashes * 2 + 1)))
            [void]$builder.Append('"')
        }
        else {
            if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)) }
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-Child {
    param(
        [string]$Script,
        [string[]]$Arguments,
        [int]$ExpectedExit = 0
    )
    $allArguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $root $Script)
    ) + $Arguments

    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $engine
    $info.Arguments = (@($allArguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding $false
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding $false

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill()
            $process.WaitForExit()
            throw ('Test child timed out: ' + $Script)
        }
        $output = $outputTask.GetAwaiter().GetResult()
        $errorOutput = $errorTask.GetAwaiter().GetResult()
        $code = $process.ExitCode
        if ($code -ne $ExpectedExit) {
            throw ('Expected exit {0}, got {1}. stderr: {2} stdout: {3}' -f $ExpectedExit, $code, $errorOutput, $output)
        }
        $lines = @($output -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Assert-True ($lines.Count -eq 1) ('Expected exactly one stdout JSON line: ' + $output)
        return ($lines[0] | ConvertFrom-Json)
    }
    finally {
        $process.Dispose()
    }
}

function New-Context {
    param([string]$Name)
    $directory = Join-Path $temporaryRoot $Name
    [void][IO.Directory]::CreateDirectory($directory)
    $registryPath = Join-Path $directory 'registry\models.json'
    $stateDirectory = Join-Path $directory 'state'
    $paths = Get-OrchestraPaths -RegistryPath $registryPath -StateDir $stateDirectory
    $sourceRegistry = $script:SourceRegistryPath
    $registry = Clone-Json (Read-JsonFile -Path $sourceRegistry)
    $geminiFixture = @($registry.models | Where-Object { $_.id -eq 'gemini-4-carbon' })[0]
    if ($null -ne $geminiFixture) {
        foreach ($capName in @('code_rigor', 'backend', 'math')) {
            $geminiFixture.caps.$capName.score = 7
            $geminiFixture.caps.$capName.approved_score = 7
        }
    }
    Write-JsonAtomic -Path $paths.Registry -Object $registry
    return [pscustomobject]@{
        Directory = $directory
        Paths = $paths
        BaseRev = [long]$registry.registry_rev
    }
}

function Read-TestRegistry {
    param($Context)
    return (Read-Registry -Paths $Context.Paths)
}

function Get-TestModel {
    param($Context, [string]$Id)
    return @((Read-TestRegistry $Context).models | Where-Object { $_.id -eq $Id }) |
        Select-Object -First 1
}

function Read-Sample {
    return (Read-JsonFile -Path (Join-Path $root 'evals\fixtures\research-sample.json'))
}

function Save-Research {
    param($Context, $Research, [string]$Name = 'research.json')
    $path = Join-Path $Context.Directory $Name
    Write-JsonAtomic -Path $path -Object $Research
    return $path
}

function Invoke-Apply {
    param(
        $Context,
        [string[]]$Arguments,
        [int]$ExpectedExit = 0
    )
    $argumentsWithPaths = $Arguments + @(
        '-RegistryPath', $Context.Paths.Registry,
        '-StateDir', $Context.Paths.StateDir
    )
    return (Invoke-Child 'scripts\apply-research.ps1' $argumentsWithPaths $ExpectedExit)
}

function New-Refresh {
    param($Context)
    $research = Read-Sample
    $registry = Read-TestRegistry $Context
    $model = @($registry.models | Where-Object { $_.id -eq 'gemini-4-carbon' })[0]
    $research.model_id = $model.id
    $research.family = $model.family
    $research.generation = $model.generation
    $research.vendor = $model.vendor
    $research.channel = $model.channel
    $research.tier = $model.tier
    $research.speed_rank_hint = $model.speed_rank
    $research.quota_rank_hint = $model.quota_rank
    $research.notable_strengths = @($model.strengths)
    $research.notable_weaknesses = @($model.weaknesses)
    foreach ($dimension in @($registry.cap_dimensions)) {
        $cap = $research.caps.PSObject.Properties[$dimension].Value
        $cap.score = $model.caps.PSObject.Properties[$dimension].Value.score
        $cap.vs_incumbent = 0
        $cap.confidence = 0.7
        $cap.evidence = @([pscustomobject]@{
            url = 'https://example.org/model-orchestra/fixture'
            claim = ('Synthetic refresh fixture: ' + $dimension)
            date = '2026-11-10'
        })
    }
    return $research
}

function Find-CapProposal {
    param($Result, [string]$Dimension)
    foreach ($path in @($Result.proposals)) {
        # approved proposals are archived (renamed); skip paths that no longer exist
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $proposal = Read-JsonFile -Path $path
        foreach ($operation in @($proposal.patch)) {
            if ($operation.op -eq 'set' -and $operation.path -like ("*.caps.$Dimension.score")) {
                return $path
            }
        }
    }
    throw ('Missing cap proposal: ' + $Dimension)
}

function Mutate-Registry {
    param($Context, [scriptblock]$Mutation)
    $null = Invoke-WithLock -Paths $Context.Paths -Name registry -ScriptBlock {
        $registry = Read-Registry -Paths $Context.Paths
        $null = & $Mutation $registry
        $null = Save-Registry -Paths $Context.Paths -Registry $registry -Reason 'Test mutation'
    }
}

function Run-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        $null = & $Body
        [void]$results.Add([pscustomobject]@{ name = $Name; passed = $true })
    }
    catch {
        [void]$results.Add([pscustomobject]@{
            name = $Name
            passed = $false
            error = $_.Exception.Message
        })
    }
}

try {
    Run-Case 'new-candidate-inheritance-history' {
        $context = New-Context 'new'
        $sample = Read-Sample
        $result = Invoke-Apply $context @('-ResearchFile', (Save-Research $context $sample))
        $model = Get-TestModel $context 'fake-model-9'
        Assert-True ($null -ne $model) 'Candidate was not added.'
        Assert-True ($model.status -eq 'candidate') 'New model is not candidate.'
        Assert-True ($model.channel -eq 'agy') 'Wrong invocation channel.'
        Assert-True ($model.invoke.model_flag -eq 'fake-model-9-{effort}') 'Wrong agy flag.'
        Assert-True (($model.invoke.efforts -join ',') -eq 'low,medium,high') 'Missing raw_slugs did not use compatibility efforts.'
        Assert-True ($model.caps.prose.source -eq 'inherited') 'Missing evidence must use inheritance.'
        Assert-True ($model.caps.prose.score -eq 9) 'Inheritance must use min(research 9, donor 10).'
        Assert-True ($model.caps.prose.confidence -eq 0.4) 'Wrong inheritance confidence.'
        Assert-True (@($model.caps.prose.evidence).Count -eq 0) 'Inherited cap gained fabricated evidence.'
        Assert-True ($model.caps.code_rigor.source -eq 'public') 'Supported cap must use public source.'
        Assert-True ((Read-TestRegistry $context).registry_rev -eq $context.BaseRev + 1) 'Revision did not increment once.'
        Assert-True (Test-Path -LiteralPath $result.backup) 'Backup missing.'
        Assert-True ((Read-JsonFile -Path $result.backup).registry_rev -eq $context.BaseRev) 'Backup is not the preimage.'
        Assert-True ([IO.Path]::GetFileName($result.backup) -match '^models-\d{8}-\d{6}-\d+-[a-zA-Z0-9]{4}\.json$') 'Wrong snapshot filename.'
        Assert-True (Test-Path -LiteralPath $context.Paths.Changelog) 'Changelog missing.'
        $bytes = [IO.File]::ReadAllBytes($context.Paths.Registry)
        Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'Registry has a BOM.'
        $state = Read-State -Paths $context.Paths
        Assert-True ($null -eq $state.research_leases.PSObject.Properties['fake-model-9']) 'Research lease was not released.'
    }

    Run-Case 'tie-does-not-propose-best-knowledge' {
        $context = New-Context 'tie'
        $result = Invoke-Apply $context @('-ResearchFile', (Save-Research $context (Read-Sample)))
        foreach ($path in @($result.proposals)) {
            $proposal = Read-JsonFile -Path $path
            foreach ($operation in @($proposal.patch)) {
                Assert-True ($operation.path -ne 'aliases.best-knowledge') 'A zero-margin tie proposed an alias change.'
            }
        }
        Assert-True ((Read-TestRegistry $context).aliases.'best-knowledge' -eq 'gemini-4-carbon') 'Alias changed automatically.'
    }

    Run-Case 'refresh-small-large-and-locked' {
        $context = New-Context 'refresh'
        $research = New-Refresh $context
        $research.caps.code_rigor.score = 8
        $research.caps.math.score = 10
        $research.caps.prose.score = 8
        $research.caps.long_context.score = 9
        $result = Invoke-Apply $context @('-ResearchFile', (Save-Research $context $research))
        $model = Get-TestModel $context 'gemini-4-carbon'
        Assert-True ($model.caps.code_rigor.score -eq 8) 'Delta 1 did not apply.'
        Assert-True ($model.caps.code_rigor.approved_score -eq 7) 'Auto apply moved the approved anchor.'
        Assert-True ($model.caps.math.score -eq 7) 'Delta 3 applied automatically.'
        Assert-True ($model.caps.prose.score -eq 10) 'Locked score changed.'
        Assert-True ($model.caps.prose.confidence -eq 0.8) 'Locked confidence decreased.'
        Assert-True ($model.caps.long_context.score -eq 9) 'Unlocked small update failed.'
        $null = Find-CapProposal $result 'math'
        $prosePath = Find-CapProposal $result 'prose'
        $preview = Invoke-Apply $context @('-Approve', $prosePath, '-DryRun')
        Assert-True $preview.dry_run 'Locked one-time approval dry run failed.'

        $null = Invoke-WithLock -Paths $context.Paths -Name registry -ScriptBlock {
            $proposal = Read-JsonFile -Path $prosePath
            foreach ($operation in @($proposal.patch)) {
                if ($operation.path -eq 'models[id=gemini-4-carbon].caps.prose.score') {
                    $operation.unlock = $true
                }
            }
            Write-JsonAtomic -Path $prosePath -Object $proposal
        }
        $null = Invoke-Apply $context @('-Approve', $prosePath)
        $model = Get-TestModel $context 'gemini-4-carbon'
        Assert-True ($model.caps.prose.score -eq 8) 'Explicit unlock approval failed.'
        Assert-True (-not $model.caps.prose.locked) 'Explicit unlock did not unlock.'
        Assert-True ($model.caps.prose.approved_score -eq 8) 'Approval did not update anchor.'
    }

    Run-Case 'locked-evidence-old-value-shapes' {
        foreach ($shape in @('missing', 'null', 'empty', 'one', 'many')) {
            $context = New-Context ('evidence-' + $shape)
            Mutate-Registry $context {
                param($registry)
                $model = @($registry.models | Where-Object { $_.id -eq 'gemini-4-carbon' })[0]
                $cap = $model.caps.prose
                if ($shape -eq 'missing') {
                    [void]$cap.PSObject.Properties.Remove('evidence')
                }
                else {
                    $oldEvidence = $null
                    if ($shape -eq 'empty') { $oldEvidence = @() }
                    if ($shape -in @('one', 'many')) {
                        $oldEvidence = @([pscustomobject]@{
                            url = 'https://example.org/model-orchestra/old-1'
                            claim = 'Synthetic old evidence one.'
                            date = '2026-11-10'
                        })
                        if ($shape -eq 'many') {
                            $oldEvidence += [pscustomobject]@{
                                url = 'https://example.org/model-orchestra/old-2'
                                claim = 'Synthetic old evidence two.'
                                date = '2026-11-10'
                            }
                        }
                    }
                    $cap | Add-Member -MemberType NoteProperty -Name evidence -Value $oldEvidence -Force
                }
            }
            $beforeCap = (Get-TestModel $context 'gemini-4-carbon').caps.prose
            $beforeJson = ConvertTo-Json -InputObject $beforeCap -Depth 32 -Compress
            $research = New-Refresh $context
            $research.caps.prose.score = 8
            $result = Invoke-Apply $context @('-ResearchFile', (Save-Research $context $research))
            $afterCap = (Get-TestModel $context 'gemini-4-carbon').caps.prose
            $afterJson = ConvertTo-Json -InputObject $afterCap -Depth 32 -Compress
            Assert-True ($beforeJson -ceq $afterJson) ('Research changed a locked cap: ' + $shape)

            $proposalPath = Find-CapProposal $result 'prose'
            $proposal = Read-JsonFile -Path $proposalPath
            $evidenceOps = @($proposal.patch | Where-Object { $_.path -eq 'models[id=gemini-4-carbon].caps.prose.evidence' })
            Assert-True ($evidenceOps.Count -eq 1) ('Wrong evidence operation count: ' + $shape)
            $operation = $evidenceOps[0]
            if ($shape -in @('missing', 'null')) {
                Assert-True ($null -eq $operation.old_value) ('Absent/null evidence was not preserved: ' + $shape)
            }
            else {
                $count = 0
                if ($shape -eq 'one') { $count = 1 }
                if ($shape -eq 'many') { $count = 2 }
                Assert-True ($operation.old_value -is [array]) ('Old evidence lost array type: ' + $shape)
                Assert-True ($operation.old_value.Count -eq $count) ('Old evidence gained/lost a wrapper: ' + $shape)
                $expectedJson = ConvertTo-Json -InputObject $beforeCap.evidence -Depth 32 -Compress
                $actualJson = ConvertTo-Json -InputObject $operation.old_value -Depth 32 -Compress
                Assert-True ($expectedJson -ceq $actualJson) ('Old evidence content changed: ' + $shape)
            }
            Assert-True ($operation.value -is [array]) ('New evidence lost array type: ' + $shape)
            Assert-True ($operation.value.Count -eq 1) ('New evidence gained a wrapper: ' + $shape)

            $preview = Invoke-Apply $context @('-Approve', $proposalPath, '-DryRun')
            Assert-True $preview.dry_run ('One-time approval preview failed: ' + $shape)
            Assert-True ((Get-TestModel $context 'gemini-4-carbon').caps.prose.locked) 'Preview changed the lock.'

            $null = Invoke-WithLock -Paths $context.Paths -Name registry -ScriptBlock {
                foreach ($item in @($proposal.patch)) {
                    if ($item.path -eq 'models[id=gemini-4-carbon].caps.prose.score') {
                        $item.unlock = $true
                    }
                }
                Write-JsonAtomic -Path $proposalPath -Object $proposal
            }
            $revision = (Read-TestRegistry $context).registry_rev
            $preview = Invoke-Apply $context @('-Approve', $proposalPath, '-DryRun')
            Assert-True $preview.dry_run ('Approval dry run failed: ' + $shape)
            Assert-True ((Read-TestRegistry $context).registry_rev -eq $revision) 'Approval dry run changed registry.'

            $null = Invoke-Apply $context @('-Approve', $proposalPath)
            $cap = (Get-TestModel $context 'gemini-4-carbon').caps.prose
            Assert-True ($cap.score -eq 8 -and $cap.approved_score -eq 8 -and -not $cap.locked) ('Approval failed: ' + $shape)
            Assert-True ($cap.evidence -is [array]) ('Applied evidence lost array type: ' + $shape)
            Assert-True ($cap.evidence.Count -eq 1) ('Applied evidence gained a wrapper: ' + $shape)
            Assert-True ($cap.evidence[0].claim -eq 'Synthetic refresh fixture: prose') ('Applied evidence content changed: ' + $shape)
        }
    }

    Run-Case 'locked-evidence-real-change-still-conflicts' {
        $context = New-Context 'evidence-conflict'
        $research = New-Refresh $context
        $research.caps.prose.score = 8
        $result = Invoke-Apply $context @('-ResearchFile', (Save-Research $context $research))
        $proposalPath = Find-CapProposal $result 'prose'
        Mutate-Registry $context {
            param($registry)
            $model = @($registry.models | Where-Object { $_.id -eq 'gemini-4-carbon' })[0]
            $model.caps.prose | Add-Member -MemberType NoteProperty -Name evidence -Value @() -Force
        }
        $null = Invoke-WithLock -Paths $context.Paths -Name registry -ScriptBlock {
            $proposal = Read-JsonFile -Path $proposalPath
            $proposal.base_rev = (Read-TestRegistry $context).registry_rev
            foreach ($operation in @($proposal.patch)) {
                if ($operation.path -eq 'models[id=gemini-4-carbon].caps.prose.score') {
                    $operation.unlock = $true
                }
            }
            Write-JsonAtomic -Path $proposalPath -Object $proposal
        }
        $revision = (Read-TestRegistry $context).registry_rev
        $blocked = Invoke-Apply $context @('-Approve', $proposalPath) 2
        Assert-True ($blocked.error -eq 'ORCHESTRA_ARGS: old_value conflict: models[id=gemini-4-carbon].caps.prose.evidence') 'A real null-to-empty evidence change was ignored.'
        Assert-True ((Read-TestRegistry $context).registry_rev -eq $revision) 'Rejected approval changed revision.'
        Assert-True ((Get-TestModel $context 'gemini-4-carbon').caps.prose.locked) 'Rejected approval unlocked the cap.'
    }

    Run-Case 'cumulative-drift-uses-approved-score' {
        $context = New-Context 'drift'
        foreach ($target in @(8, 9)) {
            $research = New-Refresh $context
            $research.caps.code_rigor.score = $target
            $null = Invoke-Apply $context @('-ResearchFile', (Save-Research $context $research))
        }
        $model = Get-TestModel $context 'gemini-4-carbon'
        Assert-True ($model.caps.code_rigor.score -eq 9) 'Allowed cumulative delta 2 failed.'
        Assert-True ($model.caps.code_rigor.approved_score -eq 7) 'Anchor drifted.'
        $research = New-Refresh $context
        $research.caps.code_rigor.score = 10
        $result = Invoke-Apply $context @('-ResearchFile', (Save-Research $context $research))
        Assert-True ((Get-TestModel $context 'gemini-4-carbon').caps.code_rigor.score -eq 9) 'Cumulative delta 3 applied.'
        $null = Find-CapProposal $result 'code_rigor'
    }

    Run-Case 'approval-unrelated-revision-rebases-and-archives' {
        $context = New-Context 'approval-revision'
        $research = New-Refresh $context
        $research.caps.math.score = 10
        $result = Invoke-Apply $context @('-ResearchFile', (Save-Research $context $research))
        $proposalPath = Find-CapProposal $result 'math'
        Mutate-Registry $context {
            param($registry)
            $registry.models[0].display_name = 'Unrelated test change'
        }
        $approved = Invoke-Apply $context @('-Approve', $proposalPath)
        Assert-True $approved.rebased 'Unrelated revision did not auto-rebase.'
        Assert-True ((Get-TestModel $context 'gemini-4-carbon').caps.math.approved_score -eq 10) 'Rebased approval failed.'
        Assert-True (Test-Path -LiteralPath $approved.approved) 'Approved archive missing.'
        $archive = Read-JsonFile -Path $approved.approved
        Assert-True ($archive.base_rev -gt $archive.original_base_rev) 'Archive did not preserve rebase provenance.'
        Assert-True (-not (Test-Path -LiteralPath $proposalPath)) 'Pending JSON was not archived.'
        $null = Invoke-Apply $context @('-Approve', $approved.approved, '-Force') 2
    }

    Run-Case 'approval-old-value-conflict' {
        $context = New-Context 'approval-value'
        $research = New-Refresh $context
        $research.caps.math.score = 10
        $result = Invoke-Apply $context @('-ResearchFile', (Save-Research $context $research))
        $proposalPath = Find-CapProposal $result 'math'
        Mutate-Registry $context {
            param($registry)
            $model = @($registry.models | Where-Object { $_.id -eq 'gemini-4-carbon' })[0]
            $model.caps.math.score = 8
        }
        $null = Invoke-WithLock -Paths $context.Paths -Name registry -ScriptBlock {
            $proposal = Read-JsonFile -Path $proposalPath
            $proposal.base_rev = (Read-TestRegistry $context).registry_rev
            Write-JsonAtomic -Path $proposalPath -Object $proposal
        }
        $null = Invoke-Apply $context @('-Approve', $proposalPath) 2
        Assert-True ((Get-TestModel $context 'gemini-4-carbon').caps.math.score -eq 8) 'old_value conflict was ignored.'
        $null = Invoke-Apply $context @('-Approve', $proposalPath, '-Force')
        Assert-True ((Get-TestModel $context 'gemini-4-carbon').caps.math.score -eq 10) 'Explicit forced conflict override failed.'
    }

    Run-Case 'rollback-monotonic-and-force-guard' {
        $context = New-Context 'rollback'
        $result = Invoke-Apply $context @('-ResearchFile', (Save-Research $context (Read-Sample)))
        $before = [long](Read-TestRegistry $context).registry_rev
        $rolled = Invoke-Apply $context @('-Rollback', $result.backup)
        Assert-True ($null -eq (Get-TestModel $context 'fake-model-9')) 'Rollback did not restore the preimage.'
        Assert-True ($rolled.registry_rev -eq $before + 1) 'Rollback reset the revision instead of incrementing it.'
        Assert-True (Test-Path -LiteralPath $rolled.backup) 'Rollback did not preserve the overwritten registry.'

        $result = Invoke-Apply $context @('-ResearchFile', (Save-Research $context (Read-Sample)))
        Mutate-Registry $context {
            param($registry)
            $registry.models[0].display_name = 'Later edit'
        }
        $before = [long](Read-TestRegistry $context).registry_rev
        $null = Invoke-Apply $context @('-Rollback', $result.backup) 2
        Assert-True ((Read-TestRegistry $context).registry_rev -eq $before) 'Rejected rollback changed revision.'
        $rolled = Invoke-Apply $context @('-Rollback', $result.backup, '-Force')
        Assert-True ($rolled.registry_rev -eq $before + 1) 'Forced rollback revision is not monotonic.'
        Assert-True ($null -eq (Get-TestModel $context 'fake-model-9')) 'Forced rollback failed.'
    }

    Run-Case 'low-confidence-rejection' {
        $context = New-Context 'reject'
        $research = Read-Sample
        foreach ($dimension in @((Read-TestRegistry $context).cap_dimensions)) {
            $cap = $research.caps.PSObject.Properties[$dimension].Value
            $cap.confidence = 0.1
            $cap.evidence = @([pscustomobject]@{
                url = 'https://example.org/model-orchestra/fixture'
                claim = 'Synthetic low-confidence fixture.'
                date = '2026-11-10'
            })
        }
        $result = Invoke-Apply $context @('-ResearchFile', (Save-Research $context $research))
        Assert-True $result.rejected 'Low-confidence research was not rejected.'
        Assert-True ($null -eq (Get-TestModel $context 'fake-model-9')) 'Rejected candidate was added.'
        Assert-True ((Read-TestRegistry $context).registry_rev -eq $context.BaseRev) 'Rejection changed models.json.'
        $state = Read-State -Paths $context.Paths
        Assert-True (@($state.rejected_slugs) -contains 'fake-model-9') 'Rejected slug not recorded.'
        Assert-True (Test-Path -LiteralPath $context.Paths.Changelog) 'Rejection was not logged.'
    }

    Run-Case 'cross-check-new-candidate-inherits-and-proposes' {
        $context = New-Context 'cross-check-new'
        $cross = [pscustomobject]@{
            disputed = @(
                [pscustomobject]@{ cap = 'world_knowledge'; reason = 'Synthetic numeric disagreement.'; suggested_score = 9 },
                [pscustomobject]@{ cap = 'code_rigor'; reason = 'Synthetic uncertainty.'; suggested_score = $null }
            )
        }
        $crossPath = Join-Path $context.Directory 'cross-check.json'
        Write-JsonAtomic -Path $crossPath -Object $cross
        $result = Invoke-Apply $context @(
            '-ResearchFile', (Save-Research $context (Read-Sample)),
            '-CrossCheckFile', $crossPath
        )
        $model = Get-TestModel $context 'fake-model-9'
        Assert-True ($model.caps.world_knowledge.score -eq 10) 'Disputed suggestion was auto-applied.'
        Assert-True ($model.caps.world_knowledge.confidence -eq 0.4) 'Disputed new cap must inherit confidence.'
        Assert-True ($model.caps.world_knowledge.source -eq 'inherited') 'Disputed new cap retained public source.'
        Assert-True (@($model.caps.world_knowledge.evidence).Count -eq 0) 'Disputed evidence was auto-applied.'
        Assert-True ($model.caps.code_rigor.score -eq 7) 'New disputed cap did not use the conservative donor score.'
        Assert-True ($model.caps.code_rigor.confidence -eq 0.4) 'Wrong new disputed confidence.'
        foreach ($cap in @('world_knowledge', 'code_rigor')) {
            $proposal = Read-JsonFile -Path (Find-CapProposal $result $cap)
            Assert-True ($proposal.cross_check.cap -eq $cap) 'Missing cross-check cap.'
            Assert-True (-not [string]::IsNullOrWhiteSpace($proposal.cross_check.reason)) 'Missing dispute reason.'
            if ($cap -eq 'world_knowledge') {
                Assert-True ($proposal.cross_check.research_score -eq 10 -and $proposal.cross_check.suggested_score -eq 9) 'Lost research/suggested scores.'
            }
            else {
                Assert-True ($proposal.cross_check.research_score -eq 8 -and $null -eq $proposal.cross_check.suggested_score) 'Null suggestion was not preserved.'
            }
        }
    }

    Run-Case 'cross-check-refresh-freezes-score-confidence-and-evidence' {
        $context = New-Context 'cross-check-refresh'
        $research = New-Refresh $context
        $research.caps.code_rigor.score = 8
        $research.caps.backend.score = 6
        $research.caps.math.score = 8
        $before = Get-TestModel $context 'gemini-4-carbon'
        $crossPath = Join-Path $context.Directory 'cross-check.json'
        Write-JsonAtomic -Path $crossPath -Object ([pscustomobject]@{
            disputed = @(
                [pscustomobject]@{ cap = 'code_rigor'; reason = 'No replacement score.'; suggested_score = $null },
                [pscustomobject]@{ cap = 'backend'; reason = 'Review proposed a different score.'; suggested_score = 9 }
            )
        })
        $result = Invoke-Apply $context @('-ResearchFile', (Save-Research $context $research), '-CrossCheckFile', $crossPath)
        $after = Get-TestModel $context 'gemini-4-carbon'
        foreach ($cap in @('code_rigor', 'backend')) {
            $old = ConvertTo-Json -InputObject $before.caps.PSObject.Properties[$cap].Value -Depth 32 -Compress
            $new = ConvertTo-Json -InputObject $after.caps.PSObject.Properties[$cap].Value -Depth 32 -Compress
            Assert-True ($old -ceq $new) ('Disputed refresh changed the cap: ' + $cap)
            $proposalPath = Find-CapProposal $result $cap
            $proposal = Read-JsonFile -Path $proposalPath
            Assert-True ($proposal.cross_check.cap -eq $cap) 'Missing dispute metadata.'
            $null = Invoke-Apply $context @('-Approve', $proposalPath)
        }
        Assert-True ($after.caps.math.score -eq 8) 'Undisputed small update did not apply.'
        $approved = Get-TestModel $context 'gemini-4-carbon'
        Assert-True ($approved.caps.code_rigor.score -eq 8) 'Explicit approval did not apply research score.'
        Assert-True ($approved.caps.backend.score -eq 9) 'Explicit approval did not apply suggested score.'
    }

    Run-Case 'same-batch-proposals-approve-sequentially' {
        $context = New-Context 'sequential'
        $research = New-Refresh $context
        $research.caps.code_rigor.score = 10
        $research.caps.math.score = 10
        $research.caps.prose.score = 8
        $result = Invoke-Apply $context @('-ResearchFile', (Save-Research $context $research))
        $first = Invoke-Apply $context @('-Approve', (Find-CapProposal $result 'code_rigor'))
        $second = Invoke-Apply $context @('-Approve', (Find-CapProposal $result 'math'))
        $third = Invoke-Apply $context @('-Approve', (Find-CapProposal $result 'prose'))
        Assert-True (-not $first.rebased) 'First proposal unexpectedly rebased.'
        Assert-True ($second.rebased -and $third.rebased) 'Later proposals required Force instead of auto-rebasing.'
        $model = Get-TestModel $context 'gemini-4-carbon'
        Assert-True ($model.caps.code_rigor.score -eq 10 -and $model.caps.math.score -eq 10 -and $model.caps.prose.score -eq 8) 'Sequential approval lost a change.'
        Assert-True $model.caps.prose.locked 'Ordinary approval permanently unlocked prose.'
    }

    Run-Case 'approve-all-preview-and-commit' {
        $context = New-Context 'approve-all'
        $research = New-Refresh $context
        $research.caps.code_rigor.score = 10
        $research.caps.math.score = 10
        $research.caps.prose.score = 8
        $result = Invoke-Apply $context @('-ResearchFile', (Save-Research $context $research))
        $revision = (Read-TestRegistry $context).registry_rev
        $preview = Invoke-Apply $context @('-ApproveAll', 'gemini-4-carbon', '-DryRun')
        Assert-True (@($preview.approvals).Count -eq 3) 'Batch preview omitted proposals.'
        Assert-True ((Read-TestRegistry $context).registry_rev -eq $revision) 'Batch preview changed revision.'
        foreach ($path in @($result.proposals)) {
            Assert-True (Test-Path -LiteralPath $path) 'Batch preview archived a pending proposal.'
        }
        $batch = Invoke-Apply $context @('-ApproveAll', 'best-knowledge')
        Assert-True (@($batch.approvals).Count -eq 3) 'Batch did not approve all matching proposals.'
        Assert-True (@($batch.rejected_proposals).Count -eq 0) 'Batch incorrectly rejected a sibling proposal.'
        Assert-True ($batch.registry_rev -eq $revision + 3) 'Batch revisions are not sequential.'
        $empty = Invoke-Apply $context @('-ApproveAll', 'gemini-4-carbon')
        Assert-True (@($empty.approvals).Count -eq 0) 'Batch replay reapplied archived proposals.'
    }

    Run-Case 'approve-all-keeps-conflicting-proposal-pending' {
        $context = New-Context 'approve-all-conflict'
        $research = New-Refresh $context
        $research.caps.code_rigor.score = 10
        $research.caps.math.score = 10
        $research.caps.prose.score = 8
        $result = Invoke-Apply $context @('-ResearchFile', (Save-Research $context $research))
        $conflicting = Find-CapProposal $result 'math'
        Mutate-Registry $context {
            param($registry)
            $model = @($registry.models | Where-Object { $_.id -eq 'gemini-4-carbon' })[0]
            $model.caps.math.score = 8
        }
        $batch = Invoke-Apply $context @('-ApproveAll', 'gemini-4-carbon') 2
        Assert-True (@($batch.approvals).Count -eq 2) 'Conflict blocked unrelated proposals.'
        Assert-True (@($batch.rejected_proposals).Count -eq 1) 'Conflict was not reported.'
        Assert-True (Test-Path -LiteralPath $conflicting) 'Conflicting proposal was archived.'
        $model = Get-TestModel $context 'gemini-4-carbon'
        Assert-True ($model.caps.math.score -eq 8) 'Conflict overwrote the current score.'
        Assert-True ($model.caps.code_rigor.score -eq 10 -and $model.caps.prose.score -eq 8) 'Unrelated batch approval failed.'
    }

    Run-Case 'locked-one-time-approval-preserves-future-lock' {
        $context = New-Context 'one-time-lock'
        $research = New-Refresh $context
        $research.caps.prose.score = 8
        $result = Invoke-Apply $context @('-ResearchFile', (Save-Research $context $research))
        $null = Invoke-Apply $context @('-Approve', (Find-CapProposal $result 'prose'))
        $model = Get-TestModel $context 'gemini-4-carbon'
        Assert-True ($model.caps.prose.score -eq 8 -and $model.caps.prose.approved_score -eq 8) 'One-time approval did not anchor the score.'
        Assert-True $model.caps.prose.locked 'One-time approval cleared locked.'
        $research = New-Refresh $context
        $research.caps.prose.score = 9
        $result = Invoke-Apply $context @('-ResearchFile', (Save-Research $context $research))
        $model = Get-TestModel $context 'gemini-4-carbon'
        Assert-True ($model.caps.prose.score -eq 8 -and $model.caps.prose.locked) 'Later refresh bypassed the retained lock.'
        $null = Find-CapProposal $result 'prose'
    }

    Run-Case 'prompt-foreign-lease-blocks-and-manual-release-works' {
        $context = New-Context 'foreign-lease'
        $foreignOwner = 'other-host-12345'
        $null = Invoke-WithLock -Paths $context.Paths -Name state -ScriptBlock {
            $testState = Read-State -Paths $context.Paths
            Set-OrchestraProperty $testState.research_leases 'fake-model-9' ([pscustomobject]@{
                owner = $foreignOwner
                until = (Get-OrchestraNow).AddMinutes(60).ToString('o')
            })
            $null = Save-State -Paths $context.Paths -State $testState
        }
        $promptArgs = @(
            '-ModelId', 'fake-model-9',
            '-RegistryPath', $context.Paths.Registry,
            '-StateDir', $context.Paths.StateDir
        )
        $before = [IO.File]::ReadAllText($context.Paths.State)
        $outputFile = Join-Path $context.Directory 'blocked-prompt.md'
        $blocked = Invoke-Child 'scripts\research-prompt.ps1' ($promptArgs + @('-OutFile', $outputFile)) 4
        Assert-True ($blocked.lease_held_by -eq $foreignOwner) 'Foreign lease owner was not reported.'
        Assert-True (-not (Test-Path -LiteralPath $outputFile)) 'Blocked prompt wrote output.'
        Assert-True ([IO.File]::ReadAllText($context.Paths.State) -ceq $before) 'Blocked prompt rewrote state.'

        $released = Invoke-Child 'scripts\research-prompt.ps1' ($promptArgs + @('-ReleaseLease'))
        Assert-True ($released.released -and $released.released_owner -eq $foreignOwner) 'Manual release could not clear the earlier process lease.'

        $generated = Invoke-Child 'scripts\research-prompt.ps1' $promptArgs
        Assert-True ($generated.lease.owner -match '-[0-9]+$') 'Prompt lease owner is not host-pid.'
        $until = [datetimeoffset]::Parse($generated.lease.until).UtcDateTime
        $minutes = ($until - (Get-OrchestraNow)).TotalMinutes
        Assert-True ($minutes -ge 58 -and $minutes -le 61) 'Prompt lease is not 60 minutes.'

        $blocked = Invoke-Child 'scripts\research-prompt.ps1' $promptArgs 4
        Assert-True ($blocked.lease_held_by -eq $generated.lease.owner) 'Second prompt did not respect the first process lease.'

        $null = Invoke-Apply $context @('-ResearchFile', (Save-Research $context (Read-Sample)))
        $testState = Read-State -Paths $context.Paths
        Assert-True ($null -eq $testState.research_leases.PSObject.Properties['fake-model-9']) 'Merge did not consume the prompt lease from another PID.'
    }

    Run-Case 'expired-prompt-lease-is-replaced' {
        $context = New-Context 'expired-lease'
        $null = Invoke-WithLock -Paths $context.Paths -Name state -ScriptBlock {
            $testState = Read-State -Paths $context.Paths
            Set-OrchestraProperty $testState.research_leases 'fake-model-9' ([pscustomobject]@{
                owner = 'expired-host-7'
                until = (Get-OrchestraNow).AddMinutes(-1).ToString('o')
            })
            $null = Save-State -Paths $context.Paths -State $testState
        }
        $argsForPrompt = @(
            '-ModelId', 'fake-model-9',
            '-RegistryPath', $context.Paths.Registry,
            '-StateDir', $context.Paths.StateDir
        )
        $generated = Invoke-Child 'scripts\research-prompt.ps1' $argsForPrompt
        Assert-True ($generated.lease.owner -ne 'expired-host-7') 'Expired lease was not replaced.'
        $null = Invoke-Child 'scripts\research-prompt.ps1' ($argsForPrompt + @('-ReleaseLease'))
        $again = Invoke-Child 'scripts\research-prompt.ps1' ($argsForPrompt + @('-ReleaseLease'))
        Assert-True (-not $again.released) 'Manual release is not idempotent.'
    }

    Run-Case 'agy-efforts-use-scanned-raw-slugs' {
        $context = New-Context 'agy-efforts'
        $null = Invoke-WithLock -Paths $context.Paths -Name state -ScriptBlock {
            $testState = Read-State -Paths $context.Paths
            Set-OrchestraProperty $testState.sources.agy 'raw_slugs' @(
                'fake-model-9-medium', 'fake-model-9-max', 'fake-model-9-medium', 'unrelated-high'
            )
            $null = Save-State -Paths $context.Paths -State $testState
        }
        $null = Invoke-Apply $context @('-ResearchFile', (Save-Research $context (Read-Sample)))
        $model = Get-TestModel $context 'fake-model-9'
        Assert-True (($model.invoke.efforts -join ',') -eq 'medium,max') 'Efforts were not inferred from exact model slugs.'
        Assert-True ($model.invoke.default_effort -eq 'max') 'Default effort is not in the scanned effort list.'
    }

    Run-Case 'schema-validation-and-dry-run' {
        $context = New-Context 'validation'
        $research = Read-Sample
        $research.caps.math.score = 11
        $null = Invoke-Apply $context @('-ResearchFile', (Save-Research $context $research)) 2
        Assert-True ((Read-TestRegistry $context).registry_rev -eq $context.BaseRev) 'Invalid schema changed registry.'

        $researchPath = Save-Research $context (Read-Sample)
        $before = [IO.File]::ReadAllText($context.Paths.Registry)
        $result = Invoke-Apply $context @('-ResearchFile', $researchPath, '-DryRun')
        Assert-True $result.dry_run 'Dry-run marker missing.'
        Assert-True ([IO.File]::ReadAllText($context.Paths.Registry) -ceq $before) 'Dry run changed registry.'
        Assert-True (-not (Test-Path -LiteralPath $context.Paths.State)) 'Dry run wrote state.'
        Assert-True (-not (Test-Path -LiteralPath $context.Paths.History)) 'Dry run created history.'
        Assert-True (-not (Test-Path -LiteralPath $context.Paths.Proposals)) 'Dry run created proposals.'
        Assert-True (-not (Test-Path -LiteralPath $context.Paths.Locks)) 'Dry run created lock files.'
    }

    Run-Case 'research-prompt-section-and-placeholders' {
        $context = New-Context 'prompt'
        $outFile = Join-Path $context.Directory 'prompt.md'
        $result = Invoke-Child 'scripts\research-prompt.ps1' @(
            '-ModelId', 'fake-model-9',
            '-Mode', 'new',
            '-OutFile', $outFile,
            '-RegistryPath', $context.Paths.Registry,
            '-StateDir', $context.Paths.StateDir
        )
        Assert-True (Test-Path -LiteralPath $result.out_file) 'Prompt file missing.'
        $text = Get-Content -LiteralPath $outFile -Raw -Encoding UTF8
        Assert-True ($text -notmatch '\{\{[A-Z_]+\}\}') 'Unresolved template token.'
        Assert-True ($text -match 'fake-model-9') 'Model placeholder missing.'
        Assert-True ($text -match '(?m)^- prose: gemini-4-carbon \(10\)\s*$') 'Wrong prose incumbent format.'
        Assert-True ($text -notmatch '(?m)^---\s*$') 'Included the next protocol section.'
        Assert-True ($text -notmatch 'cross-check-') 'Included protocol orchestration instructions.'
        $bytes = [IO.File]::ReadAllBytes($outFile)
        Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'Prompt file has a BOM.'
    }

    Run-Case 'alias-rule-and-retirement-are-proposals' {
        $context = New-Context 'proposal-only'
        $research = Read-Sample
        $research.caps.prose.evidence = @([pscustomobject]@{
            url = 'https://example.org/model-orchestra/fixture'
            claim = 'Synthetic superiority claim for proposal testing only.'
            date = '2026-11-10'
        })
        $research.caps.prose.score = 10
        $research.caps.prose.vs_incumbent = 1
        $research.supersedes = 'gemini-4-carbon'
        $research.suggested_hard_rules = @([pscustomobject]@{
            id = 'synthetic-test-rule'
            when_tags_any = @('prose')
            primary_requires_tool = 'browser'
            locked = $false
        })
        $result = Invoke-Apply $context @('-ResearchFile', (Save-Research $context $research))
        $registry = Read-TestRegistry $context
        Assert-True ($registry.aliases.'best-prose' -eq 'gemini-4-carbon') 'Alias changed without approval.'
        Assert-True ((Get-TestModel $context 'gemini-4-carbon').status -eq 'active') 'Incumbent retired without approval.'
        Assert-True (@($registry.hard_rules | Where-Object { $_.id -eq 'synthetic-test-rule' }).Count -eq 0) 'Rule applied without approval.'
        Assert-True (@($result.proposals).Count -ge 3) 'Missing alias, retirement, or hard-rule proposal.'
        $listed = Invoke-Apply $context @('-ListProposals')
        Assert-True (@($listed.proposals).Count -eq @($result.proposals).Count) 'Proposal listing is incomplete.'
    }

    Run-Case 'missing-family-is-conservative' {
        $context = New-Context 'no-family'
        $research = Read-Sample
        $research.family = 'synthetic-unrelated-family'
        $null = Invoke-Apply $context @('-ResearchFile', (Save-Research $context $research))
        $model = Get-TestModel $context 'fake-model-9'
        Assert-True ($model.caps.prose.score -eq 5) 'No-family score must be capped at 5.'
        Assert-True ($model.caps.prose.confidence -eq 0.2) 'Wrong no-family confidence.'
        Assert-True ($model.caps.prose.source -eq 'inherited') 'Wrong no-family source.'
    }
}
catch {
    [void]$results.Add([pscustomobject]@{
        name = 'suite-infrastructure'
        passed = $false
        error = $_.Exception.Message
    })
}
finally {
    if (-not $KeepTemp) {
        try {
            $resolved = [IO.Path]::GetFullPath($temporaryRoot)
            $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
            Assert-True ([IO.Path]::GetDirectoryName($resolved).TrimEnd('\', '/') -eq $expectedParent) 'Unsafe cleanup parent.'
            Assert-True ([IO.Path]::GetFileName($resolved) -match '^orchestra-apply-[a-f0-9]{32}$') 'Unsafe cleanup name.'
            if (Test-Path -LiteralPath $resolved) {
                Remove-Item -LiteralPath $resolved -Recurse -Force
            }
        }
        catch {
            [void]$results.Add([pscustomobject]@{
                name = 'cleanup'
                passed = $false
                error = $_.Exception.Message
            })
        }
    }
}

$failed = @($results.ToArray() | Where-Object { -not $_.passed }).Count
$summary = [ordered]@{
    suite = 'apply'
    passed = $results.Count - $failed
    failed = $failed
    tests = $results.ToArray()
}
if ($KeepTemp) { $summary['temp_dir'] = $temporaryRoot }
Write-OrchestraResult -Object $summary
if ($failed -gt 0) { exit 1 }
exit 0
