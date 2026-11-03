[CmdletBinding()]
param([switch]$Check)
$ErrorActionPreference = 'Stop'

# Emit only Alt transitions. No keyboard hook, focus change, or key suppression.
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
public static class ZebarAltWatcher {
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int key);
    public static void Run(int parentId) {
        using (var parent = Process.GetProcessById(parentId)) {
            bool? previous = null;
            while (!parent.HasExited) {
                bool down = (GetAsyncKeyState(0xA4) & 0x8000) != 0
                    || (GetAsyncKeyState(0xA5) & 0x8000) != 0;
                if (previous != down) {
                    try {
                        Console.WriteLine(down ? "down" : "up");
                        Console.Out.Flush();
                    } catch (System.IO.IOException) { return; }
                    previous = down;
                }
                Thread.Sleep(32);
            }
        }
    }
}
'@
if ($Check) { Write-Output 'PASS: Alt watcher compiled.'; return }
$owner = Get-CimInstance Win32_Process -Filter "ProcessId = $PID"
[ZebarAltWatcher]::Run([int]$owner.ParentProcessId)
