[CmdletBinding()]
param([string]$SettingsPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'DesktopSettings.ps1')

if (-not $SettingsPath) {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )
    $SettingsPath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $SettingsPath) {
        Write-Host 'Windows Terminal settings not found. Open Terminal once, then run windows\Configure-Terminal.ps1.'
        return
    }
}
# Parse before backing up or writing. Invalid JSON leaves the original untouched.
$settings = Read-SettingJson $SettingsPath
if ($settings.PSObject.Properties['launchMode'] -and $settings.launchMode -eq 'focus') {
    Write-Host 'Windows Terminal already launches in Focus mode.'
    return
}
Set-JsonProperty $settings 'launchMode' 'focus'
$backup = New-SettingsBackup 'terminal'
Write-SettingText $SettingsPath ($settings | ConvertTo-Json -Depth 100)
Write-Host "Windows Terminal will launch in Focus mode. Backup: $backup"
Write-Host 'For existing windows: Ctrl+Shift+P, then Toggle focus mode.'
