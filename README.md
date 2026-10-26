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
    Start-GlazeWM.cmd   Startup launcher with logging and duplicate prevention
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
This avoids the long delay observed with the Windows Startup folder. The launcher
checks whether GlazeWM already responds before starting it, so a manual launch
does not cause a duplicate-instance popup later. GlazeWM launches Zebar through
its existing startup command.

To enable or repair startup separately without restarting either app:

```powershell
.\windows\Enable-Startup.ps1
```

The installer backs up the previous `GlazeWM.lnk` Startup-folder entry under
`%USERPROFILE%\.glzr\backups\startup-task-<timestamp>` after the task is registered.
If task registration is denied, it leaves the existing shortcut in place and
reports the error. A company restriction on task registration requires IT help.

Startup logging is always enabled at `%USERPROFILE%\.glzr\glazewm\startup.log`.
It records invocation times, skipped duplicate launches, command output, and exit
codes. A zero CLI exit code confirms dispatch, not that GlazeWM became ready.
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

Zebar also starts a `wallpaper` widget on every monitor, showing the bundled
Coniston photo in `windows/multimonitor/resources/coniston.jpg`. The photo fills
each screen with a centred crop and keeps its original proportions. Replace that
file to use another picture, then run `.\windows\Apply.ps1`.

The widget stays at the bottom of the window stack, does not reserve screen
space, and passes mouse clicks through to the desktop. It is an app-rendered
background; it does not change the Windows wallpaper or management policies.
The image is local; the click-through API uses the same cached Zebar JavaScript
module as the status bar.

As a desktop widget, the photo can cover desktop icons, and `Win+D` may reveal
the underlying Windows wallpaper. Exiting Zebar also removes the photo overlay.

To stop it immediately, open Zebar's tray menu, then `Widget packs` >
`multimonitor` > `wallpaper` and stop the `default` preset. To disable it across
future setup runs, remove the `wallpaper` entry from `windows/settings.json` and
rerun `.\windows\Apply.ps1`.

## Startup lag diagnostics

FancyZones is disabled by setup so GlazeWM handles window arrangement. Other
PowerToys utilities remain enabled unless you opt into the launcher replacement.
To apply that change independently, run `.\windows\Configure-Desktop.ps1`.
Settings backups are saved under `%USERPROFILE%\.glzr\backups\desktop-<timestamp>`.

Enable a ten-minute diagnostic capture on each sign-in:

```powershell
.\windows\Enable-Startup.ps1 -Diagnostics
```

The launcher starts the collector before dispatching GlazeWM. Each capture writes
JSON lines under `%USERPROFILE%\.glzr\glazewm\diagnostics`, recording timestamps,
the first successful monitor query, query latency, total CPU and disk activity,
and CPU/memory/I/O counters for GlazeWM, Zebar, WebView2 and launcher processes.
Process CPU counters may exceed 100% across multiple cores. Probes time out after
two seconds; only the diagnostic CLI process is killed. Missing performance
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
Zebar (including its bar and wallpaper widgets):

```powershell
.\windows\Apply.ps1 -WithoutZebar
```

Run `.\windows\Apply.ps1` again to restore Zebar. These commands back up the live
configuration and gracefully restart GlazeWM. Keep the default ten-second logon
delay until the measurements show that changing it would help.

Disable future captures with `.\windows\Enable-Startup.ps1 -DisableDiagnostics`.
Ordinary setup preserves the diagnostics setting; old captures remain for comparison.

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
other utilities are retained. Both new apps get per-user Startup-folder shortcuts.
Their search UI may become available later than GlazeWM's logon task.

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

Use `-NoStart` to configure without launching either application. Setup's
`-NoRestart` also passes this flag; configuration still closes running launchers
before editing their settings. Launch them manually afterward.

Each configuration prints a backup directory under
`%USERPROFILE%\.glzr\backups\launcher-<timestamp>`. Restore settings and startup
shortcuts with:

```powershell
.\windows\Restore-DesktopSettings.ps1 -BackupPath '<printed backup directory>'
```

Restore stops PowerToys and the launchers before copying settings. Relaunch the
apps you want afterward. Restore backups newest first to undo multiple setup
runs; restore the earlier `desktop-*` backup too if you want FancyZones back.
Packages and indexes are retained. GlazeWM configuration has its separate
`multimonitor-*` backup described below.

Validate the configuration helpers and diagnostic timeout handling with:

```powershell
.\windows\tests\Test-DesktopSettings.ps1
```

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
Copy `config.yaml` and `settings.json` from the desired backup back to
`%USERPROFILE%\.glzr\glazewm\config.yaml` and
`%USERPROFILE%\.glzr\zebar\settings.json`. If the backup contains a `multimonitor`
folder, restore it to `%USERPROFILE%\.glzr\zebar\multimonitor`. The accompanying
`previous-state.json` records whether each target existed before setup. Relaunch
GlazeWM and Zebar after restoring the files.

## References

- Scoop installation: https://github.com/ScoopInstaller/Scoop#installation
- GlazeWM: https://github.com/glzr-io/glazewm
- Zebar starter widget source: https://github.com/glzr-io/zebar/tree/main/resources/starter
- WSL commands: https://learn.microsoft.com/en-us/windows/wsl/basic-commands
