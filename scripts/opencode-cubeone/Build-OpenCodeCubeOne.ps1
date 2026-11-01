<#
.SYNOPSIS
    Packs the cube one OpenCode configuration into files\opencode-cubeone-<Version>.zip and prints its hash.

.DESCRIPTION
    Rebuild the plugin first (npm ci; npm run build in plugins\cubeone-stt) when its sources changed.
    Then point the opencode-desktop manifest at the new zip and hash.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$repo = Split-Path (Split-Path $root -Parent) -Parent
$out = Join-Path $repo "files\opencode-cubeone-$Version.zip"
if (Test-Path -LiteralPath $out) {
    throw "$out already exists. Published packages are immutable, pick a new version."
}

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ('opencode-cubeone-build-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'managed') -Destination $staging -Recurse
    Copy-Item -LiteralPath (Join-Path $root 'user') -Destination $staging -Recurse
    Copy-Item -LiteralPath (Join-Path $root 'Install-OpenCodeCubeOne.ps1') -Destination $staging
    $plugin = Join-Path $staging 'plugins\cubeone-stt'
    New-Item -ItemType Directory -Path (Join-Path $plugin 'dist') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'plugins\cubeone-stt\package.json') -Destination $plugin
    Copy-Item -LiteralPath (Join-Path $root 'plugins\cubeone-stt\dist\gui-experimental.cjs') -Destination (Join-Path $plugin 'dist')

    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $out
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

$hash = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "Built $out" -ForegroundColor Green
Write-Host "sha256: $hash"
