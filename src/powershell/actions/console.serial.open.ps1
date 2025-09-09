# powershell/actions/console.serial.open.ps1
# Démarre le pont série (WS <-> Named Pipe) via openhvx-serial-bridge.exe
# Non bloquant : lance le binaire et renvoie un JSON { ok, result, notes } immédiatement.

param(
    [string]$InputJson
)

# --- Silent runtime ---
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'

# ---------- Helpers JSON ----------
function Read-TaskInput {
    param([string]$Inline)
    if ($Inline) { try { return ($Inline | ConvertFrom-Json -ErrorAction Stop) } catch {} }
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "No JSON input (use -InputJson or pipe JSON to STDIN)" }
    try { return ($raw | ConvertFrom-Json -ErrorAction Stop) } catch { throw "Invalid JSON input" }
}

function Get-VmGuidFrom($payload) {
    if ($payload.id) { return [string]$payload.id }
    if ($payload.target -and $payload.target.refId) { return [string]$payload.target.refId }
    return $null
}

function Get-Com1PipePath([string]$vmGuid) {
    try { $vm = Get-VM -Id $vmGuid -ErrorAction Stop } catch { throw "VM introuvable par GUID Hyper-V: $vmGuid" }
    try { $com = Get-VMComPort -VMName $vm.Name -Number 1 -ErrorAction Stop } catch { throw "Impossible de lire le COM1 de '$($vm.Name)'" }
    $path = [string]$com.Path
    if (-not $path) { throw "Aucun COM1 configuré. Configure un Named Pipe sur '$($vm.Name)'." }
    if ($path -notmatch '^\\\\\.\\pipe\\') { throw "COM1 n'est pas un Named Pipe (Path=$path)." }
    return $path
}

function Extract-PipeName([string]$full) { $full -replace '^\\\\\.\\pipe\\', '' }

# ---------- MAIN ----------
try {
    # 1) Parse task input (support enveloppe { action, data:{...} })
    $task = Read-TaskInput -Inline $InputJson
    $d = if ($task.PSObject.Properties.Name -contains 'data' -and $task.data) { $task.data } else { $task }

    # 2) Champs requis depuis l’enrichissement
    $wsUrl = [string]$d.agentWsUrl
    $tunnelId = [string]$d.tunnelId
    $ttl = [int]   ($d.ttlSeconds | ForEach-Object { $_ })
    if (-not $ttl -or $ttl -le 0) { $ttl = 900 }  # défaut 15 min

    if (-not $wsUrl) { throw "Missing agentWsUrl in task payload" }
    if (-not $tunnelId) { throw "Missing tunnelId in task payload" }

    # 3) Résoudre GUID VM (Hyper-V) puis COM1
    $vmGuid = Get-VmGuidFrom $d
    if (-not $vmGuid) { throw "Missing VM GUID (data.id or data.target.refId)" }

    $pipePath = Get-Com1PipePath $vmGuid
    $pipeName = Extract-PipeName $pipePath

    # 4) Résoudre le chemin de l'exécutable (dynamique)
    #    Structure attendue :
    #       powershell/
    #         ├─ actions/console.serial.open.ps1  (ce script)
    #         └─ bin/openhvx-serial-bridge.exe   (binaire Go)
    $psRoot = $PSScriptRoot                          # ...\powershell\actions
    $psBase = Split-Path $psRoot -Parent             # ...\powershell
    $exeCandidates = @(
        (Join-Path $psBase 'bin\openhvx-serial-bridge.exe'),
        (Join-Path $psRoot 'openhvx-serial-bridge.exe'),
        (Join-Path $psBase 'openhvx-serial-bridge.exe')
    )
    $exe = $exeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $exe) {
        throw "openhvx-serial-bridge.exe introuvable. Cherché: $($exeCandidates -join '; ')"
    }

    # 5) Logs (ctx.paths.logs si dispo, sinon %TEMP%)
    $ctx = $d.__ctx
    $logDir = $env:TEMP
    if ($ctx -and $ctx.paths -and $ctx.paths.logs) {
        try {
            if (-not (Test-Path -LiteralPath $ctx.paths.logs)) { New-Item -ItemType Directory -Path $ctx.paths.logs -Force | Out-Null }
            $logDir = $ctx.paths.logs
        }
        catch { $logDir = $env:TEMP }
    }
    $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logBase = Join-Path $logDir ("serial-bridge-$tunnelId-$ts")
    $logOut = "$logBase.out.log"
    $logErr = "$logBase.err.log"   # ⚠️ doit être différent de $logOut

    # 6) Construire les arguments (pas de JSON stdin pour éviter quotes/escaping)
    $args = @(
        '-pipe', $pipePath,
        '-ws', $wsUrl,
        '-ttl', "$ttl",
        '-wake-cr', '2',
        '-v'
    )

    # 7) Lancer le binaire en arrière-plan (non bloquant)
    $startParams = @{
        FilePath               = $exe
        ArgumentList           = $args
        WorkingDirectory       = (Split-Path $exe -Parent)
        NoNewWindow            = $true
        PassThru               = $true
        RedirectStandardOutput = $logOut
        RedirectStandardError  = $logErr
    }
    $p = Start-Process @startParams

    Start-Sleep -Milliseconds 150
    if ($p.HasExited) {
        # échec immédiat → remonte l’erreur + extrait lignes de log si possible
        $code = $p.ExitCode
        $tailOut = $null; $tailErr = $null
        try { if (Test-Path -LiteralPath $logOut) { $tailOut = (Get-Content -LiteralPath $logOut -Tail 50 -ErrorAction SilentlyContinue) -join "`n" } } catch {}
        try { if (Test-Path -LiteralPath $logErr) { $tailErr = (Get-Content -LiteralPath $logErr -Tail 50 -ErrorAction SilentlyContinue) -join "`n" } } catch {}
        $msg = "openhvx-serial-bridge exited prematurely (code=$code)"
        if ($tailErr) { $msg = "$msg`nERR:`n$tailErr" }
        elseif ($tailOut) { $msg = "$msg`nOUT:`n$tailOut" }
        throw $msg
    }

    # 8) Succès → on renvoie un résultat homogène, sans attendre la fin du pont
    $result = [pscustomobject]@{
        started  = $true
        pid      = $p.Id
        exe      = $exe
        args     = $args
        logOut   = $logOut
        logErr   = $logErr
        tunnelId = $tunnelId
        vmGuid   = $vmGuid
        pipe     = $pipePath
        ws       = $wsUrl
        ttl      = $ttl
    }

    [pscustomobject]@{
        ok     = $true
        result = $result
        notes  = @(
            "Bridge lancé en arrière-plan; logs OUT: $logOut",
            "Logs ERR: $logErr",
            "Le TTL et/ou la fermeture des sockets mettront fin au process automatiquement."
        )
    } | ConvertTo-Json -Depth 6 -Compress
    exit 0
}
catch {
    $err = $_.Exception.Message
    # On tente d'ajouter une aide si le pipe est présent/absent
    try {
        $hint = $null
        if ($pipeName) {
            $pipeExists = Test-Path "\\.\pipe\$pipeName"
            $hint = if ($pipeExists) { "Le Named Pipe existe; verifier droits/instance." } else { "Le Named Pipe n'existe pas encore; demarrer la VM et re-tester." }
        }
        $payload = [pscustomobject]@{ ok = $false; error = $err }
        if ($hint) { $payload | Add-Member -NotePropertyName hint -NotePropertyValue $hint }
        $payload | ConvertTo-Json -Compress
    }
    catch {
        [pscustomobject]@{ ok = $false; error = $err } | ConvertTo-Json -Compress
    }
    exit 1
}
