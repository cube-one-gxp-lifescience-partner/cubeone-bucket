<#
.SYNOPSIS
    Deploys the cube one OpenCode configuration.

.DESCRIPTION
    Machine part (%ProgramData%\opencode): the managed opencode.jsonc, the mandatory rules and the
    speech-to-text plugin. OpenCode ranks this directory above user and project configuration. The
    directory is left writable only for SYSTEM and Administrators.

    User part (~\.config\opencode): MCP servers in opencode.jsonc and the optional rules. Existing
    files are kept; missing MCP servers and missing optional rules are added.

    Works as SYSTEM (auto-updater), as an elevated administrator and as a standard user. A standard
    user can create the machine directory once, but cannot change it afterwards.
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

function Protect-ManagedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$Elevated
    )

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
        Write-Host "Managed OpenCode configuration in $Target is current." -ForegroundColor Cyan
        if ($elevated) {
            Protect-ManagedDirectory -Path $Target -Elevated $true
        }
        return
    }

    if (Test-Path -LiteralPath $Target) {
        if ($elevated) {
            $null = & takeown.exe /F $Target /R /A /D Y 2>&1
            Invoke-Icacls @($Target, '/grant', "*${SidAdministrators}:(OI)(CI)(F)", '/T', '/C', '/Q')
        } elseif (-not (Test-CanWrite -Path $Target)) {
            Write-Warning "The managed OpenCode configuration in $Target is outdated and locked. Run 'scoop update opencode-desktop --force' as administrator, or let the auto-updater apply it."
            return
        }
        Get-ChildItem -LiteralPath $Target -Force | Remove-Item -Recurse -Force
    } else {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
    }

    Copy-Item -Path (Join-Path $Staging '*') -Destination $Target -Recurse -Force
    if (-not (Test-TreeEqual -Source $Staging -Target $Target)) {
        throw "Managed OpenCode configuration in $Target does not match the package after copying"
    }
    Protect-ManagedDirectory -Path $Target -Elevated $elevated
    Write-Host "Managed OpenCode configuration written to $Target and locked for SYSTEM and Administrators." -ForegroundColor Green
}

function ConvertFrom-Jsonc {
    param([Parameter(Mandatory = $true)][string]$Text)

    # Strips // and /* */ comments outside strings, then trailing commas.
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
    $clean = [regex]::Replace($builder.ToString(), ',(\s*[}\]])', '$1')
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
    foreach ($rule in Get-ChildItem -LiteralPath $rulesSource -File) {
        $destination = Join-Path $rulesTarget $rule.Name
        if (-not (Test-Path -LiteralPath $destination)) {
            Copy-Item -LiteralPath $rule.FullName -Destination $destination
            Write-Host "Optional rule added: $destination" -ForegroundColor Green
        }
    }
}

$SourceDir = [System.IO.Path]::GetFullPath($SourceDir)
foreach ($required in @('managed\opencode.jsonc', 'managed\rules', 'plugins\cubeone-stt\dist\gui-experimental.cjs', 'plugins\cubeone-stt\dist\server.js', 'user\opencode.jsonc')) {
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDir $required))) {
        throw "Package is incomplete, missing $required"
    }
}

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ('opencode-cubeone-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $SourceDir 'managed\opencode.jsonc') -Destination $staging
    Copy-Item -LiteralPath (Join-Path $SourceDir 'managed\rules') -Destination $staging -Recurse
    $pluginTarget = Join-Path $staging 'cubeone\plugins\cubeone-stt'
    New-Item -ItemType Directory -Path (Join-Path $pluginTarget 'dist') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $SourceDir 'plugins\cubeone-stt\package.json') -Destination $pluginTarget
    Copy-Item -LiteralPath (Join-Path $SourceDir 'plugins\cubeone-stt\dist\gui-experimental.cjs') -Destination (Join-Path $pluginTarget 'dist')
    Copy-Item -LiteralPath (Join-Path $SourceDir 'plugins\cubeone-stt\dist\server.js') -Destination (Join-Path $pluginTarget 'dist')

    Install-ManagedConfiguration -Staging $staging -Target (Join-Path $env:ProgramData 'opencode')
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

$targetProfile = Resolve-TargetProfilePath
Install-UserConfiguration -Source (Join-Path $SourceDir 'user') -ProfilePath $targetProfile

$apiKey = @(
    $env:OPENROUTER_API_KEY
    [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'User')
    [Environment]::GetEnvironmentVariable('OPENROUTER_API_KEY', 'Machine')
) | Where-Object { $_ } | Select-Object -First 1
if (-not $apiKey) {
    Write-Warning 'OPENROUTER_API_KEY is not set. OpenCode shows no models and dictation fails until it is set for the user.'
}
