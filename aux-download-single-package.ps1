<#
    aux-download-single-package.ps1
    ==================================================================
    Baixa pacotes do iCUE diretamente por HTTP, contornando o
    downloader do cuepkg quando ele trava num pacote especifico.

    DOIS MODOS:
      -Nome    descobre o nome do arquivo pelo que o cuepkg ja criou
               no espelho (use quando o pacote travou e deixou um
               arquivo de 0 byte).
      -Arquivo usa o nome exato do arquivo (use quando o pacote ainda
               nem foi tentado e nao existe placeholder).

    EXEMPLOS:

        powershell -ExecutionPolicy Bypass -File .\aux-download-single-package.ps1 -Nome qt6-webengine-2

        powershell -ExecutionPolicy Bypass -File .\aux-download-single-package.ps1 -Arquivo vcredist_5.54.46_win32-release-amd64.cuepkg

    Depois rode de novo o 03-install-offline.ps1: ele confere o
    tamanho, considera pronto e continua do ponto onde parou.
    ==================================================================
#>

param(
    [string[]]$Nome,
    [string[]]$Arquivo,
    [string]$Mirror = 'D:\icue-mirror',
    [int]$TimeoutSeg = 40
)

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$repo = 'https://www3.corsair.com/software/CUE_V5/public/modules/windows/packages/'

function Baixar {
    param([string]$Url, [string]$Destino, [int]$Timeout)

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'
    $req.Timeout = 30000
    $req.ReadWriteTimeout = $Timeout * 1000
    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    $req.AllowAutoRedirect = $true

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $total = 0
    $proximo = 5MB
    $erro = ''

    try {
        $resp = $req.GetResponse()
        $in = $resp.GetResponseStream()
        $out = [System.IO.File]::Create($Destino)
        $buf = New-Object byte[] 131072
        try {
            while ($true) {
                $n = $in.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $out.Write($buf, 0, $n)
                $total += $n
                if ($total -ge $proximo) {
                    $vel = [math]::Round(($total / 1MB) / [math]::Max($sw.Elapsed.TotalSeconds, 0.01), 1)
                    Write-Host ("      ... {0,7:N1} MB  ({1} MB/s)" -f ($total / 1MB), $vel) -ForegroundColor DarkGray
                    $proximo += 5MB
                }
            }
        }
        finally { $out.Close(); $in.Close(); $resp.Close() }
    }
    catch { $erro = $_.Exception.Message }
    $sw.Stop()

    return [pscustomobject]@{ Total = $total; Seg = [math]::Round($sw.Elapsed.TotalSeconds, 1); Erro = $erro }
}

if (-not (Test-Path -LiteralPath $Mirror)) { "ERRO: espelho nao existe: $Mirror"; return }
if (-not $Nome -and -not $Arquivo) {
    "Uso:  -Nome <pacote>   ou   -Arquivo <nome_exato.cuepkg>"
    return
}

# monta a lista de nomes de arquivo a baixar
$alvos = @()

if ($Arquivo) { $alvos += $Arquivo }

if ($Nome) {
    foreach ($n in $Nome) {
        $achado = Get-ChildItem -LiteralPath $Mirror -File -Filter "$($n)_*.cuepkg" -ErrorAction SilentlyContinue |
            Sort-Object Length -Descending | Select-Object -First 1
        if ($achado) { $alvos += $achado.Name }
        else {
            Write-Host "  '$n' nao tem placeholder no espelho." -ForegroundColor Yellow
            Write-Host "  Rode o 03-install-offline.ps1 uma vez (ele cria o arquivo) ou use -Arquivo." -ForegroundColor Yellow
        }
    }
}

if ($alvos.Count -eq 0) { "Nada a baixar."; return }

$ok = 0; $falhou = 0

foreach ($nomeArquivo in ($alvos | Select-Object -Unique)) {
    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor DarkCyan
    Write-Host "  $nomeArquivo" -ForegroundColor Cyan
    Write-Host ('=' * 68) -ForegroundColor DarkCyan

    $destino = Join-Path $Mirror $nomeArquivo
    if (Test-Path -LiteralPath $destino) {
        "  tamanho antes: $([math]::Round((Get-Item -LiteralPath $destino).Length/1MB,2)) MB"
    }
    else { '  (arquivo ainda nao existe)' }
    "  url: $repo$nomeArquivo"
    Write-Host ''
    Write-Host '  baixando...' -ForegroundColor DarkGray

    $r = Baixar -Url ($repo + $nomeArquivo) -Destino $destino -Timeout $TimeoutSeg

    Write-Host ''
    "  baixado : $([math]::Round($r.Total/1MB,2)) MB em $($r.Seg)s"
    if ($r.Erro) { Write-Host "  ERRO    : $($r.Erro)" -ForegroundColor Red }

    if ($r.Total -gt 1MB -and -not $r.Erro) {
        Write-Host '  OK - gravado completo.' -ForegroundColor Green
        $ok++
    }
    else {
        Write-Host '  NAO completou.' -ForegroundColor Red
        $falhou++
    }
}

Write-Host ''
Write-Host ('=' * 68) -ForegroundColor DarkCyan
"  concluidos: $ok | falharam: $falhou"
Write-Host ''
Write-Host '  Agora rode de novo:' -ForegroundColor Yellow
Write-Host '    powershell -ExecutionPolicy Bypass -File .\03-install-offline.ps1' -ForegroundColor White
Write-Host '  Ele confere o tamanho, pula o que ja esta pronto e segue do ponto onde parou.' -ForegroundColor DarkGray
Write-Host ''
