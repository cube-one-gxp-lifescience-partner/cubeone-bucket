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
            'Get-CurrentIdentitySid', 'Get-ProfileImagePath', 'Assert-ProfileUserContext', 'Get-FailureClass', 'Get-SshHostOs', 'Assert-RemoteRunSucceeded',
            'Get-SshExecutable', 'Invoke-SshConfigDump', 'Get-EffectiveSshSettings', 'Get-BomLength', 'Assert-SshConfigSafeToEvaluate',
            'Get-PrincipalPlan', 'New-PrincipalConfigBytes', 'Assert-PrincipalConfigEffective', 'Set-DesktopPrincipal'
        )
        $variableNames = @(
            'nullInput', 'stageDirPattern', 'stageCommandPattern', 'scriptArgPattern',
            'stageSh', 'commonSh', 'installBodySh', 'installSh', 'linuxSh',
            'failureClasses', 'sshErrorClass', 'unclassifiedClass', 'windowsProbePs', 'windowsProbeEncoded',
            'principalAliases', 'principalProbeAlias', 'principalVariable', 'principalPattern', 'principalHandEdit'
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

        # Shared by the SSH config cases. Real `ssh.exe -G` runs on temporary configs only (offline, no connection).
        $haveSsh = [bool](Get-Command -Name 'ssh.exe' -CommandType Application -ErrorAction SilentlyContinue)
        $latin1 = [System.Text.Encoding]::GetEncoding(28591)
        $bom = [byte[]](0xEF, 0xBB, 0xBF)
        $aliases = @(1..8 | ForEach-Object { "coding-vm-$_" })
        $allHosts = 'Host ' + ($aliases -join ' ')
        $hostLine = $allHosts
        $validId = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ012345'

        function New-ConfigFile {
            param([byte[]]$Bytes, [string]$Folder = 'profile')
            $directory = Join-Path $sandbox ($Folder + '-' + [guid]::NewGuid().ToString('N')) | Join-Path -ChildPath '.ssh'
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $path = Join-Path $directory 'config'
            [System.IO.File]::WriteAllBytes($path, $Bytes)
            return $path
        }
        function Get-Latin1Bytes {
            param([string]$Text)
            return $latin1.GetBytes($Text)
        }
        function Get-FileSddl {
            # Owner, group and DACL as SDDL, read from the file directly. Get-Acl needs PowerShell's ObjectSecurity type
            # data, which fails to load on some installations ("Das Element Sddl ist bereits vorhanden").
            param([string]$Path)
            $sections = [System.Security.AccessControl.AccessControlSections]'Access,Owner,Group'
            $info = New-Object System.IO.FileInfo $Path
            if ($info.PSObject.Methods['GetAccessControl']) { $security = $info.GetAccessControl($sections) }
            else { $security = [System.IO.FileSystemAclExtensions]::GetAccessControl($info) }
            return $security.GetSecurityDescriptorSddlForm($sections)
        }
        function Get-FileSha {
            param([string]$Path)
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        }
        function Join-Bytes {
            param([byte[][]]$Part)
            $stream = New-Object System.IO.MemoryStream
            foreach ($item in $Part) { $stream.Write($item, 0, $item.Length) }
            return $stream.ToArray()
        }
        function Assert-HandEditGuidance {
            # The by-hand advice must keep existing settings: reuse an id, merge into the first SetEnv line that
            # applies, restore Host * after a prefix, and never tell to remove Include or Match exec.
            param([string]$Message)
            $Message | Should Match 'by hand'
            $Message | Should Match 'keep an id that already exists'
            $Message | Should Match 'NewGuid\(\)\.ToString\(.N.\)'
            $Message | Should Match 'first SetEnv line that applies to each of these hosts'
            $Message | Should Match 'keep the variables and the Host scope'
            $Message | Should Match 'followed by .Host \*., in front of the old settings'
            foreach ($alias in $aliases) { $Message.Contains($alias) | Should Be $true }
            $Message | Should Not Match '(?i)\bremove\b|\bdelete\b|two lines'
        }
        function Get-AliasSetEnv {
            param([string]$Path, [string]$Alias)
            return (@((Get-EffectiveSshSettings -ConfigPath $Path -Alias $Alias).SetEnv) -join ';')
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

    Context 'Safe reading of the SSH config (nothing is run before it is known to be safe)' {
        It 'refuses Include and every Match line with exec, in any spelling, and allows the rest' {
            $refused = @(
                'Include config.d/*', "  include=other`r`nHost a", 'Include "a b"', "Host a`r`n`tINCLUDE x",
                'Match exec "echo hi"', 'match host a exec x', 'Match "exec" y', "Match=exec x", '  Match all exec "x y"',
                "# comment`r`nMatch user bob exec cmd")
            foreach ($text in $refused) {
                $message = Get-ThrownMessage { Assert-SshConfigSafeToEvaluate -Text $text -ConfigPath 'C:\u\.ssh\config' }
                $message | Should Match 'C:\\u\\\.ssh\\config'
                $message | Should Match 'Include|exec'
                Assert-HandEditGuidance $message
            }
            $allowed = @(
                "# Include other`r`n# Match exec x", 'Host exec-server', 'HostName Include', 'Match host exec.example.com',
                "Match host foo`r`n  Port 22", 'Host a b', "SendEnv LANG", '')
            foreach ($text in $allowed) {
                { Assert-SshConfigSafeToEvaluate -Text $text -ConfigPath 'C:\u\.ssh\config' } | Should Not Throw
            }
        }

        It 'does not start ssh at all for a config with Include or Match exec, and leaves the file unchanged' {
            $global:DumpCalls = 0
            function Invoke-SshConfigDump { $global:DumpCalls++; throw 'ssh must not be started' }
            foreach ($content in @("Include config.d/*`r`nHost coding-vm-1`r`n", "Host a`r`nMatch exec `"cmd /c echo x`"`r`n  User q`r`n")) {
                $path = New-ConfigFile -Bytes (Get-Latin1Bytes $content)
                $before = Get-FileSha $path
                Assert-HandEditGuidance (Get-ThrownMessage { Set-DesktopPrincipal -ConfigPath $path 6>$null })
                Get-FileSha $path | Should Be $before
            }
            $global:DumpCalls | Should Be 0
            Remove-Variable -Name DumpCalls -Scope Global
        }

        It 'a Match exec command is not executed (a real command that would leave a marker file)' -Skip:(-not $haveSsh) {
            $marker = Join-Path $sandbox ('marker-' + [guid]::NewGuid().ToString('N') + '.txt')
            $path = New-ConfigFile -Bytes (Get-Latin1Bytes ("Match exec `"cmd /c echo x > $marker`"`r`n  User q`r`nHost coding-vm-1`r`n"))
            $before = Get-FileSha $path
            $message = Get-ThrownMessage { Set-DesktopPrincipal -ConfigPath $path 6>$null }
            $message | Should Match 'Match line with exec'
            Assert-HandEditGuidance $message
            Test-Path -LiteralPath $marker | Should Be $false
            Get-FileSha $path | Should Be $before
        }

        It 'runs only offline ssh -G with the exact arguments, reads no stdin, and never reports ssh output' {
            $fakeDir = Join-Path $sandbox ('fake-ssh-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $fakeDir | Out-Null
            $fake = Join-Path $fakeDir 'ssh.cmd'
            [System.IO.File]::WriteAllText($fake, "@echo off`r`necho %* >>`"%~dp0args.log`"`r`nif exist `"%~dp0fail.txt`" (echo SECRET-STDERR-LINE 1>&2& echo SECRET-STDOUT-LINE& exit /b 255)`r`necho hostname x`r`necho setenv A=1`r`n")
            $global:FakeSsh = $fake
            function Get-SshExecutable { return $global:FakeSsh }
            $config = Join-Path $fakeDir 'my profile\.ssh\config'
            $lines = Invoke-SshConfigDump -ConfigPath $config -Alias 'coding-vm-1'
            ($lines -join '|') | Should Be 'hostname x|setenv A=1'
            $logged = [System.IO.File]::ReadAllText((Join-Path $fakeDir 'args.log')).Trim()
            # cmd.exe writes the log in the console code page, so non-ASCII characters of the path read back as ?
            ($logged -replace '[^\x20-\x7E]', '?') | Should Be (('-G -F "' + $config + '" -o CanonicalizeHostname=no coding-vm-1') -replace '[^\x20-\x7E]', '?')
            [regex]::IsMatch($logged, '(^| )-(v+|T|N|n|W|L|R|D)( |$)') | Should Be $false
            $settings = Get-EffectiveSshSettings -ConfigPath $config -Alias 'coding-vm-2'
            ($settings.SetEnv -join '|') | Should Be 'A=1'
            [System.IO.File]::WriteAllText((Join-Path $fakeDir 'fail.txt'), 'x')
            $message = Get-ThrownMessage { Invoke-SshConfigDump -ConfigPath $config -Alias 'coding-vm-1' }
            $message | Should Match 'could not read the SSH config'
            $message | Should Match 'exit 255'
            $message.Contains('SECRET') | Should Be $false
            Remove-Variable -Name FakeSsh -Scope Global
        }

        It 'ends a hanging ssh -G after the timeout, stops that process, and reports nothing of its output' {
            # A direct cmd.exe that only loops: no child process, so killing it leaves nothing behind.
            $fakeDir = Join-Path $sandbox ('hang-ssh-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $fakeDir | Out-Null
            $fake = Join-Path $fakeDir 'ssh.cmd'
            [System.IO.File]::WriteAllText($fake, "@echo off`r`necho SECRET-OUTPUT-LINE`r`necho SECRET-STDERR-LINE 1>&2`r`n:loop`r`ngoto loop`r`n")
            $global:FakeSsh = $fake
            function Get-SshExecutable { return $global:FakeSsh }
            try {
                $watch = [System.Diagnostics.Stopwatch]::StartNew()
                $message = Get-ThrownMessage { Invoke-SshConfigDump -ConfigPath 'C:\u\.ssh\config' -Alias 'coding-vm-1' -TimeoutMilliseconds 300 }
                $watch.Stop()
                $message | Should Match 'did not finish within 300 ms'
                $message | Should Match 'It was not changed'
                $message.Contains('SECRET') | Should Be $false
                ($watch.Elapsed.TotalSeconds -lt 20) | Should Be $true
                Start-Sleep -Milliseconds 500
                $left = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'cmd.exe'" | Where-Object { $_.CommandLine -like "*$fakeDir*" })
                $left.Count | Should Be 0
            } finally {
                Get-CimInstance -ClassName Win32_Process -Filter "Name = 'cmd.exe'" | Where-Object { $_.CommandLine -like "*$fakeDir*" } |
                    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                Remove-Variable -Name FakeSsh -Scope Global
            }
        }

        It 'fails Set-DesktopPrincipal on a hanging ssh -G without changing the file' {
            $fakeDir = Join-Path $sandbox ('hang-ssh-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $fakeDir | Out-Null
            $fake = Join-Path $fakeDir 'ssh.cmd'
            [System.IO.File]::WriteAllText($fake, "@echo off`r`n:loop`r`ngoto loop`r`n")
            $global:FakeSsh = $fake
            function Get-SshExecutable { return $global:FakeSsh }
            # The default timeout is long; the test caller passes a short one through a wrapper of the same name.
            $real = ${function:Invoke-SshConfigDump}
            function Invoke-SshConfigDump { param([string]$ConfigPath, [string]$Alias) & $real -ConfigPath $ConfigPath -Alias $Alias -TimeoutMilliseconds 300 }
            try {
                $path = New-ConfigFile -Bytes (Get-Latin1Bytes "Host foo`r`n")
                $before = Get-FileSha $path
                (Get-ThrownMessage { Set-DesktopPrincipal -ConfigPath $path 6>$null }) | Should Match 'did not finish'
                Get-FileSha $path | Should Be $before
            } finally {
                Get-CimInstance -ClassName Win32_Process -Filter "Name = 'cmd.exe'" | Where-Object { $_.CommandLine -like "*$fakeDir*" } |
                    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                Remove-Variable -Name FakeSsh -Scope Global
            }
        }

        It 'reads a large stdout and a large stderr at the same time without blocking, and the timeout defaults to 30 seconds' {
            $fakeDir = Join-Path $sandbox ('big-ssh-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $fakeDir | Out-Null
            $fake = Join-Path $fakeDir 'ssh.cmd'
            $line = '0123456789' * 8
            [System.IO.File]::WriteAllText($fake, "@echo off`r`nfor /l %%i in (1,1,1500) do (echo err $line 1>&2& echo out $line)`r`necho hostname x`r`n")
            $global:FakeSsh = $fake
            function Get-SshExecutable { return $global:FakeSsh }
            try {
                $lines = Invoke-SshConfigDump -ConfigPath 'C:\u\.ssh\config' -Alias 'coding-vm-1' -TimeoutMilliseconds 60000
                $lines.Count | Should Be 1501
                $lines[-1] | Should Be 'hostname x'
            } finally {
                Remove-Variable -Name FakeSsh -Scope Global
            }
            $parameter = (Get-Command Invoke-SshConfigDump).Parameters['TimeoutMilliseconds']
            $parameter.ParameterType.Name | Should Be 'Int32'
            ([System.IO.File]::ReadAllText($scriptPath)) | Should Match '\[int\]\$TimeoutMilliseconds = 30000'
        }
        It 'refuses to continue when ssh.exe is missing, and changes nothing' {
            function Get-SshExecutable { throw 'ssh.exe (Windows OpenSSH client) was not found. It is needed to read the SSH config offline. The SSH config was not changed.' }
            $path = New-ConfigFile -Bytes (Get-Latin1Bytes "Host foo`r`n")
            $before = Get-FileSha $path
            (Get-ThrownMessage { Set-DesktopPrincipal -ConfigPath $path 6>$null }) | Should Match 'ssh.exe .* was not found'
            Get-FileSha $path | Should Be $before
        }
    }

    Context 'Personal id in the SSH config (Set-DesktopPrincipal, effective settings from ssh -G)' {
        It 'writes the block first, restores Host *, and keeps every original byte (BOM, CRLF, non-UTF-8 text, non-ASCII spaced path)' -Skip:(-not $haveSsh) {
            $original = Join-Bytes $bom, (Get-Latin1Bytes ("# Kommentar $([char]0xE4)$([char]0xF6) alt`r`nServerAliveInterval 30`r`nHost foo`r`n    HostName 192.0.2.7`r`n"))
            $path = New-ConfigFile -Bytes $original -Folder "Pr$([char]0xFC)fung Benutzer $([char]0xE4)"
            $path | Should Match ' '
            $path | Should Match '[^\x00-\x7F]'
            Set-DesktopPrincipal -ConfigPath $path 6>$null
            $after = [System.IO.File]::ReadAllBytes($path)
            $after[0..2] -join ',' | Should Be '239,187,191'
            $head = $latin1.GetString($after, 3, $after.Length - 3 - ($original.Length - 3))
            $head | Should Match ('^' + [regex]::Escape($hostLine) + '\r\n    SetEnv CUBEONE_PRINCIPAL=[A-Za-z0-9_-]{32}\r\n\r\nHost \*\r\n$')
            [Convert]::ToBase64String($after[($after.Length - ($original.Length - 3))..($after.Length - 1)]) | Should Be ([Convert]::ToBase64String($original[3..($original.Length - 1)]))
            $id = [regex]::Match($head, 'CUBEONE_PRINCIPAL=(\S+)').Groups[1].Value
            foreach ($alias in $aliases) { Get-AliasSetEnv $path $alias | Should Be "CUBEONE_PRINCIPAL=$id" }
        }

        It 'follows the line endings of the file, and an empty or BOM-only file gets just the block' -Skip:(-not $haveSsh) {
            $path = New-ConfigFile -Bytes (Get-Latin1Bytes "Host foo`n    HostName 192.0.2.7`n")
            Set-DesktopPrincipal -ConfigPath $path 6>$null
            $text = $latin1.GetString([System.IO.File]::ReadAllBytes($path))
            $text | Should Match ('^' + [regex]::Escape($hostLine) + '\n    SetEnv CUBEONE_PRINCIPAL=[A-Za-z0-9_-]{32}\n\nHost \*\nHost foo\n    HostName 192\.0\.2\.7\n$')
            $text.Contains("`r") | Should Be $false
            $empty = New-ConfigFile -Bytes ([byte[]]@())
            Set-DesktopPrincipal -ConfigPath $empty 6>$null
            ($latin1.GetString([System.IO.File]::ReadAllBytes($empty))) | Should Match ('^' + [regex]::Escape($hostLine) + '\r\n    SetEnv CUBEONE_PRINCIPAL=[A-Za-z0-9_-]{32}\r\n$')
            $bomOnly = New-ConfigFile -Bytes $bom
            Set-DesktopPrincipal -ConfigPath $bomOnly 6>$null
            $bytes = [System.IO.File]::ReadAllBytes($bomOnly)
            $bytes[0..2] -join ',' | Should Be '239,187,191'
            ($latin1.GetString($bytes, 3, $bytes.Length - 3)) | Should Match ('^' + [regex]::Escape($hostLine))
        }

        It 'keeps global settings global: every other effective setting of the eight aliases and of unrelated aliases is unchanged' -Skip:(-not $haveSsh) {
            $content = "# header`r`nUser bob`r`nPort 2222`r`nServerAliveInterval 30`r`nHost foo`r`n    HostName 192.0.2.7`r`nMatch host never-matches`r`n    Port 1`r`n"
            $path = New-ConfigFile -Bytes (Get-Latin1Bytes $content)
            $names = @($aliases) + 'foo', 'other-alias', 'never-matches'
            $before = @{}
            foreach ($name in $names) { $before[$name] = Get-EffectiveSshSettings -ConfigPath $path -Alias $name }
            Set-DesktopPrincipal -ConfigPath $path 6>$null
            foreach ($name in $names) {
                $after = Get-EffectiveSshSettings -ConfigPath $path -Alias $name
                $after.Other | Should Be $before[$name].Other
                if ($aliases -contains $name) {
                    $after.SetEnv.Count | Should Be 1
                    $after.SetEnv[0] | Should Match '^CUBEONE_PRINCIPAL=[A-Za-z0-9_-]{32}$'
                } else {
                    (@($after.SetEnv) -join ';') | Should Be (@($before[$name].SetEnv) -join ';')
                }
            }
            (Get-EffectiveSshSettings -ConfigPath $path -Alias 'coding-vm-1').Other | Should Match 'user bob'
            (Get-EffectiveSshSettings -ConfigPath $path -Alias 'foo').Other | Should Match 'hostname 192\.0\.2\.7'
            (Get-EffectiveSshSettings -ConfigPath $path -Alias 'other-alias').Other | Should Match 'hostname other-alias'
        }

        It 'evaluates a Match line without exec and still writes' -Skip:(-not $haveSsh) {
            $path = New-ConfigFile -Bytes (Get-Latin1Bytes "Match host coding-vm-2`r`n    Port 2200`r`nHost foo`r`n")
            Set-DesktopPrincipal -ConfigPath $path 6>$null
            (Get-EffectiveSshSettings -ConfigPath $path -Alias 'coding-vm-2').Other | Should Match 'port 2200'
            (Get-EffectiveSshSettings -ConfigPath $path -Alias 'coding-vm-1').Other | Should Match 'port 22(\r?\n|$)'
            Get-AliasSetEnv $path 'coding-vm-2' | Should Match '^CUBEONE_PRINCIPAL=[A-Za-z0-9_-]{32}$'
        }

        It 'does nothing when all eight aliases already get the same valid id, also quoted, with other variables, or from Host *' -Skip:(-not $haveSsh) {
            foreach ($content in @(
                    "Host *`r`n    SetEnv CUBEONE_PRINCIPAL=$validId`r`n",
                    "$allHosts`r`n    SetEnv FOO=bar CUBEONE_PRINCIPAL=`"$validId`" BAZ=`"a b`"`r`nHost *`r`n    User x`r`n",
                    "Host coding-vm-1 coding-vm-2 coding-vm-3 coding-vm-4`n  setenv CUBEONE_PRINCIPAL=$validId`nHost coding-vm-5 coding-vm-6 coding-vm-7 coding-vm-8`n  SetEnv CUBEONE_PRINCIPAL=$validId`n",
                    "Host a`r`n`tSetEnv CUBEONE_PRINCIPAL=$('a_-' * 7)xx`r`nHost *`r`n`tSetEnv CUBEONE_PRINCIPAL=$('a_-' * 7)xx`r`n")) {
                $path = New-ConfigFile -Bytes (Join-Bytes $bom, (Get-Latin1Bytes $content))
                $before = Get-FileSha $path
                $old = [datetime]'2020-01-02 03:04:05'
                (Get-Item -LiteralPath $path).LastWriteTimeUtc = $old
                Set-DesktopPrincipal -ConfigPath $path 6>$null
                Get-FileSha $path | Should Be $before
                (Get-Item -LiteralPath $path).LastWriteTimeUtc | Should Be $old
            }
        }

        It 'a second run after a write changes nothing, byte for byte and by timestamp' -Skip:(-not $haveSsh) {
            $path = New-ConfigFile -Bytes (Get-Latin1Bytes "Host foo`r`n    HostName x`r`n")
            Set-DesktopPrincipal -ConfigPath $path 6>$null
            $first = [System.IO.File]::ReadAllBytes($path)
            $old = [datetime]'2020-01-02 03:04:05'
            (Get-Item -LiteralPath $path).LastWriteTimeUtc = $old
            foreach ($run in 1..3) { Set-DesktopPrincipal -ConfigPath $path 6>$null }
            [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($path)) | Should Be ([Convert]::ToBase64String($first))
            (Get-Item -LiteralPath $path).LastWriteTimeUtc | Should Be $old
        }

        It 'reuses the one valid id that covers only some aliases for all eight, and keeps the old lines' -Skip:(-not $haveSsh) {
            $content = "Host coding-vm-1 coding-vm-2 coding-vm-3`r`n    SetEnv CUBEONE_PRINCIPAL=$validId`r`nHost coding-vm-4`r`n    User bob`r`n"
            $path = New-ConfigFile -Bytes (Get-Latin1Bytes $content)
            Set-DesktopPrincipal -ConfigPath $path 6>$null
            $text = $latin1.GetString([System.IO.File]::ReadAllBytes($path))
            $text | Should Match ('^' + [regex]::Escape($hostLine) + '\r\n    SetEnv CUBEONE_PRINCIPAL=' + $validId + '\r\n\r\nHost \*\r\n' + [regex]::Escape($content) + '$')
            foreach ($alias in $aliases) { Get-AliasSetEnv $path $alias | Should Be "CUBEONE_PRINCIPAL=$validId" }
            (Get-EffectiveSshSettings -ConfigPath $path -Alias 'coding-vm-4').Other | Should Match 'user bob'
        }

        It 'an id under an unrelated Host does not count as coverage; that Host keeps its own id and settings' -Skip:(-not $haveSsh) {
            $content = "Host build-server`r`n    SetEnv CUBEONE_PRINCIPAL=$validId Z=1`r`n"
            $path = New-ConfigFile -Bytes (Get-Latin1Bytes $content)
            $before = Get-EffectiveSshSettings -ConfigPath $path -Alias 'build-server'
            Set-DesktopPrincipal -ConfigPath $path 6>$null
            $id = [regex]::Match($latin1.GetString([System.IO.File]::ReadAllBytes($path)), '^Host coding-vm-1[^\n]*\n\s+SetEnv CUBEONE_PRINCIPAL=(\S+)').Groups[1].Value
            $id | Should Match '^[A-Za-z0-9_-]{32}$'
            ($id -ceq $validId) | Should Be $false
            foreach ($alias in $aliases) { Get-AliasSetEnv $path $alias | Should Be "CUBEONE_PRINCIPAL=$id" }
            $after = Get-EffectiveSshSettings -ConfigPath $path -Alias 'build-server'
            (@($after.SetEnv) -join ';') | Should Be (@($before.SetEnv) -join ';')
        }

        It 'refuses other SetEnv variables that a new line would hide (global, per host, or next to a partial id) and leaves the file unchanged' -Skip:(-not $haveSsh) {
            $cases = @(
                "SetEnv GLOBAL=1`r`nHost foo`r`n",
                "Host coding-vm-3`r`n    SetEnv FOO=1`r`n",
                "Host *`r`n    SetEnv FOO=1`r`nHost foo`r`n",
                "Host coding-vm-1 coding-vm-2 coding-vm-3`r`n    SetEnv CUBEONE_PRINCIPAL=$validId FOO=1`r`n")
            foreach ($content in $cases) {
                $path = New-ConfigFile -Bytes (Get-Latin1Bytes $content)
                $before = Get-FileSha $path
                $message = Get-ThrownMessage { Set-DesktopPrincipal -ConfigPath $path 6>$null }
                $message | Should Match 'other variables'
                Assert-HandEditGuidance $message
                Get-FileSha $path | Should Be $before
            }
        }

        It 'refuses a malformed id for any of the eight aliases and leaves the file unchanged' -Skip:(-not $haveSsh) {
            $bad = @('short', 'ABCDEFGHIJKLMNOPQRSTU', ('A' * 81), 'ABCDEFGHIJKLMNOPQRSTUV+/', 'ABCDEFGHIJKLMNOPQRSTUV.x', '"ABCDEFGHIJKLMNOPQRSTUVWXYZ 012345"')
            foreach ($value in $bad) {
                $path = New-ConfigFile -Bytes (Get-Latin1Bytes "Host coding-vm-5`r`n    SetEnv CUBEONE_PRINCIPAL=$value`r`n")
                $before = Get-FileSha $path
                (Get-ThrownMessage { Set-DesktopPrincipal -ConfigPath $path 6>$null }) | Should Match 'not 22 to 80 characters'
                Get-FileSha $path | Should Be $before
            }
            $empty = New-ConfigFile -Bytes (Get-Latin1Bytes "Host coding-vm-5`r`n    SetEnv CUBEONE_PRINCIPAL=`r`n")
            $before = Get-FileSha $empty
            (Get-ThrownMessage { Set-DesktopPrincipal -ConfigPath $empty 6>$null }) | Should Not Be ''
            Get-FileSha $empty | Should Be $before
        }

        It 'accepts the boundary lengths 22 and 80 for all eight aliases' -Skip:(-not $haveSsh) {
            foreach ($length in 22, 80) {
                $path = New-ConfigFile -Bytes (Get-Latin1Bytes "Host *`r`n    SetEnv CUBEONE_PRINCIPAL=$('x' * $length)`r`n")
                $before = Get-FileSha $path
                Set-DesktopPrincipal -ConfigPath $path 6>$null
                Get-FileSha $path | Should Be $before
            }
        }

        It 'refuses different ids for different aliases, also when they differ only in case, and does not pick one' -Skip:(-not $haveSsh) {
            foreach ($second in @('ZYXWVUTSRQPONMLKJIHGFEDCBA012345', $validId.ToLowerInvariant())) {
                $path = New-ConfigFile -Bytes (Get-Latin1Bytes "Host coding-vm-1`r`n    SetEnv CUBEONE_PRINCIPAL=$validId`r`nHost coding-vm-2`r`n    SetEnv CUBEONE_PRINCIPAL=$second`r`n")
                $before = Get-FileSha $path
                (Get-ThrownMessage { Set-DesktopPrincipal -ConfigPath $path 6>$null }) | Should Match 'different CUBEONE_PRINCIPAL values'
                Get-FileSha $path | Should Be $before
            }
        }

        It 'a commented-out id is ignored and kept' -Skip:(-not $haveSsh) {
            $content = "# SetEnv CUBEONE_PRINCIPAL=short`r`nHost a`r`n"
            $path = New-ConfigFile -Bytes (Get-Latin1Bytes $content)
            Set-DesktopPrincipal -ConfigPath $path 6>$null
            $latin1.GetString([System.IO.File]::ReadAllBytes($path)).EndsWith("Host *`r`n" + $content) | Should Be $true
        }

        It 'a config that ssh cannot read fails with a fixed message, unchanged, without ssh output' -Skip:(-not $haveSsh) {
            $path = New-ConfigFile -Bytes (Get-Latin1Bytes "Host coding-vm-1`r`n    NoSuchOption yes`r`n")
            $before = Get-FileSha $path
            $message = Get-ThrownMessage { Set-DesktopPrincipal -ConfigPath $path 6>$null }
            $message | Should Match 'could not read the SSH config'
            $message.Contains('Bad configuration') | Should Be $false
            $message.Contains('NoSuchOption') | Should Be $false
            Get-FileSha $path | Should Be $before
        }

        It 'does not write when the check on the copy shows a change of other settings (global settings not restored)' -Skip:(-not $haveSsh) {
            function New-PrincipalConfigBytes {
                param([byte[]]$Bytes, [string]$Principal)
                $block = [System.Text.Encoding]::ASCII.GetBytes("$hostLine`r`n    SetEnv CUBEONE_PRINCIPAL=$Principal`r`n")
                return Join-Bytes $block, $Bytes
            }
            $path = New-ConfigFile -Bytes (Get-Latin1Bytes "User bob`r`nHost foo`r`n")
            $before = Get-FileSha $path
            (Get-ThrownMessage { Set-DesktopPrincipal -ConfigPath $path 6>$null }) | Should Match 'would change more than the personal id'
            Get-FileSha $path | Should Be $before
        }

        It 'prints neither ssh output nor config content nor the id' -Skip:(-not $haveSsh) {
            $path = New-ConfigFile -Bytes (Get-Latin1Bytes "Host foo`r`n    HostName secret-host.example`r`n    IdentityFile ~/.ssh/secret_key`r`n")
            $output = (Set-DesktopPrincipal -ConfigPath $path 6>&1 4>&1 3>&1 | Out-String)
            $id = [regex]::Match($latin1.GetString([System.IO.File]::ReadAllBytes($path)), 'CUBEONE_PRINCIPAL=(\S+)').Groups[1].Value
            $output.Contains($id) | Should Be $false
            $output | Should Not Match '(?i)secret|hostname|identityfile|setenv|ssh_config'
            $second = (Set-DesktopPrincipal -ConfigPath $path 6>&1 4>&1 3>&1 | Out-String)
            $second.Contains($id) | Should Be $false
        }

        It 'keeps the permissions of the existing file (written in place, not replaced)' -Skip:(-not $haveSsh) {
            $path = New-ConfigFile -Bytes (Get-Latin1Bytes "Host a`r`n")
            & icacls.exe $path /grant '*S-1-5-32-545:(R)' /Q | Out-Null
            $LASTEXITCODE | Should Be 0
            $before = Get-FileSddl $path
            Set-DesktopPrincipal -ConfigPath $path 6>$null
            (Get-FileSddl $path) | Should Be $before
            $latin1.GetString([System.IO.File]::ReadAllBytes($path)) | Should Match 'SetEnv CUBEONE_PRINCIPAL='
        }

        It 'creates no config of its own: a missing file stays missing' {
            $directory = Join-Path $sandbox ('noconfig-' + [guid]::NewGuid().ToString('N'))
            $path = Join-Path $directory '.ssh\config'
            Set-DesktopPrincipal -ConfigPath $path 6>$null
            Test-Path -LiteralPath $directory | Should Be $false
        }

        It 'generates different ids from a cryptographic random source' -Skip:(-not $haveSsh) {
            $ids = @(1..5 | ForEach-Object {
                    $path = New-ConfigFile -Bytes (Get-Latin1Bytes "Host a`r`n")
                    Set-DesktopPrincipal -ConfigPath $path 6>$null
                    [regex]::Match($latin1.GetString([System.IO.File]::ReadAllBytes($path)), 'CUBEONE_PRINCIPAL=(\S+)').Groups[1].Value
                })
            @($ids | Select-Object -Unique).Count | Should Be 5
            foreach ($id in $ids) { $id | Should Match '^[A-Za-z0-9_-]{32}$' }
            $source = [System.IO.File]::ReadAllText($scriptPath)
            $source | Should Match 'RandomNumberGenerator'
            $source -match 'System\.Random|Get-Random' | Should Be $false
        }
    }

    Context 'Principal only (-PrincipalOnly) and the Set-OpenCodePrincipal.ps1 wrapper' {
        BeforeAll {
            $helperPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Set-OpenCodePrincipal.ps1'
            $principalAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)
            $principalText = [System.IO.File]::ReadAllText($scriptPath)
            # Every function that reaches outside the SSH config is replaced by a recorder that fails the call. The
            # identity guard is removed (it is tested above), nothing else is changed.
            $outside = @('Send-File', 'Get-OpenRouterKey', 'Get-WslDistros', 'New-LinuxPayload',
                'Get-SshHosts', 'Update-OpenRouterKeyOnTargets', 'Get-SshHostOs', 'Invoke-StagedScript', 'Invoke-RemoteScript',
                'Invoke-RemoteCommand', 'New-RemoteStage', 'Get-ProfileImagePath')
            $principalEdits = @()
            foreach ($name in $outside) {
                $definition = $principalAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
                $principalEdits += [pscustomobject]@{
                    Start = $definition.Extent.StartOffset; End = $definition.Extent.EndOffset
                    Text  = "function $name { [void]`$global:PrincipalRunCalls.Add('$name'); throw 'must not be called' }"
                }
            }
            $guardCall = $principalAst.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Assert-ProfileUserContext' }, $true)
            $principalEdits += [pscustomobject]@{ Start = $guardCall.Extent.StartOffset; End = $guardCall.Extent.EndOffset; Text = '' }
            foreach ($edit in ($principalEdits | Sort-Object Start -Descending)) {
                $principalText = $principalText.Substring(0, $edit.Start) + $edit.Text + $principalText.Substring($edit.End)
            }
            $package = Join-Path $sandbox 'principal-package'
            New-Item -ItemType Directory -Path $package -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $package 'Install-OpenCodeRemote.ps1'), $principalText, $utf8)
            Copy-Item -LiteralPath $helperPath -Destination (Join-Path $package 'Set-OpenCodePrincipal.ps1')
            $global:PrincipalRunCalls = New-Object System.Collections.ArrayList

            function New-PrincipalProfile {
                param([string]$ConfigText, [switch]$WithoutSsh)
                $profileDir = Join-Path $sandbox ("Pr$([char]0xFC)fil Anna-" + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
                if (-not $WithoutSsh) {
                    New-Item -ItemType Directory -Path (Join-Path $profileDir '.ssh') -Force | Out-Null
                    [System.IO.File]::WriteAllBytes((Join-Path $profileDir '.ssh\config'), [System.Text.Encoding]::GetEncoding(28591).GetBytes($ConfigText))
                }
                return $profileDir
            }
            function Get-RemoteWorkDirs {
                return @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'opencode-*' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            }
        }

        AfterAll {
            Remove-Variable -Name PrincipalRunCalls -Scope Global -ErrorAction SilentlyContinue
        }

        It 'handles -PrincipalOnly directly after the identity guard and before anything is read, built or started' {
            $branch = $principalAst.Find({
                    param($n)
                    $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$PrincipalOnly'
                }, $true)
            $branch | Should Not BeNullOrEmpty
            $commands = @($branch.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
            ($commands | Sort-Object -Unique) -join ',' | Should Be 'Join-Path,Set-DesktopPrincipal,Test-Path'
            $original = [System.IO.File]::ReadAllText($scriptPath)
            $guardAt = $original.IndexOf('Assert-ProfileUserContext -ProfilePath $ProfilePath')
            $branchAt = $original.IndexOf('if ($PrincipalOnly)')
            ($guardAt -gt 0 -and $branchAt -gt $guardAt) | Should Be $true
            foreach ($later in @('$utf8 = New-Object System.Text.UTF8Encoding $false', 'if ($KeyOnly) {', 'New-LinuxPayload -Source $SourceDir', '$key = Get-OpenRouterKey', '& tar.exe')) {
                $at = $original.LastIndexOf($later)
                $at | Should BeGreaterThan 0
                ($branchAt -lt $at) | Should Be $true
            }
            $statementsBefore = @($principalAst.EndBlock.Statements | Where-Object { $_.Extent.EndOffset -le $branch.Extent.StartOffset -and $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] -and $_ -isnot [System.Management.Automation.Language.AssignmentStatementAst] })
            @($statementsBefore | ForEach-Object { $_.Extent.Text }) -join '|' | Should Be 'Assert-ProfileUserContext -ProfilePath $ProfilePath'
        }

        It 'adds the id to a sandbox profile without a key read, ssh connection, wsl, payload, work directory or any other file (only the offline ssh -G runs)' -Skip:(-not $haveSsh) {
            $profileDir = New-PrincipalProfile -ConfigText "Host foo`r`n    HostName x`r`n"
            $global:PrincipalRunCalls.Clear()
            $workBefore = Get-RemoteWorkDirs
            $siblings = @(Get-ChildItem -LiteralPath $profileDir -Recurse -Force | ForEach-Object { $_.FullName })
            Get-ThrownMessage { & (Join-Path $package 'Install-OpenCodeRemote.ps1') -ProfilePath $profileDir -PrincipalOnly 6>$null } | Should Be ''
            $global:PrincipalRunCalls.Count | Should Be 0
            (Get-RemoteWorkDirs) -join ',' | Should Be ($workBefore -join ',')
            @(Get-ChildItem -LiteralPath $profileDir -Recurse -Force | ForEach-Object { $_.FullName }) -join ',' | Should Be ($siblings -join ',')
            [System.IO.File]::ReadAllText((Join-Path $profileDir '.ssh\config')) | Should Match '^Host coding-vm-1 .*coding-vm-8\r\n    SetEnv CUBEONE_PRINCIPAL=[A-Za-z0-9_-]{32}\r\n\r\nHost \*\r\nHost foo\r\n    HostName x\r\n$'
        }

        It 'fails clearly for a missing config and creates nothing; it does not invent targets' {
            $profileDir = New-PrincipalProfile -WithoutSsh
            $global:PrincipalRunCalls.Clear()
            (Get-ThrownMessage { & (Join-Path $package 'Install-OpenCodeRemote.ps1') -ProfilePath $profileDir -PrincipalOnly 6>$null }) | Should Match 'No SSH config at'
            Test-Path -LiteralPath (Join-Path $profileDir '.ssh') | Should Be $false
            $folder = New-PrincipalProfile -ConfigText ''
            Remove-Item -LiteralPath (Join-Path $folder '.ssh\config')
            New-Item -ItemType Directory -Path (Join-Path $folder '.ssh\config') | Out-Null
            (Get-ThrownMessage { & (Join-Path $package 'Install-OpenCodeRemote.ps1') -ProfilePath $folder -PrincipalOnly 6>$null }) | Should Match 'No SSH config at'
            $global:PrincipalRunCalls.Count | Should Be 0
        }

        It 'fails for a malformed or conflicting existing id and leaves the file unchanged' -Skip:(-not $haveSsh) {
            foreach ($config in @("Host coding-vm-1`r`n    SetEnv CUBEONE_PRINCIPAL=short`r`n", "Host coding-vm-1`r`n    SetEnv CUBEONE_PRINCIPAL=ABCDEFGHIJKLMNOPQRSTUVWXYZ012345`r`nHost coding-vm-2`r`n    SetEnv CUBEONE_PRINCIPAL=ZYXWVUTSRQPONMLKJIHGFEDCBA012345`r`n")) {
                $profileDir = New-PrincipalProfile -ConfigText $config
                $before = Get-FileHash -LiteralPath (Join-Path $profileDir '.ssh\config') -Algorithm SHA256
                (Get-ThrownMessage { & (Join-Path $package 'Install-OpenCodeRemote.ps1') -ProfilePath $profileDir -PrincipalOnly 6>$null }) | Should Match 'CUBEONE_PRINCIPAL'
                (Get-FileHash -LiteralPath (Join-Path $profileDir '.ssh\config') -Algorithm SHA256).Hash | Should Be $before.Hash
            }
        }

        It 'refuses -PrincipalOnly together with -KeyOnly or -DesktopOnly and changes nothing' {
            $profileDir = New-PrincipalProfile -ConfigText "Host a`r`n"
            $before = Get-FileHash -LiteralPath (Join-Path $profileDir '.ssh\config') -Algorithm SHA256
            (Get-ThrownMessage { & (Join-Path $package 'Install-OpenCodeRemote.ps1') -ProfilePath $profileDir -PrincipalOnly -KeyOnly 6>$null }) | Should Match 'cannot be combined'
            (Get-ThrownMessage { & (Join-Path $package 'Install-OpenCodeRemote.ps1') -ProfilePath $profileDir -PrincipalOnly -DesktopOnly 6>$null }) | Should Match 'cannot be combined'
            (Get-FileHash -LiteralPath (Join-Path $profileDir '.ssh\config') -Algorithm SHA256).Hash | Should Be $before.Hash
            $global:PrincipalRunCalls.Count | Should Be 0
        }

        It 'the wrapper runs the same, keeps an existing id on the second run, and starts nothing else' -Skip:(-not $haveSsh) {
            $profileDir = New-PrincipalProfile -ConfigText "Host foo`r`n"
            $config = Join-Path $profileDir '.ssh\config'
            $global:PrincipalRunCalls.Clear()
            Get-ThrownMessage { & (Join-Path $package 'Set-OpenCodePrincipal.ps1') -ProfilePath $profileDir 6>$null } | Should Be ''
            $first = Get-FileHash -LiteralPath $config -Algorithm SHA256
            $id = [regex]::Match([System.IO.File]::ReadAllText($config), 'CUBEONE_PRINCIPAL=(\S+)').Groups[1].Value
            $id | Should Match '^[A-Za-z0-9_-]{32}$'
            Get-ThrownMessage { & (Join-Path $package 'Set-OpenCodePrincipal.ps1') -ProfilePath $profileDir 6>$null } | Should Be ''
            (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash | Should Be $first.Hash
            $global:PrincipalRunCalls.Count | Should Be 0
        }

        It 'the wrapper defaults to the profile of the current user and has no other parameter' {
            $helperAst = [System.Management.Automation.Language.Parser]::ParseFile($helperPath, [ref]$null, [ref]$null)
            @($helperAst.ParamBlock.Parameters).Count | Should Be 1
            $helperAst.ParamBlock.Parameters[0].Name.VariablePath.UserPath | Should Be 'ProfilePath'
            $helperAst.ParamBlock.Parameters[0].DefaultValue.Extent.Text | Should Be '$env:USERPROFILE'
        }

        It 'the real script and the real wrapper stop for a profile of another account before any file is read or changed (Windows PowerShell 5 and PowerShell 7)' {
            $otherProfile = New-PrincipalProfile -ConfigText "Host foo`r`n"
            $config = Join-Path $otherProfile '.ssh\config'
            $before = Get-FileHash -LiteralPath $config -Algorithm SHA256
            $helper = Join-Path (Split-Path -Parent $scriptPath) 'Set-OpenCodePrincipal.ps1'
            foreach ($shell in @((Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'), (Get-Command pwsh -ErrorAction SilentlyContinue).Source)) {
                if (-not $shell) { continue }
                foreach ($target in @($scriptPath, $helper)) {
                    $arguments = if ($target -eq $scriptPath) { " -PrincipalOnly" } else { '' }
                    $childCode = 'try { & ''' + $target.Replace("'", "''") + ''' -ProfilePath ''' + $otherProfile.Replace("'", "''") + '''' + $arguments + ' } catch { [Console]::Out.Write($_.Exception.Message); exit 3 }'
                    $encodedChild = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($childCode))
                    $out = & $shell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedChild | Out-String
                    $LASTEXITCODE | Should Be 3
                    $out | Should Match 'must run as the Windows user'
                    (Get-FileHash -LiteralPath $config -Algorithm SHA256).Hash | Should Be $before.Hash
                }
            }
        }

        It 'the wrapper and the principal branch contain no registry, ssh, wsl, CLI, plugin or desktop host code' {
            $helperCode = [System.IO.File]::ReadAllText($helperPath) -replace '(?s)<#.*?#>', ''
            $helperCode -match '(?i)Registry|HKLM|ssh|wsl|sqlite|curl|npm|Get-OpenRouterKey|Send-File' | Should Be $false
            $branch = $principalAst.Find({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$PrincipalOnly' }, $true)
            ($branch.Extent.Text -replace '(?m)^\s*#.*$', '') -match '(?i)Registry|HKLM|ssh\.exe|wsl|sqlite|Get-OpenRouterKey|Send-File|Register-Desktop' | Should Be $false
        }
    }

    Context 'Desktop server list is no longer written by the setup scripts' {
        It 'the full setup neither defines nor calls a desktop host list writer, and keeps Get-SshHosts for the rollout targets' {
            $original = [System.IO.File]::ReadAllText($scriptPath)
            $original | Should Not Match 'Register-DesktopSshHosts|sqlite3|opencode\.settings|drafts\.sqlite|ai\.opencode\.desktop|DesktopSshHosts\.ps1'
            $original | Should Match 'function Get-SshHosts \{'
            ([regex]::Matches($original, 'Get-SshHosts -ConfigPath \$sshConfig')).Count | Should Be 2
            Test-Path -LiteralPath (Join-Path (Split-Path -Parent $scriptPath) 'DesktopSshHosts.ps1') | Should Be $false
        }

        It 'the Linux payload carries the plugin that the managed config lists' {
            $original = [System.IO.File]::ReadAllText($scriptPath)
            $original | Should Match "(?m)foreach \(\`$name in @\([^\r\n]*'cubeone-ssh-hosts'"
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
