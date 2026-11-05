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
# Or preview the resolved installation without sudo or changes:
# bash install.sh --dry-run --de i3
# Or fail instead of prompting for sudo credentials (for unattended installs):
# bash install.sh --non-interactive --de i3
# Or configure an existing desktop without installing packages:
# bash install.sh --no-packages --de i3
# Or skip keyring packages and PAM keyring setup (for autologin or keyring-free setups):
# bash install.sh --no-keyring --de i3
# Or log in on TTY1 without a password (no keyring unlock) in the same run:
# bash install.sh --no-keyring --autologin --de i3
# Or create ~/.config/lightxdm/.xinitrc-<id> to customize before installing (no sudo):
# bash install.sh --init-template --de i3
# Or initialize a custom X11 template from its installed session entry:
# bash install.sh --init-template --de openbox --from-session /usr/share/xsessions/openbox.desktop
# Or initialize a custom Wayland template from its installed session entry:
# bash install.sh --init-template --wayland --de hyprland --from-session /usr/share/wayland-sessions/hyprland.desktop
# Or create a custom Wayland template, edit it, then configure an installed compositor:
# bash install.sh --init-template --wayland --de sway
# bash install.sh --no-packages --de sway
# Or use KWallet for that custom session instead of GNOME Keyring:
# bash install.sh --no-packages --de sway --keyring kwallet
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
- Pass `--dry-run --de <id>` to preview the resolved desktop and template source, dotfile destinations (and removal of an existing Wayland launcher for X11), packages, PAM keyring additions and removals, GNOME session-type block, enabled display managers to disable, and whether TTY1 autologin would be enabled. It exits before privilege checks, never calls `sudo`, and writes no files. It requires `--de`; `--no-packages`, `--keyring`, `--no-keyring` and `--autologin` apply as usual, including the custom-session requirements below. Decisions that depend on unreadable files show `unknown (needs root)`. Use it separately from `--list-packages` and `--init-template`.
- Pass `--non-interactive --de <id>` for unattended installation. Every sudo call fails immediately if credentials are unavailable, including if cached credentials expire during installation. Use cached credentials or passwordless sudo.
- Pass `--no-packages` (optionally with `--de <id>`) to skip all package installation when you already have the required packages. Before changing dotfiles, PAM or display managers, the installer checks session commands (also after package installation). For X11, `startx` and the plain command name in the selected template's last `exec ` line must be on PATH. For Wayland, every absolute path before the first option (a word starting with `-`) on that line must be executable, and a plain command name such as `sway` must be on PATH; `startx` is not required. Both command-name checks include `~/.local/bin` on PATH. Templates without a simple `exec` command skip the template-command check. Dotfiles, PAM and display manager setup then run.
- Pass `--init-template --de <id>` without sudo to create an editable template: a copy of the bundled template for a built-in id, or the i3 X11 template with the session id and `exec` command swapped for a custom one. It creates `~/.config/lightxdm/.xinitrc-<id>`, or `.wayland-session-<id>` for Plasma, GNOME, and Budgie. These user templates override the bundled templates. For a custom Wayland compositor, add `--wayland` as described below. Existing files are never overwritten.
- Add `--from-session <path>` to `--init-template --de <custom-id>` to initialize a custom template from an installed session entry, for example `bash install.sh --init-template --de openbox --from-session /usr/share/xsessions/openbox.desktop`. Only its `[Desktop Entry]` group is read: `Exec` supplies the command and arguments, and the first semicolon-separated `DesktopNames` entry supplies `XDG_CURRENT_DESKTOP` (the custom id is used when absent). `DESKTOP_SESSION` stays the custom id. For X11, the rest comes from the i3 template; add `--wayland` for a Wayland template, for example `bash install.sh --init-template --wayland --de hyprland --from-session /usr/share/wayland-sessions/hyprland.desktop`. `Exec` supports whitespace-separated literal arguments and whole double-quoted words, with shell characters preserved literally through Bash quoting. Field codes such as `%f` and `%U`, backslash escapes, single-quoted words, and incomplete or joined quotes are refused before creating a template. A missing or empty `Exec` is also refused. This flag requires a custom id and cannot be combined with installation options; existing templates are never overwritten.
- Pass `--keyring <gnome|kwallet>` with `--de <custom-id> --no-packages` to choose the PAM keyring backend for a custom session. The default is GNOME Keyring. Built-in desktops refuse this flag, as do `--no-keyring` and `--init-template` combinations; invalid combinations stop before privilege checks or changes.
- Pass `--no-keyring` (combinable with `--de <id>`, `--list-packages`, and `--no-packages`) to omit `gnome-keyring` and `kwallet-pam` from package installation and skip `/etc/pam.d/login` keyring setup. GNOME's separate session-type PAM block is still installed.
- `--no-polkit-rule` is still accepted for older scripts but has no effect: lightXDM installs no Polkit rule.
- Copies dotfiles to your home: `.bash_profile`, the session template as `~/.xinitrc` (X11 sessions) or `~/.wayland-session` (Wayland sessions, including custom compositors), the gpg-agent helper (`~/.gpg-agent-kwallet` for Plasma, `~/.gpg-agent-gnome` otherwise), and `~/.config/autostart/lightxdm-gpg-agent-tty.desktop`, which refreshes gpg-agent's display inside the session ([gpg-agent.md](gpg-agent.md)); `uninstall.sh` removes it like the other dotfiles.
- Appends PAM lines to `/etc/pam.d/login` (unless `--no-keyring` is passed; after a one-time backup at `/etc/pam.d/login.lightxdm.bak`; installing another desktop or choosing a different backend replaces the keyring lines lightXDM added for the previous one, and `uninstall.sh` removes the lines lightXDM added and restores the backup when nothing else changed, otherwise it keeps your other edits and leaves the backup for review) for keyring auto-unlock: KWallet (`pam_kwallet5.so`) for Plasma and custom sessions with `--keyring kwallet`, GNOME Keyring (`pam_gnome_keyring.so`) otherwise.
- For GNOME only, inserts a [session-type PAM block](#gnome-session-requirements) before the first session line, including with `--no-keyring`.
- Installs no Polkit rule: systemd already allows power-off, reboot, suspend, and hibernate in an active local session (`uninstall.sh` removes the `49-nopasswd.rules` older versions installed), while USB mounting uses `udisks2` defaults.
- Your DE will start automatically on TTY1 after login—no need to run 'startx'.

### Custom sessions

Custom ids use `~/.config/lightxdm/.wayland-session-<id>` when present, otherwise `~/.config/lightxdm/.xinitrc-<id>` for X11. If both exist, the installer refuses before making changes and names both files; keep only the template you want. Custom ids must contain only lowercase ASCII letters, digits, `_` and `-`, with no leading hyphen. They require `--no-packages`: install the compositor or window manager and its dependencies yourself. PAM uses GNOME Keyring by default (also selectable with `--keyring gnome`), or choose `--keyring kwallet` for KWallet. Install the matching `gnome-keyring` or `kwallet-pam` package yourself; the installer warns if its PAM module is missing. Pass `--no-keyring` to skip keyring setup instead.

Before changing dotfiles, PAM or display managers, `install.sh` checks a Bash template's syntax with `bash -n` without executing it.

For example, create and edit a Sway template, then install it:

```sh
bash install.sh --init-template --wayland --de sway
# Edit ~/.config/lightxdm/.wayland-session-sway as needed.
bash install.sh --no-packages --de sway
# To unlock KWallet for KDE applications in this session (install kwallet-pam first):
bash install.sh --dry-run --no-packages --de sway --keyring kwallet
bash install.sh --no-packages --de sway --keyring kwallet
```

`--wayland` is accepted only with `--init-template` and a custom id. Plasma, GNOME, and Budgie already have Wayland templates; the six built-in X11 ids also refuse this flag. The generated file has mode `755`, exports `DESKTOP_SESSION=<id>`, `XDG_CURRENT_DESKTOP=<id>` and `XDG_SESSION_TYPE=wayland`, sources `~/.gpg-agent-gnome` when present, and ends with `exec <id>`. A compositor that does not run XDG autostart entries needs `gpg-connect-agent updatestartuptty /bye` in its own startup, or SSH passphrase prompts go to TTY1 ([gpg-agent.md](gpg-agent.md)). Edit that line if the executable differs from your id, for example `exec Hyprland` for a `hyprland` id. A missing plain command stops installation before configuration. For custom X11, use `--init-template --de dwm` and then `--no-packages --de dwm` instead.

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
1. **Default (Password Login + Keyring Auto-Unlock):** Type your password on TTY1; the desktop starts automatically and the keyring unlocks through PAM (KWallet on Plasma and custom sessions with `--keyring kwallet`, GNOME Keyring otherwise).
2. **Optional Autologin (`enable-autologin.sh`):** Run `sudo bash enable-autologin.sh YOURUSER` (`--disable` to revert; changes apply at the next login or reboot) to log in on TTY1 without a password; `bash enable-autologin.sh --status` shows the current state without sudo. Because login happens without a password, PAM cannot unlock the keyring automatically—the keyring stays locked and asks for its password in the desktop unless its password is empty (`enable-autologin.sh` prints this warning when PAM keyring lines are configured). Pass `--no-keyring` to `install.sh` (combinable with `--de <id>` and `--no-packages`) to skip installing `gnome-keyring` / `kwallet-pam` and skip adding keyring lines to `/etc/pam.d/login`—recommended for autologin users who do not use a keyring and for window-manager setups without one. If keyring unlock is already set up, `sudo bash uninstall.sh --keyring-only` removes only the keyring lines lightXDM added to `/etc/pam.d/login` and leaves everything else in place. On a new install, `bash install.sh --no-keyring --autologin` skips the keyring setup and enables autologin in one run: it calls `enable-autologin.sh` for you after the rest of the install succeeds (`--autologin` refuses to run without `--no-keyring`).

After logging in, run `bash install.sh --check-keyring gnome` in a terminal inside the desktop, without sudo or other options (use `kwallet` on Plasma and custom sessions installed with `--keyring kwallet`). It reports the collection's current state: exit code **0** means unlocked, **1** means locked, and **2** means unavailable with the reason (for example, no secret service, collection or session bus). The check asks for no password, starts no service and changes nothing.

## Uninstall

See [Uninstall in the README](../README.md#uninstall): it stays on the landing page because it re-enables display managers and edits `/etc/pam.d/login`.
