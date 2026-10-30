# Compile during installation, then load the exact source-matched assembly at login.
Set-StrictMode -Version Latest
function Set-DesktopSession {
    param([string]$Directory, [string]$Generation, [bool]$Active)
    $session = (Get-Process -Id $PID).SessionId
    $path = Join-Path $Directory ("desktop-session-$session.json")
    $temporary = $path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ([pscustomobject]@{ Generation = $Generation; Active = $Active } | ConvertTo-Json -Compress))
        Move-Item -LiteralPath $temporary -Destination $path -Force
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

function Install-DesktopLauncher {
    param([string]$Directory = $PSScriptRoot)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $source = Join-Path $PSScriptRoot 'DesktopLauncher.cs'
    $temporary = Join-Path $Directory (([guid]::NewGuid().ToString('N')) + '.exe')
    try {
        $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
        $compilerOutput = & $compiler /nologo /target:winexe /out:$temporary $source
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporary)) { throw ('Desktop launcher compilation failed: ' + ($compilerOutput -join "`n")) }
        $probe = New-Object Diagnostics.Process
        $probe.StartInfo.FileName = $temporary
        $probe.StartInfo.Arguments = 'invalid-mode'
        $probe.StartInfo.UseShellExecute = $false
        $probe.StartInfo.CreateNoWindow = $true
        try {
            try { $null = $probe.Start() }
            catch {
                $failure = $_.Exception
                while ($failure.InnerException) { $failure = $failure.InnerException }
                $detail = "Launcher execution failed: $failure; exists=$(Test-Path -LiteralPath $temporary); SHA256=$((Get-FileHash -LiteralPath $temporary -ErrorAction SilentlyContinue).Hash)"
                if ($failure -is [ComponentModel.Win32Exception]) { $detail += "; Win32=$($failure.NativeErrorCode)" }
                throw $detail
            }
            if (-not $probe.WaitForExit(5000)) { $probe.Kill(); throw 'Launcher validation timed out.' }
            if ($probe.ExitCode -ne 1) { throw 'Launcher validation failed.' }
        } finally { $probe.Dispose() }
        Move-Item -LiteralPath $temporary -Destination (Join-Path $Directory 'DesktopLauncher.exe') -Force
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary } }
}

function Start-ConsoleFreeProcess {
    param([string]$FilePath, [string]$Arguments = '')
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = $Arguments
    $info.WorkingDirectory = Split-Path -Parent $FilePath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    return [Diagnostics.Process]::Start($info)
}
