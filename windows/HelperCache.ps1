# Compile during installation, then load the exact source-matched assembly at login.
Set-StrictMode -Version Latest
# These assemblies target .NET Framework, not PowerShell 7's .NET runtime.
# Check before either building OR loading a cache, and before installers write settings.
if ($PSVersionTable.PSVersion -lt [version]'5.1' -or $PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Windows desktop scripts require Windows PowerShell 5.1 (.NET Framework), not pwsh/PowerShell 7. Open it with: & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile; then rerun the command in that shell.'
}
function Set-DesktopSession {
    param([string]$Directory, [string]$Generation, [bool]$Active)
    $session = (Get-Process -Id $PID).SessionId
    $path = Join-Path $Directory ("desktop-session-$session.json")
    $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ([pscustomobject]@{ Generation = $Generation; Active = $Active } | ConvertTo-Json -Compress))
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary, $path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}
function Test-DesktopSession {
    param([string]$Directory, [string]$Generation)
    if (-not $Generation) { return $true } # Explicit targeted/manual helper invocation.
    $session = (Get-Process -Id $PID).SessionId
    try {
        $state = Get-Content -LiteralPath (Join-Path $Directory "desktop-session-$session.json") -Raw | ConvertFrom-Json
        return ($state.Active -and $state.Generation -eq $Generation)
    } catch { return $false }
}
function Get-DesktopSessionRevision {
    param([string]$Directory)
    $session = (Get-Process -Id $PID).SessionId
    $path = Join-Path $Directory "desktop-session-$session.json"
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).Generation
}
function Start-DesktopGeneration {
    param([string]$Directory, [string]$Revision, $StopEvent)
    $transition = New-Object Threading.Mutex($false, 'Local\DotfilesDesktopTransition')
    $locked = $false
    try {
        try { $locked = $transition.WaitOne(2000) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Desktop lifecycle transition is busy.' }
        if ((Get-DesktopSessionRevision $Directory) -ne $Revision) { return '' }
        $generation = [guid]::NewGuid().ToString('N')
        $null = $StopEvent.Reset()
        Set-DesktopSession $Directory $generation $true
        return $generation
    } finally { if ($locked) { $transition.ReleaseMutex() }; $transition.Dispose() }
}
function Stop-DesktopGeneration {
    param([string]$Directory, [string]$StopEventName = 'Local\DotfilesDesktopStartupStop')
    $transition = New-Object Threading.Mutex($false, 'Local\DotfilesDesktopTransition')
    $locked = $false
    try {
        try { $locked = $transition.WaitOne(2000) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Desktop lifecycle transition is busy.' }
        Set-DesktopSession $Directory ([guid]::NewGuid().ToString('N')) $false
        try {
            $stop = [Threading.EventWaitHandle]::OpenExisting($StopEventName)
            try { $null = $stop.Set() } finally { $stop.Dispose() }
        } catch [Threading.WaitHandleCannotBeOpenedException] { }
    } finally { if ($locked) { $transition.ReleaseMutex() }; $transition.Dispose() }
}
function Start-DesktopPowerShell {
    param([string]$EncodedCommand)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $EncodedCommand
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    return [Diagnostics.Process]::Start($info)
}
function Get-DesktopHelperAssembly {
    param([string]$Source, [string[]]$References, [string]$Directory = $PSScriptRoot, [switch]$Build)
    $hash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    $cache = Join-Path $Directory 'cache'
    $path = Join-Path $cache (([IO.Path]::GetFileNameWithoutExtension($Source)) + '-' + $hash + '.dll')
    if (-not (Test-Path -LiteralPath $path)) {
        if (-not $Build) { throw "Helper cache missing for $Source. Rerun windows\Apply.ps1 to compile it before sign-in." }
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        $temporary = Join-Path $cache (([guid]::NewGuid().ToString('N')) + '.dll')
        try {
            Add-Type -Path $Source -ReferencedAssemblies $References -OutputAssembly $temporary
            if ((Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash -ne $hash) { throw 'Helper source changed during compilation.' }
            Move-Item -LiteralPath $temporary -Destination $path -Force
        } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
    }
    return $path
}
function Initialize-DesktopRuntime {
    param([string]$Directory = $PSScriptRoot, [switch]$Build)
    $assembly = Get-DesktopHelperAssembly -Source (Join-Path $PSScriptRoot 'DesktopRuntime.cs') `
        -References @('System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll', 'System.Web.Extensions.dll') `
        -Directory $Directory -Build:$Build
    if (-not ('Dotfiles.Desktop.MonitorProbe' -as [type])) { $null = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($assembly)) }
}
