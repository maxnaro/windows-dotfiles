[CmdletBinding()]
param([switch]$Diagnostics, [switch]$DisableDiagnostics, [switch]$WithLauncher)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'DesktopSettings.ps1')
Register-DesktopStartup -Diagnostics:$Diagnostics -DisableDiagnostics:$DisableDiagnostics -WithLauncher:$WithLauncher
