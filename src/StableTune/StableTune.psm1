Set-StrictMode -Version Latest

$script:ModuleRoot = $PSScriptRoot
$script:ModuleVersion = '0.1.9.1'
$script:CatalogPath = Join-Path $PSScriptRoot 'rules\catalog.json'
$script:RuleDetailsPath = Join-Path $PSScriptRoot 'rules\details.zh-CN.json'
$script:RuleGuidancePath = Join-Path $PSScriptRoot 'rules\guidance.zh-CN.json'
$script:RuleApplicabilityPath = Join-Path $PSScriptRoot 'rules\applicability.zh-CN.json'
$script:UiResourcePath = Join-Path $PSScriptRoot 'resources\ui.zh-CN.json'
$script:RuleCache = $null
$script:ApplicabilityCache = $null
$script:HardwareCache = $null
$script:HardwareCacheAt = $null
$script:WddmCache = $null
$script:WddmCacheAt = $null
$script:ActivePowerSchemeCache = $null
$script:ActivePowerSchemeCacheAt = $null
$script:RollbackCapabilityCache = $null
$script:RollbackCapabilityCacheAt = $null
$script:RollbackCapabilityCacheKey = $null
$script:SystemStatusCache = $null
$script:SystemStatusCacheAt = $null
$script:SystemStatusCacheKey = $null
$script:UiCapabilityCacheSeconds = 8
$script:UiSystemStatusCacheSeconds = 5
$script:UiActivePowerSchemeCacheSeconds = 5
$script:WddmCacheSeconds = 86400
$script:OperationMutex = [Threading.Mutex]::new($false, 'Local\FelixOptimizerPrototypeOperation')
$script:CrashGuardTaskName = 'FelixOptimizerCrashRecovery'
$script:CrashGuardRunOnceName = 'FelixOptimizerCrashRecovery'
$script:AllowedRisk = @('safe', 'advanced')
$script:RestorableStatuses = @('Applied', 'RestoreFailed', 'Failed', 'CrashRecoveryFailed', 'InProgress')
$script:AllowedStartupRoots = @(
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
)
$script:AllowedServices = @(
    'SysMain',
    'WSearch',
    'Spooler',
    'XblAuthManager',
    'XblGameSave',
    'XboxNetApiSvc',
    'DiagTrack'
)

function Get-FelixStatePath {
    [CmdletBinding()]
    param(
        [string]$ChildPath = ''
    )

    $override = [Environment]::GetEnvironmentVariable('FELIX_OPTIMIZER_HOME')
    $root = if ([string]::IsNullOrWhiteSpace($override)) {
        Join-Path $env:LOCALAPPDATA 'FelixOptimizer'
    }
    else {
        [IO.Path]::GetFullPath($override)
    }

    if ([string]::IsNullOrWhiteSpace($ChildPath)) {
        return $root
    }

    return Join-Path $root $ChildPath
}

function Initialize-FelixState {
    [CmdletBinding()]
    param()

    $paths = @(
        (Get-FelixStatePath),
        (Get-FelixStatePath 'snapshots'),
        (Get-FelixStatePath 'quarantine'),
        (Get-FelixStatePath 'crash-guards'),
        (Get-FelixStatePath 'worker'),
        (Get-FelixStatePath 'logs')
    )

    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }

    $historyPath = Get-FelixStatePath 'history.jsonl'
    if (-not (Test-Path -LiteralPath $historyPath)) {
        New-Item -ItemType File -Path $historyPath -Force | Out-Null
    }

    $rollbackPath = Get-FelixStatePath 'rollback.jsonl'
    if (-not (Test-Path -LiteralPath $rollbackPath)) {
        New-Item -ItemType File -Path $rollbackPath -Force | Out-Null
    }

    $logPath = Get-FelixStatePath 'logs\optimizer.jsonl'
    if (-not (Test-Path -LiteralPath $logPath)) {
        New-Item -ItemType File -Path $logPath -Force | Out-Null
    }

    $sessionPath = Get-FelixStatePath 'session.json'
    if (-not (Test-Path -LiteralPath $sessionPath)) {
        $session = [ordered]@{
            schemaVersion = '1.0'
            appVersion = $script:ModuleVersion
            sessionId = [guid]::NewGuid().ToString('D')
            startedAt = (Get-Date).ToString('o')
            rollbackMode = 'DualRollback'
            requiresSystemRestorePoint = $true
            restorePointAvailable = $false
            restorePointId = $null
            restorePointCreatedAt = $null
            allowOptimizationWithoutRestorePoint = $false
            rollbackPolicyUpdatedAt = (Get-Date).ToString('o')
        }
        Write-FelixJsonAtomic -Path $sessionPath -Value $session
    }
}

function Write-FelixJsonAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$Value
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Read-FelixJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable)
}

function Add-FelixLog {
    [CmdletBinding()]
    param(
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Level = 'Information',

        [Parameter(Mandatory)]
        [string]$Event,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$RuleId = $null,
        [string]$HistoryId = $null,
        [hashtable]$Data = @{}
    )

    $logDirectory = Get-FelixStatePath 'logs'
    if (-not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    }

    $record = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        level = $Level
        event = $Event
        message = $Message
        ruleId = $RuleId
        historyId = $HistoryId
        data = $Data
    }

    $line = $record | ConvertTo-Json -Compress -Depth 12
    Add-Content -LiteralPath (Get-FelixStatePath 'logs\optimizer.jsonl') -Value $line -Encoding utf8
}

function Get-FelixLog {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 5000)]
        [int]$Last = 500,

        [string]$Level
    )

    Initialize-FelixState
    $path = Get-FelixStatePath 'logs\optimizer.jsonl'
    $records = @()
    foreach ($line in Get-Content -LiteralPath $path -Tail $Last -ErrorAction SilentlyContinue) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $record = $line | ConvertFrom-Json -AsHashtable
            if ($Level -and [string]$record.level -ne $Level) {
                continue
            }
            $records += $record
        }
        catch {
            Write-Warning "Ignoring malformed log line: $($_.Exception.Message)"
        }
    }

    return @($records | Sort-Object timestamp -Descending)
}

function Write-FelixRollbackJournal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HistoryId,

        [Parameter(Mandatory)]
        [string]$RuleId,

        [Parameter(Mandatory)]
        [string]$Event,

        [string]$SnapshotPath,
        [string]$SnapshotHash,
        [string]$RestorePointId,
        [string]$RestorePointCreatedAt,
        [ValidateSet('DualRollback', 'IndependentSnapshot')]
        [string]$RollbackMode = 'DualRollback',
        [bool]$SystemRestorePointRequired = $true,
        [string]$Message = ''
    )

    Initialize-FelixState
    $record = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        historyId = $HistoryId
        ruleId = $RuleId
        event = $Event
        snapshotPath = $SnapshotPath
        snapshotHash = $SnapshotHash
        message = $Message
        rollbackMode = $RollbackMode
        systemRestorePointRequired = $SystemRestorePointRequired
        restorePointId = $RestorePointId
        restorePointCreatedAt = $RestorePointCreatedAt
    }
    Add-Content -LiteralPath (Get-FelixStatePath 'rollback.jsonl') -Value ($record | ConvertTo-Json -Compress -Depth 10) -Encoding utf8
}

function Get-FelixObjectHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Compress -Depth 30
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function Get-FelixCrashGuardPath {
    param(
        [Parameter(Mandatory)]
        [string]$OperationId
    )

    return Get-FelixStatePath (Join-Path 'crash-guards' "$OperationId.json")
}

function Get-FelixCrashGuard {
    [CmdletBinding()]
    param(
        [string]$OperationId
    )

    Initialize-FelixState
    $guards = @()
    if ($OperationId) {
        $path = Get-FelixCrashGuardPath -OperationId $OperationId
        $guard = Read-FelixJson -Path $path
        if ($guard) {
            $guard['path'] = $path
            $guards += $guard
        }
        return @($guards)
    }

    foreach ($file in Get-ChildItem -LiteralPath (Get-FelixStatePath 'crash-guards') -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $guard = Read-FelixJson -Path $file.FullName
        if ($guard) {
            $guard['path'] = $file.FullName
            $guards += $guard
        }
    }
    return @($guards | Sort-Object createdAt)
}

function Get-FelixLastBootTime {
    [CmdletBinding()]
    param()

    return (Get-Date).AddMilliseconds(-1 * [Environment]::TickCount64)
}

function Register-FelixCrashGuardInfrastructure {
    [CmdletBinding()]
    param()

    Initialize-FelixState
    $workerPath = Join-Path $script:ModuleRoot 'CrashRecoveryWorker.ps1'
    if (-not (Test-Path -LiteralPath $workerPath -PathType Leaf)) {
        throw "Crash recovery worker was not found: $workerPath"
    }

    $pwshPath = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshPath)) {
        $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    }

    $scheduledTaskAvailable = $false
    $runOnceAvailable = $false
    $errors = @()
    $statePath = Get-FelixStatePath

    if (
        (Test-FelixAdministrator) -and
        (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) -and
        (Get-Command New-ScheduledTaskAction -ErrorAction SilentlyContinue) -and
        (Get-Command New-ScheduledTaskTrigger -ErrorAction SilentlyContinue)
    ) {
        try {
            $action = New-ScheduledTaskAction -Execute $pwshPath -Argument "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$workerPath`" -StatePath `"$statePath`""
            $trigger = New-ScheduledTaskTrigger -AtStartup
            $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
            Register-ScheduledTask -TaskName $script:CrashGuardTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
            $scheduledTaskAvailable = $true
        }
        catch {
            $errors += "Scheduled task registration failed: $($_.Exception.Message)"
        }
    }

    try {
        $runOncePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
        if (-not (Test-Path -LiteralPath $runOncePath)) {
            New-Item -Path $runOncePath -Force | Out-Null
        }
        $command = "`"$pwshPath`" -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$workerPath`" -StatePath `"$statePath`""
        New-ItemProperty -LiteralPath $runOncePath -Name $script:CrashGuardRunOnceName -Value $command -PropertyType String -Force | Out-Null
        $runOnceAvailable = $true
    }
    catch {
        $errors += "RunOnce registration failed: $($_.Exception.Message)"
    }

    if (-not $scheduledTaskAvailable -and -not $runOnceAvailable) {
        throw ($errors -join [Environment]::NewLine)
    }

    return [ordered]@{
        available = $true
        scheduledTask = $scheduledTaskAvailable
        runOnce = $runOnceAvailable
        mode = if ($scheduledTaskAvailable) { 'StartupTaskWithRunOnceFallback' } else { 'RunOnceFallback' }
        workerPath = $workerPath
        errors = @($errors)
    }
}

function Remove-FelixCrashGuardInfrastructure {
    [CmdletBinding()]
    param()

    if (@(Get-FelixCrashGuard).Count -gt 0) {
        return
    }

    if (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:CrashGuardTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name $script:CrashGuardRunOnceName -Force -ErrorAction SilentlyContinue
}

function Register-FelixCrashGuard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OperationId,

        [Parameter(Mandatory)]
        [string]$HistoryId,

        [Parameter(Mandatory)]
        [string]$RuleId,

        [Parameter(Mandatory)]
        [string]$SnapshotPath,

        [Parameter(Mandatory)]
        [hashtable]$Before,

        [bool]$RequiresRestart
    )

    $infrastructure = Register-FelixCrashGuardInfrastructure
    $guard = [ordered]@{
        schemaVersion = '1.0'
        appVersion = $script:ModuleVersion
        operationId = $OperationId
        historyId = $HistoryId
        ruleId = $RuleId
        snapshotPath = $SnapshotPath
        beforeHash = Get-FelixObjectHash -Value $Before
        requiresRestart = $RequiresRestart
        state = 'Armed'
        attempts = 0
        createdAt = (Get-Date).ToString('o')
        appliedAt = $null
        completedAt = $null
        lastRecoveryError = $null
    }
    try {
        Write-FelixJsonAtomic -Path (Get-FelixCrashGuardPath -OperationId $OperationId) -Value $guard
    }
    catch {
        Remove-FelixCrashGuardInfrastructure
        throw
    }
    Add-FelixLog -Event 'crash_guard.armed' -Message 'Persistent crash-recovery guard armed before system modification.' -RuleId $RuleId -HistoryId $HistoryId -Data @{
        mode = $infrastructure.mode
        scheduledTask = $infrastructure.scheduledTask
        runOnce = $infrastructure.runOnce
    }
    Write-FelixRollbackJournal -HistoryId $HistoryId -RuleId $RuleId -Event 'crash_guard_armed' -SnapshotPath $SnapshotPath -Message $infrastructure.mode
    return $guard
}

function Set-FelixCrashGuardState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OperationId,

        [Parameter(Mandatory)]
        [ValidateSet('Armed', 'AwaitingBoot', 'Completed', 'ManualRecoveryRequired')]
        [string]$State,

        [string]$Message = ''
    )

    $path = Get-FelixCrashGuardPath -OperationId $OperationId
    $guard = Read-FelixJson -Path $path
    if (-not $guard) {
        throw "Crash guard for operation '$OperationId' was not found."
    }
    $guard.state = $State
    if ($State -eq 'AwaitingBoot') {
        $guard.appliedAt = (Get-Date).ToString('o')
    }
    if ($State -eq 'Completed') {
        $guard.completedAt = (Get-Date).ToString('o')
    }
    if ($Message) {
        $guard.lastRecoveryError = $Message
    }
    Write-FelixJsonAtomic -Path $path -Value $guard
    return $guard
}

function Complete-FelixCrashGuard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$OperationId
    )

    Set-FelixCrashGuardState -OperationId $OperationId -State 'Completed' | Out-Null
    Remove-Item -LiteralPath (Get-FelixCrashGuardPath -OperationId $OperationId) -Force -ErrorAction SilentlyContinue
    Remove-FelixCrashGuardInfrastructure
}

function Test-FelixUnexpectedShutdownSince {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetime]$Since
    )

    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'System'
            Id = 41, 1001, 6008
            StartTime = $Since
        } -MaxEvents 50 -ErrorAction Stop)
        return $events.Count -gt 0
    }
    catch {
        Add-FelixLog -Level Warning -Event 'crash_recovery.event_log' -Message $_.Exception.Message
        return $true
    }
}

function Get-FelixCrashRecoveryStatus {
    [CmdletBinding()]
    param()

    $guards = @(Get-FelixCrashGuard)
    $active = @($guards | Where-Object { $_.state -notin @('Completed', 'ManualRecoveryRequired') })
    $manual = @($guards | Where-Object { $_.state -eq 'ManualRecoveryRequired' })
    $latestRecovery = @(Get-FelixLog -Last 1000 | Where-Object {
        $_.event -in @('crash_recovery.rolled_back', 'crash_recovery.failed', 'crash_recovery.boot_confirmed')
    } | Select-Object -First 1)

    return [ordered]@{
        activeCount = $active.Count
        manualCount = $manual.Count
        available = $active.Count -eq 0 -and $manual.Count -eq 0
        message = if ($manual.Count -gt 0) {
            '存在自动恢复失败的操作，请在恢复中心手动处理。'
        }
        elseif ($active.Count -gt 0) {
            "已启用 $($active.Count) 项重启验证保险；异常关机后会自动恢复。"
        }
        else {
            '未发现待处理的崩溃恢复事务。'
        }
        latestRecovery = if ($latestRecovery.Count -gt 0) { $latestRecovery[0] } else { $null }
        guards = $guards
    }
}

function Invoke-FelixCrashRecovery {
    [CmdletBinding()]
    param()

    if (-not $script:OperationMutex.WaitOne(0)) {
        throw 'Another 稳优 StableTune operation is already running.'
    }

    $results = @()
    try {
        Initialize-FelixState
        $bootTime = Get-FelixLastBootTime
        foreach ($guard in @(Get-FelixCrashGuard)) {
            $operationId = [string]$guard.operationId
            try {
                if ($guard.state -eq 'Completed') {
                    Remove-Item -LiteralPath $guard.path -Force -ErrorAction SilentlyContinue
                    continue
                }
                if ($guard.state -eq 'ManualRecoveryRequired') {
                    $results += [ordered]@{ operationId = $operationId; status = 'ManualRecoveryRequired' }
                    continue
                }

                if ($guard.state -eq 'AwaitingBoot') {
                    $appliedAt = if ($guard.appliedAt) { [datetime]$guard.appliedAt } else { [datetime]$guard.createdAt }
                    if ($bootTime -le $appliedAt) {
                        $results += [ordered]@{ operationId = $operationId; status = 'AwaitingRestart' }
                        continue
                    }
                    if (-not (Test-FelixUnexpectedShutdownSince -Since $appliedAt)) {
                        Add-FelixHistoryEvent -Record ([ordered]@{
                            historyId = [string]$guard.historyId
                            operationId = [string]$guard.historyId
                            ruleId = [string]$guard.ruleId
                            ruleName = (Get-FelixRuleRequired -RuleId ([string]$guard.ruleId)).name
                            risk = (Get-FelixRuleRequired -RuleId ([string]$guard.ruleId)).risk
                            requiresRestart = $true
                            eventType = 'boot_confirmed'
                            status = 'Applied'
                            timestamp = (Get-Date).ToString('o')
                            message = 'Clean restart confirmed; optimization retained.'
                        })
                        Add-FelixLog -Event 'crash_recovery.boot_confirmed' -Message 'Clean restart confirmed; optimization retained.' -RuleId ([string]$guard.ruleId) -HistoryId ([string]$guard.historyId)
                        Remove-Item -LiteralPath $guard.path -Force
                        $results += [ordered]@{ operationId = $operationId; status = 'BootConfirmed' }
                        continue
                    }
                }

                $snapshot = Read-FelixSnapshot -Path ([string]$guard.snapshotPath)
                if ($guard.beforeHash -and (Get-FelixObjectHash -Value $snapshot.before) -ne [string]$guard.beforeHash) {
                    throw 'Crash-recovery snapshot integrity check failed.'
                }
                $rule = Get-FelixRuleRequired -RuleId ([string]$guard.ruleId)
                Invoke-FelixHandlerRestore -Rule $rule -Snapshot $snapshot -OperationId $operationId
                if (-not (Test-FelixHandlerRestored -Rule $rule -Snapshot $snapshot)) {
                    throw 'Crash-recovery restore verification failed.'
                }

                Add-FelixHistoryEvent -Record ([ordered]@{
                    historyId = [string]$guard.historyId
                    operationId = [string]$guard.historyId
                    ruleId = $rule.id
                    ruleName = $rule.name
                    risk = $rule.risk
                    requiresRestart = $rule.requiresRestart
                    eventType = 'crash_recovered'
                    status = 'CrashRecovered'
                    timestamp = (Get-Date).ToString('o')
                    message = 'An interrupted or crash-affected optimization was restored automatically after restart.'
                    snapshotPath = [string]$guard.snapshotPath
                })
                Add-FelixLog -Level Warning -Event 'crash_recovery.rolled_back' -Message 'Interrupted or crash-affected optimization restored automatically.' -RuleId $rule.id -HistoryId ([string]$guard.historyId)
                Write-FelixRollbackJournal -HistoryId ([string]$guard.historyId) -RuleId $rule.id -Event 'crash_recovery_rolled_back' -SnapshotPath ([string]$guard.snapshotPath) -Message 'Automatic crash recovery restored the original state.'
                Remove-Item -LiteralPath $guard.path -Force
                $results += [ordered]@{ operationId = $operationId; status = 'CrashRecovered' }
            }
            catch {
                $attempts = [int]$guard.attempts + 1
                $state = if ($attempts -ge 3) { 'ManualRecoveryRequired' } else { [string]$guard.state }
                $updated = Read-FelixJson -Path ([string]$guard.path)
                if ($updated) {
                    $updated.attempts = $attempts
                    $updated.state = $state
                    $updated.lastRecoveryError = $_.Exception.Message
                    Write-FelixJsonAtomic -Path ([string]$guard.path) -Value $updated
                }
                Add-FelixHistoryEvent -Record ([ordered]@{
                    historyId = [string]$guard.historyId
                    operationId = [string]$guard.historyId
                    ruleId = [string]$guard.ruleId
                    ruleName = (Get-FelixRuleRequired -RuleId ([string]$guard.ruleId)).name
                    risk = (Get-FelixRuleRequired -RuleId ([string]$guard.ruleId)).risk
                    requiresRestart = [bool]$guard.requiresRestart
                    eventType = 'crash_recovery_failed'
                    status = 'CrashRecoveryFailed'
                    timestamp = (Get-Date).ToString('o')
                    message = $_.Exception.Message
                    snapshotPath = [string]$guard.snapshotPath
                })
                Add-FelixLog -Level Error -Event 'crash_recovery.failed' -Message $_.Exception.Message -RuleId ([string]$guard.ruleId) -HistoryId ([string]$guard.historyId)
                $results += [ordered]@{ operationId = $operationId; status = $state; message = $_.Exception.Message }
            }
        }
    }
    finally {
        Remove-FelixCrashGuardInfrastructure
        $script:OperationMutex.ReleaseMutex()
    }
    return @($results)
}

function Clear-FelixRuntimeCaches {
    [CmdletBinding()]
    param()

    $script:RollbackCapabilityCache = $null
    $script:RollbackCapabilityCacheAt = $null
    $script:RollbackCapabilityCacheKey = $null
    $script:SystemStatusCache = $null
    $script:SystemStatusCacheAt = $null
    $script:SystemStatusCacheKey = $null
    Clear-FelixActivePowerSchemeCache
}

function Get-FelixRollbackPolicy {
    [CmdletBinding()]
    param()

    Initialize-FelixState
    $session = Get-FelixSession
    $requireSystemRestorePoint = $true

    if ($session -is [System.Collections.IDictionary]) {
        if ($session.Contains('requiresSystemRestorePoint')) {
            $requireSystemRestorePoint = [bool]$session.requiresSystemRestorePoint
        }
        elseif ($session.Contains('allowOptimizationWithoutRestorePoint')) {
            $requireSystemRestorePoint = -not [bool]$session.allowOptimizationWithoutRestorePoint
        }
    }

    return [ordered]@{
        requireSystemRestorePoint = $requireSystemRestorePoint
        mode = if ($requireSystemRestorePoint) { 'DualRollback' } else { 'IndependentSnapshot' }
        allowOptimizationWithoutRestorePoint = -not $requireSystemRestorePoint
    }
}

function Set-FelixRollbackPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool]$RequireSystemRestorePoint
    )

    Initialize-FelixState
    $session = Get-FelixSession
    $session.appVersion = $script:ModuleVersion
    $session.rollbackMode = if ($RequireSystemRestorePoint) { 'DualRollback' } else { 'IndependentSnapshot' }
    $session.requiresSystemRestorePoint = $RequireSystemRestorePoint
    $session.allowOptimizationWithoutRestorePoint = -not $RequireSystemRestorePoint
    $session.rollbackPolicyUpdatedAt = (Get-Date).ToString('o')
    Set-FelixSession -Session $session
    Clear-FelixRuntimeCaches

    Add-FelixLog -Event 'rollback.policy_changed' -Message "Rollback policy changed to $($session.rollbackMode)." -Data @{
        requireSystemRestorePoint = $RequireSystemRestorePoint
    }

    return Get-FelixRollbackPolicy
}

function Test-FelixRollbackCapability {
    [CmdletBinding()]
    param()

    try {
        Initialize-FelixState
        $snapshotRoot = Get-FelixStatePath 'snapshots'
        $probePath = Join-Path $snapshotRoot ".rollback-probe-$([guid]::NewGuid().ToString('N')).tmp"
        Set-Content -LiteralPath $probePath -Value 'ok' -Encoding ascii
        Remove-Item -LiteralPath $probePath -Force

        return [ordered]@{
            available = $true
            mode = 'IndependentSnapshot'
            snapshotRoot = $snapshotRoot
            requiresSystemRestorePoint = $false
            message = 'Independent per-operation rollback snapshots are writable and available.'
        }
    }
    catch {
        return [ordered]@{
            available = $false
            mode = 'IndependentSnapshot'
            snapshotRoot = Get-FelixStatePath 'snapshots'
            requiresSystemRestorePoint = $false
            message = $_.Exception.Message
        }
    }
}

function Test-FelixDualRollbackCapability {
    [CmdletBinding()]
    param(
        [switch]$EnsureRestorePoint,
        [switch]$Force
    )

    Initialize-FelixState
    $policy = Get-FelixRollbackPolicy
    $cacheKey = "$(Get-FelixStatePath)|$($policy.mode)"
    if (
        -not $Force -and
        -not $EnsureRestorePoint -and
        $script:RollbackCapabilityCache -and
        $script:RollbackCapabilityCacheAt -and
        $script:RollbackCapabilityCacheKey -eq $cacheKey -and
        ((Get-Date) - $script:RollbackCapabilityCacheAt).TotalSeconds -lt $script:UiCapabilityCacheSeconds
    ) {
        return $script:RollbackCapabilityCache
    }

    $snapshot = Test-FelixRollbackCapability
    if (-not $policy.requireSystemRestorePoint) {
        $available = [bool]$snapshot.available
        $message = if ($available) {
            'Independent rollback snapshots are available; the Windows system restore point is not required by the current policy.'
        }
        else {
            "Independent rollback snapshots are unavailable: $($snapshot.message)"
        }

        $session = Get-FelixSession
        $session.appVersion = $script:ModuleVersion
        $session.rollbackMode = 'IndependentSnapshot'
        $session.requiresSystemRestorePoint = $false
        $session.restorePointAvailable = $false
        $session.restorePointId = $null
        $session.restorePointCreatedAt = $null
        $session.allowOptimizationWithoutRestorePoint = $true
        Set-FelixSession -Session $session

        $result = [ordered]@{
            available = $available
            mode = 'IndependentSnapshot'
            requiresSystemRestorePoint = $false
            snapshotAvailable = [bool]$snapshot.available
            snapshotRoot = [string]$snapshot.snapshotRoot
            snapshotMessage = [string]$snapshot.message
            restorePointAvailable = $false
            restorePointId = $null
            restorePointCreatedAt = $null
            restorePointMessage = 'Windows system restore points are intentionally excluded from execution checks by policy.'
            message = $message
        }
        if (-not $EnsureRestorePoint) {
            $script:RollbackCapabilityCache = $result
            $script:RollbackCapabilityCacheAt = Get-Date
            $script:RollbackCapabilityCacheKey = $cacheKey
        }
        return $result
    }

    $restorePointAvailable = $false
    $restorePointId = $null
    $restorePointCreatedAt = $null
    $restorePointMessage = ''
    $points = @()

    try {
        if ($EnsureRestorePoint -and -not (Test-FelixAdministrator)) {
            $session = Request-FelixSessionRestorePoint
            if ($session -and $session.restorePointAvailable) {
                $restorePointAvailable = $true
                $restorePointId = [string]$session.restorePointId
                $restorePointCreatedAt = [string]$session.restorePointCreatedAt
                $restorePointMessage = 'System protection reported an available restore point after elevation.'
            }
        }
        else {
            $points = @(Get-FelixRestorePoint)
            if ($EnsureRestorePoint -and $points.Count -eq 0) {
                Invoke-FelixRestorePointRequestLocal | Out-Null
                $points = @(Get-FelixRestorePoint)
            }

            if ($points.Count -gt 0) {
                $latest = $points[0]
                $restorePointAvailable = $true
                $restorePointId = [string]$latest.SequenceNumber
                $restorePointCreatedAt = [string]$latest.CreationTime
                $restorePointMessage = "System protection returned $($points.Count) restore point(s)."
            }
            else {
                $restorePointMessage = if ($EnsureRestorePoint) {
                    'Windows did not return a usable system restore point after creation was requested.'
                }
                else {
                    'No Windows system restore point is currently available.'
                }
            }
        }
    }
    catch {
        $restorePointMessage = $_.Exception.Message
    }

    $available = [bool]$snapshot.available -and [bool]$restorePointAvailable
    $message = if ($available) {
        'Independent snapshots and a Windows system restore point are both available.'
    }
    elseif (-not $snapshot.available) {
        "Independent rollback snapshots are unavailable: $($snapshot.message)"
    }
    else {
        "Windows system restore protection is unavailable: $restorePointMessage"
    }

    $session = Get-FelixSession
    $session.appVersion = $script:ModuleVersion
    $session.rollbackMode = 'DualRollback'
    $session.requiresSystemRestorePoint = $true
    $session.restorePointAvailable = [bool]$restorePointAvailable
    $session.restorePointId = $restorePointId
    $session.restorePointCreatedAt = $restorePointCreatedAt
    $session.allowOptimizationWithoutRestorePoint = $false
    Set-FelixSession -Session $session

    $result = [ordered]@{
        available = $available
        mode = 'DualRollback'
        requiresSystemRestorePoint = $true
        snapshotAvailable = [bool]$snapshot.available
        snapshotRoot = [string]$snapshot.snapshotRoot
        snapshotMessage = [string]$snapshot.message
        restorePointAvailable = [bool]$restorePointAvailable
        restorePointId = $restorePointId
        restorePointCreatedAt = $restorePointCreatedAt
        restorePointMessage = $restorePointMessage
        message = $message
    }
    if (-not $EnsureRestorePoint) {
        $script:RollbackCapabilityCache = $result
        $script:RollbackCapabilityCacheAt = Get-Date
        $script:RollbackCapabilityCacheKey = $cacheKey
    }
    return $result
}

function Get-FelixFileHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function ConvertTo-FelixGuidText {
    param(
        [Parameter(Mandatory)]
        [object]$Value,

        [ValidateSet('D', 'B', 'N', 'P')]
        [string]$Format = 'D'
    )

    $guid = if ($Value -is [guid]) {
        [guid]$Value
    }
    else {
        [guid]::Parse([string]$Value)
    }
    return $guid.ToString($Format)
}

function Test-FelixSnapshotIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$ExpectedHash
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Rollback snapshot '$Path' is missing."
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedHash)) {
        return $true
    }

    $actual = Get-FelixFileHash -Path $Path
    if ($actual -ne $ExpectedHash) {
        throw "Rollback snapshot integrity check failed for '$Path'."
    }
    return $true
}

function Get-FelixRule {
    [CmdletBinding()]
    param(
        [string]$RuleId,
        [string]$Category
    )

    if ($null -eq $script:RuleCache) {
        $catalog = Get-Content -LiteralPath $script:CatalogPath -Raw | ConvertFrom-Json -AsHashtable
        $details = Get-Content -LiteralPath $script:RuleDetailsPath -Raw | ConvertFrom-Json -AsHashtable
        $guidance = Get-Content -LiteralPath $script:RuleGuidancePath -Raw | ConvertFrom-Json -AsHashtable
        $rules = @()
        foreach ($catalogRule in @($catalog.rules)) {
            $rule = [ordered]@{}
            foreach ($key in $catalogRule.Keys) {
                $rule[$key] = $catalogRule[$key]
            }
            $rule['schemaVersion'] = [string]$catalog.schemaVersion
            if ($details.rules.ContainsKey([string]$rule.id)) {
                foreach ($key in $details.rules[[string]$rule.id].Keys) {
                    $rule[$key] = $details.rules[[string]$rule.id][$key]
                }
            }
            if ($guidance.rules.ContainsKey([string]$rule.id)) {
                foreach ($key in $guidance.rules[[string]$rule.id].Keys) {
                    $rule[$key] = $guidance.rules[[string]$rule.id][$key]
                }
            }
            $rules += $rule
        }
        $script:RuleCache = $rules
    }

    $result = @($script:RuleCache)
    if ($RuleId) {
        $result = @($result | Where-Object { $_.id -eq $RuleId })
    }
    if ($Category) {
        $result = @($result | Where-Object { $_.category -eq $Category })
    }

    return $result
}

function Get-FelixRuleRequired {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RuleId
    )

    $rule = @(Get-FelixRule -RuleId $RuleId)
    if ($rule.Count -ne 1) {
        throw "Rule '$RuleId' was not found."
    }
    return $rule[0]
}

function Get-FelixApplicabilityCatalog {
    [CmdletBinding()]
    param()

    if ($null -eq $script:ApplicabilityCache) {
        $script:ApplicabilityCache = Get-Content -LiteralPath $script:RuleApplicabilityPath -Raw | ConvertFrom-Json -AsHashtable
    }
    return $script:ApplicabilityCache
}

function New-FelixApplicabilityConditionResult {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Pass', 'Conditional', 'Fail', 'Unknown')]
        [string]$State,

        [Parameter(Mandatory)]
        [string]$Message
    )

    return [ordered]@{
        state = $State
        message = $Message
    }
}

function Test-FelixApplicabilityCondition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Condition,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Hardware
    )

    $mode = if ($Condition.ContainsKey('mode')) { [string]$Condition.mode } else { 'hard' }
    switch ([string]$Condition.type) {
        'osFamily' {
            if ([int]$Hardware.osBuildNumber -le 0) {
                return New-FelixApplicabilityConditionResult Unknown '无法读取 Windows 内部版本。'
            }
            $family = if ([int]$Hardware.osBuildNumber -ge 22000) { 'Windows 11' } else { 'Windows 10' }
            if ($family -in @($Condition.values)) {
                return New-FelixApplicabilityConditionResult Pass "检测到 $family。"
            }
            return New-FelixApplicabilityConditionResult Fail "该规则仅适用于 $((@($Condition.values) -join '、'))。"
        }
        'architecture' {
            $architecture = [string]$Hardware.architecture
            if ([string]::IsNullOrWhiteSpace($architecture) -or $architecture -eq 'Unknown') {
                return New-FelixApplicabilityConditionResult Unknown '无法确认系统架构。'
            }
            if ($architecture -in @($Condition.values)) {
                return New-FelixApplicabilityConditionResult Pass "系统架构为 $architecture。"
            }
            return New-FelixApplicabilityConditionResult Fail "系统架构 $architecture 不在支持范围内。"
        }
        'minimumBuild' {
            if ($Hardware.osBuildNumber -le 0) {
                return New-FelixApplicabilityConditionResult Unknown '无法读取 Windows 内部版本。'
            }
            if ([int]$Hardware.osBuildNumber -ge [int]$Condition.value) {
                return New-FelixApplicabilityConditionResult Pass "Windows 内部版本 $($Hardware.osBuildNumber) 满足最低要求。"
            }
            return New-FelixApplicabilityConditionResult Fail "需要 Windows 内部版本 $($Condition.value) 或更高。"
        }
        'gpuVendor' {
            $vendors = @($Hardware.gpu | ForEach-Object { [string]$_.applicabilityVendor } | Where-Object { $_ -and $_ -ne 'Unknown' } | Sort-Object -Unique)
            if ($vendors.Count -eq 0) {
                return New-FelixApplicabilityConditionResult Unknown '无法读取 GPU 厂商。'
            }
            $matched = @($vendors | Where-Object { $_ -in @($Condition.values) })
            if ($matched.Count -gt 0) {
                return New-FelixApplicabilityConditionResult Pass "检测到支持的 GPU 厂商：$($matched -join '、')。"
            }
            return New-FelixApplicabilityConditionResult Fail "检测到 $($vendors -join '、')，不满足要求。"
        }
        'wddmMinimum' {
            $wddm = if ($Hardware.ContainsKey('wddmVersion')) {
                $Hardware.wddmVersion
            }
            else {
                Get-FelixWddmVersion
            }
            if ($null -eq $wddm) {
                return New-FelixApplicabilityConditionResult Unknown '无法从系统公开接口确认 WDDM 版本。'
            }
            $requiredWddm = [version]([string]::Format(
                [Globalization.CultureInfo]::InvariantCulture,
                '{0}',
                $Condition.value
            ))
            if ([version]$wddm -ge $requiredWddm) {
                return New-FelixApplicabilityConditionResult Pass "WDDM 版本 $wddm 满足要求。"
            }
            return New-FelixApplicabilityConditionResult Fail "WDDM 版本 $wddm 低于要求的 $($Condition.value)。"
        }
        'systemType' {
            $systemType = [string]$Hardware.systemType
            if ([string]::IsNullOrWhiteSpace($systemType) -or $systemType -eq 'Unknown') {
                return New-FelixApplicabilityConditionResult Unknown '无法确认设备是台式机还是笔记本。'
            }
            if ($systemType -in @($Condition.values)) {
                return New-FelixApplicabilityConditionResult Pass "设备类型为 $systemType。"
            }
            if ($mode -eq 'prefer') {
                return New-FelixApplicabilityConditionResult Conditional "设备类型为 $systemType，功耗和散热代价需要人工确认。"
            }
            return New-FelixApplicabilityConditionResult Fail "设备类型 $systemType 不满足要求。"
        }
        'systemDiskSsd' {
            if ($null -eq $Hardware.systemDiskIsSsd) {
                return New-FelixApplicabilityConditionResult Unknown '无法确认系统盘介质类型。'
            }
            $matches = [bool]$Hardware.systemDiskIsSsd -eq [bool]$Condition.value
            if ($matches) {
                return New-FelixApplicabilityConditionResult Pass "系统盘检测为 $(if ($Hardware.systemDiskIsSsd) { 'SSD/NVMe' } else { '机械硬盘' })。"
            }
            if ($mode -eq 'prefer') {
                return New-FelixApplicabilityConditionResult Conditional '系统盘类型不适合该优化，预计收益有限或可能变慢。'
            }
            return New-FelixApplicabilityConditionResult Fail '系统盘类型不满足该优化要求。'
        }
        'minimumMemoryGiB' {
            if ([uint64]$Hardware.totalPhysicalMemoryBytes -le 0) {
                return New-FelixApplicabilityConditionResult Unknown '无法读取物理内存总量。'
            }
            $memoryGiB = [double]$Hardware.totalPhysicalMemoryBytes / 1GB
            if ($memoryGiB -ge [double]$Condition.value) {
                return New-FelixApplicabilityConditionResult Pass ("物理内存 {0:N1} GiB 满足建议。" -f $memoryGiB)
            }
            if ($mode -eq 'prefer') {
                return New-FelixApplicabilityConditionResult Conditional ("物理内存 {0:N1} GiB 低于建议值 {1} GiB。" -f $memoryGiB, [double]$Condition.value)
            }
            return New-FelixApplicabilityConditionResult Fail "物理内存低于 $($Condition.value) GiB。"
        }
        'fileSystem' {
            $fileSystem = [string]$Hardware.systemDiskFileSystem
            if ([string]::IsNullOrWhiteSpace($fileSystem) -or $fileSystem -eq 'Unknown') {
                return New-FelixApplicabilityConditionResult Unknown '无法读取系统盘文件系统。'
            }
            if ($fileSystem -in @($Condition.values)) {
                return New-FelixApplicabilityConditionResult Pass "系统盘文件系统为 $fileSystem。"
            }
            return New-FelixApplicabilityConditionResult Fail "系统盘文件系统 $fileSystem 不满足要求。"
        }
        'printerCountMaximum' {
            if ($null -eq $Hardware.printerCount) {
                return New-FelixApplicabilityConditionResult Unknown '无法枚举打印机和扫描设备。'
            }
            if ([int]$Hardware.printerCount -le [int]$Condition.value) {
                return New-FelixApplicabilityConditionResult Pass '当前未检测到打印设备。'
            }
            if ($mode -eq 'prefer') {
                return New-FelixApplicabilityConditionResult Conditional "检测到 $($Hardware.printerCount) 个打印设备，停用后台服务会中断相关功能。"
            }
            return New-FelixApplicabilityConditionResult Fail '检测到打印设备。'
        }
        'domainJoined' {
            if ($null -eq $Hardware.isDomainJoined) {
                return New-FelixApplicabilityConditionResult Unknown '无法确认设备是否加入域。'
            }
            $matches = [bool]$Hardware.isDomainJoined -eq [bool]$Condition.value
            if ($matches) {
                return New-FelixApplicabilityConditionResult Pass '设备管理模式符合该规则的适用条件。'
            }
            if ($mode -eq 'prefer') {
                return New-FelixApplicabilityConditionResult Conditional '设备已加入域，必须先遵循组织的诊断、遥测和打印策略。'
            }
            return New-FelixApplicabilityConditionResult Fail '设备管理状态不满足要求。'
        }
        'antiCheatExpertInstalled' {
            if ($null -eq $Hardware.antiCheatExpertInstalled) {
                return New-FelixApplicabilityConditionResult Unknown '无法确认腾讯 ACE 反作弊是否存在。'
            }
            if ([bool]$Hardware.antiCheatExpertInstalled) {
                return New-FelixApplicabilityConditionResult Pass '检测到腾讯 ACE 反作弊组件。'
            }
            return New-FelixApplicabilityConditionResult Fail '未检测到腾讯 ACE 反作弊组件，该规则不适用。'
        }
        'selection' {
            return New-FelixApplicabilityConditionResult Conditional "该规则需要选择具体$(if ($Condition.kind -eq 'Device') { '设备' } else { '目标' })后进行预检。"
        }
        'userDecision' {
            $message = if ($Condition.ContainsKey('message')) { [string]$Condition.message } else { '该规则依赖用户使用场景，需要人工确认。' }
            return New-FelixApplicabilityConditionResult Conditional $message
        }
        default {
            return New-FelixApplicabilityConditionResult Unknown "未知适用性条件 '$($Condition.type)'。"
        }
    }
}

function Get-FelixRuleApplicability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Rule,

        [System.Collections.IDictionary]$Hardware
    )

    $catalog = Get-FelixApplicabilityCatalog
    $ruleId = [string]$Rule.id
    if (-not $catalog.rules.ContainsKey($ruleId)) {
        return [ordered]@{
            ruleId = $ruleId
            status = 'Unknown'
            label = '无法判断'
            confidence = 'Low'
            message = '该规则尚未配置适用性审查数据。'
            reasons = @('缺少适用性配置。')
            evidence = @()
            reviewedAt = [string]$catalog.reviewedAt
            batchEligible = $false
        }
    }

    $ruleApplicability = $catalog.rules[$ruleId]
    $profileName = [string]$ruleApplicability.profile
    if (-not $catalog.profiles.ContainsKey($profileName)) {
        return [ordered]@{
            ruleId = $ruleId
            status = 'Unknown'
            label = '无法判断'
            confidence = 'Low'
            message = "适用性配置引用了不存在的方案 '$profileName'。"
            reasons = @('适用性配置损坏。')
            evidence = @()
            reviewedAt = [string]$catalog.reviewedAt
            batchEligible = $false
        }
    }

    $profile = $catalog.profiles[$profileName]
    $hardware = if ($null -ne $Hardware) {
        [hashtable]$Hardware
    }
    else {
        [hashtable](Get-FelixHardwareInventory)
    }
    $reasons = @()
    $hasHardFailure = $false
    $hasUnknown = $false
    $hasConditional = $false

    foreach ($condition in @($profile.conditions)) {
        $result = Test-FelixApplicabilityCondition -Condition $condition -Hardware $hardware
        if ($result.state -eq 'Pass') {
            continue
        }
        $reasons += [string]$result.message
        switch ($result.state) {
            'Fail' { $hasHardFailure = $true }
            'Unknown' {
                if ($condition.ContainsKey('mode') -and [string]$condition.mode -eq 'prefer') {
                    $hasConditional = $true
                }
                else {
                    $hasUnknown = $true
                }
            }
            'Conditional' { $hasConditional = $true }
        }
    }

    $status = if ($hasHardFailure) {
        'NotApplicable'
    }
    elseif ($hasUnknown) {
        'Unknown'
    }
    elseif ($hasConditional) {
        'Conditional'
    }
    else {
        'Applicable'
    }

    $label = switch ($status) {
        'Applicable' { '适用本机' }
        'Conditional' { '有条件适用' }
        'NotApplicable' { '不适用本机' }
        default { '无法判断' }
    }
    $confidence = switch ($status) {
        'Applicable' { 'High' }
        'NotApplicable' { 'High' }
        'Conditional' { 'Medium' }
        default { 'Low' }
    }
    $message = if ($reasons.Count -gt 0) {
        $reasons -join ' '
    }
    else {
        '本机条件满足该规则的技术要求，实际收益仍需通过对照测试确认。'
    }

    $evidence = @()
    foreach ($evidenceId in @($profile.evidenceIds)) {
        if (-not $catalog.evidence.ContainsKey([string]$evidenceId)) {
            continue
        }
        $item = $catalog.evidence[[string]$evidenceId]
        $evidence += [ordered]@{
            id = [string]$evidenceId
            title = [string]$item.title
            url = [string]$item.url
            kind = [string]$item.kind
            supports = [string]$item.supports
        }
    }
    return [ordered]@{
        ruleId = $ruleId
        status = $status
        label = $label
        confidence = $confidence
        message = $message
        reasons = @($reasons)
        evidence = @($evidence)
        reviewedAt = [string]$catalog.reviewedAt
        batchEligible = [bool]$ruleApplicability.batchEligible -and $status -in @('Applicable', 'Conditional')
    }
}

function Test-FelixAdministrator {
    [CmdletBinding()]
    param()

    if ($env:OS -ne 'Windows_NT') {
        return $false
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FelixVisibleMemoryBytes {
    [CmdletBinding()]
    param()

    try {
        if (-not ('FelixOptimizer.NativeMemoryStatus' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace FelixOptimizer
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public class NativeMemoryStatus
    {
        public uint Length;
        public uint MemoryLoad;
        public ulong TotalPhysical;
        public ulong AvailablePhysical;
        public ulong TotalPageFile;
        public ulong AvailablePageFile;
        public ulong TotalVirtual;
        public ulong AvailableVirtual;
        public ulong AvailableExtendedVirtual;

        public NativeMemoryStatus()
        {
            Length = (uint)Marshal.SizeOf(typeof(NativeMemoryStatus));
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GlobalMemoryStatusEx([In, Out] NativeMemoryStatus buffer);

        public static ulong GetTotalPhysicalBytes()
        {
            NativeMemoryStatus status = new NativeMemoryStatus();
            return GlobalMemoryStatusEx(status) ? status.TotalPhysical : 0;
        }
    }
}
'@
        }
        return [uint64][FelixOptimizer.NativeMemoryStatus]::GetTotalPhysicalBytes()
    }
    catch {
        return [uint64]0
    }
}

function Get-FelixStorageSummary {
    [CmdletBinding()]
    param()

    $result = [ordered]@{
        isSsd = $null
        fileSystem = 'Unknown'
        model = 'Unknown'
        busType = 'Unknown'
    }

    try {
        $partition = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop | Select-Object -First 1
        $disk = $partition | Get-Disk -ErrorAction Stop
        $physical = $disk | Get-PhysicalDisk -ErrorAction Stop
        $mediaType = [string]$physical.MediaType
        $busType = [string]$physical.BusType
        $result.isSsd = $mediaType -eq 'SSD' -or $busType -eq 'NVMe'
        $result.model = [string]$physical.FriendlyName
        $result.busType = $busType
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.storage_media' -Message $_.Exception.Message
    }

    try {
        $volume = Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop | Select-Object -First 1
        $result.fileSystem = [string]$volume.FileSystem
        if ($result.model -eq 'Unknown') {
            $result.model = [string]$volume.FileSystemLabel
        }
    }
    catch {
        try {
            $logicalDisk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction Stop | Select-Object -First 1
            $result.fileSystem = [string]$logicalDisk.FileSystem
        }
        catch {
            Add-FelixLog -Level Warning -Event 'hardware.storage_filesystem' -Message $_.Exception.Message
        }
    }

    return $result
}

function Get-FelixPrinterCount {
    [CmdletBinding()]
    param()

    try {
        return @(Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop).Count
    }
    catch {
        try {
            return @(Get-Printer -ErrorAction Stop).Count
        }
        catch {
            return $null
        }
    }
}

function Get-FelixPointingDeviceCount {
    [CmdletBinding()]
    param()

    try {
        return @(Get-PnpDevice -Class Mouse -Status OK -ErrorAction Stop).Count
    }
    catch {
        try {
            return @(Get-CimInstance -ClassName Win32_PointingDevice -ErrorAction Stop).Count
        }
        catch {
            return $null
        }
    }
}

function Get-FelixWddmVersion {
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    $cachePath = Get-FelixStatePath 'hardware-wddm.json'
    $cacheKey = $null
    try {
        $osBuild = [Environment]::OSVersion.Version.Build
        $graphicsDrivers = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -ErrorAction Stop
        $dxgKrnlVersion = if ($null -ne $graphicsDrivers.DxgKrnlVersion) {
            [int]$graphicsDrivers.DxgKrnlVersion
        }
        else {
            0
        }
        $cacheKey = "$osBuild|$dxgKrnlVersion"
    }
    catch {
        $cacheKey = [Environment]::OSVersion.Version.Build.ToString()
    }

    if (-not $Force -and $null -ne $script:WddmCache) {
        return $script:WddmCache
    }

    if (-not $Force -and (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        try {
            $cache = Read-FelixJson -Path $cachePath
            $detectedAt = if ($cache.detectedAt) { [datetime]$cache.detectedAt } else { [datetime]::MinValue }
            if (
                $cache.version -and
                [string]$cache.cacheKey -eq [string]$cacheKey -and
                ((Get-Date) - $detectedAt).TotalSeconds -lt $script:WddmCacheSeconds
            ) {
                $script:WddmCache = [version]([string]$cache.version)
                $script:WddmCacheAt = $detectedAt
                return $script:WddmCache
            }
        }
        catch {
            Add-FelixLog -Level Warning -Event 'hardware.wddm_cache' -Message $_.Exception.Message
        }
    }

    try {
        $graphicsDrivers = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\FeatureSetUsage' -ErrorAction Stop
        $minimum = if ($null -ne $graphicsDrivers.WddmVersion_Min) { [int]$graphicsDrivers.WddmVersion_Min } else { 0 }
        $maximum = if ($null -ne $graphicsDrivers.WddmVersion_Max) { [int]$graphicsDrivers.WddmVersion_Max } else { 0 }
        if ($minimum -gt 0 -and $minimum -eq $maximum) {
            $registryVersion = ConvertFrom-FelixWddmRegistryValue -Value $maximum
            if ($null -ne $registryVersion) {
                $script:WddmCache = $registryVersion
                $script:WddmCacheAt = Get-Date
                Save-FelixWddmCache -Version $registryVersion -Source 'registry' -CacheKey $cacheKey -RawValue $maximum
                return $script:WddmCache
            }
        }
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.wddm_registry' -Message $_.Exception.Message
    }

    $reportPath = Join-Path ([IO.Path]::GetTempPath()) "felix-dxdiag-$([guid]::NewGuid().ToString('N')).txt"
    $process = $null
    try {
        $dxdiagPath = Join-Path $env:SystemRoot 'System32\dxdiag.exe'
        if (-not (Test-Path -LiteralPath $dxdiagPath)) {
            return $null
        }

        $process = Start-Process -FilePath $dxdiagPath -ArgumentList @('/t', $reportPath) -WindowStyle Hidden -PassThru
        if (-not $process.WaitForExit(12000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            return $null
        }
        if (-not (Test-Path -LiteralPath $reportPath)) {
            return $null
        }

        $content = Get-Content -LiteralPath $reportPath -Raw -Encoding Unicode -ErrorAction Stop
        $versions = @(
            [regex]::Matches($content, '(?im)WDDM\s+(\d+(?:\.\d+)?)') |
                ForEach-Object { [version]$_.Groups[1].Value }
        )
        if ($versions.Count -eq 0) {
            return $null
        }

        $script:WddmCache = ($versions | Sort-Object -Descending | Select-Object -First 1)
        $script:WddmCacheAt = Get-Date
        Save-FelixWddmCache -Version $script:WddmCache -Source 'dxdiag' -CacheKey $cacheKey -RawValue 0
        return $script:WddmCache
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.wddm' -Message $_.Exception.Message
        return $null
    }
    finally {
        if ($process -and -not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
    }
}

function ConvertFrom-FelixWddmRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Value
    )

    if ($Value -le 0) {
        return $null
    }

    # Windows encodes WDDM major/minor in the 10-bit and 6-bit fields.
    $major = $Value -shr 10
    $minor = ($Value -shr 6) -band 0xF
    if ($major -lt 1 -or $major -gt 9 -or $minor -lt 0 -or $minor -gt 9) {
        return $null
    }

    return [version]"$major.$minor"
}

function Save-FelixWddmCache {
    param(
        [Parameter(Mandatory)]
        [version]$Version,

        [Parameter(Mandatory)]
        [string]$Source,

        [string]$CacheKey,

        [int]$RawValue = 0
    )

    try {
        Initialize-FelixState
        Write-FelixJsonAtomic -Path (Get-FelixStatePath 'hardware-wddm.json') -Value ([ordered]@{
            version = $Version.ToString()
            source = $Source
            cacheKey = $CacheKey
            rawValue = $RawValue
            detectedAt = (Get-Date).ToString('o')
        })
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.wddm_cache_write' -Message $_.Exception.Message
    }
}

function Get-FelixDeviceSecurityStatus {
    [CmdletBinding()]
    param()

    $result = [ordered]@{
        vbsStatus = 'Unknown'
        vbsStatusText = '无法读取'
        hvciConfigured = $null
        hvciRunning = $null
        hypervisorLaunchType = 'Unknown'
        assessment = 'Unknown'
        message = '无法从 Windows 公开接口确认 VBS/HVCI 状态。'
    }

    try {
        $deviceGuard = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName 'Win32_DeviceGuard' -ErrorAction Stop | Select-Object -First 1
        $vbsCode = [int]$deviceGuard.VirtualizationBasedSecurityStatus
        $result.vbsStatus = switch ($vbsCode) {
            0 { 'Off' }
            1 { 'EnabledNotRunning' }
            2 { 'Running' }
            default { 'Unknown' }
        }
        $result.vbsStatusText = switch ([string]$result.vbsStatus) {
            'Off' { '未启用' }
            'EnabledNotRunning' { '已配置但未运行' }
            'Running' { '运行中' }
            default { '无法读取' }
        }
        $runningServices = @($deviceGuard.SecurityServicesRunning)
        $result.hvciRunning = 2 -in $runningServices
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.device_guard' -Message $_.Exception.Message
    }

    try {
        $hvci = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -ErrorAction Stop
        $result.hvciConfigured = [int]$hvci.Enabled -eq 1
    }
    catch {
        $result.hvciConfigured = $null
    }

    try {
        $ciState = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\State' -ErrorAction Stop
        if ($null -ne $ciState.HVCIEnabled) {
            $result.hvciRunning = [int]$ciState.HVCIEnabled -eq 1
        }
    }
    catch {
        # The volatile CI state key is not available on all Windows editions.
    }

    if (Get-Command bcdedit.exe -ErrorAction SilentlyContinue) {
        try {
            $bcd = Invoke-FelixNative -FilePath 'bcdedit.exe' -ArgumentList @('/enum', '{current}')
            $match = [regex]::Match($bcd, '(?im)^\s*hypervisorlaunchtype\s+(\S+)\s*$')
            if ($match.Success) {
                $result.hypervisorLaunchType = $match.Groups[1].Value
            }
        }
        catch {
            Add-FelixLog -Level Warning -Event 'hardware.hypervisor_launch_type' -Message $_.Exception.Message
        }
    }

    if ($result.hvciConfigured -eq $true -and $result.hvciRunning -eq $true) {
        $result.assessment = 'Active'
        $result.message = '检测到内存完整性（HVCI）正在运行。若游戏提示 VTD/HVCI 冲突，应先更新游戏、反作弊和驱动，不应由优化器自动关闭安全功能。'
    }
    elseif ($result.hvciConfigured -eq $true -and $result.hvciRunning -eq $false) {
        $result.assessment = 'ConfiguredNotRunning'
        $result.message = 'HVCI 已配置但当前未运行，通常需要重启，或由不兼容驱动、启动配置阻止。'
    }
    elseif ($result.hvciConfigured -eq $false -or $result.hvciRunning -eq $false) {
        $result.assessment = 'Inactive'
        $result.message = '当前未检测到内存完整性运行。若游戏要求 VTD/HVCI，请优先在 Windows 安全中心启用并确认驱动兼容。'
    }

    return $result
}

function Test-FelixAntiCheatExpertPresence {
    [CmdletBinding()]
    param()

    $programRoots = @(
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramW6432
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    $paths = @($programRoots | ForEach-Object { Join-Path $_ 'AntiCheatExpert' })

    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path -PathType Container) {
            return $true
        }
    }

    try {
        return @(
            Get-Process -Name 'SGuard64', 'SGuardSvc64' -ErrorAction SilentlyContinue
        ).Count -gt 0
    }
    catch {
        return $false
    }
}

function Get-FelixPowerSettingValueSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$SchemeGuid,

        [Parameter(Mandatory)]
        [string]$SubgroupGuid,

        [Parameter(Mandatory)]
        [string]$SettingGuid,

        [Parameter(Mandatory)]
        [ValidateSet('ACSettingIndex', 'DCSettingIndex')]
        [string]$ValueName,

        [switch]$UseDefaultFallback
    )

    $schemePath = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$SchemeGuid\$SubgroupGuid\$SettingGuid"
    $snapshot = Get-RegistryValueSnapshot -Path $schemePath -Name $ValueName
    if ($snapshot.exists -or -not $UseDefaultFallback) {
        return $snapshot
    }

    $defaultPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\$SubgroupGuid\$SettingGuid\DefaultPowerSchemeValues\$SchemeGuid"
    return Get-RegistryValueSnapshot -Path $defaultPath -Name $ValueName
}

function Test-FelixPowerSchemeGuidExists {
    param(
        [Parameter(Mandatory)]
        [string]$SchemeGuid
    )

    try {
        $output = Invoke-FelixNative -FilePath 'powercfg.exe' -ArgumentList @('/list')
        return $output -match [regex]::Escape($SchemeGuid)
    }
    catch {
        return $false
    }
}

function Get-FelixHeterogeneousPowerBaseline {
    [CmdletBinding()]
    param()

    $definitions = @(
        [ordered]@{
            name = 'HETEROPOLICY'
            label = '生效的异类策略'
            subgroupGuid = '54533251-82be-4824-96c1-47b60b740d00'
            settingGuid = '7f2f5cfa-f10c-4823-b5e1-e93ae85f46b5'
        },
        [ordered]@{
            name = 'SCHEDPOLICY'
            label = '异类线程调度策略'
            subgroupGuid = '54533251-82be-4824-96c1-47b60b740d00'
            settingGuid = '93b8b6dc-0698-4d1c-9ee4-0644e900c85d'
        },
        [ordered]@{
            name = 'SHORTSCHEDPOLICY'
            label = '异类短运行线程调度策略'
            subgroupGuid = '54533251-82be-4824-96c1-47b60b740d00'
            settingGuid = 'bae08b81-2d5e-4688-ad6a-13243356654b'
        },
        [ordered]@{
            name = 'PERFBOOSTMODE'
            label = '处理器性能提升模式'
            subgroupGuid = '54533251-82be-4824-96c1-47b60b740d00'
            settingGuid = 'be337238-0d82-4146-a960-4f3749d470c7'
        }
    )

    $candidates = @(
        [ordered]@{ guid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'; label = 'Windows 内置高性能方案' },
        [ordered]@{ guid = '381b4222-f694-41f0-9685-ff5bb260df2e'; label = 'Windows 内置平衡方案' }
    )

    foreach ($candidate in $candidates) {
        if (-not (Test-FelixPowerSchemeGuidExists -SchemeGuid $candidate.guid)) {
            continue
        }

        $settings = @()
        $complete = $true
        foreach ($definition in $definitions) {
            $ac = Get-FelixPowerSettingValueSnapshot -SchemeGuid $candidate.guid -SubgroupGuid $definition.subgroupGuid -SettingGuid $definition.settingGuid -ValueName 'ACSettingIndex' -UseDefaultFallback
            $dc = Get-FelixPowerSettingValueSnapshot -SchemeGuid $candidate.guid -SubgroupGuid $definition.subgroupGuid -SettingGuid $definition.settingGuid -ValueName 'DCSettingIndex' -UseDefaultFallback
            if (-not $ac.exists -or -not $dc.exists -or $null -eq $ac.value -or $null -eq $dc.value) {
                $complete = $false
                break
            }
            $settings += [ordered]@{
                name = [string]$definition.name
                label = [string]$definition.label
                subgroupGuid = [string]$definition.subgroupGuid
                settingGuid = [string]$definition.settingGuid
                targetAc = [int]$ac.value
                targetDc = [int]$dc.value
            }
        }

        if ($complete) {
            return [ordered]@{
                schemeGuid = [string]$candidate.guid
                label = [string]$candidate.label
                settings = @($settings)
            }
        }
    }

    throw '无法从 Windows 内置高性能或平衡方案解析完整的异类调度默认值。'
}

function Get-HeterogeneousPowerPolicySnapshot {
    [CmdletBinding()]
    param()

    $active = Get-FelixActivePowerScheme
    $baseline = Get-FelixHeterogeneousPowerBaseline
    $settings = @()
    foreach ($definition in @($baseline.settings)) {
        $beforeAc = Get-FelixPowerSettingValueSnapshot -SchemeGuid $active.guid -SubgroupGuid $definition.subgroupGuid -SettingGuid $definition.settingGuid -ValueName 'ACSettingIndex'
        $beforeDc = Get-FelixPowerSettingValueSnapshot -SchemeGuid $active.guid -SubgroupGuid $definition.subgroupGuid -SettingGuid $definition.settingGuid -ValueName 'DCSettingIndex'
        $settings += [ordered]@{
            name = [string]$definition.name
            label = [string]$definition.label
            subgroupGuid = [string]$definition.subgroupGuid
            settingGuid = [string]$definition.settingGuid
            targetAc = [int]$definition.targetAc
            targetDc = [int]$definition.targetDc
            beforeAc = $beforeAc
            beforeDc = $beforeDc
        }
    }

    return [ordered]@{
        activeSchemeGuid = [string]$active.guid
        activeSchemeName = [string]$active.name
        baselineSchemeGuid = [string]$baseline.schemeGuid
        baselineLabel = [string]$baseline.label
        settings = @($settings)
    }
}

function Get-HeterogeneousPowerCurrentValues {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $values = @()
    foreach ($setting in @($Snapshot.before.settings)) {
        $values += [ordered]@{
            setting = $setting
            ac = Get-FelixPowerSettingValueSnapshot -SchemeGuid $Snapshot.before.activeSchemeGuid -SubgroupGuid $setting.subgroupGuid -SettingGuid $setting.settingGuid -ValueName 'ACSettingIndex'
            dc = Get-FelixPowerSettingValueSnapshot -SchemeGuid $Snapshot.before.activeSchemeGuid -SubgroupGuid $setting.subgroupGuid -SettingGuid $setting.settingGuid -ValueName 'DCSettingIndex'
        }
    }
    return @($values)
}

function Invoke-HeterogeneousPowerPolicyApply {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    if ((Get-ActivePowerSchemeGuid) -ne $Snapshot.before.activeSchemeGuid) {
        throw '活动电源方案在预检后发生变化，已阻止执行以避免修改错误方案。'
    }

    foreach ($setting in @($Snapshot.before.settings)) {
        Invoke-FelixNative -FilePath 'powercfg.exe' -ArgumentList @(
            '/setacvalueindex',
            $Snapshot.before.activeSchemeGuid,
            $setting.subgroupGuid,
            $setting.settingGuid,
            [string]$setting.targetAc
        ) | Out-Null
        Invoke-FelixNative -FilePath 'powercfg.exe' -ArgumentList @(
            '/setdcvalueindex',
            $Snapshot.before.activeSchemeGuid,
            $setting.subgroupGuid,
            $setting.settingGuid,
            [string]$setting.targetDc
        ) | Out-Null
    }
    Invoke-FelixNative -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $Snapshot.before.activeSchemeGuid) | Out-Null
    Clear-FelixActivePowerSchemeCache

    return [ordered]@{
        appliedAt = (Get-Date).ToString('o')
    }
}

function Test-HeterogeneousPowerPolicyApplied {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    if ((Get-ActivePowerSchemeGuid) -ne $Snapshot.before.activeSchemeGuid) {
        return $false
    }
    foreach ($entry in @(Get-HeterogeneousPowerCurrentValues -Snapshot $Snapshot)) {
        if (
            -not $entry.ac.exists -or
            -not $entry.dc.exists -or
            [int]$entry.ac.value -ne [int]$entry.setting.targetAc -or
            [int]$entry.dc.value -ne [int]$entry.setting.targetDc
        ) {
            return $false
        }
    }
    return $true
}

function Test-HeterogeneousPowerPolicyRestored {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    if ((Get-ActivePowerSchemeGuid) -ne $Snapshot.before.activeSchemeGuid) {
        return $false
    }
    foreach ($entry in @(Get-HeterogeneousPowerCurrentValues -Snapshot $Snapshot)) {
        if (
            -not (Test-RegistrySnapshotCurrent -Snapshot $entry.setting.beforeAc) -or
            -not (Test-RegistrySnapshotCurrent -Snapshot $entry.setting.beforeDc)
        ) {
            return $false
        }
    }
    return $true
}

function Test-HeterogeneousPowerPolicyRestoreConflict {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    return (Test-HeterogeneousPowerPolicyRestored -Snapshot $Snapshot) -or
        (Test-HeterogeneousPowerPolicyApplied -Snapshot $Snapshot)
}

function Invoke-HeterogeneousPowerPolicyRestore {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    if ((Get-ActivePowerSchemeGuid) -ne $Snapshot.before.activeSchemeGuid) {
        throw '活动电源方案在修改后发生变化，无法安全恢复原来的隐藏调度项。'
    }
    foreach ($setting in @($Snapshot.before.settings)) {
        Invoke-RegistrySnapshotRestore -Snapshot $setting.beforeAc
        Invoke-RegistrySnapshotRestore -Snapshot $setting.beforeDc
    }
    Invoke-FelixNative -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $Snapshot.before.activeSchemeGuid) | Out-Null
    Clear-FelixActivePowerSchemeCache
}

function ConvertTo-FelixMemoryModules {
    [CmdletBinding()]
    param(
        [object[]]$RawModules,

        [hashtable]$TimingOverrides = @{}
    )

    $modules = @(foreach ($raw in @($RawModules)) {
        $deviceLocator = [string]$raw.DeviceLocator
        $partNumber = [string]$raw.PartNumber
        $serialNumber = [string]$raw.SerialNumber
        $timingKey = @($deviceLocator, $partNumber, $serialNumber) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.ToUpperInvariant() } |
            Where-Object { $TimingOverrides.ContainsKey($_) } |
            Select-Object -First 1
        $timing = if ($timingKey) { $TimingOverrides[$timingKey] } else { $null }
        $smbiosType = if ($raw.SMBIOSMemoryType) { [int]$raw.SMBIOSMemoryType } else { [int]$raw.MemoryType }
        [ordered]@{
            manufacturer = [string]$raw.Manufacturer
            partNumber = $partNumber
            serialNumber = $serialNumber
            capacityBytes = [uint64]$raw.Capacity
            speedMHz = if ($raw.Speed) { [int]$raw.Speed } else { 0 }
            configuredSpeedMHz = if ($raw.ConfiguredClockSpeed) { [int]$raw.ConfiguredClockSpeed } else { 0 }
            configuredVoltageMillivolts = if ($raw.ConfiguredVoltage) { [int]$raw.ConfiguredVoltage } else { 0 }
            memoryType = switch ($smbiosType) {
                20 { 'DDR' }
                21 { 'DDR2' }
                24 { 'DDR3' }
                26 { 'DDR4' }
                34 { 'DDR5' }
                default { if ($smbiosType -gt 0) { "SMBIOS $smbiosType" } else { 'Unknown' } }
            }
            formFactor = [string]$raw.FormFactor
            bankLabel = [string]$raw.BankLabel
            deviceLocator = $deviceLocator
            timings = if ($timing) {
                [ordered]@{
                    casLatency = [int]$timing.casLatency
                    trcd = [int]$timing.trcd
                    trp = [int]$timing.trp
                    tras = [int]$timing.tras
                    commandRate = if ($timing.ContainsKey('commandRate')) { [int]$timing.commandRate } else { 0 }
                    source = [string]$timing.source
                }
            }
            else {
                $null
            }
        }
    })

    return @($modules)
}

function Get-FelixMemoryCapacityBytes {
    [CmdletBinding()]
    param(
        [object[]]$Modules
    )

    [uint64]$total = 0
    foreach ($module in @($Modules)) {
        if ($null -eq $module) {
            continue
        }
        [uint64]$capacity = [uint64]$module.capacityBytes
        if ($capacity -gt 0) {
            $total += $capacity
        }
    }
    return $total
}

function Get-FelixMemorySpeedValues {
    [CmdletBinding()]
    param(
        [object[]]$Modules,

        [Parameter(Mandatory)]
        [ValidateSet('configuredSpeedMHz', 'speedMHz')]
        [string]$PropertyName
    )

    $values = @(
        foreach ($module in @($Modules)) {
            if ($null -eq $module) {
                continue
            }

            $value = if ($module -is [System.Collections.IDictionary]) {
                if ($module.Contains($PropertyName)) { [int]$module[$PropertyName] } else { 0 }
            }
            else {
                $property = $module.PSObject.Properties[$PropertyName]
                if ($property) { [int]$property.Value } else { 0 }
            }

            if ($value -gt 0) {
                $value
            }
        }
    )

    return @($values | Sort-Object -Unique)
}

function Get-FelixHardwareInventory {
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    if (
        -not $Force -and
        $script:HardwareCache -and
        $script:HardwareCacheAt -and
        ((Get-Date) - $script:HardwareCacheAt).TotalSeconds -lt 300
    ) {
        return $script:HardwareCache
    }

    $inventory = [ordered]@{
        detectedAt = (Get-Date).ToString('o')
        computer = 'Unavailable'
        manufacturer = 'Unavailable'
        model = 'Unavailable'
        os = [Environment]::OSVersion.VersionString
        osCaption = 'Unavailable'
        osBuild = 'Unavailable'
        osBuildNumber = 0
        architecture = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()) {
            'X64' { 'x64' }
            'X86' { 'x86' }
            'Arm64' { 'arm64' }
            'Arm' { 'arm' }
            default { 'Unknown' }
        }
        systemType = 'Unknown'
        isDomainJoined = $null
        cpu = @()
        gpu = @()
        memory = @()
        memorySummary = 'Unavailable'
        memoryTimingMessage = 'Windows 公共 API 不公开 SPD 时序。'
        totalPhysicalMemoryBytes = [uint64]0
        motherboard = 'Unavailable'
        bios = 'Unavailable'
        disks = @()
        systemDiskIsSsd = $null
        systemDiskFileSystem = 'Unknown'
        printerCount = $null
        pointingDeviceCount = $null
        antiCheatExpertInstalled = $false
        deviceSecurity = [ordered]@{
            vbsStatus = 'Unknown'
            vbsStatusText = '无法读取'
            hvciConfigured = $null
            hvciRunning = $null
            hypervisorLaunchType = 'Unknown'
            assessment = 'Unknown'
            message = '尚未读取 VBS/HVCI 状态。'
        }
    }

    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $inventory.computer = [string]$computer.Name
        $inventory.manufacturer = [string]$computer.Manufacturer
        $inventory.model = [string]$computer.Model
        $inventory.isDomainJoined = [bool]$computer.PartOfDomain
        $inventory.systemType = switch ([int]$computer.PCSystemType) {
            1 { 'Desktop' }
            2 { 'Mobile' }
            3 { 'Workstation' }
            4 { 'EnterpriseServer' }
            5 { 'SOHOServer' }
            6 { 'AppliancePC' }
            7 { 'PerformanceServer' }
            default { 'Unknown' }
        }
        if ([uint64]$computer.TotalPhysicalMemory -gt 0) {
            $inventory.totalPhysicalMemoryBytes = [uint64]$computer.TotalPhysicalMemory
        }
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.computer' -Message $_.Exception.Message
    }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $inventory.os = [string]$os.Version
        $inventory.osCaption = [string]$os.Caption
        $inventory.osBuild = [string]$os.BuildNumber
        $inventory.osBuildNumber = [int]$os.BuildNumber
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.os' -Message $_.Exception.Message
    }

    try {
        $inventory.cpu = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | ForEach-Object {
            [ordered]@{
                name = [string]$_.Name
                manufacturer = [string]$_.Manufacturer
                cores = [int]$_.NumberOfCores
                logicalProcessors = [int]$_.NumberOfLogicalProcessors
                maxClockMHz = [int]$_.MaxClockSpeed
            }
        })
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.cpu' -Message $_.Exception.Message
    }

    try {
        $inventory.gpu = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | ForEach-Object {
            $memoryBytes = if ($_.AdapterRAM -and [uint64]$_.AdapterRAM -gt 0) { [uint64]$_.AdapterRAM } else { 0 }
            [ordered]@{
                name = [string]$_.Name
                vendor = [string]$_.AdapterCompatibility
                applicabilityVendor = switch -Regex ([string]$_.AdapterCompatibility) {
                    'NVIDIA' { 'NVIDIA'; break }
                    'AMD|Advanced Micro Devices|Radeon' { 'AMD'; break }
                    'Intel' { 'Intel'; break }
                    default { 'Unknown' }
                }
                driverVersion = [string]$_.DriverVersion
                adapterMemoryBytes = $memoryBytes
            }
        })
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.gpu' -Message $_.Exception.Message
    }

    $rawMemoryModules = @()
    try {
        $rawMemoryModules = @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop)
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.memory' -Message $_.Exception.Message
        if (Get-Command Get-WmiObject -ErrorAction SilentlyContinue) {
            try {
                $rawMemoryModules = @(Get-WmiObject -Class Win32_PhysicalMemory -ErrorAction Stop)
            }
            catch {
                Add-FelixLog -Level Warning -Event 'hardware.memory_wmi_fallback' -Message $_.Exception.Message
            }
        }
    }

    $timingOverrides = @{}
    try {
        $timingPath = Get-FelixStatePath 'memory-timings.json'
        if (Test-Path -LiteralPath $timingPath -PathType Leaf) {
            $timingDocument = Read-FelixJson -Path $timingPath
            foreach ($module in @($timingDocument.modules)) {
                $key = if ($module.deviceLocator) {
                    [string]$module.deviceLocator
                }
                elseif ($module.partNumber) {
                    [string]$module.partNumber
                }
                else {
                    [string]$module.serialNumber
                }
                if ($key) {
                    $timingOverrides[$key.ToUpperInvariant()] = $module
                }
            }
            $inventory.memoryTimingMessage = '已合并状态目录中的用户核验时序数据。'
        }
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.memory_timings' -Message $_.Exception.Message
    }

    $modules = @(ConvertTo-FelixMemoryModules -RawModules $rawMemoryModules -TimingOverrides $timingOverrides)
    $inventory.memory = @($modules)
    $moduleBytes = Get-FelixMemoryCapacityBytes -Modules $modules
    if ($inventory.totalPhysicalMemoryBytes -eq 0) {
        $inventory.totalPhysicalMemoryBytes = [uint64]$moduleBytes
    }
    if ($inventory.totalPhysicalMemoryBytes -eq 0) {
        $inventory.totalPhysicalMemoryBytes = Get-FelixVisibleMemoryBytes
    }

    $speeds = @(Get-FelixMemorySpeedValues -Modules $modules -PropertyName 'configuredSpeedMHz')
    if ($speeds.Count -eq 0) {
        $speeds = @(Get-FelixMemorySpeedValues -Modules $modules -PropertyName 'speedMHz')
    }
    $timingKnown = @($modules | Where-Object { $_.timings }).Count -gt 0
    $memorySizeGiB = [double]$inventory.totalPhysicalMemoryBytes / 1GB
    $inventory.memorySummary = if ($inventory.totalPhysicalMemoryBytes -gt 0) {
        $moduleText = if ($modules.Count -gt 0) { " / $($modules.Count) 条" } else { ' / 插槽信息不可用' }
        $speedText = if ($speeds.Count -gt 0) { " / $($speeds -join ', ') MT/s" } else { ' / 频率不可用' }
        $timingText = if ($timingKnown) { ' / 已读取时序' } else { ' / 时序需 BIOS 或 CPU-Z 核验' }
        "$([math]::Round($memorySizeGiB, 1)) GiB$moduleText$speedText$timingText"
    }
    else {
        'Unavailable'
    }

    try {
        $board = Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop | Select-Object -First 1
        $inventory.motherboard = "$($board.Manufacturer) $($board.Product)".Trim()
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.motherboard' -Message $_.Exception.Message
    }

    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop | Select-Object -First 1
        $inventory.bios = "$($bios.Manufacturer) $($bios.SMBIOSBIOSVersion)".Trim()
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.bios' -Message $_.Exception.Message
    }

    try {
        $inventory.disks = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop | ForEach-Object {
            [ordered]@{
                model = [string]$_.Model
                interfaceType = [string]$_.InterfaceType
                mediaType = [string]$_.MediaType
                sizeBytes = [uint64]$_.Size
                serialNumber = [string]$_.SerialNumber
            }
        })
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.disks' -Message $_.Exception.Message
    }

    try {
        $storage = Get-FelixStorageSummary
        $inventory.systemDiskIsSsd = $storage.isSsd
        $inventory.systemDiskFileSystem = $storage.fileSystem
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.system_disk' -Message $_.Exception.Message
    }

    try {
        $inventory.printerCount = Get-FelixPrinterCount
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.printers' -Message $_.Exception.Message
    }

    try {
        $inventory.pointingDeviceCount = Get-FelixPointingDeviceCount
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.pointing_devices' -Message $_.Exception.Message
    }

    try {
        $inventory.antiCheatExpertInstalled = Test-FelixAntiCheatExpertPresence
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.ace_presence' -Message $_.Exception.Message
    }

    try {
        $inventory.deviceSecurity = Get-FelixDeviceSecurityStatus
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.device_security' -Message $_.Exception.Message
    }

    try {
        $windowsVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if ($inventory.osCaption -eq 'Unavailable' -and $windowsVersion.ProductName) {
            $inventory.osCaption = [string]$windowsVersion.ProductName
        }
        if ($inventory.osBuild -eq 'Unavailable' -and $windowsVersion.CurrentBuildNumber) {
            $inventory.osBuild = [string]$windowsVersion.CurrentBuildNumber
        }
        if ($inventory.osBuildNumber -eq 0 -and $windowsVersion.CurrentBuildNumber) {
            $inventory.osBuildNumber = [int]$windowsVersion.CurrentBuildNumber
        }
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.os_fallback' -Message $_.Exception.Message
    }

    try {
        $biosKey = Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS' -ErrorAction Stop
        if ($inventory.manufacturer -eq 'Unavailable' -and $biosKey.SystemManufacturer) {
            $inventory.manufacturer = [string]$biosKey.SystemManufacturer
        }
        if ($inventory.model -eq 'Unavailable' -and $biosKey.SystemProductName) {
            $inventory.model = [string]$biosKey.SystemProductName
        }
        if ($inventory.motherboard -eq 'Unavailable') {
            $inventory.motherboard = "$($biosKey.BaseBoardManufacturer) $($biosKey.BaseBoardProduct)".Trim()
        }
        if ($inventory.bios -eq 'Unavailable') {
            $inventory.bios = "$($biosKey.BIOSVendor) $($biosKey.BIOSVersion) $($biosKey.BIOSReleaseDate)".Trim()
        }
        if ($inventory.systemType -eq 'Unknown' -and $biosKey.EnclosureType) {
            $inventory.systemType = switch ([int]$biosKey.EnclosureType) {
                { $_ -in @(8, 9, 10, 14) } { 'Mobile'; break }
                { $_ -in @(3, 4, 5, 6, 7, 15, 16) } { 'Desktop'; break }
                default { 'Unknown' }
            }
        }
    }
    catch {
        Add-FelixLog -Level Warning -Event 'hardware.bios_fallback' -Message $_.Exception.Message
    }

    if ($inventory.cpu.Count -eq 0) {
        $cpuKey = $null
        try {
            $cpuKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('HARDWARE\DESCRIPTION\System\CentralProcessor\0', $false)
            if (-not $cpuKey) {
                throw 'CPU registry key is unavailable.'
            }
            $maxClockMhz = 0
            if ($null -ne $cpuKey.GetValue('~MHz')) {
                $maxClockMhz = [int]$cpuKey.GetValue('~MHz')
            }
            $inventory.cpu = @([ordered]@{
                name = [string]$cpuKey.GetValue('ProcessorNameString')
                manufacturer = [string]$cpuKey.GetValue('Identifier')
                cores = 0
                logicalProcessors = [int]$env:NUMBER_OF_PROCESSORS
                maxClockMHz = $maxClockMhz
            })
        }
        catch {
            Add-FelixLog -Level Warning -Event 'hardware.cpu_fallback' -Message $_.Exception.Message
        }
        finally {
            if ($cpuKey) {
                $cpuKey.Dispose()
            }
        }
    }

    if ($inventory.gpu.Count -eq 0) {
        try {
            $classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
            $gpuFallback = @()
            foreach ($key in Get-ChildItem -LiteralPath $classRoot -ErrorAction Stop) {
                if ($key.PSChildName -notmatch '^\d{4}$') {
                    continue
                }
                $registryKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
                    "SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\$($key.PSChildName)",
                    $false
                )
                if (-not $registryKey) {
                    continue
                }
                try {
                    $driverDesc = [string]$registryKey.GetValue('DriverDesc')
                    if ([string]::IsNullOrWhiteSpace($driverDesc)) {
                        continue
                    }
                    $memoryBytes = 0
                    if ($null -ne $registryKey.GetValue('HardwareInformation.qwMemorySize')) {
                        $memoryBytes = [uint64]$registryKey.GetValue('HardwareInformation.qwMemorySize')
                    }
                    $gpuFallback += [ordered]@{
                        name = $driverDesc
                        vendor = [string]$registryKey.GetValue('ProviderName')
                        applicabilityVendor = switch -Regex ("$driverDesc $($registryKey.GetValue('ProviderName'))") {
                            'NVIDIA' { 'NVIDIA'; break }
                            'AMD|Advanced Micro Devices|Radeon' { 'AMD'; break }
                            'Intel' { 'Intel'; break }
                            default { 'Unknown' }
                        }
                        driverVersion = [string]$registryKey.GetValue('DriverVersion')
                        adapterMemoryBytes = $memoryBytes
                    }
                }
                finally {
                    $registryKey.Dispose()
                }
            }
            $inventory.gpu = @($gpuFallback)
        }
        catch {
            Add-FelixLog -Level Warning -Event 'hardware.gpu_fallback' -Message $_.Exception.Message
        }
    }

    if ($inventory.disks.Count -eq 0) {
        try {
            $systemDrive = Get-PSDrive -Name $env:SystemDrive.TrimEnd(':') -ErrorAction Stop
            $inventory.disks = @([ordered]@{
                model = "$env:SystemDrive 系统盘"
                interfaceType = 'Unknown'
                mediaType = 'Unknown'
                sizeBytes = [uint64]($systemDrive.Used + $systemDrive.Free)
                serialNumber = ''
            })
        }
        catch {
            Add-FelixLog -Level Warning -Event 'hardware.disk_fallback' -Message $_.Exception.Message
        }
    }

    if ($inventory.computer -eq 'Unavailable' -and $env:COMPUTERNAME) {
        $inventory.computer = $env:COMPUTERNAME
    }
    if ($inventory.totalPhysicalMemoryBytes -eq 0) {
        $inventory.totalPhysicalMemoryBytes = Get-FelixVisibleMemoryBytes
    }

    Add-FelixLog -Event 'hardware.detected' -Message 'Hardware inventory completed.' -Data @{
        computer = $inventory.computer
        cpu = @($inventory.cpu | ForEach-Object { $_.name })
        gpu = @($inventory.gpu | ForEach-Object { $_.name })
        memory = $inventory.memorySummary
    }

    $script:HardwareCache = $inventory
    $script:HardwareCacheAt = Get-Date
    return $script:HardwareCache
}

function Get-FelixPowerSchemeCatalog {
    [CmdletBinding()]
    param()

    $output = Invoke-FelixNative -FilePath 'powercfg.exe' -ArgumentList @('/list')
    $schemes = @()
    foreach ($line in ($output -split "`r?`n")) {
        $match = [regex]::Match(
            $line,
            '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s+\(([^)]*)\)(\s+\*)?'
        )
        if (-not $match.Success) {
            continue
        }

        $schemes += [ordered]@{
            guid = $match.Groups[1].Value.ToLowerInvariant()
            name = $match.Groups[2].Value.Trim()
            active = $match.Groups[3].Success
        }
    }

    return @($schemes)
}

function Clear-FelixActivePowerSchemeCache {
    $script:ActivePowerSchemeCache = $null
    $script:ActivePowerSchemeCacheAt = $null
}

function Get-FelixActivePowerScheme {
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    if (
        -not $Force -and
        $null -ne $script:ActivePowerSchemeCache -and
        $script:ActivePowerSchemeCacheAt -and
        ((Get-Date) - $script:ActivePowerSchemeCacheAt).TotalSeconds -lt $script:UiActivePowerSchemeCacheSeconds
    ) {
        return $script:ActivePowerSchemeCache
    }

    $output = Invoke-FelixNative -FilePath 'powercfg.exe' -ArgumentList @('/getactivescheme')
    $match = [regex]::Match(
        $output,
        '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s+\(([^)]*)\)'
    )
    if (-not $match.Success) {
        throw 'Unable to parse the active power scheme.'
    }

    $activeScheme = [ordered]@{
        guid = $match.Groups[1].Value.ToLowerInvariant()
        name = $match.Groups[2].Value.Trim()
    }
    $script:ActivePowerSchemeCache = $activeScheme
    $script:ActivePowerSchemeCacheAt = Get-Date
    return $script:ActivePowerSchemeCache
}

function Invoke-FelixNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string[]]$ArgumentList
    )

    $output = & $FilePath @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "'$FilePath' failed with exit code $exitCode. $($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine)
}

function Get-FelixSession {
    [CmdletBinding()]
    param()

    Initialize-FelixState
    return Read-FelixJson -Path (Get-FelixStatePath 'session.json')
}

function Set-FelixSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Session
    )

    Write-FelixJsonAtomic -Path (Get-FelixStatePath 'session.json') -Value $Session
}

function Add-FelixHistoryEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Record
    )

    Initialize-FelixState
    $line = $Record | ConvertTo-Json -Compress -Depth 16
    Add-Content -LiteralPath (Get-FelixStatePath 'history.jsonl') -Value $line -Encoding utf8
}

function Get-FelixHistoryEvent {
    [CmdletBinding()]
    param()

    Initialize-FelixState
    $path = Get-FelixStatePath 'history.jsonl'
    $records = @()
    foreach ($line in Get-Content -LiteralPath $path) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $records += ($line | ConvertFrom-Json -AsHashtable)
        }
        catch {
            Write-Warning "Ignoring malformed history line: $($_.Exception.Message)"
        }
    }
    return $records
}

function Get-FelixHistory {
    [CmdletBinding()]
    param(
        [string]$HistoryId,
        [switch]$RestorableOnly
    )

    $events = @(Get-FelixHistoryEvent)
    $projected = @()
    foreach ($group in ($events | Group-Object operationId)) {
        $ordered = @($group.Group | Sort-Object timestamp)
        if ($ordered.Count -eq 0) {
            continue
        }

        $first = $ordered[0]
        $last = $ordered[-1]
        $appliedAt = $null
        if ($ordered | Where-Object { $_.eventType -eq 'apply_succeeded' }) {
            $appliedAt = ($ordered | Where-Object { $_.eventType -eq 'apply_succeeded' } | Select-Object -Last 1).timestamp
        }
        $hashEvent = @($ordered | Where-Object {
            $_.ContainsKey('snapshotHash') -and -not [string]::IsNullOrWhiteSpace([string]$_.snapshotHash)
        } | Select-Object -Last 1)
        $rollbackEvent = @($ordered | Where-Object {
            $_.ContainsKey('rollbackMode') -and -not [string]::IsNullOrWhiteSpace([string]$_.rollbackMode)
        } | Select-Object -Last 1)
        $rollbackMode = if ($rollbackEvent.Count -gt 0) {
            [string]$rollbackEvent[0].rollbackMode
        }
        else {
            'IndependentSnapshot'
        }

        $record = [ordered]@{
            historyId = [string]$group.Name
            operationId = [string]$group.Name
            ruleId = [string]$first.ruleId
            ruleName = [string]$first.ruleName
            risk = [string]$first.risk
            requiresRestart = [bool]$first.requiresRestart
            appliedAt = $appliedAt
            updatedAt = [string]$last.timestamp
            status = [string]$last.status
            eventType = [string]$last.eventType
            message = [string]$last.message
            snapshotPath = [string]$first.snapshotPath
            snapshotHash = if ($hashEvent.Count -gt 0) { [string]$hashEvent[0].snapshotHash } else { $null }
            rollbackMode = $rollbackMode
            systemRestorePointRequired = ($rollbackMode -eq 'DualRollback')
            restorePointId = if ($rollbackEvent.Count -gt 0) { [string]$rollbackEvent[0].restorePointId } else { $null }
            restorePointCreatedAt = if ($rollbackEvent.Count -gt 0) { [string]$rollbackEvent[0].restorePointCreatedAt } else { $null }
        }

        if ($RestorableOnly -and $record.status -notin $script:RestorableStatuses) {
            continue
        }
        if ($HistoryId -and $record.historyId -ne $HistoryId) {
            continue
        }

        $projected += [pscustomobject]$record
    }

    return @($projected | Sort-Object updatedAt -Descending)
}

function Get-FelixHistoryView {
    [CmdletBinding()]
    param()

    $history = @(Get-FelixHistory)
    $statusByRule = @{}
    $restorableByRule = @{}
    $restorable = @()

    foreach ($record in $history) {
        $ruleId = [string]$record.ruleId
        if (-not $statusByRule.ContainsKey($ruleId)) {
            $statusByRule[$ruleId] = [string]$record.status
        }

        if ($record.status -in $script:RestorableStatuses -and -not $restorableByRule.ContainsKey($ruleId)) {
            $restorableByRule[$ruleId] = $record
            $restorable += $record
        }
    }

    return [ordered]@{
        history = $history
        restorable = @($restorable)
        statusByRule = $statusByRule
        restorableByRule = $restorableByRule
    }
}

function New-FelixOperationId {
    return [guid]::NewGuid().ToString('D')
}

function Save-FelixSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $path = Get-FelixStatePath (Join-Path 'snapshots' "$($Snapshot.operationId).json")
    Write-FelixJsonAtomic -Path $path -Value $Snapshot
    return $path
}

function Read-FelixSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $snapshot = Read-FelixJson -Path $Path
    if ($null -eq $snapshot) {
        throw "Snapshot '$Path' was not found or is invalid."
    }
    return $snapshot
}

function Get-FelixRestorePoint {
    [CmdletBinding()]
    param()

    try {
        return @(Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object SequenceNumber -Descending)
    }
    catch {
        return @()
    }
}

function Test-FelixRestorePointAvailable {
    [CmdletBinding()]
    param()

    $points = @(Get-FelixRestorePoint)
    return ($points.Count -gt 0)
}

function Get-FelixAdvancedGate {
    [CmdletBinding()]
    param(
        [switch]$AcceptRisk
    )

    $rollback = Test-FelixDualRollbackCapability -EnsureRestorePoint
    if (-not $rollback.available) {
        Add-FelixLog -Level Error -Event 'rollback.unavailable' -Message $rollback.message
        return $false
    }
    if (-not $AcceptRisk) {
        return $false
    }

    $session = Get-FelixSession
    $session.appVersion = $script:ModuleVersion
    $session.rollbackMode = [string]$rollback.mode
    $session.requiresSystemRestorePoint = [bool]$rollback.requiresSystemRestorePoint
    $session.restorePointAvailable = $rollback.restorePointAvailable
    $session.restorePointId = $rollback.restorePointId
    $session.restorePointCreatedAt = $rollback.restorePointCreatedAt
    $session.allowOptimizationWithoutRestorePoint = -not [bool]$rollback.requiresSystemRestorePoint
    Set-FelixSession -Session $session
    return $true
}

function Invoke-FelixRestorePointRequestLocal {
    [CmdletBinding()]
    param()

    if (-not (Test-FelixAdministrator)) {
        throw 'Administrator privileges are required to create a system restore point.'
    }

    $drive = "$env:SystemDrive\"
    try {
        Enable-ComputerRestore -Drive $drive -ErrorAction Stop
    }
    catch {
        Write-Warning "Unable to enable system protection automatically: $($_.Exception.Message)"
    }

    $description = "稳优 StableTune $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"
    Checkpoint-Computer -Description $description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop | Out-Null
    $point = Get-FelixRestorePoint | Select-Object -First 1

    $session = Get-FelixSession
    $session.restorePointAvailable = $true
    $session.restorePointId = if ($point) { [string]$point.SequenceNumber } else { $null }
    $session.restorePointCreatedAt = (Get-Date).ToString('o')
    Set-FelixSession -Session $session
    Clear-FelixRuntimeCaches

    return $session
}

function Request-FelixSessionRestorePoint {
    [CmdletBinding()]
    param()

    if (Test-FelixAdministrator) {
        return Invoke-FelixRestorePointRequestLocal
    }

    return Invoke-FelixElevatedRequest -Action 'RestorePoint' -Payload @{}
}

function Invoke-FelixElevatedRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Apply', 'Restore', 'RestorePoint')]
        [string]$Action,

        [Parameter(Mandatory)]
        [hashtable]$Payload
    )

    Initialize-FelixState
    $requestId = [guid]::NewGuid().ToString('N')
    $requestPath = Get-FelixStatePath (Join-Path 'worker' "$requestId.request.json")
    $resultPath = Get-FelixStatePath (Join-Path 'worker' "$requestId.result.json")
    $request = [ordered]@{
        schemaVersion = '1.0'
        action = $Action
        payload = $Payload
        requestPath = $requestPath
        resultPath = $resultPath
        createdAt = (Get-Date).ToString('o')
    }

    Write-FelixJsonAtomic -Path $requestPath -Value $request
    $workerPath = Join-Path $script:ModuleRoot 'ElevatedWorker.ps1'
    $pwshPath = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshPath)) {
        $pwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    }

    try {
        $process = Start-Process -FilePath $pwshPath -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ArgumentList @(
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            "`"$workerPath`"",
            '-RequestPath',
            "`"$requestPath`""
        )
    }
    catch {
        throw "Elevation was cancelled or failed: $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $resultPath)) {
        throw "Elevated worker did not produce a result. Exit code: $($process.ExitCode)."
    }

    $response = Read-FelixJson -Path $resultPath
    Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue

    if (-not $response.success) {
        throw [string]$response.error
    }

    return $response.result
}

function Get-FelixRuleStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RuleId,

        [hashtable]$StatusByRule
    )

    if ($null -ne $StatusByRule) {
        if ($StatusByRule.ContainsKey($RuleId)) {
            return [string]$StatusByRule[$RuleId]
        }
        return 'NotApplied'
    }

    $records = @(Get-FelixHistory | Where-Object { $_.ruleId -eq $RuleId })
    if ($records.Count -eq 0) {
        return 'NotApplied'
    }

    return [string]$records[0].status
}

function New-FelixSystemChangeResult {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Modified', 'NotModified', 'RequiresSelection', 'NotPersistent', 'Unavailable')]
        [string]$State,

        [Parameter(Mandatory)]
        [string]$Message
    )

    return [ordered]@{
        state = $State
        modified = ($State -eq 'Modified')
        message = $Message
    }
}

function Test-FelixRegistryChangeCurrent {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Change,

        [hashtable]$Options = @{}
    )

    $path = Resolve-FelixTextTemplate -Text ([string]$Change.path) -Values $Options
    $name = Resolve-FelixTextTemplate -Text ([string]$Change.name) -Values $Options
    $current = Get-RegistryValueSnapshot -Path $path -Name $name
    $resolvedValue = if ($Change.value -is [string]) {
        Resolve-FelixTextTemplate -Text ([string]$Change.value) -Values $Options
    }
    else {
        $Change.value
    }
    $targetValue = ConvertTo-RegistryTargetValue -Value $resolvedValue -Kind ([string]$Change.kind)
    $target = [ordered]@{
        path = $path
        name = $name
        exists = $true
        kind = [string]$Change.kind
        value = $targetValue
    }

    return (ConvertTo-RegistryComparable -Snapshot $current) -eq (ConvertTo-RegistryComparable -Snapshot $target)
}

function Get-FelixRuleChangeState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Rule,

        [hashtable]$RestorableByRule
    )

    if ($null -ne $RestorableByRule) {
        $history = @(
            if ($RestorableByRule.ContainsKey([string]$Rule.id)) {
                $RestorableByRule[[string]$Rule.id]
            }
        )
    }
    else {
        $history = @(Get-FelixHistory -RestorableOnly | Where-Object { $_.ruleId -eq $Rule.id } | Select-Object -First 1)
    }
    if ($history.Count -eq 1 -and (Test-Path -LiteralPath ([string]$history[0].snapshotPath))) {
        try {
            Test-FelixSnapshotIntegrity -Path ([string]$history[0].snapshotPath) -ExpectedHash ([string]$history[0].snapshotHash) | Out-Null
            $snapshot = Read-FelixSnapshot -Path ([string]$history[0].snapshotPath)
            if (Test-FelixHandlerApplied -Rule $Rule -Snapshot $snapshot) {
                return New-FelixSystemChangeResult -State 'Modified' -Message '当前状态与 稳优 StableTune 最近一次成功优化结果一致。'
            }
            if (Test-FelixHandlerRestored -Rule $Rule -Snapshot $snapshot) {
                return New-FelixSystemChangeResult -State 'NotModified' -Message '当前状态与操作前快照一致。'
            }
            return New-FelixSystemChangeResult -State 'Unavailable' -Message '该项曾由程序修改，但当前系统状态已被其他设置改变。'
        }
        catch {
            return New-FelixSystemChangeResult -State 'Unavailable' -Message "无法验证历史快照：$($_.Exception.Message)"
        }
    }

    if ([bool]$Rule.requiresInput) {
        return New-FelixSystemChangeResult -State 'RequiresSelection' -Message '需要先选择设备、网卡、服务或程序后才能检查。'
    }

    try {
        switch ([string]$Rule.handler) {
            'PowerPlan' {
                $active = Get-FelixActivePowerScheme
                if ($active.name -eq 'StableTune Low Latency') {
                    return New-FelixSystemChangeResult -State 'Modified' -Message "当前电源方案为 $($active.name)。"
                }
                return New-FelixSystemChangeResult -State 'NotModified' -Message "当前电源方案为 $($active.name)。"
            }
            'ProcessorMinimum' {
                $value = [int](Get-PowerSettingSnapshot -SettingName 'Processor').ac.value
                return New-FelixSystemChangeResult -State $(if ($value -eq 100) { 'Modified' } else { 'NotModified' }) -Message "处理器最低状态 AC 当前为 $value%。"
            }
            'CoreParkingMinimum' {
                $value = [int](Get-PowerSettingSnapshot -SettingName 'CoreParking').ac.value
                return New-FelixSystemChangeResult -State $(if ($value -eq 100) { 'Modified' } else { 'NotModified' }) -Message "核心停车最低核心数 AC 当前为 $value%。"
            }
            'CpuIdleDisable' {
                $value = [int](Get-PowerSettingSnapshot -SettingName 'CpuIdle').ac.value
                return New-FelixSystemChangeResult -State $(if ($value -eq 1) { 'Modified' } else { 'NotModified' }) -Message "处理器空闲禁用状态 AC 当前为 $value。"
            }
            'UsbSelectiveSuspend' {
                $value = [int](Get-PowerSettingSnapshot -SettingName 'Usb').ac.value
                return New-FelixSystemChangeResult -State $(if ($value -eq 0) { 'Modified' } else { 'NotModified' }) -Message "USB 选择性暂停 AC 当前为 $value。"
            }
            'PcieAspm' {
                $value = [int](Get-PowerSettingSnapshot -SettingName 'Pcie').ac.value
                return New-FelixSystemChangeResult -State $(if ($value -eq 0) { 'Modified' } else { 'NotModified' }) -Message "PCIe 链接状态电源管理 AC 当前为 $value。"
            }
            'PrioritySeparation' {
                $value = Get-PrioritySeparationSnapshot
                $modified = $value.exists -and [int]$value.value -eq 40
                return New-FelixSystemChangeResult -State $(if ($modified) { 'Modified' } else { 'NotModified' }) -Message "Win32PrioritySeparation 当前值为 $(if ($value.exists) { $value.value } else { '<missing>' })。"
            }
            'MultimediaProfile' {
                $current = Get-MultimediaProfileSnapshot
                $throttle = @($current.registry | Where-Object { $_.name -eq 'NetworkThrottlingIndex' })[0]
                $responsiveness = @($current.registry | Where-Object { $_.name -eq 'SystemResponsiveness' })[0]
                $throttleValue = if ($throttle.exists) {
                    [uint32](([int64]$throttle.value) -band ([int64][uint32]::MaxValue))
                }
                else {
                    0
                }
                $modified = $throttle.exists -and $throttleValue -eq [uint32]::MaxValue -and
                    $responsiveness.exists -and [int]$responsiveness.value -eq 0
                return New-FelixSystemChangeResult -State $(if ($modified) { 'Modified' } else { 'NotModified' }) -Message '已读取网络节流与系统响应性注册表值。'
            }
            'BcdTimers' {
                $current = Get-BcdTimerSnapshot
                $modified = ([string]$current.useplatformtick.value -ieq 'No') -and ([string]$current.disabledynamictick.value -ieq 'Yes')
                return New-FelixSystemChangeResult -State $(if ($modified) { 'Modified' } else { 'NotModified' }) -Message '已读取 BCD 平台时钟与动态时钟设置。'
            }
            'TcpAutotuning' {
                $value = (Get-TcpGlobalSnapshot).autoTuning
                return New-FelixSystemChangeResult -State $(if ($value -eq 'experimental') { 'Modified' } else { 'NotModified' }) -Message "TCP 自动调优当前为 $value。"
            }
            'TcpTimestamps' {
                $value = (Get-TcpGlobalSnapshot).timestamps
                return New-FelixSystemChangeResult -State $(if ($value -eq 'enabled') { 'Modified' } else { 'NotModified' }) -Message "TCP 时间戳当前为 $value。"
            }
            'AmdDynamicPstate' {
                $value = Get-AmdDynamicPstateSnapshot
                $modified = $value.exists -and [int]$value.value -eq 1
                return New-FelixSystemChangeResult -State $(if ($modified) { 'Modified' } else { 'NotModified' }) -Message "AMD DisableDynamicPstate 当前为 $(if ($value.exists) { $value.value } else { '<missing>' })。"
            }
            'HeterogeneousPowerPolicy' {
                $snapshot = Get-HeterogeneousPowerPolicySnapshot
                if (Test-HeterogeneousPowerPolicyApplied -Snapshot $snapshot) {
                    return New-FelixSystemChangeResult -State 'Modified' -Message "当前电源方案的异类调度与性能提升模式已匹配 $($snapshot.before.baselineLabel) 的系统默认基线。"
                }
                $values = @(
                    Get-HeterogeneousPowerCurrentValues -Snapshot $snapshot |
                        ForEach-Object {
                            $ac = if ($_.ac.exists) { [string]$_.ac.value } else { '缺失' }
                            "$($_.setting.name)=$ac"
                        }
                ) -join ' / '
                return New-FelixSystemChangeResult -State 'NotModified' -Message "检测到隐藏调度项未完全恢复：$values。"
            }
            'RegistrySet' {
                $modified = $true
                foreach ($change in @($Rule.registryChanges)) {
                    if (-not (Test-FelixRegistryChangeCurrent -Change $change)) {
                        $modified = $false
                        break
                    }
                }
                return New-FelixSystemChangeResult -State $(if ($modified) { 'Modified' } else { 'NotModified' }) -Message '已检查该规则的全部注册表目标值。'
            }
            'ServiceFixed' {
                $service = Get-Service -Name ([string]$Rule.serviceName) -ErrorAction Stop
                $modified = $service.StartType.ToString() -eq [string]$Rule.targetStartupType
                if ($modified -and [bool]$Rule.stopNow -and $service.Status -eq 'Running') {
                    $modified = $false
                }
                return New-FelixSystemChangeResult -State $(if ($modified) { 'Modified' } else { 'NotModified' }) -Message "服务 $($Rule.serviceName) 当前启动类型为 $($service.StartType)，状态为 $($service.Status)。"
            }
            'TempQuarantine' {
                return New-FelixSystemChangeResult -State 'NotPersistent' -Message '临时文件隔离属于一次性操作，不通过系统设置状态判断。'
            }
            default {
                return New-FelixSystemChangeResult -State 'Unavailable' -Message '该规则需要结合用户选择或当前设备状态检查。'
            }
        }
    }
    catch {
        return New-FelixSystemChangeResult -State 'Unavailable' -Message $_.Exception.Message
    }
}

function Get-FelixSystemChangeReport {
    [CmdletBinding()]
    param()

    $historyView = Get-FelixHistoryView
    $rows = foreach ($rule in Get-FelixRule) {
        $state = Get-FelixRuleChangeState -Rule $rule -RestorableByRule $historyView.restorableByRule
        [pscustomobject][ordered]@{
            ruleId = $rule.id
            name = $rule.name
            state = $state.state
            modified = $state.modified
            message = $state.message
        }
    }
    $rows = @($rows)

    return [ordered]@{
        checkedAt = (Get-Date).ToString('o')
        total = $rows.Count
        modified = @($rows | Where-Object { $_.state -eq 'Modified' }).Count
        notModified = @($rows | Where-Object { $_.state -eq 'NotModified' }).Count
        requiresSelection = @($rows | Where-Object { $_.state -eq 'RequiresSelection' }).Count
        unavailable = @($rows | Where-Object { $_.state -eq 'Unavailable' }).Count
        rows = $rows
    }
}

function Invoke-FelixAudit {
    [CmdletBinding()]
    param(
        [System.Collections.IDictionary]$Hardware
    )

    $historyView = Get-FelixHistoryView
    $isAdministrator = Test-FelixAdministrator
    $rules = @(Get-FelixRule)
    $hardwareInventory = if ($null -ne $Hardware) {
        $Hardware
    }
    else {
        Get-FelixHardwareInventory
    }
    $rows = foreach ($rule in $rules) {
        $probe = Test-FelixRulePrerequisite -Rule $rule -Options @{}
        $applicability = Get-FelixRuleApplicability -Rule $rule -Hardware $hardwareInventory
        $ruleStatus = Get-FelixRuleStatus -RuleId $rule.id -StatusByRule $historyView.statusByRule
        $systemState = Get-FelixRuleChangeState -Rule $rule -RestorableByRule $historyView.restorableByRule
        [pscustomobject][ordered]@{
            id = $rule.id
            category = $rule.category
            name = $rule.name
            risk = $rule.risk
            requiresAdmin = $rule.requiresAdmin
            requiresRestart = $rule.requiresRestart
            requiresInput = $rule.requiresInput
            available = $probe.available
            requirement = $probe.message
            status = $ruleStatus
            systemChanged = $systemState.modified
            systemState = $systemState.state
            systemStateMessage = $systemState.message
            admin = $isAdministrator
            applicability = $applicability.status
            applicabilityLabel = $applicability.label
            applicabilityMessage = $applicability.message
            applicabilityConfidence = $applicability.confidence
            batchEligible = $applicability.batchEligible
            evidence = @($applicability.evidence)
            reviewedAt = $applicability.reviewedAt
        }
    }

    return @($rows)
}

function Invoke-FelixDryRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RuleId,

        [hashtable]$Options = @{}
    )

    $rule = Get-FelixRuleRequired -RuleId $RuleId
    $applicability = Get-FelixRuleApplicability -Rule $rule
    if ($applicability.status -in @('NotApplicable', 'Unknown')) {
        throw "本机适用性检查未通过：$($applicability.message)"
    }
    $probe = Test-FelixRulePrerequisite -Rule $rule -Options $Options
    $changes = Get-FelixHandlerChangeSummary -Rule $rule -Options $Options

    return [pscustomobject][ordered]@{
        ruleId = $rule.id
        name = $rule.name
        risk = $rule.risk
        available = $probe.available
        requirement = $probe.message
        requiresAdmin = $rule.requiresAdmin
        requiresRestart = $rule.requiresRestart
        plannedChanges = $changes
        applicability = $applicability
    }
}

function Invoke-FelixApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RuleId,

        [hashtable]$Options = @{},

        [switch]$AcceptRisk
    )

    $rule = Get-FelixRuleRequired -RuleId $RuleId
    if ($rule.requiresInput -and $Options.Count -eq 0) {
        throw "Rule '$RuleId' requires input options."
    }
    if ($rule.risk -eq 'advanced' -and -not $AcceptRisk) {
        throw 'Advanced operation requires explicit confirmation.'
    }
    $applicability = Get-FelixRuleApplicability -Rule $rule
    if ($applicability.status -in @('NotApplicable', 'Unknown')) {
        throw "本机适用性检查未通过：$($applicability.message)"
    }
    $probe = Test-FelixRulePrerequisite -Rule $rule -Options $Options
    if (-not $probe.available) {
        throw [string]$probe.message
    }

    if (-not (Test-FelixAdministrator) -and $rule.requiresAdmin) {
        return Invoke-FelixElevatedRequest -Action 'Apply' -Payload @{
            ruleId = $RuleId
            options = $Options
            acceptRisk = [bool]$AcceptRisk
        }
    }

    return Invoke-FelixApplyLocal -RuleId $RuleId -Options $Options -AcceptRisk:$AcceptRisk
}

function Invoke-FelixApplyLocal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RuleId,

        [hashtable]$Options = @{},

        [switch]$AcceptRisk
    )

    if (-not $script:OperationMutex.WaitOne(0)) {
        throw 'Another 稳优 StableTune operation is already running.'
    }

    try {
    Initialize-FelixState
    Clear-FelixRuntimeCaches
    $rule = Get-FelixRuleRequired -RuleId $RuleId

    if ($rule.requiresInput -and $Options.Count -eq 0) {
        throw "Rule '$RuleId' requires input options."
    }

    if ($rule.risk -eq 'advanced' -and -not (Get-FelixAdvancedGate -AcceptRisk:$AcceptRisk)) {
        throw 'Advanced operation requires explicit confirmation and a verified rollback capability.'
    }

    $applicability = Get-FelixRuleApplicability -Rule $rule
    if ($applicability.status -in @('NotApplicable', 'Unknown')) {
        throw "本机适用性检查未通过：$($applicability.message)"
    }

    $probe = Test-FelixRulePrerequisite -Rule $rule -Options $Options
    if (-not $probe.available) {
        throw [string]$probe.message
    }

    $rollbackCapability = Test-FelixDualRollbackCapability -EnsureRestorePoint
    if (-not $rollbackCapability.available) {
        throw "Rollback capability check failed: $($rollbackCapability.message)"
    }

    $operationId = New-FelixOperationId
    $before = Get-FelixHandlerSnapshot -Rule $rule -Options $Options -OperationId $operationId
    $snapshot = [ordered]@{
        schemaVersion = '1.0'
        appVersion = $script:ModuleVersion
        operationId = $operationId
        ruleId = $rule.id
        ruleName = $rule.name
        risk = $rule.risk
        requiresRestart = $rule.requiresRestart
        rollbackMode = [string]$rollbackCapability.mode
        systemRestorePointRequired = [bool]$rollbackCapability.requiresSystemRestorePoint
        restorePointId = $rollbackCapability.restorePointId
        restorePointCreatedAt = $rollbackCapability.restorePointCreatedAt
        snapshotHash = $null
        capturedAt = (Get-Date).ToString('o')
        options = $Options
        before = $before
        after = $null
    }
    $snapshotPath = Save-FelixSnapshot -Snapshot $snapshot

    Register-FelixCrashGuard -OperationId $operationId -HistoryId $operationId -RuleId $rule.id -SnapshotPath $snapshotPath -Before $before -RequiresRestart ([bool]$rule.requiresRestart) | Out-Null

    Add-FelixHistoryEvent -Record ([ordered]@{
        historyId = $operationId
        operationId = $operationId
        ruleId = $rule.id
        ruleName = $rule.name
        risk = $rule.risk
        requiresRestart = $rule.requiresRestart
        eventType = 'apply_started'
        status = 'InProgress'
        timestamp = (Get-Date).ToString('o')
        message = 'Applying operation.'
        snapshotPath = $snapshotPath
    })

    Add-FelixLog -Event 'apply.started' -Message "Applying '$($rule.name)'." -RuleId $rule.id -HistoryId $operationId -Data @{
        risk = $rule.risk
        snapshotPath = $snapshotPath
    }
    Write-FelixRollbackJournal -HistoryId $operationId -RuleId $rule.id -Event 'apply_started' -SnapshotPath $snapshotPath -RestorePointId ([string]$rollbackCapability.restorePointId) -RestorePointCreatedAt ([string]$rollbackCapability.restorePointCreatedAt) -RollbackMode ([string]$rollbackCapability.mode) -SystemRestorePointRequired ([bool]$rollbackCapability.requiresSystemRestorePoint) -Message 'Rollback protection captured before apply.'

    try {
        $after = Invoke-FelixHandlerApply -Rule $rule -Options $Options -Snapshot $snapshot -OperationId $operationId
        $snapshot.after = $after
        $snapshotPath = Save-FelixSnapshot -Snapshot $snapshot

        if (-not (Test-FelixHandlerApplied -Rule $rule -Snapshot $snapshot)) {
            throw 'Verification read-back did not match the expected state.'
        }

        $snapshotHash = Get-FelixFileHash -Path $snapshotPath
        Add-FelixHistoryEvent -Record ([ordered]@{
            historyId = $operationId
            operationId = $operationId
            ruleId = $rule.id
            ruleName = $rule.name
            risk = $rule.risk
            requiresRestart = $rule.requiresRestart
            eventType = 'apply_succeeded'
            status = 'Applied'
            timestamp = (Get-Date).ToString('o')
            message = 'Operation applied and verified.'
            snapshotPath = $snapshotPath
            snapshotHash = $snapshotHash
            rollbackMode = [string]$rollbackCapability.mode
            systemRestorePointRequired = [bool]$rollbackCapability.requiresSystemRestorePoint
            restorePointId = $rollbackCapability.restorePointId
            restorePointCreatedAt = $rollbackCapability.restorePointCreatedAt
        })
        Write-FelixRollbackJournal -HistoryId $operationId -RuleId $rule.id -Event 'apply_verified' -SnapshotPath $snapshotPath -SnapshotHash $snapshotHash -RestorePointId ([string]$rollbackCapability.restorePointId) -RestorePointCreatedAt ([string]$rollbackCapability.restorePointCreatedAt) -RollbackMode ([string]$rollbackCapability.mode) -SystemRestorePointRequired ([bool]$rollbackCapability.requiresSystemRestorePoint) -Message 'Apply verified; rollback protection sealed.'
        Add-FelixLog -Event 'apply.succeeded' -Message "Applied and verified '$($rule.name)'." -RuleId $rule.id -HistoryId $operationId -Data @{
            snapshotHash = $snapshotHash
        }

        if ($rule.requiresRestart) {
            Set-FelixCrashGuardState -OperationId $operationId -State 'AwaitingBoot' | Out-Null
            Add-FelixLog -Event 'crash_guard.awaiting_boot' -Message 'Optimization requires restart; crash recovery will verify the next boot.' -RuleId $rule.id -HistoryId $operationId
        }
        else {
            Complete-FelixCrashGuard -OperationId $operationId
        }
        Clear-FelixRuntimeCaches

        return [ordered]@{
            success = $true
            historyId = $operationId
            ruleId = $rule.id
            status = 'Applied'
            requiresRestart = $rule.requiresRestart
            snapshotPath = $snapshotPath
            snapshotHash = $snapshotHash
            rollbackMode = [string]$rollbackCapability.mode
            systemRestorePointRequired = [bool]$rollbackCapability.requiresSystemRestorePoint
            restorePointId = $rollbackCapability.restorePointId
            restorePointCreatedAt = $rollbackCapability.restorePointCreatedAt
            crashGuard = if ($rule.requiresRestart) { 'AwaitingBoot' } else { 'Completed' }
        }
    }
    catch {
        $failureMessage = $_.Exception.Message
        $rollbackSucceeded = $false
        try {
            Invoke-FelixHandlerRestore -Rule $rule -Snapshot $snapshot -OperationId $operationId
            if (-not (Test-FelixHandlerRestored -Rule $rule -Snapshot $snapshot)) {
                throw 'Automatic rollback verification did not match the original state.'
            }
            $rollbackSucceeded = $true
            $rollbackMessage = 'Automatic rollback completed.'
            Add-FelixLog -Level Warning -Event 'apply.rollback_succeeded' -Message $rollbackMessage -RuleId $rule.id -HistoryId $operationId
            Write-FelixRollbackJournal -HistoryId $operationId -RuleId $rule.id -Event 'automatic_rollback_succeeded' -SnapshotPath $snapshotPath -RestorePointId ([string]$rollbackCapability.restorePointId) -RestorePointCreatedAt ([string]$rollbackCapability.restorePointCreatedAt) -RollbackMode ([string]$rollbackCapability.mode) -SystemRestorePointRequired ([bool]$rollbackCapability.requiresSystemRestorePoint) -Message $rollbackMessage
        }
        catch {
            $rollbackMessage = "Automatic rollback failed: $($_.Exception.Message)"
            Add-FelixLog -Level Error -Event 'apply.rollback_failed' -Message $rollbackMessage -RuleId $rule.id -HistoryId $operationId
            Write-FelixRollbackJournal -HistoryId $operationId -RuleId $rule.id -Event 'automatic_rollback_failed' -SnapshotPath $snapshotPath -RestorePointId ([string]$rollbackCapability.restorePointId) -RestorePointCreatedAt ([string]$rollbackCapability.restorePointCreatedAt) -RollbackMode ([string]$rollbackCapability.mode) -SystemRestorePointRequired ([bool]$rollbackCapability.requiresSystemRestorePoint) -Message $rollbackMessage
        }

        if ($rollbackSucceeded) {
            Complete-FelixCrashGuard -OperationId $operationId
        }
        else {
            Set-FelixCrashGuardState -OperationId $operationId -State 'Armed' -Message $rollbackMessage | Out-Null
        }

        Add-FelixHistoryEvent -Record ([ordered]@{
            historyId = $operationId
            operationId = $operationId
            ruleId = $rule.id
            ruleName = $rule.name
            risk = $rule.risk
            requiresRestart = $rule.requiresRestart
            eventType = 'apply_failed'
            status = 'Failed'
            timestamp = (Get-Date).ToString('o')
            message = "$failureMessage $rollbackMessage"
            snapshotPath = $snapshotPath
        })
        Add-FelixLog -Level Error -Event 'apply.failed' -Message $failureMessage -RuleId $rule.id -HistoryId $operationId
        Clear-FelixRuntimeCaches
        throw
    }
    }
    finally {
        $script:OperationMutex.ReleaseMutex()
    }
}

function Invoke-FelixBatchApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$RuleIds,

        [switch]$AcceptRisk
    )

    $uniqueRuleIds = @($RuleIds | Where-Object { $_ } | Select-Object -Unique)
    if ($uniqueRuleIds.Count -eq 0) {
        throw 'No rules were selected for batch processing.'
    }

    $planned = @()
    $skipped = @()
    foreach ($ruleId in $uniqueRuleIds) {
        $rule = @(Get-FelixRule -RuleId $ruleId)
        if ($rule.Count -ne 1) {
            $skipped += [ordered]@{ ruleId = $ruleId; reason = '规则不存在。' }
            continue
        }
        $rule = $rule[0]
        if ($rule.requiresInput) {
            $skipped += [ordered]@{ ruleId = $rule.id; name = $rule.name; reason = '该规则需要单独选择目标，不能批量执行。' }
            continue
        }
        $applicability = Get-FelixRuleApplicability -Rule $rule
        if (-not $applicability.batchEligible) {
            $skipped += [ordered]@{ ruleId = $rule.id; name = $rule.name; reason = "本机适用性为 $($applicability.label)：$($applicability.message)" }
            continue
        }
        if ($rule.risk -eq 'advanced' -and -not $AcceptRisk) {
            $skipped += [ordered]@{ ruleId = $rule.id; name = $rule.name; reason = '高级项需要显式接受风险。' }
            continue
        }
        $planned += $rule
    }

    if ($planned.Count -eq 0) {
        return [ordered]@{
            success = $false
            applied = @()
            skipped = @($skipped)
            rolledBack = @()
            message = '没有可批量执行的规则。'
        }
    }

    $applied = @()
    $rolledBack = @()
    $failure = $null
    Add-FelixLog -Event 'batch.started' -Message "Starting batch apply for $($planned.Count) rule(s)." -Data @{
        ruleIds = @($planned | ForEach-Object { $_.id })
        skipped = @($skipped | ForEach-Object { $_.ruleId })
    }

    foreach ($rule in $planned) {
        try {
            $result = Invoke-FelixApply -RuleId $rule.id -AcceptRisk:$AcceptRisk
            $applied += $result
        }
        catch {
            $failure = [ordered]@{
                ruleId = $rule.id
                name = $rule.name
                message = $_.Exception.Message
            }
            break
        }
    }

    if ($failure) {
        $reverseApplied = if ($applied.Count -gt 0) {
            @($applied[($applied.Count - 1)..0])
        }
        else {
            @()
        }
        foreach ($result in $reverseApplied) {
            try {
                $restore = Invoke-FelixRestore -HistoryId ([string]$result.historyId) -Force
                $rolledBack += $restore
            }
            catch {
                $rolledBack += [ordered]@{
                    historyId = [string]$result.historyId
                    ruleId = [string]$result.ruleId
                    success = $false
                    message = $_.Exception.Message
                }
            }
        }
        Add-FelixLog -Level Error -Event 'batch.failed' -Message "Batch apply failed at '$($failure.ruleId)' and attempted rollback." -Data @{
            failure = $failure
            rolledBack = @($rolledBack | ForEach-Object { $_.ruleId })
        }
    }
    else {
        Add-FelixLog -Event 'batch.succeeded' -Message "Batch apply completed for $($applied.Count) rule(s)."
    }

    return [ordered]@{
        success = $null -eq $failure
        applied = @($applied)
        skipped = @($skipped)
        rolledBack = @($rolledBack)
        failure = $failure
        message = if ($failure) {
            "批量执行在 [$($failure.name)] 失败，已尝试回滚本次成功项。$($failure.message)"
        }
        else {
            "批量执行完成：成功 $($applied.Count) 项，跳过 $($skipped.Count) 项。"
        }
    }
}

function Invoke-FelixRestore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HistoryId,

        [switch]$Force
    )

    $record = @(Get-FelixHistory -HistoryId $HistoryId | Select-Object -First 1)
    if ($record.Count -ne 1) {
        throw "History operation '$HistoryId' was not found."
    }
    $rule = Get-FelixRuleRequired -RuleId $record[0].ruleId
    if (-not (Test-FelixAdministrator) -and $rule.requiresAdmin) {
        return Invoke-FelixElevatedRequest -Action 'Restore' -Payload @{
            historyId = $HistoryId
            force = [bool]$Force
        }
    }

    return Invoke-FelixRestoreLocal -HistoryId $HistoryId -Force:$Force
}

function Invoke-FelixRestoreLocal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HistoryId,

        [switch]$Force
    )

    if (-not $script:OperationMutex.WaitOne(0)) {
        throw 'Another 稳优 StableTune operation is already running.'
    }

    try {
    Clear-FelixRuntimeCaches
    $record = @(Get-FelixHistory -HistoryId $HistoryId | Select-Object -First 1)
    if ($record.Count -ne 1) {
        throw "History operation '$HistoryId' was not found."
    }
    if ($record[0].status -notin $script:RestorableStatuses) {
        throw "History operation '$HistoryId' is not restorable from status '$($record[0].status)'."
    }

    $rule = Get-FelixRuleRequired -RuleId $record[0].ruleId
    Test-FelixSnapshotIntegrity -Path $record[0].snapshotPath -ExpectedHash ([string]$record[0].snapshotHash) | Out-Null
    $snapshot = Read-FelixSnapshot -Path $record[0].snapshotPath
    $snapshotRollbackMode = if ($snapshot.Contains('rollbackMode')) { [string]$snapshot.rollbackMode } else { 'DualRollback' }
    $snapshotRequiresRestorePoint = if ($snapshot.Contains('systemRestorePointRequired')) { [bool]$snapshot.systemRestorePointRequired } else { $true }
    $recoveryRestore = $record[0].status -notin @('Applied', 'RestoreFailed')
    if (-not $Force -and -not $recoveryRestore -and -not (Test-FelixHandlerRestoreConflict -Rule $rule -Snapshot $snapshot)) {
        throw 'Restore skipped because the current state no longer matches the applied state.'
    }

    Add-FelixHistoryEvent -Record ([ordered]@{
        historyId = $HistoryId
        operationId = $HistoryId
        ruleId = $rule.id
        ruleName = $rule.name
        risk = $rule.risk
        requiresRestart = $rule.requiresRestart
        eventType = 'restore_started'
        status = 'Restoring'
        timestamp = (Get-Date).ToString('o')
        message = 'Restoring operation.'
        snapshotPath = $record[0].snapshotPath
    })

    Add-FelixLog -Event 'restore.started' -Message "Restoring '$($rule.name)'." -RuleId $rule.id -HistoryId $HistoryId
    Write-FelixRollbackJournal -HistoryId $HistoryId -RuleId $rule.id -Event 'restore_started' -SnapshotPath $record[0].snapshotPath -SnapshotHash ([string]$record[0].snapshotHash) -RollbackMode $snapshotRollbackMode -SystemRestorePointRequired $snapshotRequiresRestorePoint -Message 'Restore request started.'

    try {
        Invoke-FelixHandlerRestore -Rule $rule -Snapshot $snapshot -OperationId $HistoryId
        if (-not (Test-FelixHandlerRestored -Rule $rule -Snapshot $snapshot)) {
            throw 'Restore verification did not match the original state.'
        }

        Add-FelixHistoryEvent -Record ([ordered]@{
            historyId = $HistoryId
            operationId = $HistoryId
            ruleId = $rule.id
            ruleName = $rule.name
            risk = $rule.risk
            requiresRestart = $rule.requiresRestart
            eventType = 'restored'
            status = 'Restored'
            timestamp = (Get-Date).ToString('o')
            message = 'Original state restored and verified.'
            snapshotPath = $record[0].snapshotPath
        })
        Add-FelixLog -Event 'restore.succeeded' -Message "Restored and verified '$($rule.name)'." -RuleId $rule.id -HistoryId $HistoryId
        Write-FelixRollbackJournal -HistoryId $HistoryId -RuleId $rule.id -Event 'restore_verified' -SnapshotPath $record[0].snapshotPath -SnapshotHash ([string]$record[0].snapshotHash) -RollbackMode $snapshotRollbackMode -SystemRestorePointRequired $snapshotRequiresRestorePoint -Message 'Original state restored and verified.'
        if (@(Get-FelixCrashGuard -OperationId $HistoryId).Count -gt 0) {
            Complete-FelixCrashGuard -OperationId $HistoryId
        }
        Clear-FelixRuntimeCaches

        return [ordered]@{
            success = $true
            historyId = $HistoryId
            ruleId = $rule.id
            status = 'Restored'
            requiresRestart = $rule.requiresRestart
        }
    }
    catch {
        Add-FelixHistoryEvent -Record ([ordered]@{
            historyId = $HistoryId
            operationId = $HistoryId
            ruleId = $rule.id
            ruleName = $rule.name
            risk = $rule.risk
            requiresRestart = $rule.requiresRestart
            eventType = 'restore_failed'
            status = 'RestoreFailed'
            timestamp = (Get-Date).ToString('o')
            message = $_.Exception.Message
            snapshotPath = $record[0].snapshotPath
        })
        Add-FelixLog -Level Error -Event 'restore.failed' -Message $_.Exception.Message -RuleId $rule.id -HistoryId $HistoryId
        Write-FelixRollbackJournal -HistoryId $HistoryId -RuleId $rule.id -Event 'restore_failed' -SnapshotPath $record[0].snapshotPath -SnapshotHash ([string]$record[0].snapshotHash) -RollbackMode $snapshotRollbackMode -SystemRestorePointRequired $snapshotRequiresRestorePoint -Message $_.Exception.Message
        Clear-FelixRuntimeCaches
        throw
    }
    }
    finally {
        $script:OperationMutex.ReleaseMutex()
    }
}

function Invoke-FelixRestoreAll {
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    $records = @(Get-FelixHistory -RestorableOnly | Sort-Object appliedAt -Descending)
    $results = @()
    foreach ($record in $records) {
        try {
            $results += Invoke-FelixRestore -HistoryId $record.historyId -Force:$Force
        }
        catch {
            $results += [ordered]@{
                success = $false
                historyId = $record.historyId
                ruleId = $record.ruleId
                status = 'SkippedOrFailed'
                message = $_.Exception.Message
            }
        }
    }

    return @($results)
}

function Get-FelixSystemStatus {
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    $cacheKey = Get-FelixStatePath
    if (
        -not $Force -and
        $script:SystemStatusCache -and
        $script:SystemStatusCacheAt -and
        $script:SystemStatusCacheKey -eq $cacheKey -and
        ((Get-Date) - $script:SystemStatusCacheAt).TotalSeconds -lt $script:UiSystemStatusCacheSeconds
    ) {
        return $script:SystemStatusCache
    }

    $historyView = Get-FelixHistoryView
    $powerScheme = try {
        Get-FelixActivePowerScheme
    }
    catch {
        [ordered]@{
            guid = 'Unavailable'
            name = 'Unavailable'
        }
    }
    $rollback = Test-FelixDualRollbackCapability
    $crashRecovery = Get-FelixCrashRecoveryStatus

    $status = [ordered]@{
        appVersion = $script:ModuleVersion
        os = [Environment]::OSVersion.VersionString
        isAdministrator = Test-FelixAdministrator
        statePath = Get-FelixStatePath
        activePowerPlan = $powerScheme.name
        activePowerPlanGuid = $powerScheme.guid
        historyCount = $historyView.history.Count
        restorableCount = $historyView.restorable.Count
        rollbackAvailable = $rollback.available
        rollbackMode = $rollback.mode
        rollbackRequiresSystemRestorePoint = $rollback.requiresSystemRestorePoint
        rollbackMessage = $rollback.message
        snapshotRoot = $rollback.snapshotRoot
        snapshotAvailable = $rollback.snapshotAvailable
        snapshotMessage = $rollback.snapshotMessage
        restorePointAvailable = $rollback.restorePointAvailable
        restorePointMessage = $rollback.restorePointMessage
        restorePointId = $rollback.restorePointId
        restorePointCreatedAt = $rollback.restorePointCreatedAt
        crashRecovery = $crashRecovery
        session = Get-FelixSession
    }
    $script:SystemStatusCache = $status
    $script:SystemStatusCacheAt = Get-Date
    $script:SystemStatusCacheKey = $cacheKey
    return $script:SystemStatusCache
}

function Clear-FelixHistoryIndex {
    [CmdletBinding()]
    param()

    Initialize-FelixState
    $path = Get-FelixStatePath 'history.jsonl'
    Set-Content -LiteralPath $path -Value '' -Encoding utf8
}

function Clear-FelixQuarantine {
    [CmdletBinding()]
    param()

    Initialize-FelixState
    $path = Get-FelixStatePath 'quarantine'
    Get-ChildItem -LiteralPath $path -Force | Remove-Item -Recurse -Force
}

function New-FelixRequirementResult {
    param(
        [bool]$Available,
        [string]$Message
    )

    return [ordered]@{
        available = $Available
        message = $Message
    }
}

function Test-FelixRulePrerequisite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Rule,

        [hashtable]$Options = @{}
    )

    switch ($Rule.handler) {
        'PowerPlan' {
            if (-not (Get-Command powercfg.exe -ErrorAction SilentlyContinue)) {
                return New-FelixRequirementResult $false 'powercfg.exe is unavailable.'
            }
            try {
                $null = Get-ActivePowerSchemeGuid
                return New-FelixRequirementResult $true 'Active power scheme is readable.'
            }
            catch {
                return New-FelixRequirementResult $false $_.Exception.Message
            }
        }
        'ProcessorMinimum' {
            return Test-PowerSettingPrerequisite -SettingName 'Processor'
        }
        'CoreParkingMinimum' {
            return Test-PowerSettingPrerequisite -SettingName 'CoreParking'
        }
        'CpuIdleDisable' {
            return Test-PowerSettingPrerequisite -SettingName 'CpuIdle'
        }
        'UsbSelectiveSuspend' {
            return Test-PowerSettingPrerequisite -SettingName 'Usb'
        }
        'PcieAspm' {
            return Test-PowerSettingPrerequisite -SettingName 'Pcie'
        }
        'PrioritySeparation' {
            return New-FelixRequirementResult (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl') 'PriorityControl key is available.'
        }
        'MultimediaProfile' {
            return New-FelixRequirementResult (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile') 'Multimedia SystemProfile key is available.'
        }
        'BcdTimers' {
            if (-not (Get-Command bcdedit.exe -ErrorAction SilentlyContinue)) {
                return New-FelixRequirementResult $false 'bcdedit.exe is unavailable.'
            }
            return New-FelixRequirementResult $true 'bcdedit.exe is available.'
        }
        'NicPower' {
            if (-not $Options.ContainsKey('AdapterName') -or [string]::IsNullOrWhiteSpace([string]$Options.AdapterName)) {
                return New-FelixRequirementResult $false 'AdapterName is required.'
            }
            $adapter = Get-NetAdapter -Name ([string]$Options.AdapterName) -ErrorAction SilentlyContinue
            if (-not $adapter) {
                return New-FelixRequirementResult $false 'The selected network adapter was not found.'
            }
            return New-FelixRequirementResult $true 'The selected network adapter is available.'
        }
        'TcpAutotuning' {
            return New-FelixRequirementResult ([bool](Get-Command netsh.exe -ErrorAction SilentlyContinue)) 'netsh.exe availability check completed.'
        }
        'TcpTimestamps' {
            return New-FelixRequirementResult ([bool](Get-Command netsh.exe -ErrorAction SilentlyContinue)) 'netsh.exe availability check completed.'
        }
        'DnsProfile' {
            if (-not $Options.ContainsKey('InterfaceAlias') -or [string]::IsNullOrWhiteSpace([string]$Options.InterfaceAlias)) {
                return New-FelixRequirementResult $false 'InterfaceAlias is required.'
            }
            if (-not (Get-NetAdapter -Name ([string]$Options.InterfaceAlias) -ErrorAction SilentlyContinue)) {
                return New-FelixRequirementResult $false 'The selected network interface was not found.'
            }
            if (-not [bool]$Options.Dhcp -and (-not $Options.ContainsKey('DnsServers') -or @($Options.DnsServers).Count -eq 0)) {
                return New-FelixRequirementResult $false 'DnsServers is required when DHCP DNS is disabled.'
            }
            return New-FelixRequirementResult $true 'The selected network interface is available.'
        }
        'AmdDynamicPstate' {
            try {
                $keyPath = Get-AmdDisplayDriverKey
                return New-FelixRequirementResult $true "Detected AMD driver key $keyPath."
            }
            catch {
                return New-FelixRequirementResult $false $_.Exception.Message
            }
        }
        'HeterogeneousPowerPolicy' {
            try {
                $snapshot = Get-HeterogeneousPowerPolicySnapshot
                return New-FelixRequirementResult $true "已从 $($snapshot.before.baselineLabel) 解析完整默认基线。"
            }
            catch {
                return New-FelixRequirementResult $false $_.Exception.Message
            }
        }
        'StartupItem' {
            $validation = Test-StartupOptions -Options $Options
            return New-FelixRequirementResult $validation.available $validation.message
        }
        'ServiceState' {
            if (-not $Options.ContainsKey('ServiceName')) {
                return New-FelixRequirementResult $false 'ServiceName is required.'
            }
            $serviceName = [string]$Options.ServiceName
            if ($serviceName -notin $script:AllowedServices) {
                return New-FelixRequirementResult $false "Service '$serviceName' is not in the allowlist."
            }
            if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
                return New-FelixRequirementResult $false "Service '$serviceName' was not found."
            }
            return New-FelixRequirementResult $true "Service '$serviceName' is available."
        }
        'TempQuarantine' {
            $tempPath = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
            return New-FelixRequirementResult (Test-Path -LiteralPath $tempPath) 'User temp path availability check completed.'
        }
        'DeviceAffinity' {
            if (-not $Options.ContainsKey('RegistryPath') -and -not $Options.ContainsKey('InstanceId')) {
                return New-FelixRequirementResult $false 'RegistryPath or InstanceId is required.'
            }
            if (-not $Options.ContainsKey('CpuMask')) {
                return New-FelixRequirementResult $false 'CpuMask is required.'
            }
            try {
                $path = Resolve-DeviceAffinityPath -Options $Options
                return New-FelixRequirementResult (Test-Path -LiteralPath $path) "Device affinity key is available at $path."
            }
            catch {
                return New-FelixRequirementResult $false $_.Exception.Message
            }
        }
        'RegistrySet' {
            return Test-RegistrySetPrerequisite -Rule $Rule -Options $Options
        }
        'NetworkInterruptModeration' {
            if (-not $Options.ContainsKey('AdapterName') -or [string]::IsNullOrWhiteSpace([string]$Options.AdapterName)) {
                return New-FelixRequirementResult $false 'AdapterName is required.'
            }
            try {
                $property = Get-NetworkInterruptModerationProperty -AdapterName ([string]$Options.AdapterName)
                return New-FelixRequirementResult $true "Interrupt moderation property '$($property.DisplayName)' is available."
            }
            catch {
                return New-FelixRequirementResult $false $_.Exception.Message
            }
        }
        'ServiceFixed' {
            if (-not $Rule.Contains('serviceName') -or [string]::IsNullOrWhiteSpace([string]$Rule.serviceName)) {
                return New-FelixRequirementResult $false 'No service name is defined.'
            }
            $serviceName = [string]$Rule.serviceName
            if ($serviceName -notin $script:AllowedServices) {
                return New-FelixRequirementResult $false "Service '$serviceName' is not in the allowlist."
            }
            if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
                return New-FelixRequirementResult $false "Service '$serviceName' was not found."
            }
            return New-FelixRequirementResult $true "Service '$serviceName' is available."
        }
        default {
            return New-FelixRequirementResult $false "Unknown handler '$($Rule.handler)'."
        }
    }
}

function Get-FelixHandlerChangeSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Rule,

        [hashtable]$Options = @{}
    )

    switch ($Rule.handler) {
        'PowerPlan' {
            $active = Get-FelixActivePowerScheme
            return @("Duplicate the active power scheme '$($active.name)' as StableTune Low Latency.", 'Activate the duplicate scheme.')
        }
        'ProcessorMinimum' {
            return @('Set processor minimum state on AC to 100%.')
        }
        'CoreParkingMinimum' {
            return @('Set processor core parking minimum cores on AC to 100%.')
        }
        'CpuIdleDisable' {
            return @('Set processor idle disable on AC to enabled.')
        }
        'UsbSelectiveSuspend' {
            return @('Set USB selective suspend on AC to disabled.')
        }
        'PcieAspm' {
            return @('Set PCI Express link state power management on AC to off.')
        }
        'PrioritySeparation' {
            return @('Set HKLM PriorityControl Win32PrioritySeparation to 40.')
        }
        'MultimediaProfile' {
            return @('Set NetworkThrottlingIndex to 0xFFFFFFFF.', 'Set SystemResponsiveness to 0.')
        }
        'BcdTimers' {
            return @('Set useplatformtick=no.', 'Set disabledynamictick=yes.')
        }
        'NicPower' {
            return @("Disable power saving on adapter '$($Options.AdapterName)'.")
        }
        'TcpAutotuning' {
            return @('Set TCP receive window auto-tuning to experimental.')
        }
        'TcpTimestamps' {
            return @('Enable TCP timestamps.')
        }
        'DnsProfile' {
            if ([bool]$Options.Dhcp) {
                return @("Reset DNS for '$($Options.InterfaceAlias)' to DHCP.")
            }
            return @("Set DNS for '$($Options.InterfaceAlias)' to $((@($Options.DnsServers) -join ', ')).")
        }
        'AmdDynamicPstate' {
            return @('Set DisableDynamicPstate=1 on the detected AMD driver key.')
        }
        'HeterogeneousPowerPolicy' {
            return @(
                'Restore HETEROPOLICY, SCHEDPOLICY, SHORTSCHEDPOLICY and PERFBOOSTMODE from a Windows built-in plan baseline.',
                'Apply the baseline to AC and DC values without changing the active scheme.'
            )
        }
        'StartupItem' {
            return @("Disable startup item '$($Options.ValueName)'.")
        }
        'ServiceState' {
            return @("Set service '$($Options.ServiceName)' startup type to '$($Options.StartupType)'.")
        }
        'TempQuarantine' {
            return @('Move eligible user temp files into the reversible quarantine.')
        }
        'DeviceAffinity' {
            return @("Set DevicePolicy=4 and CPU mask 0x$((ConvertTo-CpuMask -Value $Options.CpuMask).ToString('X')) for the selected device.")
        }
        'RegistrySet' {
            if ($Rule.Contains('changeSummary')) {
                return @($Rule.changeSummary)
            }
            return @('Apply the configured registry values.')
        }
        'NetworkInterruptModeration' {
            return @("Disable interrupt moderation on adapter '$($Options.AdapterName)'.")
        }
        'ServiceFixed' {
            return @("Set service '$($Rule.serviceName)' startup type to '$($Rule.targetStartupType)' and stop it if requested.")
        }
        default {
            return @()
        }
    }
}

function Get-FelixHandlerSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Rule,

        [hashtable]$Options = @{},

        [Parameter(Mandatory)]
        [string]$OperationId
    )

    switch ($Rule.handler) {
        'PowerPlan' { return Get-PowerPlanSnapshot }
        'ProcessorMinimum' { return Get-PowerSettingSnapshot -SettingName 'Processor' }
        'CoreParkingMinimum' { return Get-PowerSettingSnapshot -SettingName 'CoreParking' }
        'CpuIdleDisable' { return Get-PowerSettingSnapshot -SettingName 'CpuIdle' }
        'UsbSelectiveSuspend' { return Get-PowerSettingSnapshot -SettingName 'Usb' }
        'PcieAspm' { return Get-PowerSettingSnapshot -SettingName 'Pcie' }
        'PrioritySeparation' { return Get-PrioritySeparationSnapshot }
        'MultimediaProfile' { return Get-MultimediaProfileSnapshot }
        'BcdTimers' { return Get-BcdTimerSnapshot }
        'NicPower' { return Get-NicPowerSnapshot -AdapterName ([string]$Options.AdapterName) }
        'TcpAutotuning' { return Get-TcpGlobalSnapshot }
        'TcpTimestamps' { return Get-TcpGlobalSnapshot }
        'DnsProfile' { return Get-DnsProfileSnapshot -InterfaceAlias ([string]$Options.InterfaceAlias) }
        'AmdDynamicPstate' { return Get-AmdDynamicPstateSnapshot }
        'HeterogeneousPowerPolicy' { return Get-HeterogeneousPowerPolicySnapshot }
        'StartupItem' { return Get-StartupItemSnapshot -Options $Options -OperationId $OperationId }
        'ServiceState' { return Get-ServiceStateSnapshot -ServiceName ([string]$Options.ServiceName) }
        'TempQuarantine' { return Get-TempQuarantineSnapshot -OperationId $OperationId }
        'DeviceAffinity' { return Get-DeviceAffinitySnapshot -Options $Options }
        'RegistrySet' { return Get-RegistrySetSnapshot -Rule $Rule -Options $Options }
        'NetworkInterruptModeration' { return Get-NetworkInterruptModerationSnapshot -AdapterName ([string]$Options.AdapterName) }
        'ServiceFixed' {
            $serviceOptions = Get-ServiceFixedOptions -Rule $Rule
            return Get-ServiceStateSnapshot -ServiceName ([string]$serviceOptions.ServiceName)
        }
        default { throw "Unknown snapshot handler '$($Rule.handler)'." }
    }
}

function Invoke-FelixHandlerApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Rule,

        [hashtable]$Options = @{},

        [Parameter(Mandatory)]
        [hashtable]$Snapshot,

        [Parameter(Mandatory)]
        [string]$OperationId
    )

    switch ($Rule.handler) {
        'PowerPlan' { return Invoke-PowerPlanApply -Snapshot $Snapshot }
        'ProcessorMinimum' { return Invoke-PowerSettingApply -Snapshot $Snapshot -Value 100 }
        'CoreParkingMinimum' { return Invoke-PowerSettingApply -Snapshot $Snapshot -Value 100 }
        'CpuIdleDisable' { return Invoke-PowerSettingApply -Snapshot $Snapshot -Value 1 }
        'UsbSelectiveSuspend' { return Invoke-PowerSettingApply -Snapshot $Snapshot -Value 0 }
        'PcieAspm' { return Invoke-PowerSettingApply -Snapshot $Snapshot -Value 0 }
        'PrioritySeparation' { return Invoke-PrioritySeparationApply -Snapshot $Snapshot }
        'MultimediaProfile' { return Invoke-MultimediaProfileApply -Snapshot $Snapshot }
        'BcdTimers' { return Invoke-BcdTimerApply -Snapshot $Snapshot }
        'NicPower' { return Invoke-NicPowerApply -Snapshot $Snapshot }
        'TcpAutotuning' { return Invoke-TcpGlobalApply -Snapshot $Snapshot -AutoTuning }
        'TcpTimestamps' { return Invoke-TcpGlobalApply -Snapshot $Snapshot -Timestamps }
        'DnsProfile' { return Invoke-DnsProfileApply -Snapshot $Snapshot -Options $Options }
        'AmdDynamicPstate' { return Invoke-AmdDynamicPstateApply -Snapshot $Snapshot }
        'HeterogeneousPowerPolicy' { return Invoke-HeterogeneousPowerPolicyApply -Snapshot $Snapshot }
        'StartupItem' { return Invoke-StartupItemApply -Snapshot $Snapshot -OperationId $OperationId }
        'ServiceState' { return Invoke-ServiceStateApply -Snapshot $Snapshot -Options $Options }
        'TempQuarantine' { return Invoke-TempQuarantineApply -Snapshot $Snapshot }
        'DeviceAffinity' { return Invoke-DeviceAffinityApply -Snapshot $Snapshot -Options $Options }
        'RegistrySet' { return Invoke-RegistrySetApply -Rule $Rule -Snapshot $Snapshot -Options $Options }
        'NetworkInterruptModeration' { return Invoke-NetworkInterruptModerationApply -Snapshot $Snapshot }
        'ServiceFixed' {
            $serviceOptions = Get-ServiceFixedOptions -Rule $Rule
            return Invoke-ServiceStateApply -Snapshot $Snapshot -Options $serviceOptions
        }
        default { throw "Unknown apply handler '$($Rule.handler)'." }
    }
}

function Test-FelixHandlerApplied {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Rule,

        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    switch ($Rule.handler) {
        'PowerPlan' { return Test-PowerPlanApplied -Snapshot $Snapshot }
        'ProcessorMinimum' { return Test-PowerSettingApplied -Snapshot $Snapshot }
        'CoreParkingMinimum' { return Test-PowerSettingApplied -Snapshot $Snapshot }
        'CpuIdleDisable' { return Test-PowerSettingApplied -Snapshot $Snapshot }
        'UsbSelectiveSuspend' { return Test-PowerSettingApplied -Snapshot $Snapshot }
        'PcieAspm' { return Test-PowerSettingApplied -Snapshot $Snapshot }
        'PrioritySeparation' { return Test-RegistrySnapshotCurrent -Snapshot $Snapshot.after }
        'MultimediaProfile' {
            return (@($Snapshot.after.registry | ForEach-Object { Test-RegistrySnapshotCurrent -Snapshot $_ }) -notcontains $false)
        }
        'BcdTimers' { return Test-BcdTimerApplied -Snapshot $Snapshot }
        'NicPower' { return Test-NicPowerApplied -Snapshot $Snapshot }
        'TcpAutotuning' { return Test-TcpGlobalApplied -Snapshot $Snapshot -Property 'AutoTuning' }
        'TcpTimestamps' { return Test-TcpGlobalApplied -Snapshot $Snapshot -Property 'Timestamps' }
        'DnsProfile' { return Test-DnsProfileApplied -Snapshot $Snapshot }
        'AmdDynamicPstate' { return Test-RegistrySnapshotCurrent -Snapshot $Snapshot.after }
        'HeterogeneousPowerPolicy' { return Test-HeterogeneousPowerPolicyApplied -Snapshot $Snapshot }
        'StartupItem' { return Test-StartupItemApplied -Snapshot $Snapshot }
        'ServiceState' { return Test-ServiceStateApplied -Snapshot $Snapshot }
        'TempQuarantine' { return Test-TempQuarantineApplied -Snapshot $Snapshot }
        'DeviceAffinity' { return Test-DeviceAffinityApplied -Snapshot $Snapshot }
        'RegistrySet' { return Test-RegistrySetApplied -Snapshot $Snapshot }
        'NetworkInterruptModeration' { return Test-NetworkInterruptModerationApplied -Snapshot $Snapshot }
        'ServiceFixed' { return Test-ServiceStateApplied -Snapshot $Snapshot }
        default { return $false }
    }
}

function Test-FelixHandlerRestoreConflict {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Rule,

        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    switch ($Rule.handler) {
        'ProcessorMinimum' { return Test-PowerSettingRestoreConflict -Snapshot $Snapshot }
        'CoreParkingMinimum' { return Test-PowerSettingRestoreConflict -Snapshot $Snapshot }
        'CpuIdleDisable' { return Test-PowerSettingRestoreConflict -Snapshot $Snapshot }
        'UsbSelectiveSuspend' { return Test-PowerSettingRestoreConflict -Snapshot $Snapshot }
        'PcieAspm' { return Test-PowerSettingRestoreConflict -Snapshot $Snapshot }
        'PowerPlan' { return Test-PowerPlanRestoreConflict -Snapshot $Snapshot }
        'PrioritySeparation' { return Test-RegistryRestoreConflict -Snapshot $Snapshot -Before $Snapshot.before -After $Snapshot.after }
        'MultimediaProfile' {
            return (@(@($Snapshot.before.registry) + @($Snapshot.after.registry) | ForEach-Object { Test-RegistrySnapshotCurrent -Snapshot $_ }) -notcontains $false)
        }
        'BcdTimers' { return Test-BcdTimerRestoreConflict -Snapshot $Snapshot }
        'NicPower' { return Test-NicPowerRestoreConflict -Snapshot $Snapshot }
        'TcpAutotuning' { return Test-TcpGlobalRestoreConflict -Snapshot $Snapshot }
        'TcpTimestamps' { return Test-TcpGlobalRestoreConflict -Snapshot $Snapshot }
        'DnsProfile' { return Test-DnsProfileRestoreConflict -Snapshot $Snapshot }
        'AmdDynamicPstate' { return Test-RegistryRestoreConflict -Snapshot $Snapshot -Before $Snapshot.before -After $Snapshot.after }
        'HeterogeneousPowerPolicy' { return Test-HeterogeneousPowerPolicyRestoreConflict -Snapshot $Snapshot }
        'StartupItem' { return Test-StartupItemRestoreConflict -Snapshot $Snapshot }
        'ServiceState' { return Test-ServiceStateRestoreConflict -Snapshot $Snapshot }
        'TempQuarantine' { return Test-TempQuarantineRestoreConflict -Snapshot $Snapshot }
        'DeviceAffinity' { return Test-DeviceAffinityRestoreConflict -Snapshot $Snapshot }
        'RegistrySet' { return Test-RegistrySetRestoreConflict -Snapshot $Snapshot }
        'NetworkInterruptModeration' { return Test-NetworkInterruptModerationRestoreConflict -Snapshot $Snapshot }
        'ServiceFixed' { return Test-ServiceStateRestoreConflict -Snapshot $Snapshot }
        default { return $true }
    }
}

function Test-FelixHandlerRestored {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Rule,

        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    switch ($Rule.handler) {
        'PowerPlan' { return Test-PowerPlanRestored -Snapshot $Snapshot }
        'ProcessorMinimum' { return Test-PowerSettingRestored -Snapshot $Snapshot }
        'CoreParkingMinimum' { return Test-PowerSettingRestored -Snapshot $Snapshot }
        'CpuIdleDisable' { return Test-PowerSettingRestored -Snapshot $Snapshot }
        'UsbSelectiveSuspend' { return Test-PowerSettingRestored -Snapshot $Snapshot }
        'PcieAspm' { return Test-PowerSettingRestored -Snapshot $Snapshot }
        'PrioritySeparation' { return Test-RegistrySnapshotCurrent -Snapshot $Snapshot.before }
        'MultimediaProfile' {
            return (@(@($Snapshot.before.registry) | ForEach-Object { Test-RegistrySnapshotCurrent -Snapshot $_ }) -notcontains $false)
        }
        'BcdTimers' { return Test-BcdTimerRestored -Snapshot $Snapshot }
        'NicPower' { return Test-NicPowerRestored -Snapshot $Snapshot }
        'TcpAutotuning' { return Test-TcpGlobalRestored -Snapshot $Snapshot }
        'TcpTimestamps' { return Test-TcpGlobalRestored -Snapshot $Snapshot }
        'DnsProfile' { return Test-DnsProfileRestored -Snapshot $Snapshot }
        'AmdDynamicPstate' { return Test-RegistrySnapshotCurrent -Snapshot $Snapshot.before }
        'HeterogeneousPowerPolicy' { return Test-HeterogeneousPowerPolicyRestored -Snapshot $Snapshot }
        'StartupItem' { return Test-StartupItemRestored -Snapshot $Snapshot }
        'ServiceState' { return Test-ServiceStateRestored -Snapshot $Snapshot }
        'TempQuarantine' { return Test-TempQuarantineRestored -Snapshot $Snapshot }
        'DeviceAffinity' { return Test-DeviceAffinityRestored -Snapshot $Snapshot }
        'RegistrySet' { return Test-RegistrySetRestored -Snapshot $Snapshot }
        'NetworkInterruptModeration' { return Test-NetworkInterruptModerationRestored -Snapshot $Snapshot }
        'ServiceFixed' { return Test-ServiceStateRestored -Snapshot $Snapshot }
        default { return $false }
    }
}

function Invoke-FelixHandlerRestore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Rule,

        [Parameter(Mandatory)]
        [hashtable]$Snapshot,

        [Parameter(Mandatory)]
        [string]$OperationId
    )

    switch ($Rule.handler) {
        'PowerPlan' { return Invoke-PowerPlanRestore -Snapshot $Snapshot }
        'ProcessorMinimum' { return Invoke-PowerSettingRestore -Snapshot $Snapshot }
        'CoreParkingMinimum' { return Invoke-PowerSettingRestore -Snapshot $Snapshot }
        'CpuIdleDisable' { return Invoke-PowerSettingRestore -Snapshot $Snapshot }
        'UsbSelectiveSuspend' { return Invoke-PowerSettingRestore -Snapshot $Snapshot }
        'PcieAspm' { return Invoke-PowerSettingRestore -Snapshot $Snapshot }
        'PrioritySeparation' { return Invoke-RegistrySnapshotRestore -Snapshot $Snapshot.before }
        'MultimediaProfile' {
            foreach ($entry in @($Snapshot.before.registry)) {
                Invoke-RegistrySnapshotRestore -Snapshot $entry
            }
            return
        }
        'BcdTimers' { return Invoke-BcdTimerRestore -Snapshot $Snapshot }
        'NicPower' { return Invoke-NicPowerRestore -Snapshot $Snapshot }
        'TcpAutotuning' { return Invoke-TcpGlobalRestore -Snapshot $Snapshot }
        'TcpTimestamps' { return Invoke-TcpGlobalRestore -Snapshot $Snapshot }
        'DnsProfile' { return Invoke-DnsProfileRestore -Snapshot $Snapshot }
        'AmdDynamicPstate' { return Invoke-RegistrySnapshotRestore -Snapshot $Snapshot.before }
        'HeterogeneousPowerPolicy' { return Invoke-HeterogeneousPowerPolicyRestore -Snapshot $Snapshot }
        'StartupItem' { return Invoke-StartupItemRestore -Snapshot $Snapshot }
        'ServiceState' { return Invoke-ServiceStateRestore -Snapshot $Snapshot }
        'TempQuarantine' { return Invoke-TempQuarantineRestore -Snapshot $Snapshot }
        'DeviceAffinity' { return Invoke-RegistrySnapshotRestore -Snapshot $Snapshot.before }
        'RegistrySet' { return Invoke-RegistrySetRestore -Snapshot $Snapshot }
        'NetworkInterruptModeration' { return Invoke-NetworkInterruptModerationRestore -Snapshot $Snapshot }
        'ServiceFixed' { return Invoke-ServiceStateRestore -Snapshot $Snapshot }
        default { throw "Unknown restore handler '$($Rule.handler)'." }
    }
}

function Get-StaticPowerSettingDefinition {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Processor', 'CoreParking', 'CpuIdle', 'Usb', 'Pcie')]
        [string]$Name
    )

    switch ($Name) {
        'Processor' {
            return [ordered]@{
                subgroupGuid = '54533251-82be-4824-96c1-47b60b740d00'
                settingGuid = '893dee8e-2bef-41e0-89c6-b55d0929964c'
                label = 'Processor minimum state'
            }
        }
        'CoreParking' {
            return [ordered]@{
                subgroupGuid = '54533251-82be-4824-96c1-47b60b740d00'
                settingGuid = '0cc5b647-c1df-4637-891a-dec35c318583'
                label = 'Processor core parking minimum cores'
            }
        }
        'CpuIdle' {
            return [ordered]@{
                subgroupGuid = '54533251-82be-4824-96c1-47b60b740d00'
                settingGuid = '5d76a2ca-e8c0-402f-a133-2158492d58ad'
                label = 'Processor idle disable'
            }
        }
        'Usb' {
            return [ordered]@{
                subgroupGuid = '2a737441-1930-4402-8d77-b2bebba308a3'
                settingGuid = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
                label = 'USB selective suspend'
            }
        }
        'Pcie' {
            return [ordered]@{
                subgroupGuid = '501a4d13-42af-4429-9fd1-a8218c268e20'
                settingGuid = 'ee12f906-d277-404b-b6da-e5fa1a576df5'
                label = 'PCI Express link state power management'
            }
        }
    }
}

function Get-ActivePowerSchemeGuid {
    return (Get-FelixActivePowerScheme).guid
}

function Get-PowerSchemeByName {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $output = Invoke-FelixNative -FilePath 'powercfg.exe' -ArgumentList @('/list')
    foreach ($line in ($output -split "`r?`n")) {
        if ($line -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s+\(([^)]*)\)') {
            if ($Matches[2].Trim() -eq $Name) {
                return $Matches[1].ToLowerInvariant()
            }
        }
    }
    return $null
}

function Get-PowerSettingRegistryState {
    param(
        [Parameter(Mandatory)]
        [string]$SchemeGuid,

        [Parameter(Mandatory)]
        [string]$SubgroupGuid,

        [Parameter(Mandatory)]
        [string]$SettingGuid
    )

    $path = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$SchemeGuid\$SubgroupGuid\$SettingGuid"
    $ac = Get-RegistryValueSnapshot -Path $path -Name 'ACSettingIndex'
    $dc = Get-RegistryValueSnapshot -Path $path -Name 'DCSettingIndex'
    return [ordered]@{
        path = $path
        ac = $ac
        dc = $dc
    }
}

function Get-PowerSettingSnapshot {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Processor', 'CoreParking', 'CpuIdle', 'Usb', 'Pcie')]
        [string]$SettingName
    )

    $definition = Get-StaticPowerSettingDefinition -Name $SettingName
    $schemeGuid = Get-ActivePowerSchemeGuid
    $state = Get-PowerSettingRegistryState -SchemeGuid $schemeGuid -SubgroupGuid $definition.subgroupGuid -SettingGuid $definition.settingGuid
    return [ordered]@{
        schemeGuid = $schemeGuid
        subgroupGuid = $definition.subgroupGuid
        settingGuid = $definition.settingGuid
        label = $definition.label
        ac = $state.ac
        dc = $state.dc
    }
}

function Set-PowerSettingAcValue {
    param(
        [Parameter(Mandatory)]
        [string]$SchemeGuid,

        [Parameter(Mandatory)]
        [string]$SubgroupGuid,

        [Parameter(Mandatory)]
        [string]$SettingGuid,

        [Parameter(Mandatory)]
        [int]$Value
    )

    Invoke-FelixNative -FilePath 'powercfg.exe' -ArgumentList @(
        '/setacvalueindex',
        $SchemeGuid,
        $SubgroupGuid,
        $SettingGuid,
        [string]$Value
    ) | Out-Null
    Invoke-FelixNative -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $SchemeGuid) | Out-Null
    Clear-FelixActivePowerSchemeCache
}

function Invoke-PowerSettingApply {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot,

        [Parameter(Mandatory)]
        [int]$Value
    )

    Set-PowerSettingAcValue -SchemeGuid $Snapshot.before.schemeGuid -SubgroupGuid $Snapshot.before.subgroupGuid -SettingGuid $Snapshot.before.settingGuid -Value $Value
    $after = Get-PowerSettingRegistryState -SchemeGuid $Snapshot.before.schemeGuid -SubgroupGuid $Snapshot.before.subgroupGuid -SettingGuid $Snapshot.before.settingGuid
    return [ordered]@{
        schemeGuid = $Snapshot.before.schemeGuid
        subgroupGuid = $Snapshot.before.subgroupGuid
        settingGuid = $Snapshot.before.settingGuid
        expectedAcValue = $Value
        ac = $after.ac
        dc = $after.dc
    }
}

function Test-PowerSettingPrerequisite {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Processor', 'CoreParking', 'CpuIdle', 'Usb', 'Pcie')]
        [string]$SettingName
    )

    try {
        $snapshot = Get-PowerSettingSnapshot -SettingName $SettingName
        return New-FelixRequirementResult $true "$($snapshot.label) is available in the active scheme."
    }
    catch {
        return New-FelixRequirementResult $false $_.Exception.Message
    }
}

function Test-PowerSettingApplied {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $current = Get-PowerSettingRegistryState -SchemeGuid $Snapshot.before.schemeGuid -SubgroupGuid $Snapshot.before.subgroupGuid -SettingGuid $Snapshot.before.settingGuid
    return (Test-RegistrySnapshotCurrent -Snapshot $Snapshot.after.ac) -and ([int]$current.ac.value -eq [int]$Snapshot.after.expectedAcValue)
}

function Test-PowerSettingRestoreConflict {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $current = Get-PowerSettingRegistryState -SchemeGuid $Snapshot.before.schemeGuid -SubgroupGuid $Snapshot.before.subgroupGuid -SettingGuid $Snapshot.before.settingGuid
    return (Test-RegistrySnapshotCurrent -Snapshot $Snapshot.before.ac) -or
        (Test-RegistrySnapshotCurrent -Snapshot $Snapshot.after.ac)
}

function Invoke-PowerSettingRestore {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    Invoke-RegistrySnapshotRestore -Snapshot $Snapshot.before.ac
    Invoke-RegistrySnapshotRestore -Snapshot $Snapshot.before.dc
    Invoke-FelixNative -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $Snapshot.before.schemeGuid) | Out-Null
    Clear-FelixActivePowerSchemeCache
}

function Test-PowerSettingRestored {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    return (Test-RegistrySnapshotCurrent -Snapshot $Snapshot.before.ac) -and
        (Test-RegistrySnapshotCurrent -Snapshot $Snapshot.before.dc)
}

function Get-PowerPlanSnapshot {
    $active = Get-FelixActivePowerScheme
    return [ordered]@{
        activeGuid = $active.guid
        activeName = $active.name
        existingGuid = Get-PowerSchemeByName -Name 'StableTune Low Latency'
    }
}

function Invoke-PowerPlanApply {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $created = $false
    $targetGuid = $Snapshot.before.existingGuid
    if (-not $targetGuid) {
        $output = Invoke-FelixNative -FilePath 'powercfg.exe' -ArgumentList @('/duplicatescheme', $Snapshot.before.activeGuid)
        if ($output -notmatch '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            throw 'Unable to parse the duplicated power scheme GUID.'
        }
        $targetGuid = $Matches[1].ToLowerInvariant()
        Invoke-FelixNative -FilePath 'powercfg.exe' -ArgumentList @('/changename', $targetGuid, 'StableTune Low Latency') | Out-Null
        $created = $true
    }

    Invoke-FelixNative -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $targetGuid) | Out-Null
    Clear-FelixActivePowerSchemeCache
    return [ordered]@{
        targetGuid = $targetGuid
        created = $created
    }
}

function Test-PowerPlanApplied {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    return (Get-ActivePowerSchemeGuid) -eq $Snapshot.after.targetGuid
}

function Test-PowerPlanRestored {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    return (Get-ActivePowerSchemeGuid) -eq $Snapshot.before.activeGuid
}

function Test-PowerPlanRestoreConflict {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $current = Get-ActivePowerSchemeGuid
    return $current -eq $Snapshot.before.activeGuid -or $current -eq $Snapshot.after.targetGuid
}

function Invoke-PowerPlanRestore {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    Invoke-FelixNative -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $Snapshot.before.activeGuid) | Out-Null
    Clear-FelixActivePowerSchemeCache
    if ($Snapshot.after -and $Snapshot.after.created -and (Get-PowerSchemeByName -Name 'StableTune Low Latency') -eq $Snapshot.after.targetGuid) {
        Invoke-FelixNative -FilePath 'powercfg.exe' -ArgumentList @('/delete', $Snapshot.after.targetGuid) | Out-Null
    }
}

function Get-RegistryValueSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [ordered]@{
            path = $Path
            name = $Name
            exists = $false
            kind = $null
            value = $null
        }
    }

    $key = Get-Item -LiteralPath $Path
    if ($key.GetValueNames() -notcontains $Name) {
        return [ordered]@{
            path = $Path
            name = $Name
            exists = $false
            kind = $null
            value = $null
        }
    }

    return [ordered]@{
        path = $Path
        name = $Name
        exists = $true
        kind = $key.GetValueKind($Name).ToString()
        value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
}

function ConvertTo-RegistryComparable {
    param($Snapshot)

    if (-not $Snapshot.exists) {
        return '<missing>'
    }

    $value = $Snapshot.value
    if ($value -is [byte[]]) {
        return "$($Snapshot.kind):$([Convert]::ToBase64String($value))"
    }
    if ($value -is [array]) {
        return "$($Snapshot.kind):$($value -join "`u{001f}")"
    }
    if ($null -eq $value) {
        return "$($Snapshot.kind):<null>"
    }
    return "$($Snapshot.kind):$value"
}

function Test-RegistrySnapshotCurrent {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $current = Get-RegistryValueSnapshot -Path $Snapshot.path -Name $Snapshot.name
    return (ConvertTo-RegistryComparable $current) -eq (ConvertTo-RegistryComparable $Snapshot)
}

function Invoke-RegistrySnapshotRestore {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    if (-not $Snapshot.exists) {
        if (Test-Path -LiteralPath $Snapshot.path) {
            Remove-ItemProperty -LiteralPath $Snapshot.path -Name $Snapshot.name -Force -ErrorAction SilentlyContinue
        }
        return
    }

    if (-not (Test-Path -LiteralPath $Snapshot.path)) {
        New-Item -Path $Snapshot.path -Force | Out-Null
    }

    $value = $Snapshot.value
    if ($Snapshot.kind -eq 'Binary' -and $value -isnot [byte[]]) {
        $value = [byte[]]@($value)
    }

    New-ItemProperty -LiteralPath $Snapshot.path -Name $Snapshot.name -Value $value -PropertyType $Snapshot.kind -Force | Out-Null
}

function Test-RegistryRestoreConflict {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot,

        [Parameter(Mandatory)]
        [hashtable]$Before,

        [Parameter(Mandatory)]
        [hashtable]$After
    )

    return (Test-RegistrySnapshotCurrent -Snapshot $Before) -or (Test-RegistrySnapshotCurrent -Snapshot $After)
}

function Resolve-FelixTextTemplate {
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [hashtable]$Values = @{}
    )

    $result = $Text
    foreach ($key in $Values.Keys) {
        $result = $result.Replace("{$key}", [string]$Values[$key])
    }
    if ($result -match '\{[A-Za-z0-9_]+\}') {
        throw "Unresolved template value in '$Text'."
    }
    return $result
}

function ConvertTo-RegistryTargetValue {
    param(
        [Parameter(Mandatory)]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Kind
    )

    switch ($Kind) {
        'DWord' { return [uint32]$Value }
        'QWord' { return [uint64]$Value }
        'Binary' {
            if ($Value -is [byte[]]) {
                return $Value
            }
            return [byte[]]@($Value)
        }
        'MultiString' { return [string[]]@($Value) }
        'String' { return [string]$Value }
        'ExpandString' { return [string]$Value }
        default { return $Value }
    }
}

function Get-FelixRegistryTemplateValues {
    param(
        [hashtable]$Options = @{}
    )

    $values = @{}
    foreach ($key in $Options.Keys) {
        $values[$key] = $Options[$key]
    }

    if ($values.ContainsKey('ExecutablePath') -and -not [string]::IsNullOrWhiteSpace([string]$values.ExecutablePath)) {
        $executableName = [IO.Path]::GetFileName([string]$values.ExecutablePath)
        if (
            [string]::IsNullOrWhiteSpace($executableName) -or
            $executableName -notmatch '^[^\\/:*?"<>|]+\.exe$'
        ) {
            throw 'The selected executable name is invalid.'
        }
        $values.ExecutableName = $executableName
    }

    return $values
}

function Test-RegistrySetPrerequisite {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Rule,

        [hashtable]$Options = @{}
    )

    if (-not $Rule.Contains('registryChanges') -or @($Rule.registryChanges).Count -eq 0) {
        return New-FelixRequirementResult $false 'No registry changes are defined.'
    }

    if ($Rule.Contains('prerequisiteKind') -and $Rule.prerequisiteKind -eq 'Ssd') {
        try {
            $ssd = @(Get-PhysicalDisk -ErrorAction Stop | Where-Object {
                $_.MediaType -eq 'SSD' -or $_.BusType -eq 'NVMe'
            })
            if ($ssd.Count -eq 0) {
                return New-FelixRequirementResult $false 'No SSD or NVMe device was detected.'
            }
        }
        catch {
            return New-FelixRequirementResult $false 'SSD/NVMe detection requires storage access.'
        }
    }

    if ($Rule.Contains('prerequisiteKind') -and $Rule.prerequisiteKind -eq 'AntiCheatExpert') {
        if (-not (Test-FelixAntiCheatExpertPresence)) {
            return New-FelixRequirementResult $false 'Tencent AntiCheatExpert was not detected.'
        }
    }

    if ($Rule.Contains('inputKind')) {
        switch ($Rule.inputKind) {
            'NetworkAdapter' {
                if (-not $Options.ContainsKey('InterfaceAlias') -or -not $Options.ContainsKey('InterfaceGuid')) {
                    return New-FelixRequirementResult $false 'InterfaceAlias and InterfaceGuid are required.'
                }
                $adapter = Get-NetAdapter -Name ([string]$Options.InterfaceAlias) -ErrorAction SilentlyContinue
                if (-not $adapter) {
                    return New-FelixRequirementResult $false 'The selected network adapter was not found.'
                }
                if (
                    (ConvertTo-FelixGuidText -Value $adapter.InterfaceGuid -Format D) -ne
                    (ConvertTo-FelixGuidText -Value $Options.InterfaceGuid -Format D)
                ) {
                    return New-FelixRequirementResult $false 'The selected network adapter changed after selection.'
                }
            }
            'ExecutablePath' {
                if (-not $Options.ContainsKey('ExecutablePath') -or -not (Test-Path -LiteralPath ([string]$Options.ExecutablePath) -PathType Leaf)) {
                    return New-FelixRequirementResult $false 'A valid executable path is required.'
                }
                if ([IO.Path]::GetExtension([string]$Options.ExecutablePath) -ine '.exe') {
                    return New-FelixRequirementResult $false 'The selected file is not an EXE.'
                }
            }
            'ExecutablePriority' {
                if (-not $Options.ContainsKey('ExecutablePath') -or -not (Test-Path -LiteralPath ([string]$Options.ExecutablePath) -PathType Leaf)) {
                    return New-FelixRequirementResult $false 'A valid executable path is required.'
                }
                if ([IO.Path]::GetExtension([string]$Options.ExecutablePath) -ine '.exe') {
                    return New-FelixRequirementResult $false 'The selected file is not an EXE.'
                }
                if (-not $Options.ContainsKey('CpuPriorityClass') -or [int]$Options.CpuPriorityClass -notin @(2, 6)) {
                    return New-FelixRequirementResult $false 'CPU priority must be Normal (2) or Above Normal (6).'
                }
            }
        }
    }

    try {
        $values = Get-FelixRegistryTemplateValues -Options $Options
        foreach ($change in @($Rule.registryChanges)) {
            $null = Resolve-FelixTextTemplate -Text ([string]$change.path) -Values $values
            $null = Resolve-FelixTextTemplate -Text ([string]$change.name) -Values $values
        }
    }
    catch {
        return New-FelixRequirementResult $false $_.Exception.Message
    }

    return New-FelixRequirementResult $true 'The registry target is available and the required input is valid.'
}

function Get-RegistrySetSnapshot {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Rule,

        [hashtable]$Options = @{}
    )

    $values = Get-FelixRegistryTemplateValues -Options $Options
    $entries = @()
    foreach ($change in @($Rule.registryChanges)) {
        $path = Resolve-FelixTextTemplate -Text ([string]$change.path) -Values $values
        $name = Resolve-FelixTextTemplate -Text ([string]$change.name) -Values $values
        $entries += Get-RegistryValueSnapshot -Path $path -Name $name
    }
    return [ordered]@{
        entries = @($entries)
    }
}

function Invoke-RegistrySetApply {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Rule,

        [Parameter(Mandatory)]
        [hashtable]$Snapshot,

        [hashtable]$Options = @{}
    )

    $values = Get-FelixRegistryTemplateValues -Options $Options
    for ($index = 0; $index -lt @($Rule.registryChanges).Count; $index++) {
        $change = @($Rule.registryChanges)[$index]
        $path = Resolve-FelixTextTemplate -Text ([string]$change.path) -Values $values
        $name = Resolve-FelixTextTemplate -Text ([string]$change.name) -Values $values
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -Path $path -Force | Out-Null
        }
        $resolvedValue = if ($change.value -is [string]) {
            Resolve-FelixTextTemplate -Text ([string]$change.value) -Values $values
        }
        else {
            $change.value
        }
        $value = ConvertTo-RegistryTargetValue -Value $resolvedValue -Kind ([string]$change.kind)
        New-ItemProperty -LiteralPath $path -Name $name -Value $value -PropertyType ([string]$change.kind) -Force | Out-Null
    }

    return Get-RegistrySetSnapshot -Rule $Rule -Options $Options
}

function Test-RegistrySetApplied {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    foreach ($entry in @($Snapshot.after.entries)) {
        if (-not (Test-RegistrySnapshotCurrent -Snapshot $entry)) {
            return $false
        }
    }
    return $true
}

function Test-RegistrySetRestoreConflict {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    for ($index = 0; $index -lt @($Snapshot.before.entries).Count; $index++) {
        $current = Get-RegistryValueSnapshot -Path $Snapshot.before.entries[$index].path -Name $Snapshot.before.entries[$index].name
        if ((ConvertTo-RegistryComparable $current) -eq (ConvertTo-RegistryComparable $Snapshot.before.entries[$index])) {
            return $true
        }
        if ((ConvertTo-RegistryComparable $current) -eq (ConvertTo-RegistryComparable $Snapshot.after.entries[$index])) {
            return $true
        }
    }
    return $false
}

function Invoke-RegistrySetRestore {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    foreach ($entry in @($Snapshot.before.entries)) {
        Invoke-RegistrySnapshotRestore -Snapshot $entry
    }
}

function Test-RegistrySetRestored {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    foreach ($entry in @($Snapshot.before.entries)) {
        if (-not (Test-RegistrySnapshotCurrent -Snapshot $entry)) {
            return $false
        }
    }
    return $true
}

function Get-NetworkInterruptModerationProperty {
    param(
        [Parameter(Mandatory)]
        [string]$AdapterName
    )

    $properties = @(Get-NetAdapterAdvancedProperty -Name $AdapterName -ErrorAction Stop)
    $property = $properties | Where-Object {
        $_.RegistryKeyword -match '^\*?InterruptModeration$' -or
        $_.DisplayName -match 'Interrupt Moderation|中断节流|中断裁决|中断调整'
    } | Select-Object -First 1
    if (-not $property) {
        throw "Adapter '$AdapterName' does not expose an interrupt moderation property."
    }
    return $property
}

function Get-NetworkInterruptModerationSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$AdapterName
    )

    $property = Get-NetworkInterruptModerationProperty -AdapterName $AdapterName
    return [ordered]@{
        adapterName = $AdapterName
        displayName = [string]$property.DisplayName
        registryKeyword = [string]$property.RegistryKeyword
        registryValue = $property.RegistryValue
        displayValue = [string]$property.DisplayValue
    }
}

function Set-NetworkInterruptModerationValue {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot,

        [Parameter(Mandatory)]
        [object]$Value
    )

    $parameters = @{
        Name = $Snapshot.before.adapterName
        RegistryKeyword = $Snapshot.before.registryKeyword
        RegistryValue = $Value
        ErrorAction = 'Stop'
        NoRestart = $true
    }
    Set-NetAdapterAdvancedProperty @parameters
}

function Invoke-NetworkInterruptModerationApply {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    Set-NetworkInterruptModerationValue -Snapshot $Snapshot -Value 0
    return Get-NetworkInterruptModerationSnapshot -AdapterName $Snapshot.before.adapterName
}

function Test-NetworkInterruptModerationApplied {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $current = Get-NetworkInterruptModerationSnapshot -AdapterName $Snapshot.before.adapterName
    return [string]$current.registryValue -eq [string]$Snapshot.after.registryValue
}

function Test-NetworkInterruptModerationRestored {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $current = Get-NetworkInterruptModerationSnapshot -AdapterName $Snapshot.before.adapterName
    return [string]$current.registryValue -eq [string]$Snapshot.before.registryValue
}

function Test-NetworkInterruptModerationRestoreConflict {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    try {
        return (Test-NetworkInterruptModerationRestored -Snapshot $Snapshot) -or
            (Test-NetworkInterruptModerationApplied -Snapshot $Snapshot)
    }
    catch {
        return $false
    }
}

function Invoke-NetworkInterruptModerationRestore {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    Set-NetworkInterruptModerationValue -Snapshot $Snapshot -Value $Snapshot.before.registryValue
}

function Get-ServiceFixedOptions {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Rule
    )

    return @{
        ServiceName = [string]$Rule.serviceName
        StartupType = [string]$Rule.targetStartupType
        StopNow = [bool]$Rule.stopNow
    }
}

function Get-PrioritySeparationSnapshot {
    return Get-RegistryValueSnapshot -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' -Name 'Win32PrioritySeparation'
}

function Invoke-PrioritySeparationApply {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    New-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' -Name 'Win32PrioritySeparation' -Value 40 -PropertyType DWord -Force | Out-Null
    return Get-RegistryValueSnapshot -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' -Name 'Win32PrioritySeparation'
}

function Get-MultimediaProfileSnapshot {
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    return [ordered]@{
        registry = @(
            (Get-RegistryValueSnapshot -Path $path -Name 'NetworkThrottlingIndex'),
            (Get-RegistryValueSnapshot -Path $path -Name 'SystemResponsiveness')
        )
    }
}

function Invoke-MultimediaProfileApply {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
    New-ItemProperty -LiteralPath $path -Name 'NetworkThrottlingIndex' -Value ([uint32]::MaxValue) -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $path -Name 'SystemResponsiveness' -Value 0 -PropertyType DWord -Force | Out-Null
    return [ordered]@{
        registry = @(
            (Get-RegistryValueSnapshot -Path $path -Name 'NetworkThrottlingIndex'),
            (Get-RegistryValueSnapshot -Path $path -Name 'SystemResponsiveness')
        )
    }
}

function Get-BcdValueSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $output = Invoke-FelixNative -FilePath 'bcdedit.exe' -ArgumentList @('/enum', '{current}', '/v')
    $match = [regex]::Match($output, "(?im)^\s*$([regex]::Escape($Name))\s+(\S+)")
    return [ordered]@{
        name = $Name
        exists = $match.Success
        value = if ($match.Success) { $match.Groups[1].Value } else { $null }
    }
}

function Get-BcdTimerSnapshot {
    return [ordered]@{
        useplatformtick = Get-BcdValueSnapshot -Name 'useplatformtick'
        disabledynamictick = Get-BcdValueSnapshot -Name 'disabledynamictick'
    }
}

function Set-BcdValue {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Value
    )

    Invoke-FelixNative -FilePath 'bcdedit.exe' -ArgumentList @('/set', $Name, $Value) | Out-Null
}

function Remove-BcdValue {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $output = & bcdedit.exe /deletevalue $Name 2>&1
    if ($LASTEXITCODE -ne 0 -and ($output -join ' ') -notmatch 'not found|找不到') {
        throw "bcdedit failed to delete '$Name': $($output -join [Environment]::NewLine)"
    }
}

function Invoke-BcdTimerApply {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    Set-BcdValue -Name 'useplatformtick' -Value 'no'
    Set-BcdValue -Name 'disabledynamictick' -Value 'yes'
    return Get-BcdTimerSnapshot
}

function Test-BcdTimerApplied {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $current = Get-BcdTimerSnapshot
    return $current.useplatformtick.value -eq 'No' -and $current.disabledynamictick.value -eq 'Yes'
}

function Test-BcdTimerRestoreConflict {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $current = Get-BcdTimerSnapshot
    $matchesBefore = ($current.useplatformtick.exists -eq $Snapshot.before.useplatformtick.exists) -and
        ($current.useplatformtick.value -eq $Snapshot.before.useplatformtick.value) -and
        ($current.disabledynamictick.exists -eq $Snapshot.before.disabledynamictick.exists) -and
        ($current.disabledynamictick.value -eq $Snapshot.before.disabledynamictick.value)
    $matchesAfter = ($current.useplatformtick.value -eq 'No') -and ($current.disabledynamictick.value -eq 'Yes')
    return $matchesBefore -or $matchesAfter
}

function Invoke-BcdTimerRestore {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    foreach ($entry in @($Snapshot.before.useplatformtick, $Snapshot.before.disabledynamictick)) {
        if ($entry.exists) {
            Set-BcdValue -Name $entry.name -Value $entry.value
        }
        else {
            Remove-BcdValue -Name $entry.name
        }
    }
}

function Test-BcdTimerRestored {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $current = Get-BcdTimerSnapshot
    return ($current.useplatformtick.exists -eq $Snapshot.before.useplatformtick.exists) -and
        ($current.useplatformtick.value -eq $Snapshot.before.useplatformtick.value) -and
        ($current.disabledynamictick.exists -eq $Snapshot.before.disabledynamictick.exists) -and
        ($current.disabledynamictick.value -eq $Snapshot.before.disabledynamictick.value)
}

function Get-NetworkAdapterRegistryPath {
    param(
        [Parameter(Mandatory)]
        [string]$AdapterName
    )

    $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
    $instanceId = (ConvertTo-FelixGuidText -Value $adapter.InterfaceGuid -Format B).ToUpperInvariant()
    $classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
    foreach ($key in Get-ChildItem -LiteralPath $classRoot -ErrorAction SilentlyContinue) {
        $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
        if ($properties -and ([string]$properties.NetCfgInstanceId).ToUpperInvariant() -eq $instanceId) {
            return $key.PSPath
        }
    }
    throw "Unable to resolve the registry key for adapter '$AdapterName'."
}

function Get-NicPowerSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$AdapterName
    )

    $method = 'registry'
    $allow = $null
    try {
        $power = Get-NetAdapterPowerManagement -Name $AdapterName -ErrorAction Stop
        if ($power.PSObject.Properties.Name -contains 'AllowComputerToTurnOffDevice') {
            $method = 'cmdlet'
            $allow = $power.AllowComputerToTurnOffDevice.ToString()
        }
    }
    catch {
        $method = 'registry'
    }

    $registryPath = Get-NetworkAdapterRegistryPath -AdapterName $AdapterName
    $registry = Get-RegistryValueSnapshot -Path $registryPath -Name 'PnPCapabilities'
    return [ordered]@{
        adapterName = $AdapterName
        method = $method
        allowComputerToTurnOffDevice = $allow
        registryPath = $registryPath
        registry = $registry
    }
}

function Invoke-NicPowerApply {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    if ($Snapshot.before.method -eq 'cmdlet') {
        Set-NetAdapterPowerManagement -Name $Snapshot.before.adapterName -AllowComputerToTurnOffDevice Disabled -ErrorAction Stop
        $power = Get-NetAdapterPowerManagement -Name $Snapshot.before.adapterName -ErrorAction Stop
        return [ordered]@{
            method = 'cmdlet'
            adapterName = $Snapshot.before.adapterName
            allowComputerToTurnOffDevice = $power.AllowComputerToTurnOffDevice.ToString()
        }
    }

    $beforeValue = if ($Snapshot.before.registry.exists) { [int]$Snapshot.before.registry.value } else { 0 }
    $newValue = $beforeValue -bor 0x100
    New-ItemProperty -LiteralPath $Snapshot.before.registryPath -Name 'PnPCapabilities' -Value $newValue -PropertyType DWord -Force | Out-Null
    return [ordered]@{
        method = 'registry'
        adapterName = $Snapshot.before.adapterName
        registry = Get-RegistryValueSnapshot -Path $Snapshot.before.registryPath -Name 'PnPCapabilities'
    }
}

function Test-NicPowerApplied {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    if ($Snapshot.after.method -eq 'cmdlet') {
        $power = Get-NetAdapterPowerManagement -Name $Snapshot.before.adapterName -ErrorAction Stop
        return $power.AllowComputerToTurnOffDevice.ToString() -eq 'Disabled'
    }

    return Test-RegistrySnapshotCurrent -Snapshot $Snapshot.after.registry
}

function Invoke-NicPowerRestore {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    if ($Snapshot.before.method -eq 'cmdlet') {
        $value = if ($Snapshot.before.allowComputerToTurnOffDevice) { $Snapshot.before.allowComputerToTurnOffDevice } else { 'Enabled' }
        Set-NetAdapterPowerManagement -Name $Snapshot.before.adapterName -AllowComputerToTurnOffDevice $value -ErrorAction Stop
        return
    }

    Invoke-RegistrySnapshotRestore -Snapshot $Snapshot.before.registry
}

function Test-NicPowerRestored {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    if ($Snapshot.before.method -eq 'cmdlet') {
        $power = Get-NetAdapterPowerManagement -Name $Snapshot.before.adapterName -ErrorAction Stop
        $current = $power.AllowComputerToTurnOffDevice.ToString()
        return $current -eq $Snapshot.before.allowComputerToTurnOffDevice
    }

    return Test-RegistrySnapshotCurrent -Snapshot $Snapshot.before.registry
}

function Test-NicPowerRestoreConflict {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    try {
        return (Test-NicPowerRestored -Snapshot $Snapshot) -or (Test-NicPowerApplied -Snapshot $Snapshot)
    }
    catch {
        return $false
    }
}

function Get-TcpGlobalSnapshot {
    $autoTuning = $null
    $timestamps = $null
    $raw = $null

    try {
        $setting = Get-NetTCPSetting -SettingName Internet -ErrorAction Stop
        if ($setting.PSObject.Properties.Name -contains 'AutoTuningLevelLocal' -and $null -ne $setting.AutoTuningLevelLocal) {
            $autoTuning = $setting.AutoTuningLevelLocal.ToString().ToLowerInvariant()
        }
        if ($setting.PSObject.Properties.Name -contains 'Timestamps' -and $null -ne $setting.Timestamps) {
            $timestamps = $setting.Timestamps.ToString().ToLowerInvariant()
        }
    }
    catch {
        $autoTuning = $null
        $timestamps = $null
    }

    $raw = Invoke-FelixNative -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'show', 'global')
    if (-not $autoTuning) {
        $match = [regex]::Match($raw, '(?im)^\s*(?:Receive Window Auto-Tuning Level|接收窗口自动调优级别)\s*:\s*(\S+)')
        if ($match.Success) {
            $autoTuning = $match.Groups[1].Value.ToLowerInvariant()
        }
    }
    if (-not $timestamps) {
        $match = [regex]::Match($raw, '(?im)^\s*(?:RFC 1323 Timestamps|RFC 1323 时间戳)\s*:\s*(\S+)')
        if ($match.Success) {
            $timestamps = $match.Groups[1].Value.ToLowerInvariant()
        }
    }

    if (-not $autoTuning -or -not $timestamps) {
        throw 'Unable to read TCP auto-tuning and timestamp state.'
    }

    return [ordered]@{
        autoTuning = $autoTuning
        timestamps = $timestamps
        raw = $raw
    }
}

function Set-TcpGlobalValue {
    param(
        [ValidateSet('AutoTuning', 'Timestamps')]
        [string]$Property,

        [Parameter(Mandatory)]
        [string]$Value
    )

    $usedCmdlet = $false
    if (Get-Command Set-NetTCPSetting -ErrorAction SilentlyContinue) {
        try {
            if ($Property -eq 'AutoTuning') {
                Set-NetTCPSetting -SettingName Internet -AutoTuningLevelLocal $Value -ErrorAction Stop
            }
            else {
                Set-NetTCPSetting -SettingName Internet -Timestamps $Value -ErrorAction Stop
            }
            $usedCmdlet = $true
        }
        catch {
            $usedCmdlet = $false
        }
    }

    if (-not $usedCmdlet) {
        if ($Property -eq 'AutoTuning') {
            Invoke-FelixNative -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'set', 'global', "autotuninglevel=$Value") | Out-Null
        }
        else {
            Invoke-FelixNative -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'set', 'global', "timestamps=$Value") | Out-Null
        }
    }
}

function Invoke-TcpGlobalApply {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot,

        [switch]$AutoTuning,

        [switch]$Timestamps
    )

    $autoTuningValue = if ($AutoTuning) { 'experimental' } else { $Snapshot.before.autoTuning }
    $timestampsValue = if ($Timestamps) { 'enabled' } else { $Snapshot.before.timestamps }
    if ($AutoTuning) {
        Set-TcpGlobalValue -Property 'AutoTuning' -Value 'experimental'
    }
    if ($Timestamps) {
        Set-TcpGlobalValue -Property 'Timestamps' -Value 'enabled'
    }
    return [ordered]@{
        autoTuning = $autoTuningValue
        timestamps = $timestampsValue
    }
}

function Test-TcpGlobalApplied {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot,

        [Parameter(Mandatory)]
        [ValidateSet('AutoTuning', 'Timestamps')]
        [string]$Property
    )

    $current = Get-TcpGlobalSnapshot
    if ($Property -eq 'AutoTuning') {
        return $current.autoTuning -eq $Snapshot.after.autoTuning
    }
    return $current.timestamps -eq $Snapshot.after.timestamps
}

function Invoke-TcpGlobalRestore {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    Set-TcpGlobalValue -Property 'AutoTuning' -Value $Snapshot.before.autoTuning
    Set-TcpGlobalValue -Property 'Timestamps' -Value $Snapshot.before.timestamps
}

function Test-TcpGlobalRestored {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $current = Get-TcpGlobalSnapshot
    return $current.autoTuning -eq $Snapshot.before.autoTuning -and
        $current.timestamps -eq $Snapshot.before.timestamps
}

function Test-TcpGlobalRestoreConflict {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    try {
        return (Test-TcpGlobalRestored -Snapshot $Snapshot) -or (Test-TcpGlobalApplied -Snapshot $Snapshot -Property 'AutoTuning') -or (Test-TcpGlobalApplied -Snapshot $Snapshot -Property 'Timestamps')
    }
    catch {
        return $false
    }
}

function Get-DnsProfileSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$InterfaceAlias
    )

    $addresses = @(Get-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction Stop)
    $interface = Get-NetIPInterface -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction Stop
    $servers = @()
    foreach ($address in $addresses) {
        $servers += @($address.ServerAddresses)
    }

    return [ordered]@{
        interfaceAlias = $InterfaceAlias
        servers = @($servers | Where-Object { $_ })
        dhcp = $interface.Dhcp.ToString()
    }
}

function Set-DnsProfileValue {
    param(
        [Parameter(Mandatory)]
        [string]$InterfaceAlias,

        [Parameter(Mandatory)]
        [bool]$Dhcp,

        [string[]]$DnsServers = @()
    )

    if ($Dhcp) {
        Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ResetServerAddresses -ErrorAction Stop
    }
    else {
        Set-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ServerAddresses $DnsServers -ErrorAction Stop
    }
}

function Invoke-DnsProfileApply {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot,

        [Parameter(Mandatory)]
        [hashtable]$Options
    )

    $dhcp = [bool]$Options.Dhcp
    $servers = @($Options.DnsServers)
    Set-DnsProfileValue -InterfaceAlias $Snapshot.before.interfaceAlias -Dhcp $dhcp -DnsServers $servers
    $after = Get-DnsProfileSnapshot -InterfaceAlias $Snapshot.before.interfaceAlias
    return [ordered]@{
        expectedDhcp = $dhcp
        expectedServers = $servers
        actualDhcp = $after.dhcp
        actualServers = $after.servers
    }
}

function Test-DnsProfileApplied {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $current = Get-DnsProfileSnapshot -InterfaceAlias $Snapshot.before.interfaceAlias
    if ([bool]$Snapshot.after.expectedDhcp) {
        return $current.dhcp -eq 'Enabled'
    }
    return (($current.servers -join '|') -eq (@($Snapshot.after.expectedServers) -join '|'))
}

function Invoke-DnsProfileRestore {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $dhcp = $Snapshot.before.dhcp -eq 'Enabled'
    Set-DnsProfileValue -InterfaceAlias $Snapshot.before.interfaceAlias -Dhcp $dhcp -DnsServers @($Snapshot.before.servers)
}

function Test-DnsProfileRestored {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $current = Get-DnsProfileSnapshot -InterfaceAlias $Snapshot.before.interfaceAlias
    if ($Snapshot.before.dhcp -eq 'Enabled') {
        return $current.dhcp -eq 'Enabled'
    }
    return (($current.servers -join '|') -eq (@($Snapshot.before.servers) -join '|'))
}

function Test-DnsProfileRestoreConflict {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    return (Test-DnsProfileRestored -Snapshot $Snapshot) -or (Test-DnsProfileApplied -Snapshot $Snapshot)
}

function Get-AmdDisplayDriverKey {
    $classRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    foreach ($key in Get-ChildItem -LiteralPath $classRoot -ErrorAction SilentlyContinue) {
        if ($key.PSChildName -notmatch '^\d{4}$') {
            continue
        }
        $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
        if (-not $properties) {
            continue
        }
        $provider = if ($properties.PSObject.Properties.Name -contains 'ProviderName') { [string]$properties.ProviderName } else { '' }
        $driverDesc = if ($properties.PSObject.Properties.Name -contains 'DriverDesc') { [string]$properties.DriverDesc } else { '' }
        if ("$provider $driverDesc" -match 'AMD|Advanced Micro Devices|Radeon') {
            return $key.PSPath
        }
    }
    throw 'No matching AMD display driver key was detected.'
}

function Get-AmdDynamicPstateSnapshot {
    $keyPath = Get-AmdDisplayDriverKey
    return Get-RegistryValueSnapshot -Path $keyPath -Name 'DisableDynamicPstate'
}

function Invoke-AmdDynamicPstateApply {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    New-ItemProperty -LiteralPath $Snapshot.before.path -Name 'DisableDynamicPstate' -Value 1 -PropertyType DWord -Force | Out-Null
    return Get-RegistryValueSnapshot -Path $Snapshot.before.path -Name 'DisableDynamicPstate'
}

function Test-StartupOptions {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Options
    )

    $enable = $Options.ContainsKey('Enable') -and [bool]$Options.Enable
    if ($enable) {
        if (-not $Options.ContainsKey('BackupPath') -or [string]::IsNullOrWhiteSpace([string]$Options.BackupPath)) {
            return [ordered]@{ available = $false; message = 'BackupPath is required when enabling a startup item.' }
        }
        if (-not (Test-Path -LiteralPath ([string]$Options.BackupPath))) {
            return [ordered]@{ available = $false; message = 'The startup backup key was not found.' }
        }
        return [ordered]@{ available = $true; message = 'The disabled startup item is available.' }
    }

    if (-not $Options.ContainsKey('RegistryPath') -or -not $Options.ContainsKey('ValueName')) {
        return [ordered]@{ available = $false; message = 'RegistryPath and ValueName are required.' }
    }
    if ([string]$Options.RegistryPath -notin $script:AllowedStartupRoots) {
        return [ordered]@{ available = $false; message = 'The selected startup registry path is not supported.' }
    }
    $value = Get-RegistryValueSnapshot -Path ([string]$Options.RegistryPath) -Name ([string]$Options.ValueName)
    if (-not $value.exists) {
        return [ordered]@{ available = $false; message = 'The selected startup item no longer exists.' }
    }
    return [ordered]@{ available = $true; message = 'The startup item is available.' }
}

function Get-FelixStartupBackupRoot {
    param(
        [Parameter(Mandatory)]
        [string]$OriginalPath
    )

    if ($OriginalPath.StartsWith('HKCU:', [StringComparison]::OrdinalIgnoreCase)) {
        return 'HKCU:\Software\FelixOptimizer\DisabledStartup'
    }
    return 'HKLM:\SOFTWARE\FelixOptimizer\DisabledStartup'
}

function Get-FelixStartupCandidates {
    [CmdletBinding()]
    param()

    $items = @()
    foreach ($path in $script:AllowedStartupRoots) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        $key = Get-Item -LiteralPath $path
        foreach ($name in $key.GetValueNames()) {
            if ($name -eq 'FelixOptimizer') {
                continue
            }
            $items += [pscustomobject][ordered]@{
                name = $name
                command = [string]$key.GetValue($name)
                registryPath = $path
                valueName = $name
                enabled = $true
            }
        }
    }

    foreach ($backupRoot in @('HKCU:\Software\FelixOptimizer\DisabledStartup', 'HKLM:\SOFTWARE\FelixOptimizer\DisabledStartup')) {
        if (-not (Test-Path -LiteralPath $backupRoot)) {
            continue
        }
        foreach ($key in Get-ChildItem -LiteralPath $backupRoot -ErrorAction SilentlyContinue) {
            $properties = Get-ItemProperty -LiteralPath $key.PSPath
            $items += [pscustomobject][ordered]@{
                name = [string]$properties.ValueName
                command = ''
                registryPath = [string]$properties.OriginalPath
                valueName = [string]$properties.ValueName
                backupPath = $key.PSPath
                enabled = $false
            }
        }
    }

    return @($items)
}

function Get-StartupItemSnapshot {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Options,

        [Parameter(Mandatory)]
        [string]$OperationId
    )

    if ($Options.ContainsKey('Enable') -and [bool]$Options.Enable) {
        $backupPath = [string]$Options.BackupPath
        $properties = Get-ItemProperty -LiteralPath $backupPath -ErrorAction Stop
        $value = ConvertFrom-Json -InputObject ([string]$properties.ValueJson) -AsHashtable
        return [ordered]@{
            mode = 'enable'
            backupPath = $backupPath
            originalPath = [string]$properties.OriginalPath
            valueName = [string]$properties.ValueName
            kind = [string]$properties.ValueKind
            value = $value
        }
    }

    $registryPath = [string]$Options.RegistryPath
    $valueName = [string]$Options.ValueName
    $value = Get-RegistryValueSnapshot -Path $registryPath -Name $valueName
    $backupRoot = Get-FelixStartupBackupRoot -OriginalPath $registryPath
    return [ordered]@{
        mode = 'disable'
        registryPath = $registryPath
        valueName = $valueName
        value = $value
        backupPath = Join-Path $backupRoot $OperationId
    }
}

function Get-StartupValueForRegistry {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $value = $Snapshot.value
    if ($Snapshot.kind -eq 'Binary' -and $value -isnot [byte[]]) {
        return [byte[]]@($value)
    }
    return $value
}

function Invoke-StartupItemApply {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot,

        [Parameter(Mandatory)]
        [string]$OperationId
    )

    if ($Snapshot.before.mode -eq 'disable') {
        $backupPath = $Snapshot.before.backupPath
        if (Test-Path -LiteralPath $backupPath) {
            throw "Startup backup '$backupPath' already exists."
        }
        New-Item -Path $backupPath -Force | Out-Null
        New-ItemProperty -LiteralPath $backupPath -Name 'OriginalPath' -Value $Snapshot.before.registryPath -PropertyType String -Force | Out-Null
        New-ItemProperty -LiteralPath $backupPath -Name 'ValueName' -Value $Snapshot.before.valueName -PropertyType String -Force | Out-Null
        New-ItemProperty -LiteralPath $backupPath -Name 'ValueKind' -Value $Snapshot.before.value.kind -PropertyType String -Force | Out-Null
        New-ItemProperty -LiteralPath $backupPath -Name 'ValueJson' -Value (($Snapshot.before.value.value) | ConvertTo-Json -Compress) -PropertyType String -Force | Out-Null
        Remove-ItemProperty -LiteralPath $Snapshot.before.registryPath -Name $Snapshot.before.valueName -Force
        return [ordered]@{
            mode = 'disable'
            backupPath = $backupPath
            registryPath = $Snapshot.before.registryPath
            valueName = $Snapshot.before.valueName
        }
    }

    $destination = $Snapshot.before.originalPath
    New-ItemProperty -LiteralPath $destination -Name $Snapshot.before.valueName -Value (Get-StartupValueForRegistry -Snapshot $Snapshot.before) -PropertyType $Snapshot.before.kind -Force | Out-Null
    Remove-Item -LiteralPath $Snapshot.before.backupPath -Recurse -Force
    return [ordered]@{
        mode = 'enable'
        registryPath = $destination
        valueName = $Snapshot.before.valueName
        backupPath = $Snapshot.before.backupPath
    }
}

function Test-StartupItemApplied {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    if ($Snapshot.after.mode -eq 'disable') {
        $original = Get-RegistryValueSnapshot -Path $Snapshot.after.registryPath -Name $Snapshot.after.valueName
        return (-not $original.exists) -and (Test-Path -LiteralPath $Snapshot.after.backupPath)
    }
    $original = Get-RegistryValueSnapshot -Path $Snapshot.after.registryPath -Name $Snapshot.after.valueName
    return $original.exists -and (-not (Test-Path -LiteralPath $Snapshot.after.backupPath))
}

function Invoke-StartupItemRestore {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    if ($Snapshot.before.mode -eq 'disable') {
        $backupPath = if ($Snapshot.after) { [string]$Snapshot.after.backupPath } else { [string]$Snapshot.before.backupPath }
        $properties = Get-ItemProperty -LiteralPath $backupPath -ErrorAction Stop
        $value = ConvertFrom-Json -InputObject ([string]$properties.ValueJson) -AsHashtable
        $restoreValue = if ([string]$properties.ValueKind -eq 'Binary' -and $value -isnot [byte[]]) { [byte[]]@($value) } else { $value }
        New-ItemProperty -LiteralPath ([string]$properties.OriginalPath) -Name ([string]$properties.ValueName) -Value $restoreValue -PropertyType ([string]$properties.ValueKind) -Force | Out-Null
        Remove-Item -LiteralPath $backupPath -Recurse -Force
        return
    }

    $backupPath = $Snapshot.before.backupPath
    New-Item -Path $backupPath -Force | Out-Null
    New-ItemProperty -LiteralPath $backupPath -Name 'OriginalPath' -Value $Snapshot.before.originalPath -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $backupPath -Name 'ValueName' -Value $Snapshot.before.valueName -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $backupPath -Name 'ValueKind' -Value $Snapshot.before.kind -PropertyType String -Force | Out-Null
    New-ItemProperty -LiteralPath $backupPath -Name 'ValueJson' -Value (($Snapshot.before.value) | ConvertTo-Json -Compress) -PropertyType String -Force | Out-Null
    Remove-ItemProperty -LiteralPath $Snapshot.before.originalPath -Name $Snapshot.before.valueName -Force
}

function Test-StartupItemRestored {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    if ($Snapshot.before.mode -eq 'disable') {
        $backupPath = if ($Snapshot.after) { [string]$Snapshot.after.backupPath } else { [string]$Snapshot.before.backupPath }
        return (Test-RegistrySnapshotCurrent -Snapshot $Snapshot.before.value) -and (-not (Test-Path -LiteralPath $backupPath))
    }
    $original = Get-RegistryValueSnapshot -Path $Snapshot.before.originalPath -Name $Snapshot.before.valueName
    return (-not $original.exists) -and (Test-Path -LiteralPath $Snapshot.before.backupPath)
}

function Test-StartupItemRestoreConflict {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    try {
        return (Test-StartupItemRestored -Snapshot $Snapshot) -or (Test-StartupItemApplied -Snapshot $Snapshot)
    }
    catch {
        return $false
    }
}

function Get-ServiceStateSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName
    )

    $service = Get-Service -Name $ServiceName -ErrorAction Stop
    return [ordered]@{
        name = $service.Name
        displayName = $service.DisplayName
        startType = $service.StartType.ToString()
        status = $service.Status.ToString()
    }
}

function Invoke-ServiceStateApply {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot,

        [Parameter(Mandatory)]
        [hashtable]$Options
    )

    $startupType = if ($Options.ContainsKey('StartupType')) { [string]$Options.StartupType } else { 'Manual' }
    if ($startupType -notin @('Automatic', 'Manual', 'Disabled')) {
        throw "Unsupported service startup type '$startupType'."
    }
    Set-Service -Name $Snapshot.before.name -StartupType $startupType -ErrorAction Stop
    $stopNow = if ($Options.ContainsKey('StopNow')) { [bool]$Options.StopNow } else { $startupType -eq 'Disabled' }
    if ($stopNow) {
        Stop-Service -Name $Snapshot.before.name -Force -ErrorAction SilentlyContinue
    }
    $after = Get-ServiceStateSnapshot -ServiceName $Snapshot.before.name
    return [ordered]@{
        requestedStartType = $startupType
        requestedStop = $stopNow
        startType = $after.startType
        status = $after.status
    }
}

function Test-ServiceStateApplied {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $current = Get-ServiceStateSnapshot -ServiceName $Snapshot.before.name
    if ($current.startType -ne $Snapshot.after.startType) {
        return $false
    }
    if ($Snapshot.after.requestedStop -and $current.status -eq 'Running') {
        return $false
    }
    return $true
}

function Invoke-ServiceStateRestore {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    Set-Service -Name $Snapshot.before.name -StartupType $Snapshot.before.startType -ErrorAction Stop
    if ($Snapshot.before.status -eq 'Running') {
        Start-Service -Name $Snapshot.before.name -ErrorAction Stop
    }
    elseif ((Get-Service -Name $Snapshot.before.name).Status -eq 'Running') {
        Stop-Service -Name $Snapshot.before.name -Force -ErrorAction Stop
    }
}

function Test-ServiceStateRestored {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $current = Get-ServiceStateSnapshot -ServiceName $Snapshot.before.name
    return $current.startType -eq $Snapshot.before.startType -and $current.status -eq $Snapshot.before.status
}

function Test-ServiceStateRestoreConflict {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $current = Get-ServiceStateSnapshot -ServiceName $Snapshot.before.name
    $matchesBefore = $current.startType -eq $Snapshot.before.startType -and $current.status -eq $Snapshot.before.status
    $matchesAfter = $current.startType -eq $Snapshot.after.startType
    if ($Snapshot.after.requestedStop) {
        $matchesAfter = $matchesAfter -and $current.status -ne 'Running'
    }
    return $matchesBefore -or $matchesAfter
}

function Get-TempQuarantineSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$OperationId,

        [int]$OlderThanDays = 7,
        [long]$MaxBytes = 2147483648,
        [int]$MaxFiles = 5000
    )

    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $stateRoot = [IO.Path]::GetFullPath((Get-FelixStatePath)).TrimEnd('\')
    $cutoff = (Get-Date).AddDays(-1 * $OlderThanDays)
    $quarantineRoot = Get-FelixStatePath (Join-Path 'quarantine' $OperationId)
    $files = @()
    $totalBytes = [long]0
    $skipped = 0

    foreach ($file in Get-ChildItem -LiteralPath $tempRoot -File -Force -Recurse -ErrorAction SilentlyContinue) {
        if ($files.Count -ge $MaxFiles -or $totalBytes -ge $MaxBytes) {
            break
        }
        if ($file.LastWriteTime -gt $cutoff) {
            continue
        }
        $fullPath = [IO.Path]::GetFullPath($file.FullName)
        if ($fullPath.StartsWith($stateRoot, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        try {
            $stream = [IO.File]::Open($fullPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $stream.Dispose()
        }
        catch {
            $skipped++
            continue
        }

        if (($totalBytes + $file.Length) -gt $MaxBytes) {
            continue
        }

        $relativePath = $fullPath.Substring($tempRoot.Length).TrimStart('\')
        $destination = Join-Path $quarantineRoot (Join-Path 'files' $relativePath)
        $files += [ordered]@{
            source = $fullPath
            destination = $destination
            relativePath = $relativePath
            length = [long]$file.Length
            lastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
        }
        $totalBytes += $file.Length
    }

    return [ordered]@{
        tempRoot = $tempRoot
        quarantineRoot = $quarantineRoot
        olderThanDays = $OlderThanDays
        files = @($files)
        totalBytes = $totalBytes
        skipped = $skipped
    }
}

function Invoke-TempQuarantineApply {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $moved = @()
    foreach ($file in @($Snapshot.before.files)) {
        if (-not (Test-Path -LiteralPath $file.source -PathType Leaf)) {
            continue
        }
        $destinationParent = Split-Path -Parent $file.destination
        if (-not (Test-Path -LiteralPath $destinationParent)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }
        if (Test-Path -LiteralPath $file.destination) {
            throw "Quarantine destination already exists: $($file.destination)"
        }
        Move-Item -LiteralPath $file.source -Destination $file.destination -Force
        $moved += $file
    }

    return [ordered]@{
        moved = @($moved)
        movedCount = $moved.Count
    }
}

function Test-TempQuarantineApplied {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    foreach ($file in @($Snapshot.after.moved)) {
        if ((Test-Path -LiteralPath $file.source) -or -not (Test-Path -LiteralPath $file.destination)) {
            return $false
        }
    }
    return $true
}

function Invoke-TempQuarantineRestore {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $files = if ($Snapshot.after) { @($Snapshot.after.moved) } else { @($Snapshot.before.files) }
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file.destination -PathType Leaf)) {
            continue
        }
        if (Test-Path -LiteralPath $file.source) {
            throw "Cannot restore '$($file.source)' because the destination already exists."
        }
        $sourceParent = Split-Path -Parent $file.source
        if (-not (Test-Path -LiteralPath $sourceParent)) {
            New-Item -ItemType Directory -Path $sourceParent -Force | Out-Null
        }
        Move-Item -LiteralPath $file.destination -Destination $file.source -Force
    }
}

function Test-TempQuarantineRestored {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $files = if ($Snapshot.after) { @($Snapshot.after.moved) } else { @($Snapshot.before.files) }
    foreach ($file in $files) {
        if (Test-Path -LiteralPath $file.destination) {
            return $false
        }
    }
    return $true
}

function Test-TempQuarantineRestoreConflict {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    try {
        return (Test-TempQuarantineRestored -Snapshot $Snapshot) -or (Test-TempQuarantineApplied -Snapshot $Snapshot)
    }
    catch {
        return $false
    }
}

function Resolve-DeviceAffinityPath {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Options
    )

    if ($Options.ContainsKey('RegistryPath') -and -not [string]::IsNullOrWhiteSpace([string]$Options.RegistryPath)) {
        return [string]$Options.RegistryPath
    }

    $instanceId = [string]$Options.InstanceId
    $deviceKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$instanceId"
    if (-not (Test-Path -LiteralPath $deviceKey)) {
        throw "Device instance '$instanceId' was not found."
    }
    return Join-Path $deviceKey 'Device Parameters\Interrupt Management\Affinity Policy'
}

function ConvertTo-CpuMask {
    param(
        [Parameter(Mandatory)]
        [object]$Value
    )

    if ($Value -is [byte[]]) {
        $padded = New-Object byte[] 8
        [Array]::Copy($Value, $padded, [Math]::Min($Value.Length, 8))
        return [BitConverter]::ToUInt64($padded, 0)
    }
    if ($Value -is [uint64]) {
        return $Value
    }
    if ($Value -is [long] -or $Value -is [int]) {
        return [uint64]$Value
    }

    $text = ([string]$Value).Trim()
    if ($text.StartsWith('0x', [StringComparison]::OrdinalIgnoreCase)) {
        return [Convert]::ToUInt64($text.Substring(2), 16)
    }
    return [Convert]::ToUInt64($text, 10)
}

function Get-FelixInterruptCandidate {
    [CmdletBinding()]
    param()

    $rows = @()
    $pciRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI'
    foreach ($deviceClass in Get-ChildItem -LiteralPath $pciRoot -ErrorAction SilentlyContinue) {
        foreach ($device in Get-ChildItem -LiteralPath $deviceClass.PSPath -ErrorAction SilentlyContinue) {
            $name = ''
            if ($device.GetValueNames() -contains 'DeviceDesc') {
                $name = [string]$device.GetValue('DeviceDesc')
            }
            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }
            $interruptPath = Join-Path $device.PSPath 'Device Parameters\Interrupt Management'
            if (-not (Test-Path -LiteralPath $interruptPath)) {
                continue
            }
            $affinityPath = Join-Path $interruptPath 'Affinity Policy'
            $policy = Get-RegistryValueSnapshot -Path $affinityPath -Name 'DevicePolicy'
            $mask = Get-RegistryValueSnapshot -Path $affinityPath -Name 'AssignmentSetOverride'
            $rows += [pscustomobject][ordered]@{
                name = $name
                instanceId = $device.PSChildName
                registryPath = $affinityPath
                policy = $policy.value
                cpuMask = if ($mask.exists) { (ConvertTo-CpuMask -Value $mask.value).ToString('X') } else { $null }
            }
        }
    }
    return @($rows)
}

function Get-DeviceAffinitySnapshot {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Options
    )

    $path = Resolve-DeviceAffinityPath -Options $Options
    return [ordered]@{
        registryPath = $path
        policy = Get-RegistryValueSnapshot -Path $path -Name 'DevicePolicy'
        mask = Get-RegistryValueSnapshot -Path $path -Name 'AssignmentSetOverride'
    }
}

function Invoke-DeviceAffinityApply {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot,

        [Parameter(Mandatory)]
        [hashtable]$Options
    )

    $path = $Snapshot.before.registryPath
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -Path $path -Force | Out-Null
    }
    $mask = ConvertTo-CpuMask -Value $Options.CpuMask
    if ($mask -eq 0) {
        Remove-ItemProperty -LiteralPath $path -Name 'DevicePolicy' -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $path -Name 'AssignmentSetOverride' -Force -ErrorAction SilentlyContinue
    }
    else {
        New-ItemProperty -LiteralPath $path -Name 'DevicePolicy' -Value 4 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -LiteralPath $path -Name 'AssignmentSetOverride' -Value ([BitConverter]::GetBytes($mask)) -PropertyType Binary -Force | Out-Null
    }
    return [ordered]@{
        registry = [ordered]@{
            path = $path
            name = 'DevicePolicy'
            exists = ($mask -ne 0)
            kind = if ($mask -ne 0) { 'DWord' } else { $null }
            value = if ($mask -ne 0) { 4 } else { $null }
        }
        mask = [ordered]@{
            path = $path
            name = 'AssignmentSetOverride'
            exists = ($mask -ne 0)
            kind = if ($mask -ne 0) { 'Binary' } else { $null }
            value = if ($mask -ne 0) { [BitConverter]::GetBytes($mask) } else { $null }
        }
    }
}

function Get-DeviceAffinityCurrentSnapshot {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $path = $Snapshot.before.registryPath
    return [ordered]@{
        policy = Get-RegistryValueSnapshot -Path $path -Name 'DevicePolicy'
        mask = Get-RegistryValueSnapshot -Path $path -Name 'AssignmentSetOverride'
    }
}

function Test-DeviceAffinityApplied {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $current = Get-DeviceAffinityCurrentSnapshot -Snapshot $Snapshot
    return (ConvertTo-RegistryComparable $current.policy) -eq (ConvertTo-RegistryComparable $Snapshot.after.registry) -and
        (ConvertTo-RegistryComparable $current.mask) -eq (ConvertTo-RegistryComparable $Snapshot.after.mask)
}

function Test-DeviceAffinityRestoreConflict {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $current = Get-DeviceAffinityCurrentSnapshot -Snapshot $Snapshot
    $matchesBefore = (ConvertTo-RegistryComparable $current.policy) -eq (ConvertTo-RegistryComparable $Snapshot.before.policy) -and
        (ConvertTo-RegistryComparable $current.mask) -eq (ConvertTo-RegistryComparable $Snapshot.before.mask)
    $matchesAfter = (ConvertTo-RegistryComparable $current.policy) -eq (ConvertTo-RegistryComparable $Snapshot.after.registry) -and
        (ConvertTo-RegistryComparable $current.mask) -eq (ConvertTo-RegistryComparable $Snapshot.after.mask)
    return $matchesBefore -or $matchesAfter
}

function Test-DeviceAffinityRestored {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Snapshot
    )

    $current = Get-DeviceAffinityCurrentSnapshot -Snapshot $Snapshot
    return (ConvertTo-RegistryComparable $current.policy) -eq (ConvertTo-RegistryComparable $Snapshot.before.policy) -and
        (ConvertTo-RegistryComparable $current.mask) -eq (ConvertTo-RegistryComparable $Snapshot.before.mask)
}

if (Test-Path -LiteralPath (Join-Path $script:ModuleRoot 'Ui.ps1')) {
    . (Join-Path $script:ModuleRoot 'Ui.ps1')
}
