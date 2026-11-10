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
    Port of the OpenCode service on the VM.
.PARAMETER CheckOnly
    Performs a bounded connection check without generating a pairing link or changing the clipboard.
.NOTES
    Author: Marvin Fenßel
    Created: 10.11.2026
    Changelog: 10.11.2026 - Select the VM from the SSH configuration instead of a fixed host.
    Changelog: 10.11.2026 - Support Linux VMs next to Windows VMs.
#>
[CmdletBinding()]
param(
    [string]$HostName,
    [ValidateRange(1024, 65535)]
    [int]$LocalPort,
    [ValidateRange(1024, 65535)]
    [int]$RemotePort = 28894,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
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
        Write-Host "Tunnel aktiv: $baseUrl -> $sshTarget"
        Write-Host 'Der einmalige Kopplungslink liegt in der Zwischenablage (5 Minuten gueltig).'
        Write-Host 'In OpenCode: Server hinzufuegen (nicht SSH-Server) -> Link einfuegen.'
        Write-Host "Als Namen $sshTarget eintragen, dann verbinden."
        Write-Host 'Spaeter reicht es, diesen Tunnel zu starten und den gespeicherten Server auszuwaehlen.'
        Write-Host 'Dieses Fenster waehrend der Nutzung offen lassen. Strg+C beendet die Verbindung.'
        while (-not $sshProcess.HasExited) {
            Start-Sleep -Seconds 2
        }
        throw 'The SSH tunnel disconnected. Start the script again to reconnect.'
    }
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
