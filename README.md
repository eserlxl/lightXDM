# lightXDM

A lightweight, display-manager-free desktop environment for minimalists, Arch Linux users, and those who prefer `startx` over SDDM/LightDM.

## Purpose & Target Users
- **Minimal RAM/boot time**: No display manager, no bloat, just your DE.
- **Session auto-start, with Keyring auto-unlock or optional Autologin**: Choose between password login on TTY1 with automatic keyring unlock via PAM (default) or passwordless TTY1 autologin via `enable-autologin.sh` across KDE Plasma, GNOME, XFCE, LXQt, LXDE, MATE, Cinnamon, Budgie, and i3.
- **Full Polkit & PAM integration**: `udisks2` defaults for USB mounting, passwordless power actions for local active `wheel` users, and PAM keyring unlock.
- **Systemd compatible**: Works on Arch Linux and derivatives.

**Target users:**
- Minimalists
- Arch Linux users
- Display manager haters
- Tinkerers who want full control

## Why not SDDM/LightDM?
- No extra daemons or RAM usage
- Faster boot (no DM startup delay)
- Simpler troubleshooting (all config in dotfiles)
- No graphical login: boots to TTY1, and your DE auto-starts after login—no need to run `startx` manually

## Quick Install (Arch Linux)
```sh
# Clone and run the installer
cd ~
git clone https://github.com/eserlxl/lightXDM.git
cd lightXDM
bash install.sh
```

> **Important:**
> - **Do NOT run `install.sh` as root or with `sudo`.** Run it as your regular user. The script will use `sudo` internally when needed.
> - Your user **must be in the `wheel` group** and have working `sudo` privileges. If not, see the error messages for instructions on how to add your user to the `wheel` group and configure `sudo`.
> - If you run `sudo bash install.sh` or run as root, the script will exit with an error.

- **Detects your installed DE** (Plasma, GNOME, XFCE, LXQt, LXDE, MATE, Cinnamon, Budgie, or i3).
- If no DE is found, it **prompts you to choose one** to install.
- Installs the minimal required packages for your chosen DE, including the correct polkit agent:
  - polkit-kde-agent for KDE Plasma
  - lxqt-policykit for LXQt
  - polkit-gnome for all other supported DEs.
- Copies dotfiles to your home, including the correct `.xinitrc-<de>` for your DE.
- Appends PAM lines to `/etc/pam.d/login` (after a one-time backup at `/etc/pam.d/login.lightxdm.bak`, which `uninstall.sh` restores) for KWallet (`pam_kwallet5.so` on Plasma) or GNOME Keyring (`pam_gnome_keyring.so` on every other supported desktop) auto-unlock.
- Configures Polkit for passwordless power-off, reboot, and suspend for local active `wheel` users, while USB mounting uses `udisks2` defaults.
- Your DE will start automatically on TTY1 after login—no need to run 'startx'.

### Two Login Modes
1. **Default (Password Login + Keyring Auto-Unlock):** Type your password on TTY1; the desktop starts automatically and your keyring (KWallet on Plasma, GNOME Keyring on all other desktops) unlocks through PAM.
2. **Optional Autologin (`enable-autologin.sh`):** Run `sudo bash enable-autologin.sh YOURUSER` (`--disable` to revert; changes apply at the next login or reboot) to log in on TTY1 without a password. Because login happens without a password, PAM cannot unlock the keyring automatically—the keyring stays locked and asks for its password in the desktop unless its password is empty (`enable-autologin.sh` prints this warning).

## Features

lightXDM has recently expanded to support many desktop environments and improved its installation workflow:

### Multi-Desktop Environment Support
- **Automatic Detection:** The installer detects if KDE Plasma, GNOME, XFCE, LXQt, LXDE, MATE, Cinnamon, Budgie, or i3 is already installed.
- **User Choice:** If no supported DE is found, the installer prompts you to select and install one (KDE Plasma, GNOME, XFCE, LXQt, LXDE, MATE, Cinnamon, Budgie, or i3).
- **Minimal Install:** Only the essential packages for your chosen DE are installed, including the correct polkit agent (polkit-kde-agent for Plasma, lxqt-policykit for LXQt, polkit-gnome for all others), keeping the system lightweight.
- **Dotfiles:** The correct `.xinitrc-<de>` and `.bash_profile` are copied for your DE, ensuring seamless session start on TTY1.

### Display Manager Independence
- **No Display Manager Needed:** The script disables any installed display managers (SDDM, LightDM, GDM, LXDM) to ensure a pure TTY+startx workflow.
- **Auto-Start on TTY1:** After login on TTY1, your desktop environment starts automatically—no need to run `startx` manually. Optional passwordless autologin is available via `enable-autologin.sh` (with the trade-off that the keyring cannot unlock automatically unless its password is empty).

### System Integration
- **Polkit & PAM:** The installer installs a Polkit rule granting passwordless power-off, reboot, and suspend to local active `wheel` users (leaving USB mounting to `udisks2` defaults), and appends PAM lines to `/etc/pam.d/login` (with a one-time backup `/etc/pam.d/login.lightxdm.bak` restored by `uninstall.sh`) for KWallet (`pam_kwallet5.so` on Plasma) or GNOME Keyring (`pam_gnome_keyring.so` on every other desktop) auto-unlock.
- **GPG Agent Integration**: Seamlessly integrates `gpg-agent` with KWallet (for Plasma) or GNOME Keyring (for other DEs) for secure, passwordless GPG and SSH operations.
- **Documentation:** See the `docs/` directory for technical details on KWallet auto-unlock, Polkit integration, and autologin setup.

### Feature Overview

| Feature                        | Status                                      |
|--------------------------------|-----------------------------------------------------------|
| KDE Plasma support             | auto-detect/install, KWallet, polkit-kde-agent, dotfiles      |
| GNOME support                  | auto-detect/install, GNOME Keyring, polkit-gnome, dotfiles    |
| XFCE support                   | auto-detect/install, GNOME Keyring, polkit-gnome, dotfiles    |
| LXQt support                   | auto-detect/install, GNOME Keyring, lxqt-policykit, dotfiles   |
| LXDE support                   | auto-detect/install, GNOME Keyring, polkit-gnome, dotfiles    |
| MATE support                   | auto-detect/install, GNOME Keyring, polkit-gnome, dotfiles    |
| Cinnamon support               | auto-detect/install, GNOME Keyring, polkit-gnome, dotfiles    |
| Budgie support                 | auto-detect/install, GNOME Keyring, polkit-gnome, dotfiles    |
| i3 support                     | auto-detect/install, GNOME Keyring, polkit-gnome, dotfiles    |
| No DE installed                | Prompts user, installs selected DE                                |
| Display manager free           | disables SDDM, LightDM, GDM, LXDM                           |
| Auto-start & optional autologin| TTY1 auto-start via `.bash_profile`/`.xinitrc-*`; optional autologin via `enable-autologin.sh` |
| Polkit integration             | passwordless power-off/reboot/suspend for local active `wheel` users, `udisks2` defaults for USB, correct agent for each DE |
| PAM integration                | appends `pam_kwallet5.so` (Plasma) or `pam_gnome_keyring.so` (all other DEs) to `/etc/pam.d/login` with one-time backup |
| GPG Agent Integration          | via `~/.gpg-agent-kwallet` for Plasma or `~/.gpg-agent-gnome` for other DEs |
| Documentation                  | `README.md`, `docs/`                                        |

---
See `docs/` for technical details and customization tips.

## Project Structure
```
lightXDM/
├── README.md
├── install.sh
├── enable-autologin.sh
├── uninstall.sh
├── lint.sh
├── dotfiles/
│   ├── .gpg-agent-gnome
│   ├── .gpg-agent-kwallet
│   ├── .xinitrc-plasma
│   ├── .xinitrc-gnome
│   ├── .xinitrc-xfce
│   ├── .xinitrc-lxqt
│   ├── .xinitrc-lxde
│   ├── .xinitrc-mate
│   ├── .xinitrc-cinnamon
│   ├── .xinitrc-budgie
│   ├── .xinitrc-i3
│   └── .bash_profile
├── polkit/
│   └── 49-nopasswd.rules
├── docs/
│   ├── gpg-agent.md
│   ├── kwallet-autounlock.md
│   ├── polkit-support.md
│   └── startx-autologin.md
├── tests/
│   └── run.sh
└── LICENSE
```
