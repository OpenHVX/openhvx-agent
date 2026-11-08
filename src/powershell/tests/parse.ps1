$ErrorActionPreference = 'Stop'
$failed = $false
Get-ChildItem (Join-Path $PSScriptRoot '../actions') -Filter '*.ps1' | Where-Object { $_.Name -notlike '*.old.ps1' } | ForEach-Object {
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    foreach ($error in $errors) {
        Write-Host "$($_.Name):$($error.Extent.StartLineNumber): $($error.Message)"
        $failed = $true
    }
}
if ($failed) { exit 1 }
Write-Host 'Active PowerShell action scripts parse successfully.'
