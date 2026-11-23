# iCUE 5 Offline Installer — Full Documentation

Complete reference for the workaround in this folder.

**Start here if you just want to install:** [README.md](README.md) (quick start).
This document explains *why*, *how*, every parameter, and how to recover from the
failures you are likely to hit.

> **Unofficial.** Not affiliated with Corsair. This project rewrites one table inside
> Corsair's own package manager (`cuepkg.registry`, a SQLite database) so that package
> downloads resolve to `127.0.0.1` instead of the Corsair CDN. It is reversible, and
> step 4 restores the original state.

---

## Table of contents

1. [The problem](#1-the-problem)
2. [Root cause](#2-root-cause)
3. [Approaches that do NOT work](#3-approaches-that-do-not-work)
4. [How this solution works](#4-how-this-solution-works)
5. [Requirements](#5-requirements)
6. [Step-by-step](#6-step-by-step)
7. [Script reference](#7-script-reference)
8. [Where iCUE actually gets installed](#8-where-icue-actually-gets-installed)
9. [After the install](#9-after-the-install)
10. [Installing plugins (Gigabyte, MSI, ASUS…)](#10-installing-plugins)
11. [Troubleshooting](#11-troubleshooting)
12. [Restoring the registry / undoing everything](#12-restoring-the-registry)
13. [Reusing this for future updates](#13-reusing-this-for-future-updates)
14. [Evidence appendix](#14-evidence-appendix)

---

## 1. The problem

`Install iCUE.exe` (the small ~3.4 MB stub from Corsair) runs a package manager called
**iCUE Package Manager** (`cuepkg.exe`, version 2.25.5 in this build) which downloads
around 55 packages totalling ~446 MB — and then much more for the full product.

The installer reliably **freezes at 33–36%** (or 55%) and never progresses. The progress bar stays
put for tens of minutes. Cancelling and retrying reproduces it at exactly the same point.

Typical remedies do not help, because they address the wrong layer:

* running `iCUE_Removal_Tool`
* stopping/disabling Corsair services
* closing Gigabyte Control Center or other vendor tools
* disabling Windows Defender / antivirus
* clearing temp folders, rebooting, reinstalling as admin

---

## 2. Root cause

**`cuepkg`'s downloader stalls in the middle of large transfers and has no timeout and no
retry.** It simply waits forever, so the installer UI never advances.

### The evidence

| Measurement | Result |
|---|---|
| Packages that downloaded completely | 44 of 55, all ≤ 4.9 MB, byte-exact |
| Packages truncated | 11, every one > 4.4 MB |
| Truncation pattern | 8 files stopped at almost exactly **9.03–9.17 MB** |
| Worst case | `qt6-webengine-2` stopped at **76,459,343 of 98,815,468 bytes (77%)** |
| Same file, one plain HTTP stream (.NET) | **125,448,746 of 125,448,746 bytes**, 21 MB/s, exact |
| Files intact on disk after failure | 55 packages, of which 11 truncated |
| Retries attempted by `cuepkg` | **zero** |

The truncation happens **even with a single connection**, so it is not a concurrency
problem — it is `cuepkg`'s own HTTP client. Meanwhile the network, the NIC, the MTU, TLS
and the OS stack were all verified healthy (see `01-check-environment.ps1`).

The package manager log ends here, with no error at all:

```
[ 14%] Entered calculate state
[ 14%] Calculation step finished.
[ 14%] Entered prepare state      <- and nothing, forever
```

---

## 3. Approaches that do NOT work

These were all tested during development. Documenting them saves you the time.

### 3.1 `-c RepositoryUrl=http://127.0.0.1:PORT/`

`cuepkg` accepts an overridden repository URL, but **it only replaces the catalog source**.
The URL actually used to download each package is stored per package in the registry table
`repository_info.location`, pointing at `www3.corsair.com`.

Symptom: the install prints `Downloaded: <package>` and finishes a few small packages, while
your local HTTP server's access log receives **zero GET requests**. The big packages then
stall exactly as before, because they are still coming from the CDN.

### 3.2 `-c RepositoryUrl=file:///D:/mirror/`

`cuepkg` accepts the scheme but hangs in `prepare state`. A `file://` reply has different
semantics from HTTP (no `Content-Length` handling, no streaming reply), and `cuepkg` waits
for data that never arrives. Use a real HTTP server.

### 3.3 Letting `cuepkg download <name>` fetch packages one at a time

Better than parallel, but still the same client: a single `cuepkg download` of
`qt6-webengine-2` stalled at 76.4 MB of 98.8 MB and hung. Useful only for small packages.

### 3.4 Copying the `manager` folder with `robocopy` while `cuepkg` is running

16 DLLs that were loaded by the running process are skipped silently, including
`Qt6Network.dll`, `qsqlite.dll` and the three TLS backends. The copied `cuepkg.exe` then
fails to start with:

```
exit code -1073741515  (0xC0000135 = STATUS_DLL_NOT_FOUND)
```

Correct approach: copy the single archive `cuepkg.zip` (never locked) and extract it
afterwards. That is what `00-bootstrap.ps1` does.

### 3.5 Redirecting `www3.corsair.com` via the `hosts` file

Technically possible, but the URL stays `https://`, so the client demands a valid
certificate for `www3.corsair.com`. You would need to create a local CA, install it into the
machine's trusted root store, issue a leaf certificate, and listen on port 443. `cuepkg`
ships three TLS backends (`qschannelbackend.dll`, `qopensslbackend.dll`,
`qcertonlybackend.dll`); schannel would trust the machine store, OpenSSL would not.

Editing the registry table is strictly simpler, needs no certificate and no system-wide trust
change.

---

## 4. How this solution works

```
            step 02                                    step 03
  ┌──────────────────────────┐          ┌──────────────────────────────────┐
  │ plain HTTP downloader    │          │ local HTTP server 127.0.0.1:8099 │
  │ (one stream, retries,    │  ──────► │ serves D:\icue-mirror            │
  │  exact size verification)│          └──────────────┬───────────────────┘
  └──────────────────────────┘                         │
           │                                           │ fetches
           ▼                                           ▼
   D:\icue-mirror  (524 files, 1.47 GB)        cuepkg.exe  ──reads──► cuepkg.registry
                                                                    repository_info.location
                                                                    rewritten to 127.0.0.1
```

1. **02** reads the official package list from `cuepkg.registry` and downloads every package
   with .NET's HTTP client — one connection, `.part` file, retry on stall, and it only
   accepts a file whose byte count matches the official size exactly.
2. **03** starts a small HTTP server on `127.0.0.1` serving that folder. It answers `HEAD`
   and `GET` with a correct `Content-Length`, which is what `cuepkg` needs.
3. **03** rewrites every row of `repository_info.location` to
   `http://127.0.0.1:<port>/<filename>` and runs the install.
4. **03** watches the install; if no output appears for `-StallSeg` seconds it terminates
   `cuepkg` instead of waiting forever.
5. **04** rewrites the URLs back to the official CDN (or restores the `.bak`).

A successful install looks like this in the request log:

```
12:46:49 GET /shared-qml-plugins_5.54.46_win32-release-amd64.cuepkg -> 200 (71948911)
12:46:50 GET /qt6-redist-2_5.42.0-6.9.3_win32-release-amd64.cuepkg   -> 200 (18513097)
...
requests: 55  (200: 55 | 404: 0)
```

and in the registry:

```
pkg_operation_history:  id=6  op=install  success=1
installed_info:         55 packages
```

---

## 5. Requirements

* Windows 10/11 x64
* Windows PowerShell 5.1 (built in). PowerShell 7 also works.
* **Python 3** with the `sqlite3` module. No third-party packages. Auto-detected via
  `python`, `py` or `python3`; otherwise pass `-PythonPath`.
  The Python Store stub (`WindowsApps\python.exe`) is ignored on purpose — it is a
  placeholder that only opens the Microsoft Store.
* ~1.5 GB free where the mirror goes (default `D:\icue-mirror`)
* ~1 GB free on `C:` for the installation
* Administrator for steps 00, 03, 04 (they write to `ProgramData` and create services)

---

## 6. Step-by-step

### Step 00 — bootstrap (admin)

```powershell
.\00-bootstrap.ps1
```

What it does:

1. Looks for a working `cuepkg.exe` in `D:\icue-tools\manager`.
2. If absent, it waits for `cuepkg.zip` to appear. **You must launch `Install iCUE.exe`
   now.** The stub downloads the archive within ~10 seconds into
   `C:\ProgramData\Corsair\iCUE5 Initial Installer\manager\`. The script copies it
   (a single file, never locked), then waits for you to cancel the installer, extracts it,
   and verifies that `cuepkg.exe --version` works.
3. Creates the package store (`cuepkg.registry`) if missing. Note: `init` refuses to run if
   the target directory already exists — the script removes an empty leftover automatically.
4. Sets `RepositoryUrl` to the official repository (a fresh store has **none**, and without
   it `update` downloads nothing).
5. Runs `update` and verifies the catalog (~524 packages).

Why you cannot skip this: `cuepkg.exe` lives in a folder the official installer **deletes on
exit**, and the registry it creates is what every later step reads.

### Step 01 — environment check (optional, no admin)

```powershell
.\01-check-environment.ps1
```

Diagnostic only, changes nothing. Reports DNS, TCP 443, MTU (probes 1472 → 1380 bytes),
NIC offloads, IPv6, TCP autotuning, and downloads a 3 MB sample of the eleven packages that
historically failed. Ends with a verdict:

* **all samples OK** → your network is fine; the fault is `cuepkg` (expected)
* **samples fail** → fix the network first (see troubleshooting)

> Output messages of this script and the `aux-*` scripts are in Portuguese (pt-BR).

### Step 02 — mirror the repository (no admin)

```powershell
.\02-download-repository.ps1
```

* Reads all ~524 packages from the registry: filename + exact size.
* Skips anything already present with the correct size, so re-running is cheap.
* Downloads to `<name>.part`, renames only when the byte count matches.
* Up to `-Retries` attempts per file; a `-TimeoutSec` silence aborts that attempt.
* Typical: ~1.47 GB, 3–5 minutes on a 20 MB/s link.

Why the *whole* repository and not just the 54 packages the installer asks for?
Because the calculation is incomplete: `cuepkg calculate install icue-installer` lists 54
packages, but at install time `cuepkg` also requests `tokens-prod`, which is not in that
list. Missing it aborts the entire install with `Failed to download 'tokens-prod'`. Later
phases (plugins, updates) pull still other packages. Mirroring everything removes the whole
class of 404 failures.

### Step 03 — install (admin)

```powershell
.\03-install-offline.ps1
```

Default target: `icue-basic` — the meta-package titled **"Corsair iCUE Software"**.

Not `icue-installer`. That one is only the installer/maintenance UI; installing it gives you
a program that, when run, offers to uninstall things and complains:

```
Has non-empty install dir. Installation is not possible.
```

Useful options:

```powershell
# install several packages at once
.\03-install-offline.ps1 -Pacote "update-service plugin-host-service devplugin-gigabyte"

# free files owned by another package first (see troubleshooting 11.5)
.\03-install-offline.ps1 -Pacote icue-basic -Desinstalar icue-installer

# smaller / isolated mirror
.\03-install-offline.ps1 -Mirror E:\icue-mirror -Port 9100
```

### Step 04 — restore the registry (admin)

```powershell
.\04-restore-registry.ps1
```

Rewrites every package URL back to the official CDN. Uses `cuepkg.registry.bak` when it
exists; otherwise rebuilds the URLs from the filenames (necessary because `cuepkg` deletes
unknown files from the store when an install finishes, so the `.bak` can disappear).

Check current state without changing anything:

```powershell
.\04-restore-registry.ps1 -Status
```

---

## 7. Script reference

### `00-bootstrap.ps1`

| Parameter | Default | Meaning |
|---|---|---|
| `-Tools` | `D:\icue-tools` | Where the permanent `cuepkg.exe` copy lives |
| `-Store` | `C:\ProgramData\Corsair\iCUE5 Initial Installer\packages` | cuepkg installation directory |

### `01-check-environment.ps1`

No parameters. Read-only.

### `02-download-repository.ps1`

| Parameter | Default | Meaning |
|---|---|---|
| `-Mirror` | `D:\icue-mirror` | Destination folder |
| `-Store` | `C:\ProgramData\...\packages` | Registry to read |
| `-PythonPath` | auto | `python.exe` to use |
| `-TimeoutSec` | `40` | Silence before retrying a file |
| `-Retries` | `3` | Attempts per file |

### `03-install-offline.ps1`

| Parameter | Default | Meaning |
|---|---|---|
| `-Pacote` | `icue-basic` | Package(s) to install, space separated |
| `-Desinstalar` | *(empty)* | Package(s) to uninstall first |
| `-Mirror` | `D:\icue-mirror` | Folder served over HTTP |
| `-Store` | `C:\ProgramData\...\packages` | cuepkg installation directory |
| `-PythonPath` | auto | `python.exe` to use |
| `-Cuepkg` | `D:\icue-tools\manager\cuepkg.exe` | Path to the `cuepkg.exe` copy made in step 00 |
| `-Port` | `8099` | Local HTTP port |
| `-StallSeg` | `120` | Seconds without output → treat as stuck |
| `-MaxMin` | `30` | Hard limit in minutes |

Run it as **Administrator**: it writes package actions into `ProgramData`, creates services
and starts/stop `cuepkg`.

### `04-restore-registry.ps1`

| Parameter | Default | Meaning |
|---|---|---|
| `-Store` | `C:\ProgramData\...\packages` | cuepkg installation directory |
| `-PythonPath` | auto | `python.exe` to use |
| `-RepoUrl` | official Corsair URL | Base URL to restore |
| `-Status` | off | Report only, change nothing |

### `aux-download-single-package.ps1`

| Parameter | Default | Meaning |
|---|---|---|
| `-Nome` | — | Package name; the filename is discovered from the placeholder in the mirror |
| `-Arquivo` | — | Exact filename, when no placeholder exists yet |
| `-Mirror` | `D:\icue-mirror` | Destination |
| `-TimeoutSeg` | `40` | Silence before aborting |

### `aux-download-required-only.ps1`

Same parameters as step 02, but limited to a hard-coded list of 54 packages (~446 MB).

> **Known incomplete.** This list misses `tokens-prod` and anything a later phase needs.
> It exists for constrained links; expect to fill 404s with
> `aux-download-single-package.ps1`. Prefer `02-download-repository.ps1`.

### `aux-test-full-download.ps1`

No parameters. Downloads `vcredist` (25 MB) and `core-ui` (125 MB) completely, outside
`cuepkg`, and prints whether they match the official sizes. Use it to prove the fault is not
your network.

---

## 8. Where iCUE actually gets installed

**iCUE 5 installs into `C:\ProgramData\Corsair\iCUE5 Initial Installer\packages` — by design.**

This surprises everyone, so here is the evidence:

* The official installer's own command line (read from its log) is:

  ```
  cuepkg.exe --installdir="C:\ProgramData\Corsair\iCUE5 Initial Installer\packages" ...
  ```

* Searching every table of `cuepkg.registry` for the string `Program Files` returns **0 hits**.
* All **954** file actions use the placeholder `InstallDirectory`, which resolves to that path.

There is no "move to Program Files" step in this build. `C:\Program Files\Corsair` not
existing is normal.

The name "Initial Installer" is a legacy artifact. It is a staging name for what became the
permanent install location once Corsair moved iCUE to a package-manager architecture.

**Consequence:** the official `Install iCUE.exe` deletes `manager\` and `packages\` when it
exits. Since `packages\` *is* the installation, launching the official installer again
destroys a working iCUE. Back it up.

---

## 9. After the install

Launch:

```powershell
& 'C:\ProgramData\Corsair\iCUE5 Initial Installer\packages\iCUE Launcher.exe'
```

Registry and services created by the install:

| Item | Value |
|---|---|
| Autorun | `Corsair iCUE5 Software` → `...\packages\iCUE Launcher.exe --autorun` |
| Service | `CorsairDeviceListerService` (Manual) → `...\packages\CorsairDeviceListerService.exe` |
| Service | `CorsairCpuIdService` (Manual) → `...\packages\CorsairCpuIdService.exe` |
| User data | `%LOCALAPPDATA%\Corsair\CUE5`, `%APPDATA%\Corsair\CUE5` |

A Start Menu shortcut is **not** created. Create one:

```powershell
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\iCUE5.lnk")
$lnk.TargetPath = 'C:\ProgramData\Corsair\iCUE5 Initial Installer\packages\iCUE Launcher.exe'
$lnk.WorkingDirectory = 'C:\ProgramData\Corsair\iCUE5 Initial Installer\packages'
$lnk.IconLocation = 'C:\ProgramData\Corsair\iCUE5 Initial Installer\packages\iCUE.exe,0'
$lnk.Save()
```

Two services stay `Stopped` until iCUE needs them. Reboot once after installing.

**Back up the installation** (with iCUE closed):

```powershell
robocopy 'C:\ProgramData\Corsair\iCUE5 Initial Installer\packages' 'D:\icue-backup\packages' /E /R:2 /W:1 /NFL /NDL
```

The folder contains `cuepkg.registry` too, so it is a complete, restorable snapshot.

---

## 10. Installing plugins

Third-party integration plugins (Gigabyte, MSI, ASUS, Lenovo, Nanoleaf, Philips Hue, Govee…)
are cuepkg packages named `devplugin-*`. They are **not** installed by the base install.

### Why "Install plugin" inside iCUE does nothing

iCUE delegates plugin installation to the **update service** over a local socket. If that
service is not installed you get, repeatedly, in
`%LOCALAPPDATA%\Corsair\Logs\CUE5\*.log`:

```
cue.psm: Install plugin requested: "devplugin-gigabyte"
cue.updsvc.client: Error: QLocalSocket::ServerNotFoundError
```

The request is made, nobody answers it, and the UI silently does nothing.

### Fix

Install the three packages from the mirror:

```powershell
.\03-install-offline.ps1 -Pacote "update-service plugin-host-service devplugin-gigabyte"
.\04-restore-registry.ps1
```

| Package | Size | Role |
|---|---|---|
| `devplugin-gigabyte` | 5.42 MB | the plugin itself |
| `plugin-host-service` | 0.56 MB | service that hosts third-party plugins |
| `update-service` | 0.31 MB | the service iCUE was trying to reach |

Then restart iCUE; the plugin appears as installed and the `ServerNotFoundError` lines stop.

For a different vendor, swap the plugin name: `devplugin-msi`, `devplugin-asus`,
`devplugin-nvidia`, `devplugin-lenovo`, etc. To list what exists:

```powershell
& 'D:\icue-tools\manager\cuepkg.exe' --installdir="C:\ProgramData\Corsair\iCUE5 Initial Installer\packages" search --format=plain | Select-String 'devplugin-'
```

---

## 11. Troubleshooting

### 11.1 `Python 3 not found`

The scripts need Python for SQLite. Windows ships a `python.exe` stub in `WindowsApps` that
only opens the Store; the detection skips it on purpose. Install Python 3 from python.org
(or `winget install Python.Python.3.12`), or point at an existing interpreter:

```powershell
.\03-install-offline.ps1 -PythonPath 'C:\Python312\python.exe'
```

### 11.2 `cuepkg.registry not found`

Step 00 did not complete. Run `00-bootstrap.ps1` and make sure the catalog count at the end
is a few hundred packages.

### 11.3 `Failed to init. Root install directory already exists.`

`cuepkg init` creates the root directory itself and refuses if it already exists. Step 00
handles an empty leftover automatically. If the directory has real content, it stops and
tells you — inspect it before deleting.

### 11.4 `Registry is not available` / `Registry is not available.`

You ran a cuepkg command before `init`, or against the wrong `--installdir`. Complete step 00.

### 11.5 `File '...' from package 'X' already exists in the installation directory`

Two packages ship the same file. In this project the classic pair is:

* `icue-installer` — declares 3 files:
  `cueuiqmlplugins/com/corsair/cue/maininstaller/ComCorsairCueMaininstallerQmlPlugin.dll`,
  `.../qmldir`, `icue-installer.exe`
* `icue-uninstaller` — **identical payload** (both are 3,682,764 bytes installed)

Installing `icue-basic` after `icue-installer` collides and the whole operation aborts with
`success=0`, leaving `installed_info` unchanged.

Fix — uninstall the owner of the conflicting files first:

```powershell
.\03-install-offline.ps1 -Pacote icue-basic -Desinstalar icue-installer
.\04-restore-registry.ps1
```

A fresh installation (never ran `icue-installer` before) does not hit this: `icue-basic`
pulls `icue-uninstaller` only.

### 11.6 Install reports 404s in the request log

The mirror is missing a file that `cuepkg` asked for. The script prints the exact filenames.
Fetch them:

```powershell
.\02-download-repository.ps1
# or, for one file:
.\aux-download-single-package.ps1 -Arquivo tokens-prod_1.7.3_win32-release-amd64.cuepkg
```

Historical example: `Failed to download 'tokens-prod'` — a **2,441-byte** package that is
not in the 54-package calculation but is requested at install time. That single missing file
aborted an otherwise perfect install.

### 11.7 Downloads are not coming from the local server

Check `D:\icue-mirror\logs\requests.log`. If it only shows the startup line and the HEAD
probe, `cuepkg` is still using the CDN. That means `repository_info.location` was not
rewritten — confirm step 03 reached `OK: 524 package URLs now point at 127.0.0.1`.

Remember: `-c RepositoryUrl` alone is **not** enough (see §3.1). Only the registry rewrite
redirects downloads.

### 11.8 The install freezes and the script kills it after 120 s

The script prints the last output line it saw. Typical causes:

* a 404 (see 11.6) — the log shows `Failed to download '<name>'`
* a file conflict (see 11.5) — the log shows `already exists in the installation directory`
* genuine `cuepkg` stall — rerun; if it repeats on the same package, that package is the
  problem, not the flow

Increase the patience if your machine is slow: `-StallSeg 300 -MaxMin 60`.

### 11.9 `exit code -1073741515` (0xC0000135)

`STATUS_DLL_NOT_FOUND` — the `cuepkg` copy is incomplete. Do not copy the `manager` folder
with `robocopy` (§3.4). Copy `cuepkg.zip` and extract it. `00-bootstrap.ps1` does this and
verifies `cuepkg.exe --version` afterwards.

### 11.10 iCUE keeps logging `QLocalSocket::ServerNotFoundError`

`update-service` is not installed. See §10. Harmless but it disables plugin installation
and update checks.

### 11.11 `Has non-empty install dir. Installation is not possible.`

You ran `icue-installer.exe` from the store. That binary is the maintenance/uninstall entry
point; with an existing installation it goes down the uninstall path and offers to remove
backups or delete settings. **Cancel it.** It is not a repair tool for a working install.

### 11.12 Everything broke after running `Install iCUE.exe`

The official stub deletes `manager\` and `packages\` on exit — including the installation.
Restore your backup:

```powershell
robocopy 'D:\icue-backup\packages' 'C:\ProgramData\Corsair\iCUE5 Initial Installer\packages' /E /R:2 /W:1
```

Then re-create services if needed by rerunning the install step, and `04-restore-registry.ps1`.

---

## 12. Restoring the registry

If step 03 was interrupted, or you want to undo everything:

```powershell
# report only
.\04-restore-registry.ps1 -Status

# restore
.\04-restore-registry.ps1
```

Manual equivalents:

```powershell
# from the automatic backup, if it still exists
Copy-Item 'C:\ProgramData\Corsair\iCUE5 Initial Installer\packages\cuepkg.registry.bak' `
          'C:\ProgramData\Corsair\iCUE5 Initial Installer\packages\cuepkg.registry' -Force
```

To verify by hand, any SQLite browser will do: table `repository_info`, column `location`.
It should contain `https://www3.corsair.com/...` for all rows when the system is healthy, and
`http://127.0.0.1:8099/...` only while step 03 is running.

---

## 13. Reusing this for future updates

The same `cuepkg` bug affects every future download: updates, plugin installs, repairs. The
mirror stays valid as long as the repository content does not change.

When iCUE asks you to update and stalls:

```powershell
.\03-install-offline.ps1 -Pacote "<package the log names>"
.\04-restore-registry.ps1
```

If a new package version appeared, `02-download-repository.ps1` will fetch only the new
files (it compares exact sizes and skips everything already correct).

If the catalog itself went stale, rerun step 00 (or just its `update` part) **before**
step 02, and note that `update` resets `repository_info.location` back to the CDN — which is
why step 03 must always come after any `update`.

---

## 14. Evidence appendix

Raw numbers collected on the machine this was developed on (iCUE 5.54.46, cuepkg 2.25.5,
Windows 11 build 26200).

**Truncated downloads (bytes on disk vs official size):**

| Package | On disk | Expected | % |
|---|---|---|---|
| `core-ui` | 9,166,107 | 125,448,746 | 7.3 |
| `qt6-webengine-2` | 9,035,023 | 98,815,468 | 9.1 |
| `shared-qml-plugins` | 4,185,362 | 71,948,911 | 5.8 |
| `vcredist` | 9,031,288 | 25,386,423 | 35.6 |
| `qt6-base-2` | 9,035,029 | 25,330,916 | 35.7 |
| `cuepkg` | 2,998,272 | 23,846,537 | 12.6 |
| `core` | 9,166,848 | 21,972,064 | 41.7 |
| `qt6-redist-2` | 9,035,027 | 18,513,097 | 48.8 |
| `required-modules` | 9,035,731 | 16,715,316 | 54.1 |
| `icue-ffmpeg-libs` | 9,164,270 | 12,495,105 | 73.3 |
| `base` | 3,399,644 | 4,389,057 | 77.5 |
| `system-sensors-service` (control) | 4,911,687 | 4,911,687 | **100** |

**Control measurement (single HTTP stream, .NET):**

```
vcredist   25,386,423 / 25,386,423 bytes  → 100%  in 2.4 s
core-ui   125,448,746 / 125,448,746 bytes → 100%  in 5.5 s  (21 MB/s)
```

**Successful offline install:**

```
requests: 55  (200: 55 | 404: 0)
pkg_operation_history: id=6  op=install  success=1
installed_info: 55 packages (~813 MB installed, ~980 MB on disk)
```

**Package counts:**

| Set | Count | Size |
|---|---|---|
| Whole repository | 524 | 1,471.7 MB |
| Required by `icue-installer` | 54 | 446.5 MB |
| Required by `icue-basic` (transitive) | 57 | — |
| Installed by the successful run | 55 | ~813 MB installed |

---

## License / disclaimer

Provided as-is, for personal use, to work around a vendor installer bug. It modifies
Corsair's package manager database — always keep the `.bak` and a copy of the installation
folder. Trademarks belong to their respective owners.
