# iCUE 5 Offline Installer

Workaround for the **iCUE 5 installer that hangs at 33–36% (or 55%) and never finishes**.

Instead of letting Corsair's package manager (`cuepkg`) download the packages itself, these
scripts mirror the whole package repository over plain HTTP, serve it locally, and point
`cuepkg` at that mirror.

> **Unofficial.** Not affiliated with Corsair. It works by rewriting one SQLite table inside
> Corsair's own package manager so it fetches from `127.0.0.1` instead of the CDN.
> Everything is reversible — see step 4.

---

## Quick start

Run in order. Steps 00, 03 and 04 need an **Administrator** PowerShell.

```powershell
# 0. get a permanent copy of cuepkg.exe and create the package store
.\00-bootstrap.ps1

# 1. (optional) prove the CDN is reachable and the fault is not your network
.\01-check-environment.ps1

# 2. mirror the repository (~1.5 GB) - downloads only what is missing
.\02-download-repository.ps1

# 3. install iCUE from the local mirror
.\03-install-offline.ps1

# 4. ALWAYS run this afterwards - puts the package URLs back on the CDN
.\04-restore-registry.ps1
```

Step 4 is not optional. Skipping it leaves iCUE pointing at a local server that no longer
exists, so anything that downloads (plugins, updates) will fail.

After step 3, launch iCUE from:

```
C:\ProgramData\Corsair\iCUE5 Initial Installer\packages\iCUE Launcher.exe
```

> **No `D:` drive?** Two defaults assume one. Read
> [Paths you must change](#paths-you-must-change) before running anything.

---

## Paths you must change

The scripts default to a **`D:` drive**. Plenty of machines don't have one. Only two values
ever need changing:

| What | Default | How to change |
|---|---|---|
| Package mirror (~1.5 GB) | `D:\icue-mirror` | `-Mirror` in `02`, `03`, `aux-download-single-package`, `aux-download-required-only` |
| cuepkg copy | `D:\icue-tools` | `-Tools` in `00`, and `-Cuepkg` in `03` |

Everything else is fixed by Windows or by Corsair. In particular **do not change**
`C:\ProgramData\Corsair\iCUE5 Initial Installer\packages` — that is Corsair's own install
location. The scripts read it; they don't choose it.

**Two traps** (both cause confusing failures):

1. If you pass `-Mirror` to step 02, you **must** pass the same `-Mirror` to step 03.
   Otherwise step 03 looks in the default folder, finds it empty and stops.
2. `03 -Cuepkg` must point inside whatever folder you gave `00 -Tools`.

Example on a machine with only `C:`:

```powershell
.\00-bootstrap.ps1 -Tools 'C:\icue-tools'
.\01-check-environment.ps1
.\02-download-repository.ps1 -Mirror 'C:\icue-mirror'
.\03-install-offline.ps1 -Mirror 'C:\icue-mirror' -Cuepkg 'C:\icue-tools\manager\cuepkg.exe'
.\04-restore-registry.ps1
```

Full details, including how to edit the defaults permanently and how to confirm your real
store path: [README-FULL.md](README-FULL.md#51-paths-you-must-change).

---

## Requirements

| | |
|---|---|
| OS | Windows 10/11 x64 |
| PowerShell | 5.1 (built in) — no modules needed |
| Python | 3.x with `sqlite3` (bundled with any normal install). Auto-detected; override with `-PythonPath` |
| Disk | ~1.5 GB for the mirror + ~1 GB for the installation |
| Access | Administrator for steps 00, 03, 04 |

Python is used only to read/write Corsair's SQLite registry. No third-party packages.

---

## What it does, in one paragraph

`cuepkg` stalls in the middle of large downloads and never retries. A single plain HTTP
stream on the same machine downloads the same files perfectly. So we fetch every package
ourselves, verify exact byte sizes, serve them from `127.0.0.1`, rewrite the per-package URL
column in `cuepkg.registry` to that local server, run the install, then restore the URLs.

---

## Scripts

| Script | Purpose | Admin |
|---|---|---|
| `00-bootstrap.ps1` | Obtains `cuepkg.exe`, creates the package store, downloads the catalog | yes |
| `01-check-environment.ps1` | Diagnostic: DNS, TLS, MTU, NIC offloads, sample downloads | no |
| `02-download-repository.ps1` | Mirrors all ~524 packages with size verification and retries | no |
| `03-install-offline.ps1` | Serves the mirror, patches the registry, installs, restores nothing | yes |
| `04-restore-registry.ps1` | Restores all package URLs to the official CDN | yes |
| `aux-download-single-package.ps1` | Fetch one stubborn package | no |
| `aux-download-required-only.ps1` | Smaller mirror (54 packages) — **known incomplete** | no |
| `aux-test-full-download.ps1` | Prove whether large downloads work outside `cuepkg` | no |

Every script has its parameters documented in its own header and in
**[README-FULL.md](README-FULL.md)**.

---

## Common problems

| Symptom | Fix |
|---|---|
| `Python 3 not found` | Install Python, or pass `-PythonPath "C:\...\python.exe"` |
| `cuepkg.registry not found` | Run `00-bootstrap.ps1` first |
| `Failed to init. Root install directory already exists.` | Delete the empty store folder and rerun 00 |
| Install reports 404s | Run `02-download-repository.ps1` again |
| `... already exists in the installation directory` | Two packages share a file; use `-Desinstalar <pkg>` on step 3 |
| Plugins refuse to install inside iCUE | Install `update-service` and `plugin-host-service` (see full README) |

Full explanations, evidence and the reasoning behind every decision:
**[README-FULL.md](README-FULL.md)**.

---

## A warning worth repeating

Once installed, iCUE lives in
`C:\ProgramData\Corsair\iCUE5 Initial Installer\packages`.

The official `Install iCUE.exe` **deletes that folder when it exits** — because in the normal
flow it is only a staging area. Re-running it destroys a working installation created by these
scripts. Back the folder up after a successful install:

```powershell
robocopy 'C:\ProgramData\Corsair\iCUE5 Initial Installer\packages' 'D:\icue-backup\packages' /E /R:2 /W:1 /NFL /NDL
```
