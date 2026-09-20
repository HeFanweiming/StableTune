$repoRoot = Split-Path -Parent $PSScriptRoot
$moduleCandidates = @(
    (Join-Path $repoRoot 'src\StableTune\StableTune.psd1'),
    (Join-Path $PSScriptRoot 'src\StableTune\StableTune.psd1')
)
$modulePath = $moduleCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $modulePath) {
    throw 'Unable to locate the StableTune module.'
}
$entryScriptCandidates = @(
    (Join-Path $repoRoot 'StableTune.ps1'),
    (Join-Path $PSScriptRoot 'StableTune.ps1')
)
$entryScriptPath = $entryScriptCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$env:FELIX_OPTIMIZER_HOME = Join-Path $env:TEMP "FelixOptimizerPesterCatalog-$([guid]::NewGuid().ToString('N'))"
Import-Module $modulePath -Force

Describe '稳优 StableTune catalog' {
    It 'contains exactly thirty-eight unique rules' {
        $rules = Get-FelixRule
        $rules.Count | Should Be 38
        $ids = foreach ($rule in $rules) { $rule['id'] }
        ($ids | Sort-Object -Unique).Count | Should Be 38
    }

    It 'has required metadata for every rule' {
        foreach ($rule in Get-FelixRule) {
            $rule.schemaVersion | Should Be '1.0'
            $rule.id | Should Not BeNullOrEmpty
            $rule.category | Should Not BeNullOrEmpty
            $rule.handler | Should Not BeNullOrEmpty
            $rule.snapshotKind | Should Not BeNullOrEmpty
            @('safe', 'advanced') -contains $rule.risk | Should Be $true
            $rule.advice | Should Not BeNullOrEmpty
            $rule.consequences.Count | Should BeGreaterThan 1
            $rule.benefits.Count | Should BeGreaterThan 2
            $rule.drawbacks.Count | Should BeGreaterThan 2
            $rule.compatibility.scope | Should Not BeNullOrEmpty
            $rule.compatibility.os | Should Not BeNullOrEmpty
            $rule.compatibility.cpuBrand | Should Not BeNullOrEmpty
            $rule.compatibility.gpuBrand | Should Not BeNullOrEmpty
            $rule.compatibility.memory | Should Not BeNullOrEmpty
        }
    }

    It 'returns a complete read-only audit' {
        $audit = Invoke-FelixAudit
        $audit.Count | Should Be 38
    }

    It 'provides cross-checked applicability evidence for every rule' {
        foreach ($rule in Get-FelixRule) {
            $applicability = Get-FelixRuleApplicability -Rule $rule
            (@('Applicable', 'Conditional', 'NotApplicable', 'Unknown') -contains $applicability.status) | Should Be $true
            $applicability.reviewedAt | Should Be '2026-09-20'
            @($applicability.evidence).Count | Should BeGreaterThan 0
            $applicability.batchEligible | Should BeOfType System.Boolean
        }
    }

    It 'fails closed for unsupported architectures and unknown Windows builds' {
        InModuleScope StableTune {
            $architecture = Test-FelixApplicabilityCondition -Condition @{
                type = 'architecture'
                values = @('x64')
            } -Hardware @{
                architecture = 'arm64'
                osBuildNumber = 26200
            }
            $architecture.state | Should Be 'Fail'

            $osFamily = Test-FelixApplicabilityCondition -Condition @{
                type = 'osFamily'
                values = @('Windows 10', 'Windows 11')
            } -Hardware @{
                architecture = 'x64'
                osBuildNumber = 0
            }
            $osFamily.state | Should Be 'Unknown'

            $wddm = Test-FelixApplicabilityCondition -Condition @{
                type = 'wddmMinimum'
                value = 2.7
            } -Hardware @{
                wddmVersion = [version]'2.7'
            }
            $wddm.state | Should Be 'Pass'
        }
    }

    It 'merges only user-verified SPD timing data into memory modules' {
        InModuleScope StableTune {
            $modules = @(ConvertTo-FelixMemoryModules -RawModules @(
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
            })

            $modules.Count | Should Be 1
            $modules[0].memoryType | Should Be 'DDR5'
            $modules[0].capacityBytes | Should Be 17179869184
            $modules[0].speedMHz | Should Be 5600
            $modules[0].configuredSpeedMHz | Should Be 5200
            $modules[0].timings.casLatency | Should Be 40
            $modules[0].timings.commandRate | Should Be 2
            $modules[0].timings.source | Should Be 'CPU-Z verified'
        }
    }

    It 'sums capacity from ordered memory module records' {
        InModuleScope StableTune {
            $capacity = Get-FelixMemoryCapacityBytes -Modules @(
                [ordered]@{ capacityBytes = [uint64]17179869184 },
                [ordered]@{ capacityBytes = [uint64]17179869184 }
            )
            $capacity | Should Be 34359738368
        }
    }

    It 'reads memory speeds from ordered module records without property expansion' {
        InModuleScope StableTune {
            $speeds = @(Get-FelixMemorySpeedValues -Modules @(
                [ordered]@{ configuredSpeedMHz = 6800 },
                [ordered]@{ configuredSpeedMHz = 6800 }
            ) -PropertyName 'configuredSpeedMHz')

            $speeds.Count | Should Be 1
            $speeds[0] | Should Be 6800
        }
    }

    It 'does not fall back to default power values when capturing the active scheme' {
        InModuleScope StableTune {
            Mock Get-RegistryValueSnapshot {
                param($Path, $Name)
                $exists = $Path -like '*\DefaultPowerSchemeValues\*'
                return [ordered]@{
                    path = $Path
                    name = $Name
                    exists = $exists
                    kind = $(if ($exists) { 'DWord' } else { $null })
                    value = $(if ($exists) { 99 } else { $null })
                }
            }

            $active = Get-FelixPowerSettingValueSnapshot `
                -SchemeGuid '11111111-1111-1111-1111-111111111111' `
                -SubgroupGuid '22222222-2222-2222-2222-222222222222' `
                -SettingGuid '33333333-3333-3333-3333-333333333333' `
                -ValueName 'ACSettingIndex'
            $active.exists | Should Be $false

            $baseline = Get-FelixPowerSettingValueSnapshot `
                -SchemeGuid '11111111-1111-1111-1111-111111111111' `
                -SubgroupGuid '22222222-2222-2222-2222-222222222222' `
                -SettingGuid '33333333-3333-3333-3333-333333333333' `
                -ValueName 'ACSettingIndex' `
                -UseDefaultFallback
            $baseline.exists | Should Be $true
            $baseline.value | Should Be 99
        }
    }

    It 'switches the heterogeneous power baseline to the current active scheme' {
        InModuleScope StableTune {
            $snapshot = @{
                before = [ordered]@{
                    activeSchemeGuid = '11111111-1111-1111-1111-111111111111'
                    settings = @(
                        [ordered]@{
                            name = 'HETEROPOLICY'
                            subgroupGuid = '22222222-2222-2222-2222-222222222222'
                            settingGuid = '33333333-3333-3333-3333-333333333333'
                            targetAc = 0
                            targetDc = 0
                        }
                    )
                }
            }

            Mock Get-ActivePowerSchemeGuid { return '11111111-1111-1111-1111-111111111111' }
            Mock Get-HeterogeneousPowerCurrentValues {
                param($Snapshot)
                return @(
                    [ordered]@{
                        setting = $Snapshot.before.settings[0]
                        ac = [ordered]@{ exists = $true; value = 0 }
                        dc = [ordered]@{ exists = $true; value = 0 }
                    }
                )
            }
            $script:powerCalls = @()
            Mock Invoke-FelixNative {
                param($FilePath, $ArgumentList)
                $script:powerCalls += ,@($FilePath, $ArgumentList)
            }
            Mock Clear-FelixActivePowerSchemeCache {}

            (Test-HeterogeneousPowerPolicyApplied -Snapshot $snapshot) | Should Be $true
            Invoke-HeterogeneousPowerPolicyApply -Snapshot $snapshot | Out-Null
            @($script:powerCalls).Count | Should Be 3
            @($script:powerCalls | Where-Object { $_[1][0] -eq '/setacvalueindex' }).Count | Should Be 1
            @($script:powerCalls | Where-Object { $_[1][0] -eq '/setdcvalueindex' }).Count | Should Be 1
            @($script:powerCalls | Where-Object { $_[1][0] -eq '/setactive' }).Count | Should Be 1
        }
    }

    It 'blocks the ACE priority rule when AntiCheatExpert is not detected' {
        InModuleScope StableTune {
            Mock Test-FelixAntiCheatExpertPresence { return $false }
            $rule = @{
                handler = 'RegistrySet'
                prerequisiteKind = 'AntiCheatExpert'
                registryChanges = @(
                    [ordered]@{
                        path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\SGuard64.exe\PerfOptions'
                        name = 'CpuPriorityClass'
                        kind = 'DWord'
                        value = 1
                    }
                )
            }

            $result = Test-RegistrySetPrerequisite -Rule $rule
            $result.available | Should Be $false
            $result.message | Should Match 'AntiCheatExpert'
        }
    }

    It 'allows only normal or above-normal priorities for a selected executable' {
        InModuleScope StableTune {
            $executablePath = (Get-Process -Id $PID).Path
            if ([string]::IsNullOrWhiteSpace($executablePath) -or -not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
                throw 'Unable to resolve the current PowerShell executable for the fixture.'
            }
            $rule = @{
                handler = 'RegistrySet'
                inputKind = 'ExecutablePriority'
                registryChanges = @(
                    [ordered]@{
                        path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\{ExecutableName}\PerfOptions'
                        name = 'CpuPriorityClass'
                        kind = 'DWord'
                        value = '{CpuPriorityClass}'
                    }
                )
            }

            (Test-RegistrySetPrerequisite -Rule $rule -Options @{
                ExecutablePath = $executablePath
                CpuPriorityClass = 2
            }).available | Should Be $true
            (Test-RegistrySetPrerequisite -Rule $rule -Options @{
                ExecutablePath = $executablePath
                CpuPriorityClass = 6
            }).available | Should Be $true

            foreach ($priority in @(1, 3, 4, 5)) {
                (Test-RegistrySetPrerequisite -Rule $rule -Options @{
                    ExecutablePath = $executablePath
                    CpuPriorityClass = $priority
                }).available | Should Be $false
            }
        }
    }

    It 'restores the original executable priority value without touching other process settings' {
        InModuleScope StableTune {
            $executablePath = (Get-Process -Id $PID).Path
            $testKey = "HKCU:\Software\FelixOptimizerTests\$([guid]::NewGuid().ToString('N'))"
            $rule = @{
                handler = 'RegistrySet'
                inputKind = 'ExecutablePriority'
                registryChanges = @(
                    [ordered]@{
                        path = $testKey
                        name = 'CpuPriorityClass'
                        kind = 'DWord'
                        value = '{CpuPriorityClass}'
                    }
                )
            }
            $options = @{
                ExecutablePath = $executablePath
                CpuPriorityClass = 6
            }

            try {
                $before = Get-RegistrySetSnapshot -Rule $rule -Options $options
                $before.entries[0].exists | Should Be $false
                Invoke-RegistrySetApply -Rule $rule -Snapshot $before -Options $options | Out-Null
                (Get-ItemPropertyValue -LiteralPath $testKey -Name 'CpuPriorityClass') | Should Be 6
                Invoke-RegistrySetRestore -Snapshot @{
                    before = $before
                    after = $null
                }
                ((Get-Item -LiteralPath $testKey).GetValueNames() -notcontains 'CpuPriorityClass') | Should Be $true
            }
            finally {
                Remove-Item -LiteralPath $testKey -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'normalizes adapter GUID values returned as strings or GUID objects' {
        InModuleScope StableTune {
            $guid = [guid]'00112233-4455-6677-8899-aabbccddeeff'
            (ConvertTo-FelixGuidText -Value $guid -Format D) | Should Be $guid.ToString('D')
            (ConvertTo-FelixGuidText -Value $guid.ToString('D') -Format B) | Should Be $guid.ToString('B')
        }
    }

    It 'decodes WDDM registry capabilities without launching dxdiag' {
        InModuleScope StableTune {
            (ConvertFrom-FelixWddmRegistryValue -Value 0x9C0).ToString() | Should Be '2.7'
            (ConvertFrom-FelixWddmRegistryValue -Value 0xC80).ToString() | Should Be '3.2'
            ConvertFrom-FelixWddmRegistryValue -Value 1 | Should BeNullOrEmpty
        }
    }

    It 'reuses a supplied hardware snapshot for applicability checks' {
        InModuleScope StableTune {
            $applicability = Get-FelixRuleApplicability -Rule (Get-FelixRuleRequired -RuleId 'power-plan') -Hardware @{
                osBuildNumber = 26100
                architecture = 'x64'
            }
            $applicability.status | Should Be 'Applicable'
        }
    }

    It 'returns a dry-run plan without changing the system' {
        $plan = Invoke-FelixDryRun -RuleId 'power-plan'
        $plan.ruleId | Should Be 'power-plan'
        @($plan.plannedChanges).Count | Should BeGreaterThan 0
    }

    It 'plans a data-driven registry rule without changing the system' {
        $plan = Invoke-FelixDryRun -RuleId 'input-mouse-acceleration'
        $plan.ruleId | Should Be 'input-mouse-acceleration'
        @($plan.plannedChanges).Count | Should BeGreaterThan 0
    }

    It 'detects the active power plan by name and keeps its GUID internal' {
        $status = Get-FelixSystemStatus
        $status.activePowerPlan | Should Not BeNullOrEmpty
        $status.activePowerPlan | Should Not Match '^[0-9a-fA-F-]{36}$'
        $status.activePowerPlanGuid | Should Not BeNullOrEmpty
    }

    It 'returns hardware inventory without changing the system' {
        $hardware = Get-FelixHardwareInventory
        $hardware.detectedAt | Should Not BeNullOrEmpty
        $hardware.architecture | Should Not BeNullOrEmpty
        $hardware.Contains('memory') | Should Be $true
        $hardware.Contains('memorySummary') | Should Be $true
        $hardware.Contains('memoryTimingMessage') | Should Be $true
        $hardware.Contains('antiCheatExpertInstalled') | Should Be $true
        $hardware.Contains('deviceSecurity') | Should Be $true
        $hardware.deviceSecurity.Contains('message') | Should Be $true
    }

    It 'returns a native system-change report for every rule' {
        $report = Get-FelixSystemChangeReport
        $report.total | Should Be 38
        @($report.rows).Count | Should Be 38
    }

    It 'requires independent snapshots and a Windows restore point for rollback' {
        $snapshot = Test-FelixRollbackCapability
        $snapshot.available | Should Be $true
        $snapshot.mode | Should Be 'IndependentSnapshot'
        $snapshot.requiresSystemRestorePoint | Should Be $false

        $rollback = Test-FelixDualRollbackCapability
        $rollback.mode | Should Be 'DualRollback'
        $rollback.requiresSystemRestorePoint | Should Be $true
        $rollback.snapshotAvailable | Should Be $true
    }

    It 'defaults to dual rollback and persists an explicit snapshot-only policy' {
        $originalHome = $env:FELIX_OPTIMIZER_HOME
        $testRoot = Join-Path $env:TEMP "FelixOptimizerRollbackPolicy-$([guid]::NewGuid().ToString('N'))"
        $env:FELIX_OPTIMIZER_HOME = $testRoot

        try {
            $defaultPolicy = Get-FelixRollbackPolicy
            $defaultPolicy.requireSystemRestorePoint | Should Be $true
            $defaultPolicy.mode | Should Be 'DualRollback'

            $updated = Set-FelixRollbackPolicy -RequireSystemRestorePoint $false
            $updated.requireSystemRestorePoint | Should Be $false
            $updated.mode | Should Be 'IndependentSnapshot'

            $persisted = Get-FelixRollbackPolicy
            $persisted.requireSystemRestorePoint | Should Be $false
            $persisted.mode | Should Be 'IndependentSnapshot'
            $session = Get-Content -LiteralPath (Join-Path $testRoot 'session.json') -Raw | ConvertFrom-Json
            $session.allowOptimizationWithoutRestorePoint | Should Be $true
        }
        finally {
            $env:FELIX_OPTIMIZER_HOME = $originalHome
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'runs with independent snapshots only when the restore-point requirement is disabled' {
        $originalHome = $env:FELIX_OPTIMIZER_HOME
        $testRoot = Join-Path $env:TEMP "FelixOptimizerSnapshotOnly-$([guid]::NewGuid().ToString('N'))"
        $env:FELIX_OPTIMIZER_HOME = $testRoot

        try {
            InModuleScope StableTune {
                Clear-FelixRuntimeCaches
                Mock Test-FelixRollbackCapability {
                    return [ordered]@{
                        available = $true
                        mode = 'IndependentSnapshot'
                        snapshotRoot = (Get-FelixStatePath 'snapshots')
                        requiresSystemRestorePoint = $false
                        message = 'Fixture snapshot storage.'
                    }
                }
                Mock Get-FelixRestorePoint {
                    throw 'Restore-point discovery must not run in snapshot-only mode.'
                }

                Set-FelixRollbackPolicy -RequireSystemRestorePoint $false
                $result = Test-FelixDualRollbackCapability -Force
                $result.available | Should Be $true
                $result.mode | Should Be 'IndependentSnapshot'
                $result.requiresSystemRestorePoint | Should Be $false
                $result.restorePointAvailable | Should Be $false
            }
        }
        finally {
            $env:FELIX_OPTIMIZER_HOME = $originalHome
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'still blocks snapshot-only execution when independent snapshot storage is unavailable' {
        $originalHome = $env:FELIX_OPTIMIZER_HOME
        $testRoot = Join-Path $env:TEMP "FelixOptimizerNoSnapshot-$([guid]::NewGuid().ToString('N'))"
        $env:FELIX_OPTIMIZER_HOME = $testRoot

        try {
            InModuleScope StableTune {
                Clear-FelixRuntimeCaches
                Mock Test-FelixRollbackCapability {
                    return [ordered]@{
                        available = $false
                        mode = 'IndependentSnapshot'
                        snapshotRoot = (Get-FelixStatePath 'snapshots')
                        requiresSystemRestorePoint = $false
                        message = 'Fixture snapshot failure.'
                    }
                }

                Set-FelixRollbackPolicy -RequireSystemRestorePoint $false
                $result = Test-FelixDualRollbackCapability -Force
                $result.available | Should Be $false
                $result.snapshotAvailable | Should Be $false
                $result.mode | Should Be 'IndependentSnapshot'
            }
        }
        finally {
            $env:FELIX_OPTIMIZER_HOME = $originalHome
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'constructs all WPF pages in smoke mode' {
        Start-StableTuneUi -SmokeTest -EntryScriptPath $entryScriptPath
    }

    It 'treats unknown system facts as not executable' {
        InModuleScope StableTune {
            $catalog = Get-FelixApplicabilityCatalog
            $originalRule = $catalog.rules['power-plan']
            $fixtureProfile = 'test-unknown-fixture'
            $catalog.profiles[$fixtureProfile] = @{
                summary = 'Fixture'
                conditions = @(
                    @{ type = 'unknown-fixture-condition' }
                )
                evidenceIds = @()
            }
            $catalog.rules['power-plan'] = @{
                profile = $fixtureProfile
                batchEligible = $true
            }

            try {
                $status = Get-FelixRuleApplicability -Rule (Get-FelixRuleRequired -RuleId 'power-plan')
                $status.status | Should Be 'Unknown'
                $threw = $false
                try {
                    Invoke-FelixDryRun -RuleId 'power-plan' | Out-Null
                }
                catch {
                    $threw = $true
                }
                $threw | Should Be $true
            }
            finally {
                $catalog.rules['power-plan'] = $originalRule
                $catalog.profiles.Remove($fixtureProfile) | Out-Null
            }
        }
    }

    It 'verifies handlers that store a registry value snapshot directly' {
        InModuleScope StableTune {
            Mock Test-RegistrySnapshotCurrent { return $true }

            foreach ($handler in @('PrioritySeparation', 'AmdDynamicPstate')) {
                $rule = @{ handler = $handler }
                $snapshot = @{
                    before = [ordered]@{
                        path = 'HKLM:\Test\Before'
                        name = 'Value'
                        exists = $true
                        kind = 'DWord'
                        value = 64
                    }
                    after = [ordered]@{
                        path = 'HKLM:\Test\After'
                        name = 'Value'
                        exists = $true
                        kind = 'DWord'
                        value = 40
                    }
                }

                (Test-FelixHandlerApplied -Rule $rule -Snapshot $snapshot) | Should Be $true
                (Test-FelixHandlerRestoreConflict -Rule $rule -Snapshot $snapshot) | Should Be $true
                (Test-FelixHandlerRestored -Rule $rule -Snapshot $snapshot) | Should Be $true
            }
        }
    }
}

Describe '稳优 StableTune state' {
    It 'persists and projects append-only history' {
        $testRoot = Join-Path $env:TEMP "FelixOptimizerPester-$([guid]::NewGuid().ToString('N'))"
        $env:FELIX_OPTIMIZER_HOME = $testRoot

        try {
            InModuleScope StableTune {
                $operationId = [guid]::NewGuid().ToString('D')
                Initialize-FelixState
                Add-FelixHistoryEvent -Record ([ordered]@{
                    historyId = $operationId
                    operationId = $operationId
                    ruleId = 'power-plan'
                    ruleName = 'Test'
                    risk = 'safe'
                    requiresRestart = $false
                    eventType = 'apply_succeeded'
                    status = 'Applied'
                    timestamp = (Get-Date).ToString('o')
                    message = 'Test'
                    snapshotPath = 'test.json'
                })
                Add-FelixHistoryEvent -Record ([ordered]@{
                    historyId = $operationId
                    operationId = $operationId
                    ruleId = 'power-plan'
                    ruleName = 'Test'
                    risk = 'safe'
                    requiresRestart = $false
                    eventType = 'restored'
                    status = 'Restored'
                    timestamp = (Get-Date).AddSeconds(1).ToString('o')
                    message = 'Restored'
                    snapshotPath = 'test.json'
                })

                $record = @(Get-FelixHistory -HistoryId $operationId)
                $record.Count | Should Be 1
                $record[0].status | Should Be 'Restored'
            }
        }
        finally {
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'writes persistent log and rollback journal records' {
        $testRoot = Join-Path $env:TEMP "FelixOptimizerLogs-$([guid]::NewGuid().ToString('N'))"
        $env:FELIX_OPTIMIZER_HOME = $testRoot

        try {
            InModuleScope StableTune {
                Initialize-FelixState
                Add-FelixLog -Event 'test.event' -Message 'Test log entry.'
                Write-FelixRollbackJournal -HistoryId 'test-history' -RuleId 'power-plan' -Event 'test_rollback' -Message 'Test rollback entry.'

                @(Get-FelixLog).Count | Should BeGreaterThan 0
                (Get-FelixStatePath 'rollback.jsonl') | Should Not BeNullOrEmpty
                Test-Path -LiteralPath (Get-FelixStatePath 'rollback.jsonl') | Should Be $true
            }
        }
        finally {
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe '稳优 StableTune safeguards' {
    It 'keeps direct module UI startup free of a second elevation prompt' {
        $command = Get-Command Start-StableTuneUi
        $definition = $command.ScriptBlock.ToString()
        $definition | Should Not Match 'ui\.admin_required'
        $definition | Should Not Match 'Verb RunAs'
    }

    It 'filters the rule collection in place when switching categories' {
        InModuleScope StableTune {
            $definition = (Get-Command Update-FelixUiRuleList).ScriptBlock.ToString()
            $definition | Should Match 'RuleItemsView\.Refresh'
            $definition | Should Not Match 'RuleList\.Items\.Clear'
        }
    }

    It 'starts independent overview checks and rule audit in background jobs' {
        InModuleScope StableTune {
            $overview = (Get-Command Start-FelixUiOverviewLoad).ScriptBlock.ToString()
            $overview | Should Match 'Start-ThreadJob'
            $overview | Should Match 'Get-FelixSystemStatus'
            $overview | Should Match 'Get-FelixHardwareInventory'
            $overview | Should Match 'Get-FelixSystemChangeReport'

            $rulesLoad = (Get-Command Start-FelixUiRulesLoad).ScriptBlock.ToString()
            $rulesLoad | Should Match 'ConvertTo-FelixUiRuleShells'

            $rulesAudit = (Get-Command Start-FelixUiRulesAudit).ScriptBlock.ToString()
            $rulesAudit | Should Match 'Invoke-FelixAudit -Hardware \$HardwareSnapshot'
        }
    }

    It 'counts an empty rule selection without failing under strict mode' {
        InModuleScope StableTune {
            $originalState = $script:FelixUiState
            try {
                $script:FelixUiState = @{ RuleRows = @() }
                (Get-FelixSelectedRuleCount) | Should Be 0
            }
            finally {
                $script:FelixUiState = $originalState
            }
        }
    }

    It 'treats a null rule collection as empty during filtering and selection' {
        InModuleScope StableTune {
            $originalState = $script:FelixUiState
            try {
                $script:FelixUiState = @{
                    RuleRows = $null
                    RuleFilter = $null
                }
                @(Get-FelixAllRuleRows).Count | Should Be 0
                @(Get-FelixVisibleRuleRows).Count | Should Be 0
                @(Get-FelixSelectedRuleRows).Count | Should Be 0
                (Get-FelixSelectedRuleCount) | Should Be 0
            }
            finally {
                $script:FelixUiState = $originalState
            }
        }
    }

    It 'supports all, none, and applicable selection modes' {
        InModuleScope StableTune {
            $originalState = $script:FelixUiState
            try {
                $script:FelixUiState = @{
                    RuleRows = @(
                        [pscustomobject]@{ selected = $false; batchEligible = $true; category = 'one' }
                        [pscustomobject]@{ selected = $false; batchEligible = $false; category = 'two' }
                    )
                    RuleFilter = $null
                    RuleList = $null
                }

                (Set-FelixVisibleRuleSelection -Mode All) | Should Be 2
                (Set-FelixVisibleRuleSelection -Mode None) | Should Be 0
                (Set-FelixVisibleRuleSelection -Mode Applicable) | Should Be 1
                @($script:FelixUiState.RuleRows | Where-Object { $_.selected }).Count | Should Be 1
            }
            finally {
                $script:FelixUiState = $originalState
            }
        }
    }

    It 'reports administrator privilege status from the command launcher' {
        $launcher = Get-Content -LiteralPath (Join-Path $repoRoot 'Start-StableTune.cmd') -Raw
        $launcher | Should Match 'IS_ADMIN'
        $launcher | Should Match 'Administrator privileges'
        $launcher | Should Match 'Verb RunAs'
        $launcher | Should Match 'fltmc\.exe'
    }

    It 'keeps Windows command launchers compatible with cmd.exe' {
        $launcherPaths = @(
            (Join-Path $repoRoot 'Start-StableTune.cmd'),
            (Join-Path $repoRoot 'tools\Start-StableTunePortable.cmd')
        ) | Where-Object { Test-Path -LiteralPath $_ }

        $launcherPaths.Count | Should BeGreaterThan 0
        foreach ($launcherPath in $launcherPaths) {
            $bytes = [System.IO.File]::ReadAllBytes($launcherPath)
            for ($index = 0; $index -lt $bytes.Length; $index++) {
                if ($bytes[$index] -eq 10) {
                    ($index -gt 0 -and $bytes[$index - 1] -eq 13) | Should Be $true
                }
                ($bytes[$index] -lt 128) | Should Be $true
            }
        }
    }

    It 'supports portable launcher path fallback and smoke-test arguments' {
        $portablePath = Join-Path $repoRoot 'tools\Start-StableTunePortable.cmd'
        if (Test-Path -LiteralPath $portablePath) {
            $launcher = Get-Content -LiteralPath $portablePath -Raw
            $launcher | Should Match '%~dp0\.\.\\bin\\StableTune\.exe'
            $launcher | Should Match '"%APP%" %\*'
        }
    }

    It 'persists and clears crash guard state without registering machine tasks in tests' {
        $testRoot = Join-Path $env:TEMP "FelixOptimizerGuard-$([guid]::NewGuid().ToString('N'))"
        $env:FELIX_OPTIMIZER_HOME = $testRoot

        try {
            InModuleScope StableTune {
                Mock Register-FelixCrashGuardInfrastructure {
                    return [ordered]@{
                        available = $true
                        scheduledTask = $true
                        runOnce = $true
                        mode = 'Test'
                        workerPath = 'test.ps1'
                        errors = @()
                    }
                }
                Mock Remove-FelixCrashGuardInfrastructure {}

                $guard = Register-FelixCrashGuard -OperationId 'guard-test' -HistoryId 'guard-test' -RuleId 'power-plan' -SnapshotPath 'snapshot.json' -Before @{ value = 1 } -RequiresRestart $true
                $guard.state | Should Be 'Armed'
                Test-Path -LiteralPath (Get-FelixCrashGuardPath -OperationId 'guard-test') | Should Be $true

                Set-FelixCrashGuardState -OperationId 'guard-test' -State 'AwaitingBoot' | Out-Null
                $awaiting = @(Get-FelixCrashGuard -OperationId 'guard-test')[0]
                $awaiting.state | Should Be 'AwaitingBoot'
                $awaiting.appliedAt | Should Not BeNullOrEmpty

                Complete-FelixCrashGuard -OperationId 'guard-test'
                Test-Path -LiteralPath (Get-FelixCrashGuardPath -OperationId 'guard-test') | Should Be $false
            }
        }
        finally {
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'automatically restores an armed operation after an interrupted apply' {
        $testRoot = Join-Path $env:TEMP "FelixOptimizerRecovery-$([guid]::NewGuid().ToString('N'))"
        $env:FELIX_OPTIMIZER_HOME = $testRoot

        try {
            InModuleScope StableTune {
                Mock Register-FelixCrashGuardInfrastructure {
                    return [ordered]@{
                        available = $true
                        scheduledTask = $true
                        runOnce = $true
                        mode = 'Test'
                        workerPath = 'test.ps1'
                        errors = @()
                    }
                }
                Mock Remove-FelixCrashGuardInfrastructure {}
                Mock Invoke-FelixHandlerRestore {}
                Mock Test-FelixHandlerRestored { return $true }

                $before = [ordered]@{ value = 'original' }
                $snapshot = [ordered]@{
                    schemaVersion = '1.0'
                    appVersion = 'test'
                    operationId = 'recovery-test'
                    ruleId = 'power-plan'
                    ruleName = 'Fixture'
                    risk = 'safe'
                    requiresRestart = $false
                    rollbackMode = 'DualRollback'
                    systemRestorePointRequired = $true
                    snapshotHash = $null
                    capturedAt = (Get-Date).ToString('o')
                    options = @{}
                    before = $before
                    after = $null
                }
                $snapshotPath = Save-FelixSnapshot -Snapshot $snapshot
                Register-FelixCrashGuard -OperationId 'recovery-test' -HistoryId 'recovery-test' -RuleId 'power-plan' -SnapshotPath $snapshotPath -Before $before -RequiresRestart $false | Out-Null

                $results = @(Invoke-FelixCrashRecovery)
                $results.Count | Should Be 1
                $results[0].status | Should Be 'CrashRecovered'
                Test-Path -LiteralPath (Get-FelixCrashGuardPath -OperationId 'recovery-test') | Should Be $false
            }
        }
        finally {
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rolls back earlier successes when a batch operation fails' {
        $testRoot = Join-Path $env:TEMP "FelixOptimizerBatch-$([guid]::NewGuid().ToString('N'))"
        $env:FELIX_OPTIMIZER_HOME = $testRoot

        try {
            InModuleScope StableTune {
                Mock Get-FelixRuleApplicability {
                    param($Rule)
                    return [ordered]@{
                        ruleId = [string]$Rule.id
                        status = 'Applicable'
                        label = '适用本机'
                        confidence = 'High'
                        message = 'Fixture'
                        reasons = @()
                        evidence = @()
                        reviewedAt = '2026-09-15'
                        batchEligible = $true
                    }
                }
                Mock Invoke-FelixApply {
                    param($RuleId)
                    if ($RuleId -eq 'power-usb-suspend') {
                        throw 'Fixture failure.'
                    }
                    return [ordered]@{
                        success = $true
                        historyId = $RuleId
                        ruleId = $RuleId
                        status = 'Applied'
                        requiresRestart = $false
                    }
                }
                Mock Invoke-FelixRestore {
                    param($HistoryId)
                    return [ordered]@{
                        success = $true
                        historyId = $HistoryId
                        ruleId = 'power-plan'
                        status = 'Restored'
                    }
                }

                $result = Invoke-FelixBatchApply -RuleIds @('power-plan', 'power-usb-suspend')
                $result.success | Should Be $false
                @($result.applied).Count | Should Be 1
                @($result.rolledBack).Count | Should Be 1
                $result.failure.ruleId | Should Be 'power-usb-suspend'
            }
        }
        finally {
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps failed and interrupted transactions available for recovery' {
        $testRoot = Join-Path $env:TEMP "FelixOptimizerRecoveryIndex-$([guid]::NewGuid().ToString('N'))"
        $env:FELIX_OPTIMIZER_HOME = $testRoot

        try {
            InModuleScope StableTune {
                Initialize-FelixState
                Add-FelixHistoryEvent -Record ([ordered]@{
                    historyId = 'failed-operation'
                    operationId = 'failed-operation'
                    ruleId = 'power-plan'
                    ruleName = 'Test'
                    risk = 'safe'
                    requiresRestart = $false
                    eventType = 'apply_failed'
                    status = 'Failed'
                    timestamp = (Get-Date).ToString('o')
                    message = 'Fixture failure'
                    snapshotPath = 'test.json'
                })

                $restorable = @(Get-FelixHistory -RestorableOnly)
                $restorable.Count | Should Be 1
                $restorable[0].status | Should Be 'Failed'
                $view = Get-FelixHistoryView
                $view.restorable.Count | Should Be 1
            }
        }
        finally {
            Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
