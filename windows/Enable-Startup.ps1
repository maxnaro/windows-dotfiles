[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
$glazeCli = Join-Path $scoopRoot 'apps\glazewm\current\cli\GlazeWM.exe'
if (-not (Test-Path -LiteralPath $glazeCli -PathType Leaf)) {
    throw "GlazeWM CLI not found: $glazeCli"
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$userSid = $identity.User.Value
$taskName = 'GlazeWM'
$existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
# Task Scheduler can return the account name without its domain.
$accountNames = @($userSid, $identity.Name, ($identity.Name -split '\\')[-1])
if ($existingTask -and $existingTask.Principal.UserId -notin $accountNames) {
    throw 'An existing GlazeWM scheduled task belongs to another account.'
}

$launcherDir = Join-Path $env:USERPROFILE '.glzr\glazewm'
New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null
$launcherPath = Join-Path $launcherDir 'Start-GlazeWM.cmd'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Start-GlazeWM.cmd') -Destination $launcherPath -Force

# A logon task avoids Explorer's delayed processing of the Startup folder.
$action = New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\cmd.exe') `
    -Argument ('/d /s /c ""{0}" "{1}""' -f $launcherPath, $glazeCli) -WorkingDirectory $launcherDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userSid
$trigger.Delay = 'PT10S'
$principal = New-ScheduledTaskPrincipal -UserId $userSid -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Description 'Start GlazeWM at sign-in for this user (Windows dotfiles).' -Force | Out-Null

# Retire the old entry only after registration succeeds, preserving a backup.
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'GlazeWM.lnk'
if (Test-Path -LiteralPath $shortcutPath) {
    $backupDir = Join-Path $env:USERPROFILE ('.glzr\backups\startup-task-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Move-Item -LiteralPath $shortcutPath -Destination (Join-Path $backupDir 'GlazeWM.lnk')
    Write-Host "Previous Startup shortcut backed up to: $backupDir"
}

Write-Host "Registered $taskName logon task for $($identity.Name) with a 10-second delay."
Write-Host "Startup log: $(Join-Path $launcherDir 'startup.log')"
