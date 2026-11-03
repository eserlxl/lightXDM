#!/usr/bin/env bash
# uninstall.sh: Revert changes made by install scripts (PAM, autologin, Polkit)
set -e

if [[ $# -gt 0 ]]; then
  if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    echo "Usage: sudo bash $0 [-h|--help]"
    exit 0
  fi
  echo "Usage: sudo bash $0 [-h|--help]" >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (with sudo)."
  exit 1
fi

if [[ -z "${TARGET_HOME:-}" && -n "${SUDO_USER:-}" && "$SUDO_USER" != -* ]]; then
  if passwd_entry="$(getent passwd "$SUDO_USER")"; then
    IFS=: read -r _ _ _ _ _ TARGET_HOME _ <<<"$passwd_entry"
  fi
fi

if [[ -z "${TARGET_HOME:-}" ]]; then
  echo "Error: Could not determine target user home directory. Run with sudo from your user account, or set TARGET_HOME." >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOGIN_FILE="${LOGIN_FILE:-/etc/pam.d/login}"
BACKUP_FILE="${LOGIN_FILE}.lightxdm.bak"

# Restore /etc/pam.d/login if backup exists
if [ -f "$BACKUP_FILE" ]; then
  echo "Restoring $LOGIN_FILE from backup..."
  cp "$BACKUP_FILE" "$LOGIN_FILE"
  rm -f "$BACKUP_FILE"
else
  echo "No $BACKUP_FILE found; skipping PAM restore."
fi

# Remove autologin override
OVERRIDE_FILE="${OVERRIDE_FILE:-/etc/systemd/system/getty@tty1.service.d/override.conf}"
if [ -f "$OVERRIDE_FILE" ]; then
  echo "Removing autologin override..."
  rm -f "$OVERRIDE_FILE"
  systemctl daemon-reload
  echo "Autologin override removed. Change will take effect at the next login or reboot."
else
  echo "No autologin override found; skipping."
fi

# Remove Polkit rule
POLKIT_RULE="${POLKIT_RULE:-/etc/polkit-1/rules.d/49-nopasswd.rules}"
if [ -f "$POLKIT_RULE" ]; then
  echo "Removing Polkit rule..."
  rm -f "$POLKIT_RULE"
else
  echo "No Polkit rule found; skipping."
fi

# Restore or remove user dotfiles
files_match() {
  [[ "$(sha256sum < "$1")" == "$(sha256sum < "$2")" ]]
}

for dotfile in .bash_profile .xinitrc; do
  if [[ -f "$TARGET_HOME/${dotfile}.lightxdm.bak" ]]; then
    echo "Restoring $TARGET_HOME/$dotfile from backup..."
    mv "$TARGET_HOME/${dotfile}.lightxdm.bak" "$TARGET_HOME/$dotfile"
  elif [[ -f "$TARGET_HOME/$dotfile" ]]; then
    matches_template=0
    if [[ "$dotfile" == ".bash_profile" ]]; then
      if [[ -f "$SCRIPT_DIR/dotfiles/.bash_profile" ]] && files_match "$TARGET_HOME/$dotfile" "$SCRIPT_DIR/dotfiles/.bash_profile"; then
        matches_template=1
      fi
    else
      for tmpl in "$SCRIPT_DIR"/dotfiles/.xinitrc-*; do
        if [[ -f "$tmpl" ]] && files_match "$TARGET_HOME/$dotfile" "$tmpl"; then
          matches_template=1
          break
        fi
      done
    fi
    if [[ $matches_template -eq 0 ]]; then
      echo "Keeping $TARGET_HOME/$dotfile (not an unmodified lightXDM template)."
    elif [[ -e "$TARGET_HOME/${dotfile}.lightxdm-removed" || -L "$TARGET_HOME/${dotfile}.lightxdm-removed" ]]; then
      echo "Skipping move of $TARGET_HOME/$dotfile; $TARGET_HOME/${dotfile}.lightxdm-removed already exists."
    else
      echo "Moving $TARGET_HOME/$dotfile to $TARGET_HOME/${dotfile}.lightxdm-removed..."
      mv "$TARGET_HOME/$dotfile" "$TARGET_HOME/${dotfile}.lightxdm-removed"
    fi
  fi
done
rm -f "$TARGET_HOME/.gpg-agent-kwallet" "$TARGET_HOME/.gpg-agent-gnome"

echo "Uninstall complete. Changes will take effect at the next login or reboot."
