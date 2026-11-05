<#
.SYNOPSIS
    Deploys the cube one OpenCode configuration.

.DESCRIPTION
    Machine part (%ProgramData%\opencode): the managed opencode.jsonc, the mandatory rules, the
    path rules (vorgaben) and the cube one plugins. OpenCode ranks this directory above user and project configuration.
    A directory created by this run is locked: writable only for SYSTEM and Administrators. An existing
    directory keeps its ACL and every write permission it already has, also when it is already current.

    User part (~\.config\opencode): MCP servers in opencode.jsonc and the optional rules. Existing
    files are kept; missing MCP servers and missing optional rules are added.

    Works as SYSTEM (auto-updater), as an elevated administrator and as a standard user. A standard
    user can create the machine directory once; updating an existing one works only where its
    permissions already allow it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceDir
)

$ErrorActionPreference = 'Stop'

$SidSystem = 'S-1-5-18'
$SidAdministrators = 'S-1-5-32-544'
$SidUsers = 'S-1-5-32-545'
$SidOwnerRights = 'S-1-3-4'

function Get-OpenRouterApiKey {
    param([Parameter(Mandatory = $true)][string]$Name)

    # Deposited in the registry. The value is never printed.
    $regBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $regSub = $regBase.OpenSubKey('SOFTWARE\cubeone\OpenCode')
        if (-not $regSub) { return '' }
        try {
            $rawKey = $regSub.GetValue($Name)
            if ($null -eq $rawKey) { return '' }
            $apiKey = ([string]$rawKey).Trim()
            if ($apiKey -match "[\r\n]") { throw "$Name in HKLM\SOFTWARE\cubeone\OpenCode must be a single line." }
            return $apiKey
        } finally {
            $regSub.Close()
        }
    } finally {
        $regBase.Close()
    }
}

function Test-IsElevated {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal $identity
    return $identity.User.Value -eq $SidSystem -or $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-ProfilePathFile {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    if (-not (Test-Path -LiteralPath $FilePath)) {
        return ''
    }
    $value = [System.IO.File]::ReadAllText($FilePath).Trim()
    if ($value.StartsWith([char]0xFEFF)) {
        $value = $value.Substring(1).Trim()
    }
    if (-not $value -or -not (Test-Path -LiteralPath $value -PathType Container)) {
        return ''
    }
    return [System.IO.Path]::GetFullPath($value).TrimEnd('\')
}

function Resolve-TargetProfilePath {
    # Same lookup as coding-vms-ssh: the auto-updater runs as SYSTEM and names the profile in these files.
    foreach ($file in @('C:\Temp\home', 'C:\cubeone\auto-updater\home.cache')) {
        $fromFile = Read-ProfilePathFile -FilePath $file
        if ($fromFile) {
            return $fromFile
        }
    }
    if (-not $env:USERPROFILE) {
        throw 'Could not resolve target profile: auto-updater home files missing and USERPROFILE is empty'
    }
    return [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
}

function Get-RelativeFiles {
    param([Parameter(Mandatory = $true)][string]$Root)

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force | ForEach-Object {
        $_.FullName.Substring($rootFull.Length + 1)
    }
}

function Test-TreeEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Target
    )

    if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
        return $false
    }
    $sourceFiles = @(Get-RelativeFiles -Root $Source | Sort-Object)
    $targetFiles = @(Get-RelativeFiles -Root $Target | Sort-Object)
    if (Compare-Object $sourceFiles $targetFiles) {
        return $false
    }
    foreach ($file in $sourceFiles) {
        $a = (Get-FileHash -LiteralPath (Join-Path $Source $file) -Algorithm SHA256).Hash
        $b = (Get-FileHash -LiteralPath (Join-Path $Target $file) -Algorithm SHA256).Hash
        if ($a -ne $b) {
            return $false
        }
    }
    return $true
}

function Invoke-Icacls {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & icacls.exe @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "icacls $($Arguments -join ' ') failed (exit $LASTEXITCODE): $output"
    }
}

function Invoke-TakeownAdministrators {
    param([Parameter(Mandatory = $true)][string]$Path)

    # /D is localized. English Windows accepts Y, German Windows only J. The help text quotes the letter.
    $help = & takeown.exe /? 2>&1 | Out-String
    $answer = if ($help -match '"J"') { 'J' } else { 'Y' }
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & takeown.exe /F $Path /R /A /D $answer 2>&1 | Out-Null
    } finally {
        $ErrorActionPreference = $saved
    }
    if ($LASTEXITCODE -ne 0) {
        throw "takeown /F $Path /R /A /D $answer failed with exit $LASTEXITCODE"
    }
}

function Protect-ManagedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$Elevated
    )

    # Only for a directory this run has just created (see Install-ManagedConfiguration). It replaces the
    # inherited ACL, so it must never be called for an existing installation.
    # Principals are addressed by SID: localized group names and non-ASCII
    # account names do not survive the native-command argument encoding.
    $grants = @("*${SidSystem}:(OI)(CI)(F)", "*${SidAdministrators}:(OI)(CI)(F)", "*${SidUsers}:(OI)(CI)(RX)")
    if ($Elevated) {
        Invoke-Icacls @($Path, '/setowner', "*$SidAdministrators", '/T', '/C', '/Q')
        Invoke-Icacls (@($Path, '/inheritance:r', '/grant:r') + $grants + @('/Q'))
        Invoke-Icacls @((Join-Path $Path '*'), '/reset', '/T', '/C', '/Q')
        return
    }
    # A standard user stays owner and would keep the implicit right to rewrite
    # the ACL. An OWNER RIGHTS entry replaces that implicit right, so this has
    # to be the last change: afterwards the user can no longer touch the ACL.
    # The freshly copied files carry only inherited entries, which this one
    # call replaces.
    Invoke-Icacls (@($Path, '/inheritance:r', '/grant:r') + $grants + @("*${SidOwnerRights}:(OI)(CI)(RX)", '/Q'))
}

function Test-FileLocked {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $stream.Dispose()
        return $false
    } catch {
        return $true
    }
}

function Sync-ManagedTree {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $sourceFiles = @(Get-RelativeFiles -Root $Source)
    $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $sourceFiles) { [void]$wanted.Add($file) }
    $changed = @($sourceFiles | Where-Object {
            $existing = Join-Path $Target $_
            -not (Test-Path -LiteralPath $existing -PathType Leaf) -or
            (Get-FileHash -LiteralPath (Join-Path $Source $_) -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $existing -Algorithm SHA256).Hash
        })
    $stale = @(Get-RelativeFiles -Root $Target | Where-Object { -not $wanted.Contains($_) })

    # A running OpenCode keeps native modules such as rust_pty.dll open. Every file that has to change is checked
    # before the first one is touched, so a locked file cannot leave the tree half replaced.
    $locked = @(@($changed) + @($stale) | Where-Object { Test-FileLocked -Path (Join-Path $Target $_) })
    if ($locked.Count -gt 0) {
        throw "OpenCode is running and keeps files in $Target open ($($locked -join ', ')). Close OpenCode and run the installation again. Nothing was changed."
    }

    foreach ($file in $changed) {
        $destination = Join-Path $Target $file
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $Source $file) -Destination $destination -Force
    }
    foreach ($file in $stale) {
        Remove-Item -LiteralPath (Join-Path $Target $file) -Force
    }
    Get-ChildItem -LiteralPath $Target -Recurse -Directory -Force |
        Sort-Object { $_.FullName.Length } -Descending |
        Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force) } |
        Remove-Item -Force
}

function Test-CanWrite {
    param([Parameter(Mandatory = $true)][string]$Path)

    $probe = Join-Path $Path ('.write-probe-' + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force
        return $true
    } catch {
        return $false
    }
}

function Install-ManagedConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$Staging,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $elevated = Test-IsElevated
    if (Test-TreeEqual -Source $Staging -Target $Target) {
        # Nothing to write and nothing to touch: permissions of an existing installation stay as they are.
        Write-Host "Managed OpenCode configuration in $Target is current." -ForegroundColor Cyan
        return
    }

    # Only a directory that did not exist and that this run created empty counts as a new installation. Its
    # ACL is set once at the end. Anything that existed before keeps its ACL and its write permissions.
    $fresh = -not (Test-Path -LiteralPath $Target)
    if ($fresh) {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
        if (@(Get-ChildItem -LiteralPath $Target -Force).Count -gt 0) {
            # Somebody else created and filled it between the check and New-Item: treat it as existing.
            $fresh = $false
        }
    }
    if ($fresh) {
        # Nothing to prepare.
    } elseif ($elevated) {
        # Emergency access for an administrator who cannot write yet. Add an entry first; take ownership
        # only when that is refused. Nothing is removed in either step.
        if (-not (Test-CanWrite -Path $Target)) {
            $adminGrant = @($Target, '/grant', "*${SidAdministrators}:(OI)(CI)(F)", '/T', '/C', '/Q')
            try {
                Invoke-Icacls $adminGrant
            } catch {
                Invoke-TakeownAdministrators -Path $Target
                Invoke-Icacls $adminGrant
            }
        }
    } elseif (-not (Test-CanWrite -Path $Target)) {
        Write-Warning "The managed OpenCode configuration in $Target is outdated and locked. Run 'scoop update opencode-desktop --force' as administrator, or let the auto-updater apply it."
        return
    }

    Sync-ManagedTree -Source $Staging -Target $Target
    if (-not (Test-TreeEqual -Source $Staging -Target $Target)) {
        throw "Managed OpenCode configuration in $Target does not match the package after copying"
    }
    if ($fresh) {
        Protect-ManagedDirectory -Path $Target -Elevated $elevated
        Write-Host "Managed OpenCode configuration written to $Target and locked for SYSTEM and Administrators." -ForegroundColor Green
    } else {
        Write-Host "Managed OpenCode configuration in $Target updated. Existing permissions were left unchanged." -ForegroundColor Green
    }
}

function Remove-JsoncComment {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    # Strips // and /* */ comments outside strings. Strings, escapes and URLs such as "https://host" stay as they are.
    $builder = New-Object System.Text.StringBuilder
    $inString = $false
    $i = 0
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if ($inString) {
            [void]$builder.Append($c)
            if ($c -eq '\' -and $i + 1 -lt $Text.Length) {
                [void]$builder.Append($Text[$i + 1])
                $i += 2
                continue
            }
            if ($c -eq '"') {
                $inString = $false
            }
            $i++
            continue
        }
        if ($c -eq '"') {
            $inString = $true
            [void]$builder.Append($c)
            $i++
            continue
        }
        if ($c -eq '/' -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '/') {
            while ($i -lt $Text.Length -and $Text[$i] -ne "`n") {
                $i++
            }
            continue
        }
        if ($c -eq '/' -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '*') {
            $end = $Text.IndexOf('*/', $i + 2)
            $i = if ($end -lt 0) { $Text.Length } else { $end + 2 }
            continue
        }
        [void]$builder.Append($c)
        $i++
    }
    return $builder.ToString()
}


function Remove-JsoncTrailingComma {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    # Drops a comma only when it stands outside a string and only whitespace separates it from } or ].
    # Expects the text without comments. A comma inside a string such as "a,}" is never touched.
    $builder = New-Object System.Text.StringBuilder
    $inString = $false
    $i = 0
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if ($inString) {
            [void]$builder.Append($c)
            if ($c -eq '\' -and $i + 1 -lt $Text.Length) {
                [void]$builder.Append($Text[$i + 1])
                $i += 2
                continue
            }
            if ($c -eq '"') {
                $inString = $false
            }
            $i++
            continue
        }
        if ($c -eq '"') {
            $inString = $true
        } elseif ($c -eq ',') {
            $next = $i + 1
            while ($next -lt $Text.Length -and [char]::IsWhiteSpace($Text[$next])) {
                $next++
            }
            if ($next -lt $Text.Length -and ($Text[$next] -eq '}' -or $Text[$next] -eq ']')) {
                $i++
                continue
            }
        }
        [void]$builder.Append($c)
        $i++
    }
    return $builder.ToString()
}


function ConvertFrom-Jsonc {
    param([Parameter(Mandatory = $true)][string]$Text)

    $withoutComments = Remove-JsoncComment -Text $Text
    $clean = Remove-JsoncTrailingComma -Text $withoutComments
    return $clean | ConvertFrom-Json
}

function Install-UserConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$ProfilePath
    )

    $configDir = Join-Path $ProfilePath '.config\opencode'
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding $false

    $template = Join-Path $Source 'opencode.jsonc'
    $existing = @('opencode.jsonc', 'opencode.json') | ForEach-Object { Join-Path $configDir $_ } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $existing) {
        Copy-Item -LiteralPath $template -Destination (Join-Path $configDir 'opencode.jsonc')
        Write-Host "MCP servers written to $configDir\opencode.jsonc" -ForegroundColor Green
    } else {
        $wanted = (ConvertFrom-Jsonc -Text ([System.IO.File]::ReadAllText($template))).mcp.servers
        try {
            $current = ConvertFrom-Jsonc -Text ([System.IO.File]::ReadAllText($existing))
        } catch {
            Write-Warning "Could not parse $existing, MCP servers were not added: $($_.Exception.Message)"
            $current = $null
        }
        if ($current) {
            if (-not $current.PSObject.Properties['mcp']) {
                $current | Add-Member -NotePropertyName mcp -NotePropertyValue ([pscustomobject]@{})
            }
            if (-not $current.mcp.PSObject.Properties['servers']) {
                $current.mcp | Add-Member -NotePropertyName servers -NotePropertyValue ([pscustomobject]@{})
            }
            $added = @()
            foreach ($server in $wanted.PSObject.Properties) {
                if (-not $current.mcp.servers.PSObject.Properties[$server.Name]) {
                    $current.mcp.servers | Add-Member -NotePropertyName $server.Name -NotePropertyValue $server.Value
                    $added += $server.Name
                }
            }
            if ($added.Count -gt 0) {
                Copy-Item -LiteralPath $existing -Destination "$existing.bak" -Force
                [System.IO.File]::WriteAllText($existing, ($current | ConvertTo-Json -Depth 30), $utf8WithoutBom)
                Write-Host "Added MCP servers to ${existing}: $($added -join ', ') (backup: $existing.bak)" -ForegroundColor Green
            } else {
                Write-Host "All cube one MCP servers are already configured in $existing." -ForegroundColor Cyan
            }
        }
    }

    $rulesSource = Join-Path $Source 'rules\optional'
    $rulesTarget = Join-Path $configDir 'rules\optional'
    New-Item -ItemType Directory -Path $rulesTarget -Force | Out-Null
    # Personal files stay: a rule that already exists, edited or not, is never overwritten, and files that are
    # not part of the package are never removed. Only shipped rules that are missing are added.
    foreach ($rule in Get-ChildItem -LiteralPath $rulesSource -File -Filter *.md) {
        $destination = Join-Path $rulesTarget $rule.Name
        if (-not (Test-Path -LiteralPath $destination)) {
            Copy-Item -LiteralPath $rule.FullName -Destination $destination
            Write-Host "Optional rule added: $destination" -ForegroundColor Green
        }
    }

    # Rules tied to file types. The plugin reads them only when the agent touches a matching file.
    $vorgabenSource = Join-Path $Source 'vorgaben'
    $vorgabenTarget = Join-Path $configDir 'vorgaben'
    New-Item -ItemType Directory -Path $vorgabenTarget -Force | Out-Null
    foreach ($rule in Get-ChildItem -LiteralPath $vorgabenSource -File) {
        $destination = Join-Path $vorgabenTarget $rule.Name
        if (-not (Test-Path -LiteralPath $destination)) {
            Copy-Item -LiteralPath $rule.FullName -Destination $destination
            Write-Host "Path rule added: $destination" -ForegroundColor Green
        }
    }

    $memorySource = Join-Path $Source 'opencode-mem.jsonc'
    $memoryTarget = Join-Path $configDir 'opencode-mem.jsonc'
    if ((Test-Path -LiteralPath $memorySource) -and -not (Test-Path -LiteralPath $memoryTarget)) {
        Copy-Item -LiteralPath $memorySource -Destination $memoryTarget
        Write-Host "Local memory settings written to $memoryTarget" -ForegroundColor Green
    }
}

$SourceDir = [System.IO.Path]::GetFullPath($SourceDir)
foreach ($required in @('managed\opencode.jsonc', 'managed\rules', 'managed\vorgaben', 'plugins\cubeone-stt\dist\gui-experimental.cjs', 'plugins\cubeone-stt\dist\server.js', 'plugins\cubeone-pty\server.js', 'plugins\cubeone-pty\node_modules\opencode-pty', 'plugins\cubeone-vorgaben\server.js', 'plugins\cubeone-vorgaben\gui-experimental.cjs', 'plugins\cubeone-mcp\server.js', 'plugins\cubeone-mcp\gui-experimental.cjs', 'plugins\cubeone-cursor-skills\server.js', 'plugins\cubeone-redmine\server.js', 'plugins\cubeone-dcp-view\server.js', 'plugins\cubeone-dcp-view\display.js', 'plugins\cubeone-sale\server.js', 'plugins\cubeone-sale\sale.js', 'Install-OpenCodeRemote.ps1', 'user\opencode.jsonc', 'user\opencode-mem.jsonc', 'user\vorgaben', 'user\rules\optional')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDir $required))) {
        throw "Package is incomplete, missing $required"
    }
}

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ('opencode-cubeone-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $SourceDir 'managed\opencode.jsonc') -Destination $staging
    Copy-Item -LiteralPath (Join-Path $SourceDir 'managed\rules') -Destination $staging -Recurse
    Copy-Item -LiteralPath (Join-Path $SourceDir 'managed\vorgaben') -Destination $staging -Recurse
    Copy-Item -LiteralPath (Join-Path $SourceDir 'Install-OpenCodeRemote.ps1') -Destination $staging
    $pluginTarget = Join-Path $staging 'cubeone\plugins\cubeone-stt'
    New-Item -ItemType Directory -Path (Join-Path $pluginTarget 'dist') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $SourceDir 'plugins\cubeone-stt\package.json') -Destination $pluginTarget
    Copy-Item -LiteralPath (Join-Path $SourceDir 'plugins\cubeone-stt\dist\gui-experimental.cjs') -Destination (Join-Path $pluginTarget 'dist')
    Copy-Item -LiteralPath (Join-Path $SourceDir 'plugins\cubeone-stt\dist\server.js') -Destination (Join-Path $pluginTarget 'dist')
    Copy-Item -LiteralPath (Join-Path $SourceDir 'plugins\cubeone-pty') -Destination (Join-Path $staging 'cubeone\plugins\cubeone-pty') -Recurse
    foreach ($name in @('cubeone-vorgaben', 'cubeone-mcp', 'cubeone-cursor-skills', 'cubeone-redmine', 'cubeone-dcp-view', 'cubeone-sale')) {
        $target = Join-Path $staging "cubeone\plugins\$name"
        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Get-ChildItem -LiteralPath (Join-Path $SourceDir "plugins\$name") -File | Copy-Item -Destination $target
    }

    Install-ManagedConfiguration -Staging $staging -Target (Join-Path $env:ProgramData 'opencode')
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

$targetProfile = Resolve-TargetProfilePath
Install-UserConfiguration -Source (Join-Path $SourceDir 'user') -ProfilePath $targetProfile

$apiKey = Get-OpenRouterApiKey -Name 'OpenRouterApiKey'
if (-not $apiKey) {
    Write-Warning 'HKLM\SOFTWARE\cubeone\OpenCode OpenRouterApiKey is not set. OpenCode shows no models until that value exists.'
} else {
    Remove-Variable apiKey
    Write-Host 'OpenRouter key found in HKLM\SOFTWARE\cubeone\OpenCode.'
}
$voiceKey = Get-OpenRouterApiKey -Name 'OpenRouterVoiceApiKey'
if (-not $voiceKey) {
    Write-Warning 'HKLM\SOFTWARE\cubeone\OpenCode OpenRouterVoiceApiKey is not set. Dictation fails until that value exists.'
} else {
    Remove-Variable voiceKey
    Write-Host 'OpenRouter voice key found in HKLM\SOFTWARE\cubeone\OpenCode.'
}

$remoteScript = Join-Path $SourceDir 'Install-OpenCodeRemote.ps1'
if (Test-Path -LiteralPath $remoteScript) {
    & $remoteScript -SourceDir $SourceDir -ProfilePath $targetProfile
}
