[CmdletBinding()]
param([string]$GlazeCli, [switch]$CompanionsOnly, [switch]$StopCompanions)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'HelperCache.ps1')

function Write-StartupStatus {
    param([string]$Message)
    $line = '[{0}] [{1,5:N1}s] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $script:startupWatch.Elapsed.TotalSeconds, $Message
    Write-Host $line
    Add-Content -LiteralPath $script:startupLog -Value $line -Encoding UTF8
}

function Initialize-StartupWindows {
    . (Join-Path $PSScriptRoot 'HelperCache.ps1')
    Initialize-DesktopRuntime
}

function Invoke-StartupProbe {
    param([string]$Path, [int]$TimeoutMilliseconds = 2000)
    $probe = New-Object Diagnostics.Process
    $probe.StartInfo.FileName = $Path
    $probe.StartInfo.Arguments = 'query monitors'
    $probe.StartInfo.UseShellExecute = $false
    $probe.StartInfo.CreateNoWindow = $true
    $probe.StartInfo.RedirectStandardOutput = $true
    $probe.StartInfo.RedirectStandardError = $true
    try {
        $null = $probe.Start()
        $stdout = $probe.StandardOutput.ReadToEndAsync()
        $stderr = $probe.StandardError.ReadToEndAsync()
        if (-not $probe.WaitForExit($TimeoutMilliseconds)) {
            $probe.Kill()
            $null = $probe.WaitForExit(200)
            return 'monitor query timed out'
        }
        if ($probe.ExitCode -eq 0) { return 'ready' }
        $detail = if ($stderr.IsCompleted) { $stderr.Result.Trim() } else { '' }
        return ("monitor query exited {0}: {1}" -f $probe.ExitCode, $detail).Trim()
    } catch { return ('monitor query error: ' + $_.Exception.Message) }
    finally { $probe.Dispose() }
}

function Get-StartupApplicationProcess {
    param($App)
    $session = (Get-Process -Id $PID).SessionId
    @(Get-Process -Name $App.ProcessName -ErrorAction SilentlyContinue | Where-Object {
        $_.SessionId -eq $session -and $_.Path -and
        $_.Path.StartsWith($App.Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -and
        ($App.Kind -ne 'GlazeWM' -or $_.Path -notmatch '\\cli\\')
    } | Sort-Object StartTime -Descending)
}

function New-StartupApplication {
    param([string]$Name, [string]$Kind, [string]$Exe, [string]$Root, [string]$Arguments = '')
    return [pscustomobject]@{
        Name = $Name; Kind = $Kind; Exe = $Exe; Root = $Root; Arguments = $Arguments
        ProcessName = [IO.Path]::GetFileNameWithoutExtension($Exe)
        Ready = $false; Failed = $false; Dispatched = $false; StartAt = 0.0; Optional = $false; Detail = 'waiting for scheduled dispatch'
    }
}

function Start-StartupApplication {
    param($App)
    $App.Dispatched = $true
    try {
        if (-not (Test-Path -LiteralPath $App.Exe -PathType Leaf)) { throw "Executable not found: $($App.Exe)" }
        if (@(Get-StartupApplicationProcess $App).Count) {
            Write-StartupStatus "$($App.Name): already running; checking readiness."
            return
        }
        Write-StartupStatus "$($App.Name): launching $($App.Exe)"
        $options = @{ FilePath = $App.Exe; WorkingDirectory = (Split-Path -Parent $App.Exe); ErrorAction = 'Stop' }
        if ($App.Arguments) { $options.ArgumentList = $App.Arguments }
        Start-Process @options
    } catch {
        $App.Failed = $true
        $App.Detail = $_.Exception.Message
        Write-StartupStatus "ERROR $($App.Name): $($App.Detail)"
    }
}

function Get-FlowStartupStatus {
    param([string]$LogDirectory, [datetime]$ProcessStart)
    $started = $false
    $plugins = $false
    $files = @(Get-ChildItem -LiteralPath $LogDirectory -Filter '*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -ge $ProcessStart.ToUniversalTime() })
    foreach ($file in $files) {
        if ($file.Name -notmatch '\.(\d{4}-\d{2}-\d{2})\.log$') { continue }
        $day = $Matches[1]
        # Correlate markers to the application process, not the short-lived Scoop bootstrapper.
        # Flow keeps its active log open for writing; allow concurrent writes and rotation.
        $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader = $null
        try {
            $reader = New-Object IO.StreamReader($stream)
            $lines = $reader.ReadToEnd() -split '\r?\n'
        } finally {
            if ($reader) { $reader.Dispose() }
            $stream.Dispose()
        }
        foreach ($line in $lines) {
            if ($line -notmatch '^(\d{2}:\d{2}:\d{2}(?:\.\d+)?[+-]\d{2}:\d{2})\s+-') { continue }
            $time = [DateTimeOffset]::Parse($day + 'T' + $Matches[1], [Globalization.CultureInfo]::InvariantCulture)
            if ($time.UtcDateTime -lt $ProcessStart.ToUniversalTime()) { continue }
            if ($line -match '(?i)(error|fatal).*hot.?key|hot.?key.*(fail|error)') { return 'hotkey registration failed; inspect the Flow log' }
            if ($line.Contains('App.OnStartup - End Flow Launcher startup')) { $started = $true }
            if ($line.Contains('App.OnStartup - End plugin initialization')) { $plugins = $true }
        }
    }
    if ($started -and $plugins) { return 'ready' }
    if ($started) { return 'waiting for plugin initialization' }
    return 'waiting for Flow initialization'
}

function Get-StartupApplicationStatus {
    param($App, [string]$Cli, [int]$TimeoutMilliseconds)
    if ($App.Kind -eq 'GlazeWM') {
        if (-not $script:startupMonitorProbe) { Initialize-StartupWindows; $script:startupMonitorProbe = New-Object Dotfiles.Desktop.MonitorProbe }
        $result = $script:startupMonitorProbe.Query($TimeoutMilliseconds)
        if ($result.QueryStatus -eq 'ok') { return 'ready' }
        return "monitor query $($result.QueryStatus): $($result.QueryError)"
    }
    $processes = @(Get-StartupApplicationProcess $App)
    if ($App.Kind -eq 'Flow') {
        # Squirrel hands off to app-<version>\Flow.Launcher.exe and exits successfully.
        $processes = @($processes | Where-Object { $_.Path -match '\\app-[^\\]+\\Flow\.Launcher\.exe$' })
    }
    if (-not $processes.Count) { return 'waiting for application process' }
    if ($App.Kind -eq 'Everything') {
        if ([Dotfiles.Desktop.StartupWindows]::EverythingResponds($processes[0].Id)) { return 'ready' }
        return 'waiting for Everything IPC'
    }
    if ($App.Kind -eq 'Zebar') { return 'ready' }
    # Derive logs from the actual app process, which can still be an older version after a Scoop update.
    $applicationDirectory = Split-Path -Parent $processes[0].Path
    $version = (Split-Path -Leaf $applicationDirectory).Substring(4)
    $logDirectory = Join-Path $applicationDirectory ("UserData\Logs\$version")
    return (Get-FlowStartupStatus $logDirectory $processes[0].StartTime)
}

function Start-StartupScript {
    param([string]$Directory, [string]$Script, [string]$Arguments = '')
    $entry = Join-Path $Directory $Script
    if (-not (Test-Path -LiteralPath $entry)) { throw "Startup helper missing: $entry" }
    $Arguments += " -StartupGeneration '" + $script:startupGeneration + "'"
    $log = Join-Path $Directory ($Script.Replace('.ps1', '-startup.log'))
    $command = "& '" + $entry.Replace("'", "''") + "'" + $Arguments + " *> '" + $log.Replace("'", "''") + "'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded) -WindowStyle Hidden
}

function Start-StartupDiagnostics {
    param([string]$Directory)
    if (-not (Test-Path -LiteralPath (Join-Path $Directory 'diagnostics.enabled'))) { return }
    $collector = Join-Path $Directory 'Measure-GlazeWMStartup.ps1'
    if (-not (Test-Path -LiteralPath $collector -PathType Leaf)) { throw "Diagnostic collector not found: $collector" }
    $output = Join-Path $Directory 'diagnostics'
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    $prefix = Join-Path $output ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-collector')
    # Redirect inside the child, so its log handles remain valid after this host exits.
    # ShellExecute (no parent-side redirection or -NoNewWindow) gives it a separate hidden console.
    $command = '& {{ $ErrorActionPreference = ''Stop''; try {{ & ''{0}'' -OutputDirectory ''{1}'' }} catch {{ Write-Error $_ -ErrorAction Continue; exit 1 }} }} *> ''{2}''' -f `
        $collector.Replace("'", "''"), $output.Replace("'", "''"), ($prefix + '.log').Replace("'", "''")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $collectorProcess = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -ArgumentList ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded) -WindowStyle Hidden -PassThru
    Write-StartupStatus "Diagnostics: started independently (PID $($collectorProcess.Id)); captures: $output; collector log: $prefix.log"
    $collectorProcess.Dispose()
}

function Invoke-DesktopStartup {
    param([string]$Cli, [string]$Directory = $PSScriptRoot, [ValidateRange(1, 300)][int]$TimeoutSeconds = 45, [switch]$CompanionsOnly, [double]$StageScale = 1)
    $script:startupWatch = [Diagnostics.Stopwatch]::StartNew()
    $script:startupMonitorProbe = $null
    $script:startupLog = Join-Path $Directory 'startup.log'
    $mutex = New-Object Threading.Mutex($false, 'Local\DotfilesDesktopStartup')
    $locked = $false
    $stopEvent = $null
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { Write-Host 'Desktop startup is already in progress; skipping this invocation.'; return 0 }
        $stopEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, 'Local\DotfilesDesktopStartupStop')
        $null = $stopEvent.Reset()
        $script:startupGeneration = [guid]::NewGuid().ToString('N')
        Set-DesktopSession $Directory $script:startupGeneration $true
        Write-StartupStatus "Desktop startup invoked. Log: $script:startupLog"
        if ([string]::IsNullOrWhiteSpace($Cli) -or -not (Test-Path -LiteralPath $Cli -PathType Leaf)) {
            throw "GlazeWM CLI not found: $Cli"
        }
        $apps = New-Object 'Collections.Generic.List[object]'
        $glazeDirectory = Split-Path -Parent (Split-Path -Parent $Cli)
        $glaze = New-StartupApplication 'GlazeWM' 'GlazeWM' (Join-Path $glazeDirectory 'GlazeWM.exe') (Split-Path -Parent $glazeDirectory)
        $apps.Add($glaze)
        # Dispatch tiling before loading launcher metadata or compiling the IPC helper.
        if ($CompanionsOnly) { $glaze.Dispatched = $true } else { Start-StartupApplication $glaze }
        $launcherConfig = Join-Path $Directory 'launcher-startup.json'
        $configurationFailed = $false
        if (Test-Path -LiteralPath $launcherConfig) {
            try {
                $config = Get-Content -LiteralPath $launcherConfig -Raw | ConvertFrom-Json
                if (-not $config -or -not $config.PSObject.Properties['ScoopRoot'] -or
                    $config.ScoopRoot -isnot [string] -or [string]::IsNullOrWhiteSpace($config.ScoopRoot) -or
                    -not [IO.Path]::IsPathRooted($config.ScoopRoot)) {
                    throw 'launcher-startup.json must contain an absolute ScoopRoot.'
                }
                $everythingRoot = Join-Path $config.ScoopRoot 'apps\everything'
                $everything = New-StartupApplication 'Everything' 'Everything' (Join-Path $everythingRoot 'current\Everything.exe') $everythingRoot '-startup'
                $apps.Add($everything)
                $everything.StartAt = 5 * $StageScale
                $flowRoot = Join-Path $config.ScoopRoot 'apps\flow-launcher'
                $flow = New-StartupApplication 'Flow Launcher' 'Flow' (Join-Path $flowRoot 'current\Flow.Launcher.exe') $flowRoot
                $apps.Add($flow)
                $flow.StartAt = 8 * $StageScale
            } catch {
                $configurationFailed = $true
                Write-StartupStatus ('ERROR launcher configuration: ' + $_.Exception.Message)
            }
        } else { Write-StartupStatus 'App launchers: not configured for scheduled startup.' }
        try { Start-StartupDiagnostics $Directory }
        catch { Write-StartupStatus ('WARNING diagnostics: ' + $_.Exception.Message) }

        $stages = New-Object 'Collections.Generic.List[object]'
        $desktopConfig = Join-Path $Directory 'desktop-startup.json'
        if (Test-Path -LiteralPath $desktopConfig) {
            $desktop = Get-Content -LiteralPath $desktopConfig -Raw | ConvertFrom-Json
            $stages.Add([pscustomobject]@{ Name = 'Workspace helper'; At = 5 * $StageScale; Done = $false; Script = 'Watch-FlowWorkspace.ps1'; Arguments = '' })
            if ($desktop.ZebarEnabled) {
                $scoop = Split-Path -Parent (Split-Path -Parent $glaze.Root)
                $root = Join-Path $scoop 'apps\zebar'
                $bar = New-StartupApplication 'Zebar' 'Zebar' (Join-Path $root 'current\zebar.exe') $root
                $bar.Optional = $true; $bar.StartAt = 12 * $StageScale; $apps.Add($bar)
            }
            if ($desktop.WallpaperMode -ne 'None') {
                $stages.Add([pscustomobject]@{ Name = 'Wallpaper'; At = 15 * $StageScale; Done = $false; Script = 'Wallpaper.ps1'; Arguments = ' -Run' })
            }
        }
        $windowsReady = $false
        $nextProgress = 0.0
        while ($script:startupWatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            if ($stopEvent.WaitOne(0)) { Write-StartupStatus 'GlazeWM shutdown cancelled pending companion launches.'; return 0 }
            $due = @($stages | Where-Object { -not $_.Done -and $_.At -le $script:startupWatch.Elapsed.TotalSeconds } | ForEach-Object {
                [pscustomobject]@{ At = $_.At; Order = $(if ($_.Name -eq 'Wallpaper') { 5 } else { 1 }); Stage = $_; App = $null }
            }) + @($apps | Where-Object { -not $_.Dispatched -and $_.StartAt -le $script:startupWatch.Elapsed.TotalSeconds } | ForEach-Object {
                [pscustomobject]@{ At = $_.StartAt; Order = $(switch ($_.Kind) { 'Everything' { 2 }; 'Flow' { 3 }; default { 4 } }); Stage = $null; App = $_ }
            })
            foreach ($item in @($due | Sort-Object At, Order)) {
                if ($stopEvent.WaitOne(0)) { Write-StartupStatus 'Shutdown cancelled companion dispatch.'; return 0 }
                if ($item.App) { Start-StartupApplication $item.App; continue }
                $stage = $item.Stage
                $stage.Done = $true
                try {
                    Start-StartupScript $Directory $stage.Script $stage.Arguments
                    Write-StartupStatus "$($stage.Name): dispatched (details in helper log)."
                } catch { Write-StartupStatus "WARNING $($stage.Name): $($_.Exception.Message)" }
            }
            $pending = @($apps | Where-Object { $_.Dispatched -and -not $_.Ready -and -not $_.Failed })
            if (-not $pending.Count -and -not @($apps | Where-Object { -not $_.Dispatched }).Count -and -not @($stages | Where-Object { -not $_.Done }).Count) { break }
            foreach ($app in $pending) {
                $remaining = $TimeoutSeconds - $script:startupWatch.Elapsed.TotalSeconds
                if ($remaining -le 0) { break }
                try {
                    if ($app.Kind -eq 'Everything' -and -not $windowsReady) { Initialize-StartupWindows; $windowsReady = $true }
                    $app.Detail = Get-StartupApplicationStatus $app $Cli ([int][Math]::Max(1, [Math]::Min(2000, $remaining * 1000)))
                    if ($app.Detail -eq 'ready') {
                        $app.Ready = $true
                        $suffix = if ($app.Kind -eq 'Zebar') { ' Process running; widget rendering is not confirmed.' } elseif ($app.Kind -eq 'Flow') { ' Initialized; use Alt+Space.' } elseif ($app.Kind -eq 'Everything') { ' IPC responds; indexing can continue in the background.' } else { ' Monitor query responds.' }
                        Write-StartupStatus "$($app.Name): ready.$suffix"
                    } elseif ($app.Detail -like 'hotkey registration failed*') {
                        $app.Failed = $true
                        Write-StartupStatus "ERROR $($app.Name): $($app.Detail)"
                    }
                } catch { $app.Detail = $_.Exception.Message }
            }
            if ($script:startupWatch.Elapsed.TotalSeconds -ge $nextProgress) {
                foreach ($app in @($apps | Where-Object { -not $_.Ready -and -not $_.Failed })) {
                    Write-StartupStatus "$($app.Name): $($app.Detail)."
                }
                $nextProgress = $script:startupWatch.Elapsed.TotalSeconds + 5
            }
            $remaining = $TimeoutSeconds - $script:startupWatch.Elapsed.TotalSeconds
            if ($remaining -gt 0 -and (@($apps | Where-Object { -not $_.Ready -and -not $_.Failed }).Count -or @($stages | Where-Object { -not $_.Done }).Count)) {
                Start-Sleep -Milliseconds ([int][Math]::Min(500, $remaining * 1000))
            }
        }
        foreach ($app in @($apps | Where-Object { -not $_.Ready -and -not $_.Failed })) {
            $app.Failed = $true
            Write-StartupStatus "ERROR $($app.Name): readiness not confirmed within $TimeoutSeconds seconds ($($app.Detail)). Application left running."
        }
        if ($configurationFailed -or @($apps | Where-Object { $_.Failed -and -not $_.Optional }).Count) {
            Write-StartupStatus "Startup incomplete. Inspect $script:startupLog and Flow's UserData\Logs for details."
            return 1
        }
        Write-StartupStatus 'Startup complete. This window will close automatically.'
        return 0
    } catch {
        # Keep errors visible even if the log itself could not be opened.
        $message = $_.Exception.Message
        try { Write-StartupStatus ('ERROR desktop startup: ' + $message) }
        catch { Write-Host "Could not write startup log: $script:startupLog" }
        return 1
    } finally {
        if ($script:startupMonitorProbe) { $script:startupMonitorProbe.Dispose(); $script:startupMonitorProbe = $null }
        if ($stopEvent) { $stopEvent.Dispose() }
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($StopCompanions) {
        Set-DesktopSession $PSScriptRoot '' $false
        try { $stop = [Threading.EventWaitHandle]::OpenExisting('Local\DotfilesDesktopStartupStop'); try { $null = $stop.Set() } finally { $stop.Dispose() } }
        catch [Threading.WaitHandleCannotBeOpenedException] { }
        & (Join-Path $PSScriptRoot 'Wallpaper.ps1') -Stop
        & (Join-Path $PSScriptRoot 'Watch-FlowWorkspace.ps1') -Stop
        $session = (Get-Process -Id $PID).SessionId
        Get-Process -Name zebar -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session } | Stop-Process
        exit 0
    }
    if (-not $GlazeCli) {
        $scoop = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
        $GlazeCli = Join-Path $scoop 'apps\glazewm\current\cli\GlazeWM.exe'
    }
    $result = Invoke-DesktopStartup -Cli $GlazeCli -CompanionsOnly:$CompanionsOnly
    if ($result -eq 0) { Start-Sleep -Seconds 3 }
    exit $result
}
