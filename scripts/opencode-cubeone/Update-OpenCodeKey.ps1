<#
.SYNOPSIS
    Reads the OpenRouter key from HKLM and writes it to every host in the SSH config.

.DESCRIPTION
    The value is OpenRouterApiKey under HKLM\SOFTWARE\cubeone\OpenCode. It is never printed.
    Linux hosts receive ~/.config/opencode/openrouter.key (mode 0600), including an existing
    per-person copy. A Windows host receives the user environment variable OPENROUTER_API_KEY
    and, when the account may write there, the same registry value. Hosts come from ~/.ssh/config.
#>
[CmdletBinding()]
param(
    [string]$ProfilePath = $env:USERPROFILE,
    [string]$OnlyHost
)

$ErrorActionPreference = 'Stop'
$remote = Join-Path $PSScriptRoot 'Install-OpenCodeRemote.ps1'
& $remote -ProfilePath $ProfilePath -SkipWsl -KeyOnly -OnlyHost $OnlyHost
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
