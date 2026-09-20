[CmdletBinding()]
param(
    [switch]$IncludeWpf
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$moduleCandidates = @(
    (Join-Path $repoRoot 'src\StableTune\StableTune.psd1'),
    (Join-Path $PSScriptRoot 'src\StableTune\StableTune.psd1')
)
$modulePath = $moduleCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $modulePath) {
    throw 'Unable to locate the StableTune module.'
}

$entryCandidates = @(
    (Join-Path $repoRoot 'StableTune.ps1'),
    (Join-Path $PSScriptRoot 'StableTune.ps1')
)
$entryScriptPath = $entryCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$testRoot = Join-Path $env:TEMP "StableTuneCiSmoke-$([guid]::NewGuid().ToString('N'))"
$env:FELIX_OPTIMIZER_HOME = $testRoot

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

try {
    Import-Module $modulePath -Force

    $rules = @(Get-FelixRule)
    Assert-True ($rules.Count -eq 38) "Expected 38 rules, found $($rules.Count)."

    $ids = @($rules | ForEach-Object { $_.id })
    Assert-True ((@($ids | Sort-Object -Unique).Count) -eq $ids.Count) 'Rule IDs are not unique.'

    foreach ($rule in $rules) {
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$rule.id)) "Rule '$($rule.id)' has no ID."
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$rule.advice)) "Rule '$($rule.id)' has no advice."
        Assert-True (@($rule.consequences).Count -gt 1) "Rule '$($rule.id)' has insufficient consequences."
        Assert-True (@($rule.benefits).Count -gt 2) "Rule '$($rule.id)' has insufficient benefits."
        Assert-True (@($rule.drawbacks).Count -gt 2) "Rule '$($rule.id)' has insufficient drawbacks."
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$rule.compatibility.scope)) "Rule '$($rule.id)' has no compatibility scope."
    }

    $audit = @(Invoke-FelixAudit)
    Assert-True ($audit.Count -eq 38) "Expected 38 audit rows, found $($audit.Count)."

    $applicabilityResults = @(
        foreach ($rule in $rules) {
            Get-FelixRuleApplicability -Rule $rule
        }
    )
    Assert-True ($applicabilityResults.Count -eq 38) "Expected 38 applicability rows, found $($applicabilityResults.Count)."
    foreach ($applicability in $applicabilityResults) {
        Assert-True ($applicability.status -in @('Applicable', 'Conditional', 'NotApplicable', 'Unknown')) "Applicability result '$($applicability.ruleId)' has invalid status '$($applicability.status)'."
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$applicability.reviewedAt)) "Applicability result '$($applicability.ruleId)' has no review date."
        Assert-True (@($applicability.evidence).Count -ge 1) "Applicability result '$($applicability.ruleId)' has no technical evidence."
    }

    $plan = Invoke-FelixDryRun -RuleId 'power-plan'
    Assert-True (@($plan.plannedChanges).Count -gt 0) 'Power plan dry-run returned no changes.'

    $module = Get-Module StableTune
    $operationFixtures = @{}
    $adapter = @(
        Get-NetAdapter -ErrorAction SilentlyContinue |
            Sort-Object Status, Name |
            Select-Object -First 1
    )
    if ($adapter.Count -eq 1) {
        $adapterName = [string]$adapter[0].Name
        $operationFixtures.NetworkAdapter = @{
            AdapterName = $adapterName
            InterfaceAlias = $adapterName
            InterfaceGuid = & $module {
                param($Value)
                ConvertTo-FelixGuidText -Value $Value -Format D
            } $adapter[0].InterfaceGuid
        }
        $operationFixtures.NicPower = @{ AdapterName = $adapterName }
        $operationFixtures.NetworkInterruptModeration = @{ AdapterName = $adapterName }
        $operationFixtures.DnsProfile = @{
            InterfaceAlias = $adapterName
            Dhcp = $true
            DnsServers = @()
        }
    }
    $operationFixtures.ExecutablePath = @{
        ExecutablePath = Join-Path $env:SystemRoot 'System32\notepad.exe'
    }
    $operationFixtures.ExecutablePriority = @{
        ExecutablePath = Join-Path $env:SystemRoot 'System32\notepad.exe'
        CpuPriorityClass = 6
    }

    $startupItem = @(
        & $module { Get-FelixStartupCandidates } |
            Select-Object -First 1
    )
    if ($startupItem.Count -eq 1) {
        $operationFixtures.StartupItem = if ($startupItem[0].enabled) {
            @{
                RegistryPath = [string]$startupItem[0].registryPath
                ValueName = [string]$startupItem[0].valueName
                Enable = $false
            }
        }
        else {
            @{
                BackupPath = [string]$startupItem[0].backupPath
                Enable = $true
            }
        }
    }

    $serviceName = @(
        & $module { $script:AllowedServices } |
            Where-Object { Get-Service -Name $_ -ErrorAction SilentlyContinue } |
            Select-Object -First 1
    )
    if ($serviceName.Count -eq 1) {
        $operationFixtures.ServiceState = @{
            ServiceName = [string]$serviceName[0]
            StartupType = 'Manual'
            StopNow = $false
        }
    }

    $interruptDevice = @(
        & $module { Get-FelixInterruptCandidate } |
            Where-Object { $_.registryPath -and $_.instanceId } |
            Select-Object -First 1
    )
    if ($interruptDevice.Count -eq 1) {
        $operationFixtures.DeviceAffinity = @{
            RegistryPath = [string]$interruptDevice[0].registryPath
            InstanceId = [string]$interruptDevice[0].instanceId
            CpuMask = '0'
        }
    }

    $operationResults = @()
    foreach ($rule in $rules) {
        $applicability = Get-FelixRuleApplicability -Rule $rule
        if ($applicability.status -notin @('Applicable', 'Conditional')) {
            $operationResults += [pscustomobject]@{
                Rule = $rule.id
                Status = 'Skipped'
                Detail = $applicability.status
            }
            continue
        }

        $fixtureKey = if ($rule.Contains('inputKind')) {
            [string]$rule.inputKind
        }
        else {
            [string]$rule.handler
        }
        if ($rule.requiresInput -and -not $operationFixtures.ContainsKey($fixtureKey)) {
            $operationResults += [pscustomobject]@{
                Rule = $rule.id
                Status = 'Skipped'
                Detail = "No safe fixture for $fixtureKey."
            }
            continue
        }

        try {
            $options = if ($rule.requiresInput) { $operationFixtures[$fixtureKey] } else { @{} }
            $rulePlan = Invoke-FelixDryRun -RuleId $rule.id -Options $options
            Assert-True (@($rulePlan.plannedChanges).Count -gt 0) "Dry-run rule '$($rule.id)' returned no planned changes."
            $operationResults += [pscustomobject]@{
                Rule = $rule.id
                Status = 'Passed'
                Detail = "$(@($rulePlan.plannedChanges).Count) planned change(s)."
            }
        }
        catch {
            $operationResults += [pscustomobject]@{
                Rule = $rule.id
                Status = 'Failed'
                Detail = $_.Exception.Message
            }
        }
    }

    $failedOperations = @($operationResults | Where-Object { $_.Status -eq 'Failed' })
    if ($failedOperations.Count -gt 0) {
        $details = $failedOperations | ForEach-Object { "$($_.Rule): $($_.Detail)" }
        throw "Operation preflight failed for $($failedOperations.Count) rule(s):`n$($details -join [Environment]::NewLine)"
    }
    $passedOperations = @($operationResults | Where-Object { $_.Status -eq 'Passed' })
    $skippedOperations = @($operationResults | Where-Object { $_.Status -eq 'Skipped' })
    Assert-True ($passedOperations.Count -gt 0) 'No applicable rule completed the operation preflight.'
    Write-Host "Operation preflight passed: $($passedOperations.Count); skipped: $($skippedOperations.Count); failed: 0"

    $status = Get-FelixSystemStatus
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$status.activePowerPlan)) 'Active power plan name is empty.'
    Assert-True ([string]$status.activePowerPlan -notmatch '^[0-9a-fA-F-]{36}$') 'Power plan UI value is still a GUID.'

    $hardware = Get-FelixHardwareInventory
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$hardware.detectedAt)) 'Hardware inventory timestamp is missing.'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$hardware.architecture)) 'Hardware architecture is missing.'
    Assert-True ($hardware.Contains('memory')) 'Hardware inventory is missing the memory module collection.'
    Assert-True ($hardware.Contains('memorySummary')) 'Hardware inventory is missing the memory summary.'
    Assert-True ($hardware.Contains('memoryTimingMessage')) 'Hardware inventory is missing the memory timing message.'
    Assert-True ($hardware.Contains('antiCheatExpertInstalled')) 'Hardware inventory is missing the ACE presence result.'
    Assert-True ($hardware.Contains('deviceSecurity')) 'Hardware inventory is missing the device security result.'
    Assert-True ($hardware.deviceSecurity.Contains('message')) 'Device security status is missing its user-facing message.'

    $memoryFixture = & $module {
        ConvertTo-FelixMemoryModules -RawModules @(
            [pscustomobject]@{
                DeviceLocator = 'DIMM 0'
                BankLabel = 'BANK 0'
                PartNumber = 'TEST-DDR5'
                SerialNumber = '0001'
                Capacity = 17179869184
                Speed = 5600
                ConfiguredClockSpeed = 5200
                ConfiguredVoltage = 1100
                SMBIOSMemoryType = 34
                FormFactor = 12
                Manufacturer = 'TestVendor'
            }
        ) -TimingOverrides @{
            'DIMM 0' = @{
                casLatency = 40
                trcd = 40
                trp = 40
                tras = 96
                commandRate = 2
                source = 'CPU-Z verified'
            }
        }
    }
    Assert-True (@($memoryFixture).Count -eq 1) 'Memory fixture conversion did not return one module.'
    Assert-True (@($memoryFixture)[0].capacityBytes -eq 17179869184) 'Memory fixture capacity was not preserved.'
    Assert-True (@($memoryFixture)[0].speedMHz -eq 5600) 'Memory fixture rated speed was not preserved.'
    Assert-True (@($memoryFixture)[0].configuredSpeedMHz -eq 5200) 'Memory fixture configured speed was not preserved.'
    Assert-True (@($memoryFixture)[0].timings.casLatency -eq 40) 'Verified memory timing data was not merged.'
    Assert-True (@($memoryFixture)[0].timings.commandRate -eq 2) 'Verified memory command rate was not merged.'
    $memoryCapacity = & $module {
        Get-FelixMemoryCapacityBytes -Modules @(
            [ordered]@{ capacityBytes = [uint64]17179869184 },
            [ordered]@{ capacityBytes = [uint64]17179869184 }
        )
    }
    Assert-True ($memoryCapacity -eq 34359738368) 'Memory capacity summation failed for ordered module records.'
    $memorySpeeds = @(& $module {
        Get-FelixMemorySpeedValues -Modules @(
            [ordered]@{ configuredSpeedMHz = 6800 },
            [ordered]@{ configuredSpeedMHz = 6800 }
        ) -PropertyName 'configuredSpeedMHz'
    })
    Assert-True ($memorySpeeds.Count -eq 1 -and $memorySpeeds[0] -eq 6800) 'Memory speed extraction failed for ordered module records.'

    $report = Get-FelixSystemChangeReport
    Assert-True ($report.total -eq 38) "Expected 38 change-report rows, found $($report.total)."

    $rollback = Test-FelixRollbackCapability
    Assert-True ([bool]$rollback.available) 'Independent rollback snapshot storage is unavailable.'
    Assert-True ([string]$rollback.mode -eq 'IndependentSnapshot') 'Rollback mode is not IndependentSnapshot.'
    Assert-True (-not [bool]$rollback.requiresSystemRestorePoint) 'Rollback unexpectedly depends on a system restore point.'

    $dualRollback = Test-FelixDualRollbackCapability
    Assert-True ([string]$dualRollback.mode -eq 'DualRollback') 'Dual rollback mode is not DualRollback.'
    Assert-True ([bool]$dualRollback.requiresSystemRestorePoint) 'Dual rollback does not require a system restore point.'
    Assert-True ([bool]$dualRollback.snapshotAvailable) 'Dual rollback snapshot storage is unavailable.'

    $snapshotPolicy = Set-FelixRollbackPolicy -RequireSystemRestorePoint $false
    Assert-True (-not [bool]$snapshotPolicy.requireSystemRestorePoint) 'Snapshot-only rollback policy was not persisted.'
    $snapshotOnlyRollback = Test-FelixDualRollbackCapability -Force
    Assert-True ([string]$snapshotOnlyRollback.mode -eq 'IndependentSnapshot') 'Snapshot-only rollback mode is not IndependentSnapshot.'
    Assert-True (-not [bool]$snapshotOnlyRollback.requiresSystemRestorePoint) 'Snapshot-only rollback unexpectedly requires a system restore point.'
    Assert-True ([bool]$snapshotOnlyRollback.snapshotAvailable) 'Snapshot-only rollback storage is unavailable.'
    Set-FelixRollbackPolicy -RequireSystemRestorePoint $true | Out-Null

    $crashRecovery = Get-FelixCrashRecoveryStatus
    Assert-True ($crashRecovery.Contains('activeCount')) 'Crash recovery status is missing the active guard count.'
    Assert-True ($crashRecovery.Contains('manualCount')) 'Crash recovery status is missing the manual recovery count.'
    Assert-True ($crashRecovery.Contains('message')) 'Crash recovery status is missing its user-facing message.'

    & $module {
        Add-FelixLog -Event 'ci.smoke' -Message 'CI smoke log entry.'
        Write-FelixRollbackJournal -HistoryId 'ci-smoke' -RuleId 'power-plan' -Event 'ci_smoke' -Message 'CI rollback journal entry.'
    }
    Assert-True (@(Get-FelixLog).Count -gt 0) 'Persistent log records were not written.'
    Assert-True (Test-Path -LiteralPath (Get-FelixStatePath 'rollback.jsonl')) 'Rollback journal was not created.'

    $runWpf = $IncludeWpf -or $env:GITHUB_ACTIONS -ne 'true'
    if ($runWpf) {
        Start-StableTuneUi -SmokeTest -EntryScriptPath $entryScriptPath
    }

    Write-Host "Current smoke tests passed. WPF checked: $runWpf"
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
