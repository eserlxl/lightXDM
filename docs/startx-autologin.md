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
- **Choosing autologin without keyring unlock:** on a new install, `bash install.sh --no-keyring --autologin` skips the keyring setup and enables autologin in the same run. On an existing default install, `bash install.sh --login-mode autologin` automates switching to passwordless TTY1 autologin without keyring PAM lines (and `bash install.sh --login-mode password` switches back to password login with PAM keyring unlock, both supporting `--dry-run`), or manually run `sudo bash uninstall.sh --keyring-only` (keeping GNOME's session-type block and config) followed by `sudo bash enable-autologin.sh YOURUSER`.
- **systemd-homed accounts:** An account whose home directory is managed by `systemd-homed` (using LUKS or fscrypt storage) requires a password at login to unlock the home directory. Passwordless TTY1 autologin boots to a failed login because `pam_systemd_home` cannot activate an encrypted home without a password; keep password login on TTY1 for homed accounts so the password unlocks both the home directory and keyring. `enable-autologin.sh` and `install.sh --preflight` warn when the target account is managed by systemd-homed.

## zsh and fish users
The installer writes `~/.bash_profile` by default. If your login shell is zsh or fish, either manage the fenced block automatically:
```sh
bash install.sh --setup-shell auto   # or pass zsh / fish explicitly (supports --dry-run and --recover)
```
or add the equivalent block yourself (`--setup-shell` honors in-home `$ZDOTDIR/.zprofile` and `$XDG_CONFIG_HOME/fish/config.fish` automatically, manages `# >>> lightXDM TTY1 auto-start >>>` .. `# <<< lightXDM TTY1 auto-start <<<` markers safely, and records custom hook paths in `${XDG_STATE_HOME:-~/.local/state}/lightxdm/installed-shell-hooks`; `uninstall.sh` reads that record from the default `~/.local/state/lightxdm/` location—not a custom `XDG_STATE_HOME`—while also checking default and in-home `$ZDOTDIR`/`$XDG_CONFIG_HOME` paths to clean up only that fenced block). These snippets match `~/.bash_profile` in honoring `~/.config/lightxdm/no-autostart`, pausing TTY1 auto-start after 3 launches within 30 seconds, and wrapping launches in `systemd-cat -t lightxdm` when `~/.config/lightxdm/session-journal` exists (`lightxdm-update`, `--setup-shell <zsh|fish|auto>`, and `--fix` upgrade an older managed block in place while leaving unmanaged custom hooks untouched).

You can also print either snippet directly to stdout without opening this file (for example under a package install with `lightxdm-install`):
```sh
bash install.sh --shell-snippet zsh >> ~/.zprofile
mkdir -p ~/.config/fish && bash install.sh --shell-snippet fish >> ~/.config/fish/config.fish
```

zsh, in `~/.zprofile`:
```zsh
if [[ -o interactive && -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} && $(tty) == /dev/tty1 && ! -e $HOME/.config/lightxdm/no-autostart ]]; then
  export PATH="$HOME/.local/bin:$PATH"
  _lightxdm_launcher=""
  if [[ -f $HOME/.wayland-session && -x $HOME/.wayland-session ]]; then
    _lightxdm_launcher="$HOME/.wayland-session"
  elif command -v startx >/dev/null 2>&1; then
    _lightxdm_launcher="startx"
  fi
  if [[ -n $_lightxdm_launcher ]]; then
    _lightxdm_attempts="${XDG_STATE_HOME:-$HOME/.local/state}/lightxdm/startx-attempts"
    zmodload -F zsh/datetime p:EPOCHSECONDS 2>/dev/null || :
    _lightxdm_now=${EPOCHSECONDS:-$(date +%s 2>/dev/null || printf '0')}
    _lightxdm_lines=()
    _lightxdm_recent=()
    if [[ -f $_lightxdm_attempts && -r $_lightxdm_attempts ]]; then
      _lightxdm_lines=("${(@f)$(<"$_lightxdm_attempts" 2>/dev/null)}")
    fi
    for _lightxdm_ts in "${_lightxdm_lines[@]}"; do
      if [[ -n $_lightxdm_ts && ${#_lightxdm_ts} -le 18 && $_lightxdm_ts != *[!0123456789]* ]] &&
        (( _lightxdm_now - 10#$_lightxdm_ts >= 0 && _lightxdm_now - 10#$_lightxdm_ts <= 30 )); then
        _lightxdm_recent+=("$_lightxdm_ts")
      fi
    done
    if (( ${#_lightxdm_recent[@]} >= 3 )); then
      if mkdir -p "$HOME/.config/lightxdm" 2>/dev/null &&
        : 2>/dev/null >| "$HOME/.config/lightxdm/no-autostart"; then
        : 2>/dev/null >| "$_lightxdm_attempts" || :
      fi
      printf '%s\n' "TTY1 auto-start paused: the session was started 3 times within 30s; run 'rm ~/.config/lightxdm/no-autostart' to resume."
      unset _lightxdm_launcher _lightxdm_attempts _lightxdm_now _lightxdm_lines _lightxdm_recent _lightxdm_ts
    else
      if mkdir -p "${_lightxdm_attempts:h}" 2>/dev/null; then
        { printf '%s\n' "${_lightxdm_recent[@]}" "$_lightxdm_now" >| "$_lightxdm_attempts"; } 2>/dev/null || :
      fi
      unset _lightxdm_attempts _lightxdm_now _lightxdm_lines _lightxdm_recent _lightxdm_ts
      if [[ -e $HOME/.config/lightxdm/session-journal ]] && command -v systemd-cat >/dev/null 2>&1; then
        exec systemd-cat -t lightxdm "$_lightxdm_launcher"
      fi
      exec "$_lightxdm_launcher"
    fi
  else
    unset _lightxdm_launcher
  fi
fi
```

fish, in `~/.config/fish/config.fish`:
```fish
if status is-login; and status is-interactive; and test -z "$DISPLAY"; and test -z "$WAYLAND_DISPLAY"; and test (tty) = /dev/tty1; and not test -e "$HOME/.config/lightxdm/no-autostart"
  set -gx PATH $HOME/.local/bin $PATH
  set -l _lightxdm_launcher ""
  if test -f "$HOME/.wayland-session"; and test -x "$HOME/.wayland-session"
    set _lightxdm_launcher "$HOME/.wayland-session"
  else if command -q startx
    set _lightxdm_launcher startx
  end
  if test -n "$_lightxdm_launcher"
    set -l _lightxdm_state_dir "$HOME/.local/state"
    if set -q XDG_STATE_HOME; and test -n "$XDG_STATE_HOME"
      set _lightxdm_state_dir "$XDG_STATE_HOME"
    end
    set -l _lightxdm_attempts "$_lightxdm_state_dir/lightxdm/startx-attempts"
    set -l _lightxdm_now (date +%s 2>/dev/null; or echo 0)
    set -l _lightxdm_recent
    if test -f "$_lightxdm_attempts"; and test -r "$_lightxdm_attempts"
      for _lightxdm_ts in (command cat -- "$_lightxdm_attempts" 2>/dev/null)
        if string match -rq '^[0-9]{1,15}$' -- "$_lightxdm_ts"
          set -l _lightxdm_ts_clean (string replace -r '^0+(.)' '$1' -- "$_lightxdm_ts")
          set -l _lightxdm_age (math "$_lightxdm_now - $_lightxdm_ts_clean" 2>/dev/null; or echo -1)
          if test "$_lightxdm_age" -ge 0 2>/dev/null; and test "$_lightxdm_age" -le 30 2>/dev/null
            set -a _lightxdm_recent $_lightxdm_ts
          end
        end
      end
    end
    if test (count $_lightxdm_recent) -ge 3
      if mkdir -p "$HOME/.config/lightxdm" >/dev/null 2>&1; and begin; printf '' > "$HOME/.config/lightxdm/no-autostart"; end 2>/dev/null
        begin; printf '' > "$_lightxdm_attempts"; end 2>/dev/null; or true
      end
      echo "TTY1 auto-start paused: the session was started 3 times within 30s; run 'rm ~/.config/lightxdm/no-autostart' to resume."
    else
      if mkdir -p (dirname -- "$_lightxdm_attempts") >/dev/null 2>&1
        begin; printf '%s\n' $_lightxdm_recent $_lightxdm_now > "$_lightxdm_attempts"; end 2>/dev/null; or true
      end
      if test -e "$HOME/.config/lightxdm/session-journal"; and command -q systemd-cat
        exec systemd-cat -t lightxdm "$_lightxdm_launcher"
      end
      exec "$_lightxdm_launcher"
    end
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
This will create the override for you. If `getty@tty1.service` is masked or disabled, the script changes nothing and asks you to run `systemctl unmask getty@tty1.service` or `systemctl enable getty@tty1.service`. If the target account is managed by `systemd-homed`, the script prints a warning to stderr that its home directory may not unlock without a password (autologin is still configured; it does not refuse). To remove autologin, run:
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

If the desktop (`~/.wayland-session` or `startx`) was launched on TTY1 three times within the 30 seconds before a TTY1 login (a desktop that keeps crashing right after it starts), that login automatically pauses auto-start: `.bash_profile` (and the `zsh`/`fish` TTY1 hooks from `--setup-shell` / `--shell-snippet`) creates `~/.config/lightxdm/no-autostart`, clears `${XDG_STATE_HOME:-~/.local/state}/lightxdm/startx-attempts`, prints a one-line notice explaining how to resume, and continues to an interactive shell instead of starting the desktop. (Recent launch timestamps are kept in `${XDG_STATE_HOME:-~/.local/state}/lightxdm/startx-attempts`, dropping entries older than 30 seconds; `uninstall.sh` removes this file from the default `~/.local/state` location, but not a copy under a custom `XDG_STATE_HOME`.)

You can also create the marker manually as your user from another TTY or SSH:
```sh
mkdir -p ~/.config/lightxdm
touch ~/.config/lightxdm/no-autostart
```
While the marker exists, the installed `.bash_profile` (and `zsh`/`fish` TTY1 snippets) skips the desktop launch and opens your interactive shell on the next TTY1 login. Other TTYs are unchanged, and no edit to `~/.bash_profile` is needed.

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
  Runs read-only without `sudo` and exits `0` when healthy or `1` when issues remain (`--json` emits structured JSON checks and counts on stdout). Checks the active TTY1 launcher (`~/.wayland-session` vs `startx`/`~/.xinitrc`), template syntax and commands, `bash`/`zsh`/`fish` login-shell hooks (including malformed markers, unsafe symlinks/permissions, and outdated managed blocks), `~/.config/lightxdm/no-autostart`, `startx-attempts`, `*.lightxdm-new` update files, existing helper dotfiles/dotfile records/PAM backup integrity, PAM keyring/GNOME session-type rules and `.so` modules (including `.pacnew` state), `getty@tty1.service`, re-enabled display managers, and TTY1 autologin conflicts.

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
  Accepts `--dry-run`, `--non-interactive`, and `--de <id>`. It validates templates, `~/.config*` directories, `installed-dotfiles`, and dotfile readability/type safety first, preserves valid user-edited session dotfiles when only system state needs repair (delegating broken, missing, shadowed, or paused launchers and broken helper/`~/.bash_profile` symlinks to home recovery), installs or refreshes outdated managed `zsh`/`fish` hooks (while refusing malformed markers or symlinks), uses `sudo` only when PAM or systemd/display-manager state requires inspection or repair (restoring missing, partial, or `.pacnew`-dropped PAM keyring and GNOME session-type rules, unmasking/enabling `getty@tty1.service`, and disabling re-enabled display managers), and finishes by re-running `--doctor`. See [installation.md](installation.md) for the full CLI reference.
