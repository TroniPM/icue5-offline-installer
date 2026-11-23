<#
    01-check-environment.ps1
    ------------------------------------------------------------------
    Testa POR QUE o instalador do iCUE 5 trava no download dos pacotes
    grandes (core-ui, qt6-webengine-2, shared-qml-plugins, etc.).

    COMO RODAR (PowerShell como ADMINISTRADOR):

        powershell -ExecutionPolicy Bypass -File .\01-check-environment.ps1

    O script NAO altera nada no sistema. Ele so mede e relata.
    ------------------------------------------------------------------
#>

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$repo = 'https://www3.corsair.com/software/CUE_V5/public/modules/windows/packages/'

# Os 11 pacotes que ficaram com 0 bytes na sua instalacao
$pacotes = @(
    @{ n = 'core-ui';          mb = 125.4; f = 'core-ui_5.54.46_win32-release-amd64.cuepkg' }
    @{ n = 'qt6-webengine-2';  mb =  98.8; f = 'qt6-webengine-2_5.42.0-6.9.3_win32-release-amd64.cuepkg' }
    @{ n = 'shared-qml-plugins'; mb = 71.9; f = 'shared-qml-plugins_5.54.46_win32-release-amd64.cuepkg' }
    @{ n = 'vcredist';         mb =  25.4; f = 'vcredist_5.54.46_win32-release-amd64.cuepkg' }
    @{ n = 'qt6-base-2';       mb =  25.3; f = 'qt6-base-2_5.42.0-6.9.3_win32-release-amd64.cuepkg' }
    @{ n = 'cuepkg';           mb =  23.8; f = 'cuepkg_2.25.5_win32-release-amd64.cuepkg' }
    @{ n = 'core';             mb =  22.0; f = 'core_5.54.46_win32-release-amd64.cuepkg' }
    @{ n = 'qt6-redist-2';     mb =  18.5; f = 'qt6-redist-2_5.42.0-6.9.3_win32-release-amd64.cuepkg' }
    @{ n = 'required-modules'; mb =  16.7; f = 'required-modules_5.54.46_win32-release-amd64.cuepkg' }
    @{ n = 'icue-ffmpeg-libs'; mb =  12.5; f = 'icue-ffmpeg-libs_5.52.93_win32-release-amd64.cuepkg' }
    @{ n = 'base';             mb =   4.4; f = 'base_5.54.46_win32-release-amd64.cuepkg' }
)

# Pacotes pequenos que VOCE conseguiu baixar (controle)
$controle = @(
    @{ n = 'system-sensors-service'; mb = 4.9; f = 'system-sensors-service_5.54.46_win32-release-amd64.cuepkg' }
    @{ n = 'openssl';                mb = 2.7; f = 'openssl_5.40.0-3.5.4.2_win32-release-amd64.cuepkg' }
    @{ n = 'fwupd-tools';            mb = 1.4; f = 'fwupd-tools_5.54.46_win32-release-amd64.cuepkg' }
)

function Titulo($t) {
    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
}

function Baixar-Trecho {
    param([string]$Url, [int]$Bytes = 3145728, [int]$TimeoutSeg = 25)

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'
    $req.Timeout = $TimeoutSeg * 1000
    $req.ReadWriteTimeout = $TimeoutSeg * 1000
    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    $req.AddRange(0, $Bytes - 1)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = $req.GetResponse()
        $stream = $resp.GetResponseStream()
        $buf = New-Object byte[] 65536
        $total = 0
        while ($total -lt $Bytes) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $total += $n
        }
        $stream.Close(); $resp.Close()
        $sw.Stop()
        $seg = [math]::Max($sw.Elapsed.TotalSeconds, 0.001)
        return [pscustomobject]@{
            OK = $true
            Bytes = $total
            Seg = [math]::Round($seg, 2)
            KBs = [math]::Round(($total / 1024) / $seg, 0)
            Erro = ''
        }
    }
    catch {
        $sw.Stop()
        return [pscustomobject]@{
            OK = $false; Bytes = 0; Seg = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            KBs = 0; Erro = $_.Exception.Message
        }
    }
}

# ----------------------------------------------------------------------
Titulo '1. IDENTIFICACAO'
# ----------------------------------------------------------------------
"Data/hora        : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"
"Maquina          : $env:COMPUTERNAME"
"Windows          : $((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption)"
"Build            : $((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).BuildNumber)"
"Elevado (admin)  : $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"

# ----------------------------------------------------------------------
Titulo '2. DNS'
# ----------------------------------------------------------------------
Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.ServerAddresses } |
    ForEach-Object { "  $($_.InterfaceAlias): $($_.ServerAddresses -join ', ')" }

Write-Host ''
Write-Host 'Resolucao de www3.corsair.com:'
try {
    Resolve-DnsName www3.corsair.com -Type A -ErrorAction Stop |
        Where-Object { $_.IPAddress } |
        ForEach-Object { "  -> $($_.IPAddress)" }
}
catch { "  FALHOU: $($_.Exception.Message)" }

# ----------------------------------------------------------------------
Titulo '3. CONEXAO TCP 443'
# ----------------------------------------------------------------------
try {
    $r = Test-NetConnection -ComputerName www3.corsair.com -Port 443 -WarningAction SilentlyContinue
    "  TcpTestSucceeded : $($r.TcpTestSucceeded)"
    "  RemoteAddress    : $($r.RemoteAddress)"
}
catch {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $t = $c.BeginConnect('www3.corsair.com', 443, $null, $null)
        if ($t.AsyncWaitHandle.WaitOne(8000)) { '  TCP 443: OK' } else { '  TCP 443: TIMEOUT' }
        $c.EndConnect($t)
    }
    catch { "  TCP 443: FALHOU - $($_.Exception.Message)" }
    finally { $c.Close() }
}

# ----------------------------------------------------------------------
Titulo '4. DOWNLOAD - PACOTES QUE FALHARAM (3 MB de cada)'
# ----------------------------------------------------------------------
$falhas = 0
foreach ($p in $pacotes) {
    $url = $repo + $p.f
    $res = Baixar-Trecho -Url $url -Bytes 3145728 -TimeoutSeg 25
    if ($res.OK -and $res.Bytes -gt 0) {
        $status = 'OK   '
        $cor = 'Green'
    }
    else {
        $status = 'FALHA'
        $cor = 'Red'
        $falhas++
    }
    $linha = "  [{0}] {1,-20} ({2,6} MB)  {3,5} KB/s  {4,5}s  {5}" -f `
        $status, $p.n, $p.mb, $res.KBs, $res.Seg, $res.Erro
    Write-Host $linha -ForegroundColor $cor
}

# ----------------------------------------------------------------------
Titulo '5. DOWNLOAD - PACOTES PEQUENOS (controle)'
# ----------------------------------------------------------------------
foreach ($p in $controle) {
    $url = $repo + $p.f
    $res = Baixar-Trecho -Url $url -Bytes 1048576 -TimeoutSeg 25
    $status = if ($res.OK -and $res.Bytes -gt 0) { 'OK   ' } else { 'FALHA' }
    $cor = if ($status -eq 'OK   ') { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1,-24} ({2,5} MB)  {3,5} KB/s  {4}s  {5}" -f `
            $status, $p.n, $p.mb, $res.KBs, $res.Seg, $res.Erro) -ForegroundColor $cor
}

# ----------------------------------------------------------------------
Titulo '6. DESCARTAVEL? teste de MTU (o mais importante)'
# ----------------------------------------------------------------------
Write-Host '  Se os pacotes pequenos passam e os grandes nao, MTU quebrado'
Write-Host '  (PPPoE / roteador) e a causa mais comum. Testando...'
Write-Host ''
foreach ($tam in 1472, 1464, 1452, 1420, 1400, 1380) {
    $out = ping.exe -n 2 -f -l $tam -w 2000 www3.corsair.com 2>&1 | Out-String
    if ($out -match 'TTL=' -or $out -match 'ttl=') {
        Write-Host ("  payload {0,4} bytes (MTU {1,4}) -> PASSOU" -f $tam, ($tam + 28)) -ForegroundColor Green
    }
    elseif ($out -match 'fragmenta|fragment|Packet needs to be fragmented') {
        Write-Host ("  payload {0,4} bytes (MTU {1,4}) -> precisa fragmentar" -f $tam, ($tam + 28)) -ForegroundColor Yellow
    }
    else {
        Write-Host ("  payload {0,4} bytes (MTU {1,4}) -> SEM RESPOSTA" -f $tam, ($tam + 28)) -ForegroundColor Red
    }
}

# ----------------------------------------------------------------------
Titulo '7. PLACA DE REDE / MTU / OFFLOAD / IPv6'
# ----------------------------------------------------------------------
Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.ConnectionState -eq 'Connected' } |
    ForEach-Object { "  Interface: $($_.InterfaceAlias)   NlMtu: $($_.NlMtu)   metric: $($_.InterfaceMetric)" }

Write-Host ''
Write-Host '  Offload (se der erro, rode como admin):'
Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'Large Send|Checksum|Offload' } |
    ForEach-Object { "    $($_.Name) | $($_.DisplayName) = $($_.DisplayValue)" }

Write-Host ''
Write-Host '  IPv6:'
Get-NetAdapterBinding -ComponentID 'ms_tcpip6' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch 'Loopback' } |
    ForEach-Object { "    $($_.Name): Enabled = $($_.Enabled)" }

Write-Host ''
Write-Host '  TCP global:'
& netsh.exe int tcp show global 2>&1 | Select-String -Pattern 'autotuning|Auto-Tuning|Escalonamento|RSS|Chimney' | ForEach-Object { "    $($_.Line)" }

# ----------------------------------------------------------------------
Titulo '8. ESTADO DO INSTALADOR AGORA'
# ----------------------------------------------------------------------
$dl = 'C:\ProgramData\Corsair\iCUE5 Initial Installer\packages\tmp'
if (Test-Path $dl) {
    $z = Get-ChildItem -Path $dl -Recurse -File -Filter *.cuepkg -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -eq 0 }
    $todos = Get-ChildItem -Path $dl -Recurse -File -Filter *.cuepkg -ErrorAction SilentlyContinue
    "  Pacotes presentes : $($todos.Count)"
    "  Com 0 bytes       : $($z.Count)"
    if ($z) {
        $z | ForEach-Object { "    - $($_.Name)" }
    }
}
else {
    '  (pasta tmp nao existe - a ultima tentativa foi limpa)'
}

# ----------------------------------------------------------------------
Titulo 'VEREDITO'
# ----------------------------------------------------------------------
if ($falhas -eq 0) {
    Write-Host '  TODOS os 11 pacotes baixaram a partir daqui.' -ForegroundColor Green
    Write-Host '  => A CDN esta acessivel nesta rede. O travamento provavelmente' -ForegroundColor Green
    Write-Host '     NAO e de rede: e do proprio cuepkg. Veja as opcoes na resposta.' -ForegroundColor Green
}
else {
    Write-Host "  $falhas de $($pacotes.Count) pacotes FALHARAM a partir daqui." -ForegroundColor Red
    Write-Host '  => Confirma o diagnostico: o download desses arquivos especificos' -ForegroundColor Red
    Write-Host '     morre nesta rede/maquina. Aplique as correcoes de rede.' -ForegroundColor Red
}
Write-Host ''
Write-Host '  Rode este script de novo depois de cada mudanca para comparar.' -ForegroundColor DarkGray
Write-Host ''
