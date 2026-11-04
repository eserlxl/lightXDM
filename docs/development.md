# Development

How the repository is laid out and how to check a change before sending it.

```sh
bash lint.sh               # ShellCheck on every script
bash tests/run.sh          # behavior suite (--strict also fails on skipped checks)
bash tests/docker-arch.sh  # package lists and real PAM checks in an Arch container (needs Docker)
```

## Project Structure
```
lightXDM/
├── README.md
├── install.sh
├── enable-autologin.sh
├── uninstall.sh
├── lint.sh
├── dotfiles/
│   ├── .gpg-agent-gnome
│   ├── .gpg-agent-kwallet
│   ├── .wayland-session-plasma
│   ├── .xinitrc-gnome
│   ├── .xinitrc-xfce
│   ├── .xinitrc-lxqt
│   ├── .xinitrc-lxde
│   ├── .xinitrc-mate
│   ├── .xinitrc-cinnamon
│   ├── .xinitrc-budgie
│   ├── .xinitrc-i3
│   └── .bash_profile
├── polkit/
│   └── 49-nopasswd.rules
├── docs/
│   ├── gpg-agent.md
│   ├── kwallet-autounlock.md
│   ├── polkit-support.md
│   └── startx-autologin.md
├── tests/
│   ├── docker-arch.sh   # real PAM checks in an Arch container (needs Docker)
│   └── run.sh           # behavior suite (--strict fails on skipped checks; --help)
└── LICENSE
```
