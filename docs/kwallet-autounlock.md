# KWallet Auto-Unlock via PAM

lightXDM uses pam_kwallet5 to automatically unlock your KDE Wallet (KWallet) at login, even without a display manager.

> **Note:** Plasma now runs only on Wayland on Arch Linux, so `install.sh` currently refuses it and does not configure KWallet (see the README). This page describes the KWallet integration kept for future Wayland support.

## How it works
- The installer creates a one-time backup of `/etc/pam.d/login` at `/etc/pam.d/login.lightxdm.bak`. `uninstall.sh` removes only the lines lightXDM added; it restores the backup when nothing else changed, and otherwise keeps your other edits and leaves the backup for review.
- It appends two PAM lines (`auth       optional   pam_kwallet5.so` and `session    optional   pam_kwallet5.so force_run`) to `/etc/pam.d/login` if `pam_kwallet5.so` is not already configured.
- The `force_run` option ensures KWallet unlock runs even if no display manager is present.
- When you type your password to log in on TTY1 and Plasma starts with `startx`, your wallet is unlocked seamlessly.

## Troubleshooting
- Make sure your wallet password matches your login password.
- If you enable passwordless autologin (`enable-autologin.sh`), PAM does not receive a login password, so KWallet will stay locked and ask for its password in the desktop unless its password is empty.
- If you use a custom PAM stack, adjust the `pam_kwallet5.so` lines in `/etc/pam.d/login` accordingly.
