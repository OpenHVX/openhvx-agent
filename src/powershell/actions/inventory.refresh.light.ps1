# powershell/actions/inventory.refresh.light.ps1
# Sortie: objet JSON { ok, result, error }
# - result.inventory  : inventaire Hyper-V (host, réseaux, stockage, VMs) -> mêmes clés que la version complète
# - result.datastores : [{ name, kind, path, drive, totalBytes, freeBytes }]
# Paramètres d'entrée: identiques à inventory.refresh.ps1 (via -InputJson ou STDIN)

param(
    [string]$InputJson
)

$ErrorActionPreference = 'Stop'

# ===================== Helpers entrée JSON (arg ou STDIN) =====================
function Read-ParamsJson {
    param([string]$Inline)
    if ($Inline) { try { return ($Inline | ConvertFrom-Json -ErrorAction Stop) } catch {} }
    $stdinLines = @()
    foreach ($line in $input) { $stdinLines += $line }
    if ($stdinLines.Count -gt 0) {
        $text = ($stdinLines -join "`n")
        try { return ($text | ConvertFrom-Json -ErrorAction Stop) } catch {}
    }
    return @{}
}

# ===================== Helpers génériques =====================
function _MB($bytes) {
    if ($null -eq $bytes) { return $null }
    return [int]([math]::Round($bytes / 1MB))
}

function Get-DriveUsage {
    param([string]$Path)
    if (-not $Path) { return @{ drive = $null; totalBytes = 0; freeBytes = 0 } }
    $drive = $null
    try { $drive = [System.IO.Path]::GetPathRoot($Path) } catch {}
    if (-not $drive) { try { $drive = (Split-Path -Path $Path -Qualifier) } catch {} }
    try {
        $di = New-Object System.IO.DriveInfo ($drive)
        return @{
            drive      = $drive
            totalBytes = [uint64]$di.TotalSize
            freeBytes  = [uint64]$di.AvailableFreeSpace
        }
    }
    catch {
        return @{ drive = $drive; totalBytes = 0; freeBytes = 0 }
    }
}

function Build-DefaultDatastores {
    param([string]$BasePath)
    if (-not $BasePath) { return @() }
    $root = Join-Path $BasePath 'openhvx'
    return @(
        @{ name = 'OpenHVX Root'; kind = 'root'; path = (Join-Path $root '') },
        @{ name = 'OpenHVX VMS'; kind = 'vm'; path = (Join-Path $root 'VMS') },
        @{ name = 'OpenHVX VHD'; kind = 'vhd'; path = (Join-Path $root 'VHD') },
        @{ name = 'OpenHVX ISOs'; kind = 'iso'; path = (Join-Path $root 'ISOs') },
        @{ name = 'Checkpoints'; kind = 'checkpoint'; path = (Join-Path $root 'Checkpoints') },
        @{ name = 'Logs'; kind = 'logs'; path = (Join-Path $root 'Logs') }
    )
}

# ===================== Collecte HOST (light) =====================
function Get-HostInfoLight {
    $cs = $null; $os = $null; $cpuCi = $null; $hv = $null
    try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem } catch {}
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem } catch {}
    try { $cpuCi = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1 } catch {}
    try {
        $vmh = Get-VMHost
        if ($vmh) {
            $hv = [pscustomobject]@{
                logicalProcessors       = $vmh.LogicalProcessorCount
                memoryCapacityMB        = _MB $vmh.MemoryCapacity
                numaSpanningEnabled     = $vmh.NumaSpanningEnabled
                defaultVmPath           = $vmh.VirtualMachinePath
                defaultVhdPath          = $vmh.VirtualHardDiskPath
                resourceMeteringEnabled = $vmh.ResourceMeteringSaveInterval -ne $null
            }
        }
    }
    catch {}

    [pscustomobject]@{
        hostname   = ($cs.Name            | ForEach-Object { $_ }) -as [string]
        os         = ($os.Caption         | ForEach-Object { $_ }) -as [string]
        osVersion  = ($os.Version         | ForEach-Object { $_ }) -as [string]
        memMB      = if ($cs) { _MB $cs.TotalPhysicalMemory } else { $null }
        domain     = if ($cs) { $cs.Domain } else { $env:USERDOMAIN }
        cpu        = if ($cpuCi) {
            [pscustomobject]@{
                name              = $cpuCi.Name
                cores             = $cpuCi.NumberOfCores
                logicalProcessors = $cpuCi.NumberOfLogicalProcessors
                maxClockMHz       = $cpuCi.MaxClockSpeed
            }
        }
        else { $null }
        hypervHost = $hv
    }
}

# ===================== Réseau / vSwitch (light) =====================
function Get-HostAdaptersLight {
    $adapters = @()
    try {
        $adapters = Get-NetAdapter | Sort-Object -Property ifIndex | ForEach-Object {
            [pscustomobject]@{
                name       = $_.Name
                interface  = $_.InterfaceDescription
                mac        = $_.MacAddress
                status     = "$($_.Status)"
                linkSpeed  = [string]$_.LinkSpeed
                switchName = $null
                ip         = @()   # placeholder (light)
                dns        = @()   # placeholder (light)
            }
        }
    }
    catch {}
    return , $adapters
}

function Get-VSwitchesLight {
    $switches = @()
    try {
        $switches = Get-VMSwitch | ForEach-Object {
            $uplinks = @()
            if ($_.SwitchType -eq 'External') {
                try { $uplinks = $_.NetAdapterInterfaceDescriptions } catch {}
            }
            [pscustomobject]@{
                name          = $_.Name
                type          = "$($_.SwitchType)"    # External/Internal/Private
                notes         = $_.Notes
                uplinks       = $uplinks
                bandwidthMode = $_.BandwidthReservationMode
                allowMacSpoof = $_.AllowMacSpoofing
                extensions    = @()                   # placeholder (light)
            }
        }
    }
    catch {}
    return , $switches
}

function Map-VSwitchToHostAdapters {
    param($switches, $hostAdapters)
    foreach ($sw in $switches) {
        if ($sw.type -eq 'External' -and $sw.uplinks) {
            foreach ($upl in $sw.uplinks) {
                $match = $hostAdapters | Where-Object { $_.interface -eq $upl }
                foreach ($m in $match) { $m.switchName = $sw.name }
            }
        }
    }
}

# ===================== Stockage hôte (light placeholders) =====================
function Get-StorageInventoryLight {
    # placeholders pour garder la forme (évite Get-Disk / Get-Volume)
    [pscustomobject]@{
        disks   = @()
        volumes = @()
    }
}

# ===================== VMs (light) =====================
function Get-VHD-LightInfo {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $fi = $null
    try { $fi = Get-Item -LiteralPath $Path -ErrorAction Stop } catch { return $null }

    $ext = [System.IO.Path]::GetExtension($Path)
    $fmt = if ($ext -and $ext.TrimStart('.').ToUpperInvariant() -eq 'VHD') { 'VHD' } else { 'VHDX' }

    $fileSizeMB = _MB $fi.Length
    # On n’appelle PAS Get-VHD. On renseigne sizeMB = fileSizeMB (valeur “utile” pour l’UI).
    return [pscustomobject]@{
        format             = $fmt
        type               = $null
        sizeMB             = $null
        fileSizeMB         = $fileSizeMB
        parentPath         = $null
        blockSize          = $null
        logicalSectorSize  = $null
        physicalSectorSize = $null
    }
}

function Get-VM-NICsLight {
    param([string]$VmName)
    $items = @()
    try {
        $nics = Get-VMNetworkAdapter -VMName $VmName
        foreach ($n in $nics) {
            $items += [pscustomobject]@{
                name       = $n.Name
                switch     = $n.SwitchName
                mac        = $n.MacAddress
                dynamicMac = $n.DynamicMacAddressEnabled
                isLegacy   = $n.IsLegacy
                vlan       = $null   # placeholder (light)
                ips        = @()     # placeholder (light)
            }
        }
    }
    catch {}
    return , $items
}
function Get-VM-DisksLight {
    param([string]$VmName)
    $items = @()
    try {
        $hdds = Get-VMHardDiskDrive -VMName $VmName
        foreach ($h in $hdds) {
            # 1) skip DVD / ISO
            if ($h.ControllerType -eq 'DVD' -or ($h.Path -and $h.Path.ToLower().EndsWith('.iso'))) { continue }

            # 2) skip si pas de chemin (rien à mesurer)
            if (-not $h.Path) { continue }

            $vhdLight = $null
            try { $vhdLight = Get-VHD-LightInfo -Path $h.Path } catch {}

            $items += [pscustomobject]@{
                controllerType   = "$($h.ControllerType)"
                controllerNumber = $h.ControllerNumber
                controllerSlot   = $h.ControllerLocation
                path             = $h.Path
                vhd              = $vhdLight  # sizeMB=null, fileSizeMB=réel (rapide)
            }
        }
    }
    catch {}
    return , $items
}



function Get-VMListLight {
    $list = @()
    try {
        $vms = Get-VM
        foreach ($v in $vms) {
            $nics = Get-VM-NICsLight  -VmName $v.Name
            $disks = Get-VM-DisksLight -VmName $v.Name

            $list += [pscustomobject]@{
                name             = $v.Name
                id               = "$($v.Id)"
                state            = "$($v.State)"
                generation       = $v.Generation
                uptimeSec        = [int]$v.Uptime.TotalSeconds
                cpuUsagePct      = [int]$v.CPUUsage
                memoryAssignedMB = _MB $v.MemoryAssigned
                automaticStart   = "$($v.AutomaticStartAction)"
                automaticStop    = "$($v.AutomaticStopAction)"
                configuration    = [pscustomobject]@{
                    memory        = $null      # pas de Get-VMMemory (light)
                    cpu           = $null      # pas de Get-VMProcessor (light)
                    firmware      = $null      # pas de Get-VMFirmware (light)
                    integrationSv = @()        # pas de Get-VMIntegrationService (light)
                    replication   = $null      # pas de Get-VMReplication (light)
                }
                networkAdapters  = $nics
                storage          = $disks
                checkpoints      = @()       # pas de Get-VMCheckpoint (light)
            }
        }
    }
    catch {}
    return , $list
}
function Get-VHD-LightInfo {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $fi = Get-Item -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        return $null
    }

    $ext = [System.IO.Path]::GetExtension($Path)
    $fmt = if ($ext -and $ext.TrimStart('.').ToUpperInvariant() -eq 'VHD') { 'VHD' } else { 'VHDX' }

    $fileSizeMB = _MB $fi.Length

    # IMPORTANT: on NE RENSEIGNE PAS sizeMB (provisionné) pour laisser le merge conserver la valeur du full
    return [pscustomobject]@{
        format             = $fmt
        type               = $null
        sizeMB             = $null          # <- on laisse vide pour que le merge garde l’ancienne valeur
        fileSizeMB         = $fileSizeMB    # <- utilisé (rapide)
        parentPath         = $null
        blockSize          = $null
        logicalSectorSize  = $null
        physicalSectorSize = $null
    }
}


# ===================== MAIN =====================
try {
    $Params = Read-ParamsJson -Inline $InputJson
    $ctx = $Params.__ctx

    $basePath = $null
    $datastores = $null
    if ($ctx) {
        if ($ctx.basePath) { $basePath = $ctx.basePath }
        if ($ctx.datastores) { $datastores = $ctx.datastores }
        if (-not $datastores -and $ctx.paths -and $ctx.paths.root) {
            $datastores = Build-DefaultDatastores -BasePath (Split-Path -Path $ctx.paths.root -Parent)
        }
    }
    if (-not $basePath -and $Params.basePath) { $basePath = $Params.basePath }
    if (-not $datastores -and $Params.datastores) { $datastores = $Params.datastores }
    if (-not $datastores -and $basePath) { $datastores = Build-DefaultDatastores -BasePath $basePath }
    if (-not $datastores) { $datastores = @() }

    # Inventaire (light)
    $hostInfo = Get-HostInfoLight
    $switches = Get-VSwitchesLight
    $adapters = Get-HostAdaptersLight
    Map-VSwitchToHostAdapters -switches $switches -hostAdapters $adapters
    $storage = Get-StorageInventoryLight
    $vms = Get-VMListLight

    $inventory = [pscustomobject]@{
        host        = $hostInfo
        networks    = [pscustomobject]@{
            switches     = $switches
            hostAdapters = $adapters
        }
        storage     = $storage
        vms         = $vms
        collectedAt = (Get-Date).ToUniversalTime().ToString("o")
    }

    # Datastores: capacité / libre (rapide)
    $dsOut = @()
    foreach ($ds in $datastores) {
        $p = [string]$ds.path
        if (-not $p) { continue }
        $u = Get-DriveUsage -Path $p
        $dsOut += [ordered]@{
            name       = $ds.name
            kind       = $ds.kind
            path       = $p
            drive      = $u.drive
            totalBytes = $u.totalBytes
            freeBytes  = $u.freeBytes
        }
    }
    [pscustomobject]@{
        inventory  = $inventory
        datastores = $dsOut
    } | ConvertTo-Json -Depth 12

    exit 0
}
catch {
    [pscustomobject]@{
        ok    = $false
        error = $_.Exception.Message
        where = $_.InvocationInfo.PositionMessage
    } | ConvertTo-Json -Depth 6
    exit 1
}
