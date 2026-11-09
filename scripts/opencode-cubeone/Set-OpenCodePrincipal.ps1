<#
.SYNOPSIS
    Sets the personal cube one id (CUBEONE_PRINCIPAL) for the coding VMs in the user's SSH config.

.DESCRIPTION
    Run once as the Windows user who owns the profile. No administrator rights are needed.
    The script makes ssh send `SetEnv CUBEONE_PRINCIPAL=<id>` to coding-vm-1 to coding-vm-8 through the existing
    ~\.ssh\config. The id is 32 random URL-safe characters from the system's cryptographic random generator.

    What ssh would send is read offline with `ssh.exe -G -F <config> <alias>`. That command prints the effective
    settings and makes no connection, reads no key and prints nothing of the config. The new lines are first
    checked on a temporary copy.

    - All eight aliases already get the same valid id (also quoted, or together with other variables): nothing is
      written.
    - Only some do: their id is reused for all eight. An id under an unrelated Host does not count.
    - A missing SSH config is an error. Nothing is created and no host is invented.
    - A malformed id, different ids, or other SetEnv variables that a new line would hide (ssh uses only the
      first SetEnv line that applies) are errors. The file stays as it is and the message says what to do.
    - A config with Include or with a Match line that has exec is not evaluated (-G would run that command) and
      is not changed. Nothing is suggested to remove: the message says how to merge the id by hand (keep an
      existing id or make one, add it to the first SetEnv line that applies to each alias and keep that line's
      variables and scope; without any SetEnv there, a block followed by `Host *` in front of the old settings).
    - New lines are only inserted at the start of the file (after a BOM), followed by `Host *` so the old
      settings at the top still apply to every host. Everything else stays byte for byte. The file keeps its
      permissions.

    It reads no registry value, starts no ssh connection or wsl, installs nothing and touches no other file.
    The work is done by Install-OpenCodeRemote.ps1 -PrincipalOnly, which stops before the key is read.
#>
[CmdletBinding()]
param(
    [string]$ProfilePath = $env:USERPROFILE
)

$ErrorActionPreference = 'Stop'
$remote = Join-Path $PSScriptRoot 'Install-OpenCodeRemote.ps1'
& $remote -ProfilePath $ProfilePath -PrincipalOnly
