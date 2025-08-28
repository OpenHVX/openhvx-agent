# powershell/actions/inventory.refresh.ps1
# Sortie: objet JSON "inventory" complet (STDOUT)
# Dépendances: Module Hyper-V, NetAdapter/NetTCPIP, Storage

$ErrorActionPreference = 'Stop'

function _MB($bytes) {
  if ($null -eq $bytes) { return $null }
  return [int]([math]::Round($bytes / 1MB))
}

function Get-HostInfo {
  try {
    $ci = Get-ComputerInfo
  }
  catch { $ci = $null }

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
      try {
        $dns = (Get-DnsClientServerAddress -InterfaceIndex $ifx.ifIndex -ErrorAction Stop).ServerAddresses
      }
      catch {}
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
      # Uplink(s) physiques pour switch "External"
      if ($sw.SwitchType -eq 'External') {
        try {
          $uplinks = (Get-VMSwitch -Name $sw.Name).NetAdapterInterfaceDescriptions
        }
        catch {}
      }
      $ext = @()
      try {
        $ext = Get-VMSwitchExtension -VMSwitchName $sw.Name | Select-Object Name, Vendor, ExtensionType, Enabled
      }
      catch {}

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

function Get-StorageInventory {
  $disks = @()
  $vols = @()
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

function Get-VM-NICs {
  param([string]$VmName)
  $items = @()
  try {
    $nics = Get-VMNetworkAdapter -VMName $VmName -ErrorAction Stop
    foreach ($n in $nics) {
      # VLAN
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

      # IPs (si IC + VM up)
      $ips = @()
      try { $ips = $n.IPAddresses } catch {}

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
      try {
        if ($h.Path) { $vhd = Get-VHD -Path $h.Path }
      }
      catch {}
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
        try {
          $bootOrder = $f.BootOrder | ForEach-Object { $_.Device | ForEach-Object { $_.ToString() } }
        }
        catch {}
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

      $checkpoints = @()
      try {
        $checkpoints = Get-VMCheckpoint -VM $v | Select-Object -Property SnapshotType, Name, CreationTime
      }
      catch {}

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
        checkpoints      = $checkpoints
      }
    }
  }
  catch {}
  return , $list
}

# --- Lier les vSwitch externes aux NICs hôte (switchName sur hostAdapters) ---
function Map-VSwitchToHostAdapters {
  param($switches, $hostAdapters)
  foreach ($sw in $switches) {
    if ($sw.type -eq 'External' -and $sw.uplinks) {
      foreach ($upl in $sw.uplinks) {
        # on matche par description d'interface (approx)
        $match = $hostAdapters | Where-Object { $_.interface -eq $upl }
        foreach ($m in $match) { $m.switchName = $sw.name }
      }
    }
  }
}

# --- MAIN ---
try {
  # on lit l'entrée (pour compat) mais on ne s'en sert pas
  $null = [Console]::In.ReadToEnd()

  $hostInfo = Get-HostInfo
  $switches = Get-VSwitches
  $adapters = Get-HostAdapters
  Map-VSwitchToHostAdapters -switches $switches -hostAdapters $adapters
  $storage = Get-StorageInventory
  $vms = Get-VMList

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

  $inventory | ConvertTo-Json -Depth 12 -Compress
  exit 0
}
catch {
  # En cas d'erreur globale, on remonte un objet de diagnostic
  [pscustomobject]@{
    error = $_.Exception.Message
    where = $_.InvocationInfo.PositionMessage
  } | ConvertTo-Json -Compress
  exit 1
}
