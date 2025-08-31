# actions/vm.power.ps1 — format attendu sur STDIN:
# { "action":"vm.power", "data": { "__ctx":{...}, "guid":"...", "id":"...", "state":"start|off|...", "target": { "kind":"vm","agentId":"...","refId":"..." } } }

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# --- DEBUG dump du STDIN ---
$DbgDir = 'C:\ProgramData\openhvx\debug\vm.power'
try { New-Item -ItemType Directory -Force -Path $DbgDir | Out-Null } catch {}
$raw = [Console]::In.ReadToEnd()
$stamp = (Get-Date).ToString('yyyy-MM-dd_HH-mm-ss.fff')
try { Set-Content -LiteralPath (Join-Path $DbgDir "stdin_$stamp.json") -Value $raw -Encoding UTF8 -Force } catch {}

function Get-VmByIdOrName {
  param([Parameter(Mandatory = $true)][string]$IdOrName)
  $vm = $null
  try { $g = [guid]$IdOrName; $vm = Get-VM -Id $g -ErrorAction Stop } catch { }
  if (-not $vm) { $vm = Get-VM -Name $IdOrName -ErrorAction Stop }
  return $vm
}
function VmInfo {
  param([Parameter(Mandatory = $true)]$Vm)
  $memMB = 0; if ($Vm.MemoryAssigned -ne $null) { $memMB = [int]([math]::Round($Vm.MemoryAssigned / 1MB)) }
  [pscustomobject]@{
    name = $Vm.Name; id = "$($Vm.Id)"; state = "$($Vm.State)"; cpuUsagePct = [int]$Vm.CPUUsage
    memoryAssignedMB = $memMB; generation = $Vm.Generation; uptimeSec = [int]$Vm.Uptime.TotalSeconds
  }
}
function Normalize-State {
  param([Parameter(Mandatory = $true)][string]$s)
  switch ($s.ToLowerInvariant()) {
    'on' { 'start' } 'start' { 'start' } 'poweron' { 'start' }
    'off' { 'off' } 'poweroff' { 'off' }
    'shutdown' { 'shutdown' }
    'restart' { 'restart' } 'reboot' { 'restart' }
    'pause' { 'pause' } 'suspend' { 'pause' }
    'resume' { 'resume' }
    'save' { 'save' }
    default { throw "unsupported state '$s' (use: on|off|shutdown|restart|pause|resume|save)" }
  }
}

try {
  if ([string]::IsNullOrWhiteSpace($raw)) { throw "no input on STDIN" }
  $p = $raw | ConvertFrom-Json -ErrorAction Stop
  if ($p.action -ne 'vm.power' -or -not $p.data) { throw "invalid payload (need action=vm.power + data)" }
  $d = $p.data

  $idOrName = $d.guid; if (-not $idOrName) { $idOrName = $d.id }
  if (-not $idOrName) { $idOrName = $d.target.refId }
  if (-not $idOrName) { $idOrName = $d.target }   # legacy string
  if (-not $idOrName) { throw "missing VM reference (data.guid|data.id|data.target.refId)" }

  if (-not $d.state) { throw "missing data.state" }
  $state = Normalize-State $d.state

  $vm = Get-VmByIdOrName -IdOrName $idOrName
  $current = "$($vm.State)"

  switch ($state) {
    'start' { if ($current -ne 'Running') { Start-VM  -VM $vm -ErrorAction Stop | Out-Null } }
    'off' { if ($current -ne 'Off') { Stop-VM   -VM $vm -TurnOff -Force -ErrorAction Stop | Out-Null } }
    'shutdown' { if ($current -ne 'Off') { Stop-VM   -VM $vm -ErrorAction Stop | Out-Null } }  # gracieux si possible
    'restart' { Restart-VM -VM $vm -Force -ErrorAction Stop | Out-Null }
    'pause' { if ($current -eq 'Running') { Suspend-VM -VM $vm -ErrorAction Stop | Out-Null } }
    'resume' { if ($current -eq 'Paused' -or $current -eq 'Saved') { Resume-VM -VM $vm -ErrorAction Stop | Out-Null } }
    'save' { if ($current -ne 'Saved') { Save-VM   -VM $vm -ErrorAction Stop | Out-Null } }
  }

  $vmAfter = Get-VmByIdOrName -IdOrName $idOrName
  $result = [pscustomobject]@{
    ok = $true; action = 'vm.power'; requestedState = $state;
    target = (@{ kind = 'vm'; agentId = $d.target.agentId; refId = $d.target.refId })
    vm = (VmInfo -Vm $vmAfter)
    when = (Get-Date).ToUniversalTime().ToString('o')
  }
  # log out pour debug
  try { $result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $DbgDir "out_$stamp.json") -Encoding UTF8 -Force } catch {}
  $result | ConvertTo-Json -Depth 20 -Compress
  exit 0
}
catch {
  $msg = $_.Exception.Message
  try { Add-Content -LiteralPath (Join-Path $DbgDir "err_$stamp.log") -Value $msg } catch {}
  [pscustomobject]@{ ok = $false; error = $msg } | ConvertTo-Json -Compress
  exit 1
}