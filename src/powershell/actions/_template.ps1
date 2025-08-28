# powershell/actions/_template.ps1
$ErrorActionPreference = 'Stop'
$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) {
  @{ ok = $false; error = "no input" } | ConvertTo-Json; exit 1
}
$task = $raw | ConvertFrom-Json

try {
  # $task.action, $task.data
  $result = @{ note = "implement me" }
  @{ ok = $true; result = $result } | ConvertTo-Json -Depth 8; exit 0
}
catch {
  @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json; exit 1
}