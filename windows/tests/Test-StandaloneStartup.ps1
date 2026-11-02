[CmdletBinding()]
param([switch]$Live)
$ErrorActionPreference = 'Stop'
$entry = Join-Path (Split-Path -Parent $PSScriptRoot) 'Install-GlazeStartup.ps1'
$before = $env:LOCALAPPDATA
$root = Join-Path $env:TEMP ('standalone startup ' + [guid]::NewGuid())
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function New-ScheduledTaskAction { param($Execute,$Argument); [pscustomobject]@{Execute=$Execute;Argument=$Argument} }
function New-ScheduledTaskTrigger { param([switch]$AtLogOn,$User); [pscustomobject]@{Delay='';User=$User} }
function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel); Assert ($RunLevel -eq 'Limited') 'Task requested elevation'; [pscustomobject]@{UserId=$UserId} }
function New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,$Priority,$MultipleInstances,$ExecutionTimeLimit); Assert ($Priority -eq 6) 'Wrong task priority'; @{} }
function Register-ScheduledTask { param($TaskName,$Action,$Trigger,$Principal,$Settings,[switch]$Force); Assert ($TaskName -eq 'GlazeWM-Zebar Startup') 'Unexpected task name'; Assert ($Trigger.Delay -eq 'PT10S') 'Missing delay'; $global:standaloneRegistrations++ }
function Unregister-ScheduledTask { param($TaskName,$Confirm,$ErrorAction); Assert ($TaskName -eq 'GlazeWM-Zebar Startup') 'Uninstalled unrelated task'; $global:standaloneRemoved=$true }
try {
    $env:LOCALAPPDATA=$root
    New-Item -ItemType Directory $root | Out-Null
    $glaze=Join-Path $root 'GlazeWM.exe'; $zebar=Join-Path $root 'zebar.exe'
    [IO.File]::WriteAllText($glaze,'fixture'); [IO.File]::WriteAllText($zebar,'fixture')
    $global:standaloneRegistrations=0
    & $entry -GlazeWMPath $glaze -ZebarPath $zebar
    & $entry -GlazeWMPath $glaze -ZebarPath $zebar
    Assert ($global:standaloneRegistrations -eq 2) 'Repeat install failed'
    $installed=Join-Path $root 'GlazeWMStartup'
    $config=Get-Content (Join-Path $installed 'applications.json') -Raw | ConvertFrom-Json
    Assert ($config.GlazeWM -eq $glaze -and $config.Zebar -eq $zebar) 'Paths changed'
    Assert (Test-Path (Join-Path $installed 'Start.vbs')) 'Hidden launcher missing'
    if ($Live) {
    # A real IPC read with mocked existing processes never launches desktop apps.
    function Get-Process {
        param($Name,[int]$Id,$ErrorAction)
        if($PSBoundParameters.ContainsKey('Id')) { Microsoft.PowerShell.Management\Get-Process -Id $Id }
        else { [pscustomobject]@{SessionId=(Microsoft.PowerShell.Management\Get-Process -Id $PID).SessionId} }
    }
    function Start-Process { throw 'An already-running application was launched again' }
    & $entry -Run
    Assert ((Get-Content (Join-Path $installed 'startup.log') -Raw).Contains('Startup dispatched successfully')) 'Runtime readiness failed'
    }
    [IO.File]::WriteAllText((Join-Path $installed 'unrelated.txt'),'keep')
    & $entry -Uninstall
    Assert $global:standaloneRemoved 'Task not removed'
    Assert (Test-Path (Join-Path $installed 'unrelated.txt')) 'Unrelated file removed'
    Assert (-not (Test-Path (Join-Path $installed 'Start.ps1'))) 'Launcher not removed'
    $failed=$false
    try { & $entry -GlazeWMPath (Join-Path $root 'missing.exe') -ZebarPath $zebar } catch { $failed=$true }
    Assert $failed 'Missing executable accepted'
    Write-Host 'PASS: standalone install, repeat install, paths with spaces, limited task, uninstall and missing executable.'
} finally {
    $env:LOCALAPPDATA=$before
    Remove-Item -LiteralPath $root -Recurse -Force
}
