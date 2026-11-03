# KWallet Auto-Unlock via PAM

lightXDM uses pam_kwallet5 to automatically unlock your KDE Wallet (KWallet) at login, even without a display manager.

## How it works
- The installer creates a one-time backup of `/etc/pam.d/login` at `/etc/pam.d/login.lightxdm.bak` (which `uninstall.sh` restores).
- It appends two PAM lines (`auth       optional   pam_kwallet5.so` and `session    optional   pam_kwallet5.so force_run`) to `/etc/pam.d/login` if `pam_kwallet5.so` is not already configured.
- The `force_run` option ensures KWallet unlock runs even if no display manager is present.
- When you type your password to log in on TTY1 and Plasma starts with `startx`, your wallet is unlocked seamlessly.

## Troubleshooting
- Make sure your wallet password matches your login password.
- If you enable passwordless autologin (`enable-autologin.sh`), PAM does not receive a login password, so KWallet will stay locked and ask for its password in the desktop unless its password is empty.
- If you use a custom PAM stack, adjust the `pam_kwallet5.so` lines in `/etc/pam.d/login` accordingly.
