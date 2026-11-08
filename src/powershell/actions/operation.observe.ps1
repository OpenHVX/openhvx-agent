# Read-only recovery. Never repeat New-VM, Restart-VM or another host mutation.
param([string]$InputJson)
$ErrorActionPreference = 'Stop'
try {
    $inputData = $InputJson | ConvertFrom-Json -ErrorAction Stop
    if ($inputData.operationId -notmatch '^[a-zA-Z0-9-]{1,128}$' -or $inputData.commandFingerprint -notmatch '^[a-f0-9]{64}$') { throw 'Invalid operation identity' }
    # A failed host query is never interpreted as absence.
    $observed = @(Get-VM -ErrorAction Stop)
    if ($inputData.action -eq 'vm.create') {
        $marker = "OpenHVX operation=$($inputData.operationId) hash=$($inputData.commandFingerprint) phase=complete"
        $selected = @($observed | Where-Object { $_.Notes -eq $marker })
        if ($selected.Count -gt 1) { throw 'Conflicting host operation markers' }
        if ($selected.Count -eq 1) {
            $vm = $selected[0]
            @{ complete = $true; result = @{ vm = @{ guid = "$($vm.Id)"; id = "$($vm.Id)"; name = $vm.Name } } } | ConvertTo-Json -Depth 8 -Compress
            exit 0
        }
    } elseif ($inputData.action -in @('vm.delete', 'vm.power')) {
        $targetGuid = [guid]::Empty
        if (-not [guid]::TryParse([string]$inputData.targetRef, [ref]$targetGuid)) { throw 'Canonical VM GUID required for observation' }
        $selected = @($observed | Where-Object { $_.Id -eq $targetGuid })
        if ($inputData.action -eq 'vm.delete' -and $selected.Count -eq 0) {
            @{ complete = $true; result = @{ vm = @{ guid = "$targetGuid"; notFound = $true } } } | ConvertTo-Json -Depth 8 -Compress
            exit 0
        }
        if ($inputData.action -eq 'vm.power' -and $selected.Count -eq 1) {
            $vm = $selected[0]
            $satisfied = ($inputData.requestedState -eq 'start' -and "$($vm.State)" -eq 'Running') -or ($inputData.requestedState -eq 'stop' -and "$($vm.State)" -eq 'Off')
            # Running alone cannot prove whether a requested restart happened.
            if ($satisfied) {
                @{ complete = $true; result = @{ vm = @{ guid = "$($vm.Id)"; name = $vm.Name; state = "$($vm.State)" } } } | ConvertTo-Json -Depth 8 -Compress
                exit 0
            }
        }
    }
    @{ complete = $false } | ConvertTo-Json -Compress
    exit 0
} catch { Write-Error 'Host operation observation failed'; exit 1 }
