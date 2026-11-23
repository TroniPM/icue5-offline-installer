<#
    ==================================================================
    04-restore-registry.ps1
    ==================================================================
    STEP 4 (ALWAYS RUN AFTER STEP 3): point the package URLs back at
    the official Corsair repository.

    WHY THIS IS MANDATORY
      03-install-offline.ps1 rewrites every repository_info.location
      in cuepkg.registry to http://127.0.0.1:<port>/. If you leave it
      that way, every future operation that needs to download a package
      (plugin install, update, repair) fails, because that local server
      is gone.

    HOW IT RESTORES
      1. if cuepkg.registry.bak exists, copy it back (fast path)
      2. otherwise rebuild every URL from the filename plus the official
         base URL - this is needed because cuepkg deletes unknown files
         from the store when it finishes an install, so the .bak may be
         gone even though the patch was applied

    It never touches installed_info, so the list of installed packages
    is preserved.

    USAGE (PowerShell as ADMINISTRATOR)

        powershell -ExecutionPolicy Bypass -File .\04-restore-registry.ps1

    PARAMETERS
        -Store <dir>       cuepkg installation directory
        -PythonPath <exe>  python.exe (auto-detected)
        -RepoUrl <url>     repository base to restore to
                           default: the official Corsair URL
        -Status            only report state, change nothing
    ==================================================================
#>

param(
    [string]$Store = 'C:\ProgramData\Corsair\iCUE5 Initial Installer\packages',
    [string]$PythonPath = '',
    [string]$RepoUrl = 'https://www3.corsair.com/software/CUE_V5/public/modules/windows/packages/',
    [switch]$Status
)

$ErrorActionPreference = 'Continue'

$reg = Join-Path $Store 'cuepkg.registry'
$bak = "$reg.bak"

function Titulo($t) {
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}

function Find-Python {
    param([string]$Explicit)
    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) { return $Explicit }
        Write-Host "  -PythonPath not found: $Explicit" -ForegroundColor Red
        return $null
    }
    foreach ($name in @('python', 'py', 'python3')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        if ($cmd.Source -match 'WindowsApps') { continue }
        try {
            $v = & $cmd.Source -c "import sqlite3,sys;print(sys.version_info[0])" 2>$null
            if ("$v".Trim() -eq '3') { return $cmd.Source }
        }
        catch { }
    }
    return $null
}

Titulo '0. CHECKS'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '  Run this as ADMINISTRATOR.' -ForegroundColor Yellow
    return
}
'  administrator : yes'

if (-not (Test-Path -LiteralPath $reg)) {
    Write-Host "  ERROR: $reg not found." -ForegroundColor Red
    Write-Host '  Nothing to restore - the store does not exist yet.' -ForegroundColor Yellow
    return
}
"  registry: $reg"

$py = Find-Python -Explicit $PythonPath
if (-not $py -and -not (Test-Path -LiteralPath $bak)) {
    Write-Host '  ERROR: Python 3 not found and no .bak exists - cannot restore.' -ForegroundColor Red
    return
}

# ================================================================== 1
Titulo '1. STATE'

$inspect = Join-Path $env:TEMP 'icue_inspect_registry.py'
@"
import sqlite3, shutil, os
src = r'$reg'
dst = os.path.join(os.environ['TEMP'], 'icue_inspect.sqlite')
shutil.copy2(src, dst)
c = sqlite3.connect(dst)
cur = c.cursor()
cur.execute("SELECT COUNT(*) FROM repository_info WHERE location LIKE 'http://127.0.0.1%'")
local_count = cur.fetchone()[0]
cur.execute("SELECT COUNT(*) FROM repository_info WHERE location LIKE 'https://%'")
cdn_count = cur.fetchone()[0]
cur.execute('SELECT COUNT(*) FROM installed_info')
installed = cur.fetchone()[0]
cur.execute("SELECT value FROM settings WHERE key='RepositoryUrl'")
row = cur.fetchone()
c.close()
print('LOCAL', local_count)
print('CDN', cdn_count)
print('INSTALLED', installed)
print('CONFIG', row[0] if row else '(none)')
"@ | Set-Content -LiteralPath $inspect -Encoding UTF8

$state = & $py $inspect 2>&1
$state | ForEach-Object { "  $_" }

$localCount = 0; $installed = 0
foreach ($line in $state) {
    if ("$line" -match '^LOCAL\s+(\d+)') { $localCount = [int]$Matches[1] }
    if ("$line" -match '^INSTALLED\s+(\d+)') { $installed = [int]$Matches[1] }
}

"  installed packages: $installed"

if ($Status) {
    Titulo 'STATUS ONLY'
    if ($localCount -gt 0) {
        Write-Host "  $localCount package URLs still point at 127.0.0.1." -ForegroundColor Yellow
        Write-Host '  Run this script without -Status to fix it.' -ForegroundColor Yellow
    }
    else {
        Write-Host '  Registry looks correct (pointing at the official repository).' -ForegroundColor Green
    }
    return
}

if ($localCount -eq 0) {
    Titulo 'NOTHING TO DO'
    Write-Host '  Registry already points at the official repository.' -ForegroundColor Green
    return
}

# ================================================================== 2
Titulo '2. RESTORING'

$done = $false

if (Test-Path -LiteralPath $bak) {
    try {
        Copy-Item -LiteralPath $bak -Destination $reg -Force -ErrorAction Stop
        Write-Host '  restored from cuepkg.registry.bak' -ForegroundColor Green
        $done = $true
    }
    catch {
        Write-Host "  backup copy failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if (-not $done) {
    if (-not $py) {
        Write-Host '  ERROR: no backup and no Python - restore manually.' -ForegroundColor Red
        return
    }

    Write-Host '  rebuilding URLs from the filename (no usable backup)...' -ForegroundColor DarkGray
    $fix = Join-Path $env:TEMP 'icue_restore_registry.py'
    @"
import sqlite3
reg = r'$reg'
base = '$RepoUrl'
c = sqlite3.connect(reg)
cur = c.cursor()
cur.execute('SELECT info_id, location FROM repository_info')
n = 0
for i, loc in cur.fetchall():
    if not loc:
        continue
    fn = loc.rsplit('/', 1)[-1]
    cur.execute('UPDATE repository_info SET location=? WHERE info_id=?', (base + fn, i))
    n += 1
cur.execute("UPDATE settings SET value=? WHERE key='RepositoryUrl'", (base,))
cur.execute('UPDATE repository_timestamps SET url=?', (base,))
c.commit()
cur.execute("SELECT COUNT(*) FROM repository_info WHERE location LIKE 'https://%'")
print('RESTORED', n)
print('POINTING_CDN', cur.fetchone()[0])
c.close()
"@ | Set-Content -LiteralPath $fix -Encoding UTF8

    $fixOut = & $py $fix 2>&1
    $fixOut | ForEach-Object { "  $_" }

    $restored = 0
    foreach ($line in $fixOut) { if ("$line" -match 'RESTORED\s+(\d+)') { $restored = [int]$Matches[1] } }
    if ($restored -lt 100) {
        Write-Host '  ERROR: restore failed.' -ForegroundColor Red
        return
    }
    Write-Host "  restored $restored URLs to the official repository" -ForegroundColor Green
}

# ================================================================== 3
Titulo '3. VERIFY'

$state = & $py $inspect 2>&1
$state | ForEach-Object { "  $_" }

$stillLocal = 0
foreach ($line in $state) { if ("$line" -match '^LOCAL\s+(\d+)') { $stillLocal = [int]$Matches[1] } }

if ($stillLocal -eq 0) {
    Write-Host ''
    Write-Host '  Registry is back on the official repository.' -ForegroundColor Green
}
else {
    Write-Host ''
    Write-Host "  WARNING: $stillLocal URLs still point at localhost." -ForegroundColor Yellow
}

Write-Host ''
