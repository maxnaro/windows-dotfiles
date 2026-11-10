[CmdletBinding()]
param([switch]$Stop, [switch]$Run, [string]$StartupGeneration, [string]$Directory = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'HelperCache.ps1')

function Get-NativeWallpaperState { [Dotfiles.Desktop.Wallpaper]::Capture() }
function Set-NativeWallpaper { param([string]$Path); [Dotfiles.Desktop.Wallpaper]::Apply($Path) }
function Test-NativeWallpaper { param([string]$Path); [Dotfiles.Desktop.Wallpaper]::Matches($Path) }
function Restore-NativeWallpaper { param([string]$Json); [Dotfiles.Desktop.Wallpaper]::Restore($Json) }

function Set-DesktopWallpaperConfiguration {
    param([ValidateSet('', 'Auto', 'Native', 'Overlay', 'None')][string]$Mode,
        [string]$ImagePath, [string]$Directory, [string]$BackupDirectory)
    $configuration = Join-Path $Directory 'desktop-startup.json'
    $previous = if (Test-Path -LiteralPath $configuration) { Get-Content -LiteralPath $configuration -Raw | ConvertFrom-Json } else { $null }
    if (-not $Mode) { $Mode = if ($previous -and $previous.PSObject.Properties['WallpaperMode']) { $previous.WallpaperMode } else { 'Auto' } }
    $backend = 'None'
    $reason = ''
    $originalPath = Join-Path $Directory 'wallpaper-original.json'
    if ($Mode -in @('Overlay', 'None') -and $previous -and $previous.WallpaperBackend -eq 'Native' -and (Test-Path -LiteralPath $originalPath)) {
        [IO.File]::WriteAllText((Join-Path $BackupDirectory 'wallpaper-state.json'), ((Get-NativeWallpaperState) | ConvertTo-Json -Depth 8))
        Restore-NativeWallpaper (Get-Content -LiteralPath $originalPath -Raw)
    }
    if ($Mode -ne 'None') {
        if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) { throw "Wallpaper not found: $ImagePath" }
        $backend = 'Overlay'
        if ($Mode -in @('Auto', 'Native')) {
            $state = $null
            $attempted = $false
            try {
                $state = Get-NativeWallpaperState
                $snapshot = $state | ConvertTo-Json -Depth 8
                # Write before calling Windows so even interrupted application is recoverable.
                [IO.File]::WriteAllText((Join-Path $BackupDirectory 'wallpaper-state.json'), $snapshot)
                if ($state.SlideshowActive) { throw 'An existing wallpaper slideshow is preserved.' }
                $attempted = $true
                Set-NativeWallpaper $ImagePath
                if (-not (Test-NativeWallpaper $ImagePath)) { throw 'The native wallpaper did not take effect.' }
                $backend = 'Native'
                if (-not (Test-Path -LiteralPath $originalPath)) { [IO.File]::WriteAllText($originalPath, $snapshot) }
            } catch {
                $reason = $_.Exception.Message
                if ($attempted -and ((Get-NativeWallpaperState | ConvertTo-Json -Depth 8) -ne $snapshot)) {
                    try { Restore-NativeWallpaper $snapshot }
                    catch { throw "Wallpaper application and rollback failed. Restore $BackupDirectory before retrying. $($_.Exception.Message)" }
                }
                if ($Mode -eq 'Native') { throw "Native wallpaper unavailable: $reason" }
                Write-Warning "Using the native image overlay: $reason"
            }
        }
    }
    return [pscustomobject]@{ WallpaperMode = $Mode; WallpaperBackend = $backend; WallpaperPath = $ImagePath; WallpaperReason = $reason }
}

function Test-DesktopWallpaperOverlayRequired {
    param($Configuration)
    if ($Configuration.WallpaperMode -eq 'None') { return $false }
    if ($Configuration.WallpaperBackend -eq 'Overlay') { return $true }
    if ($Configuration.WallpaperMode -eq 'Auto') {
        try { return (-not (Test-NativeWallpaper $Configuration.WallpaperPath)) }
        catch { return $true }
    }
    if (-not (Test-NativeWallpaper $Configuration.WallpaperPath)) { throw 'Native wallpaper was replaced; rerun Apply.ps1 or select Auto mode.' }
    return $false
}

function Stop-DesktopWallpaper {
    param([switch]$Wait)
    $session = (Get-Process -Id $PID).SessionId
    function Send-WallpaperStop {
        try {
            $event = [Threading.EventWaitHandle]::OpenExisting("Local\DotfilesWallpaperStop-$session")
            try { $null = $event.Set() } finally { $event.Dispose() }
        } catch [Threading.WaitHandleCannotBeOpenedException] { }
    }
    Send-WallpaperStop
    if ($Wait) {
        $mutex = New-Object Threading.Mutex($false, "Local\DotfilesWallpaper-$session")
        $locked = $false
        try {
            $deadline = [datetime]::UtcNow.AddSeconds(5)
            do {
                Send-WallpaperStop
                try { $locked = $mutex.WaitOne(100) } catch [Threading.AbandonedMutexException] { $locked = $true }
            } while (-not $locked -and [datetime]::UtcNow -lt $deadline)
            if (-not $locked) { throw 'Wallpaper overlay did not stop within five seconds.' }
        } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
    }
}
if ($MyInvocation.InvocationName -eq '.') { return }
if ($Stop) { Stop-DesktopWallpaper -Wait; return }
if (-not $Run) { throw 'Use -Run or -Stop.' }
if (-not (Test-DesktopSession $Directory $StartupGeneration)) { return }
Initialize-DesktopRuntime -Directory $Directory
$config = Get-Content -LiteralPath (Join-Path $Directory 'desktop-startup.json') -Raw | ConvertFrom-Json
$session = (Get-Process -Id $PID).SessionId
$mutex = New-Object Threading.Mutex($false, "Local\DotfilesWallpaper-$session")
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { return }
    # Recheck after acquiring ownership. Native mode normally needs no resident process.
    if (-not (Test-DesktopSession $Directory $StartupGeneration)) { return }
    if (-not (Test-DesktopWallpaperOverlayRequired $config)) { return }
    $stopEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, "Local\DotfilesWallpaperStop-$session")
    $readyEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, "Local\DotfilesWallpaperReady-$session")
    try {
        $null = $readyEvent.Reset()
        if (-not (Test-DesktopSession $Directory $StartupGeneration)) { return }
        [Dotfiles.Desktop.WallpaperOverlay]::Run($config.WallpaperPath, $stopEvent, $readyEvent)
    }
    finally { $null = $readyEvent.Reset(); $readyEvent.Dispose(); $stopEvent.Dispose() }
} finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
