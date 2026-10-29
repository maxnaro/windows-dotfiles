# Read-only attribution helpers; never persist command lines or window titles.
Set-StrictMode -Version Latest
function Get-WebViewHost {
    param($Process, [hashtable]$ProcessesById)
    if ($Process.Name -ne 'msedgewebview2.exe') { return $Process.Name }
    if ($Process.CommandLine -match '--webview-exe-name=(?:"([^"]+)"|(\S+))') {
        return ($Matches[1] + $Matches[2])
    }
    $seen = @{}
    $ancestor = $Process
    for ($i = 0; $i -lt 16; $i++) {
        $parent = [int]$ancestor.ParentProcessId
        if ($seen.ContainsKey($parent) -or -not $ProcessesById.ContainsKey($parent)) { break }
        $seen[$parent] = $true
        $ancestor = $ProcessesById[$parent]
        if ($ancestor.Name -ne 'msedgewebview2.exe') { return $ancestor.Name }
        if ($ancestor.CommandLine -match '--webview-exe-name=(?:"([^"]+)"|(\S+))') { return ($Matches[1] + $Matches[2]) }
    }
    return 'unknown'
}
function Get-StartupProcessPerformance {
    param([object[]]$Counters, [object[]]$Metadata, [int]$LogicalProcessors)
    $byId = @{}
    foreach ($process in $Metadata) { $byId[[int]$process.ProcessId] = $process }
    $all = @($Counters | Where-Object { $_.IDProcess -gt 0 -and $_.Name -ne '_Total' })
    $selected = @{}
    foreach ($process in @($all | Sort-Object PercentProcessorTime -Descending | Select-Object -First 10) +
        @($all | Sort-Object IODataBytesPersec -Descending | Select-Object -First 10) +
        @($all | Where-Object { $_.Name -match '^(glazewm|zebar|msedgewebview2|PowerToys|Microsoft.CmdPal|Flow.Launcher|Everything|powershell)' })) {
        $selected[[int]$process.IDProcess] = $process
    }
    foreach ($id in @($selected.Keys | Sort-Object)) {
        $counter = $selected[$id]
        $process = $byId[$id]
        [pscustomobject]@{
            Name = $counter.Name; IDProcess = $id
            PercentProcessorTime = $counter.PercentProcessorTime
            CpuPercent = [Math]::Round($counter.PercentProcessorTime / [Math]::Max(1, $LogicalProcessors), 2)
            WorkingSetPrivate = $counter.WorkingSetPrivate; IODataBytesPersec = $counter.IODataBytesPersec
            ParentProcessId = if ($process) { $process.ParentProcessId } else { $null }
            BasePriority = if ($process) { $process.Priority } else { $null }
            Host = if ($process) { Get-WebViewHost $process $byId } else { 'unknown' }
        }
    }
}
