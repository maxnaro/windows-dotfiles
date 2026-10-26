[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DesktopSettings.ps1')
$backup = New-SettingsBackup 'desktop'
Update-PowerToys
Write-Host "Disabled FancyZones. Settings backup: $backup"
