[CmdletBinding()]
param([Parameter(Mandatory)][string]$BackupPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'DesktopSettings.ps1')
$parsedEntries = Get-Content -LiteralPath (Join-Path $BackupPath 'files.json') -Raw | ConvertFrom-Json
$entries = @($parsedEntries)
# Validate the backup before stopping apps or restoring any files.
foreach ($entry in $entries) {
    if ($entry.Existed -and -not (Test-Path -LiteralPath (Join-Path $BackupPath $entry.Backup))) {
        throw "Missing backup: $($entry.Backup)"
    }
}
foreach ($name in @('PowerToys', 'PowerToys.FancyZones', 'PowerToys.PowerLauncher', 'Microsoft.CmdPal*', 'Flow.Launcher', 'Everything')) {
    Stop-DesktopApp $name
}
foreach ($entry in $entries) {
    if ($entry.Existed) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $entry.Path) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $BackupPath $entry.Backup) -Destination $entry.Path -Force
    } elseif (Test-Path -LiteralPath $entry.Path -PathType Leaf) {
        Remove-Item -LiteralPath $entry.Path
    }
}
Write-Host 'Settings and shortcuts restored. Relaunch PowerToys and any desired launchers manually.'
