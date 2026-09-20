[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$indexPath = Join-Path $repoRoot 'release-index.json'

if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
    throw "Release index not found: $indexPath"
}

$index = Get-Content -LiteralPath $indexPath -Raw | ConvertFrom-Json
if ($index.repository -ne 'https://github.com/HeFanweiming/StableTune') {
    throw "Release index points to an unexpected repository: $($index.repository)"
}

$current = @($index.releases | Where-Object { $_.version -eq $index.currentVersion })
if ($current.Count -ne 1) {
    throw "Current release '$($index.currentVersion)' must be listed exactly once."
}

$readmePath = Join-Path $repoRoot 'README.md'
if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) {
    throw "Repository README not found: $readmePath"
}

$readme = Get-Content -LiteralPath $readmePath -Raw
$readmeVersionMarker = '当前说明对应版本：`{0}`' -f $index.currentVersion
if (-not $readme.Contains($readmeVersionMarker)) {
    throw "README.md must identify current version '$($index.currentVersion)'."
}

$currentArtifact = [string]$current[0].artifact
if (-not $readme.Contains($currentArtifact)) {
    throw "README.md must reference current release artifact '$currentArtifact'."
}

$currentReleasePath = Join-Path $repoRoot 'CURRENT-RELEASE.md'
if (-not (Test-Path -LiteralPath $currentReleasePath -PathType Leaf)) {
    throw "Current release summary not found: $currentReleasePath"
}

$currentRelease = Get-Content -LiteralPath $currentReleasePath -Raw
$currentVersionMarker = '- 当前版本：`{0}`' -f $index.currentVersion
$currentArtifactMarker = '- 推荐安装包：`{0}`' -f $currentArtifact
if (-not $currentRelease.Contains($currentVersionMarker)) {
    throw "CURRENT-RELEASE.md must identify current version '$($index.currentVersion)'."
}
if (-not $currentRelease.Contains($currentArtifactMarker)) {
    throw "CURRENT-RELEASE.md must reference current release artifact '$currentArtifact'."
}

foreach ($release in @($index.releases)) {
    if (-not $release.artifactPresent) {
        continue
    }

    $artifactPath = Join-Path $repoRoot ([string]$release.artifact)
    if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
        throw "Release artifact is missing: $artifactPath"
    }

    $actualHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash
    if ($actualHash -ne [string]$release.sha256) {
        throw "Release hash mismatch for '$artifactPath'."
    }
}

$requiredPaths = @(
    'Build-Release.ps1',
    'CHANGELOG.md',
    'CURRENT-RELEASE.md',
    'StableTune.ps1',
    'Start-StableTune.cmd',
    'src\StableTune\StableTune.psd1',
    'src\StableTune\CrashRecoveryWorker.ps1',
    'src\StableTune\rules\applicability.zh-CN.json',
    'src\StableTune\rules\catalog.json',
    'src\StableTune\rules\details.zh-CN.json',
    'src\StableTune\rules\guidance.zh-CN.json',
    'tests\StableTune.Tests.ps1',
    'tests\Test-Smoke.ps1',
    'tests\Run-Tests.ps1',
    'docs\REPOSITORY-GUIDE.zh-CN.md',
    'docs\RELEASES.md'
)

foreach ($relativePath in $requiredPaths) {
    $fullPath = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath)) {
        throw "Required repository path is missing: $relativePath"
    }
}

Write-Host "Repository verification passed. Current release: $($index.currentVersion)"
