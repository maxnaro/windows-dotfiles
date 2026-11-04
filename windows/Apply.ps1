[CmdletBinding()]
param(
    [ValidateRange(0, 9)]
    [int]$MonitorCount = 0,
    [switch]$NoRestart,
    [switch]$WithoutZebar,
    [ValidateSet('Auto', 'Native', 'Overlay', 'None')][string]$WallpaperMode
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'DesktopSettings.ps1')
. (Join-Path $PSScriptRoot 'HelperCache.ps1')
. (Join-Path $PSScriptRoot 'Wallpaper.ps1')

$configPath = Join-Path $env:USERPROFILE '.glzr\glazewm\config.yaml'
$settingsPath = Join-Path $env:USERPROFILE '.glzr\zebar\settings.json'
$packPath = Join-Path $env:USERPROFILE '.glzr\zebar\multimonitor'

# Widget runtime assets are bundled; development dependencies are not installed.
function Copy-WidgetPack {
    param([string]$Source, [string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        if ($item.Name -eq 'node_modules') { continue }
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) { Copy-WidgetPack $item.FullName $target }
        else { Copy-Item -LiteralPath $item.FullName -Destination $target -Force }
    }
}

if ($MonitorCount -eq 0) {
    Add-Type -AssemblyName System.Windows.Forms
    $MonitorCount = [System.Windows.Forms.Screen]::AllScreens.Count
}
if ($MonitorCount -lt 1 -or $MonitorCount -gt 9) {
    throw 'This setup requires between 1 and 9 connected monitors.'
}

# Distribute the nine workspaces across the connected monitors.
# With two monitors: 1-4 on monitor 0, 5-9 on monitor 1.
# With three monitors: 1-3 on monitor 0, 4-6 on 1, 7-9 on 2.
$perMonitor = [int][Math]::Floor(9 / $MonitorCount)
$workspaceLines = @('workspaces:')
for ($number = 1; $number -le 9; $number++) {
    $monitorIndex = [int][Math]::Min([Math]::Floor(($number - 1) / $perMonitor), $MonitorCount - 1)
    $workspaceLines += "  - { name: '$number', bind_to_monitor: $monitorIndex, keep_alive: true }"
}
$workspaceBlock = ($workspaceLines -join "`r`n") + "`r`n`r`n"
$config = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'config.yaml'))
if ($WithoutZebar) {
    $config = [regex]::Replace($config, '(?m)^    - ''shell-exec zebar''\r?\n', '')
    $config = [regex]::Replace($config, '(?m)^    - ''shell-exec taskkill /IM zebar.exe /F''\r?\n', '')
}
$workspacePattern = '(?ms)^workspaces:\r?\n.*?(?=^[a-z_]+:)'
if ([regex]::Matches($config, $workspacePattern).Count -ne 1) {
    throw 'The prepared configuration does not contain exactly one workspace section.'
}
$config = [regex]::Replace($config, $workspacePattern, $workspaceBlock)

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$backupPath = Join-Path $env:USERPROFILE ".glzr\backups\multimonitor-$stamp"
New-Item -ItemType Directory -Path $backupPath | Out-Null
$hadConfig = Test-Path -LiteralPath $configPath -PathType Leaf
$hadSettings = Test-Path -LiteralPath $settingsPath -PathType Leaf
$hadPack = Test-Path -LiteralPath $packPath -PathType Container
$helperFiles = @('Watch-FlowWorkspace.ps1', 'FlowWorkspace.cs', 'Start-Desktop.ps1', 'HelperCache.ps1',
    'DesktopRuntime.cs', 'TitleBars.cs', 'Watch-TitleBars.ps1', 'Wallpaper.ps1', 'Measure-GlazeWMStartup.ps1', 'StartupPerformance.ps1', 'desktop-startup.json', 'wallpaper.jpg', 'wallpaper-original.json')
$script:settingsBackup = $backupPath
$script:backupEntries = @()
foreach ($path in @($configPath, $settingsPath) + @($helperFiles | ForEach-Object { Join-Path (Split-Path -Parent $configPath) $_ })) { Save-SettingFile $path }
# Build before changing the installed configuration. Cached assemblies are source-addressed.
Initialize-DesktopRuntime -Directory (Split-Path -Parent $configPath) -Build

$existingTitleBars = Join-Path (Split-Path -Parent $configPath) 'Watch-TitleBars.ps1'
if (-not $NoRestart -and (Test-Path $existingTitleBars)) { & $existingTitleBars -Stop -WaitForStop }
$hadHelper = @{}
foreach ($name in $helperFiles) {
    $path = Join-Path (Split-Path -Parent $configPath) $name
    $hadHelper[$name] = Test-Path -LiteralPath $path -PathType Leaf
    if ($hadHelper[$name]) { Copy-Item -LiteralPath $path -Destination (Join-Path $backupPath $name) }
}
if ($hadConfig) {
    Copy-Item -LiteralPath $configPath -Destination (Join-Path $backupPath 'config.yaml')
}
if ($hadSettings) {
    Copy-Item -LiteralPath $settingsPath -Destination (Join-Path $backupPath 'settings.json')
}
if ($hadPack) {
    Copy-WidgetPack $packPath (Join-Path $backupPath 'multimonitor')
}
@{ hadConfig = $hadConfig; hadSettings = $hadSettings; hadPack = $hadPack; hadHelper = $hadHelper } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupPath 'previous-state.json') -Encoding UTF8

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $configPath) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $settingsPath) -Force | Out-Null
    foreach ($name in @($helperFiles | Where-Object { $_ -notin @('desktop-startup.json', 'wallpaper.jpg', 'wallpaper-original.json') })) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path (Split-Path -Parent $configPath) $name) -Force
    }
    if ($hadPack) { Remove-Item -LiteralPath $packPath -Recurse -Force }
    Copy-WidgetPack (Join-Path $PSScriptRoot 'multimonitor') $packPath
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'settings.json') -Destination $settingsPath
    $installed = Split-Path -Parent $configPath
    # Build the installed Flow cache too; the source-side cache is used by targeted updates/tests.
    & (Join-Path $installed 'Watch-FlowWorkspace.ps1') -Build
    if (-not $NoRestart) { Stop-DesktopWallpaper -Wait }
    $image = Join-Path $installed 'wallpaper.jpg'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'multimonitor\resources\coniston.jpg') -Destination $image -Force
    $desktop = Set-DesktopWallpaperConfiguration -Mode $WallpaperMode -ImagePath $image -Directory $installed -BackupDirectory $backupPath
    & (Join-Path $installed 'Watch-TitleBars.ps1') -Build
    $titleBarsEnabled = $true
    $previousDesktop = Join-Path $backupPath 'desktop-startup.json'
    if (Test-Path $previousDesktop) {
        $previous = Get-Content $previousDesktop -Raw | ConvertFrom-Json
        if ($previous.PSObject.Properties['TitleBarsEnabled']) { $titleBarsEnabled = [bool]$previous.TitleBarsEnabled }
    }
    $desktop | Add-Member NoteProperty TitleBarsEnabled $titleBarsEnabled
    $desktop | Add-Member NoteProperty ZebarEnabled (-not $WithoutZebar)
    [IO.File]::WriteAllText((Join-Path $installed 'desktop-startup.json'), ($desktop | ConvertTo-Json -Depth 8))
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($configPath, $config, $utf8)
} catch {
    foreach ($name in $helperFiles) {
        $path = Join-Path (Split-Path -Parent $configPath) $name
        if ($hadHelper[$name]) { Copy-Item -LiteralPath (Join-Path $backupPath $name) -Destination $path -Force }
        elseif (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    if ($hadConfig) {
        Copy-Item -LiteralPath (Join-Path $backupPath 'config.yaml') -Destination $configPath -Force
    } elseif (Test-Path -LiteralPath $configPath) {
        Remove-Item -LiteralPath $configPath -Force
    }
    if ($hadSettings) {
        Copy-Item -LiteralPath (Join-Path $backupPath 'settings.json') -Destination $settingsPath -Force
    } elseif (Test-Path -LiteralPath $settingsPath) {
        Remove-Item -LiteralPath $settingsPath -Force
    }
    if (Test-Path -LiteralPath $packPath) {
        Remove-Item -LiteralPath $packPath -Recurse -Force
    }
    if ($hadPack) {
        Copy-Item -LiteralPath (Join-Path $backupPath 'multimonitor') -Destination $packPath -Recurse
    }
    if (Test-Path -LiteralPath (Join-Path $backupPath 'wallpaper-state.json')) {
        try { Restore-NativeWallpaper (Get-Content -LiteralPath (Join-Path $backupPath 'wallpaper-state.json') -Raw) }
        catch { Write-Warning "Could not restore wallpaper; snapshot: $backupPath" }
    }
    throw
}

Write-Host "Installed settings for $MonitorCount monitor(s). Backups: $backupPath"

if ($NoRestart) {
    Write-Host 'Restart GlazeWM and Zebar to activate the installed settings.'
    return
}

# A restart is needed to activate and place every bound keep_alive workspace.
# Exit GlazeWM gracefully so its hidden windows are restored first.
# Application windows and Windows virtual desktops are left open.
$scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
$zebarExe = Join-Path $scoopRoot 'apps\zebar\current\zebar.exe'
$glazeCli = Join-Path $scoopRoot 'apps\glazewm\current\cli\GlazeWM.exe'
$glazeExe = Join-Path $scoopRoot 'apps\glazewm\current\GlazeWM.exe'
try {
    $requiredExecutables = @($glazeCli, $glazeExe)
    if (-not $WithoutZebar) { $requiredExecutables += $zebarExe }
    foreach ($exe in $requiredExecutables) {
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
            throw "Executable not found: $exe"
        }
    }
    $sessionId = (Get-Process -Id $PID).SessionId
    $runningGlaze = @(Get-Process -Name GlazeWM -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $sessionId -and $_.Path -notmatch '\\cli\\' })
    if ($runningGlaze.Count -gt 0) {
        & $glazeCli command wm-exit
        if ($LASTEXITCODE -ne 0) {
            throw 'GlazeWM did not accept the graceful exit command.'
        }
        $exitingIds = @($runningGlaze | ForEach-Object { $_.Id })
        for ($attempt = 0; $attempt -lt 120; $attempt++) {
            $runningGlaze = @(Get-Process -Id $exitingIds -ErrorAction SilentlyContinue)
            if ($runningGlaze.Count -eq 0) { break }
            Start-Sleep -Milliseconds 250
        }
        if ($runningGlaze.Count -gt 0) {
            throw 'GlazeWM is still exiting. Restart it manually after it closes.'
        }
    }
    Get-Process -Name zebar -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $sessionId } |
        Stop-Process -Force
    # The installed GlazeWM startup hook owns companion dispatch. Do not race it with a fallback Zebar launch.
    & (Join-Path (Split-Path -Parent $configPath) 'Start-Desktop.ps1') -GlazeCli $glazeCli
    if ($LASTEXITCODE -ne 0) { throw 'Desktop startup reported a failure; inspect startup.log.' }
} catch {
    Write-Warning "Settings are installed, but refreshing the apps failed: $_"
    Write-Warning 'Exit and relaunch GlazeWM from its tray menu/Start menu, then launch Zebar if needed.'
}

Write-Host 'Use Alt+1..9 for workspaces, or Ctrl+Alt+Left/Right on the focused monitor.'
Write-Host 'Ctrl+Win+Left/Right still switches Windows virtual desktops and can trigger the upstream layout issue.'
