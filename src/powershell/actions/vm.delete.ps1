

# src/powershell/actions/vm.delete.ps1
# Attend sur STDIN un JSON du type:
# {
#   "data": {
#     "id": "<GUID_VM>"        # optionnel si "name" fourni
#     "name": "vm-demo",       # optionnel si "id" fourni
#     "forceStop": true,       # optionnel (default: false)
#     "deleteDisks": true,     # optionnel (default: false) → supprime les VHDX si non partagés
#     "waitForStopSec": 30     # optionnel (default: 30)
#   }
# }
#
# Sorties:
#  - Succès:
#    { "ok": true, "result": {
#        "deleted": true,
#        "name": "...",
#        "guid": "...",
#        "wasRunning": true|false,
#        "stopped": true|false,
#        "deletedDisks": [ "D:\\HyperV\\Disks\\x.vhdx", ... ],
#        "skippedDisks": [ { "path": "...", "reason": "in use by other VM" }, ... ]
#    } }
#  - Erreur:
#    { "ok": false, "error": "message court", "detail": "trace" }

$ErrorActionPreference = 'Stop'

function To-Bool($v, $default = $false) {
    if ($null -eq $v) { return [bool]$default }
    if ($v -is [bool]) { return $v }
    $s = "$v".Trim().ToLower()
    switch ($s) {
        '1' { return $true }
        'true' { return $true }
        'yes' { return $true }
        'y' { return $true }
        '0' { return $false }
        'false' { return $false }
        'no' { return $false }
        'n' { return $false }
        default { return [bool]$default }
    }
}

try {
    # === Lecture STDIN ===
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        @{ ok = $false; error = "no input" } | ConvertTo-Json
        exit 1
    }

    $task = $raw | ConvertFrom-Json
    $data = $task.data
    if (-not $data) { throw "missing 'data' object" }

    $Id = $data.id
    $Name = $data.name
    if (-not $Id -and [string]::IsNullOrWhiteSpace($Name)) {
        throw "provide 'data.id' (VM GUID) or 'data.name'"
    }

    $ForceStop = To-Bool $data.forceStop $false
    $DeleteDisks = To-Bool $data.deleteDisks $false
    $WaitForStop = 30
    if ($data.waitForStopSec) {
        $WaitForStop = [int]$data.waitForStopSec
        if ($WaitForStop -lt 0) { $WaitForStop = 0 }
    }

    # === Résolution de la VM ===
    $vm = $null
    if ($Id) {
        try { $vm = Get-VM -Id $Id -ErrorAction Stop } catch {}
    }
    if (-not $vm -and $Name) {
        try { $vm = Get-VM -Name $Name -ErrorAction Stop } catch {}
    }
    if (-not $vm) {
        throw "VM not found (id='$Id', name='$Name')"
    }

    $vmGuid = "$($vm.Id)"
    $vmName = $vm.Name
    $wasRunning = ($vm.State -eq 'Running' -or $vm.State -eq 'Paused' -or $vm.State -eq 'Saving' -or $vm.State -eq 'Starting')

    # === Lister les disques AVANT suppression ===
    $diskPaths = @()
    try {
        $diskPaths = Get-VMHardDiskDrive -VMName $vmName -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -Expand Path
    }
    catch {}

    if (-not $diskPaths) { $diskPaths = @() }

    # === Stop VM si nécessaire ===
    $stopped = $false
    if ($wasRunning) {
        if ($ForceStop) {
            # Arrêt brutal si demandé explicitement
            try { Stop-VM -Name $vmName -TurnOff -Force -ErrorAction Stop } catch {
                # fallback
                Stop-VM -Name $vmName -Force -ErrorAction Stop
            }
        }
        else {
            try {
                Stop-VM -Name $vmName -Force -ErrorAction Stop
            }
            catch {
                throw "VM is running. Use 'forceStop: true' to force shutdown"
            }
        }

        # Attente de l'état "Off"
        $deadline = (Get-Date).AddSeconds($WaitForStop)
        do {
            Start-Sleep -Milliseconds 400
            try { $vm = Get-VM -Id $vmGuid -ErrorAction Stop } catch { break }
        } while ($vm.State -ne 'Off' -and (Get-Date) -lt $deadline)
        $stopped = ($vm -and $vm.State -eq 'Off')
    }

    # === Suppression de la VM ===
    Remove-VM -Name $vmName -Force -ErrorAction Stop

    # === Suppression des VHDX si demandé et sûrs ===
    $deletedDisks = @()
    $skippedDisks = @()

    if ($DeleteDisks -and $diskPaths.Count -gt 0) {
        foreach ($p in $diskPaths | Select-Object -Unique) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            # Vérifie si d'autres VMs utilisent ce VHD
            $stillInUse = $false
            try {
                $refs = Get-VMHardDiskDrive -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -eq $p } |
                Where-Object { $_.VMName -ne $vmName }
                if ($refs -and $refs.Count -gt 0) { $stillInUse = $true }
            }
            catch {}

            if ($stillInUse) {
                $skippedDisks += @{ path = $p; reason = "in use by other VM" }
                continue
            }

            if (Test-Path -LiteralPath $p) {
                try {
                    Remove-Item -LiteralPath $p -Force -ErrorAction Stop
                    $deletedDisks += $p
                }
                catch {
                    $skippedDisks += @{ path = $p; reason = "delete failed: $($_.Exception.Message)" }
                }
            }
            else {
                $skippedDisks += @{ path = $p; reason = "file not found" }
            }
        }
    }

    $result = @{
        deleted      = $true
        name         = $vmName
        id           = $vmGuid
        guid         = $vmGuid
        wasRunning   = $wasRunning
        stopped      = $stopped
        deletedDisks = $deletedDisks
        skippedDisks = $skippedDisks
    }

    # IMPORTANT: ne pas émettre { ok, result }, juste l’objet utile.
    @{ vm = $result } | ConvertTo-Json -Depth 6
    exit 0
}
catch {
    # Erreur structurée (message court + détail)
    $msg = $_.Exception.Message
    $detail = $_ | Out-String
    @{ ok = $false; error = $msg; detail = $detail } | ConvertTo-Json -Depth 6
    exit 1
}
