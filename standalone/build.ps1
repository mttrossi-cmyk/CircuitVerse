<#
.SYNOPSIS
    Costruisce il pacchetto standalone offline di CircuitVerse (Windows x64).

.DESCRIPTION
    1. compila il frontend Vue in modalita standalone (VITE_STANDALONE=1)
    2. verifica che il bundle non contenga riferimenti a risorse di rete
    3. assembla la cartella finale (app/, caddy.exe, script di avvio)
    4. produce lo .zip distribuibile

    Richiede Node.js. Va eseguito una sola volta sulla macchina che ha
    internet; i PC destinatari non devono costruire nulla.

.EXAMPLE
    .\standalone\build.ps1
    .\standalone\build.ps1 -SkipZip
#>
[CmdletBinding()]
param(
    [switch] $SkipZip,
    [switch] $SkipInstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot   = Split-Path -Parent $PSScriptRoot
$frontend   = Join-Path $repoRoot 'cv-frontend-vue'
$stageDir   = Join-Path $PSScriptRoot 'dist'
$launcher   = Join-Path $PSScriptRoot 'launcher'
$vendorDir  = Join-Path $PSScriptRoot 'vendor'
$zipPath    = Join-Path $PSScriptRoot 'CircuitVerse-Offline-Windows-x64.zip'

# Risorse che il bundle scarica SENZA che l'utente faccia nulla: se una di
# queste finisce nel pacchetto, il simulatore non e' realmente autonomo e la
# build deve fallire.
$blocking = @(
    'ajax.googleapis.com',
    'fonts.googleapis.com',
    'fonts.gstatic.com',
    'googletagmanager.com'
)

# Risorse che si aprono solo se l'utente preme un link (help, manuale, forum,
# EDA Playground) o apre un dialogo che nella build offline non e' montato
# (Report Issue). Offline non funzionano, ma sono un degrado accettabile e sono
# documentati nel README: segnalate, non bloccanti.
$advisory = @(
    'circuitverse.org',
    'docs.circuitverse.org',
    'edaplayground.com',
    'learn.circuitverse',
    # Solo dentro components/ReportIssue, che Extra.vue non renderizza in offline.
    'api.imgur.com'
)

function Get-BundleHits($builtDir, $needles) {
    $hits = @()
    Get-ChildItem -LiteralPath $builtDir -Recurse -File -Include *.js, *.html, *.css | ForEach-Object {
        $content = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
        if ($null -eq $content) { return }
        foreach ($needle in $needles) {
            if ($content.Contains($needle)) {
                $hits += [pscustomobject]@{ File = $_.Name; Pattern = $needle }
            }
        }
    }
    # @() guarantees an array even for 0 or 1 hits, so .Count is always defined.
    return @($hits)
}

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'Node.js non trovato nel PATH.'
}

# ---------------------------------------------------------------- 1. build ---
Write-Step 'Dipendenze npm'
Push-Location $frontend
try {
    if (-not $SkipInstall -and -not (Test-Path -LiteralPath (Join-Path $frontend 'node_modules'))) {
        Write-Host '    npm ci ...'
        npm ci
        if ($LASTEXITCODE -ne 0) { throw 'npm ci fallito.' }
    } else {
        Write-Ok 'node_modules gia presente'
    }

    Write-Step 'Build del frontend (VITE_STANDALONE=1, VITE_BASE=/)'
    $env:VITE_STANDALONE = '1'
    $env:VITE_BASE       = '/'
    npm run build -- v0
    if ($LASTEXITCODE -ne 0) { throw 'Build del frontend fallito.' }
} finally {
    Pop-Location
}

$built = Join-Path $frontend 'dist\simulatorvue\v0'
if (-not (Test-Path -LiteralPath (Join-Path $built 'index.html'))) {
    throw "Output di build non trovato in $built"
}

# ------------------------------------------------------------- 2. gate rete ---
Write-Step 'Verifica: nessuna risorsa esterna scaricata automaticamente'
$violations = @(Get-BundleHits $built $blocking)

if ($violations.Count -gt 0) {
    Write-Host ''
    $violations | Format-Table -AutoSize | Out-String | Write-Host
    throw 'Build offline rifiutata: il bundle richiede risorse di rete al boot. Vedi la tabella sopra.'
}
Write-Ok 'Nessuna richiesta di rete automatica.'

$notes = @(Get-BundleHits $built $advisory)
if ($notes.Count -gt 0) {
    Write-Step 'Nota: link esterni presenti (si aprono solo su clic, non funzionano offline)'
    $notes | Group-Object Pattern | ForEach-Object {
        Write-Host ("    {0,-24} in {1} file" -f $_.Name, $_.Count) -ForegroundColor DarkGray
    }
    Write-Host '    Sono i collegamenti "Aiuto / Manuale / Forum", documentati nel README.' -ForegroundColor DarkGray
}

function Clear-Directory($dir) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return
    }
    # Si svuota la cartella invece di eliminarla: se un terminale ha questa
    # cartella come directory di lavoro, Windows ne blocca la rimozione.
    Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    $left = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
    if ($left.Count -gt 0) {
        cmd /c "rd /s /q `"$dir`"" | Out-Null
        $left = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
    }
    if ($left.Count -gt 0) {
        throw "Impossibile pulire $stageDir. Chiudi il simulatore e riprova."
    }
}

# --------------------------------------------------------------- 3. staging ---
Write-Step 'Assemblaggio del pacchetto'

# Se una copia precedente e' in esecuzione, caddy.exe ha il file bloccato.
$stageCaddy = Join-Path $stageDir 'caddy.exe'
Get-Process caddy -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path -eq $stageCaddy } |
    ForEach-Object {
        Write-Host "    arresto di caddy in esecuzione (PID $($_.Id)) per liberare il file"
        Stop-Process -Id $_.Id -Force
        Start-Sleep -Milliseconds 500
    }

Clear-Directory $stageDir
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

Copy-Item -LiteralPath $built -Destination (Join-Path $stageDir 'app') -Recurse
Copy-Item -LiteralPath (Join-Path $vendorDir 'caddy.exe') -Destination $stageDir
Copy-Item -LiteralPath $launcher -Destination $stageDir -Recurse
Remove-Item -LiteralPath (Join-Path $stageDir 'launcher') -Recurse -Force -ErrorAction SilentlyContinue

# Gli script .cmd/.ps1 devono stare alla root del pacchetto.
Get-ChildItem -LiteralPath $launcher -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $stageDir
}

# Il Caddyfile, il .pid e i log sono runtime, non contenuto del pacchetto.
foreach ($junk in @('Caddyfile', 'caddy.pid', 'caddy.port', 'caddy.log', 'caddy-error.log', '.caddy')) {
    $p = Join-Path $stageDir $junk
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
}

$size = (Get-ChildItem -LiteralPath $stageDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-Ok ("pacchetto: {0} file, {1} MB" -f (Get-ChildItem -LiteralPath $stageDir -Recurse -File).Count, [math]::Round($size / 1MB, 2))

# ------------------------------------------------------------------ 4. zip ---
if ($SkipZip) {
    Write-Step 'ZIP non richiesto (-SkipZip)'
    return
}

Write-Step 'Creazione dello ZIP'
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

# Compress-Archive e' fragile sui file grandi (>2 GB di stream) e sugli archivi
# con molti file: usiamo direttamente System.IO.Compression.
Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $stageDir,
    $zipPath,
    [System.IO.Compression.CompressionLevel]::Optimal,
    $false
)

$zipSize = (Get-Item -LiteralPath $zipPath).Length
Write-Ok ("{0}  ({1} MB)" -f (Split-Path -Leaf $zipPath), [math]::Round($zipSize / 1MB, 2))

Write-Step 'Fatto'
Write-Host "    Estratto:  $stageDir"
Write-Host "    Zip:       $zipPath"
Write-Host ''
Write-Host '    Prova rapida: esegui standalone\dist\Avvia CircuitVerse.cmd' -ForegroundColor Gray