# Ensure UTF-8 encoding for the entire session
try {
    # Set console code page
    $currentCP = (chcp | Out-String) -replace "[^\d]",""
    if ($currentCP -ne "65001") {
        Write-Host "[LOG]: Setting console code page to 65001 (UTF-8) from $currentCP"
        chcp 65001 | Out-Null
    }

    # Force UTF-8 encoding with BOM for PowerShell
    $OutputEncoding = [System.Text.UTF8Encoding]::new($true)  # With BOM
    [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($true)
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($true)
    
    # Set default encoding for cmdlets with BOM
    $PSDefaultParameterValues['*:Encoding'] = 'utf8BOM'
    
    Write-Host "[LOG]: Successfully configured UTF-8 encoding for the session"
} catch {
    Write-Warning "Failed to configure UTF-8 encoding: $_"
    exit 1
}

$scriptDir = $PSScriptRoot

$binPath = Resolve-Path (Join-Path $scriptDir "..\bin")

$env:PATH = "$binPath;$env:PATH"

Write-Host "Current directory: $scriptDir"
Write-Host "PATH Component: $binPath"
# Write-Host "PATH: $env:PATH"
