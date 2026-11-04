# Features

Why lightXDM exists and what it sets up for each desktop.

## Purpose & Target Users
- **Minimal RAM/boot time**: No display manager, no bloat, just your DE.
- **Session auto-start, with Keyring auto-unlock or optional Autologin**: Choose between password login on TTY1 with automatic keyring unlock via PAM (default) or passwordless TTY1 autologin via `enable-autologin.sh` across KDE Plasma (Wayland), XFCE, LXQt, LXDE, MATE, Cinnamon, and i3.
- **Full Polkit & PAM integration**: `udisks2` defaults for USB mounting, passwordless power actions for local active `wheel` users on seat0, and PAM keyring unlock.
- **Systemd compatible**: Works on Arch Linux and derivatives.

**Target users:**
- Minimalists
- Arch Linux users
- Display manager haters
- Tinkerers who want full control

## Why not SDDM/LightDM?
- No extra daemons or RAM usage
- Faster boot (no DM startup delay)
- Simpler troubleshooting (session config in dotfiles; system changes limited to `/etc/pam.d/login`, one Polkit rule, and systemd units)
- No graphical login: boots to TTY1, and your DE auto-starts after login—no need to run `startx` manually

## Features

lightXDM has recently expanded to support many desktop environments and improved its installation workflow:

### Multi-Desktop Environment Support
- **Automatic Detection:** The installer detects if Plasma, XFCE, LXQt, LXDE, MATE, Cinnamon, or i3 is already installed.
- **User Choice:** If no DE is found, the installer prompts you to select and install one (XFCE, LXQt, LXDE, MATE, Cinnamon, or i3).
- **Minimal Install:** Only the essential packages for your chosen DE are installed, including the correct polkit agent (lxqt-policykit for LXQt, polkit-kde-agent for Plasma, polkit-gnome for all others), keeping the system lightweight.
- **Dotfiles:** `.bash_profile` and the session template for your DE (`~/.xinitrc`, or `~/.wayland-session` for Plasma) are copied, ensuring seamless session start on TTY1.

### Display Manager Independence
- **No Display Manager Needed:** The script disables enabled display managers (SDDM, LightDM, GDM, LXDM, `ly@tty1`, and whatever unit `display-manager.service` points to) to ensure a pure TTY workflow (`startx`, or Plasma's Wayland session); `ly` on other TTYs is left alone unless `display-manager.service` points to it.
- **Auto-Start on TTY1:** After login on TTY1, your desktop environment starts automatically—no need to run `startx` manually. Optional passwordless autologin is available via `enable-autologin.sh` (with the trade-off that the keyring cannot unlock automatically unless its password is empty).

### System Integration
- **Polkit & PAM:** The installer installs a Polkit rule granting passwordless power-off, reboot, suspend, and hibernate to local active `wheel` users on seat0 (leaving USB mounting to `udisks2` defaults), and appends PAM lines to `/etc/pam.d/login` (with a one-time backup `/etc/pam.d/login.lightxdm.bak`; `uninstall.sh` removes only the lines lightXDM added and keeps the backup for review if you changed anything else) for keyring auto-unlock (`pam_kwallet5.so` on Plasma, `pam_gnome_keyring.so` elsewhere).
- **GPG Agent Integration**: Starts `gpg-agent` at session startup, points `SSH_AUTH_SOCK` at it when `enable-ssh-support` is set in `~/.gnupg/gpg-agent.conf`, and refreshes its startup tty (see [gpg-agent.md](gpg-agent.md) for optional keyring-backed `pinentry` setup).
- **Documentation:** See the `docs/` directory for technical details on KWallet auto-unlock, Polkit integration, and autologin setup.

### Feature Overview

| Feature                        | Status                                      |
|--------------------------------|-----------------------------------------------------------|
| Plasma support                 | auto-detect/install, Wayland via `~/.wayland-session`, KWallet, polkit-kde-agent, dotfiles |
| XFCE support                   | auto-detect/install, GNOME Keyring, polkit-gnome, dotfiles    |
| LXQt support                   | auto-detect/install, GNOME Keyring, lxqt-policykit, dotfiles   |
| LXDE support                   | auto-detect/install, GNOME Keyring, polkit-gnome, dotfiles    |
| MATE support                   | auto-detect/install, GNOME Keyring, polkit-gnome, dotfiles    |
| Cinnamon support               | auto-detect/install, GNOME Keyring, polkit-gnome, dotfiles    |
| i3 support                     | auto-detect/install, GNOME Keyring, polkit-gnome, dotfiles    |
| No DE installed                | Prompts user, installs selected DE                                |
| Display manager free           | disables SDDM, LightDM, GDM, LXDM, ly@tty1 and the display-manager.service unit |
| Auto-start & optional autologin| TTY1 auto-start via `.bash_profile` (`~/.xinitrc` or `~/.wayland-session`); optional autologin via `enable-autologin.sh` |
| Polkit integration             | passwordless power-off/reboot/suspend/hibernate for local active `wheel` users on seat0, `udisks2` defaults for USB, correct agent for each DE |
| PAM integration                | appends `pam_kwallet5.so` (Plasma) or `pam_gnome_keyring.so` to `/etc/pam.d/login` with one-time backup |
| GPG Agent Integration          | starts `gpg-agent`, sets `SSH_AUTH_SOCK` when `enable-ssh-support` is set, and refreshes its tty via `~/.gpg-agent-kwallet` (Plasma) or `~/.gpg-agent-gnome` |
| Documentation                  | `README.md`, `docs/`                                        |

---
See `docs/` for technical details and customization tips.
