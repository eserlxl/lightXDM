#!/usr/bin/env bash
# uninstall.sh: Revert changes made by install scripts (PAM, autologin, Polkit)
set -e

keyring_only=0
if [[ $# -gt 0 ]]; then
  if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    echo "Usage: sudo bash $0 [-h|--help] [--keyring-only]"
    echo "  --keyring-only  remove only the keyring lines lightXDM added to /etc/pam.d/login (for switching to autologin)"
    exit 0
  elif [[ $# -eq 1 && "$1" == "--keyring-only" ]]; then
    keyring_only=1
  else
    echo "Usage: sudo bash $0 [-h|--help] [--keyring-only]" >&2
    exit 1
  fi
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
  if [[ ! -e "$LOGIN_FILE" ]]; then
    echo "Restoring $LOGIN_FILE from backup..."
    rm -f -- "$LOGIN_FILE"
    cp -- "$BACKUP_FILE" "$LOGIN_FILE"
    rm -f -- "$BACKUP_FILE"
  else
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
  fi
else
  echo "No $BACKUP_FILE found; skipping PAM restore."
fi

if [[ $keyring_only -eq 1 ]]; then
  echo "Done (--keyring-only): dotfiles, autologin, the Polkit rule and display managers are unchanged."
  exit 0
fi

# Remove autologin drop-in and any legacy lightXDM-written override.conf
AUTOLOGIN_DROPIN="${AUTOLOGIN_DROPIN:-/etc/systemd/system/getty@tty1.service.d/lightxdm-autologin.conf}"
OVERRIDE_FILE="${OVERRIDE_FILE:-/etc/systemd/system/getty@tty1.service.d/override.conf}"

is_legacy_autologin_override() {
  local file="$1"
  if [[ ! -f "$file" || -L "$file" ]]; then
    return 1
  fi
  local lines=()
  local exec_re='^ExecStart=-/usr/bin/agetty --autologin [^-[:space:]:][^[:space:]:]* --noclear %I [$]TERM$'
  mapfile -t lines < "$file"
  [[ ${#lines[@]} -eq 3 && "${lines[0]}" == "[Service]" && "${lines[1]}" == "ExecStart=" && "${lines[2]}" =~ $exec_re ]]
}

autologin_removed=0
if [ -f "$AUTOLOGIN_DROPIN" ]; then
  echo "Removing autologin drop-in..."
  rm -f "$AUTOLOGIN_DROPIN"
  autologin_removed=1
fi
if [[ -f "$OVERRIDE_FILE" || -L "$OVERRIDE_FILE" ]]; then
  if is_legacy_autologin_override "$OVERRIDE_FILE"; then
    echo "Removing legacy autologin override..."
    rm -f "$OVERRIDE_FILE"
    autologin_removed=1
  else
    echo "Keeping $OVERRIDE_FILE (not written by lightXDM)."
  fi
fi
if [[ $autologin_removed -eq 1 ]]; then
  systemctl daemon-reload || [[ ! -d "${SYSTEMD_RUN_DIR:-/run/systemd/system}" ]]
  echo "Autologin configuration removed. Change will take effect at the next login or reboot."
elif [[ ! -f "$OVERRIDE_FILE" && ! -L "$OVERRIDE_FILE" ]]; then
  echo "No autologin drop-in found; skipping."
fi

save_edited_dotfile() {
  local src="$1"
  local edited_dest="${src}.lightxdm-edited" n=1
  if [[ -e "$edited_dest" || -L "$edited_dest" ]]; then
    while [[ -e "${edited_dest}.${n}" || -L "${edited_dest}.${n}" ]]; do
      n=$((n + 1))
    done
    edited_dest="${edited_dest}.${n}"
  fi
  echo "Saving edited $src to $edited_dest..."
  mv -- "$src" "$edited_dest"
}

# Restore the original Polkit rule or remove the installed rule
POLKIT_RULE="${POLKIT_RULE:-/etc/polkit-1/rules.d/49-nopasswd.rules}"
if [[ -e "${POLKIT_RULE}.lightxdm.bak" || -L "${POLKIT_RULE}.lightxdm.bak" ]]; then
  if [[ -L "$POLKIT_RULE" ]] ||
    { [[ -e "$POLKIT_RULE" ]] && ! files_match "$POLKIT_RULE" "$SCRIPT_DIR/polkit/49-nopasswd.rules"; }; then
    save_edited_dotfile "$POLKIT_RULE"
  fi
  echo "Restoring $POLKIT_RULE from backup..."
  mv -- "${POLKIT_RULE}.lightxdm.bak" "$POLKIT_RULE"
elif [[ -e "${POLKIT_RULE}.lightxdm.absent" || -L "${POLKIT_RULE}.lightxdm.absent" ]]; then
  if [[ -e "$POLKIT_RULE" || -L "$POLKIT_RULE" ]]; then
    if [[ -f "$POLKIT_RULE" && ! -L "$POLKIT_RULE" ]] && files_match "$POLKIT_RULE" "$SCRIPT_DIR/polkit/49-nopasswd.rules"; then
      echo "Removing Polkit rule..."
      rm -f "$POLKIT_RULE"
    else
      save_edited_dotfile "$POLKIT_RULE"
    fi
  fi
  rm -f -- "${POLKIT_RULE}.lightxdm.absent"
elif [[ -f "$POLKIT_RULE" && ! -L "$POLKIT_RULE" ]] && files_match "$POLKIT_RULE" "$SCRIPT_DIR/polkit/49-nopasswd.rules"; then
  echo "Removing Polkit rule..."
  rm -f "$POLKIT_RULE"
elif [[ -e "$POLKIT_RULE" || -L "$POLKIT_RULE" ]]; then
  echo "Keeping $POLKIT_RULE (not an unmodified lightXDM rule)."
else
  echo "No Polkit rule found; skipping."
fi

# Restore or remove user dotfiles
matches_lightxdm_template() {
  local dotfile="$1"
  local mode="${2:-}"
  local path="$TARGET_HOME/$dotfile"
  if [[ ! -f "$path" || -L "$path" ]]; then
    return 1
  fi
  case "$dotfile" in
    .bash_profile | .gpg-agent-gnome | .gpg-agent-kwallet)
      if [[ -f "$SCRIPT_DIR/dotfiles/$dotfile" ]] && files_match "$path" "$SCRIPT_DIR/dotfiles/$dotfile"; then
        return 0
      fi
      return 1
      ;;
  esac
  local templates=("$SCRIPT_DIR"/dotfiles/.xinitrc-*)
  if [[ "$mode" != "--bundled-only" ]]; then
    templates+=("$TARGET_HOME"/.config/lightxdm/.xinitrc-*)
  fi
  local tmpl
  for tmpl in "${templates[@]}"; do
    [[ "$tmpl" -ef "$path" ]] && continue
    if [[ -f "$tmpl" ]] && files_match "$path" "$tmpl"; then
      return 0
    fi
  done
  return 1
}

for dotfile in .bash_profile .xinitrc .gpg-agent-kwallet .gpg-agent-gnome; do
  if [[ -e "$TARGET_HOME/${dotfile}.lightxdm.bak" || -L "$TARGET_HOME/${dotfile}.lightxdm.bak" ]]; then
    if [[ -e "$TARGET_HOME/$dotfile" || -L "$TARGET_HOME/$dotfile" ]]; then
      if matches_lightxdm_template "$dotfile"; then
        rm -f -- "$TARGET_HOME/$dotfile"
      else
        save_edited_dotfile "$TARGET_HOME/$dotfile"
      fi
    fi
    echo "Restoring $TARGET_HOME/$dotfile from backup..."
    mv -- "$TARGET_HOME/${dotfile}.lightxdm.bak" "$TARGET_HOME/$dotfile"
    rm -f -- "$TARGET_HOME/${dotfile}.lightxdm.absent"
  elif [[ -e "$TARGET_HOME/${dotfile}.lightxdm.absent" || -L "$TARGET_HOME/${dotfile}.lightxdm.absent" ]]; then
    if [[ -e "$TARGET_HOME/$dotfile" || -L "$TARGET_HOME/$dotfile" ]]; then
      if matches_lightxdm_template "$dotfile"; then
        echo "Removing $TARGET_HOME/$dotfile..."
        rm -f -- "$TARGET_HOME/$dotfile"
      else
        save_edited_dotfile "$TARGET_HOME/$dotfile"
      fi
    fi
    rm -f -- "$TARGET_HOME/${dotfile}.lightxdm.absent"
  elif [[ -e "$TARGET_HOME/$dotfile" || -L "$TARGET_HOME/$dotfile" ]]; then
    if matches_lightxdm_template "$dotfile" --bundled-only; then
      echo "Removing $TARGET_HOME/$dotfile..."
      rm -f -- "$TARGET_HOME/$dotfile"
    else
      echo "Keeping $TARGET_HOME/$dotfile (not an unmodified lightXDM template)."
    fi
  fi
done

# Re-enable only display managers disabled by the installer
if [[ -f "$DM_STATE_FILE" ]]; then
  failed=()
  while IFS= read -r dm_unit || [[ -n "$dm_unit" ]]; do
    [[ -n "$dm_unit" ]] || continue
    if ! systemctl enable "$dm_unit"; then
      # A unit removed or masked since install cannot be re-enabled; do not block uninstall on it.
      case "$(systemctl is-enabled "$dm_unit" 2>/dev/null)" in
        not-found) echo "Warning: $dm_unit is not installed any more; skipping it." >&2 ;;
        masked | masked-runtime) echo "Warning: $dm_unit is masked; unmask it to use it again." >&2 ;;
        *) failed+=("$dm_unit") ;;
      esac
    fi
  done < "$DM_STATE_FILE"
  if [[ ${#failed[@]} -eq 0 ]]; then
    rm -f "$DM_STATE_FILE"
  else
    echo "Failed to re-enable display manager(s): ${failed[*]}" >&2
    printf '%s\n' "${failed[@]}" > "$DM_STATE_FILE"
    exit 1
  fi
fi
# install.sh creates the state directory even when it disables nothing.
rmdir --ignore-fail-on-non-empty "$(dirname -- "$DM_STATE_FILE")" 2>/dev/null || true

echo "Uninstall complete. Changes will take effect at the next login or reboot."
