# Windows PowerShell 5.1. Real WSH/PowerShell launchers with disposable scripts.
# Does not start/stop installed applications or register tasks.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$windows = Split-Path -Parent $PSScriptRoot
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Wait-File([string]$Path) {
    $deadline = [datetime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $Path) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
    Assert (Test-Path -LiteralPath $Path) "Fixture did not produce $Path"
}
function Read-FixtureJson([string]$Path) {
    $deadline = [datetime]::UtcNow.AddSeconds(15)
    do {
        try {
            if (Test-Path -LiteralPath $Path) {
                $data = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
                if ($data -and $data.PSObject.Properties['Pid']) { return $data }
            }
        } catch { } # The child may still be writing the small fixture record.
        Start-Sleep -Milliseconds 25
    } while ([datetime]::UtcNow -lt $deadline)
    throw "Fixture did not complete JSON record $Path"
}
$root = Join-Path $env:TEMP ("desktop launcher $ fixture's & %DOTFILES_QUOTE_SENTINEL%-" + [guid]::NewGuid())
$names = @('DOTFILES_QUOTE_SENTINEL', 'DOTFILES_LAUNCHER_EXIT', 'DOTFILES_LAUNCHER_MODE', 'DOTFILES_FIXTURE_ORCHESTRATOR', 'DOTFILES_FIXTURE_INSTANCE')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$processes = New-Object 'Collections.Generic.List[Diagnostics.Process]'
$children = New-Object 'Collections.Generic.List[object]'
New-Item -ItemType Directory -Path $root -Force | Out-Null
function Start-Launcher([string]$Argument) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $env:WINDIR 'System32\wscript.exe'
    $info.Arguments = '//B //Nologo "' + (Join-Path $root 'Start-GlazeWM.vbs') + '"'
    if ($Argument) { $info.Arguments += ' "' + $Argument + '"' }
    $info.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($info)
    $processes.Add($process)
    return $process
}
function Get-ChildLog([string]$Action, [int]$ChildId) {
    $marker = "$Action dispatched (PID $ChildId); child status/errors: "
    $entry = Get-Content -LiteralPath (Join-Path $root 'desktop-launcher.log') | Where-Object { $_.Contains($marker) } | Select-Object -Last 1
    Assert ([bool]$entry) "Missing dispatch/log record for $Action PID $ChildId"
    return $entry.Substring($entry.IndexOf($marker) + $marker.Length)
}
function Read-ResidentLog([string]$Path, [int]$ChildId) {
    $needle = "fixture resident output after dispatcher exit PID $ChildId"
    $deadline = [datetime]::UtcNow.AddSeconds(5)
    do {
        $text = if (Test-Path -LiteralPath $Path) { [string](Get-Content -LiteralPath $Path -Raw) } else { '' }
        if ($text.Contains($needle)) { return $text }
        Start-Sleep -Milliseconds 25
    } while ([datetime]::UtcNow -lt $deadline)
    throw "Child logging was lost after dispatcher exit: $Path"
}
function Stop-FixtureChildren {
    $records = @($children.ToArray())
    # Recover ownership even if an assertion failed before child registration.
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.owned.json' -ErrorAction SilentlyContinue)) {
        try { $records += Read-FixtureJson $file.FullName } catch { }
    }
    $seen = @{}
    foreach ($child in $records) {
        if (-not $child.PSObject.Properties['StartTimeUtcTicks']) { continue }
        $key = "$($child.Pid):$($child.StartTimeUtcTicks)"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $running = Get-Process -Id $child.Pid -ErrorAction SilentlyContinue
        if ($running) {
            try {
                if ($running.ProcessName -eq 'powershell' -and $running.StartTime.ToUniversalTime().Ticks -eq $child.StartTimeUtcTicks) { $running.Kill(); $null = $running.WaitForExit(3000) }
            } catch { } finally { $running.Dispose() }
        }
    }
}
try {
    $env:DOTFILES_FIXTURE_INSTANCE = ''
    $env:DOTFILES_QUOTE_SENTINEL = 'THIS-MUST-NOT-BE-EXPANDED'
    $env:DOTFILES_FIXTURE_ORCHESTRATOR = Join-Path $windows 'Start-Desktop.ps1'
    foreach ($file in @('Start-GlazeWM.vbs', 'Start-DesktopLauncher.ps1', 'HelperCache.ps1')) {
        Copy-Item -LiteralPath (Join-Path $windows $file) -Destination $root
    }
    $vbs = Get-Content -LiteralPath (Join-Path $root 'Start-GlazeWM.vbs') -Raw
    Assert ($vbs.Contains('shell.Run(command, 7, True)')) 'Launcher no longer requests minimized/no-activation or waits for startup.'
    $native = @'
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class LauncherConsoleFixture { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h); [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h); }'
'@
    $resident = @'
param([switch]$Restart, [switch]$Stop, [switch]$WaitForStop, [switch]$StopCompanions)
$action = $env:DOTFILES_DESKTOP_ACTION
if ($env:DOTFILES_FIXTURE_INSTANCE) { $action += '-' + $env:DOTFILES_FIXTURE_INSTANCE }
[pscustomobject]@{ Pid = $PID; StartTimeUtcTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot ($action + '.owned.json'))
'@ + "`r`n" + $native + @'

$handle = [LauncherConsoleFixture]::GetConsoleWindow()
[pscustomobject]@{ Pid = $PID; StartTimeUtcTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks; Console = $handle.ToInt64(); Restart = [bool]$Restart; Stop = [bool]$Stop; WaitForStop = [bool]$WaitForStop; StopCompanions = [bool]$StopCompanions } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot ($action + '.started.json'))
$deadline = [datetime]::UtcNow.AddSeconds(20)
while (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot ($action + '.release'))) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
if ([datetime]::UtcNow -ge $deadline) { throw 'Resident fixture was not released.' }
Write-Host "fixture resident output after dispatcher exit PID $PID"
Set-Content -LiteralPath (Join-Path $PSScriptRoot ($action + '.completed')) -Value 'complete'
exit 0
'@
    [IO.File]::WriteAllText((Join-Path $root 'Fixture-Resident.ps1'), $resident)
    $watcher = @'
param([switch]$Restart, [switch]$Stop, [switch]$WaitForStop)
& (Join-Path $PSScriptRoot 'Fixture-Resident.ps1') @PSBoundParameters
exit $LASTEXITCODE
'@
    foreach ($file in @('Watch-TitleBars.ps1', 'Watch-FlowWorkspace.ps1')) { [IO.File]::WriteAllText((Join-Path $root $file), $watcher) }
    $startup = @'
param([string]$GlazeCli, [switch]$CompanionsOnly, [switch]$StopCompanions)
if ($StopCompanions) { & (Join-Path $PSScriptRoot 'Fixture-Resident.ps1') -StopCompanions; exit $LASTEXITCODE }
[pscustomobject]@{ Pid = $PID; StartTimeUtcTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'Startup.owned.json')
'@ + "`r`n" + $native + @'

$handle = [LauncherConsoleFixture]::GetConsoleWindow()
[pscustomobject]@{ Pid = $PID; StartTimeUtcTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks; Console = $handle.ToInt64(); Visible = [LauncherConsoleFixture]::IsWindowVisible($handle); Minimized = [LauncherConsoleFixture]::IsIconic($handle); Cli = $GlazeCli; CompanionsOnly = [bool]$CompanionsOnly } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'startup.started.json')
if ($env:DOTFILES_LAUNCHER_MODE -eq 'timeout') {
    . $env:DOTFILES_FIXTURE_ORCHESTRATOR
    function Start-StartupApplication { param($App); $App.Dispatched = $true }
    function Start-StartupDiagnostics { param($Directory) }
    function Get-StartupApplicationStatus { param($App, $Cli, $TimeoutMilliseconds); return 'fixture readiness pending' }
    $result = Invoke-DesktopStartup -Cli (Join-Path $PSScriptRoot 'scoop\apps\glazewm\current\cli\GlazeWM.exe') -Directory $PSScriptRoot -TimeoutSeconds 1
    exit $result
}
$deadline = [datetime]::UtcNow.AddSeconds(20)
while (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'startup.release')) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
if ([datetime]::UtcNow -ge $deadline) { throw 'Startup fixture was not released.' }
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'startup.completed') -Value 'ready'
exit ([int]$env:DOTFILES_LAUNCHER_EXIT)
'@
    [IO.File]::WriteAllText((Join-Path $root 'Start-Desktop.ps1'), $startup)
    $cli = "C:\fixture $ ' & (test) %DOTFILES_QUOTE_SENTINEL%\cli.exe"
    $env:DOTFILES_LAUNCHER_MODE = 'normal'
    foreach ($case in @(
        @{ Argument = $cli; ExitCode = 0; Companion = $false },
        @{ Argument = $cli; ExitCode = 7; Companion = $false },
        @{ Argument = '--companions'; ExitCode = 0; Companion = $true },
        @{ Argument = ''; ExitCode = 0; Companion = $false }
    )) {
        foreach ($file in @('startup.started.json', 'startup.release', 'startup.completed')) {
            $path = Join-Path $root $file
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
        }
        $env:DOTFILES_LAUNCHER_EXIT = [string]$case.ExitCode
        $process = Start-Launcher $case.Argument
        $started = Join-Path $root 'startup.started.json'
        $details = Read-FixtureJson $started
        $children.Add($details)
        Assert ($details.CompanionsOnly -eq $case.Companion) 'Companion-only mode was not forwarded.'
        $expectedCli = if ($case.Argument -eq $cli) { $cli } else { '' }
        Assert ($details.Cli -eq $expectedCli) 'CLI data was expanded or interpreted as PowerShell/CMD source.'
        if ($details.Visible) { Assert $details.Minimized 'The visible traditional startup console was not minimized.' }
        else { Write-Host 'INFO: native console is not visible; outer Windows Terminal state needs interactive validation.' }
        Start-Sleep -Milliseconds 200
        Assert (-not $process.HasExited) 'Launcher detached before initialization completed.'
        Set-Content -LiteralPath (Join-Path $root 'startup.release') -Value 'ready'
        Assert ($process.WaitForExit(10000)) 'Launcher did not close automatically after initialization.'
        Assert ($process.ExitCode -eq $case.ExitCode) 'Launcher lost the startup exit code.'
        Assert (Test-Path -LiteralPath (Join-Path $root 'startup.completed')) 'Launcher exited before readiness.'
    }
    # Exercise the real orchestrator deadline behind the actual minimized launcher.
    Remove-Item -LiteralPath (Join-Path $root 'startup.started.json')
    $cliFixture = Join-Path $root 'scoop\apps\glazewm\current\cli\GlazeWM.exe'
    New-Item -ItemType Directory -Path (Split-Path -Parent $cliFixture) -Force | Out-Null
    [IO.File]::WriteAllText($cliFixture, '')
    $env:DOTFILES_LAUNCHER_MODE = 'timeout'
    $process = Start-Launcher $cli
    $children.Add((Read-FixtureJson (Join-Path $root 'startup.started.json')))
    Assert ($process.WaitForExit(10000) -and $process.ExitCode -eq 1) 'Readiness timeout did not close the launcher with failure.'
    Assert ((Get-Content -LiteralPath (Join-Path $root 'startup.log') -Raw).Contains('readiness not confirmed within 1 seconds')) 'Readiness timeout was not logged.'
    # Resident children must survive their short-lived dispatcher without a console.
    foreach ($case in @(
        @{ Argument = '--title-bars-restart'; Action = 'TitleBarsRestart'; Restart = $true; Stop = $false; Wait = $false; StopCompanions = $false },
        @{ Argument = '--flow-restart'; Action = 'FlowRestart'; Restart = $true; Stop = $false; Wait = $false; StopCompanions = $false },
        @{ Argument = '--flow-start'; Action = 'FlowStart'; Restart = $false; Stop = $false; Wait = $false; StopCompanions = $false },
        @{ Argument = '--flow-stop'; Action = 'FlowStop'; Restart = $false; Stop = $true; Wait = $true; StopCompanions = $false },
        @{ Argument = '--stop'; Action = 'StopCompanions'; Restart = $false; Stop = $false; Wait = $false; StopCompanions = $true }
    )) {
        $process = Start-Launcher $case.Argument
        Assert ($process.WaitForExit(10000) -and $process.ExitCode -eq 0) 'Lifecycle dispatcher did not exit successfully.'
        $started = Join-Path $root ($case.Action + '.started.json')
        $details = Read-FixtureJson $started
        $children.Add($details)
        Assert ($details.Console -eq 0) 'A resident helper allocated a console.'
        Assert ($details.Restart -eq $case.Restart -and $details.Stop -eq $case.Stop -and $details.WaitForStop -eq $case.Wait -and $details.StopCompanions -eq $case.StopCompanions) 'Lifecycle arguments changed.'
        $done = Join-Path $root ($case.Action + '.completed')
        Assert (-not (Test-Path -LiteralPath $done)) 'Dispatcher waited for a resident helper.'
        Set-Content -LiteralPath (Join-Path $root ($case.Action + '.release')) -Value 'stop'
        Wait-File $done
        $log = Get-ChildLog $case.Action $details.Pid
        $null = Read-ResidentLog $log $details.Pid
    }
    # A restart must reach its script even while the previous invocation still
    # holds its redirection file. Test both actions without touching real helpers.
    foreach ($case in @(
        @{ Argument = '--flow-restart'; Action = 'FlowRestart' },
        @{ Argument = '--title-bars-restart'; Action = 'TitleBarsRestart' }
    )) {
        $env:DOTFILES_FIXTURE_INSTANCE = 'first'
        $process = Start-Launcher $case.Argument
        Assert ($process.WaitForExit(10000) -and $process.ExitCode -eq 0) 'First restart dispatch failed.'
        $first = Read-FixtureJson (Join-Path $root ($case.Action + '-first.started.json'))
        $children.Add($first)
        $firstLog = Get-ChildLog $case.Action $first.Pid
        $locked = $false
        try { $stream = [IO.File]::Open($firstLog, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::Read); $stream.Dispose() }
        catch [IO.IOException] { $locked = $true }
        Assert $locked 'First resident did not hold its redirection file open.'
        $running = Get-Process -Id $first.Pid
        try {
            $env:DOTFILES_FIXTURE_INSTANCE = 'second'
            $process = Start-Launcher $case.Argument
            Assert ($process.WaitForExit(10000) -and $process.ExitCode -eq 0) 'Second restart dispatch failed.'
            $second = Read-FixtureJson (Join-Path $root ($case.Action + '-second.started.json'))
            $children.Add($second)
            $secondLog = Get-ChildLog $case.Action $second.Pid
            Assert (-not $running.HasExited) 'First resident exited before the second restart reached its script.'
            Assert ($first.Pid -ne $second.Pid -and $firstLog -ne $secondLog) 'Repeated restart reused a resident process or its locked log.'
            Assert ($first.Restart -and $second.Restart -and $first.Console -eq 0 -and $second.Console -eq 0) 'Repeated restart changed helper arguments or allocated a console.'
            foreach ($instance in @('first', 'second')) {
                Set-Content -LiteralPath (Join-Path $root ($case.Action + '-' + $instance + '.release')) -Value 'stop'
                Wait-File (Join-Path $root ($case.Action + '-' + $instance + '.completed'))
            }
            $firstText = Read-ResidentLog $firstLog $first.Pid
            $secondText = Read-ResidentLog $secondLog $second.Pid
            Assert ($firstText -notmatch "PID $($second.Pid)\b" -and $secondText -notmatch "PID $($first.Pid)\b") 'Repeated invocation logs were mixed.'
        } finally { $running.Dispose() }
    }
    $env:DOTFILES_FIXTURE_INSTANCE = ''
    # Simulate an assertion failing after dispatch, before registering the child.
    foreach ($suffix in @('.started.json', '.owned.json', '.release', '.completed')) {
        Remove-Item -LiteralPath (Join-Path $root ('FlowStart' + $suffix)) -ErrorAction SilentlyContinue
    }
    $process = Start-Launcher '--flow-start'
    Assert ($process.WaitForExit(10000) -and $process.ExitCode -eq 0) 'Cleanup recovery fixture could not dispatch.'
    $unregistered = Read-FixtureJson (Join-Path $root 'FlowStart.owned.json')
    $running = Get-Process -Id $unregistered.Pid
    try {
        Stop-FixtureChildren
        Assert $running.HasExited 'Cleanup failed to recover and stop an unregistered fixture child.'
    } finally { $running.Dispose() }
    $process = Start-Launcher '--not-an-action'
    Assert ($process.WaitForExit(5000) -and $process.ExitCode -eq 1) 'Unknown launcher action was accepted.'
    Remove-Item -LiteralPath (Join-Path $root 'Watch-TitleBars.ps1')
    $process = Start-Launcher '--title-bars-restart'
    Assert ($process.WaitForExit(10000) -and $process.ExitCode -eq 1) 'Missing lifecycle script was reported as successful dispatch.'
    Assert ((Get-Content -LiteralPath (Join-Path $root 'desktop-launcher.log') -Raw).Contains('Lifecycle script missing')) 'Dispatcher launch failure was not logged.'
    Remove-Item -LiteralPath (Join-Path $root 'Start-Desktop.ps1')
    $process = Start-Launcher $cli
    Assert ($process.WaitForExit(10000) -and $process.ExitCode -eq 1) 'Missing orchestrator left the launcher open or returned success.'
    Remove-Item -LiteralPath (Join-Path $root 'Start-DesktopLauncher.ps1')
    $process = Start-Launcher $cli
    Assert ($process.WaitForExit(10000) -and $process.ExitCode -eq 1) 'Missing launcher bootstrap was reported as successful startup.'
    [IO.File]::WriteAllText((Join-Path $root 'Start-DesktopLauncher.ps1'), 'param( {')
    $process = Start-Launcher $cli
    Assert ($process.WaitForExit(10000) -and $process.ExitCode -eq 1) 'Malformed launcher bootstrap was reported as successful startup.'
    Write-Host 'PASS: minimized WSH request, attached startup/readiness timeout, automatic exit/status, literal arguments, console-free detached helpers, repeated restarts with active log writers, action forwarding, logs and failures.'
} finally {
    foreach ($process in $processes) { try { if (-not $process.HasExited) { $process.Kill() } } catch { }; $process.Dispose() }
    # PID plus creation time guards against reuse; records belong to our fixtures.
    Stop-FixtureChildren
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    Remove-Item -LiteralPath $root -Recurse -Force
}
