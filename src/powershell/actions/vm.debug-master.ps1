# debug.ps1
# Lit tout le STDIN et écrit dans ./debug.log

$raw = [Console]::In.ReadToEnd()

$logFile = Join-Path (Get-Location) "debug.log"
Set-Content -LiteralPath $logFile -Value $raw -Encoding UTF8

# aussi sur STDERR pour feedback
Write-Error "Payload écrit dans $logFile"
