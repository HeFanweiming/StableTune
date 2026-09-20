[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ModulePath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$allowedFunctions = @(
    'Get-FelixRule',
    'Get-FelixHistory',
    'Get-FelixHistoryView',
    'Get-FelixSystemStatus',
    'Get-FelixHardwareInventory',
    'Get-FelixRuleApplicability',
    'Get-FelixCrashRecoveryStatus',
    'Get-FelixSystemChangeReport',
    'Get-FelixLog',
    'Get-FelixStatePath',
    'Get-FelixRollbackPolicy',
    'Set-FelixRollbackPolicy',
    'Test-FelixRollbackCapability',
    'Test-FelixDualRollbackCapability',
    'Invoke-FelixAudit',
    'Invoke-FelixDryRun',
    'Invoke-FelixApply',
    'Invoke-FelixBatchApply',
    'Invoke-FelixRestore',
    'Invoke-FelixRestoreAll',
    'Invoke-FelixCrashRecovery',
    'Clear-FelixHistoryIndex',
    'Clear-FelixQuarantine',
    'Get-FelixStartupCandidates',
    'Get-FelixInterruptCandidate',
    'Get-FelixNetworkAdapterCandidates',
    'Get-FelixServiceCandidates',
    'Get-FelixApplicabilityCatalog'
)

function ConvertTo-PlainValue {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $result[[string]$key] = ConvertTo-PlainValue -Value $Value[$key]
        }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { ConvertTo-PlainValue -Value $_ })
    }
    return $Value
}

try {
    $requestJson = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($requestJson)) {
        throw 'The backend request is empty.'
    }

    $request = $requestJson | ConvertFrom-Json -AsHashtable
    $method = [string]$request.method
    if ([string]::IsNullOrWhiteSpace($method)) {
        throw 'The backend request does not specify a method.'
    }
    if ($method -notin $allowedFunctions) {
        throw "Backend method '$method' is not allowed."
    }

    $arguments = if ($request.ContainsKey('arguments') -and $null -ne $request.arguments) {
        $request.arguments
    }
    else {
        @{}
    }

    $module = Import-Module -Name $ModulePath -Force -PassThru -ErrorAction Stop
    if ($method -eq 'Get-FelixNetworkAdapterCandidates') {
        $data = & $module {
            @(
                Get-NetAdapter -ErrorAction SilentlyContinue |
                    Sort-Object Name |
                    Select-Object `
                        Name,
                        InterfaceGuid,
                        InterfaceDescription,
                        InterfaceIndex,
                        Status,
                        MacAddress,
                        LinkSpeed,
                        MediaType,
                        Virtual
            )
        }
    }
    elseif ($method -eq 'Get-FelixServiceCandidates') {
        $data = & $module {
            @(
                Get-Service -Name $script:AllowedServices -ErrorAction SilentlyContinue |
                    Sort-Object Name |
                    Select-Object Name, DisplayName, Status, StartType
            )
        }
    }
    else {
        $command = & $module {
            param($Name)
            Get-Command -Name $Name -ErrorAction Stop
        } $method

        $data = & $module {
            param($Name, $Parameters)
            & $Name @Parameters
        } $command $arguments
    }

    $response = [ordered]@{
        success = $true
        data = ConvertTo-PlainValue -Value $data
        error = $null
    }
}
catch {
    $response = [ordered]@{
        success = $false
        data = $null
        error = $_.Exception.Message
        scriptStackTrace = $_.ScriptStackTrace
    }
}

$response | ConvertTo-Json -Depth 60 -Compress
