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

This installs missing GlazeWM/Zebar packages through Scoop, copies the tracked
configuration into `%USERPROFILE%\.glzr`, and gracefully restarts the window
manager and bar. Existing configuration and the local bar are backed up under
`%USERPROFILE%\.glzr\backups\multimonitor-<timestamp>` on every run. Future edits
belong in this repository; rerunning setup copies them into place. No symlinks
or administrator privileges are required for the Windows setup.

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
- `Alt+Space`: open the existing PowerToys Run app launcher.
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

## Spotlight-style app search

PowerToys is already installed on this PC, starts with Windows, and has PowerToys
Run enabled with `Alt+Space`. Its Program plugin is enabled for app searches:
press `Alt+Space`, type an app name, then press `Enter`. GlazeWM leaves that
shortcut free and ignores the Run window so the launcher stays an overlay.

On a new PC, install [Microsoft PowerToys](https://learn.microsoft.com/en-us/windows/powertoys/install),
enable Run and its Program plugin, and select `Alt+Space` as the activation shortcut.
PowerToys must stay running in the background. The existing PowerToys settings
are retained; setup only installs the GlazeWM and Zebar configuration.

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
