# Features

Why lightXDM exists and what it sets up for each desktop.

## Purpose & Target Users
- **Minimal RAM/boot time**: No display manager, no bloat, just your DE.
- **Session auto-start, with Keyring auto-unlock or optional Autologin**: Choose between password login on TTY1 with automatic keyring unlock via PAM (default) or passwordless TTY1 autologin via `enable-autologin.sh` across KDE Plasma, GNOME, and Budgie (Wayland), plus XFCE, LXQt, LXDE, MATE, Cinnamon, and i3 (X11).
- **Full Polkit & PAM integration**: the right polkit agent for each desktop, `udisks2` defaults for USB mounting, systemd's defaults for passwordless power actions, and PAM keyring unlock.
- **Systemd compatible**: Works on Arch Linux and derivatives.

**Target users:**
- Minimalists
- Arch Linux users
- Display manager haters
- Tinkerers who want full control

## Why not SDDM/LightDM?
- No extra daemons or RAM usage
- Faster boot (no DM startup delay)
- Simpler troubleshooting (session config in dotfiles; system changes include `/etc/pam.d/login`, GNOME's `/etc/lightxdm/gnome-session-type.conf`, and systemd units)
- No graphical login: boots to TTY1, and your DE auto-starts after login—no need to run `startx` manually

## Features

lightXDM supports built-in and custom X11/Wayland desktop sessions, non-bash login shells, safe package updates, and built-in recovery diagnostics:

### Multi-Desktop Environment Support
- **Automatic Detection:** The installer detects if Plasma, GNOME, Budgie, XFCE, LXQt, LXDE, MATE, Cinnamon, or i3 is already installed.
- **User Choice:** If no DE is found, the installer prompts you to select and install one of Plasma, GNOME, Budgie, XFCE, LXQt, LXDE, MATE, Cinnamon, or i3.
- **Minimal Install:** Only the essential packages for your chosen DE are installed, including the polkit agent each desktop needs: polkit-kde-agent for Plasma, lxqt-policykit for LXQt, polkit-gnome for XFCE and i3 (their templates start it); GNOME Shell and Cinnamon have one built in, and Budgie (budgie-polkit-dialog), LXDE (lxpolkit) and MATE (mate-polkit) start their own, keeping the system lightweight.
- **Dotfiles:** `.bash_profile` and the session template for your DE (`~/.xinitrc` for X11, or `~/.wayland-session` for Plasma, GNOME, and Budgie) are copied for session start on TTY1. Installing an X11 desktop moves any `~/.wayland-session` aside and removes it so `startx` can run; see [session files and backups](installation.md#session-files-and-backups).
- **Wayland packages:** Plasma, GNOME, and Budgie do not install `xorg-server` or `xorg-xinit`.

### Custom X11 & Wayland Sessions
- **Session Discovery:** `--list-sessions` inspects installed X11 and Wayland `.desktop` session entries safely on the host.
- **Editable Templates:** `--init-template [--wayland] [--from-session <path>] --de <custom-id>` creates `~/.config/lightxdm/.xinitrc-<id>` (or `.wayland-session-<id>` when `--wayland` is passed or `<path>` is a Wayland entry) for manual customization before installing with `--no-packages --de <custom-id>`.
- **One-Command Session Provisioning:** `--install-session <path>` validates `TryExec`/`Exec` before privilege checks or home writes, infers Wayland mode when `--wayland` is set or `<path>` resides under `wayland-sessions/`, derives `--de <custom-id>` from the `.desktop` filename unless overridden, creates missing custom templates (preserving existing user templates on rerun), and installs with `--no-packages`.
- **Keyring Selection:** Custom sessions default to GNOME Keyring (`--keyring gnome`), or use `--keyring kwallet` or `--no-keyring`.

### Display Manager Independence & Login Shells
- **No Display Manager Needed:** The script disables enabled display managers (SDDM, LightDM, GDM, LXDM, `ly@tty1`, and whatever unit `display-manager.service` points to) to ensure a pure TTY workflow (`startx`, or a Wayland session for Plasma, GNOME, and Budgie); `ly` on other TTYs is left alone unless `display-manager.service` points to it. `lightxdm-update` never disables one you enabled again; it names it and the command that disables it.
- **GNOME limitation:** GNOME cannot lock the screen without GDM. See [GNOME session requirements](installation.md#gnome-session-requirements) before choosing it.
- **Auto-Start on TTY1:** After login on TTY1, your desktop environment starts automatically—no need to run `startx` manually. Optional passwordless autologin is available via `enable-autologin.sh` (with the trade-off that the keyring cannot unlock automatically unless its password is empty).
- **Bash, Zsh, and Fish Hooks:** Bash works directly via `~/.bash_profile`. For `zsh` or `fish`, `--setup-shell <zsh|fish|auto>` idempotently writes a managed `# >>> lightXDM TTY1 auto-start >>>` block in `~/.zprofile` or `~/.config/fish/config.fish` (which `uninstall.sh` cleanly removes), and `--shell-snippet <zsh|fish>` prints the snippet for manual setup.

### Safe Updates, Diagnostics & Recovery
- **Safe Updates (`--update` / `lightxdm-update`):** Re-applies newer lightXDM versions using your saved `install-choices` and `/etc/lightxdm/pam-keyring`. Home files you edited stay intact with updated templates written beside them as `*.lightxdm-new`, removed packages and re-enabled display managers stay as you left them (with commands printed if you want to re-sync), and PAM lines dropped by an `/etc/pam.d/login.pacnew` merge are restored without overriding edits you made in `/etc/pam.d/login`.
- **Read-Only Checks (`--preflight`, `--status [--json]`, `--doctor`):** Inspect host readiness, current installation state (human-readable or JSON), active launcher, template syntax and commands, shell hooks, `no-autostart`, `startx-attempts`, `*.lightxdm-new` files, PAM keyring/GNOME rules and `.so` modules, `getty@tty1.service`, re-enabled display managers, and TTY1 autologin conflicts without `sudo`.
- **Automated Recovery (`--recover` and `--fix`):** `--recover` restores broken or paused home dotfiles without `sudo` (backing up edits to `*.lightxdm-edited*` and clearing `no-autostart`/`startx-attempts`) without touching packages, PAM, or systemd; `--fix` repairs broken home dotfiles, missing managed shell hooks, PAM rules, `getty@tty1.service`, and re-enabled display managers (preserving valid user templates and calling `sudo` only when system state requires inspection or repair) before re-running `--doctor`.
- **Crash-Loop Pause & Session Journal:** If TTY1 desktop launch occurs three times within 30 seconds, `.bash_profile` pauses auto-start via `~/.config/lightxdm/no-autostart` and opens an interactive shell; creating `~/.config/lightxdm/session-journal` sends launcher stdout/stderr to the systemd journal (`journalctl -b -t lightxdm`). See [startx-autologin.md](startx-autologin.md#recovery).

### System Integration
- **Polkit & PAM:** Power actions use systemd's own Polkit defaults (lightXDM installs no rule) and USB mounting uses `udisks2` defaults; the installer appends PAM lines to `/etc/pam.d/login` (with a one-time backup `/etc/pam.d/login.lightxdm.bak`; `uninstall.sh` removes only the lines lightXDM added and keeps the backup for review if you changed anything else) for keyring auto-unlock (`pam_kwallet5.so` on Plasma, `pam_gnome_keyring.so` elsewhere).
- **GNOME session type:** A separate PAM block in `/etc/pam.d/login` reads `/etc/lightxdm/gnome-session-type.conf` to register a Wayland login only for the installing user on TTY1, including with `--no-keyring`. Installing another desktop or uninstalling removes it and the config; `--keyring-only` keeps them. See [the block and its purpose](installation.md#gnome-session-requirements).
- **GPG Agent Integration**: Starts `gpg-agent` at session startup, points `SSH_AUTH_SOCK` at it when `enable-ssh-support` is set in `~/.gnupg/gpg-agent.conf`, and refreshes its startup tty (see [gpg-agent.md](gpg-agent.md) for optional keyring-backed `pinentry` setup).
- **Documentation:** See [installation.md](installation.md) for full CLI and option details, [startx-autologin.md](startx-autologin.md) for TTY1 auto-start, autologin, `zsh`/`fish`, and recovery, [kwallet-autounlock.md](kwallet-autounlock.md) for KWallet unlock, [polkit-support.md](polkit-support.md) for Polkit integration, [gpg-agent.md](gpg-agent.md) for GPG/SSH setup, and [development.md](development.md) for tests and packaging.

### Feature Overview

| Feature                        | Status                                      |
|--------------------------------|-----------------------------------------------------------|
| Plasma support                 | auto-detect/install, Wayland via `~/.wayland-session`, KWallet, polkit-kde-agent, dotfiles |
| GNOME support                  | auto-detect/install, Wayland via `~/.wayland-session`, GNOME Keyring, TTY1 session-type PAM block; no screen lock without GDM |
| Budgie support                 | auto-detect/install, Wayland via `~/.wayland-session`, GNOME Keyring, dotfiles |
| XFCE support                   | auto-detect/install, GNOME Keyring, polkit-gnome (started by `.xinitrc`), dotfiles |
| LXQt support                   | auto-detect/install, GNOME Keyring, lxqt-policykit, dotfiles   |
| LXDE support                   | auto-detect/install, GNOME Keyring, lxpolkit (lxsession), dotfiles |
| MATE support                   | auto-detect/install, GNOME Keyring, mate-polkit, dotfiles |
| Cinnamon support               | auto-detect/install, GNOME Keyring, built-in polkit agent, dotfiles |
| i3 support                     | auto-detect/install, GNOME Keyring, polkit-gnome (started by `.xinitrc`), dotfiles |
| Custom X11 & Wayland sessions  | `--list-sessions`, `--init-template [--wayland] [--from-session]`, `--install-session <path>`, `--keyring <gnome|kwallet>` |
| No DE installed                | Prompts user, installs selected DE                                |
| Display manager free           | disables SDDM, LightDM, GDM, LXDM, ly@tty1 and the display-manager.service unit |
| Auto-start & optional autologin| TTY1 auto-start via `.bash_profile` (`~/.xinitrc` or `~/.wayland-session`), optional `zsh`/`fish` hooks (`--setup-shell`, `--shell-snippet`), optional autologin via `enable-autologin.sh` |
| Safe updates                   | `--update` (`lightxdm-update`) keeps edited dotfiles (`*.lightxdm-new`), preserves user package/DM/PAM choices, restores `.pacnew`-dropped PAM lines |
| Diagnostics & recovery         | `--preflight`, `--status [--json]`, `--doctor`, `--recover`, `--fix`, automatic crash-loop pause (`no-autostart`), `session-journal` |
| Polkit integration             | systemd's defaults for power actions, `udisks2` defaults for USB, correct agent for each DE |
| PAM integration                | appends `pam_kwallet5.so` (Plasma) or `pam_gnome_keyring.so` to `/etc/pam.d/login` with one-time backup; custom sessions choose with `--keyring gnome` (default) or `--keyring kwallet` |
| GPG Agent Integration          | starts `gpg-agent`, sets `SSH_AUTH_SOCK` when `enable-ssh-support` is set, and refreshes its tty via `~/.gpg-agent-kwallet` (Plasma) or `~/.gpg-agent-gnome` |
| Documentation                  | `README.md`, [installation.md](installation.md), [startx-autologin.md](startx-autologin.md), [kwallet-autounlock.md](kwallet-autounlock.md), [polkit-support.md](polkit-support.md), [gpg-agent.md](gpg-agent.md), [development.md](development.md) |

---
See `docs/` for technical details and customization tips.
