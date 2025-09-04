# powershell/actions/vm.create.cloudinit.ps1
# Crée une VM Hyper-V depuis une image VHDX cloud + seed cloud-init (CIDATA).
# Entrée: JSON via -InputJson ou STDIN. Supporte l’enveloppe { action, data:{...} }.
# Attend que le controller ait déjà résolu data.imagePath (UNC/local).
# Sortie: { ok, result:{ vm }, error?, detail? }

param(
    [string]$InputJson
)

$ErrorActionPreference = 'Stop'

# ---------- Helpers JSON ----------
function Read-TaskInput {
    param([string]$Inline)
    if ($Inline) { try { return ($Inline | ConvertFrom-Json -ErrorAction Stop) } catch {} }
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "No JSON input (use -InputJson or pipe JSON to STDIN)" }
    try { return ($raw | ConvertFrom-Json -ErrorAction Stop) } catch { throw "Invalid JSON input" }
}

# ---------- Helpers tailles ----------
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

# ---------- Helpers chemins/sécurité ----------
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

# ---------- Helpers cloud-init ----------
function New-CloudInitFiles($dir, $Name, $CI) {
    Ensure-Dir $dir

    # user-data
    $userdata = @("#cloud-config")
    if ($CI.hostname) { $userdata += "hostname: $($CI.hostname)" }

    if ($CI.user) {
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
    elseif ($CI.ssh_authorized_keys) {
        $userdata += "ssh_authorized_keys:"
        $userdata += ($CI.ssh_authorized_keys | ForEach-Object { "  - $_" })
    }

    if ($CI.packages) { $userdata += "packages:"; $userdata += ($CI.packages | ForEach-Object { "  - $_" }) }
    if ($CI.runcmd) { $userdata += "runcmd:"; $userdata += ($CI.runcmd   | ForEach-Object { "  - $_" }) }

    $userdataText = ($userdata -join "`n") + "`n"
    Set-Content -Path (Join-Path $dir "user-data") -Value $userdataText -NoNewline -Encoding UTF8

    # meta-data
    $instanceId = "$Name-$(Get-Random)"
    $md = @(
        "instance-id: $instanceId",
        "local-hostname: $($CI.hostname ?? $Name)",
        "dsmode: local"
    ) -join "`n"
    Set-Content -Path (Join-Path $dir "meta-data") -Value ($md + "`n") -NoNewline -Encoding UTF8

    # network-config
    $net = @()
    if ($CI.network.mode -eq "static") {
        $net += "version: 2"
        $net += "ethernets:"
        $net += "  eth0:"
        $net += "    dhcp4: false"
        $net += "    addresses: [ $($CI.network.address) ]"
        if ($CI.network.gateway) { $net += "    routes: [ { to: default, via: $($CI.network.gateway) } ]" }
        if ($CI.network.nameservers) { $net += "    nameservers: { addresses: [ $(($CI.network.nameservers -join ', ')) ] }" }
    }
    else {
        $net += "version: 2"
        $net += "ethernets:"
        $net += "  eth0:"
        $net += "    dhcp4: true"
    }
    Set-Content -Path (Join-Path $dir "network-config") -Value (($net -join "`n") + "`n") -NoNewline -Encoding UTF8
}

function New-SeedVhdx($path, $filesDir) {
    $size = 64MB
    $vhd = New-VHD -Path $path -SizeBytes $size -Dynamic
    $disk = (Mount-VHD -Path $path -PassThru | Get-Disk)
    Initialize-Disk -Number $disk.Number -PartitionStyle MBR -PassThru | Out-Null
    $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter -MbrType IFS
    $vol = Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel "CIDATA" -Confirm:$false
    $drive = ($vol.DriveLetter + ":\")
    Copy-Item -Path (Join-Path $filesDir "*") -Destination $drive -Recurse -Force
    Dismount-VHD -Path $path
}

# ---------- MAIN ----------
try {
    # Lecture + déballage 'data'
    $task = Read-TaskInput -Inline $InputJson
    $d = if ($task.PSObject.Properties.Name -contains 'data' -and $task.data) { $task.data } else { $task }

    # Champs requis / optionnels
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

    # Contexte (__ctx) et racines
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

    # Image système (doit être résolue par le controller)
    if (-not $d.imagePath) { throw "missing 'imagePath' (controller must enrich imageId -> imagePath)" }
    $BaseVhdx = $d.imagePath
    if (-not (Test-Path -LiteralPath $BaseVhdx)) { throw "base image not found: $BaseVhdx" }

    # Emplacements dédiés par type: VMS et VHD, avec tenantId
    # VM config path
    $VmDir = $d.path
    if (-not $VmDir -and $vmsRoot) {
        $VmDir = if ($tenantId) { Join-Path (Join-Path $vmsRoot $tenantId) $Name } else { Join-Path $vmsRoot $Name }
    }
    if ($VmDir) {
        Assert-UnderRoot -Candidate $VmDir -Root $root
        if (Test-Path -LiteralPath $VmDir) { $VmDir = Get-UniquePath -Path $VmDir }
        Ensure-Dir $VmDir
    }

    # VHD storage path (système + seed)
    if (-not $vhdRoot) { throw "ctx.paths.vhd is required for disk placement" }
    $VhdDir = if ($tenantId) { Join-Path (Join-Path $vhdRoot $tenantId) $Name } else { Join-Path $vhdRoot $Name }
    Assert-UnderRoot -Candidate $VhdDir -Root $root
    Ensure-Dir $VhdDir

    $VmVhdx = Join-Path $VhdDir "disk.vhdx"
    $SeedVhdx = Join-Path $VhdDir "seed-cidata.vhdx"

    # Existence d'une VM homonyme
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "a VM named '$Name' already exists" }

    # 1) Clone du VHDX de base -> disque système
    Copy-Item -Path $BaseVhdx -Destination $VmVhdx -Force

    # 2) Création de la VM (attache le disque système dès la création)
    $vmParams = @{
        Name               = $Name
        MemoryStartupBytes = $MemoryStartupBytes
        Generation         = $Generation
        VHDPath            = $VmVhdx
    }
    if ($VmDir) { $vmParams.Path = $VmDir }
    if ($SwitchName) { $vmParams.SwitchName = $SwitchName }

    $vm = New-VM @vmParams -ErrorAction Stop

    # CPU
    if ($CPU -and $CPU -ge 1) {
        Set-VM -VM $vm -ProcessorCount $CPU -ErrorAction Stop | Out-Null
    }

    # Mémoire
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

    # 3) Générer les fichiers cloud-init et créer le VHDX CIDATA
    $tmp = Join-Path $env:TEMP ("cidata-" + [guid]::NewGuid().ToString())
    Ensure-Dir $tmp
    New-CloudInitFiles -dir $tmp -Name $Name -CI $CI
    New-SeedVhdx -path $SeedVhdx -filesDir $tmp
    Remove-Item -Path $tmp -Recurse -Force

    # 4) Attacher le seed comme second disque (SCSI)
    Add-VMHardDiskDrive -VMName $Name -Path $SeedVhdx

    # 5) Ordre de boot (disque système en premier), utile surtout pour Gen2
    if ($Generation -eq 2) {
        $sys = Get-VMHardDiskDrive -VMName $Name | Where-Object { $_.Path -eq $VmVhdx }
        if ($sys) { Set-VMFirmware -VMName $Name -FirstBootDevice $sys | Out-Null }
    }

    # (Optionnel) SecureBoot Linux Gen2
    # if ($Generation -eq 2) {
    #   Set-VMFirmware -VMName $Name -EnableSecureBoot On -SecureBootTemplate "MicrosoftUEFICertificateAuthority" | Out-Null
    # }

    # 6) Boot
    Start-VM -Name $Name | Out-Null

    # Sortie normalisée
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
        disks      = @(
            @{ role = "system"; path = $VmVhdx },
            @{ role = "cidata"; path = $SeedVhdx }
        )
        tenantId   = $tenantId
        locations  = @{
            vm  = $VmDir
            vhd = $VhdDir
        }
    }

    [pscustomobject]@{
        vm = $vmObj
    } | ConvertTo-Json -Depth 8
    exit 0
}
catch {
    $errMsg = $_.Exception.Message
    $errFull = ($_ | Out-String).Trim()
    [pscustomobject]@{
        ok     = $false
        result = $null
        error  = $errMsg
        detail = $errFull
    } | ConvertTo-Json -Depth 6
    exit 1
}
