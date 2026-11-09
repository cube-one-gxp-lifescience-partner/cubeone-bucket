<#
.SYNOPSIS
    Regression tests for the principal wrapper's remote setup delegation.

.DESCRIPTION
    Copies the wrapper to an isolated directory with spaces and replaces its sibling remote script with a
    recording stand-in. No real remote setup, SSH, keys, configuration or installer is accessed. Runs on
    Windows PowerShell 5.1 and PowerShell 7 without additional modules. Exits 1 if any case fails.

.NOTES
    Author:     Marvin Fenßel
    Created:    09.11.2026
    Changelog:  09.11.2026 - Added isolated wrapper delegation tests.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path (Join-Path $env:LOCALAPPDATA 'Temp\opencode') (
    'principal wrapper test ' + [guid]::NewGuid().ToString('N')
)
$wrapperSource = Join-Path (Split-Path -Parent $PSScriptRoot) 'Set-OpenCodePrincipal.ps1'
$wrapperCopy = Join-Path $testRoot 'Set-OpenCodePrincipal.ps1'
$remoteCopy = Join-Path $testRoot 'Install-OpenCodeRemote.ps1'
$customProfile = Join-Path $testRoot 'custom profile with spaces'
$throwProfile = 'synthetic remote error'
$passed = 0
$failed = 0
$remoteStub = @'
<#
.SYNOPSIS
    Records delegation arguments or raises a synthetic error.
.NOTES
    Author:     Marvin Fenßel
    Created:    09.11.2026
    Changelog:  09.11.2026 - Added a recording remote setup stand-in.
#>
[CmdletBinding()]
param(
    [string]$SourceDir,
    [string]$ProfilePath,
    [switch]$PrincipalOnly
)
if ($ProfilePath -eq 'synthetic remote error') {
    throw 'synthetic remote error'
}
[pscustomobject]@{
    ProfilePath        = $ProfilePath
    SourceDir          = $SourceDir
    PrincipalOnly      = [bool]$PrincipalOnly
    BoundParameters    = @($PSBoundParameters.Keys | Sort-Object)
}
'@

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    Copy-Item -LiteralPath $wrapperSource -Destination $wrapperCopy
    [System.IO.File]::WriteAllText($remoteCopy, $remoteStub, (New-Object System.Text.UTF8Encoding $false))

    $modes = @(
        @{ Name = 'default'; Arguments = @{}; Full = $false }
        @{ Name = 'explicit false'; Arguments = @{ FullInstall = $false }; Full = $false }
        @{ Name = 'full'; Arguments = @{}; Full = $true }
    )
    foreach ($mode in $modes) {
        foreach ($profile in @(
            @{ Name = 'default profile'; Arguments = @{}; Expected = $env:USERPROFILE }
            @{ Name = 'custom profile'; Arguments = @{ ProfilePath = $customProfile }; Expected = $customProfile }
        )) {
            $caseName = "$($mode.Name), $($profile.Name)"
            try {
                $arguments = @{}
                foreach ($key in $mode.Arguments.Keys) { $arguments[$key] = $mode.Arguments[$key] }
                foreach ($key in $profile.Arguments.Keys) { $arguments[$key] = $profile.Arguments[$key] }
                $result = if ($mode.Full) {
                    @(& $wrapperCopy -FullInstall @arguments)
                } else {
                    @(& $wrapperCopy @arguments)
                }
                $result = @($result)
                if ($result.Count -ne 1) { throw "Expected one remote call, got $($result.Count)." }
                $call = $result[0]
                if ($call.ProfilePath -cne $profile.Expected) { throw 'ProfilePath was not forwarded unchanged.' }
                if ($mode.Full) {
                    if (($call.BoundParameters -join ',') -cne 'ProfilePath,SourceDir') {
                        throw 'Full setup received unexpected parameters.'
                    }
                    if ($call.SourceDir -cne $testRoot) { throw 'SourceDir is not the copied wrapper directory.' }
                    if ($call.PrincipalOnly) { throw 'Full setup enabled PrincipalOnly.' }
                } else {
                    if (($call.BoundParameters -join ',') -cne 'PrincipalOnly,ProfilePath') {
                        throw 'Principal-only setup received unexpected parameters.'
                    }
                    if (-not $call.PrincipalOnly) { throw 'PrincipalOnly was not enabled.' }
                }
                $passed++
                Write-Output "PASS $caseName"
            } catch {
                $caseError = $_
                $failed++
                Write-Output "FAIL $caseName :: $($caseError.Exception.Message)"
            }
        }

        $caseName = "$($mode.Name), remote throw"
        try {
            $arguments = @{ ProfilePath = $throwProfile }
            foreach ($key in $mode.Arguments.Keys) { $arguments[$key] = $mode.Arguments[$key] }
            $caughtMessage = $null
            try {
                & $wrapperCopy @arguments | Out-Null
            } catch {
                $caughtMessage = $_.Exception.Message
            }
            if ($caughtMessage -cne $throwProfile) { throw 'The remote error did not propagate unchanged.' }
            $passed++
            Write-Output "PASS $caseName"
        } catch {
            $caseError = $_
            $failed++
            Write-Output "FAIL $caseName :: $($caseError.Exception.Message)"
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
