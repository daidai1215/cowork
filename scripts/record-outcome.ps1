<#
.SYNOPSIS
Append an outcome and promote or reject a candidate under ordered locks.
.DESCRIPTION
The last outcome per invocation_id is authoritative. Identical repeated
outcomes do not append another event. Capability metadata is never changed.
Registry history and changelog are written only for a status transition.
#>
[CmdletBinding()]
param(
    [string]$SessionId,
    [string]$InvocationId,
    [switch]$Last,
    [string]$Outcome,
    [string]$Note = '',
    [string]$RegistryPath,
    [string]$StateDir
)

. (Join-Path $PSScriptRoot 'lib\common.ps1')

try {
    $selectors = 0
    if (-not [string]::IsNullOrWhiteSpace($SessionId)) { $selectors++ }
    if (-not [string]::IsNullOrWhiteSpace($InvocationId)) { $selectors++ }
    if ($Last) { $selectors++ }
    if ($selectors -ne 1 -or $Outcome -notin @('ok', 'redo', 'fail')) {
        throw (
            'ORCHESTRA_ARGS: Specify one of -SessionId, -InvocationId, -Last ' +
            'and an outcome of ok, redo, or fail.'
        )
    }

    $paths = Get-OrchestraPaths -RegistryPath $RegistryPath -StateDir $StateDir
    $result = Invoke-WithLock -Paths $paths -Name registry -ScriptBlock {
        $registry = Read-Registry -Paths $paths

        Invoke-WithLock -Paths $paths -Name state -ScriptBlock {
            $state = Read-State -Paths $paths

            Invoke-WithLock -Paths $paths -Name usage -ScriptBlock {
                # Read-UsageEvents streams individual records.
                $events = @(Read-UsageEvents -Paths $paths)
                $invocations = @($events | Where-Object {
                    (Get-OrchestraProperty $_ 'type') -eq 'invocation'
                })

                if ($Last) {
                    $matching = $invocations
                }
                elseif (-not [string]::IsNullOrWhiteSpace($InvocationId)) {
                    $matching = @($invocations | Where-Object {
                        (Get-OrchestraProperty $_ 'invocation_id') -eq $InvocationId
                    })
                }
                else {
                    $matching = @($invocations | Where-Object {
                        (Get-OrchestraProperty $_ 'session_id') -eq $SessionId
                    })
                }

                if ($matching.Count -eq 0) {
                    throw 'ORCHESTRA_ARGS: No matching invocation.'
                }
                $target = $matching[$matching.Count - 1]
                $targetId = [string](
                    Get-OrchestraProperty $target 'invocation_id'
                )
                $targetModelId = [string](
                    Get-OrchestraProperty $target 'model'
                )
                $models = @($registry.models | Where-Object {
                    $_.id -eq $targetModelId
                })
                if ($models.Count -ne 1) {
                    throw 'ORCHESTRA_EXTERNAL: Invocation model is absent or duplicated.'
                }
                $modelObject = $models[0]

                $previous = @($events | Where-Object {
                    (Get-OrchestraProperty $_ 'type') -eq 'outcome' -and
                    (Get-OrchestraProperty $_ 'invocation_id') -eq $targetId
                })
                $alreadyRecorded = $false
                if ($previous.Count -gt 0) {
                    $latest = $previous[$previous.Count - 1]
                    $alreadyRecorded = (
                        (Get-OrchestraProperty $latest 'outcome') -eq $Outcome -and
                        [string](Get-OrchestraProperty $latest 'note' '') -ceq $Note
                    )
                }

                if (-not $alreadyRecorded) {
                    Add-UsageEvent -Paths $paths -Event @{
                        type = 'outcome'
                        invocation_id = $targetId
                        ts = (Get-OrchestraNow).ToString('o')
                        outcome = $Outcome
                        note = $Note
                    }
                    $events = @(Read-UsageEvents -Paths $paths)
                }

                $policy = Get-OrchestraProperty $registry 'policy'
                $stats = Get-OutcomeStats -Events $events `
                    -ModelId $targetModelId -WindowDays 30
                $oldStatus = [string](Get-OrchestraProperty $modelObject 'status')
                $action = 'recorded'
                $stateChanged = $false

                if ($oldStatus -eq 'candidate') {
                    $rejectAfter = [int](
                        Get-OrchestraProperty $policy 'reject_after_consecutive_fail' 2
                    )
                    if ($rejectAfter -lt 1) {
                        throw 'ORCHESTRA_EXTERNAL: Invalid rejection threshold.'
                    }

                    if ($stats.consecutive_fail -ge $rejectAfter) {
                        Set-OrchestraProperty $modelObject 'status' 'rejected'

                        $rejectedValues = Get-OrchestraProperty `
                            $state 'rejected_slugs' @()
                        $rejected = @($rejectedValues)
                        if ($targetModelId -notin $rejected) {
                            Set-OrchestraProperty $state 'rejected_slugs' @(
                                $rejected + $targetModelId
                            )
                            $stateChanged = $true
                        }
                        $action = 'rejected'
                    }
                    else {
                        $caps = Get-OrchestraProperty $modelObject 'caps'
                        # Get-OrchestraNames streams scalar names.
                        $capNames = @(Get-OrchestraNames -Object $caps)
                        $confidenceSum = [decimal]0
                        foreach ($capName in $capNames) {
                            $cap = Get-OrchestraProperty $caps $capName
                            $confidenceSum += [decimal](
                                Get-OrchestraProperty $cap 'confidence' 0
                            )
                        }
                        $averageConfidence = [decimal]0
                        if ($capNames.Count -gt 0) {
                            $averageConfidence = $confidenceSum / $capNames.Count
                        }

                        $requiredOk = [Math]::Max(3, [int](
                            Get-OrchestraProperty $policy 'promote_after_ok' 3
                        ))
                        $requiredTags = [Math]::Max(2, [int](
                            Get-OrchestraProperty $policy 'promote_min_distinct_tags' 2
                        ))
                        $maximumBad = [int](
                            Get-OrchestraProperty $policy 'promote_max_bad' 1
                        )
                        $requiredConfidence = [decimal](
                            Get-OrchestraProperty $policy 'promote_min_confidence' 0.6
                        )

                        if ($capNames.Count -gt 0 -and
                            $stats.ok_invocations -ge $requiredOk -and
                            @($stats.ok_tags).Count -ge $requiredTags -and
                            ($stats.redo + $stats.fail) -le $maximumBad -and
                            $averageConfidence -ge $requiredConfidence) {
                            Set-OrchestraProperty $modelObject 'status' 'active'
                            $action = 'promoted'
                        }
                    }
                }

                $newStatus = [string](Get-OrchestraProperty $modelObject 'status')
                $backup = $null
                if ($oldStatus -ne $newStatus) {
                    $reason = (
                        "Outcome $Outcome for $targetModelId; " +
                        "status $oldStatus -> $newStatus; invocation $targetId"
                    )
                    $backup = Save-Registry -Paths $paths `
                        -Registry $registry -Reason $reason
                }
                if ($stateChanged) {
                    Save-State -Paths $paths -State $state
                }

                return @{
                    invocation_id = $targetId
                    session_id = Get-OrchestraProperty $target 'session_id'
                    model = $targetModelId
                    outcome = $Outcome
                    appended = -not $alreadyRecorded
                    action = $action
                    status = $newStatus
                    stats = $stats
                    registry_rev = Get-OrchestraProperty $registry 'registry_rev'
                    backup = $backup
                    exit = 0
                }
            }
        }
    }

    Write-OrchestraResult -Object $result
    exit 0
}
catch {
    $code = Get-OrchestraExitCode -Message $_.Exception.Message
    [Console]::Error.WriteLine($_.Exception.Message)
    Write-OrchestraResult -Object @{
        exit = $code
        error = $_.Exception.Message
    }
    exit $code
}
