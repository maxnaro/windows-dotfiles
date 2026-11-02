# Run with Windows PowerShell 5.1. -Live also checks IPC and helper lifecycle.
[CmdletBinding()]
param([switch]$Live, [switch]$LaunchApps)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$windows = Split-Path -Parent $PSScriptRoot
& (Join-Path $windows 'Watch-FlowWorkspace.ps1') -Check
function Assert-True { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }
function New-Snapshot {
    param([string]$Workspace = '6', [long]$Original = 101)
    $snapshot = New-Object Dotfiles.FlowWorkspace.Snapshot
    $snapshot.Workspace = $Workspace
    $snapshot.FocusedHandle = $Original
    foreach ($row in @(@('1', 0, 0, 2300, 1440, $true), @('3', 0, 0, 2300, 1440, $false), @('6', 2300, 0, 1920, 1080, $true))) {
        $info = New-Object Dotfiles.FlowWorkspace.WorkspaceInfo
        $info.Name = $row[0]; $info.Id = [guid]::NewGuid().ToString()
        $info.X = $row[1]; $info.Y = $row[2]; $info.Width = $row[3]; $info.Height = $row[4]; $info.IsDisplayed = $row[5]
        $snapshot.Workspaces.Add($info.Name, $info)
    }
    foreach ($row in @(@(101, '1', 'WindowsTerminal'), @(202, '3', 'firefox'), @(303, '6', 'notepad'), @(505, '1', 'explorer'))) {
        $window = New-Object Dotfiles.FlowWorkspace.ManagedWindow
        $window.Handle = $row[0]; $window.Workspace = $row[1]; $window.Process = $row[2]
        $window.Id = [guid]::NewGuid().ToString()
        $snapshot.Windows.Add($window.Handle, $window)
    }
    return $snapshot
}
Assert-True ([Dotfiles.FlowWorkspace.Bridge]::ClassifyKey(13, $true, $false, $true, $false, $false) -eq 'dismiss') 'Ctrl+Enter armed placement instead of dismissing routing.'
$now = [datetime]::UtcNow
$snapshot = New-Snapshot
$state = New-Object Dotfiles.FlowWorkspace.Placement
. (Join-Path $windows 'Enable-FlowWorkspace.ps1')
$command = 'shell-exec powershell.exe -File "%USERPROFILE%/.glzr/glazewm/Watch-FlowWorkspace.ps1"'
foreach ($commands in @("  startup_commands: ['shell-exec zebar']", "  startup_commands: []", "  startup_commands:`r`n    - 'shell-exec zebar'")) {
    $fixture = "general:`r`n$commands`r`n  focus_follows_cursor: false`r`nworkspaces:`r`n  - name: '6'`r`n"
    $updated = Add-FlowWorkspaceCommand $fixture 'startup_commands' $command
    Assert-True ($updated.Contains('Watch-FlowWorkspace.ps1') -and $updated.Contains('focus_follows_cursor: false')) 'Targeted update lost existing general settings.'
    Assert-True ((Add-FlowWorkspaceCommand $updated 'startup_commands' $command) -eq $updated) 'Targeted lifecycle update is not idempotent.'
    if ($fixture.Contains('zebar')) { Assert-True ($updated.Contains('zebar')) 'Targeted update removed an existing startup command.' }
}

Assert-True ([Dotfiles.FlowWorkspace.Bridge]::ClassifyKey(13, $true, $false, $false, $false, $false) -eq 'commit') 'Enter did not arm a Flow result.'
Assert-True ([Dotfiles.FlowWorkspace.Bridge]::ClassifyKey(13, $true, $false, $false, $true, $false) -eq 'none') 'Opening Flow context menu was mistaken for a launch.'
Assert-True ([Dotfiles.FlowWorkspace.Bridge]::ClassifyKey(27, $true, $false, $false, $false, $false) -eq 'dismiss') 'Escape did not preserve origin for dismissal.'
Assert-True ([Dotfiles.FlowWorkspace.Bridge]::ClassifyKey(32, $false, $true, $false, $false, $false) -eq 'intent') 'Alt+Space did not capture workspace before Flow.'
Assert-True ([Dotfiles.FlowWorkspace.Bridge]::ClassifyKey(32, $true, $true, $false, $false, $false) -eq 'dismiss') 'Toggling Flow closed did not preserve origin for dismissal.'
Assert-True ([Dotfiles.FlowWorkspace.Bridge]::ClassifyKey(0x36, $true, $true, $false, $false, $false) -eq 'cancel') 'Workspace switch was mistaken for a Flow result shortcut.'
Assert-True ([Dotfiles.FlowWorkspace.Bridge]::ClassifyKey(0x30, $true, $true, $false, $false, $false) -eq 'quick') 'Unreserved Flow result shortcut was lost.'
Assert-True ([Dotfiles.FlowWorkspace.Bridge]::ClassifyKey(0x41, $false, $false, $false, $false, $false) -eq 'cancel') 'Further typing outside Flow did not cancel.'
Assert-True ([Dotfiles.FlowWorkspace.Bridge]::ClassifyKey(9, $true, $true, $false, $false, $false) -eq 'cancel') 'Alt+Tab did not release the workspace guard.'
Assert-True ([Dotfiles.FlowWorkspace.Placement]::MatchesProcess('firefox.exeC:\Apps', 'firefox')) 'Concatenated WPF title/path lost executable identity.'
Assert-True (-not [Dotfiles.FlowWorkspace.Placement]::MatchesProcess('firefox.exeOtherText', 'firefox')) 'An executable-name substring was treated as identity.'

# Freeze the invoking workspace even if the launcher/focus events change WM focus.
$state.Begin($snapshot, 101)
$snapshot.Workspace = '3'
$state.Commit($now, 'C:\Apps\firefox.exe')
$state.Dismiss($now)
$state.Foreground(202, $now)
$resolved = $state.Resolve($snapshot, 202, $now.AddMilliseconds(400))
Assert-True ($resolved.Handle -eq 202 -and $state.Workspace -eq '6') 'Existing window did not target the invoking workspace.'
Assert-True ($null -eq $state.Resolve($snapshot, 303, $now)) 'A background window was selected for movement.'

# Unmanaged/new windows wait for GlazeWM to assign an ID; no unrelated window is moved.
$state.Foreground(404, $now)
Assert-True ($null -eq $state.Resolve($snapshot, 404, $now)) 'Unmanaged window was accepted.'
$new = New-Object Dotfiles.FlowWorkspace.ManagedWindow
$new.Handle = 404; $new.Id = [guid]::NewGuid().ToString(); $new.Workspace = '1'; $new.Process = 'cmd'
$snapshot.Windows.Add(404, $new)
Assert-True ($state.Resolve($snapshot, 404, $now).Id -eq $new.Id) 'Newly managed window was not resolved.'

# Temporary restoration of the old window is not mistaken for the launched app.
$state.Begin((New-Snapshot), 101)
$state.Commit($now, 'C:\Apps\firefox.exe')
$state.Dismiss($now)
$state.Foreground(101, $now)
Assert-True ($null -eq $state.Resolve($snapshot, 101, $now.AddMilliseconds(500))) 'Temporary focus restoration was treated as a launch.'
$state.Begin((New-Snapshot), 101)
$state.Commit($now, 'WindowsTerminal.exe')
$state.Dismiss($now)
$state.Foreground(101, $now)
Assert-True ($null -eq $state.Resolve($snapshot, 101, $now.AddMilliseconds(100))) 'Original window was accepted before restoration settled.'
Assert-True ($state.Resolve($snapshot, 101, $now.AddMilliseconds(400)).Handle -eq 101) 'Explicitly selected previous app was not brought to an empty workspace.'

# Restoring the desktop while a positively identified reused app settles must
# not discard that app, or origin preservation would undo reuse across spaces.
$reuse = New-Snapshot -Original 0
$state.Begin($reuse, 9999)
$state.Commit($now, 'C:\Apps\firefox.exe')
$state.Foreground(202, $now)
$state.Dismiss($now)
$state.Foreground(9999, $now.AddMilliseconds(100))
Assert-True ($state.Resolve($reuse, 9999, $now.AddMilliseconds(400)).Handle -eq 202) 'Origin restoration discarded the identified reused target during settling.'

# Plugin/help labels mentioning a process are not executable identity.
$negative = New-Snapshot -Original 0
$state.Begin($negative, 9999)
$state.Commit($now, 'DotfilesFixture.exe - Explorer plugin help for WindowsTerminal')
$state.Dismiss($now)
foreach ($restored in @(505, 101)) {
    $state.Foreground($restored, $now)
    Assert-True ($null -eq $state.Resolve($negative, $restored, $now.AddMilliseconds(500))) 'Plugin/help text was mistaken for a selected Explorer or terminal executable.'
}

# Exact regression: on an empty origin the native original HWND can be the
# desktop, so protecting only that one HWND must not allow a restored terminal.
$empty = New-Snapshot -Original 0
$state.Begin($empty, 999)
$state.Commit($now, '')
$state.Dismiss($now)
$state.Foreground(101, $now)
Assert-True ($null -eq $state.Resolve($empty, 101, $now.AddMilliseconds(500))) 'An existing restoration window was mistaken for the launched app.'
$empty.Windows.Add(404, $new)
$state.Foreground(404, $now)
Assert-True ($state.Resolve($empty, 404, $now.AddMilliseconds(500)).Handle -eq 404) 'Missing UIA metadata disabled routing of a genuinely new window.'
$state.CancelRouting()
Assert-True ($state.Workspace -eq '6' -and -not $state.Committed) 'Escape-style cancellation discarded the origin before dismissal.'
Assert-True ($null -eq $state.Resolve($empty, 404, $now.AddMilliseconds(600))) 'Dismissal-only session still allowed routing.'

# Replay dispatcher ordering with an immutable pre-show snapshot, a duplicate
# foreground event, focus restoration elsewhere, and a new managed result.
$session = New-Object Dotfiles.FlowWorkspace.SessionState
$beforeShow = New-Snapshot -Original 0
$session.ObserveSnapshot($beforeShow)
$session.OpenIntent($beforeShow, 999)
$session.FlowShown(7001, 2500, 200)
$session.Commit($now, '')
$session.FlowShown(7001, 500, 200)
Assert-True ($session.Placement.Workspace -eq '6' -and $session.Placement.Committed) 'Duplicate Flow foreground event reset the launch session.'
$drift = New-Snapshot -Workspace '1' -Original 101
$session.ObserveSnapshot($drift)
$session.Foreground(101, $now)
$session.FlowHidden($now)
Assert-True ($session.Placement.Workspace -eq '6' -and $session.Placement.Hidden) 'The post-close focus snapshot overwrote the invoking empty workspace.'
Assert-True ([object]::ReferenceEquals($session.Current, $drift)) 'Snapshot event was replaced by a different global snapshot.'
Assert-True ($null -eq $session.Placement.Resolve($drift, 101, $now.AddMilliseconds(500))) 'Dispatcher replay moved the restored populated-workspace window.'
$drift.Windows.Add(404, $new)
$session.ObserveSnapshot($drift)
$session.Foreground(404, $now)
Assert-True ($session.Placement.Resolve($drift, 404, $now.AddMilliseconds(500)).Handle -eq 404) 'Dispatcher replay lost the new result after Flow hid.'
# Windows may cover a new result with an old restoration window before hide.
$session.Foreground(101, $now.AddMilliseconds(510))
Assert-True ($session.Placement.Resolve($drift, 101, $now.AddMilliseconds(520)).Handle -eq 404) 'An old restoration event discarded the already observed new result.'

# GlazeWM's focused managed snapshot is authoritative even if Windows coalesces
# the native foreground notification for the newly created window.
$snapshotOnly = New-Object Dotfiles.FlowWorkspace.SessionState
$snapshotOnly.OpenIntent((New-Snapshot -Original 0), 9999)
$snapshotOnly.FlowShown(7001, 2500, 200)
$snapshotOnly.Commit($now, '')
$snapshotOnly.FlowHidden($now)
$managed = New-Snapshot -Original 404
$managed.Windows.Add(404, $new)
$snapshotOnly.ObserveSnapshot($managed)
Assert-True ($snapshotOnly.Placement.Resolve($managed, 404, $now.AddMilliseconds(500)).Handle -eq 404) 'Focused managed snapshot did not recover a coalesced native foreground event.'

$session = New-Object Dotfiles.FlowWorkspace.SessionState
$session.OpenIntent((New-Snapshot -Original 0), 999)
$session.FlowShown(7001, 2500, 200)
$session.Commit($now, '')
$session.DismissOnly()
$session.FlowHidden($now)
Assert-True ($session.Placement.Workspace -eq '6' -and -not $session.Placement.Committed) 'Escape/toggle-close did not retain only origin preservation.'
$session.Cancel()
Assert-True ($null -eq $session.Placement.Workspace) 'Deliberate navigation did not release origin preservation.'

foreach ($scenario in @('escape', 'outside-click', 'workspace-switch', 'disconnect')) {
    $state.Begin((New-Snapshot), 101); $state.Commit($now, 'C:\Apps\firefox.exe'); $state.Cancel(); $state.Foreground(202, $now)
    Assert-True ($null -eq $state.Resolve($snapshot, 202, $now)) "Cancelled $scenario session moved a window."
}
$state.Begin((New-Snapshot), 101); $state.Commit($now, 'C:\Apps\firefox.exe'); $state.Foreground(202, $now)
Assert-True ($null -eq $state.Resolve($snapshot, 202, $now.AddSeconds(10))) 'Expired launch moved a later window.'
Assert-True ($null -eq $state.Workspace) 'Expired origin was retained.'
$state.Begin((New-Snapshot), 101); $state.Foreground(202, $now)
Assert-True ($null -eq $state.Resolve($snapshot, 202, $now)) 'Uncommitted search moved a window.'
$state.Begin($null, 101); $state.Commit($now, 'C:\Apps\firefox.exe'); $state.Foreground(202, $now)
Assert-True ($null -eq $state.Resolve($snapshot, 202, $now)) 'Missing origin was guessed.'

# Real IPC format includes split containers and a focused empty workspace.
$json = @'
{"success":true,"data":{"workspaces":[{"id":"00000000-0000-0000-0000-000000000006","name":"6","hasFocus":true,"isDisplayed":true,"x":2300,"y":0,"width":1920,"height":1080,"children":[]},{"id":"00000000-0000-0000-0000-000000000003","name":"3","hasFocus":false,"isDisplayed":false,"x":0,"y":0,"width":2300,"height":1440,"children":[{"type":"split","children":[{"type":"window","id":"00000000-0000-0000-0000-000000000001","handle":202,"processName":"firefox","hasFocus":false}]}]}]}}
'@
$parsed = [Dotfiles.FlowWorkspace.Snapshot]::Parse($json)
Assert-True ($parsed.Workspace -eq '6' -and $parsed.Windows[202L].Workspace -eq '3') 'Nested windows or focused empty workspace were parsed incorrectly.'
Assert-True ($parsed.AtPoint(2500, 200) -eq '6') 'Visible Flow monitor did not identify the displayed empty workspace.'
$rejected = $false
try { $null = [Dotfiles.FlowWorkspace.Snapshot]::Parse('{"success":false,"error":"fixture"}') } catch { $rejected = $true }
Assert-True $rejected 'Failed IPC response was accepted.'

$testRoot = Join-Path $env:TEMP ('dotfiles-flow-test-' + [guid]::NewGuid())
$profileBefore = $env:USERPROFILE
$children = @()
$preserveTestRoot = $false
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    # Installation keeps the helper with or without Zebar and backs up earlier source.
    $env:USERPROFILE = Join-Path $testRoot 'profile'
    $installed = Join-Path $env:USERPROFILE '.glzr\glazewm'
    & (Join-Path $windows 'Apply.ps1') -MonitorCount 2 -NoRestart -WithoutZebar -WallpaperMode None
    $config = Get-Content -LiteralPath (Join-Path $installed 'config.yaml') -Raw
    Assert-True (-not $config.Contains("- 'shell-exec zebar'")) 'WithoutZebar still starts Zebar.'
    Assert-True ($config.Contains('Watch-FlowWorkspace.ps1') -and $config.Contains('-Restart') -and $config.Contains('-Stop')) 'Helper lifecycle commands were lost.'
    Assert-True ($config.Contains("name: '6', bind_to_monitor: 1")) 'Monitor assignments changed.'
    foreach ($name in @('Watch-FlowWorkspace.ps1', 'FlowWorkspace.cs')) {
        Assert-True ([IO.File]::ReadAllText((Join-Path $installed $name)) -eq [IO.File]::ReadAllText((Join-Path $windows $name))) "Helper installation differs: $name"
    }
    [IO.File]::WriteAllText((Join-Path $installed 'FlowWorkspace.cs'), '// previous version')
    & (Join-Path $windows 'Apply.ps1') -MonitorCount 1 -NoRestart -WallpaperMode None
    $config = Get-Content -LiteralPath (Join-Path $installed 'config.yaml') -Raw
    Assert-True ((Get-Content -LiteralPath (Join-Path $env:USERPROFILE '.glzr\glazewm\desktop-startup.json') -Raw | ConvertFrom-Json).ZebarEnabled) 'Normal installation omitted Zebar.'
    Assert-True (-not $config.Contains('bind_to_monitor: 1')) 'Single-monitor installation retained a second monitor.'
    $backups = @(Get-ChildItem (Join-Path $env:USERPROFILE '.glzr\backups') -Directory | Sort-Object Name)
    Assert-True ([IO.File]::ReadAllText((Join-Path $backups[-1].FullName 'FlowWorkspace.cs')) -eq '// previous version') 'Previous helper source was not backed up.'
    # Restore the last real installation backup without touching running desktop apps.
    [IO.File]::WriteAllText((Join-Path $installed 'wallpaper-original.json'), 'temporary-new-state')
    & (Join-Path $windows 'Restore-DesktopSettings.ps1') -BackupPath $backups[-1].FullName -NoRestart
    Assert-True ([IO.File]::ReadAllText((Join-Path $installed 'FlowWorkspace.cs')) -eq '// previous version') 'Restore lost the previous helper source.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installed 'wallpaper-original.json'))) 'Restore retained a previously absent wallpaper state file.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $installed 'desktop-startup.json') -Raw | ConvertFrom-Json).ZebarEnabled -eq $false) 'Restore lost the previous companion configuration.'
    $env:USERPROFILE = $profileBefore

    if ($Live) {
        $response = [Dotfiles.FlowWorkspace.Ipc]::Request('query workspaces')
        $liveSnapshot = [Dotfiles.FlowWorkspace.Snapshot]::Parse($response)
        Assert-True (-not [string]::IsNullOrWhiteSpace($liveSnapshot.Workspace)) 'No focused workspace in live IPC.'
        $session = (Get-Process -Id $PID).SessionId
        $eventName = "Local\DotfilesFlowWorkspaceStop-$session"
        function Test-HelperEvent {
            try { $handle = [Threading.EventWaitHandle]::OpenExisting($eventName); $handle.Dispose(); return $true }
            catch [Threading.WaitHandleCannotBeOpenedException] { return $false }
        }
        if (Test-HelperEvent) { throw 'Stop the existing workspace helper before running lifecycle tests.' }
        $exe = Join-Path $PSHOME 'powershell.exe'
        $entry = Join-Path $windows 'Watch-FlowWorkspace.ps1'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -LogPath "{1}"' -f $entry, (Join-Path $testRoot 'helper.log')
        $first = Start-Process $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $children += $first
        for ($i = 0; $i -lt 100 -and -not (Test-HelperEvent) -and -not $first.HasExited; $i++) { Start-Sleep -Milliseconds 100 }
        Assert-True ((Test-HelperEvent) -and -not $first.HasExited) 'Helper did not start.'
        $duplicate = Start-Process $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $children += $duplicate
        Assert-True ($duplicate.WaitForExit(10000) -and $duplicate.ExitCode -eq 0 -and -not $first.HasExited) 'Duplicate helper was not suppressed.'
        $replacement = Start-Process $exe -ArgumentList ($arguments + ' -Restart') -WindowStyle Hidden -PassThru
        $children += $replacement
        Assert-True ($first.WaitForExit(10000)) 'Reload did not stop the old helper.'
        for ($i = 0; $i -lt 100 -and -not (Test-HelperEvent) -and -not $replacement.HasExited; $i++) { Start-Sleep -Milliseconds 100 }
        Assert-True ((Test-HelperEvent) -and -not $replacement.HasExited) 'Reload did not start a replacement helper.'
        & $entry -Stop
        Assert-True ($replacement.WaitForExit(10000) -and $replacement.ExitCode -eq 0) 'Helper did not shut down cleanly.'
        Assert-True (-not (Test-HelperEvent)) 'Helper stop event leaked.'
        Write-Host 'PASS: live IPC, duplicate prevention, reload, and shutdown.'
    }
    if ($LaunchApps) {
        # Explicit opt-in: only a uniquely named temporary test app is launched.
        $before = [Dotfiles.FlowWorkspace.Ipc]::Request('query workspaces') | ConvertFrom-Json
        $originalWorkspace = @($before.data.workspaces | Where-Object hasFocus)[0].name
        $originalSnapshot = [Dotfiles.FlowWorkspace.Snapshot]::Parse(($before | ConvertTo-Json -Depth 50))
        $originalWindow = $originalSnapshot.FocusedHandle
        $originalId = if ($originalWindow -and $originalSnapshot.Windows.ContainsKey($originalWindow)) { $originalSnapshot.Windows[$originalWindow].Id } else { '' }
        $baseline = @{}
        foreach ($window in $originalSnapshot.Windows.Values) { $baseline[$window.Id] = $window.Workspace }
        [IO.File]::WriteAllText((Join-Path $testRoot 'before-workspaces.json'), ($before | ConvertTo-Json -Depth 50))
        $origins = @($before.data.workspaces | Where-Object { $_.children.Count -eq 0 } | Group-Object parentId | ForEach-Object { $_.Group[0].name })
        if ($origins.Count -eq 0) { throw 'App-launch tests need an empty workspace.' }
        $fixtureName = 'DotfilesFlowFixture' + [guid]::NewGuid().ToString('N')
        $fixtureExe = Join-Path $testRoot ($fixtureName + '.exe')
        $delayPath = [IO.Path]::ChangeExtension($fixtureExe, '.delay')
        Add-Type -Path (Join-Path $PSScriptRoot 'FlowWorkspaceFixture.cs') -OutputAssembly $fixtureExe -OutputType WindowsApplication -ReferencedAssemblies @('System.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll')
        Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
namespace Dotfiles.FlowWorkspace.Tests {
    public static class Input {
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
        [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
        [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("user32.dll")] static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern uint GetLongPathName(string path, StringBuilder expanded, uint count);
        public static void UsePhysicalCoordinates() { SetThreadDpiAwarenessContext(new IntPtr(-4)); }
        public static int ModifierMask() {
            return ((GetAsyncKeyState(0x11) & 0x8000) != 0 ? 1 : 0) |
                ((GetAsyncKeyState(0x10) & 0x8000) != 0 ? 2 : 0) |
                ((GetAsyncKeyState(0x12) & 0x8000) != 0 ? 4 : 0) |
                (((GetAsyncKeyState(0x5b) | GetAsyncKeyState(0x5c)) & 0x8000) != 0 ? 8 : 0);
        }
        public static string CanonicalPath(string path) {
            var expanded = new StringBuilder(32768);
            uint count = GetLongPathName(path, expanded, (uint)expanded.Capacity);
            if (count == 0 || count >= expanded.Capacity) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "Could not normalize fixture path.");
            return System.IO.Path.GetFullPath(expanded.ToString());
        }
        public static bool IsFlow() {
            IntPtr window = GetForegroundWindow();
            var title = new StringBuilder(256);
            GetWindowText(window, title, title.Capacity);
            if (title.ToString() != "Flow.Launcher") return false;
            uint process;
            GetWindowThreadProcessId(window, out process);
            try { using (var app = Process.GetProcessById((int)process)) return app.ProcessName == "Flow.Launcher"; }
            catch (ArgumentException) { return false; }
            catch (InvalidOperationException) { return false; }
        }
        public static void Click(int x, int y) {
            SetThreadDpiAwarenessContext(new IntPtr(-4));
            SetCursorPos(x, y);
            mouse_event(2, 0, 0, 0, UIntPtr.Zero);
            System.Threading.Thread.Sleep(50);
            mouse_event(4, 0, 0, 0, UIntPtr.Zero);
        }
    }
}
'@
        [Dotfiles.FlowWorkspace.Tests.Input]::UsePhysicalCoordinates()
        $fixtureCanonical = [Dotfiles.FlowWorkspace.Tests.Input]::CanonicalPath($fixtureExe)
        $cursorBefore = [Windows.Forms.Cursor]::Position
        $shell = New-Object -ComObject WScript.Shell
        $launchFailure = $null
        $cleanupErrors = @()
        function Get-CurrentSnapshot {
            return [Dotfiles.FlowWorkspace.Snapshot]::Parse([Dotfiles.FlowWorkspace.Ipc]::Request('query workspaces'))
        }
        function Assert-PreservedWindows {
            param($Current)
            $byId = @{}
            foreach ($window in $Current.Windows.Values) { $byId[$window.Id] = $window.Workspace }
            foreach ($id in $baseline.Keys) {
                Assert-True ($byId.ContainsKey($id)) "Pre-existing window disappeared during the test: $id"
                Assert-True ($byId[$id] -eq $baseline[$id]) "Pre-existing window $id moved from workspace $($baseline[$id]) to $($byId[$id])."
            }
        }
        function Send-FlowKeys {
            param([string]$Keys)
            Assert-True ([Dotfiles.FlowWorkspace.Tests.Input]::IsFlow()) 'Flow lost focus; refusing to send keys to another app.'
            $shell.SendKeys($Keys)
        }
        function Open-Flow {
            if ([Dotfiles.FlowWorkspace.Tests.Input]::IsFlow()) { Send-FlowKeys '{ESC}'; Start-Sleep -Milliseconds 250 }
            $shell.SendKeys('% ')
            for ($attempt = 0; $attempt -lt 50 -and -not [Dotfiles.FlowWorkspace.Tests.Input]::IsFlow(); $attempt++) { Start-Sleep -Milliseconds 100 }
            Assert-True ([Dotfiles.FlowWorkspace.Tests.Input]::IsFlow()) 'Flow did not take keyboard focus.'
        }
        function Test-TransientFixtureUiaFailure {
            param([Exception]$Exception)
            for ($currentException = $Exception; $null -ne $currentException; $currentException = $currentException.InnerException) {
                if ($currentException -is [Windows.Automation.ElementNotAvailableException]) { return $true }
                # Native UIA element disappearance / disconnected provider, when
                # surfaced as COMException instead of the managed UIA exception.
                if ($currentException -is [Runtime.InteropServices.COMException] -and
                    $currentException.HResult -in @(-2147220991, -2147417848)) { return $true }
            }
            return $false
        }
        function Find-FixtureResult {
            try {
            $root = [Windows.Automation.AutomationElement]::FromHandle([Dotfiles.FlowWorkspace.Tests.Input]::GetForegroundWindow())
            $items = $root.FindAll([Windows.Automation.TreeScope]::Descendants,
                (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ListItem)))
            foreach ($item in $items) {
                $titleElement = $item.FindFirst([Windows.Automation.TreeScope]::Descendants,
                    (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty, 'Title')))
                if ($null -eq $titleElement) { continue }
                $title = $titleElement.Current.Name
                if (-not [string]::Equals($title, $fixtureName, [StringComparison]::OrdinalIgnoreCase) -and
                    -not [string]::Equals($title, ($fixtureName + '.exe'), [StringComparison]::OrdinalIgnoreCase)) { continue }
                $text = $item.Current.Name
                foreach ($part in $item.FindAll([Windows.Automation.TreeScope]::Descendants,
                    (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Text)))) { $text += ' ' + $part.Current.Name }
                if ($text.IndexOf(($fixtureName + '.exe'), [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
                    $text -match '(?i)https?://|google|bing|duckduckgo|search (the )?web' -or $item.Current.IsOffscreen) { continue }
                $pattern = $null
                if (-not $item.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) { continue }
                $selection = [Windows.Automation.SelectionItemPattern]$pattern
                if (-not $selection.Current.IsSelected) { $selection.Select() }
                if (-not $selection.Current.IsSelected) { return $null }
                $bounds = $item.Current.BoundingRectangle
                if ($bounds -isnot [Windows.Rect]) {
                    $kind = if ($null -eq $bounds) { '<null>' } else { $bounds.GetType().FullName }
                    throw "Fixture result returned unexpected bounds type: $kind"
                }
                # Explicit scalar fields prevent AutomationElement/Rect pipeline
                # adaptation from changing the object later consumed by Click.
                return ,([pscustomobject]@{
                    Element = $item
                    ElementType = $item.GetType().FullName
                    Title = $title
                    Text = $text
                    Left = [double]$bounds.X
                    Top = [double]$bounds.Y
                    Width = [double]$bounds.Width
                    Height = [double]$bounds.Height
                })
            }
            return $null
            } catch {
                if (Test-TransientFixtureUiaFailure $_.Exception) { return $null }
                throw
            }
        }
        function Wait-FixtureResult {
            param([int]$Attempts = 100)
            for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
                Assert-True ([Dotfiles.FlowWorkspace.Tests.Input]::IsFlow()) 'Flow lost focus while waiting for the fixture result.'
                $found = @(Find-FixtureResult | Where-Object { $null -ne $_ })
                if ($found.Count -gt 1) { throw "Fixture result lookup emitted $($found.Count) objects instead of one wrapper." }
                if ($found.Count) { return ,$found[0] }
                Start-Sleep -Milliseconds 100
            }
            throw 'Flow did not expose a stable exact fixture executable; refusing to launch a web-search result.'
        }
        function Wait-FixtureModifiersReleased {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            do {
                $mask = [Dotfiles.FlowWorkspace.Tests.Input]::ModifierMask()
                if ($mask -eq 0) { return $mask }
                Start-Sleep -Milliseconds 20
            } while ($watch.ElapsedMilliseconds -lt 2000)
            return $mask
        }
        function Invoke-FixtureFromFlow {
            param([switch]$ClickResult)
            Open-Flow
            Send-FlowKeys '^a'
            $literal = New-Object Text.StringBuilder
            foreach ($character in $fixtureExe.ToCharArray()) {
                if ('+^%~(){}[]'.IndexOf($character) -ge 0) { $null = $literal.Append('{').Append($character).Append('}') }
                else { $null = $literal.Append($character) }
            }
            Send-FlowKeys $literal.ToString()
            $result = Wait-FixtureResult
            Start-Sleep -Milliseconds 300
            Assert-True ([Dotfiles.FlowWorkspace.Tests.Input]::IsFlow()) 'Flow lost focus before fixture launch.'
            # Query providers can replace/reselect rows during the metadata wait.
            # Re-find and select the exact executable immediately before either input.
            $result = Wait-FixtureResult -Attempts 30
            $modifierMask = Wait-FixtureModifiersReleased
            $selectionRecord = [pscustomobject]@{
                At = [datetime]::UtcNow.ToString('o')
                Input = $(if ($ClickResult) { 'click' } else { 'Enter' })
                Title = $result.Title
                Text = $result.Text
                ModifierMask = $modifierMask
            } | ConvertTo-Json -Compress
            [IO.File]::AppendAllText((Join-Path $testRoot 'selected-results.jsonl'), $selectionRecord + [Environment]::NewLine)
            Assert-True ($modifierMask -eq 0) "Modifier keys remained down before plain fixture activation: $modifierMask (Ctrl=1, Shift=2, Alt=4, Win=8)."
            Assert-True ([Dotfiles.FlowWorkspace.Tests.Input]::ModifierMask() -eq 0) 'Modifier state changed before fixture activation; refusing modified Enter/click.'
            if ($ClickResult) {
                Assert-True ($result.Element -is [Windows.Automation.AutomationElement]) "Unexpected fixture element type: $($result.ElementType)"
                [Dotfiles.FlowWorkspace.Tests.Input]::Click([int]($result.Left + $result.Width / 2), [int]($result.Top + $result.Height / 2))
            } else { Send-FlowKeys '{ENTER}' }
        }
        function Wait-FixtureOnWorkspace {
            param([string]$Origin, [switch]$AssertBeforeWindow)
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $preservedBeforeWindow = $false
            for ($attempt = 0; $attempt -lt 120; $attempt++) {
                $current = Get-CurrentSnapshot
                Assert-PreservedWindows $current
                $fixtures = @($current.Windows.Values | Where-Object { $_.Process -eq $fixtureName })
                $focused = @($fixtures | Where-Object { $_.Workspace -eq $Origin -and $_.Handle -eq $current.FocusedHandle })
                if ($focused.Count -and $current.Workspace -eq $Origin) {
                    if ($AssertBeforeWindow) { Assert-True $preservedBeforeWindow 'Delayed-launch test never observed origin before the fixture appeared.' }
                    return $focused[0]
                }
                if ($AssertBeforeWindow -and $watch.ElapsedMilliseconds -gt 400 -and $fixtures.Count -eq 0 -and -not [Dotfiles.FlowWorkspace.Tests.Input]::IsFlow()) {
                    Assert-True ($current.Workspace -eq $Origin) "Flow closed and focus jumped to $($current.Workspace) before the fixture appeared on $Origin."
                    $preservedBeforeWindow = $true
                }
                Start-Sleep -Milliseconds 100
            }
            throw "Flow's fixture did not arrive focused on workspace $Origin."
        }
        function Close-Fixture {
            foreach ($process in @(Get-Process -Name $fixtureName -ErrorAction SilentlyContinue)) {
                if ($process.HasExited) { continue }
                $actualPath = [Dotfiles.FlowWorkspace.Tests.Input]::CanonicalPath($process.Path)
                if (-not [string]::Equals($actualPath, $fixtureCanonical, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture process path did not match; refusing to close it.' }
                $null = $process.CloseMainWindow()
                if (-not $process.WaitForExit(3000)) { Stop-Process -Id $process.Id -Force }
            }
        }
        function Wait-Workspace {
            param([string]$Name)
            for ($attempt = 0; $attempt -lt 30; $attempt++) {
                $current = Get-CurrentSnapshot
                Assert-PreservedWindows $current
                if ($current.Workspace -eq $Name) { return }
                Start-Sleep -Milliseconds 100
            }
            throw "Workspace $Name did not retain focus."
        }
        try {
            foreach ($origin in $origins) {
                Close-Fixture
                [IO.File]::WriteAllText($delayPath, '2500')
                $null = [Dotfiles.FlowWorkspace.Ipc]::Request("command focus --workspace $origin")
                Start-Sleep -Milliseconds 500
                Invoke-FixtureFromFlow
                $fixtureWindow = Wait-FixtureOnWorkspace $origin -AssertBeforeWindow
                # Invoke again from an occupied workspace, then from an empty one
                # after moving the existing app away. Both new and reused hosts work.
                [IO.File]::WriteAllText($delayPath, '0')
                Invoke-FixtureFromFlow -ClickResult
                $reused = Wait-FixtureOnWorkspace $origin
                Assert-True ($reused.Id -eq $fixtureWindow.Id) 'Single-instance fixture unexpectedly created a second window.'
                $away = @($before.data.workspaces | Where-Object { $_.name -ne $origin })[0].name
                $null = [Dotfiles.FlowWorkspace.Ipc]::Request("command --id $($fixtureWindow.Id) move --workspace $away")
                $null = [Dotfiles.FlowWorkspace.Ipc]::Request("command focus --workspace $origin")
                Start-Sleep -Milliseconds 500
                Invoke-FixtureFromFlow
                $reused = Wait-FixtureOnWorkspace $away
                Assert-True ($reused.Id -eq $fixtureWindow.Id) 'Existing fixture was not focused on its original workspace.'
                Close-Fixture
                $null = [Dotfiles.FlowWorkspace.Ipc]::Request("command focus --workspace $origin")
                Start-Sleep -Milliseconds 500
                Open-Flow
                Send-FlowKeys '{ESC}'
                Start-Sleep -Milliseconds 500
                Wait-Workspace $origin
                Open-Flow
                Send-FlowKeys ('%' + $away)
                Start-Sleep -Milliseconds 500
                Wait-Workspace $away
            }
            Assert-PreservedWindows (Get-CurrentSnapshot)
            Write-Host 'PASS: exact Flow executable selection, delayed empty-workspace launches on each monitor, occupied origins, click/Enter launches, reused fixture, Escape, and deliberate navigation.'
        } catch {
            $launchFailure = $_
            $preserveTestRoot = $true
        } finally {
            try { if ([Dotfiles.FlowWorkspace.Tests.Input]::IsFlow()) { Send-FlowKeys '{ESC}' } } catch { $cleanupErrors += $_ }
            try { Close-Fixture } catch { $cleanupErrors += $_ }
            try {
                $null = [Dotfiles.FlowWorkspace.Ipc]::Request("command focus --workspace $originalWorkspace")
                $current = Get-CurrentSnapshot
                if ($originalId -and @($current.Windows.Values | Where-Object { $_.Id -eq $originalId }).Count) {
                    $null = [Dotfiles.FlowWorkspace.Ipc]::Request("command focus --container-id $originalId")
                }
            } catch { $cleanupErrors += $_ }
            [Windows.Forms.Cursor]::Position = $cursorBefore
        }
        foreach ($cleanupError in $cleanupErrors) { Write-Warning ("Fixture cleanup: " + $cleanupError.Exception.Message) }
        if ($launchFailure) { throw $launchFailure }
        if ($cleanupErrors.Count) { throw 'App-launch checks passed, but fixture cleanup was incomplete.' }
    }
    Write-Host 'PASS: workspace capture, existing/new windows, focus restoration, cancellation, expiry, IPC parsing, installation, and backups.'
} finally {
    $env:USERPROFILE = $profileBefore
    foreach ($child in $children) { if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue } }
    if ($preserveTestRoot) { Write-Warning "Retained failure diagnostics: $testRoot" }
    else { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
