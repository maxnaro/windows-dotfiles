# Opt-in desktop integration test. Focuses existing windows; restores focus afterwards.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PluginExe, [string]$FromWorkspace, [switch]$ClickResult, [switch]$MinimizeTarget, [string]$SearchTerm)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NativeFlowTest {
[DllImport("user32.dll")]public static extern bool ShowWindowAsync(IntPtr h,int command);
[DllImport("user32.dll")]public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")]public static extern bool SetCursorPos(int x,int y);
[DllImport("user32.dll")]public static extern void mouse_event(uint f,uint x,uint y,uint d,UIntPtr e);
[DllImport("user32.dll")]public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
[DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")]public static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint id);
}
'@
$cli=Join-Path $env:USERPROFILE 'scoop\apps\glazewm\current\cli\GlazeWM.exe'
function Snapshot { & $cli query workspaces | ConvertFrom-Json }
function Windows($nodes,$ws) { foreach($n in $nodes) { if($n.type -eq 'window') { [pscustomobject]@{Id=$n.id;Handle=[long]$n.handle;Workspace=$ws;Focus=$n.hasFocus;Process=$n.processName;Title=$n.title} };if($n.children){Windows $n.children $ws} } }
$queryRequest='{"method":"query","parameters":[""]}'
$queryProcess=New-Object Diagnostics.Process
$queryProcess.StartInfo.FileName=$PluginExe
$queryProcess.StartInfo.Arguments='"'+$queryRequest.Replace('"','\"')+'"'
$queryProcess.StartInfo.UseShellExecute=$false
$queryProcess.StartInfo.RedirectStandardOutput=$true
$queryProcess.StartInfo.CreateNoWindow=$true
$null=$queryProcess.Start()
$queryResult=$queryProcess.StandardOutput.ReadToEnd() | ConvertFrom-Json
$queryProcess.WaitForExit()
$queryProcess.Dispose()
if(-not $queryResult.result.Count){throw 'Native plugin returned no windows'}
$before=Snapshot
$all=@($before.data.workspaces | ForEach-Object {Windows $_.children $_.name})
$original=@($all | Where-Object Focus | Select-Object -First 1)
$origin=@($before.data.workspaces | Where-Object hasFocus)[0].name
$searchWorkspace=if($FromWorkspace){$FromWorkspace}else{$origin}
$target=@($all | Where-Object {$_.Workspace -ne $searchWorkspace -and $_.Process -eq 'olk'} | Select-Object -First 1)
if(-not $target.Count){$target=@($all | Where-Object {$_.Workspace -ne $searchWorkspace -and $_.Process -eq 'firefox'} | Select-Object -First 1)}
if(-not $target.Count){throw 'Need Outlook or Firefox on another workspace'}
$target=$target[0]
function Is-Flow {
    $owner=0
    $null=[NativeFlowTest]::GetWindowThreadProcessId([NativeFlowTest]::GetForegroundWindow(),[ref]$owner)
    (Get-Process -Id $owner -ErrorAction SilentlyContinue).ProcessName -eq 'Flow.Launcher'
}
$shell=New-Object -ComObject WScript.Shell
$wasMinimized=[NativeFlowTest]::IsIconic([IntPtr]$target.Handle)
try {
    if($MinimizeTarget){$null=[NativeFlowTest]::ShowWindowAsync([IntPtr]$target.Handle,6);Start-Sleep -Milliseconds 400}
    if($FromWorkspace){$null=& $cli command focus --workspace $FromWorkspace}
    $null=[NativeFlowTest]::SetThreadDpiAwarenessContext([IntPtr](-4))
    if(Is-Flow){$shell.SendKeys('{ESC}');Start-Sleep -Milliseconds 300}
    $shell.SendKeys('% ')
    $openDeadline=[datetime]::UtcNow.AddSeconds(4)
    while(-not (Is-Flow) -and [datetime]::UtcNow -lt $openDeadline){Start-Sleep -Milliseconds 100}
    if(-not (Is-Flow)){throw 'Flow did not open; refusing input'}
    $search=if($SearchTerm){$SearchTerm}else{'gw '+$target.Process}
    $shell.SendKeys('^a' + $search)
    Start-Sleep -Milliseconds 800
    $handle=[NativeFlowTest]::GetForegroundWindow()
    if(-not (Is-Flow)){throw 'Flow not foreground; refusing input'}
    $root=[Windows.Automation.AutomationElement]::FromHandle($handle)
    $rows=$root.FindAll([Windows.Automation.TreeScope]::Descendants,(New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::ListItem)))
    $selected=$false
    foreach($row in $rows){
        $text=$row.Current.Name
        foreach($part in $row.FindAll([Windows.Automation.TreeScope]::Descendants,(New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Text)))){$text+=' '+$part.Current.Name}
        if($text.Contains('Workspace '+$target.Workspace) -and $text.Contains($target.Process) -and $text.Contains($target.Title)){
            ([Windows.Automation.SelectionItemPattern]$row.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)).Select()
            $selected=$true;break
        }
    }
    if(-not $selected){throw 'Native result not exposed in Flow'}
    if($ClickResult){
        $bounds=$row.Current.BoundingRectangle
        $null=[NativeFlowTest]::SetCursorPos([int]($bounds.X+$bounds.Width/2),[int]($bounds.Y+$bounds.Height/2))
        [NativeFlowTest]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
        Start-Sleep -Milliseconds 40
        [NativeFlowTest]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
    }else{$shell.SendKeys('{ENTER}')}
    $deadline=[datetime]::UtcNow.AddSeconds(8)
    do {
        Start-Sleep -Milliseconds 100
        $after=Snapshot
        $now=@($after.data.workspaces | ForEach-Object {Windows $_.children $_.name})
        $focused=@($now | Where-Object {$_.Id -eq $target.Id -and $_.Focus})
        if($focused.Count -and [NativeFlowTest]::GetForegroundWindow().ToInt64() -eq $target.Handle){break}
    }while([datetime]::UtcNow -lt $deadline)
    if(-not $focused.Count -or [NativeFlowTest]::GetForegroundWindow().ToInt64() -ne $target.Handle){throw 'Selected window did not become foreground'}
    foreach($old in $all){$current=@($now | Where-Object Id -eq $old.Id);if($current.Count -and $current[0].Workspace -ne $old.Workspace){throw 'An existing window moved workspaces'}}
    Write-Host 'PASS: real Flow native result focused a hidden-workspace window without moving existing windows.'
} finally {
    if($MinimizeTarget -and -not $wasMinimized -and [NativeFlowTest]::IsIconic([IntPtr]$target.Handle)){$null=[NativeFlowTest]::ShowWindowAsync([IntPtr]$target.Handle,9)}
    if($original.Count){$null=& $cli command focus --workspace $origin;$null=& $cli command focus --container-id $original[0].Id}
}
