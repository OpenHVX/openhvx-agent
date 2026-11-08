param([string]$InputJson)
$ErrorActionPreference = 'Stop'
$proof = $InputJson | ConvertFrom-Json
function Get-VM {
    [CmdletBinding()] param()
    if ($env:OPENHVX_TEST_MODE -eq 'unavailable') { throw 'Host unavailable' }
    if ($env:OPENHVX_TEST_MODE -eq 'deleted') { return }
    $phase = if ($env:OPENHVX_TEST_MODE -eq 'create-complete') { 'complete' } else { 'applying' }
    $state = if ($env:OPENHVX_TEST_MODE -eq 'off') { 'Off' } else { 'Running' }
    [pscustomobject]@{
        Id = [guid]'11111111-1111-4111-8111-111111111111'
        Name = 'vm'
        State = $state
        Notes = "OpenHVX operation=$($proof.operationId) hash=$($proof.commandFingerprint) phase=$phase"
    }
}
& (Join-Path $PSScriptRoot '../actions/operation.observe.ps1') -InputJson $InputJson
exit $LASTEXITCODE
