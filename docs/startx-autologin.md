# Autologin on TTY1 with startx or Wayland

lightXDM provides a display-manager-free autologin experience by:
- Logging in to TTY1 (via systemd or getty autologin)
- Using `.bash_profile` to auto-launch the desktop only on TTY1: `~/.wayland-session` when it is executable (Plasma, GNOME, and Budgie on Wayland), otherwise `startx`

## How it works
- If you log in on TTY1 (an interactive login shell), `.bash_profile` runs `~/.wayland-session` or `startx` automatically (never from inside an X11 or Wayland session). Non-interactive login shells such as `su - user -c cmd` on TTY1 run their command and do not start a desktop.
- No graphical login screen, no display manager needed.
- You get a full desktop environment session with minimal RAM and boot time.

GNOME also needs the installer's [session-type PAM block](installation.md#gnome-session-requirements), which applies only to the installing user on TTY1, including with `--no-keyring`. GNOME cannot lock the screen without GDM.

## Keyring Unlock Trade-Off
- **Default mode (password login on TTY1):** You type your password on TTY1, your desktop starts automatically, and PAM unlocks your keyring (KWallet on Plasma, GNOME Keyring on the other supported desktops; a custom session uses GNOME Keyring unless you install it with `--keyring kwallet`, see [installation.md](installation.md)) using that password.
- **Autologin mode (`agetty --autologin`):** Login happens without a password, so the PAM keyring module cannot unlock your keyring automatically. The keyring stays locked and asks for its password in the desktop unless its password is empty (`enable-autologin.sh` prints a warning when PAM keyring unlock is configured).
- **Choosing autologin without keyring unlock:** on a new install, `bash install.sh --no-keyring --autologin` skips the keyring setup and enables autologin in the same run. On an existing default install, `sudo bash uninstall.sh --keyring-only` removes only the keyring lines lightXDM added to `/etc/pam.d/login`, keeping GNOME's session-type block and config; then run `sudo bash enable-autologin.sh YOURUSER`.

## zsh and fish users
The installer writes `~/.bash_profile` by default. If your login shell is zsh or fish, either manage the fenced block automatically:
```sh
bash install.sh --setup-shell auto   # or pass zsh / fish explicitly (supports --dry-run and --recover)
```
or add the equivalent block yourself (`--setup-shell` manages `# >>> lightXDM TTY1 auto-start >>>` .. `# <<< lightXDM TTY1 auto-start <<<` markers safely and `uninstall.sh` cleans up only that fenced block). These snippets honor the `~/.config/lightxdm/no-autostart` marker (see Recovery below), but only the Bash profile pauses auto-start on its own after repeated crashes and honors `~/.config/lightxdm/session-journal`.

You can also print either snippet directly to stdout without opening this file (for example under a package install with `lightxdm-install`):
```sh
bash install.sh --shell-snippet zsh >> ~/.zprofile
mkdir -p ~/.config/fish && bash install.sh --shell-snippet fish >> ~/.config/fish/config.fish
```

zsh, in `~/.zprofile`:
```zsh
if [[ -o interactive && -z $DISPLAY && -z $WAYLAND_DISPLAY && $(tty) == /dev/tty1 && ! -e ~/.config/lightxdm/no-autostart ]]; then
  export PATH="$HOME/.local/bin:$PATH"
  if [[ -f ~/.wayland-session && -x ~/.wayland-session ]]; then
    exec ~/.wayland-session
  elif command -v startx >/dev/null 2>&1; then
    exec startx
  fi
fi
```

fish, in `~/.config/fish/config.fish`:
```fish
if status is-login; and status is-interactive; and test -z "$DISPLAY"; and test -z "$WAYLAND_DISPLAY"; and test (tty) = /dev/tty1; and not test -e ~/.config/lightxdm/no-autostart
  set -gx PATH $HOME/.local/bin $PATH
  if test -f ~/.wayland-session; and test -x ~/.wayland-session
    exec ~/.wayland-session
  else if command -q startx
    exec startx
  end
end
```

## Setup
- The installer copies `.bash_profile` and `.xinitrc` (or `.wayland-session` for Plasma, GNOME, and Budgie) to your home. Installing an X11 desktop moves any `.wayland-session` aside and removes it so `startx` can run; uninstall restores the original backup. See [session files and backups](installation.md#session-files-and-backups).
- With the installed Bash profile, you can keep autologin enabled and temporarily skip the desktop using `~/.config/lightxdm/no-autostart` (see Recovery below).
- To enable TTY1 autologin, set up a systemd override for `agetty` on tty1 for your user:

### Example: Enable Autologin on TTY1 (systemd)

1. Create an override directory:
   ```sh
   sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
   ```
2. Create the override file:
   ```sh
   sudo nano /etc/systemd/system/getty@tty1.service.d/lightxdm-autologin.conf
   ```
   Paste the following content (replace `YOURUSER` with your username):
   ```ini
   [Service]
   ExecStart=
   ExecStart=-/usr/bin/agetty --autologin YOURUSER --noclear %I $TERM
   ```
3. Reload systemd (takes effect at next login or reboot):
   ```sh
   sudo systemctl daemon-reload
   ```

**To disable autologin:**
Remove the override file and reload systemd (takes effect at next login or reboot):
```sh
sudo rm /etc/systemd/system/getty@tty1.service.d/lightxdm-autologin.conf
sudo systemctl daemon-reload
```

### Optional: Helper Script
You can use the provided `enable-autologin.sh` script to automate this setup (changes take effect at the next login or reboot). Run:
```sh
sudo bash enable-autologin.sh YOURUSER
```
This will create the override for you. If `getty@tty1.service` is masked, the script changes nothing and asks you to run `systemctl unmask getty@tty1.service`. To remove autologin, run:
```sh
sudo bash enable-autologin.sh --disable
```
To inspect the saved configuration without sudo, run:
```sh
bash enable-autologin.sh --status
bash enable-autologin.sh --status --json
```
This prints `enabled for <user> (<file>)` for the lightXDM drop-in (or an accepted legacy `override.conf`), otherwise `disabled`, or structured JSON (`"mode": "autologin-status"`, `"state": "enabled" | "disabled" | "unknown-needs-root"`, user/file details, `keyring_configured`, `dropin_files`, `warnings`, and `notes`) when `--json` is passed. It warns about other drop-ins that enable autologin or override it with a later `ExecStart=`, and, when autologin is enabled, about PAM keyring unlock lines. It exits successfully without changing files or calling `systemctl`. The status describes the saved configuration; changes take effect at the next login or reboot.

## Recovery

If the desktop (`~/.wayland-session` or `startx`) was launched on TTY1 three times within the 30 seconds before a TTY1 login (a desktop that keeps crashing right after it starts), that login automatically pauses auto-start: `.bash_profile` creates `~/.config/lightxdm/no-autostart`, clears `${XDG_STATE_HOME:-~/.local/state}/lightxdm/startx-attempts`, prints a one-line notice explaining how to resume, and loads `~/.bashrc` instead of starting the desktop. (Recent launch timestamps are kept in `${XDG_STATE_HOME:-~/.local/state}/lightxdm/startx-attempts`, dropping entries older than 30 seconds; `uninstall.sh` removes this file from the default `~/.local/state` location, but not a copy under a custom `XDG_STATE_HOME`.)

You can also create the marker manually as your user from another TTY or SSH:
```sh
mkdir -p ~/.config/lightxdm
touch ~/.config/lightxdm/no-autostart
```
While the marker exists, the installed `.bash_profile` skips the desktop launch and loads `~/.bashrc`, giving you an interactive shell on the next TTY1 login. Other TTYs are unchanged, and no edit to `~/.bash_profile` is needed.

To restore desktop auto-start at the next TTY1 login:
```sh
rm ~/.config/lightxdm/no-autostart
```

To keep the session's output, create `~/.config/lightxdm/session-journal` with `mkdir -p ~/.config/lightxdm && touch ~/.config/lightxdm/session-journal`. From the next TTY1 login, the session's stdout and stderr go to the journal; read them with `journalctl -b -t lightxdm` (or `journalctl -b -1 -t lightxdm` after a reboot). This needs `systemd-cat` (part of systemd). Plasma and GNOME start most of their components as systemd user services, which log under their own names (`journalctl --user -b`); the `lightxdm` identifier holds only what the session launcher itself prints, which on a working Plasma session can be nothing. Remove the file to send the output to the terminal again.

### Automated Diagnostics and Repair

Instead of editing files by hand, run these workflows as your regular user (previewing changes with `--dry-run` on `--recover` or `--fix`):

- **Diagnose without changing anything (`--doctor` / `--doctor --json`)**:
  ```sh
  bash install.sh --doctor
  bash install.sh --doctor --json
  ```
  Runs read-only without `sudo` and exits `0` when healthy or `1` when issues remain (`--json` emits structured JSON checks and counts on stdout). Checks the active TTY1 launcher (`~/.wayland-session` vs `startx`/`~/.xinitrc`), template syntax and commands, `bash`/`zsh`/`fish` login-shell hooks, `~/.config/lightxdm/no-autostart`, `startx-attempts`, `*.lightxdm-new` update files, PAM keyring/GNOME session-type rules and `.so` modules (including `.pacnew` state), `getty@tty1.service`, re-enabled display managers, and TTY1 autologin conflicts.

- **Restore home session dotfiles (`--recover`)**:
  ```sh
  bash install.sh --recover --dry-run
  bash install.sh --recover
  ```
  Runs without `sudo` using your saved `install-choices` (or `--de <id>`), optional `--dry-run`, and optional `--setup-shell <zsh|fish|auto>`. It validates template syntax and commands first, backs up your edited dotfiles as `*.lightxdm-edited*`, restores fresh home dotfiles (`~/.bash_profile`, `~/.xinitrc` or `~/.wayland-session`, GPG helper, autostart desktop entry), removes any X11-shadowing `~/.wayland-session` and stale `*.lightxdm-new` files, clears `~/.config/lightxdm/no-autostart` and `startx-attempts`, and optionally updates managed `zsh`/`fish` hooks. Packages, `/etc/pam.d/login`, and systemd units stay untouched.

- **Repair home and system state (`--fix`)**:
  ```sh
  bash install.sh --fix --dry-run
  bash install.sh --fix
  ```
  Accepts `--dry-run`, `--non-interactive`, and `--de <id>`. It validates templates first, preserves valid user-edited session dotfiles when only system state needs repair (delegating broken, missing, shadowed, or paused home setups to home recovery), installs missing managed `zsh`/`fish` hooks, uses `sudo` only when PAM or systemd/display-manager state requires inspection or repair (restoring missing, partial, or `.pacnew`-dropped PAM keyring and GNOME session-type rules, unmasking/enabling `getty@tty1.service`, and disabling re-enabled display managers), and finishes by re-running `--doctor`. See [installation.md](installation.md) for the full CLI reference.
