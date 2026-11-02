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
    [switch]$SkipSsh,
    [switch]$DesktopOnly,
    # Limits the SSH part to one host alias from ~/.ssh/config. Used by cubeone-ssh for a single,
    # on-demand or background setup instead of a full company-wide run.
    [string]$OnlyHost
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

function Register-DesktopSshHosts {
    param([string]$ProfilePath)
    $desktop = Join-Path $ProfilePath 'AppData\Roaming\ai.opencode.desktop'
    if (-not (Test-Path -LiteralPath $desktop)) { return }
    $names = @(@(Get-SshHosts -ConfigPath (Join-Path $ProfilePath '.ssh\config')) | Where-Object { $_ -match '^[A-Za-z0-9-]{1,80}$' -and $_ -notmatch '-win-' })
    if ($names.Count -eq 0) { return }

    $settingsPath = Join-Path $desktop 'opencode.settings'
    if (-not (Test-Path -LiteralPath $settingsPath)) { [System.IO.File]::WriteAllText($settingsPath, '{}') }
    $namesJson = ($names | ConvertTo-Json -Compress)
    if ($names.Count -eq 1) { $namesJson = "[$namesJson]" }
    $updater = @'
const fs = require("fs")
const file = process.argv[2]
const names = JSON.parse(process.argv[3])
const settings = JSON.parse(fs.readFileSync(file, "utf8"))
const current = settings.ssh && Array.isArray(settings.ssh.servers) ? settings.ssh.servers : []
const byId = new Map(current.filter((item) => item && item.id).map((item) => [item.id, item]))
for (const name of names) {
  if (!byId.has(name)) byId.set(name, { id: name, target: name, name })
}
settings.ssh = Object.assign({}, settings.ssh, { servers: [...byId.values()] })
fs.writeFileSync(file, JSON.stringify(settings, null, "\t") + "\n")
process.stdout.write(String(settings.ssh.servers.length))
'@
    $updaterFile = Join-Path ([System.IO.Path]::GetTempPath()) ('opencode-ssh-settings-' + [guid]::NewGuid().ToString('N') + '.js')
    [System.IO.File]::WriteAllText($updaterFile, $updater)
    try {
        $count = (& node $updaterFile $settingsPath $namesJson | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $count) { throw "settings update failed" }
        Write-Host "Desktop lists $count SSH hosts for new projects." -ForegroundColor Green
    } finally {
        Remove-Item -LiteralPath $updaterFile -Force -ErrorAction SilentlyContinue
    }

    $db = Join-Path $desktop 'drafts.sqlite'
    $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if (-not $sqlite -or -not (Test-Path -LiteralPath $db)) { return }
    $servers = @($names | ForEach-Object { [pscustomobject]@{ id = $_; target = $_; name = $_ } })
    $value = $servers | ConvertTo-Json -Compress -Depth 4
    if ($servers.Count -eq 1) { $value = "[$value]" }
    $value = $value.Replace("'", "''")
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    & sqlite3 $db "INSERT INTO state(name, key, value, updated_at) VALUES('plugin.ssh','servers','$value',$now) ON CONFLICT(name, key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;"
    if ($LASTEXITCODE -ne 0) { Write-Warning 'The desktop server list could not be written. Quit OpenCode and run this script again.' }
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
    foreach ($name in @('cubeone-stt', 'cubeone-pty', 'cubeone-vorgaben', 'cubeone-mcp', 'cubeone-ssh', 'cubeone-redmine')) {
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
    # Piping $InputPath through .NET's Process.StandardInput corrupts it: that property lazily builds
    # a StreamWriter with AutoFlush=true, and merely touching it flushes a 3-byte UTF-8 BOM to the pipe
    # before any byte we write ourselves lands - breaking the tar.gz transfer (invalid gzip), the
    # OpenRouter key file (3 garbage bytes prepended) and the first line of every shell script sent
    # this way. cmd.exe's own "<" redirection is a raw OS file-handle redirect and never touches that
    # encoder, so route the whole call through it instead of RedirectStandardInput.
    $cmdLine = "$Exe $Arguments < `"$InputPath`""
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = "/d /c `"$cmdLine`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($UserProfile) {
        $psi.Environment['USERPROFILE'] = $UserProfile
        $psi.Environment['HOME'] = $UserProfile
    }
    $process = [System.Diagnostics.Process]::Start($psi)
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

# Installs the official OpenCode CLI (the same binary the desktop app runs as its remote server) when
# a Linux target does not have it yet, so a freshly added SSH host needs no manual setup. Uses the
# company's passwordless-sudo pattern, the same one install.sh above already relies on, to also put
# the binary on the default non-interactive PATH (/usr/local/bin), which is where the desktop app looks
# for it over a plain `ssh host command` call. A CPU that is too old for Bun (missing SSE4.2, common on
# a QEMU/KVM VM without host CPU passthrough) fails here with that exact message instead of silently
# leaving the host unusable.
$cliInstallSh = @'
#!/bin/bash
set -eu
if command -v opencode >/dev/null 2>&1; then
    echo "opencode already present: $(command -v opencode)"
    exit 0
fi
curl -fsSL https://opencode.ai/v2/install | bash
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    sudo -n install -m 755 "$HOME/.opencode/bin/opencode" /usr/local/bin/opencode
fi
command -v opencode
'@

$utf8 = New-Object System.Text.UTF8Encoding $false
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('opencode-remote-' + [guid]::NewGuid().ToString('N'))
$payload = Join-Path $work 'payload'
$tar = Join-Path $work 'cubeone-opencode.tgz'
$keyFile = Join-Path $work 'openrouter.key'
$scriptFile = Join-Path $work 'install.sh'
$cliInstallFile = Join-Path $work 'install-cli.sh'
New-Item -ItemType Directory -Path $payload -Force | Out-Null
try {
    # A targeted, single-host maintenance call (background auto-setup or the /ssh-einrichten command)
    # has no business touching the desktop's full server list or WSL.
    if (-not $OnlyHost) {
        Register-DesktopSshHosts -ProfilePath $ProfilePath
    }
    if ($DesktopOnly) { return }
    New-LinuxPayload -Source $SourceDir -Destination $payload
    $scriptText = $installSh -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($scriptFile, $scriptText, $utf8)
    [System.IO.File]::WriteAllText($cliInstallFile, ($cliInstallSh -replace "`r`n", "`n"), $utf8)
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
    if (-not $SkipWsl -and -not $OnlyHost) {
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
    $sshTargets = @(Get-SshHosts -ConfigPath $sshConfig)
    if ($OnlyHost) { $sshTargets = @($sshTargets | Where-Object { $_ -eq $OnlyHost }) }
    foreach ($sshHost in $sshTargets) {
        $sshArgs = "-F `"$sshConfig`" -o BatchMode=yes -o ConnectTimeout=12 $sshHost"
        try {
            $probe = Send-File -Exe 'ssh.exe' -Arguments "$sshArgs uname -s" -InputPath $keyFile -UserProfile $ProfilePath
            # uname reads no stdin; an empty key file keeps the stream valid.
            if ($probe.Code -ne 0 -or $probe.Out.Trim() -ne 'Linux') {
                Write-Warning "SSH ${sshHost}: skipped, not a reachable Linux host."
                continue
            }
            # The desktop app runs the remote server as a plain `ssh host opencode ...`, so the CLI has
            # to exist on the default, non-interactive PATH before anything else here helps.
            $cli = Send-File -Exe 'ssh.exe' -Arguments "$sshArgs bash -s" -InputPath $cliInstallFile -UserProfile $ProfilePath
            Invoke-Checked $cli "opencode CLI on SSH $sshHost"
            Write-Host "SSH ${sshHost}: $($cli.Out.Trim())" -ForegroundColor Green
            # Quoted so cmd.exe (Send-File's local redirection shell) leaves the ">" for the remote
            # shell instead of redirecting ssh's own stdout into a local file named /tmp/... .
            $recv = Send-File -Exe 'ssh.exe' -Arguments "$sshArgs `"cat > /tmp/cubeone-opencode.tgz`"" -InputPath $tar -UserProfile $ProfilePath
            Invoke-Checked $recv "Copy to SSH $sshHost"
            $recv = Send-File -Exe 'ssh.exe' -Arguments "$sshArgs `"cat > /tmp/cubeone-openrouter.key`"" -InputPath $keyFile -UserProfile $ProfilePath
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
