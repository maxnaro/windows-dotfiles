# Windows PowerShell 5.1: isolated sockets, mocked wallpaper APIs, disposable files.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$windows = Split-Path -Parent $PSScriptRoot
. (Join-Path $windows 'HelperCache.ps1')
. (Join-Path $windows 'Wallpaper.ps1')
. (Join-Path $windows 'StartupPerformance.ps1')
function Assert-True { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }
$testRoot = Join-Path $env:TEMP ('dotfiles performance ' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    Set-DesktopSession $testRoot 'generation-one' $true
    Assert-True (Test-DesktopSession $testRoot 'generation-one') 'Active startup generation was rejected.'
    Assert-True (-not (Test-DesktopSession $testRoot 'generation-two')) 'A stale helper generation was accepted.'
    Set-DesktopSession $testRoot '' $false
    Assert-True (-not (Test-DesktopSession $testRoot 'generation-one')) 'A delayed child was allowed after shutdown.'
    # Stop before event creation/activation is durable, not lost to Reset().
    $eventName = 'Local\DotfilesStartupFixture-' + [guid]::NewGuid()
    $revision = Get-DesktopSessionRevision $testRoot
    Stop-DesktopGeneration $testRoot $eventName
    $fixtureStop = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $eventName)
    try {
        Assert-True (-not (Start-DesktopGeneration $testRoot $revision $fixtureStop)) 'A stop before event creation was erased by startup activation.'
        $revision = Get-DesktopSessionRevision $testRoot
        $generation = Start-DesktopGeneration $testRoot $revision $fixtureStop
        Assert-True (Test-DesktopSession $testRoot $generation) 'A new invocation after shutdown could not activate.'
        Stop-DesktopGeneration $testRoot $eventName
        Assert-True ($fixtureStop.WaitOne(0) -and -not (Test-DesktopSession $testRoot $generation)) 'Stop did not atomically signal and retire the active generation.'
    } finally { $fixtureStop.Dispose() }
    Initialize-DesktopRuntime -Directory $testRoot -Build
    $memory = [Dotfiles.Desktop.Performance]::Memory()
    Assert-True ($memory.CommitLimit -gt 0 -and $memory.CommittedBytes -gt 0) 'Native memory statistics are unavailable.'
    $before = (Get-ChildItem (Join-Path $testRoot 'cache') -Filter '*.dll')[0].LastWriteTimeUtc
    Initialize-DesktopRuntime -Directory $testRoot
    Assert-True ((Get-ChildItem (Join-Path $testRoot 'cache') -Filter '*.dll')[0].LastWriteTimeUtc -eq $before) 'Runtime recompiled at load.'
    Add-Type -Path (Join-Path $PSScriptRoot 'StartupSocketFixture.cs')
    foreach ($mode in @('ok', 'fragmented', 'failed', 'invalid', 'hang', 'close')) {
        $server = New-Object StartupSocketFixture
        $server.Mode = $mode
        $probe = New-Object Dotfiles.Desktop.MonitorProbe("ws://127.0.0.1:$($server.Port)")
        try {
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $result = $probe.Query($(if ($mode -eq 'hang') { 250 } else { 2000 }))
            $expected = if ($mode -in @('ok', 'fragmented')) { 'ok' } elseif ($mode -eq 'hang') { 'timeout' } elseif ($mode -eq 'failed') { 'failed' } else { 'error' }
            Assert-True ($result.QueryStatus -eq $expected) "Unexpected $mode result: $($result.QueryStatus): $($result.QueryError)"
            Assert-True ($timer.Elapsed.TotalSeconds -lt 3) 'WebSocket timeout exceeded its bound.'
            if ($mode -eq 'hang' -and $server.Requests -gt 0) {
                Assert-True ($result.QueryMilliseconds -gt 0) 'A response timeout was incorrectly attributed entirely to connection time.'
            }
            if ($mode -eq 'ok') {
                $null = $probe.Query(2000)
                Assert-True ($server.Connections -eq 1 -and $server.Requests -eq 2) 'Monitor queries did not reuse the connection.'
            }
        } finally { $probe.Dispose(); $server.Dispose() }
    }
    # Polling must not serialize the dispatch loop behind a stalled socket.
    $server = New-Object StartupSocketFixture
    $server.Mode = 'hang'
    $probe = New-Object Dotfiles.Desktop.MonitorProbe("ws://127.0.0.1:$($server.Port)")
    try {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        Assert-True ($probe.BeginQuery(250)) 'Async monitor probe did not start.'
        Assert-True ($timer.ElapsedMilliseconds -lt 100) 'Starting a readiness probe blocked dispatch.'
        $iterations = 0; $result = $null
        while (-not $result -and $timer.ElapsedMilliseconds -lt 1500) {
            $iterations++; $result = $probe.PollQuery(); Start-Sleep -Milliseconds 20
        }
        Assert-True ($result.QueryStatus -eq 'timeout' -and $iterations -gt 1) 'Stalled readiness did not allow dispatch/cancellation work between polls.'
    } finally { $probe.Dispose(); $server.Dispose() }
    # Deterministic deadline classification, independent of timer/thread scheduling:
    # inject a late completion timestamp after a successful loopback response.
    $server = New-Object StartupSocketFixture
    $probe = New-Object Dotfiles.Desktop.MonitorProbe("ws://127.0.0.1:$($server.Port)")
    try {
        $flags = [Reflection.BindingFlags]'Instance,NonPublic'
        $pendingField = $probe.GetType().GetField('pending', $flags)
        $completedField = $probe.GetType().GetField('pendingCompletedMilliseconds', $flags)
        $null = $probe.BeginQuery(2000)
        $task = $pendingField.GetValue($probe)
        Assert-True ($task.Wait(3000) -and $task.Result.QueryStatus -eq 'ok') 'Deadline fixture did not receive a successful response.'
        $completedField.SetValue($probe, [double]2001)
        Assert-True ($probe.PollQuery().QueryStatus -eq 'timeout') 'An overdue successful worker result bypassed the probe deadline.'
        $null = $probe.BeginQuery(2000)
        $task = $pendingField.GetValue($probe)
        Assert-True ($task.Wait(3000) -and $task.Result.QueryStatus -eq 'ok') 'Probe did not reconnect after an overdue response.'
        # A busy orchestrator may not poll until after the budget has expired.
        Start-Sleep -Milliseconds 2100
        Assert-True ($probe.PollQuery().QueryStatus -eq 'ok') 'An on-time response was rejected merely because the caller polled late.'
    } finally { $probe.Dispose(); $server.Dispose() }
    Add-Type -AssemblyName System.Windows.Forms
    $form = New-Object Windows.Forms.Form
    try {
        $form.Text = 'DO NOT PERSIST PRIVATE WINDOW TITLE'
        $snapshot = [Dotfiles.Desktop.StartupWindows]::DescribeWindow($form.Handle.ToInt64())
        Assert-True ($snapshot.ProcessId -eq $PID -and $snapshot.ClassName -like 'WindowsForms10.*') 'Window ownership snapshot was incorrect.'
        Assert-True (-not $form.Visible -and -not (($snapshot | ConvertTo-Json) -match 'PRIVATE WINDOW TITLE')) 'Window snapshot activated a window or leaked its title.'
    } finally { $form.Dispose() }
    $crop = [Dotfiles.Desktop.WallpaperWindow]::Cover([Drawing.Size]::new(200, 100), [Drawing.Size]::new(100, 100))
    Assert-True ($crop.X -eq -50 -and $crop.Y -eq 0 -and $crop.Width -eq 200) 'Wallpaper crop changed proportions or centring.'
    & {
        $script:nativeCalls = 0; $script:restoreCalls = 0; $script:denyNative = $false; $script:matches = $true
        function Get-NativeWallpaperState { [pscustomobject]@{ SlideshowActive = $false; Position = 4; BackgroundColor = 0; Monitors = @() } }
        function Set-NativeWallpaper { param($Path); $script:nativeCalls++; if ($script:denyNative) { throw 'fixture policy denied' } }
        function Test-NativeWallpaper { param($Path); $script:matches }
        function Restore-NativeWallpaper { param($Json); $script:restoreCalls++ }
        $image = Join-Path $testRoot 'image.jpg'; [IO.File]::WriteAllText($image, 'fixture')
        $config = Set-DesktopWallpaperConfiguration Auto $image $testRoot $testRoot
        Assert-True ($config.WallpaperBackend -eq 'Native' -and $script:nativeCalls -eq 1) 'Auto did not try native wallpaper first.'
        Assert-True (-not (Test-DesktopWallpaperOverlayRequired $config)) 'A matching native wallpaper launched an overlay.'
        $script:matches = $false
        Assert-True (Test-DesktopWallpaperOverlayRequired $config) 'A replaced wallpaper did not trigger Auto fallback.'
        $script:denyNative = $true
        $config = Set-DesktopWallpaperConfiguration Auto $image $testRoot $testRoot
        Assert-True ($config.WallpaperBackend -eq 'Overlay') 'Native failure did not fall back.'
        $threw = $false
        try { $null = Set-DesktopWallpaperConfiguration Native $image $testRoot $testRoot } catch { $threw = $true }
        Assert-True $threw 'Explicit Native mode silently fell back.'
        $config | ConvertTo-Json | Set-Content (Join-Path $testRoot 'desktop-startup.json')
        $config = Set-DesktopWallpaperConfiguration '' $image $testRoot $testRoot
        Assert-True ($config.WallpaperMode -eq 'Auto') 'Repeated application lost the chosen mode.'
        $config = Set-DesktopWallpaperConfiguration None $image $testRoot $testRoot
        Assert-True (-not (Test-DesktopWallpaperOverlayRequired $config)) 'None mode required an overlay.'
        Assert-True (Test-Path (Join-Path $testRoot 'wallpaper-state.json')) 'Native state was not backed up.'
    }
    $metadata = @(
        [pscustomobject]@{ ProcessId = 10; ParentProcessId = 1; Name = 'zebar.exe'; CommandLine = ''; Priority = 8 },
        [pscustomobject]@{ ProcessId = 11; ParentProcessId = 10; Name = 'msedgewebview2.exe'; CommandLine = ''; Priority = 8 },
        [pscustomobject]@{ ProcessId = 12; ParentProcessId = 11; Name = 'msedgewebview2.exe'; CommandLine = ''; Priority = 8 },
        [pscustomobject]@{ ProcessId = 13; ParentProcessId = 99; Name = 'msedgewebview2.exe'; CommandLine = '--webview-exe-name="olk.exe" --secret=not-for-output'; Priority = 8 }
    )
    $counters = @($metadata | ForEach-Object { [pscustomobject]@{ IDProcess = $_.ProcessId; Name = $_.Name; PercentProcessorTime = 80; WorkingSetPrivate = 100; IODataBytesPersec = 10 } })
    $sample = @(Get-StartupProcessPerformance $counters $metadata 8)
    Assert-True (($sample | Where-Object IDProcess -eq 12).Host -eq 'zebar.exe') 'WebView ancestry was not attributed.'
    Assert-True (($sample | Where-Object IDProcess -eq 13).Host -eq 'olk.exe') 'WebView host flag was not attributed.'
    Assert-True ($sample[0].CpuPercent -eq 10) 'Process CPU was not normalised by logical processors.'
    Assert-True (-not (($sample | ConvertTo-Json) -match 'not-for-output|CommandLine')) 'Diagnostics persisted command lines.'
    # One failed performance source must not discard memory, disk or process samples.
    & {
        $profileBefore = $env:USERPROFILE; $scoopBefore = $env:SCOOP
        try {
            $env:USERPROFILE = Join-Path $testRoot 'counter-profile'
            $env:SCOOP = Join-Path $testRoot 'counter-scoop'
            $cache = Join-Path $env:USERPROFILE '.glzr\glazewm'
            New-Item -ItemType Directory -Path $cache -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $testRoot 'cache') -Destination $cache -Recurse
            $cliDirectory = Join-Path $env:SCOOP 'apps\glazewm\current\cli'
            New-Item -ItemType Directory -Path $cliDirectory -Force | Out-Null
            Add-Type -TypeDefinition 'public class DotfilesCounterFixture { public static int Main() { return 0; } }' -OutputAssembly (Join-Path $cliDirectory 'GlazeWM.exe') -OutputType ConsoleApplication
            function Get-CimInstance {
                param($ClassName, $Filter, $OperationTimeoutSec)
                switch ($ClassName) {
                    'Win32_PerfFormattedData_PerfOS_Processor' { throw 'fixture CPU counter unavailable' }
                    'Win32_PerfFormattedData_PerfOS_Memory' { throw 'fixture paging counter unavailable' }
                    'Win32_PerfFormattedData_PerfDisk_PhysicalDisk' { [pscustomobject]@{ DiskBytesPersec = 123; CurrentDiskQueueLength = 0 } }
                    'Win32_PerfFormattedData_PerfProc_Process' { [pscustomobject]@{ IDProcess = 10; Name = 'zebar'; PercentProcessorTime = 8; WorkingSetPrivate = 100; IODataBytesPersec = 10 } }
                    'Win32_Process' { [pscustomobject]@{ ProcessId = 10; ParentProcessId = 1; Name = 'zebar.exe'; CommandLine = ''; Priority = 8 } }
                }
            }
            $output = Join-Path $testRoot 'counter-capture'
            & (Join-Path $windows 'Measure-GlazeWMStartup.ps1') -DurationSeconds 1 -IntervalSeconds 1 -ProbeTransport Cli -OutputDirectory $output
            $records = @(Get-Content -LiteralPath (Get-ChildItem $output -Filter '*.jsonl')[0].FullName | ForEach-Object { $_ | ConvertFrom-Json })
            $sample = @($records | Where-Object Event -eq sample)[0]
            Assert-True ($sample.ProbeCompletedAt -and $sample.ProbeCompletedElapsedSeconds -ge $sample.ElapsedSeconds) 'Probe completion time was not recorded.'
            Assert-True ($sample.Memory[0].CommitLimit -gt 0 -and $sample.Disk[0].DiskBytesPersec -eq 123) 'One unavailable counter suppressed other samples.'
            Assert-True ($sample.Processes[0].Host -eq 'zebar.exe') 'The collector did not record attributed processes.'
            Assert-True ($sample.PerformanceErrors.Cpu -match 'unavailable' -and $sample.PerformanceErrors.Paging -match 'unavailable') 'Counter failures were not recorded separately.'
        } finally { $env:USERPROFILE = $profileBefore; $env:SCOOP = $scoopBefore }
    }
    Write-Host 'PASS: cached helpers, bounded/reused/fragmented WebSocket queries, wallpaper selection/fallback, crop, and process attribution.'
} finally { Remove-Item -LiteralPath $testRoot -Recurse -Force }
