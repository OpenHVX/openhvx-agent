# Test-only Hyper-V adapter: no real Hyper-V cmdlet is loaded or called.
param([string]$InputJson)
$ErrorActionPreference = 'Stop'
$targetId = '11111111-1111-4111-8111-111111111111'
$otherId = '22222222-2222-4222-8222-222222222222'
function Get-VM {
    [CmdletBinding()] param([guid]$Id, [string]$Name)
    if ($env:OPENHVX_TEST_MODE -eq 'unavailable') { throw 'Host observation unavailable' }
    $other = [pscustomobject]@{ Id = [guid]$otherId; Name = 'duplicate'; State = 'Off' }
    if ($env:OPENHVX_TEST_MODE -ne 'absent') { [pscustomobject]@{ Id = [guid]$targetId; Name = 'duplicate'; State = 'Off' } }
    $other
}
function Get-VMHardDiskDrive {
    [CmdletBinding()] param($VM, [string]$VMName)
    if ($VMName -or !$VM -or "$($VM.Id)" -ne $targetId) { throw 'Disk lookup lost its VM identity' }
}
function Get-VMDvdDrive {
    [CmdletBinding()] param($VM, [string]$VMName)
    if ($VMName -or !$VM -or "$($VM.Id)" -ne $targetId) { throw 'DVD lookup lost its VM identity' }
}
function Remove-VM {
    [CmdletBinding()] param($VM, [string]$Name, [switch]$Force)
    if ($Name -or !$VM -or "$($VM.Id)" -ne $targetId) { throw 'Deletion lost its VM identity' }
    [System.IO.File]::WriteAllText($env:OPENHVX_TEST_EFFECT, "$($VM.Id)")
}
& (Join-Path $PSScriptRoot '../actions/vm.delete.ps1') -InputJson $InputJson
exit $LASTEXITCODE
