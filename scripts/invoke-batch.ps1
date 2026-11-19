<#
.SYNOPSIS
Bounded parallel batch runner for Cowork Lite (strict hard cap: <= 3 tasks).
.DESCRIPTION
Executes 1 to 3 independent one-shot invoke-model.ps1 tasks concurrently and returns one aggregated JSON object.
#>
[CmdletBinding()]
param(
    [string]$BatchFile = '',
    [string]$TasksJson = '',
    [int]$MaxParallel = 3,
    [int]$StaggerMs = 300,
    [switch]$DryRun,
    [string]$RegistryPath = ''
)

. (Join-Path $PSScriptRoot 'lib\common.ps1')

$watch = [Diagnostics.Stopwatch]::StartNew()
$active = New-Object 'System.Collections.Generic.List[object]'

try {
    $hasFile = -not [string]::IsNullOrWhiteSpace($BatchFile)
    $hasJson = -not [string]::IsNullOrWhiteSpace($TasksJson)
    if ($hasFile -eq $hasJson) {
        throw 'ORCHESTRA_ARGS: Specify exactly one of -BatchFile or -TasksJson.'
    }
    if ($MaxParallel -lt 1 -or $MaxParallel -gt 3) {
        throw 'ORCHESTRA_ARGS: -MaxParallel must be between 1 and 3.'
    }

    $rawDoc = if ($hasFile) {
        if (-not [IO.File]::Exists($BatchFile)) { throw "ORCHESTRA_ARGS: BatchFile not found: $BatchFile" }
        Read-JsonFile -Path $BatchFile
    }
    else {
        $TasksJson | ConvertFrom-Json
    }

    $tasks = if ($rawDoc -is [array]) { @($rawDoc) }
        elseif ($null -ne (Get-OrchestraProperty $rawDoc 'tasks')) { @(Get-OrchestraArray $rawDoc 'tasks') }
        else { @($rawDoc) }

    if ($tasks.Count -lt 1) { throw 'ORCHESTRA_ARGS: Batch must contain at least 1 task.' }
    if ($tasks.Count -gt 3) {
        throw "ORCHESTRA_ARGS: Batch size is hard-capped at 3 concurrent tasks (got $($tasks.Count))."
    }

    $invokeScript = Join-Path $PSScriptRoot 'invoke-model.ps1'
    $psExe = Join-Path $PSHOME 'powershell.exe'
    if (-not [IO.File]::Exists($psExe)) { $psExe = 'powershell.exe' }

    $results = New-Object 'object[]' $tasks.Count
    $nextIdx = 0

    while ($nextIdx -lt $tasks.Count -or $active.Count -gt 0) {
        while ($active.Count -lt $MaxParallel -and $nextIdx -lt $tasks.Count) {
            if (-not $DryRun -and $nextIdx -gt 0 -and $StaggerMs -gt 0) {
                Start-Sleep -Milliseconds $StaggerMs
            }
            $task = $tasks[$nextIdx]
            $taskIdx = $nextIdx
            $nextIdx++

            $taskId = [string](Get-OrchestraProperty $task 'id' ("task-" + ($taskIdx + 1)))
            $childArgs = New-Object 'System.Collections.Generic.List[string]'
            foreach ($baseArg in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $invokeScript)) {
                [void]$childArgs.Add($baseArg)
            }
            foreach ($map in @(
                @{ key = 'model'; flag = '-Model' },
                @{ key = 'preset'; flag = '-Preset' },
                @{ key = 'prompt'; flag = '-Prompt' },
                @{ key = 'prompt_file'; flag = '-PromptFile' },
                @{ key = 'access'; flag = '-Access' },
                @{ key = 'work_dir'; flag = '-WorkDir' },
                @{ key = 'effort'; flag = '-Effort' },
                @{ key = 'service_tier'; flag = '-ServiceTier' },
                @{ key = 'out_file'; flag = '-OutFile' },
                @{ key = 'json_schema'; flag = '-JsonSchema' },
                @{ key = 'agy_settings'; flag = '-AgySettings' }
            )) {
                $val = Get-OrchestraProperty $task $map.key $null
                if ($null -ne $val -and -not [string]::IsNullOrWhiteSpace([string]$val)) {
                    [void]$childArgs.Add($map.flag)
                    [void]$childArgs.Add([string]$val)
                }
            }
            $ctxVal = Get-OrchestraProperty $task 'context_files' $null
            if ($null -ne $ctxVal) {
                $ctxJoined = if ($ctxVal -is [array]) { (@($ctxVal) | ForEach-Object { [string]$_ }) -join ',' } else { [string]$ctxVal }
                if (-not [string]::IsNullOrWhiteSpace($ctxJoined)) {
                    [void]$childArgs.Add('-ContextFiles'); [void]$childArgs.Add($ctxJoined)
                }
            }
            $tagsVal = Get-OrchestraProperty $task 'tags' $null
            if ($null -ne $tagsVal) {
                $tagsJoined = if ($tagsVal -is [array]) { (@($tagsVal) | ForEach-Object { [string]$_ }) -join ',' } else { [string]$tagsVal }
                if (-not [string]::IsNullOrWhiteSpace($tagsJoined)) {
                    [void]$childArgs.Add('-Tags'); [void]$childArgs.Add($tagsJoined)
                }
            }
            $timeoutVal = Get-OrchestraProperty $task 'timeout_sec' $null
            $taskTimeoutSec = if ($null -ne $timeoutVal -and [int]$timeoutVal -gt 0) { [int]$timeoutVal } else { 600 }
            [void]$childArgs.Add('-TimeoutSec'); [void]$childArgs.Add([string]$taskTimeoutSec)

            foreach ($sw in @(
                @{ key = 'no_fast'; flag = '-NoFast' },
                @{ key = 'allow_codex_shell'; flag = '-AllowCodexShell' },
                @{ key = 'full_codex_config'; flag = '-FullCodexConfig' },
                @{ key = 'keep_session'; flag = '-KeepSession' }
            )) {
                if ([bool](Get-OrchestraProperty $task $sw.key $false)) { [void]$childArgs.Add($sw.flag) }
            }
            if (-not [string]::IsNullOrWhiteSpace($RegistryPath)) {
                [void]$childArgs.Add('-RegistryPath'); [void]$childArgs.Add($RegistryPath)
            }
            if ($DryRun) { [void]$childArgs.Add('-DryRun') }

            $quoted = @(foreach ($a in $childArgs) { ConvertTo-OrchestraArgument -Value $a })
            $psi = New-Object Diagnostics.ProcessStartInfo
            $psi.FileName = $psExe
            $psi.Arguments = ($quoted -join ' ')
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = $script:OrchestraUtf8
            $psi.StandardErrorEncoding = $script:OrchestraUtf8
            $psi.WorkingDirectory = (Get-Location).Path

            $proc = New-Object Diagnostics.Process
            $proc.StartInfo = $psi
            $null = $proc.Start()
            try { $proc.StandardInput.Close() } catch {}
            [void]$active.Add(@{
                index = $taskIdx; id = $taskId; process = $proc
                watch = [Diagnostics.Stopwatch]::StartNew()
                timeout_sec = ($taskTimeoutSec + 30)
                out_task = $proc.StandardOutput.ReadLineAsync()
                err_task = $proc.StandardError.ReadLineAsync()
                out_done = $false; err_done = $false
                stdout = (New-Object 'System.Collections.Generic.List[string]')
                stderr = (New-Object 'System.Collections.Generic.List[string]')
            })
        }

        $progress = $false
        for ($i = $active.Count - 1; $i -ge 0; $i--) {
            $job = $active[$i]
            $proc = $job.process
            if (-not $proc.HasExited -and $job.watch.Elapsed.TotalSeconds -ge $job.timeout_sec) {
                Stop-OrchestraProcessTree -Process $proc
            }
            for ($b = 0; $b -lt 128 -and -not $job.out_done -and $job.out_task.IsCompleted; $b++) {
                $line = $job.out_task.GetAwaiter().GetResult(); $progress = $true
                if ($null -eq $line) { $job.out_done = $true; break }
                [void]$job.stdout.Add($line)
                $job.out_task = $proc.StandardOutput.ReadLineAsync()
            }
            for ($b = 0; $b -lt 128 -and -not $job.err_done -and $job.err_task.IsCompleted; $b++) {
                $line = $job.err_task.GetAwaiter().GetResult(); $progress = $true
                if ($null -eq $line) { $job.err_done = $true; break }
                [void]$job.stderr.Add($line)
                $job.err_task = $proc.StandardError.ReadLineAsync()
            }
            if ($proc.HasExited -and $job.out_done -and $job.err_done) {
                $exitC = [int]$proc.ExitCode
                $job.watch.Stop()
                try { $proc.Dispose() } catch {}
                $parsed = $null
                $nonEmpty = @($job.stdout | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
                if ($nonEmpty.Count -gt 0) {
                    try { $parsed = ([string]$nonEmpty[-1] | ConvertFrom-Json) } catch { $parsed = $null }
                }
                if ($null -ne $parsed) {
                    $parsed | Add-Member -MemberType NoteProperty -Name 'id' -Value $job.id -Force
                    $results[$job.index] = $parsed
                }
                else {
                    $results[$job.index] = [ordered]@{
                        id = $job.id; exit = $(if ($exitC -ne 0) { $exitC } else { 3 })
                        error = (($job.stderr -join "`n").Trim())
                    }
                }
                $active.RemoveAt($i)
                $progress = $true
            }
        }
        if (-not $progress -and $active.Count -gt 0) {
            $waits = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task]'
            foreach ($job in $active) {
                if (-not $job.out_done) { [void]$waits.Add([System.Threading.Tasks.Task]$job.out_task) }
                if (-not $job.err_done) { [void]$waits.Add([System.Threading.Tasks.Task]$job.err_task) }
            }
            if ($waits.Count -gt 0) {
                try { $null = [System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]$waits.ToArray(), 25) } catch {}
            }
            else { Start-Sleep -Milliseconds 10 }
        }
    }

    $succeeded = 0; $failed = 0
    foreach ($r in $results) {
        if ($null -ne $r -and [int](Get-OrchestraProperty $r 'exit' 3) -eq 0) { $succeeded++ } else { $failed++ }
    }
    $watch.Stop()
    Write-OrchestraResult -Object ([ordered]@{
        total = $tasks.Count
        succeeded = $succeeded
        failed = $failed
        duration_sec = [Math]::Round($watch.Elapsed.TotalSeconds, 3)
        dry_run = [bool]$DryRun
        results = $results
    })
    if ($failed -gt 0) { exit 1 }
    exit 0
}
catch {
    $watch.Stop()
    $msg = $_.Exception.Message
    $code = Get-OrchestraExitCode -Message $msg
    [Console]::Error.WriteLine($msg)
    Write-OrchestraResult -Object ([ordered]@{
        total = 0; succeeded = 0; failed = 1
        duration_sec = [Math]::Round($watch.Elapsed.TotalSeconds, 3)
        error = $msg; exit = $code
    })
    exit $code
}
finally {
    foreach ($job in $active) {
        try {
            if ($null -ne $job.process -and -not $job.process.HasExited) {
                Stop-OrchestraProcessTree -Process $job.process
            }
        }
        catch {}
        try { if ($null -ne $job.process) { $job.process.Dispose() } } catch {}
    }
}
