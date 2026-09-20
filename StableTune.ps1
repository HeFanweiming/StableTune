[CmdletBinding(DefaultParameterSetName = 'Ui')]
param(
    [Parameter(ParameterSetName = 'Ui')]
    [switch]$Ui,

    [Parameter(Mandatory, ParameterSetName = 'Command')]
    [ValidateSet('List', 'Audit', 'ChangeAudit', 'Hardware', 'Applicability', 'RollbackCheck', 'DualRollbackCheck', 'Logs', 'DryRun', 'Apply', 'BatchApply', 'Restore', 'RestoreAll', 'Recover')]
    [string]$Command,

    [Parameter(ParameterSetName = 'Command')]
    [string]$RuleId,

    [Parameter(ParameterSetName = 'Command')]
    [string[]]$RuleIds,

    [Parameter(ParameterSetName = 'Command')]
    [string]$HistoryId,

    [Parameter(ParameterSetName = 'Command')]
    [string]$OptionsJson,

    [Parameter(ParameterSetName = 'Command')]
    [switch]$AcceptRisk,

    [Parameter(ParameterSetName = 'Command')]
    [switch]$Force,

    [Parameter(ParameterSetName = 'Command')]
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
$moduleCandidates = @(
    (Join-Path $PSScriptRoot 'src\StableTune\StableTune.psd1')
)
$modulePath = $moduleCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $modulePath) {
    throw "稳优 StableTune module was not found. Checked:`n$($moduleCandidates -join [Environment]::NewLine)"
}
Import-Module $modulePath -Force

function ConvertFrom-OptionsJson {
    param([string]$Json)

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return @{}
    }

    $value = ConvertFrom-Json -InputObject $Json -AsHashtable
    if ($value -isnot [hashtable]) {
        throw 'OptionsJson must contain a JSON object.'
    }

    return $value
}

function Write-CliResult {
    param(
        [Parameter(Mandatory)]
        [object]$Value,

        [switch]$Json
    )

    if ($Json) {
        $Value | ConvertTo-Json -Depth 12
        return
    }

    if ($null -eq $Value) {
        return
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = foreach ($item in $Value) {
            if ($item -is [System.Collections.IDictionary]) {
                [pscustomobject]$item
            }
            else {
                $item
            }
        }
        $items | Format-Table -AutoSize
        return
    }

    if ($Value -is [System.Collections.IDictionary]) {
        [pscustomobject]$Value | Format-List
        return
    }

    $Value | Format-List
}

try {
    if ($PSCmdlet.ParameterSetName -eq 'Ui') {
        Start-StableTuneUi -EntryScriptPath $PSCommandPath
        return
    }

    $options = ConvertFrom-OptionsJson -Json $OptionsJson
    $result = switch ($Command) {
        'List' {
            Get-FelixRule
        }
        'Audit' {
            Invoke-FelixAudit
        }
        'ChangeAudit' {
            Get-FelixSystemChangeReport
        }
        'Hardware' {
            Get-FelixHardwareInventory
        }
        'Applicability' {
            if ($RuleId) {
                Get-FelixRuleApplicability -Rule (Get-FelixRuleRequired -RuleId $RuleId)
            }
            else {
                Get-FelixRule | ForEach-Object { Get-FelixRuleApplicability -Rule $_ }
            }
        }
        'RollbackCheck' {
            Test-FelixRollbackCapability
        }
        'DualRollbackCheck' {
            Test-FelixDualRollbackCapability
        }
        'Logs' {
            Get-FelixLog
        }
        'DryRun' {
            if (-not $RuleId) {
                throw '-RuleId is required for DryRun.'
            }
            Invoke-FelixDryRun -RuleId $RuleId -Options $options
        }
        'Apply' {
            if (-not $RuleId) {
                throw '-RuleId is required for Apply.'
            }
            Invoke-FelixApply -RuleId $RuleId -Options $options -AcceptRisk:$AcceptRisk
        }
        'BatchApply' {
            if (-not $RuleIds) {
                throw '-RuleIds is required for BatchApply.'
            }
            Invoke-FelixBatchApply -RuleIds $RuleIds -AcceptRisk:$AcceptRisk
        }
        'Restore' {
            if (-not $HistoryId) {
                throw '-HistoryId is required for Restore.'
            }
            Invoke-FelixRestore -HistoryId $HistoryId -Force:$Force
        }
        'RestoreAll' {
            Invoke-FelixRestoreAll -Force:$Force
        }
        'Recover' {
            Invoke-FelixCrashRecovery
        }
    }

    Write-CliResult -Value $result -Json:$AsJson
}
catch {
    if ($AsJson) {
        [ordered]@{
            success = $false
            error = $_.Exception.Message
        } | ConvertTo-Json -Depth 8
        exit 1
    }

    Write-Error $_
    exit 1
}
