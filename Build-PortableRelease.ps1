[CmdletBinding()]
param(
    [string]$Version = '0.1.9.2',
    [string]$BuildDate = '20260920',
    [Parameter(Mandatory)]
    [string]$InstallRoot,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot

function Set-CrLfLineEndings {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $content = [System.IO.File]::ReadAllText($Path)
    $content = $content.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
    [System.IO.File]::WriteAllText($Path, $content, [System.Text.UTF8Encoding]::new($false))
}

function Assert-CmdCompatible {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -eq 10 -and ($index -eq 0 -or $bytes[$index - 1] -ne 13)) {
            throw "Launcher must use CRLF line endings: $Path"
        }
        if ($bytes[$index] -ge 128) {
            throw "Launcher must contain ASCII text only: $Path"
        }
    }
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot "tmp\portable-release-v$Version-$BuildDate"
}

$installRoot = (Resolve-Path -LiteralPath $InstallRoot).Path
if (-not (Test-Path -LiteralPath (Join-Path $installRoot 'bin\StableTune.exe') -PathType Leaf)) {
    throw "Installed StableTune executable not found under: $installRoot"
}

$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
$packageName = "StableTune-v$Version-win-x64"
$stagingRoot = Join-Path $outputRoot $packageName
$archivePath = Join-Path $outputRoot "$packageName.zip"
$hashPath = Join-Path $outputRoot "$packageName.zip.sha256"
$manifestPath = Join-Path $outputRoot "$packageName.manifest.json"

foreach ($path in @($stagingRoot, $archivePath, $hashPath, $manifestPath)) {
    if (Test-Path -LiteralPath $path) {
        throw "Refusing to overwrite existing portable release output '$path'."
    }
}

New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
Copy-Item -Path (Join-Path $installRoot '*') -Destination $stagingRoot -Recurse -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination (Join-Path $stagingRoot 'README.md') -Force

$docsSource = Join-Path $repoRoot 'docs\images'
$docsDestination = Join-Path $stagingRoot 'docs\images'
New-Item -ItemType Directory -Path $docsDestination -Force | Out-Null
Copy-Item -Path (Join-Path $docsSource '*') -Destination $docsDestination -Recurse -Force

$launcherDestination = Join-Path $stagingRoot 'Start-StableTune.cmd'
Copy-Item -LiteralPath (Join-Path $repoRoot 'tools\Start-StableTunePortable.cmd') -Destination $launcherDestination -Force
Set-CrLfLineEndings -Path $launcherDestination
Assert-CmdCompatible -Path $launcherDestination

"$Version" | Set-Content -LiteralPath (Join-Path $stagingRoot 'VERSION.txt') -Encoding ascii

Compress-Archive -LiteralPath $stagingRoot -DestinationPath $archivePath -CompressionLevel Optimal
$hash = Get-FileHash -LiteralPath $archivePath -Algorithm SHA256
"$($hash.Hash)  $packageName.zip" | Set-Content -LiteralPath $hashPath -Encoding ascii

$files = @(Get-ChildItem -LiteralPath $stagingRoot -Recurse -File)
[ordered]@{
    name = 'StableTune'
    version = $Version
    buildDate = $BuildDate
    archive = "$packageName.zip"
    sha256 = $hash.Hash
    fileCount = $files.Count
    uncompressedBytes = ($files | Measure-Object -Property Length -Sum).Sum
    launcher = 'Start-StableTune.cmd'
    launcherEncoding = 'ASCII'
    launcherLineEndings = 'CRLF'
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8

Get-Item -LiteralPath $archivePath, $hashPath, $manifestPath |
    Select-Object Name, Length, LastWriteTime
