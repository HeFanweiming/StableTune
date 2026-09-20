[CmdletBinding()]
param(
    [string]$Version = '0.1.9.2',
    [string]$BuildDate = '20260920'
)

$ErrorActionPreference = 'Stop'

function Set-CrLfLineEndings {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $content = [System.IO.File]::ReadAllText($Path)
    $content = $content.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
    [System.IO.File]::WriteAllText($Path, $content, [System.Text.UTF8Encoding]::new($false))
}

$repoRoot = $PSScriptRoot
$distPath = Join-Path $repoRoot 'dist'
$archiveName = "StableTune-prototype-v$Version-$BuildDate.zip"
$archivePath = Join-Path $distPath $archiveName
$manifestPath = Join-Path $distPath "StableTune-prototype-v$Version-$BuildDate.manifest.json"
$hashPath = Join-Path $distPath "StableTune-prototype-v$Version-$BuildDate.sha256"

if (-not (Test-Path -LiteralPath $distPath)) {
    New-Item -ItemType Directory -Path $distPath | Out-Null
}

foreach ($path in @($archivePath, $manifestPath, $hashPath)) {
    if (Test-Path -LiteralPath $path) {
        throw "Refusing to overwrite existing release artifact '$path'."
    }
}

$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) "StableTuneBuild-$([guid]::NewGuid().ToString('N'))"
$sourceMappings = @(
    @{ Source = 'StableTune.ps1'; Destination = 'StableTune.ps1' },
    @{ Source = 'Start-StableTune.cmd'; Destination = 'Start-StableTune.cmd' },
    @{ Source = 'Build-PortableRelease.ps1'; Destination = 'Build-PortableRelease.ps1' },
    @{ Source = 'Build-Release.ps1'; Destination = 'Build-Release.ps1' },
    @{ Source = 'CHANGELOG.md'; Destination = 'CHANGELOG.md' },
    @{ Source = 'README.md'; Destination = 'README.md' },
    @{ Source = 'docs\images'; Destination = 'docs\images' },
    @{ Source = 'src\StableTune'; Destination = 'src\StableTune' },
    @{ Source = 'tests\StableTune.Tests.ps1'; Destination = 'tests\StableTune.Tests.ps1' },
    @{ Source = 'tests\Test-Smoke.ps1'; Destination = 'tests\Test-Smoke.ps1' },
    @{ Source = 'tests\Run-Tests.ps1'; Destination = 'tests\Run-Tests.ps1' },
    @{ Source = 'tools\Start-StableTunePortable.cmd'; Destination = 'tools\Start-StableTunePortable.cmd' }
)

try {
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    foreach ($mapping in $sourceMappings) {
        $sourcePath = Join-Path $repoRoot $mapping.Source
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            throw "Release source is missing: $sourcePath"
        }

        $destinationPath = Join-Path $stagingRoot $mapping.Destination
        $destinationParent = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $destinationParent)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Recurse -Force
    }

    Get-ChildItem -LiteralPath $stagingRoot -Recurse -File |
        Where-Object { $_.Extension -in @('.cmd', '.bat') } |
        ForEach-Object { Set-CrLfLineEndings -Path $_.FullName }

    Compress-Archive -Path (Join-Path $stagingRoot '*') -DestinationPath $archivePath -CompressionLevel Optimal
}
finally {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$hash = Get-FileHash -LiteralPath $archivePath -Algorithm SHA256

[ordered]@{
    name = '稳优 StableTune Prototype'
    version = $Version
    buildDate = $BuildDate
    createdAt = (Get-Date).ToString('o')
    archive = $archiveName
    sha256 = $hash.Hash
    launcherLineEndings = 'CRLF'
    previousArtifactsOverwritten = $false
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8

"$($hash.Hash)  $archiveName" | Set-Content -LiteralPath $hashPath -Encoding ascii

Get-Item -LiteralPath $archivePath, $manifestPath, $hashPath | Select-Object Name, Length, LastWriteTime
