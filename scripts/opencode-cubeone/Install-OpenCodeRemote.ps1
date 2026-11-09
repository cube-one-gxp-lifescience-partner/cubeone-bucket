<#
.SYNOPSIS
    Installs the cube one OpenCode configuration on local WSL distros and Linux SSH hosts.

.DESCRIPTION
    The desktop app runs a separate OpenCode server for WSL and for each SSH host. That server
    reads /etc/opencode on Linux, not C:\ProgramData\opencode. This script copies the managed
    models, rules and plugins there and stores the OpenRouter key in the remote user's
    ~/.config/opencode/openrouter.key (mode 0600). The key is never printed. Package and key travel through
    a private, randomly named 0700 directory under /tmp that is removed again on success, on failure and on abort;
    the key file is replaced atomically and never written to a fixed or world-readable path.

    The script must run as the Windows user who owns -ProfilePath: ssh.exe authenticates with that user's
    key and the key file ACL. A different identity (SYSTEM, another account) stops before anything is read,
    connected or sent. Install-OpenCodeCubeOne.ps1 does not start it as that user: with -FullInstall it defers
    and prints the command to run once as the profile user.

    Besides the remote files, the run makes ssh send a personal CUBEONE_PRINCIPAL to the coding VMs (coding-vm-1 to
    coding-vm-8) through the user's existing ~\.ssh\config (a missing one is not created). What ssh would send is read
    offline with `ssh.exe -G -F <config> <alias>`, which prints settings and makes no connection. A config with
    Include or `Match exec` is not evaluated and not changed. New lines are only inserted at the start of the file;
    existing text, host keys and private keys stay as they are. -PrincipalOnly does just that and nothing else (see
    Set-OpenCodePrincipal.ps1).
#>
[CmdletBinding()]
param(
    [string]$SourceDir = $PSScriptRoot,
    [string]$ProfilePath = $env:USERPROFILE,
    [switch]$SkipWsl,
    [switch]$SkipSsh,
    # Stops after the personal id step. It no longer writes a desktop host list (see the cubeone-ssh-hosts plugin).
    [switch]$DesktopOnly,
    # Writes only the OpenRouter key from HKLM. No plugins, no desktop settings, no CLI install.
    [switch]$KeyOnly,
    # Writes only the personal CUBEONE_PRINCIPAL into the existing ~\.ssh\config. No key read, no payload, no ssh
    # connection, wsl, CLI install, plugin install or desktop host list. Only the offline `ssh.exe -G` is started.
    [switch]$PrincipalOnly,
    # Limits the SSH part to one host alias from ~/.ssh/config, for a single on-demand or background setup
    # instead of a full company-wide run.
    [string]$OnlyHost
)

$ErrorActionPreference = 'Stop'

function Get-CurrentIdentitySid {
    return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-ProfileImagePath {
    # Reads only the profile path of one SID below ProfileList. No other registry value is read.
    param([string]$Sid)
    if ($Sid -notmatch '^S-1-[0-9-]+$') { return '' }
    $regBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $regSub = $regBase.OpenSubKey("SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid")
        if (-not $regSub) { return '' }
        try {
            return [string]$regSub.GetValue('ProfileImagePath')
        } finally {
            $regSub.Close()
        }
    } finally {
        $regBase.Close()
    }
}

function Assert-ProfileUserContext {
    # ssh.exe, the key ACL and the user environment belong to the identity that runs this script. Setting HOME
    # or USERPROFILE for a child process does not change that identity, so a profile of another account is refused.
    param([string]$ProfilePath)
    $stop = "Remote OpenCode setup must run as the Windows user who owns '$ProfilePath'. It was not started: nothing was read, connected or sent."
    $currentSid = Get-CurrentIdentitySid
    if ($currentSid -eq 'S-1-5-18' -or -not $ProfilePath) { throw $stop }
    $imagePath = Get-ProfileImagePath -Sid $currentSid
    if (-not $imagePath) { throw $stop }
    $expected = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($imagePath)).TrimEnd('\')
    $actual = [System.IO.Path]::GetFullPath($ProfilePath).TrimEnd('\')
    if (-not [string]::Equals($expected, $actual, [System.StringComparison]::OrdinalIgnoreCase)) { throw $stop }
}

function Get-OpenRouterKey {
    # The key is deposited in the registry and is never printed.
    $regBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $regSub = $regBase.OpenSubKey('SOFTWARE\cubeone\OpenCode')
        if (-not $regSub) { return '' }
        try {
            $rawKey = $regSub.GetValue('OpenRouterApiKey')
            if ($null -eq $rawKey) { return '' }
            $apiKey = ([string]$rawKey).Trim()
            if ($apiKey -match "[\r\n]") { throw 'OpenRouterApiKey in HKLM\SOFTWARE\cubeone\OpenCode must be a single line.' }
            return $apiKey
        } finally {
            $regSub.Close()
        }
    } finally {
        $regBase.Close()
    }
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

# The personal id is set for exactly these aliases (the coding VMs). What ssh would really use for them is read
# offline with `ssh.exe -G`. The probe alias is a name the id must never reach.
$principalAliases = @(1..8 | ForEach-Object { "coding-vm-$_" })
$principalProbeAlias = 'cubeone-unrelated-probe'
$principalVariable = 'CUBEONE_PRINCIPAL='
$principalPattern = '^[A-Za-z0-9_-]{22,80}$'
# What to do by hand when the file cannot be changed automatically. A blind two-line prefix would move the old
# top-of-file settings into the block, and a second SetEnv line would hide the first one.
$principalHandEdit = "Set it by hand for $($principalAliases -join ' '): keep an id that already exists for any of them, otherwise make one of 22 to 80 characters (A-Z a-z 0-9 _ -), for example [guid]::NewGuid().ToString('N') in PowerShell. Add CUBEONE_PRINCIPAL=<id> to the first SetEnv line that applies to each of these hosts and keep the variables and the Host scope that line already has (ssh uses only the first SetEnv line that applies and ignores later ones). Where no SetEnv applies to them yet, add the line 'Host $($principalAliases -join ' ')' with '    SetEnv CUBEONE_PRINCIPAL=<id>', followed by 'Host *', in front of the old settings at the top of the file, so those settings keep applying to every host."

function Get-SshExecutable {
    # The Windows OpenSSH client first (not a copy that comes with Git or another tool earlier in PATH).
    $windowsSsh = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
    if (Test-Path -LiteralPath $windowsSsh -PathType Leaf) { return $windowsSsh }
    $found = Get-Command -Name 'ssh.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) {
        throw 'ssh.exe (Windows OpenSSH client) was not found. It is needed to read the SSH config offline. The SSH config was not changed.'
    }
    return $found.Source
}

function Invoke-SshConfigDump {
    # `ssh -G` only prints the settings ssh would use for an alias. It makes no connection, reads no key and
    # needs no stdin. Output and stderr are parsed by the callers and never printed. A `Match exec` line would
    # run a command here, which is why Assert-SshConfigSafeToEvaluate runs first. Every wait is bounded: a
    # process that does not finish is killed and the call fails without any output.
    param([string]$ConfigPath, [string]$Alias, [int]$TimeoutMilliseconds = 30000)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Get-SshExecutable
    $psi.Arguments = '-G -F "' + $ConfigPath + '" -o CanonicalizeHostname=no ' + $Alias
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $psi.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        # Both streams are read at the same time, so a full pipe can never stop the process.
        $outputRead = $process.StandardOutput.ReadToEndAsync()
        $errorRead = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill() } catch { $process.Refresh() }
            [void]$process.WaitForExit(5000)
            throw "ssh.exe -G did not finish within $TimeoutMilliseconds ms for the SSH config '$ConfigPath' and was stopped. It was not changed."
        }
        # The process has ended; its output is complete once both reads are. Still bounded.
        if (-not $outputRead.Wait(5000) -or -not $errorRead.Wait(5000)) {
            throw "ssh.exe -G left its output open for the SSH config '$ConfigPath'. It was not changed."
        }
        $text = $outputRead.GetAwaiter().GetResult()
        [void]$errorRead.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    } finally {
        $process.Dispose()
    }
    if ($exitCode -ne 0 -or $text -notmatch '(?m)^hostname ') {
        throw "ssh.exe -G could not read the SSH config '$ConfigPath' (exit $exitCode). It was not changed. Check it with: ssh -G -F `"$ConfigPath`" $Alias"
    }
    return @($text -split '\r?\n' | Where-Object { $_ })
}
function Get-EffectiveSshSettings {
    # SetEnv = the NAME=VALUE assignments ssh would send. Other = every other effective setting as one text.
    # OpenSSH uses only the first SetEnv line that applies to a host and ignores all later ones.
    param([string]$ConfigPath, [string]$Alias)
    $lines = @(Invoke-SshConfigDump -ConfigPath $ConfigPath -Alias $Alias)
    $assignments = @($lines | Where-Object { $_.StartsWith('setenv ', [System.StringComparison]::Ordinal) } | ForEach-Object { $_.Substring(7) })
    $others = @($lines | Where-Object { -not $_.StartsWith('setenv ', [System.StringComparison]::Ordinal) })
    return [pscustomobject]@{ SetEnv = $assignments; Other = ($others -join "`n") }
}

function Get-BomLength {
    param([byte[]]$Bytes)
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { return 3 }
    return 0
}

function Assert-SshConfigSafeToEvaluate {
    # Nothing is executed or followed here, the text is only read. ssh -G runs the command of every `Match exec`
    # line, also in included files. A config with Include, or with a Match line that has exec, is not evaluated:
    # the id is then set by hand.
    param([string]$Text, [string]$ConfigPath)
    foreach ($line in ($Text -split '\r\n|\n|\r')) {
        $plain = ($line -replace '["'']', '').TrimStart()
        if ($plain.StartsWith('#')) { continue }
        if ($plain -match '^(?i)Include([ \t=]|$)') {
            throw "SSH config '$ConfigPath' uses Include. Included files cannot be checked safely, so the personal id is not set automatically and the file was not changed. $principalHandEdit"
        }
        if ($plain -match '^(?i)Match([ \t=]|$)' -and $plain -match '(?i)(?<![\w.-])exec(?![\w.-])') {
            throw "SSH config '$ConfigPath' has a Match line with exec, which would run a command when the config is read. The personal id is not set automatically and the file was not changed. $principalHandEdit"
        }
    }
}

function Get-PrincipalPlan {
    # From what ssh really uses for the eight aliases: nothing to do, which id to write, or why nothing is written.
    param([hashtable]$Before, [string]$ConfigPath)
    $values = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $missing = 0
    $otherVariables = $false
    foreach ($alias in $principalAliases) {
        $covered = $false
        foreach ($assignment in $Before[$alias].SetEnv) {
            if ($assignment.StartsWith($principalVariable, [System.StringComparison]::Ordinal)) {
                [void]$values.Add($assignment.Substring($principalVariable.Length))
                $covered = $true
            } else {
                $otherVariables = $true
            }
        }
        if (-not $covered) { $missing++ }
    }
    foreach ($value in $values) {
        if (-not [regex]::IsMatch($value, $principalPattern)) {
            throw "SSH config '$ConfigPath': ssh would send a CUBEONE_PRINCIPAL that is not 22 to 80 characters of A-Z, a-z, 0-9, _ and -. It was not changed. Fix or remove that SetEnv assignment."
        }
    }
    if ($values.Count -gt 1) {
        throw "SSH config '$ConfigPath': the coding VMs would get $($values.Count) different CUBEONE_PRINCIPAL values. It was not changed. Keep one."
    }
    $existing = ''
    foreach ($value in $values) { $existing = $value }
    if ($existing -and $missing -eq 0) {
        return [pscustomobject]@{ Complete = $true; Principal = $existing }
    }
    if ($otherVariables) {
        throw "SSH config '$ConfigPath': SetEnv already sends other variables to the coding VMs. ssh uses only the first SetEnv line that applies and ignores later ones, so a new line would hide them. It was not changed. $principalHandEdit"
    }
    return [pscustomobject]@{ Complete = $false; Principal = $existing }
}

function New-PrincipalConfigBytes {
    # Only inserts at the start of the file (after a BOM). The block comes first so its SetEnv is the first that
    # applies. `Host *` then puts the old top-of-file settings, which would otherwise end up inside the block,
    # back to applying to every host. The old first Host line starts its own scope as before.
    param([byte[]]$Bytes, [string]$Principal)
    $bomLength = Get-BomLength -Bytes $Bytes
    $text = [System.Text.Encoding]::GetEncoding(28591).GetString($Bytes, $bomLength, $Bytes.Length - $bomLength)
    $eol = "`r`n"
    if ($text.Contains("`n") -and -not $text.Contains("`r`n")) { $eol = "`n" }
    $block = "Host $($principalAliases -join ' ')$eol    SetEnv $principalVariable$Principal$eol"
    if ($text.Trim().Length -gt 0) { $block = $block + $eol + 'Host *' + $eol }
    $insert = [System.Text.Encoding]::ASCII.GetBytes($block)
    $result = New-Object byte[] ($Bytes.Length + $insert.Length)
    [System.Array]::Copy($Bytes, 0, $result, 0, $bomLength)
    [System.Array]::Copy($insert, 0, $result, $bomLength, $insert.Length)
    [System.Array]::Copy($Bytes, $bomLength, $result, $bomLength + $insert.Length, $Bytes.Length - $bomLength)
    return $result
}

function Assert-PrincipalConfigEffective {
    # Dry run on a temporary copy, never on the real file: with the new text ssh must use exactly this id and
    # nothing else of the eight aliases may change, and an unrelated alias must be unchanged in every setting.
    param([byte[]]$NewBytes, [hashtable]$Before, [string]$Principal, [string]$ConfigPath)
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('opencode-principal-' + [guid]::NewGuid().ToString('N') + '.config')
    [System.IO.File]::WriteAllBytes($temp, $NewBytes)
    try {
        $expected = "$principalVariable$Principal"
        foreach ($alias in (@($principalAliases) + $principalProbeAlias)) {
            $after = Get-EffectiveSshSettings -ConfigPath $temp -Alias $alias
            $wanted = @($Before[$alias].SetEnv) -join "`n"
            if ($alias -ne $principalProbeAlias) { $wanted = $expected }
            if ($after.Other -ne $Before[$alias].Other -or (@($after.SetEnv) -join "`n") -ne $wanted) {
                throw "SSH config '$ConfigPath': the check on a copy showed that the new lines would change more than the personal id for '$alias'. It was not changed."
            }
        }
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Set-DesktopPrincipal {
    # Makes ssh send the same valid personal id to all eight coding VM aliases. What ssh would use is read offline
    # with `ssh -G` (no connection). All eight already covered: nothing is written. Partly covered: the existing
    # id is reused. Anything unclear (bad or different ids, other SetEnv variables that a new line would hide,
    # Include, Match exec) stops with the file unchanged. The file is written in place and keeps its permissions.
    param([string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return }
    $bytes = [System.IO.File]::ReadAllBytes($ConfigPath)
    $bomLength = Get-BomLength -Bytes $bytes
    $text = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes, $bomLength, $bytes.Length - $bomLength)
    Assert-SshConfigSafeToEvaluate -Text $text -ConfigPath $ConfigPath

    $before = @{}
    foreach ($alias in (@($principalAliases) + $principalProbeAlias)) {
        $before[$alias] = Get-EffectiveSshSettings -ConfigPath $ConfigPath -Alias $alias
    }
    $plan = Get-PrincipalPlan -Before $before -ConfigPath $ConfigPath
    if ($plan.Complete) {
        Write-Host 'SSH config already sends a personal OpenCode id to all coding VMs. Left unchanged.' -ForegroundColor Cyan
        return
    }
    $principal = $plan.Principal
    if (-not $principal) {
        $random = New-Object byte[] 24
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($random) } finally { $rng.Dispose() }
        $principal = [Convert]::ToBase64String($random).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }
    $newBytes = New-PrincipalConfigBytes -Bytes $bytes -Principal $principal
    Assert-PrincipalConfigEffective -NewBytes $newBytes -Before $before -Principal $principal -ConfigPath $ConfigPath
    # Writes into the existing file: its permissions and owner stay.
    [System.IO.File]::WriteAllBytes($ConfigPath, $newBytes)
    Write-Host 'SSH config sends a personal OpenCode id to the coding VMs.' -ForegroundColor Green
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
    # Linux has no HKLM. The remote server reads a file that only this user can read.
    $needle = '"baseURL": "https://openrouter.ai/api/v1"'
    if (-not $text.Contains($needle)) { throw "Managed config has no OpenRouter baseURL to attach the key file to." }
    if (-not $text.Contains('"apiKey"')) {
        $text = $text.Replace($needle, $needle + ', "apiKey": "{file:~/.config/opencode/openrouter.key}"')
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText((Join-Path $Destination 'opencode.jsonc'), $text, $utf8)
    Copy-Item -LiteralPath (Join-Path $Source 'managed\rules') -Destination (Join-Path $Destination 'rules') -Recurse
    Copy-Item -LiteralPath (Join-Path $Source 'managed\vorgaben') -Destination (Join-Path $Destination 'vorgaben') -Recurse
    Copy-Item -LiteralPath (Join-Path $Source 'managed\skills') -Destination (Join-Path $Destination 'skills') -Recurse
    $plugins = Join-Path $Destination 'cubeone\plugins'
    New-Item -ItemType Directory -Path $plugins -Force | Out-Null
    foreach ($name in @('cubeone-stt', 'cubeone-pty', 'cubeone-vorgaben', 'cubeone-mcp', 'cubeone-ssh-hosts', 'cubeone-cursor-skills', 'cubeone-redmine', 'cubeone-dcp-view', 'cubeone-sale')) {
        Copy-PluginPayload -Name $name -From (Join-Path $Source "plugins\$name") -To (Join-Path $plugins $name)
    }
    $userTo = Join-Path $Destination 'user'
    New-Item -ItemType Directory -Path (Join-Path $userTo 'vorgaben') -Force | Out-Null
    foreach ($file in @('opencode.jsonc', 'opencode-mem.jsonc')) {
        $path = Join-Path $Source "user\$file"
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $userTo $file) }
    }
    $optionalRules = Join-Path $Source 'user\rules\optional'
    if (Test-Path -LiteralPath $optionalRules) {
        Copy-Item -LiteralPath $optionalRules -Destination (Join-Path $userTo 'rules\optional') -Recurse
    }
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

# Failures are reported as one fixed label, never as the raw stderr or stdout of ssh, wsl or the remote
# script: that text is unbounded and can contain host details or, after a bad transfer, key material.
# Transport = the connection or login failed, so nothing is known about the remote system.
$failureClasses = @(
    [pscustomobject]@{ Transport = $true; Label = 'host key verification failed'; Pattern = 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED' },
    [pscustomobject]@{ Transport = $true; Label = 'private key file rejected'; Pattern = 'UNPROTECTED PRIVATE KEY|Bad owner or permissions|bad permissions|Load key|invalid format|no such identity' },
    [pscustomobject]@{ Transport = $true; Label = 'authentication failed (public key denied)'; Pattern = 'Permission denied|Too many authentication failures|No supported authentication methods' },
    [pscustomobject]@{ Transport = $true; Label = 'host not reachable'; Pattern = 'timed out|No route to host|Network is unreachable|Connection refused|Could not resolve hostname|Name or service not known|Connection closed|Connection reset|kex_exchange_identification' },
    [pscustomobject]@{ Transport = $false; Label = 'invalid or foreign staging directory'; Pattern = 'invalid or foreign staging directory' },
    [pscustomobject]@{ Transport = $false; Label = 'package transfer incomplete'; Pattern = 'package transfer incomplete' },
    [pscustomobject]@{ Transport = $false; Label = 'key transfer incomplete'; Pattern = 'key transfer incomplete|key file missing|invalid expected key size' },
    [pscustomobject]@{ Transport = $false; Label = 'key target is a directory'; Pattern = 'key target is a directory' },
    [pscustomobject]@{ Transport = $false; Label = 'cannot write /etc/opencode (no sudo)'; Pattern = 'cannot write managed configuration' },
    [pscustomobject]@{ Transport = $false; Label = 'sudo or opencode binary missing'; Pattern = 'sudo is required|opencode is not installed in' },
    [pscustomobject]@{ Transport = $false; Label = 'CPU lacks instructions required by Bun'; Pattern = 'SSE4|[Ii]llegal instruction' }
)
$sshErrorClass = [pscustomobject]@{ Transport = $true; Label = 'ssh connection error'; Pattern = '' }
$unclassifiedClass = [pscustomobject]@{ Transport = $false; Label = 'unclassified'; Pattern = '' }

function Get-FailureClass {
    param($Result)
    $text = [string]$Result.Err + "`n" + [string]$Result.Out
    if ($text.Length -gt 8000) { $text = $text.Substring(0, 8000) }
    # ssh.exe itself exits with 255 when the connection or login failed. Any other exit code comes from the
    # remote command, so transport patterns (for example "Permission denied" from a remote mkdir) do not apply.
    $isTransport = $Result.Code -eq 255
    foreach ($class in $failureClasses) {
        if ($class.Transport -ne $isTransport) { continue }
        if ($text -match $class.Pattern) { return $class }
    }
    if ($isTransport) { return $sshErrorClass }
    return $unclassifiedClass
}

# Every target ends in exactly one of these. Skipped is a host the setup does not cover (Windows in the full
# setup, a system that is neither Linux nor Windows). A host that could not be reached or logged in to is Failed.
$tally = @{ Succeeded = 0; Skipped = 0; Failed = 0 }

function Assert-RemoteRunSucceeded {
    # A run that attempted targets and failed on any of them must not end like a success: the caller
    # (Scoop installer) reports it, and Update-OpenCodeKey.ps1 exits non-zero.
    param($Tally)
    if ($Tally.Failed -gt 0) {
        $attempted = $Tally.Succeeded + $Tally.Failed
        throw "Remote OpenCode setup failed on $($Tally.Failed) of $attempted targets ($($Tally.Succeeded) succeeded, $($Tally.Skipped) skipped). The warnings above name each target and the reason."
    }
}

function Invoke-Checked {
    param($Result, [string]$Action)
    if ($Result.Code -ne 0) {
        $class = Get-FailureClass -Result $Result
        throw "$Action failed (exit $($Result.Code)): $($class.Label)."
    }
}

# cmd.exe's own "<" redirection reads this; it is the empty input for steps that need no stdin.
$nullInput = 'NUL'
$stageDirPattern = '^/tmp/cubeone-[A-Za-z0-9]{10}$'
# The only remote commands that travel inside one pair of double quotes through cmd.exe, ssh and
# wsl.exe: receive a file into the private stage directory, or remove that directory.
$stageCommandPattern = '^(cat > |rm -rf )/tmp/cubeone-[A-Za-z0-9]{10}(/[A-Za-z0-9][A-Za-z0-9.-]*)?$'
$scriptArgPattern = '^[A-Za-z0-9_./-]+$'

function New-RemoteTarget {
    param([string]$Kind, [string]$Name, [string]$SshArguments, [string]$UserProfile)
    if ($Kind -ne 'wsl' -and $Kind -ne 'ssh') { throw "Unknown remote target kind '$Kind'." }
    return [pscustomobject]@{ Kind = $Kind; Name = $Name; SshArguments = $SshArguments; UserProfile = $UserProfile }
}

function Invoke-RemoteCommand {
    param($Target, [string]$Command, [string]$InputPath)
    if ($Command -notmatch $stageCommandPattern) { throw 'Remote command is not an allowed staging command.' }
    if ($Target.Kind -eq 'wsl') {
        $arguments = "-d $($Target.Name) -- bash -c `"$Command`""
        return Send-File -Exe 'wsl.exe' -Arguments $arguments -InputPath $InputPath
    }
    $arguments = "$($Target.SshArguments) `"$Command`""
    return Send-File -Exe 'ssh.exe' -Arguments $arguments -InputPath $InputPath -UserProfile $Target.UserProfile
}

function Invoke-RemoteScript {
    param($Target, [string]$InputPath, [string[]]$ScriptArguments = @(), [switch]$AsRoot)
    foreach ($item in $ScriptArguments) {
        if ($item -notmatch $scriptArgPattern) { throw 'Remote script argument contains unsafe characters.' }
    }
    $tail = ''
    if ($ScriptArguments.Count -gt 0) { $tail = ' -- ' + ($ScriptArguments -join ' ') }
    if ($Target.Kind -eq 'wsl') {
        $user = ''
        if ($AsRoot) { $user = '-u root ' }
        $arguments = "-d $($Target.Name) $user-- bash -s$tail"
        return Send-File -Exe 'wsl.exe' -Arguments $arguments -InputPath $InputPath
    }
    $arguments = "$($Target.SshArguments) bash -s$tail"
    return Send-File -Exe 'ssh.exe' -Arguments $arguments -InputPath $InputPath -UserProfile $Target.UserProfile
}

function New-RemoteStage {
    param($Target, [string]$StageScriptPath)
    $result = Invoke-RemoteScript -Target $Target -InputPath $StageScriptPath
    Invoke-Checked $result "Private staging directory on $($Target.Kind) $($Target.Name)"
    $lines = @($result.Out -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $path = ''
    if ($lines.Count -gt 0) { $path = $lines[$lines.Count - 1] }
    if ($path -notmatch $stageDirPattern) {
        throw "Private staging directory on $($Target.Kind) $($Target.Name) returned an unexpected path."
    }
    return $path
}

function Send-RemoteStageFile {
    param($Target, [string]$StageDir, [string]$Name, [string]$InputPath)
    $result = Invoke-RemoteCommand -Target $Target -Command "cat > $StageDir/$Name" -InputPath $InputPath
    Invoke-Checked $result "Copy $Name to $($Target.Kind) $($Target.Name)"
}

function Invoke-StagedScript {
    <#
    Stages the files in a private directory on the target, runs the script with that directory as its
    argument (after LeadingArguments, before TrailingArguments) and always removes the directory again,
    whether the transfer, the script or the connection failed. Returns the script result.
    #>
    param(
        $Target,
        [string]$StageScriptPath,
        $Files,
        [string]$ScriptPath,
        [string[]]$LeadingArguments = @(),
        [string[]]$TrailingArguments = @(),
        [switch]$AsRoot
    )
    $stageDir = $null
    try {
        $stageDir = New-RemoteStage -Target $Target -StageScriptPath $StageScriptPath
        foreach ($name in $Files.Keys) {
            Send-RemoteStageFile -Target $Target -StageDir $stageDir -Name $name -InputPath $Files[$name]
        }
        $scriptArguments = @($LeadingArguments) + @($stageDir) + @($TrailingArguments)
        return Invoke-RemoteScript -Target $Target -InputPath $ScriptPath -ScriptArguments $scriptArguments -AsRoot:$AsRoot
    } finally {
        Remove-RemoteStage -Target $Target -StageDir $stageDir
    }
}

function Remove-RemoteStage {
    # Best effort and idempotent: the install scripts already remove the directory on success.
    param($Target, [string]$StageDir)
    if (-not $StageDir -or $StageDir -notmatch $stageDirPattern) { return }
    try {
        $result = Invoke-RemoteCommand -Target $Target -Command "rm -rf $StageDir" -InputPath $nullInput
        if ($result.Code -ne 0) {
            Write-Warning "Staging directory $StageDir on $($Target.Kind) $($Target.Name) was not removed."
        }
    } catch {
        $err = $_
        Write-Warning "Staging directory $StageDir on $($Target.Kind) $($Target.Name) was not removed: $($err.Exception.Message)"
    }
}

# Read-only OS probe for Windows OpenSSH hosts. It contains no key and runs with empty input.
$windowsProbePs = "Write-Output ('cubeone-os=' + [System.Environment]::OSVersion.Platform)"
$windowsProbeEncoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($windowsProbePs))

function Get-SshHostOs {
    <#
    Finds out what a host is before anything but the probes is sent to it. Both probes read no stdin, so the
    key is never sent to a host whose system is not known. A failed login or connection is not a statement
    about the system: it returns Unknown with the failure label and no second probe is made.
    Returns Os = Linux, Windows or Unknown, Failure = the label for Unknown, and Transport = true when the
    connection or login failed (a failure of the target), false when the system simply is neither.
    #>
    param([string]$SshArguments, [string]$UserProfile)
    $linux = Send-File -Exe 'ssh.exe' -Arguments "$SshArguments uname -s" -InputPath $nullInput -UserProfile $UserProfile
    if ($linux.Code -eq 0 -and $linux.Out.Trim() -eq 'Linux') {
        return [pscustomobject]@{ Os = 'Linux'; Failure = ''; Transport = $false }
    }
    $class = Get-FailureClass -Result $linux
    if ($class.Transport) {
        return [pscustomobject]@{ Os = 'Unknown'; Failure = $class.Label; Transport = $true }
    }
    $windows = Send-File -Exe 'ssh.exe' -Arguments "$SshArguments powershell.exe -NoProfile -NonInteractive -EncodedCommand $windowsProbeEncoded" -InputPath $nullInput -UserProfile $UserProfile
    if ($windows.Code -eq 0 -and $windows.Out.Trim() -eq 'cubeone-os=Win32NT') {
        return [pscustomobject]@{ Os = 'Windows'; Failure = ''; Transport = $false }
    }
    $class = Get-FailureClass -Result $windows
    if ($class.Transport) {
        return [pscustomobject]@{ Os = 'Unknown'; Failure = $class.Label; Transport = $true }
    }
    return [pscustomobject]@{ Os = 'Unknown'; Failure = 'system is neither Linux nor Windows'; Transport = $false }
}

# Remote side of the transfer. Package and key never land at a fixed path in /tmp. A stage step creates
# a private directory (mktemp -d, mode 0700, random name) and every later step reads from it. The
# directory is removed by the install script itself and again by the caller, also after a failure.
$stageSh = @'
#!/bin/bash
set -eu
umask 077
inbox=$(mktemp -d /tmp/cubeone-XXXXXXXXXX)
chmod 700 "$inbox"
printf '%s\n' "$inbox"
'@

# Shared by the install and key scripts. check_inbox accepts only a directory the stage step made:
# fixed prefix, 10 alphanumerics, no symlink, owned by the caller (or by root / the target user when
# the caller is root). put_key replaces the key in one rename from a 0600 file in the same directory,
# so a reader never sees a partial key, an existing symlink is replaced instead of followed, and a
# failure leaves the old key untouched.
$commonSh = @'
#!/bin/bash
set -eu
check_inbox() {
    case "$1" in /tmp/cubeone-*) ;; *) return 1 ;; esac
    suffix=${1#/tmp/cubeone-}
    case "$suffix" in ''|*[!A-Za-z0-9]*) return 1 ;; esac
    [ "${#suffix}" -eq 10 ] || return 1
    if [ -L "$1" ] || [ ! -d "$1" ]; then return 1; fi
    if [ "$(id -u)" -eq 0 ]; then
        owner=$(stat -c %u "$1")
        allowed=0
        if [ -n "${2:-}" ]; then allowed=$(id -u "$2"); fi
        if [ "$owner" != "0" ] && [ "$owner" != "$allowed" ]; then return 1; fi
    elif [ ! -O "$1" ]; then
        return 1
    fi
    chmod 700 "$1"
}
put_key() {
    if [ -d "$2" ]; then echo "key target is a directory" >&2; return 1; fi
    tmp=$(umask 077 && mktemp "$(dirname "$2")/.openrouter.key.XXXXXX") || return 1
    if cat "$1" > "$tmp" && chmod 600 "$tmp" && { [ -z "${3:-}" ] || chown "$3:$3" "$tmp"; } && mv -f "$tmp" "$2"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}
byte_count() {
    wc -c < "$1" | tr -d ' '
}
'@

$installBodySh = @'
TARGET_USER="${1:-}"
if [ "$TARGET_USER" = "-" ]; then TARGET_USER=""; fi
INBOX="${2:-}"
KEY_BYTES="${3:-}"
TGZ_BYTES="${4:-}"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
trap 'exit 1' INT TERM HUP
if ! check_inbox "$INBOX" "$TARGET_USER"; then
    echo "invalid or foreign staging directory" >&2
    exit 1
fi
trap 'rm -rf "$STAGE" "$INBOX"' EXIT
chmod 600 "$INBOX"/* 2>/dev/null || true
if [ ! -f "$INBOX/cubeone-opencode.tgz" ] || [ "$(byte_count "$INBOX/cubeone-opencode.tgz")" != "$TGZ_BYTES" ]; then
    echo "package transfer incomplete" >&2
    exit 1
fi
case "$KEY_BYTES" in ''|*[!0-9]*) echo "invalid expected key size" >&2; exit 1 ;; esac
if [ "$KEY_BYTES" -gt 0 ] && { [ ! -f "$INBOX/openrouter.key" ] || [ -L "$INBOX/openrouter.key" ] || [ "$(byte_count "$INBOX/openrouter.key")" != "$KEY_BYTES" ]; }; then
    echo "key transfer incomplete" >&2
    exit 1
fi
tar -xzf "$INBOX/cubeone-opencode.tgz" -C "$STAGE"
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
    echo "cannot write managed configuration to /etc/opencode; personal configuration was not changed" >&2
    exit 1
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
# The copy adds and overwrites. A rule removed from the package has to go too, or it stays in force.
prune_md() {
    [ -d "$2" ] || return 0
    for existing in "$2"/*.md; do
        [ -e "$existing" ] || continue
        base=$(basename "$existing")
        if [ ! -f "$1/$base" ]; then
            if [ -n "$SUDO" ]; then sudo -n rm -f "$existing"; else rm -f "$existing"; fi
        fi
    done
}
prune_md "$STAGE/rules" "$ROOT/rules"
prune_md "$STAGE/vorgaben" "$ROOT/vorgaben"
copy_tree "$STAGE/cubeone" "$ROOT/cubeone"
if [ -n "$SUDO" ]; then
    sed "s#__CUBEONE_ROOT__#${ROOT}#g" "$STAGE/opencode.jsonc" | sudo -n tee "$ROOT/opencode.jsonc" >/dev/null
    sudo -n chmod -R a+rX "$ROOT"
else
    sed "s#__CUBEONE_ROOT__#${ROOT}#g" "$STAGE/opencode.jsonc" > "$ROOT/opencode.jsonc"
fi
personal_owner() {
    if [ -n "$TARGET_USER" ] && [ "$(id -u)" -eq 0 ]; then chown "$TARGET_USER:$TARGET_USER" "$1"; fi
}
for directory in "$HOME_DIR/.config" "$HOME_DIR/.config/opencode" "$HOME_DIR/.config/opencode/vorgaben" "$HOME_DIR/.config/opencode/rules" "$HOME_DIR/.config/opencode/rules/optional"; do
    if [ ! -d "$directory" ]; then mkdir -p "$directory"; personal_owner "$directory"; fi
done
if [ -d "$STAGE/user/rules/optional" ]; then
    for optional in "$STAGE/user/rules/optional/"*.md; do
        [ -f "$optional" ] || continue
        destination="$HOME_DIR/.config/opencode/rules/optional/$(basename "$optional")"
        if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then cp "$optional" "$destination"; personal_owner "$destination"; fi
    done
fi
# Existing personal rules and configuration are never replaced or removed.
if [ ! -e "$HOME_DIR/.config/opencode/opencode.jsonc" ] && [ ! -L "$HOME_DIR/.config/opencode/opencode.jsonc" ] && [ ! -e "$HOME_DIR/.config/opencode/opencode.json" ] && [ ! -L "$HOME_DIR/.config/opencode/opencode.json" ] && [ -f "$STAGE/user/opencode.jsonc" ]; then
    cp "$STAGE/user/opencode.jsonc" "$HOME_DIR/.config/opencode/opencode.jsonc"
    personal_owner "$HOME_DIR/.config/opencode/opencode.jsonc"
fi
# Merge only missing MCP names. Python is optional: without it, preserve the existing file and warn.
USER_CONFIG="$HOME_DIR/.config/opencode/opencode.jsonc"
if [ ! -f "$USER_CONFIG" ]; then USER_CONFIG="$HOME_DIR/.config/opencode/opencode.json"; fi
if [ -f "$USER_CONFIG" ] && [ -f "$STAGE/user/opencode.jsonc" ]; then
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$USER_CONFIG" "$STAGE/user/opencode.jsonc" <<'PY' || echo "warning: personal MCP configuration was not merged" >&2
import json
import os
import sys

def parse_jsonc(path):
    with open(path, encoding="utf-8-sig") as source:
        text = source.read()
    clean = []
    i = 0
    quoted = False
    while i < len(text):
        char = text[i]
        if quoted:
            clean.append(char)
            if char == "\\" and i + 1 < len(text):
                clean.append(text[i + 1])
                i += 2
                continue
            if char == '"':
                quoted = False
        elif char == '"':
            quoted = True
            clean.append(char)
        elif text.startswith("//", i):
            end = text.find("\n", i + 2)
            i = len(text) if end < 0 else end
            continue
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            if end < 0:
                raise ValueError("unterminated comment")
            clean.append(" ")
            i = end + 2
            continue
        else:
            clean.append(char)
        i += 1
    text = "".join(clean)
    clean = []
    i = 0
    quoted = False
    while i < len(text):
        char = text[i]
        if quoted:
            clean.append(char)
            if char == "\\" and i + 1 < len(text):
                clean.append(text[i + 1])
                i += 2
                continue
            if char == '"':
                quoted = False
        elif char == '"':
            quoted = True
            clean.append(char)
        elif char == ",":
            end = i + 1
            while end < len(text) and text[end].isspace():
                end += 1
            if end >= len(text) or text[end] not in "}]":
                clean.append(char)
        else:
            clean.append(char)
        i += 1
    return json.loads("".join(clean))

try:
    destination, template = sys.argv[1:]
    current = parse_jsonc(destination)
    supplied = parse_jsonc(template)
    if not isinstance(current, dict) or not isinstance(supplied, dict):
        raise ValueError("configuration is not an object")
    mcp = current.setdefault("mcp", {})
    if not isinstance(mcp, dict):
        raise ValueError("MCP configuration is not an object")
    servers = mcp.setdefault("servers", {})
    wanted = supplied.get("mcp", {}).get("servers", {})
    if not isinstance(servers, dict) or not isinstance(wanted, dict):
        raise ValueError("server configuration is not an object")
    added = [name for name in wanted if name not in servers]
    if added:
        for name in added:
            servers[name] = wanted[name]
        rendered = json.dumps(current, ensure_ascii=False, indent=2) + "\n"
        backup = destination + ".bak-cubeone-mcp-" + os.urandom(8).hex()
        # Exclusive backup creation prevents overwriting or following a planted backup link.
        descriptor = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as saved:
            original_stat = os.stat(destination)
            if hasattr(os, "fchown") and os.geteuid() == 0:
                os.fchown(saved.fileno(), original_stat.st_uid, original_stat.st_gid)
            with open(destination, "rb") as source:
                saved.write(source.read())
        with open(destination, "r+", encoding="utf-8") as target:
            target.seek(0)
            target.write(rendered)
            target.truncate()
        print("personal MCP configuration: missing servers added")
except Exception:
    print("warning: personal MCP configuration could not be merged; check its backup if writing failed", file=sys.stderr)
    sys.exit(1)
PY
    else
        echo "warning: python3 unavailable; existing personal MCP configuration preserved" >&2
    fi
fi
if [ ! -e "$HOME_DIR/.config/opencode/vorgaben/design.md" ] && [ ! -L "$HOME_DIR/.config/opencode/vorgaben/design.md" ] && [ -f "$STAGE/user/vorgaben/design.md" ]; then
    cp "$STAGE/user/vorgaben/design.md" "$HOME_DIR/.config/opencode/vorgaben/design.md"
    personal_owner "$HOME_DIR/.config/opencode/vorgaben/design.md"
fi
if [ ! -e "$HOME_DIR/.config/opencode/opencode-mem.jsonc" ] && [ ! -L "$HOME_DIR/.config/opencode/opencode-mem.jsonc" ] && [ -f "$STAGE/user/opencode-mem.jsonc" ]; then
    cp "$STAGE/user/opencode-mem.jsonc" "$HOME_DIR/.config/opencode/opencode-mem.jsonc"
    personal_owner "$HOME_DIR/.config/opencode/opencode-mem.jsonc"
fi
if [ "$KEY_BYTES" -gt 0 ]; then
    KEY_OWNER=""
    if [ -n "$TARGET_USER" ] && [ "$(id -u)" -eq 0 ]; then KEY_OWNER="$TARGET_USER"; fi
    put_key "$INBOX/openrouter.key" "$HOME_DIR/.config/opencode/openrouter.key" "$KEY_OWNER"
fi
printf 'installed %s\n' "$ROOT"
'@
$installSh = $commonSh + "`n" + $installBodySh

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

# Each desktop sends CUBEONE_PRINCIPAL. The server then keeps that person's MCP logins in their own
# data directory, even though every SSH session is the Linux user cubeone. Without the variable the
# existing shared server stays in place.
$personSh = @'
#!/bin/bash
set -eu
if ! sudo -n true 2>/dev/null; then
    echo "sudo is required" >&2
    exit 1
fi
if [ ! -x /usr/local/bin/opencode.bin ]; then
    if [ ! -x /usr/local/bin/opencode ]; then
        echo "opencode is not installed in /usr/local/bin" >&2
        exit 1
    fi
    sudo -n mv /usr/local/bin/opencode /usr/local/bin/opencode.bin
fi
sudo -n tee /usr/local/bin/opencode >/dev/null << 'EOF'
#!/bin/bash
set -eu
principal="${CUBEONE_PRINCIPAL:-}"
if printf '%s' "$principal" | grep -Eq '^[A-Za-z0-9_-]{22,80}$'; then
    base="${HOME}/.local"
    export XDG_DATA_HOME="${base}/share/opencode-people/${principal}"
    export XDG_STATE_HOME="${base}/state/opencode-people/${principal}"
    export XDG_CACHE_HOME="${base}/cache/opencode-people/${principal}"
    export XDG_CONFIG_HOME="${base}/config/opencode-people/${principal}"
    mkdir -p "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "${XDG_CONFIG_HOME}/opencode"
    chmod 700 "${base}/share/opencode-people" "${base}/state/opencode-people" "${base}/cache/opencode-people" "${base}/config/opencode-people" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" 2>/dev/null || true
    shared="${HOME}/.config/opencode"
    cfg="${XDG_CONFIG_HOME}/opencode"
    if [ -d "$shared" ]; then
        for item in "$shared"/*; do
            [ -e "$item" ] || continue
            name=$(basename "$item")
            [ "$name" = "service.json" ] && continue
            [ -e "${cfg}/${name}" ] && continue
            ln -s "$item" "${cfg}/${name}"
        done
    fi
    if [ ! -f "${cfg}/service.json" ]; then
        port=""
        state="${XDG_STATE_HOME}/opencode/service.json"
        if [ -f "$state" ]; then
            port=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("url","").rsplit(":",1)[-1])' "$state" 2>/dev/null || true)
        fi
        case "$port" in
            ''|*[!0-9]*)
                n=$(printf '%s' "$principal" | cksum | awk '{print $1}')
                port=$((20000 + n % 25000))
                ;;
        esac
        if [ "$port" -eq 49374 ]; then port=49375; fi
        /usr/local/bin/opencode.bin service set port "$port"
    fi
fi
exec /usr/local/bin/opencode.bin "$@"
EOF
sudo -n chmod 755 /usr/local/bin/opencode
sudo -n tee /etc/ssh/sshd_config.d/cubeone-principal.conf >/dev/null << 'EOF'
AcceptEnv CUBEONE_PRINCIPAL
EOF
sudo -n sshd -t
if systemctl list-unit-files 'ssh.service' 2>/dev/null | grep -q '^ssh.service'; then
    sudo -n systemctl reload ssh
else
    sudo -n systemctl reload sshd
fi
echo "principal wrapper installed"
'@

function Update-OpenRouterKeyOnTargets {
    $key = Get-OpenRouterKey
    if (-not $key) { throw 'HKLM\SOFTWARE\cubeone\OpenCode OpenRouterApiKey is not set.' }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('opencode-key-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $keyFile = Join-Path $work 'openrouter.key'
    $linuxScript = Join-Path $work 'install-key.sh'
    [System.IO.File]::WriteAllText($keyFile, $key, $utf8)
    $linuxSh = @'
INBOX="${1:-}"
KEY_BYTES="${2:-}"
trap 'exit 1' INT TERM HUP
if ! check_inbox "$INBOX" ""; then
  echo "invalid or foreign staging directory" >&2
  exit 1
fi
trap 'rm -rf "$INBOX"' EXIT
if [ ! -s "$INBOX/openrouter.key" ]; then
  echo "key file missing" >&2
  exit 1
fi
if [ "$(byte_count "$INBOX/openrouter.key")" != "$KEY_BYTES" ]; then
  echo "key transfer incomplete" >&2
  exit 1
fi
umask 077
mkdir -p "$HOME/.config/opencode"
put_key "$INBOX/openrouter.key" "$HOME/.config/opencode/openrouter.key"
if [ -d "$HOME/.local/config/opencode-people" ]; then
  find "$HOME/.local/config/opencode-people" -type f -path '*/opencode/openrouter.key' -print0 | while IFS= read -r -d '' person_key; do
    put_key "$INBOX/openrouter.key" "$person_key" || exit 1
  done
fi
referenced=no
for candidate in "$HOME/.config/opencode/opencode.jsonc" /etc/opencode/opencode.jsonc; do
  if [ -f "$candidate" ] && grep -q 'openrouter.key' "$candidate"; then
    referenced=yes
  fi
done
bytes=$(wc -c < "$HOME/.config/opencode/openrouter.key")
printf 'bytes=%s referenced=%s\n' "$bytes" "$referenced"
'@
    $linuxSh = $commonSh + "`n" + $linuxSh
    [System.IO.File]::WriteAllText($linuxScript, ($linuxSh -replace "`r`n", "`n"), $utf8)
    $stageScript = Join-Path $work 'stage.sh'
    [System.IO.File]::WriteAllText($stageScript, ($stageSh -replace "`r`n", "`n"), $utf8)
    $windowsSh = @'
$k = [Console]::In.ReadToEnd().Trim()
if (-not $k -or $k.Contains("`n") -or $k.Contains("`r")) { throw 'key missing' }
[Environment]::SetEnvironmentVariable('OPENROUTER_API_KEY', $k, 'User')
$hklm = 'skipped'
try {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', [Microsoft.Win32.RegistryView]::Registry64)
    $sub = $base.CreateSubKey('SOFTWARE\cubeone\OpenCode')
    $sub.SetValue('OpenRouterApiKey', $k, [Microsoft.Win32.RegistryValueKind]::String)
    $sub.Close()
    $base.Close()
    $hklm = 'set'
} catch {
    $hklm = 'skipped'
}
Write-Output ("bytes=" + $k.Length + " hklm=" + $hklm)
'@
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($windowsSh))
    $expected = $key.Length
    $keyBytes = $utf8.GetByteCount($key)
    $keyFiles = [ordered]@{ 'openrouter.key' = $keyFile }
    try {
        if (-not $SkipWsl -and -not $OnlyHost) {
            foreach ($distro in @(Get-WslDistros)) {
                $target = New-RemoteTarget -Kind 'wsl' -Name $distro
                try {
                    $recv = Invoke-StagedScript -Target $target -StageScriptPath $stageScript -Files $keyFiles `
                        -ScriptPath $linuxScript -TrailingArguments @($keyBytes)
                    Invoke-Checked $recv "Key on WSL $distro"
                    Write-Host "WSL ${distro}: $($recv.Out.Trim())" -ForegroundColor Green
                    $tally.Succeeded++
                } catch {
                    $tally.Failed++
                    Write-Warning "WSL ${distro}: $($_.Exception.Message)"
                }
            }
        }
        if ($SkipSsh) { return }
        $sshConfig = Join-Path $ProfilePath '.ssh\config'
        $sshTargets = @(Get-SshHosts -ConfigPath $sshConfig)
        if ($OnlyHost) { $sshTargets = @($sshTargets | Where-Object { $_ -eq $OnlyHost }) }
        foreach ($sshHost in $sshTargets) {
            $sshArgs = "-F `"$sshConfig`" -o BatchMode=yes -o ConnectTimeout=12 $sshHost"
            $target = New-RemoteTarget -Kind 'ssh' -Name $sshHost -SshArguments $sshArgs -UserProfile $ProfilePath
            try {
                # The probes read no stdin: the key is not sent to a host before its system is known. A failed
                # Linux probe is no reason to try the Windows transfer; only a positive Windows answer is.
                $hostOs = Get-SshHostOs -SshArguments $sshArgs -UserProfile $ProfilePath
                if ($hostOs.Os -eq 'Linux') {
                    $recv = Invoke-StagedScript -Target $target -StageScriptPath $stageScript -Files $keyFiles `
                        -ScriptPath $linuxScript -TrailingArguments @($keyBytes)
                    Invoke-Checked $recv "Key on SSH $sshHost"
                    $line = $recv.Out.Trim()
                    if ($line -notmatch "bytes=$keyBytes(\s|$)") {
                        $tally.Failed++
                        Write-Warning "SSH ${sshHost}: key check failed, expected $keyBytes bytes."
                    } else {
                        $tally.Succeeded++
                        Write-Host "SSH ${sshHost}: $line" -ForegroundColor Green
                    }
                    continue
                }
                if ($hostOs.Os -ne 'Windows') {
                    if ($hostOs.Transport) { $tally.Failed++ } else { $tally.Skipped++ }
                    Write-Warning "SSH ${sshHost}: key not sent, $($hostOs.Failure)."
                    continue
                }
                $recv = Send-File -Exe 'ssh.exe' -Arguments "$sshArgs powershell.exe -NoProfile -EncodedCommand $encoded" -InputPath $keyFile -UserProfile $ProfilePath
                Invoke-Checked $recv "Key on SSH $sshHost"
                $line = $recv.Out.Trim()
                if ($line -notmatch "bytes=$expected(\s|$)") {
                    $tally.Failed++
                    Write-Warning "SSH ${sshHost}: key check failed, expected $expected bytes."
                } else {
                    $tally.Succeeded++
                    Write-Host "SSH ${sshHost}: $line" -ForegroundColor Green
                }
            } catch {
                $tally.Failed++
                Write-Warning "SSH ${sshHost}: $($_.Exception.Message)"
            }
        }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# First action of the run: nothing below (registry key, ssh, wsl, SSH config) runs under another identity.
Assert-ProfileUserContext -ProfilePath $ProfilePath

if ($PrincipalOnly) {
    # Before anything is read, built or started: no registry key, no payload, no ssh connection, wsl, CLI or desktop
    # list. The only process is the offline `ssh.exe -G` inside Set-DesktopPrincipal.
    if ($KeyOnly -or $DesktopOnly) { throw '-PrincipalOnly cannot be combined with -KeyOnly or -DesktopOnly.' }
    $principalConfig = Join-Path $ProfilePath '.ssh\config'
    if (-not (Test-Path -LiteralPath $principalConfig -PathType Leaf)) {
        throw "No SSH config at '$principalConfig'. Set up the SSH hosts for this user first; no config was created."
    }
    Set-DesktopPrincipal -ConfigPath $principalConfig
    return
}

$utf8 = New-Object System.Text.UTF8Encoding $false
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('opencode-remote-' + [guid]::NewGuid().ToString('N'))
$payload = Join-Path $work 'payload'
$tar = Join-Path $work 'cubeone-opencode.tgz'
$keyFile = Join-Path $work 'openrouter.key'
$scriptFile = Join-Path $work 'install.sh'
$cliInstallFile = Join-Path $work 'install-cli.sh'
$personFile = Join-Path $work 'install-person.sh'
$stageFile = Join-Path $work 'stage.sh'
New-Item -ItemType Directory -Path $payload -Force | Out-Null
try {
    if ($KeyOnly) {
        Update-OpenRouterKeyOnTargets
        Assert-RemoteRunSucceeded -Tally $tally
        return
    }
    # The desktop's SSH server list is not written here: a script that overwrote the Desktop database would replace a
    # list the user built. The cubeone-ssh-hosts plugin seeds an empty list from inside the Desktop app instead.
    try {
        Set-DesktopPrincipal -ConfigPath (Join-Path $ProfilePath '.ssh\config')
    } catch {
        $err = $_
        Write-Warning "Personal OpenCode id not set: $($err.Exception.Message) The remote setup continues. Run Set-OpenCodePrincipal.ps1 after fixing the SSH config."
    }
    if ($DesktopOnly) { return }
    New-LinuxPayload -Source $SourceDir -Destination $payload
    $scriptText = $installSh -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($scriptFile, $scriptText, $utf8)
    [System.IO.File]::WriteAllText($cliInstallFile, ($cliInstallSh -replace "`r`n", "`n"), $utf8)
    [System.IO.File]::WriteAllText($personFile, ($personSh -replace "`r`n", "`n"), $utf8)
    [System.IO.File]::WriteAllText($stageFile, ($stageSh -replace "`r`n", "`n"), $utf8)
    if (Test-Path -LiteralPath $tar) { Remove-Item -LiteralPath $tar -Force }
    & tar.exe -czf $tar -C $payload .
    if ($LASTEXITCODE -ne 0) { throw "tar failed with exit $LASTEXITCODE" }

    $key = Get-OpenRouterKey
    if ($key) {
        [System.IO.File]::WriteAllText($keyFile, $key, $utf8)
    } else {
        Write-Warning 'HKLM\SOFTWARE\cubeone\OpenCode OpenRouterApiKey is not set. Remote servers get the models, but calls fail until the key file exists.'
        [System.IO.File]::WriteAllText($keyFile, '', $utf8)
    }
    $keyBytes = $utf8.GetByteCount([string]$key)
    $tgzBytes = (Get-Item -LiteralPath $tar).Length
    # The package is always sent; the key only when one is deposited, so an empty key never replaces a good one.
    $installFiles = [ordered]@{ 'cubeone-opencode.tgz' = $tar }
    if ($key) { $installFiles['openrouter.key'] = $keyFile }

    $ok = 0
    if (-not $SkipWsl -and -not $OnlyHost) {
    foreach ($distro in @(Get-WslDistros)) {
        $target = New-RemoteTarget -Kind 'wsl' -Name $distro
        try {
            # -u root reaches /etc/opencode without a sudo password. The key stays in the distro user's home.
            $wslUser = (& wsl.exe -d $distro -- bash -lc 'printf %s "$USER"').Trim()
            if (-not $wslUser) { throw 'could not resolve the WSL user' }
            # Package and key go into a private 0700 directory of the distro user, never to a fixed /tmp path.
            $recv = Invoke-StagedScript -Target $target -StageScriptPath $stageFile -Files $installFiles `
                -ScriptPath $scriptFile -LeadingArguments @($wslUser) -TrailingArguments @($keyBytes, $tgzBytes) -AsRoot
            Invoke-Checked $recv "Install on WSL $distro"
            Write-Host "WSL ${distro}: $($recv.Out.Trim())" -ForegroundColor Green
            $ok++
            $tally.Succeeded++
        } catch {
            $tally.Failed++
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
        $target = New-RemoteTarget -Kind 'ssh' -Name $sshHost -SshArguments $sshArgs -UserProfile $ProfilePath
        try {
            # The probes read no stdin, so the package and the key never go to a host that is not known to be Linux.
            $hostOs = Get-SshHostOs -SshArguments $sshArgs -UserProfile $ProfilePath
            if ($hostOs.Os -eq 'Windows') {
                $tally.Skipped++
                Write-Warning "SSH ${sshHost}: skipped, Windows hosts are not supported by the full setup. Only the key is updated there (Update-OpenCodeKey.ps1)."
                continue
            }
            if ($hostOs.Os -ne 'Linux') {
                if ($hostOs.Transport) { $tally.Failed++ } else { $tally.Skipped++ }
                Write-Warning "SSH ${sshHost}: not set up, $($hostOs.Failure)."
                continue
            }
            # The desktop app runs the remote server as a plain `ssh host opencode ...`, so the CLI has
            # to exist on the default, non-interactive PATH before anything else here helps.
            $cli = Send-File -Exe 'ssh.exe' -Arguments "$sshArgs bash -s" -InputPath $cliInstallFile -UserProfile $ProfilePath
            Invoke-Checked $cli "opencode CLI on SSH $sshHost"
            Write-Host "SSH ${sshHost}: $($cli.Out.Trim())" -ForegroundColor Green
            $person = Send-File -Exe 'ssh.exe' -Arguments "$sshArgs bash -s" -InputPath $personFile -UserProfile $ProfilePath
            Invoke-Checked $person "per-person OpenCode data directory on SSH $sshHost"
            Write-Host "SSH ${sshHost}: $($person.Out.Trim())" -ForegroundColor Green
            # Send-RemoteStageFile quotes the remote command so cmd.exe (Send-File's local redirection shell)
            # leaves the ">" for the remote shell instead of redirecting ssh's own stdout into a local file.
            $recv = Invoke-StagedScript -Target $target -StageScriptPath $stageFile -Files $installFiles `
                -ScriptPath $scriptFile -LeadingArguments @('-') -TrailingArguments @($keyBytes, $tgzBytes)
            Invoke-Checked $recv "Install on SSH $sshHost"
            Write-Host "SSH ${sshHost}: $($recv.Out.Trim())" -ForegroundColor Green
            $tally.Succeeded++
        } catch {
            $tally.Failed++
            Write-Warning "SSH ${sshHost}: $($_.Exception.Message)"
        }
    }
    }
    Assert-RemoteRunSucceeded -Tally $tally
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
