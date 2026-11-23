<#
    ==================================================================
    03-install-offline.ps1
    ==================================================================
    STEP 3: install iCUE 5 packages from the local mirror.

    HOW IT WORKS (and why the obvious approaches do not)
      Serving the mirror and passing -c RepositoryUrl=http://127.0.0.1
      is NOT enough: that option only replaces the catalog URL. The
      actual download URL is stored per package inside cuepkg's own
      SQLite registry, column repository_info.location, pointing at
      www3.corsair.com. That is why an install could report
      "Downloaded: <package>" while the local server received zero GETs.

      Using file:// instead of http:// also fails: cuepkg enters its
      "prepare state" and waits forever for a reply it never gets.

      So this script:
        1. starts a real HTTP server on 127.0.0.1 serving the mirror
        2. rewrites every repository_info.location to that server
           (backup of the registry is created first)
        3. runs `cuepkg install <package>` with a stall watchdog
        4. reports how many GETs were served and whether they were 200

    IMPORTANT: AFTER EVERY RUN, RESTORE THE REGISTRY
        .\04-restore-registry.ps1
      Otherwise iCUE keeps pointing at a local server that is no longer
      running, and anything that needs to download will fail.

    USAGE (PowerShell as ADMINISTRATOR)

        powershell -ExecutionPolicy Bypass -File .\03-install-offline.ps1

    PARAMETERS
        -Pacote <name>       package(s) to install.
                             default: icue-basic  ("Corsair iCUE Software")
                             use "icue-basic update-service plugin-host-service"
                             style for several packages at once.
        -Desinstalar <name>  uninstall these first (space separated).
                             Needed when two packages ship the same file,
                             e.g. icue-installer and icue-uninstaller.
        -Mirror <dir>        package mirror (default D:\icue-mirror)
        -Store <dir>         cuepkg installation directory
        -Port <int>          local HTTP port (default 8099)
        -StallSeg <int>      seconds of no output = stuck (default 120)
        -MaxMin <int>        hard time limit in minutes (default 30)
        -PythonPath <exe>    python.exe (auto-detected)

    WHICH PACKAGE TO INSTALL
        icue-installer  the installer/maintenance UI only - NOT the app
        icue-basic      the actual product meta-package (recommended)

    NEXT STEP
        .\04-restore-registry.ps1
    ==================================================================
#>

param(
    [string]$Pacote = 'icue-basic',
    [string]$Desinstalar = '',
    [string]$Mirror = 'D:\icue-mirror',
    [string]$Store = 'C:\ProgramData\Corsair\iCUE5 Initial Installer\packages',
    [string]$PythonPath = '',
    [string]$Cuepkg = 'D:\icue-tools\manager\cuepkg.exe',
    [int]$Port = 8099,
    [int]$StallSeg = 120,
    [int]$MaxMin = 30
)

$ErrorActionPreference = 'Continue'

$exe = $Cuepkg
$reg = Join-Path $Store 'cuepkg.registry'
$logs = Join-Path $Mirror 'logs'
$reqLog = Join-Path $logs 'requests.log'
$outFile = Join-Path $logs 'install-out.txt'
$errFile = Join-Path $logs 'install-err.txt'

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

# ================================================================== 0
Titulo '0. CHECKS'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '  Run this as ADMINISTRATOR.' -ForegroundColor Yellow
    return
}
'  administrator : yes'

if (-not (Test-Path -LiteralPath $exe)) { Write-Host "  ERROR: $exe not found. Run 00-bootstrap.ps1 first." -ForegroundColor Red; return }
if (-not (Test-Path -LiteralPath $reg)) { Write-Host "  ERROR: $reg not found. Run 00-bootstrap.ps1 first." -ForegroundColor Red; return }

New-Item -ItemType Directory -Path $logs -Force | Out-Null

$packages = Get-ChildItem -LiteralPath $Mirror -File -Filter *.cuepkg -ErrorAction SilentlyContinue
"  mirror: $($packages.Count) packages ($([math]::Round((($packages | Measure-Object Length -Sum).Sum)/1MB,1)) MB)"
if ($packages.Count -lt 50) { Write-Host '  ERROR: mirror incomplete. Run 02-download-repository.ps1.' -ForegroundColor Red; return }

$py = Find-Python -Explicit $PythonPath
if (-not $py) { Write-Host '  ERROR: Python 3 not found (needed to edit the SQLite registry).' -ForegroundColor Red; return }
"  python: $py"

# ================================================================== 1
Titulo '1. CLEANING UP PROCESSES AND TASKS'

$pending = Get-Process cuepkg -ErrorAction SilentlyContinue
if ($pending) {
    $pending | ForEach-Object { Write-Host "  killing cuepkg PID $($_.Id)" -ForegroundColor Yellow; $_ | Stop-Process -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
}
else { '  no cuepkg running.' }

$tasks = & schtasks.exe /query /fo CSV 2>$null | Select-String -Pattern 'cuepkg-' | ForEach-Object { ($_.Line -split '","')[0].Trim('"') }
foreach ($t in ($tasks | Select-Object -Unique)) {
    & schtasks.exe /delete /tn "$t" /f 2>&1 | Out-Null
    Write-Host "  task removed: $t" -ForegroundColor DarkGray
}
if (-not $tasks) { '  no cuepkg tasks left behind.' }

# ================================================================== 2
Titulo '2. LOCAL HTTP SERVER'

$srvPath = Join-Path $env:TEMP 'icue-local-server.ps1'
@'
param([int]$Port,[string]$Root,[string]$ReqLog)
$ErrorActionPreference='Stop'
$l=[System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback,$Port)
$l.Start(200)
Add-Content -LiteralPath $ReqLog -Value ("=== server {0:HH:mm:ss} port {1} ===" -f (Get-Date),$Port)
while($true){
  $c=$l.AcceptTcpClient()
  try{
    $ns=$c.GetStream(); $ns.ReadTimeout=30000; $ns.WriteTimeout=30000
    $sr=New-Object System.IO.StreamReader($ns,[System.Text.Encoding]::ASCII,$false,1024,$true)
    $req=$sr.ReadLine()
    while($true){ $x=$sr.ReadLine(); if($null -eq $x -or $x -eq ''){break} }
    if($req -match '^(GET|HEAD)\s+(\S+)'){
      $verb=$Matches[1]
      $cam=[System.Uri]::UnescapeDataString($Matches[2]); $cam=($cam -split '\?')[0].TrimStart('/')
      $full=Join-Path $Root $cam
      if(Test-Path -LiteralPath $full -PathType Leaf){
        $fi=New-Object System.IO.FileInfo($full)
        Add-Content -LiteralPath $ReqLog -Value ("{0:HH:mm:ss} {1} /{2} -> 200 ({3})" -f (Get-Date),$verb,$cam,$fi.Length)
        $h="HTTP/1.1 200 OK`r`nContent-Type: application/octet-stream`r`nContent-Length: $($fi.Length)`r`nAccept-Ranges: bytes`r`nConnection: close`r`n`r`n"
        $b=[System.Text.Encoding]::ASCII.GetBytes($h); $ns.Write($b,0,$b.Length)
        if($verb -eq 'GET'){ $fs=[System.IO.File]::OpenRead($full); try{$fs.CopyTo($ns,262144)}finally{$fs.Close()} }
      } else {
        Add-Content -LiteralPath $ReqLog -Value ("{0:HH:mm:ss} {1} /{2} -> 404" -f (Get-Date),$verb,$cam)
        $b=[System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 3`r`nConnection: close`r`n`r`n404")
        $ns.Write($b,0,$b.Length)
      }
    }
    $ns.Flush(); $ns.Close()
  } catch {} finally { $c.Close() }
}
'@ | Set-Content -LiteralPath $srvPath -Encoding UTF8

Remove-Item -LiteralPath $reqLog -Force -ErrorAction SilentlyContinue
$srv = Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$srvPath`"", '-Port', $Port, '-Root', "`"$Mirror`"", '-ReqLog', "`"$reqLog`"" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3
"  server PID $($srv.Id) on http://127.0.0.1:$Port/"

try {
    $probe = (Get-ChildItem -LiteralPath $Mirror -File -Filter *.cuepkg | Select-Object -First 1)
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/$($probe.Name)" -Method Head -TimeoutSec 10 -UseBasicParsing
    "  HEAD test: $($r.StatusCode) Content-Length=$($r.Headers['Content-Length'])"
}
catch {
    Write-Host "  server did not answer: $($_.Exception.Message)" -ForegroundColor Red
    Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue
    return
}

# ================================================================== 3
Titulo '3. POINTING THE REGISTRY AT THE LOCAL SERVER'

$patch = Join-Path $env:TEMP 'icue_patch_registry.py'
@"
import sqlite3, shutil, os
reg = r'$reg'
base = 'http://127.0.0.1:$Port/'
if not os.path.exists(reg + '.bak'):
    shutil.copy2(reg, reg + '.bak')
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
cur.execute("SELECT COUNT(*) FROM repository_info WHERE location LIKE 'http://127.0.0.1%'")
print('REWRITTEN', n)
print('POINTING_LOCAL', cur.fetchone()[0])
c.close()
"@ | Set-Content -LiteralPath $patch -Encoding UTF8

$patchOut = & $py $patch 2>&1
$patchOut | ForEach-Object { "  $_" }

$localCount = 0
foreach ($line in $patchOut) { if ("$line" -match 'POINTING_LOCAL\s+(\d+)') { $localCount = [int]$Matches[1] } }
if ($localCount -lt 100) {
    Write-Host '  ERROR: registry was not rewritten.' -ForegroundColor Red
    Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue
    return
}
Write-Host "  OK: $localCount package URLs now point at 127.0.0.1" -ForegroundColor Green

# ================================================================== 4
function Invoke-Cuepkg {
    param([string]$Verb, [string]$Targets, [string]$Label)

    $argLine = "--installdir=`"$Store`" --tempdir=`"$Store\tmp`" " +
               "-c RepositoryUrl=http://127.0.0.1:$Port/ " +
               " $Verb $Targets --format=plain"

    Write-Host ''
    Write-Host "  [$Label] $Verb $Targets" -ForegroundColor DarkGray
    Write-Host ''

    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue

    $proc = Start-Process -FilePath $exe -ArgumentList $argLine -WorkingDirectory $Mirror `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
        -PassThru -WindowStyle Hidden

    $start = Get-Date
    $lastSize = -1
    $lastChange = Get-Date
    $reason = 'finished'

    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 2
        $size = 0
        if (Test-Path -LiteralPath $outFile) { $size = (Get-Item -LiteralPath $outFile).Length }

        if ($size -ne $lastSize) {
            $lastSize = $size
            $lastChange = Get-Date
            $lines = @(Get-Content -LiteralPath $outFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() })
            if ($lines.Count -gt 0) { Write-Host "    $($lines[-1])" -ForegroundColor DarkGray }
        }

        if (((Get-Date) - $lastChange).TotalSeconds -ge $StallSeg) { $reason = "STUCK (${StallSeg}s without output)"; break }
        if (((Get-Date) - $start).TotalMinutes -ge $MaxMin) { $reason = "TIME LIMIT ${MaxMin}min"; break }
    }

    if (-not $proc.HasExited) {
        Write-Host ''
        Write-Host "  $reason - terminating cuepkg." -ForegroundColor Red
        $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        Get-Process cuepkg -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    else {
        try { $proc.WaitForExit(5000) | Out-Null } catch { }
        Write-Host ''
        Write-Host "  [$Label] $reason" -ForegroundColor DarkGray
    }
    Get-Process cuepkg -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

if ($Desinstalar) {
    Titulo "4. UNINSTALLING: $Desinstalar"
    Invoke-Cuepkg -Verb 'uninstall' -Targets $Desinstalar -Label 'uninstall'
}

Titulo "5. INSTALLING: $Pacote"
Invoke-Cuepkg -Verb 'install' -Targets $Pacote -Label 'install'

Start-Sleep -Seconds 1
Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue

# ================================================================== 5
Titulo '6. RESULT'

$reqs = Get-Content -LiteralPath $reqLog -ErrorAction SilentlyContinue
$gets = @($reqs | Where-Object { $_ -match 'GET |HEAD ' })
$ok200 = @($reqs | Where-Object { $_ -match '->\s*200' })
$bad404 = @($reqs | Where-Object { $_ -match '->\s*404' })

"  requests: $($gets.Count)  (200: $($ok200.Count) | 404: $($bad404.Count))"

if ($bad404.Count -gt 0) {
    Write-Host ''
    Write-Host '  Real 404s (requested file missing from the mirror):' -ForegroundColor Yellow
    $reqs | Where-Object { $_ -match '->\s*404' } | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    Write-Host '  Fix: run 02-download-repository.ps1 again to fetch the missing files.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  last lines from cuepkg:' -ForegroundColor DarkGray
Get-Content -LiteralPath $outFile -ErrorAction SilentlyContinue | Where-Object { $_.Trim() } | Select-Object -Last 18 | ForEach-Object { "    $_" }

if ((Test-Path -LiteralPath $errFile) -and (Get-Item -LiteralPath $errFile).Length -gt 0) {
    Write-Host ''
    Write-Host '  stderr:' -ForegroundColor DarkGray
    Get-Content -LiteralPath $errFile | Select-Object -Last 10 | ForEach-Object { "    $_" }
}

$chk = Join-Path $env:TEMP 'icue_install_check.py'
@"
import sqlite3, shutil, os
src = r'$reg'
dst = os.path.join(os.environ['TEMP'], 'icue_chk.sqlite')
shutil.copy2(src, dst)
c = sqlite3.connect(dst)
cur = c.cursor()
cur.execute('SELECT COUNT(*) FROM installed_info')
print('INSTALLED_PACKAGES', cur.fetchone()[0])
cur.execute('SELECT record_id, success, coalesce(error, \'\') FROM pkg_operation_history ORDER BY record_id DESC LIMIT 1')
r = cur.fetchone()
if r:
    print('LAST_OPERATION', r[0], r[1], (r[2] or '')[:200])
c.close()
"@ | Set-Content -LiteralPath $chk -Encoding UTF8

Write-Host ''
$chkOut = & $py $chk 2>&1
$chkOut | ForEach-Object { "  $_" }

Write-Host ''
Write-Host '  REMEMBER: the registry is still pointing at 127.0.0.1.' -ForegroundColor Yellow
Write-Host '  Restore it now:' -ForegroundColor Yellow
Write-Host '    .\04-restore-registry.ps1' -ForegroundColor White
Write-Host ''
