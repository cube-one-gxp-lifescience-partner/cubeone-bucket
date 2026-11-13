<#
.SYNOPSIS
    Connects a coding VM to OpenCode Desktop through a loopback-only SSH tunnel.
.DESCRIPTION
    Reads the host aliases from the user's SSH configuration, asks which VM to connect, starts that
    VM's existing OpenCode service and keeps its SSH session alive. The one-time pairing link is
    copied to the local clipboard without printing or persisting credentials. Keep this terminal
    open while using the connection. Existing SSH configuration supplies the user and key. The VM
    can be a Windows or a Linux machine with OpenCode installed; the system is detected over SSH.
.PARAMETER HostName
    SSH host alias of the VM. Without it, the aliases from ~/.ssh/config are offered for selection.
.PARAMETER LocalPort
    Loopback port of the tunnel. Defaults to a stable port derived from the host alias, so each VM
    keeps its own saved server in OpenCode Desktop.
.PARAMETER RemotePort
    Port of the OpenCode service on the VM. Without it, the port is read from the running service.
.PARAMETER CheckOnly
    Performs a bounded connection check without generating a pairing link or changing the clipboard.
.PARAMETER NoPause
    Skips the final "press Enter" prompt that keeps the window open after the connection ends.
.NOTES
    Author: Marvin Fenßel
    Created: 10.11.2026
    Changelog: 10.11.2026 - Select the VM from the SSH configuration instead of a fixed host.
    Changelog: 10.11.2026 - Support Linux VMs next to Windows VMs.
    Changelog: 10.11.2026 - Show instructions and pause at the end for Start menu launches.
    Changelog: 13.11.2026 - Read the service port from the VM; Linux VMs use a port per user.
#>
[CmdletBinding()]
param(
    [string]$HostName,
    [ValidateRange(1024, 65535)]
    [int]$LocalPort,
    [ValidateRange(1024, 65535)]
    [int]$RemotePort,
    [switch]$CheckOnly,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$failed = $false
. (Join-Path -Path $PSScriptRoot -ChildPath 'OpenCodeVmCommon.ps1')

$sshProcess = $null
$processStarted = $false
$pairingLink = $null

try {
    $sshTarget = Resolve-SshHostAlias -HostName $HostName
    if (-not $PSBoundParameters.ContainsKey('LocalPort')) {
        $LocalPort = Get-TunnelLocalPort -Alias $sshTarget
    }
    $baseUrl = "http://127.0.0.1:$LocalPort"
    if (-not (Test-LocalTunnelPort -Port $LocalPort)) {
        throw "Local port $LocalPort is unavailable. Close an existing tunnel to $sshTarget or pass -LocalPort."
    }

    Write-Host "Pruefe $sshTarget ..."
    $remoteOs = Get-RemoteHostOs -Target $sshTarget
    if (-not $PSBoundParameters.ContainsKey('RemotePort')) {
        $RemotePort = Get-RemoteServicePort -Target $sshTarget -Os $remoteOs
    }
    $mode = if ($CheckOnly) { 'Check' } else { 'Pair' }
    $remoteCommand = Get-RemoteSessionCommand -Os $remoteOs -Mode $mode -RemotePort $RemotePort -LocalPort $LocalPort
    $forward = "127.0.0.1:${LocalPort}:127.0.0.1:$RemotePort"

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = (Get-Command ssh.exe -CommandType Application | Select-Object -First 1).Source
    $startInfo.Arguments = '-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 ' +
        '-o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 ' +
        "-L $forward $sshTarget `"$remoteCommand`""
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    Write-Host "Verbinde mit $sshTarget ($remoteOs) ..."
    $sshProcess = New-Object System.Diagnostics.Process
    $sshProcess.StartInfo = $startInfo
    [void]$sshProcess.Start()
    $processStarted = $true
    # Drain diagnostics privately so a full stderr pipe cannot block the connection.
    $diagnostics = $sshProcess.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    $ready = $false
    $pairPattern = '^OPENCODE_PAIR=(http://127\.0\.0\.1:' + $LocalPort + '/auth/connect/[A-Za-z0-9_-]+)$'
    $readLine = $sshProcess.StandardOutput.ReadLineAsync()
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not $readLine.Wait(1000)) { continue }
        $line = $readLine.Result
        if ($null -eq $line) { break }
        if ($CheckOnly -and $line -match '^OPENCODE_READY=([0-9][0-9A-Za-z.+-]*)$') {
            $remoteVersion = $Matches[1]
            $ready = $true
            break
        }
        if (-not $CheckOnly -and $line -match $pairPattern) {
            $pairingLink = $Matches[1]
            $ready = $true
            break
        }
        $readLine = $sshProcess.StandardOutput.ReadLineAsync()
    }
    if (-not $ready) {
        throw "$sshTarget did not become ready. Check that OpenCode is installed there and listens on port $RemotePort (-RemotePort)."
    }

    # The unauthenticated forwarded endpoint must remain password-protected.
    if (-not (Test-TunnelAuthChallenge -Port $LocalPort)) {
        throw 'The forwarded server did not return the expected authentication challenge.'
    }

    if ($CheckOnly) {
        Write-Host "Tunnel OK: $baseUrl -> $sshTarget, OpenCode $remoteVersion, authentication required."
    } else {
        Set-Clipboard -Value $pairingLink
        Write-Host ''
        Write-Host "Tunnel aktiv: $baseUrl -> $sshTarget" -ForegroundColor Green
        Write-Host ''
        Write-Host 'Anleitung' -ForegroundColor Cyan
        Write-Host '  1. Der einmalige Kopplungslink liegt in der Zwischenablage (5 Minuten gueltig).'
        Write-Host '  2. In OpenCode Desktop: Server hinzufuegen (nicht "SSH-Server") waehlen.'
        Write-Host '  3. Den Link mit Strg+V einfuegen.'
        Write-Host "  4. Als Namen $sshTarget eintragen und verbinden."
        Write-Host ''
        Write-Host 'Beim naechsten Mal: dieses Programm starten und den gespeicherten Server waehlen.'
        Write-Host 'Dieses Fenster waehrend der Nutzung offen lassen. Strg+C beendet die Verbindung.'
        while (-not $sshProcess.HasExited) {
            Start-Sleep -Seconds 2
        }
        throw 'The SSH tunnel disconnected. Start the script again to reconnect.'
    }
} catch {
    $failed = $true
    Write-Host ''
    Write-Host "Fehler: $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if ($sshProcess) {
        if ($processStarted -and -not $sshProcess.HasExited) {
            if ($sshProcess.StandardInput) {
                $sshProcess.StandardInput.Close()
            }
            if (-not $sshProcess.WaitForExit(10000)) {
                $sshProcess.Kill()
                [void]$sshProcess.WaitForExit(5000)
            }
        }
        $sshProcess.Dispose()
    }
    if ($pairingLink) {
        try {
            if ((Get-Clipboard -Raw) -ceq $pairingLink) {
                Set-Clipboard -Value ([string]::Empty)
            }
        } catch {
            # Clipboard cleanup must not prevent tunnel cleanup or replace the original error.
        }
    }
}

# The window of a Start menu launch closes with the script, so wait before the message disappears.
if (-not $CheckOnly -and -not $NoPause -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
    Write-Host ''
    [void](Read-Host 'Enter druecken zum Schliessen')
}
if ($failed) {
    exit 1
}
