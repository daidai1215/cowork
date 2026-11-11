<#
.SYNOPSIS
Builds a research prompt and acquires a 60-minute research lease.
.DESCRIPTION
Reads the registry and updates research leases under the state lock.
ReleaseLease explicitly clears the named lease, including one from an earlier PID.
Writes one JSON object to stdout. All script source is ASCII.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ModelId,

    [ValidateSet('new', 'refresh')]
    [string]$Mode = 'new',

    [string]$OutFile,

    [switch]$ReleaseLease,

    [string]$RegistryPath,
    [string]$StateDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false

. (Join-Path $PSScriptRoot 'lib\common.ps1')

$leaseAcquired = $false
$leaseOwner = '{0}-{1}' -f [Environment]::MachineName, $PID
$paths = $null
$leaseId = $null

try {
    if ($ModelId -notmatch '^[a-z0-9][a-z0-9.-]*$') {
        throw 'ORCHESTRA_ARGS: Invalid model slug.'
    }

    $paths = Get-OrchestraPaths -RegistryPath $RegistryPath -StateDir $StateDir
    $leaseId = ConvertTo-BaseSlug -Slug $ModelId
    $leaseResult = Invoke-WithLock -Paths $paths -Name state -ScriptBlock {
        $state = Read-State -Paths $paths
        $leases = Get-OrchestraProperty $state 'research_leases'
        $currentLease = Get-OrchestraProperty $leases $leaseId
        $previousOwner = Get-OrchestraProperty $currentLease 'owner'

        if ($ReleaseLease) {
            $existed = $null -ne $currentLease
            if ($existed) {
                if ($leases -is [Collections.IDictionary]) {
                    [void]$leases.Remove($leaseId)
                }
                else {
                    [void]$leases.PSObject.Properties.Remove($leaseId)
                }
                $null = Save-State -Paths $paths -State $state
            }
            return @{ released = $existed; released_owner = $previousOwner }
        }

        $until = [datetimeoffset]::MinValue
        if (
            $null -ne $currentLease -and
            [datetimeoffset]::TryParse([string](Get-OrchestraProperty $currentLease 'until'), [ref]$until) -and
            $until.UtcDateTime -gt (Get-OrchestraNow) -and
            $previousOwner -ne $leaseOwner
        ) {
            return @{
                lease_held_by = $previousOwner
                until = $until.ToString('o')
            }
        }

        $newLease = [pscustomobject]@{
            owner = $leaseOwner
            until = (Get-OrchestraNow).AddMinutes(60).ToString('o')
        }
        Set-OrchestraProperty $leases $leaseId $newLease
        $null = Save-State -Paths $paths -State $state
        return @{ lease = $newLease }
    }

    if ($ReleaseLease) {
        Write-OrchestraResult -Object @{
            model_id = $leaseId
            released = $leaseResult.released
            released_owner = $leaseResult.released_owner
        }
        exit 0
    }

    if ($leaseResult.ContainsKey('lease_held_by')) {
        Write-OrchestraResult -Object @{
            model_id = $leaseId
            lease_held_by = $leaseResult.lease_held_by
            until = $leaseResult.until
        }
        exit 4
    }
    $leaseAcquired = $true

    $registry = Read-Registry -Paths $paths
    $protocolPath = Join-Path $paths.Root 'references\research-protocol.md'

    if (-not (Test-Path -LiteralPath $protocolPath -PathType Leaf)) {
        throw 'ORCHESTRA_ARGS: Research protocol not found.'
    }

    $protocol = Get-Content -LiteralPath $protocolPath -Raw -Encoding UTF8
    $section = [regex]::Match(
        $protocol,
        '(?ms)^##[ \t]+[^\r\n]+\r?\n.*?(?=^---[ \t]*\r?$|\z)'
    )
    if (-not $section.Success) {
        throw 'ORCHESTRA_ARGS: Protocol has no level-two research section.'
    }

    $preferred = @{
        code_rigor = 'best-rigor'
        backend = 'best-rigor'
        math = 'best-math'
        image_gen = 'best-image'
        frontend_aesthetic = 'best-aesthetic'
        prose = 'best-prose'
        world_knowledge = 'best-knowledge'
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($dimension in @($registry.cap_dimensions)) {
        $incumbent = $null
        if ($preferred.ContainsKey($dimension)) {
            $resolved = Resolve-ModelId -Registry $registry -Name $preferred[$dimension]
            $incumbent = @(
                $registry.models |
                    Where-Object {
                        $_.id -eq $resolved -and $_.status -eq 'active'
                    }
            ) | Select-Object -First 1
        }

        if ($null -eq $incumbent) {
            $incumbent = @(
                $registry.models |
                    Where-Object {
                        $_.status -eq 'active' -and
                        $null -ne $_.caps.PSObject.Properties[$dimension]
                    } |
                    Sort-Object -Property @{
                        Expression = {
                            [double]$_.caps.PSObject.Properties[$dimension].Value.score
                        }
                        Descending = $true
                    }, id
            ) | Select-Object -First 1
        }

        if ($null -eq $incumbent) {
            [void]$lines.Add(('- {0}: none (0)' -f $dimension))
        }
        else {
            $score = $incumbent.caps.PSObject.Properties[$dimension].Value.score
            $formatted = ([double]$score).ToString(
                '0.##',
                [Globalization.CultureInfo]::InvariantCulture
            )
            [void]$lines.Add(('- {0}: {1} ({2})' -f $dimension, $incumbent.id, $formatted))
        }
    }

    $prompt = $section.Value.Trim()
    $prompt = $prompt.Replace('{{MODEL_ID}}', $ModelId)
    $prompt = $prompt.Replace('{{MODE}}', $Mode)
    $prompt = $prompt.Replace('{{INCUMBENTS}}', ($lines.ToArray() -join "`n"))
    $prompt = $prompt.Replace(
        '{{CAP_DIMENSIONS}}',
        (@($registry.cap_dimensions) -join ', ')
    )
    $prompt = $prompt.Replace(
        '{{TODAY}}',
        (Get-OrchestraNow).ToString('yyyy-MM-dd')
    )
    if ($prompt -match '\{\{[A-Z_]+\}\}') {
        throw 'ORCHESTRA_ARGS: Unresolved protocol placeholder.'
    }

    $destination = $null
    if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
        $destination = [IO.Path]::GetFullPath($OutFile)
        foreach ($protected in @($paths.Registry, $paths.State, $paths.Usage)) {
            if ($destination -eq [IO.Path]::GetFullPath($protected)) {
                throw 'ORCHESTRA_ARGS: OutFile points to an orchestra data file.'
            }
        }

        $directory = [IO.Path]::GetDirectoryName($destination)
        [void][IO.Directory]::CreateDirectory($directory)
        $temporary = $destination + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        try {
            [IO.File]::WriteAllText(
                $temporary,
                $prompt + "`n",
                (New-Object Text.UTF8Encoding $false)
            )
            Move-Item -LiteralPath $temporary -Destination $destination -Force
        }
        finally {
            if (Test-Path -LiteralPath $temporary) {
                Remove-Item -LiteralPath $temporary -Force
            }
        }
    }

    $result = [ordered]@{
        model_id = $ModelId
        mode = $Mode
        out_file = $destination
        lease = $leaseResult.lease
    }
    if ($null -eq $destination) {
        $result['prompt'] = $prompt
    }
    Write-OrchestraResult -Object $result
    exit 0
}
catch {
    $message = $_.Exception.Message
    if ($leaseAcquired -and $null -ne $paths) {
        try {
            $null = Invoke-WithLock -Paths $paths -Name state -ScriptBlock {
                $state = Read-State -Paths $paths
                $leases = Get-OrchestraProperty $state 'research_leases'
                $lease = Get-OrchestraProperty $leases $leaseId
                if ((Get-OrchestraProperty $lease 'owner') -eq $leaseOwner) {
                    if ($leases -is [Collections.IDictionary]) {
                        [void]$leases.Remove($leaseId)
                    }
                    else {
                        [void]$leases.PSObject.Properties.Remove($leaseId)
                    }
                    $null = Save-State -Paths $paths -State $state
                }
            }
        }
        catch {
            [Console]::Error.WriteLine('Lease cleanup failed: ' + $_.Exception.Message)
        }
    }
    [Console]::Error.WriteLine($message)
    Write-OrchestraResult -Object @{
        error = $message
        model_id = $ModelId
        mode = $Mode
    }
    if ($message -match 'ORCHESTRA_LOCK_TIMEOUT') { exit 5 }
    if ($message -match '^ORCHESTRA_ARGS:') { exit 2 }
    exit 3
}
