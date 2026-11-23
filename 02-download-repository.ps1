<#
    ==================================================================
    02-download-repository.ps1
    ==================================================================
    STEP 2: mirror the whole iCUE 5 package repository to local disk.

    WHY THIS EXISTS
      cuepkg's downloader stalls in the middle of large files and never
      recovers (no timeout, no retry):

        * parallel downloads died at ~9 MB per file
        * a single-file download stalled at 76.4 MB of 98.8 MB
        * the same 125 MB file downloads fine over one plain HTTP
          stream at ~21 MB/s, byte-exact

      So we download every package ourselves, verify the exact byte
      size, and serve them locally in step 3.

    WHAT IT DOES
      1. reads the official package list from cuepkg.registry
         (filename + exact size for all ~524 packages)
      2. downloads only what is missing or the wrong size
      3. writes to <name>.part and renames only when the size matches
      4. retries up to N times; a 40 s silence aborts that attempt
         instead of hanging forever

    USAGE (PowerShell, admin NOT required)

        powershell -ExecutionPolicy Bypass -File .\02-download-repository.ps1

    PARAMETERS
        -Mirror <dir>       where to store the packages
                            default: D:\icue-mirror   (~1.5 GB)
        -Store <dir>        cuepkg installation directory (read only)
        -PythonPath <exe>   python.exe to use (auto-detected by default)
        -TimeoutSec <int>   seconds without data before retrying (40)
        -Retries <int>      attempts per file (3)

    REQUIREMENTS
        - Python 3 with the sqlite3 module (bundled with any normal
          Python install; no extra packages needed)
        - step 00 completed (cuepkg.registry must exist)

    NEXT STEP
        .\03-install-offline.ps1
    ==================================================================
#>

param(
    [string]$Mirror = 'D:\icue-mirror',
    [string]$Store = 'C:\ProgramData\Corsair\iCUE5 Initial Installer\packages',
    [string]$PythonPath = '',
    [int]$TimeoutSec = 40,
    [int]$Retries = 3
)

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
try { [Net.ServicePointManager]::DefaultConnectionLimit = 4 } catch {}

$repo = 'https://www3.corsair.com/software/CUE_V5/public/modules/windows/packages/'
$reg = Join-Path $Store 'cuepkg.registry'

function Titulo($t) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
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

function Try-Download {
    param([string]$Url, [string]$Dest, [int64]$Expected, [int]$Timeout)

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'
    $req.Timeout = 30000
    $req.ReadWriteTimeout = $Timeout * 1000
    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    $req.AllowAutoRedirect = $true

    $total = 0
    $err = ''
    try {
        $resp = $req.GetResponse()
        $in = $resp.GetResponseStream()
        $out = [System.IO.File]::Create($Dest)
        $buf = New-Object byte[] 131072
        try {
            while ($true) {
                $n = $in.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $out.Write($buf, 0, $n)
                $total += $n
            }
        }
        finally { $out.Close(); $in.Close(); $resp.Close() }
    }
    catch { $err = $_.Exception.Message }
    return [pscustomobject]@{ Total = $total; Error = $err }
}

# ================================================================== 1
Titulo '1. READING THE OFFICIAL PACKAGE LIST'

$py = Find-Python -Explicit $PythonPath
if (-not $py) {
    Write-Host '  ERROR: Python 3 not found.' -ForegroundColor Red
    Write-Host '  Install Python 3 or pass -PythonPath "C:\path\to\python.exe"' -ForegroundColor Yellow
    return
}
"  python: $py"

if (-not (Test-Path -LiteralPath $reg)) {
    Write-Host "  ERROR: $reg not found. Run 00-bootstrap.ps1 first." -ForegroundColor Red
    return
}

$listTxt = Join-Path $env:TEMP 'icue_package_list.txt'
$pyFile = Join-Path $env:TEMP 'icue_package_list.py'
@"
import sqlite3
c = sqlite3.connect(r'$reg')
cur = c.cursor()
cur.execute('''SELECT p.download_size, r.location
               FROM repository_info r
               JOIN packages p ON p.package_id = r.package_id''')
seen = set()
rows = []
for size, loc in cur.fetchall():
    if not loc:
        continue
    fn = loc.rsplit('/', 1)[-1]
    if fn in seen:
        continue
    seen.add(fn)
    rows.append((fn, size or 0))
c.close()
with open(r'$listTxt', 'w', encoding='utf-8') as f:
    for fn, size in rows:
        f.write('%s\t%d\n' % (fn, size))
print('PACKAGES', len(rows))
"@ | Set-Content -LiteralPath $pyFile -Encoding UTF8

$pyOut = & $py $pyFile 2>&1
$pyOut | ForEach-Object { "  $_" }
if (-not (Test-Path -LiteralPath $listTxt)) { Write-Host '  ERROR: could not read the registry.' -ForegroundColor Red; return }

$items = @()
foreach ($line in Get-Content -LiteralPath $listTxt) {
    if ($line -match '^(.+?)\t(\d+)$') {
        $items += [pscustomobject]@{ f = $Matches[1]; s = [int64]$Matches[2] }
    }
}

$totalBytes = ($items | ForEach-Object { $_.s } | Measure-Object -Sum).Sum
"  repository: $($items.Count) packages / $([math]::Round($totalBytes/1MB,1)) MB"

if (-not (Test-Path -LiteralPath $Mirror)) { New-Item -ItemType Directory -Path $Mirror -Force | Out-Null }

# ================================================================== 2
Titulo '2. DOWNLOADING WHAT IS MISSING'

$pending = Get-Process cuepkg -ErrorAction SilentlyContinue
if ($pending) { $pending | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }

$t0 = Get-Date
$alreadyOk = 0; $newFiles = 0; $failed = @(); $newBytes = 0
$i = 0

foreach ($p in $items) {
    $i++
    $dest = Join-Path $Mirror $p.f
    $short = ($p.f -split '_')[0]

    if ((Test-Path -LiteralPath $dest) -and ((Get-Item -LiteralPath $dest).Length -eq $p.s)) {
        $alreadyOk++
        continue
    }

    $part = "$dest.part"
    $ok = $false
    for ($t = 1; $t -le $Retries; $t++) {
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
        $r = Try-Download -Url ($repo + $p.f) -Dest $part -Expected $p.s -Timeout $TimeoutSec
        if ($r.Total -eq $p.s) {
            Move-Item -LiteralPath $part -Destination $dest -Force -ErrorAction SilentlyContinue
            $newFiles++; $newBytes += $r.Total; $ok = $true
            Write-Host ("  [{0,3}/{1}] {2,-24} ok ({3:N1} MB)" -f $i, $items.Count, $short, ($p.s / 1MB)) -ForegroundColor Green
            break
        }
        $why = if ($r.Error) { $r.Error } else { "got $($r.Total) of $($p.s) bytes" }
        Write-Host ("  [{0,3}/{1}] {2,-24} attempt {3} failed: {4}" -f $i, $items.Count, $short, $t, $why) -ForegroundColor DarkYellow
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    }
    if (-not $ok) { $failed += $p.f }
}

$dur = [math]::Round(((Get-Date) - $t0).TotalSeconds, 0)

Titulo '3. RESULT'
"  already ok    : $alreadyOk"
"  downloaded    : $newFiles ($([math]::Round($newBytes/1MB,1)) MB)"
"  failed        : $($failed.Count)"
"  elapsed       : ${dur}s"

if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host '  Files that did not complete:' -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    Write-Host ''
    Write-Host '  Run this script again - it only fetches what is missing.' -ForegroundColor Yellow
    Write-Host '  A single stubborn file can be fetched with:' -ForegroundColor Yellow
    Write-Host '    .\aux-download-single-package.ps1 -Arquivo <name>.cuepkg' -ForegroundColor White
}
else {
    Write-Host ''
    Write-Host '  Repository mirror is complete.' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Next:  .\03-install-offline.ps1' -ForegroundColor Cyan
}
Write-Host ''
