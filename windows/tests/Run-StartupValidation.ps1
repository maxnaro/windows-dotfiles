$ErrorActionPreference = 'Stop'
$failed = @()
foreach ($name in @('Test-DesktopLauncher.ps1', 'Test-DesktopSettings.ps1', 'Test-Startup.ps1', 'Test-StartupPerformance.ps1', 'Test-FlowWorkspace.ps1', 'Test-Launcher.ps1')) {
    & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $name)
    if ($LASTEXITCODE -ne 0) { $failed += $name }
}

if ($failed.Count) { throw ('Failed suites: ' + ($failed -join ', ')) }
