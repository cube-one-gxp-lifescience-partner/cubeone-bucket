<#
.SYNOPSIS
    Regression tests for the shared OpenCode VM tunnel helpers.

.DESCRIPTION
    Dot-sources OpenCodeVmCommon.ps1 and exercises the SSH host alias parsing, the host menu, the
    per-alias loopback port, the port reservation check and the authentication challenge check.
    Uses synthetic SSH configurations in a temporary directory and loopback listeners only. No SSH
    connection, key, clipboard or OpenCode service is touched. Runs on Windows PowerShell 5.1 and
    PowerShell 7 without additional modules. Exits 1 if any case fails.

.NOTES
    Author:     Marvin Fenßel
    Created:    10.11.2026
    Changelog:  10.11.2026 - Added tests for the shared tunnel helpers.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $scriptRoot 'OpenCodeVmCommon.ps1')

$testRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'Temp\opencode') (
    'vm-common-test-' + [guid]::NewGuid().ToString('N')
)
$passed = 0
$failed = 0


function Invoke-Case {
    [CmdletBinding()]
    param([string]$Name, [scriptblock]$Body)

    try {
        & $Body
        $script:passed++
        Write-Output "PASS $Name"
    } catch {
        $caseError = $_
        $script:failed++
        Write-Output "FAIL $Name :: $($caseError.Exception.Message)"
    }
}


function Get-FreePort {
    [CmdletBinding()]
    param()

    $probe = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 0
    try {
        $probe.Start()
        return ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
    } finally {
        $probe.Stop()
    }
}


function Start-StatusServer {
    [CmdletBinding()]
    param([int]$Port, [int]$StatusCode)

    $shell = [powershell]::Create()
    [void]$shell.AddScript({
        param($Port, $StatusCode)
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://127.0.0.1:$Port/")
        $listener.Start()
        try {
            $context = $listener.GetContext()
            $context.Response.StatusCode = $StatusCode
            $context.Response.Close()
        } finally {
            $listener.Stop()
        }
    }).AddArgument($Port).AddArgument($StatusCode)
    $handle = $shell.BeginInvoke()
    Start-Sleep -Milliseconds 500
    return [pscustomobject]@{ Shell = $shell; Handle = $handle }
}


function Stop-StatusServer {
    [CmdletBinding()]
    param($Server)

    try {
        if ($Server.Handle.IsCompleted) { $Server.Shell.EndInvoke($Server.Handle) }
        else { $Server.Shell.Stop() }
    } finally {
        $Server.Shell.Dispose()
    }
}


try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $configPath = Join-Path $testRoot 'ssh config'
    $configLines = @(
        '# Host commented-out',
        'Include other.conf',
        'Host coding-vm-win-1',
        '    HostName 192.0.2.10',
        'Host coding-vm-1 coding-vm-2   # trailing comment',
        'host lower.case.example',
        'Host *',
        'Host dev-* !dev-skip',
        'Host -oProxyCommand=evil',
        'Host coding-vm-1',
        '    User example'
    )
    [System.IO.File]::WriteAllLines($configPath, $configLines, (New-Object System.Text.UTF8Encoding $false))

    Invoke-Case 'aliases: concrete hosts only, unique, in order' {
        $aliases = @(Get-SshHostAlias -ConfigPath $configPath)
        $expected = 'coding-vm-win-1,coding-vm-1,coding-vm-2,lower.case.example'
        if (($aliases -join ',') -cne $expected) { throw "Unexpected aliases: $($aliases -join ',')" }
    }

    Invoke-Case 'aliases: missing file yields none' {
        $aliases = @(Get-SshHostAlias -ConfigPath (Join-Path $testRoot 'absent'))
        if ($aliases.Count -ne 0) { throw 'Expected no aliases.' }
    }

    Invoke-Case 'port: legacy alias keeps 42894, case-insensitive' {
        if ((Get-TunnelLocalPort -Alias 'coding-vm-win-1') -ne 42894) { throw 'Legacy port changed.' }
        if ((Get-TunnelLocalPort -Alias 'CODING-VM-WIN-1') -ne 42894) { throw 'Legacy port is case-sensitive.' }
    }

    Invoke-Case 'port: derived ports are stable and within range' {
        foreach ($name in 'coding-vm-win-2', 'coding-vm-win-3', 'a', 'host.example.com') {
            $first = Get-TunnelLocalPort -Alias $name
            $second = Get-TunnelLocalPort -Alias $name.ToUpperInvariant()
            if ($first -ne $second) { throw "Port for $name is not stable." }
            if ($first -lt 42000 -or $first -gt 43999) { throw "Port $first for $name is out of range." }
        }
        if ((Get-TunnelLocalPort -Alias 'coding-vm-win-2') -eq (Get-TunnelLocalPort -Alias 'coding-vm-win-3')) {
            throw 'Different aliases share a port.'
        }
    }

    Invoke-Case 'resolve: explicit valid name skips the menu' {
        if ((Resolve-SshHostAlias -HostName 'coding-vm-win-9') -cne 'coding-vm-win-9') { throw 'Name changed.' }
    }

    Invoke-Case 'resolve: option-like name is rejected' {
        $message = $null
        try { Resolve-SshHostAlias -HostName '-oProxyCommand=evil' | Out-Null } catch { $message = $_.Exception.Message }
        if (-not $message) { throw 'An invalid alias was accepted.' }
    }

    Invoke-Case 'menu: single alias is chosen without asking' {
        function Read-Host { throw 'The menu must not prompt for a single alias.' }
        try {
            if ((Select-SshHostAlias -Alias @('only-one')) -cne 'only-one') { throw 'Wrong alias.' }
        } finally {
            Remove-Item Function:\Read-Host
        }
    }

    Invoke-Case 'menu: invalid input repeats, number selects' {
        $script:answers = [System.Collections.Generic.Queue[string]]::new()
        foreach ($answer in '0', 'x', '3', '2') { $script:answers.Enqueue($answer) }
        function Read-Host { param($Prompt) $script:answers.Dequeue() }
        try {
            $choice = Select-SshHostAlias -Alias @('a-vm', 'b-vm', 'c-vm') 6>$null
            if ($choice -cne 'c-vm') { throw "Expected c-vm, got $choice." }
        } finally {
            Remove-Item Function:\Read-Host
        }
    }

    Invoke-Case 'menu: empty input cancels' {
        function Read-Host { param($Prompt) '' }
        $message = $null
        try {
            Select-SshHostAlias -Alias @('a-vm', 'b-vm') 6>$null | Out-Null
        } catch {
            $message = $_.Exception.Message
        } finally {
            Remove-Item Function:\Read-Host
        }
        if (-not $message) { throw 'Empty input did not cancel.' }
    }

    Invoke-Case 'port check: free port is available, occupied port is not' {
        $port = Get-FreePort
        if (-not (Test-LocalTunnelPort -Port $port)) { throw 'A free port was reported as occupied.' }
        $holder = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), $port
        try {
            $holder.Start()
            if (Test-LocalTunnelPort -Port $port) { throw 'An occupied port was reported as free.' }
        } finally {
            $holder.Stop()
        }
    }

    Invoke-Case 'auth challenge: 401 passes' {
        $port = Get-FreePort
        $server = Start-StatusServer -Port $port -StatusCode 401
        try {
            if (-not (Test-TunnelAuthChallenge -Port $port)) { throw 'A 401 response was rejected.' }
        } finally {
            Stop-StatusServer -Server $server
        }
    }

    Invoke-Case 'auth challenge: 200 fails' {
        $port = Get-FreePort
        $server = Start-StatusServer -Port $port -StatusCode 200
        try {
            if (Test-TunnelAuthChallenge -Port $port) { throw 'An unauthenticated 200 response was accepted.' }
        } finally {
            Stop-StatusServer -Server $server
        }
    }

    Invoke-Case 'remote command (Windows): decodes to valid PowerShell with ports and mode filled in' {
        foreach ($mode in 'Check', 'Pair', 'Tunnel') {
            $command = Get-RemoteSessionCommand -Os Windows -Mode $mode -RemotePort 28894 -LocalPort 42001
            $prefix = 'powershell.exe -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand '
            if (-not $command.StartsWith($prefix)) { throw 'Unexpected Windows command prefix.' }
            $text = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($command.Substring($prefix.Length)))
            $errors = $null
            $tokens = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
            if ($errors.Count -gt 0) { throw "Parse error in $mode script: $($errors[0].Message)" }
            if ($text -match '__\w+__') { throw 'A placeholder was not replaced.' }
            if ($text -notmatch "'$mode' -eq 'Tunnel'") { throw 'The mode was not filled in.' }
            if ($text -notmatch 'http://127\.0\.0\.1:28894' -or $text -notmatch '127\\\.0\\\.0\\\.1:42001/auth') {
                throw 'The ports were not filled in.'
            }
        }
    }

    $bashPath = $null
    $gitCommand = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gitCommand) {
        $execPath = (& $gitCommand.Source --exec-path)
        $candidate = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $execPath))) 'bin\bash.exe'
        if (Test-Path -LiteralPath $candidate) { $bashPath = $candidate }
    }

    function Invoke-LinuxScript {
        [CmdletBinding()]
        param([string]$Command, [string]$StubPort)

        $encoded = [regex]::Match($Command, '^sh -c \\"\$\(printf %s ([A-Za-z0-9+/=]+) \| base64 -d\)\\"$').Groups[1].Value
        if (-not $encoded) { throw 'Unexpected Linux command shape.' }
        $script = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
        if ($script.Contains("`r")) { throw 'The Linux script contains carriage returns.' }
        if ($script -match '__\w+__') { throw 'A placeholder was not replaced.' }

        $fakeHome = Join-Path $testRoot ('home-' + [guid]::NewGuid().ToString('N'))
        $binDir = Join-Path $fakeHome '.opencode\bin'
        New-Item -ItemType Directory -Path $binDir | Out-Null
        $stub = @(
            '#!/bin/sh',
            'case "$1 $2" in',
            '  "service start") exit 0;;',
            "  `"service status`") echo http://127.0.0.1:$StubPort;;",
            '  "api get") echo "{\"version\": \"2.2.7\"}";;',
            '  "pair --url") echo "Open ${3%/}/auth/connect/abc_DEF-1 within five minutes";;',
            'esac'
        ) -join "`n"
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText((Join-Path $binDir 'opencode'), $stub + "`n", $utf8)
        $scriptFile = Join-Path $fakeHome 'remote.sh'
        [System.IO.File]::WriteAllText($scriptFile, $script, $utf8)

        $process = New-Object System.Diagnostics.Process
        try {
            $process.StartInfo.FileName = $bashPath
            $process.StartInfo.Arguments = '"' + $scriptFile + '"'
            $process.StartInfo.UseShellExecute = $false
            $process.StartInfo.CreateNoWindow = $true
            $process.StartInfo.RedirectStandardInput = $true
            $process.StartInfo.RedirectStandardOutput = $true
            $process.StartInfo.RedirectStandardError = $true
            $process.StartInfo.EnvironmentVariables['HOME'] = $fakeHome
            [void]$process.Start()
            $process.StandardInput.Close()
            $output = $process.StandardOutput.ReadToEndAsync()
            $errors = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'The Linux script did not finish.' }
            return [pscustomobject]@{
                ExitCode = $process.ExitCode
                Output   = $output.Result.Trim()
                Errors   = $errors.Result.Trim()
            }
        } finally {
            $process.Dispose()
        }
    }

    Invoke-Case 'remote command (Linux): shell script prints the marker for every mode' {
        if (-not $bashPath) { Write-Output 'SKIP no bash available'; return }
        $expected = @{
            Check  = 'OPENCODE_READY=2.2.7'
            Pair   = 'OPENCODE_PAIR=http://127.0.0.1:42001/auth/connect/abc_DEF-1'
            Tunnel = 'OPENCODE_TUNNEL_READY'
        }
        foreach ($mode in 'Check', 'Pair', 'Tunnel') {
            $command = Get-RemoteSessionCommand -Os Linux -Mode $mode -RemotePort 28894 -LocalPort 42001
            $result = Invoke-LinuxScript -Command $command -StubPort 28894
            if ($result.ExitCode -ne 0) { throw "$mode exited with $($result.ExitCode): $($result.Errors)" }
            if ($result.Output -cne $expected[$mode]) { throw "$mode printed '$($result.Output)'." }
        }
    }

    Invoke-Case 'remote command (Linux): a different service port fails without a marker' {
        if (-not $bashPath) { Write-Output 'SKIP no bash available'; return }
        $command = Get-RemoteSessionCommand -Os Linux -Mode Pair -RemotePort 28894 -LocalPort 42001
        $result = Invoke-LinuxScript -Command $command -StubPort 31000
        if ($result.ExitCode -eq 0) { throw 'A wrong service address was accepted.' }
        if ($result.Output) { throw 'A marker was printed for a wrong service address.' }
    }

    foreach ($scriptName in 'Start-OpenCodeWindowsVm.ps1', 'Maintain-OpenCodeWindowsVm.ps1') {
        Invoke-Case "$scriptName : parses and takes host and ports as parameters" {
            $errors = $null
            $tokens = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $scriptRoot $scriptName), [ref]$tokens, [ref]$errors
            )
            if ($errors.Count -gt 0) { throw "Parse error: $($errors[0].Message)" }
            $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            foreach ($required in 'HostName', 'LocalPort', 'RemotePort', 'CheckOnly') {
                if ($names -cnotcontains $required) { throw "Missing parameter $required." }
            }
            $text = [System.IO.File]::ReadAllText((Join-Path $scriptRoot $scriptName))
            if ($text -match "(?m)^\s*\`$\w+\s*=\s*'coding-vm-win-1'") { throw 'A fixed host is still assigned.' }
        }
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Output "Passed: $passed, failed: $failed"
if ($failed -gt 0) { exit 1 }
exit 0
