# powershell/actions/vm.edit.ps1
# Update an existing Hyper-V VM configuration.
# - Supports: CPU, memory (static/dynamic, min/max), Secure Boot (Gen2), vSwitch, COM1 (named pipe), and optional rename.
# - Handles power state safely: stops the VM if required for a change, then restores the previous state.
# Input  : JSON via -InputJson or STDIN. Supports an envelope { action, data:{...} }.
#          Required: { name: "currentName", ... }
#          Optional rename: { new_name: "newName" }  (works online; no stop required)
# Output :
#   Success -> { vm:{...}, notes:[...] }
#   Error   -> writes to STDERR and exits 1

param(
    [string]$InputJson
)

# --- IMPORTANT: no useless STDOUT ---
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'

$notes = New-Object System.Collections.Generic.List[string]

# ---------- Helpers (JSON) ----------
function Read-TaskInput {
    param([string]$Inline)
    if ($Inline) { try { return ($Inline | ConvertFrom-Json -ErrorAction Stop) } catch {} }
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "No JSON input (use -InputJson or pipe JSON to STDIN)" }
    try { return ($raw | ConvertFrom-Json -ErrorAction Stop) } catch { throw "Invalid JSON input" }
}

# ---------- Helpers (sizes) ----------
function Resolve-SizeBytes {
    param([Parameter(Mandatory = $true)][object]$InputValue)
    if ($null -eq $InputValue) { return $null }
    if ($InputValue -is [int] -or $InputValue -is [long]) {
        if ($InputValue -le 131072) { return [int64]$InputValue * 1MB } return [int64]$InputValue
    }
    $s = "$InputValue".Trim().ToUpper()
    if ($s -match '^\d+$') {
        $n = [int64]$s
        if ($n -le 131072) { return $n * 1MB } else { return $n }
    }
    if ($s -match '^(\d+(?:\.\d+)?)(B|KB|MB|GB|TB)$') {
        $num = [double]$Matches[1]
        switch ($Matches[2]) {
            'B' { return [int64]$num }
            'KB' { return [int64]($num * 1KB) }
            'MB' { return [int64]($num * 1MB) }
            'GB' { return [int64]($num * 1GB) }
            'TB' { return [int64]($num * 1TB) }
        }
    }
    throw "invalid size: '$InputValue'"
}

# ---------- Helpers (power/stop decision) ----------
function Get-NeedsStop {
    param(
        [Microsoft.HyperV.PowerShell.VirtualMachine]$VM,
        [hashtable]$Desired
    )
    # Conservative, safe rules:
    # - CPU change -> STOP
    # - Secure Boot (Gen2) change -> STOP
    # - Switching static/dynamic memory mode -> STOP
    # - Static startup RAM change (when dynamic off) -> STOP
    # - min/max when not in dynamic mode -> STOP (conservative)
    $needStop = $false

    if ($Desired.ContainsKey('cpu') -and $null -ne $Desired.cpu) {
        if ($Desired.cpu -ne $VM.ProcessorCount) { $needStop = $true }
    }

    if ($VM.Generation -eq 2 -and $Desired.ContainsKey('secure_boot')) {
        $currentSb = (Get-VMFirmware -VM $VM).SecureBoot
        $targetSb = [bool]$Desired.secure_boot
        if (($targetSb -and $currentSb -ne 'On') -or ((-not $targetSb) -and $currentSb -ne 'Off')) {
            $needStop = $true
        }
    }

    if ($Desired.ContainsKey('dynamic_memory')) {
        $targetDyn = [bool]$Desired.dynamic_memory
        if ($targetDyn -ne $VM.DynamicMemoryEnabled) { $needStop = $true }
    }

    if ($Desired.ContainsKey('ram') -and $null -ne $Desired.ram) {
        $targetStartup = Resolve-SizeBytes $Desired.ram
        if (-not $VM.DynamicMemoryEnabled) {
            if ($targetStartup -ne $VM.MemoryStartup) { $needStop = $true }
        }
        # In dynamic mode, a startup change can often be tolerated live -> keep conservative: no forced stop here.
    }

    if ($Desired.ContainsKey('min_ram') -or $Desired.ContainsKey('max_ram')) {
        if (-not $VM.DynamicMemoryEnabled) {
            $needStop = $true
        }
    }

    return $needStop
}

# ---------- MAIN ----------
try {
    $task = Read-TaskInput -Inline $InputJson
    $d = if ($task.PSObject.Properties.Name -contains 'data' -and $task.data) { $task.data } else { $task }

    if ([string]::IsNullOrWhiteSpace($d.name)) { throw "missing 'name'" }
    $Name = $d.name.Trim()

    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) { throw "VM '$Name' not found" }

    # ----- Optional rename (works online) -----
    # UI/API convention: send { name:"oldName", new_name:"newName" } if renaming.
    if ($d.PSObject.Properties.Name -contains 'new_name' -and -not [string]::IsNullOrWhiteSpace($d.new_name)) {
        $NewName = $d.new_name.Trim()
        if ($NewName -ne $Name) {
            if (Get-VM -Name $NewName -ErrorAction SilentlyContinue) {
                throw "a VM named '$NewName' already exists"
            }
            Rename-VM -VM $vm -NewName $NewName -ErrorAction Stop
            $notes.Add("VM renamed: '$Name' -> '$NewName'") | Out-Null
            # refresh handles and continue with the new name
            $Name = $NewName
            $vm = Get-VM -Name $Name -ErrorAction Stop
        }
    }

    # ----- Desired state collection (only keys provided are considered) -----
    $desired = @{}
    if ($d.PSObject.Properties.Name -contains 'cpu') { $desired['cpu'] = if ($null -ne $d.cpu) { [int]$d.cpu } else { $null } }
    if ($d.PSObject.Properties.Name -contains 'ram') { $desired['ram'] = $d.ram }
    if ($d.PSObject.Properties.Name -contains 'dynamic_memory') { $desired['dynamic_memory'] = [bool]$d.dynamic_memory }
    if ($d.PSObject.Properties.Name -contains 'min_ram') { $desired['min_ram'] = $d.min_ram }
    if ($d.PSObject.Properties.Name -contains 'max_ram') { $desired['max_ram'] = $d.max_ram }
    if ($d.PSObject.Properties.Name -contains 'secure_boot') { $desired['secure_boot'] = [bool]$d.secure_boot }
    if ($d.PSObject.Properties.Name -contains 'switch') { $desired['switch'] = $d.switch }
    if ($d.PSObject.Properties.Name -contains 'serial' -and $d.serial -and $d.serial.com1 -and $d.serial.com1.path) {
        $desired['com1_path'] = "$($d.serial.com1.path)".Trim()
    }

    # Determine if a stop is required, remember previous state
    $needStop = Get-NeedsStop -VM $vm -Desired $desired
    $wasRunning = $vm.State -eq 'Running'
    if ($needStop -and $wasRunning) {
        Stop-VM -VM $vm -Force -TurnOff:$false -ErrorAction Stop | Out-Null
        $notes.Add("VM stopped to apply changes requiring power-off") | Out-Null
        $vm = Get-VM -Name $Name
    }

    # ----- CPU -----
    if ($desired.ContainsKey('cpu') -and $null -ne $desired.cpu) {
        if ($desired.cpu -lt 1) { throw "invalid 'cpu' (<1)" }
        if ($desired.cpu -ne $vm.ProcessorCount) {
            Set-VM -VM $vm -ProcessorCount $desired.cpu -ErrorAction Stop | Out-Null
            $notes.Add("CPU set to $($desired.cpu)") | Out-Null
        }
    }

    # ----- Memory (static / dynamic) -----
    $memChanged = $false
    $startupBytes = $null; $minBytes = $null; $maxBytes = $null
    $wantDyn = $vm.DynamicMemoryEnabled

    if ($desired.ContainsKey('dynamic_memory')) {
        $wantDyn = [bool]$desired.dynamic_memory
    }

    if ($desired.ContainsKey('ram') -and $null -ne $desired.ram) {
        $startupBytes = Resolve-SizeBytes $desired.ram
    }
    else {
        $startupBytes = $vm.MemoryStartup
    }

    if ($desired.ContainsKey('min_ram') -and $null -ne $desired.min_ram) {
        $minBytes = Resolve-SizeBytes $desired.min_ram
    }
    else {
        $minBytes = if ($vm.MinimumMemory) { [int64]$vm.MinimumMemory } else { $null }
    }

    if ($desired.ContainsKey('max_ram') -and $null -ne $desired.max_ram) {
        $maxBytes = Resolve-SizeBytes $desired.max_ram
    }
    else {
        $maxBytes = if ($vm.MaximumMemory) { [int64]$vm.MaximumMemory } else { $null }
    }

    if ($wantDyn) {
        if (-not $minBytes) { $minBytes = [int64]([math]::Max(512MB, [math]::Floor($startupBytes * 0.5))) }
        if (-not $maxBytes) { $maxBytes = [int64]([math]::Max($startupBytes, 2GB)) }
        if ($minBytes -gt $startupBytes) { $tmp = $minBytes; $minBytes = $startupBytes; $startupBytes = $tmp }
        if ($maxBytes -lt $startupBytes) { $maxBytes = $startupBytes }

        if ($vm.DynamicMemoryEnabled -ne $true `
                -or $vm.MemoryStartup -ne $startupBytes `
                -or $vm.MinimumMemory -ne $minBytes `
                -or $vm.MaximumMemory -ne $maxBytes) {
            Set-VMMemory -VM $vm -DynamicMemoryEnabled $true -MinimumBytes $minBytes -MaximumBytes $maxBytes -StartupBytes $startupBytes -ErrorAction Stop | Out-Null
            $memChanged = $true
        }
    }
    else {
        # Static memory
        if ($vm.DynamicMemoryEnabled -ne $false -or $vm.MemoryStartup -ne $startupBytes) {
            Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -StartupBytes $startupBytes -ErrorAction Stop | Out-Null
            $memChanged = $true
        }
    }

    if ($memChanged) {
        $mode = if ($wantDyn) { "dynamic (min=$minBytes max=$maxBytes start=$startupBytes)" } else { "static (startup=$startupBytes)" }
        $notes.Add("Memory updated: $mode") | Out-Null
    }

    # ----- Secure Boot (Gen2) -----
    if ($vm.Generation -eq 2 -and $desired.ContainsKey('secure_boot')) {
        $firm = Get-VMFirmware -VM $vm
        $target = if ($desired.secure_boot) { 'On' } else { 'Off' }
        if ($firm.SecureBoot -ne $target) {
            if ($target -eq 'On') {
                Set-VMFirmware -VM $vm -EnableSecureBoot On  -SecureBootTemplate "MicrosoftUEFICertificateAuthority" | Out-Null
            }
            else {
                Set-VMFirmware -VM $vm -EnableSecureBoot Off | Out-Null
            }
            $notes.Add("Secure Boot set to $target") | Out-Null
        }
    }

    # ----- Network: connect (or re-connect) to vSwitch -----
    if ($desired.ContainsKey('switch') -and $desired.switch) {
        $nic = Get-VMNetworkAdapter -VMName $Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $nic) {
            $null = Add-VMNetworkAdapter -VMName $Name -Name "net0" -SwitchName $desired.switch -ErrorAction Stop
            $notes.Add("Network adapter created and connected to switch '$($desired.switch)'") | Out-Null
        }
        else {
            if ($nic.SwitchName -ne $desired.switch) {
                Connect-VMNetworkAdapter -VMName $Name -Name $nic.Name -SwitchName $desired.switch -ErrorAction Stop
                $notes.Add("Network adapter '$($nic.Name)' connected to switch '$($desired.switch)'") | Out-Null
            }
        }
    }

    # ----- COM1 Named Pipe (optional) -----
    if ($desired.ContainsKey('com1_path') -and $desired.com1_path) {
        Set-VMComPort -VMName $Name -Number 1 -Path $desired.com1_path | Out-Null
        $notes.Add("COM1 named pipe set: $($desired.com1_path)") | Out-Null
    }

    # Restore power state if we had to stop
    if ($needStop -and $wasRunning) {
        Start-VM -VM $vm | Out-Null
        $notes.Add("VM restarted") | Out-Null
    }

    # ----- Output object (aligned with vm.create.ps1 style) -----
    $vm = Get-VM -Name $Name
    $firm = if ($vm.Generation -eq 2) { Get-VMFirmware -VM $vm } else { $null }
    $nic = Get-VMNetworkAdapter -VMName $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    $com1 = (Get-VMComPort -VMName $Name -Number 1 -ErrorAction SilentlyContinue)

    $vmObj = @{
        name       = $vm.Name
        id         = "$($vm.Id)"
        guid       = "$($vm.Id)"
        generation = $vm.Generation
        path       = $vm.Path
        state      = "$($vm.State)"
        cpu        = $vm.ProcessorCount
        memory     = @{
            startup = [int64]$vm.MemoryStartup
            dynamic = [bool]$vm.DynamicMemoryEnabled
            min     = if ($vm.DynamicMemoryEnabled) { [int64]$vm.MinimumMemory } else { $null }
            max     = if ($vm.DynamicMemoryEnabled) { [int64]$vm.MaximumMemory } else { $null }
        }
        network    = if ($nic) { $nic.SwitchName } else { $null }
        firmware   = @{
            secureBoot = if ($vm.Generation -eq 2) { if ($firm.SecureBoot -eq 'On') { $true } else { $false } } else { $null }
        }
        serial     = @{
            com1 = @{
                path = if ($com1) { $com1.Path } else { $null }
            }
        }
    }

    $payload = @{ vm = $vmObj }
    if ($notes.Count -gt 0) { $payload.notes = $notes }

    $payload | ConvertTo-Json -Depth 10
    exit 0
}
catch {
    $errMsg = $_.Exception.Message
    Write-Error $errMsg
    exit 1
}
