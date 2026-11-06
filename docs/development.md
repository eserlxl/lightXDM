# Development

How the repository is laid out and how to check a change before sending it.

```sh
bash lint.sh               # ShellCheck on every script
bash tests/run.sh          # behavior suite (--strict also fails on skipped checks)
bash tests/docker-arch.sh  # package lists and real PAM checks in an Arch container (needs Docker)
bash tests/qemu-arch.sh    # real TTY1 password logins in QEMU VMs (needs Docker and KVM; slow)
```

Both `tests/docker-arch.sh` and `tests/qemu-arch.sh` accept `--strict` (or
`LIGHTXDM_STRICT_TESTS=1`) to exit 1 instead of 0 when a missing prerequisite causes a `SKIP`.

`install.sh` and `uninstall.sh` recognize a home file that an older lightXDM version installed by
its sha256 in `dotfiles/template-history.sha256`, which lists every version of every bundled
template, so the check also works in a copy without `.git`. After editing a template in
`dotfiles/`, regenerate the list with `bash tests/template-history.sh > dotfiles/template-history.sha256`;
`tests/run.sh` fails until the list matches the git history.

## Project Structure
```
lightXDM/
├── README.md
├── install.sh
├── enable-autologin.sh
├── uninstall.sh
├── lint.sh
├── aur/
│   └── aurgen.install.yaml  # aurgen config of the lightxdm AUR package; aurgen generates the other aur/ files
├── bin/                     # lightxdm-install, -update, -uninstall, -autologin: the package's /usr/bin launchers
├── dotfiles/
│   ├── .gpg-agent-gnome
│   ├── lightxdm-gpg-agent-tty.desktop
│   ├── .wayland-session-plasma
│   ├── .wayland-session-gnome
│   ├── .wayland-session-budgie
│   ├── .xinitrc-xfce
│   ├── .xinitrc-lxqt
│   ├── .xinitrc-lxde
│   ├── .xinitrc-mate
│   ├── .xinitrc-cinnamon
│   ├── .xinitrc-i3
│   ├── .bash_profile
│   └── template-history.sha256  # sha256 of every template version; tests/template-history.sh regenerates it
├── pam/
│   └── gnome-session-type.conf
├── polkit/
│   └── 49-nopasswd.rules  # last rule older versions installed; frozen: uninstall.sh pins its sha256 in LIGHTXDM_OLD_POLKIT_HASHES and the tests install it as the old rule, so an edit fails them
├── docs/
│   ├── development.md
│   ├── features.md
│   ├── gpg-agent.md
│   ├── installation.md
│   ├── kwallet-autounlock.md
│   ├── polkit-support.md
│   └── startx-autologin.md
├── tests/
│   ├── docker-arch.sh   # real PAM checks in an Arch container (needs Docker)
│   ├── qemu-arch.sh     # real TTY1 logins in QEMU VMs (needs Docker and KVM)
│   ├── qemu/
│   │   ├── build-image.sh  # builds the VM image in a privileged Arch container
│   │   └── vmtest.py       # boots one VM, installs, types the TTY1 login, checks the session
│   ├── run.sh           # behavior suite (--strict fails on skipped checks; --help)
│   └── template-history.sh  # prints dotfiles/template-history.sha256 from the git history
└── LICENSE
```

## QEMU login test

`bash tests/qemu-arch.sh [desktop | <from>:<to> | <desktop>+autologin | <desktop>+lightdm | <desktop>+relogin | <desktop>+recovery ...]` (default: `plasma xfce`) proves the whole path on a real system: it builds an Arch Linux VM image in Docker with the requested desktops' packages (rebuilt only when the package set or `tests/qemu/build-image.sh` changes), boots one VM per desktop with KVM, runs `install.sh --de <desktop>` as a test user, reboots, types the password at the TTY1 login, and checks twice that the desktop session starts (Xorg or Wayland as expected) and that PAM unlocked the keyring without a prompt. The second login proves an existing keyring unlocks too. An argument `<from>:<to>` installs `<from>`, then `<to>` in the same VM and checks `<to>` (for example, `xfce:plasma` verifies that switching desktops swaps the keyring PAM lines cleanly). An argument `<desktop>+autologin` installs with `--no-keyring --autologin`, checks `enable-autologin.sh --status`, and boots twice without typing a password. An argument `<desktop>+lightdm` (for example, `xfce+lightdm`) adds `lightdm` and `lightdm-gtk-greeter` to the image, enables LightDM before installation, checks that `install.sh` disables and records it, runs both password logins and keyring checks, then runs `uninstall.sh` and checks that LightDM is enabled again, the `display-manager.service` link points to `lightdm.service`, and the state file is removed. An argument `<desktop>+relogin` (plain desktop ids only) logs out through the desktop's session manager (Plasma, XFCE, GNOME; other desktops are logged out by force with `loginctl terminate-user`), waits until the login prompt is back while the user's other processes (for example the keyring daemon) may still run, logs in again in the same boot and repeats the session and keyring checks. An argument `<desktop>+recovery` installs with `--no-keyring --autologin`, makes the session crash immediately, and proves that auto-start pauses with `getty@tty1` still active, the paused TTY1 shell executes a command typed through QMP, and repairing the launcher and ending that shell starts the desktop. VM disks are opened with `-snapshot`, so every run starts from the same clean image.

It needs Docker, `qemu-system-x86_64`, read/write access to `/dev/kvm`, `python3` and `ssh`, and prints `SKIP` when one is missing. Add `--strict` or set `LIGHTXDM_STRICT_TESTS=1` to exit 1 on a `SKIP`; the default is exit 0. The image is reused while the package set and `build-image.sh` are unchanged, and `--rebuild-image` forces a fresh image with current Arch packages. Images, the package cache and per-desktop logs and screenshots live in `${XDG_CACHE_HOME:-~/.cache}/lightxdm-vm` (`LIGHTXDM_VM_DIR`); `LIGHTXDM_VM_JOBS` sets how many VMs run at once (4 GiB each, default 2), and `LIGHTXDM_VM_KEEP=1` leaves each VM running after its first login for debugging. The test copies the working tree, so uncommitted changes are tested as they are.

## Release

The git tag `vX.Y.Z` is the only version source (there is no VERSION file): a fix bumps the patch
number, a new feature the minor number, a breaking change the major number. Before tagging, run every
gate on the final tree: `bash lint.sh`, `bash tests/run.sh --strict`, `bash tests/docker-arch.sh --strict`,
`bash tests/qemu-arch.sh --strict` with the login matrix the change needs (for example
`plasma gnome xfce xfce+autologin`), and `aurgen --build-only local`, which builds the package with
makepkg and checks it with namcap without installing it.

```sh
git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin main vX.Y.Z
aurgen aur          # signed release tarball, GitHub release, PKGBUILD and .SRCINFO
aurgen aur-init     # first release only: sets up the local clone of the AUR repository
aurgen aur-deploy   # pushes PKGBUILD, .SRCINFO and lightxdm.install to the AUR
```

`aur/aurgen.install.yaml` decides the package layout (`bin/` to `/usr/bin`, the scripts, `dotfiles/` and
`pam/` to `/usr/share/lightxdm`, the guides to `/usr/share/doc/lightxdm`), the signing key and the notes
pacman prints after install and upgrade and before removal. aurgen generates every other file in `aur/`,
and `aur/.gitignore` keeps them out of git.
