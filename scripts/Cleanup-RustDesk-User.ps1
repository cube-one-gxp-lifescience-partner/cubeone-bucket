#Requires -Version 4.0
# Cleanup-RustDesk-User.ps1
# Run as normal user (Scoop under %USERPROFILE%)
# Skips when cubeone/rustdesk is already installed.

$ErrorActionPreference = 'Stop'

function Test-IsCubeoneRustDesk {
    $installJson = Join-Path $env:USERPROFILE 'scoop\apps\rustdesk\current\install.json'
    if (-not (Test-Path -LiteralPath $installJson)) {
        return $false
    }

    $raw = Get-Content -LiteralPath $installJson -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $false
    }

    # Matches bucket name "cubeone" and local path "...\cubeone-bucket\..."
    return ($raw -match 'cubeone')
}

if (Test-IsCubeoneRustDesk) {
    Write-Host 'cubeone/rustdesk is already installed - skipping cleanup.' -ForegroundColor Green
    exit 0
}

Write-Host 'cubeone/rustdesk not found - cleaning up other RustDesk installs...' -ForegroundColor Yellow

$scoopAppDir = Join-Path $env:USERPROFILE 'scoop\apps\rustdesk'
if (Test-Path -LiteralPath $scoopAppDir) {
    Write-Host "Uninstalling Scoop package 'rustdesk'..." -ForegroundColor Cyan
    & scoop uninstall rustdesk
} else {
    Write-Host 'No Scoop rustdesk package found.' -ForegroundColor Gray
}

$rustDeskExe = Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe'
if (-not (Test-Path -LiteralPath $rustDeskExe)) {
    $rustDeskExe = Join-Path $env:ProgramFiles 'RustDesk\RustDesk.exe'
}

if (Test-Path -LiteralPath $rustDeskExe) {
    Write-Host 'Uninstalling Program Files RustDesk (elevated)...' -ForegroundColor Cyan
    $p = Start-Process -FilePath $rustDeskExe -ArgumentList '--uninstall' -Verb RunAs -Wait -PassThru
    if ($null -eq $p) {
        Write-Warning 'RustDesk --uninstall was not started (admin approval may have been denied)'
    } elseif ($p.ExitCode -ne 0) {
        Write-Warning ("RustDesk --uninstall returned exit code {0}" -f $p.ExitCode)
    }
} else {
    Write-Host 'No Program Files RustDesk installation found.' -ForegroundColor Gray
}

Write-Host 'Cleanup finished.' -ForegroundColor Green
