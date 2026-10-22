[CmdletBinding()]
param()

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
$shortcut.WindowStyle = 7
$shortcut.Description = 'Start GlazeWM when you sign in.'
$shortcut.Save()

Write-Host "Enabled GlazeWM at sign-in: $shortcutPath"
