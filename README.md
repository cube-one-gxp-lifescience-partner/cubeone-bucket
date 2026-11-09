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

### Default install and the personal id

The default install is lean and local. `scoop install opencode-desktop` and the auto-updater write the managed
configuration in `%ProgramData%\opencode` and the user's `~\.config\opencode`, and check that the OpenRouter keys
exist in the registry. They start no `ssh` or `wsl`, read no SSH config, set no personal id and register no
desktop hosts. This also holds when the installer runs as SYSTEM.

```powershell
scoop install opencode-desktop
```

Each user sets the personal cube one id (`CUBEONE_PRINCIPAL`) once, on every machine, as that user. No
administrator rights are needed. The script ships in the package:

```powershell
$source = Join-Path (scoop prefix opencode-desktop) 'cubeone'
& "$source\Set-OpenCodePrincipal.ps1"
```

`Set-OpenCodePrincipal.ps1` (parameter `-ProfilePath`, default the current user's profile) makes ssh send
`SetEnv CUBEONE_PRINCIPAL=<32 random URL-safe characters>` to `coding-vm-1` to `coding-vm-8` by adding a block to the
**existing** `~\.ssh\config`. It reads no registry value, makes no SSH connection, starts no `wsl` or CLI installer
and installs nothing.

It decides from what ssh would really use, read **offline** with `ssh.exe -G -F <config> <alias>` for each of the
eight aliases. `-G` only prints the effective settings. It connects to nothing and reads no key, and neither its
output nor the config is printed. The Windows OpenSSH client (`%SystemRoot%\System32\OpenSSH\ssh.exe`) is used first.
OpenSSH uses only the first `SetEnv` line that applies to a host and ignores all later ones, which is why a plain
extra line would not be safe.

- All eight aliases already get the same valid id (22 to 80 characters of `A-Z a-z 0-9 _ -`; quoted, from `Host *`
  or next to other variables is fine): nothing is written, not even the timestamp.
- Only some aliases get a valid id: that id is reused for all eight. An id under an unrelated `Host` does not count.
- No alias gets one: 32 random characters (CSPRNG) are generated.
- A missing SSH config is an error. Nothing is created and no host is invented.
- Stops with the file unchanged and a message that says what to do by hand: a malformed id, different ids for
  different aliases, other `SetEnv` variables for the eight aliases that a new line would hide, or a config that
  `ssh.exe -G` cannot read.
- **Not supported, left unchanged:** a config with `Include` (included files are not checked) or with a `Match` line
  that has `exec`. `ssh -G` would run that command, so the config is only read as text and `ssh` is not started.
  Those lines stay as they are and nothing is suggested to remove; the message says how to set the id by hand.
- **Setting the id by hand** (for every case where the file is left unchanged): keep an id that already exists for
  any of `coding-vm-1` to `coding-vm-8`; otherwise make one of 22 to 80 characters (`A-Z a-z 0-9 _ -`), for example
  `[guid]::NewGuid().ToString('N')` in PowerShell. Add `CUBEONE_PRINCIPAL=<id>` to the **first `SetEnv` line that
  applies** to each of the eight hosts and keep the variables and the `Host` scope that line already has (ssh
  ignores every later `SetEnv` line). Only where no `SetEnv` applies to them yet, put
  `Host coding-vm-1 ... coding-vm-8` with `    SetEnv CUBEONE_PRINCIPAL=<id>`, followed by `Host *`, in front of the
  old settings at the top of the file, so those settings keep applying to every host. Never add just the two lines
  at the top: that would move the old top-of-file settings into the block or hide an existing `SetEnv`.
- The new text is only inserted at the very start of the file (after a BOM): the block with the eight aliases, then
  `Host *` so settings that stood at the top of the file still apply to every host, then the original bytes. Before
  anything is written, `ssh -G` is run on a temporary copy: the eight aliases must get exactly this id and nothing
  else, and no other setting of the eight aliases or of an unrelated alias may change. Otherwise the file stays
  as it is. The file is written in place and keeps its permissions. Host keys and private keys are not touched.
### Full install (administrators) and the identity it runs as

The full remote setup is still shipped, for administrators. It installs the managed configuration, the plugins
and the OpenRouter key on WSL distros and Linux SSH hosts (`Install-OpenCodeRemote.ps1`). It is off unless asked
for with `-FullInstall`:

```powershell
$source = Join-Path (scoop prefix opencode-desktop) 'cubeone'
& "$source\Install-OpenCodeCubeOne.ps1" -SourceDir $source -FullInstall
# or only the remote part, for example one host and no WSL (one alias per call):
& "$source\Install-OpenCodeRemote.ps1" -SourceDir $source -SkipWsl -OnlyHost coding-vm-1
```

It needs the SSH keys of the Windows user who owns the profile and a server account with passwordless `sudo`
(`sudo -n`). `ssh.exe` signs in with the key and the key file permissions of the identity that runs it. Pointing
`HOME` or `USERPROFILE` at another profile does not change that identity, so the setup only works as the Windows
user who owns the profile. An administrator who is a different Windows identity than the profile owner does not
get a workaround: the setup is deferred, and there is no `sudo` or Windows impersonation.

| `-FullInstall` runs as | Result |
| --- | --- |
| The profile user (for example `scoop install` in a normal session) | The remote setup runs directly. |
| SYSTEM (auto-updater), or any other account | The Scoop install succeeds and the remote setup is **deferred**. Nothing is read, connected or sent. The warning contains the exact command to run once as the profile user. |
| The profile cannot be matched to exactly one user account | Deferred as well, with the same command. |

**The remote setup is never done automatically for SYSTEM.** This package does not start anything in the user's
session; there is no hook in this repository that does. After the deferral, run the command from the warning as
the profile user, for example:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<scoop app dir>\cubeone\Install-OpenCodeRemote.ps1" -SourceDir "<scoop app dir>\cubeone" -ProfilePath "C:\Users\<name>"
```

The profile SID comes from `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList` (profile paths and SID
names only). `Install-OpenCodeRemote.ps1` also checks this itself first and refuses to start when it is run by
SYSTEM or for a profile that is not the profile of the running account. That covers `Update-OpenCodeKey.ps1` and
`Set-OpenCodePrincipal.ps1` too. The full setup also sets the personal id the same way as `Set-OpenCodePrincipal.ps1` (offline `ssh -G`, same limits). If that cannot be done it prints a warning and continues; run `Set-OpenCodePrincipal.ps1` after fixing the SSH config. SSH host keys, private keys and the key file permissions are never changed by the setup.
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

### Models and agent roles

The default model and the model of every role is **Auto (ZDR, EU)**: `openrouter-zdr/openrouter/auto`. This is the
existing global OpenRouter Auto router, and the request still goes through OpenRouter's global request handling.
**This is not end-to-end EU data residency.** What the configuration pins is the inference: the router may only
choose models on its allow-list that take image and PDF input, and the request carries `zdr: true`,
`data_collection: deny`, an `only` list of EU endpoints and `allow_fallbacks: false`. These settings are unchanged
by the role mapping and the variants do not widen them. The root model has no variant and behaves like `balanced`.
A role picks only the variant, which is the cost tier of the router:

| Role | Variant | Cost tier |
| --- | --- | --- |
| `orchestrator`, `architect` | `intelligence` | max |
| `developer`, `reviewer` | `balanced` | medium |
| `quick`, `researcher` | `cost` | low |
| `ask` | none, inherits the current model | |

The router decides per request which allowed model answers, so a role has no fixed model and no fixed price. The
variants set the `cost_tier` band (`low`, `medium`, `max`); they are not token prices. The price depends on the
model that was chosen; the per-model prices stay in the generated configuration. Every
variant repeats the allow-list and the EU/ZDR routing, because OpenCode replaces arrays instead of merging them.
The role prompts and permissions did not change. If Auto (ZDR, EU) cannot be built, for example because the
router or every EU image/PDF model is missing from the catalog, `Update-OpenCodeModels.ps1` stops and writes no
file. It does not fall back to another model, to SALE or to a non-EU endpoint.

Web search and dictation are separate: native search stays on its pinned Luna model at the `azure/eu` endpoint and
dictation on Voxtral. Neither depends on the model of `researcher`. The Zero Data Retention and EU guarantees above
cover model inference only. The native web search is an OpenRouter server tool (see its documentation) and is
**not** guaranteed to be EU-only or Zero Data Retention. The description "zero-data-retention web search" of the
`researcher` agent therefore does not extend to the search backend.

The memory plugin seed `user\opencode-mem.jsonc` uses Auto at variant `cost` (`opencodeProvider`,
`opencodeModel`, `opencodeVariant`). The file is created once and never overwritten, so existing installations
keep their values; a user can change these three keys by hand. There is no migration.

### Tests

Run all of them before building a package. Both shells must report no failure.

```powershell
cd scripts\opencode-cubeone\test
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-OpenCodeCubeOne.Tests.ps1
pwsh -NoProfile -File .\Install-OpenCodeCubeOne.Tests.ps1
powershell.exe -NoProfile -Command "Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Path .\Install-OpenCodeRemote.Tests.ps1"
```

The generator, the role mapping and the memory seed are tested with Node on synthetic catalogs (no network, no key):

```powershell
node --test scripts\opencode-cubeone\test scripts\opencode-cubeone\plugins\cubeone-sale\test
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
3. Check the zip: it opens, contains `Install-OpenCodeCubeOne.ps1`, `Install-OpenCodeRemote.ps1`, `Set-OpenCodePrincipal.ps1`, `managed`, `user`
   and `plugins`, and holds no `.env`, key or credential.
4. In `bucket/opencode-desktop.json` change only the zip URL (second `url` entry under `architecture.64bit`
   and the matching one in `autoupdate`) and its hash (second `hash` entry). Keep `version` and the hash of
   the desktop download as they are.
5. Commit the zip and the manifest. Push only after review.
