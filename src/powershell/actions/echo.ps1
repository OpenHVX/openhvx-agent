# src/powershell/actions/echo.ps1
# Lit un JSON sur STDIN du type:
#   { "action": "echo", "data": { ... } }
# et renvoie sur STDOUT un JSON (le "result") que l'agent republiera sur RabbitMQ.

$ErrorActionPreference = 'Stop'

try {
    $raw = [Console]::In.ReadToEnd()

    if ([string]::IsNullOrWhiteSpace($raw)) {
        # Pas d'entrée -> on renvoie quand même un résultat minimal
        $payload = [pscustomobject]@{
            action = "echo"
            data   = $null
        }
    }
    else {
        try {
            $payload = $raw | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            # JSON invalide -> erreur (l'agent marquera ok=false)
            Write-Error "invalid json payload: $($_.Exception.Message)"
            exit 1
        }
    }

    # Normalise au cas où
    $action = if ($payload.PSObject.Properties.Name -contains 'action') { $payload.action } else { 'echo' }
    $data = if ($payload.PSObject.Properties.Name -contains 'data') { $payload.data }   else { $null }

    # Construis le "result" (tu peux y mettre ce que tu veux ; le wrapper Go l'encapsule ensuite)
    $result = [pscustomobject]@{
        action = $action
        echo   = $data
        meta   = @{
            when = (Get-Date).ToUniversalTime().ToString("o")
            host = $env:COMPUTERNAME
            user = $env:USERNAME
            ps   = $PSVersionTable.PSVersion.ToString()
        }
    }

    $result | ConvertTo-Json -Depth 20 -Compress
    exit 0
}
catch {
    # Toute autre erreur -> on la fait remonter
    Write-Error $_.Exception.Message
    exit 1
}
