# Run in Windows PowerShell 5.1. Unsupported hosts are simulated by temporarily
# changing version metadata, not by installing PowerShell 7 or changing its policy.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$windows = Split-Path -Parent $PSScriptRoot
$repository = Split-Path -Parent $windows
. (Join-Path $windows 'HelperCache.ps1')
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
Assert-True ([bool](Get-Command Get-DesktopHelperAssembly -CommandType Function)) 'Supported host did not load the helper library.'
$root = Join-Path $env:TEMP ('dotfiles host guard ' + [guid]::NewGuid())
$environment = @{}
foreach ($name in @('USERPROFILE', 'LOCALAPPDATA', 'SCOOP')) { $environment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$edition = $PSVersionTable.PSEdition
$version = $PSVersionTable.PSVersion
New-Item -ItemType Directory -Path $root | Out-Null
# Defensive stubs: even a broken early guard must not install packages or compile.
function scoop { throw 'Host guard missed: reached package management.' }
function Add-Type { throw 'Host guard missed: reached helper compilation.' }
try {
    $env:USERPROFILE = Join-Path $root 'profile'
    $env:LOCALAPPDATA = Join-Path $root 'local'
    $env:SCOOP = Join-Path $root 'scoop'
    $entries = @(
        @{ Path = (Join-Path $windows 'HelperCache.ps1'); Parameters = @{} },
        @{ Path = (Join-Path $windows 'Apply.ps1'); Parameters = @{ MonitorCount = 1; NoRestart = $true; WallpaperMode = 'None' } },
        @{ Path = (Join-Path $windows 'Enable-Startup.ps1'); Parameters = @{} },
        @{ Path = (Join-Path $repository 'setup.ps1'); Parameters = @{ NoRestart = $true } }
    )
    foreach ($hostInfo in @(
        # Keep the real engine's version for Core simulation: Windows PowerShell's
        # Set-StrictMode -Version Latest cannot accept a simulated 7.x version.
        @{ PSEdition = 'Core'; PSVersion = $version },
        @{ PSEdition = 'Desktop'; PSVersion = [version]'5.0' }
    )) {
        $PSVersionTable.PSEdition = $hostInfo.PSEdition
        $PSVersionTable.PSVersion = $hostInfo.PSVersion
        foreach ($entry in $entries) {
            $failure = ''
            try { $parameters = $entry.Parameters; & $entry.Path @parameters }
            catch { $failure = $_.Exception.Message }
            Assert-True ($failure.Contains('require Windows PowerShell 5.1 (.NET Framework)') -and $failure.Contains('powershell.exe')) "Missing actionable host error for $($entry.Path): $failure"
            Assert-True (@(Get-ChildItem -LiteralPath $root -Force).Count -eq 0) "Unsupported host wrote files before rejecting $($entry.Path)."
        }
    }
} finally {
    $PSVersionTable.PSEdition = $edition
    $PSVersionTable.PSVersion = $version
    foreach ($name in $environment.Keys) { [Environment]::SetEnvironmentVariable($name, $environment[$name], 'Process') }
    Remove-Item -LiteralPath $root -Recurse -Force
}
# Loading remains valid after restoring the actual host metadata.
. (Join-Path $windows 'HelperCache.ps1')
Write-Host 'PASS: Windows PowerShell 5.1 accepted; simulated Core/old Desktop hosts rejected before package operations, compilation, cache loading or settings writes.'
