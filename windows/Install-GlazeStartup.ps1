# Standalone installer: no dotfiles or configuration files are required.
[CmdletBinding()]
param([string]$GlazeWMPath, [string]$ZebarPath, [switch]$Uninstall, [switch]$Run)
$ErrorActionPreference = 'Stop'
$directory = Join-Path $env:LOCALAPPDATA 'GlazeWMStartup'
$taskName = 'GlazeWM-Zebar Startup'
if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    foreach ($name in @('Start.ps1', 'Start.vbs', 'applications.json')) {
        $path = Join-Path $directory $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    return
}
function Resolve-Application([string]$Path, [string]$Package, [string]$Executable) {
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Executable not found: $Path" }
        return (Resolve-Path -LiteralPath $Path).Path
    }
    $scoop = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
    $candidates = @((Join-Path $scoop "apps\$Package\current\$Executable"),
        (Join-Path $env:ProgramFiles "glzr.io\$Package\$Executable"))
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate) { return $candidate } }
    $command = Get-Command $Executable -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw "Cannot locate $Executable. Supply its full executable path."
}
if ($Run) {
    $mutex = New-Object Threading.Mutex($false, ('Local\GlazeWMStartup-' + (Get-Process -Id $PID).SessionId))
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { return }
        $log = Join-Path $directory 'startup.log'
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 262144) { Clear-Content $log }
        $config = Get-Content (Join-Path $directory 'applications.json') -Raw | ConvertFrom-Json
        $session = (Get-Process -Id $PID).SessionId
        function Find-App([string]$Name) { @(Get-Process -Name $Name -ErrorAction SilentlyContinue | Where-Object SessionId -eq $session) }
        if (-not (Find-App 'GlazeWM')) { Start-Process -FilePath $config.GlazeWM }
        $deadline = [datetime]::UtcNow.AddSeconds(20)
        do {
            $client = New-Object Net.WebSockets.ClientWebSocket
            $client.Options.Proxy=$null
            $timeout=New-Object Threading.CancellationTokenSource
            $timeout.CancelAfter(1000)
            try {
                $null=$client.ConnectAsync([uri]'ws://127.0.0.1:6123',$timeout.Token).GetAwaiter().GetResult()
                $command=[Text.Encoding]::UTF8.GetBytes('query monitors')
                $null=$client.SendAsync([ArraySegment[byte]]::new($command),[Net.WebSockets.WebSocketMessageType]::Text,$true,$timeout.Token).GetAwaiter().GetResult()
                $buffer=New-Object byte[] 65536
                $response=New-Object Text.StringBuilder
                do {
                    $received=$client.ReceiveAsync([ArraySegment[byte]]::new($buffer),$timeout.Token).GetAwaiter().GetResult()
                    $null=$response.Append([Text.Encoding]::UTF8.GetString($buffer,0,$received.Count))
                    if($response.Length -gt 1048576){throw 'Oversized IPC response'}
                }while(-not $received.EndOfMessage)
                $ready=($response.ToString() | ConvertFrom-Json).success -eq $true
            }
            catch { $ready = $false } finally { $client.Dispose(); $timeout.Dispose() }
            if ($ready) { break }
            Start-Sleep -Milliseconds 250
        } while ([datetime]::UtcNow -lt $deadline)
        if (-not $ready) { throw 'GlazeWM IPC did not become available within twenty seconds.' }
        Start-Sleep -Seconds 2
        if (-not (Find-App 'zebar')) { Start-Process -FilePath $config.Zebar }
        Add-Content $log ((Get-Date -Format o) + ' Startup dispatched successfully.')
    } catch {
        Add-Content (Join-Path $directory 'startup.log') ((Get-Date -Format o) + ' ' + $_.Exception.Message)
        throw
    } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
    return
}
$glaze = Resolve-Application $GlazeWMPath 'glazewm' 'GlazeWM.exe'
$zebar = Resolve-Application $ZebarPath 'zebar' 'zebar.exe'
New-Item -ItemType Directory -Path $directory -Force | Out-Null
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $directory 'Start.ps1') -Force
@{ GlazeWM = $glaze; Zebar = $zebar } | ConvertTo-Json | Set-Content (Join-Path $directory 'applications.json') -Encoding UTF8
@'
Option Explicit
Dim shell, files, entry
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
entry = files.BuildPath(files.GetParentFolderName(WScript.ScriptFullName), "Start.ps1")
WScript.Quit shell.Run(Chr(34) & shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe") & Chr(34) & " -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & entry & Chr(34) & " -Run", 0, True)
'@ | Set-Content (Join-Path $directory 'Start.vbs') -Encoding ASCII
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$action = New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\wscript.exe') -Argument ('//B //Nologo "' + (Join-Path $directory 'Start.vbs') + '"')
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
$trigger.Delay = 'PT10S'
$principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Priority 6 -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Startup installed. Log: $directory\startup.log"
