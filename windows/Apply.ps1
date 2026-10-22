[CmdletBinding()]
param(
    [ValidateRange(0, 9)]
    [int]$MonitorCount = 0,
    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$configPath = Join-Path $env:USERPROFILE '.glzr\glazewm\config.yaml'
$settingsPath = Join-Path $env:USERPROFILE '.glzr\zebar\settings.json'
$packPath = Join-Path $env:USERPROFILE '.glzr\zebar\multimonitor'

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
if ($hadConfig) {
    Copy-Item -LiteralPath $configPath -Destination (Join-Path $backupPath 'config.yaml')
}
if ($hadSettings) {
    Copy-Item -LiteralPath $settingsPath -Destination (Join-Path $backupPath 'settings.json')
}
if ($hadPack) {
    Copy-Item -LiteralPath $packPath -Destination (Join-Path $backupPath 'multimonitor') -Recurse
}
@{ hadConfig = $hadConfig; hadSettings = $hadSettings; hadPack = $hadPack } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupPath 'previous-state.json') -Encoding UTF8

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $configPath) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $settingsPath) -Force | Out-Null
    if ($hadPack) { Remove-Item -LiteralPath $packPath -Recurse -Force }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'multimonitor') -Destination $packPath -Recurse
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'settings.json') -Destination $settingsPath
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($configPath, $config, $utf8)
} catch {
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
    foreach ($exe in @($glazeCli, $glazeExe, $zebarExe)) {
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
            throw "Executable not found: $exe"
        }
    }
    $sessionId = (Get-Process -Id $PID).SessionId
    $runningGlaze = @(Get-Process -Name GlazeWM -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $sessionId })
    if ($runningGlaze.Count -gt 0) {
        & $glazeCli command wm-exit
        if ($LASTEXITCODE -ne 0) {
            throw 'GlazeWM did not accept the graceful exit command.'
        }
        for ($attempt = 0; $attempt -lt 40; $attempt++) {
            $runningGlaze = @(Get-Process -Name GlazeWM -ErrorAction SilentlyContinue |
                Where-Object { $_.SessionId -eq $sessionId })
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
    Start-Process -FilePath $glazeExe
    # Your existing GlazeWM startup command launches Zebar.
    Start-Sleep -Seconds 3
    $runningZebar = @(Get-Process -Name zebar -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $sessionId })
    if ($runningZebar.Count -eq 0) {
        Start-Process -FilePath $zebarExe
        Start-Sleep -Seconds 2
    }
    & $glazeCli command wm-redraw
    if ($LASTEXITCODE -ne 0) {
        throw 'GlazeWM is not ready to redraw yet.'
    }
} catch {
    Write-Warning "Settings are installed, but refreshing the apps failed: $_"
    Write-Warning 'Exit and relaunch GlazeWM from its tray menu/Start menu, then launch Zebar if needed.'
}

Write-Host 'Use Alt+1..9 for workspaces, or Ctrl+Alt+Left/Right on the focused monitor.'
Write-Host 'Ctrl+Win+Left/Right still switches Windows virtual desktops and can trigger the upstream layout issue.'
