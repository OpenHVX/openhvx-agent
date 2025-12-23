# src/powershell/actions/vm.delete.ps1
param(
    [string]$InputJson
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'

function To-Bool($v, $default = $false) {
    if ($null -eq $v) { return [bool]$default }
    if ($v -is [bool]) { return $v }
    $s = "$v".Trim().ToLower()
    switch -Regex ($s) {
        '^(1|true|yes|y)$' { return $true }
        '^(0|false|no|n)$' { return $false }
        default { return [bool]$default }
    }
}
function Get-FullPath([string]$p) { if ([string]::IsNullOrWhiteSpace($p)) { return $null } [System.IO.Path]::GetFullPath($p) }
function Assert-UnderRoot([string]$Candidate, [string]$Root) {
    if (-not $Root) { return }
    $c = Get-FullPath $Candidate; $r = Get-FullPath $Root
    if (-not $c -or -not $r) { throw "invalid path check" }
    if ($c.Length -lt $r.Length -or ($c.Substring(0, $r.Length)).ToLower() -ne $r.ToLower()) { throw "unsafe path outside managed root: $Candidate (root=$Root)" }
}
function Ensure-Dir([string]$p) { if ($p -and -not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
function Unique-Dest([string]$destPath) {
    if (-not (Test-Path -LiteralPath $destPath)) { return $destPath }
    $dir = [System.IO.Path]::GetDirectoryName($destPath); $file = [System.IO.Path]::GetFileNameWithoutExtension($destPath); $ext = [System.IO.Path]::GetExtension($destPath)
    for ($i = 1; $i -le 9999; $i++) { $cand = Join-Path $dir ("{0} ({1}){2}" -f $file, $i, $ext); if (-not (Test-Path -LiteralPath $cand)) { return $cand } }
    $stamp = (Get-Date -Format "yyyyMMdd-HHmmssfff"); return (Join-Path $dir ("{0}-{1}{2}" -f $file, $stamp, $ext))
}
function Wait-FileUnlocked {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$TimeoutMs = 15000,
        [int]$ProbeMs = 250
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        try {
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $fs.Close(); return $true
        }
        catch { Start-Sleep -Milliseconds $ProbeMs }
    }
    return $false
}
function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [int]$Retries = 15,
        [int]$DelayMs = 500
    )
    for ($i = 0; $i -lt $Retries; $i++) {
        try { & $Action; return $true } catch {
            if ($i -ge ($Retries - 1)) { throw }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
    return $false
}
function Get-VmNamesUsingDiskNumber {
    param([Parameter(Mandatory = $true)][int]$DiskNumber)
    $names = @()
    try {
        $vms = Get-VM
        foreach ($v in $vms) {
            $hdds = Get-VMHardDiskDrive -VMName $v.Name -ErrorAction SilentlyContinue
            foreach ($h in $hdds) {
                if ($null -ne $h.DiskNumber -and $h.DiskNumber -eq $DiskNumber) {
                    $names += $v.Name
                }
            }
        }
    }
    catch {}
    return $names
}
function Get-IscsiSessionsByDiskNumber {
    param([Parameter(Mandatory = $true)][int]$DiskNumber)
    $matches = @()
    try {
        $sessions = Get-WmiObject -Namespace ROOT\WMI -Class MSiSCSIInitiator_SessionClass -ErrorAction Stop
        foreach ($s in $sessions) {
            if (-not $s.Devices) { continue }
            foreach ($dev in $s.Devices) {
                if ($dev.DeviceNumber -eq $DiskNumber) {
                    $matches += [pscustomobject]@{
                        sessionId  = $s.SessionId
                        targetName = $s.TargetName
                    }
                    break
                }
            }
        }
    }
    catch {}
    return , $matches
}

try {
    # === Lecture via -InputJson ===
    $raw = $InputJson
    if ([string]::IsNullOrWhiteSpace($raw)) {
        @{ ok = $false; error = "no input" } | ConvertTo-Json
        exit 1
    }
    $task = $raw | ConvertFrom-Json
    $data = $task.data; if (-not $data) { $data = $task }

    # IDs
    $Id = $data.id; if (-not $Id -and $data.guid) { $Id = $data.guid }
    if (-not $Id -and $data.refId) { $Id = $data.refId }
    $Name = $data.name
    if (-not $Id -and [string]::IsNullOrWhiteSpace($Name)) { throw "provide 'id/guid/refId' (VM GUID) or 'name'" }

    $ForceStop = To-Bool $data.forceStop   $false
    $DeleteDisks = To-Bool $data.deleteDisks $false
    $WaitForStop = if ($data.waitForStopSec) { [int]$data.waitForStopSec } else { 30 }
    if ($WaitForStop -lt 0) { $WaitForStop = 0 }

    # Contexte
    $ctx = $data.__ctx
    $tenantId = $null; $rootPath = $null; $vhdRoot = $null; $trashRoot = $null
    if ($ctx) {
        $tenantId = $ctx.tenantId
        if ($ctx.paths) {
            $rootPath = $ctx.paths.root
            $vhdRoot = $ctx.paths.vhd
            if ($ctx.paths.trash) { $trashRoot = $ctx.paths.trash }
            elseif ($vhdRoot) { $trashRoot = Join-Path $vhdRoot "_trash" }
        }
    }

    # === Résolution VM ===
    $vm = $null
    if ($Id) { try { $vm = Get-VM -Id $Id -ErrorAction Stop } catch {} }
    if (-not $vm -and $Name) { try { $vm = Get-VM -Name $Name -ErrorAction Stop } catch {} }
    if (-not $vm) {
        $result = @{
            deleted  = $false
            notFound = $true
            name     = $Name
            id       = $Id
            guid     = $Id
        }
        @{ vm = $result } | ConvertTo-Json -Depth 6
        exit 0
    }

    $vmGuid = "$($vm.Id)"; $vmName = $vm.Name
    $wasRunning = ($vm.State -in 'Running', 'Paused', 'Saving', 'Starting')

    # === Lister objets + chemins via Hyper-V ===
    $hddObjs = @(); $dvdObjs = @()
    try { $hddObjs = Get-VMHardDiskDrive -VMName $vmName -ErrorAction SilentlyContinue } catch {}
    try { $dvdObjs = Get-VMDvdDrive      -VMName $vmName -ErrorAction SilentlyContinue } catch {}

    $hddPaths = @($hddObjs | Where-Object { $_.Path } | Select-Object -Expand Path)
    $passThroughNumbers = @($hddObjs | Where-Object { $_.DiskNumber -ne $null } | Select-Object -ExpandProperty DiskNumber -Unique)
    $isoPaths = @($dvdObjs | Where-Object { $_.Path } | Select-Object -Expand Path)
    $diskPaths = @($hddPaths + $isoPaths) | Where-Object { $_ } | Select-Object -Unique

    # === Fallback: scanner le dossier datastore VHD/<tenant>/<vmName> pour *.vhd[x]/*.avhd[x]/*.iso ===
    if ($vhdRoot -and $tenantId -and $vmName) {
        $candidateDir = Join-Path (Join-Path $vhdRoot $tenantId) $vmName
        if (Test-Path -LiteralPath $candidateDir) {
            try {
                $extra = Get-ChildItem -LiteralPath $candidateDir -File -ErrorAction SilentlyContinue -Include *.vhd, *.vhdx, *.avhd, *.avhdx, *.iso
                if ($extra) {
                    $extraPaths = $extra | Select-Object -ExpandProperty FullName
                    $diskPaths = @($diskPaths + $extraPaths) | Select-Object -Unique
                }
            }
            catch {}
        }
    }

    # === Stop VM si nécessaire ===
    $stopped = $false
    if ($wasRunning) {
        if ($ForceStop) {
            try { Stop-VM -Name $vmName -TurnOff -Force -ErrorAction Stop } catch { Stop-VM -Name $vmName -Force -ErrorAction Stop }
        }
        else {
            try { Stop-VM -Name $vmName -Force -ErrorAction Stop } catch { throw "VM is running. Use 'forceStop: true' to force shutdown" }
        }
        $deadline = (Get-Date).AddSeconds($WaitForStop)
        do {
            Start-Sleep -Milliseconds 400
            try { $vm = Get-VM -Id $vmGuid -ErrorAction Stop } catch { break }
        } while ($vm.State -ne 'Off' -and (Get-Date) -lt $deadline)
        $stopped = ($vm -and $vm.State -eq 'Off')
    }

    # === Éjecter ISO + détacher VHD avant opérations FS ===
    foreach ($d in $dvdObjs) {
        try {
            Set-VMDvdDrive -VMName $vmName -ControllerType $d.ControllerType -ControllerNumber $d.ControllerNumber -ControllerLocation $d.ControllerLocation -Path $null -ErrorAction SilentlyContinue
        }
        catch {}
    }
    foreach ($h in $hddObjs) {
        try {
            Remove-VMHardDiskDrive -VMName $vmName -ControllerType $h.ControllerType -ControllerNumber $h.ControllerNumber -ControllerLocation $h.ControllerLocation -ErrorAction SilentlyContinue
        }
        catch {}
    }

    # === Detach iSCSI or bring online pass-through disks ===
    foreach ($n in $passThroughNumbers) {
        if ($null -eq $n) { continue }
        $inUseBy = @(Get-VmNamesUsingDiskNumber -DiskNumber $n)
        if ($inUseBy.Count -gt 0) { continue }

        $iscsiSessions = @(Get-IscsiSessionsByDiskNumber -DiskNumber $n | Where-Object { $_ })
        if ($iscsiSessions.Count -gt 0) {
            $targets = @()
            foreach ($sess in $iscsiSessions) {
                if ($sess.targetName) { $targets += $sess.targetName }
                try { Disconnect-IscsiTarget -SessionIdentifier $sess.sessionId -Confirm:$false -ErrorAction Stop | Out-Null }
                catch {}
            }
            foreach ($t in ($targets | Select-Object -Unique)) {
                try { Disconnect-IscsiTarget -NodeAddress $t -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch {}
            }
            continue
        }

        try { Set-Disk -Number $n -IsOffline $false | Out-Null } catch {}
    }

    # === Préparer Trash si nécessaire ===
    $deletedDisks = @()
    $movedDisks = @()
    $skippedDisks = @()

    $trashBase = $null
    if (-not $DeleteDisks -and $diskPaths.Count -gt 0 -and $trashRoot) {
        $stamp = (Get-Date -Format "yyyyMMdd-HHmmss")
        $sub = if ($tenantId) { Join-Path $tenantId "$stamp-$vmName-$vmGuid" } else { "$stamp-$vmName-$vmGuid" }
        $trashBase = Join-Path $trashRoot $sub
        if ($rootPath) { Assert-UnderRoot -Candidate $trashBase -Root $rootPath }
        Ensure-Dir $trashBase
    }

    # === Déplacer/Supprimer fichiers ===
    foreach ($p in $diskPaths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }

        if ($rootPath) {
            try { Assert-UnderRoot -Candidate $p -Root $rootPath }
            catch { $skippedDisks += @{ path = $p; reason = "outside managed root" }; continue }
        }

        $stillInUse = $false
        try {
            $refs = Get-VMHardDiskDrive -VMName * -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -eq $p -and $_.VMName -ne $vmName }
            if ($refs) { $stillInUse = $true }
        }
        catch {}
        if ($stillInUse) { $skippedDisks += @{ path = $p; reason = "in use by other VM" }; continue }

        if (-not (Test-Path -LiteralPath $p)) { $skippedDisks += @{ path = $p; reason = "file not found" }; continue }

        [void](Wait-FileUnlocked -Path $p -TimeoutMs 15000 -ProbeMs 250)

        if ($DeleteDisks) {
            try {
                Invoke-WithRetry -Action { Remove-Item -LiteralPath $p -Force -ErrorAction Stop } | Out-Null
                $deletedDisks += $p
            }
            catch {
                $skippedDisks += @{ path = $p; reason = "delete failed: $($_.Exception.Message)" }
            }
        }
        elseif ($trashBase) {
            try {
                $dest = Unique-Dest (Join-Path $trashBase ([System.IO.Path]::GetFileName($p)))
                try {
                    Invoke-WithRetry -Action { Move-Item -LiteralPath $p -Destination $dest -Force -ErrorAction Stop } | Out-Null
                }
                catch {
                    Copy-Item -LiteralPath $p -Destination $dest -Force -ErrorAction Stop
                    Invoke-WithRetry -Action { Remove-Item -LiteralPath $p -Force -ErrorAction Stop } | Out-Null
                }
                $movedDisks += @{ from = $p; to = $dest }
            }
            catch {
                $skippedDisks += @{ path = $p; reason = "move/copy failed: $($_.Exception.Message)" }
            }
        }
        else {
            $skippedDisks += @{ path = $p; reason = "no trash path; leaving in place" }
        }
    }

    # === Supprimer la VM (config) en dernier ===
    try { Remove-VM -Name $vmName -Force -ErrorAction Stop } catch {
        $vmGone = $false
        try { $vmGone = -not (Get-VM -Name $vmName -ErrorAction SilentlyContinue) } catch {}
        if (-not $vmGone) { throw }
    }

    $result = @{
        deleted      = $true
        name         = $vmName
        id           = $vmGuid
        guid         = $vmGuid
        wasRunning   = $wasRunning
        stopped      = $stopped
        deletedDisks = $deletedDisks
        movedDisks   = $movedDisks
        skippedDisks = $skippedDisks
    }

    @{ vm = $result } | ConvertTo-Json -Depth 8
    exit 0
}
catch {
    $msg = $_.Exception.Message
    $detail = $_ | Out-String
    @{ ok = $false; error = $msg; detail = $detail } | ConvertTo-Json -Depth 8
    exit 1
}
