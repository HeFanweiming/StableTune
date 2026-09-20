@{
    RootModule        = 'StableTune.psm1'
    ModuleVersion     = '0.1.9.1'
    GUID              = 'a91f7f71-68af-4d51-80f4-093c4932141c'
    Author            = 'OpenAI Codex'
    CompanyName       = 'StableTune'
    Copyright         = '(c) 2026. All rights reserved.'
    Description       = 'Reversible Windows optimization prototype with non-blocking startup, cross-checked applicability, crash recovery, memory inventory, native change audit, and configurable rollback protection.'
    PowerShellVersion = '7.4'

    FunctionsToExport = @(
        'Get-FelixRule'
        'Get-FelixHistory'
        'Get-FelixSystemStatus'
        'Get-FelixHardwareInventory'
        'Get-FelixRuleApplicability'
        'Get-FelixCrashRecoveryStatus'
        'Get-FelixSystemChangeReport'
        'Get-FelixLog'
        'Get-FelixStatePath'
        'Get-FelixRollbackPolicy'
        'Set-FelixRollbackPolicy'
        'Test-FelixRollbackCapability'
        'Test-FelixDualRollbackCapability'
        'Invoke-FelixAudit'
        'Invoke-FelixDryRun'
        'Invoke-FelixApply'
        'Invoke-FelixBatchApply'
        'Invoke-FelixRestore'
        'Invoke-FelixRestoreAll'
        'Invoke-FelixCrashRecovery'
        'Start-StableTuneUi'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
