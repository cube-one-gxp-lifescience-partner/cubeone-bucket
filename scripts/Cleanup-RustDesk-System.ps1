#Requires -Version 4.0
# Cleanup-RustDesk-System.ps1
# Run as SYSTEM / elevated
# Detects cubeone via user Scoop install.json under C:\Users\*

$ErrorActionPreference = 'Stop'

function Get-LocalUserProfiles {
    Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $name = $_.Name
            ($name -ne 'Public') -and
            ($name -ne 'Default') -and
            ($name -ne 'Default User') -and
            ($name -ne 'All Users') -and
            ($name -notlike 'WsiAccount*')
        }
}

function Get-RustDeskInstallJsonPaths {
    $paths = @()
    foreach ($profile in (Get-LocalUserProfiles)) {
        $json = Join-Path $profile.FullName 'scoop\apps\rustdesk\current\install.json'
        if (Test-Path -LiteralPath $json) {
            $paths += $json
        }
    }
    return $paths
}

function Test-IsCubeoneRustDeskPresent {
    foreach ($json in (Get-RustDeskInstallJsonPaths)) {
        $raw = Get-Content -LiteralPath $json -Raw -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($raw) -and ($raw -match 'cubeone')) {
            Write-Host ("cubeone/rustdesk found via: {0}" -f $json) -ForegroundColor Green
            return $true
        }
    }
    return $false
}

function Uninstall-ScoopRustDeskForUser {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserProfilePath
    )

    $appDir = Join-Path $UserProfilePath 'scoop\apps\rustdesk'
    if (-not (Test-Path -LiteralPath $appDir)) {
        Write-Host ("No Scoop rustdesk for profile: {0}" -f $UserProfilePath) -ForegroundColor Gray
        return
    }

    Write-Host ("Uninstalling Scoop rustdesk for profile: {0}" -f $UserProfilePath) -ForegroundColor Cyan

    $scoopPs1 = Join-Path $UserProfilePath 'scoop\apps\scoop\current\bin\scoop.ps1'
    $uninstalledViaScoop = $false

    if (Test-Path -LiteralPath $scoopPs1) {
        # Use Windows PowerShell + -File to avoid pwsh/scoop.cmd path encoding issues (e.g. ß)
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $args = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $scoopPs1,
            'uninstall', 'rustdesk'
        )

        $p = Start-Process -FilePath $powershellExe -ArgumentList $args -WorkingDirectory $UserProfilePath -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -eq 0) {
            $uninstalledViaScoop = $true
        } else {
            Write-Warning ("scoop.ps1 uninstall failed for {0} with exit code {1}; falling back to manual removal" -f $UserProfilePath, $p.ExitCode)
        }
    }

    if (-not $uninstalledViaScoop) {
        Write-Host 'Removing Scoop rustdesk files manually...' -ForegroundColor Yellow
        Remove-Item -LiteralPath $appDir -Recurse -Force -ErrorAction SilentlyContinue

        $shimDir = Join-Path $UserProfilePath 'scoop\shims'
        Get-ChildItem -LiteralPath $shimDir -Filter 'rustdesk*' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

        $shortcut = Join-Path $UserProfilePath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Scoop Apps\RustDesk.lnk'
        if (Test-Path -LiteralPath $shortcut) {
            Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue
        }
    }
}

if (Test-IsCubeoneRustDeskPresent) {
    Write-Host 'cubeone/rustdesk is already installed - skipping cleanup.' -ForegroundColor Green
    exit 0
}

Write-Host 'cubeone/rustdesk not found - cleaning up other RustDesk installs...' -ForegroundColor Yellow

foreach ($profile in (Get-LocalUserProfiles)) {
    Uninstall-ScoopRustDeskForUser -UserProfilePath $profile.FullName
}

$rustDeskExe = Join-Path $env:ProgramFiles 'RustDesk\rustdesk.exe'
if (-not (Test-Path -LiteralPath $rustDeskExe)) {
    $rustDeskExe = Join-Path $env:ProgramFiles 'RustDesk\RustDesk.exe'
}

if (Test-Path -LiteralPath $rustDeskExe) {
    $svc = Get-Service -Name 'RustDesk' -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host 'Stopping RustDesk service...' -ForegroundColor Cyan
        Stop-Service -Name 'RustDesk' -Force -ErrorAction SilentlyContinue
    }

    Get-Process -Name 'RustDesk' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 2

    Write-Host 'Uninstalling Program Files RustDesk...' -ForegroundColor Cyan
    $p = Start-Process -FilePath $rustDeskExe -ArgumentList '--uninstall' -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Write-Warning ("RustDesk --uninstall returned exit code {0}" -f $p.ExitCode)
    }

    if (Test-Path -LiteralPath $rustDeskExe) {
        Write-Warning 'RustDesk executable still present after uninstall attempt'
        exit 1
    }
} else {
    Write-Host 'No Program Files RustDesk installation found.' -ForegroundColor Gray
}

Write-Host 'Cleanup finished.' -ForegroundColor Green
