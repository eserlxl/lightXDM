#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# lint.sh: Run ShellCheck on all project shell scripts
set -e

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

scripts=(
  install.sh
  enable-autologin.sh
  uninstall.sh
  lint.sh
  tests/run.sh
  tests/docker-arch.sh
  tests/qemu-arch.sh
  tests/qemu/build-image.sh
  dotfiles/.bash_profile
  dotfiles/.gpg-agent-gnome
  dotfiles/.gpg-agent-kwallet
  dotfiles/.wayland-session-plasma
  dotfiles/.xinitrc-budgie
  dotfiles/.xinitrc-cinnamon
  dotfiles/.xinitrc-gnome
  dotfiles/.xinitrc-i3
  dotfiles/.xinitrc-lxde
  dotfiles/.xinitrc-lxqt
  dotfiles/.xinitrc-mate
  dotfiles/.xinitrc-xfce
)

for script in "${scripts[@]}"; do
  if [ -f "$SCRIPT_DIR/$script" ]; then
    echo "Checking $script..."
    opts=()
    # The sourced gpg-agent dotfiles export a command substitution in one step (SC2155).
    case "$script" in dotfiles/.gpg-agent-*) opts=(-e SC2155) ;; esac
    shellcheck "${opts[@]}" "$SCRIPT_DIR/$script"
  else
    echo "Error: $SCRIPT_DIR/$script not found." >&2
    exit 1
  fi
  echo
done

echo "ShellCheck completed for all scripts."