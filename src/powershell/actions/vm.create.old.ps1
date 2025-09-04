# powershell/actions/vm.create.ps1
# Crée une VM Hyper-V à partir d'un payload JSON sur STDIN
# Example of payload:
# {
#   "data": {
#     "name": "vm-demo",
#     "generation": 2,
#     "ram": "4GB",
#     "path": "D:\\HyperV\\VMs\\vm-demo",        # (optionnel; défaut via __ctx.paths.vms/<tenant>/<name>)
#     "switch": "vSwitch-LAN",                   # (optionnel)
#     "cpu": 2,                                  # (optionnel)
#     "dynamic_memory": true,                    # (optionnel)
#     "min_ram": "2GB",                          # (optionnel; auto si dyn)
#     "max_ram": "8GB",                          # (optionnel; auto si dyn)
#     "vhd_path": "D:\\HyperV\\Disks\\vm.vhdx",  # (optionnel; défaut via __ctx.paths.vhd/<tenant>/<name>.vhdx)
#     "vhd_size": "60GB"                         # (optionnel; requis si on crée un VHD)
#     "__ctx": {
#        "tenantId": "TEN-123",
#        "paths": { "root":"C:\\Hyper-V\\openhvx", "vms":"...", "vhd":"...", "isos":"...", "checkpoints":"...", "logs":"...", "trash":"..." }
#     }
#   }
# }
# Sortie: { ok, result: { vm }, error }

param()

$ErrorActionPreference = 'Stop'

# ---------- Helpers JSON ----------
function Read-TaskFromStdin {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "no input"
    }
    try { return $raw | ConvertFrom-Json -ErrorAction Stop } catch {
        throw "invalid JSON"
    }
}

# ---------- Helpers tailles ----------
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
    throw "invalid size: '$InputValue'"
}

# ---------- Helpers sécurité chemins ----------
function Get-FullPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    return [System.IO.Path]::GetFullPath($p)
}
function Assert-UnderRoot {
    param([string]$Candidate, [string]$Root)
    if (-not $Root) { return } # sans root de contexte, on ne restreint pas
    $c = Get-FullPath $Candidate
    $r = Get-FullPath $Root
    if (-not $c -or -not $r) { throw "invalid path check" }
    # comparaison insensitive sur Windows
    if ($c.Length -lt $r.Length -or ($c.Substring(0, $r.Length) -ne $r -and $c.Substring(0, $r.Length).ToLower() -ne $r.ToLower())) {
        throw "unsafe path outside managed root: $Candidate (root=$Root)"
    }
}
function Get-UniquePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    # si libre, on garde
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
    if (-not (Test-Path -LiteralPath $p)) {
        New-Item -ItemType Directory -Path $p -Force | Out-Null
    }
}

# ---------- MAIN ----------
try {
    $task = Read-TaskFromStdin
    $data = $task.data
    if (-not $data) { throw "missing 'data' object" }

    # Entrées de base
    if ([string]::IsNullOrWhiteSpace($data.name)) { throw "missing 'data.name'" }
    $Name = $data.name.Trim()
    $Generation = if ($data.generation) { [int]$data.generation } else { 2 }
    if ($Generation -notin 1, 2) { throw "invalid 'data.generation' (must be 1 or 2)" }

    if (-not $data.ram) { throw "missing 'data.ram'" }
    $MemoryStartupBytes = Resolve-SizeBytes $data.ram

    $SwitchName = $data.switch
    $CPU = if ($data.cpu) { [int]$data.cpu } else { $null }

    $DynMem = [bool]$data.dynamic_memory
    $MinBytes = if ($data.min_ram) { Resolve-SizeBytes $data.min_ram } else { $null }
    $MaxBytes = if ($data.max_ram) { Resolve-SizeBytes $data.max_ram } else { $null }

    # Contexte (facultatif mais recommandé)
    $ctx = $data.__ctx
    $tenantId = $null
    $root = $null
    $vmsRoot = $null
    $vhdRoot = $null
    if ($ctx) {
        $tenantId = $ctx.tenantId
        if ($ctx.paths) {
            $root = $ctx.paths.root
            $vmsRoot = $ctx.paths.vms
            $vhdRoot = $ctx.paths.vhd
        }
    }

    # Paramètres chemin VM (peuvent être fournis par l'appelant)
    $Path = $data.path
    $VhdPath = $data.vhd_path
    $VhdSize = if ($data.vhd_size) { Resolve-SizeBytes $data.vhd_size } else { $null }

    # Si pas de Path, proposer un chemin sûr: <vmsRoot>/<tenantId>/<Name>
    if (-not $Path) {
        if ($vmsRoot) {
            $Path = if ($tenantId) { Join-Path (Join-Path $vmsRoot $tenantId) $Name } else { Join-Path $vmsRoot $Name }
        }
    }
    # Si pas de VhdPath mais on doit créer un disque (VhdSize fourni), proposer <vhdRoot>/<tenantId>/<Name>.vhdx
    if (-not $VhdPath -and $VhdSize) {
        if ($vhdRoot) {
            $fileName = "$Name.vhdx"
            $VhdPath = if ($tenantId) { Join-Path (Join-Path $vhdRoot $tenantId) $fileName } else { Join-Path $vhdRoot $fileName }
        }
    }

    # Vérifs sécurité: tout ce qu’on écrit doit rester sous root (si fourni)
    if ($Path) { Assert-UnderRoot -Candidate $Path    -Root $root }
    if ($VhdPath) { Assert-UnderRoot -Candidate $VhdPath -Root $root }

    # Garantir absence d’overwrite: dossiers/fichiers uniques
    if ($Path) {
        # on ne renomme pas la VM pour éviter collisions de nom; Hyper-V interdit déjà deux VMs de même nom
        # mais on garantit que le dossier cible n’écrase rien d’existant
        if (Test-Path -LiteralPath $Path) {
            $Path = Get-UniquePath -Path $Path
        }
        Ensure-Dir $Path
    }
    if ($VhdPath) {
        # Cas 1 : on attache un VHD existant (aucune création) -> pas de rename auto
        # Cas 2 : on crée un VHD (VhdSize fourni). Si le fichier existe, on choisit un nom unique pour la création.
        if ($VhdSize -and (Test-Path -LiteralPath $VhdPath)) {
            $VhdPath = Get-UniquePath -Path $VhdPath
        }
        # Prépare le dossier
        $parent = Split-Path -Path $VhdPath -Parent
        if ($parent) { Ensure-Dir $parent }
    }

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

    # Gestion disque:
    # - Attacher un VHD existant: VhdPath fourni, VhdSize NON fourni -> VHDPath
    # - Créer un VHD: VhdPath + VhdSize -> NewVHDPath/NewVHDSizeBytes
    # - Créer un VHD sans chemin explicite -> on a construit $VhdPath ci-dessus
    $attachExisting = $false
    if ($VhdPath -and -not $VhdSize) {
        if (-not (Test-Path -LiteralPath $VhdPath)) {
            throw "vhd_path does not exist (attach mode): $VhdPath"
        }
        $vmParams.VHDPath = $VhdPath
        $attachExisting = $true
    }
    elseif ($VhdPath -and $VhdSize) {
        $vmParams.NewVHDPath = $VhdPath
        $vmParams.NewVHDSizeBytes = $VhdSize
    }
    elseif ($VhdSize -and -not $VhdPath) {
        throw "you provided 'vhd_size' without 'vhd_path' and no default could be derived from context"
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
        if ($MinBytes -gt $MemoryStartupBytes) { $tmp = $MinBytes; $MinBytes = $MemoryStartupBytes; $MemoryStartupBytes = $tmp }
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
            vhd_path         = if ($attachExisting) { $VhdPath } elseif ($vm.HardDrives[0]) { $vm.HardDrives[0].Path } else { $VhdPath }
            vhd_size         = $VhdSize
            exists           = ($(if ($VhdPath) { Test-Path -LiteralPath $VhdPath } else { $false }))
            attachedExisting = $attachExisting
        }
        tenantId   = $tenantId
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
