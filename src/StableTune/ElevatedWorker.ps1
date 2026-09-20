[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RequestPath
)

$ErrorActionPreference = 'Stop'
$request = $null
$resultPath = $null

try {
    $request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json -AsHashtable
    $resultPath = [string]$request.resultPath
    $modulePath = Join-Path $PSScriptRoot 'StableTune.psd1'
    Import-Module $modulePath -Force

    $result = switch ([string]$request.action) {
        'RestorePoint' {
            Invoke-FelixRestorePointRequestLocal
        }
        'Apply' {
            Invoke-FelixApplyLocal -RuleId ([string]$request.payload.ruleId) -Options $request.payload.options -AcceptRisk:([bool]$request.payload.acceptRisk)
        }
        'Restore' {
            Invoke-FelixRestoreLocal -HistoryId ([string]$request.payload.historyId) -Force:([bool]$request.payload.force)
        }
        default {
            throw "Unsupported worker action '$($request.action)'."
        }
    }

    [ordered]@{
        success = $true
        result = $result
        error = $null
    } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultPath -Encoding utf8
}
catch {
    if ($resultPath) {
        [ordered]@{
            success = $false
            result = $null
            error = $_.Exception.Message
        } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $resultPath -Encoding utf8
    }
    exit 1
}

