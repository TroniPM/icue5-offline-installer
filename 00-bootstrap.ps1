<#
    ==================================================================
    00-bootstrap.ps1
    ==================================================================
    STEP 0 of the iCUE 5 offline installer toolkit.

    Gets a working `cuepkg.exe` and creates the package store that
    every other script depends on.

    WHY THIS STEP EXISTS
      cuepkg.exe lives in a temporary folder that the official
      installer ("Install iCUE.exe") deletes when it exits:

          C:\ProgramData\Corsair\iCUE5 Initial Installer\manager

      So we keep our own copy and create the store ourselves. The
      store is where cuepkg records what is installed and where the
      package URLs live - everything else reads from it.

    WHAT IT DOES
      1. finds a usable cuepkg.exe (or captures cuepkg.zip while the
         official installer is running, then extracts it)
      2. initialises the store (cuepkg.registry) if missing
      3. points the catalog at the official Corsair repository
      4. downloads the catalog (cuepkg-metadata.json) and verifies it

    USAGE (PowerShell as ADMINISTRATOR)

        powershell -ExecutionPolicy Bypass -File .\00-bootstrap.ps1

    PARAMETERS
        -Tools <dir>     where to keep the cuepkg copy
                         default: D:\icue-tools
        -Store <dir>     cuepkg installation directory
                         default: C:\ProgramData\Corsair\iCUE5 Initial Installer\packages

    NEXT STEP
        .\02-download-repository.ps1
    ==================================================================
#>

param(
    [string]$Tools = 'D:\icue-tools',
    [string]$Store = 'C:\ProgramData\Corsair\iCUE5 Initial Installer\packages'
)

$ErrorActionPreference = 'Continue'
try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch {}

$repoCdn = 'https://www3.corsair.com/software/CUE_V5/public/modules/windows/packages/'
$managerDest = Join-Path $Tools 'manager'
$exeDest = Join-Path $managerDest 'cuepkg.exe'
$officialManager = 'C:\ProgramData\Corsair\iCUE5 Initial Installer\manager'

function Titulo($t) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}

function Test-Cuepkg {
    param([string]$Exe)
    if (-not (Test-Path -LiteralPath $Exe)) { return $false }
    $v = & $Exe --version 2>&1
    return ($LASTEXITCODE -eq 0 -and "$v" -match 'Package Manager')
}

# ================================================================== 0
Titulo '0. CHECKS'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '  Run this as ADMINISTRATOR.' -ForegroundColor Yellow
    return
}
'  administrator : yes'

New-Item -ItemType Directory -Path $Tools -Force | Out-Null
"  tools  : $Tools"
"  store  : $Store"

# ================================================================== 1
Titulo '1. GET A PERMANENT COPY OF cuepkg.exe'

if (Test-Cuepkg -Exe $exeDest) {
    "  already have a working copy: $exeDest"
}
else {
    # look for the bootstrap archive the official installer downloads
    $zipSaved = Join-Path $Tools 'cuepkg.zip'
    $candidates = @(
        $zipSaved,
        (Join-Path $officialManager 'cuepkg.zip'),
        (Join-Path $managerDest 'cuepkg.zip')
    )
    $zip = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    if (-not $zip) {
        Write-Host '  No cuepkg.zip found yet.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  ACTION REQUIRED:' -ForegroundColor Cyan
        Write-Host '    1) Double-click "Install iCUE.exe" (the Corsair downloader)' -ForegroundColor White
        Write-Host '    2) Do NOT cancel - this script copies the archive automatically' -ForegroundColor White
        Write-Host ''
        Write-Host '  Waiting for cuepkg.zip (up to 20 minutes)...' -ForegroundColor DarkGray

        $deadline = (Get-Date).AddMinutes(20)
        $watch = Join-Path $officialManager 'cuepkg.zip'
        $lastNote = Get-Date
        $got = $false

        while ((Get-Date) -lt $deadline) {
            if ((Test-Path -LiteralPath $watch) -and ((Get-Item -LiteralPath $watch).Length -gt 20MB)) {
                Write-Host '  detected, copying...' -ForegroundColor Green
                Copy-Item -LiteralPath $watch -Destination $zipSaved -Force -ErrorAction SilentlyContinue
                try {
                    $z = [System.IO.Compression.ZipFile]::OpenRead($zipSaved)
                    $entry = $z.Entries | Where-Object { $_.Name -eq 'cuepkg.exe' }
                    $z.Dispose()
                    if ($entry -and $entry.Length -gt 7MB) {
                        Write-Host "  copy verified ($([math]::Round($entry.Length/1MB,1)) MB cuepkg.exe)" -ForegroundColor Green
                        Write-Host ''
                        Write-Host '  >>> YOU MAY CANCEL THE iCUE INSTALLER NOW <<<' -ForegroundColor Yellow
                        Start-Sleep -Seconds 6
                        $got = $true
                        break
                    }
                }
                catch { }
                Write-Host '  archive still incomplete, waiting...' -ForegroundColor DarkGray
            }
            elseif (((Get-Date) - $lastNote).TotalSeconds -ge 20) {
                Write-Host ("  ... waiting ({0:HH:mm:ss})" -f (Get-Date)) -ForegroundColor DarkGray
                $lastNote = Get-Date
            }
            Start-Sleep -Milliseconds 600
        }

        if (-not $got) {
            Write-Host '  Could not capture cuepkg.zip. Start the installer and run this script again.' -ForegroundColor Red
            return
        }
        $zip = $zipSaved
    }
    else {
        "  found: $zip"
        if ($zip -ne $zipSaved) { Copy-Item -LiteralPath $zip -Destination $zipSaved -Force -ErrorAction SilentlyContinue }
        $zip = $zipSaved
    }

    Write-Host '  extracting...' -ForegroundColor DarkGray
    Remove-Item -LiteralPath $managerDest -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $managerDest -Force | Out-Null
    try { [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $managerDest) }
    catch { Write-Host "  extract failed: $($_.Exception.Message)" -ForegroundColor Red; return }

    $count = (Get-ChildItem -LiteralPath $managerDest -Recurse -File -Force).Count
    "  files extracted: $count"

    if (-not (Test-Cuepkg -Exe $exeDest)) {
        Write-Host '  cuepkg.exe does not run. Run it manually and check the error:' -ForegroundColor Red
        Write-Host "    & `"$exeDest`" --version" -ForegroundColor White
        return
    }
    $v = & $exeDest --version 2>&1
    Write-Host "  cuepkg works: $v" -ForegroundColor Green
    if ($count -lt 70) { Write-Host "  WARNING: only $count files (expected ~75) - a DLL may be missing" -ForegroundColor Yellow }
}

$exe = $exeDest
"  cuepkg: $exe"

$cfg = @()

function Cuepkg {
    param([string[]]$Args2, [string]$Cwd = $Tools)
    Push-Location $Cwd
    try { & $exe --installdir="$Store" --tempdir="$Store\tmp" @cfg @Args2 2>&1 }
    finally { Pop-Location }
}

# ================================================================== 2
Titulo '2. INITIALISE THE STORE'

$reg = Join-Path $Store 'cuepkg.registry'

if (Test-Path -LiteralPath $reg) {
    '  store already has a registry, skipping init.'
}
else {
    # init creates the root directory itself and refuses if it exists
    if (Test-Path -LiteralPath $Store) {
        $content = @(Get-ChildItem -LiteralPath $Store -Force -ErrorAction SilentlyContinue)
        $relevant = @($content | Where-Object { $_.Name -ne 'tmp' })
        if ($relevant.Count -eq 0) {
            Write-Host '  removing empty leftover directory so init can create it...' -ForegroundColor Yellow
            Remove-Item -LiteralPath $Store -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Host '  Directory exists, has content and no registry:' -ForegroundColor Red
            $relevant | Select-Object -First 10 | ForEach-Object { Write-Host "    $($_.Name)" -ForegroundColor Red }
            Write-Host '  If this is leftover from a failed attempt, delete it and rerun:' -ForegroundColor Yellow
            Write-Host "    Remove-Item '$Store' -Recurse -Force" -ForegroundColor White
            return
        }
    }

    Write-Host '  running init...' -ForegroundColor DarkGray
    $out = Cuepkg @('init', '--format=plain')
    $out | Where-Object { "$_".Trim() } | Select-Object -First 10 | ForEach-Object { "    $_" }

    if (-not (Test-Path -LiteralPath $reg)) {
        Write-Host '  init did not create cuepkg.registry. See the messages above.' -ForegroundColor Red
        return
    }
    Write-Host '  registry created.' -ForegroundColor Green
}

# ================================================================== 3
Titulo '3. POINT THE CATALOG AT THE OFFICIAL REPOSITORY'

$current = Cuepkg @('get-config', 'RepositoryUrl', '--format=plain')
if ("$current" -notmatch 'https?://') {
    Write-Host '  RepositoryUrl is empty (fresh store), setting it...' -ForegroundColor Yellow
    $out = Cuepkg @('set-config', 'RepositoryUrl', $repoCdn, '--format=plain')
    $out | Where-Object { "$_".Trim() } | Select-Object -First 6 | ForEach-Object { "    $_" }
    $current = Cuepkg @('get-config', 'RepositoryUrl', '--format=plain')
}
"$current" -split "`n" | Where-Object { $_ -match 'https?://' } | ForEach-Object { "  $($_.Trim())" }

if ("$current" -notmatch 'https?://') {
    Write-Host '  ERROR: RepositoryUrl still empty - update has nothing to download.' -ForegroundColor Red
    return
}

# ================================================================== 4
Titulo '4. DOWNLOAD THE CATALOG'

$out = Cuepkg @('update', '--format=plain')
$out | Where-Object { "$_".Trim() } | Select-Object -Last 8 | ForEach-Object { "    $_" }

$search = Cuepkg @('search', '--format=plain')
$catalog = 0
foreach ($line in $search) { if ("$line" -match '^([A-Za-z0-9][A-Za-z0-9._-]*):$') { $catalog++ } }

"  packages in catalog: $catalog"

if ($catalog -lt 100) {
    Write-Host '  WARNING: the catalog looks empty. Check your connection and rerun.' -ForegroundColor Yellow
    return
}

Titulo 'DONE'
Write-Host "  cuepkg : $exe" -ForegroundColor Green
Write-Host "  store  : $Store" -ForegroundColor Green
Write-Host "  catalog: $catalog packages" -ForegroundColor Green
Write-Host ''
Write-Host '  Next:  .\02-download-repository.ps1' -ForegroundColor Cyan
Write-Host ''
