# Windows dotfiles

Keep this repository at `%USERPROFILE%\dotfiles` on the Windows filesystem,
for example `C:\Users\MaxNarongchai\dotfiles`.

It contains the Windows host setup for GlazeWM and Zebar, plus a Windows entry
point for bootstrapping the separate Linux dotfiles inside WSL. The Linux
repository remains at `~/dotfiles` inside its distribution.

```text
dotfiles/
  setup.ps1             Windows packages, monitor configuration, optional WSL setup
  setup-wsl.ps1         Bootstrap the existing Linux dotfiles inside WSL
  windows/
    Apply.ps1           Back up and install the tracked Windows configuration
    Enable-Startup.ps1  Enable GlazeWM at sign-in for the current Windows user
    Start-GlazeWM.cmd   Startup terminal entry point
    Start-Desktop.ps1   Desktop startup progress, readiness checks and logging
    config.yaml         GlazeWM configuration
    settings.json       Zebar startup configuration
    multimonitor/       Local copy of the Zebar starter widget pack
```

## Windows setup

Use a normal, non-admin PowerShell window. Scoop is the only bootstrap prerequisite.
If needed, install it using its official instructions:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression
```

Then run:

```powershell
Set-Location "$env:USERPROFILE\dotfiles"
.\setup.ps1
```

This disables PowerToys FancyZones (with a settings backup), installs missing
GlazeWM/Zebar packages through Scoop, copies the tracked
configuration into `%USERPROFILE%\.glzr`, and gracefully restarts the window
manager and bar. Existing configuration and the local bar are backed up under
`%USERPROFILE%\.glzr\backups\multimonitor-<timestamp>` on every run. Future edits
belong in this repository; rerunning setup copies them into place. No symlinks
or administrator privileges are required for the Windows setup.

Setup registers a `GlazeWM` scheduled task for your Windows account. It runs
10 seconds after you sign in, with normal user privileges and no stored password.
The task runs on battery power and does not wait for the computer to become idle.
This avoids the long delay observed with the Windows Startup folder. The task
explicitly uses normal interactive priority (6), rather than Task Scheduler's
background-priority default. GlazeWM starts first. Companion dispatch is scheduled
at offsets of five seconds for its workspace helper and Everything, eight seconds
for Flow, twelve seconds for Zebar, and fifteen seconds for wallpaper verification
or overlay startup. Offsets are best-effort under system load; they do not mean
that every app finishes initialising within fifteen seconds. Existing processes
in the current session are reused. Scheduled and manual GlazeWM launches share
one orchestrator and session mutex; shutdown cancels pending launches.

To enable or repair startup separately without restarting running desktop apps:

```powershell
.\windows\Enable-Startup.ps1
```

The installer recognizes existing `Flow Launcher (dotfiles).lnk` and
`Everything (dotfiles).lnk` shortcuts as launcher opt-in. It saves that opt-in and
the Scoop root in `%USERPROFILE%\.glzr\glazewm\launcher-startup.json`, then retires
the dotfiles launcher shortcuts and old `GlazeWM.lnk` after task registration
succeeds. Backups, including a `files.json` manifest for the restore command, live
under `%USERPROFILE%\.glzr\backups\startup-task-<timestamp>`. Unrelated shortcuts
are retained. If registration is denied, existing shortcuts and opt-in remain
intact. A company restriction on task registration requires IT help.

Startup logging is always enabled at `%USERPROFILE%\.glzr\glazewm\startup.log`.
Startup uses a console-free Windows launcher compiled during installation with the existing .NET Framework compiler. Timestamped stages, readiness
results, and errors remain in the log. Readiness checks share a forty-five-second
deadline. Success and failure both exit automatically; failures return a nonzero
code to Task Scheduler without a dialog or keypress. Application processes remain
running so late initialization can finish.
To disable startup, open Task Scheduler and disable the `GlazeWM` task.
Rerunning setup or the startup script enables it again.

The monitor count is detected automatically. With two screens, workspaces 1-4
belong to monitor 0 and 5-9 to monitor 1. With three screens the groups are 1-3,
4-6, and 7-9. Monitor 0 is the leftmost display. The tracked `config.yaml` previews
the two-monitor setup; the installer adjusts the workspace section for the actual
number of monitors.

- `Alt+Arrow keys`: focus a window in that direction; `Alt+H/J/K/L` stay available for Neovim.
- `Ctrl+Alt+Left/Right`: previous/next GlazeWM workspace on the focused monitor.
- `Ctrl+Alt+H/L`: focus monitor 0/1 directly.
- `Alt+1` through `Alt+9`: select a workspace.
- `Alt+Shift+1` through `Alt+Shift+9`: move a window there and follow it.
- `Alt+Q` or `Alt+Shift+Q`: close the focused window normally, allowing save prompts.
- `Alt+F4`: the standard Windows close-window shortcut also works.
- `Alt+Space`: open Flow Launcher when configured, otherwise PowerToys Run.
- `Alt+C`: cycle focus between tiling, floating, and fullscreen windows.

Zebar docks at the top of every monitor and shows that monitor's workspaces.
Window and screen-edge gaps are 6px, scaled with each monitor's DPI. Zebar reserves
its own space above the manual top gap. Cursor jumping between monitors is enabled.

Use one Windows virtual desktop while using GlazeWM workspaces. `Ctrl+Win+Left/Right`
continues to switch native Windows desktops and can trigger the upstream layout
issue: https://github.com/glzr-io/glazewm/issues/432

To write settings without restarting apps:

```powershell
.\setup.ps1 -NoRestart
```

Restart GlazeWM afterward to activate every bound workspace. Reloading the config
alone does not create all of those workspaces.

For changes limited to gaps, keybindings, or window rules, press `Alt+Shift+R`
after installing the config to reload GlazeWM without restarting it.

## Chocolatier / Kimbie appearance

The bar uses a fixed dark chocolate background, cream text, amber active
workspaces, and muted green/teal status icons, inspired by
[Chocolatier](https://github.com/qaptoR-nvim/chocolatier.nvim) and
[Kimbie Dark+](https://marketplace.visualstudio.com/items?itemName=dnamsons.kimbie-dark-plus).
GlazeWM uses matching amber focused-window borders and brown inactive borders.

Zebar uses **JetBrains Mono Nerd Font** at 12px, including workspace labels and
text buttons. It is already installed on this PC as `JetBrainsMono NF`. On another
PC, install the font in Windows; a font installed only inside WSL is not available
to Zebar. Status icons use bundled Lucide SVGs at 16px with a consistent stroke
and alignment, independently of the text font. They are shared by all three bar
variants and do not download an icon font. Their license is bundled at
`windows/multimonitor/resources/lucide-LICENSE`.

To use **Adobe Utopia**, install it in Windows, then change these properties in
the `:root` block of `windows/multimonitor/styles.css`:

```css
--font-family: var(--utopia-font-family);
--text-size: 16px;
```

The Utopia stack includes `Utopia`, `Utopia Std`, and `Adobe Utopia`; adjust the
family name to match your installed font if needed. The palette also lives in
that `:root` block; matching window borders are in `windows/config.yaml`.

Apply appearance changes from a Windows PowerShell window with:

```powershell
.\windows\Apply.ps1
```

This backs up the live configuration, copies the tracked files, and restarts
GlazeWM and Zebar. Application windows stay open. A GlazeWM config reload alone
does not reload Zebar's CSS.

## Photo background

Setup preserves the Coniston photo without automatically starting Zebar wallpaper
widgets. `-WallpaperMode Auto` first uses Windows' `IDesktopWallpaper` API with a
centred fill on every monitor. It verifies the result and falls back to one
WinForms/GDI+ image-overlay process if the image cannot be applied. Managed
wallpaper settings are not edited. An existing slideshow is preserved using the
overlay instead of replacing it.

```powershell
.\windows\Apply.ps1 -WallpaperMode Auto
```

`Native` requires the Windows wallpaper API to succeed; `Overlay` forces the
native image renderer; `None` disables the custom background and restores the
saved original wallpaper when switching from native mode. Subsequent runs retain
an explicitly chosen mode when `-WallpaperMode` is omitted. `-WithoutZebar` only
disables the bar; combine it with `-WallpaperMode None` for a minimal baseline.

The image is copied from `windows/multimonitor/resources/coniston.jpg` to
`%USERPROFILE%\.glzr\glazewm\wallpaper.jpg`, independently of Zebar. Replace the
source image and rerun Apply to change it. Original per-monitor wallpaper paths,
position and background colour are backed up before a native change. In Auto
mode, sign-in verifies the effective wallpaper and uses an overlay if Windows
has replaced it; it does not repeatedly reapply native wallpaper.

The overlay uses one non-activating, click-through window per monitor and redraws
only when needed. It handles display changes and resume without browser views or
remote scripts. As with the earlier overlay, it can cover desktop icons and
`Win+D` may reveal the underlying Windows background. Stop it with:

```powershell
& "$env:USERPROFILE\.glzr\glazewm\Wallpaper.ps1" -Stop
```

Helpers are compiled into a source-hashed cache during configuration. Sign-in
loads those assemblies without compiling. A missing cache requires rerunning
Apply. `-NoRestart` installs the changes without restarting desktop apps; an
explicit native-wallpaper change still takes effect immediately. Restart GlazeWM
or sign out/in to activate staged startup and the new bar.

## Startup lag diagnostics

FancyZones is disabled by setup so GlazeWM handles window arrangement. Other
PowerToys utilities remain enabled unless you opt into the launcher replacement.
To apply that change independently, run `.\windows\Configure-Desktop.ps1`.
Settings backups are saved under `%USERPROFILE%\.glzr\backups\desktop-<timestamp>`.

Enable a ten-minute diagnostic capture on each sign-in:

```powershell
.\windows\Enable-Startup.ps1 -Diagnostics
```

The launcher starts the collector in its own
hidden process. Its ten-minute capture continues after startup exits;
collector output and errors go to a separate `*-collector.log` in the diagnostics
directory. Each capture writes
JSON lines under `%USERPROFILE%\.glzr\glazewm\diagnostics`, recording timestamps,
the first successful monitor query, query latency, total CPU and disk activity,
and CPU/memory/I/O counters for desktop processes and the top CPU/I/O consumers.
Memory samples use the native Windows API for available memory and commit usage/limit;
paging activity is collected separately from performance counters.
WebView2 processes are attributed using their host flag or process ancestry, so
Outlook, Teams and Windows Search are distinguished from Zebar. Samples include
base priorities and CPU normalised by logical processor count; the original raw
CPU counter can still exceed 100%. Command lines are never saved.

The default probe reuses a WebSocket connection and records connection time
separately from query latency, with a two-second cancellation limit. The optional
`-ProbeTransport Cli` retains the old subprocess measurement for comparison;
its elapsed time includes process startup, which Windows may delay beyond the
wait timeout. Only that probe process is killed on timeout. Missing performance
counters are recorded as errors without stopping readiness measurements. Counters
may take a little longer than the nominal capture duration to finish. Only one
collector runs per Windows session. It does not change window layouts.

For a short capture in the current session:

```powershell
.\windows\Measure-GlazeWMStartup.ps1 -DurationSeconds 30 -IntervalSeconds 5 -Label manual
```

A successful monitor query measures command responsiveness; it does not prove
that keyboard focus changes or window movement feel responsive. Compare those
interactions during the slow period as well as after stabilisation. Current-session
measurements cannot reproduce a cold sign-in by themselves.

If disabling FancyZones does not resolve the lag, compare another sign-in without
the Zebar bar:

```powershell
.\windows\Apply.ps1 -WithoutZebar
```

Run `.\windows\Apply.ps1` again to restore Zebar. These commands back up the live
configuration and gracefully restart GlazeWM. Keep the default ten-second logon
delay until the measurements show that changing it would help.

Disable future captures with `.\windows\Enable-Startup.ps1 -DisableDiagnostics`.
Ordinary setup disables automatic captures; use `setup.ps1 -StartupDiagnostics` to opt in. Old captures remain for comparison.

## Spotlight-style app and filename search

Install and configure Flow Launcher with portable Everything:

```powershell
.\setup.ps1 -WithLauncher
```

To also enable sign-in diagnostics, add `-StartupDiagnostics`. Complete a baseline
comparison before introducing the indexer's initial scan when investigating lag.
The optional launcher setup installs Scoop's `extras/flow-launcher` and standard
`extras/everything` 1.4 packages. It never installs the Everything service or runs
either app as administrator. [Folder indexing works without elevation](https://www.voidtools.com/en-au/support/everything/folder_indexing/).

Flow uses `Alt+Space` for apps, files and folders. Its Explorer plugin uses
Everything's index with an explicit executable path. GlazeWM ignores the launcher
window so it remains an overlay. PowerToys Run and Command Palette are disabled;
other utilities are retained. Both apps join GlazeWM's per-user scheduled task,
bypassing the Startup folder's potentially lengthy delay. Existing dotfiles
launcher shortcuts are migrated automatically by startup repair. To explicitly
enable scheduled startup for already-configured launchers, use
`.\windows\Enable-Startup.ps1 -WithLauncher`; ordinary repair preserves that opt-in.
Simply installing the packages does not opt them in.

Flow appears on the focused monitor. A hidden, unelevated workspace helper remembers
the workspace displaying Flow and preserves it when Flow cloaks or hides. This
keeps an empty workspace focused while the launched app is starting, even if
Windows briefly reactivates a window on another workspace. New windows are brought
to the invoking workspace; existing windows require matching result metadata.
Reusing a browser or terminal brings its whole window, including its tabs.
The helper recognizes Enter and clicks on accessible result rows; GlazeWM's
`Alt+1..9` workspace shortcuts retain precedence over Flow's result shortcuts.
Escape or toggling Flow closed cancels launch placement but restores the invoking
workspace once. Clicking away, Alt+Tab, or deliberate workspace navigation releases
the guard. A pending launch expires after ten seconds.

The helper starts with GlazeWM, restarts on config reload, and stops with GlazeWM.
It requires no extra runtime or administrator rights. Installation copies
`Watch-FlowWorkspace.ps1` and `FlowWorkspace.cs` beside the installed GlazeWM config,
including when Zebar is disabled. Its bounded diagnostic log is
`%USERPROFILE%\.glzr\glazewm\flow-workspace.log`; searches and result titles are
not logged. Result accessibility is optional for empty-workspace preservation and
new-window placement. It is used only to identify reused windows and result clicks;
unavailable metadata cannot block the handoff worker. Older windows reactivated
by Windows stay on their original workspaces.

To update placement alone in an existing installation, run
`.\windows\Enable-FlowWorkspace.ps1`. It backs up the affected files, preserves
existing workspace/layout settings and other startup commands, restarts a running
Flow instance, and reloads GlazeWM. It stops the previous helper before replacing
files and verifies the running version, source hash, and IPC readiness. Other
application windows stay open. Its
`-NoRestart` option still closes Flow before editing settings; launch Flow and press
`Alt+Shift+R` afterward to activate the changes.

The first configuration indexes redirected Windows Documents and Desktop,
Downloads, this repository, and OneDrive business-account roots. Overlapping roots
are removed. Folder indexes only cover names readable by your account; they do not
provide full-drive NTFS metadata indexing or document-content search. OneDrive
results depend on the names exposed by the local sync client.

The first scan can take several minutes. Folder monitoring detects live changes;
a daily noon rescan catches missed changes. Missed scheduled scans do not run
immediately at sign-in. Files changed while Everything was closed can therefore
remain stale until the next rescan. Use Everything's **Tools > Options > Folders >
Rescan All Now** for an immediate update. Missing/offline folders do not block
other roots, but opening their results may be slow or fail.

Edit folder selections and schedules in Everything's **Tools > Options > Folders**.
Subsequent setup runs retain existing folder selections, schedules, unrelated
settings, and the database. They reassert the no-elevation settings and Flow
integration. The configuration script expects Scoop's portable settings, and
refuses existing AppData-based Everything settings rather than silently replacing them.

To configure already-installed packages independently:

```powershell
.\windows\Configure-Launcher.ps1
```

The command also installs and selects the fixed Chocolatier theme in portable
`UserData/Themes`, matching GlazeWM's Kimbie palette: chocolate background,
brown selection, cream text, muted subtitles, and amber borders and accents.
The search overlay uses JetBrainsMono NF with Cascadia Mono fallback, 18px query
text, 14px titles, 12px subtitles, 4px corners, a 580px width, a 42px query box,
and 48px result rows. The clock, date, search icon, and result scrollbar are
hidden; mouse-wheel and keyboard scrolling remain available. Flow's settings
window keeps its existing typography.
Theme installation and the previous theme selection are included in the backup;
restoring a first installation removes the custom theme file.

Use `-NoStart` to configure without launching either application. Setup's
`-NoRestart` also passes this flag; configuration still closes running launchers
before editing their settings. Launch them manually afterward.

Each configuration prints a backup directory under
`%USERPROFILE%\.glzr\backups\launcher-<timestamp>`. Restore settings and startup
ownership and any previous shortcuts with:

```powershell
.\windows\Restore-DesktopSettings.ps1 -BackupPath '<printed backup directory>'
```

Restore stops PowerToys and the launchers before copying settings. Relaunch the
apps you want afterward. Restore backups newest first to undo multiple setup
runs; restore the earlier `desktop-*` backup too if you want FancyZones back.
Packages and indexes are retained. GlazeWM configuration has its separate
`multimonitor-*` backup described below.
Restoring a startup or launcher backup also restores the previous launcher
opt-in file and shortcuts. The shared `GlazeWM` task remains registered; without
the opt-in file it starts only GlazeWM. Disable the task separately to stop all
startup managed by it.

Validate the configuration helpers and diagnostic timeout handling with:

```powershell
.\windows\tests\Test-DesktopSettings.ps1
.\windows\tests\Test-Startup.ps1
.\windows\tests\Test-StartupPerformance.ps1
.\windows\tests\Test-FlowWorkspace.ps1
```

The performance suite uses mocked wallpaper APIs and a loopback WebSocket server;
it does not change the live wallpaper. It verifies fallback, cached loading,
timeouts, fragmented responses, connection reuse and process attribution.
The active bar has no runtime Babel/React or remote JavaScript dependency. Its
pinned bundle and rebuild instructions are in `windows/multimonitor/vendor`.
From that directory, `npm ci --ignore-scripts` then `npm test` runs its DOM tests.

The startup suite uses disposable files, a fake CLI, mocked task registration,
and a short hidden collector. It checks launch ordering, duplicate prevention,
errors and timeouts, Flow bootstrap handoff and current-process logs, shortcut
migration/restore, and diagnostics continuing after the startup process exits.
It does not register real tasks or restart installed apps. After repairing live
startup, validate a fresh sign-in: tiling should respond promptly, no startup terminal
should appear, and `Alt+Space` should open Flow for app search.

The Flow workspace suite tests capture, new/reused windows, focus restoration,
cancellation, timeout expiry, and installation with and without Zebar. With GlazeWM
running and no workspace helper already active, add `-Live` to check IPC and the
helper's duplicate prevention, reload, and shutdown. After applying live settings,
launch an app through Flow from empty and occupied workspaces on both monitors,
then repeat with an existing browser/terminal window and with Escape cancellation.
The explicit `-LaunchApps` option automates these checks with a uniquely named,
temporary GUI executable, including delayed startup from an empty workspace on
each monitor. It verifies the exact Flow result, asserts that all pre-existing
windows retain their workspaces, and restores the original focus afterward.
The helper must already be running. Use Windows PowerShell's `-Mta` option for
this UI Automation test.

With the launchers running, validate their settings, unelevated processes, and
Everything searches and file creation/rename monitoring using Flow's bundled SDK:

```powershell
.\windows\tests\Test-Launcher.ps1
```

This briefly creates and removes a uniquely named test file in this repository.

## WSL setup from Windows

WSL and a distribution must already be installed. Enabling the required Windows
features on a new PC can require an administrator; these scripts use an existing
installation and do not attempt that step. List your distributions with
`wsl --list --verbose`.

For your current distribution:

```powershell
.\setup-wsl.ps1 -Distribution UbuntuNC
```

This runs `~/dotfiles/setup.sh` inside UbuntuNC. It uses the existing Linux
repository and does not copy it onto the Windows filesystem. Its own prerequisites
still apply: Git, curl, Python 3.11+, tmux, tar/xz, sha256sum, and a C linker must
already exist inside the distribution. The Linux script handles the user tools,
Rust, Git submodules, and Linux dotfile links.

On an existing WSL distribution without your Linux repository, supply its URL:

```powershell
.\setup-wsl.ps1 -Distribution Ubuntu -Repository '<your-Linux-dotfiles-Git-URL>'
```

To run both setups:

```powershell
.\setup.ps1 -WithWsl -Distribution UbuntuNC
```

The WSL entry point preserves the Windows `.wslconfig`, the distribution's
`/etc/wsl.conf`, and the default distribution. In particular, it leaves the
current networking configuration in place.

## Restore

Close GlazeWM gracefully from its tray icon first so hidden windows are restored.
New configuration backups contain a `files.json` manifest and can be restored with:

```powershell
.\windows\Restore-DesktopSettings.ps1 -BackupPath "$env:USERPROFILE\.glzr\backups\multimonitor-<timestamp>"
```

This restores source/settings files, the widget pack, and any saved native
wallpaper state. It stops companion apps before restoring; relaunch GlazeWM and
any desired launchers afterward. `-NoRestart` restores files without stopping
apps and is useful for isolated configuration tests. Native wallpaper restoration
still takes effect immediately.

For older backups without `files.json`, copy `config.yaml` and `settings.json` to
`%USERPROFILE%\.glzr\glazewm\config.yaml` and
`%USERPROFILE%\.glzr\zebar\settings.json`, and the backed-up `multimonitor`
folder to `%USERPROFILE%\.glzr\zebar\multimonitor`. Their `previous-state.json`
records which targets originally existed.

## References

- Scoop installation: https://github.com/ScoopInstaller/Scoop#installation
- GlazeWM: https://github.com/glzr-io/glazewm
- Zebar starter widget source: https://github.com/glzr-io/zebar/tree/main/resources/starter
- WSL commands: https://learn.microsoft.com/en-us/windows/wsl/basic-commands

### Reproducible startup updates

From a fresh clone, run `./setup.ps1` in Windows PowerShell 5.1 as your normal user.
After pulling changes, run `./setup.ps1 -NoRestart` to install and build the helpers,
then reload/restart GlazeWM. `-WithLauncher` opts into Flow and Everything; existing
launcher opt-in is retained. Custom `$env:SCOOP` roots and paths with spaces are supported.
`windows/Enable-Startup.ps1` repairs the launcher, lifecycle hooks and logon task.
`windows/Enable-FlowWorkspace.ps1` also builds the launcher for targeted Flow updates.
Generated binaries and helper caches are not tracked.

Setup removes matching current-user Firefox and Adobe Acrobat Synchronizer Run
entries and the Send to OneNote startup shortcut, backing them up first. Use
`-KeepOptionalStartupApps` to keep them. This policy runs only during setup;
Teams, OneDrive, device/security utilities and management tasks are preserved.
Restore a printed backup with `windows/Restore-DesktopSettings.ps1 -BackupPath <path>`;
startup backups include the previous task XML, registry value types and shortcuts.
Startup-only restoration leaves unrelated running applications alone.

The launcher supports `startup [GlazeCli]`, `companions`, `shutdown`, and `reload`.
The first three wait and return the PowerShell exit code; reload detaches the helper.
Errors are recorded in `launcher-errors.log` and per-invocation `launcher-<mode>-<PID>.log` files beside the launcher.
Manual interactive terminals continue to use `Start-GlazeWM.cmd`.

After installation, check reload and workspace switching, then validate a fresh
sign-in separately: prompt tiling, working Alt+Space, bars on every monitor and no
startup terminal. Zebar readiness requires visible bars on every monitor for three seconds.

Launcher installation currently fails validation on this machine with native Windows
error 5 (Access is denied), even though the compiled file exists. Minimal generated
executables run successfully; no specific enforcing policy has been identified.
The installer reports the executable hash and native error and retains the previous
configuration. Do not install until the launcher suite passes. Correlate the reported
hash and time with application-control and endpoint-security events for IT review.
