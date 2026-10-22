[CmdletBinding()]
param(
    [switch]$LogStartup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
$glazeCli = Join-Path $scoopRoot 'apps\glazewm\current\cli\GlazeWM.exe'
if (-not (Test-Path -LiteralPath $glazeCli -PathType Leaf)) {
    throw "GlazeWM CLI not found: $glazeCli"
}

# The current user's Startup folder works without administrator privileges.
$startupPath = [Environment]::GetFolderPath('Startup')
if ([string]::IsNullOrWhiteSpace($startupPath)) {
    throw 'Unable to locate the current user Startup folder.'
}
New-Item -ItemType Directory -Path $startupPath -Force | Out-Null
$shortcutPath = Join-Path $startupPath 'GlazeWM.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
# The CLI handles the UIAccess launch requirements of the main executable.
$shortcut.TargetPath = $glazeCli
$shortcut.Arguments = 'start'
$shortcut.WorkingDirectory = Split-Path -Parent $glazeCli
if ($LogStartup) {
    $launcherDir = Join-Path $env:USERPROFILE '.glzr\glazewm'
    New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null
    $launcherPath = Join-Path $launcherDir 'Start-GlazeWM.cmd'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Start-GlazeWM.cmd') -Destination $launcherPath -Force
    $shortcut.TargetPath = Join-Path $env:WINDIR 'System32\cmd.exe'
    $shortcut.Arguments = '/d /s /c ""{0}" "{1}""' -f $launcherPath, $glazeCli
    $shortcut.WorkingDirectory = $launcherDir
}
$shortcut.WindowStyle = 7
$shortcut.Description = 'Start GlazeWM when you sign in.'
$shortcut.Save()

Write-Host "Registered GlazeWM startup entry: $shortcutPath"
if ($LogStartup) {
    Write-Host "Startup log: $(Join-Path $launcherDir 'startup.log')"
}
