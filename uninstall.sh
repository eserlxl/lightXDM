#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# uninstall.sh: Revert changes made by install scripts (PAM, autologin, Polkit)
set -e

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOGIN_FILE="${LOGIN_FILE:-/etc/pam.d/login}"
# Every keyring line lightXDM ever appended to the login file; install.sh keeps an identical list.
readonly LIGHTXDM_KEYRING_LINES=(
  "auth       optional   pam_kwallet5.so"
  "session    optional   pam_kwallet5.so force_run"
  "auth       optional   pam_gnome_keyring.so"
  "auth       optional   pam_gnome_keyring.so auto_start"
  "session    optional   pam_gnome_keyring.so auto_start"
)
readonly GNOME_SESSION_TYPE_DEST="${GNOME_SESSION_TYPE_DEST:-/etc/lightxdm/gnome-session-type.conf}"
DM_STATE_FILE="${DM_STATE_FILE:-/etc/lightxdm/disabled-display-managers}"
PAM_KEYRING_STATE="${PAM_KEYRING_STATE:-/etc/lightxdm/pam-keyring}"
PAM_LOGIN_BASE_STATE="${PAM_LOGIN_BASE_STATE:-/etc/lightxdm/pam-login-base}"
POLKIT_RULE="${POLKIT_RULE:-/etc/polkit-1/rules.d/49-nopasswd.rules}"

# Hashes of the Polkit rules older lightXDM versions installed at this path (git history of
# polkit/49-nopasswd.rules), pinned so an edit to that file cannot hide a copy users still have.
LIGHTXDM_OLD_POLKIT_HASHES=(
  b40b6310d9bd99611c1954dfbc28a18f3c8a579eacac9deb12b39806dc5ce01e
  dad6a3771ac75a4411fb4bff0a000ac97140b4d62b99919ea167c02a10f39aa6
  4bc421259361fb23b640176b88ea7df8a3c30e841fe38be2c24d48d5132f6262
  b6073bfb5c36b1df6f03a7e274646e4a2d71dcb5467855a0a4641b8a30c2dad4
  d7e2e00acab61ca5c7d081f86705d699fa81b4da85c6d4e8bdfc88cda1234fc2
  154c72602e1e8667b94446a2370dadff5f8328534572965f48788c76272fb43f
  5f0b2207f050dd9f56f748c54cb2956abbc894f5bb85aecc47cdbee230316b2a
)

files_match() {
  [[ "$(sha256sum < "$1")" == "$(sha256sum < "$2")" ]]
}

normalize_home_path() {
  local path="$1"
  while [[ "$path" == */ && "$path" != "/" ]]; do
    path="${path%/}"
  done
  printf '%s\n' "$path"
}

# Return 0 when target home is a non-symlink directory, 2 when it is a symlink, 1 otherwise.
target_home_is_safe() {
  local home="${1:-${TARGET_HOME:-}}"
  home="$(normalize_home_path "$home")"
  [[ -n "$home" ]] || return 1
  [[ ! -L "$home" ]] || return 2
  [[ -d "$home" ]]
}

# Verify $TARGET_HOME and every segment along relative directory $1 are non-symlink directories
# (or absent trailing segments when $2 == 1). Returns 2 on any symlink segment, 1 on missing/non-dir.
home_dir_is_safe() {
  local rel_dir="${1:-.}" allow_absent="${2:-0}" home cur seg
  local -a segments=()
  home="$(normalize_home_path "${TARGET_HOME:-}")"
  target_home_is_safe "$home" || return $?
  if [[ -z "$rel_dir" || "$rel_dir" == "." ]]; then
    return 0
  fi
  cur="$home"
  IFS=/ read -r -a segments <<<"$rel_dir"
  for seg in "${segments[@]}"; do
    [[ -n "$seg" && "$seg" != "." ]] || continue
    [[ "$seg" != ".." ]] || return 1
    if [[ "$cur" == "/" ]]; then
      cur="/$seg"
    else
      cur+="/$seg"
    fi
    if [[ -L "$cur" ]]; then
      return 2
    fi
    if [[ -d "$cur" ]]; then
      continue
    fi
    if [[ -e "$cur" ]]; then
      return 1
    fi
    if [[ "$allow_absent" == 1 ]]; then
      return 0
    fi
    return 1
  done
  return 0
}

home_parent_is_safe() {
  local rel="$1" allow_absent="${2:-0}" parent="."
  if [[ "$rel" == */* ]]; then
    parent="${rel%/*}"
    [[ -n "$parent" ]] || parent="."
  fi
  home_dir_is_safe "$parent" "$allow_absent"
}

save_edited_dotfile() {
  local src="$1" home
  if [[ -n "${TARGET_HOME:-}" ]]; then
    home="$(normalize_home_path "$TARGET_HOME")"
    if [[ "$home" != "/" && "$src" == "$home/"* ]]; then
      home_parent_is_safe "${src#"$home"/}" || return 1
    fi
  fi
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

# True for a regular file equal to any rule an older lightXDM version installed.
is_lightxdm_polkit_rule() {
  local path="$1" hash old
  [[ -f "$path" && ! -L "$path" ]] || return 1
  hash="$(sha256sum < "$path")"
  hash="${hash%% *}"
  for old in "${LIGHTXDM_OLD_POLKIT_HASHES[@]}"; do
    [[ "$hash" == "$old" ]] && return 0
  done
  return 1
}

# True when $1 is a regular file equal to any version of the bundled template for home dotfile $2
# (a file an older lightXDM installed), as pinned in dotfiles/template-history.sha256.
is_past_lightxdm_template() {
  local file="$1" pathspec hash
  case "$2" in
    .bash_profile) pathspec='dotfiles/.bash_profile' ;;
    .xinitrc) pathspec='dotfiles/.xinitrc*' ;;
    .wayland-session) pathspec='dotfiles/.wayland-session-*' ;;
    .gpg-agent-*) pathspec='dotfiles/.gpg-agent-*' ;;
    .config/autostart/lightxdm-gpg-agent-tty.desktop) pathspec='dotfiles/lightxdm-gpg-agent-tty.desktop' ;;
    *) return 1 ;;
  esac
  [[ -f "$file" && ! -L "$file" ]] || return 1
  hash="$(sha256sum <"$file")" || return 1
  grep -Fqx -- "${hash%% *}  $pathspec" "$SCRIPT_DIR/dotfiles/template-history.sha256" 2>/dev/null
}

# Print the recorded hash of what lightXDM last wrote into home dotfile $1, if there is one.
recorded_dotfile_sum() {
  local rel="$1" home state_dir file line sum="" LC_ALL=C
  home_dir_is_safe ".local/state/lightxdm" || return 0
  home="$(normalize_home_path "${TARGET_HOME:-}")"
  state_dir="$home/.local/state/lightxdm"
  file="$state_dir/installed-dotfiles"
  [[ -f "$file" && ! -L "$file" && -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "${line:66}" == "$rel" && "${line:64:2}" == "  " && "${line:0:64}" =~ ^[0-9a-f]{64}$ ]]; then
      sum="${line:0:64}"
    fi
  done <"$file"
  [[ -z "$sum" ]] || printf '%s\n' "$sum"
}

# Restore or remove user dotfiles
matches_lightxdm_template() {
  local dotfile="$1"
  local mode="${2:-}"
  local home path
  home_parent_is_safe "$dotfile" || return 1
  home="$(normalize_home_path "${TARGET_HOME:-}")"
  path="$home/$dotfile"
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
      if [[ "$mode" != "--bundled-only" ]] && home_dir_is_safe ".config/lightxdm"; then
        templates+=("$home"/.config/lightxdm/.wayland-session-*)
      fi
      ;;
    *)
      templates=("$SCRIPT_DIR"/dotfiles/.xinitrc-*)
      if [[ "$mode" != "--bundled-only" ]] && home_dir_is_safe ".config/lightxdm"; then
        templates+=("$home"/.config/lightxdm/.xinitrc-*)
      fi
      ;;
  esac
  local tmpl path_sum="" recorded_sum=""
  for tmpl in "${templates[@]}"; do
    [[ "$tmpl" -ef "$path" ]] && continue
    if [[ -f "$tmpl" ]] && files_match "$path" "$tmpl"; then
      return 0
    fi
  done
  if [[ "$mode" != "--bundled-only" ]]; then
    recorded_sum="$(recorded_dotfile_sum "$dotfile")"
    if [[ -n "$recorded_sum" ]]; then
      path_sum="$(sha256sum < "$path")"
      if [[ "${path_sum%% *}" == "$recorded_sum" ]]; then
        return 0
      fi
    fi
  fi
  is_past_lightxdm_template "$path" "$dotfile"
}

cleanup_home_dotfiles() {
  local home dotfile past_backup rc
  home="$(normalize_home_path "${TARGET_HOME:-}")"
  target_home_is_safe "$home" || return $?
  for dotfile in .bash_profile .xinitrc .wayland-session .gpg-agent-kwallet .gpg-agent-gnome .config/autostart/lightxdm-gpg-agent-tty.desktop; do
    rc=0
    home_parent_is_safe "$dotfile" || rc=$?
    if [[ $rc -ne 0 ]]; then
      if [[ $rc -eq 2 ]]; then
        echo "Warning: Refusing symlinked directory along $home/$dotfile." >&2
      fi
      continue
    fi
    # The current template install.sh --update put beside a dotfile the user edited.
    if [[ -f "$home/${dotfile}.lightxdm-new" && ! -L "$home/${dotfile}.lightxdm-new" ]]; then
      echo "Removing $home/${dotfile}.lightxdm-new..."
      rm -f -- "$home/${dotfile}.lightxdm-new"
    fi
    past_backup=0
    # A backup equal to an older bundled template is a lightXDM file an earlier install backed up
    # as the user's original: drop it and treat the dotfile as one lightXDM created.
    if is_past_lightxdm_template "$home/${dotfile}.lightxdm.bak" "$dotfile"; then
      echo "Removing $home/${dotfile}.lightxdm.bak (a file from an earlier lightXDM version)..."
      rm -f -- "$home/${dotfile}.lightxdm.bak"
      past_backup=1
    fi
    if [[ -e "$home/${dotfile}.lightxdm.bak" || -L "$home/${dotfile}.lightxdm.bak" ]]; then
      if [[ -e "$home/$dotfile" || -L "$home/$dotfile" ]]; then
        if matches_lightxdm_template "$dotfile"; then
          rm -f -- "$home/$dotfile"
        else
          save_edited_dotfile "$home/$dotfile"
        fi
      fi
      echo "Restoring $home/$dotfile from backup..."
      mv -T -- "$home/${dotfile}.lightxdm.bak" "$home/$dotfile"
      rm -f -- "$home/${dotfile}.lightxdm.absent"
    elif [[ $past_backup -eq 1 || -e "$home/${dotfile}.lightxdm.absent" || -L "$home/${dotfile}.lightxdm.absent" ]]; then
      if [[ -e "$home/$dotfile" || -L "$home/$dotfile" ]]; then
        if matches_lightxdm_template "$dotfile"; then
          echo "Removing $home/$dotfile..."
          rm -f -- "$home/$dotfile"
        else
          save_edited_dotfile "$home/$dotfile"
        fi
      fi
      rm -f -- "$home/${dotfile}.lightxdm.absent"
    elif [[ -e "$home/$dotfile" || -L "$home/$dotfile" ]]; then
      if matches_lightxdm_template "$dotfile" --bundled-only; then
        echo "Removing $home/$dotfile..."
        rm -f -- "$home/$dotfile"
      else
        echo "Keeping $home/$dotfile (not an unmodified lightXDM template)."
      fi
    fi
  done
}

# The .bash_profile respawn guard keeps launch timestamps here, and install.sh the choices --update
# reuses and what it wrote into each dotfile; copies under a custom XDG_STATE_HOME are not removed.
cleanup_home_state_dir() {
  local home state_dir state_file state_removed=0 rc=0
  home_dir_is_safe ".local/state/lightxdm" || rc=$?
  if [[ $rc -ne 0 ]]; then
    if [[ $rc -eq 2 ]]; then
      home="$(normalize_home_path "${TARGET_HOME:-}")"
      echo "Warning: Refusing symlinked directory along $home/.local/state/lightxdm." >&2
    fi
    return 0
  fi
  home="$(normalize_home_path "${TARGET_HOME:-}")"
  state_dir="$home/.local/state/lightxdm"
  for state_file in startx-attempts install-choices installed-dotfiles; do
    if [[ -f "$state_dir/$state_file" && ! -L "$state_dir/$state_file" ]]; then
      rm -f -- "$state_dir/$state_file"
      state_removed=1
    fi
  done
  if [[ $state_removed -eq 1 ]]; then
    rmdir --ignore-fail-on-non-empty -- "$state_dir" 2>/dev/null || true
  fi
}

main() {
  local keyring_only=0
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
    local passwd_entry target_uid
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

    TARGET_HOME="$(normalize_home_path "$TARGET_HOME")"
    if [[ -L "$TARGET_HOME" ]]; then
      echo "Error: Refusing symlinked target home directory: $TARGET_HOME" >&2
      exit 1
    fi
    if [[ ! -d "$TARGET_HOME" ]]; then
      echo "Error: Target home directory does not exist: $TARGET_HOME" >&2
      exit 1
    fi
  fi

  local BACKUP_FILE="${LOGIN_FILE}.lightxdm.bak"
  # Installs before 2026-11-03 backed up to .lightxde.bak.<epoch>; the oldest one is the original.
  if [[ ! -f "$BACKUP_FILE" || -L "$BACKUP_FILE" ]]; then
    local oldest_epoch="" old_backup epoch
    for old_backup in "${LOGIN_FILE}".lightxde.bak.*; do
      epoch="${old_backup##*.lightxde.bak.}"
      if [[ -f "$old_backup" && ! -L "$old_backup" && "$epoch" =~ ^[0-9]+$ ]] && { [[ -z "$oldest_epoch" ]] || ((10#$epoch < 10#$oldest_epoch)); }; then
        oldest_epoch="$epoch"
      fi
    done
    if [[ -n "$oldest_epoch" ]]; then
      BACKUP_FILE="${LOGIN_FILE}.lightxde.bak.${oldest_epoch}"
    fi
  fi

  # Remove GNOME session-type lines before comparing the login file with its backup.
  if [[ $keyring_only -eq 0 ]]; then
    local gnome_marker='# lightXDM: GNOME on TTY1 needs a wayland session type (uninstall.sh removes this)'
    local gnome_tty_gate='session    [success=2 default=ignore] pam_succeed_if.so quiet tty notin tty1:/dev/tty1'
    local gnome_user_gate_re='^session    \[success=1 default=ignore\] pam_succeed_if\.so quiet user != [abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._][abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*$'
    # Only lightXDM's own conffile: a user's pam_env line for another file stays.
    local gnome_env_line="session    optional   pam_env.so readenv=0 user_readenv=0 conffile=$GNOME_SESSION_TYPE_DEST"
    local gnome_pam_sed=()
    if [[ -f "$LOGIN_FILE" ]]; then
      local line_number=0 line
      while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        if [[ "$line" == "$gnome_marker" || "$line" == "$gnome_tty_gate" || "$line" =~ $gnome_user_gate_re || "$line" == "$gnome_env_line" ]]; then
          if [[ ! -f "$BACKUP_FILE" || -L "$BACKUP_FILE" ]] || ! grep -Fxq -- "$line" "$BACKUP_FILE"; then
            gnome_pam_sed+=(-e "${line_number}d")
          fi
        fi
      done < "$LOGIN_FILE"
      if [[ ${#gnome_pam_sed[@]} -gt 0 ]]; then
        sed -i --follow-symlinks "${gnome_pam_sed[@]}" "$LOGIN_FILE"
      fi
    fi
    rm -f -- "$GNOME_SESSION_TYPE_DEST"
    # The packaged login version install.sh --update recorded after a .pacnew merge; --keyring-only keeps
    # it for the GNOME block that stays.
    rm -f -- "$PAM_LOGIN_BASE_STATE"
  fi

  # Remove only the exact PAM lines configure_pam appends.
  if [[ -f "$BACKUP_FILE" && ! -L "$BACKUP_FILE" ]]; then
    if [[ ! -e "$LOGIN_FILE" ]]; then
      echo "Restoring $LOGIN_FILE from backup..."
      rm -f -- "$LOGIN_FILE"
      cp -p -- "$BACKUP_FILE" "$LOGIN_FILE"
      rm -f -- "$BACKUP_FILE"
    else
      # A line already present before install (it is in the backup) is the user's, not ours.
      local pam_sed=() pam_line pam_re
      for pam_line in "${LIGHTXDM_KEYRING_LINES[@]}"; do
        pam_re="^${pam_line//./\\.}\$"
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
        cp -p -- "$BACKUP_FILE" "$LOGIN_FILE"
        rm -f -- "$BACKUP_FILE"
      else
        echo "Removed lightXDM PAM lines from $LOGIN_FILE; backup kept for review: $BACKUP_FILE"
      fi
    fi
  else
    echo "No $BACKUP_FILE found; skipping PAM restore."
  fi
  # The keyring backend install.sh recorded for --update goes with its lines.
  rm -f -- "$PAM_KEYRING_STATE"

  if [[ $keyring_only -eq 1 ]]; then
    if [[ -f "$LOGIN_FILE" ]] && grep -Eq '^[[:space:]]*-?(auth|session)[[:space:]][^#]*(pam_kwallet5\.so|pam_gnome_keyring\.so)([[:space:]]|$)' "$LOGIN_FILE"; then
      echo "Warning: $LOGIN_FILE still configures PAM keyring unlock (lines lightXDM did not add); remove them by hand if you use autologin." >&2
    fi
    echo "Done (--keyring-only): dotfiles, autologin, the Polkit rule and display managers are unchanged."
    local autologin_status
    autologin_status="$(bash "$SCRIPT_DIR/enable-autologin.sh" --status 2>/dev/null)"
    if [[ "$autologin_status" != "enabled for"* && "$autologin_status" != *"still enables autologin."* ]]; then
      echo "To log in on TTY1 without a password, run: sudo $(printf 'bash %q' "$SCRIPT_DIR/enable-autologin.sh") ${SUDO_USER:-<user>}"
    fi
    exit 0
  fi

  # Remove the autologin drop-in and any legacy lightXDM-written override.conf (OVERRIDE_DIR
  # selects the getty@tty1 drop-in directory); a failed daemon-reload stops the uninstall.
  bash "$SCRIPT_DIR/enable-autologin.sh" --disable

  # Restore the original Polkit rule or remove the installed rule
  if [[ -e "${POLKIT_RULE}.lightxdm.bak" || -L "${POLKIT_RULE}.lightxdm.bak" ]]; then
    if [[ -L "$POLKIT_RULE" ]] ||
      { [[ -e "$POLKIT_RULE" ]] && ! is_lightxdm_polkit_rule "$POLKIT_RULE"; }; then
      save_edited_dotfile "$POLKIT_RULE"
    fi
    echo "Restoring $POLKIT_RULE from backup..."
    mv -T -- "${POLKIT_RULE}.lightxdm.bak" "$POLKIT_RULE"
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

  cleanup_home_dotfiles
  cleanup_home_state_dir

  # Re-enable only display managers disabled by the installer
  local re_enabled=()
  if [[ -L "$DM_STATE_FILE" ]]; then
    rm -f -- "$DM_STATE_FILE"
  elif [[ -f "$DM_STATE_FILE" ]]; then
    local failed=() dm_unit
    while IFS= read -r dm_unit || [[ -n "$dm_unit" ]]; do
      [[ -n "$dm_unit" ]] || continue
      if systemctl enable "$dm_unit"; then
        re_enabled+=("$dm_unit")
      else
        # A unit removed or masked since install cannot be re-enabled; do not block uninstall on it.
        case "$(systemctl is-enabled "$dm_unit" 2>/dev/null)" in
          not-found) echo "Warning: $dm_unit is not installed any more; skipping it." >&2 ;;
          masked | masked-runtime) echo "Warning: $dm_unit is masked; unmask it to use it again." >&2 ;;
          *) failed+=("$dm_unit") ;;
        esac
      fi
    done < "$DM_STATE_FILE"
    if [[ ${#failed[@]} -eq 0 ]]; then
      rm -f -- "$DM_STATE_FILE"
    else
      echo "Failed to re-enable display manager(s): ${failed[*]}" >&2
      local dm_dir dm_tmp=""
      dm_dir="$(dirname -- "$DM_STATE_FILE")"
      if dm_tmp="$(mktemp "$dm_dir/.disabled-display-managers.XXXXXX")" &&
        printf '%s\n' "${failed[@]}" >"$dm_tmp" &&
        chmod 644 -- "$dm_tmp" &&
        mv -Tf -- "$dm_tmp" "$DM_STATE_FILE"; then
        :
      else
        [[ -z "$dm_tmp" ]] || rm -f -- "$dm_tmp" 2>/dev/null || true
        echo "Warning: Could not update $DM_STATE_FILE." >&2
      fi
      exit 1
    fi
  fi
  # install.sh creates the state directory even when it disables nothing.
  rmdir --ignore-fail-on-non-empty "$(dirname -- "$DM_STATE_FILE")" 2>/dev/null || true

  if [[ ${#re_enabled[@]} -gt 0 ]]; then
    echo "Uninstall complete. Reboot to return to ${re_enabled[*]}: they are enabled for the next boot, not started now."
  else
    echo "Uninstall complete. Changes will take effect at the next login or reboot."
  fi
}

# Run only when executed directly, so tests can source the helpers.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
