# powershell/actions/vm.create.ps1
# Crée une VM Hyper-V à partir d'un payload JSON sur STDIN
# Entrée attendue :
# {
#   "data": {
#     "name": "vm-demo",
#     "generation": 2,
#     "ram": "4GB",
#     "path": "D:\\HyperV\\VMs\\vm-demo",
#     "switch": "vSwitch-LAN",
#     "cpu": 2,
#     "dynamic_memory": true,
#     "min_ram": "2GB",
#     "max_ram": "8GB",
#     "vhd_path": "D:\\HyperV\\Disks\\vm-demo.vhdx",
#     "vhd_size": "60GB"
#   }
# }

$ErrorActionPreference = 'Stop'

function Resolve-SizeBytes {
    param([Parameter(Mandatory = $true)][Alias('Value')][object]$InputValue)

    if ($null -eq $InputValue) { return $null }

    if ($InputValue -is [int] -or $InputValue -is [long]) {
        if ($InputValue -le 131072) { return [int64]$InputValue * 1MB }
        return [int64]$InputValue
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
    throw "Taille invalide: '$InputValue'"
}

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        @{ ok = $false; error = "no input" } | ConvertTo-Json
        exit 1
    }

    $task = $raw | ConvertFrom-Json
    $data = $task.data

    if (-not $data) { throw "missing 'data' object" }
    if ([string]::IsNullOrWhiteSpace($data.name)) { throw "missing 'data.name'" }

    $Name = $data.name.Trim()
    $Generation = if ($data.generation) { [int]$data.generation } else { 2 }
    if ($Generation -notin 1, 2) { throw "invalid 'data.generation' (must be 1 or 2)" }

    if (-not $data.ram) { throw "missing 'data.ram'" }
    $MemoryStartupBytes = Resolve-SizeBytes $data.ram

    $Path = $data.path
    $SwitchName = $data.switch
    $CPU = if ($data.cpu) { [int]$data.cpu } else { $null }

    $DynMem = [bool]$data.dynamic_memory
    $MinBytes = if ($data.min_ram) { Resolve-SizeBytes $data.min_ram } else { $null }
    $MaxBytes = if ($data.max_ram) { Resolve-SizeBytes $data.max_ram } else { $null }

    $VhdPath = $data.vhd_path
    $VhdSize = if ($data.vhd_size) { Resolve-SizeBytes $data.vhd_size } else { $null }

    # Existence d'une VM homonyme ?
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
        throw "a VM named '$Name' already exists"
    }

    # Paramètres pour New-VM
    $vmParams = @{
        Name               = $Name
        MemoryStartupBytes = $MemoryStartupBytes
        Generation         = $Generation
    }
    if ($Path) { $vmParams.Path = $Path }
    if ($SwitchName) { $vmParams.SwitchName = $SwitchName }

    # Disque
    if ($VhdPath -and (Test-Path -LiteralPath $VhdPath)) {
        $vmParams.VHDPath = $VhdPath
    }
    elseif ($VhdPath -and $VhdSize) {
        $vmParams.NewVHDPath = $VhdPath
        $vmParams.NewVHDSizeBytes = $VhdSize
    }
    elseif ($VhdSize -and -not $VhdPath) {
        throw "you provided 'data.vhd_size' without 'data.vhd_path'"
    }

    # Création
    $vm = New-VM @vmParams -ErrorAction Stop

    # CPU
    if ($CPU -and $CPU -ge 1) {
        Set-VM -VM $vm -ProcessorCount $CPU -ErrorAction Stop | Out-Null
    }

    # Mémoire
    if ($DynMem) {
        if (-not $MinBytes) { $MinBytes = [int64]([math]::Max(512MB, [math]::Floor($MemoryStartupBytes * 0.5))) }
        if (-not $MaxBytes) { $MaxBytes = [int64]([math]::Max($MemoryStartupBytes, 2GB)) }
        if ($MinBytes -gt $MemoryStartupBytes) { $MinBytes, $MemoryStartupBytes = $MemoryStartupBytes, $MinBytes }
        if ($MaxBytes -lt $MemoryStartupBytes) { $MaxBytes = $MemoryStartupBytes }

        Set-VMMemory -VM $vm `
            -DynamicMemoryEnabled $true `
            -MinimumBytes $MinBytes `
            -MaximumBytes $MaxBytes `
            -StartupBytes $MemoryStartupBytes -ErrorAction Stop | Out-Null
    }
    else {
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -StartupBytes $MemoryStartupBytes -ErrorAction Stop | Out-Null
    }
    # ... ta logique de création ...

    # Objet VM normalisé
    $vmObj = @{
        name       = $vm.Name
        id         = "$($vm.Id)"         # compat
        guid       = "$($vm.Id)"         # clé stable pour TenantResource
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
        disk       = @{
            vhd_path = $VhdPath
            vhd_size = $VhdSize
            exists   = ($(if ($VhdPath) { Test-Path -LiteralPath $VhdPath } else { $false }))
        }
    }

    # >>> IMPORTANT : on n’émet QUE { vm = ... } ; l’agent ajoutera ok/result
    @{ vm = $vmObj } | ConvertTo-Json -Depth 6
    exit 0
}
catch {
    $errMsg = $_.Exception.Message
    $errFull = ($_ | Out-String).Trim()

    $errorObj = @{
        ok     = $false
        error  = $errMsg
        detail = $errFull   # <-- message complet (stack PS)
    }

    $errorObj | ConvertTo-Json -Depth 6
    exit 1
}