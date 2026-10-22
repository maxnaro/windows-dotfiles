[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
$glazeExe = Join-Path $scoopRoot 'apps\glazewm\current\GlazeWM.exe'
if (-not (Test-Path -LiteralPath $glazeExe -PathType Leaf)) {
    throw "GlazeWM executable not found: $glazeExe"
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
$shortcut.TargetPath = $glazeExe
$shortcut.Arguments = ''
$shortcut.WorkingDirectory = Split-Path -Parent $glazeExe
$shortcut.Description = 'Start GlazeWM when you sign in.'
$shortcut.Save()

Write-Host "Enabled GlazeWM at sign-in: $shortcutPath"
