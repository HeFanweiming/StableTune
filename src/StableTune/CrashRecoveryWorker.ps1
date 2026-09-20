[CmdletBinding()]
param(
    [string]$StatePath
)

$ErrorActionPreference = 'Stop'
if (-not [string]::IsNullOrWhiteSpace($StatePath)) {
    $env:FELIX_OPTIMIZER_HOME = $StatePath
}
$modulePath = Join-Path $PSScriptRoot 'StableTune.psd1'
Import-Module $modulePath -Force

try {
    Invoke-FelixCrashRecovery | Out-Null
    exit 0
}
catch {
    $stateRoot = Get-FelixStatePath
    if (-not (Test-Path -LiteralPath $stateRoot)) {
        New-Item -ItemType Directory -Path $stateRoot -Force | Out-Null
    }
    [ordered]@{
        timestamp = (Get-Date).ToString('o')
        success = $false
        error = $_.Exception.Message
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stateRoot 'crash-recovery-error.json') -Encoding utf8
    exit 1
}
