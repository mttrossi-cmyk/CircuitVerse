# CircuitVerse Simulator - offline standalone launcher
#
# Starts the bundled static server (Caddy) on the first free loopback port and
# opens the default browser. Everything is served from ./app; nothing leaves the
# machine and nothing is reachable from the network.
#
#   .\Avvia.ps1              avvia e apre il browser
#   .\Avvia.ps1 -NoBrowser   avvia senza aprire il browser (test, chioschi)

param(
    [switch] $NoBrowser
)

$ErrorActionPreference = 'Stop'

$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $baseDir

$caddy   = Join-Path $baseDir 'caddy.exe'
$appDir  = Join-Path $baseDir 'app'
$pidFile = Join-Path $baseDir 'caddy.pid'
$portFile = Join-Path $baseDir 'caddy.port'
$logFile = Join-Path $baseDir 'caddy.log'
$errFile = Join-Path $baseDir 'caddy-error.log'

function Stop-WithMessage($message) {
    Write-Host ''
    Write-Host $message -ForegroundColor Red
    if (Test-Path -LiteralPath $errFile) {
        Write-Host ''
        Write-Host 'Dettaglio del server:' -ForegroundColor Yellow
        Get-Content -LiteralPath $errFile -Tail 12 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
    # Con -NoBrowser lo script e' usato per test: non bloccare su un input.
    if (-not $NoBrowser -and $Host.Name -eq 'ConsoleHost') { Read-Host 'Premi Invio per uscire' }
    exit 1
}

if (-not (Test-Path -LiteralPath $caddy)) { Stop-WithMessage 'caddy.exe non trovato: il pacchetto e incompleto.' }
if (-not (Test-Path -LiteralPath (Join-Path $appDir 'index.html'))) { Stop-WithMessage 'Cartella app/ non trovata o incompleta.' }

# Already running? Just bring the browser up.
if (Test-Path -LiteralPath $pidFile) {
    $existing = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue
    if ($existing) {
        $proc = Get-Process -Id ([int]$existing) -ErrorAction SilentlyContinue
        if ($proc -and $proc.ProcessName -eq 'caddy') {
            $running = Get-Content -LiteralPath $portFile -ErrorAction SilentlyContinue
            if ($running) {
                Write-Host "Simulatore gia' in esecuzione su http://127.0.0.1:$running" -ForegroundColor Green
                cmd /c "start `"`" `"http://127.0.0.1:$running/`"" | Out-Null
                exit 0
            }
        }
        Remove-Item -LiteralPath $pidFile -Force
    }
}

# Assegna la porta effettivamente tried-and-tried: Get-NetTCPConnection puo'
# rispondere in ritardo e far partire due istanze sulla stessa porta.
function Try-BindPort($port) {
    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($listener) { try { $listener.Stop() } catch { } }
    }
}

function Get-FreePort($from, $to) {
    foreach ($candidate in $from..$to) {
        if (Try-BindPort $candidate) { return $candidate }
    }
    return $null
}

# Caddy tiene il proprio stato in directory annidate profonde: dentro il
# pacchetto (che l'utente puo' estrarre in un percorso gia' lungo) si
# supererebbe il limite di 260 caratteri di Windows.
$stateDir = Join-Path $env:LOCALAPPDATA 'CircuitVerseStandalone'
if (-not (Test-Path -LiteralPath $stateDir)) {
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}

$caddyfile = Join-Path $baseDir 'Caddyfile'
$proc = $null
$port = $null
$url = $null

# Fino a 3 tentativi: se Caddy muore subito (per esempio la porta e' stata
# presa nel frattempo) si riprova con la successiva.
foreach ($attempt in 1..3) {
    $port = Get-FreePort 3000 3010
    if (-not $port) { Stop-WithMessage 'Nessuna porta libera fra 3000 e 3010.' }

    # Anche l'endpoint di amministrazione ha una porta: quella predefinita
    # (2019) e' unica per macchina e bloccherebbe una seconda istanza.
    $adminPort = Get-FreePort 13000 13020
    if (-not $adminPort) { Stop-WithMessage 'Nessuna porta libera fra 13000 e 13020 per il canale interno.' }

# Bind esplicito sul loopback IPv4. Scrivere "localhost" non basta: Caddy lo
    # risolve e si mette in ascolto su :: (tutte le interfacce), il che espone
    # il simulatore alla rete locale e fa comparire il prompt di Windows Firewall.
@"
{
	admin localhost:ADMINPORT
}
:PORT {
	bind 127.0.0.1

	root * app
	encode gzip zstd

	# Entry e index.html devono sempre essere riverificati.
	@entry path / /index.html /simulator-v0.js
	header @entry Cache-Control "no-cache, max-age=0"

	# Gli asset hanno il nome con hash: non cambiano mai.
	@assets path /assets/*
	header @assets Cache-Control "public, max-age=31536000, immutable"

	# WebAssembly.instantiateStreaming() richiede il MIME esatto.
	@wasm path *.wasm
	header @wasm Content-Type "application/wasm"

	try_files {path} /index.html
	file_server
}
"@ -replace 'ADMINPORT', $adminPort -replace 'PORT', $port | Set-Content -LiteralPath $caddyfile -Encoding utf8

    foreach ($old in @($logFile, $errFile)) {
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
    }

    $env:XDG_CONFIG_HOME = $stateDir
    $env:XDG_DATA_HOME = $stateDir

    $url = "http://127.0.0.1:$port/"

    # -WindowStyle Hidden: senza finestra nera durante l'uso.
    $proc = Start-Process -FilePath $caddy `
        -ArgumentList @('run', '--config', 'Caddyfile', '--adapter', 'caddyfile') `
        -WorkingDirectory $baseDir `
        -WindowStyle Hidden `
        -RedirectStandardOutput $logFile `
        -RedirectStandardError $errFile `
        -PassThru

    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 250
        if ($proc.HasExited) { break }
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2
            if ($response.StatusCode -eq 200) { $ready = $true; break }
        } catch {
            # ancora in avvio
        }
    }

    if ($ready) { break }

    # Se e' morto, si riprova con un'altra porta.
    if ($proc.HasExited) {
        Write-Host "    tentativo $attempt fallito (porta $port occupata), riprovo..."
        Start-Sleep -Milliseconds 400
        $proc = $null
    }
}

if (-not $ready) {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Stop-WithMessage 'Il server non ha risposto.'
}

$proc.Id | Set-Content -LiteralPath $pidFile -Encoding ascii
$port | Set-Content -LiteralPath $portFile -Encoding ascii

Write-Host ''
Write-Host '  CircuitVerse Simulator - modalita offline' -ForegroundColor Green
Write-Host "  $url" -ForegroundColor Green
Write-Host ''
Write-Host '  Per chiudere: esegui "Ferma CircuitVerse.cmd"' -ForegroundColor Gray

# cmd /c start stacca il browser: non eredita gli handle della console, quindi
# il terminale che ha lanciato lo script puo' chiudersi.
if ($NoBrowser) {
    Write-Host "  (browser non aperto: avvio con -NoBrowser)" -ForegroundColor DarkGray
} else {
    cmd /c "start `"`" `"$url`"" | Out-Null
}