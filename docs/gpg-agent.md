# GPG Agent Integration

lightXDM provides seamless integration between the GPG agent and your desktop environment's keyring, ensuring that your GPG keys are automatically available in your session. This integration allows you to use GPG for signing, encryption, and SSH authentication without repeatedly entering your passphrase.

## How It Works

lightXDM uses a dedicated script to initialize the GPG agent and configure it to use your desktop environment's keyring for secure password caching. This script is automatically sourced when you log in, ensuring that the GPG agent is started and configured correctly.

### For KDE Plasma

-   **`~/.gpg-agent-kwallet` Script**: This script configures the GPG agent to use KWallet.
-   **`.xinitrc-plasma`**: The `.xinitrc-plasma` file sources the `~/.gpg-agent-kwallet` script.

### For GNOME, XFCE, and other GTK-based environments

-   **`~/.gpg-agent-gnome` Script**: This script configures the GPG agent to use GNOME Keyring.
-   **`.xinitrc-*`**: The relevant `.xinitrc` file for your desktop environment sources the `~/.gpg-agent-gnome` script.

## Configuration Notes

-   **Terminal Pinentry (`GPG_TTY`)**: Add `export GPG_TTY=$(tty)` to `~/.bashrc` so interactive terminal shells report the active tty to `gpg-agent`.
-   **SSH Agent Support (`SSH_AUTH_SOCK`)**: The `.gpg-agent-*` scripts only point `SSH_AUTH_SOCK` at `gpg-agent` when `enable-ssh-support` is present in `~/.gnupg/gpg-agent.conf`.

## Benefits

-   **Single Sign-On**: Unlock your keyring once at login, and your GPG keys are ready to use.
-   **Seamless SSH Authentication**: Use your GPG keys for SSH authentication without any extra steps.
-   **Secure Password Caching**: Your GPG passphrase is securely stored in your keyring.
