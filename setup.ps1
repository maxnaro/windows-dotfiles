[CmdletBinding()]
param(
    [ValidateRange(0, 9)]
    [int]$MonitorCount = 0,
    [switch]$NoRestart,
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

& (Join-Path $PSScriptRoot 'windows\Apply.ps1') -MonitorCount $MonitorCount -NoRestart:$NoRestart
& (Join-Path $PSScriptRoot 'windows\Enable-Startup.ps1')

if ($WithWsl) {
    & (Join-Path $PSScriptRoot 'setup-wsl.ps1') -Distribution $Distribution -Repository $LinuxDotfilesRepository
}
