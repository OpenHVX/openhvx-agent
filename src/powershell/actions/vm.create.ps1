# powershell/actions/vm.create.ps1
# Crée une VM Hyper-V depuis une image VHDX cloud + seed cloud-init (CIDATA).
# Ajoute la configuration COM1 (Named Pipe) et prépare cloud-init pour la console série.
# Entrée: JSON via -InputJson ou STDIN. Supporte l’enveloppe { action, data:{...} }.
# Sortie:
#   Succès -> { ok:true, result:{ vm:{...} }, notes?:[...] }
#   Échec  -> { ok:false, result:null, error:"...", detail:"stack..." }

param(
    [string]$InputJson
)

# --- IMPORTANT: no useless STDOUT ---
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'

$notes = New-Object System.Collections.Generic.List[string]

# ---------- Helpers JSON ----------
function Read-TaskInput {
    param([string]$Inline)
    if ($Inline) { try { return ($Inline | ConvertFrom-Json -ErrorAction Stop) } catch {} }
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "No JSON input (use -InputJson or pipe JSON to STDIN)" }
    try { return ($raw | ConvertFrom-Json -ErrorAction Stop) } catch { throw "Invalid JSON input" }
}

# ---------- Helpers size ----------
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

# ---------- Helpers path ----------
function Get-FullPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    return [System.IO.Path]::GetFullPath($p)
}
function Assert-UnderRoot {
    param([string]$Candidate, [string]$Root)
    if (-not $Root) { return }
    $c = Get-FullPath $Candidate
    $r = Get-FullPath $Root
    if (-not $c -or -not $r) { throw "invalid path check" }
    if ($c.Length -lt $r.Length -or ($c.Substring(0, $r.Length)).ToLower() -ne $r.ToLower()) {
        throw "unsafe path outside managed root: $Candidate (root=$Root)"
    }
}
function Get-UniquePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    $file = [System.IO.Path]::GetFileName($Path)
    $ext = [System.IO.Path]::GetExtension($file)
    $name = if ($ext) { $file.Substring(0, $file.Length - $ext.Length) } else { $file }
    for ($i = 1; $i -le 9999; $i++) {
        $cand = if ($ext) { Join-Path $dir "$name ($i)$ext" } else { Join-Path $dir "$name ($i)" }
        if (-not (Test-Path -LiteralPath $cand)) { return $cand }
    }
    $stamp = (Get-Date -Format "yyyyMMdd-HHmmssfff")
    return if ($ext) { Join-Path $dir "$name-$stamp$ext" } else { Join-Path $dir "$name-$stamp" }
}
function Ensure-Dir([string]$p) {
    if ($p -and -not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

# ---------- Helpers cloud-init (files) ----------
function New-CloudInitFiles($dir, $Name, $CI) {
    Ensure-Dir $dir

    $userdata = @("#cloud-config")
    $hostname = $Name
    if ($CI -and $CI.PSObject.Properties.Name -contains 'hostname' -and $CI.hostname) {
        $hostname = $CI.hostname
    }
    $userdata += "hostname: $hostname"
    $userdata += "datasource_list: [ NoCloud ]"

    # users / ssh keys
    if ($CI -and $CI.user) {
        $userdata += "users:"
        $userdata += "  - name: $($CI.user)"
        $userdata += "    sudo: ALL=(ALL) NOPASSWD:ALL"
        $userdata += "    groups: users, admin"
        $userdata += "    shell: /bin/bash"
        if ($CI.ssh_authorized_keys) {
            $userdata += "    ssh_authorized_keys:"
            $userdata += ($CI.ssh_authorized_keys | ForEach-Object { "      - $_" })
        }
    }
    elseif ($CI -and $CI.ssh_authorized_keys) {
        $userdata += "ssh_authorized_keys:"
        $userdata += ($CI.ssh_authorized_keys | ForEach-Object { "  - $_" })
    }

    if ($CI -and $CI.packages) {
        $userdata += "packages:"
        $userdata += ($CI.packages | ForEach-Object { "  - $_" })
    }

    # runcmd (utilisateur)
    $addedRuncmdHeader = $false
    if ($CI -and $CI.runcmd) {
        $userdata += "runcmd:"
        $addedRuncmdHeader = $true
        $userdata += ($CI.runcmd | ForEach-Object { "  - $_" })
    }

    # ----- Activer console série Linux (option par défaut) -----
    $enableSerial = $true
    if ($CI -and $CI.PSObject.Properties.Name -contains 'enableSerial') {
        $enableSerial = [bool]$CI.enableSerial
    }
    if ($enableSerial) {
        if (-not $addedRuncmdHeader) {
            $userdata += "runcmd:"
            $addedRuncmdHeader = $true
        }

        # Ajoute console=ttyS0 aux kernels (RHEL via grubby, Debian/Ubuntu via /etc/default/grub)
        $cmd1 = (@'
sh -c 'if command -v grubby >/dev/null 2>&1; then grubby --update-kernel=ALL --args="console=ttyS0,115200n8 console=tty0"; elif [ -f /etc/default/grub ]; then if ! grep -q "console=ttyS0" /etc/default/grub; then sed -i "s/GRUB_CMDLINE_LINUX=\"\([^\"]*\)\"/GRUB_CMDLINE_LINUX=\"\1 console=ttyS0,115200n8 console=tty0\"/" /etc/default/grub; fi; if command -v update-grub >/dev/null 2>&1; then update-grub; elif command -v grub2-mkconfig >/dev/null 2>&1; then grub2-mkconfig -o /boot/grub2/grub.cfg; fi; fi || true'
'@).Trim()

        $cmd2 = "systemctl enable --now serial-getty@ttyS0.service || true"

        $userdata += "  - $cmd1"
        $userdata += "  - $cmd2"

        # reboot auto optionnel (cloud-init power_state)
        $serialReboot = $false
        if ($CI -and $CI.PSObject.Properties.Name -contains 'serialReboot') {
            $serialReboot = [bool]$CI.serialReboot
        }
        if ($serialReboot) {
            $userdata += "power_state:"
            $userdata += "  mode: reboot"
            $userdata += "  timeout: 30"
            $userdata += "  message: Applying serial console settings"
            $userdata += "  condition: true"
        }
    }


    # network-config
    $net = @()
    if ($CI -and $CI.network -and $CI.network.mode -eq "static") {
        $net += "version: 2"
        $net += "ethernets:"
        $net += "  eth0:"
        $net += "    dhcp4: false"
        if ($CI.network.address) { $net += "    addresses: [ $($CI.network.address) ]" }
        if ($CI.network.gateway) { $net += "    routes: [ { to: default, via: $($CI.network.gateway) } ]" }
        if ($CI.network.nameservers) { $net += "    nameservers: { addresses: [ $(($CI.network.nameservers -join ', ')) ] }" }
    }
    else {
        $net += "version: 2"
        $net += "ethernets:"
        $net += "  eth0:"
        $net += "    dhcp4: true"
    }

    $userdataText = ($userdata -join "`n") + "`n"
    Set-Content -Path (Join-Path $dir "user-data") -Value $userdataText -NoNewline -Encoding UTF8

    $hostForMd = if ($CI -and $CI.hostname) { $CI.hostname } else { $Name }
    $instanceId = "$Name-$(Get-Random)"
    $md = @(
        "instance-id: $instanceId",
        "local-hostname: $hostForMd",
        "dsmode: local"
    ) -join "`n"
    Set-Content -Path (Join-Path $dir "meta-data") -Value ($md + "`n") -NoNewline -Encoding UTF8

    Set-Content -Path (Join-Path $dir "network-config") -Value (($net -join "`n") + "`n") -NoNewline -Encoding UTF8
}

# ---------- Helpers seed builder (openhvx-cidata-iso) ----------
function New-SeedIso($filesDir, $isoPath) {
    $exe = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) "bin") "openhvx-cidata-iso.exe"
    if (-not (Test-Path $exe)) { throw "openhvx-cidata-iso.exe not found at $exe" }

    $args = @("-in", $filesDir, "-out", $isoPath, "-label", "cidata")
    $p = Start-Process -FilePath $exe -ArgumentList $args -NoNewWindow -PassThru -Wait
    if ($p.ExitCode -ne 0) { throw "openhvx-cidata-iso.exe failed with code $($p.ExitCode)" }
}

# ---------- MAIN ----------
try {
    $task = Read-TaskInput -Inline $InputJson
    $d = if ($task.PSObject.Properties.Name -contains 'data' -and $task.data) { $task.data } else { $task }

    if ([string]::IsNullOrWhiteSpace($d.name)) { throw "missing 'name'" }
    $Name = $d.name.Trim()
    $Generation = if ($d.generation) { [int]$d.generation } else { 2 }
    if ($Generation -notin 1, 2) { throw "invalid 'generation' (must be 1 or 2)" }

    if (-not $d.ram) { throw "missing 'ram'" }
    $MemoryStartupBytes = Resolve-SizeBytes $d.ram

    $CPU = if ($d.cpu) { [int]$d.cpu } else { $null }
    $SwitchName = $d.switch
    $DynMem = [bool]$d.dynamic_memory
    $MinBytes = if ($d.min_ram) { Resolve-SizeBytes $d.min_ram } else { $null }
    $MaxBytes = if ($d.max_ram) { Resolve-SizeBytes $d.max_ram } else { $null }
    $CI = $d.cloudInit

    $SecureBoot = $false
    if ($null -ne $d.secure_boot) { $SecureBoot = [bool]$d.secure_boot }
    $CiDataFormat = "iso"

    $ctx = $d.__ctx
    $tenantId = $null; $root = $null; $vmsRoot = $null; $vhdRoot = $null
    if ($ctx) {
        $tenantId = $ctx.tenantId
        if ($ctx.paths) {
            $root = $ctx.paths.root
            $vmsRoot = $ctx.paths.vms
            $vhdRoot = $ctx.paths.vhd
        }
    }

    if (-not $d.imagePath) { throw "missing 'imagePath'" }
    $BaseVhdx = $d.imagePath
    if (-not (Test-Path -LiteralPath $BaseVhdx)) { throw "base image not found: $BaseVhdx" }

    $VmDir = $d.path
    if (-not $VmDir -and $vmsRoot) {
        $VmDir = if ($tenantId) { Join-Path (Join-Path $vmsRoot $tenantId) $Name } else { Join-Path $vmsRoot $Name }
    }
    if ($VmDir) {
        Assert-UnderRoot -Candidate $VmDir -Root $root
        if (Test-Path -LiteralPath $VmDir) { $VmDir = Get-UniquePath -Path $VmDir }
        Ensure-Dir $VmDir
    }

    if (-not $vhdRoot) { throw "ctx.paths.vhd is required for disk placement" }
    $VhdDir = if ($tenantId) { Join-Path (Join-Path $vhdRoot $tenantId) $Name } else { Join-Path $vhdRoot $Name }
    Assert-UnderRoot -Candidate $VhdDir -Root $root
    Ensure-Dir $VhdDir

    $VmVhdx = Join-Path $VhdDir "disk.vhdx"
    $SeedIso = Join-Path $VhdDir "seed-cidata.iso"

    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "a VM named '$Name' already exists" }

    Copy-Item -Path $BaseVhdx -Destination $VmVhdx -Force

    $vmParams = @{
        Name               = $Name
        MemoryStartupBytes = $MemoryStartupBytes
        Generation         = $Generation
        VHDPath            = $VmVhdx
    }
    if ($VmDir) { $vmParams.Path = $VmDir }
    if ($SwitchName) { $vmParams.SwitchName = $SwitchName }

    $vm = New-VM @vmParams -ErrorAction Stop

    if ($CPU -and $CPU -ge 1) {
        Set-VM -VM $vm -ProcessorCount $CPU -ErrorAction Stop | Out-Null
    }

    if ($DynMem) {
        if (-not $MinBytes) { $MinBytes = [int64]([math]::Max(512MB, [math]::Floor($MemoryStartupBytes * 0.5))) }
        if (-not $MaxBytes) { $MaxBytes = [int64]([math]::Max($MemoryStartupBytes, 2GB)) }
        if ($MinBytes -gt $MemoryStartupBytes) { $tmp = $MinBytes; $MinBytes = $MemoryStartupBytes; $MemoryStartupBytes = $tmp }
        if ($MaxBytes -lt $MemoryStartupBytes) { $MaxBytes = $MemoryStartupBytes }
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $true -MinimumBytes $MinBytes -MaximumBytes $MaxBytes -StartupBytes $MemoryStartupBytes -ErrorAction Stop | Out-Null
    }
    else {
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -StartupBytes $MemoryStartupBytes -ErrorAction Stop | Out-Null
    }

    # ----- COM1 (Named Pipe) AVANT 1er boot -----
    $vmGuid = $vm.Id.Guid
    $com1Path = "\\.\pipe\openhvx-$vmGuid-com1"
    Set-VMComPort -VMName $Name -Number 1 -Path $com1Path | Out-Null
    $notes.Add("COM1 named pipe configured: $com1Path") | Out-Null

    # Firmware (Secure Boot) pour Gen2
    if ($Generation -eq 2) {
        if ($SecureBoot) {
            Set-VMFirmware -VMName $Name -EnableSecureBoot On -SecureBootTemplate "MicrosoftUEFICertificateAuthority" | Out-Null
        }
        else {
            Set-VMFirmware -VMName $Name -EnableSecureBoot Off | Out-Null
        }
    }

    # ----- cloud-init files + seed -----
    $tmp = Join-Path $env:TEMP ("cidata-" + [guid]::NewGuid().ToString())
    Ensure-Dir $tmp
    New-CloudInitFiles -dir $tmp -Name $Name -CI $CI

    New-SeedIso -filesDir $tmp -isoPath $SeedIso
    Add-VMDvdDrive -VMName $Name -Path $SeedIso | Out-Null
    Remove-Item -Path $tmp -Recurse -Force

    # Ordre de boot (Gen2)
    if ($Generation -eq 2) {
        $sys = Get-VMHardDiskDrive -VMName $Name | Where-Object { $_.Path -eq $VmVhdx }
        if ($sys) { Set-VMFirmware -VMName $Name -FirstBootDevice $sys | Out-Null }
    }

    Start-VM -Name $Name | Out-Null

    $disks = @(@{ role = "system"; path = $VmVhdx })
    if (Test-Path $SeedIso) { $disks += @{ role = "cidata"; path = $SeedIso; type = "iso" } }

    $vmObj = @{
        name       = $vm.Name
        id         = "$($vm.Id)"
        guid       = "$($vm.Id)"
        generation = $Generation
        path       = $vm.Path
        cpu        = $CPU
        memory     = @{
            startup = $MemoryStartupBytes
            dynamic = $DynMem
            min     = $MinBytes
            max     = $MaxBytes
        }
        network    = $SwitchName
        disks      = $disks
        tenantId   = $tenantId
        locations  = @{
            vm  = $VmDir
            vhd = $VhdDir
        }
        firmware   = @{
            secureBoot = if ($Generation -eq 2) { $SecureBoot } else { $null }
        }
        cidata     = @{
            format = "iso"
        }
        serial     = @{
            com1 = @{
                path = $com1Path
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
