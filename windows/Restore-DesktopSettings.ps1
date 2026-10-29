[CmdletBinding()]
param([Parameter(Mandatory)][string]$BackupPath, [switch]$NoRestart)
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
$wallpaperSnapshot = Join-Path $BackupPath 'wallpaper-state.json'
$hasDesktopState = @( $entries | Where-Object { [IO.Path]::GetFileName($_.Path) -eq 'desktop-startup.json' } ).Count -gt 0
if ($hasDesktopState -or (Test-Path -LiteralPath $wallpaperSnapshot)) {
    . (Join-Path $PSScriptRoot 'Wallpaper.ps1')
    if (-not $NoRestart) {
        $installed = Join-Path $env:USERPROFILE '.glzr\glazewm'
        Set-DesktopSession $installed '' $false
        Stop-DesktopWallpaper -Wait
        & (Join-Path $PSScriptRoot 'Watch-FlowWorkspace.ps1') -Stop -WaitForStop
        Stop-DesktopApp 'zebar'
    }
    if (Test-Path -LiteralPath $wallpaperSnapshot) {
        Initialize-DesktopRuntime -Directory (Join-Path $env:USERPROFILE '.glzr\glazewm') -Build
    }
}
foreach ($name in @('PowerToys', 'PowerToys.FancyZones', 'PowerToys.PowerLauncher', 'Microsoft.CmdPal*', 'Flow.Launcher', 'Everything')) {
    if (-not $NoRestart) { Stop-DesktopApp $name }
}
foreach ($entry in $entries) {
    if ($entry.Existed) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $entry.Path) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $BackupPath $entry.Backup) -Destination $entry.Path -Force
    } elseif (Test-Path -LiteralPath $entry.Path -PathType Leaf) {
        Remove-Item -LiteralPath $entry.Path
    }
}
$statePath = Join-Path $BackupPath 'previous-state.json'
if (Test-Path -LiteralPath $statePath) {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $pack = Join-Path $env:USERPROFILE '.glzr\zebar\multimonitor'
    if (Test-Path -LiteralPath $pack) { Remove-Item -LiteralPath $pack -Recurse -Force }
    if ($state.hadPack) { Copy-Item -LiteralPath (Join-Path $BackupPath 'multimonitor') -Destination $pack -Recurse }
}
if (Test-Path -LiteralPath $wallpaperSnapshot) {
    # Restore paths first, then let Windows read their restored image contents.
    Restore-NativeWallpaper (Get-Content -LiteralPath $wallpaperSnapshot -Raw)
}
Write-Host 'Settings and shortcuts restored. Relaunch PowerToys and any desired launchers manually.'
