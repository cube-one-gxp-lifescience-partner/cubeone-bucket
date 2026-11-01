<#
.SYNOPSIS
    Installs the cube one OpenCode configuration on local WSL distros and Linux SSH hosts.

.DESCRIPTION
    The desktop app runs a separate OpenCode server for WSL and for each SSH host. That server
    reads /etc/opencode on Linux, not C:\ProgramData\opencode. This script copies the managed
    models, rules and plugins there and stores the OpenRouter key in the remote user's
    ~/.config/opencode/openrouter.key (mode 0600). The key is never printed.
#>
[CmdletBinding()]
param(
    [string]$SourceDir = $PSScriptRoot,
    [string]$ProfilePath = $env:USERPROFILE,
    [switch]$SkipWsl,
    [switch]$SkipSsh
)

$ErrorActionPreference = 'Stop'

function Get-OpenRouterKey {
    $found = @(
        $env:OPENROUTER_API_KEY
        [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'User')
        [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'Machine')
    ) | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1
    if ($found) { return $found.Trim() }
    return ''
}

function Get-WslDistros {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $raw = & wsl.exe -l -q 2>$null
    $ErrorActionPreference = $previous
    if (-not $raw) { return @() }
    $text = ($raw | Out-String) -replace [char]0, ''
    return @($text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object {
        $_ -and $_ -notmatch '^(docker-desktop|docker-desktop-data)$'
    })
}

function Get-SshHosts {
    param([string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return @() }
    $hosts = New-Object System.Collections.Generic.List[string]
    foreach ($raw in [System.IO.File]::ReadAllLines($ConfigPath)) {
        $line = ($raw -replace '#.*$', '').Trim()
        if ($line -notmatch '^(?i)Host\s+(.+)$') { continue }
        foreach ($token in ($Matches[1] -split '\s+')) {
            if ($token -and $token -notmatch '[*?!]') { $hosts.Add($token) }
        }
    }
    return @($hosts | Select-Object -Unique)
}

function Copy-PluginPayload {
    param([string]$Name, [string]$From, [string]$To)
    New-Item -ItemType Directory -Path $To -Force | Out-Null
    if ($Name -eq 'cubeone-stt') {
        Copy-Item -LiteralPath (Join-Path $From 'package.json') -Destination $To
        Copy-Item -LiteralPath (Join-Path $From 'dist') -Destination (Join-Path $To 'dist') -Recurse
        return
    }
    if ($Name -eq 'cubeone-pty') {
        # node_modules ships the Linux bun-pty library next to the Windows one.
        Get-ChildItem -LiteralPath $From -Force | Where-Object { $_.Name -ne 'test' } | Copy-Item -Destination $To -Recurse
        return
    }
    Get-ChildItem -LiteralPath $From -File | Copy-Item -Destination $To
}

function New-LinuxPayload {
    param([string]$Source, [string]$Destination)
    $managed = Join-Path $Source 'managed\opencode.jsonc'
    $text = [System.IO.File]::ReadAllText($managed)
    $text = $text.Replace('C:/ProgramData/opencode', '__CUBEONE_ROOT__')
    $needle = '"baseURL": "https://openrouter.ai/api/v1"'
    $replacement = '"baseURL": "https://openrouter.ai/api/v1", "apiKey": "{file:~/.config/opencode/openrouter.key}"'
    if (-not $text.Contains($needle)) { throw "Managed config has no OpenRouter baseURL to attach the key file to." }
    $text = $text.Replace($needle, $replacement)
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText((Join-Path $Destination 'opencode.jsonc'), $text, $utf8)
    Copy-Item -LiteralPath (Join-Path $Source 'managed\rules') -Destination (Join-Path $Destination 'rules') -Recurse
    Copy-Item -LiteralPath (Join-Path $Source 'managed\vorgaben') -Destination (Join-Path $Destination 'vorgaben') -Recurse
    $plugins = Join-Path $Destination 'cubeone\plugins'
    New-Item -ItemType Directory -Path $plugins -Force | Out-Null
    foreach ($name in @('cubeone-stt', 'cubeone-pty', 'cubeone-vorgaben', 'cubeone-mcp', 'cubeone-ssh')) {
        Copy-PluginPayload -Name $name -From (Join-Path $Source "plugins\$name") -To (Join-Path $plugins $name)
    }
    $userTo = Join-Path $Destination 'user'
    New-Item -ItemType Directory -Path (Join-Path $userTo 'vorgaben') -Force | Out-Null
    foreach ($file in @('opencode.jsonc', 'opencode-mem.jsonc')) {
        $path = Join-Path $Source "user\$file"
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $userTo $file) }
    }
    $design = Join-Path $Source 'user\vorgaben\design.md'
    if (Test-Path -LiteralPath $design) { Copy-Item -LiteralPath $design -Destination (Join-Path $userTo 'vorgaben\design.md') }
}

function Send-File {
    param([string]$Exe, [string]$Arguments, [string]$InputPath, [string]$UserProfile)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($UserProfile) {
        $psi.Environment['USERPROFILE'] = $UserProfile
        $psi.Environment['HOME'] = $UserProfile
    }
    $process = [System.Diagnostics.Process]::Start($psi)
    $stream = [System.IO.File]::OpenRead($InputPath)
    try {
        $stream.CopyTo($process.StandardInput.BaseStream)
    } finally {
        $stream.Dispose()
        $process.StandardInput.Close()
    }
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ Code = $process.ExitCode; Out = $stdout; Err = $stderr }
}

function Invoke-Checked {
    param($Result, [string]$Action)
    if ($Result.Code -ne 0) {
        $detail = ($Result.Err + $Result.Out).Trim()
        if ($detail.Length -gt 400) { $detail = $detail.Substring(0, 400) }
        throw "$Action failed (exit $($Result.Code)). $detail"
    }
}

$installSh = @'
#!/bin/bash
set -eu
TARGET_USER="${1:-}"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE" /tmp/cubeone-opencode.tgz /tmp/cubeone-openrouter.key' EXIT
tar -xzf /tmp/cubeone-opencode.tgz -C "$STAGE"
if [ -n "$TARGET_USER" ] && [ "$(id -u)" -eq 0 ]; then
    HOME_DIR=$(getent passwd "$TARGET_USER" | cut -d: -f6)
else
    HOME_DIR="$HOME"
fi
ROOT=/etc/opencode
SUDO=""
if [ "$(id -u)" -eq 0 ]; then
    mkdir -p "$ROOT"
elif mkdir -p "$ROOT" 2>/dev/null && [ -w "$ROOT" ]; then
    :
elif command -v sudo >/dev/null 2>&1 && sudo -n mkdir -p "$ROOT"; then
    SUDO="sudo -n"
else
    ROOT="$HOME_DIR/.config/opencode"
    mkdir -p "$ROOT"
fi
copy_tree() {
    if [ -n "$SUDO" ]; then
        sudo -n mkdir -p "$2"
        sudo -n cp -a "$1"/. "$2"/
    else
        mkdir -p "$2"
        cp -a "$1"/. "$2"/
    fi
}
copy_tree "$STAGE/rules" "$ROOT/rules"
copy_tree "$STAGE/vorgaben" "$ROOT/vorgaben"
copy_tree "$STAGE/cubeone" "$ROOT/cubeone"
if [ -n "$SUDO" ]; then
    sed "s#__CUBEONE_ROOT__#${ROOT}#g" "$STAGE/opencode.jsonc" | sudo -n tee "$ROOT/opencode.jsonc" >/dev/null
    sudo -n chmod -R a+rX "$ROOT"
else
    sed "s#__CUBEONE_ROOT__#${ROOT}#g" "$STAGE/opencode.jsonc" > "$ROOT/opencode.jsonc"
fi
mkdir -p "$HOME_DIR/.config/opencode/vorgaben"
# A previous run without root stored the managed file in the user config and hid the MCP servers.
if [ -f "$HOME_DIR/.config/opencode/opencode.jsonc" ] && grep -q 'openrouter-zdr' "$HOME_DIR/.config/opencode/opencode.jsonc" && ! grep -q '"mcp"' "$HOME_DIR/.config/opencode/opencode.jsonc"; then
    mv "$HOME_DIR/.config/opencode/opencode.jsonc" "$HOME_DIR/.config/opencode/opencode.jsonc.bak-cubeone"
fi
if [ ! -f "$HOME_DIR/.config/opencode/opencode.jsonc" ] && [ -f "$STAGE/user/opencode.jsonc" ]; then
    cp "$STAGE/user/opencode.jsonc" "$HOME_DIR/.config/opencode/opencode.jsonc"
fi
if [ ! -f "$HOME_DIR/.config/opencode/vorgaben/design.md" ] && [ -f "$STAGE/user/vorgaben/design.md" ]; then
    cp "$STAGE/user/vorgaben/design.md" "$HOME_DIR/.config/opencode/vorgaben/design.md"
fi
if [ ! -f "$HOME_DIR/.config/opencode/opencode-mem.jsonc" ] && [ -f "$STAGE/user/opencode-mem.jsonc" ]; then
    cp "$STAGE/user/opencode-mem.jsonc" "$HOME_DIR/.config/opencode/opencode-mem.jsonc"
fi
if [ -s /tmp/cubeone-openrouter.key ]; then
    install -m 600 -o "$TARGET_USER" -g "$TARGET_USER" /dev/null "$HOME_DIR/.config/opencode/openrouter.key" 2>/dev/null || true
    umask 077
    cat /tmp/cubeone-openrouter.key > "$HOME_DIR/.config/opencode/openrouter.key"
    chmod 600 "$HOME_DIR/.config/opencode/openrouter.key"
    if [ -n "$TARGET_USER" ] && [ "$(id -u)" -eq 0 ]; then
        chown "$TARGET_USER:$TARGET_USER" "$HOME_DIR/.config/opencode/openrouter.key"
        chown -R "$TARGET_USER:$TARGET_USER" "$HOME_DIR/.config/opencode"
    fi
fi
printf 'installed %s\n' "$ROOT"
'@

$utf8 = New-Object System.Text.UTF8Encoding $false
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('opencode-remote-' + [guid]::NewGuid().ToString('N'))
$payload = Join-Path $work 'payload'
$tar = Join-Path $work 'cubeone-opencode.tgz'
$keyFile = Join-Path $work 'openrouter.key'
$scriptFile = Join-Path $work 'install.sh'
New-Item -ItemType Directory -Path $payload -Force | Out-Null
try {
    New-LinuxPayload -Source $SourceDir -Destination $payload
    $scriptText = $installSh -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($scriptFile, $scriptText, $utf8)
    if (Test-Path -LiteralPath $tar) { Remove-Item -LiteralPath $tar -Force }
    & tar.exe -czf $tar -C $payload .
    if ($LASTEXITCODE -ne 0) { throw "tar failed with exit $LASTEXITCODE" }

    $key = Get-OpenRouterKey
    if ($key) {
        [System.IO.File]::WriteAllText($keyFile, $key, $utf8)
    } else {
        Write-Warning 'OPENROUTER_API_KEY is not set. Remote servers get the models, but calls fail until the key file exists.'
        [System.IO.File]::WriteAllText($keyFile, '', $utf8)
    }

    $ok = 0
    if (-not $SkipWsl) {
    foreach ($distro in @(Get-WslDistros)) {
        try {
            # -u root reaches /etc/opencode without a sudo password. The key stays in the distro user's home.
            $wslUser = (& wsl.exe -d $distro -- bash -lc 'printf %s "$USER"').Trim()
            if (-not $wslUser) { throw 'could not resolve the WSL user' }
            $recv = Send-File -Exe 'wsl.exe' -Arguments "-d $distro -- bash -c `"cat > /tmp/cubeone-opencode.tgz`"" -InputPath $tar
            Invoke-Checked $recv "Copy to WSL $distro"
            $recv = Send-File -Exe 'wsl.exe' -Arguments "-d $distro -- bash -c `"cat > /tmp/cubeone-openrouter.key`"" -InputPath $keyFile
            Invoke-Checked $recv "Key file to WSL $distro"
            $recv = Send-File -Exe 'wsl.exe' -Arguments "-d $distro -u root -- bash -s -- $wslUser" -InputPath $scriptFile
            Invoke-Checked $recv "Install on WSL $distro"
            Write-Host "WSL ${distro}: $($recv.Out.Trim())" -ForegroundColor Green
            $ok++
        } catch {
            Write-Warning "WSL ${distro}: $($_.Exception.Message)"
        }
    }
    }

    if ($ok -gt 0) {
        $current = [Environment]::GetEnvironmentVariable('WSLENV', 'User')
        $entries = @()
        if ($current) { $entries = @($current -split ':' | Where-Object { $_ }) }
        if ($entries -notcontains 'OPENROUTER_API_KEY') {
            $entries += 'OPENROUTER_API_KEY'
            [Environment]::SetEnvironmentVariable('WSLENV', ($entries -join ':'), 'User')
            Write-Host 'WSLENV passes OPENROUTER_API_KEY into WSL.' -ForegroundColor Green
        }
    }

    $sshConfig = Join-Path $ProfilePath '.ssh\config'
    if (-not $SkipSsh) {
    foreach ($sshHost in @(Get-SshHosts -ConfigPath $sshConfig)) {
        $sshArgs = "-F `"$sshConfig`" -o BatchMode=yes -o ConnectTimeout=12 $sshHost"
        try {
            $probe = Send-File -Exe 'ssh.exe' -Arguments "$sshArgs uname -s" -InputPath $keyFile -UserProfile $ProfilePath
            # uname reads no stdin; an empty key file keeps the stream valid.
            if ($probe.Code -ne 0 -or $probe.Out.Trim() -ne 'Linux') {
                Write-Warning "SSH ${sshHost}: skipped, not a reachable Linux host."
                continue
            }
            $recv = Send-File -Exe 'ssh.exe' -Arguments "$sshArgs cat > /tmp/cubeone-opencode.tgz" -InputPath $tar -UserProfile $ProfilePath
            Invoke-Checked $recv "Copy to SSH $sshHost"
            $recv = Send-File -Exe 'ssh.exe' -Arguments "$sshArgs cat > /tmp/cubeone-openrouter.key" -InputPath $keyFile -UserProfile $ProfilePath
            Invoke-Checked $recv "Key file to SSH $sshHost"
            $recv = Send-File -Exe 'ssh.exe' -Arguments "$sshArgs bash -s" -InputPath $scriptFile -UserProfile $ProfilePath
            Invoke-Checked $recv "Install on SSH $sshHost"
            Write-Host "SSH ${sshHost}: $($recv.Out.Trim())" -ForegroundColor Green
        } catch {
            Write-Warning "SSH ${sshHost}: $($_.Exception.Message)"
        }
    }
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
