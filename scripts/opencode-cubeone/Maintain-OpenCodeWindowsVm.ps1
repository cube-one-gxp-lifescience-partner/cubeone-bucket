<#
.SYNOPSIS
    Maintains the current user's loopback SSH connection to a Windows or Linux coding VM.
.DESCRIPTION
    Runs in the foreground, using the VM's existing SSH configuration. The VM is chosen from the
    host aliases in ~/.ssh/config unless -HostName is given. The SSH session keeps the remote
    service alive and is retried after a disconnect, with a 10-second backoff. An occupied local
    port or extra forwards in SSH configuration are left untouched and retried. Stop the supervisor
    to close its tunnel. It does not install a task, start a background supervisor, or generate a
    pairing link. The operating system of the VM is detected over SSH. Run as the already-paired
    Desktop user, not as SYSTEM.
.PARAMETER HostName
    SSH host alias of the VM. Without it, the aliases from ~/.ssh/config are offered for selection.
.PARAMETER LocalPort
    Loopback port of the tunnel. Defaults to the stable port derived from the host alias, the same
    one Start-OpenCodeWindowsVm.ps1 uses.
.PARAMETER RemotePort
    Port of the OpenCode service on the VM. Without it, the port is read from the running service.
.PARAMETER CheckOnly
    Makes one bounded attempt, checks for an HTTP 401 on the forwarded endpoint, and closes the tunnel.
.NOTES
    Author: Marvin Fenßel
    Created: 10.11.2026
    Changelog: 10.11.2026 - Initial implementation, VM selected from the SSH configuration.
    Changelog: 10.11.2026 - Support Linux VMs next to Windows VMs.
    Changelog: 13.11.2026 - Read the service port from the VM when -RemotePort is not given.
#>
[CmdletBinding()]
param(
    [string]$HostName,
    [ValidateRange(1024, 65535)]
    [int]$LocalPort,
    [ValidateRange(1024, 65535)]
    [int]$RemotePort,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'OpenCodeVmCommon.ps1')


function Test-SshForwardConfiguration {
    <#
    .SYNOPSIS
        Rejects additional forwards in the effective SSH configuration without displaying it.
    .PARAMETER SshPath
        Path of ssh.exe.
    .PARAMETER SshOptions
        The fixed SSH options of the tunnel.
    .PARAMETER Target
        The SSH host alias.
    .NOTES
        Author: Marvin Fenßel
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$SshPath, [string]$SshOptions, [string]$Target)

    $process = New-Object System.Diagnostics.Process
    $started = $false
    try {
        $process.StartInfo.FileName = $SshPath
        $process.StartInfo.Arguments = "-G $SshOptions $Target"
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        [void]$process.Start()
        $started = $true
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) { return $false }
        if (-not $output.Wait(1000) -or -not $errors.Wait(1000)) { return $false }
        $hasAdditionalForwards = $output.Result -match '(?im)^(localforward|remoteforward|dynamicforward)\s'
        return ($process.ExitCode -eq 0 -and -not $hasAdditionalForwards)
    } finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
}


function Invoke-WindowsVmTunnel {
    <#
    .SYNOPSIS
        Runs one SSH session and optionally verifies its forwarded authentication challenge.
    .PARAMETER SshPath
        Path of ssh.exe.
    .PARAMETER SshOptions
        The fixed SSH options of the tunnel.
    .PARAMETER Target
        The SSH host alias.
    .PARAMETER Os
        Operating system of the VM.
    .PARAMETER LocalPort
        Loopback port of the tunnel.
    .PARAMETER RemotePort
        Port of the OpenCode service on the VM.
    .PARAMETER CheckOnly
        Verifies the authentication challenge once and returns.
    .PARAMETER StartupTimeoutSeconds
        How long the VM may take to report readiness.
    .NOTES
        Author: Marvin Fenßel
    #>
    [CmdletBinding()]
    param(
        [string]$SshPath,
        [string]$SshOptions,
        [string]$Target,
        [ValidateSet('Linux', 'Windows')]
        [string]$Os,
        [int]$LocalPort,
        [int]$RemotePort,
        [switch]$CheckOnly,
        [int]$StartupTimeoutSeconds = 90
    )

    $remoteCommand = Get-RemoteSessionCommand -Os $Os -Mode Tunnel -RemotePort $RemotePort -LocalPort $LocalPort
    $forward = "127.0.0.1:${LocalPort}:127.0.0.1:$RemotePort"
    $process = New-Object System.Diagnostics.Process
    $started = $false
    try {
        $process.StartInfo.FileName = $SshPath
        $process.StartInfo.Arguments = "$SshOptions -L $forward $Target `"$remoteCommand`""
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardInput = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        [void]$process.Start()
        $started = $true
        $stdout = $process.StandardOutput.ReadLineAsync()
        $stderr = $process.StandardError.ReadLineAsync()
        $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
        $ready = $false
        while (-not $process.HasExited) {
            # Drain both streams without publishing their contents or retaining the whole output.
            if ($stdout -and $stdout.IsCompleted) {
                $line = $stdout.Result
                $stdout = $null
                if ($null -ne $line) {
                    if ($line -ceq 'OPENCODE_TUNNEL_READY') { $ready = $true }
                    $stdout = $process.StandardOutput.ReadLineAsync()
                }
            }
            if ($stderr -and $stderr.IsCompleted) {
                $line = $stderr.Result
                $stderr = $null
                if ($null -ne $line) { $stderr = $process.StandardError.ReadLineAsync() }
            }
            if (-not $ready -and [DateTime]::UtcNow -ge $deadline) {
                throw 'The Windows VM tunnel startup timed out.'
            }
            if ($ready -and $CheckOnly) {
                if (-not (Test-TunnelAuthChallenge -Port $LocalPort) -or $process.HasExited) {
                    throw 'The Windows VM tunnel did not return the expected authentication challenge.'
                }
                return
            }
            if (($stdout -and $stdout.IsCompleted) -or ($stderr -and $stderr.IsCompleted)) { continue }
            [void]$process.WaitForExit(200)
        }
        throw 'The Windows VM SSH session ended.'
    } finally {
        if ($started -and -not $process.HasExited) {
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(5000)) {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            }
        }
        $process.Dispose()
    }
}


function Invoke-WindowsVmSupervisor {
    <#
    .SYNOPSIS
        Retries the current user's tunnel after failures until the supervisor is stopped.
    .PARAMETER Target
        The SSH host alias of the VM.
    .PARAMETER LocalPort
        Loopback port of the tunnel.
    .PARAMETER RemotePort
        Port of the OpenCode service on the VM.
    .PARAMETER CheckOnly
        Performs one attempt and reports success only after the HTTP authentication check.
    .NOTES
        Author: Marvin Fenßel
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Target,
        [int]$LocalPort,
        [int]$RemotePort,
        [switch]$CheckOnly
    )

    $retrySeconds = 10
    $sshOptions = '-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 ' +
        '-o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 ' +
        '-o ClearAllForwardings=no -o ForkAfterAuthentication=no -o StdinNull=no ' +
        '-o ControlMaster=no -o ControlPath=none -o RequestTTY=no -o RemoteCommand=none ' +
        '-o GatewayPorts=no -o Tunnel=no -o PermitLocalCommand=no -o ForwardAgent=no -o ForwardX11=no'
    while ($true) {
        try {
            if (-not (Test-LocalTunnelPort -Port $LocalPort)) { throw 'Local tunnel port is unavailable.' }
            $sshPath = (Get-Command -Name 'ssh.exe' -CommandType Application | Select-Object -First 1).Source
            if (-not (Test-SshForwardConfiguration -SshPath $sshPath -SshOptions $sshOptions -Target $Target)) {
                throw 'SSH configuration check failed or contains additional forwards.'
            }
            $remoteOs = Get-RemoteHostOs -Target $Target
            $servicePort = if ($RemotePort -gt 0) { $RemotePort } else {
                Get-RemoteServicePort -Target $Target -Os $remoteOs
            }
            $connection = @{
                SshPath    = $sshPath
                SshOptions = $sshOptions
                Target     = $Target
                Os         = $remoteOs
                LocalPort  = $LocalPort
                RemotePort = $servicePort
                CheckOnly  = $CheckOnly
            }
            Invoke-WindowsVmTunnel @connection
            if ($CheckOnly) {
                Write-Output 'Windows VM tunnel check succeeded; authentication is required.'
                return
            }
        } catch {
            if ($CheckOnly) { throw 'Windows VM tunnel check failed; no SSH output is displayed.' }
            Write-Warning "Tunnel to $Target unavailable or disconnected; retrying in $retrySeconds seconds."
        }
        Start-Sleep -Seconds $retrySeconds
    }
}


$target = Resolve-SshHostAlias -HostName $HostName
if (-not $PSBoundParameters.ContainsKey('LocalPort')) {
    $LocalPort = Get-TunnelLocalPort -Alias $target
}
Invoke-WindowsVmSupervisor -Target $target -LocalPort $LocalPort -RemotePort $RemotePort -CheckOnly:$CheckOnly
