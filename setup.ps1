[CmdletBinding()]
param(
    [ValidateRange(0, 9)]
    [int]$MonitorCount = 0,
    [switch]$NoRestart,
    [switch]$WithLauncher,
    [switch]$StartupDiagnostics,
    [switch]$WithoutZebar,
    [ValidateSet('Auto', 'Native', 'Overlay', 'None')][string]$WallpaperMode,
    [switch]$WithWsl,
    [string]$Distribution = 'UbuntuNC',
    [string]$LinuxDotfilesRepository = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Use a normal PowerShell window; Scoop and these settings are per-user.
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    throw 'Install Scoop first using the instructions in README.md, then rerun setup.ps1.'
}

function Invoke-Scoop {
    param([string[]]$Arguments)
    & scoop @Arguments
    if (-not $?) { throw "Scoop failed: $($Arguments -join ' ')" }
}

$scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Invoke-Scoop -Arguments @('install', 'git')
}
if (-not (Test-Path -LiteralPath (Join-Path $scoopRoot 'buckets\extras'))) {
    Invoke-Scoop -Arguments @('bucket', 'add', 'extras')
}
foreach ($app in @('glazewm', 'zebar')) {
    if (-not (Test-Path -LiteralPath (Join-Path $scoopRoot "apps\$app\current"))) {
        Invoke-Scoop -Arguments @('install', "extras/$app")
    }
}

& (Join-Path $PSScriptRoot 'windows\Configure-Desktop.ps1')
& (Join-Path $PSScriptRoot 'windows\Configure-Terminal.ps1')
$wallpaperArguments = @{}
if ($PSBoundParameters.ContainsKey('WallpaperMode')) { $wallpaperArguments.WallpaperMode = $WallpaperMode }
& (Join-Path $PSScriptRoot 'windows\Apply.ps1') -MonitorCount $MonitorCount -NoRestart:$NoRestart -WithoutZebar:$WithoutZebar @wallpaperArguments
& (Join-Path $PSScriptRoot 'windows\Enable-Startup.ps1') -Diagnostics:$StartupDiagnostics

if ($WithLauncher) {
    foreach ($app in @('flow-launcher', 'everything')) {
        if (-not (Test-Path -LiteralPath (Join-Path $scoopRoot "apps\$app\current"))) {
            Invoke-Scoop -Arguments @('install', "extras/$app")
        }
    }
    & (Join-Path $PSScriptRoot 'windows\Configure-Launcher.ps1') -NoStart:$NoRestart
}

if ($WithWsl) {
    & (Join-Path $PSScriptRoot 'setup-wsl.ps1') -Distribution $Distribution -Repository $LinuxDotfilesRepository
}
