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
    IFS=: read -r _ _ target_uid _ _ TARGET_HOME _ <<<"$passwd_entry"
    if [[ "$target_uid" == "0" ]]; then
      echo "Error: Refusing to uninstall for root. Run with sudo from your user account, or set TARGET_HOME." >&2
      exit 1
    fi
  fi
fi

if [[ -z "${TARGET_HOME:-}" ]]; then
  echo "Error: Could not determine target user home directory. Run with sudo from your user account, or set TARGET_HOME." >&2
  exit 1
fi

if [[ ! -d "$TARGET_HOME" ]]; then
  echo "Error: Target home directory does not exist: $TARGET_HOME" >&2
  exit 1
fi

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOGIN_FILE="${LOGIN_FILE:-/etc/pam.d/login}"
DM_STATE_FILE="${DM_STATE_FILE:-/etc/lightxdm/disabled-display-managers}"
BACKUP_FILE="${LOGIN_FILE}.lightxdm.bak"

files_match() {
  [[ "$(sha256sum < "$1")" == "$(sha256sum < "$2")" ]]
}

# Remove only the exact PAM lines configure_pam appends.
if [ -f "$BACKUP_FILE" ]; then
  # A line already present before install (it is in the backup) is the user's, not ours.
  pam_sed=()
  for pam_re in \
    '^auth       optional   pam_kwallet5\.so$' \
    '^session    optional   pam_kwallet5\.so force_run$' \
    '^auth       optional   pam_gnome_keyring\.so$' \
    '^session    optional   pam_gnome_keyring\.so auto_start$'; do
    if [[ -z "$(sed -n "/${pam_re}/p" "$BACKUP_FILE")" ]]; then
      pam_sed+=(-e "/${pam_re}/d")
    fi
  done
  if [[ ${#pam_sed[@]} -gt 0 ]]; then
    sed -i --follow-symlinks "${pam_sed[@]}" "$LOGIN_FILE"
  fi
  if files_match "$LOGIN_FILE" "$BACKUP_FILE" ||
    { [[ -s "$BACKUP_FILE" && -n "$(tail -c 1 "$BACKUP_FILE")" ]] &&
      files_match "$LOGIN_FILE" <(cat "$BACKUP_FILE"; printf '\n'); }; then
    echo "Restoring $LOGIN_FILE from backup..."
    cp "$BACKUP_FILE" "$LOGIN_FILE"
    rm -f "$BACKUP_FILE"
  else
    echo "Removed lightXDM PAM lines from $LOGIN_FILE; backup kept for review: $BACKUP_FILE"
  fi
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
matches_lightxdm_template() {
  local dotfile="$1"
  local path="$TARGET_HOME/$dotfile"
  if [[ ! -f "$path" || -L "$path" ]]; then
    return 1
  fi
  if [[ "$dotfile" == ".bash_profile" ]]; then
    if [[ -f "$SCRIPT_DIR/dotfiles/.bash_profile" ]] && files_match "$path" "$SCRIPT_DIR/dotfiles/.bash_profile"; then
      return 0
    fi
    return 1
  fi
  local tmpl
  for tmpl in "$SCRIPT_DIR"/dotfiles/.xinitrc-*; do
    if [[ -f "$tmpl" ]] && files_match "$path" "$tmpl"; then
      return 0
    fi
  done
  return 1
}

for dotfile in .bash_profile .xinitrc; do
  if [[ -f "$TARGET_HOME/${dotfile}.lightxdm.bak" || -L "$TARGET_HOME/${dotfile}.lightxdm.bak" ]]; then
    if [[ -e "$TARGET_HOME/$dotfile" || -L "$TARGET_HOME/$dotfile" ]] && ! matches_lightxdm_template "$dotfile"; then
      edited_dest="$TARGET_HOME/${dotfile}.lightxdm-edited"
      if [[ -e "$edited_dest" || -L "$edited_dest" ]]; then
        n=1
        while [[ -e "${edited_dest}.${n}" || -L "${edited_dest}.${n}" ]]; do
          n=$((n + 1))
        done
        edited_dest="${edited_dest}.${n}"
      fi
      echo "Saving edited $TARGET_HOME/$dotfile to $edited_dest..."
      mv "$TARGET_HOME/$dotfile" "$edited_dest"
    fi
    echo "Restoring $TARGET_HOME/$dotfile from backup..."
    mv "$TARGET_HOME/${dotfile}.lightxdm.bak" "$TARGET_HOME/$dotfile"
  elif [[ -f "$TARGET_HOME/$dotfile" ]]; then
    if ! matches_lightxdm_template "$dotfile"; then
      echo "Keeping $TARGET_HOME/$dotfile (not an unmodified lightXDM template)."
    else
      echo "Removing $TARGET_HOME/$dotfile..."
      rm -f "$TARGET_HOME/$dotfile"
    fi
  fi
done
rm -f "$TARGET_HOME/.gpg-agent-kwallet" "$TARGET_HOME/.gpg-agent-gnome"

# Re-enable only display managers disabled by the installer
if [[ -f "$DM_STATE_FILE" ]]; then
  while IFS= read -r dm_unit || [[ -n "$dm_unit" ]]; do
    [[ -n "$dm_unit" ]] || continue
    systemctl enable "$dm_unit"
  done < "$DM_STATE_FILE"
  rm -f "$DM_STATE_FILE"
fi
# install.sh creates the state directory even when it disables nothing.
rmdir --ignore-fail-on-non-empty "$(dirname -- "$DM_STATE_FILE")" 2>/dev/null || true

echo "Uninstall complete. Changes will take effect at the next login or reboot."
