<#
.SYNOPSIS
    Pester tests for the key and package transfer in Install-OpenCodeRemote.ps1.

.DESCRIPTION
    Everything runs locally with synthetic data. Send-File is replaced by a recording mock, so no
    ssh.exe or wsl.exe is started and no real host, distro or registry key is touched. The remote
    shell scripts run in Git for Windows bash against a sandbox HOME. Written for the installed Pester 3.4.
#>

Describe 'Install-OpenCodeRemote key and package transfer' {
    BeforeAll {
        $scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Install-OpenCodeRemote.ps1'
        $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('remote-key-test-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
        $utf8 = New-Object System.Text.UTF8Encoding $false
        $syntheticKey = 'sk-or-SYNTHETIC-0123456789abcdef'

        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
        $functionNames = @(
            'Send-File', 'Invoke-Checked', 'New-RemoteTarget', 'Invoke-RemoteCommand', 'Invoke-RemoteScript',
            'New-RemoteStage', 'Send-RemoteStageFile', 'Invoke-StagedScript', 'Remove-RemoteStage',
            'Get-CurrentIdentitySid', 'Get-ProfileImagePath', 'Assert-ProfileUserContext', 'Get-FailureClass', 'Get-SshHostOs', 'Assert-RemoteRunSucceeded'
        )
        $variableNames = @(
            'nullInput', 'stageDirPattern', 'stageCommandPattern', 'scriptArgPattern',
            'stageSh', 'commonSh', 'installBodySh', 'installSh', 'linuxSh',
            'failureClasses', 'sshErrorClass', 'unclassifiedClass', 'windowsProbePs', 'windowsProbeEncoded'
        )
        $functionAsts = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $functionNames -contains $node.Name
        }, $true))
        $variableAsts = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $variableNames -contains $node.Left.VariablePath.UserPath
        }, $true) | Sort-Object { $_.Extent.StartOffset })

        # Real Send-File under another name, to check the cmd.exe quoting; the mock replaces Send-File.
        $realSendFile = ($functionAsts | Where-Object { $_.Name -eq 'Send-File' }).Extent.Text
        $realSendFile = $realSendFile -replace '^function Send-File', 'function Send-FileReal'
        $mockedFunctions = ($functionAsts | Where-Object { $_.Name -ne 'Send-File' } | ForEach-Object { $_.Extent.Text }) -join "`n`n"
        $variableCode = ($variableAsts | ForEach-Object { $_.Extent.Text }) -join "`n"
        $loader = Join-Path $sandbox 'extracted.ps1'
        [System.IO.File]::WriteAllText($loader, ($realSendFile + "`n`n" + $mockedFunctions + "`n`n" + $variableCode), $utf8)
        . $loader

        # Recording stand-in for Send-File. TestBehavior decides the result for each call.
        $global:TestCalls = New-Object System.Collections.ArrayList
        $global:TestBehavior = $null
        function Send-File {
            param([string]$Exe, [string]$Arguments, [string]$InputPath, [string]$UserProfile)
            $call = [pscustomobject]@{ Exe = $Exe; Arguments = $Arguments; InputPath = $InputPath; UserProfile = $UserProfile }
            [void]$global:TestCalls.Add($call)
            return & $global:TestBehavior $call
        }
        function New-Result {
            param([int]$Code = 0, [string]$Out = '', [string]$Err = '')
            return [pscustomobject]@{ Code = $Code; Out = $Out; Err = $Err }
        }

        $bashExe = 'C:\Program Files\Git\usr\bin\bash.exe'
        $cygpath = 'C:\Program Files\Git\usr\bin\cygpath.exe'
        $haveBash = (Test-Path -LiteralPath $bashExe) -and (Test-Path -LiteralPath $cygpath)
        # A non-login bash needs the Git coreutils (mktemp, stat, tar) on PATH. Restored in AfterAll.
        $originalPath = $env:PATH
        if ($haveBash) { $env:PATH = (Split-Path -Parent $bashExe) + ';' + $env:PATH }

        function Get-ThrownMessage {
            param([scriptblock]$Body)
            try { & $Body } catch { return $_.Exception.Message }
            return ''
        }

        function Write-LfFile {
            param([string]$Path, [string]$Text)
            [System.IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), $utf8)
        }

        # Runs a local file as the remote script through the real Send-File (cmd.exe redirection).
        function Invoke-LocalBash {
            param([string]$Script, [string]$HomeDir, [string[]]$ScriptArguments = @())
            $argumentText = ''
            if ($ScriptArguments.Count -gt 0) { $argumentText = ' ' + ($ScriptArguments -join ' ') }
            return Send-FileReal -Exe "`"$bashExe`"" -Arguments "-s --$argumentText" -InputPath $Script -UserProfile $HomeDir
        }
        function Get-WindowsPath {
            param([string]$PosixPath)
            return (& $cygpath -w $PosixPath).Trim()
        }
        function New-LocalStage {
            param([string]$HomeDir)
            $stage = Join-Path $sandbox 'stage.sh'
            Write-LfFile $stage $stageSh
            $result = Invoke-LocalBash -Script $stage -HomeDir $HomeDir
            return $result
        }
    }

    AfterAll {
        if ($originalPath) { $env:PATH = $originalPath }
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name TestCalls, TestBehavior -Scope Global -ErrorAction SilentlyContinue
    }

    Context 'Source file' {
        It 'parses without errors in Windows PowerShell 5 and PowerShell 7' {
            @($parseErrors).Count | Should Be 0
            $code = '$e=$null;$t=$null;[void][System.Management.Automation.Language.Parser]::ParseFile(''' + $scriptPath.Replace("'", "''") +
                ''',[ref]$t,[ref]$e);@($e).Count'
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($code))
            $ps5 = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
            (& $ps5 -NoProfile -EncodedCommand $encoded) | Should Be '0'
        }

        It 'has no fixed /tmp path for the key or the package and no world-readable receive' {
            $text = [System.IO.File]::ReadAllText($scriptPath)
            $text -match 'cubeone-openrouter\.key' | Should Be $false
            $text -match "-Name 'cubeone-opencode\.tgz'|\['cubeone-opencode\.tgz'\]|'cubeone-opencode\.tgz' =" | Should Be $true
            $text -match '/tmp/cubeone-opencode\.tgz' | Should Be $false
            $text -match '/tmp/cubeone-openrouter' | Should Be $false
            $text -match 'cat > /tmp/cubeone-[a-z]+\.' | Should Be $false
        }

        It 'never sends the key to a probe, and only a positive Windows answer reaches the Windows key transfer' {
            $text = [System.IO.File]::ReadAllText($scriptPath)
            $text -match 'uname -s" -InputPath \$keyFile' | Should Be $false
            ([regex]::Matches($text, 'uname -s" -InputPath \$nullInput')).Count | Should Be 1
            ([regex]::Matches($text, 'uname -s')).Count | Should Be 1
            ([regex]::Matches($text, 'Get-SshHostOs -SshArguments')).Count | Should Be 2
            $keySend = $text.IndexOf('-InputPath $keyFile -UserProfile $ProfilePath')
            $gate = $text.IndexOf("if (`$hostOs.Os -ne 'Windows')")
            $keySend | Should BeGreaterThan 0
            $gate | Should BeGreaterThan 0
            ($gate -lt $keySend) | Should Be $true
            ([regex]::Matches($text, '-InputPath \$keyFile -UserProfile \$ProfilePath')).Count | Should Be 1
        }

        It 'checks the user context before it reads the key, starts ssh or touches the profile' {
            $text = [System.IO.File]::ReadAllText($scriptPath)
            $guard = $text.IndexOf('Assert-ProfileUserContext -ProfilePath $ProfilePath')
            $guard | Should BeGreaterThan 0
            foreach ($later in @('if ($KeyOnly)', 'Set-DesktopPrincipal -ConfigPath (Join-Path $ProfilePath', 'New-LinuxPayload -Source $SourceDir', '$key = Get-OpenRouterKey')) {
                $at = $text.LastIndexOf($later)
                $at | Should BeGreaterThan 0
                ($guard -lt $at) | Should Be $true
            }
        }

        It 'stops with the guard message when a child process runs it for a profile of another account (no key read, no ssh)' {
            $other = Join-Path ([System.IO.Path]::GetTempPath()) ('other-profile-' + [guid]::NewGuid().ToString('N'))
            foreach ($shell in @((Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'), (Get-Command pwsh -ErrorAction SilentlyContinue).Source)) {
                if (-not $shell) { continue }
                # The message is printed by the child itself: a wrapped error record would split it across lines.
                $childCode = 'try { & ''' + $scriptPath.Replace("'", "''") + ''' -ProfilePath ''' + $other.Replace("'", "''") + ''' -DesktopOnly -SkipWsl -SkipSsh } catch { [Console]::Out.Write($_.Exception.Message); exit 3 }'
                $encodedChild = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($childCode))
                $out = & $shell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedChild | Out-String
                $LASTEXITCODE | Should Be 3
                $out | Should Match 'must run as the Windows user'
                $out | Should Match 'nothing was read, connected or sent'
            }
        }

        It 'composes the remote scripts with LF only and valid bash syntax' -Skip:(-not $haveBash) {
            foreach ($name in @('stageSh', 'installSh', 'linuxSh')) {
                $body = (Get-Variable -Name $name -ValueOnly) -replace "`r`n", "`n"
                $file = Join-Path $sandbox "$name.sh"
                Write-LfFile $file $body
                $result = Send-FileReal -Exe "`"$bashExe`"" -Arguments "-n `"$file`"" -InputPath $nullInput
                $result.Code | Should Be 0
                $result.Err | Should Be ''
            }
        }
    }

    Context 'User context guard' {
        It 'accepts the profile of the identity that runs the script (real identity and real profile list, read only)' {
            $own = [System.IO.Path]::GetFullPath($env:USERPROFILE)
            { Assert-ProfileUserContext -ProfilePath $own } | Should Not Throw
            { Assert-ProfileUserContext -ProfilePath ($own.ToUpperInvariant() + '\') } | Should Not Throw
        }

        It 'refuses SYSTEM, a profile of another account, an unknown profile and an empty path' {
            $global:TestCalls.Clear()
            $global:TestBehavior = { New-Result }
            function Get-CurrentIdentitySid { return 'S-1-5-21-1-2-3-1001' }
            function Get-ProfileImagePath { param([string]$Sid) if ($Sid -eq 'S-1-5-21-1-2-3-1001') { return 'C:\Users\Anna' } return '' }
            { Assert-ProfileUserContext -ProfilePath 'C:\Users\Anna' } | Should Not Throw
            { Assert-ProfileUserContext -ProfilePath 'c:\users\anna\' } | Should Not Throw
            (Get-ThrownMessage { Assert-ProfileUserContext -ProfilePath 'C:\Users\Bernd' }) | Should Match 'must run as the Windows user'
            (Get-ThrownMessage { Assert-ProfileUserContext -ProfilePath 'C:\Users\Ann' }) | Should Match 'must run as the Windows user'
            (Get-ThrownMessage { Assert-ProfileUserContext -ProfilePath '' }) | Should Match 'must run as the Windows user'
            function Get-CurrentIdentitySid { return 'S-1-5-18' }
            function Get-ProfileImagePath { param([string]$Sid) return 'C:\Windows\system32\config\systemprofile' }
            (Get-ThrownMessage { Assert-ProfileUserContext -ProfilePath 'C:\Windows\system32\config\systemprofile' }) | Should Match 'nothing was read, connected or sent'
            (Get-ThrownMessage { Assert-ProfileUserContext -ProfilePath 'C:\Users\Anna' }) | Should Match 'must run as the Windows user'
            function Get-CurrentIdentitySid { return 'S-1-5-21-1-2-3-1002' }
            (Get-ThrownMessage { Assert-ProfileUserContext -ProfilePath 'C:\Users\Anna' }) | Should Match 'must run as the Windows user'
            $global:TestCalls.Count | Should Be 0
        }

        It 'expands environment variables in the registered profile path' {
            function Get-CurrentIdentitySid { return 'S-1-5-21-1-2-3-1001' }
            function Get-ProfileImagePath { param([string]$Sid) return '%SystemDrive%\Users\Anna' }
            { Assert-ProfileUserContext -ProfilePath ($env:SystemDrive + '\Users\Anna') } | Should Not Throw
        }

        It 'reads no registry path from a SID that is not a SID' {
            Get-ProfileImagePath -Sid 'S-1-5-21-1\..\..\x' | Should Be ''
            Get-ProfileImagePath -Sid '' | Should Be ''
        }
    }

    Context 'Failure classification' {
        It 'maps ssh and script failures to one fixed label' {
            $cases = @(
                @{ Code = 255; Err = 'x@h: Permission denied (publickey,password).'; Label = 'authentication failed (public key denied)' },
                @{ Code = 255; Err = 'Host key verification failed.'; Label = 'host key verification failed' },
                @{ Code = 255; Err = 'ssh: connect to host h port 22: Connection timed out'; Label = 'host not reachable' },
                @{ Code = 255; Err = 'ssh: Could not resolve hostname h'; Label = 'host not reachable' },
                @{ Code = 255; Err = 'Load key "C:\\u\\.ssh\\id": invalid format'; Label = 'private key file rejected' },
                @{ Code = 255; Err = 'something new'; Label = 'ssh connection error' },
                @{ Code = 255; Err = ''; Label = 'ssh connection error' },
                @{ Code = 1; Err = 'package transfer incomplete'; Label = 'package transfer incomplete' },
                @{ Code = 1; Err = 'key transfer incomplete'; Label = 'key transfer incomplete' },
                @{ Code = 1; Err = 'invalid or foreign staging directory'; Label = 'invalid or foreign staging directory' },
                @{ Code = 1; Err = 'cannot write managed configuration to /etc/opencode; personal configuration was not changed'; Label = 'cannot write /etc/opencode (no sudo)' },
                @{ Code = 1; Err = 'mkdir: cannot create directory: Permission denied'; Label = 'unclassified' },
                @{ Code = 1; Err = 'Connection timed out while downloading'; Label = 'unclassified' },
                @{ Code = 1; Err = ''; Label = 'unclassified' }
            )
            foreach ($case in $cases) {
                (Get-FailureClass -Result (New-Result -Code $case.Code -Err $case.Err)).Label | Should Be $case.Label
            }
            (Get-FailureClass -Result (New-Result -Code 1 -Out 'key transfer incomplete')).Label | Should Be 'key transfer incomplete'
        }

        It 'reports the exit code and the label only, never the raw output, and stays bounded' {
            $secret = $syntheticKey + ' /home/someone/.config/opencode/openrouter.key host-detail-9'
            $long = ('x' * 100000) + $secret
            foreach ($result in @((New-Result -Code 255 -Err $secret), (New-Result -Code 1 -Err $secret -Out $long), (New-Result -Code 2 -Out $long))) {
                $message = ''
                try { Invoke-Checked $result 'Install on SSH h' } catch { $message = $_.Exception.Message }
                $message | Should Match '^Install on SSH h failed \(exit \d+\): [^:]+\.$'
                $message.Contains($syntheticKey) | Should Be $false
                $message.Contains('host-detail') | Should Be $false
                ($message.Length -lt 200) | Should Be $true
            }
            { Invoke-Checked (New-Result -Code 0 -Err 'noise') 'x' } | Should Not Throw
        }
    }

    Context 'Host system probe' {
        BeforeEach {
            $global:TestCalls.Clear()
        }

        It 'answers Linux after one probe without input' {
            $global:TestBehavior = { New-Result -Out "Linux`n" }
            $os = Get-SshHostOs -SshArguments '-F x h' -UserProfile 'C:\u'
            $os.Os | Should Be 'Linux'
            $global:TestCalls.Count | Should Be 1
            $global:TestCalls[0].Arguments | Should Be '-F x h uname -s'
            $global:TestCalls[0].InputPath | Should Be 'NUL'
        }

        It 'does not assume an operating system after a failed login, and sends nothing else' {
            foreach ($err in @('x@h: Permission denied (publickey).', 'Host key verification failed.', 'ssh: connect to host h port 22: Connection refused', '')) {
                $global:TestCalls.Clear()
                $failed = New-Result -Code 255 -Err $err
                $global:TestBehavior = { param($c) return $failed }.GetNewClosure()
                $os = Get-SshHostOs -SshArguments '-F x h' -UserProfile 'C:\u'
                $os.Os | Should Be 'Unknown'
                $os.Failure | Should Not BeNullOrEmpty
                $global:TestCalls.Count | Should Be 1
            }
        }

        It 'recognises Windows by a read-only PowerShell probe that carries no key and no input' {
            $global:TestBehavior = {
                param($c)
                if ($c.Arguments -like '*uname -s') { return New-Result -Code 1 -Err "'uname' is not recognized as an internal or external command" }
                return New-Result -Out "cubeone-os=Win32NT`r`n"
            }
            $os = Get-SshHostOs -SshArguments '-F x h' -UserProfile 'C:\u'
            $os.Os | Should Be 'Windows'
            $global:TestCalls.Count | Should Be 2
            foreach ($call in $global:TestCalls) { $call.InputPath | Should Be 'NUL' }
            $encoded = ($global:TestCalls[1].Arguments -split ' ')[-1]
            $global:TestCalls[1].Arguments | Should Match 'powershell\.exe -NoProfile -NonInteractive -EncodedCommand '
            $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
            $decoded | Should Be $windowsProbePs
            $decoded | Should Match 'OSVersion\.Platform'
            $decoded | Should Not Match 'Set-|Remove-|Out-File|Environment\]::Set|Registry|ReadToEnd'
        }

        It 'does not treat a Linux host with a failing uname, or another system, as Windows' {
            foreach ($first in @((New-Result -Code 127 -Err 'uname: not found'), (New-Result -Out "Darwin`n"))) {
                $global:TestCalls.Clear()
                $second = New-Result -Code 127 -Err 'powershell.exe: command not found'
                $global:TestBehavior = {
                    param($c)
                    if ($c.Arguments -like '*uname -s') { return $first }
                    return $second
                }.GetNewClosure()
                $os = Get-SshHostOs -SshArguments '-F x h' -UserProfile 'C:\u'
                $os.Os | Should Be 'Unknown'
                $os.Failure | Should Be 'system is neither Linux nor Windows'
            }
        }

        It 'stops at a transport error of the second probe' {
            $global:TestBehavior = {
                param($c)
                if ($c.Arguments -like '*uname -s') { return New-Result -Code 1 -Err 'not recognized' }
                return New-Result -Code 255 -Err 'Connection reset by peer'
            }
            $os = Get-SshHostOs -SshArguments '-F x h' -UserProfile 'C:\u'
            $os.Os | Should Be 'Unknown'
            $os.Failure | Should Be 'host not reachable'
        }
    }

    Context 'Run result (counts, exit)' {
        It 'does not throw when nothing was attempted, everything worked, or only unsupported hosts were skipped' {
            { Assert-RemoteRunSucceeded -Tally @{ Succeeded = 0; Skipped = 0; Failed = 0 } } | Should Not Throw
            { Assert-RemoteRunSucceeded -Tally @{ Succeeded = 3; Skipped = 0; Failed = 0 } } | Should Not Throw
            { Assert-RemoteRunSucceeded -Tally @{ Succeeded = 0; Skipped = 2; Failed = 0 } } | Should Not Throw
            { Assert-RemoteRunSucceeded -Tally @{ Succeeded = 2; Skipped = 1; Failed = 0 } } | Should Not Throw
        }

        It 'throws with the counts when every attempted target failed, and when only some did' {
            (Get-ThrownMessage { Assert-RemoteRunSucceeded -Tally @{ Succeeded = 0; Skipped = 0; Failed = 2 } }) | Should Be 'Remote OpenCode setup failed on 2 of 2 targets (0 succeeded, 0 skipped). The warnings above name each target and the reason.'
            (Get-ThrownMessage { Assert-RemoteRunSucceeded -Tally @{ Succeeded = 5; Skipped = 1; Failed = 1 } }) | Should Match 'failed on 1 of 6 targets \(5 succeeded, 1 skipped\)'
            (Get-ThrownMessage { Assert-RemoteRunSucceeded -Tally @{ Succeeded = 0; Skipped = 3; Failed = 1 } }) | Should Match 'failed on 1 of 1 targets'
        }
    }

    Context 'Whole run with a mocked transport (no ssh, no wsl, no registry key, synthetic profile)' {
        BeforeAll {
            # The script itself runs in-process. Only the four things that reach outside are replaced: the identity
            # guard (tested above), Send-File (the mock), the registry key read and the WSL list.
            $remoteAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
            $remoteText = [System.IO.File]::ReadAllText($scriptPath)
            $stubs = @{
                'Send-File'         = 'function Send-File { param([string]$Exe, [string]$Arguments, [string]$InputPath, [string]$UserProfile) throw ''replaced'' }'
                'Get-OpenRouterKey' = "function Get-OpenRouterKey { return '$syntheticKey' }"
                'Get-WslDistros'    = 'function Get-WslDistros { return @() }'
            }
            $edits = @()
            foreach ($name in $stubs.Keys) {
                $definition = $remoteAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
                $edits += [pscustomobject]@{ Start = $definition.Extent.StartOffset; End = $definition.Extent.EndOffset; Text = $(if ($name -eq 'Send-File') { '' } else { $stubs[$name] }) }
            }
            $guard = $remoteAst.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Assert-ProfileUserContext' }, $true)
            $edits += [pscustomobject]@{ Start = $guard.Extent.StartOffset; End = $guard.Extent.EndOffset; Text = '' }
            foreach ($edit in ($edits | Sort-Object Start -Descending)) {
                $remoteText = $remoteText.Substring(0, $edit.Start) + $edit.Text + $remoteText.Substring($edit.End)
            }
            $modifiedScript = Join-Path $sandbox 'Install-OpenCodeRemote.modified.ps1'
            [System.IO.File]::WriteAllText($modifiedScript, $remoteText, $utf8)
            # A copy of the package without node_modules and tests keeps the payload (copy and tar) small.
            $packageRoot = Join-Path $sandbox 'package'
            & robocopy.exe (Split-Path -Parent $PSScriptRoot) $packageRoot /E /XD node_modules test /NFL /NDL /NJH /NJS /NP | Out-Null

            $global:HostModes = @{}
            $global:TestBehavior = {
                param($c)
                $hostName = ''
                if ($c.Arguments -match 'ConnectTimeout=12 (\S+)') { $hostName = $Matches[1] }
                $mode = $global:HostModes[$hostName]
                $keyLength = $syntheticKey.Length
                if ($c.Arguments -like '*uname -s') {
                    if ($mode -like 'linux*') { return New-Result -Out "Linux`n" }
                    if ($mode -eq 'denied') { return New-Result -Code 255 -Err 'u@h: Permission denied (publickey).' }
                    if ($mode -eq 'down') { return New-Result -Code 255 -Err 'ssh: connect to host h port 22: Connection timed out' }
                    return New-Result -Code 1 -Err "'uname' is not recognized as an internal or external command"
                }
                if ($c.Arguments -like '*powershell.exe*EncodedCommand*') {
                    if ($c.InputPath -eq 'NUL') {
                        if ($mode -like 'windows*') { return New-Result -Out "cubeone-os=Win32NT`r`n" }
                        return New-Result -Code 127 -Err 'powershell.exe: command not found'
                    }
                    if ($mode -eq 'windows-badkey') { return New-Result -Out 'bytes=1 hklm=skipped' }
                    return New-Result -Out "bytes=$keyLength hklm=skipped"
                }
                if ($c.InputPath -like '*stage.sh') { return New-Result -Out '/tmp/cubeone-AAAAAAAAAA' }
                if ($c.InputPath -like '*install-key.sh') {
                    if ($mode -eq 'linux-badkey') { return New-Result -Out 'bytes=1 referenced=no' }
                    return New-Result -Out "bytes=$keyLength referenced=no"
                }
                if ($mode -eq 'linux-installfail' -and $c.InputPath -like '*install.sh') { return New-Result -Code 1 -Err 'package transfer incomplete' }
                return New-Result -Out 'installed'
            }
        }

        AfterAll {
            Remove-Variable -Name HostModes -Scope Global -ErrorAction SilentlyContinue
        }

        function Invoke-WholeRun {
            param([hashtable]$Modes, [switch]$KeyOnly)
            $profileDir = Join-Path $sandbox ('profile-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $profileDir '.ssh') -Force | Out-Null
            $lines = @('Host *', '    SetEnv CUBEONE_PRINCIPAL=SYNTHETICPRINCIPAL0123456789')
            foreach ($name in $Modes.Keys) { $lines += "Host $name" }
            [System.IO.File]::WriteAllText((Join-Path $profileDir '.ssh\config'), ($lines -join "`r`n"), $utf8)
            $global:HostModes = $Modes
            $global:TestCalls.Clear()
            $params = @{ SourceDir = $packageRoot; ProfilePath = $profileDir; SkipWsl = $true }
            if ($KeyOnly) { $params['KeyOnly'] = $true }
            # Git's GNU tar (first on PATH for the bash cases) cannot read drive paths; the script needs Windows tar.
            $savedPath = $env:PATH
            $env:PATH = (Join-Path $env:windir 'System32') + ';' + $env:PATH
            try {
                $message = Get-ThrownMessage { & $modifiedScript @params 3>$null 6>$null | Out-Null }
            } finally {
                $env:PATH = $savedPath
            }
            return $message
        }

        function Get-KeyCalls {
            return @($global:TestCalls | Where-Object { $_.InputPath -like '*openrouter.key' -or $_.InputPath -like '*cubeone-opencode.tgz' })
        }

        It 'key update: all targets good ends without an error' {
            (Invoke-WholeRun -KeyOnly @{ a = 'linux'; b = 'linux' }) | Should Be ''
        }

        It 'key update: all attempted targets failing ends with an error, and no key was sent to a host that refused the login' {
            (Invoke-WholeRun -KeyOnly @{ a = 'denied'; b = 'down' }) | Should Match 'failed on 2 of 2 targets \(0 succeeded, 0 skipped\)'
            @(Get-KeyCalls).Count | Should Be 0
        }

        It 'key update: a mix of good and failing targets ends with an error naming the counts' {
            (Invoke-WholeRun -KeyOnly @{ a = 'linux'; b = 'denied'; c = 'linux-badkey' }) | Should Match 'failed on 2 of 3 targets \(1 succeeded, 0 skipped\)'
        }

        It 'key update: a Windows host gets the key only after the read-only probe, and a wrong byte count is a failure' {
            (Invoke-WholeRun -KeyOnly @{ w = 'windows' }) | Should Be ''
            $keyCalls = @(Get-KeyCalls)
            $keyCalls.Count | Should Be 1
            $keyCalls[0].Arguments | Should Match 'powershell\.exe -NoProfile -EncodedCommand '
            $probeAt = 0
            for ($i = 0; $i -lt $global:TestCalls.Count; $i++) { if ($global:TestCalls[$i].Arguments -like '*EncodedCommand*' -and $global:TestCalls[$i].InputPath -eq 'NUL') { $probeAt = $i } }
            $keyAt = [array]::IndexOf(@($global:TestCalls), $keyCalls[0])
            ($probeAt -gt 0 -and $keyAt -gt $probeAt) | Should Be $true
            (Invoke-WholeRun -KeyOnly @{ w = 'windows-badkey' }) | Should Match 'failed on 1 of 1 targets'
        }

        It 'key update: a system that is neither Linux nor Windows is skipped, not failed, and gets no key' {
            (Invoke-WholeRun -KeyOnly @{ x = 'other' }) | Should Be ''
            @(Get-KeyCalls).Count | Should Be 0
        }

        It 'key update: an unreachable host is a failure, not a non-Linux host' {
            (Invoke-WholeRun -KeyOnly @{ a = 'down' }) | Should Match 'failed on 1 of 1 targets'
            @($global:TestCalls | Where-Object { $_.Arguments -like '*EncodedCommand*' }).Count | Should Be 0
        }

        It 'key update: no hosts at all is not a failure' {
            (Invoke-WholeRun -KeyOnly @{}) | Should Be ''
        }

        It 'full setup: Windows hosts are skipped as unsupported without error, and nothing but probes reaches them' {
            (Invoke-WholeRun @{ w1 = 'windows'; w2 = 'windows' }) | Should Be ''
            @($global:TestCalls | Where-Object { $_.InputPath -ne 'NUL' }).Count | Should Be 0
        }

        It 'full setup: Windows next to a failing Linux host still ends with an error, and the failure is counted once' {
            (Invoke-WholeRun @{ w = 'windows'; l = 'linux-installfail' }) | Should Match 'failed on 1 of 1 targets \(0 succeeded, 1 skipped\)'
        }

        It 'full setup: all good, and a failing install on one of two hosts, end as expected' {
            (Invoke-WholeRun @{ a = 'linux'; b = 'linux' }) | Should Be ''
            $message = Invoke-WholeRun @{ a = 'linux'; b = 'linux-installfail' }
            $message | Should Match 'failed on 1 of 2 targets \(1 succeeded, 0 skipped\)'
            $message.Contains($syntheticKey) | Should Be $false
            $message | Should Not Match 'package transfer incomplete'
            (Invoke-WholeRun @{ a = 'denied'; b = 'down' }) | Should Match 'failed on 2 of 2 targets'
            @(Get-KeyCalls).Count | Should Be 0
        }
    }

    Context 'Remote command construction and quoting' {
        It 'accepts only staging commands and safe script arguments' {
            $target = New-RemoteTarget -Kind 'ssh' -Name 'h' -SshArguments '-F x h' -UserProfile 'C:\u'
            $global:TestBehavior = { New-Result }
            foreach ($bad in @(
                    'cat > /tmp/openrouter.key', 'cat > /tmp/cubeone-aaaaaaaaaa/../x', 'cat > /tmp/cubeone-aaaaaaaaaa/.hidden',
                    'rm -rf /tmp', 'rm -rf /tmp/cubeone-short', 'cat > /tmp/cubeone-aaaaaaaaaa/k; id', 'cat > /tmp/cubeone-aaaaaaaaaa/k"x')) {
                { Invoke-RemoteCommand -Target $target -Command $bad -InputPath 'NUL' } | Should Throw
            }
            { Invoke-RemoteScript -Target $target -InputPath 'NUL' -ScriptArguments @('a b') } | Should Throw
            { Invoke-RemoteScript -Target $target -InputPath 'NUL' -ScriptArguments @('x"y') } | Should Throw
            { Invoke-RemoteScript -Target $target -InputPath 'NUL' -ScriptArguments @('$(id)') } | Should Throw
        }

        It 'builds the wsl and ssh argument lines' {
            $global:TestBehavior = { New-Result }
            $global:TestCalls.Clear()
            $wsl = New-RemoteTarget -Kind 'wsl' -Name 'Ubuntu'
            $ssh = New-RemoteTarget -Kind 'ssh' -Name 'coding-vm-1' -SshArguments '-F "C:\u\.ssh\config" -o BatchMode=yes coding-vm-1' -UserProfile 'C:\u'
            Invoke-RemoteCommand -Target $wsl -Command 'cat > /tmp/cubeone-AbCdEfGhIj/openrouter.key' -InputPath 'k' | Out-Null
            Invoke-RemoteScript -Target $wsl -InputPath 's' -ScriptArguments @('alice', '/tmp/cubeone-AbCdEfGhIj', '5') -AsRoot | Out-Null
            Invoke-RemoteCommand -Target $ssh -Command 'rm -rf /tmp/cubeone-AbCdEfGhIj' -InputPath 'NUL' | Out-Null
            Invoke-RemoteScript -Target $ssh -InputPath 's' -ScriptArguments @('-', '/tmp/cubeone-AbCdEfGhIj') | Out-Null
            $global:TestCalls[0].Arguments | Should Be '-d Ubuntu -- bash -c "cat > /tmp/cubeone-AbCdEfGhIj/openrouter.key"'
            $global:TestCalls[1].Arguments | Should Be '-d Ubuntu -u root -- bash -s -- alice /tmp/cubeone-AbCdEfGhIj 5'
            $global:TestCalls[2].Arguments | Should Be '-F "C:\u\.ssh\config" -o BatchMode=yes coding-vm-1 "rm -rf /tmp/cubeone-AbCdEfGhIj"'
            $global:TestCalls[3].Arguments | Should Be '-F "C:\u\.ssh\config" -o BatchMode=yes coding-vm-1 bash -s -- - /tmp/cubeone-AbCdEfGhIj'
            $global:TestCalls[2].UserProfile | Should Be 'C:\u'
        }

        It 'keeps the quoted remote command in one argument through cmd.exe and delivers raw stdin' {
            $echo = Join-Path $sandbox 'echoargs.ps1'
            $echoCode = '$o = [Console]::OpenStandardInput(); $m = New-Object IO.MemoryStream; $o.CopyTo($m); ' +
                '$b = $m.ToArray(); [Console]::Out.Write((ConvertTo-Json -Compress -InputObject @{ args = @($args); len = $b.Length; first = $(if ($b.Length) { $b[0] } else { -1 }) }))'
            [System.IO.File]::WriteAllText($echo, $echoCode)
            $payload = Join-Path $sandbox 'payload.bin'
            [System.IO.File]::WriteAllBytes($payload, [byte[]](0x41, 0x42, 0x43))
            $fake = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$echo`""
            $wsl = New-RemoteTarget -Kind 'wsl' -Name 'Ubuntu'
            $global:TestCalls.Clear()
            $global:TestBehavior = { New-Result }
            Invoke-RemoteCommand -Target $wsl -Command 'cat > /tmp/cubeone-AbCdEfGhIj/openrouter.key' -InputPath $payload | Out-Null
            $argumentLine = $global:TestCalls[0].Arguments
            $real = Send-FileReal -Exe $fake -Arguments $argumentLine -InputPath $payload
            $real.Code | Should Be 0
            $parsed = $real.Out | ConvertFrom-Json
            $parsed.len | Should Be 3
            $parsed.first | Should Be 65
            @($parsed.args)[-1] | Should Be 'cat > /tmp/cubeone-AbCdEfGhIj/openrouter.key'
            @($parsed.args).Count | Should Be 6
        }
    }

    Context 'Staging lifecycle with a mocked transport' {
        BeforeEach {
            $global:TestCalls.Clear()
            $keyFile = Join-Path $sandbox 'openrouter.key'
            $tarFile = Join-Path $sandbox 'package.tgz'
            [System.IO.File]::WriteAllText($keyFile, $syntheticKey, $utf8)
            [System.IO.File]::WriteAllBytes($tarFile, [byte[]](1, 2, 3))
            $files = [ordered]@{ 'cubeone-opencode.tgz' = $tarFile; 'openrouter.key' = $keyFile }
            $stageFile = Join-Path $sandbox 'stage.sh'
            $scriptFile = Join-Path $sandbox 'install.sh'
            $dirA = '/tmp/cubeone-AAAAAAAAAA'
        }

        function Find-Cleanup {
            param([string]$Directory)
            return @($global:TestCalls | Where-Object { $_.Arguments -like "*rm -rf $Directory*" })
        }

        It 'transfers package and key into the private directory, runs the script and cleans up' {
            $global:TestBehavior = {
                param($c)
                if ($c.InputPath -eq $stageFile) { return New-Result -Out "$dirA`n" }
                return New-Result -Out 'installed'
            }
            $target = New-RemoteTarget -Kind 'wsl' -Name 'Ubuntu'
            $result = Invoke-StagedScript -Target $target -StageScriptPath $stageFile -Files $files -ScriptPath $scriptFile `
                -LeadingArguments @('alice') -TrailingArguments @(33, 3) -AsRoot
            $result.Out | Should Be 'installed'
            $global:TestCalls[1].Arguments | Should Be "-d Ubuntu -- bash -c `"cat > $dirA/cubeone-opencode.tgz`""
            $global:TestCalls[2].Arguments | Should Be "-d Ubuntu -- bash -c `"cat > $dirA/openrouter.key`""
            $global:TestCalls[3].Arguments | Should Be "-d Ubuntu -u root -- bash -s -- alice $dirA 33 3"
            @(Find-Cleanup $dirA).Count | Should Be 1
            $global:TestCalls[-1].InputPath | Should Be 'NUL'
        }

        It 'removes the directory when the key transfer fails' {
            $global:TestBehavior = {
                param($c)
                if ($c.InputPath -eq $stageFile) { return New-Result -Out $dirA }
                if ($c.InputPath -eq $keyFile) { return New-Result -Code 255 -Err 'Connection reset' }
                return New-Result
            }
            $target = New-RemoteTarget -Kind 'ssh' -Name 'h' -SshArguments '-F x h' -UserProfile 'C:\u'
            { Invoke-StagedScript -Target $target -StageScriptPath $stageFile -Files $files -ScriptPath $scriptFile } | Should Throw
            @(Find-Cleanup $dirA).Count | Should Be 1
            @($global:TestCalls | Where-Object { $_.InputPath -eq $scriptFile }).Count | Should Be 0
        }

        It 'removes the directory when the install script fails' {
            $global:TestBehavior = {
                param($c)
                if ($c.InputPath -eq $stageFile) { return New-Result -Out $dirA }
                if ($c.InputPath -eq $scriptFile) { return New-Result -Code 1 -Err 'boom' }
                return New-Result
            }
            $target = New-RemoteTarget -Kind 'ssh' -Name 'h' -SshArguments '-F x h' -UserProfile 'C:\u'
            $result = Invoke-StagedScript -Target $target -StageScriptPath $stageFile -Files $files -ScriptPath $scriptFile
            $result.Code | Should Be 1
            @(Find-Cleanup $dirA).Count | Should Be 1
        }

        It 'removes the directory when the transport throws' {
            $global:TestBehavior = {
                param($c)
                if ($c.InputPath -eq $stageFile) { return New-Result -Out $dirA }
                if ($c.InputPath -eq $tarFile) { throw 'process could not start' }
                return New-Result
            }
            $target = New-RemoteTarget -Kind 'ssh' -Name 'h' -SshArguments '-F x h' -UserProfile 'C:\u'
            { Invoke-StagedScript -Target $target -StageScriptPath $stageFile -Files $files -ScriptPath $scriptFile } | Should Throw
            @(Find-Cleanup $dirA).Count | Should Be 1
        }

        It 'does not clean up or send anything when the stage step fails or returns an odd path' {
            foreach ($stageResult in @((New-Result -Code 1 -Err 'mktemp failed'), (New-Result -Out '/tmp/evil'), (New-Result -Out '/tmp/cubeone-../etc'), (New-Result -Out ''))) {
                $global:TestCalls.Clear()
                $global:TestBehavior = { param($c) return $stageResult }.GetNewClosure()
                $target = New-RemoteTarget -Kind 'ssh' -Name 'h' -SshArguments '-F x h' -UserProfile 'C:\u'
                { Invoke-StagedScript -Target $target -StageScriptPath $stageFile -Files $files -ScriptPath $scriptFile } | Should Throw
                $global:TestCalls.Count | Should Be 1
            }
        }

        It 'treats a failed cleanup as a warning and still returns the result' {
            $global:TestBehavior = {
                param($c)
                if ($c.InputPath -eq $stageFile) { return New-Result -Out $dirA }
                if ($c.Arguments -like '*rm -rf*') { throw 'ssh vanished' }
                return New-Result -Out 'ok'
            }
            $target = New-RemoteTarget -Kind 'ssh' -Name 'h' -SshArguments '-F x h' -UserProfile 'C:\u'
            $result = Invoke-StagedScript -Target $target -StageScriptPath $stageFile -Files $files -ScriptPath $scriptFile 3>$null
            $result.Out | Should Be 'ok'
        }

        It 'gives parallel targets and repeated runs their own directory and removes only that one' {
            $global:TestBehavior = {
                param($c)
                if ($c.InputPath -eq $stageFile) {
                    if ($c.Arguments -like '*Ubuntu*') { return New-Result -Out '/tmp/cubeone-WSLWSLWSL1' }
                    return New-Result -Out '/tmp/cubeone-SSHSSHSSH2'
                }
                if ($c.InputPath -eq $scriptFile -and $c.Arguments -like '*Ubuntu*') { return New-Result -Code 1 -Err 'fail' }
                return New-Result
            }
            $wsl = New-RemoteTarget -Kind 'wsl' -Name 'Ubuntu'
            $ssh = New-RemoteTarget -Kind 'ssh' -Name 'h' -SshArguments '-F x h' -UserProfile 'C:\u'
            Invoke-StagedScript -Target $wsl -StageScriptPath $stageFile -Files $files -ScriptPath $scriptFile -AsRoot | Out-Null
            Invoke-StagedScript -Target $ssh -StageScriptPath $stageFile -Files $files -ScriptPath $scriptFile | Out-Null
            @(Find-Cleanup '/tmp/cubeone-WSLWSLWSL1').Count | Should Be 1
            @(Find-Cleanup '/tmp/cubeone-SSHSSHSSH2').Count | Should Be 1
            @($global:TestCalls | Where-Object { $_.Arguments -like '*Ubuntu*' -and $_.Arguments -like '*SSHSSHSSH2*' }).Count | Should Be 0
            @($global:TestCalls | Where-Object { $_.Arguments -notlike '*Ubuntu*' -and $_.Arguments -like '*WSLWSLWSL1*' }).Count | Should Be 0
        }

        It 'never puts the key or its content on a command line' {
            $global:TestBehavior = {
                param($c)
                if ($c.InputPath -eq $stageFile) { return New-Result -Out $dirA }
                return New-Result -Out 'installed'
            }
            $target = New-RemoteTarget -Kind 'ssh' -Name 'h' -SshArguments '-F x h' -UserProfile 'C:\u'
            Invoke-StagedScript -Target $target -StageScriptPath $stageFile -Files $files -ScriptPath $scriptFile | Out-Null
            foreach ($call in $global:TestCalls) {
                $call.Arguments.Contains($syntheticKey) | Should Be $false
            }
        }

        It 'does not leak the key through a failed transfer message' {
            $global:TestBehavior = {
                param($c)
                if ($c.InputPath -eq $stageFile) { return New-Result -Out $dirA }
                if ($c.InputPath -eq $keyFile) { return New-Result -Code 1 -Err 'cat: write error' }
                return New-Result
            }
            $target = New-RemoteTarget -Kind 'ssh' -Name 'h' -SshArguments '-F x h' -UserProfile 'C:\u'
            $message = ''
            try {
                Invoke-StagedScript -Target $target -StageScriptPath $stageFile -Files $files -ScriptPath $scriptFile | Out-Null
            } catch {
                $message = $_.Exception.Message
            }
            $message.Contains($syntheticKey) | Should Be $false
            $message | Should Match 'openrouter.key'
        }
    }

    Context 'Remote scripts in bash (sandbox HOME)' {
        BeforeEach {
            $homeDir = Join-Path $sandbox ('home-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $homeDir -Force | Out-Null
            $keyPayload = Join-Path $sandbox 'k.bin'
            [System.IO.File]::WriteAllText($keyPayload, $syntheticKey, $utf8)
            $keyLength = $utf8.GetByteCount($syntheticKey)
            $keyScript = Join-Path $sandbox 'install-key.sh'
            Write-LfFile $keyScript $linuxSh
        }

        function New-StageWithFiles {
            param([hashtable]$Content)
            $stageResult = New-LocalStage -HomeDir $HomeDir
            $stageResult.Code | Should Be 0
            $posix = $stageResult.Out.Trim()
            $posix | Should Match '^/tmp/cubeone-[A-Za-z0-9]{10}$'
            $windows = Get-WindowsPath $posix
            Test-Path -LiteralPath $windows | Should Be $true
            foreach ($name in $Content.Keys) {
                [System.IO.File]::WriteAllBytes((Join-Path $windows $name), $Content[$name])
            }
            return [pscustomobject]@{ Posix = $posix; Windows = $windows }
        }

        It 'stage script creates distinct private directories, also when run in parallel' -Skip:(-not $haveBash) {
            $stage = Join-Path $sandbox 'stage.sh'
            Write-LfFile $stage $stageSh
            $processes = 1..4 | ForEach-Object {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $bashExe
                $psi.Arguments = "`"$stage`""
                $psi.UseShellExecute = $false
                $psi.RedirectStandardInput = $true
                $psi.RedirectStandardOutput = $true
                $psi.CreateNoWindow = $true
                $psi.EnvironmentVariables['HOME'] = $homeDir
                $process = [System.Diagnostics.Process]::Start($psi)
                $process.StandardInput.Close()
                $process
            }
            $paths = @($processes | ForEach-Object {
                $out = $_.StandardOutput.ReadToEnd()
                [void]$_.WaitForExit(30000)
                $out.Trim()
            })
            try {
                $paths.Count | Should Be 4
                @($paths | Select-Object -Unique).Count | Should Be 4
                foreach ($path in $paths) {
                    $path | Should Match '^/tmp/cubeone-[A-Za-z0-9]{10}$'
                    Test-Path -LiteralPath (Get-WindowsPath $path) | Should Be $true
                }
            } finally {
                foreach ($path in $paths) { Remove-Item -LiteralPath (Get-WindowsPath $path) -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        It 'key script installs the key atomically, leaves no temp file, prints no key, removes the inbox' -Skip:(-not $haveBash) {
            $stage = New-StageWithFiles @{ 'openrouter.key' = [System.IO.File]::ReadAllBytes($keyPayload) }
            $personDir = Join-Path $homeDir '.local\config\opencode-people\abc\opencode'
            New-Item -ItemType Directory -Path $personDir -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $personDir 'openrouter.key'), 'old', $utf8)
            $result = Invoke-LocalBash -Script $keyScript -HomeDir $HomeDir -ScriptArguments @($stage.Posix, $keyLength)
            $result.Code | Should Be 0
            $result.Out.Trim() | Should Be "bytes=$keyLength referenced=no"
            ($result.Out + $result.Err).Contains($syntheticKey) | Should Be $false
            [System.IO.File]::ReadAllText((Join-Path $homeDir '.config\opencode\openrouter.key')) | Should Be $syntheticKey
            [System.IO.File]::ReadAllText((Join-Path $personDir 'openrouter.key')) | Should Be $syntheticKey
            @(Get-ChildItem -LiteralPath (Join-Path $homeDir '.config\opencode') -Force | Where-Object { $_.Name -like '.openrouter.key.*' }).Count | Should Be 0
            Test-Path -LiteralPath $stage.Windows | Should Be $false
        }

        It 'key script keeps the old key and removes the inbox when the transfer is incomplete' -Skip:(-not $haveBash) {
            New-Item -ItemType Directory -Path (Join-Path $homeDir '.config\opencode') -Force | Out-Null
            $existing = Join-Path $homeDir '.config\opencode\openrouter.key'
            [System.IO.File]::WriteAllText($existing, 'previous-key', $utf8)
            $partial = [System.Text.Encoding]::UTF8.GetBytes($syntheticKey.Substring(0, 10))
            $stage = New-StageWithFiles @{ 'openrouter.key' = $partial }
            $result = Invoke-LocalBash -Script $keyScript -HomeDir $HomeDir -ScriptArguments @($stage.Posix, $keyLength)
            $result.Code | Should Not Be 0
            $result.Err | Should Match 'incomplete'
            [System.IO.File]::ReadAllText($existing) | Should Be 'previous-key'
            Test-Path -LiteralPath $stage.Windows | Should Be $false
        }

        It 'key script replaces the destination by rename (no write-through) and refuses a directory' -Skip:(-not $haveBash) {
            New-Item -ItemType Directory -Path (Join-Path $homeDir '.config\opencode') -Force | Out-Null
            $victim = Join-Path $homeDir 'victim.txt'
            [System.IO.File]::WriteAllText($victim, 'untouched', $utf8)
            $destination = Join-Path $homeDir '.config\opencode\openrouter.key'
            # A hard link stands in for a planted link: writing through it would change the victim file.
            # Windows cannot create symlinks without privileges; the rename logic is the same.
            $linkScript = Join-Path $sandbox 'mklink.sh'
            Write-LfFile $linkScript "ln `"`$HOME/victim.txt`" `"`$HOME/.config/opencode/openrouter.key`""
            $link = Invoke-LocalBash -Script $linkScript -HomeDir $homeDir
            $link.Code | Should Be 0
            $stage = New-StageWithFiles @{ 'openrouter.key' = [System.IO.File]::ReadAllBytes($keyPayload) }
            $result = Invoke-LocalBash -Script $keyScript -HomeDir $homeDir -ScriptArguments @($stage.Posix, $keyLength)
            $result.Code | Should Be 0
            [System.IO.File]::ReadAllText($victim) | Should Be 'untouched'
            [System.IO.File]::ReadAllText($destination) | Should Be $syntheticKey
            Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            $stage = New-StageWithFiles @{ 'openrouter.key' = [System.IO.File]::ReadAllBytes($keyPayload) }
            $result = Invoke-LocalBash -Script $keyScript -HomeDir $homeDir -ScriptArguments @($stage.Posix, $keyLength)
            $result.Code | Should Not Be 0
            Test-Path -LiteralPath $stage.Windows | Should Be $false
        }
        It 'refuses a foreign, symlinked or malformed staging path and does not delete it' -Skip:(-not $haveBash) {
            $decoy = Join-Path $sandbox 'decoy'
            New-Item -ItemType Directory -Path $decoy -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $decoy 'openrouter.key'), $syntheticKey, $utf8)
            $decoyPosix = (& $cygpath -u $decoy).Trim()
            foreach ($bad in @($decoyPosix, '/tmp/cubeone-short', '/tmp/cubeone-../x', '/tmp/cubeone-AAAAAAAAAA', '/tmp/cubeone-AAAAAAAAAAA')) {
                $result = Invoke-LocalBash -Script $keyScript -HomeDir $HomeDir -ScriptArguments @($bad, $keyLength)
                $result.Code | Should Not Be 0
                $result.Err | Should Match 'invalid or foreign'
            }
            Test-Path -LiteralPath (Join-Path $decoy 'openrouter.key') | Should Be $true
            Test-Path -LiteralPath (Join-Path $homeDir '.config\opencode\openrouter.key') | Should Be $false
        }

        It 'full install script installs package and key, then removes the staging directory' -Skip:(-not $haveBash) {
            $payload = Join-Path $sandbox ('payload-' + [guid]::NewGuid().ToString('N'))
            foreach ($dir in @('rules', 'vorgaben', 'cubeone', 'user\vorgaben')) { New-Item -ItemType Directory -Path (Join-Path $payload $dir) -Force | Out-Null }
            [System.IO.File]::WriteAllText((Join-Path $payload 'rules\a.md'), 'rule', $utf8)
            [System.IO.File]::WriteAllText((Join-Path $payload 'vorgaben\v.md'), 'v', $utf8)
            [System.IO.File]::WriteAllText((Join-Path $payload 'cubeone\x.txt'), 'x', $utf8)
            [System.IO.File]::WriteAllText((Join-Path $payload 'opencode.jsonc'), '{ "root": "__CUBEONE_ROOT__" }', $utf8)
            [System.IO.File]::WriteAllText((Join-Path $payload 'user\opencode.jsonc'), '{"mcp":{"servers":{"trace":{"type":"remote","url":"https://trace.example/mcp"},"custom":{"type":"remote","url":"https://template.example/mcp"}}}}', $utf8)
            New-Item -ItemType Directory -Path (Join-Path $payload 'user\rules\optional') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $payload 'user\rules\optional\existing.md'), 'template', $utf8)
            [System.IO.File]::WriteAllText((Join-Path $payload 'user\rules\optional\added.md'), 'new rule', $utf8)
            New-Item -ItemType Directory -Path (Join-Path $homeDir '.config\opencode\rules\optional') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $homeDir '.config\opencode\vorgaben') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $homeDir '.config\opencode\rules\optional\existing.md'), 'edited', $utf8)
            [System.IO.File]::WriteAllText((Join-Path $homeDir '.config\opencode\rules\optional\personal.md'), 'personal', $utf8)
            [System.IO.File]::WriteAllText((Join-Path $homeDir '.config\opencode\vorgaben\design.md'), 'personal design', $utf8)
            [System.IO.File]::WriteAllText((Join-Path $homeDir '.config\opencode\opencode.json'), '{/* comment */"example":"literal,}","mcp":{"servers":{"custom":{"type":"remote","url":"https://personal.example/mcp"},},},}', $utf8)
            $tgz = Join-Path $sandbox ('pkg-' + [guid]::NewGuid().ToString('N') + '.tgz')
            & (Join-Path $env:windir 'System32\tar.exe') -czf $tgz -C $payload .
            $tgzBytes = (Get-Item -LiteralPath $tgz).Length
            # The test copy writes into the sandbox instead of /etc/opencode.
            $installText = $installSh.Replace('ROOT=/etc/opencode', 'ROOT="$HOME/etc-opencode"')
            $installText.Contains('etc-opencode') | Should Be $true
            $installFile = Join-Path $sandbox 'install-full.sh'
            Write-LfFile $installFile $installText

            $stage = New-StageWithFiles @{ 'openrouter.key' = [System.IO.File]::ReadAllBytes($keyPayload); 'cubeone-opencode.tgz' = [System.IO.File]::ReadAllBytes($tgz) }
            $result = Invoke-LocalBash -Script $installFile -HomeDir $HomeDir -ScriptArguments @('-', $stage.Posix, $keyLength, $tgzBytes)
            $result.Code | Should Be 0
            ($result.Out + $result.Err).Contains($syntheticKey) | Should Be $false
            [System.IO.File]::ReadAllText((Join-Path $homeDir '.config\opencode\openrouter.key')) | Should Be $syntheticKey
            Test-Path -LiteralPath (Join-Path $homeDir 'etc-opencode\rules\a.md') | Should Be $true
            Test-Path -LiteralPath $stage.Windows | Should Be $false
            @(Get-ChildItem -LiteralPath (Join-Path $homeDir '.config\opencode') -Force | Where-Object { $_.Name -like '.openrouter.key.*' }).Count | Should Be 0

            $personal = Get-Content -Raw -LiteralPath (Join-Path $homeDir '.config\opencode\opencode.json') | ConvertFrom-Json
            $personal.example | Should Be 'literal,}'
            $personal.mcp.servers.custom.url | Should Be 'https://personal.example/mcp'
            $personal.mcp.servers.trace.url | Should Be 'https://trace.example/mcp'
            Test-Path -LiteralPath (Join-Path $homeDir '.config\opencode\opencode.jsonc') | Should Be $false
            [System.IO.File]::ReadAllText((Join-Path $homeDir '.config\opencode\rules\optional\existing.md')) | Should Be 'edited'
            [System.IO.File]::ReadAllText((Join-Path $homeDir '.config\opencode\rules\optional\personal.md')) | Should Be 'personal'
            [System.IO.File]::ReadAllText((Join-Path $homeDir '.config\opencode\vorgaben\design.md')) | Should Be 'personal design'
            Test-Path -LiteralPath (Join-Path $homeDir '.config\opencode\rules\optional\added.md') | Should Be $true

            # Wrong package size: nothing is installed or changed, the staging directory is gone anyway.
            $stage = New-StageWithFiles @{ 'openrouter.key' = [System.IO.File]::ReadAllBytes($keyPayload); 'cubeone-opencode.tgz' = [System.IO.File]::ReadAllBytes($tgz) }
            $result = Invoke-LocalBash -Script $installFile -HomeDir $HomeDir -ScriptArguments @('-', $stage.Posix, $keyLength, ($tgzBytes + 1))
            $result.Code | Should Not Be 0
            $result.Err | Should Match 'incomplete'
            Test-Path -LiteralPath $stage.Windows | Should Be $false

            # Missing or empty expected key fails before changing the installed configuration.
            foreach ($emptyKey in @($false, $true)) {
                $files = @{ 'cubeone-opencode.tgz' = [System.IO.File]::ReadAllBytes($tgz) }
                if ($emptyKey) { $files['openrouter.key'] = [byte[]]@() }
                $stage = New-StageWithFiles $files
                $before = [System.IO.File]::ReadAllText((Join-Path $homeDir 'etc-opencode\opencode.jsonc'))
                $result = Invoke-LocalBash -Script $installFile -HomeDir $HomeDir -ScriptArguments @('-', $stage.Posix, $keyLength, $tgzBytes)
                $result.Code | Should Not Be 0
                $result.Err | Should Match 'key transfer incomplete'
                [System.IO.File]::ReadAllText((Join-Path $homeDir 'etc-opencode\opencode.jsonc')) | Should Be $before
                Test-Path -LiteralPath $stage.Windows | Should Be $false
            }

            # Key size mismatch before installation: old key stays, staging directory removed.
            [System.IO.File]::WriteAllText((Join-Path $homeDir '.config\opencode\openrouter.key'), 'previous-key', $utf8)
            $stage = New-StageWithFiles @{ 'openrouter.key' = [System.Text.Encoding]::UTF8.GetBytes('short'); 'cubeone-opencode.tgz' = [System.IO.File]::ReadAllBytes($tgz) }
            $result = Invoke-LocalBash -Script $installFile -HomeDir $HomeDir -ScriptArguments @('-', $stage.Posix, $keyLength, $tgzBytes)
            $result.Code | Should Not Be 0
            [System.IO.File]::ReadAllText((Join-Path $homeDir '.config\opencode\openrouter.key')) | Should Be 'previous-key'
            Test-Path -LiteralPath $stage.Windows | Should Be $false
        }
    }
}
