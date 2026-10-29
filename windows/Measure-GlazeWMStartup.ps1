[CmdletBinding()]
param(
    [ValidateRange(1, 600)][int]$DurationSeconds = 600,
    [ValidateRange(1, 30)][int]$IntervalSeconds = 10,
    [ValidateLength(1, 80)][string]$Label = 'startup',
    [ValidateSet('WebSocket', 'Cli')][string]$ProbeTransport = 'WebSocket',
    [switch]$SkipPerformanceCounters,
    [string]$OutputDirectory = (Join-Path $env:USERPROFILE '.glzr\glazewm\diagnostics')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
$cli = Join-Path $scoopRoot 'apps\glazewm\current\cli\GlazeWM.exe'
if ($ProbeTransport -eq 'Cli' -and -not (Test-Path -LiteralPath $cli)) { throw "GlazeWM CLI not found: $cli" }
. (Join-Path $PSScriptRoot 'StartupPerformance.ps1')
$connection = $null
if ($ProbeTransport -eq 'WebSocket' -or -not $SkipPerformanceCounters) {
    . (Join-Path $PSScriptRoot 'HelperCache.ps1')
    Initialize-DesktopRuntime -Directory (Join-Path $env:USERPROFILE '.glzr\glazewm')
    if ($ProbeTransport -eq 'WebSocket') { $connection = New-Object Dotfiles.Desktop.MonitorProbe }
}
# Keep the optional collector out of the interactive desktop's scheduling class.
$originalPriority = (Get-Process -Id $PID).PriorityClass
(Get-Process -Id $PID).PriorityClass = 'BelowNormal'
$cores = [int]$env:NUMBER_OF_PROCESSORS
$mutex = New-Object Threading.Mutex($false, 'Local\DotfilesGlazeWMDiagnostics')
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { Write-Warning 'A diagnostic capture is already running.'; return }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $path = Join-Path $OutputDirectory ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.jsonl')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $ready = $false
    $session = (Get-Process -Id $PID).SessionId
    [pscustomobject]@{ Event = 'capture-start'; Time = (Get-Date).ToString('o'); Label = $Label
        DurationSeconds = $DurationSeconds; Cli = $cli; SessionId = $session; ProbeTransport = $ProbeTransport; LogicalProcessors = $cores } |
        ConvertTo-Json -Compress | Add-Content -LiteralPath $path -Encoding UTF8
    while ($watch.Elapsed.TotalSeconds -lt $DurationSeconds) {
        $sample = [ordered]@{ Event = 'sample'; Time = (Get-Date).ToString('o'); ElapsedSeconds = [Math]::Round($watch.Elapsed.TotalSeconds, 3) }
        if ($connection) {
            $total = [Diagnostics.Stopwatch]::StartNew()
            $timeout = [int][Math]::Max(1, [Math]::Min(2000, ($DurationSeconds - $watch.Elapsed.TotalSeconds) * 1000))
            $result = $connection.Query($timeout)
            foreach ($property in $result.PSObject.Properties) { $sample[$property.Name] = $property.Value }
            $sample.ProbeMilliseconds = [Math]::Round($total.Elapsed.TotalMilliseconds, 1)
            if ($result.QueryStatus -eq 'ok' -and -not $ready) { $sample.FirstReady = $true; $ready = $true }
        } else {
        $probe = New-Object Diagnostics.Process
        $probe.StartInfo.FileName = $cli
        $probe.StartInfo.Arguments = 'query monitors'
        $probe.StartInfo.UseShellExecute = $false
        $probe.StartInfo.CreateNoWindow = $true
        $probe.StartInfo.RedirectStandardOutput = $true
        $probe.StartInfo.RedirectStandardError = $true
        $latency = [Diagnostics.Stopwatch]::StartNew()
        try {
            $null = $probe.Start()
            $stdout = $probe.StandardOutput.ReadToEndAsync()
            $stderr = $probe.StandardError.ReadToEndAsync()
            $timeout = [int][Math]::Max(1, [Math]::Min(2000, ($DurationSeconds - $watch.Elapsed.TotalSeconds) * 1000))
            if ($probe.WaitForExit($timeout)) {
                $sample.QueryExitCode = $probe.ExitCode
                $sample.QueryStatus = if ($probe.ExitCode -eq 0) { 'ok' } else { 'failed' }
                if ($probe.ExitCode -eq 0 -and -not $ready) { $sample.FirstReady = $true; $ready = $true }
            } else {
                $probe.Kill()
                $null = $probe.WaitForExit(500)
                $sample.QueryStatus = 'timeout'
            }
        } catch { $sample.QueryStatus = 'error'; $sample.QueryError = $_.Exception.Message }
        finally { $sample.QueryMilliseconds = [Math]::Round($latency.Elapsed.TotalMilliseconds, 1); $probe.Dispose() }
        }

        if (-not $SkipPerformanceCounters) {
            $errors = [ordered]@{}
            try { $sample.Memory = @([Dotfiles.Desktop.Performance]::Memory()) }
            catch { $errors.Memory = $_.Exception.Message }
            try {
                $sample.Cpu = @(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -OperationTimeoutSec 2 |
                    Select-Object PercentProcessorTime)
            } catch { $errors.Cpu = $_.Exception.Message }
            try {
                $sample.Disk = @(Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -OperationTimeoutSec 2 |
                    Select-Object DiskBytesPersec, CurrentDiskQueueLength)
            } catch { $errors.Disk = $_.Exception.Message }
            $counters = @(); $metadata = @()
            try { $counters = @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -OperationTimeoutSec 2) }
            catch { $errors.ProcessCounters = $_.Exception.Message }
            try { $metadata = @(Get-CimInstance Win32_Process -OperationTimeoutSec 2) }
            catch { $errors.ProcessMetadata = $_.Exception.Message }
            if ($counters.Count) { $sample.Processes = @(Get-StartupProcessPerformance $counters $metadata $cores) }
            try {
                $sample.Paging = @(Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -OperationTimeoutSec 2 |
                    Select-Object PagesInputPersec)
            } catch { $errors.Paging = $_.Exception.Message }
            if ($errors.Count) {
                $sample.PerformanceErrors = $errors
                $sample.PerformanceError = ($errors.Keys | ForEach-Object { $_ + ': ' + $errors[$_] }) -join '; '
            }
        }
        [pscustomobject]$sample | ConvertTo-Json -Depth 6 -Compress | Add-Content -LiteralPath $path -Encoding UTF8
        $remaining = $DurationSeconds - $watch.Elapsed.TotalSeconds
        if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int]([Math]::Min($IntervalSeconds, $remaining) * 1000)) }
    }
    [pscustomobject]@{ Event = 'capture-end'; Time = (Get-Date).ToString('o'); ReadyObserved = $ready } |
        ConvertTo-Json -Compress | Add-Content -LiteralPath $path -Encoding UTF8
    Write-Host "Diagnostic capture: $path"
} finally {
    if ($connection) { $connection.Dispose() }
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    (Get-Process -Id $PID).PriorityClass = $originalPriority
}
