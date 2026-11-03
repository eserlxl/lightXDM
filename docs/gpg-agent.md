# GPG Agent Integration

lightXDM initializes `gpg-agent` when your desktop session starts so it is ready for GPG signing, encryption, and optional SSH authentication.

## How It Works

When you log in, your `.xinitrc` sources a helper script that:

1. Starts `gpg-agent` via `gpg-connect-agent /bye`.
2. Points `SSH_AUTH_SOCK` at the `gpg-agent` SSH socket when `enable-ssh-support` is present in `~/.gnupg/gpg-agent.conf`.
3. Refreshes the agent's startup tty with `gpg-connect-agent updatestartuptty /bye`.

These scripts do not configure a `pinentry-program` or desktop keyring integration on their own.

### For KDE Plasma

-   **`~/.gpg-agent-kwallet` Script**: Sourced by `.xinitrc-plasma` to start `gpg-agent`, set `SSH_AUTH_SOCK` when `enable-ssh-support` is enabled, and refresh the agent's tty.

### For GNOME, XFCE, and other non-Plasma environments

-   **`~/.gpg-agent-gnome` Script**: Sourced by the relevant `.xinitrc-*` file to start `gpg-agent`, set `SSH_AUTH_SOCK` when `enable-ssh-support` is enabled, and refresh the agent's tty.

## Configuration Notes

-   **Keyring-Backed Passphrase Caching (`pinentry-program`)**: To cache your GPG passphrase in GNOME Keyring or KWallet, set `pinentry-program` in `~/.gnupg/gpg-agent.conf` to `/usr/bin/pinentry-gnome3` or `/usr/bin/pinentry-qt`, then reload the agent with `gpgconf --kill gpg-agent`.
-   **Terminal Pinentry (`GPG_TTY`)**: Add `export GPG_TTY=$(tty)` to `~/.bashrc` so interactive terminal shells report the active tty to `gpg-agent`.
-   **SSH Agent Support (`SSH_AUTH_SOCK`)**: The `.gpg-agent-*` scripts only point `SSH_AUTH_SOCK` at `gpg-agent` when `enable-ssh-support` is present in `~/.gnupg/gpg-agent.conf`.
