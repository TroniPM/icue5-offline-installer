<#
    aux-test-full-download.ps1
    ------------------------------------------------------------------
    Baixa pacotes do iCUE 5 COMPLETOS (sem Range) para descobrir se o
    corte em ~9 MB acontece fora do cuepkg tambem.

    NAO altera nada no sistema. Salva em %TEMP% e apaga no final.

    COMO RODAR (PowerShell normal ja serve):

        powershell -ExecutionPolicy Bypass -File .\aux-test-full-download.ps1
    ------------------------------------------------------------------
#>

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$repo = 'https://www3.corsair.com/software/CUE_V5/public/modules/windows/packages/'

$testes = @(
    @{ n = 'vcredist  (25,4 MB)'; f = 'vcredist_5.54.46_win32-release-amd64.cuepkg'; esperado = 25386423 }
    @{ n = 'core-ui   (125,4 MB)'; f = 'core-ui_5.54.46_win32-release-amd64.cuepkg'; esperado = 125448746 }
)

function Baixar-Completo {
    param([string]$Url, [string]$Destino, [int64]$Esperado)

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'
    $req.Timeout = 30000
    $req.ReadWriteTimeout = 30000          # 30s sem receber = travou
    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proximoAviso = 5MB
    $total = 0
    $erro = ''
    $parouEm = ''

    try {
        $resp = $req.GetResponse()
        $in = $resp.GetResponseStream()
        $out = [System.IO.File]::Create($Destino)
        $buf = New-Object byte[] 65536
        try {
            while ($true) {
                $n = $in.Read($buf, 0, $buf.Length)
                if ($n -le 0) { $parouEm = 'fim do stream (servidor fechou)'; break }
                $out.Write($buf, 0, $n)
                $total += $n
                if ($total -ge $proximoAviso) {
                    $mb = [math]::Round($total / 1MB, 1)
                    $vel = [math]::Round(($total / 1MB) / [math]::Max($sw.Elapsed.TotalSeconds, 0.01), 1)
                    Write-Host ("      ... {0,7:N1} MB  ({1} MB/s)" -f $mb, $vel) -ForegroundColor DarkGray
                    $proximoAviso += 5MB
                }
            }
        }
        finally {
            $out.Close(); $in.Close(); $resp.Close()
        }
    }
    catch {
        $erro = $_.Exception.Message
    }
    $sw.Stop()

    return [pscustomobject]@{
        Total    = $total
        Esperado = $Esperado
        Seg      = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Erro     = $erro
        ParouEm  = $parouEm
    }
}

Write-Host ''
Write-Host ('=' * 70) -ForegroundColor DarkCyan
Write-Host '  TESTE: download COMPLETO fora do cuepkg' -ForegroundColor Cyan
Write-Host ('=' * 70) -ForegroundColor DarkCyan

$resultados = @()

foreach ($t in $testes) {
    $url = $repo + $t.f
    $destino = Join-Path $env:TEMP $t.f

    Write-Host ''
    Write-Host "  Baixando $($t.n)" -ForegroundColor Yellow
    Write-Host "  $url" -ForegroundColor DarkGray

    $r = Baixar-Completo -Url $url -Destino $destino -Esperado $t.esperado

    $pct = if ($t.esperado -gt 0) { [math]::Round(100 * $r.Total / $t.esperado, 1) } else { 0 }
    $completo = ($r.Total -eq $t.esperado)

    Write-Host ''
    Write-Host ("    Esperado : {0,14:N0} bytes" -f $t.esperado)
    Write-Host ("    Obtido   : {0,14:N0} bytes  ({1}%)" -f $r.Total, $pct) -ForegroundColor $(if ($completo) { 'Green' } else { 'Red' })
    Write-Host ("    Tempo    : {0} s" -f $r.Seg)
    if ($r.Erro) { Write-Host ("    ERRO     : {0}" -f $r.Erro) -ForegroundColor Red }
    if ($r.ParouEm) { Write-Host ("    Terminou : {0}" -f $r.ParouEm) -ForegroundColor Yellow }

    if ($completo) {
        Write-Host '    >>> COMPLETO' -ForegroundColor Green
    }
    else {
        Write-Host '    >>> INCOMPLETO / TRUNCADO' -ForegroundColor Red
    }

    $resultados += [pscustomobject]@{ Nome = $t.n; Ok = $completo; Total = $r.Total; Esperado = $t.esperado }

    Remove-Item -LiteralPath $destino -Force -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 70) -ForegroundColor DarkCyan
Write-Host '  CONFIGURACOES DE REDE RELEVANTES' -ForegroundColor Cyan
Write-Host ('=' * 70) -ForegroundColor DarkCyan

Write-Host ''
Write-Host '  RSC (Receive Segment Coalescing) - suspeito classico de corte:'
Get-NetAdapterRsc -ErrorAction SilentlyContinue |
    ForEach-Object { "    $($_.Name)  IPv4Enabled=$($_.IPv4Enabled)  IPv6Enabled=$($_.IPv6Enabled)" }

Write-Host ''
Write-Host '  Ajuste automatico da janela de recepcao:'
netsh int tcp show global 2>&1 |
    Select-String -Pattern 'Ajuste|Auto-Tuning|Uni..o do Segmento|Ritmo' |
    ForEach-Object { "    $($_.Line.Trim())" }

Write-Host ''
Write-Host '  Offload da placa:'
Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match 'Large Send|Checksum' } |
    ForEach-Object { "    $($_.DisplayName) = $($_.DisplayValue)" }

Write-Host ''
Write-Host '  Driver da placa:'
Get-NetAdapter -ErrorAction SilentlyContinue |
    ForEach-Object { "    $($_.Name) | $($_.InterfaceDescription) | driver $($_.DriverVersion) ($($_.DriverDate))" }

# ----------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 70) -ForegroundColor DarkCyan
Write-Host '  VEREDITO' -ForegroundColor Cyan
Write-Host ('=' * 70) -ForegroundColor DarkCyan
Write-Host ''

$todosOk = ($resultados | Where-Object { -not $_.Ok }).Count -eq 0

if ($todosOk) {
    Write-Host '  Os dois arquivos baixaram COMPLETOS fora do cuepkg.' -ForegroundColor Green
    Write-Host '  => O problema NAO e a rede nem o Windows: e o downloader do cuepkg.' -ForegroundColor Green
    Write-Host '     Ele corta as transferencias grandes e nao retoma.' -ForegroundColor Green
    Write-Host '' 
    Write-Host '  Caminho: usar um espelho local (RepositoryUrl) ou preseed dos pacotes.' -ForegroundColor Green
}
else {
    Write-Host '  O download COMPLETO tambem falhou fora do cuepkg.' -ForegroundColor Red
    Write-Host '  => O corte em ~9 MB acontece no Windows/rede, nao no cuepkg.' -ForegroundColor Red
    Write-Host '' 
    Write-Host '  Proximos passos: desativar RSC e offloads, atualizar o driver da' -ForegroundColor Red
    Write-Host '  placa de rede, e testar no 4G para separar maquina de roteador.' -ForegroundColor Red
}
Write-Host ''
