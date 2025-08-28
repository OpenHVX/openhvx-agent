# src/powershell/actions/vm.power.ps1
# Attend sur STDIN un JSON du type:
# { "action": "vm.power", "data": { "target": "VM1", "state": "on" } }

$ErrorActionPreference = 'Stop'

function Get-VmInfoJson {
  param([string]$Name)
  $vm = Get-VM -Name $Name -ErrorAction Stop
  [pscustomobject]@{
    name             = $vm.Name
    state            = "$($vm.State)"
    cpuUsagePct      = [int]$vm.CPUUsage
    memoryAssignedMB = [int]([math]::Round($vm.MemoryAssigned / 1MB))
    generation       = $vm.Generation
    uptimeSec        = [int]$vm.Uptime.TotalSeconds
  }
}

try {
  $raw = [Console]::In.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "no input"
  }

  $payload = $raw | ConvertFrom-Json -ErrorAction Stop
  $data = $payload.data
  if (-not $data) { throw "missing 'data' object" }
  $target = $data.target
  if (-not $target) { throw "missing 'data.target' (VM name)" }

  $state = ($data.state ? $data.state : "on").ToString().ToLowerInvariant()

  # État courant pour éviter les erreurs inutiles
  $vmBefore = Get-VM -Name $target -ErrorAction Stop
  $current = "$($vmBefore.State)"

  switch ($state) {
    'on' { 
      if ($current -ne 'Running') { Start-VM -Name $target -ErrorAction Stop | Out-Null }
    }
    'start' { 
      if ($current -ne 'Running') { Start-VM -Name $target -ErrorAction Stop | Out-Null }
    }
    'poweron' { 
      if ($current -ne 'Running') { Start-VM -Name $target -ErrorAction Stop | Out-Null }
    }
    'off' {
      # power off (coupure brutale)
      if ($current -ne 'Off') { Stop-VM -Name $target -TurnOff -Force -ErrorAction Stop | Out-Null }
    }
    'poweroff' {
      # alias off
      if ($current -ne 'Off') { Stop-VM -Name $target -TurnOff -Force -ErrorAction Stop | Out-Null }
    }
    'shutdown' {
      # arrêt "propre" si services d’intégration OK
      if ($current -ne 'Off') { Stop-VM -Name $target -Force -ErrorAction Stop | Out-Null }
    }
    'restart' { Restart-VM -Name $target -Force -ErrorAction Stop | Out-Null }
    'reboot' { Restart-VM -Name $target -Force -ErrorAction Stop | Out-Null }
    'pause' { Suspend-VM -Name $target -ErrorAction Stop | Out-Null }
    'suspend' { Suspend-VM -Name $target -ErrorAction Stop | Out-Null }
    'resume' { Resume-VM  -Name $target -ErrorAction Stop | Out-Null }
    'save' { Save-VM    -Name $target -ErrorAction Stop | Out-Null }
    default { throw "unsupported state '$state' (use: on/off/shutdown/restart/pause/resume/save)" }
  }

  # Retourne l’état post-opération
  $info = Get-VmInfoJson -Name $target
  $result = [pscustomobject]@{
    action         = 'vm.power'
    target         = $target
    requestedState = $state
    vm             = $info
    when           = (Get-Date).ToUniversalTime().ToString('o')
  }
  $result | ConvertTo-Json -Depth 20 -Compress
  exit 0
}
catch {
  $err = [pscustomobject]@{
    ok    = $false
    error = $_.Exception.Message
  }
  $err | ConvertTo-Json -Compress
  exit 1
}
