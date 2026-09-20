[CmdletBinding()]
param()

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
$testCandidates = @(
    (Join-Path $PSScriptRoot 'StableTune.Tests.ps1'),
    (Join-Path $repoRoot 'tests\StableTune.Tests.ps1')
)
$testPath = $testCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $testPath) {
    throw 'Unable to locate the StableTune tests.'
}
Import-Module $modulePath -Force

if (Get-Command Invoke-Pester -ErrorAction SilentlyContinue) {
    $result = Invoke-Pester -Script $testPath -PassThru
    if ($result.FailedCount -gt 0) {
        throw "$($result.FailedCount) test(s) failed."
    }
    return
}

$rules = Get-FelixRule
if ($rules.Count -ne 38) {
    throw "Expected 38 rules, found $($rules.Count)."
}

$ids = foreach ($rule in $rules) { $rule['id'] }
if (($ids | Sort-Object -Unique).Count -ne $ids.Count) {
    throw 'Rule IDs are not unique.'
}

$audit = Invoke-FelixAudit
if ($audit.Count -ne 38) {
    throw "Expected 38 audit rows, found $($audit.Count)."
}

foreach ($rule in $rules) {
    if (
        [string]::IsNullOrWhiteSpace([string]$rule.advice) -or
        @($rule.consequences).Count -lt 2 -or
        @($rule.benefits).Count -lt 3 -or
        @($rule.drawbacks).Count -lt 3
    ) {
        throw "Rule '$($rule.id)' is missing detailed advice, consequences, benefits, or drawbacks."
    }
    if (-not $rule.Contains('compatibility') -or -not $rule.compatibility.scope) {
        throw "Rule '$($rule.id)' is missing compatibility metadata."
    }
}

Write-Host 'Catalog and audit smoke tests passed.'
