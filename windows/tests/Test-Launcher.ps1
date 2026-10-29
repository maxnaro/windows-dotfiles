# Integration test against the installed, running launchers. Uses Flow's own Everything SDK.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'DesktopSettings.ps1')
function Assert-True { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }
$scoopRoot = if ($env:SCOOP) { $env:SCOOP } else { Join-Path $env:USERPROFILE 'scoop' }
$flowRoot = Join-Path $scoopRoot 'apps\flow-launcher\current'
$manifestPath = Join-Path $flowRoot 'scoop-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { $manifestPath = Join-Path $flowRoot 'manifest.json' }
$manifest = Read-SettingJson $manifestPath
$app = Join-Path $flowRoot ("app-$($manifest.version)")
$data = Join-Path $app 'UserData'
$settings = Read-SettingJson (Join-Path $data 'Settings\Settings.json')
$explorer = Read-SettingJson (Join-Path $data 'Settings\Plugins\Flow.Launcher.Plugin.Explorer\Settings.json')
Assert-True ($settings.Hotkey -eq 'Alt + Space') 'Flow hotkey is incorrect.'
Assert-True ($settings.SearchWindowScreen -eq 'Focus') 'Flow is not following the focused monitor.'
Assert-True ($settings.Theme -eq 'Chocolatier') 'Flow theme is incorrect.'
foreach ($property in @('QueryBoxFont', 'ResultFont', 'ResultSubFont')) {
    Assert-True ($settings.$property -eq 'JetBrainsMono NF, Cascadia Mono') "Incorrect font: $property"
}
Assert-True ($settings.QueryBoxFontSize -eq 18 -and $settings.ResultItemFontSize -eq 14 -and
    $settings.ResultSubItemFontSize -eq 12) 'Flow font sizes are incorrect.'
$themePath = Join-Path $data 'Themes\Chocolatier.xaml'
Assert-True ([IO.File]::ReadAllText($themePath) -eq
    [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'flow-launcher\Chocolatier.xaml'))) 'Installed theme differs from the tracked theme.'
Assert-True ($explorer.IndexSearchEngine -eq 1) 'Flow is not using Everything.'
Assert-True (Test-Path -LiteralPath $explorer.EverythingInstalledPath) 'Flow cannot find Everything.'
Assert-True (@(Get-Service -Name Everything -ErrorAction SilentlyContinue).Count -eq 0) 'An Everything service is installed; this test expects the service-free configuration.'
$ini = [IO.File]::ReadAllText((Join-Path $scoopRoot 'apps\everything\current\Everything.ini'))
Assert-True ((Get-IniValue $ini 'run_as_admin') -eq '0') 'Everything is configured to elevate.'
Assert-True (-not [string]::IsNullOrWhiteSpace((Get-IniValue $ini 'folders'))) 'No index folders configured.'

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
public static class DotfilesLauncherValidation {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibrary(string path);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetTokenInformation(IntPtr token, int type, out int data, int size, out int needed);
    public static bool IsElevated(Process process) {
        IntPtr token;
        if (!OpenProcessToken(process.Handle, 8, out token)) throw new System.ComponentModel.Win32Exception();
        try {
            int value, needed;
            if (!GetTokenInformation(token, 20, out value, 4, out needed)) throw new System.ComponentModel.Win32Exception();
            return value != 0;
        } finally { CloseHandle(token); }
    }
    [DllImport("Everything.dll", CharSet = CharSet.Unicode)] public static extern void Everything_SetSearchW(string value);
    [DllImport("Everything.dll")] public static extern void Everything_SetMax(uint value);
    [DllImport("Everything.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool Everything_QueryW([MarshalAs(UnmanagedType.Bool)] bool wait);
    [DllImport("Everything.dll")] public static extern uint Everything_GetNumResults();
    [DllImport("Everything.dll")] public static extern uint Everything_GetLastError();
    [DllImport("Everything.dll", CharSet = CharSet.Unicode)]
    public static extern uint Everything_GetResultFullPathNameW(uint index, StringBuilder buffer, uint size);
}
'@
$architecture = if ([IntPtr]::Size -eq 8) { 'x64' } else { 'x86' }
$dll = Join-Path $app ("EverythingSDK\$architecture\Everything.dll")
Assert-True ([DotfilesLauncherValidation]::LoadLibrary($dll) -ne [IntPtr]::Zero) 'Could not load Flow Everything SDK.'
foreach ($name in @('Flow.Launcher', 'Everything')) {
    $processes = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
    Assert-True ($processes.Count -eq 1) "Expected one running $name process."
    Assert-True (-not [DotfilesLauncherValidation]::IsElevated($processes[0])) "$name is elevated."
}
function Find-IndexedPath {
    param([string]$Path)
    [DotfilesLauncherValidation]::Everything_SetSearchW(('"' + $Path + '"'))
    [DotfilesLauncherValidation]::Everything_SetMax(100)
    if (-not [DotfilesLauncherValidation]::Everything_QueryW($true)) {
        throw "Everything IPC query failed: $([DotfilesLauncherValidation]::Everything_GetLastError())"
    }
    $count = [DotfilesLauncherValidation]::Everything_GetNumResults()
    for ($i = 0; $i -lt $count; $i++) {
        $buffer = New-Object Text.StringBuilder 32768
        $null = [DotfilesLauncherValidation]::Everything_GetResultFullPathNameW($i, $buffer, 32768)
        if ($buffer.ToString().Equals($Path, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
function Wait-IndexedPath {
    param([string]$Path)
    $deadline = (Get-Date).AddSeconds(30)
    do {
        if (Find-IndexedPath $Path) { return }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw "File did not appear in Everything's folder index: $Path"
}
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Wait-IndexedPath (Join-Path $repo 'README.md')
$file = Join-Path $repo ('launcher-probe-' + [guid]::NewGuid() + '.tmp')
$renamed = $file + '.renamed.tmp'
try {
    [IO.File]::WriteAllText($file, 'Temporary Everything folder-monitoring probe.')
    Wait-IndexedPath $file
    Move-Item -LiteralPath $file -Destination $renamed
    Wait-IndexedPath $renamed
    Assert-True (-not (Find-IndexedPath $file)) 'The old filename remains after the rename.'
    Write-Host 'PASS: Flow settings, Everything IPC search, file creation/rename monitoring, no service, and unelevated launcher processes.'
} finally {
    foreach ($path in @($file, $renamed)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
}
