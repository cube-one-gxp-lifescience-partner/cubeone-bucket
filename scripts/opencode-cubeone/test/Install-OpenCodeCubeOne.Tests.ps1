<#
.SYNOPSIS
    Regression tests for the Windows installer Install-OpenCodeCubeOne.ps1.

.DESCRIPTION
    Runs on Windows PowerShell 5.1 and PowerShell 7 without Pester. The installer is never executed: only its
    function definitions are loaded. Everything happens in a temporary directory with synthetic data.

    - JSONC parsing: commas, comments and escapes inside strings stay untouched.
    - MCP merge: personal MCP servers and settings survive, only missing cube one servers are added.
    - Optional rules: existing, edited and personal files (also design.md) are neither overwritten nor removed.
    - Permissions: a directory created by the run is locked as before; an existing one (current, outdated or
      empty) keeps its ACL. The icacls calls are recorded by a mock and never reach C:\ProgramData; the real
      icacls cases only touch directories created in the temp folder.

    Exit code 0 when every case passed, 1 otherwise.
#>
[CmdletBinding()]
param(
    [string]$InstallerPath
)

$ErrorActionPreference = 'Stop'

if (-not $InstallerPath) {
    $testRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $InstallerPath = Join-Path $testRoot '..\Install-OpenCodeCubeOne.ps1'
}

$script:Passed = 0
$script:Failed = 0
$script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('opencode-cubeone-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = 'values differ')

    if ($Actual -ne $Expected) {
        throw "$Message. Expected <$Expected>, got <$Actual>"
    }
}

function Assert-True {
    param($Condition, [string]$Message = 'condition is false')

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)

    try {
        & $Body
        $script:Passed++
        Write-Output "PASS $Name"
    } catch {
        $script:Failed++
        Write-Output "FAIL $Name :: $($_.Exception.Message)"
    }
}

function New-TempDir {
    param([string]$Name)

    $path = Join-Path $script:TempRoot ($Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Write-Utf8File {
    param([string]$Path, [string]$Text)

    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

# Load only the function definitions and the SID constants of the installer.
$parseErrors = $null
$parseTokens = $null
$installerAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path -LiteralPath $InstallerPath).Path, [ref]$parseTokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "Installer does not parse: $($parseErrors[0].Message)"
}
$definitions = New-Object System.Collections.Generic.List[string]
foreach ($statement in $installerAst.EndBlock.Statements) {
    if ($statement -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
        $definitions.Add($statement.Extent.Text)
    } elseif ($statement -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $statement.Left.Extent.Text -like '$Sid*') {
        $definitions.Add($statement.Extent.Text)
    }
}
. ([scriptblock]::Create($definitions -join "`n`n"))

# Keep the real implementations so the mocks can be switched off for the one real icacls case.
$realInvokeIcacls = ${function:Invoke-Icacls}

# Mocks: nothing below talks to the real icacls, takeown or the real elevation state.
$script:IcaclsCalls = New-Object System.Collections.Generic.List[string]
$script:TakeownCalls = New-Object System.Collections.Generic.List[string]
$script:MockElevated = $false
$script:MockCanWrite = $true
$script:UseRealIcacls = $false
$script:FailIcacls = 0
function Invoke-Icacls {
    param([string[]]$Arguments)

    Assert-True ($Arguments[0].StartsWith($script:TempRoot)) "icacls mock got a path outside the test directory: $($Arguments[0])"
    $script:IcaclsCalls.Add($Arguments -join ' ')
    if ($script:FailIcacls -gt 0) {
        $script:FailIcacls--
        throw 'icacls refused (simulated)'
    }
    if ($script:UseRealIcacls) {
        & $realInvokeIcacls -Arguments $Arguments
    }
}
function Invoke-TakeownAdministrators {
    param([string]$Path)

    Assert-True ($Path.StartsWith($script:TempRoot)) "takeown mock got a path outside the test directory: $Path"
    $script:TakeownCalls.Add($Path)
}
function Test-IsElevated { return $script:MockElevated }
$realTestCanWrite = ${function:Test-CanWrite}
function Test-CanWrite {
    param([string]$Path)

    if ($script:MockCanWrite) { return (& $realTestCanWrite -Path $Path) }
    return $false
}

function Reset-Mocks {
    param([bool]$Elevated = $false, [bool]$CanWrite = $true)

    $script:IcaclsCalls.Clear()
    $script:TakeownCalls.Clear()
    $script:MockElevated = $Elevated
    $script:MockCanWrite = $CanWrite
    $script:UseRealIcacls = $false
    $script:FailIcacls = 0
}

function Assert-NoPermissionRemoval {
    $forbidden = @('/inheritance:r', '/grant:r', '/reset', '/setowner', '/remove', '/deny', 'S-1-3-4')
    foreach ($call in $script:IcaclsCalls) {
        foreach ($token in $forbidden) {
            Assert-True (-not $call.Contains($token)) "icacls call removes or replaces permissions ($token): $call"
        }
    }
}

# ---------------------------------------------------------------------------------------------------------------
# JSONC parsing
# ---------------------------------------------------------------------------------------------------------------
Invoke-Case 'jsonc: comma before } or ] inside a string is kept' {
    $json = '{"a":"literal,}","b":"x,]","c":[ "y,]" ],"d":"p, }"}'
    $value = ConvertFrom-Jsonc -Text $json
    Assert-Equal $value.a 'literal,}'
    Assert-Equal $value.b 'x,]'
    Assert-Equal $value.c[0] 'y,]'
    Assert-Equal $value.d 'p, }'
}

Invoke-Case 'jsonc: real trailing commas are removed in objects and arrays' {
    $json = "{`n  `"a`": [1, 2, 3,],`n  `"b`": { `"c`": true, },`n}"
    $value = ConvertFrom-Jsonc -Text $json
    Assert-Equal $value.a.Count 3
    Assert-Equal $value.b.c $true
}

Invoke-Case 'jsonc: trailing comma followed by a comment is removed' {
    $json = "{`n  `"a`": 1, // last entry`n  /* block */`n}"
    $value = ConvertFrom-Jsonc -Text $json
    Assert-Equal $value.a 1
}

Invoke-Case 'jsonc: URLs and comment markers inside strings are kept' {
    $json = '{"u":"https://host.example/mcp?a=1//2","v":"/* not a comment */","w":"a // b"} // trailing'
    $value = ConvertFrom-Jsonc -Text $json
    Assert-Equal $value.u 'https://host.example/mcp?a=1//2'
    Assert-Equal $value.v '/* not a comment */'
    Assert-Equal $value.w 'a // b'
}

Invoke-Case 'jsonc: escapes stay intact, also before a trailing comma' {
    $json = '{"q":"say \"hi,}\" now","p":"C:\\dir\\","n":"line\nbreak,]","u":"\u00e4,}",}'
    $value = ConvertFrom-Jsonc -Text $json
    Assert-Equal $value.q 'say "hi,}" now'
    Assert-Equal $value.p 'C:\dir\'
    Assert-Equal $value.n "line`nbreak,]"
    Assert-Equal $value.u ([string][char]0xE4 + ',}')
}

Invoke-Case 'jsonc: helpers handle empty input and unterminated comments' {
    Assert-Equal (Remove-JsoncComment -Text '') ''
    Assert-Equal (Remove-JsoncTrailingComma -Text '') ''
    Assert-Equal (Remove-JsoncTrailingComma -Text '[1,2,]') '[1,2]'
    Assert-Equal ((Remove-JsoncComment -Text '{"a":1} /* open') -replace '\s+$', '') '{"a":1}'
}

# ---------------------------------------------------------------------------------------------------------------
# MCP merge on a synthetic profile
# ---------------------------------------------------------------------------------------------------------------
function New-UserSource {
    $source = New-TempDir 'user-source'
    Write-Utf8File (Join-Path $source 'opencode.jsonc') @'
{
  // cube one
  "mcp": {
    "servers": {
      "cube-note": { "type": "remote", "url": "https://note.cubeone.de/mcp" },
      "trace": { "type": "remote", "url": "https://trace.cubeone.de/mcp" },
    }
  }
}
'@
    Write-Utf8File (Join-Path $source 'rules\optional\sample.md') 'optional rule'
    Write-Utf8File (Join-Path $source 'vorgaben\sample.md') 'path rule'
    return $source
}

Invoke-Case 'merge: personal settings and MCP servers survive, missing servers are added' {
    $source = New-UserSource
    $profilePath = New-TempDir 'profile'
    $configDir = Join-Path $profilePath '.config\opencode'
    $personal = @'
{
  // personal comment
  "$schema": "https://opencode.ai/config.json",
  "theme": "literal,}",
  "note": "list,]",
  "path": "C:\\Users\\me\\",
  "mcp": {
    "servers": {
      "cube-note": { "type": "remote", "url": "https://mine.example/mcp?x=//y" },
      "own": { "type": "local", "command": ["node", "own,].js",], },
    },
  },
}
'@
    Write-Utf8File (Join-Path $configDir 'opencode.jsonc') $personal
    Install-UserConfiguration -Source $source -ProfilePath $profilePath | Out-Null

    $result = ConvertFrom-Jsonc -Text ([System.IO.File]::ReadAllText((Join-Path $configDir 'opencode.jsonc')))
    Assert-Equal $result.theme 'literal,}'
    Assert-Equal $result.note 'list,]'
    Assert-Equal $result.path 'C:\Users\me\'
    Assert-Equal $result.'$schema' 'https://opencode.ai/config.json'
    Assert-Equal $result.mcp.servers.'cube-note'.url 'https://mine.example/mcp?x=//y'
    Assert-Equal $result.mcp.servers.own.command[1] 'own,].js'
    Assert-Equal $result.mcp.servers.own.type 'local'
    Assert-Equal $result.mcp.servers.trace.url 'https://trace.cubeone.de/mcp'
    Assert-True (Test-Path -LiteralPath (Join-Path $configDir 'opencode.jsonc.bak')) 'backup missing'
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $configDir 'opencode.jsonc.bak'))) $personal 'backup differs from the original'
}

Invoke-Case 'merge: a file that already has all servers is not rewritten' {
    $source = New-UserSource
    $profilePath = New-TempDir 'profile'
    $configDir = Join-Path $profilePath '.config\opencode'
    $personal = '{"mcp":{"servers":{"cube-note":{"url":"x,}"},"trace":{"url":"y"}}}} // mine'
    Write-Utf8File (Join-Path $configDir 'opencode.jsonc') $personal
    Install-UserConfiguration -Source $source -ProfilePath $profilePath | Out-Null
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $configDir 'opencode.jsonc'))) $personal 'file was rewritten'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $configDir 'opencode.jsonc.bak'))) 'unexpected backup'
}

Invoke-Case 'merge: an unparsable personal file is left byte for byte unchanged' {
    $source = New-UserSource
    $profilePath = New-TempDir 'profile'
    $configDir = Join-Path $profilePath '.config\opencode'
    $broken = '{ "theme": "dark", "mcp": '
    Write-Utf8File (Join-Path $configDir 'opencode.jsonc') $broken
    Install-UserConfiguration -Source $source -ProfilePath $profilePath -WarningAction SilentlyContinue | Out-Null
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $configDir 'opencode.jsonc'))) $broken 'file was changed'
}

# ---------------------------------------------------------------------------------------------------------------
# Permissions: a new installation is locked, an existing one is never touched
# ---------------------------------------------------------------------------------------------------------------
function New-StagingTree {
    param([string]$Content)

    $staging = New-TempDir 'staging'
    Write-Utf8File (Join-Path $staging 'opencode.jsonc') $Content
    Write-Utf8File (Join-Path $staging 'rules\a.md') 'rule'
    return $staging
}

function Get-DirectorySddl {
    param([string]$Path)

    return (Get-Acl -LiteralPath $Path).Sddl
}

foreach ($elevated in @($false, $true)) {
    $label = if ($elevated) { 'elevated' } else { 'standard user' }

    Invoke-Case "acl ($label): a current installation is not touched" {
        $staging = New-StagingTree -Content 'same'
        $target = New-TempDir 'target'
        Copy-Item -Path (Join-Path $staging '*') -Destination $target -Recurse
        Reset-Mocks -Elevated $elevated
        Install-ManagedConfiguration -Staging $staging -Target $target | Out-Null
        Assert-Equal $script:IcaclsCalls.Count 0 'icacls was called for an equal tree'
        Assert-Equal $script:TakeownCalls.Count 0 'takeown was called for an equal tree'
    }

    Invoke-Case "acl ($label): an update of a non-empty installation keeps the existing permissions" {
        $staging = New-StagingTree -Content 'new'
        $target = New-TempDir 'target'
        Write-Utf8File (Join-Path $target 'opencode.jsonc') 'old'
        Write-Utf8File (Join-Path $target 'stale.txt') 'stale'
        Reset-Mocks -Elevated $elevated
        Install-ManagedConfiguration -Staging $staging -Target $target | Out-Null
        Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $target 'opencode.jsonc'))) 'new' 'file was not updated'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'stale.txt'))) 'stale file remains'
        Assert-Equal $script:IcaclsCalls.Count 0 "an update changed permissions: $($script:IcaclsCalls -join ' | ')"
        Assert-Equal $script:TakeownCalls.Count 0 'an update took ownership'
    }

    Invoke-Case "acl ($label): an existing empty directory counts as existing and is not locked" {
        $staging = New-StagingTree -Content 'new'
        $target = New-TempDir 'target'
        Reset-Mocks -Elevated $elevated
        Install-ManagedConfiguration -Staging $staging -Target $target | Out-Null
        Assert-True (Test-Path -LiteralPath (Join-Path $target 'opencode.jsonc')) 'file missing'
        Assert-Equal $script:IcaclsCalls.Count 0 "permissions of an existing directory changed: $($script:IcaclsCalls -join ' | ')"
        Assert-Equal $script:TakeownCalls.Count 0 'ownership of an existing directory changed'
    }
}

Invoke-Case 'acl: a new installation by an administrator is locked like before' {
    $staging = New-StagingTree -Content 'new'
    $target = Join-Path (New-TempDir 'parent') 'opencode'
    Reset-Mocks -Elevated $true
    Install-ManagedConfiguration -Staging $staging -Target $target | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'opencode.jsonc')) 'file missing'
    Assert-Equal $script:IcaclsCalls.Count 3 'expected setowner, inheritance and reset'
    Assert-True ($script:IcaclsCalls[0].Contains('/setowner *S-1-5-32-544')) 'owner is not set to Administrators'
    Assert-True ($script:IcaclsCalls[1].Contains('/inheritance:r /grant:r')) 'inheritance is not cut'
    Assert-True ($script:IcaclsCalls[1].Contains('*S-1-5-18:(OI)(CI)(F)')) 'SYSTEM full control missing'
    Assert-True ($script:IcaclsCalls[1].Contains('*S-1-5-32-544:(OI)(CI)(F)')) 'Administrators full control missing'
    Assert-True ($script:IcaclsCalls[1].Contains('*S-1-5-32-545:(OI)(CI)(RX)')) 'Users must only read'
    Assert-True ($script:IcaclsCalls[2].Contains('/reset /T')) 'children are not reset'
    Assert-Equal $script:TakeownCalls.Count 0 'a new installation took ownership'
}

Invoke-Case 'acl: a new installation by a standard user is locked like before' {
    $staging = New-StagingTree -Content 'new'
    $target = Join-Path (New-TempDir 'parent') 'opencode'
    Reset-Mocks -Elevated $false
    Install-ManagedConfiguration -Staging $staging -Target $target | Out-Null
    Assert-Equal $script:IcaclsCalls.Count 1 'expected one icacls call'
    $call = $script:IcaclsCalls[0]
    Assert-True ($call.Contains('/inheritance:r /grant:r')) 'inheritance is not cut'
    Assert-True ($call.Contains('*S-1-5-32-545:(OI)(CI)(RX)')) 'Users must only read'
    Assert-True ($call.Contains('*S-1-3-4:(OI)(CI)(RX)')) 'OWNER RIGHTS entry missing'
}

Invoke-Case 'acl: an administrator who cannot write first only adds an entry' {
    $staging = New-StagingTree -Content 'new'
    $target = New-TempDir 'target'
    Write-Utf8File (Join-Path $target 'opencode.jsonc') 'old'
    Reset-Mocks -Elevated $true
    # The directory is writable for the test process, so only the first probe is forced to fail. The function
    # lives in this script block only; the shared mock is active again afterwards.
    $script:ProbeCount = 0
    function Test-CanWrite {
        param([string]$Path)

        $script:ProbeCount++
        return ($script:ProbeCount -gt 1)
    }
    Install-ManagedConfiguration -Staging $staging -Target $target | Out-Null
    Assert-Equal $script:TakeownCalls.Count 0 'ownership was taken although the grant worked'
    Assert-Equal $script:IcaclsCalls.Count 1 'expected exactly one icacls call'
    Assert-True ($script:IcaclsCalls[0].Contains('/grant *S-1-5-32-544:(OI)(CI)(F)')) 'Administrators grant missing'
    Assert-NoPermissionRemoval
}

Invoke-Case 'acl: ownership is taken only when the Administrators grant is refused' {
    $staging = New-StagingTree -Content 'new'
    $target = New-TempDir 'target'
    Write-Utf8File (Join-Path $target 'opencode.jsonc') 'old'
    Reset-Mocks -Elevated $true
    $script:ProbeCount = 0
    function Test-CanWrite {
        param([string]$Path)

        $script:ProbeCount++
        return ($script:ProbeCount -gt 1)
    }
    $script:FailIcacls = 1
    Install-ManagedConfiguration -Staging $staging -Target $target | Out-Null
    Assert-Equal $script:TakeownCalls.Count 1 'takeown expected once'
    Assert-Equal $script:IcaclsCalls.Count 2 'expected the refused and the repeated grant'
    Assert-NoPermissionRemoval
}

Invoke-Case 'acl: a standard user without write access changes nothing and does not fail' {
    $staging = New-StagingTree -Content 'new'
    $target = New-TempDir 'target'
    Write-Utf8File (Join-Path $target 'opencode.jsonc') 'old'
    Reset-Mocks -Elevated $false -CanWrite $false
    Install-ManagedConfiguration -Staging $staging -Target $target -WarningAction SilentlyContinue | Out-Null
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $target 'opencode.jsonc'))) 'old' 'locked directory was changed'
    Assert-Equal $script:IcaclsCalls.Count 0
}

foreach ($elevated in @($false, $true)) {
    $label = if ($elevated) { 'elevated' } else { 'standard user' }

    Invoke-Case "acl ($label): real icacls leaves the ACL of an existing installation byte for byte equal (temp only)" {
        $parent = New-TempDir 'real-acl'
        Assert-True ($parent.StartsWith($script:TempRoot)) 'directory is not below the temp root'
        $script:UseRealIcacls = $true
        foreach ($state in @('current', 'outdated')) {
            $staging = New-StagingTree -Content 'new'
            $target = Join-Path $parent $state
            New-Item -ItemType Directory -Path $target | Out-Null
            Write-Utf8File (Join-Path $target 'opencode.jsonc') $(if ($state -eq 'current') { 'new' } else { 'old' })
            if ($state -eq 'current') {
                Write-Utf8File (Join-Path $target 'rules\a.md') 'rule'
            }
            # Synthetic precondition: ordinary users may write here, as granted on purpose on some machine.
            & icacls.exe $target /grant '*S-1-5-32-545:(OI)(CI)(M)' /Q | Out-Null
            Assert-Equal $LASTEXITCODE 0 'could not prepare the test directory'
            $before = Get-DirectorySddl -Path $target
            Reset-Mocks -Elevated $elevated
            $script:UseRealIcacls = $true
            Install-ManagedConfiguration -Staging $staging -Target $target | Out-Null
            Assert-Equal (Get-DirectorySddl -Path $target) $before "ACL of the $state installation changed"
            Assert-Equal $script:IcaclsCalls.Count 0 'icacls was called'
        }
        $script:UseRealIcacls = $false
    }
}
# ---------------------------------------------------------------------------------------------------------------
# Optional rules: personal files are never overwritten or removed
# ---------------------------------------------------------------------------------------------------------------
function Get-TreeSnapshot {
    param([string]$Root)

    $rootFull = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
    $entries = foreach ($file in (Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force)) {
        '{0}={1}' -f $file.FullName.Substring($rootFull.Length + 1), (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return @($entries | Sort-Object)
}

function New-RuleSource {
    $source = New-UserSource
    Write-Utf8File (Join-Path $source 'rules\optional\design.md') 'shipped design'
    Write-Utf8File (Join-Path $source 'rules\optional\mcp.md') 'shipped mcp'
    Write-Utf8File (Join-Path $source 'rules\optional\new.md') 'shipped new'
    return $source
}

Invoke-Case 'rules: a fresh profile receives every shipped optional rule' {
    $source = New-RuleSource
    $profilePath = New-TempDir 'profile'
    Install-UserConfiguration -Source $source -ProfilePath $profilePath | Out-Null
    $rules = Join-Path $profilePath '.config\opencode\rules\optional'
    foreach ($name in @('sample.md', 'design.md', 'mcp.md', 'new.md')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $rules $name)) "$name missing"
    }
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $rules 'design.md'))) 'shipped design'
}

Invoke-Case 'rules: edited, personal and design rules survive, missing ones are added, a repeat changes nothing' {
    $source = New-RuleSource
    $profilePath = New-TempDir 'profile'
    $rules = Join-Path $profilePath '.config\opencode\rules\optional'
    Write-Utf8File (Join-Path $rules 'mcp.md') 'my edited mcp rule'
    Write-Utf8File (Join-Path $rules 'design.md') 'my own design rule'
    Write-Utf8File (Join-Path $rules 'mine.md') 'personal rule not in the package'
    Write-Utf8File (Join-Path $rules 'notes.txt') 'not a markdown file'
    Write-Utf8File (Join-Path $rules 'sub\deep.md') 'nested personal rule'
    Install-UserConfiguration -Source $source -ProfilePath $profilePath | Out-Null

    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $rules 'mcp.md'))) 'my edited mcp rule' 'edited rule was overwritten'
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $rules 'design.md'))) 'my own design rule' 'personal design.md changed'
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $rules 'mine.md'))) 'personal rule not in the package' 'personal rule changed'
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $rules 'notes.txt'))) 'not a markdown file'
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $rules 'sub\deep.md'))) 'nested personal rule'
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $rules 'new.md'))) 'shipped new' 'missing shipped rule not added'
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $rules 'sample.md'))) 'optional rule' 'missing shipped rule not added'

    $first = Get-TreeSnapshot -Root $profilePath
    Install-UserConfiguration -Source $source -ProfilePath $profilePath | Out-Null
    $second = Get-TreeSnapshot -Root $profilePath
    Assert-Equal ($second -join "`n") ($first -join "`n") 'a repeated run changed the profile'
}

Invoke-Case 'rules: a rule deleted by the user is added again, an unchanged one is not touched' {
    $source = New-RuleSource
    $profilePath = New-TempDir 'profile'
    Install-UserConfiguration -Source $source -ProfilePath $profilePath | Out-Null
    $rules = Join-Path $profilePath '.config\opencode\rules\optional'
    Remove-Item -LiteralPath (Join-Path $rules 'new.md')
    $stamp = (Get-Item -LiteralPath (Join-Path $rules 'mcp.md')).LastWriteTimeUtc
    Install-UserConfiguration -Source $source -ProfilePath $profilePath | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $rules 'new.md')) 'deleted shipped rule not restored'
    Assert-Equal (Get-Item -LiteralPath (Join-Path $rules 'mcp.md')).LastWriteTimeUtc $stamp 'existing rule was rewritten'
}

Invoke-Case 'rules: personal path rules (vorgaben) stay as before' {
    $source = New-RuleSource
    $profilePath = New-TempDir 'profile'
    $vorgaben = Join-Path $profilePath '.config\opencode\vorgaben'
    Write-Utf8File (Join-Path $vorgaben 'sample.md') 'my path rule'
    Write-Utf8File (Join-Path $vorgaben 'extra.md') 'my extra path rule'
    Install-UserConfiguration -Source $source -ProfilePath $profilePath | Out-Null
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $vorgaben 'sample.md'))) 'my path rule'
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $vorgaben 'extra.md'))) 'my extra path rule'
}

Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Output "Passed: $script:Passed, failed: $script:Failed"
if ($script:Failed -gt 0) {
    exit 1
}
exit 0
