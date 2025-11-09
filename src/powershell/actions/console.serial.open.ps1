# powershell/actions/console.serial.open.ps1
# Run serial bridge (WS <-> Named Pipe) openhvx-serial-bridge.exe

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
    try { $vm = Get-VM -Id $vmGuid -ErrorAction Stop } catch { throw "VM not by GUID Hyper-V: $vmGuid" }
    try { $com = Get-VMComPort -VMName $vm.Name -Number 1 -ErrorAction Stop } catch { throw "Impossible to read COM1 of '$($vm.Name)'" }
    $path = [string]$com.Path
    if (-not $path) { throw "no COM1 configured. Configure a Named Pipe on '$($vm.Name)'." }
    if ($path -notmatch '^\\\\\.\\pipe\\') { throw "COM1 n'est pas un Named Pipe (Path=$path)." }
    return $path
}

function Extract-PipeName([string]$full) { $full -replace '^\\\\\.\\pipe\\', '' }

# ---------- MAIN ----------
try {
    # 1) Parse task input (support enveloppe { action, data:{...} })
    $task = Read-TaskInput -Inline $InputJson
    $d = if ($task.PSObject.Properties.Name -contains 'data' -and $task.data) { $task.data } else { $task }

    $wsUrl = [string]$d.agentWsUrl
    $tunnelId = [string]$d.tunnelId
    $ttl = [int]   ($d.ttlSeconds | ForEach-Object { $_ })
    if (-not $ttl -or $ttl -le 0) { $ttl = 900 }  # défaut 15 min

    if (-not $wsUrl) { throw "Missing agentWsUrl in task payload" }
    if (-not $tunnelId) { throw "Missing tunnelId in task payload" }

    # 3) Resolve GUID VM (Hyper-V) then COM1
    $vmGuid = Get-VmGuidFrom $d
    if (-not $vmGuid) { throw "Missing VM GUID (data.id or data.target.refId)" }

    $pipePath = Get-Com1PipePath $vmGuid
    $pipeName = Extract-PipeName $pipePath
    $psRoot = $PSScriptRoot                      
    $psBase = Split-Path $psRoot -Parent             
    $exeCandidates = @(
        (Join-Path $psBase 'bin\openhvx-serial-bridge.exe'),
        (Join-Path $psRoot 'openhvx-serial-bridge.exe'),
        (Join-Path $psBase 'openhvx-serial-bridge.exe')
    )
    $exe = $exeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $exe) {
        throw "openhvx-serial-bridge.exe not found. WD: $($exeCandidates -join '; ')"
    }

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
    $logErr = "$logBase.err.log" 

    $args = @(
        '-pipe', $pipePath,
        '-ws', $wsUrl,
        '-ttl', "$ttl",
        '-wake-cr', '2',
        '-v'
    )

    #Exec serial-bridge bin

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
        $code = $p.ExitCode
        $tailOut = $null; $tailErr = $null
        try { if (Test-Path -LiteralPath $logOut) { $tailOut = (Get-Content -LiteralPath $logOut -Tail 50 -ErrorAction SilentlyContinue) -join "`n" } } catch {}
        try { if (Test-Path -LiteralPath $logErr) { $tailErr = (Get-Content -LiteralPath $logErr -Tail 50 -ErrorAction SilentlyContinue) -join "`n" } } catch {}
        $msg = "openhvx-serial-bridge exited prematurely (code=$code)"
        if ($tailErr) { $msg = "$msg`nERR:`n$tailErr" }
        elseif ($tailOut) { $msg = "$msg`nOUT:`n$tailOut" }
        throw $msg
    }

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
            "Bridge running in background; logs OUT: $logOut",
            "Logs ERR: $logErr",
            "TTL and/or socket termination will kill the process automatically"
        )
    } | ConvertTo-Json -Depth 6 -Compress
    exit 0
}
catch {
    $err = $_.Exception.Message
    try {
        $hint = $null
        if ($pipeName) {
            $pipeExists = Test-Path "\\.\pipe\$pipeName"
            $hint = if ($pipeExists) { "Named pipe exist; please verify rights/instances." } else { "Named pipe doesnt exist." }
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
