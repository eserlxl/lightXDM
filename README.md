# lightXDM

[![License: GPL-3.0-or-later](https://img.shields.io/badge/License-GPL--3.0--or--later-blue.svg)](LICENSE)
[![Platform: Arch Linux](https://img.shields.io/badge/platform-Arch%20Linux-1793d1.svg)](https://archlinux.org)

A lightweight, display-manager-free desktop environment for minimalists, Arch Linux users, and those who prefer a TTY1 login over SDDM/LightDM: X11 desktops start with `startx`; KDE Plasma, GNOME, and Budgie start on Wayland. Log in on TTY1 and your desktop starts; the installer sets up keyring unlock through PAM and turns off display managers. `uninstall.sh` reverts these configuration changes; the packages it installed stay.

## Contents

- [Quick start](#quick-start)
- [Install](#install)
- [Supported desktops](#supported-desktops)
- [Login modes](#login-modes)
- [Before you install](#before-you-install)
- [Uninstall](#uninstall)
- [Documentation](#documentation)
- [Development](#development)
- [License](#license)

## Quick start

```sh
git clone https://github.com/eserlxl/lightXDM.git
cd lightXDM
bash install.sh   # as your regular user, not root
```

It asks for your sudo password up front (again only if the package download outlasts sudo's timeout).

Reboot (log out only works when no display manager was running), log in on TTY1, and your desktop starts automatically.

## Install

You need Arch Linux (or a derivative) with systemd, and a user in the `wheel` group with working `sudo`. Without options, the installer detects your desktop (or asks which one to install). The common options:

- `--de <id>`: configure this desktop (`plasma`, `gnome`, `budgie`, `xfce`, `lxqt`, `lxde`, `mate`, `cinnamon`, `i3`, or a custom id with `--no-packages`)
- `--list-packages --de <id>`: print the packages it would install, change nothing
- `--dry-run --de <id>`: preview every change the install would make (dotfiles, packages, PAM, display managers), change nothing
- `--non-interactive --de <id>`: for unattended installs, fail instead of prompting for sudo
- `--no-packages`, `--no-keyring`: skip packages or PAM keyring setup
- `--no-keyring --autologin`: log in on TTY1 without a password, in the same run
- `--init-template --de <id>`: create `~/.config/lightxdm/.xinitrc-<id>` (or `.wayland-session-<id>` for Plasma, GNOME, and Budgie) to edit first (no sudo)
- `--init-template --wayland --de sway`: create `~/.config/lightxdm/.wayland-session-sway` for a custom Wayland compositor; edit it, then install with `--no-packages --de sway`. `--wayland` requires `--init-template` and a custom id; keep only one X11 or Wayland template per custom id.

`bash install.sh --help` lists every option. [docs/installation.md](docs/installation.md) explains each step and option in full.

## Supported desktops

| Desktop | Starts with | Keyring unlocked by PAM | Polkit agent |
|---|---|---|---|
| KDE Plasma (`plasma`) | Wayland, through `~/.wayland-session` | KWallet | polkit-kde-agent |
| GNOME (`gnome`) | Wayland, through `~/.wayland-session`; **no screen lock without GDM** | GNOME Keyring | built into GNOME Shell |
| Budgie (`budgie`) | Wayland, through `~/.wayland-session` | GNOME Keyring | budgie-polkit-dialog |
| XFCE, i3 | `startx`, through `~/.xinitrc` | GNOME Keyring | polkit-gnome (started by the template) |
| LXDE (`lxde`) | `startx`, through `~/.xinitrc` | GNOME Keyring | lxpolkit (from lxsession) |
| MATE (`mate`) | `startx`, through `~/.xinitrc` | GNOME Keyring | mate-polkit |
| Cinnamon (`cinnamon`) | `startx`, through `~/.xinitrc` | GNOME Keyring | built into Cinnamon |
| LXQt (`lxqt`) | `startx`, through `~/.xinitrc` | GNOME Keyring | lxqt-policykit |
| Your own window manager | X11 or Wayland, with your template and `--no-packages` | GNOME Keyring by default, KWallet with `--keyring kwallet`, or none with `--no-keyring` | your choice |

Wayland desktops do not install `xorg-server` or `xorg-xinit`. See [GNOME session requirements](docs/installation.md#gnome-session-requirements) before choosing GNOME.

## Login modes

1. **Password login (default):** type your password on TTY1; the desktop starts and PAM unlocks your keyring with that password.
2. **Autologin:** `sudo bash enable-autologin.sh YOURUSER` (or `bash install.sh --no-keyring --autologin`) logs you in without a password, so the keyring cannot unlock automatically. See [docs/startx-autologin.md](docs/startx-autologin.md).

## Before you install

**GNOME cannot lock the screen without GDM.** It shows “Screen Lock disabled — Screen Locking requires the GNOME display manager”. lightXDM disables GDM along with other display managers.

> **Important:**
> - **Do NOT run `install.sh` as root or with `sudo`.** Run it as your regular user. The script will use `sudo` internally when needed.
> - Your user **must be in the `wheel` group** and have working `sudo` privileges. If not, see the error messages for instructions on how to add your user to the `wheel` group and configure `sudo`.
> - If you run `sudo bash install.sh` or run as root, the script will exit with an error (only `--help`, `--list-packages` and `--dry-run` work as root, since they change nothing; run `--dry-run` as your regular user to preview your own files).

What the installer changes outside your home, so nothing comes as a surprise:

- It **disables enabled display managers** (SDDM, LightDM, GDM, LXDM, `ly@tty1`, and whatever `display-manager.service` points to), so the next boot ends at a TTY1 login. `uninstall.sh` re-enables them.
- It **appends keyring lines to `/etc/pam.d/login`** (backup at `/etc/pam.d/login.lightxdm.bak`) unless you pass `--no-keyring`.
- For **GNOME only**, it inserts a PAM block before the first session line in `/etc/pam.d/login`, using `/etc/lightxdm/gnome-session-type.conf` to register a Wayland session **only for the installing user on TTY1**, including with `--no-keyring`. Installing another desktop or running `uninstall.sh` removes the block and config; `uninstall.sh --keyring-only` keeps them. See [why GNOME needs this](docs/installation.md#gnome-session-requirements).
- It installs no Polkit rule: systemd already allows power-off, reboot, suspend and hibernate in an active local session. Older versions installed `/etc/polkit-1/rules.d/49-nopasswd.rules`; `uninstall.sh` still removes it (or restores the rule it replaced), and `--no-polkit-rule` is accepted but no longer needed.

In your home it replaces `~/.bash_profile` and `~/.xinitrc` (or `~/.wayland-session` for Wayland sessions), keeping your copies as `*.lightxdm.bak`. An executable `~/.wayland-session` takes precedence over `startx`; installing an X11 desktop moves it aside and removes it, and uninstall restores it. See [session backups](docs/installation.md#session-files-and-backups). If your desktop keeps crashing, TTY1 auto-start pauses itself; see [Recovery](docs/startx-autologin.md#recovery).

## Uninstall

Run `sudo bash uninstall.sh` from your user account to restore backups and remove lightXDM configuration. Packages the installer installed are not removed. Display managers disabled by the installer are re-enabled for the next boot, using `/etc/lightxdm/disabled-display-managers`; the state file is then removed (a display manager that was removed or masked since install is skipped with a warning; any other unit that fails to re-enable stays recorded there and uninstall exits with an error). Other display managers are left unchanged. To use a different state path, set `DM_STATE_FILE` to the same path for both scripts (pass it through sudo when uninstalling). To keep everything else and remove only the keyring lines lightXDM added to `/etc/pam.d/login` (for example to switch to autologin), run `sudo bash uninstall.sh --keyring-only`.

## Documentation

User guides:

| Guide | What it covers |
|---|---|
| [Installation](docs/installation.md) | every installer step and option, login modes, uninstall details |
| [Features](docs/features.md) | why lightXDM exists and what it sets up per desktop |
| [TTY1 auto-start and autologin](docs/startx-autologin.md) | how the desktop starts, autologin, zsh/fish, recovery |
| [KWallet auto-unlock](docs/kwallet-autounlock.md) | KWallet unlock through PAM on Plasma |
| [GPG agent](docs/gpg-agent.md) | `gpg-agent` startup and SSH support |
| [Polkit](docs/polkit-support.md) | agents, systemd's power defaults, and the rule older versions installed |

Maintainer docs:

| Guide | What it covers |
|---|---|
| [Development](docs/development.md) | project layout, lint and test commands |

## Development

```sh
bash lint.sh               # ShellCheck on every script
bash tests/run.sh          # behavior suite (--strict also fails on skipped checks)
bash tests/docker-arch.sh  # package lists and real PAM checks in an Arch container (needs Docker)
bash tests/qemu-arch.sh    # real TTY1 password logins in QEMU VMs (needs Docker and KVM; slow)
```

`lint.sh` and `tests/run.sh` must pass for every change; run the Docker and QEMU tests too before a release. [docs/development.md](docs/development.md) describes the QEMU test.

## License

lightXDM is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version (GPL-3.0-or-later). See [LICENSE](LICENSE).
