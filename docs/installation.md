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
# Or keep your existing Polkit policy without installing the passwordless power rule:
# bash install.sh --no-polkit-rule --de i3
# Or log in on TTY1 without a password (no keyring unlock) in the same run:
# bash install.sh --no-keyring --autologin --de i3
# Or create ~/.config/lightxdm/.xinitrc-<id> to customize before installing (no sudo):
# bash install.sh --init-template --de i3
# Every script has a read-only help: bash install.sh --help, bash uninstall.sh --help, bash enable-autologin.sh --help
```

## What the installer does

Plasma, GNOME, and Budgie start on Wayland through `~/.wayland-session`, which `.bash_profile` runs on TTY1 in place of `startx`. These desktops do not install `xorg-server` or `xorg-xinit`. XFCE, LXQt, LXDE, MATE, Cinnamon, and i3 start with `startx` through `~/.xinitrc`. Before choosing GNOME, read its [session requirements and screen-lock limitation](#gnome-session-requirements).

- **Detects your installed DE** (Plasma, GNOME, Budgie, XFCE, LXQt, LXDE, MATE, Cinnamon, or i3), or pass `--de <id>` (`plasma`, `gnome`, `budgie`, `xfce`, `lxqt`, `lxde`, `mate`, `cinnamon`, or `i3`) to configure a specific desktop explicitly. One detected desktop is configured automatically; two or more prompt you to choose (or pass `--de <id>` to select non-interactively).
- If no DE is found (and `--de` is not passed), it **prompts you to choose one** to install.
- Installs the minimal required packages for your chosen DE, including the correct polkit agent:
  - lxqt-policykit for LXQt
  - polkit-kde-agent for Plasma
  - polkit-gnome for all other supported DEs.
- Pass `--list-packages --de <id>` (`plasma`, `gnome`, `budgie`, `xfce`, `lxqt`, `lxde`, `mate`, `cinnamon`, or `i3`; combinable with `--no-keyring`) to print the package set `install.sh` would install, one per line, and exit 0 without needing `sudo` or changing anything—useful to review the packages beforehand or install them yourself before running `--no-packages`.
- Pass `--no-packages` (optionally with `--de <id>`) to skip all package installation when you already have the required packages. Before changing dotfiles, PAM, Polkit or display managers, the installer checks the session commands (also after package installation): for an X11 desktop, `startx` and the plain command name in the selected template's last `exec ` line must be on PATH; for Plasma, GNOME, and Budgie, every absolute path on the last `exec` line of the Wayland template must be executable (no `startx` needed). Templates without a simple `exec` command skip the session-command check. Dotfiles, PAM, Polkit and display manager setup then run. For a custom session, create `~/.config/lightxdm/.xinitrc-<id>` and run, for example, `bash install.sh --no-packages --de dwm` with `~/.config/lightxdm/.xinitrc-dwm` present (`~/.config/lightxdm/.xinitrc-<id>` also overrides any bundled `dotfiles/.xinitrc-<id>` template). `bash install.sh --init-template --de <id>` creates that file for you without sudo: a copy of the bundled template for a built-in id, or the i3 template with the session id and `exec` command swapped for a custom one; it never overwrites an existing file. For Plasma, GNOME, and Budgie it creates `~/.config/lightxdm/.wayland-session-<id>` instead, which also overrides the bundled Wayland template. Custom ids must match `^[a-z0-9_][a-z0-9_-]*$` (no leading hyphen) and use GNOME Keyring for PAM (pass `--no-keyring` to skip keyring PAM setup); install the required packages yourself.
- Pass `--no-keyring` (combinable with `--de <id>`, `--list-packages`, `--no-packages`, and `--no-polkit-rule`) to omit `gnome-keyring` and `kwallet-pam` from package installation and skip `/etc/pam.d/login` keyring setup. GNOME's separate session-type PAM block is still installed.
- Pass `--no-polkit-rule` (combinable with `--de <id>`, `--no-packages`, and `--no-keyring`) to skip installing `/etc/polkit-1/rules.d/49-nopasswd.rules` and keep your existing Polkit authorization policy.
- Copies dotfiles to your home: `.bash_profile`, the session template as `~/.xinitrc` (X11 desktops) or `~/.wayland-session` (Plasma, GNOME, and Budgie), and the gpg-agent helper (`~/.gpg-agent-kwallet` for Plasma, `~/.gpg-agent-gnome` otherwise).
- Appends PAM lines to `/etc/pam.d/login` (unless `--no-keyring` is passed; after a one-time backup at `/etc/pam.d/login.lightxdm.bak`; `uninstall.sh` removes the lines lightXDM added and restores the backup when nothing else changed, otherwise it keeps your other edits and leaves the backup for review) for keyring auto-unlock: KWallet (`pam_kwallet5.so`) for Plasma, GNOME Keyring (`pam_gnome_keyring.so`) for the other desktops.
- For GNOME only, inserts a [session-type PAM block](#gnome-session-requirements) before the first session line, including with `--no-keyring`.
- Configures Polkit (unless `--no-polkit-rule` is passed) for passwordless power-off, reboot, suspend, and hibernate for local active `wheel` users on seat0, while USB mounting uses `udisks2` defaults.
- Your DE will start automatically on TTY1 after login—no need to run 'startx'.

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
