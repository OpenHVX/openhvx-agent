# powershell/actions/inventory.refresh.ps1
# Sortie: objet JSON { ok, result, error }
# - result.inventory.inventory  : inventaire Hyper-V (host, réseaux, stockage, VMs)
# - result.inventory.datastores : tableau des "datastores" (path -> drive, totalBytes, freeBytes)
# - result.inventory.images     : catalogue d'images (fourni par l'agent)
# Paramètres d'entrée (via -InputJson ou STDIN):
# 1) Nouveau (préféré, injecté par l'agent pour les tâches):
# {
#   "__ctx": {
#     "agentId": "HOST-XXX",
#     "tenantId": "TEN-123",
#     "basePath": "C:\\Hyper-V",
#     "paths": { "root":"C:\\Hyper-V\\openhvx", "vms":"...", "vhd":"...", "isos":"...", "checkpoints":"...", "logs":"...", "trash":"..." },
#     "datastores": [ {"name":"OpenHVX VMS","kind":"vm","path":"C:\\Hyper-V\\openhvx\\VMS"}, ... ],
#     "images": [ { "id":"...", "filename":"...", "path":"...", "sizeBytes":123, "mtime":"...", "osGuess":"...", "archGuess":"x86_64", "gen":2, "readOnly":true } ]
#   }
#   // + éventuels autres champs spécifiques
# }
# 2) Ancien (fallback pour l'inventaire périodique):
# {
#   "basePath": "C:\\Hyper-V",
#   "datastores": [ ... ],
#   "images": [ ... ]   // optionnel
# }

param(
  [string]$InputJson
)

$ErrorActionPreference = 'Stop'

# ===================== Helpers entrée JSON (arg ou STDIN) =====================
function Read-ParamsJson {
  param([string]$Inline)

  if ($Inline) {
    try { return ($Inline | ConvertFrom-Json -ErrorAction Stop) } catch {}
  }

  # Lecture STDIN (si l'agent envoie le JSON via STDIN)
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
  if (-not $Path) {
    return @{ drive = $null; totalBytes = 0; freeBytes = 0 }
  }

  $drive = $null
  try { $drive = [System.IO.Path]::GetPathRoot($Path) } catch {}
  if (-not $drive) {
    try { $drive = (Split-Path -Path $Path -Qualifier) } catch {}
  }

  try {
    $di = New-Object System.IO.DriveInfo ($drive)
    return @{
      drive      = $drive
      totalBytes = [uint64]$di.TotalSize
      freeBytes  = [uint64]$di.AvailableFreeSpace
    }
  }
  catch {
    # UNC / contextes restreints : renvoie 0 plutôt que d'échouer
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

# ===================== Collecte HOST =====================
function Get-HostInfo {
  try { $ci = Get-ComputerInfo } catch { $ci = $null }

  $cpu = $null
  try {
    $cpuCi = Get-CimInstance Win32_Processor | Select-Object -First 1
    if ($cpuCi) {
      $cpu = [pscustomobject]@{
        name              = $cpuCi.Name
        cores             = $cpuCi.NumberOfCores
        logicalProcessors = $cpuCi.NumberOfLogicalProcessors
        maxClockMHz       = $cpuCi.MaxClockSpeed
      }
    }
  }
  catch {}

  $hv = $null
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
    hostname   = $ci.CsName
    os         = $ci.OsName
    osVersion  = $ci.OsVersion
    memMB      = if ($ci) { [int]([math]::Round($ci.CsTotalPhysicalMemory / 1MB)) } else { $null }
    domain     = $env:USERDOMAIN
    cpu        = $cpu
    hypervHost = $hv
  }
}

# ===================== Réseau / vSwitch =====================
function Get-HostAdapters {
  $adapters = @()
  try {
    $adapters = Get-NetAdapter | Sort-Object -Property ifIndex | ForEach-Object {
      $ifx = $_
      $ips = @()
      try {
        $ips = Get-NetIPAddress -InterfaceIndex $ifx.ifIndex -ErrorAction Stop | ForEach-Object {
          [pscustomobject]@{
            address   = $_.IPAddress
            prefixLen = $_.PrefixLength
            family    = "$($_.AddressFamily)"
          }
        }
      }
      catch {}
      $dns = @()
      try { $dns = (Get-DnsClientServerAddress -InterfaceIndex $ifx.ifIndex -ErrorAction Stop).ServerAddresses } catch {}
      [pscustomobject]@{
        name       = $ifx.Name
        interface  = $ifx.InterfaceDescription
        mac        = $ifx.MacAddress
        status     = "$($ifx.Status)"
        linkSpeed  = [string]$ifx.LinkSpeed
        switchName = $null  # rempli via mapping vSwitch plus bas si externe
        ip         = $ips
        dns        = $dns
      }
    }
  }
  catch {}
  return , $adapters
}

function Get-VSwitches {
  $switches = @()
  try {
    $switches = Get-VMSwitch | ForEach-Object {
      $sw = $_
      $uplinks = @()
      if ($sw.SwitchType -eq 'External') {
        try { $uplinks = (Get-VMSwitch -Name $sw.Name).NetAdapterInterfaceDescriptions } catch {}
      }
      $ext = @()
      try { $ext = Get-VMSwitchExtension -VMSwitchName $sw.Name | Select-Object Name, Vendor, ExtensionType, Enabled } catch {}

      [pscustomobject]@{
        name          = $sw.Name
        type          = "$($sw.SwitchType)"     # External/Internal/Private
        notes         = $sw.Notes
        uplinks       = $uplinks
        bandwidthMode = $sw.BandwidthReservationMode
        allowMacSpoof = $sw.AllowMacSpoofing
        extensions    = $ext
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

# ===================== Stockage hôte =====================
function Get-StorageInventory {
  $disks = @(); $vols = @()
  try {
    $disks = Get-Disk | ForEach-Object {
      [pscustomobject]@{
        number         = $_.Number
        friendly       = $_.FriendlyName
        sizeMB         = _MB $_.Size
        busType        = "$($_.BusType)"
        isSystem       = $_.IsSystem
        isBoot         = $_.IsBoot
        isReadOnly     = $_.IsReadOnly
        health         = "$($_.HealthStatus)"
        partitionStyle = "$($_.PartitionStyle)"
      }
    }
  }
  catch {}
  try {
    $vols = Get-Volume | ForEach-Object {
      [pscustomobject]@{
        drive  = $_.DriveLetter
        label  = $_.FileSystemLabel
        fs     = $_.FileSystem
        sizeMB = _MB $_.Size
        freeMB = _MB $_.SizeRemaining
        health = "$($_.HealthStatus)"
        path   = $_.Path
      }
    }
  }
  catch {}
  [pscustomobject]@{
    disks   = $disks
    volumes = $vols
  }
}

# ===================== VMs =====================
function Get-VM-NICs {
  param([string]$VmName)
  $items = @()
  try {
    $nics = Get-VMNetworkAdapter -VMName $VmName -ErrorAction Stop
    foreach ($n in $nics) {
      $vlanObj = $null
      try {
        $vlan = Get-VMNetworkAdapterVlan -VMNetworkAdapter $n
        if ($vlan) {
          if ($vlan.OperationMode -eq 'Access') {
            $vlanObj = [pscustomobject]@{ mode = 'Access'; vlanId = $vlan.AccessVlanId }
          }
          elseif ($vlan.OperationMode -eq 'Trunk') {
            $vlanObj = [pscustomobject]@{
              mode       = 'Trunk'
              nativeVlan = $vlan.NativeVlanId
              trunkVlans = $vlan.AllowedVlanIdList
            }
          }
          else {
            $vlanObj = [pscustomobject]@{ mode = "$($vlan.OperationMode)" }
          }
        }
      }
      catch {}
      $ips = @(); try { $ips = $n.IPAddresses } catch {}
      $items += [pscustomobject]@{
        name       = $n.Name
        switch     = $n.SwitchName
        mac        = $n.MacAddress
        dynamicMac = $n.DynamicMacAddressEnabled
        isLegacy   = $n.IsLegacy
        vlan       = $vlanObj
        ips        = $ips
      }
    }
  }
  catch {}
  return , $items
}

function Get-VM-Disks {
  param([string]$VmName)
  $items = @()
  try {
    $hdds = Get-VMHardDiskDrive -VMName $VmName
    foreach ($h in $hdds) {
      $vhd = $null
      try { if ($h.Path) { $vhd = Get-VHD -Path $h.Path } } catch {}
      $items += [pscustomobject]@{
        controllerType   = "$($h.ControllerType)"     # IDE/SCSI
        controllerNumber = $h.ControllerNumber
        controllerSlot   = $h.ControllerLocation
        path             = $h.Path
        vhd              = if ($vhd) {
          [pscustomobject]@{
            format             = "$($vhd.VhdFormat)"         # VHD/VHDX
            type               = "$($vhd.VhdType)"           # Fixed/Dynamic/Differencing
            sizeMB             = _MB $vhd.Size
            fileSizeMB         = _MB $vhd.FileSize
            parentPath         = $vhd.ParentPath
            blockSize          = $vhd.BlockSize
            logicalSectorSize  = $vhd.LogicalSectorSize
            physicalSectorSize = $vhd.PhysicalSectorSize
          }
        }
        else { $null }
      }
    }
  }
  catch {}
  return , $items
}

function Get-VM-Config {
  param([string]$VmName, [int]$Generation)
  $mem = $null; $cpu = $null; $fw = $null; $integrations = @(); $repl = $null

  try {
    $mm = Get-VMMemory -VMName $VmName
    if ($mm) {
      $mem = [pscustomobject]@{
        dynamicEnabled = $mm.DynamicMemoryEnabled
        startupMB      = _MB $mm.Startup
        minMB          = _MB $mm.Minimum
        maxMB          = _MB $mm.Maximum
        priority       = $mm.Priority
        bufferPct      = $mm.Buffer
      }
    }
  }
  catch {}

  try {
    $pr = Get-VMProcessor -VMName $VmName
    if ($pr) {
      $cpu = [pscustomobject]@{
        count                          = $pr.Count
        compatibilityForOlder          = $pr.CompatibilityForOlderOperatingSystemsEnabled
        hwThreadsPerCore               = $pr.HWThreadCountPerCore
        reserve                        = $pr.Reserve
        limit                          = $pr.Limit
        relativeWeight                 = $pr.RelativeWeight
        exposeVirtualizationExtensions = $pr.ExposeVirtualizationExtensions
      }
    }
  }
  catch {}

  try {
    if ($Generation -eq 2) {
      $f = Get-VMFirmware -VMName $VmName
      if ($f) {
        $bootOrder = @()
        try { $bootOrder = $f.BootOrder | ForEach-Object { $_.Device | ForEach-Object { $_.ToString() } } } catch {}
        $fw = [pscustomobject]@{
          secureBootEnabled            = $f.SecureBoot
          secureBootTemplate           = $f.SecureBootTemplate
          bootOrder                    = $bootOrder
          preferredNetworkBootProtocol = $f.PreferredNetworkBootProtocol
          consoleMode                  = $f.ConsoleMode
        }
      }
    }
  }
  catch {}

  try {
    $integrations = Get-VMIntegrationService -VMName $VmName | ForEach-Object {
      [pscustomobject]@{
        name    = $_.Name
        enabled = $_.Enabled
        status  = $_.PrimaryStatusDescription
        version = $_.Version
      }
    }
  }
  catch {}

  try {
    $repl = Get-VMReplication -VMName $VmName -ErrorAction Stop
    if ($repl) {
      $repl = [pscustomobject]@{
        mode    = "$($repl.Mode)"
        state   = "$($repl.State)"
        health  = "$($repl.Health)"
        primary = $repl.PrimaryServer
        replica = $repl.ReplicaServer
      }
    }
  }
  catch { $repl = $null }

  [pscustomobject]@{
    memory        = $mem
    cpu           = $cpu
    firmware      = $fw
    integrationSv = $integrations
    replication   = $repl
  }
}

function Get-VMList {
  $list = @()
  try {
    $vms = Get-VM
    foreach ($v in $vms) {
      $nics = Get-VM-NICs  -VmName $v.Name
      $disks = Get-VM-Disks -VmName $v.Name
      $cfg = Get-VM-Config -VmName $v.Name -Generation $v.Generation

      $checks = @()
      try { $checks = Get-VMCheckpoint -VM $v | Select-Object -Property SnapshotType, Name, CreationTime } catch {}

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
        configuration    = $cfg
        networkAdapters  = $nics
        storage          = $disks
        checkpoints      = $checks
      }
    }
  }
  catch {}
  return , $list
}

# ===================== MAIN =====================
try {
  # 1) Lire les paramètres (arg ou STDIN) + extraire le contexte
  $Params = Read-ParamsJson -Inline $InputJson
  $ctx = $Params.__ctx

  # Préférence: __ctx (injecté par l'agent pour les tasks)
  $basePath = $null
  $datastores = $null
  $imagesIn = @()

  if ($ctx) {
    if ($ctx.basePath) { $basePath = $ctx.basePath }
    if ($ctx.datastores) { $datastores = $ctx.datastores }
    if ($ctx.images) { $imagesIn = $ctx.images }
    # si pas de datastores mais des paths normés, on peut reconstruire un défaut
    if (-not $datastores -and $ctx.paths -and $ctx.paths.root) {
      $datastores = Build-DefaultDatastores -BasePath (Split-Path -Path $ctx.paths.root -Parent)
    }
  }

  # Fallback compat (inventaire périodique appelle encore basePath/datastores/images)
  if (-not $basePath -and $Params.basePath) { $basePath = $Params.basePath }
  if (-not $datastores -and $Params.datastores) { $datastores = $Params.datastores }
  if ($Params.images) { $imagesIn = $Params.images }

  if (-not $datastores -and $basePath) { $datastores = Build-DefaultDatastores -BasePath $basePath }
  if (-not $datastores) { $datastores = @() }
  if (-not $imagesIn) { $imagesIn = @() }

  # 2) Inventaire Hyper-V (branche "inventory.inventory")
  $hostInfo = Get-HostInfo
  $switches = Get-VSwitches
  $adapters = Get-HostAdapters
  Map-VSwitchToHostAdapters -switches $switches -hostAdapters $adapters
  $storage = Get-StorageInventory
  $vms = Get-VMList

  $inventoryStruct = [pscustomobject]@{
    host        = $hostInfo
    networks    = [pscustomobject]@{
      switches     = $switches
      hostAdapters = $adapters
    }
    storage     = $storage
    vms         = $vms
    collectedAt = (Get-Date).ToUniversalTime().ToString("o")
  }

  # 3) Datastores -> capacité/ libre (branche "inventory.datastores")
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
  # 4) Sortie finale { ok, result, error }
  #    IMPORTANT: on regroupe sous result.inventory.{ inventory, datastores, images }
  [pscustomobject]@{
    inventory  = $inventoryStruct
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
