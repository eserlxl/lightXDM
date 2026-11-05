# Installation

Everything `install.sh` does, every option, the two login modes, and uninstalling.

## Quick Install (Arch Linux)
```sh
# Clone and run the installer
cd ~
git clone https://github.com/eserlxl/lightXDM.git
cd lightXDM
bash install.sh
# Or select a desktop explicitly (skips detection and prompt):
# bash install.sh --de i3
# Or review the package list for a desktop without installing anything:
# bash install.sh --list-packages --de i3
# Or configure an existing desktop without installing packages:
# bash install.sh --no-packages --de i3
# Or skip keyring packages and PAM keyring setup (for autologin or keyring-free setups):
# bash install.sh --no-keyring --de i3
# Or keep the system's own Polkit policy (lightXDM installs no rule):
# bash install.sh --no-polkit-rule --de i3
# Or log in on TTY1 without a password (no keyring unlock) in the same run:
# bash install.sh --no-keyring --autologin --de i3
# Or create ~/.config/lightxdm/.xinitrc-<id> to customize before installing (no sudo):
# bash install.sh --init-template --de i3
# Or create a custom Wayland template, edit it, then configure an installed compositor:
# bash install.sh --init-template --wayland --de sway
# bash install.sh --no-packages --de sway
# Every script has a read-only help: bash install.sh --help, bash uninstall.sh --help, bash enable-autologin.sh --help
```

## What the installer does

Plasma, GNOME, and Budgie start on Wayland through `~/.wayland-session`, which `.bash_profile` runs on TTY1 in place of `startx`. These desktops do not install `xorg-server` or `xorg-xinit`. XFCE, LXQt, LXDE, MATE, Cinnamon, and i3 start with `startx` through `~/.xinitrc`. Before choosing GNOME, read its [session requirements and screen-lock limitation](#gnome-session-requirements).

- **Detects your installed DE** (Plasma, GNOME, Budgie, XFCE, LXQt, LXDE, MATE, Cinnamon, or i3), or pass `--de <id>` (`plasma`, `gnome`, `budgie`, `xfce`, `lxqt`, `lxde`, `mate`, `cinnamon`, or `i3`) to configure a specific desktop explicitly. One detected desktop is configured automatically; two or more prompt you to choose (or pass `--de <id>` to select non-interactively).
- If no DE is found (and `--de` is not passed), it **prompts you to choose one** to install.
- Installs the minimal required packages for your chosen DE, including the correct polkit agent:
  - polkit-kde-agent for Plasma, lxqt-policykit for LXQt
  - polkit-gnome for XFCE and i3, whose templates start it
  - nothing extra for GNOME and Cinnamon (built into the shell), Budgie (budgie-polkit-dialog), LXDE (lxpolkit from lxsession) and MATE (mate-polkit), which start their own
- Pass `--list-packages --de <id>` (`plasma`, `gnome`, `budgie`, `xfce`, `lxqt`, `lxde`, `mate`, `cinnamon`, or `i3`; combinable with `--no-keyring`) to print the package set `install.sh` would install, one per line, and exit 0 without needing `sudo` or changing anything—useful to review the packages beforehand or install them yourself before running `--no-packages`.
- Pass `--no-packages` (optionally with `--de <id>`) to skip all package installation when you already have the required packages. Before changing dotfiles, PAM, Polkit or display managers, the installer checks session commands (also after package installation). For X11, `startx` and the plain command name in the selected template's last `exec ` line must be on PATH. For Wayland, every absolute path before the first option (a word starting with `-`) on that line must be executable, and a plain command name such as `sway` must be on PATH; `startx` is not required. Both command-name checks include `~/.local/bin` on PATH. Templates without a simple `exec` command skip the template-command check. Dotfiles, PAM, Polkit and display manager setup then run.
- Pass `--init-template --de <id>` without sudo to create an editable template: a copy of the bundled template for a built-in id, or the i3 X11 template with the session id and `exec` command swapped for a custom one. It creates `~/.config/lightxdm/.xinitrc-<id>`, or `.wayland-session-<id>` for Plasma, GNOME, and Budgie. These user templates override the bundled templates. For a custom Wayland compositor, add `--wayland` as described below. Existing files are never overwritten.
- Pass `--no-keyring` (combinable with `--de <id>`, `--list-packages`, `--no-packages`, and `--no-polkit-rule`) to omit `gnome-keyring` and `kwallet-pam` from package installation and skip `/etc/pam.d/login` keyring setup. GNOME's separate session-type PAM block is still installed.
- Pass `--no-polkit-rule` (combinable with `--de <id>`, `--no-packages`, and `--no-keyring`) to skip installing `/etc/polkit-1/rules.d/49-nopasswd.rules` and keep the system's own policy.
- Copies dotfiles to your home: `.bash_profile`, the session template as `~/.xinitrc` (X11 sessions) or `~/.wayland-session` (Wayland sessions, including custom compositors), and the gpg-agent helper (`~/.gpg-agent-kwallet` for Plasma, `~/.gpg-agent-gnome` otherwise).
- Appends PAM lines to `/etc/pam.d/login` (unless `--no-keyring` is passed; after a one-time backup at `/etc/pam.d/login.lightxdm.bak`; installing another desktop replaces the keyring lines lightXDM added for the previous one, and `uninstall.sh` removes the lines lightXDM added and restores the backup when nothing else changed, otherwise it keeps your other edits and leaves the backup for review) for keyring auto-unlock: KWallet (`pam_kwallet5.so`) for Plasma, GNOME Keyring (`pam_gnome_keyring.so`) for the other desktops.
- For GNOME only, inserts a [session-type PAM block](#gnome-session-requirements) before the first session line, including with `--no-keyring`.
- Configures Polkit (unless `--no-polkit-rule` is passed) to keep power-off, reboot, suspend, and hibernate allowed for local active `wheel` users on seat0 if systemd's defaults are tightened (systemd already allows them in active local sessions), while USB mounting uses `udisks2` defaults.
- Your DE will start automatically on TTY1 after login—no need to run 'startx'.

### Custom sessions

Custom ids use `~/.config/lightxdm/.wayland-session-<id>` when present, otherwise `~/.config/lightxdm/.xinitrc-<id>` for X11. If both exist, the installer refuses before making changes and names both files; keep only the template you want. Custom ids must contain only lowercase ASCII letters, digits, `_` and `-`, with no leading hyphen. They require `--no-packages`: install the compositor or window manager and its dependencies yourself. PAM uses GNOME Keyring, or pass `--no-keyring` to skip keyring setup.

For example, create and edit a Sway template, then install it:

```sh
bash install.sh --init-template --wayland --de sway
# Edit ~/.config/lightxdm/.wayland-session-sway as needed.
bash install.sh --no-packages --de sway
```

`--wayland` is accepted only with `--init-template` and a custom id. Plasma, GNOME, and Budgie already have Wayland templates; the six built-in X11 ids also refuse this flag. The generated file has mode `755`, exports `DESKTOP_SESSION=<id>`, `XDG_CURRENT_DESKTOP=<id>` and `XDG_SESSION_TYPE=wayland`, sources `~/.gpg-agent-gnome` when present, and ends with `exec <id>`. Edit that line if the executable differs from your id, for example `exec Hyprland` for a `hyprland` id. A missing plain command stops installation before configuration. For custom X11, use `--init-template --de dwm` and then `--no-packages --de dwm` instead.

### Session files and backups

The Wayland templates in `dotfiles/` are copied to `~/.wayland-session` and end with:

| Desktop | Template | Session command |
|---|---|---|
| Plasma | `.wayland-session-plasma` | `exec /usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasma-wayland` |
| GNOME | `.wayland-session-gnome` | `exec /usr/bin/gnome-session` |
| Budgie | `.wayland-session-budgie` | `exec /usr/bin/startbudgielabwc` |

An executable `~/.wayland-session` takes precedence over `startx`. Installing an X11 desktop after a Wayland one moves that file aside like `~/.xinitrc`, preserving an original as `~/.wayland-session.lightxdm.bak` or saving later edits as `~/.wayland-session.lightxdm-edited*`, then removes `~/.wayland-session` so `startx` can run. This also applies to edited or foreign session files. `uninstall.sh` restores the original backup; saved edits remain available for review.

### GNOME session requirements

**GNOME cannot lock the screen without GDM.** GNOME shows “Screen Lock disabled — Screen Locking requires the GNOME display manager”. lightXDM disables GDM, so choose GNOME only if you accept this limitation.

GNOME Shell runs as a systemd user service and needs a logind session of type `wayland`, but a getty login creates a `tty` session. For GNOME only, the installer inserts this block before the first session line in `/etc/pam.d/login` (`<installing user>` is replaced with your username):

```text
# lightXDM: GNOME on TTY1 needs a wayland session type (uninstall.sh removes this)
session    [success=2 default=ignore] pam_succeed_if.so quiet tty notin tty1:/dev/tty1
session    [success=1 default=ignore] pam_succeed_if.so quiet user != <installing user>
session    optional   pam_env.so readenv=0 user_readenv=0 conffile=/etc/lightxdm/gnome-session-type.conf
```

The first two lines after the comment skip the environment setting for other TTYs or users. `/etc/lightxdm/gnome-session-type.conf` sets `XDG_SESSION_TYPE DEFAULT=wayland`, so the block applies only to the installing user on TTY1. It is installed even with `--no-keyring`, independently of the `pam_gnome_keyring.so` lines that unlock GNOME Keyring for GNOME and Budgie.

Installing another desktop or running `uninstall.sh` removes the block and `/etc/lightxdm/gnome-session-type.conf`. `uninstall.sh --keyring-only` keeps both so GNOME can still start.

### Two Login Modes
1. **Default (Password Login + Keyring Auto-Unlock):** Type your password on TTY1; the desktop starts automatically and the keyring unlocks through PAM (KWallet on Plasma, GNOME Keyring elsewhere).
2. **Optional Autologin (`enable-autologin.sh`):** Run `sudo bash enable-autologin.sh YOURUSER` (`--disable` to revert; changes apply at the next login or reboot) to log in on TTY1 without a password; `bash enable-autologin.sh --status` shows the current state without sudo. Because login happens without a password, PAM cannot unlock the keyring automatically—the keyring stays locked and asks for its password in the desktop unless its password is empty (`enable-autologin.sh` prints this warning when PAM keyring lines are configured). Pass `--no-keyring` to `install.sh` (combinable with `--de <id>` and `--no-packages`) to skip installing `gnome-keyring` / `kwallet-pam` and skip adding keyring lines to `/etc/pam.d/login`—recommended for autologin users who do not use a keyring and for window-manager setups without one. If keyring unlock is already set up, `sudo bash uninstall.sh --keyring-only` removes only the keyring lines lightXDM added to `/etc/pam.d/login` and leaves everything else in place. On a new install, `bash install.sh --no-keyring --autologin` skips the keyring setup and enables autologin in one run: it calls `enable-autologin.sh` for you after the rest of the install succeeds (`--autologin` refuses to run without `--no-keyring`).

## Uninstall

See [Uninstall in the README](../README.md#uninstall): it stays on the landing page because it re-enables display managers and edits `/etc/pam.d/login`.
