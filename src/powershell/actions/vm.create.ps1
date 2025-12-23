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

# --- Transaction state ---
$createdVmName = $null
$createdVm = $null
$createdVmDir = $null
$createdVhdDir = $null
$createdSeedDir = $null
$createdVhdx = $null
$createdSeedIso = $null
$iscsiConnectedByUs = $false
$iscsiPortalAdded = $false
$iscsiInitiallyConnected = $false
$iscsiDiskNumber = $null
$iscsiDiskWasOffline = $null
$iscsiDiskWasReadOnly = $null
$passThroughAttached = $false

# --- Early debug (script start) ---
$earlyLogRoots = @()
if ($InputJson) {
    try {
        $earlyObj = $InputJson | ConvertFrom-Json -ErrorAction Stop
        if ($earlyObj.data -and $earlyObj.data.__ctx -and $earlyObj.data.__ctx.paths -and $earlyObj.data.__ctx.paths.logs) {
            $earlyLogRoots += $earlyObj.data.__ctx.paths.logs
        }
        elseif ($earlyObj.__ctx -and $earlyObj.__ctx.paths -and $earlyObj.__ctx.paths.logs) {
            $earlyLogRoots += $earlyObj.__ctx.paths.logs
        }
    }
    catch {}
}
if ($env:TEMP) { $earlyLogRoots += $env:TEMP }
if ($PSScriptRoot) { $earlyLogRoots += $PSScriptRoot }
foreach ($root in $earlyLogRoots) {
    try {
        if (-not $root) { continue }
        if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
        $logPath = Join-Path $root "debug.log"
        Add-Content -Path $logPath -Value ("[{0}] vm.create invoked" -f (Get-Date).ToString("o")) -Encoding UTF8
    }
    catch {}
}

# ---------- Helpers JSON ----------
function Read-TaskInput {
    param([string]$Inline)
    if ($Inline) { try { return ($Inline | ConvertFrom-Json -ErrorAction Stop) } catch {} }
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { throw "No JSON input (use -InputJson or pipe JSON to STDIN)" }
    try { return ($raw | ConvertFrom-Json -ErrorAction Stop) } catch { throw "Invalid JSON input" }
}

# ---------- Helpers debug ----------
function Write-DebugLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [object]$Ctx
    )
    $logRoots = @()
    if ($Ctx -and $Ctx.paths -and $Ctx.paths.logs) { $logRoots += $Ctx.paths.logs }
    if ($env:TEMP) { $logRoots += $env:TEMP }
    if ($PSScriptRoot) { $logRoots += $PSScriptRoot }
    foreach ($root in $logRoots) {
        try {
            if (-not $root) { continue }
            if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
            $logPath = Join-Path $root "debug.log"
            $stamp = (Get-Date).ToString("o")
            Add-Content -Path $logPath -Value ("[{0}] {1}" -f $stamp, $Message) -Encoding UTF8
            break
        }
        catch {}
    }
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
function Align-VMBytes {
    param([int64]$Bytes)
    if ($Bytes -le 0) { return 0 }
    $step = 2MB  # Hyper-V requires 2MB alignment for memory values
    $aligned = [int64]([math]::Floor($Bytes / $step) * $step)
    if ($aligned -lt $step) { $aligned = $step }
    return $aligned
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


# ---------- Helpers iSCSI ----------
function Ensure-IscsiTargetConnected {
    param(
        [Parameter(Mandatory = $true)][string]$Iqn,
        [string]$Portal
    )

    $portalObj = $null
    if ($Portal) {
        $portalObj = Get-IscsiTargetPortal | Where-Object { $_.TargetPortalAddress -eq $Portal }
        if (-not $portalObj) {
            New-IscsiTargetPortal -TargetPortalAddress $Portal | Out-Null
            $portalObj = Get-IscsiTargetPortal | Where-Object { $_.TargetPortalAddress -eq $Portal }
            Set-Variable -Scope Script -Name iscsiPortalAdded -Value $true -Force
        }
    }

    # Découverte/rafraîchissement via le portail si dispo (tolère un portail sans cibles)
    if ($portalObj) {
        try { Update-IscsiTargetPortal -TargetPortalAddress $portalObj.TargetPortalAddress -ErrorAction Stop | Out-Null } catch {}
    }
    $target = $null
    for ($i = 0; $i -lt 3 -and -not $target; $i++) {
        $targets = @()
        if ($portalObj) {
            try { $targets = @(Get-IscsiTarget -IscsiTargetPortal $portalObj -ErrorAction Stop) } catch { $targets = @() }
        }
        if (-not $targets -or $targets.Count -eq 0) {
            $targets = @(Get-IscsiTarget -ErrorAction SilentlyContinue)
        }
        $target = $targets | Where-Object { $_.NodeAddress -eq $Iqn }
        if (-not $target) { Start-Sleep -Seconds 1 }
    }
    if (-not $target) { throw "iSCSI target not found: $Iqn" }

    if (-not $target.IsConnected) {
        for ($j = 0; $j -lt 3; $j++) {
            try {
                Connect-IscsiTarget -NodeAddress $Iqn -IsPersistent $true -IsMultipathEnabled $false | Out-Null
                return $true
            }
            catch {
                $sessionExists = $false
                try {
                    $sessionExists = @(Get-IscsiSession -ErrorAction SilentlyContinue | Where-Object { $_.TargetNodeAddress -eq $Iqn }).Count -gt 0
                }
                catch {}
                if ($sessionExists) { return $false }
                if ($_.Exception -and ($_.Exception.Message -like "*already been logged in*")) { return $false }
                if ($j -ge 2) { throw }
                Start-Sleep -Seconds 1
            }
        }
    }
    return $false
}

function Get-IscsiDiskByIqn {
    param([Parameter(Mandatory = $true)][string]$Iqn)
    $devices = @()
    try {
        $filter = "TargetName='$Iqn'"
        $session = Get-WmiObject -Namespace ROOT\WMI -Class MSiSCSIInitiator_SessionClass -Filter $filter -ErrorAction Stop
        if ($session -and $session.Devices) {
            $devices = @($session.Devices)
        }
    }
    catch {}

    if ($devices.Count -gt 0) {
        $nums = @($devices | Where-Object { $_.DeviceNumber -ne $null } | Select-Object -ExpandProperty DeviceNumber -Unique)
        if ($nums.Count -eq 1) {
            return (Get-Disk -Number $nums[0] -ErrorAction SilentlyContinue)
        }
        if ($nums.Count -gt 1) { throw "multiple iSCSI disks mapped for IQN ${Iqn}: $($nums -join ', ')" }
    }
    return $null
}

function Wait-IscsiDisk {
    param(
        [Parameter(Mandatory = $true)][string]$Iqn,
        [int]$TimeoutSec = 20
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        $disk = Get-IscsiDiskByIqn -Iqn $Iqn
        if ($disk) { return $disk }
        Start-Sleep -Seconds 1
    } while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec)
    return $null
}

function Get-VmNamesUsingDiskNumber {
    param([Parameter(Mandatory = $true)][int]$DiskNumber)
    $names = @()
    try {
        $vms = Get-VM
        foreach ($v in $vms) {
            $hdds = Get-VMHardDiskDrive -VMName $v.Name -ErrorAction SilentlyContinue
            foreach ($h in $hdds) {
                if ($null -ne $h.DiskNumber -and $h.DiskNumber -eq $DiskNumber) {
                    $names += $v.Name
                }
            }
        }
    }
    catch {}
    return $names
}
function Disconnect-IscsiTargetSafe {
    param([Parameter(Mandatory = $true)][string]$Iqn)
    try {
        $sessions = Get-IscsiSession -ErrorAction SilentlyContinue | Where-Object { $_.TargetNodeAddress -eq $Iqn }
        foreach ($s in $sessions) {
            try { Disconnect-IscsiTarget -SessionIdentifier $s.SessionIdentifier -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch {}
        }
    }
    catch {}
    try { Disconnect-IscsiTarget -NodeAddress $Iqn -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch {}
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
        if ($CI.network.address) {
            $addr = "$($CI.network.address)".Trim()
            if ($addr -notlike "*/?*") {
                $prefix = $null
                if ($CI.network.prefix) { $prefix = [int]$CI.network.prefix }
                elseif ($CI.network.netmask) {
                    try {
                        $maskBytes = [System.Net.IPAddress]::Parse("$($CI.network.netmask)").GetAddressBytes()
                        $maskBits = ($maskBytes | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
                        if ($maskBits -match '^1*0*$') {
                            $zeros = $maskBits.IndexOf('0')
                            $prefix = if ($zeros -ge 0) { $zeros } else { 32 }
                        }
                    }
                    catch {}
                }
                if (-not $prefix) { $prefix = 24 }
                $addr = "$addr/$prefix"
            }
            $net += "    addresses:"
            $net += "      - $addr"
        }
        if ($CI.network.gateway) { $net += "    gateway4: $($CI.network.gateway)" }
        if ($CI.network.nameservers) {
            $net += "    nameservers:"
            $net += "      addresses:"
            $net += (@($CI.network.nameservers) | ForEach-Object { "        - $_" })
        }
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
    $ctxEarly = $null
    if ($task.PSObject.Properties.Name -contains 'data' -and $task.data -and $task.data.__ctx) {
        $ctxEarly = $task.data.__ctx
    }
    elseif ($task.__ctx) {
        $ctxEarly = $task.__ctx
    }
    Write-DebugLog -Message "payload received" -Ctx $ctxEarly
    $d = if ($task.PSObject.Properties.Name -contains 'data' -and $task.data) { $task.data } else { $task }

    if ([string]::IsNullOrWhiteSpace($d.name)) { throw "missing 'name'" }
    $Name = $d.name.Trim()
    $Generation = if ($d.generation) { [int]$d.generation } else { 2 }
    if ($Generation -notin 1, 2) { throw "invalid 'generation' (must be 1 or 2)" }

    if (-not $d.ram) { throw "missing 'ram'" }
    $MemoryStartupBytes = Align-VMBytes (Resolve-SizeBytes $d.ram)

    $CPU = if ($d.cpu) { [int]$d.cpu } else { $null }
    $SwitchName = $d.switch
    $DynMem = [bool]$d.dynamic_memory
    $MinBytes = if ($d.min_ram) { Align-VMBytes (Resolve-SizeBytes $d.min_ram) } else { $null }
    $MaxBytes = if ($d.max_ram) { Align-VMBytes (Resolve-SizeBytes $d.max_ram) } else { $null }
    $CI = $d.cloudInit

    $SecureBoot = $false
    if ($null -ne $d.secure_boot) { $SecureBoot = [bool]$d.secure_boot }
    $CiDataFormat = "iso"

    $ctx = $d.__ctx
    Write-DebugLog -Message "vm.create start name=$Name" -Ctx $ctx
    $tenantId = $null; $root = $null; $vmsRoot = $null; $vhdRoot = $null; $isosRoot = $null
    if ($ctx) {
        $tenantId = $ctx.tenantId
        if ($ctx.paths) {
            $root = $ctx.paths.root
            $vmsRoot = $ctx.paths.vms
            $vhdRoot = $ctx.paths.vhd
            $isosRoot = $ctx.paths.isos
        }
    }

    $UseIscsi = $false
    $Iqn = $null
    if ($d.PSObject.Properties.Name -contains 'iqn' -and $d.iqn) {
        $tmpIqn = "$($d.iqn)".Trim()
        if ($tmpIqn) {
            $UseIscsi = $true
            $Iqn = $tmpIqn
        }
    }
    if ($UseIscsi) {
        $iscsiInitiallyConnected = $false
        try {
            $iscsiInitiallyConnected = @(Get-IscsiSession -ErrorAction SilentlyContinue | Where-Object { $_.TargetNodeAddress -eq $Iqn }).Count -gt 0
        }
        catch {}
        Write-DebugLog -Message "iscsi enabled iqn=$Iqn initialConnected=$iscsiInitiallyConnected" -Ctx $ctx
    }

    $DiskId = $null
    if ($d.PSObject.Properties.Name -contains 'diskId') { $DiskId = $d.diskId }

    $IscsiPortal = $null
    $IscsiPortalHost = $null
    if ($d.PSObject.Properties.Name -contains 'iscsiPortal' -and $d.iscsiPortal) {
        $IscsiPortal = $d.iscsiPortal
    }
    elseif ($d.PSObject.Properties.Name -contains 'iscsi' -and $d.iscsi) {
        if ($d.iscsi.PSObject.Properties.Name -contains 'portal' -and $d.iscsi.portal) {
            $IscsiPortal = $d.iscsi.portal
        }
    }
    elseif ($d.PSObject.Properties.Name -contains 'portal' -and $d.portal) {
        if ($d.portal.PSObject.Properties.Name -contains 'ip' -and $d.portal.ip) {
            $IscsiPortal = $d.portal.ip
        }
        if ($d.portal.PSObject.Properties.Name -contains 'host' -and $d.portal.host) {
            $IscsiPortalHost = $d.portal.host
        }
    }

    $BaseVhdx = $null
    if (-not $UseIscsi) {
        if (-not $d.imagePath) {
            if ($DiskId) { throw "missing 'iqn' for diskId '$DiskId' (or provide imagePath)" }
            throw "missing 'iqn' or 'imagePath'"
        }
        $BaseVhdx = $d.imagePath
        if (-not (Test-Path -LiteralPath $BaseVhdx)) { throw "base image not found: $BaseVhdx" }
    }
    elseif ($d.imagePath) {
        $notes.Add("imagePath ignored because iqn is provided") | Out-Null
    }

    $VmDir = $d.path
    if (-not $VmDir -and $vmsRoot) {
        $VmDir = if ($tenantId) { Join-Path (Join-Path $vmsRoot $tenantId) $Name } else { Join-Path $vmsRoot $Name }
    }
    if ($VmDir) {
        Assert-UnderRoot -Candidate $VmDir -Root $root
        if (Test-Path -LiteralPath $VmDir) { $VmDir = Get-UniquePath -Path $VmDir }
        $vmDirExisted = Test-Path -LiteralPath $VmDir
        Ensure-Dir $VmDir
        if (-not $vmDirExisted) { $createdVmDir = $VmDir }
    }

    $VhdDir = $null
    if (-not $UseIscsi) {
        if (-not $vhdRoot) { throw "ctx.paths.vhd is required for disk placement" }
        $VhdDir = if ($tenantId) { Join-Path (Join-Path $vhdRoot $tenantId) $Name } else { Join-Path $vhdRoot $Name }
        Assert-UnderRoot -Candidate $VhdDir -Root $root
        $vhdDirExisted = Test-Path -LiteralPath $VhdDir
        Ensure-Dir $VhdDir
        if (-not $vhdDirExisted) { $createdVhdDir = $VhdDir }
    }

    $SeedDir = $null
    if (-not $UseIscsi) {
        $SeedDir = $VhdDir
    }
    else {
        if ($isosRoot) {
            $SeedDir = if ($tenantId) { Join-Path (Join-Path $isosRoot $tenantId) $Name } else { Join-Path $isosRoot $Name }
        }
        elseif ($vhdRoot) {
            $SeedDir = if ($tenantId) { Join-Path (Join-Path $vhdRoot $tenantId) $Name } else { Join-Path $vhdRoot $Name }
        }
        elseif ($VmDir) {
            $SeedDir = $VmDir
        }
        else {
            throw "no path available for cloud-init seed placement"
        }
        Assert-UnderRoot -Candidate $SeedDir -Root $root
        $seedDirExisted = Test-Path -LiteralPath $SeedDir
        Ensure-Dir $SeedDir
        if (-not $seedDirExisted) { $createdSeedDir = $SeedDir }
    }

    $VmVhdx = if ($VhdDir) { Join-Path $VhdDir "disk.vhdx" } else { $null }
    $SeedIso = Join-Path $SeedDir "seed-cidata.iso"

    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) { throw "a VM named '$Name' already exists" }

    if (-not $UseIscsi) {
        Copy-Item -Path $BaseVhdx -Destination $VmVhdx -Force
        $createdVhdx = $VmVhdx
    }

    $vmParams = @{
        Name               = $Name
        MemoryStartupBytes = $MemoryStartupBytes
        Generation         = $Generation
    }
    if ($UseIscsi) { $vmParams.NoVHD = $true } else { $vmParams.VHDPath = $VmVhdx }
    if ($VmDir) { $vmParams.Path = $VmDir }
    if ($SwitchName) { $vmParams.SwitchName = $SwitchName }

    $vm = New-VM @vmParams -ErrorAction Stop
    $createdVm = $vm
    $createdVmName = $vm.Name

    if ($CPU -and $CPU -ge 1) {
        Set-VM -VM $vm -ProcessorCount $CPU -ErrorAction Stop | Out-Null
    }

    if ($DynMem) {
        if (-not $MinBytes) { $MinBytes = Align-VMBytes ([int64]([math]::Max(512MB, [math]::Floor($MemoryStartupBytes * 0.5)))) }
        if (-not $MaxBytes) { $MaxBytes = Align-VMBytes ([int64]([math]::Max($MemoryStartupBytes, 2GB))) }
        if ($MinBytes -gt $MemoryStartupBytes) { $tmp = $MinBytes; $MinBytes = $MemoryStartupBytes; $MemoryStartupBytes = $tmp }
        if ($MaxBytes -lt $MemoryStartupBytes) { $MaxBytes = $MemoryStartupBytes }
        $MemoryStartupBytes = Align-VMBytes $MemoryStartupBytes
        $MinBytes = Align-VMBytes $MinBytes
        $MaxBytes = Align-VMBytes $MaxBytes
        Set-VMMemory -VM $vm -DynamicMemoryEnabled $true -MinimumBytes $MinBytes -MaximumBytes $MaxBytes -StartupBytes $MemoryStartupBytes -ErrorAction Stop | Out-Null
    }
    else {
        $MemoryStartupBytes = Align-VMBytes $MemoryStartupBytes
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

    # ----- iSCSI pass-through disk -----
    $iscsiDisk = $null
    if ($UseIscsi) {
        $iscsiConnectedByUs = Ensure-IscsiTargetConnected -Iqn $Iqn -Portal $IscsiPortal
        Write-DebugLog -Message "iscsi connected portal=$IscsiPortal" -Ctx $ctx
        try { Update-HostStorageCache | Out-Null } catch {}
        $iscsiDisk = Wait-IscsiDisk -Iqn $Iqn -TimeoutSec 20
        if (-not $iscsiDisk) {
            $diskList = @(Get-Disk | Where-Object { $_.BusType -eq "iSCSI" } | ForEach-Object { "$($_.Number)=$([int64]$_.Size)" }) -join ", "
            throw "no iSCSI disk detected for target: ${Iqn} (iscsi disks: $diskList)"
        }
        $inUseBy = @(Get-VmNamesUsingDiskNumber -DiskNumber $iscsiDisk.Number)
        if ($inUseBy.Count -gt 0) {
            throw "iSCSI disk $($iscsiDisk.Number) already attached to VM(s): $($inUseBy -join ', ')"
        }
        if ($iscsiDisk.IsBoot -or $iscsiDisk.IsSystem) { throw "iSCSI disk cannot be a boot/system disk on the host (disk $($iscsiDisk.Number))" }

        $iscsiDiskNumber = $iscsiDisk.Number
        $iscsiDiskWasReadOnly = $iscsiDisk.IsReadOnly
        $iscsiDiskWasOffline = $iscsiDisk.IsOffline

        if ($iscsiDisk.IsReadOnly) { Set-Disk -Number $iscsiDisk.Number -IsReadOnly $false | Out-Null }
        if (-not $iscsiDisk.IsOffline) { Set-Disk -Number $iscsiDisk.Number -IsOffline $true | Out-Null }

        $controllerType = if ($Generation -eq 1) { "IDE" } else { "SCSI" }
        Add-VMHardDiskDrive -VMName $Name -DiskNumber $iscsiDisk.Number -ControllerType $controllerType | Out-Null
        $passThroughAttached = $true
        Write-DebugLog -Message "iscsi disk attached number=$($iscsiDisk.Number) controller=$controllerType" -Ctx $ctx
        $portalNote = if ($IscsiPortal) { " via $IscsiPortal" } else { "" }
        $hostNote = if ($IscsiPortalHost) { " ($IscsiPortalHost)" } else { "" }
        $notes.Add("iSCSI disk attached as pass-through (disk $($iscsiDisk.Number), iqn $Iqn$portalNote$hostNote)") | Out-Null
    }

    # ----- cloud-init files + seed -----
    $tmp = Join-Path $env:TEMP ("cidata-" + [guid]::NewGuid().ToString())
    Ensure-Dir $tmp
    New-CloudInitFiles -dir $tmp -Name $Name -CI $CI

    New-SeedIso -filesDir $tmp -isoPath $SeedIso
    $createdSeedIso = $SeedIso
    Add-VMDvdDrive -VMName $Name -Path $SeedIso | Out-Null
    Remove-Item -Path $tmp -Recurse -Force
    Write-DebugLog -Message "seed iso attached path=$SeedIso" -Ctx $ctx

    # Ordre de boot (Gen2)
    if ($Generation -eq 2) {
        $sys = if ($UseIscsi) {
            Get-VMHardDiskDrive -VMName $Name | Where-Object { $_.DiskNumber -eq $iscsiDisk.Number }
        }
        else {
            Get-VMHardDiskDrive -VMName $Name | Where-Object { $_.Path -eq $VmVhdx }
        }
        if ($sys) { Set-VMFirmware -VMName $Name -FirstBootDevice $sys | Out-Null }
    }

    Start-VM -Name $Name | Out-Null
    Write-DebugLog -Message "vm started name=$Name" -Ctx $ctx

    $disks = @()
    if ($UseIscsi) {
        $disks += @{
            role       = "system"
            type       = "iscsi"
            iqn        = $Iqn
            diskId     = $DiskId
            diskNumber = $iscsiDisk.Number
        }
    }
    else {
        $disks += @{ role = "system"; path = $VmVhdx }
    }
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
    $errFull = ($_ | Out-String).Trim()
    Write-DebugLog -Message ("error: {0}" -f $errMsg) -Ctx $ctx

    try {
        if ($passThroughAttached -and $createdVmName -and $iscsiDiskNumber -ne $null) {
            Remove-VMHardDiskDrive -VMName $createdVmName -DiskNumber $iscsiDiskNumber -ErrorAction SilentlyContinue | Out-Null
        }
    }
    catch {}
    try {
        if ($createdVmName -and (Get-VM -Name $createdVmName -ErrorAction SilentlyContinue)) {
            Stop-VM -Name $createdVmName -TurnOff -Force -ErrorAction SilentlyContinue | Out-Null
            Remove-VM -Name $createdVmName -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
    catch {}
    try {
        if ($createdSeedIso -and (Test-Path -LiteralPath $createdSeedIso)) {
            Remove-Item -LiteralPath $createdSeedIso -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}
    try {
        if ($createdVhdx -and (Test-Path -LiteralPath $createdVhdx)) {
            Remove-Item -LiteralPath $createdVhdx -Force -ErrorAction SilentlyContinue
        }
    }
    catch {}
    foreach ($dir in @($createdSeedDir, $createdVhdDir, $createdVmDir)) {
        try {
            if ($dir -and (Test-Path -LiteralPath $dir)) {
                $items = Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue
                if (-not $items) { Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue }
            }
        }
        catch {}
    }
    try {
        if ($iscsiDiskNumber -ne $null) {
            if ($null -ne $iscsiDiskWasReadOnly) { Set-Disk -Number $iscsiDiskNumber -IsReadOnly $iscsiDiskWasReadOnly | Out-Null }
            if ($null -ne $iscsiDiskWasOffline) { Set-Disk -Number $iscsiDiskNumber -IsOffline $iscsiDiskWasOffline | Out-Null }
        }
    }
    catch {}
    try {
        if ($UseIscsi -and $Iqn -and -not $iscsiInitiallyConnected) {
            Disconnect-IscsiTargetSafe -Iqn $Iqn
        }
    }
    catch {}

    [pscustomobject]@{
        ok     = $false
        result = $null
        error  = $errMsg
        detail = $errFull
    } | ConvertTo-Json -Depth 6
    exit 1
}
