# Autologin on TTY1 with startx

lightXDM provides a display-manager-free autologin experience by:
- Logging in to TTY1 (via systemd or getty autologin)
- Using `.bash_profile` to auto-launch `startx` only on TTY1

## How it works
- If you log in on TTY1 (an interactive login shell), `.bash_profile` runs `startx` automatically. Non-interactive login shells such as `su - user -c cmd` on TTY1 run their command and do not start X.
- No graphical login screen, no display manager needed.
- You get a full desktop environment session with minimal RAM and boot time.

## Keyring Unlock Trade-Off
- **Default mode (password login on TTY1):** You type your password on TTY1, your desktop starts automatically, and PAM unlocks your keyring (KWallet on Plasma, GNOME Keyring on all other supported desktops) using that password.
- **Autologin mode (`agetty --autologin`):** Login happens without a password, so the PAM keyring module cannot unlock your keyring automatically. The keyring stays locked and asks for its password in the desktop unless its password is empty (`enable-autologin.sh` prints a warning when PAM keyring unlock is configured).

## Setup
- The installer copies `.bash_profile` and `.xinitrc` to your home.
- To enable TTY1 autologin, set up a systemd override for `agetty` on tty1 for your user:

### Example: Enable Autologin on TTY1 (systemd)

1. Create an override directory:
   ```sh
   sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
   ```
2. Create the override file:
   ```sh
   sudo nano /etc/systemd/system/getty@tty1.service.d/override.conf
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
sudo rm /etc/systemd/system/getty@tty1.service.d/override.conf
sudo systemctl daemon-reload
```

### Optional: Helper Script
You can use the provided `enable-autologin.sh` script to automate this setup (changes take effect at the next login or reboot). Run:
```sh
sudo bash enable-autologin.sh YOURUSER
```
This will create the override for you. To remove autologin, run:
```sh
sudo bash enable-autologin.sh --disable
```
