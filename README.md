# Scoop Bucket Template

<!-- Uncomment the following line after replacing placeholders -->
<!-- [![Tests](https://github.com/<username>/<bucketname>/actions/workflows/ci.yml/badge.svg)](https://github.com/<username>/<bucketname>/actions/workflows/ci.yml) [![Excavator](https://github.com/<username>/<bucketname>/actions/workflows/excavator.yml/badge.svg)](https://github.com/<username>/<bucketname>/actions/workflows/excavator.yml) -->

Template bucket for [Scoop](https://scoop.sh), the Windows command-line installer.

## How do I use this template?

1. Generate your own copy of this repository with the "Use this template"
   button.
2. Allow all GitHub Actions:
   - Navigate to `Settings` - `Actions` - `General` - `Actions permissions`.
   - Select `Allow all actions and reusable workflows`.
   - Then `Save`.
3. Allow writing to the repository from within GitHub Actions:
   - Navigate to `Settings` - `Actions` - `General` - `Workflow permissions`.
   - Select `Read and write permissions`.
   - Then `Save`.
4. Document the bucket in `README.md`.
5. Replace the placeholder repository string in `bin/auto-pr.ps1`.
6. Create new manifests by copying `bucket/app-name.json.template` to
   `bucket/<app-name>.json`.
7. Commit and push changes.
8. If you'd like your bucket to be indexed on `https://scoop.sh`, add the
   topic `scoop-bucket` to your repository.

## How do I install these manifests?

After manifests have been committed and pushed, run the following:

```pwsh
scoop bucket add <bucketname> https://github.com/<username>/<bucketname>
scoop install <bucketname>/<manifestname>
```

## How do I contribute new manifests?

To make a new manifest contribution, please read the [Contributing
Guide](https://github.com/ScoopInstaller/.github/blob/main/.github/CONTRIBUTING.md)
and [App Manifests](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests)
wiki page.

## OpenCode Desktop (cube one package)

`bucket/opencode-desktop.json` installs the OpenCode desktop app (download from opencode.ai) and the cube one
configuration from `files/opencode-cubeone-<version>.zip`. The zip is built from
`scripts/opencode-cubeone`. Published zips are immutable: every change of the scripts, rules, plugins or
configuration is a new zip with the next free version.

### Remote setup (WSL and Linux SSH hosts) and the identity it runs as

`Install-OpenCodeCubeOne.ps1` finishes with the setup of WSL distros and Linux SSH hosts
(`Install-OpenCodeRemote.ps1`). `ssh.exe` signs in with the key and the key file permissions of the identity
that runs it. Pointing `HOME` or `USERPROFILE` at another profile does not change that identity, so the setup
only works as the Windows user who owns the profile.

| Installer runs as | Result |
| --- | --- |
| The profile user (for example `scoop install` in a normal session) | The remote setup runs directly. |
| SYSTEM (auto-updater), or any other account | The Scoop install succeeds and the remote setup is **deferred**. Nothing is read, connected or sent. The warning contains the exact command to run once as the profile user. |
| The profile cannot be matched to exactly one user account | Deferred as well, with the same command. |

**The remote setup is not done automatically for SYSTEM.** This package does not start anything in the user's
session; there is no hook in this repository that does. After an auto-updater run, the remote hosts keep their
previous configuration until the user runs the command from the warning, for example:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<scoop app dir>\cubeone\Install-OpenCodeRemote.ps1" -SourceDir "<scoop app dir>\cubeone" -ProfilePath "C:\Users\<name>"
```

The profile SID comes from `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList` (profile paths and SID
names only). `Install-OpenCodeRemote.ps1` also checks this itself first and refuses to start when it is run by
SYSTEM or for a profile that is not the profile of the running account. That covers `Update-OpenCodeKey.ps1` too.
SSH host keys, the SSH config and the key file permissions are never changed by the setup.

#### Result of a run

A run counts its targets as succeeded, skipped or failed.

- **Skipped** are hosts the setup does not cover: a Windows SSH host in the full setup (only the key is updated
  there by `Update-OpenCodeKey.ps1`), or a system that is neither Linux nor Windows.
- **Failed** is everything it tried and could not finish, including a host that could not be reached or logged
  in to (a failed login says nothing about the host's system).
- If any target failed, the script ends with an error and the count (`failed on 1 of 3 targets (2 succeeded, 0
  skipped)`). `Update-OpenCodeKey.ps1` therefore exits non-zero. The Scoop installer catches it, prints a
  warning and still finishes the app install.

Each host warning carries one fixed label (for example `authentication failed (public key denied)` or `host not
reachable`) and never the raw output of `ssh`. A host is identified by `uname -s` (accepted only as exactly
`Linux`) and, if that fails without a connection error, by a read-only PowerShell probe. The key is sent to a
Windows host only after that probe identified it as Windows.

### Tests

Run all of them before building a package. Both shells must report no failure.

```powershell
cd scripts\opencode-cubeone\test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-OpenCodeCubeOne.Tests.ps1
pwsh -NoProfile -File .\Install-OpenCodeCubeOne.Tests.ps1
powershell.exe -NoProfile -Command "Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path .\Install-OpenCodeRemote.Tests.ps1"
```

`Install-OpenCodeRemote.Tests.ps1` needs Pester 3.4, which is installed for Windows PowerShell. Under `pwsh`
four older cases fail because Pester 3.4 cannot evaluate `Should Throw` there; that is not a regression. The
transport is always replaced by a mock: no ssh, wsl, registry key or scheduled task is used.

### Releasing a new package

1. Make and test the change as above.
2. Commit the sources and tests. Pick the next free version (`files/opencode-cubeone-<version>.zip`, higher than
   every published one) and build it from the committed files, not from the working tree. Earlier packages hold
   the files as stored in git (LF), while a Windows checkout has CRLF (`.gitattributes`). Build with PowerShell 7:
   Windows PowerShell 5.1 writes backslashes into the zip entry names.

   ```powershell
   $export = Join-Path $env:TEMP 'bucket-export'
   New-Item -ItemType Directory -Path "$export\files" -Force | Out-Null
   foreach ($file in git ls-files scripts/opencode-cubeone) {
       New-Item -ItemType Directory -Path (Split-Path "$export\$file") -Force | Out-Null
       cmd /c "git show HEAD:$file > `"$export\$file`""
   }
   pwsh -NoProfile -File "$export\scripts\opencode-cubeone\Build-OpenCodeCubeOne.ps1" -Version <version>
   Copy-Item "$export\files\opencode-cubeone-<version>.zip" files\
   ```

   The script refuses an existing zip and prints the SHA-256. The build installs the production dependencies of
   `cubeone-pty` with `npm` (as locked in `package-lock.json`).

   Compare the new zip with the previous one entry by entry: only the intended files may differ. The installer
   compares the managed folder byte by byte (SHA-256), so a file that differs only in its line endings makes
   every installation count as outdated. Some files of earlier packages have CRLF where git stores LF; copy the
   previous bytes of such unchanged files into the export before building.
3. Check the zip: it opens, contains `Install-OpenCodeCubeOne.ps1`, `Install-OpenCodeRemote.ps1`, `managed`, `user`
   and `plugins`, and holds no `.env`, key or credential.
4. In `bucket/opencode-desktop.json` change only the zip URL (second `url` entry under `architecture.64bit`
   and the matching one in `autoupdate`) and its hash (second `hash` entry). Keep `version` and the hash of
   the desktop download as they are.
5. Commit the zip and the manifest. Push only after review.
