$ErrorActionPreference = 'SilentlyContinue'

$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $baseDir 'caddy.pid'

if (-not (Test-Path -LiteralPath $pidFile)) {
    Write-Host 'Il simulatore non risulta in esecuzione.' -ForegroundColor Yellow
    if ($Host.Name -eq 'ConsoleHost') { Read-Host 'Premi Invio per uscire' }
    exit 0
}

$pid_ = Get-Content -LiteralPath $pidFile
$proc = Get-Process -Id ([int]$pid_) -ErrorAction SilentlyContinue

if ($proc -and $proc.ProcessName -eq 'caddy') {
    Stop-Process -Id $proc.Id -Force
    Write-Host 'Simulatore arrestato.' -ForegroundColor Green
} else {
    Write-Host 'Il processo non e piu attivo.' -ForegroundColor Yellow
}

Remove-Item -LiteralPath $pidFile -Force
Remove-Item -LiteralPath (Join-Path $baseDir 'caddy.port') -Force