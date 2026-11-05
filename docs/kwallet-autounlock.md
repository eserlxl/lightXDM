# KWallet Auto-Unlock via PAM

lightXDM uses pam_kwallet5 to automatically unlock your KDE Wallet (KWallet) at login, even without a display manager.

Plasma uses KWallet automatically. For a custom X11 or Wayland session with KDE applications, install `kwallet-pam` yourself, create and edit the session template, then choose KWallet during installation:

```sh
bash install.sh --init-template --wayland --de sway
# Edit ~/.config/lightxdm/.wayland-session-sway as needed.
bash install.sh --dry-run --no-packages --de sway --keyring kwallet
bash install.sh --no-packages --de sway --keyring kwallet
```

Custom sessions still require `--no-packages` and default to GNOME Keyring when `--keyring` is omitted; `--keyring gnome` selects that default explicitly. `--keyring` is refused for built-in desktop ids and together with `--no-keyring` or `--init-template`, before privilege checks or changes. Custom templates keep sourcing `~/.gpg-agent-gnome`; its shared helper supports either backend.

## How it works
- The installer creates a one-time backup of `/etc/pam.d/login` at `/etc/pam.d/login.lightxdm.bak`. `uninstall.sh` removes only the lines lightXDM added; it restores the backup when nothing else changed, and otherwise keeps your other edits and leaves the backup for review.
- It appends two PAM lines (`auth       optional   pam_kwallet5.so` and `session    optional   pam_kwallet5.so force_run`) to `/etc/pam.d/login` if `pam_kwallet5.so` is not already configured.
- Switching a custom session from GNOME Keyring to KWallet removes only the GNOME Keyring lines lightXDM added. The preview shows the same removals and KWallet additions; uninstall handles these lines as usual.
- The `force_run` option ensures KWallet unlock runs even if no display manager is present.
- When you type your password to log in on TTY1, your wallet is unlocked for Plasma or the custom session using KWallet.

## Troubleshooting
- Make sure your wallet password matches your login password.
- If the installer warns that `pam_kwallet5.so` is missing, install `kwallet-pam` before relying on automatic unlock.
- If you enable passwordless autologin (`enable-autologin.sh`), PAM does not receive a login password, so KWallet will stay locked and ask for its password in the desktop unless its password is empty; to keep autologin, remove the keyring lines lightXDM added with `sudo bash uninstall.sh --keyring-only`.
- If you use a custom PAM stack, adjust the `pam_kwallet5.so` lines in `/etc/pam.d/login` accordingly.
