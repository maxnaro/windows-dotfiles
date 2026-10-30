[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'HelperCache.ps1')
$root = Join-Path $env:TEMP ('launcher fixture $ ' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $root | Out-Null
try {
    Copy-Item (Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-DesktopLauncher.ps1') $root
    Install-DesktopLauncher $root
    $fixture = @'
param([string]$GlazeCli, [switch]$CompanionsOnly, [switch]$StopCompanions, [switch]$Restart)
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public class ConsoleProbe { [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("kernel32.dll")] public static extern uint GetConsoleProcessList([Out] uint[] p, uint n); }'
if ([ConsoleProbe]::GetConsoleWindow() -ne [IntPtr]::Zero -or [ConsoleProbe]::GetConsoleProcessList((New-Object uint[] 8), 8) -ne 0) { exit 91 }
Add-Type -AssemblyName System.Windows.Forms
$form = New-Object Windows.Forms.Form
try { $form.Show(); [Windows.Forms.Application]::DoEvents(); if (-not $form.Visible -or $form.Handle -eq [IntPtr]::Zero) { exit 93 } } finally { $form.Dispose() }
if ($Restart) { Start-Sleep -Seconds 2; [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'survived'), 'yes'); exit 0 }
if ($GlazeCli -and $GlazeCli -ne "path with spaces and ' quote") { exit 92 }
exit 7
'@
    [IO.File]::WriteAllText((Join-Path $root 'Start-Desktop.ps1'), $fixture)
    [IO.File]::WriteAllText((Join-Path $root 'Watch-FlowWorkspace.ps1'), $fixture)
    foreach ($mode in @('startup "path with spaces and '' quote"', 'companions', 'shutdown')) {
        $child = Start-ConsoleFreeProcess (Join-Path $root 'DesktopLauncher.exe') $mode
        try {
            if (-not $child.WaitForExit(10000) -or $child.ExitCode -ne 7) { throw "Console/argument/exit-code failure: $mode" }
        } finally { $child.Dispose() }
    }
    $child = Start-ConsoleFreeProcess (Join-Path $root 'DesktopLauncher.exe') 'reload'
    try { if (-not $child.WaitForExit(1500) -or $child.ExitCode -ne 0) { throw 'Reload failed to detach.' } } finally { $child.Dispose() }
    $deadline = [datetime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path (Join-Path $root 'survived')) -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path (Join-Path $root 'survived'))) { throw 'Detached console-free helper did not survive.' }
    Write-Host 'PASS: launcher console absence, modes, arguments, exit codes and detached survival.'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
