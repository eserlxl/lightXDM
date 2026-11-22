# lightXDM

[![License: GPL-3.0-or-later](https://img.shields.io/badge/License-GPL--3.0--or--later-blue.svg)](LICENSE)
[![Platform: Arch Linux](https://img.shields.io/badge/platform-Arch%20Linux-1793d1.svg)](https://archlinux.org)

Display-manager-free TTY1 login: your desktop starts and its keyring unlocks. lightXDM is for minimalists, Arch Linux users, and those who prefer a TTY1 login over SDDM/LightDM: X11 desktops start with `startx`; KDE Plasma, GNOME, and Budgie start on Wayland. The installer sets up keyring unlock through PAM and turns off display managers. `uninstall.sh` reverts these configuration changes; the packages it installed stay.

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

Or install the [`lightxdm`](https://aur.archlinux.org/packages/lightxdm) AUR package, which adds the commands and sets nothing up by itself:

```sh
yay -S lightxdm    # or: paru -S lightxdm
lightxdm-install   # same options as install.sh; after a package update, run lightxdm-update
```

It asks for your sudo password up front (again only if the package download outlasts sudo's timeout).

Reboot (log out only works when no display manager was running), log in on TTY1, and your desktop starts automatically.

## Install

You need Arch Linux (or a derivative) with systemd, and a user in the `wheel` group with working `sudo`. Without options, the installer detects your desktop (or asks which one to install); for an interactive first-run walkthrough that checks readiness before asking for `sudo`, run `bash install.sh --guided` (or `lightxdm-install --guided`). The common options:

- `--guided` (optional `--dry-run`): run `--preflight` before `sudo`, interactively choose from detected desktops, discovered custom X11/Wayland `.desktop` sessions, or all 9 built-in desktops, choose keyring vs passwordless autologin and optional `--setup-shell` integration, preview the equivalent CLI command and `--dry-run` plan, and ask confirmation before applying changes
- `--de <id>`: configure this desktop (`plasma`, `gnome`, `budgie`, `xfce`, `lxqt`, `lxde`, `mate`, `cinnamon`, `i3`, or a custom id with `--no-packages`)
- `--status` (optional `--json`): inspect the current lightXDM configuration, login-shell hook state, dotfile state, PAM lines, disabled display managers, and TTY1 autologin state without sudo or changes (`--json` emits machine-readable JSON on stdout)
- `--list-sessions` (optional `--json`): scan installed X11 and Wayland freedesktop session entries across system `/usr/share` and user `~/.local/share` (`$XDG_DATA_HOME`) directories, check executable availability, and print ready `--init-template --from-session` and `--install-session` commands without sudo or changes (`--json` emits machine-readable JSON on stdout)
- `--preflight` (optional `--json`): check user/sudo, `pacman`/`systemctl`, `getty@tty1.service`, enabled display managers, a systemd-homed account (warning for autologin), login shell (recommending `--setup-shell <zsh|fish>` alongside `--shell-snippet` when needed), existing setup, detected built-in desktops (with GNOME screen-lock notice), and ready custom sessions without sudo or changes, then print the next command (`--json` emits machine-readable JSON on stdout)
- `--doctor` (optional `--json`): verify post-install session launchers, login-shell TTY1 hooks, PAM keyring/GNOME rules, `.pacnew` drift, and systemd boot health without sudo or changes (`0` healthy, `1` issues found with recovery commands; `--json` emits machine-readable JSON on stdout)
- `--check-keyring <gnome|kwallet|auto>` (optional `--json`; `auto` picks the backend as `--setup-gpg auto` does and names it on stderr): report the existing keyring collection state from inside your desktop session without sudo or service activation (`0` unlocked, `1` locked, `2` unavailable; `--json` emits machine-readable JSON on stdout)
- `--list-packages --de <id>`: print the packages it would install, change nothing
- `--dry-run --de <id>`: preview every change the install would make (dotfiles, packages, PAM, display managers), change nothing
- `--non-interactive --de <id>`: for unattended installs, fail instead of prompting for sudo
- `--no-packages`, `--no-keyring`: skip packages or PAM keyring setup
- `--no-keyring --autologin`: log in on TTY1 without a password, in the same run
- `--login-mode <password|autologin>` (optional `--dry-run`, `--non-interactive`, and with `password`: `--de <id>`, `--keyring <gnome|kwallet>`): switch an existing setup between password login with PAM keyring unlock and passwordless TTY1 autologin without touching dotfiles, packages, shell hooks, or display managers
- `--update`: apply a newer lightXDM to the last install with its saved choices, changing only what lightXDM installed and you left as it was (home files you edited stay, with the new template beside them as `*.lightxdm-new`; packages you removed stay removed and display managers you enabled again stay enabled; PAM lines you removed or commented out stay that way, while lines a `.pacnew` merge removed come back; autologin stays as it is)
- `--dotfile-updates <diff|accept|dismiss|interactive>` (optional `--dry-run`): inspect diffs (`diff`), safely adopt (`accept`, backing up edited dotfiles as `*.lightxdm-edited*`, setting each file's expected mode, and updating `installed-dotfiles`), interactively choose per file (`interactive`), or discard (`dismiss`) pending `*.lightxdm-new` files left by `--update` without sudo
- `--recover` (optional `--dry-run`, `--de <id>`, `--setup-shell <zsh|fish|auto>`): restore broken or paused home session dotfiles (`~/.bash_profile`, `~/.xinitrc` / `~/.wayland-session`, GPG helper) from validated templates without sudo or package/PAM/systemd changes, saving any edits as `*.lightxdm-edited*` and clearing `~/.config/lightxdm/no-autostart`
- `--fix` (optional `--dry-run`, `--non-interactive`, `--de <id>`): automatically diagnose and repair broken/paused home dotfiles, missing non-bash TTY1 shell hooks, missing/partial PAM keyring or GNOME session-type rules, masked/disabled `getty@tty1.service`, and re-enabled display managers; preserves valid user-edited templates when only system state needs repair, uses `sudo` only when system changes or root PAM checks are required, and re-runs `--doctor` (`0` healthy, `1` remaining issues)
- `--setup-shell <zsh|fish|auto>`: idempotently install or update the managed `# >>> lightXDM TTY1 auto-start >>>` block in `~/.zprofile` (`$ZDOTDIR/.zprofile` when inside `$HOME`) or `~/.config/fish/config.fish` (`$XDG_CONFIG_HOME/fish/config.fish` when inside `$HOME`), recording non-default paths in `${XDG_STATE_HOME:-~/.local/state}/lightxdm/installed-shell-hooks` (standalone with optional `--dry-run`, or combined with install / `--recover`; `uninstall.sh` removes only lightXDM's fenced block)
- `--setup-gpg <gnome|kwallet|auto|remove>` (optional `--gpg-ssh`, `--dry-run`): configure or remove a fenced `# >>> lightXDM GPG setup >>>` block in `~/.gnupg/gpg-agent.conf` (`$GNUPGHOME/gpg-agent.conf` when inside `$HOME`) with `/usr/bin/pinentry-gnome3` or `/usr/bin/pinentry-qt` (plus `enable-ssh-support` with `--gpg-ssh`) and reload `gpg-agent` via `gpgconf --kill gpg-agent` without sudo (standalone, or combined with install)
- `--pam-only --de <id>`: add only lightXDM's lines to `/etc/pam.d/login` (keyring unlock, and GNOME's session-type block), touching nothing else except recording that keyring in the saved choices
- `--init-template --de <id>`: create `~/.config/lightxdm/.xinitrc-<id>` (or `.wayland-session-<id>` for Plasma, GNOME, and Budgie) to edit first (no sudo)
- `--init-template --wayland --de sway`: create `~/.config/lightxdm/.wayland-session-sway` for a custom Wayland compositor; edit it, then install with `--no-packages --de sway`. `--wayland` requires `--init-template` or `--install-session` and a custom id; keep only one X11 or Wayland template per custom id.
- `--install-session <path>`: validate an installed X11/Wayland `.desktop` session entry, create `~/.config/lightxdm/` template if missing (preserving existing edits on rerun), and install with `--no-packages` in one command (auto-derives `--de <custom-id>` and infers Wayland under `wayland-sessions`; optional `--de <custom-id>`, `--wayland`, `--uwsm`, `--dry-run`, `--non-interactive`, `--keyring`, `--no-keyring`, `--autologin`, `--setup-shell`, `--setup-gpg`, `--gpg-ssh`)

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
2. **Autologin:** `sudo bash enable-autologin.sh YOURUSER` (or `bash install.sh --no-keyring --autologin`, or `bash install.sh --login-mode autologin` on an existing install; `bash install.sh --login-mode password` switches back) logs you in without a password, so the keyring cannot unlock automatically (`bash enable-autologin.sh --status` or `--status --json` inspects saved autologin state without sudo). See [docs/startx-autologin.md](docs/startx-autologin.md).

## Before you install

**GNOME cannot lock the screen without GDM.** It shows “Screen Lock disabled — Screen Locking requires the GNOME display manager”. lightXDM disables GDM along with other display managers.

> **Important:**
> - **Do NOT run `install.sh` as root or with `sudo`.** Run it as your regular user. The script will use `sudo` internally when needed.
> - Your user **must be in the `wheel` group** and have working `sudo` privileges. If not, see the error messages for instructions on how to add your user to the `wheel` group and configure `sudo`.
> - If you run `sudo bash install.sh` or run as root, the script will exit with an error (only `--help`, `--status`, `--list-sessions`, `--list-packages`, `--recover --dry-run`, `--fix --dry-run`, `--login-mode <...> --dry-run`, `--dotfile-updates diff`, `--dotfile-updates <...> --dry-run`, `--setup-shell <...> --dry-run`, `--setup-gpg <...> --dry-run`, `--shell-snippet`, and `--dry-run` work without the root check, while `--preflight` and `--doctor` inspect your regular user's setup and must be run as your regular user; also run `--status`, `--recover`, `--fix`, `--login-mode`, `--dotfile-updates`, `--setup-shell`, `--setup-gpg`, and `--dry-run` as your regular user for your own home directory).

What the installer changes outside your home, so nothing comes as a surprise:

- It **disables enabled display managers** (SDDM, LightDM, GDM, LXDM, `ly@tty1`, and whatever `display-manager.service` points to), so the next boot ends at a TTY1 login. `uninstall.sh` re-enables them.
- It **appends keyring lines to `/etc/pam.d/login`** (backup at `/etc/pam.d/login.lightxdm.bak`) unless you pass `--no-keyring`. If a util-linux update leaves `/etc/pam.d/login.pacnew` and you take it over that file, run `lightxdm-update` afterwards (`bash install.sh --update` from a git clone) to bring the lines back (the AUR package's pacman hook reminds you).
- For **GNOME only**, it inserts a PAM block before the first session line in `/etc/pam.d/login`, using `/etc/lightxdm/gnome-session-type.conf` to register a Wayland session **only for the installing user on TTY1**, including with `--no-keyring` (if you merge `/etc/pam.d/login.pacnew`, run `lightxdm-update` to bring the block back too; the package's pacman hook reminds you). Installing another desktop or running `uninstall.sh` removes the block and config; `uninstall.sh --keyring-only` keeps them. See [why GNOME needs this](docs/installation.md#gnome-session-requirements).
- It installs no Polkit rule: systemd already allows power-off, reboot, suspend and hibernate in an active local session. Older versions installed `/etc/polkit-1/rules.d/49-nopasswd.rules`; `uninstall.sh` still removes it (or restores the rule it replaced), and `--no-polkit-rule` is accepted but no longer needed.

In your home it replaces `~/.bash_profile` and `~/.xinitrc` (or `~/.wayland-session` for Wayland sessions), keeping your copies as `*.lightxdm.bak`. A later `lightxdm-install` replaces them again and keeps your edits only as `*.lightxdm-edited` copies, while `lightxdm-update` leaves a file you edited alone and puts the new template beside it as `*.lightxdm-new`. Put shell settings in `~/.bashrc` (lightXDM's `~/.bash_profile` reads it) and session changes in a template under `~/.config/lightxdm/` (`install.sh --init-template --de <id>`). An executable `~/.wayland-session` takes precedence over `startx`; installing an X11 desktop moves it aside and removes it, and uninstall restores it. See [session backups](docs/installation.md#session-files-and-backups). If your desktop keeps crashing, TTY1 auto-start pauses itself; see [Recovery](docs/startx-autologin.md#recovery).

## Uninstall

**With the AUR package, run `sudo lightxdm-uninstall` first and `sudo pacman -R lightxdm` after it: removing the package alone leaves the setup in place.**

Run `sudo bash uninstall.sh` (`sudo lightxdm-uninstall` with the package) from your user account to restore backups and remove lightXDM configuration (pass `--dry-run` first to preview what would change without modifying anything, or `--dry-run --json` for machine-readable JSON on stdout). Packages the installer installed are not removed. Display managers disabled by the installer are re-enabled for the next boot, using `/etc/lightxdm/disabled-display-managers`; the state file is then removed (a display manager that was removed or masked since install is skipped with a warning; any other unit that fails to re-enable stays recorded there and uninstall exits with an error). Other display managers are left unchanged. To use a different state path, set `DM_STATE_FILE` to the same path for both scripts (pass it through sudo when uninstalling). To keep everything else and remove only the keyring lines lightXDM added to `/etc/pam.d/login` (for example to switch to autologin), run `sudo bash uninstall.sh --keyring-only` (`--dry-run` and `--dry-run --json` work with it too).

## Documentation

User guides:

| Guide | What it covers |
|---|---|
| [Installation](docs/installation.md) | the AUR package, every installer step and option, login modes, uninstall details |
| [Features](docs/features.md) | why lightXDM exists and what it sets up per desktop |
| [TTY1 auto-start and autologin](docs/startx-autologin.md) | how the desktop starts, autologin, zsh/fish, recovery |
| [KWallet auto-unlock](docs/kwallet-autounlock.md) | KWallet unlock through PAM on Plasma |
| [GPG agent](docs/gpg-agent.md) | `gpg-agent` startup and SSH support |
| [Polkit](docs/polkit-support.md) | agents, systemd's power defaults, and the rule older versions installed |

Maintainer docs:

| Guide | What it covers |
|---|---|
| [Development](docs/development.md) | project layout, lint and test commands, release steps |

## Development

```sh
bash lint.sh               # ShellCheck on every script
bash tests/run.sh          # behavior suite (--strict also fails on skipped checks)
bash tests/docker-arch.sh  # package lists and real PAM checks in an Arch container (needs Docker)
bash tests/qemu-arch.sh    # real TTY1 password logins in QEMU VMs (needs Docker and KVM; slow)
```

`lint.sh` and `tests/run.sh` must pass for every change; run the Docker and QEMU tests too before a release. [docs/development.md](docs/development.md) describes the QEMU test and the release steps.

## License

lightXDM is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version (GPL-3.0-or-later). See [LICENSE](LICENSE).
