param(
    [string]$InputJson
)

$ErrorActionPreference = 'Stop'

function Read-ParamsJson {
    param([string]$Inline)

    if ($Inline) {
        try { return ($Inline | ConvertFrom-Json -ErrorAction Stop) } catch {}
    }
    $stdinLines = @()
    foreach ($line in $input) { $stdinLines += $line }
    if ($stdinLines.Count -gt 0) {
        $text = ($stdinLines -join "`n")
        try { return ($text | ConvertFrom-Json -ErrorAction Stop) } catch {}
    }
    return @{}
}

function _MB($bytes) {
    if ($null -eq $bytes) { return $null }
    return [int]([math]::Round($bytes / 1MB))
}

function Get-VM-Light {
    $list = @()
    try {
        $vms = Get-VM
        foreach ($v in $vms) {
            # NICs (juste IPs & switchName de base)
            $nics = @()
            try {
                $adapters = Get-VMNetworkAdapter -VMName $v.Name -ErrorAction Stop
                foreach ($n in $adapters) {
                    $ips = @(); try { $ips = $n.IPAddresses } catch {}
                    $nicIps = $ips | Where-Object { $_ }
                    $nics += [pscustomobject]@{
                        id          = $n.Name
                        networkId   = $n.SwitchName
                        macAddress  = $n.MacAddress
                        primary     = $false
                        ipAddresses = $nicIps
                    }
                }
            }
            catch {}

            $list += [pscustomobject]@{
                id               = "$($v.Id)"
                name             = $v.Name
                powerState       = "$($v.State)"
                cpu              = @{ vcpus = $null }     # on s'en fout en light, full le remplira
                memoryMb         = _MB $v.MemoryAssigned  # runtime
                # champs volatiles utilisés par combineAgent :
                state            = "$($v.State)"
                uptimeSec        = [int]$v.Uptime.TotalSeconds
                cpuUsagePct      = [int]$v.CPUUsage
                memoryAssignedMB = _MB $v.MemoryAssigned
                automaticStart   = "$($v.AutomaticStartAction)"
                automaticStop    = "$($v.AutomaticStopAction)"
                nics             = $nics
            }
        }
    }
    catch {}
    return , $list
}

try {
    $Params = Read-ParamsJson -Inline $InputJson

    $inv = [pscustomobject]@{
        schemaVersion = "1.0.0"
        collectedAt   = (Get-Date).ToUniversalTime().ToString("o")
        # host/networks/datastores laissés vides en light
        vms           = Get-VM-Light
    }

    $inv | ConvertTo-Json -Depth 10
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
