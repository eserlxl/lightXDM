#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# uninstall.sh: Revert changes made by install scripts (PAM, autologin, Polkit)
set -e

keyring_only=0
if [[ $# -gt 0 ]]; then
  if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    echo "Usage: sudo bash $0 [-h|--help] [--keyring-only]"
    echo "  --keyring-only  remove only the keyring lines lightXDM added to /etc/pam.d/login (for switching to autologin)"
    echo "Run it with sudo from your user account; as root without sudo, set TARGET_HOME=/home/<user>."
    exit 0
  elif [[ $# -eq 1 && "$1" == "--keyring-only" ]]; then
    keyring_only=1
  else
    echo "Unknown option: $*" >&2
    echo "Usage: sudo bash $0 [-h|--help] [--keyring-only]" >&2
    exit 1
  fi
fi

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (with sudo)."
  exit 1
fi

# --keyring-only touches only PAM, so it needs no target home.
if [[ $keyring_only -eq 0 ]]; then
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
fi

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOGIN_FILE="${LOGIN_FILE:-/etc/pam.d/login}"
readonly GNOME_SESSION_TYPE_DEST="${GNOME_SESSION_TYPE_DEST:-/etc/lightxdm/gnome-session-type.conf}"
DM_STATE_FILE="${DM_STATE_FILE:-/etc/lightxdm/disabled-display-managers}"
BACKUP_FILE="${LOGIN_FILE}.lightxdm.bak"
# Installs before 2026-11-03 backed up to .lightxde.bak.<epoch>; the oldest one is the original.
if [[ ! -f "$BACKUP_FILE" ]]; then
  oldest_epoch=""
  for old_backup in "${LOGIN_FILE}".lightxde.bak.*; do
    epoch="${old_backup##*.lightxde.bak.}"
    if [[ -f "$old_backup" && "$epoch" =~ ^[0-9]+$ ]] && { [[ -z "$oldest_epoch" ]] || ((10#$epoch < 10#$oldest_epoch)); }; then
      oldest_epoch="$epoch"
    fi
  done
  if [[ -n "$oldest_epoch" ]]; then
    BACKUP_FILE="${LOGIN_FILE}.lightxde.bak.${oldest_epoch}"
  fi
fi

files_match() {
  [[ "$(sha256sum < "$1")" == "$(sha256sum < "$2")" ]]
}

# Remove GNOME session-type lines before comparing the login file with its backup.
if [[ $keyring_only -eq 0 ]]; then
  gnome_marker='# lightXDM: GNOME on TTY1 needs a wayland session type (uninstall.sh removes this)'
  gnome_tty_gate='session    [success=2 default=ignore] pam_succeed_if.so quiet tty notin tty1:/dev/tty1'
  gnome_user_gate_re='^session    \[success=1 default=ignore\] pam_succeed_if\.so quiet user != [abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._][abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*$'
  # Only lightXDM's own conffile: a user's pam_env line for another file stays.
  gnome_env_line="session    optional   pam_env.so readenv=0 user_readenv=0 conffile=$GNOME_SESSION_TYPE_DEST"
  gnome_pam_sed=()
  if [[ -f "$LOGIN_FILE" ]]; then
    line_number=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      line_number=$((line_number + 1))
      if [[ "$line" == "$gnome_marker" || "$line" == "$gnome_tty_gate" || "$line" =~ $gnome_user_gate_re || "$line" == "$gnome_env_line" ]]; then
        if [[ ! -f "$BACKUP_FILE" ]] || ! grep -Fxq -- "$line" "$BACKUP_FILE"; then
          gnome_pam_sed+=(-e "${line_number}d")
        fi
      fi
    done < "$LOGIN_FILE"
    if [[ ${#gnome_pam_sed[@]} -gt 0 ]]; then
      sed -i --follow-symlinks "${gnome_pam_sed[@]}" "$LOGIN_FILE"
    fi
  fi
  rm -f -- "$GNOME_SESSION_TYPE_DEST"
fi

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
      '^auth       optional   pam_gnome_keyring\.so auto_start$' \
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
  if [[ -f "$LOGIN_FILE" ]] && grep -Eq '^[[:space:]]*-?(auth|session)[[:space:]][^#]*(pam_kwallet5\.so|pam_gnome_keyring\.so)([[:space:]]|$)' "$LOGIN_FILE"; then
    echo "Warning: $LOGIN_FILE still configures PAM keyring unlock (lines lightXDM did not add); remove them by hand if you use autologin." >&2
  fi
  echo "Done (--keyring-only): dotfiles, autologin, the Polkit rule and display managers are unchanged."
  exit 0
fi

# Remove the autologin drop-in and any legacy lightXDM-written override.conf (OVERRIDE_DIR
# selects the getty@tty1 drop-in directory); a failed daemon-reload stops the uninstall.
bash "$SCRIPT_DIR/enable-autologin.sh" --disable

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
  mv -T -- "$src" "$edited_dest"
}

# Hashes of the Polkit rules older lightXDM versions installed at this path (git history of polkit/49-nopasswd.rules).
LIGHTXDM_OLD_POLKIT_HASHES=(
  b40b6310d9bd99611c1954dfbc28a18f3c8a579eacac9deb12b39806dc5ce01e
  dad6a3771ac75a4411fb4bff0a000ac97140b4d62b99919ea167c02a10f39aa6
  4bc421259361fb23b640176b88ea7df8a3c30e841fe38be2c24d48d5132f6262
  b6073bfb5c36b1df6f03a7e274646e4a2d71dcb5467855a0a4641b8a30c2dad4
  d7e2e00acab61ca5c7d081f86705d699fa81b4da85c6d4e8bdfc88cda1234fc2
  154c72602e1e8667b94446a2370dadff5f8328534572965f48788c76272fb43f
)

# True for a regular file equal to the current rule or to any rule an older lightXDM version installed.
is_lightxdm_polkit_rule() {
  local path="$1" hash old
  [[ -f "$path" && ! -L "$path" ]] || return 1
  files_match "$path" "$SCRIPT_DIR/polkit/49-nopasswd.rules" && return 0
  hash="$(sha256sum < "$path")"
  hash="${hash%% *}"
  for old in "${LIGHTXDM_OLD_POLKIT_HASHES[@]}"; do
    [[ "$hash" == "$old" ]] && return 0
  done
  return 1
}

# Restore the original Polkit rule or remove the installed rule
POLKIT_RULE="${POLKIT_RULE:-/etc/polkit-1/rules.d/49-nopasswd.rules}"
if [[ -e "${POLKIT_RULE}.lightxdm.bak" || -L "${POLKIT_RULE}.lightxdm.bak" ]]; then
  if [[ -L "$POLKIT_RULE" ]] ||
    { [[ -e "$POLKIT_RULE" ]] && ! is_lightxdm_polkit_rule "$POLKIT_RULE"; }; then
    save_edited_dotfile "$POLKIT_RULE"
  fi
  echo "Restoring $POLKIT_RULE from backup..."
  mv -- "${POLKIT_RULE}.lightxdm.bak" "$POLKIT_RULE"
elif [[ -e "${POLKIT_RULE}.lightxdm.absent" || -L "${POLKIT_RULE}.lightxdm.absent" ]]; then
  if [[ -e "$POLKIT_RULE" || -L "$POLKIT_RULE" ]]; then
    if is_lightxdm_polkit_rule "$POLKIT_RULE"; then
      echo "Removing Polkit rule..."
      rm -f "$POLKIT_RULE"
    else
      save_edited_dotfile "$POLKIT_RULE"
    fi
  fi
  rm -f -- "${POLKIT_RULE}.lightxdm.absent"
elif is_lightxdm_polkit_rule "$POLKIT_RULE"; then
  echo "Removing Polkit rule..."
  rm -f "$POLKIT_RULE"
elif [[ -e "$POLKIT_RULE" || -L "$POLKIT_RULE" ]]; then
  echo "Keeping $POLKIT_RULE (not an unmodified lightXDM rule)."
else
  echo "No Polkit rule found; skipping."
fi

# True when $1 is a regular file equal to any version of the bundled template for home dotfile $2
# in this checkout's git history (a file an older lightXDM installed); false without .git or git.
is_past_lightxdm_template() {
  local file="$1" pathspec blob history
  case "$2" in
    .bash_profile) pathspec='dotfiles/.bash_profile' ;;
    .xinitrc) pathspec='dotfiles/.xinitrc*' ;;
    .wayland-session) pathspec='dotfiles/.wayland-session-*' ;;
    .gpg-agent-*) pathspec='dotfiles/.gpg-agent-*' ;;
    .config/autostart/lightxdm-gpg-agent-tty.desktop) pathspec='dotfiles/lightxdm-gpg-agent-tty.desktop' ;;
    *) return 1 ;;
  esac
  [[ -f "$file" && ! -L "$file" && -e "$SCRIPT_DIR/.git" ]] || return 1
  command -v git >/dev/null || return 1
  # safe.directory: uninstall.sh runs as root on a clone the user owns.
  blob="$(git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" hash-object --no-filters --stdin <"$file" 2>/dev/null)" || return 1
  history="$(git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" log --format= --raw --no-abbrev -- "$pathspec" 2>/dev/null)" || return 1
  # Raw lines read ":<mode> <mode> <old-blob> <new-blob> <status>\t<path>".
  [[ -n "$blob" && "$history" == *" $blob "* ]]
}

# Restore or remove user dotfiles
matches_lightxdm_template() {
  local dotfile="$1"
  local mode="${2:-}"
  local path="$TARGET_HOME/$dotfile"
  if [[ ! -f "$path" || -L "$path" ]]; then
    return 1
  fi
  local templates=()
  case "$dotfile" in
    .bash_profile)
      templates=("$SCRIPT_DIR/dotfiles/$dotfile")
      ;;
    .gpg-agent-gnome | .gpg-agent-kwallet)
      templates=("$SCRIPT_DIR/dotfiles/.gpg-agent-gnome")
      ;;
    .config/autostart/lightxdm-gpg-agent-tty.desktop)
      templates=("$SCRIPT_DIR/dotfiles/lightxdm-gpg-agent-tty.desktop")
      ;;
    .wayland-session)
      templates=("$SCRIPT_DIR"/dotfiles/.wayland-session-*)
      if [[ "$mode" != "--bundled-only" ]]; then
        templates+=("$TARGET_HOME"/.config/lightxdm/.wayland-session-*)
      fi
      ;;
    *)
      templates=("$SCRIPT_DIR"/dotfiles/.xinitrc-*)
      if [[ "$mode" != "--bundled-only" ]]; then
        templates+=("$TARGET_HOME"/.config/lightxdm/.xinitrc-*)
      fi
      ;;
  esac
  local tmpl
  for tmpl in "${templates[@]}"; do
    [[ "$tmpl" -ef "$path" ]] && continue
    if [[ -f "$tmpl" ]] && files_match "$path" "$tmpl"; then
      return 0
    fi
  done
  is_past_lightxdm_template "$path" "$dotfile"
}

for dotfile in .bash_profile .xinitrc .wayland-session .gpg-agent-kwallet .gpg-agent-gnome .config/autostart/lightxdm-gpg-agent-tty.desktop; do
  past_backup=0
  # A backup equal to an older bundled template is a lightXDM file an earlier install backed up
  # as the user's original: drop it and treat the dotfile as one lightXDM created.
  if is_past_lightxdm_template "$TARGET_HOME/${dotfile}.lightxdm.bak" "$dotfile"; then
    echo "Removing $TARGET_HOME/${dotfile}.lightxdm.bak (a file from an earlier lightXDM version)..."
    rm -f -- "$TARGET_HOME/${dotfile}.lightxdm.bak"
    past_backup=1
  fi
  if [[ -e "$TARGET_HOME/${dotfile}.lightxdm.bak" || -L "$TARGET_HOME/${dotfile}.lightxdm.bak" ]]; then
    if [[ -e "$TARGET_HOME/$dotfile" || -L "$TARGET_HOME/$dotfile" ]]; then
      if matches_lightxdm_template "$dotfile"; then
        rm -f -- "$TARGET_HOME/$dotfile"
      else
        save_edited_dotfile "$TARGET_HOME/$dotfile"
      fi
    fi
    echo "Restoring $TARGET_HOME/$dotfile from backup..."
    mv -T -- "$TARGET_HOME/${dotfile}.lightxdm.bak" "$TARGET_HOME/$dotfile"
    rm -f -- "$TARGET_HOME/${dotfile}.lightxdm.absent"
  elif [[ $past_backup -eq 1 || -e "$TARGET_HOME/${dotfile}.lightxdm.absent" || -L "$TARGET_HOME/${dotfile}.lightxdm.absent" ]]; then
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

# The .bash_profile respawn guard keeps launch timestamps here; a copy under a custom XDG_STATE_HOME is not removed.
attempts_dir="$TARGET_HOME/.local/state/lightxdm"
if [[ ! -L "$attempts_dir" && -f "$attempts_dir/startx-attempts" && ! -L "$attempts_dir/startx-attempts" ]]; then
  rm -f -- "$attempts_dir/startx-attempts"
  rmdir --ignore-fail-on-non-empty -- "$attempts_dir" 2>/dev/null || true
fi

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
