<#
  Publica o BombOffice a partir deste PC, gerando UM link público (HTTPS) para a plateia.

  Usa túneis gratuitos da Cloudflare (não precisa de conta nem abrir portas no roteador).

  Requisitos:
    - Godot 4.3+          (informe o caminho em -Godot se não estiver no PATH)
    - Python 3            (serve os arquivos do jogo)
    - cloudflared         (winget install --id Cloudflare.cloudflared)
    - Projeto exportado para Web em build\web  (Projeto > Exportar... > Web > Exportar Projeto)

  Uso:
    .\publicar.ps1 -Godot "C:\Godot\Godot_v4.3-stable_win64_console.exe"
#>
param(
    [string]$Godot = "godot",
    [int]$Port = 9080,
    [int]$WebPort = 8060
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$web = Join-Path $root "build\web"
$logs = Join-Path $root "build\logs"

if (-not (Test-Path (Join-Path $web "index.html"))) {
    Write-Host "Nao encontrei build\web\index.html. Exporte o projeto para Web primeiro." -ForegroundColor Red
    exit 1
}
foreach ($cmd in @($Godot, "python", "cloudflared")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Host "Nao encontrei '$cmd'. Veja os requisitos no topo deste arquivo." -ForegroundColor Red
        exit 1
    }
}
New-Item -ItemType Directory -Force $logs | Out-Null

function Wait-TunnelUrl([string]$file) {
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Path $file) {
            $m = Select-String -Path $file -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' | Select-Object -First 1
            if ($m) { return $m.Matches[0].Value }
        }
    }
    return $null
}

$procs = @()
try {
    Write-Host "Iniciando servidor do jogo (porta $Port)..."
    $procs += Start-Process $Godot -ArgumentList "--headless --path `"$root`" -- --server --port=$Port" `
        -NoNewWindow -PassThru -RedirectStandardOutput "$logs\server.log" -RedirectStandardError "$logs\server.err"

    Write-Host "Servindo arquivos web (porta $WebPort)..."
    $procs += Start-Process python -ArgumentList "`"$root\servidor_web.py`" $WebPort `"$web`" 127.0.0.1" `
        -NoNewWindow -PassThru -RedirectStandardOutput "$logs\http.log" -RedirectStandardError "$logs\http.err"

    Write-Host "Abrindo tuneis da Cloudflare..."
    $procs += Start-Process cloudflared -ArgumentList "tunnel --no-autoupdate --url http://127.0.0.1:$WebPort" `
        -NoNewWindow -PassThru -RedirectStandardOutput "$logs\tunnel-web.out" -RedirectStandardError "$logs\tunnel-web.log"
    $procs += Start-Process cloudflared -ArgumentList "tunnel --no-autoupdate --url http://127.0.0.1:$Port" `
        -NoNewWindow -PassThru -RedirectStandardOutput "$logs\tunnel-ws.out" -RedirectStandardError "$logs\tunnel-ws.log"

    $webUrl = Wait-TunnelUrl "$logs\tunnel-web.log"
    $wsUrl = Wait-TunnelUrl "$logs\tunnel-ws.log"
    if (-not $webUrl -or -not $wsUrl) {
        Write-Host "Nao consegui obter os enderecos dos tuneis. Veja os logs em build\logs." -ForegroundColor Red
        exit 1
    }
    $link = "$webUrl/?server=" + ($wsUrl -replace '^https://', 'wss://')
    Set-Clipboard -Value $link

    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Green
    Write-Host " LINK DO JOGO (ja copiado para a area de transferencia):" -ForegroundColor Green
    Write-Host ""
    Write-Host "   $link" -ForegroundColor Yellow
    Write-Host ""
    Write-Host " Dica: gere um QR Code desse link para a plateia." -ForegroundColor Green
    Write-Host "==================================================================" -ForegroundColor Green
    Write-Host ""
    Read-Host "Pressione ENTER para encerrar o servidor"
}
finally {
    foreach ($p in $procs) {
        if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "Tudo encerrado."
}
