# Windows PowerShell 5.1. Uses disposable fixtures and mocked Task Scheduler commands.
# No installed applications are stopped or started, and no real tasks are registered.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$windows = Split-Path -Parent $PSScriptRoot
. (Join-Path $windows 'DesktopSettings.ps1')
. (Join-Path $windows 'Start-Desktop.ps1')
function Assert-True { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }
$originalProfile = $env:USERPROFILE
$testRoot = Join-Path $env:TEMP ('dotfiles startup $ fixture-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $scoop = Join-Path $testRoot 'scoop'
    $cli = Join-Path $scoop 'apps\glazewm\current\cli\GlazeWM.exe'
    $gui = Join-Path $scoop 'apps\glazewm\current\GlazeWM.exe'
    $flow = Join-Path $scoop 'apps\flow-launcher\current\Flow.Launcher.exe'
    $everything = Join-Path $scoop 'apps\everything\current\Everything.exe'
    foreach ($path in @($gui, $flow, $everything, $cli)) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    }
    foreach ($path in @($gui, $flow, $everything)) { [IO.File]::WriteAllText($path, '') }
    Add-Type -TypeDefinition @'
using System;
using System.Threading;
public class DotfilesStartupFakeCli {
    public static int Main() {
        Thread.Sleep(Int32.Parse(Environment.GetEnvironmentVariable("DOTFILES_STARTUP_QUERY_DELAY")));
        Console.Error.WriteLine("fixture query output");
        return Int32.Parse(Environment.GetEnvironmentVariable("DOTFILES_STARTUP_QUERY_EXIT"));
    }
}
'@ -OutputAssembly $cli -OutputType ConsoleApplication
    $env:DOTFILES_STARTUP_QUERY_DELAY = '0'
    $env:DOTFILES_STARTUP_QUERY_EXIT = '0'
    Assert-True ((Invoke-StartupProbe $cli) -eq 'ready') 'Successful monitor query was not recognized.'
    $env:DOTFILES_STARTUP_QUERY_EXIT = '2'
    Assert-True ((Invoke-StartupProbe $cli) -like 'monitor query exited 2:*') 'Failed query was not reported.'
    $env:DOTFILES_STARTUP_QUERY_DELAY = '5000'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Assert-True ((Invoke-StartupProbe $cli 150) -eq 'monitor query timed out') 'Hung query was not timed out.'
    Assert-True ($timer.Elapsed.TotalSeconds -lt 2) 'Timed-out query exceeded its bound.'
    Assert-True ((Invoke-StartupProbe (Join-Path $testRoot 'missing.exe')) -like 'monitor query error:*') 'Missing CLI was not reported.'

    # The real CMD entry point must quote paths, close on success, and preserve failure codes without input.
    $entryDirectory = Join-Path $testRoot 'entry point'
    New-Item -ItemType Directory -Path $entryDirectory -Force | Out-Null
    $entry = Join-Path $entryDirectory 'Start-GlazeWM.cmd'
    Copy-Item -LiteralPath (Join-Path $windows 'Start-GlazeWM.cmd') -Destination $entry
    [IO.File]::WriteAllText((Join-Path $entryDirectory 'Start-Desktop.ps1'), 'param([string]$GlazeCli) if ($GlazeCli -ne $env:DOTFILES_STARTUP_EXPECTED_CLI) { exit 9 }; Write-Host "fixture startup summary"; exit ([int]$env:DOTFILES_STARTUP_ENTRY_EXIT)')
    $env:DOTFILES_STARTUP_EXPECTED_CLI = $cli
    foreach ($exitCode in @('0', '7')) {
        $env:DOTFILES_STARTUP_ENTRY_EXIT = $exitCode
        $entryProcess = New-Object Diagnostics.Process
        $entryProcess.StartInfo.FileName = Join-Path $env:WINDIR 'System32\cmd.exe'
        $entryProcess.StartInfo.Arguments = '/d /s /c ""{0}" "{1}""' -f $entry, $cli
        $entryProcess.StartInfo.UseShellExecute = $false
        $entryProcess.StartInfo.CreateNoWindow = $true
        $entryProcess.StartInfo.RedirectStandardInput = $true
        $entryProcess.StartInfo.RedirectStandardOutput = $true
        $entryProcess.StartInfo.RedirectStandardError = $true
        try {
            $null = $entryProcess.Start()
            $entryOutput = $entryProcess.StandardOutput.ReadToEndAsync()
            $entryError = $entryProcess.StandardError.ReadToEndAsync()
            Assert-True ($entryProcess.WaitForExit(5000)) 'Startup terminal did not close.'
            Assert-True ($entryProcess.ExitCode -eq [int]$exitCode) 'CMD entry point changed the exit code or CLI argument.'
            Assert-True ($entryOutput.Result.Contains('fixture startup summary')) 'CMD hid progress output.'
        } finally {
            if (-not $entryProcess.HasExited) { $entryProcess.Kill() }
            $entryProcess.Dispose()
        }
    }

    Copy-Item (Join-Path $windows 'Start-GlazeWM.vbs') $entryDirectory
    foreach ($exitCode in @('0', '7')) {
        $env:DOTFILES_STARTUP_ENTRY_EXIT = $exitCode
        $hidden = Start-Process (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('//B //Nologo "{0}" "{1}"' -f (Join-Path $entryDirectory 'Start-GlazeWM.vbs'), $cli) -PassThru
        try {
            Assert-True ($hidden.WaitForExit(10000)) 'Hidden launcher did not finish.'
            Assert-True ($hidden.ExitCode -eq [int]$exitCode) 'Hidden launcher changed the exit code or CLI path.'
        } finally { if (-not $hidden.HasExited) { $hidden.Kill() }; $hidden.Dispose() }
    }

    # Exercise orchestration independently of application IPC; the real probes are checked separately.
    & {
        $directory = Join-Path $testRoot 'orchestration'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $config = Join-Path $directory 'launcher-startup.json'
        $script:startupEvents = New-Object 'Collections.Generic.List[string]'
        $script:existingApps = $false
        $script:failLaunch = ''
        $script:pendingApp = ''
        function Get-StartupApplicationProcess { param($App); if ($script:existingApps) { [pscustomobject]@{ Id = 1 } } }
        function Initialize-StartupWindows { }
        function Start-StartupDiagnostics { param($Directory); $script:startupEvents.Add('diagnostics') }
        function Start-ConsoleFreeProcess {
            param($FilePath, $Arguments)
            $name = [IO.Path]::GetFileNameWithoutExtension($FilePath)
            $script:startupEvents.Add('launch:' + $name)
            if ($name -eq $script:failLaunch) { throw 'fixture launch failed' }
            return (New-Object IO.MemoryStream)
        }
        function Get-StartupApplicationStatus {
            param($App, $Cli, $TimeoutMilliseconds)
            $script:startupEvents.Add('probe:' + $App.Kind)
            if ($App.Kind -eq $script:pendingApp) { return 'fixture readiness pending' }
            return 'ready'
        }
        Assert-True ((Invoke-DesktopStartup $cli $directory 2 -StageScale 0) -eq 0) 'GlazeWM-only startup failed.'
        Assert-True (($script:startupEvents -join ',') -eq 'launch:GlazeWM,diagnostics,probe:GlazeWM') 'Unconfigured launchers were started.'

        [IO.File]::WriteAllText($config, ([pscustomobject]@{ ScoopRoot = $scoop } | ConvertTo-Json))
        $script:startupEvents.Clear()
        $console = & { $script:startupResult = Invoke-DesktopStartup $cli $directory 2 -StageScale 0 } 6>&1 | Out-String
        Assert-True ($script:startupResult -eq 0) "Configured startup failed: $console"
        Assert-True ((($script:startupEvents | Where-Object { $_ -like 'launch:*' }) -join ',') -eq 'launch:GlazeWM,launch:Everything,launch:Flow.Launcher') "Application dispatch changed order: $($script:startupEvents -join ',')"
        Assert-True ($console.Contains('Startup complete.') -and $console.Contains('Alt+Space')) 'Console did not receive progress and the final summary.'
        Assert-True ([IO.File]::ReadAllText((Join-Path $directory 'startup.log')).Contains('Startup complete.')) 'File did not receive the same summary.'

        $script:existingApps = $true
        $script:startupEvents.Clear()
        Assert-True ((Invoke-DesktopStartup $cli $directory 2 -StageScale 0) -eq 0) 'Existing instances did not pass readiness.'
        Assert-True (@($script:startupEvents | Where-Object { $_ -like 'launch:*' }).Count -eq 0) 'Existing instances were relaunched.'
        $script:existingApps = $false

        $script:failLaunch = 'Flow.Launcher'
        Assert-True ((Invoke-DesktopStartup $cli $directory 2 -StageScale 0) -eq 1) 'Launch failure was reported as success.'
        $script:failLaunch = ''
        Remove-Item -LiteralPath $everything
        $script:startupEvents.Clear()
        Assert-True ((Invoke-DesktopStartup $cli $directory 2 -StageScale 0) -eq 1) 'Missing application was reported as success.'
        Assert-True ($script:startupEvents.Contains('launch:Flow.Launcher')) 'One missing application blocked another launch.'
        [IO.File]::WriteAllText($everything, '')

        $script:pendingApp = 'GlazeWM'
        $timer.Restart()
        Assert-True ((Invoke-DesktopStartup $cli $directory 1 -StageScale 0) -eq 1) 'Unconfirmed readiness was reported as success.'
        Assert-True ($timer.Elapsed.TotalSeconds -lt 3) 'Overall readiness timeout was not bounded.'
        $script:pendingApp = ''
        [IO.File]::WriteAllText($config, '{}')
        Assert-True ((Invoke-DesktopStartup $cli $directory 2 -StageScale 0) -eq 1) 'Invalid launcher opt-in was silently ignored.'
    }

    # Real staged ordering with accelerated offsets; no application processes or IPC.
    & {
        $directory = Join-Path $testRoot 'stages'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $directory 'launcher-startup.json'), ([pscustomobject]@{ ScoopRoot = $scoop } | ConvertTo-Json))
        [IO.File]::WriteAllText((Join-Path $directory 'desktop-startup.json'), '{"ZebarEnabled":true,"WallpaperMode":"Overlay"}')
        $script:stagedEvents = New-Object 'Collections.Generic.List[string]'
        $script:cancelStage = $false
        function Get-StartupApplicationProcess { param($App) }
        function Initialize-StartupWindows { }
        function Start-StartupDiagnostics { param($Directory) }
        function Start-StartupApplication {
            param($App)
            $App.Dispatched = $true
            $script:stagedEvents.Add($App.Kind)
            if ($App.Kind -eq 'Everything' -and $script:cancelStage) {
                $stop = [Threading.EventWaitHandle]::OpenExisting('Local\DotfilesDesktopStartupStop')
                try { $null = $stop.Set() } finally { $stop.Dispose() }
            }
        }
        function Start-StartupScript { param($Directory, $Script, $Arguments); $script:stagedEvents.Add($Script) }
        function Get-StartupApplicationStatus { param($App, $Cli, $TimeoutMilliseconds); return 'ready' }
        Assert-True ((Invoke-DesktopStartup $cli $directory 3 -StageScale 0.02) -eq 0) 'Staged startup failed.'
        $events = $script:stagedEvents -join ','
        Assert-True ($events.StartsWith('GlazeWM,') -and $events.EndsWith('Flow,Zebar,Wallpaper.ps1')) "Companion order changed: $events"
        Assert-True ($script:stagedEvents.IndexOf('Watch-FlowWorkspace.ps1') -lt $script:stagedEvents.IndexOf('Flow')) 'Flow started before its workspace helper.'
        $script:stagedEvents.Clear()
        Assert-True ((Invoke-DesktopStartup $cli $directory 3 -StageScale 0.02 -CompanionsOnly) -eq 0) 'Manual companion startup failed.'
        Assert-True (-not $script:stagedEvents.Contains('GlazeWM')) 'Companion-only entry point launched GlazeWM again.'
        $script:stagedEvents.Clear(); $script:cancelStage = $true
        Assert-True ((Invoke-DesktopStartup $cli $directory 3 -StageScale 0.02) -eq 0) 'Shutdown cancellation failed.'
        Assert-True (-not $script:stagedEvents.Contains('Flow') -and -not $script:stagedEvents.Contains('Wallpaper.ps1')) 'Shutdown allowed delayed helpers to start.'
    }

    # Current-process Flow logs, including locked files, bootstrap handoff, and midnight rotation.
    $logDirectory = Join-Path (Split-Path -Parent $flow) 'app-2.1.4\UserData\Logs\2.1.4'
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
    function Write-FlowFixtureLine {
        param([DateTimeOffset]$Time, [string]$Message)
        $path = Join-Path $logDirectory ('Flow.Launcher.' + $Time.ToString('yyyy-MM-dd') + '.log')
        Add-Content -LiteralPath $path -Value ($Time.ToString('HH:mm:ss.ffffzzz') + ' - INFO  - App.OnStartup - ' + $Message)
    }
    $start = [DateTimeOffset]::Parse('2026-01-15T23:59:58+01:00')
    Write-FlowFixtureLine ($start.AddSeconds(-2)) 'End Flow Launcher startup'
    Write-FlowFixtureLine ($start.AddSeconds(-1)) 'End plugin initialization'
    Assert-True ((Get-FlowStartupStatus $logDirectory $start.UtcDateTime) -ne 'ready') 'Historical Flow log markers were reused.'
    Write-FlowFixtureLine ($start.AddSeconds(1)) 'End Flow Launcher startup'
    Assert-True ((Get-FlowStartupStatus $logDirectory $start.UtcDateTime) -eq 'waiting for plugin initialization') 'Flow plugins were prematurely marked ready.'
    Write-FlowFixtureLine ($start.AddSeconds(2)) 'End plugin initialization'
    $lockedLog = [IO.File]::Open((Join-Path $logDirectory 'Flow.Launcher.2026-01-16.log'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try { Assert-True ((Get-FlowStartupStatus $logDirectory $start.UtcDateTime) -eq 'ready') 'Locked or midnight-rotated Flow logs could not be read.' }
    finally { $lockedLog.Dispose() }
    & {
        $script:flowFixtureProcesses = @([pscustomobject]@{ Path = $flow; StartTime = $start.UtcDateTime })
        function Get-StartupApplicationProcess { param($App); $script:flowFixtureProcesses }
        $app = New-StartupApplication 'Flow Launcher' 'Flow' $flow (Split-Path -Parent (Split-Path -Parent $flow))
        Assert-True ((Get-StartupApplicationStatus $app $cli 100) -ne 'ready') 'Flow bootstrapper was mistaken for the application.'
        $script:flowFixtureProcesses = @([pscustomobject]@{ Path = (Join-Path (Split-Path -Parent $flow) 'app-2.1.4\Flow.Launcher.exe'); StartTime = $start.UtcDateTime })
        Assert-True ((Get-StartupApplicationStatus $app $cli 100) -eq 'ready') 'Flow application handoff was not recognized.'
    }
    Write-FlowFixtureLine ($start.AddSeconds(3)) 'ERROR hotkey registration failed'
    Assert-True ((Get-FlowStartupStatus $logDirectory $start.UtcDateTime) -like 'hotkey registration failed*') 'Hotkey registration error was ignored.'

    # A different thread owns the session mutex while this invocation tries to enter.
    $worker = [PowerShell]::Create()
    $entered = New-Object Threading.ManualResetEvent($false)
    $release = New-Object Threading.ManualResetEvent($false)
    try {
        $null = $worker.AddScript('param($entered, $release) $m = New-Object Threading.Mutex($false, "Local\DotfilesDesktopStartup"); $locked = $false; try { $locked = $m.WaitOne(2000); if ($locked) { $null = $entered.Set(); $null = $release.WaitOne(10000) } } finally { if ($locked) { $m.ReleaseMutex() }; $m.Dispose() }').AddArgument($entered).AddArgument($release)
        $pending = $worker.BeginInvoke()
        Assert-True ($entered.WaitOne(3000)) 'Could not acquire fixture startup mutex.'
        Assert-True ((Invoke-DesktopStartup $cli (Join-Path $testRoot 'orchestration') 1) -eq 0) 'Concurrent invocation did not exit cleanly.'
        $null = $release.Set()
        $null = $worker.EndInvoke($pending)
    } finally { $null = $release.Set(); $worker.Dispose(); $entered.Dispose(); $release.Dispose() }

    # Real file migration and restore, with Task Scheduler calls replaced by fixtures.
    $env:USERPROFILE = Join-Path $testRoot 'profile'
    & {
        $installed = Join-Path $env:USERPROFILE '.glzr\glazewm'
        $shortcuts = Join-Path $testRoot 'Startup'
        New-Item -ItemType Directory -Path $shortcuts -Force | Out-Null
        $names = @('GlazeWM.lnk', 'Flow Launcher (dotfiles).lnk', 'Everything (dotfiles).lnk')
        foreach ($name in $names + @('Keep.lnk')) { [IO.File]::WriteAllText((Join-Path $shortcuts $name), $name) }
        $script:denyRegistration = $false
        $script:taskOwner = $null
        function Get-ScheduledTask { param($TaskName, $TaskPath, $ErrorAction); if ($script:taskOwner) { [pscustomobject]@{ Principal = [pscustomobject]@{ UserId = $script:taskOwner } } } }
        function New-ScheduledTaskAction { param($Execute, $Argument, $WorkingDirectory); [pscustomobject]@{ Execute = $Execute; Arguments = $Argument; WorkingDirectory = $WorkingDirectory } }
        function New-ScheduledTaskTrigger { param([switch]$AtLogOn, $User); [pscustomobject]@{ Delay = ''; UserId = $User } }
        function New-ScheduledTaskPrincipal { param($UserId, $LogonType, $RunLevel); [pscustomobject]@{ UserId = $UserId; LogonType = $LogonType; RunLevel = $RunLevel } }
        function New-ScheduledTaskSettingsSet { param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, $MultipleInstances, $ExecutionTimeLimit, $Priority); [pscustomobject]@{ MultipleInstances = $MultipleInstances; ExecutionTimeLimit = $ExecutionTimeLimit; Priority = $Priority } }
        function Unregister-ScheduledTask { param($TaskName, $TaskPath, $Confirm, $ErrorAction) }
        function Register-ScheduledTask {
            param($TaskName, $TaskPath, $Action, $Trigger, $Principal, $Settings, $Description, [switch]$Force)
            if ($script:denyRegistration) { throw 'fixture registration denied' }
            Assert-True ($Trigger.Delay -eq 'PT10S' -and $Principal.RunLevel -eq 'Limited') 'Task timing or privileges changed.'
            Assert-True ($Settings.Priority -eq 6) 'Interactive startup must use normal priority.'
            Assert-True ($Settings.MultipleInstances -eq 'IgnoreNew') 'Task permits duplicate invocations.'
            Assert-True ($Action.Execute -like '*\DesktopLauncher.exe') 'Task must use the console-free launcher.'
            Assert-True ($Action.Arguments.StartsWith('startup ')) 'Task omitted hidden launcher.'
            Assert-True ($Action.Arguments.Contains($cli)) 'Task omitted the quoted CLI argument.'
        }
        Register-DesktopStartup -ScoopRoot $scoop -LauncherDirectory $installed -StartupDirectory $shortcuts -Diagnostics
        $backup = $script:settingsBackup
        $config = Join-Path $installed 'launcher-startup.json'
        $firstConfig = [IO.File]::ReadAllText($config)
        Assert-True ((Read-SettingJson $config).ScoopRoot -eq $scoop) 'Legacy launcher opt-in was not migrated.'
        foreach ($name in $names) { Assert-True (-not (Test-Path -LiteralPath (Join-Path $shortcuts $name))) 'Migrated shortcut remains active.' }
        Assert-True (Test-Path -LiteralPath (Join-Path $shortcuts 'Keep.lnk')) 'Unrelated shortcut was removed.'
        foreach ($name in @('Start-Desktop.ps1', 'Start-GlazeWM.cmd', 'Start-GlazeWM.vbs', 'Measure-GlazeWMStartup.ps1')) {
            Assert-True (Test-Path -LiteralPath (Join-Path $installed $name)) 'Startup implementation was not installed.'
        }
        Register-DesktopStartup -ScoopRoot $scoop -LauncherDirectory $installed -StartupDirectory $shortcuts
        Assert-True ([IO.File]::ReadAllText($config) -eq $firstConfig) 'Repeated migration changed launcher opt-in.'
        Assert-True (Test-Path -LiteralPath (Join-Path $installed 'diagnostics.enabled')) 'Ordinary startup repair disabled diagnostics.'

        & {
            # Restore's real Stop-DesktopApp helper sees no application processes.
            function Get-Process { param($Id, $Name, $ErrorAction); if ($Id) { Microsoft.PowerShell.Management\Get-Process -Id $Id } }
            function Stop-Process {
                [CmdletBinding()]
                param([Parameter(ValueFromPipeline = $true)]$InputObject, [switch]$Force)
                process { if ($null -ne $InputObject) { throw 'Restore attempted to stop a real process.' } }
            }
            & (Join-Path $windows 'Restore-DesktopSettings.ps1') -BackupPath $backup
        }
        Assert-True (-not (Test-Path -LiteralPath $config)) 'Restore did not recover absent launcher opt-in.'
        foreach ($name in $names) { Assert-True ([IO.File]::ReadAllText((Join-Path $shortcuts $name)) -eq $name) 'Restore lost a legacy shortcut.' }

        $script:denyRegistration = $true
        $failed = $false
        try { Register-DesktopStartup -ScoopRoot $scoop -LauncherDirectory $installed -StartupDirectory $shortcuts -DisableDiagnostics }
        catch { $failed = $_.Exception.Message -eq 'fixture registration denied' }
        Assert-True $failed 'Registration failure was swallowed.'
        Assert-True (-not (Test-Path -LiteralPath $config)) 'Failed registration changed opt-in.'
        foreach ($name in $names) { Assert-True (Test-Path -LiteralPath (Join-Path $shortcuts $name)) 'Failed registration removed a shortcut.' }
        Assert-True (Test-Path -LiteralPath (Join-Path $installed 'diagnostics.enabled')) 'Failed registration changed diagnostics.'
        $script:denyRegistration = $false
        foreach ($name in $names) { Remove-Item -LiteralPath (Join-Path $shortcuts $name) }
        Register-DesktopStartup -ScoopRoot $scoop -LauncherDirectory $installed -StartupDirectory $shortcuts
        Assert-True (-not (Test-Path -LiteralPath $config)) 'Installed packages alone enabled launchers.'
        Register-DesktopStartup -ScoopRoot $scoop -LauncherDirectory $installed -StartupDirectory $shortcuts -WithLauncher -DisableDiagnostics
        Assert-True (Test-Path -LiteralPath $config) 'Explicit launcher opt-in failed.'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $installed 'diagnostics.enabled'))) 'Explicit diagnostics disable failed.'
        $script:taskOwner = 'another-account'
        $failed = $false
        try { Register-DesktopStartup -ScoopRoot $scoop -LauncherDirectory $installed -StartupDirectory $shortcuts }
        catch { $failed = $_.Exception.Message -like '*belongs to another account*' }
        Assert-True $failed 'Another account task was replaced.'
    }

    # An actual child collector must remain hidden and continue logging after its parent exits.
    $detached = Join-Path $testRoot "detached collector's directory"
    New-Item -ItemType Directory -Path $detached -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $detached 'diagnostics.enabled'), 'startup')
    $collector = @'
param([string]$OutputDirectory)
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class StartupCollectorWindow { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd); }'
$handle = [StartupCollectorWindow]::GetConsoleWindow()
[pscustomobject]@{ Pid = $PID; Visible = [StartupCollectorWindow]::IsWindowVisible($handle) } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'started.json')
Start-Sleep -Seconds 4
Write-Host 'collector output after parent exit'
Set-Content -LiteralPath (Join-Path $OutputDirectory 'completed.txt') -Value 'complete'
'@
    [IO.File]::WriteAllText((Join-Path $detached 'Measure-GlazeWMStartup.ps1'), $collector)
    $parentScript = Join-Path $testRoot 'parent.ps1'
    $parent = ". '" + (Join-Path $windows 'Start-Desktop.ps1').Replace("'", "''") + "'`r`n" +
        '$script:startupWatch = [Diagnostics.Stopwatch]::StartNew()' + "`r`n" +
        '$script:startupLog = ' + "'" + (Join-Path $detached 'startup.log').Replace("'", "''") + "'`r`n" +
        "Start-StartupDiagnostics '" + $detached.Replace("'", "''") + "'`r`n"
    [IO.File]::WriteAllText($parentScript, $parent)
    $hostPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $parentProcess = Start-Process -FilePath $hostPath -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $parentScript) -WindowStyle Hidden -PassThru
    try {
        Assert-True ($parentProcess.WaitForExit(10000)) 'Collector kept its parent startup process alive.'
        Assert-True ($parentProcess.ExitCode -eq 0) 'Collector parent failed.'
        $done = Join-Path $detached 'diagnostics\completed.txt'
        Assert-True (-not (Test-Path -LiteralPath $done)) 'Parent waited for the collector to finish.'
        $deadline = (Get-Date).AddSeconds(15)
        while (-not (Test-Path -LiteralPath $done) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
        Assert-True (Test-Path -LiteralPath $done) 'Collector did not survive parent exit.'
        $info = Read-SettingJson (Join-Path $detached 'diagnostics\started.json')
        Assert-True (-not $info.Visible) 'Diagnostic collector console is visible.'
        $logs = @(Get-ChildItem -LiteralPath (Join-Path $detached 'diagnostics') -Filter '*-collector.log')
        Assert-True ($logs.Count -eq 1 -and (Get-Content -LiteralPath $logs[0].FullName -Raw).Contains('collector output after parent exit')) 'Collector output was lost after parent exit.'
    } finally { $parentProcess.Dispose() }
    Write-Host 'PASS: startup ordering, duplicate prevention, errors/timeouts, Flow handoff/readiness, migration/restore, and detached diagnostics.'
} finally {
    $env:USERPROFILE = $originalProfile
    Remove-Item Env:DOTFILES_STARTUP_QUERY_DELAY -ErrorAction SilentlyContinue
    Remove-Item Env:DOTFILES_STARTUP_QUERY_EXIT -ErrorAction SilentlyContinue
    Remove-Item Env:DOTFILES_STARTUP_EXPECTED_CLI -ErrorAction SilentlyContinue
    Remove-Item Env:DOTFILES_STARTUP_ENTRY_EXIT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
