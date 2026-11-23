<#
    aux-download-required-only.ps1
    ==================================================================
    Baixa os 54 pacotes do iCUE 5 diretamente por HTTP, SEM usar o
    downloader do cuepkg (que trava no meio das transferencias).

    Por que: medido nesta maquina, o cuepkg para em ~77% de um arquivo
    de 98 MB e fica esperando para sempre. O .NET do PowerShell baixou
    125 MB completos a 21 MB/s. Entao o download sai por aqui.

    Cada arquivo e conferido byte a byte contra o tamanho oficial.
    Se falhar ou estagnar (40s sem receber), tenta de novo - ate 3x.
    Grava em .part e so renomeia quando o tamanho bate.

    COMO USAR (PowerShell normal):

        powershell -ExecutionPolicy Bypass -File .\aux-download-required-only.ps1

    Depois:

        powershell -ExecutionPolicy Bypass -File .\03-install-offline.ps1

    O instalador vai pular o download (tudo ja pronto) e ir direto
    para a instalacao a partir do espelho local.

    ATENCAO: feche a janela do script anterior e mate qualquer cuepkg
    pendente antes de rodar - senao o arquivo fica travado:

        Get-Process cuepkg -ErrorAction SilentlyContinue | Stop-Process -Force
    ==================================================================
#>

param(
    [string]$Mirror = 'D:\icue-mirror',
    [int]$TimeoutSeg = 40,
    [int]$Tentativas = 3
)

$ErrorActionPreference = 'Continue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
try { [Net.ServicePointManager]::DefaultConnectionLimit = 4 } catch {}

$repo = 'https://www3.corsair.com/software/CUE_V5/public/modules/windows/packages/'

# Manifesto oficial: 54 pacotes exigidos por "install icue-installer"
# (gerado a partir do registro do proprio cuepkg)
$pacotes = @(
    @{ f = 'audio-driver-libs_5.54.3-2.5.121_win32-release-amd64.cuepkg'; s = 277820 },
    @{ f = 'base_5.54.46_win32-release-amd64.cuepkg'; s = 4389057 },
    @{ f = 'bluetooth-enumeration_5.54.46_win32-release-amd64.cuepkg'; s = 60942 },
    @{ f = 'core_5.54.46_win32-release-amd64.cuepkg'; s = 21972064 },
    @{ f = 'core-ui_5.54.46_win32-release-amd64.cuepkg'; s = 125448746 },
    @{ f = 'cpuid-lib_5.54.1_win32-release-amd64.cuepkg'; s = 1344879 },
    @{ f = 'cuepkg_2.25.5_win32-release-amd64.cuepkg'; s = 23846537 },
    @{ f = 'dashboard-screen-ui_5.54.46_win32-release-amd64.cuepkg'; s = 474527 },
    @{ f = 'data-mining-usb_5.54.46_win32-release-amd64.cuepkg'; s = 68572 },
    @{ f = 'dev-govee_5.31.100_win32-release-amd64.cuepkg'; s = 675257 },
    @{ f = 'dev-nanoleaf_5.31.100_win32-release-amd64.cuepkg'; s = 573434 },
    @{ f = 'dev-philips-hue_5.31.100_win32-release-amd64.cuepkg'; s = 289300 },
    @{ f = 'device-listing_5.54.46_win32-release-amd64.cuepkg'; s = 47432 },
    @{ f = 'devlisterservice_5.54.46_win32-release-amd64.cuepkg'; s = 167456 },
    @{ f = 'edid-protocol_5.54.46_win32-release-amd64.cuepkg'; s = 130859 },
    @{ f = 'fwupd-tools_5.54.46_win32-release-amd64.cuepkg'; s = 1390827 },
    @{ f = 'gip-protocols_5.54.46_win32-release-amd64.cuepkg'; s = 195579 },
    @{ f = 'govee-ui_5.54.46_win32-release-amd64.cuepkg'; s = 30354 },
    @{ f = 'hid-enumeration_5.54.46_win32-release-amd64.cuepkg'; s = 109091 },
    @{ f = 'icue-ffmpeg-libs_5.52.93_win32-release-amd64.cuepkg'; s = 12495105 },
    @{ f = 'icue-installer_5.54.46_win32-release-amd64.cuepkg'; s = 1403381 },
    @{ f = 'icue-version_5.54.46_win32-release-amd64.cuepkg'; s = 14948 },
    @{ f = 'idisplay_5.54.46_win32-release-amd64.cuepkg'; s = 23372 },
    @{ f = 'idisplay-al021_5.54.46_win32-release-amd64.cuepkg'; s = 27790 },
    @{ f = 'idisplay-bs010_5.54.46_win32-release-amd64.cuepkg'; s = 23686 },
    @{ f = 'idisplay-cc021_5.54.46_win32-release-amd64.cuepkg'; s = 26710 },
    @{ f = 'localization_5.54.46_win32-release-amd64.cuepkg'; s = 1000 },
    @{ f = 'localization-de_5.54.46_win32-release-amd64.cuepkg'; s = 323474 },
    @{ f = 'localization-en_5.54.46_win32-release-amd64.cuepkg'; s = 304083 },
    @{ f = 'localization-es_5.54.46_win32-release-amd64.cuepkg'; s = 317460 },
    @{ f = 'localization-fr_5.54.46_win32-release-amd64.cuepkg'; s = 322200 },
    @{ f = 'localization-it_5.54.46_win32-release-amd64.cuepkg'; s = 315735 },
    @{ f = 'localization-ja_5.54.46_win32-release-amd64.cuepkg'; s = 275459 },
    @{ f = 'localization-ko_5.54.46_win32-release-amd64.cuepkg'; s = 268479 },
    @{ f = 'localization-pt_5.54.46_win32-release-amd64.cuepkg'; s = 315407 },
    @{ f = 'localization-ru_5.54.46_win32-release-amd64.cuepkg'; s = 324398 },
    @{ f = 'localization-uk_5.54.46_win32-release-amd64.cuepkg'; s = 274345 },
    @{ f = 'localization-zh-cn_5.54.46_win32-release-amd64.cuepkg'; s = 255984 },
    @{ f = 'localization-zh-tw_5.54.46_win32-release-amd64.cuepkg'; s = 252021 },
    @{ f = 'openssl_5.40.0-3.5.4.2_win32-release-amd64.cuepkg'; s = 2719290 },
    @{ f = 'predefined-data_5.54.46_any.cuepkg'; s = 33736 },
    @{ f = 'qt6-base-2_5.42.0-6.9.3_win32-release-amd64.cuepkg'; s = 25330916 },
    @{ f = 'qt6-imports-2_5.42.0-6.9.3_win32-release-amd64.cuepkg'; s = 1568118 },
    @{ f = 'qt6-plugins-2_5.42.0-6.9.3_win32-release-amd64.cuepkg'; s = 2873215 },
    @{ f = 'qt6-redist-2_5.42.0-6.9.3_win32-release-amd64.cuepkg'; s = 18513097 },
    @{ f = 'qt6-webengine-2_5.42.0-6.9.3_win32-release-amd64.cuepkg'; s = 98815468 },
    @{ f = 'quazip_5.28.99-1.5.0.3_win32-release-amd64.cuepkg'; s = 119754 },
    @{ f = 'required-modules_5.54.46_win32-release-amd64.cuepkg'; s = 16715316 },
    @{ f = 'shared-qml-plugins_5.54.46_win32-release-amd64.cuepkg'; s = 71948911 },
    @{ f = 'system-sensors-service_5.54.46_win32-release-amd64.cuepkg'; s = 4911687 },
    @{ f = 'usb-device-listing_5.54.46_win32-release-amd64.cuepkg'; s = 43580 },
    @{ f = 'vcredist_5.54.46_win32-release-amd64.cuepkg'; s = 25386423 },
    @{ f = 'wmi-device-listing_5.54.46_win32-release-amd64.cuepkg'; s = 79855 },
    @{ f = 'zlib_5.28.99-1.3.1.4_win32-release-amd64.cuepkg'; s = 60882 }
)

function Tentar-Baixar {
    param([string]$Url, [string]$Destino, [int64]$Esperado, [int]$Timeout)

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'
    $req.Timeout = 30000
    $req.ReadWriteTimeout = $Timeout * 1000
    $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    $req.AllowAutoRedirect = $true

    $total = 0
    $erro = ''
    try {
        $resp = $req.GetResponse()
        $in = $resp.GetResponseStream()
        $out = [System.IO.File]::Create($Destino)
        $buf = New-Object byte[] 131072
        $prox = 10MB
        try {
            while ($true) {
                $n = $in.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $out.Write($buf, 0, $n)
                $total += $n
                if ($Esperado -gt 20MB -and $total -ge $prox) {
                    Write-Host ("      ... {0,7:N1} / {1:N1} MB" -f ($total / 1MB), ($Esperado / 1MB)) -ForegroundColor DarkGray
                    $prox += 10MB
                }
            }
        }
        finally { $out.Close(); $in.Close(); $resp.Close() }
    }
    catch { $erro = $_.Exception.Message }
    return [pscustomobject]@{ Total = $total; Erro = $erro }
}

# ------------------------------------------------------------------ inicio
if (-not (Test-Path -LiteralPath $Mirror)) {
    New-Item -ItemType Directory -Path $Mirror -Force | Out-Null
}

# mata cuepkg pendente que possa segurar arquivo
$pend = Get-Process cuepkg -ErrorAction SilentlyContinue
if ($pend) {
    Write-Host '  Encerrando cuepkg pendente...' -ForegroundColor Yellow
    $pend | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

Write-Host ''
Write-Host ('=' * 70) -ForegroundColor DarkCyan
Write-Host '  BAIXANDO OS 54 PACOTES POR HTTP (sem o cuepkg)' -ForegroundColor Cyan
Write-Host ('=' * 70) -ForegroundColor DarkCyan
"  destino: $Mirror"
"  pacotes: $($pacotes.Count) | total: $([math]::Round((($pacotes | ForEach-Object { $_.s } | Measure-Object -Sum).Sum)/1MB,1)) MB"
Write-Host ''

$t0 = Get-Date
$jaOk = 0; $novos = 0; $falhas = @()
$i = 0

foreach ($p in $pacotes) {
    $i++
    $destino = Join-Path $Mirror $p.f
    $rotulo = "  [{0,2}/{1}] {2,-16}" -f $i, $pacotes.Count, ($p.f -split '_')[0]

    # ja existe e integro?
    if ((Test-Path -LiteralPath $destino) -and ((Get-Item -LiteralPath $destino).Length -eq $p.s)) {
        Write-Host "$rotulo ja ok ($([math]::Round($p.s/1MB,1)) MB)" -ForegroundColor DarkGray
        $jaOk++
        continue
    }

    $part = "$destino.part"
    $sucesso = $false

    for ($t = 1; $t -le $Tentativas; $t++) {
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }

        if ($t -eq 1) { Write-Host "$rotulo baixando $([math]::Round($p.s/1MB,1)) MB..." -ForegroundColor Yellow }
        else { Write-Host "  $(' ' * 22)tentativa $t de $Tentativas..." -ForegroundColor Yellow }

        $r = Tentar-Baixar -Url ($repo + $p.f) -Destino $part -Esperado $p.s -Timeout $TimeoutSeg

        if ($r.Total -eq $p.s) {
            Move-Item -LiteralPath $part -Destination $destino -Force -ErrorAction SilentlyContinue
            Write-Host "  $(' ' * 22)ok ($([math]::Round($r.Total/1MB,1)) MB)" -ForegroundColor Green
            $novos++; $sucesso = $true
            break
        }

        $motivo = if ($r.Erro) { $r.Erro } else { "recebeu $($r.Total) de $($p.s) bytes" }
        Write-Host "  $(' ' * 22)falhou: $motivo" -ForegroundColor Red
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    }

    if (-not $sucesso) {
        $falhas += $p.f
        # deixa o arquivo como estava (o instalador vai tentar de novo depois)
    }
}

$dur = [math]::Round(((Get-Date) - $t0).TotalSeconds, 0)

Write-Host ''
Write-Host ('=' * 70) -ForegroundColor DarkCyan
"  ja estavam ok : $jaOk"
"  baixados agora: $novos"
"  falharam      : $($falhas.Count)"
"  tempo         : ${dur}s"
Write-Host ('=' * 70) -ForegroundColor DarkCyan

if ($falhas.Count -gt 0) {
    Write-Host ''
    Write-Host '  Pacotes que nao fecharam:' -ForegroundColor Red
    $falhas | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    Write-Host ''
    Write-Host '  Rode de novo - ele so baixa o que falta.' -ForegroundColor Yellow
}
else {
    Write-Host ''
    Write-Host '  Todos os 54 pacotes estao completos e conferidos.' -ForegroundColor Green
    Write-Host ''
    Write-Host '  Proximo passo:' -ForegroundColor Cyan
    Write-Host '    powershell -ExecutionPolicy Bypass -File .\03-install-offline.ps1' -ForegroundColor White
}
Write-Host ''
