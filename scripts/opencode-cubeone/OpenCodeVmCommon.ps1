<#
.SYNOPSIS
    Shared helpers for the OpenCode VM tunnel scripts.
.DESCRIPTION
    Dot-sourced by Start-OpenCodeWindowsVm.ps1 and Maintain-OpenCodeWindowsVm.ps1. Reads the host
    aliases of the current user's SSH configuration, lets the user choose one, derives a stable
    loopback port per alias, and checks the forwarded endpoint. Defines functions only; it neither
    connects anywhere nor reads credentials.
.NOTES
    Author: Marvin Fenßel
    Created: 10.11.2026
    Changelog: 10.11.2026 - Initial implementation, shared by the tunnel scripts.
    Changelog: 10.11.2026 - Detect Linux and Windows VMs and build their remote session scripts.
#>

# Aliases that were paired before the port was derived from the alias keep their original port.
$script:LegacyTunnelPorts = @{
    'coding-vm-win-1' = 42894
}


function Get-SshHostAlias {
    <#
    .SYNOPSIS
        Returns the concrete host aliases from the user's SSH configuration.
    .DESCRIPTION
        Wildcard and negated patterns are skipped, as are names that are not safe to pass on a
        command line. Include directives are not followed.
    .PARAMETER ConfigPath
        SSH configuration file. Defaults to the current user's ~/.ssh/config.
    .NOTES
        Author: Marvin Fenßel
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]$ConfigPath = (Join-Path -Path $HOME -ChildPath '.ssh\config')
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return [string[]]@()
    }
    $aliases = foreach ($line in [System.IO.File]::ReadAllLines($ConfigPath)) {
        $text = ($line -replace '\s+#.*$', '').Trim()
        if ($text -match '^(?i)Host\s+(.+)$') {
            foreach ($token in ($Matches[1] -split '\s+')) {
                if ($token -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { $token }
            }
        }
    }
    return [string[]]@($aliases | Select-Object -Unique)
}


function Select-SshHostAlias {
    <#
    .SYNOPSIS
        Asks the user which SSH host alias to use.
    .PARAMETER Alias
        The candidate aliases. A single candidate is chosen without asking.
    .NOTES
        Author: Marvin Fenßel
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]]$Alias
    )

    if ($Alias.Count -eq 1) {
        return $Alias[0]
    }
    Write-Host 'Welche VM soll gekoppelt werden?'
    for ($index = 0; $index -lt $Alias.Count; $index++) {
        Write-Host ('  {0,2}) {1}' -f ($index + 1), $Alias[$index])
    }
    while ($true) {
        $answer = (Read-Host 'Nummer eingeben (leer = Abbruch)').Trim()
        if (-not $answer) {
            throw 'Abgebrochen.'
        }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Alias.Count) {
            return $Alias[$number - 1]
        }
        Write-Host 'Ungueltige Eingabe.'
    }
}


function Resolve-SshHostAlias {
    <#
    .SYNOPSIS
        Returns the requested alias, or lets the user choose one from the SSH configuration.
    .PARAMETER HostName
        Explicit alias. When given, no menu is shown.
    .NOTES
        Author: Marvin Fenßel
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$HostName)

    if ($HostName) {
        if ($HostName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
            throw 'The host name is not a valid SSH host alias.'
        }
        return $HostName
    }
    $aliases = Get-SshHostAlias
    if (-not $aliases) {
        throw 'No host entries were found in ~/.ssh/config. Pass -HostName to name the VM.'
    }
    return Select-SshHostAlias -Alias $aliases
}


function Get-TunnelLocalPort {
    <#
    .SYNOPSIS
        Returns the stable loopback port for a host alias.
    .DESCRIPTION
        OpenCode Desktop stores each paired server by URL, so every VM needs its own port that
        stays the same between runs. The port is derived from the alias (42000-43999).
    .PARAMETER Alias
        The SSH host alias.
    .NOTES
        Author: Marvin Fenßel
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$Alias
    )

    $key = $Alias.ToLowerInvariant()
    if ($script:LegacyTunnelPorts.ContainsKey($key)) {
        return [int]$script:LegacyTunnelPorts[$key]
    }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($key))
    } finally {
        $sha256.Dispose()
    }
    return 42000 + ([System.BitConverter]::ToUInt32($hash, 0) % 2000)
}


function Test-LocalTunnelPort {
    <#
    .SYNOPSIS
        Checks whether the loopback port can be reserved exclusively.
    .PARAMETER Port
        The loopback port.
    .NOTES
        Author: Marvin Fenßel
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([int]$Port)

    $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), $Port
    try {
        $listener.Server.ExclusiveAddressUse = $true
        $listener.Start()
        $true
    } catch {
        $false
    } finally {
        $listener.Stop()
    }
}


function Test-TunnelAuthChallenge {
    <#
    .SYNOPSIS
        Checks that the forwarded OpenCode server still requires authentication.
    .PARAMETER Port
        The local loopback port of the tunnel.
    .NOTES
        Author: Marvin Fenßel
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([int]$Port)

    $request = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/api/info")
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
    return ($httpStatus -eq 401)
}


function Get-RemoteHostOs {
    <#
    .SYNOPSIS
        Detects whether an SSH host is a Linux or a Windows machine.
    .DESCRIPTION
        Runs "uname -s" once. Linux answers "Linux"; the default Windows shell does not know the
        command. A failed connection (exit code 255) is an error and never guessed as Windows.
    .PARAMETER Target
        The SSH host alias.
    .NOTES
        Author: Marvin Fenßel
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Target
    )

    $process = New-Object System.Diagnostics.Process
    $started = $false
    try {
        $process.StartInfo.FileName = (Get-Command ssh.exe -CommandType Application | Select-Object -First 1).Source
        $process.StartInfo.Arguments = '-o BatchMode=yes -o StrictHostKeyChecking=accept-new ' +
            "-o ConnectTimeout=10 $Target uname -s"
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardInput = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        [void]$process.Start()
        $started = $true
        $process.StandardInput.Close()
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            throw "The SSH connection to $Target timed out."
        }
        [void]$output.Wait(1000)
        [void]$errors.Wait(1000)
        $text = if ($output.IsCompleted) { $output.Result.Trim() } else { '' }
        if ($process.ExitCode -eq 255) {
            throw "Could not connect to $Target. Check the SSH configuration and key."
        }
        if ($process.ExitCode -eq 0 -and $text -ceq 'Linux') { return 'Linux' }
        if ($process.ExitCode -ne 0 -or $text -match '^(MINGW|MSYS|CYGWIN)') { return 'Windows' }
        throw "$Target is neither a Linux nor a Windows VM."
    } finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
}


function Get-RemoteSessionCommand {
    <#
    .SYNOPSIS
        Builds the command line that starts OpenCode on the VM and keeps the SSH session open.
    .DESCRIPTION
        The remote script starts the OpenCode service, checks that it listens on the expected
        loopback port and prints one marker line: OPENCODE_READY=<version> (Check),
        OPENCODE_PAIR=<link> (Pair) or OPENCODE_TUNNEL_READY (Tunnel). It then waits for its input
        to close, which ends the service session together with the SSH connection. The script is
        sent encoded, so no quoting of its content reaches the remote shell. The returned command
        is meant to be placed between double quotes on the ssh.exe command line.
    .PARAMETER Os
        Operating system of the VM, from Get-RemoteHostOs.
    .PARAMETER Mode
        Check, Pair, Tunnel or Port. Port only prints OPENCODE_PORT=<port> of the running service
        and ends without waiting.
    .PARAMETER RemotePort
        Port of the OpenCode service on the VM.
    .PARAMETER LocalPort
        Loopback port of the tunnel; used for the pairing link.
    .NOTES
        Author: Marvin Fenßel
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Linux', 'Windows')]
        [string]$Os,
        [Parameter(Mandatory)]
        [ValidateSet('Check', 'Pair', 'Tunnel', 'Port')]
        [string]$Mode,
        [Parameter(Mandatory)]
        [int]$RemotePort,
        [Parameter(Mandatory)]
        [int]$LocalPort
    )

    if ($Os -eq 'Windows') {
        $script = @'
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
    if ($LASTEXITCODE -ne 0) { throw 'address' }
    if ('__MODE__' -eq 'Port') {
        $portMatch = [regex]::Match($statusOutput, '^http://127\.0\.0\.1:([0-9]+)$')
        if (-not $portMatch.Success) { throw 'address' }
        [Console]::Out.WriteLine('OPENCODE_PORT=' + $portMatch.Groups[1].Value)
        [Console]::Out.Flush()
        exit 0
    }
    if ($statusOutput -ne 'http://127.0.0.1:__REMOTE_PORT__') { throw 'address' }
    if ('__MODE__' -eq 'Tunnel') {
        [Console]::Out.WriteLine('OPENCODE_TUNNEL_READY')
    } else {
        $infoOutput = & opencode api get /api/info 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'health' }
        $info = ($infoOutput | Out-String) | ConvertFrom-Json
        if (-not $info.version) { throw 'version' }
        if ('__MODE__' -eq 'Check') {
            [Console]::Out.WriteLine('OPENCODE_READY=' + $info.version)
        } else {
            $pairOutput = (& opencode pair --url http://127.0.0.1:__LOCAL_PORT__ 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) { throw 'pairing' }
            $match = [regex]::Match($pairOutput, 'http://127\.0\.0\.1:__LOCAL_PORT__/auth/connect/[A-Za-z0-9_-]+')
            if (-not $match.Success) { throw 'pairing' }
            [Console]::Out.WriteLine('OPENCODE_PAIR=' + $match.Value)
        }
    }
    [Console]::Out.Flush()
    # Closing the local control pipe ends the SSH session and its Windows job cleanly.
    [void][Console]::In.ReadLine()
} catch {
    [Console]::Error.WriteLine('OpenCode startup or pairing failed on the Windows VM.')
    exit 1
}
'@
    } else {
        $script = @'
export OPENCODE_DISABLE_FREE_MODELS=1
export PATH="$HOME/.opencode/bin:$HOME/.local/bin:/usr/local/bin:$PATH"
fail() { echo 'OpenCode startup or pairing failed on the Linux VM.' >&2; exit 1; }
opencode service start >/dev/null 2>&1 || fail
status=$(opencode service status 2>/dev/null) || fail
if [ '__MODE__' = 'Port' ]; then
    port=${status#http://127.0.0.1:}
    case "$port" in ''|*[!0-9]*) fail ;; esac
    [ "$status" = "http://127.0.0.1:$port" ] || fail
    echo "OPENCODE_PORT=$port"
    exit 0
fi
[ "$status" = 'http://127.0.0.1:__REMOTE_PORT__' ] || fail
if [ '__MODE__' = 'Tunnel' ]; then
    echo OPENCODE_TUNNEL_READY
else
    info=$(opencode api get /api/info 2>/dev/null) || fail
    version=$(printf '%s' "$info" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9][0-9A-Za-z.+-]*\)".*/\1/p' | head -n 1)
    [ -n "$version" ] || fail
    if [ '__MODE__' = 'Check' ]; then
        echo "OPENCODE_READY=$version"
    else
        pair=$(opencode pair --url http://127.0.0.1:__LOCAL_PORT__ 2>&1) || fail
        link=$(printf '%s\n' "$pair" | grep -Eo 'http://127\.0\.0\.1:__LOCAL_PORT__/auth/connect/[A-Za-z0-9_-]+' | head -n 1)
        [ -n "$link" ] || fail
        echo "OPENCODE_PAIR=$link"
    fi
fi
# Closing the local control pipe ends this read and with it the SSH session.
read -r _line || true
'@
        $script = $script -replace "`r`n", "`n"
    }
    $script = $script.Replace('__MODE__', $Mode).Replace('__REMOTE_PORT__', $RemotePort.ToString())
    $script = $script.Replace('__LOCAL_PORT__', $LocalPort.ToString())

    if ($Os -eq 'Windows') {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        return 'powershell.exe -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand ' + $encoded
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
    return 'sh -c \"$(printf %s ' + $encoded + ' | base64 -d)\"'
}


function Get-RemoteServicePort {
    <#
    .SYNOPSIS
        Starts the OpenCode service on the VM and returns the loopback port it listens on.
    .DESCRIPTION
        The port differs per VM and user (Linux VMs assign one per principal), so it is read from
        "opencode service status" instead of being assumed.
    .PARAMETER Target
        The SSH host alias.
    .PARAMETER Os
        Operating system of the VM, from Get-RemoteHostOs.
    .NOTES
        Author: Marvin Fenßel
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string]$Target,
        [Parameter(Mandatory)]
        [ValidateSet('Linux', 'Windows')]
        [string]$Os
    )

    $remoteCommand = Get-RemoteSessionCommand -Os $Os -Mode Port -RemotePort 0 -LocalPort 0
    $process = New-Object System.Diagnostics.Process
    $started = $false
    try {
        $process.StartInfo.FileName = (Get-Command ssh.exe -CommandType Application | Select-Object -First 1).Source
        $process.StartInfo.Arguments = '-o BatchMode=yes -o StrictHostKeyChecking=accept-new ' +
            "-o ConnectTimeout=10 $Target `"$remoteCommand`""
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardInput = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        [void]$process.Start()
        $started = $true
        $process.StandardInput.Close()
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            throw "Reading the OpenCode port on $Target timed out."
        }
        [void]$output.Wait(1000)
        $text = if ($output.IsCompleted) { $output.Result } else { '' }
        $match = [regex]::Match($text, '(?m)^OPENCODE_PORT=([0-9]{4,5})\r?$')
        if ($process.ExitCode -ne 0 -or -not $match.Success) {
            throw "Could not read the OpenCode service port on $Target. Check that OpenCode is installed there."
        }
        return [int]$match.Groups[1].Value
    } finally {
        if ($started -and -not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
}