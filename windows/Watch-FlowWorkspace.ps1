[CmdletBinding()]
param([switch]$Stop, [switch]$Check, [switch]$Restart, [switch]$WaitForStop, [switch]$Status, [switch]$Build, [string]$StartupGeneration,
    [string]$LogPath = (Join-Path $env:USERPROFILE '.glzr\glazewm\flow-workspace.log'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# All callbacks run in C#, never on a PowerShell thread-pool/runspace callback.
# The scripts and source live together so no SDK, module, or elevated task is needed.
function Initialize-FlowWorkspace {
    $source = Join-Path $PSScriptRoot 'FlowWorkspace.cs'
    $script:flowWorkspaceSourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    Add-Type -AssemblyName System.Windows.Forms, UIAutomationClient, UIAutomationTypes, System.Web.Extensions, WindowsBase
    $references = @('System.dll', 'System.Core.dll', 'System.Windows.Forms.dll',
        'System.Web.Extensions.dll', [Windows.Rect].Assembly.Location,
        [Windows.Automation.AutomationElement].Assembly.Location,
        [Windows.Automation.ControlType].Assembly.Location)
    . (Join-Path $PSScriptRoot 'HelperCache.ps1')
    $assembly = Get-DesktopHelperAssembly -Source $source -References $references -Build:($Build -or $Check)
    if ('Dotfiles.FlowWorkspace.Bridge' -as [type]) {
        if ([AppDomain]::CurrentDomain.GetData('DotfilesFlowWorkspaceSourceHash') -ne $script:flowWorkspaceSourceHash) {
            throw 'A different Flow workspace source is loaded in this PowerShell process. Use a fresh powershell.exe process.'
        }
        return
    }
    $null = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($assembly))
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $script:flowWorkspaceSourceHash) {
        throw 'Flow workspace source changed during compilation; retry the update.'
    }
    [AppDomain]::CurrentDomain.SetData('DotfilesFlowWorkspaceSourceHash', $script:flowWorkspaceSourceHash)
}
if ($Check -or $Build) { Initialize-FlowWorkspace; Write-Host 'PASS: Flow workspace helper compiled.'; return }
$session = (Get-Process -Id $PID).SessionId
$eventName = "Local\DotfilesFlowWorkspaceStop-$session"
$readyName = "Local\DotfilesFlowWorkspaceReady-$session"
$statusPath = Join-Path (Split-Path -Parent $LogPath) ("flow-workspace-status-$session.json")
if ($Status) {
    $state = [pscustomobject]@{ Ready = $false; ProcessId = $null; Version = $null; SourceSha256 = $null }
    if (Test-Path -LiteralPath $statusPath) {
        try {
            $saved = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
            $process = Get-Process -Id $saved.ProcessId -ErrorAction Stop
            if ($process.SessionId -eq $session -and $process.StartTime.ToUniversalTime().Ticks -eq [long]$saved.StartTimeUtcTicks) {
                $state.ProcessId = $saved.ProcessId
                $state.Version = $saved.Version
                $state.SourceSha256 = $saved.SourceSha256
                $ready = [Threading.EventWaitHandle]::OpenExisting($readyName)
                try { $state.Ready = $ready.WaitOne(0) } finally { $ready.Dispose() }
            }
        } catch { } # The owner may exit or finish writing its status during this read.
    }
    return $state
}
function Send-FlowWorkspaceStop {
    try {
        $stopEvent = [Threading.EventWaitHandle]::OpenExisting($eventName)
        try { $null = $stopEvent.Set() } finally { $stopEvent.Dispose() }
    } catch [Threading.WaitHandleCannotBeOpenedException] { }
}
if ($Stop -or $Restart) { Send-FlowWorkspaceStop }
if ($Stop -and -not $WaitForStop) { return }
$mutex = New-Object Threading.Mutex($false, "Local\DotfilesFlowWorkspace-$session")
$locked = $false
try {
    if ($Restart -or $Stop) {
        $deadline = [datetime]::UtcNow.AddSeconds(15)
        do {
            # An older process might still be compiling before it creates its stop
            # event. Keep signalling until it releases the mutex, rather than
            # silently returning while the old version is still running.
            Send-FlowWorkspaceStop
            try { $locked = $mutex.WaitOne(100) }
            catch [Threading.AbandonedMutexException] { $locked = $true }
        } while (-not $locked -and [datetime]::UtcNow -lt $deadline)
        if (-not $locked) { throw 'The previous Flow workspace helper did not stop within 15 seconds.' }
    } else {
        try { $locked = $mutex.WaitOne(2000) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { return }
    }
    if ($Stop) { return }
    . (Join-Path $PSScriptRoot 'HelperCache.ps1')
    if (-not (Test-DesktopSession $PSScriptRoot $StartupGeneration)) { return }
    Initialize-FlowWorkspace
    if (-not (Test-DesktopSession $PSScriptRoot $StartupGeneration)) { return }
    $stopEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $eventName)
    $readyEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $readyName)
    try {
        $null = $readyEvent.Reset()
        New-Item -ItemType Directory -Path (Split-Path -Parent $statusPath) -Force | Out-Null
        $owner = Get-Process -Id $PID
        [pscustomobject]@{
            ProcessId = $PID
            StartTimeUtcTicks = $owner.StartTime.ToUniversalTime().Ticks
            Version = [Dotfiles.FlowWorkspace.Bridge]::Version
            SourceSha256 = $script:flowWorkspaceSourceHash
        } | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
        if (-not (Test-DesktopSession $PSScriptRoot $StartupGeneration)) { return }
        [Dotfiles.FlowWorkspace.Bridge]::Run($stopEvent, $LogPath, $readyEvent)
    } finally {
        $null = $readyEvent.Reset()
        $readyEvent.Dispose()
        $stopEvent.Dispose()
        if (Test-Path -LiteralPath $statusPath) { Remove-Item -LiteralPath $statusPath -Force }
    }
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
