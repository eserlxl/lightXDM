# GPG Agent Integration

lightXDM initializes `gpg-agent` when your desktop session starts so it is ready for GPG signing, encryption, and optional SSH authentication.

## How It Works

When you log in, your session script (`~/.xinitrc` on X11 desktops, `~/.wayland-session` on Plasma, GNOME, and Budgie) sources a helper script that:

1. Starts `gpg-agent` via `gpg-connect-agent /bye`.
2. Points `SSH_AUTH_SOCK` at the `gpg-agent` SSH socket when `enable-ssh-support` is present in `~/.gnupg/gpg-agent.conf` (`$GNUPGHOME/gpg-agent.conf` when `GNUPGHOME` is set).
3. If `SSH_AUTH_SOCK` is still empty, exports the first agent socket found: OpenSSH's `$XDG_RUNTIME_DIR/ssh-agent.socket` (`ssh-agent.socket`), then the GCR SSH agent's `$XDG_RUNTIME_DIR/gcr/ssh` (`gcr-ssh-agent.socket`).
4. Refreshes the agent's startup tty with `gpg-connect-agent updatestartuptty /bye`.
5. On every desktop, `~/.config/autostart/lightxdm-gpg-agent-tty.desktop` re-runs that refresh inside the session, so SSH passphrase prompts reach the desktop on Wayland, where the helper runs before the compositor starts.

A custom compositor without XDG autostart support needs `gpg-connect-agent updatestartuptty /bye` in its own startup.

These scripts do not enable a `pinentry-program` or desktop keyring integration by default; run `bash install.sh --setup-gpg auto` (with optional `--gpg-ssh` and `--dry-run`) to configure them automatically, or edit `~/.gnupg/gpg-agent.conf` manually.

## Automated Setup (`--setup-gpg`)

To configure keyring-backed GPG passphrase caching and optional SSH agent support in `${GNUPGHOME:-~/.gnupg}/gpg-agent.conf` without `sudo`:

```sh
bash install.sh --setup-gpg auto --dry-run   # preview pinentry backend from your desktop/install choices
bash install.sh --setup-gpg auto             # write fenced pinentry-program block and reload gpg-agent
bash install.sh --setup-gpg auto --gpg-ssh   # also add enable-ssh-support inside the managed block
bash install.sh --setup-gpg remove           # remove only lightXDM's fenced block and reload gpg-agent
```

- Pass `gnome` (`/usr/bin/pinentry-gnome3`), `kwallet` (`/usr/bin/pinentry-qt`), or `auto` (resolves from active `--keyring`/`--de`, saved `install-choices`, readable `/etc/lightxdm/pam-keyring`, readable `/etc/pam.d/login` `pam_kwallet5.so` / `pam_gnome_keyring.so` lines, or detected Plasma vs other desktops), or combine `--setup-gpg` with an install command (`--de <id>` or `--install-session <path>`).
- Updates write atomically inside `# >>> lightXDM GPG setup >>>` .. `# <<< lightXDM GPG setup <<<` (`0700` directory creation, `0600` config permissions), preserve existing unmanaged `pinentry-program` settings untouched, validate regular executable `pinentry` and in-`$HOME` `$GNUPGHOME` paths before modifying files, surface state and broken markers/pinentry paths in `install.sh --status [--json]` and `--doctor [--json]`, and reload via `gpgconf --kill gpg-agent` (leaving your personal GPG settings untouched on `uninstall.sh`).

### For KDE Plasma

-   **`~/.gpg-agent-kwallet` Script**: Sourced by `~/.wayland-session` (from `.wayland-session-plasma`) to start `gpg-agent`, set `SSH_AUTH_SOCK` when `enable-ssh-support` is enabled, and refresh the agent's tty.

### For XFCE and other non-Plasma environments

-   **`~/.gpg-agent-gnome` Script**: Sourced by `~/.xinitrc` on X11 desktops or `~/.wayland-session` on GNOME and Budgie to start `gpg-agent`, set `SSH_AUTH_SOCK` when `enable-ssh-support` is enabled, and refresh the agent's tty.

## Configuration Notes

-   **Keyring-Backed Passphrase Caching (`pinentry-program`)**: Run `bash install.sh --setup-gpg auto` (or pass `gnome` / `kwallet`), or manually set `pinentry-program` in `~/.gnupg/gpg-agent.conf` to `/usr/bin/pinentry-gnome3` or `/usr/bin/pinentry-qt` and reload the agent with `gpgconf --kill gpg-agent`.
-   **Terminal Pinentry (`GPG_TTY`)**: Add `export GPG_TTY=$(tty)` to `~/.bashrc` so interactive terminal shells report the active tty to `gpg-agent`.
-   **SSH Agent Support (`SSH_AUTH_SOCK`)**: `enable-ssh-support` gives `gpg-agent` priority. Otherwise, the `.gpg-agent-*` scripts preserve an existing `SSH_AUTH_SOCK` (for example, from `~/.xprofile` or `xinitrc.d`) and, only when `SSH_AUTH_SOCK` is empty, fall back to `$XDG_RUNTIME_DIR/ssh-agent.socket` and then `$XDG_RUNTIME_DIR/gcr/ssh`, whichever socket exists first. With no socket, an unset `SSH_AUTH_SOCK` stays unset.
