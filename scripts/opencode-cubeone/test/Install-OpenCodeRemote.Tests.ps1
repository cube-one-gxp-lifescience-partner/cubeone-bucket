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
            'New-RemoteStage', 'Send-RemoteStageFile', 'Invoke-StagedScript', 'Remove-RemoteStage'
        )
        $variableNames = @(
            'nullInput', 'stageDirPattern', 'stageCommandPattern', 'scriptArgPattern',
            'stageSh', 'commonSh', 'installBodySh', 'installSh', 'linuxSh'
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

        It 'never sends the key to the uname probe' {
            $text = [System.IO.File]::ReadAllText($scriptPath)
            $text -match 'uname -s" -InputPath \$keyFile' | Should Be $false
            ([regex]::Matches($text, 'uname -s" -InputPath \$nullInput')).Count | Should Be 2
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
