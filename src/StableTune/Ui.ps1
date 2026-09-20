function Get-FelixUiText {
    return Get-Content -LiteralPath $script:UiResourcePath -Raw | ConvertFrom-Json -AsHashtable
}

function Show-FelixMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [string]$Title = '稳优 StableTune',
        [System.Windows.MessageBoxImage]$Icon = [System.Windows.MessageBoxImage]::Information
    )

    $owner = $script:FelixUiState.Window
    if ($owner) {
        [System.Windows.MessageBox]::Show($owner, $Message, $Title, [System.Windows.MessageBoxButton]::OK, $Icon) | Out-Null
    }
    else {
        [System.Windows.MessageBox]::Show($Message, $Title, [System.Windows.MessageBoxButton]::OK, $Icon) | Out-Null
    }
}

function Confirm-FelixSnapshotOnlyExecution {
    param(
        [Parameter(Mandatory)]
        [object]$Rollback
    )

    if ([bool]$Rollback.requiresSystemRestorePoint) {
        return $true
    }

    $result = [System.Windows.MessageBox]::Show(
        $script:FelixUiState.Window,
        $script:FelixUiState.Text.dialogs.snapshotOnlyConfirm,
        $script:FelixUiState.Text.dialogs.snapshotOnlyTitle,
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    return $result -eq [System.Windows.MessageBoxResult]::Yes
}

function Get-FelixUiStatusText {
    param([string]$Status)

    $text = $script:FelixUiState.Text
    switch ($Status) {
        'NotApplied' { return $text.rules.notApplied }
        'Applied' { return $text.rules.applied }
        'Restored' { return $text.rules.restored }
        'InProgress' { return $text.rules.inProgress }
        'Restoring' { return $text.rules.restoring }
        'RestoreFailed' { return $text.rules.failed }
        'Failed' { return $text.rules.failed }
        'CrashRecovered' { return $text.rules.crashRecovered }
        'CrashRecoveryFailed' { return $text.rules.crashRecoveryFailed }
        default { return $Status }
    }
}

function Get-FelixUiSystemStateText {
    param([string]$State)

    $text = $script:FelixUiState.Text
    switch ($State) {
        'Modified' { return $text.rules.modified }
        'NotModified' { return $text.rules.notModified }
        'RequiresSelection' { return $text.rules.requiresSelection }
        'NotPersistent' { return $text.rules.notPersistent }
        default { return $text.rules.checkUnavailable }
    }
}

function Get-FelixUiCategoryName {
    param([string]$Category)

    if ($script:FelixUiState.Text.categories.ContainsKey($Category)) {
        return [string]$script:FelixUiState.Text.categories[$Category]
    }
    return $Category
}

function New-FelixUiButton {
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [double]$Width = 96,
        [double]$Height = 34,
        [ValidateSet('Default', 'Selection', 'Primary', 'Warning', 'Danger')]
        [string]$Variant = 'Default'
    )

    $button = New-Object System.Windows.Controls.Button
    $button.Content = $Text
    $button.MinWidth = $Width
    $button.Height = $Height
    $button.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $button.Padding = [System.Windows.Thickness]::new(14, 0, 14, 0)
    $button.BorderThickness = [System.Windows.Thickness]::new(1)
    $button.HorizontalContentAlignment = [System.Windows.HorizontalAlignment]::Center
    $button.VerticalContentAlignment = [System.Windows.VerticalAlignment]::Center
    $button.FontWeight = [System.Windows.FontWeights]::SemiBold
    $button.Cursor = [System.Windows.Input.Cursors]::Hand

    switch ($Variant) {
        'Selection' {
            $button.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFFF')
            $button.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#CBD5E1')
            $button.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#334155')
        }
        'Primary' {
            $button.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#2563EB')
            $button.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#1D4ED8')
            $button.Foreground = [System.Windows.Media.Brushes]::White
        }
        'Warning' {
            $button.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#B45309')
            $button.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#92400E')
            $button.Foreground = [System.Windows.Media.Brushes]::White
        }
        'Danger' {
            $button.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#B91C1C')
            $button.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#991B1B')
            $button.Foreground = [System.Windows.Media.Brushes]::White
        }
        default {
            $button.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFFF')
            $button.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#D1D5DB')
            $button.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#1F2937')
        }
    }
    return $button
}

function New-FelixUiListView {
    param(
        [Parameter(Mandatory)]
        [array]$Columns,

        [switch]$UseRuleSelection,
        [switch]$UseRiskColors
    )

    $list = New-Object System.Windows.Controls.ListView
    $list.BorderThickness = [System.Windows.Thickness]::new(1)
    $gridView = New-Object System.Windows.Controls.GridView

    if ($UseRuleSelection) {
        $factory = [System.Windows.FrameworkElementFactory]::new([System.Windows.Controls.CheckBox])
        $binding = [System.Windows.Data.Binding]::new('selected')
        $binding.Mode = [System.Windows.Data.BindingMode]::TwoWay
        $binding.UpdateSourceTrigger = [System.Windows.Data.UpdateSourceTrigger]::PropertyChanged
        $factory.SetBinding([System.Windows.Controls.CheckBox]::IsCheckedProperty, $binding)
        $template = [System.Windows.DataTemplate]::new()
        $template.VisualTree = $factory
        $selectionColumn = New-Object System.Windows.Controls.GridViewColumn
        $selectionColumn.Header = ''
        $selectionColumn.Width = 42
        $selectionColumn.CellTemplate = $template
        $gridView.Columns.Add($selectionColumn) | Out-Null
    }

    foreach ($column in $Columns) {
        $gridColumn = New-Object System.Windows.Controls.GridViewColumn
        $gridColumn.Header = $column.Header
        $gridColumn.Width = $column.Width
        $gridColumn.DisplayMemberBinding = New-Object System.Windows.Data.Binding -ArgumentList $column.Property
        $gridView.Columns.Add($gridColumn) | Out-Null
    }

    $list.View = $gridView
    if ($UseRiskColors) {
        $style = [System.Windows.Style]::new([System.Windows.Controls.ListViewItem])
        $lowTrigger = [System.Windows.DataTrigger]::new()
        $lowTrigger.Binding = [System.Windows.Data.Binding]::new('riskCode')
        $lowTrigger.Value = 'low'
        $lowTrigger.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.Control]::ForegroundProperty, [System.Windows.Media.Brushes]::DarkGreen))
        $highTrigger = [System.Windows.DataTrigger]::new()
        $highTrigger.Binding = [System.Windows.Data.Binding]::new('riskCode')
        $highTrigger.Value = 'high'
        $highTrigger.Setters.Add([System.Windows.Setter]::new([System.Windows.Controls.Control]::ForegroundProperty, [System.Windows.Media.Brushes]::DarkRed))
        $style.Triggers.Add($lowTrigger)
        $style.Triggers.Add($highTrigger)
        $list.ItemContainerStyle = $style
    }
    return $list
}

function Set-FelixUiPageTitle {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [string]$Subtitle = ''
    )

    $script:FelixUiState.PageTitle.Text = $Title
    $script:FelixUiState.PageSubtitle.Text = $Subtitle
}

function Set-FelixUiContent {
    param(
        [Parameter(Mandatory)]
        [System.Windows.UIElement]$Element
    )

    $script:FelixUiState.ContentHost.Content = $Element
}

function Clear-FelixUiPageCache {
    param(
        [string[]]$Page
    )

    if (-not $Page) {
        $script:FelixUiState.RuleRows = @()
        $script:FelixUiState.RuleSystemChecks = @{}
        $script:FelixUiState.RuleDetailCache = @{}
        $script:FelixUiState.RuleRowById = @{}
        $script:FelixUiState.RuleLoadError = $null
        $script:FelixUiState.RuleAuditReady = $false
        $script:FelixUiState.RuleAuditLoadedCount = 0
        Stop-FelixUiRulesLoad
        Stop-FelixUiOverviewLoad
        $script:FelixUiState.OverviewStatus = $null
        $script:FelixUiState.OverviewHardware = $null
        $script:FelixUiState.OverviewChangeReport = $null
        $script:FelixUiState.PageViews.Clear()
        return
    }

    foreach ($pageName in $Page) {
        if ($pageName -eq 'rules') {
            $script:FelixUiState.RuleRows = @()
            $script:FelixUiState.RuleSystemChecks = @{}
            $script:FelixUiState.RuleDetailCache = @{}
            $script:FelixUiState.RuleRowById = @{}
            $script:FelixUiState.RuleLoadError = $null
            $script:FelixUiState.RuleAuditReady = $false
            $script:FelixUiState.RuleAuditLoadedCount = 0
            Stop-FelixUiRulesLoad
        }
        if ($pageName -eq 'overview') {
            Stop-FelixUiOverviewLoad
            $script:FelixUiState.OverviewStatus = $null
            $script:FelixUiState.OverviewHardware = $null
            $script:FelixUiState.OverviewChangeReport = $null
        }
        if ($script:FelixUiState.PageViews.ContainsKey($pageName)) {
            $script:FelixUiState.PageViews.Remove($pageName) | Out-Null
        }
    }
}

function Set-FelixUiStatus {
    param([string]$Message)

    $script:FelixUiState.StatusText.Text = $Message
}

function ConvertTo-FelixUiRuleRows {
    param(
        [object[]]$Audit
    )

    $rows = @()
    foreach ($row in @($audit)) {
        if ($null -eq $row -or -not $row.PSObject.Properties['id']) {
            continue
        }
        $source = $row.id
        $rows += [pscustomobject]@{
            id = $row.id
            name = $row.name
            category = $row.category
            categoryName = Get-FelixUiCategoryName -Category $row.category
            risk = if ($row.risk -eq 'safe') { $script:FelixUiState.Text.rules.riskLow } else { $script:FelixUiState.Text.rules.riskHigh }
            riskCode = if ($row.risk -eq 'safe') { 'low' } else { 'high' }
            status = Get-FelixUiStatusText -Status $row.status
            systemState = $row.systemState
            systemCheck = Get-FelixUiSystemStateText -State $row.systemState
            systemCheckMessage = $row.systemStateMessage
            applicability = $row.applicabilityLabel
            applicabilityCode = $row.applicability
            applicabilityMessage = $row.applicabilityMessage
            applicabilityConfidence = $row.applicabilityConfidence
            evidenceCount = @($row.evidence).Count
            evidence = @($row.evidence)
            batchEligible = [bool]$row.batchEligible
            requiresInput = [bool]$row.requiresInput
            restart = if ($row.requiresRestart) { $script:FelixUiState.Text.rules.yes } else { $script:FelixUiState.Text.rules.no }
            available = if ($row.available) { 'OK' } else { 'N/A' }
            requirement = $row.requirement
            sourceId = $source
            selected = $false
        }
    }
    return @($rows)
}

function ConvertTo-FelixUiRuleShells {
    param(
        [object[]]$Rules
    )

    $text = $script:FelixUiState.Text
    $rows = foreach ($rule in @($Rules)) {
        if ($null -eq $rule) {
            continue
        }
        [pscustomobject]@{
            id = $rule.id
            name = $rule.name
            category = $rule.category
            categoryName = Get-FelixUiCategoryName -Category $rule.category
            risk = if ($rule.risk -eq 'safe') { $text.rules.riskLow } else { $text.rules.riskHigh }
            riskCode = if ($rule.risk -eq 'safe') { 'low' } else { 'high' }
            status = $text.rules.checking
            systemState = 'Unknown'
            systemCheck = $text.rules.systemChecking
            systemCheckMessage = ''
            applicability = $text.rules.applicabilityChecking
            applicabilityCode = 'Checking'
            applicabilityMessage = ''
            applicabilityConfidence = ''
            evidenceCount = 0
            evidence = @()
            batchEligible = $false
            requiresInput = [bool]$rule.requiresInput
            restart = if ($rule.requiresRestart) { $text.rules.yes } else { $text.rules.no }
            available = ''
            requirement = ''
            sourceId = $rule.id
            selected = $false
        }
    }
    return @($rows)
}

function Get-FelixUiRuleRows {
    return @(ConvertTo-FelixUiRuleRows -Audit @(Invoke-FelixAudit))
}

function Stop-FelixUiRulesLoad {
    if (-not $script:FelixUiState.RuleLoad) {
        return
    }

    $load = $script:FelixUiState.RuleLoad
    if ($load.Timer) {
        $load.Timer.Stop()
    }
    if ($load.Job) {
        Stop-Job -Job $load.Job -ErrorAction SilentlyContinue
        Remove-Job -Job $load.Job -Force -ErrorAction SilentlyContinue
    }
    $script:FelixUiState.RuleLoad = $null
}

function Complete-FelixUiRulesLoad {
    $load = $script:FelixUiState.RuleLoad
    if (-not $load) {
        return
    }

    $job = $load.Job
    if (-not $job -or $job.State -notin @('Completed', 'Failed', 'Stopped')) {
        return
    }

    $load.Timer.Stop()
    try {
        if ($job.State -eq 'Completed') {
            $audit = @(Receive-Job -Job $job -ErrorAction Stop | Where-Object {
                $null -ne $_ -and $_.PSObject.Properties['id']
            })
            $script:FelixUiState.RuleRows = @(ConvertTo-FelixUiRuleRows -Audit $audit)
            $script:FelixUiState.RuleDetailCache = @{}
            $script:FelixUiState.RuleRowById = @{}
            $script:FelixUiState.RuleLoadError = $null
            $script:FelixUiState.RuleAuditReady = $true
            $script:FelixUiState.RuleAuditLoadedCount = $audit.Count
        }
        else {
            $script:FelixUiState.RuleLoadError = @(Receive-Job -Job $job -ErrorAction SilentlyContinue) -join [Environment]::NewLine
        }
    }
    catch {
        $script:FelixUiState.RuleLoadError = $_.Exception.Message
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        $script:FelixUiState.RuleLoad = $null
    }

    if (@(Get-FelixAllRuleRows).Count -gt 0 -and $script:FelixUiState.RuleList) {
        Update-FelixUiRuleList
    }
    elseif ($script:FelixUiState.CurrentPage -eq 'rules' -and $script:FelixUiState.RuleLoadError) {
        $script:FelixUiState.RuleDetails.Text = "$($script:FelixUiState.Text.rules.loadFailed)$($script:FelixUiState.RuleLoadError)"
    }
    if (@(Get-FelixAllRuleRows).Count -gt 0) {
        Set-FelixUiStatus -Message $script:FelixUiState.Text.app.statusReady
    }
}

function Start-FelixUiRulesLoad {
    if (@(Get-FelixAllRuleRows).Count -gt 0 -and $script:FelixUiState.RuleAuditReady) {
        return
    }
    if ($script:FelixUiState.RuleLoad) {
        return
    }

    if (@(Get-FelixAllRuleRows).Count -eq 0) {
        $script:FelixUiState.RuleRows = @(ConvertTo-FelixUiRuleShells -Rules @(Get-FelixRule))
        $script:FelixUiState.RuleDetailCache = @{}
        $script:FelixUiState.RuleRowById = @{}
    }

    $script:FelixUiState.RuleAuditReady = $false
    $script:FelixUiState.RuleAuditLoadedCount = 0
    $script:FelixUiState.RuleLoad = [ordered]@{
        Job = $null
        Timer = $null
        Hardware = $null
        Pending = $true
    }
}

function Start-FelixUiRulesAudit {
    param(
        [System.Collections.IDictionary]$Hardware
    )

    $load = $script:FelixUiState.RuleLoad
    if (-not $load -or -not $load.Pending) {
        return
    }

    if ($script:FelixUiState.SmokeTest -or -not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
        $script:FelixUiState.RuleRows = @(Get-FelixUiRuleRows)
        $script:FelixUiState.RuleDetailCache = @{}
        $script:FelixUiState.RuleRowById = @{}
        $script:FelixUiState.RuleAuditReady = $true
        $script:FelixUiState.RuleAuditLoadedCount = @(Get-FelixAllRuleRows).Count
        $script:FelixUiState.RuleLoad = $null
        if ($script:FelixUiState.RuleList) {
            Update-FelixUiRuleList
        }
        return
    }

    $manifestPath = Join-Path $script:ModuleRoot 'StableTune.psd1'
    $statePath = Get-FelixStatePath
    $job = Start-ThreadJob -ScriptBlock {
        param($ModuleManifest, $StatePath, $HardwareSnapshot)
        $env:FELIX_OPTIMIZER_HOME = $StatePath
        Import-Module $ModuleManifest -Force
        if ($null -ne $HardwareSnapshot) {
            Invoke-FelixAudit -Hardware $HardwareSnapshot
        }
        else {
            Invoke-FelixAudit
        }
    } -ArgumentList $manifestPath, $statePath, $Hardware

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $timer.Add_Tick({
        Complete-FelixUiRulesLoad
    })
    $load.Job = $job
    $load.Timer = $timer
    $load.Hardware = $Hardware
    $load.Pending = $false
    $timer.Start()
}

function Update-FelixUiRuleList {
    if (-not $script:FelixUiState.RuleList) {
        return
    }

    $selectedId = $null
    if ($script:FelixUiState.RuleList.SelectedItem) {
        $selectedId = $script:FelixUiState.RuleList.SelectedItem.id
    }
    $rows = @(Get-FelixAllRuleRows)
    $ruleChecks = @{}
    $rowById = @{}
    foreach ($row in $rows) {
        $rowById[[string]$row.id] = $row
        $ruleChecks[[string]$row.id] = [ordered]@{
            state = [string]$row.systemState
            message = [string]$row.systemCheckMessage
        }
    }
    $script:FelixUiState.RuleSystemChecks = $ruleChecks
    $script:FelixUiState.RuleRowById = $rowById

    $ruleItems = $script:FelixUiState.RuleItems
    $ruleItemsView = $script:FelixUiState.RuleItemsView
    if ($null -eq $ruleItems -or $null -eq $ruleItemsView) {
        return
    }

    $needsReplace = $ruleItems.Count -ne $rows.Count
    if (-not $needsReplace) {
        for ($index = 0; $index -lt $rows.Count; $index++) {
            if ([string]$ruleItems[$index].id -ne [string]$rows[$index].id) {
                $needsReplace = $true
                break
            }
        }
    }
    $script:FelixUiState.IsUpdatingRuleList = $true
    try {
        if ($needsReplace) {
            $ruleItems.Clear()
            foreach ($row in $rows) {
                $ruleItems.Add($row) | Out-Null
            }
        }
        $ruleItemsView.Refresh()
        if ($selectedId) {
            foreach ($item in $script:FelixUiState.RuleList.Items) {
                if ($item.id -eq $selectedId) {
                    $script:FelixUiState.RuleList.SelectedItem = $item
                    break
                }
            }
        }
    }
    finally {
        $script:FelixUiState.IsUpdatingRuleList = $false
    }

    if ($script:FelixUiState.RuleList.SelectedItem) {
        Show-FelixRuleHint
    }
    else {
        $script:FelixUiState.SelectedRule = $null
        $script:FelixUiState.RuleDetails.Text = $script:FelixUiState.Text.dialogs.selectRule
    }
}

function Get-FelixAllRuleRows {
    return @($script:FelixUiState.RuleRows | Where-Object { $null -ne $_ })
}

function Get-FelixVisibleRuleRows {
    $rows = @(Get-FelixAllRuleRows)
    if ($script:FelixUiState.RuleFilter -and $script:FelixUiState.RuleFilter.SelectedItem) {
        $category = $script:FelixUiState.RuleFilter.SelectedItem.value
        if ($category) {
            $rows = @($rows | Where-Object { $_.category -eq $category })
        }
    }
    return @($rows)
}

function Get-FelixSelectedRuleRows {
    return @(Get-FelixAllRuleRows | Where-Object { $_.selected })
}

function Get-FelixSelectedRuleCount {
    return @(Get-FelixSelectedRuleRows).Count
}

function Set-FelixVisibleRuleSelection {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('All', 'None', 'Applicable')]
        [string]$Mode
    )

    foreach ($row in @(Get-FelixVisibleRuleRows)) {
        $row.selected = switch ($Mode) {
            'All' { $true }
            'None' { $false }
            'Applicable' { [bool]$row.batchEligible }
        }
    }
    Update-FelixUiRuleList
    return Get-FelixSelectedRuleCount
}

function Show-FelixRuleHint {
    if (-not $script:FelixUiState.SelectedRule) {
        $script:FelixUiState.RuleDetails.Text = $script:FelixUiState.Text.dialogs.selectRule
        return
    }

    $rule = $script:FelixUiState.SelectedRule
    $ruleId = [string]$rule.id
    if (-not $script:FelixUiState.RuleAuditReady -and $script:FelixUiState.RuleLoad) {
        $script:FelixUiState.RuleDetails.Text = $script:FelixUiState.Text.rules.loading
        return
    }
    $detailCache = $script:FelixUiState.RuleDetailCache
    if ($detailCache -and $detailCache.ContainsKey($ruleId)) {
        $script:FelixUiState.RuleDetails.Text = [string]$detailCache[$ruleId]
        return
    }

    $restartText = if ($rule.requiresRestart) { $script:FelixUiState.Text.rules.yes } else { $script:FelixUiState.Text.rules.no }
    $riskText = if ($rule.risk -eq 'safe') { $script:FelixUiState.Text.rules.riskLow } else { $script:FelixUiState.Text.rules.riskHigh }
    $row = $null
    if ($script:FelixUiState.RuleRowById -and $script:FelixUiState.RuleRowById.ContainsKey($ruleId)) {
        $row = $script:FelixUiState.RuleRowById[$ruleId]
    }
    $applicability = if ($row) {
        [ordered]@{
            label = [string]$row.applicability
            confidence = [string]$row.applicabilityConfidence
            message = [string]$row.applicabilityMessage
            evidence = @($row.evidence)
        }
    }
    else {
        Get-FelixRuleApplicability -Rule $rule
    }
    $changeState = if (
        $script:FelixUiState.RuleSystemChecks -and
        $script:FelixUiState.RuleSystemChecks.ContainsKey([string]$rule.id)
    ) {
        $script:FelixUiState.RuleSystemChecks[[string]$rule.id]
    }
    else {
        Get-FelixRuleChangeState -Rule $rule
    }
    $lines = @(
        $rule.name
        ''
        $rule.description
        ''
        "$($script:FelixUiState.Text.rules.advice):"
        [string]$rule.advice
        ''
        "$($script:FelixUiState.Text.rules.consequences):"
    )
    $lines += @($rule.consequences | ForEach-Object { "- $_" })
    $lines += @(
        ''
        "$($script:FelixUiState.Text.rules.category): $(Get-FelixUiCategoryName -Category $rule.category)"
        "$($script:FelixUiState.Text.rules.risk): $riskText"
        "$($script:FelixUiState.Text.rules.restart): $restartText"
        "$($script:FelixUiState.Text.rules.applicability): $($applicability.label) / $($applicability.confidence)"
        "$($applicability.message)"
        "$($script:FelixUiState.Text.rules.systemCheck): $(Get-FelixUiSystemStateText -State $changeState.state)"
        "$($changeState.message)"
        ''
        "$($script:FelixUiState.Text.rules.benefits):"
    )
    $lines += @($rule.benefits | ForEach-Object { "- $_" })
    $lines += @(
        ''
        "$($script:FelixUiState.Text.rules.drawbacks):"
    )
    $lines += @($rule.drawbacks | ForEach-Object { "- $_" })
    $lines += @(
        ''
        "$($script:FelixUiState.Text.rules.compatibility):"
    )

    $compatibilityLabels = [ordered]@{
        scope = $script:FelixUiState.Text.rules.scope
        os = $script:FelixUiState.Text.rules.os
        cpuBrand = $script:FelixUiState.Text.rules.cpuBrand
        cpuSeries = $script:FelixUiState.Text.rules.cpuSeries
        gpuBrand = $script:FelixUiState.Text.rules.gpuBrand
        gpuDriver = $script:FelixUiState.Text.rules.gpuDriver
        memory = $script:FelixUiState.Text.rules.memory
        storage = $script:FelixUiState.Text.rules.storage
        device = $script:FelixUiState.Text.rules.device
    }
    foreach ($key in $compatibilityLabels.Keys) {
        if ($rule.compatibility.ContainsKey($key)) {
            $lines += "- $($compatibilityLabels[$key]): $($rule.compatibility[$key])"
        }
    }

    $lines += @(
        ''
        "$($script:FelixUiState.Text.rules.evidence)（$($applicability.evidence.Count)）:"
    )
    foreach ($item in @($applicability.evidence)) {
        $lines += "- [$($item.kind)] $($item.title) - $($item.url)"
    }

    $detailText = $lines -join [Environment]::NewLine
    $script:FelixUiState.RuleDetails.Text = $detailText
    if ($detailCache) {
        $detailCache[$ruleId] = $detailText
    }
}

function Show-FelixPage {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('overview', 'rules', 'history', 'restore', 'logs', 'settings', 'about')]
        [string]$Page,

        [switch]$Force
    )

    $script:FelixUiState.CurrentPage = $Page
    if (-not $Force -and $script:FelixUiState.PageViews.ContainsKey($Page)) {
        $view = $script:FelixUiState.PageViews[$Page]
        Set-FelixUiPageTitle -Title $view.Title -Subtitle $view.Subtitle
        Set-FelixUiContent -Element $view.Element
        return
    }

    if ($Force -and $script:FelixUiState.PageViews.ContainsKey($Page)) {
        $script:FelixUiState.PageViews.Remove($Page) | Out-Null
    }

    switch ($Page) {
        'overview' { Show-FelixOverviewPage }
        'rules' { Show-FelixRulesPage }
        'history' { Show-FelixHistoryPage }
        'restore' { Show-FelixRestorePage }
        'logs' { Show-FelixLogsPage }
        'settings' { Show-FelixSettingsPage }
        'about' { Show-FelixAboutPage }
    }

    $script:FelixUiState.PageViews[$Page] = [ordered]@{
        Element = $script:FelixUiState.ContentHost.Content
        Title = $script:FelixUiState.PageTitle.Text
        Subtitle = $script:FelixUiState.PageSubtitle.Text
    }
}

function New-FelixMetric {
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [string]$Value
    )

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = [System.Windows.Thickness]::new(0, 0, 36, 18)
    $labelBlock = New-Object System.Windows.Controls.TextBlock
    $labelBlock.Text = $Label
    $labelBlock.Foreground = [System.Windows.Media.Brushes]::DimGray
    $labelBlock.FontSize = 12
    $valueBlock = New-Object System.Windows.Controls.TextBlock
    $valueBlock.Text = $Value
    $valueBlock.FontSize = 20
    $valueBlock.FontWeight = [System.Windows.FontWeights]::SemiBold
    $valueBlock.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    $panel.Children.Add($labelBlock) | Out-Null
    $panel.Children.Add($valueBlock) | Out-Null
    return [pscustomobject]@{
        Element = $panel
        Value = $valueBlock
    }
}

function Add-FelixUiOverviewMetric {
    param(
        [Parameter(Mandatory)]
        [System.Windows.Controls.WrapPanel]$Metrics,

        [Parameter(Mandatory)]
        [hashtable]$Values,

        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [string]$Value
    )

    $metric = New-FelixMetric -Label $Label -Value $Value
    $Metrics.Children.Add($metric.Element) | Out-Null
    $Values[$Key] = $metric.Value
}

function Set-FelixUiOverviewMetric {
    param(
        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        [string]$Value
    )

    $values = $script:FelixUiState.OverviewMetricValues
    if ($values -and $values.ContainsKey($Key)) {
        $values[$Key].Text = $Value
    }
}

function Update-FelixUiOverviewStatus {
    $status = $script:FelixUiState.OverviewStatus
    if ($null -eq $status) {
        return
    }

    $text = $script:FelixUiState.Text
    $rollbackValue = if ($status.rollbackMode -eq 'IndependentSnapshot') {
        if ($status.rollbackAvailable) { $text.overview.snapshotOnlyReady } else { $text.overview.rollbackUnavailable }
    }
    elseif ($status.rollbackAvailable) {
        $text.overview.rollbackReady
    }
    else {
        $text.overview.rollbackUnavailable
    }
    $crashValue = if ($status.crashRecovery.manualCount -gt 0) {
        $text.rules.crashRecoveryFailed
    }
    elseif ($status.crashRecovery.activeCount -gt 0) {
        "$($status.crashRecovery.activeCount) / $($text.overview.crashPending)"
    }
    else {
        $text.overview.crashReady
    }

    Set-FelixUiOverviewMetric -Key 'os' -Value ([string]$status.os)
    Set-FelixUiOverviewMetric -Key 'admin' -Value $(if ($status.isAdministrator) { 'Yes' } else { 'No' })
    Set-FelixUiOverviewMetric -Key 'power' -Value ([string]$status.activePowerPlan)
    Set-FelixUiOverviewMetric -Key 'rollback' -Value $rollbackValue
    Set-FelixUiOverviewMetric -Key 'crash' -Value $crashValue
    Set-FelixUiOverviewMetric -Key 'snapshot' -Value $(if ($status.snapshotAvailable) { $text.overview.rollbackReady } else { $text.overview.rollbackUnavailable })
    Set-FelixUiOverviewMetric -Key 'systemRestorePoint' -Value $(if ($status.restorePointAvailable) { $text.overview.restorePointReady } else { $text.overview.restorePointUnavailable })
    Set-FelixUiOverviewMetric -Key 'history' -Value ([string]$status.historyCount)
    Set-FelixUiOverviewMetric -Key 'pending' -Value ([string]$status.restorableCount)

    $notice = $script:FelixUiState.OverviewNotice
    if ($null -eq $notice) {
        return
    }
    $noticeLines = @(
        if ($status.rollbackMode -eq 'IndependentSnapshot') {
            if ($status.rollbackAvailable) { $text.dialogs.snapshotOnlyReady } else { $text.dialogs.rollbackUnavailable }
        }
        elseif ($status.rollbackAvailable) {
            $text.dialogs.rollbackReady
        }
        else {
            $text.dialogs.rollbackUnavailable
        }
        "$($text.overview.crashInsurance): $($status.crashRecovery.message)"
        "$($text.overview.snapshot): $(if ($status.snapshotAvailable) { $text.overview.rollbackReady } else { $text.overview.rollbackUnavailable })"
        if ($status.rollbackMode -eq 'IndependentSnapshot') {
            "$($text.overview.systemRestorePoint): $($text.overview.restorePointNotRequired)"
        }
        else {
            "$($text.overview.systemRestorePoint): $(if ($status.restorePointAvailable) { $text.overview.restorePointReady } else { $text.overview.restorePointUnavailable })"
        }
        [string]$status.rollbackMessage
    )
    if ($status.rollbackMode -eq 'IndependentSnapshot') {
        $noticeLines += $text.dialogs.snapshotOnlyWarning
    }
    $notice.Text = $noticeLines -join [Environment]::NewLine
    $notice.Foreground = if ($status.rollbackAvailable) {
        [System.Windows.Media.Brushes]::DarkGreen
    }
    else {
        [System.Windows.Media.Brushes]::DarkRed
    }
}

function Update-FelixUiOverviewHardware {
    param(
        [System.Collections.IDictionary]$Hardware
    )

    $panel = $script:FelixUiState.OverviewHardwarePanel
    if ($null -eq $panel) {
        return
    }

    $text = $script:FelixUiState.Text
    $panel.Children.Clear()
    $hardwareTitle = New-Object System.Windows.Controls.TextBlock
    $hardwareTitle.Text = $text.overview.hardwareTitle
    $hardwareTitle.FontSize = 18
    $hardwareTitle.FontWeight = [System.Windows.FontWeights]::SemiBold
    $hardwareTitle.Margin = [System.Windows.Thickness]::new(0, 10, 0, 8)
    $panel.Children.Add($hardwareTitle) | Out-Null

    if ($null -eq $Hardware) {
        $loading = New-Object System.Windows.Controls.TextBlock
        $loading.Text = $text.overview.hardwareLoading
        $loading.Foreground = [System.Windows.Media.Brushes]::DimGray
        $panel.Children.Add($loading) | Out-Null
        return
    }

    $cpuText = if (@($Hardware.cpu).Count -gt 0) {
        @($Hardware.cpu | ForEach-Object { "$($_.name) / $($_.cores)C$($_.logicalProcessors)T" }) -join '; '
    }
    else {
        $text.overview.hardwareUnavailable
    }
    $gpuText = if (@($Hardware.gpu).Count -gt 0) {
        @($Hardware.gpu | ForEach-Object { "$($_.name) / $($_.driverVersion)" }) -join '; '
    }
    else {
        $text.overview.hardwareUnavailable
    }
    $diskText = if (@($Hardware.disks).Count -gt 0) {
        @($Hardware.disks | ForEach-Object {
            $size = if ($_.sizeBytes -gt 0) { " / $([math]::Round($_.sizeBytes / 1GB, 0)) GB" } else { '' }
            "$($_.model)$size"
        }) -join '; '
    }
    else {
        $text.overview.hardwareUnavailable
    }
    $deviceSecurityText = if ($null -ne $Hardware.deviceSecurity) {
        $hvciState = switch ($Hardware.deviceSecurity.hvciRunning) {
            $true { 'HVCI 运行中' }
            $false { 'HVCI 未运行' }
            default { 'HVCI 状态未知' }
        }
        "$($Hardware.deviceSecurity.vbsStatusText) / $hvciState / $($Hardware.deviceSecurity.message)"
    }
    else {
        $text.overview.deviceSecurityUnavailable
    }
    $aceText = if ([bool]$Hardware.antiCheatExpertInstalled) {
        $text.overview.aceDetected
    }
    else {
        $text.overview.aceNotDetected
    }

    foreach ($entry in @(
        @{ Label = $text.overview.computer; Value = "$($Hardware.manufacturer) $($Hardware.model) [$($Hardware.computer)]" },
        @{ Label = $text.overview.cpu; Value = $cpuText },
        @{ Label = $text.overview.gpu; Value = $gpuText },
        @{ Label = $text.overview.memory; Value = $Hardware.memorySummary },
        @{ Label = $text.overview.motherboard; Value = $Hardware.motherboard },
        @{ Label = $text.overview.disks; Value = $diskText },
        @{ Label = $text.overview.deviceSecurity; Value = $deviceSecurityText },
        @{ Label = $text.overview.acePresence; Value = $aceText }
    )) {
        $line = New-Object System.Windows.Controls.TextBlock
        $line.Text = "$($entry.Label): $($entry.Value)"
        $line.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $line.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
        $panel.Children.Add($line) | Out-Null
    }

    $memoryTitle = New-Object System.Windows.Controls.TextBlock
    $memoryTitle.Text = $text.overview.memoryModules
    $memoryTitle.FontSize = 16
    $memoryTitle.FontWeight = [System.Windows.FontWeights]::SemiBold
    $memoryTitle.Margin = [System.Windows.Thickness]::new(0, 14, 0, 6)
    $panel.Children.Add($memoryTitle) | Out-Null

    if (@($Hardware.memory).Count -gt 0) {
        foreach ($module in $Hardware.memory) {
            $moduleLine = New-Object System.Windows.Controls.TextBlock
            $moduleName = if ($module.deviceLocator) { [string]$module.deviceLocator } else { [string]$module.bankLabel }
            if ([string]::IsNullOrWhiteSpace($moduleName)) {
                $moduleName = [string]$module.partNumber
            }
            $size = if ($module.capacityBytes -gt 0) { "$([math]::Round($module.capacityBytes / 1GB, 1)) GiB" } else { $text.overview.hardwareUnavailable }
            $configuredSpeed = if ($module.configuredSpeedMHz -gt 0) { "$($module.configuredSpeedMHz) MT/s" } else { $text.overview.hardwareUnavailable }
            $ratedSpeed = if ($module.speedMHz -gt 0) { "$($module.speedMHz) MT/s" } else { $text.overview.hardwareUnavailable }
            $timing = if ($module.timings) {
                $commandRate = if ($module.timings.commandRate -gt 0) { " / CR$($module.timings.commandRate)" } else { '' }
                "CL$($module.timings.casLatency)-$($module.timings.trcd)-$($module.timings.trp)-$($module.timings.tras)$commandRate"
            }
            else {
                $text.overview.memoryTimingUnavailable
            }
            $moduleLine.Text = "$moduleName [$($module.memoryType)]: $($text.overview.memorySize) $size / $($text.overview.memoryConfiguredSpeed) $configuredSpeed / $($text.overview.memoryRatedSpeed) $ratedSpeed / $($text.overview.timing) $timing"
            $moduleLine.TextWrapping = [System.Windows.TextWrapping]::Wrap
            $moduleLine.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
            $panel.Children.Add($moduleLine) | Out-Null
        }
        if (@($Hardware.memory | Where-Object { $_.timings }).Count -eq 0) {
            $timingHelp = New-Object System.Windows.Controls.TextBlock
            $timingHelp.Text = $text.overview.memoryTimingHelp
            $timingHelp.Foreground = [System.Windows.Media.Brushes]::DimGray
            $timingHelp.TextWrapping = [System.Windows.TextWrapping]::Wrap
            $timingHelp.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
            $panel.Children.Add($timingHelp) | Out-Null
        }
    }
    else {
        $memoryFallback = New-Object System.Windows.Controls.TextBlock
        $memoryFallback.Text = "$($Hardware.memorySummary) / $($Hardware.memoryTimingMessage)"
        $memoryFallback.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $memoryFallback.Foreground = [System.Windows.Media.Brushes]::DimGray
        $memoryFallback.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
        $panel.Children.Add($memoryFallback) | Out-Null
    }

    if ($Hardware.osCaption -ne 'Unavailable') {
        Set-FelixUiOverviewMetric -Key 'os' -Value "$($Hardware.osCaption) $($Hardware.osBuild)"
    }
}

function Update-FelixUiOverviewChangeReport {
    $report = $script:FelixUiState.OverviewChangeReport
    if ($null -eq $report) {
        return
    }

    $text = $script:FelixUiState.Text
    Set-FelixUiOverviewMetric -Key 'modified' -Value ([string]$report.modified)
    Set-FelixUiOverviewMetric -Key 'clear' -Value ([string]$report.notModified)
    Set-FelixUiOverviewMetric -Key 'selection' -Value ([string]$report.requiresSelection)
    $notice = $script:FelixUiState.OverviewChangeNotice
    if ($null -ne $notice) {
        $notice.Text = "$($text.overview.systemChanges): $($report.modified) / $($report.total) ($($text.overview.modifiedCount): $($report.modified), $($text.overview.clearCount): $($report.notModified), $($text.overview.selectionCount): $($report.requiresSelection))"
    }
}

function Update-FelixUiOverviewData {
    Update-FelixUiOverviewStatus
    Update-FelixUiOverviewHardware -Hardware $script:FelixUiState.OverviewHardware
    Update-FelixUiOverviewChangeReport
}

function Stop-FelixUiOverviewLoad {
    $load = $script:FelixUiState.OverviewLoad
    if (-not $load) {
        return
    }
    if ($load.Timer) {
        $load.Timer.Stop()
    }
    foreach ($key in @('Status', 'Hardware', 'ChangeReport')) {
        $job = $load.Jobs[$key]
        if ($job) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }
    $script:FelixUiState.OverviewLoad = $null
}

function Complete-FelixUiOverviewLoad {
    $load = $script:FelixUiState.OverviewLoad
    if (-not $load) {
        return
    }

    foreach ($key in @('Status', 'Hardware', 'ChangeReport')) {
        $job = $load.Jobs[$key]
        if (-not $job -or $job.State -notin @('Completed', 'Failed', 'Stopped')) {
            continue
        }

        try {
            if ($job.State -eq 'Completed') {
                $result = @(Receive-Job -Job $job -ErrorAction Stop | Where-Object { $null -ne $_ })
                $value = if ($result.Count -gt 0) { $result[-1] } else { $null }
                switch ($key) {
                    'Status' {
                        $script:FelixUiState.OverviewStatus = $value
                    }
                    'Hardware' {
                        $script:FelixUiState.OverviewHardware = $value
                        Start-FelixUiRulesAudit -Hardware $value
                    }
                    'ChangeReport' {
                        $script:FelixUiState.OverviewChangeReport = $value
                    }
                }
            }
            else {
                $message = @(Receive-Job -Job $job -ErrorAction SilentlyContinue) -join [Environment]::NewLine
                Add-FelixLog -Level Warning -Event "ui.overview_$($key.ToLowerInvariant())" -Message $message
                if ($key -eq 'Hardware') {
                    Start-FelixUiRulesAudit
                }
            }
        }
        catch {
            Add-FelixLog -Level Warning -Event "ui.overview_$($key.ToLowerInvariant())" -Message $_.Exception.Message
            if ($key -eq 'Hardware') {
                Start-FelixUiRulesAudit
            }
        }
        finally {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            $load.Jobs[$key] = $null
        }
    }

    Update-FelixUiOverviewData
    if (-not @($load.Jobs.Values | Where-Object { $_ }).Count) {
        $load.Timer.Stop()
        $script:FelixUiState.OverviewLoad = $null
    }
}

function Start-FelixUiOverviewLoad {
    if (
        $script:FelixUiState.OverviewLoad -or
        $script:FelixUiState.SmokeTest -or
        -not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
    ) {
        if (
            -not $script:FelixUiState.SmokeTest -and
            $script:FelixUiState.RuleLoad -and
            $script:FelixUiState.RuleLoad.Pending
        ) {
            Start-FelixUiRulesAudit
        }
        return
    }

    $manifestPath = Join-Path $script:ModuleRoot 'StableTune.psd1'
    $statePath = Get-FelixStatePath
    $jobs = @{}
    if ($null -eq $script:FelixUiState.OverviewStatus) {
        $jobs.Status = Start-ThreadJob -ScriptBlock {
            param($ModuleManifest, $StatePath)
            $env:FELIX_OPTIMIZER_HOME = $StatePath
            Import-Module $ModuleManifest -Force
            Get-FelixSystemStatus -Force
        } -ArgumentList $manifestPath, $statePath
    }
    if ($null -eq $script:FelixUiState.OverviewHardware) {
        $jobs.Hardware = Start-ThreadJob -ScriptBlock {
            param($ModuleManifest, $StatePath)
            $env:FELIX_OPTIMIZER_HOME = $StatePath
            Import-Module $ModuleManifest -Force
            Get-FelixHardwareInventory -Force
        } -ArgumentList $manifestPath, $statePath
    }
    if ($null -eq $script:FelixUiState.OverviewChangeReport) {
        $jobs.ChangeReport = Start-ThreadJob -ScriptBlock {
            param($ModuleManifest, $StatePath)
            $env:FELIX_OPTIMIZER_HOME = $StatePath
            Import-Module $ModuleManifest -Force
            Get-FelixSystemChangeReport
        } -ArgumentList $manifestPath, $statePath
    }

    if (-not @($jobs.Values | Where-Object { $_ }).Count) {
        if ($script:FelixUiState.RuleLoad -and $script:FelixUiState.RuleLoad.Pending) {
            Start-FelixUiRulesAudit -Hardware $script:FelixUiState.OverviewHardware
        }
        return
    }

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $timer.Add_Tick({
        Complete-FelixUiOverviewLoad
    })
    $script:FelixUiState.OverviewLoad = [ordered]@{
        Jobs = $jobs
        Timer = $timer
    }
    $timer.Start()
}

function Show-FelixOverviewPage {
    $text = $script:FelixUiState.Text
    Set-FelixUiPageTitle -Title $text.nav.overview -Subtitle $text.app.subtitle
    $status = $script:FelixUiState.OverviewStatus
    $hardware = $script:FelixUiState.OverviewHardware
    $changeReport = $script:FelixUiState.OverviewChangeReport

    $root = New-Object System.Windows.Controls.StackPanel
    $metrics = New-Object System.Windows.Controls.WrapPanel
    $metricValues = @{}
    Add-FelixUiOverviewMetric -Metrics $metrics -Values $metricValues -Key 'os' -Label $text.overview.os -Value $text.overview.loading
    Add-FelixUiOverviewMetric -Metrics $metrics -Values $metricValues -Key 'admin' -Label $text.overview.admin -Value $text.overview.loading
    Add-FelixUiOverviewMetric -Metrics $metrics -Values $metricValues -Key 'power' -Label $text.overview.power -Value $text.overview.loading
    Add-FelixUiOverviewMetric -Metrics $metrics -Values $metricValues -Key 'rollback' -Label $text.overview.rollback -Value $text.overview.loading
    Add-FelixUiOverviewMetric -Metrics $metrics -Values $metricValues -Key 'crash' -Label $text.overview.crashInsurance -Value $text.overview.loading
    Add-FelixUiOverviewMetric -Metrics $metrics -Values $metricValues -Key 'snapshot' -Label $text.overview.snapshot -Value $text.overview.loading
    Add-FelixUiOverviewMetric -Metrics $metrics -Values $metricValues -Key 'systemRestorePoint' -Label $text.overview.systemRestorePoint -Value $text.overview.loading
    Add-FelixUiOverviewMetric -Metrics $metrics -Values $metricValues -Key 'modified' -Label $text.overview.modifiedCount -Value $text.overview.loading
    Add-FelixUiOverviewMetric -Metrics $metrics -Values $metricValues -Key 'clear' -Label $text.overview.clearCount -Value $text.overview.loading
    Add-FelixUiOverviewMetric -Metrics $metrics -Values $metricValues -Key 'selection' -Label $text.overview.selectionCount -Value $text.overview.loading
    Add-FelixUiOverviewMetric -Metrics $metrics -Values $metricValues -Key 'history' -Label $text.overview.history -Value $text.overview.loading
    Add-FelixUiOverviewMetric -Metrics $metrics -Values $metricValues -Key 'pending' -Label $text.overview.pending -Value $text.overview.loading
    $root.Children.Add($metrics) | Out-Null
    $script:FelixUiState.OverviewMetricValues = $metricValues

    $hardwarePanel = New-Object System.Windows.Controls.StackPanel
    $root.Children.Add($hardwarePanel) | Out-Null
    $script:FelixUiState.OverviewHardwarePanel = $hardwarePanel
    Update-FelixUiOverviewHardware -Hardware $hardware

    $changeNotice = New-Object System.Windows.Controls.TextBlock
    $changeNotice.Text = $text.overview.systemChangesLoading
    $changeNotice.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $changeNotice.Margin = [System.Windows.Thickness]::new(0, 16, 0, 0)
    $changeNotice.FontWeight = [System.Windows.FontWeights]::SemiBold
    $root.Children.Add($changeNotice) | Out-Null
    $script:FelixUiState.OverviewChangeNotice = $changeNotice

    $notice = New-Object System.Windows.Controls.TextBlock
    $notice.Text = $text.overview.safetyLoading
    $notice.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $notice.Foreground = [System.Windows.Media.Brushes]::DimGray
    $notice.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    $root.Children.Add($notice) | Out-Null
    $script:FelixUiState.OverviewNotice = $notice

    Update-FelixUiOverviewData

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $scroll.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Disabled
    $scroll.Content = $root
    Set-FelixUiContent -Element $scroll
    Start-FelixUiOverviewLoad
}

function Show-FelixRulesPage {
    $text = $script:FelixUiState.Text
    Set-FelixUiPageTitle -Title $text.nav.rules -Subtitle $text.rules.details

    $pageRoot = New-Object System.Windows.Controls.Grid
    $pageRoot.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = [System.Windows.GridLength]::Auto }))
    $pageRoot.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }))

    $toolbar = New-Object System.Windows.Controls.StackPanel
    $toolbar.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)

    $filterRow = New-Object System.Windows.Controls.Grid
    $filterRow.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::Auto }))
    $filterRow.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::Auto }))
    $filterRow.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }))
    $filterRow.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::Auto }))
    $filterLabel = New-Object System.Windows.Controls.TextBlock
    $filterLabel.Text = "$($text.rules.category):"
    $filterLabel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $filterLabel.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $filter = New-Object System.Windows.Controls.ComboBox
    $filter.Width = 180
    $filter.DisplayMemberPath = 'label'
    $filter.Items.Add([pscustomobject]@{ label = $text.categories.all; value = $null }) | Out-Null
    foreach ($category in @('power_cpu', 'latency_scheduler', 'network', 'graphics', 'input_response', 'startup_services', 'storage', 'hardware_binding', 'system_shell')) {
        $filter.Items.Add([pscustomobject]@{ label = Get-FelixUiCategoryName -Category $category; value = $category }) | Out-Null
    }
    $filter.SelectedIndex = 0
    $filterRow.Children.Add($filterLabel) | Out-Null
    $filterRow.Children.Add($filter) | Out-Null
    $refreshButton = New-FelixUiButton -Text $text.app.refresh -Width 82 -Variant Selection
    [System.Windows.Controls.Grid]::SetColumn($filter, 1)
    [System.Windows.Controls.Grid]::SetColumn($refreshButton, 3)
    $filterRow.Children.Add($refreshButton) | Out-Null
    $toolbar.Children.Add($filterRow) | Out-Null

    $actionBar = New-Object System.Windows.Controls.Grid
    $actionBar.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
    $actionBar.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }))
    $actionBar.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::Auto }))

    $selectionButtons = New-Object System.Windows.Controls.WrapPanel
    $selectionButtons.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $batchButtons = New-Object System.Windows.Controls.WrapPanel
    $batchButtons.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $batchButtons.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

    $selectAllButton = New-FelixUiButton -Text $text.rules.selectAll -Width 74 -Variant Selection
    $clearSelectionButton = New-FelixUiButton -Text $text.rules.clearSelection -Width 82 -Variant Selection
    $selectApplicableButton = New-FelixUiButton -Text $text.rules.selectApplicable -Width 112 -Variant Selection
    $batchPreflightButton = New-FelixUiButton -Text $text.rules.batchPreflight -Width 108
    $batchApplyButton = New-FelixUiButton -Text $text.rules.batchApply -Width 100 -Variant Warning

    $selectionButtons.Children.Add($selectAllButton) | Out-Null
    $selectionButtons.Children.Add($clearSelectionButton) | Out-Null
    $selectionButtons.Children.Add($selectApplicableButton) | Out-Null
    $batchButtons.Children.Add($batchPreflightButton) | Out-Null
    $batchButtons.Children.Add($batchApplyButton) | Out-Null
    [System.Windows.Controls.Grid]::SetColumn($selectionButtons, 0)
    [System.Windows.Controls.Grid]::SetColumn($batchButtons, 1)
    $actionBar.Children.Add($selectionButtons) | Out-Null
    $actionBar.Children.Add($batchButtons) | Out-Null
    $toolbar.Children.Add($actionBar) | Out-Null
    $pageRoot.Children.Add($toolbar) | Out-Null

    $root = New-Object System.Windows.Controls.Grid
    [System.Windows.Controls.Grid]::SetRow($root, 1)
    $root.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(3, [System.Windows.GridUnitType]::Star) }))
    $root.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(2, [System.Windows.GridUnitType]::Star) }))

    $list = New-FelixUiListView -UseRuleSelection -UseRiskColors -Columns @(
        @{ Header = $text.rules.name; Property = 'name'; Width = 220 },
        @{ Header = $text.rules.applicability; Property = 'applicability'; Width = 100 },
        @{ Header = $text.rules.risk; Property = 'risk'; Width = 72 },
        @{ Header = $text.rules.state; Property = 'status'; Width = 82 },
        @{ Header = $text.rules.systemCheck; Property = 'systemCheck'; Width = 112 }
    )
    [System.Windows.Controls.Grid]::SetColumn($list, 0)
    $root.Children.Add($list) | Out-Null
    $pageRoot.Children.Add($root) | Out-Null

    $detailsPanel = New-Object System.Windows.Controls.Grid
    $detailsPanel.Margin = [System.Windows.Thickness]::new(18, 0, 0, 0)
    $detailsPanel.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = [System.Windows.GridLength]::Auto }))
    $detailsPanel.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{ Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }))

    $singleActionBar = New-Object System.Windows.Controls.Border
    $singleActionBar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F8FAFC')
    $singleActionBar.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E2E8F0')
    $singleActionBar.BorderThickness = [System.Windows.Thickness]::new(1)
    $singleActionBar.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $singleActionBar.Padding = [System.Windows.Thickness]::new(8, 6, 8, 6)
    $singleActionBar.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $buttons = New-Object System.Windows.Controls.WrapPanel
    $buttons.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $dryRunButton = New-FelixUiButton -Text $text.rules.dryRun -Width 82
    $applyButton = New-FelixUiButton -Text $text.rules.apply -Width 82 -Variant Warning
    $restoreButton = New-FelixUiButton -Text $text.rules.restore -Width 82 -Variant Selection
    $buttons.Children.Add($dryRunButton) | Out-Null
    $buttons.Children.Add($applyButton) | Out-Null
    $buttons.Children.Add($restoreButton) | Out-Null
    $singleActionBar.Child = $buttons
    $singleActionBar.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    [System.Windows.Controls.Grid]::SetRow($buttons, 0)
    $detailsPanel.Children.Add($singleActionBar) | Out-Null

    $details = New-Object System.Windows.Controls.TextBlock
    $details.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $details.FontSize = 14
    $details.Text = $text.dialogs.selectRule
    $detailsScroll = New-Object System.Windows.Controls.ScrollViewer
    $detailsScroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $detailsScroll.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Disabled
    $detailsScroll.Content = $details
    [System.Windows.Controls.Grid]::SetRow($detailsScroll, 1)
    $detailsPanel.Children.Add($detailsScroll) | Out-Null

    [System.Windows.Controls.Grid]::SetColumn($detailsPanel, 1)
    $root.Children.Add($detailsPanel) | Out-Null

    $ruleItems = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    $list.ItemsSource = $ruleItems
    $ruleItemsView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($ruleItems)
    $ruleItemsView.Filter = [System.Predicate[object]]{
        param([object]$item)

        $state = $script:FelixUiState
        if (
            -not $state -or
            -not $state.RuleFilter -or
            -not $state.RuleFilter.SelectedItem
        ) {
            return $true
        }
        $category = $state.RuleFilter.SelectedItem.value
        return (-not $category -or [string]$item.category -eq [string]$category)
    }

    $script:FelixUiState.RuleList = $list
    $script:FelixUiState.RuleItems = $ruleItems
    $script:FelixUiState.RuleItemsView = $ruleItemsView
    $script:FelixUiState.RuleDetails = $details
    $script:FelixUiState.RuleButtonPanel = $buttons
    $script:FelixUiState.RuleDetailsScrollViewer = $detailsScroll
    $script:FelixUiState.RuleFilter = $filter
    $script:FelixUiState.RuleSelectionPanel = $selectionButtons
    $script:FelixUiState.RuleBatchPanel = $batchButtons
    $script:FelixUiState.RuleSingleActionPanel = $buttons
    $script:FelixUiState.SelectedRule = $null
    if (@(Get-FelixAllRuleRows).Count -gt 0) {
        Update-FelixUiRuleList
    }
    else {
        $details.Text = $text.rules.loading
        Set-FelixUiStatus -Message $text.rules.loading
        Start-FelixUiRulesLoad
    }

    $refreshButton.Add_Click({
        $script:FelixUiState.RuleRows = @()
        $script:FelixUiState.RuleDetailCache = @{}
        $script:FelixUiState.RuleRowById = @{}
        $script:FelixUiState.RuleLoadError = $null
        Stop-FelixUiRulesLoad
        Show-FelixPage -Page 'rules' -Force
    })

    $filter.Add_SelectionChanged({
        Update-FelixUiRuleList
    })

    $selectAllButton.Add_Click({
        $count = Set-FelixVisibleRuleSelection -Mode All
        Set-FelixUiStatus -Message "已选择 $count 项。"
    })

    $clearSelectionButton.Add_Click({
        $count = Set-FelixVisibleRuleSelection -Mode None
        Set-FelixUiStatus -Message "已选择 $count 项。"
    })

    $selectApplicableButton.Add_Click({
        $count = Set-FelixVisibleRuleSelection -Mode Applicable
        Set-FelixUiStatus -Message "已选择 $count 项本机适用且可批量执行的规则。"
    })

    $batchPreflightButton.Add_Click({
        $rows = @(Get-FelixSelectedRuleRows)
        if ($rows.Count -eq 0) {
            Show-FelixMessage -Message $script:FelixUiState.Text.dialogs.selectRule
            return
        }
        $lines = @()
        foreach ($row in $rows) {
            if (-not $row.batchEligible -or $row.requiresInput) {
                $lines += "$($row.name): 跳过，$($row.applicabilityMessage)"
                continue
            }
            try {
                $plan = Invoke-FelixDryRun -RuleId $row.id
                $lines += "$($row.name): $($plan.plannedChanges -join '；')"
            }
            catch {
                $lines += "$($row.name): 预检失败 - $($_.Exception.Message)"
            }
        }
        Show-FelixMessage -Message ($lines -join [Environment]::NewLine) -Title $script:FelixUiState.Text.rules.batchPreflight
    })

    $batchApplyButton.Add_Click({
        $rows = @(Get-FelixSelectedRuleRows)
        if ($rows.Count -eq 0) {
            Show-FelixMessage -Message $script:FelixUiState.Text.dialogs.selectRule
            return
        }
        $confirm = [System.Windows.MessageBox]::Show(
            $script:FelixUiState.Window,
            $script:FelixUiState.Text.dialogs.confirmBatch,
            $script:FelixUiState.Text.rules.batchApply,
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) {
            return
        }
        if (@($rows | Where-Object { $_.riskCode -eq 'high' }).Count -gt 0) {
            $riskConfirm = [System.Windows.MessageBox]::Show(
                $script:FelixUiState.Window,
                $script:FelixUiState.Text.dialogs.confirmAdvanced,
                $script:FelixUiState.Text.dialogs.acceptRiskTitle,
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($riskConfirm -ne [System.Windows.MessageBoxResult]::Yes) {
                return
            }
        }
        if (@($rows | Where-Object { $_.applicabilityCode -eq 'Conditional' }).Count -gt 0) {
            $conditionalConfirm = [System.Windows.MessageBox]::Show(
                $script:FelixUiState.Window,
                $script:FelixUiState.Text.dialogs.confirmConditional,
                $script:FelixUiState.Text.rules.applicabilityConditional,
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($conditionalConfirm -ne [System.Windows.MessageBoxResult]::Yes) {
                return
            }
        }
        try {
            $policy = Get-FelixRollbackPolicy
            Set-FelixUiStatus -Message $(if ($policy.requireSystemRestorePoint) {
                $script:FelixUiState.Text.dialogs.dualRollbackChecking
            }
            else {
                $script:FelixUiState.Text.dialogs.snapshotOnlyChecking
            })
            $rollback = Test-FelixDualRollbackCapability -Force
            if (-not $rollback.available) {
                throw $script:FelixUiState.Text.dialogs.rollbackUnavailable
            }
            if (-not (Confirm-FelixSnapshotOnlyExecution -Rollback $rollback)) {
                return
            }
            $result = Invoke-FelixBatchApply -RuleIds @($rows | ForEach-Object { $_.id }) -AcceptRisk
            $message = [string]$result.message
            if (@($result.applied | Where-Object { $_.requiresRestart }).Count -gt 0) {
                $message += [Environment]::NewLine + $script:FelixUiState.Text.dialogs.restartGuard
            }
            Show-FelixMessage -Message $message -Title $script:FelixUiState.Text.dialogs.batchComplete -Icon $(if ($result.success) { [System.Windows.MessageBoxImage]::Information } else { [System.Windows.MessageBoxImage]::Warning })
            Clear-FelixUiPageCache -Page @('overview', 'rules', 'history', 'restore', 'logs')
            Show-FelixPage -Page 'rules' -Force
        }
        catch {
            Show-FelixMessage -Message $_.Exception.Message -Title $script:FelixUiState.Text.dialogs.operationFailed -Icon ([System.Windows.MessageBoxImage]::Error)
            Set-FelixUiStatus -Message $script:FelixUiState.Text.dialogs.operationFailed
        }
    })

    $list.Add_SelectionChanged({
        if ($script:FelixUiState.IsUpdatingRuleList) {
            return
        }
        if ($script:FelixUiState.RuleList.SelectedItem) {
            $script:FelixUiState.SelectedRule = Get-FelixRuleRequired -RuleId $script:FelixUiState.RuleList.SelectedItem.id
            Show-FelixRuleHint
        }
    })

    $dryRunButton.Add_Click({
        if (-not $script:FelixUiState.SelectedRule) {
            Show-FelixMessage -Message $script:FelixUiState.Text.dialogs.selectRule
            return
        }
        try {
            $options = Get-FelixRuleInput -Rule $script:FelixUiState.SelectedRule
            if ($null -eq $options) { return }
            $result = Invoke-FelixDryRun -RuleId $script:FelixUiState.SelectedRule.id -Options $options
            Show-FelixMessage -Message (($result.plannedChanges -join [Environment]::NewLine))
        }
        catch {
            Show-FelixMessage -Message $_.Exception.Message -Title $script:FelixUiState.Text.dialogs.operationFailed -Icon ([System.Windows.MessageBoxImage]::Error)
        }
    })

    $applyButton.Add_Click({
        if (-not $script:FelixUiState.SelectedRule) {
            Show-FelixMessage -Message $script:FelixUiState.Text.dialogs.selectRule
            return
        }
        $rule = $script:FelixUiState.SelectedRule
        $applicability = Get-FelixRuleApplicability -Rule $rule
        if ($applicability.status -eq 'Conditional') {
            $conditionalConfirm = [System.Windows.MessageBox]::Show(
                $script:FelixUiState.Window,
                $script:FelixUiState.Text.dialogs.confirmConditional,
                $script:FelixUiState.Text.rules.applicabilityConditional,
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($conditionalConfirm -ne [System.Windows.MessageBoxResult]::Yes) {
                return
            }
        }
        $acceptRisk = $false
        if ($rule.risk -eq 'advanced') {
            $confirm = [System.Windows.MessageBox]::Show($script:FelixUiState.Window, $script:FelixUiState.Text.dialogs.confirmAdvanced, $script:FelixUiState.Text.dialogs.acceptRiskTitle, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
            if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) {
                return
            }
            $acceptRisk = $true
        }
        try {
            $policy = Get-FelixRollbackPolicy
            Set-FelixUiStatus -Message $(if ($policy.requireSystemRestorePoint) {
                $script:FelixUiState.Text.dialogs.dualRollbackChecking
            }
            else {
                $script:FelixUiState.Text.dialogs.snapshotOnlyChecking
            })
            $rollback = Test-FelixDualRollbackCapability -EnsureRestorePoint
            if (-not $rollback.available) {
                $rollbackDetails = @(
                    $script:FelixUiState.Text.dialogs.rollbackUnavailable
                    "$($script:FelixUiState.Text.overview.snapshot): $($rollback.snapshotMessage)"
                    "$($script:FelixUiState.Text.overview.systemRestorePoint): $($rollback.restorePointMessage)"
                ) -join [Environment]::NewLine
                throw $rollbackDetails
            }
            if (-not (Confirm-FelixSnapshotOnlyExecution -Rollback $rollback)) {
                return
            }
            $options = Get-FelixRuleInput -Rule $rule
            if ($null -eq $options) { return }
            Set-FelixUiStatus -Message $script:FelixUiState.Text.rules.inProgress
            $result = Invoke-FelixApply -RuleId $rule.id -Options $options -AcceptRisk:$acceptRisk
            $message = if ($result.crashGuard -eq 'AwaitingBoot') {
                $script:FelixUiState.Text.dialogs.restartGuard
            }
            else {
                $script:FelixUiState.Text.dialogs.operationComplete
            }
            Show-FelixMessage -Message $message
            Clear-FelixUiPageCache -Page @('overview', 'rules', 'history', 'restore', 'logs')
            Show-FelixPage -Page 'rules' -Force
        }
        catch {
            Show-FelixMessage -Message $_.Exception.Message -Title $script:FelixUiState.Text.dialogs.operationFailed -Icon ([System.Windows.MessageBoxImage]::Error)
            Set-FelixUiStatus -Message $script:FelixUiState.Text.dialogs.operationFailed
        }
    })

    $restoreButton.Add_Click({
        if (-not $script:FelixUiState.SelectedRule) {
            Show-FelixMessage -Message $script:FelixUiState.Text.dialogs.selectRule
            return
        }
        $record = @(Get-FelixHistory -RestorableOnly | Where-Object { $_.ruleId -eq $script:FelixUiState.SelectedRule.id } | Select-Object -First 1)
        if ($record.Count -eq 0) {
            Show-FelixMessage -Message $script:FelixUiState.Text.history.empty
            return
        }
        try {
            Invoke-FelixRestore -HistoryId $record[0].historyId | Out-Null
            Show-FelixMessage -Message $script:FelixUiState.Text.dialogs.restoreComplete
            Clear-FelixUiPageCache -Page @('overview', 'rules', 'history', 'restore', 'logs')
            Show-FelixPage -Page 'rules' -Force
        }
        catch {
            Show-FelixMessage -Message $_.Exception.Message -Title $script:FelixUiState.Text.dialogs.operationFailed -Icon ([System.Windows.MessageBoxImage]::Error)
        }
    })

    Set-FelixUiContent -Element $pageRoot
}

function Show-FelixHistoryPage {
    $text = $script:FelixUiState.Text
    Set-FelixUiPageTitle -Title $text.nav.history
    $history = @(Get-FelixHistory)
    if ($history.Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = $text.history.empty
        Set-FelixUiContent -Element $empty
        return
    }

    $rows = foreach ($record in $history) {
        [pscustomobject]@{
            operation = $record.historyId
            rule = $record.ruleName
            time = ([datetime]$record.updatedAt).ToString('yyyy-MM-dd HH:mm:ss')
            status = Get-FelixUiStatusText -Status $record.status
            restart = if ($record.requiresRestart) { $text.rules.yes } else { $text.rules.no }
            restorePoint = $record.restorePointId
            message = $record.message
        }
    }

    $list = New-FelixUiListView -Columns @(
        @{ Header = $text.history.operation; Property = 'operation'; Width = 230 },
        @{ Header = $text.history.rule; Property = 'rule'; Width = 230 },
        @{ Header = $text.history.time; Property = 'time'; Width = 150 },
        @{ Header = $text.history.status; Property = 'status'; Width = 90 },
        @{ Header = $text.history.restart; Property = 'restart'; Width = 70 },
        @{ Header = $text.history.restorePoint; Property = 'restorePoint'; Width = 110 },
        @{ Header = $text.history.message; Property = 'message'; Width = 360 }
    )
    foreach ($row in $rows) {
        $list.Items.Add($row) | Out-Null
    }
    Set-FelixUiContent -Element $list
}

function Show-FelixLogsPage {
    $text = $script:FelixUiState.Text
    Set-FelixUiPageTitle -Title $text.logs.title -Subtitle $text.logs.description

    $root = New-Object System.Windows.Controls.StackPanel
    $toolbar = New-Object System.Windows.Controls.WrapPanel
    $refreshButton = New-FelixUiButton -Text $text.logs.refresh -Width 90 -Variant Selection
    $openButton = New-FelixUiButton -Text $text.logs.openDirectory -Width 130
    $toolbar.Children.Add($refreshButton) | Out-Null
    $toolbar.Children.Add($openButton) | Out-Null
    $root.Children.Add($toolbar) | Out-Null

    $records = @(Get-FelixLog -Last 1000)
    if ($records.Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TextBlock
        $empty.Text = $text.logs.empty
        $empty.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)
        $root.Children.Add($empty) | Out-Null
    }
    else {
        $list = New-FelixUiListView -Columns @(
            @{ Header = $text.logs.time; Property = 'time'; Width = 160 },
            @{ Header = $text.logs.level; Property = 'level'; Width = 80 },
            @{ Header = $text.logs.event; Property = 'event'; Width = 190 },
            @{ Header = $text.logs.rule; Property = 'rule'; Width = 180 },
            @{ Header = $text.logs.history; Property = 'history'; Width = 220 },
            @{ Header = $text.logs.message; Property = 'message'; Width = 460 }
        )
        $list.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)
        foreach ($record in $records) {
            $list.Items.Add([pscustomobject]@{
                time = if ($record.timestamp) { ([datetime]$record.timestamp).ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
                level = $record.level
                event = $record.event
                rule = $record.ruleId
                history = $record.historyId
                message = $record.message
            }) | Out-Null
        }
        $root.Children.Add($list) | Out-Null
    }

    $refreshButton.Add_Click({
        Show-FelixPage -Page 'logs' -Force
    })
    $openButton.Add_Click({
        $logPath = Get-FelixStatePath 'logs'
        if (-not (Test-Path -LiteralPath $logPath)) {
            New-Item -ItemType Directory -Path $logPath -Force | Out-Null
        }
        Start-Process explorer.exe -ArgumentList $logPath
    })

    Set-FelixUiContent -Element $root
}

function Show-FelixRestorePage {
    $text = $script:FelixUiState.Text
    Set-FelixUiPageTitle -Title $text.restore.title -Subtitle $text.restore.description

    $root = New-Object System.Windows.Controls.StackPanel
    $toolbar = New-Object System.Windows.Controls.WrapPanel
    $restoreSelected = New-FelixUiButton -Text $text.restore.restoreSelected -Width 120 -Variant Primary
    $restoreAll = New-FelixUiButton -Text $text.restore.restoreAll -Width 110
    $testRollback = New-FelixUiButton -Text $text.restore.testRollback -Width 150 -Variant Selection
    $openSystemRestore = New-FelixUiButton -Text $text.restore.openSystemRestore -Width 140 -Variant Selection
    $toolbar.Children.Add($restoreSelected) | Out-Null
    $toolbar.Children.Add($restoreAll) | Out-Null
    $toolbar.Children.Add($testRollback) | Out-Null
    $toolbar.Children.Add($openSystemRestore) | Out-Null
    $root.Children.Add($toolbar) | Out-Null

    $rollbackStatus = Test-FelixDualRollbackCapability
    $rollbackText = New-Object System.Windows.Controls.TextBlock
    $rollbackLines = @(
        if ($rollbackStatus.mode -eq 'IndependentSnapshot') {
            if ($rollbackStatus.available) { $text.dialogs.snapshotOnlyReady } else { $text.dialogs.rollbackUnavailable }
        }
        elseif ($rollbackStatus.available) {
            $text.dialogs.rollbackReady
        }
        else {
            $text.dialogs.rollbackUnavailable
        }
        "$($text.restore.snapshotMode): $(if ($rollbackStatus.snapshotAvailable) { $text.restore.snapshotReady } else { $text.restore.snapshotUnavailable })"
        if ($rollbackStatus.mode -eq 'IndependentSnapshot') {
            "$($text.restore.systemPoint): $($text.restore.pointNotRequired)"
        }
        else {
            "$($text.restore.systemPoint): $(if ($rollbackStatus.restorePointAvailable) { $text.restore.pointAvailable } else { $text.restore.pointUnavailable })"
        }
        [string]$rollbackStatus.message
    )
    if ($rollbackStatus.mode -eq 'IndependentSnapshot') {
        $rollbackLines += $text.restore.snapshotOnlyDescription
    }
    $rollbackText.Text = $rollbackLines -join [Environment]::NewLine
    $rollbackText.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $rollbackText.Foreground = if ($rollbackStatus.available) { [System.Windows.Media.Brushes]::DarkGreen } else { [System.Windows.Media.Brushes]::DarkRed }
    $rollbackText.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
    $root.Children.Add($rollbackText) | Out-Null

    $records = @(Get-FelixHistory -RestorableOnly)
    $list = New-FelixUiListView -Columns @(
        @{ Header = $text.history.rule; Property = 'rule'; Width = 260 },
        @{ Header = $text.history.time; Property = 'time'; Width = 160 },
        @{ Header = $text.history.status; Property = 'status'; Width = 100 },
        @{ Header = $text.history.restorePoint; Property = 'restorePoint'; Width = 110 },
        @{ Header = $text.history.message; Property = 'message'; Width = 420 }
    )
    $list.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)
    foreach ($record in $records) {
        $list.Items.Add([pscustomobject]@{
            historyId = $record.historyId
            rule = $record.ruleName
            time = ([datetime]$record.updatedAt).ToString('yyyy-MM-dd HH:mm:ss')
            status = Get-FelixUiStatusText -Status $record.status
            restorePoint = $record.restorePointId
            message = $record.message
        }) | Out-Null
    }
    $root.Children.Add($list) | Out-Null

    $script:FelixUiState.RestoreList = $list

    $restoreSelected.Add_Click({
        if (-not $script:FelixUiState.RestoreList.SelectedItem) {
            Show-FelixMessage -Message $script:FelixUiState.Text.dialogs.selectHistory
            return
        }
        try {
            Invoke-FelixRestore -HistoryId $script:FelixUiState.RestoreList.SelectedItem.historyId | Out-Null
            Show-FelixMessage -Message $script:FelixUiState.Text.dialogs.restoreComplete
            Clear-FelixUiPageCache -Page @('overview', 'rules', 'history', 'restore', 'logs')
            Show-FelixPage -Page 'restore' -Force
        }
        catch {
            Show-FelixMessage -Message $_.Exception.Message -Title $script:FelixUiState.Text.dialogs.operationFailed -Icon ([System.Windows.MessageBoxImage]::Error)
        }
    })

    $restoreAll.Add_Click({
        $confirm = [System.Windows.MessageBox]::Show($script:FelixUiState.Window, $script:FelixUiState.Text.dialogs.confirmRestoreAll, $script:FelixUiState.Text.restore.title, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) {
            return
        }
        try {
            $results = @(Invoke-FelixRestoreAll)
            $failed = @($results | Where-Object { -not $_.success }).Count
            Show-FelixMessage -Message "$($script:FelixUiState.Text.dialogs.restoreComplete) $failed failed."
            Clear-FelixUiPageCache -Page @('overview', 'rules', 'history', 'restore', 'logs')
            Show-FelixPage -Page 'restore' -Force
        }
        catch {
            Show-FelixMessage -Message $_.Exception.Message -Title $script:FelixUiState.Text.dialogs.operationFailed -Icon ([System.Windows.MessageBoxImage]::Error)
        }
    })

    $testRollback.Add_Click({
        try {
            $result = Test-FelixDualRollbackCapability -EnsureRestorePoint
            $message = @(
                if ($result.mode -eq 'IndependentSnapshot') {
                    if ($result.available) { $script:FelixUiState.Text.dialogs.snapshotOnlyReady } else { $script:FelixUiState.Text.dialogs.rollbackUnavailable }
                }
                elseif ($result.available) {
                    $script:FelixUiState.Text.dialogs.rollbackReady
                }
                else {
                    $script:FelixUiState.Text.dialogs.rollbackUnavailable
                }
                "$($script:FelixUiState.Text.overview.snapshot): $(if ($result.snapshotAvailable) { $script:FelixUiState.Text.restore.snapshotReady } else { $script:FelixUiState.Text.restore.snapshotUnavailable })"
                if ($result.mode -eq 'IndependentSnapshot') {
                    "$($script:FelixUiState.Text.overview.systemRestorePoint): $($script:FelixUiState.Text.restore.pointNotRequired)"
                }
                else {
                    "$($script:FelixUiState.Text.overview.systemRestorePoint): $(if ($result.restorePointAvailable) { $script:FelixUiState.Text.restore.pointAvailable } else { $script:FelixUiState.Text.restore.pointUnavailable })"
                }
                [string]$result.snapshotMessage
                [string]$result.restorePointMessage
            ) -join [Environment]::NewLine
            Show-FelixMessage -Message $message -Title $script:FelixUiState.Text.nav.restore -Icon $(if ($result.available) { [System.Windows.MessageBoxImage]::Information } else { [System.Windows.MessageBoxImage]::Error })
        }
        catch {
            Show-FelixMessage -Message $_.Exception.Message -Title $script:FelixUiState.Text.nav.restore -Icon ([System.Windows.MessageBoxImage]::Error)
        }
    })

    $openSystemRestore.Add_Click({
        try {
            Start-Process -FilePath 'rstrui.exe'
        }
        catch {
            Show-FelixMessage -Message $_.Exception.Message -Title $script:FelixUiState.Text.nav.restore -Icon ([System.Windows.MessageBoxImage]::Error)
        }
    })

    Set-FelixUiContent -Element $root
}

function Show-FelixSettingsPage {
    $text = $script:FelixUiState.Text
    Set-FelixUiPageTitle -Title $text.nav.settings
    $root = New-Object System.Windows.Controls.StackPanel

    $pathText = New-Object System.Windows.Controls.TextBlock
    $pathText.Text = "$($text.settings.statePath): $(Get-FelixStatePath)"
    $pathText.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $root.Children.Add($pathText) | Out-Null

    $policy = Get-FelixRollbackPolicy
    $policyCard = New-Object System.Windows.Controls.Border
    $policyCard.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F8FAFC')
    $policyCard.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#E2E8F0')
    $policyCard.BorderThickness = [System.Windows.Thickness]::new(1)
    $policyCard.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $policyCard.Padding = [System.Windows.Thickness]::new(14, 12, 14, 12)
    $policyCard.Margin = [System.Windows.Thickness]::new(0, 16, 0, 0)
    $policyStack = New-Object System.Windows.Controls.StackPanel
    $policyTitle = New-Object System.Windows.Controls.TextBlock
    $policyTitle.Text = $text.settings.rollbackPolicy
    $policyTitle.FontSize = 16
    $policyTitle.FontWeight = [System.Windows.FontWeights]::SemiBold
    $policyStack.Children.Add($policyTitle) | Out-Null
    $policyCheck = New-Object System.Windows.Controls.CheckBox
    $policyCheckText = New-Object System.Windows.Controls.TextBlock
    $policyCheckText.Text = $text.settings.dualRollback
    $policyCheckText.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $policyCheck.Content = $policyCheckText
    $policyCheck.IsChecked = [bool]$policy.requireSystemRestorePoint
    $policyCheck.FontWeight = [System.Windows.FontWeights]::SemiBold
    $policyCheck.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
    $policyStack.Children.Add($policyCheck) | Out-Null
    $policyDescription = New-Object System.Windows.Controls.TextBlock
    $policyDescription.Text = $text.settings.dualRollbackDescription
    $policyDescription.Foreground = [System.Windows.Media.Brushes]::DimGray
    $policyDescription.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $policyDescription.Margin = [System.Windows.Thickness]::new(0, 6, 0, 0)
    $policyStack.Children.Add($policyDescription) | Out-Null
    $policyStatus = New-Object System.Windows.Controls.TextBlock
    $policyStatus.Text = if ($policy.requireSystemRestorePoint) { $text.settings.dualRollbackEnabled } else { $text.settings.snapshotOnlyEnabled }
    $policyStatus.Foreground = if ($policy.requireSystemRestorePoint) { [System.Windows.Media.Brushes]::DarkGreen } else { [System.Windows.Media.Brushes]::DarkOrange }
    $policyStatus.FontWeight = [System.Windows.FontWeights]::SemiBold
    $policyStatus.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    $policyStack.Children.Add($policyStatus) | Out-Null
    $policyCard.Child = $policyStack
    $root.Children.Add($policyCard) | Out-Null
    $script:FelixUiState.RollbackPolicyCheckBox = $policyCheck
    $script:FelixUiState.RollbackPolicyStatus = $policyStatus

    $buttons = New-Object System.Windows.Controls.WrapPanel
    $buttons.Margin = [System.Windows.Thickness]::new(0, 16, 0, 0)
    $openButton = New-FelixUiButton -Text $text.settings.openState -Width 130
    $clearHistoryButton = New-FelixUiButton -Text $text.settings.clearHistory -Width 130 -Variant Selection
    $purgeButton = New-FelixUiButton -Text $text.settings.purgeQuarantine -Width 130 -Variant Danger
    $buttons.Children.Add($openButton) | Out-Null
    $buttons.Children.Add($clearHistoryButton) | Out-Null
    $buttons.Children.Add($purgeButton) | Out-Null
    $root.Children.Add($buttons) | Out-Null

    $danger = New-Object System.Windows.Controls.TextBlock
    $danger.Text = $text.settings.dangerous
    $danger.Foreground = [System.Windows.Media.Brushes]::DarkRed
    $danger.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)
    $root.Children.Add($danger) | Out-Null

    $openButton.Add_Click({
        Start-Process explorer.exe -ArgumentList (Get-FelixStatePath)
    })
    $policyCheck.Add_Click({
        param($sender, $eventArgs)

        $requireSystemRestorePoint = [bool]$sender.IsChecked
        if (-not $requireSystemRestorePoint) {
            $confirm = [System.Windows.MessageBox]::Show(
                $script:FelixUiState.Window,
                $script:FelixUiState.Text.settings.snapshotOnlyConfirm,
                $script:FelixUiState.Text.settings.rollbackPolicy,
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) {
                $sender.IsChecked = $true
                return
            }
        }

        try {
            $updatedPolicy = Set-FelixRollbackPolicy -RequireSystemRestorePoint $requireSystemRestorePoint
            $script:FelixUiState.RollbackPolicyStatus.Text = if ($updatedPolicy.requireSystemRestorePoint) {
                $script:FelixUiState.Text.settings.dualRollbackEnabled
            }
            else {
                $script:FelixUiState.Text.settings.snapshotOnlyEnabled
            }
            $script:FelixUiState.RollbackPolicyStatus.Foreground = if ($updatedPolicy.requireSystemRestorePoint) {
                [System.Windows.Media.Brushes]::DarkGreen
            }
            else {
                [System.Windows.Media.Brushes]::DarkOrange
            }
            Clear-FelixUiPageCache -Page @('overview', 'rules', 'restore')
            Show-FelixMessage -Message $script:FelixUiState.Text.settings.rollbackPolicySaved
        }
        catch {
            $sender.IsChecked = -not $requireSystemRestorePoint
            Show-FelixMessage -Message $_.Exception.Message -Title $script:FelixUiState.Text.dialogs.operationFailed -Icon ([System.Windows.MessageBoxImage]::Error)
        }
    })
    $clearHistoryButton.Add_Click({
        $confirm = [System.Windows.MessageBox]::Show($script:FelixUiState.Window, $script:FelixUiState.Text.settings.clearHistory, $script:FelixUiState.Text.nav.settings, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
            Clear-FelixHistoryIndex
            Clear-FelixUiPageCache -Page @('overview', 'rules', 'history', 'restore', 'logs')
            Show-FelixMessage -Message $script:FelixUiState.Text.dialogs.historyCleared
        }
    })
    $purgeButton.Add_Click({
        $confirm = [System.Windows.MessageBox]::Show($script:FelixUiState.Window, $script:FelixUiState.Text.dialogs.confirmPurge, $script:FelixUiState.Text.nav.settings, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        if ($confirm -eq [System.Windows.MessageBoxResult]::Yes) {
            Clear-FelixQuarantine
            Show-FelixMessage -Message $script:FelixUiState.Text.dialogs.quarantineCleared
        }
    })

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $scroll.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Disabled
    $scroll.Content = $root
    Set-FelixUiContent -Element $scroll
}

function New-FelixAboutSection {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Body
    )

    $section = New-Object System.Windows.Controls.StackPanel
    $section.Margin = [System.Windows.Thickness]::new(0, 0, 0, 18)
    $heading = New-Object System.Windows.Controls.TextBlock
    $heading.Text = $Title
    $heading.FontSize = 17
    $heading.FontWeight = [System.Windows.FontWeights]::SemiBold
    $heading.Margin = [System.Windows.Thickness]::new(0, 0, 0, 5)
    $bodyBlock = New-Object System.Windows.Controls.TextBlock
    $bodyBlock.Text = $Body
    $bodyBlock.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $bodyBlock.LineHeight = 21
    $section.Children.Add($heading) | Out-Null
    $section.Children.Add($bodyBlock) | Out-Null
    return $section
}

function Show-FelixAboutPage {
    $text = $script:FelixUiState.Text
    Set-FelixUiPageTitle -Title $text.about.title -Subtitle $text.about.description
    $catalog = Get-FelixApplicabilityCatalog

    $root = New-Object System.Windows.Controls.StackPanel
    $projectBody = @(
        "$($text.about.version): $($script:ModuleVersion)"
        "$($text.about.repository): https://github.com/HeFanweiming"
    ) -join [Environment]::NewLine
    $root.Children.Add((New-FelixAboutSection -Title $text.about.project -Body $projectBody)) | Out-Null

    $linkButtons = New-Object System.Windows.Controls.WrapPanel
    $repositoryButton = New-FelixUiButton -Text $text.about.openRepository -Width 138 -Variant Primary
    $stateButton = New-FelixUiButton -Text $text.about.stateDirectory -Width 126 -Variant Selection
    $linkButtons.Children.Add($repositoryButton) | Out-Null
    $linkButtons.Children.Add($stateButton) | Out-Null
    $linkButtons.Margin = [System.Windows.Thickness]::new(0, 0, 0, 18)
    $root.Children.Add($linkButtons) | Out-Null

    $researchBody = @(
        $text.about.researchDescription
        "$($text.about.reviewedAt): $($catalog.reviewedAt)"
    ) -join [Environment]::NewLine
    $root.Children.Add((New-FelixAboutSection -Title $text.about.research -Body $researchBody)) | Out-Null
    $root.Children.Add((New-FelixAboutSection -Title $text.about.safety -Body $text.about.safetyDescription)) | Out-Null
    $hardware = $script:FelixUiState.OverviewHardware
    if ($null -eq $hardware) {
        $securityBody = $text.about.securityStatusPending
    }
    else {
        $deviceSecurityText = if ($null -ne $hardware.deviceSecurity) {
            [string]$hardware.deviceSecurity.message
        }
        else {
            $text.overview.deviceSecurityUnavailable
        }
        $aceText = if ([bool]$hardware.antiCheatExpertInstalled) {
            $text.overview.aceDetected
        }
        else {
            $text.overview.aceNotDetected
        }
        $securityBody = @(
            "$($text.overview.deviceSecurity): $deviceSecurityText"
            "$($text.overview.acePresence): $aceText"
        ) -join [Environment]::NewLine
    }
    $root.Children.Add((New-FelixAboutSection -Title $text.about.securityStatus -Body $securityBody)) | Out-Null
    $root.Children.Add((New-FelixAboutSection -Title $text.about.crashGuard -Body $text.about.crashGuardDescription)) | Out-Null

    $repositoryButton.Add_Click({
        try {
            Start-Process 'https://github.com/HeFanweiming'
        }
        catch {
            Show-FelixMessage -Message $_.Exception.Message -Title $script:FelixUiState.Text.about.repository -Icon ([System.Windows.MessageBoxImage]::Error)
        }
    })
    $stateButton.Add_Click({
        try {
            $statePath = Get-FelixStatePath
            if (-not (Test-Path -LiteralPath $statePath)) {
                New-Item -ItemType Directory -Path $statePath -Force | Out-Null
            }
            Start-Process explorer.exe -ArgumentList $statePath
        }
        catch {
            Show-FelixMessage -Message $_.Exception.Message -Title $script:FelixUiState.Text.about.stateDirectory -Icon ([System.Windows.MessageBoxImage]::Error)
        }
    })

    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $scroll.HorizontalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Disabled
    $scroll.Content = $root
    Set-FelixUiContent -Element $scroll
}

function New-FelixInputCombo {
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [array]$Items,
        [string]$DisplayProperty
    )

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $labelBlock = New-Object System.Windows.Controls.TextBlock
    $labelBlock.Text = $Label
    $labelBlock.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    $combo = New-Object System.Windows.Controls.ComboBox
    $combo.MinWidth = 420
    if ($DisplayProperty) {
        $combo.DisplayMemberPath = $DisplayProperty
    }
    foreach ($item in $Items) {
        $combo.Items.Add($item) | Out-Null
    }
    if ($combo.Items.Count -gt 0) {
        $combo.SelectedIndex = 0
    }
    $panel.Children.Add($labelBlock) | Out-Null
    $panel.Children.Add($combo) | Out-Null
    return [pscustomobject]@{ Panel = $panel; Combo = $combo }
}

function Get-FelixRuleInput {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Rule
    )

    if (-not $Rule.requiresInput) {
        return @{}
    }

    $window = New-Object System.Windows.Window
    $window.Owner = $script:FelixUiState.Window
    $window.Title = $Rule.name
    $window.Width = 520
    $window.SizeToContent = [System.Windows.SizeToContent]::Height
    $window.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner

    $root = New-Object System.Windows.Controls.StackPanel
    $root.Margin = [System.Windows.Thickness]::new(18)
    $result = @{}
    $inputMode = if ($Rule.Contains('inputKind')) { [string]$Rule.inputKind } else { [string]$Rule.handler }

    switch ($inputMode) {
        'NetworkAdapter' {
            $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
            $input = New-FelixInputCombo -Label 'Adapter' -Items $adapters -DisplayProperty 'Name'
            $root.Children.Add($input.Panel) | Out-Null
            $window.Tag = $input.Combo
        }
        'ExecutablePath' {
            $label = New-Object System.Windows.Controls.TextBlock
            $label.Text = 'Application EXE'
            $label.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
            $pathBox = New-Object System.Windows.Controls.TextBox
            $pathBox.MinWidth = 420
            $pathBox.Text = 'C:\Games\game.exe'
            $pickerRow = New-Object System.Windows.Controls.StackPanel
            $pickerRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
            $browse = New-FelixUiButton -Text 'Browse...' -Width 90
            $browse.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
            $pickerRow.Children.Add($pathBox) | Out-Null
            $pickerRow.Children.Add($browse) | Out-Null
            $root.Children.Add($label) | Out-Null
            $root.Children.Add($pickerRow) | Out-Null
            $window.Tag = $pathBox
            $browse.Add_Click({
                $dialog = New-Object Microsoft.Win32.OpenFileDialog
                $dialog.Filter = 'Applications (*.exe)|*.exe'
                $dialog.CheckFileExists = $true
                if ($dialog.ShowDialog() -eq $true) {
                    $pathBox.Text = $dialog.FileName
                }
            })
        }
        'ExecutablePriority' {
            $label = New-Object System.Windows.Controls.TextBlock
            $label.Text = 'Application EXE'
            $label.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
            $pathBox = New-Object System.Windows.Controls.TextBox
            $pathBox.MinWidth = 420
            $pathBox.Text = 'C:\Games\game.exe'
            $pickerRow = New-Object System.Windows.Controls.StackPanel
            $pickerRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
            $browse = New-FelixUiButton -Text 'Browse...' -Width 90
            $browse.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
            $pickerRow.Children.Add($pathBox) | Out-Null
            $pickerRow.Children.Add($browse) | Out-Null
            $root.Children.Add($label) | Out-Null
            $root.Children.Add($pickerRow) | Out-Null

            $priorityItems = @(
                [pscustomobject]@{ label = 'Above normal (recommended)'; value = 6 },
                [pscustomobject]@{ label = 'Normal'; value = 2 }
            )
            $priority = New-FelixInputCombo -Label 'CPU priority' -Items $priorityItems -DisplayProperty 'label'
            $root.Children.Add($priority.Panel) | Out-Null
            $window.Tag = @{
                path = $pathBox
                priority = $priority.Combo
            }
            $browse.Add_Click({
                $dialog = New-Object Microsoft.Win32.OpenFileDialog
                $dialog.Filter = 'Applications (*.exe)|*.exe'
                $dialog.CheckFileExists = $true
                if ($dialog.ShowDialog() -eq $true) {
                    $pathBox.Text = $dialog.FileName
                }
            })
        }
        'NicPower' {
            $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
            $input = New-FelixInputCombo -Label 'Adapter' -Items $adapters -DisplayProperty 'Name'
            $root.Children.Add($input.Panel) | Out-Null
            $window.Tag = $input.Combo
        }
        'DnsProfile' {
            $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
            $input = New-FelixInputCombo -Label 'Interface' -Items $adapters -DisplayProperty 'Name'
            $root.Children.Add($input.Panel) | Out-Null

            $dhcpPanel = New-Object System.Windows.Controls.StackPanel
            $dhcpPanel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
            $dhcpCheck = New-Object System.Windows.Controls.CheckBox
            $dhcpCheck.Content = 'Use DHCP DNS'
            $dhcpCheck.IsChecked = $false
            $dhcpPanel.Children.Add($dhcpCheck) | Out-Null
            $root.Children.Add($dhcpPanel) | Out-Null

            $serverLabel = New-Object System.Windows.Controls.TextBlock
            $serverLabel.Text = 'DNS servers'
            $serverLabel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
            $serverBox = New-Object System.Windows.Controls.TextBox
            $serverBox.Text = '223.5.5.5,119.29.29.29'
            $serverBox.MinWidth = 420
            $root.Children.Add($serverLabel) | Out-Null
            $root.Children.Add($serverBox) | Out-Null
            $window.Tag = @{
                adapter = $input.Combo
                dhcp = $dhcpCheck
                servers = $serverBox
            }
        }
        'StartupItem' {
            $items = @(Get-FelixStartupCandidates)
            $input = New-FelixInputCombo -Label 'Startup item' -Items $items -DisplayProperty 'name'
            $root.Children.Add($input.Panel) | Out-Null
            $window.Tag = $input.Combo
        }
        'ServiceState' {
            $services = @(Get-Service -Name $script:AllowedServices -ErrorAction SilentlyContinue | Sort-Object Name)
            $input = New-FelixInputCombo -Label 'Service' -Items $services -DisplayProperty 'DisplayName'
            $root.Children.Add($input.Panel) | Out-Null
            $startTypes = @('Manual', 'Disabled', 'Automatic')
            $typeInput = New-FelixInputCombo -Label 'Startup type' -Items $startTypes
            $root.Children.Add($typeInput.Panel) | Out-Null
            $stopCheck = New-Object System.Windows.Controls.CheckBox
            $stopCheck.Content = 'Stop the service now'
            $stopCheck.IsChecked = $true
            $root.Children.Add($stopCheck) | Out-Null
            $window.Tag = @{
                service = $input.Combo
                startupType = $typeInput.Combo
                stop = $stopCheck
            }
        }
        'DeviceAffinity' {
            $devices = @(Get-FelixInterruptCandidate)
            $input = New-FelixInputCombo -Label 'Device' -Items $devices -DisplayProperty 'name'
            $root.Children.Add($input.Panel) | Out-Null
            $maskLabel = New-Object System.Windows.Controls.TextBlock
            $maskLabel.Text = 'CPU mask (hex, 0 resets)'
            $maskLabel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
            $maskBox = New-Object System.Windows.Controls.TextBox
            $maskBox.Text = '0x1'
            $maskBox.MinWidth = 420
            $root.Children.Add($maskLabel) | Out-Null
            $root.Children.Add($maskBox) | Out-Null
            $window.Tag = @{
                device = $input.Combo
                mask = $maskBox
            }
        }
        default {
            throw $script:FelixUiState.Text.dialogs.inputRequired
        }
    }

    $buttons = New-Object System.Windows.Controls.StackPanel
    $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $buttons.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $buttons.Margin = [System.Windows.Thickness]::new(0, 18, 0, 0)
    $ok = New-FelixUiButton -Text 'OK' -Width 80
    $cancel = New-FelixUiButton -Text 'Cancel' -Width 80
    $ok.IsDefault = $true
    $cancel.IsCancel = $true
    $buttons.Children.Add($ok) | Out-Null
    $buttons.Children.Add($cancel) | Out-Null
    $root.Children.Add($buttons) | Out-Null
    $window.Content = $root

    $ok.Add_Click({
        $window.DialogResult = $true
    })
    $cancel.Add_Click({
        $window.DialogResult = $false
    })

    if ($window.ShowDialog() -ne $true) {
        return $null
    }

    switch ($inputMode) {
        'NetworkAdapter' {
            if (-not $window.Tag.SelectedItem) { return $null }
            $adapter = $window.Tag.SelectedItem
            return @{
                AdapterName = [string]$adapter.Name
                InterfaceAlias = [string]$adapter.Name
                InterfaceGuid = ConvertTo-FelixGuidText -Value $adapter.InterfaceGuid -Format D
            }
        }
        'ExecutablePath' {
            if ([string]::IsNullOrWhiteSpace($window.Tag.Text)) { return $null }
            return @{ ExecutablePath = [string]$window.Tag.Text }
        }
        'ExecutablePriority' {
            $tag = $window.Tag
            if ([string]::IsNullOrWhiteSpace($tag.path.Text) -or -not $tag.priority.SelectedItem) { return $null }
            return @{
                ExecutablePath = [string]$tag.path.Text
                CpuPriorityClass = [int]$tag.priority.SelectedItem.value
            }
        }
        'NicPower' {
            if (-not $window.Tag.SelectedItem) { return $null }
            return @{ AdapterName = $window.Tag.SelectedItem.Name }
        }
        'DnsProfile' {
            $tag = $window.Tag
            if (-not $tag.adapter.SelectedItem) { return $null }
            $servers = @($tag.servers.Text -split '[,\s]+' | Where-Object { $_ })
            return @{
                InterfaceAlias = $tag.adapter.SelectedItem.Name
                Dhcp = [bool]$tag.dhcp.IsChecked
                DnsServers = $servers
            }
        }
        'StartupItem' {
            if (-not $window.Tag.SelectedItem) { return $null }
            $item = $window.Tag.SelectedItem
            if ($item.enabled) {
                return @{
                    RegistryPath = $item.registryPath
                    ValueName = $item.valueName
                    Enable = $false
                }
            }
            return @{
                BackupPath = $item.backupPath
                Enable = $true
            }
        }
        'ServiceState' {
            $tag = $window.Tag
            if (-not $tag.service.SelectedItem) { return $null }
            return @{
                ServiceName = $tag.service.SelectedItem.Name
                StartupType = [string]$tag.startupType.SelectedItem
                StopNow = [bool]$tag.stop.IsChecked
            }
        }
        'DeviceAffinity' {
            $tag = $window.Tag
            if (-not $tag.device.SelectedItem) { return $null }
            return @{
                RegistryPath = $tag.device.SelectedItem.registryPath
                InstanceId = $tag.device.SelectedItem.instanceId
                CpuMask = $tag.mask.Text
            }
        }
    }

    return @{}
}

function Start-StableTuneUi {
    [CmdletBinding()]
    param(
        [switch]$SmokeTest,
        [string]$EntryScriptPath
    )

    Add-Type -AssemblyName PresentationFramework

    $createdNew = $false
    $mutexName = if ($SmokeTest) {
        "Local\FelixOptimizerPrototypeUiSmoke-$PID"
    }
    else {
        'Local\FelixOptimizerPrototypeUi'
    }
    $uiMutex = [Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)
    if (-not $createdNew) {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show('稳优 StableTune is already running.', '稳优 StableTune', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
        return
    }

    try {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Initialize-FelixState
    Add-FelixLog -Event 'ui.started' -Message "Optimizer UI started with version $($script:ModuleVersion)."

    $text = Get-FelixUiText
    $window = New-Object System.Windows.Window
    $window.Title = $text.app.title
    $window.Width = 1280
    $window.Height = 780
    $window.MinWidth = 980
    $window.MinHeight = 640
    $window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen

    $root = New-Object System.Windows.Controls.Grid
    $root.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(210) }))
    $root.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }))

    $sidebar = New-Object System.Windows.Controls.StackPanel
    $sidebar.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F3F4F6')
    $sidebar.Margin = [System.Windows.Thickness]::new(0)

    $brand = New-Object System.Windows.Controls.TextBlock
    $brand.Text = $text.app.title
    $brand.FontSize = 22
    $brand.FontWeight = [System.Windows.FontWeights]::SemiBold
    $brand.Margin = [System.Windows.Thickness]::new(14, 18, 14, 2)
    $sidebar.Children.Add($brand) | Out-Null
    $subtitle = New-Object System.Windows.Controls.TextBlock
    $subtitle.Text = $text.app.subtitle
    $subtitle.Foreground = [System.Windows.Media.Brushes]::DimGray
    $subtitle.Margin = [System.Windows.Thickness]::new(14, 0, 14, 22)
    $sidebar.Children.Add($subtitle) | Out-Null

    foreach ($entry in @(
        @{ Page = 'overview'; Label = $text.nav.overview },
        @{ Page = 'rules'; Label = $text.nav.rules },
        @{ Page = 'history'; Label = $text.nav.history },
        @{ Page = 'restore'; Label = $text.nav.restore },
        @{ Page = 'logs'; Label = $text.nav.logs },
        @{ Page = 'settings'; Label = $text.nav.settings },
        @{ Page = 'about'; Label = $text.nav.about }
    )) {
        $button = New-Object System.Windows.Controls.Button
        $button.Content = $entry.Label
        $button.Height = 38
        $button.HorizontalContentAlignment = [System.Windows.HorizontalAlignment]::Left
        $button.Margin = [System.Windows.Thickness]::new(14, 0, 14, 6)
        $button.Tag = $entry.Page
        $button.Add_Click({
            Show-FelixPage -Page $this.Tag
        })
        $sidebar.Children.Add($button) | Out-Null
    }

    [System.Windows.Controls.Grid]::SetColumn($sidebar, 0)
    $root.Children.Add($sidebar) | Out-Null

    $main = New-Object System.Windows.Controls.DockPanel
    $main.Margin = [System.Windows.Thickness]::new(24)
    [System.Windows.Controls.Grid]::SetColumn($main, 1)

    $header = New-Object System.Windows.Controls.StackPanel
    $pageTitle = New-Object System.Windows.Controls.TextBlock
    $pageTitle.FontSize = 26
    $pageTitle.FontWeight = [System.Windows.FontWeights]::SemiBold
    $pageSubtitle = New-Object System.Windows.Controls.TextBlock
    $pageSubtitle.Foreground = [System.Windows.Media.Brushes]::DimGray
    $pageSubtitle.Margin = [System.Windows.Thickness]::new(0, 3, 0, 18)
    $header.Children.Add($pageTitle) | Out-Null
    $header.Children.Add($pageSubtitle) | Out-Null
    [System.Windows.Controls.DockPanel]::SetDock($header, [System.Windows.Controls.Dock]::Top)
    $main.Children.Add($header) | Out-Null

    $footer = New-Object System.Windows.Controls.Border
    $footer.BorderBrush = [System.Windows.Media.Brushes]::LightGray
    $footer.BorderThickness = [System.Windows.Thickness]::new(0, 1, 0, 0)
    $footer.Padding = [System.Windows.Thickness]::new(0, 8, 0, 0)
    $statusText = New-Object System.Windows.Controls.TextBlock
    $statusText.Text = $text.app.statusReady
    $statusText.Foreground = [System.Windows.Media.Brushes]::DimGray
    $footer.Child = $statusText
    [System.Windows.Controls.DockPanel]::SetDock($footer, [System.Windows.Controls.Dock]::Bottom)
    $main.Children.Add($footer) | Out-Null

    $contentHost = New-Object System.Windows.Controls.ContentControl
    $main.Children.Add($contentHost) | Out-Null
    $root.Children.Add($main) | Out-Null
    $window.Content = $root

    $script:FelixUiState = @{
        Text = $text
        Window = $window
        ContentHost = $contentHost
        PageTitle = $pageTitle
        PageSubtitle = $pageSubtitle
        StatusText = $statusText
        SelectedRule = $null
        RuleList = $null
        RuleDetails = $null
        RuleButtonPanel = $null
        RuleDetailsScrollViewer = $null
        RuleSelectionPanel = $null
        RuleBatchPanel = $null
        RuleSingleActionPanel = $null
        RestoreList = $null
        RollbackPolicyCheckBox = $null
        RollbackPolicyStatus = $null
        PageViews = @{}
        RuleRows = @()
        RuleSystemChecks = @{}
        RuleDetailCache = @{}
        RuleRowById = @{}
        RuleItems = $null
        RuleItemsView = $null
        IsUpdatingRuleList = $false
        RuleLoad = $null
        RuleLoadError = $null
        RuleAuditReady = $false
        RuleAuditLoadedCount = 0
        OverviewLoad = $null
        OverviewStatus = $null
        OverviewHardware = $null
        OverviewChangeReport = $null
        OverviewMetricValues = @{}
        OverviewHardwarePanel = $null
        OverviewChangeNotice = $null
        OverviewNotice = $null
        SmokeTest = [bool]$SmokeTest
        CurrentPage = 'overview'
    }

    $window.Dispatcher.add_UnhandledException({
        param($sender, $eventArgs)

        $eventArgs.Handled = $true
        $exception = $eventArgs.Exception
        try {
            Add-FelixLog -Level Error -Event 'ui.unhandled_exception' -Message $exception.ToString()
        }
        catch {
            # Keep the UI alive even when logging is unavailable.
        }

        try {
            $message = "$($script:FelixUiState.Text.dialogs.unexpectedError)`n`n$($exception.Message)"
            [System.Windows.MessageBox]::Show(
                $script:FelixUiState.Window,
                $message,
                $script:FelixUiState.Text.dialogs.operationFailed,
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            ) | Out-Null
        }
        catch {
            # The persistent log remains available when the dialog cannot be shown.
        }
    })

    Start-FelixUiRulesLoad
    Show-FelixPage -Page 'overview'
    if ($SmokeTest) {
        foreach ($page in @('rules', 'history', 'restore', 'logs', 'settings', 'about', 'overview')) {
            Show-FelixPage -Page $page
        }
        if ($script:FelixUiState.PageViews.Count -ne 7) {
            throw "Expected seven cached page views, found $($script:FelixUiState.PageViews.Count)."
        }
        if (
            -not $script:FelixUiState.RollbackPolicyCheckBox -or
            -not $script:FelixUiState.RollbackPolicyStatus
        ) {
            throw 'Settings page is missing the rollback policy switch.'
        }
        if (
            -not $script:FelixUiState.RuleItemsView -or
            -not [object]::ReferenceEquals($script:FelixUiState.RuleList.ItemsSource, $script:FelixUiState.RuleItems)
        ) {
            throw 'Rules page is not using the in-place filtered collection view.'
        }
        if (
            @(Get-FelixAllRuleRows).Count -ne 38 -or
            -not $script:FelixUiState.OverviewMetricValues -or
            $script:FelixUiState.OverviewMetricValues.Count -ne 12 -or
            -not $script:FelixUiState.OverviewHardwarePanel -or
            -not $script:FelixUiState.OverviewChangeNotice -or
            -not $script:FelixUiState.OverviewNotice
        ) {
            throw 'The staged rule or overview page state was not initialized.'
        }
        if (
            -not $script:FelixUiState.RuleButtonPanel -or
            -not $script:FelixUiState.RuleDetailsScrollViewer -or
            -not $script:FelixUiState.RuleSelectionPanel -or
            -not $script:FelixUiState.RuleBatchPanel -or
            -not $script:FelixUiState.RuleSingleActionPanel -or
            $script:FelixUiState.RuleDetailsScrollViewer.VerticalScrollBarVisibility -ne [System.Windows.Controls.ScrollBarVisibility]::Auto
        ) {
            throw 'Rules page is missing the top action panel or scrollable details area.'
        }
        if (
            $script:FelixUiState.RuleSelectionPanel.Children.Count -ne 3 -or
            $script:FelixUiState.RuleBatchPanel.Children.Count -ne 2 -or
            $script:FelixUiState.RuleSingleActionPanel.Children.Count -ne 3
        ) {
            throw 'Rules page action groups do not contain the expected buttons.'
        }
        if ([System.Windows.Controls.Grid]::GetRow($script:FelixUiState.RuleButtonPanel) -ne 0) {
            throw 'Rule action buttons are not positioned above the rule information area.'
        }
        $originalRows = @(Get-FelixAllRuleRows)
        try {
            $script:FelixUiState.RuleFilter.SelectedIndex = 1
            Update-FelixUiRuleList
            if ($script:FelixUiState.RuleList.Items.Count -ne @(Get-FelixVisibleRuleRows).Count) {
                throw 'Rule category filtering did not keep the list view and row projection in sync.'
            }

            $script:FelixUiState.RuleRows = @()
            $script:FelixUiState.RuleFilter.SelectedIndex = 1
            Update-FelixUiRuleList
            if (@(Get-FelixVisibleRuleRows).Count -ne 0 -or (Get-FelixSelectedRuleCount) -ne 0) {
                throw 'Empty rule collections produced unexpected selection state.'
            }
        }
        finally {
            $script:FelixUiState.RuleRows = $originalRows
            $script:FelixUiState.RuleFilter.SelectedIndex = 0
            Update-FelixUiRuleList
        }
        foreach ($scrollPage in @('overview', 'settings', 'about')) {
            if ($script:FelixUiState.PageViews[$scrollPage].Element -isnot [System.Windows.Controls.ScrollViewer]) {
                throw "Page '$scrollPage' is not wrapped in a vertical scroll viewer."
            }
        }
        $cachedRulesPage = $script:FelixUiState.PageViews['rules'].Element
        Show-FelixPage -Page 'rules'
        if (-not [object]::ReferenceEquals($cachedRulesPage, $script:FelixUiState.ContentHost.Content)) {
            throw 'Cached page navigation rebuilt the rules page unexpectedly.'
        }
        Stop-FelixUiRulesLoad
        Stop-FelixUiOverviewLoad
        $window.Close()
        $script:FelixUiState = $null
        return
    }
    $window.ShowDialog() | Out-Null
    Stop-FelixUiRulesLoad
    Stop-FelixUiOverviewLoad
    $script:FelixUiState = $null
    }
    catch {
        $errorText = $_.Exception.ToString()
        try {
            Add-FelixLog -Level Error -Event 'ui.start_failed' -Message $errorText
        }
        catch {
            # Preserve the original startup exception.
        }

        if (-not $SmokeTest) {
            try {
                $message = "$($script:FelixUiState.Text.dialogs.startupFailed)`n`n$errorText"
                [System.Windows.MessageBox]::Show(
                    $message,
                    $script:FelixUiState.Text.dialogs.operationFailed,
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Error
                ) | Out-Null
            }
            catch {
                # The command-line launcher still reports the original exception.
            }
        }
        throw
    }
    finally {
        $uiMutex.ReleaseMutex()
        $uiMutex.Dispose()
    }
}
