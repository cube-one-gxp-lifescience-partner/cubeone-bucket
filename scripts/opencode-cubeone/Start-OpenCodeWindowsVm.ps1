<#
.SYNOPSIS
    Connects the Windows coding VM to OpenCode Desktop through a loopback-only SSH tunnel.
.DESCRIPTION
    Starts the VM's existing OpenCode service and keeps its SSH session alive. The one-time pairing
    link is copied to the local clipboard without printing or persisting credentials. Keep this
    terminal open while using the connection. Existing SSH configuration supplies the user and key.
.PARAMETER CheckOnly
    Performs a bounded connection check without generating a pairing link or changing the clipboard.
.NOTES
    Author: Marvin Fenßel
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$sshTarget = 'coding-vm-win-1'
$localPort = 42894
$remotePort = 28894
$baseUrl = "http://127.0.0.1:$localPort"
$sshProcess = $null
$processStarted = $false
$pairingLink = $null
$listener = $null

try {
    $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), $localPort
    $listener.Server.ExclusiveAddressUse = $true
    try {
        $listener.Start()
    } catch {
        throw "Local port $localPort is unavailable. Close an existing Windows-VM tunnel and try again."
    } finally {
        $listener.Stop()
    }

    $remoteScript = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
    [Environment]::GetEnvironmentVariable('PATH', 'User')
$env:OPENCODE_DISABLE_FREE_MODELS = '1'
try {
    $startupOutput = & opencode service start 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'startup' }
    $statusOutput = (& opencode service status 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $statusOutput -ne 'http://127.0.0.1:28894') { throw 'address' }
    $infoOutput = & opencode api get /api/info 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'health' }
    $info = ($infoOutput | Out-String) | ConvertFrom-Json
    if (-not $info.version) { throw 'version' }

    if ('__CHECK_ONLY__' -eq 'true') {
        [Console]::Out.WriteLine('OPENCODE_READY=' + $info.version)
    } else {
        $pairOutput = (& opencode pair --url http://127.0.0.1:42894 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { throw 'pairing' }
        $match = [regex]::Match($pairOutput, 'http://127\.0\.0\.1:42894/auth/connect/[A-Za-z0-9_-]+')
        if (-not $match.Success) { throw 'pairing' }
        [Console]::Out.WriteLine('OPENCODE_PAIR=' + $match.Value)
    }
    [Console]::Out.Flush()
    # Closing the local control pipe ends the SSH session and its Windows job cleanly.
    [void][Console]::In.ReadLine()
} catch {
    [Console]::Error.WriteLine('OpenCode startup or pairing failed on the Windows VM.')
    exit 1
}
'@
    $remoteScript = $remoteScript.Replace('__CHECK_ONLY__', $CheckOnly.IsPresent.ToString().ToLowerInvariant())
    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remoteScript))
    $forward = "127.0.0.1:${localPort}:127.0.0.1:$remotePort"
    $remoteCommand = 'powershell.exe -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand ' +
        $encodedScript

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

    Write-Host 'Verbinde mit coding-vm-win-1 ...'
    $sshProcess = New-Object System.Diagnostics.Process
    $sshProcess.StartInfo = $startInfo
    [void]$sshProcess.Start()
    $processStarted = $true
    # Drain diagnostics privately so a full stderr pipe cannot block the connection.
    $diagnostics = $sshProcess.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    $ready = $false
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
        $pairPattern = '^OPENCODE_PAIR=(http://127\.0\.0\.1:42894/auth/connect/[A-Za-z0-9_-]+)$'
        if (-not $CheckOnly -and $line -match $pairPattern) {
            $pairingLink = $Matches[1]
            $ready = $true
            break
        }
        $readLine = $sshProcess.StandardOutput.ReadLineAsync()
    }
    if (-not $ready) {
        throw 'The VM did not become ready. Check SSH connectivity and the OpenCode installation on the VM.'
    }

    # The unauthenticated forwarded endpoint must remain password-protected.
    $request = [System.Net.HttpWebRequest]::Create("$baseUrl/api/info")
    $request.Proxy = $null
    $request.Timeout = 5000
    $request.AllowAutoRedirect = $false
    $httpStatus = $null
    try {
        $response = $request.GetResponse()
        $httpStatus = [int]$response.StatusCode
        $response.Close()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $httpStatus = [int]$_.Exception.Response.StatusCode
            $_.Exception.Response.Close()
        }
    }
    if ($httpStatus -ne 401) {
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
        Write-Host 'Als Namen coding-vm-win-1 (Windows VM) eintragen, dann verbinden.'
        Write-Host 'Spaeter reicht es, diesen Tunnel zu starten und den gespeicherten Server auszuwaehlen.'
        Write-Host 'Dieses Fenster waehrend der Nutzung offen lassen. Strg+C beendet die Verbindung.'
        while (-not $sshProcess.HasExited) {
            Start-Sleep -Seconds 2
        }
        throw 'The SSH tunnel disconnected. Start the shortcut again to reconnect.'
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
