Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$target = [Environment]::GetEnvironmentVariable('ORCHESTRA_SHIM_SCRIPT')
$rawArgs = [Environment]::GetEnvironmentVariable('ORCHESTRA_SHIM_ARGV')
[Environment]::SetEnvironmentVariable('ORCHESTRA_SHIM_SCRIPT', $null)
[Environment]::SetEnvironmentVariable('ORCHESTRA_SHIM_ARGV', $null)
if ([string]::IsNullOrWhiteSpace($target) -or -not [IO.File]::Exists($target)) {
    throw 'ORCHESTRA_EXTERNAL: Missing PowerShell shim script.'
}
$shimArgs = [string[]]@()
if (-not [string]::IsNullOrEmpty($rawArgs) -and $rawArgs[0] -eq ':') {
    $parts = $rawArgs.Substring(1) -split ','
    $shimArgs = [string[]]@(foreach ($part in $parts) {
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part))
    })
}
$global:LASTEXITCODE = 0
& $target @shimArgs
if ($null -ne $global:LASTEXITCODE -and $global:LASTEXITCODE -ne 0) {
    exit $global:LASTEXITCODE
}
exit 0
