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

DRY_RUN_JSON=0
DRY_NEEDS_ROOT=false
DRY_ACTIONS=()
DRY_WARNINGS=()
DRY_NOTES=()
DRY_DOTFILE_JSON=()
DRY_SHELL_HOOK_JSON=()
DRY_STATE_FILE_JSON=()
DRY_STATE_DIR=""
DRY_STATE_DIR_STATUS="absent"
DRY_STATE_DIR_REMOVE=false
DRY_LAST_EDITED_DEST=""

json_escape() {
  local s="$1" out="" i ch code LC_ALL=C
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\b'/\\b}"
  s="${s//$'\f'/\\f}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  if [[ "$s" == *[$'\001'-$'\037']* ]]; then
    for ((i = 0; i < ${#s}; i++)); do
      ch="${s:i:1}"
      if [[ "$ch" == [$'\001'-$'\037'] ]]; then
        printf -v code '%d' "'$ch"
        printf -v ch '\\u%04x' "$code"
      fi
      out+="$ch"
    done
    printf '%s' "$out"
    return 0
  fi
  printf '%s' "$s"
}

json_str() {
  printf '"%s"' "$(json_escape "$1")"
}

json_str_or_null() {
  if [[ -n "$1" ]]; then
    json_str "$1"
  else
    printf 'null'
  fi
}

print_json_string_array() {
  local first=1 item
  printf '['
  for item in "$@"; do
    [[ $first -eq 1 ]] || printf ', '
    first=0
    json_str "$item"
  done
  printf ']'
}

dry_action() {
  DRY_ACTIONS+=("$1")
  if [[ $DRY_RUN_JSON -eq 0 ]]; then
    echo "$1"
  fi
}

dry_warn_err() {
  DRY_WARNINGS+=("$1")
  if [[ $DRY_RUN_JSON -eq 0 ]]; then
    echo "$1" >&2
  fi
}

dry_warn_out() {
  DRY_WARNINGS+=("$1")
  if [[ $DRY_RUN_JSON -eq 0 ]]; then
    echo "$1"
  fi
}

dry_note() {
  DRY_NOTES+=("$1")
  if [[ $DRY_RUN_JSON -eq 0 ]]; then
    echo "$1"
  fi
}

append_dry_dotfile_json() {
  local dotfile="$1" path="$2" action="$3" rm_new="$4" rm_past="$5" rm_absent="$6" edited_backup="$7"
  local obj
  printf -v obj '{"dotfile": %s, "path": %s, "action": %s, "remove_pending_update": %s, "remove_past_backup": %s, "remove_absent_marker": %s, "edited_backup": %s}' \
    "$(json_str "$dotfile")" \
    "$(json_str "$path")" \
    "$(json_str "$action")" \
    "$rm_new" \
    "$rm_past" \
    "$rm_absent" \
    "$(json_str_or_null "$edited_backup")"
  DRY_DOTFILE_JSON+=("$obj")
}

append_dry_shell_hook_json() {
  local path="$1" status="$2" obj
  printf -v obj '{"path": %s, "status": %s}' "$(json_str "$path")" "$(json_str "$status")"
  DRY_SHELL_HOOK_JSON+=("$obj")
}

append_dry_state_file_json() {
  local name="$1" path="$2" status="$3" obj
  printf -v obj '{"name": %s, "path": %s, "status": %s}' "$(json_str "$name")" "$(json_str "$path")" "$(json_str "$status")"
  DRY_STATE_FILE_JSON+=("$obj")
}

files_match() {
  [[ "$(sha256sum < "$1")" == "$(sha256sum < "$2")" ]]
}

# True when $1 needs root access to inspect (unreadable entry or unsearchable parent directory;
# pass $2=1 to inspect symlinked targets rather than ignoring symlinks).
path_needs_sudo() {
  local path="$1" follow_symlink="${2:-0}" dir target
  [[ $EUID -ne 0 ]] || return 1
  if [[ -L "$path" ]]; then
    if [[ $follow_symlink -eq 0 ]]; then
      return 1
    fi
    if [[ -e "$path" ]]; then
      [[ ! -r "$path" ]] && return 0
      return 1
    fi
    target="$(readlink -m -- "$path" 2>/dev/null || true)"
    [[ -n "$target" ]] || return 1
    dir="$target"
  elif [[ -e "$path" ]]; then
    if [[ ! -r "$path" ]]; then
      return 0
    fi
    return 1
  else
    dir="$path"
  fi
  while [[ "$dir" == */* ]]; do
    dir="${dir%/*}"
    [[ -n "$dir" ]] || dir="/"
    if [[ -d "$dir" ]]; then
      if [[ ! -x "$dir" ]]; then
        return 0
      fi
      return 1
    elif [[ -e "$dir" || -L "$dir" ]]; then
      return 1
    fi
    [[ "$dir" == "/" ]] && break
  done
  return 1
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
# (or absent trailing segments when $2 == 1). Returns 2 on any symlink segment, 3 on an
# unsearchable directory for non-root, 1 on missing/non-dir.
home_dir_is_safe() {
  local rel_dir="${1:-.}" allow_absent="${2:-0}" home cur seg
  local -a segments=()
  home="$(normalize_home_path "${TARGET_HOME:-}")"
  target_home_is_safe "$home" || return $?
  if [[ $EUID -ne 0 && ! -x "$home" ]]; then
    return 3
  fi
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
      if [[ $EUID -ne 0 && ! -x "$cur" ]]; then
        return 3
      fi
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

next_edited_dotfile_dest() {
  local src="$1" edited_dest="${1}.lightxdm-edited" n=1
  if [[ -e "$edited_dest" || -L "$edited_dest" ]]; then
    while [[ -e "${edited_dest}.${n}" || -L "${edited_dest}.${n}" ]]; do
      n=$((n + 1))
    done
    edited_dest="${edited_dest}.${n}"
  fi
  printf '%s\n' "$edited_dest"
}

save_edited_dotfile() {
  local src="$1" dry_run="${2:-0}" home
  if [[ -n "${TARGET_HOME:-}" ]]; then
    home="$(normalize_home_path "$TARGET_HOME")"
    if [[ "$home" != "/" && "$src" == "$home/"* ]]; then
      home_parent_is_safe "${src#"$home"/}" || return 1
    fi
  fi
  local edited_dest
  edited_dest="$(next_edited_dotfile_dest "$src")"
  DRY_LAST_EDITED_DEST="$edited_dest"
  if [[ $dry_run -eq 1 ]]; then
    dry_action "Would save edited $src to $edited_dest."
    return 0
  fi
  echo "Saving edited $src to $edited_dest..."
  mv -T -- "$src" "$edited_dest"
}

# True for a regular file equal to any rule an older lightXDM version installed.
is_lightxdm_polkit_rule() {
  local path="$1" hash old
  [[ -f "$path" && ! -L "$path" && -r "$path" ]] || return 1
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
  if [[ ! -f "$path" || -L "$path" || ! -r "$path" ]]; then
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
    if [[ -f "$tmpl" && -r "$tmpl" ]] && files_match "$path" "$tmpl"; then
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

SHELL_HOOK_BEGIN="# >>> lightXDM TTY1 auto-start >>>"
SHELL_HOOK_END="# <<< lightXDM TTY1 auto-start <<<"

is_safe_rel_hook_path() {
  local rel="$1" seg
  local -a segs=()
  [[ -n "$rel" && "$rel" != /* && "$rel" != */ && "$rel" != *//* ]] || return 1
  IFS=/ read -r -a segs <<<"$rel"
  for seg in "${segs[@]}"; do
    [[ -n "$seg" && "$seg" != "." && "$seg" != ".." ]] || return 1
  done
  return 0
}

resolve_home_subpath() {
  local home="$1" raw="$2" seg out="" base=""
  local -a segs=()
  [[ -n "$raw" && "$raw" == /* ]] || return 1
  IFS=/ read -r -a segs <<<"$raw"
  for seg in "${segs[@]}"; do
    [[ -n "$seg" && "$seg" != "." ]] || continue
    [[ "$seg" != ".." ]] || return 1
    out+="/$seg"
  done
  [[ -n "$out" ]] || out="/"
  if [[ "$out" == "$home" ]]; then
    base=""
  elif [[ "$home" == "/" ]]; then
    base="${out#/}"
  elif [[ "$out" == "$home/"* ]]; then
    base="${out#"$home"/}"
  else
    return 1
  fi
  printf '%s\n' "$base"
}

cleanup_shell_hooks() {
  local dry_run="${1:-0}" home rc rel target marker_info bc ec bl el tmp
  local hooks_file line env_sub env_rel existing
  local -a hook_rels=(.zprofile .config/fish/config.fish)
  home="$(normalize_home_path "${TARGET_HOME:-}")"
  target_home_is_safe "$home" || return $?

  _add_shell_hook_rel() {
    local candidate="$1"
    is_safe_rel_hook_path "$candidate" || return 0
    for existing in "${hook_rels[@]}"; do
      [[ "$existing" == "$candidate" ]] && return 0
    done
    hook_rels+=("$candidate")
  }

  [[ "$home" == "/" ]] && hooks_file="/.local/state/lightxdm/installed-shell-hooks" || hooks_file="$home/.local/state/lightxdm/installed-shell-hooks"
  rc=0
  home_dir_is_safe ".local/state/lightxdm" || rc=$?
  if [[ $rc -eq 3 ]]; then
    dry_warn_err "Warning: Cannot read $hooks_file; skipping custom shell hook lookup."
    if [[ $dry_run -eq 1 && $EUID -ne 0 ]]; then
      DRY_NEEDS_ROOT=true
    fi
  elif [[ $rc -eq 0 ]]; then
    if [[ -L "$hooks_file" ]]; then
      dry_warn_err "Warning: Refusing symlinked shell hook record $hooks_file."
    elif [[ -f "$hooks_file" ]]; then
      if [[ -r "$hooks_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
          _add_shell_hook_rel "$line"
        done <"$hooks_file"
      else
        dry_warn_err "Warning: Cannot read $hooks_file; skipping custom shell hook lookup."
        if [[ $dry_run -eq 1 && $EUID -ne 0 ]]; then
          DRY_NEEDS_ROOT=true
        fi
      fi
    fi
  fi

  if [[ -n "${ZDOTDIR:-}" ]] && env_sub="$(resolve_home_subpath "$home" "$ZDOTDIR")"; then
    env_rel="${env_sub:+$env_sub/}.zprofile"
    _add_shell_hook_rel "$env_rel"
  fi
  if [[ -n "${XDG_CONFIG_HOME:-}" ]] && env_sub="$(resolve_home_subpath "$home" "$XDG_CONFIG_HOME")"; then
    env_rel="${env_sub:+$env_sub/}fish/config.fish"
    _add_shell_hook_rel "$env_rel"
  fi

  for rel in "${hook_rels[@]}"; do
    rc=0
    home_parent_is_safe "$rel" || rc=$?
    [[ "$home" == "/" ]] && target="/$rel" || target="$home/$rel"
    if [[ $rc -eq 2 ]]; then
      dry_warn_err "Warning: Refusing symlinked directory along $target."
      [[ $dry_run -eq 1 ]] && append_dry_shell_hook_json "$target" "refused-symlink-dir"
      continue
    elif [[ $rc -eq 3 ]]; then
      dry_warn_err "Warning: Cannot read $target; skipping shell hook cleanup."
      if [[ $dry_run -eq 1 ]]; then
        [[ $EUID -ne 0 ]] && DRY_NEEDS_ROOT=true
        append_dry_shell_hook_json "$target" "unknown-needs-root"
      fi
      continue
    elif [[ $rc -ne 0 ]]; then
      [[ $dry_run -eq 1 ]] && append_dry_shell_hook_json "$target" "absent"
      continue
    fi
    if [[ -L "$target" ]]; then
      dry_warn_err "Warning: Refusing symlinked shell config $target."
      [[ $dry_run -eq 1 ]] && append_dry_shell_hook_json "$target" "refused-symlink-file"
      continue
    fi
    if [[ ! -f "$target" ]]; then
      [[ $dry_run -eq 1 ]] && append_dry_shell_hook_json "$target" "absent"
      continue
    fi
    if [[ ! -r "$target" ]]; then
      dry_warn_err "Warning: Cannot read $target; skipping shell hook cleanup."
      if [[ $dry_run -eq 1 ]]; then
        [[ $EUID -ne 0 ]] && DRY_NEEDS_ROOT=true
        append_dry_shell_hook_json "$target" "unknown-needs-root"
      fi
      continue
    fi

    marker_info="$(awk -v b="$SHELL_HOOK_BEGIN" -v e="$SHELL_HOOK_END" '
      $0 == b { bc++; if (!bl) bl = NR }
      $0 == e { ec++; if (!el) el = NR }
      END { printf "%d %d %d %d\n", bc+0, ec+0, bl+0, el+0 }
    ' "$target")"
    read -r bc ec bl el <<<"$marker_info"
    if [[ $bc -eq 0 && $ec -eq 0 ]]; then
      [[ $dry_run -eq 1 ]] && append_dry_shell_hook_json "$target" "no-hook"
      continue
    fi
    if [[ $bc -ne 1 || $ec -ne 1 || $bl -ge $el ]]; then
      dry_warn_err "Warning: Malformed lightXDM hook markers in $target; leaving untouched."
      [[ $dry_run -eq 1 ]] && append_dry_shell_hook_json "$target" "malformed-markers"
      continue
    fi

    if [[ $dry_run -eq 1 ]]; then
      dry_action "Would remove managed lightXDM TTY1 auto-start hook from $target"
      append_dry_shell_hook_json "$target" "remove"
      continue
    fi

    tmp="$(mktemp "${target%/*}/.${target##*/}.lightxdm.XXXXXX")" || {
      echo "Warning: Failed to create temp file for $target; leaving untouched." >&2
      continue
    }
    if ! awk -v b="$SHELL_HOOK_BEGIN" -v e="$SHELL_HOOK_END" '
      $0 == b { skip = 1; next }
      $0 == e { skip = 0; next }
      !skip { print }
    ' "$target" >"$tmp"; then
      rm -f -- "$tmp"
      echo "Warning: Failed stripping managed hook from $target." >&2
      continue
    fi

    if [[ ! -s "$tmp" ]]; then
      rm -f -- "$tmp" "$target"
      echo "Removed managed lightXDM shell hook file $target."
    else
      if [[ $EUID -eq 0 ]]; then
        if ! chown --reference="$target" -- "$tmp"; then
          rm -f -- "$tmp"
          continue
        fi
      fi
      if ! { chmod --reference="$target" -- "$tmp" && mv -Tf -- "$tmp" "$target"; }; then
        rm -f -- "$tmp"
        echo "Warning: Failed updating $target; leaving untouched." >&2
        continue
      fi
      echo "Removed managed lightXDM TTY1 auto-start hook from $target."
    fi
  done
}

cleanup_home_dotfiles() {
  local dry_run="${1:-0}" home dotfile past_backup rc
  local df_action df_rm_new df_rm_past df_rm_absent df_edited_backup
  home="$(normalize_home_path "${TARGET_HOME:-}")"
  target_home_is_safe "$home" || return $?
  cleanup_shell_hooks "${1:-0}"
  for dotfile in .bash_profile .xinitrc .wayland-session .gpg-agent-kwallet .gpg-agent-gnome .config/autostart/lightxdm-gpg-agent-tty.desktop; do
    df_action="absent"
    df_rm_new=false
    df_rm_past=false
    df_rm_absent=false
    df_edited_backup=""
    rc=0
    home_parent_is_safe "$dotfile" || rc=$?
    if [[ $rc -ne 0 ]]; then
      if [[ $rc -eq 2 ]]; then
        dry_warn_err "Warning: Refusing symlinked directory along $home/$dotfile."
        [[ $dry_run -eq 1 ]] && append_dry_dotfile_json "$dotfile" "$home/$dotfile" "refused-symlink-dir" false false false ""
      elif [[ $rc -eq 3 ]]; then
        if [[ $dry_run -eq 1 ]]; then
          dry_action "Skipped check on $home/$dotfile (parent directory unsearchable without root)."
          DRY_NEEDS_ROOT=true
          append_dry_dotfile_json "$dotfile" "$home/$dotfile" "unknown-needs-root" false false false ""
        else
          dry_warn_err "Warning: Cannot access parent directory of $home/$dotfile; skipping dotfile cleanup."
        fi
      else
        [[ $dry_run -eq 1 ]] && append_dry_dotfile_json "$dotfile" "$home/$dotfile" "absent" false false false ""
      fi
      continue
    fi
    # The current template install.sh --update put beside a dotfile the user edited.
    if [[ -f "$home/${dotfile}.lightxdm-new" && ! -L "$home/${dotfile}.lightxdm-new" ]]; then
      df_rm_new=true
      if [[ $dry_run -eq 1 ]]; then
        dry_action "Would remove $home/${dotfile}.lightxdm-new."
      else
        echo "Removing $home/${dotfile}.lightxdm-new..."
        rm -f -- "$home/${dotfile}.lightxdm-new"
      fi
    fi
    past_backup=0
    # A backup equal to an older bundled template is a lightXDM file an earlier install backed up
    # as the user's original: drop it and treat the dotfile as one lightXDM created.
    if [[ -r "$home/${dotfile}.lightxdm.bak" ]] && is_past_lightxdm_template "$home/${dotfile}.lightxdm.bak" "$dotfile"; then
      df_rm_past=true
      if [[ $dry_run -eq 1 ]]; then
        dry_action "Would remove $home/${dotfile}.lightxdm.bak (a file from an earlier lightXDM version)."
      else
        echo "Removing $home/${dotfile}.lightxdm.bak (a file from an earlier lightXDM version)..."
        rm -f -- "$home/${dotfile}.lightxdm.bak"
      fi
      past_backup=1
    fi
    if [[ $past_backup -eq 0 ]] && [[ -e "$home/${dotfile}.lightxdm.bak" || -L "$home/${dotfile}.lightxdm.bak" ]]; then
      local backup_msg="Would restore $home/$dotfile from backup."
      df_action="restore-from-backup"
      if [[ -e "$home/$dotfile" || -L "$home/$dotfile" ]]; then
        if [[ $dry_run -eq 1 && ! -L "$home/$dotfile" && ! -r "$home/$dotfile" ]]; then
          backup_msg="Would restore $home/$dotfile from backup (existing file unreadable without root to check edits)."
          DRY_NEEDS_ROOT=true
          df_action="restore-from-backup-unreadable"
        elif matches_lightxdm_template "$dotfile"; then
          if [[ $dry_run -eq 0 ]]; then
            rm -f -- "$home/$dotfile"
          fi
        else
          DRY_LAST_EDITED_DEST=""
          save_edited_dotfile "$home/$dotfile" "$dry_run"
          df_edited_backup="$DRY_LAST_EDITED_DEST"
          df_action="save-edited-and-restore-from-backup"
        fi
      fi
      if [[ $dry_run -eq 1 ]]; then
        dry_action "$backup_msg"
        if [[ -e "$home/${dotfile}.lightxdm.absent" || -L "$home/${dotfile}.lightxdm.absent" ]]; then
          dry_action "Would remove $home/${dotfile}.lightxdm.absent."
          df_rm_absent=true
        fi
      else
        echo "Restoring $home/$dotfile from backup..."
        mv -T -- "$home/${dotfile}.lightxdm.bak" "$home/$dotfile"
        rm -f -- "$home/${dotfile}.lightxdm.absent"
      fi
    elif [[ $past_backup -eq 1 || -e "$home/${dotfile}.lightxdm.absent" || -L "$home/${dotfile}.lightxdm.absent" ]]; then
      df_action="remove-markers"
      if [[ -e "$home/$dotfile" || -L "$home/$dotfile" ]]; then
        if [[ $dry_run -eq 1 && ! -L "$home/$dotfile" && ! -r "$home/$dotfile" ]]; then
          dry_action "Skipped check on $home/$dotfile (unreadable without root)."
          DRY_NEEDS_ROOT=true
          df_action="unknown-needs-root"
        elif matches_lightxdm_template "$dotfile"; then
          df_action="remove"
          if [[ $dry_run -eq 1 ]]; then
            dry_action "Would remove $home/$dotfile."
          else
            echo "Removing $home/$dotfile..."
            rm -f -- "$home/$dotfile"
          fi
        else
          DRY_LAST_EDITED_DEST=""
          save_edited_dotfile "$home/$dotfile" "$dry_run"
          df_edited_backup="$DRY_LAST_EDITED_DEST"
          df_action="save-edited"
        fi
      fi
      if [[ $dry_run -eq 1 ]]; then
        if [[ -e "$home/${dotfile}.lightxdm.absent" || -L "$home/${dotfile}.lightxdm.absent" ]]; then
          dry_action "Would remove $home/${dotfile}.lightxdm.absent."
          df_rm_absent=true
        fi
      else
        rm -f -- "$home/${dotfile}.lightxdm.absent"
      fi
    elif [[ -e "$home/$dotfile" || -L "$home/$dotfile" ]]; then
      if [[ $dry_run -eq 1 && ! -L "$home/$dotfile" && ! -r "$home/$dotfile" ]]; then
        dry_action "Skipped check on $home/$dotfile (unreadable without root)."
        DRY_NEEDS_ROOT=true
        df_action="unknown-needs-root"
      elif matches_lightxdm_template "$dotfile" --bundled-only; then
        df_action="remove"
        if [[ $dry_run -eq 1 ]]; then
          dry_action "Would remove $home/$dotfile."
        else
          echo "Removing $home/$dotfile..."
          rm -f -- "$home/$dotfile"
        fi
      else
        df_action="keep"
        if [[ $dry_run -eq 1 ]]; then
          dry_action "Would keep $home/$dotfile (not an unmodified lightXDM template)."
        else
          echo "Keeping $home/$dotfile (not an unmodified lightXDM template)."
        fi
      fi
    elif [[ "$df_rm_new" == true ]]; then
      df_action="remove-pending-update"
    fi
    if [[ $dry_run -eq 1 ]]; then
      append_dry_dotfile_json "$dotfile" "$home/$dotfile" "$df_action" "$df_rm_new" "$df_rm_past" "$df_rm_absent" "$df_edited_backup"
    fi
  done
}

# The .bash_profile respawn guard keeps launch timestamps here, and install.sh the choices --update
# reuses, what it wrote into each dotfile, and custom shell hook paths; copies under a custom XDG_STATE_HOME are not removed.
cleanup_home_state_dir() {
  local dry_run="${1:-0}" home state_dir state_file state_removed=0 rc=0
  local -a state_files=(startx-attempts install-choices installed-dotfiles installed-shell-hooks)
  home="$(normalize_home_path "${TARGET_HOME:-}")"
  state_dir="$home/.local/state/lightxdm"
  DRY_STATE_DIR="$state_dir"
  DRY_STATE_DIR_STATUS="absent"
  DRY_STATE_DIR_REMOVE=false
  home_dir_is_safe ".local/state/lightxdm" || rc=$?
  if [[ $rc -ne 0 ]]; then
    if [[ $rc -eq 2 ]]; then
      dry_warn_err "Warning: Refusing symlinked directory along $home/.local/state/lightxdm."
      DRY_STATE_DIR_STATUS="refused-symlink-dir"
    elif [[ $rc -eq 3 ]]; then
      dry_warn_err "Warning: Cannot read $state_dir; skipping state file lookup."
      if [[ $dry_run -eq 1 ]]; then
        [[ $EUID -ne 0 ]] && DRY_NEEDS_ROOT=true
        DRY_STATE_DIR_STATUS="unknown-needs-root"
        for state_file in "${state_files[@]}"; do
          append_dry_state_file_json "$state_file" "$state_dir/$state_file" "unknown-needs-root"
        done
      fi
    elif [[ $dry_run -eq 1 ]]; then
      for state_file in "${state_files[@]}"; do
        append_dry_state_file_json "$state_file" "$state_dir/$state_file" "absent"
      done
    fi
    return 0
  fi
  for state_file in "${state_files[@]}"; do
    if [[ -f "$state_dir/$state_file" && ! -L "$state_dir/$state_file" ]]; then
      if [[ $dry_run -eq 1 ]]; then
        dry_action "Would remove $state_dir/$state_file."
        append_dry_state_file_json "$state_file" "$state_dir/$state_file" "remove"
      else
        rm -f -- "$state_dir/$state_file"
      fi
      state_removed=1
    elif [[ $dry_run -eq 1 ]]; then
      append_dry_state_file_json "$state_file" "$state_dir/$state_file" "absent"
    fi
  done
  if [[ $state_removed -eq 1 ]]; then
    if [[ $dry_run -eq 1 ]]; then
      dry_action "Would remove $state_dir if empty."
      DRY_STATE_DIR_STATUS="remove"
      DRY_STATE_DIR_REMOVE=true
    else
      rmdir --ignore-fail-on-non-empty -- "$state_dir" 2>/dev/null || true
    fi
  fi
}

# Return 0 when stdin matches backup $1 (including backups missing a trailing newline).
pam_matches_backup_stream() {
  local backup="$1" stream_sum backup_sum
  stream_sum="$(sha256sum)"
  backup_sum="$(sha256sum <"$backup")"
  if [[ "$stream_sum" == "$backup_sum" ]]; then
    return 0
  fi
  if [[ -s "$backup" && -n "$(tail -c 1 "$backup")" ]]; then
    backup_sum="$( (cat -- "$backup"; printf '\n') | sha256sum )"
    [[ "$stream_sum" == "$backup_sum" ]] && return 0
  fi
  return 1
}

# Print the full rollback plan without modifying PAM, systemd units, Polkit rules, or dotfiles.
preview_uninstall() {
  local keyring_only="$1" backup_file="$2"
  DRY_NEEDS_ROOT=false
  DRY_ACTIONS=()
  DRY_WARNINGS=()
  DRY_NOTES=()
  DRY_DOTFILE_JSON=()
  DRY_SHELL_HOOK_JSON=()
  DRY_STATE_FILE_JSON=()
  DRY_STATE_DIR=""
  DRY_STATE_DIR_STATUS="absent"
  DRY_STATE_DIR_REMOVE=false

  [[ $DRY_RUN_JSON -eq 0 ]] && echo "Dry run: no files or systemd units will be modified."

  local pam_unknown=0 pam_status="skip-no-backup" pam_keep_backup=false pam_residual_warning=false
  local gnome_hits=0 keyring_hits=0
  local gnome_session_status="kept-keyring-only" pam_login_base_status="kept-keyring-only" pam_keyring_status="absent"
  local polkit_status="kept-keyring-only" polkit_edited_backup=""
  local override_dir="${OVERRIDE_DIR:-/etc/systemd/system/getty@tty1.service.d}"
  local autologin_status="kept-keyring-only" autologin_recommended_cmd=""
  local -a autologin_remove_files=() autologin_keep_files=()
  local dm_status="kept-keyring-only"
  local -a dm_reenable=() dm_skip=()

  if path_needs_sudo "$LOGIN_FILE" 1 || path_needs_sudo "$backup_file"; then
    pam_unknown=1
    pam_status="unknown-needs-root"
    DRY_NEEDS_ROOT=true
    dry_action "PAM ($LOGIN_FILE): unknown (needs root — rerun with sudo --dry-run to inspect)."
  fi

  local gnome_marker='# lightXDM: GNOME on TTY1 needs a wayland session type (uninstall.sh removes this)'
  local gnome_tty_gate='session    [success=2 default=ignore] pam_succeed_if.so quiet tty notin tty1:/dev/tty1'
  local gnome_user_gate_re='^session    \[success=1 default=ignore\] pam_succeed_if\.so quiet user != [abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._][abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*$'
  local gnome_env_line="session    optional   pam_env.so readenv=0 user_readenv=0 conffile=$GNOME_SESSION_TYPE_DEST"
  local gnome_pam_sed=()
  if [[ $pam_unknown -eq 0 && $keyring_only -eq 0 && -f "$LOGIN_FILE" && -r "$LOGIN_FILE" ]]; then
    local line_number=0 line
    while IFS= read -r line || [[ -n "$line" ]]; do
      line_number=$((line_number + 1))
      if [[ "$line" == "$gnome_marker" || "$line" == "$gnome_tty_gate" || "$line" =~ $gnome_user_gate_re || "$line" == "$gnome_env_line" ]]; then
        if [[ ! -f "$backup_file" || -L "$backup_file" || ! -r "$backup_file" ]] || ! grep -Fxq -- "$line" "$backup_file"; then
          gnome_pam_sed+=(-e "${line_number}d")
        fi
      fi
    done < "$LOGIN_FILE"
    gnome_hits=$(( ${#gnome_pam_sed[@]} / 2 ))
    if [[ $gnome_hits -gt 0 ]]; then
      dry_action "Would remove $gnome_hits GNOME session-type PAM line(s) from $LOGIN_FILE."
    fi
  fi

  if [[ $keyring_only -eq 0 ]]; then
    if path_needs_sudo "$GNOME_SESSION_TYPE_DEST"; then
      gnome_session_status="unknown-needs-root"
      DRY_NEEDS_ROOT=true
      dry_action "GNOME session-type config ($GNOME_SESSION_TYPE_DEST): unknown (needs root)."
    elif [[ -e "$GNOME_SESSION_TYPE_DEST" || -L "$GNOME_SESSION_TYPE_DEST" ]]; then
      gnome_session_status="remove"
      dry_action "Would remove $GNOME_SESSION_TYPE_DEST."
    else
      gnome_session_status="absent"
    fi
    if path_needs_sudo "$PAM_LOGIN_BASE_STATE"; then
      pam_login_base_status="unknown-needs-root"
      DRY_NEEDS_ROOT=true
      dry_action "PAM login base state ($PAM_LOGIN_BASE_STATE): unknown (needs root)."
    elif [[ -e "$PAM_LOGIN_BASE_STATE" || -L "$PAM_LOGIN_BASE_STATE" ]]; then
      pam_login_base_status="remove"
      dry_action "Would remove $PAM_LOGIN_BASE_STATE."
    else
      pam_login_base_status="absent"
    fi
  fi

  if [[ $pam_unknown -eq 0 ]]; then
    if [[ -f "$backup_file" && ! -L "$backup_file" && -r "$backup_file" ]]; then
      if [[ ! -e "$LOGIN_FILE" ]]; then
        pam_status="restore-from-backup"
        dry_action "Would restore $LOGIN_FILE from backup ($backup_file) and remove backup."
      elif [[ -f "$LOGIN_FILE" && -r "$LOGIN_FILE" ]]; then
        local pam_sed=() pam_line pam_re hits
        for pam_line in "${LIGHTXDM_KEYRING_LINES[@]}"; do
          pam_re="^${pam_line//./\\.}\$"
          if [[ -z "$(sed -n "/${pam_re}/p" "$backup_file")" ]]; then
            pam_sed+=(-e "/${pam_re}/d")
            hits="$(grep -Ec -- "${pam_re}" "$LOGIN_FILE" || true)"
            keyring_hits=$((keyring_hits + hits))
          fi
        done
        local all_sed=("${gnome_pam_sed[@]}" "${pam_sed[@]}")
        if (if [[ ${#all_sed[@]} -gt 0 ]]; then sed "${all_sed[@]}" "$LOGIN_FILE"; else cat -- "$LOGIN_FILE"; fi) | pam_matches_backup_stream "$backup_file"; then
          pam_status="restore-from-backup"
          dry_action "Would restore $LOGIN_FILE from backup ($backup_file) and remove backup."
        else
          pam_status="remove-lines-keep-backup"
          pam_keep_backup=true
          dry_action "Would remove $((gnome_hits + keyring_hits)) lightXDM PAM line(s) from $LOGIN_FILE; backup would be kept for review ($backup_file)."
        fi
        if [[ $keyring_only -eq 1 ]] &&
          (if [[ ${#all_sed[@]} -gt 0 ]]; then sed "${all_sed[@]}" "$LOGIN_FILE"; else cat -- "$LOGIN_FILE"; fi) |
          grep -Eq '^[[:space:]]*-?(auth|session)[[:space:]][^#]*(pam_kwallet5\.so|pam_gnome_keyring\.so)([[:space:]]|$)'; then
          pam_residual_warning=true
          dry_warn_err "Warning: $LOGIN_FILE would still configure PAM keyring unlock (lines lightXDM did not add); remove them by hand if you use autologin."
        fi
      fi
    else
      pam_status="skip-no-backup"
      dry_action "No $backup_file found; would skip PAM restore."
      if [[ $keyring_only -eq 1 && -f "$LOGIN_FILE" && -r "$LOGIN_FILE" ]] &&
        grep -Eq '^[[:space:]]*-?(auth|session)[[:space:]][^#]*(pam_kwallet5\.so|pam_gnome_keyring\.so)([[:space:]]|$)' "$LOGIN_FILE"; then
        pam_residual_warning=true
        dry_warn_err "Warning: $LOGIN_FILE would still configure PAM keyring unlock (lines lightXDM did not add); remove them by hand if you use autologin."
      fi
    fi
  fi

  if path_needs_sudo "$PAM_KEYRING_STATE"; then
    pam_keyring_status="unknown-needs-root"
    DRY_NEEDS_ROOT=true
    dry_action "PAM keyring state ($PAM_KEYRING_STATE): unknown (needs root)."
  elif [[ -e "$PAM_KEYRING_STATE" || -L "$PAM_KEYRING_STATE" ]]; then
    pam_keyring_status="remove"
    dry_action "Would remove $PAM_KEYRING_STATE."
  fi

  if [[ $keyring_only -eq 1 ]]; then
    dry_note "Dry run (--keyring-only): dotfiles, autologin, the Polkit rule and display managers would stay unchanged."
    local autologin_status_text
    autologin_status_text="$(bash "$SCRIPT_DIR/enable-autologin.sh" --status 2>/dev/null || true)"
    if [[ "$autologin_status_text" != "enabled for"* && "$autologin_status_text" != *"still enables autologin."* ]]; then
      autologin_recommended_cmd="sudo $(printf 'bash %q' "$SCRIPT_DIR/enable-autologin.sh") ${SUDO_USER:-${USER:-<user>}}"
      dry_note "To log in on TTY1 without a password, run: $autologin_recommended_cmd"
    fi
    if [[ $DRY_RUN_JSON -eq 0 ]]; then
      return 0
    fi
  else

    local override_file="$override_dir/lightxdm-autologin.conf"
    local legacy_override="$override_dir/override.conf"
    local autologin_seen=0
    if path_needs_sudo "$override_file" || path_needs_sudo "$legacy_override"; then
      autologin_status="unknown-needs-root"
      DRY_NEEDS_ROOT=true
      dry_action "TTY1 autologin ($override_dir): unknown (needs root)."
    else
      autologin_status="absent"
      if [[ -f "$override_file" || -L "$override_file" ]]; then
        dry_action "Would disable TTY1 autologin (remove $override_file)."
        autologin_remove_files+=("$override_file")
        autologin_seen=1
      fi
      if [[ -f "$legacy_override" && ! -L "$legacy_override" && -r "$legacy_override" ]]; then
        local legacy_lines=() exec_re='^ExecStart=-/usr/bin/agetty --autologin [^-[:space:]:][^[:space:]:]* --noclear %I [$]TERM$'
        mapfile -t legacy_lines < "$legacy_override"
        if [[ ${#legacy_lines[@]} -eq 3 && "${legacy_lines[0]}" == "[Service]" && "${legacy_lines[1]}" == "ExecStart=" && "${legacy_lines[2]}" =~ $exec_re ]]; then
          dry_action "Would remove legacy autologin override: $legacy_override."
          autologin_remove_files+=("$legacy_override")
          autologin_seen=1
        else
          dry_action "Would keep $legacy_override (not written by lightXDM)."
          autologin_keep_files+=("$legacy_override")
        fi
      elif [[ -L "$legacy_override" ]]; then
        dry_action "Would keep $legacy_override (not written by lightXDM)."
        autologin_keep_files+=("$legacy_override")
      fi
      local autologin_probe status_line
      autologin_probe="$(LOGIN_FILE=/dev/null bash "$SCRIPT_DIR/enable-autologin.sh" --status 2>&1 || true)"
      while IFS= read -r status_line || [[ -n "$status_line" ]]; do
        if [[ "$status_line" == Warning:* ]]; then
          dry_warn_out "$status_line"
        elif [[ "$status_line" == Note:* ]]; then
          dry_note "$status_line"
          if [[ "$status_line" == "Note: cannot read "* || "$status_line" == *"with sudo"* ]]; then
            DRY_NEEDS_ROOT=true
          fi
        fi
      done <<<"$autologin_probe"
      if [[ $autologin_seen -eq 0 ]]; then
        dry_action "No lightXDM autologin drop-in found; would skip."
        [[ ${#autologin_keep_files[@]} -gt 0 ]] && autologin_status="keep-custom"
      else
        autologin_status="disable"
      fi
    fi

    if path_needs_sudo "$POLKIT_RULE" || path_needs_sudo "${POLKIT_RULE}.lightxdm.bak" || path_needs_sudo "${POLKIT_RULE}.lightxdm.absent"; then
      polkit_status="unknown-needs-root"
      DRY_NEEDS_ROOT=true
      dry_action "Polkit rule ($POLKIT_RULE): unknown (needs root)."
    elif [[ -e "${POLKIT_RULE}.lightxdm.bak" || -L "${POLKIT_RULE}.lightxdm.bak" ]]; then
      polkit_status="restore-from-backup"
      if [[ -L "$POLKIT_RULE" ]] || { [[ -e "$POLKIT_RULE" && -r "$POLKIT_RULE" ]] && ! is_lightxdm_polkit_rule "$POLKIT_RULE"; }; then
        DRY_LAST_EDITED_DEST=""
        save_edited_dotfile "$POLKIT_RULE" 1
        polkit_edited_backup="$DRY_LAST_EDITED_DEST"
      elif [[ -e "$POLKIT_RULE" && ! -r "$POLKIT_RULE" ]]; then
        polkit_status="restore-from-backup-unreadable"
        DRY_NEEDS_ROOT=true
        dry_action "Would restore $POLKIT_RULE from backup (existing rule unreadable without root to check edits)."
      fi
      dry_action "Would restore $POLKIT_RULE from backup (${POLKIT_RULE}.lightxdm.bak)."
    elif [[ -e "${POLKIT_RULE}.lightxdm.absent" || -L "${POLKIT_RULE}.lightxdm.absent" ]]; then
      polkit_status="remove-absent-marker"
      if [[ -e "$POLKIT_RULE" || -L "$POLKIT_RULE" ]]; then
        if [[ -r "$POLKIT_RULE" ]] && is_lightxdm_polkit_rule "$POLKIT_RULE"; then
          polkit_status="remove"
          dry_action "Would remove Polkit rule: $POLKIT_RULE."
        else
          DRY_LAST_EDITED_DEST=""
          save_edited_dotfile "$POLKIT_RULE" 1
          polkit_edited_backup="$DRY_LAST_EDITED_DEST"
          polkit_status="save-edited-and-remove-absent"
        fi
      fi
      dry_action "Would remove ${POLKIT_RULE}.lightxdm.absent."
    elif is_lightxdm_polkit_rule "$POLKIT_RULE"; then
      polkit_status="remove"
      dry_action "Would remove Polkit rule: $POLKIT_RULE."
    elif [[ -e "$POLKIT_RULE" || -L "$POLKIT_RULE" ]]; then
      polkit_status="keep"
      dry_action "Would keep $POLKIT_RULE (not an unmodified lightXDM rule)."
    else
      polkit_status="absent"
      dry_action "No Polkit rule found; would skip."
    fi

    cleanup_home_dotfiles 1
    cleanup_home_state_dir 1

    if path_needs_sudo "$DM_STATE_FILE"; then
      dm_status="unknown-needs-root"
      DRY_NEEDS_ROOT=true
      dry_action "Disabled display managers ($DM_STATE_FILE): unknown (needs root)."
    elif [[ -L "$DM_STATE_FILE" ]]; then
      dm_status="unlink-symlink"
      dry_action "Would unlink symlinked $DM_STATE_FILE without re-enabling display managers."
    elif [[ -f "$DM_STATE_FILE" ]]; then
      local dm_unit dm_state dm_recorded=0
      while IFS= read -r dm_unit || [[ -n "$dm_unit" ]]; do
        [[ -n "$dm_unit" ]] || continue
        dm_recorded=1
        dm_state="$(systemctl is-enabled "$dm_unit" 2>/dev/null || true)"
        case "$dm_state" in
          not-found)
            dry_warn_out "Warning: $dm_unit is not installed any more; would skip it."
            dm_skip+=("$dm_unit")
            ;;
          masked | masked-runtime)
            dry_warn_out "Warning: $dm_unit is masked; would warn and skip re-enabling."
            dm_skip+=("$dm_unit")
            ;;
          *)
            dry_action "Would re-enable display manager: $dm_unit (current state: ${dm_state:-unknown})."
            dm_reenable+=("$dm_unit")
            ;;
        esac
      done < "$DM_STATE_FILE"
      if [[ $dm_recorded -eq 0 ]]; then
        dm_status="empty"
        dry_action "No disabled display managers listed in $DM_STATE_FILE."
      elif [[ ${#dm_reenable[@]} -gt 0 ]]; then
        dm_status="reenable"
      else
        dm_status="skip-only"
      fi
      dry_action "Would remove $DM_STATE_FILE."
    else
      dm_status="absent"
      dry_action "No disabled display managers recorded ($DM_STATE_FILE)."
    fi
  fi

  if [[ $DRY_RUN_JSON -eq 0 ]]; then
    echo "Dry run complete: no files or systemd units were modified."
    return 0
  fi

  local keyring_json="false" target_home_val="" idx
  if [[ $keyring_only -eq 1 ]]; then
    keyring_json="true"
  else
    target_home_val="${TARGET_HOME:-}"
  fi
  local state_dir_val="" state_status_val="kept-keyring-only"
  if [[ $keyring_only -eq 0 ]]; then
    state_dir_val="$DRY_STATE_DIR"
    state_status_val="$DRY_STATE_DIR_STATUS"
  fi

  printf '{\n'
  printf '  "mode": "uninstall-dry-run",\n'
  printf '  "keyring_only": %s,\n' "$keyring_json"
  printf '  "target_home": %s,\n' "$(json_str_or_null "$target_home_val")"
  printf '  "login_file": %s,\n' "$(json_str "$LOGIN_FILE")"
  printf '  "needs_root": %s,\n' "$DRY_NEEDS_ROOT"
  printf '  "pam": {\n'
  printf '    "status": %s,\n' "$(json_str "$pam_status")"
  printf '    "backup_file": %s,\n' "$(json_str "$backup_file")"
  printf '    "gnome_lines_to_remove": %d,\n' "$gnome_hits"
  printf '    "lightxdm_lines_to_remove": %d,\n' "$((gnome_hits + keyring_hits))"
  printf '    "keep_backup": %s,\n' "$pam_keep_backup"
  printf '    "residual_keyring_warning": %s\n' "$pam_residual_warning"
  printf '  },\n'
  printf '  "gnome_session_type": {\n'
  printf '    "path": %s,\n' "$(json_str "$GNOME_SESSION_TYPE_DEST")"
  printf '    "status": %s\n' "$(json_str "$gnome_session_status")"
  printf '  },\n'
  printf '  "pam_keyring_state": {\n'
  printf '    "path": %s,\n' "$(json_str "$PAM_KEYRING_STATE")"
  printf '    "status": %s\n' "$(json_str "$pam_keyring_status")"
  printf '  },\n'
  printf '  "pam_login_base_state": {\n'
  printf '    "path": %s,\n' "$(json_str "$PAM_LOGIN_BASE_STATE")"
  printf '    "status": %s\n' "$(json_str "$pam_login_base_status")"
  printf '  },\n'
  printf '  "polkit": {\n'
  printf '    "path": %s,\n' "$(json_str "$POLKIT_RULE")"
  printf '    "status": %s,\n' "$(json_str "$polkit_status")"
  printf '    "edited_backup": %s\n' "$(json_str_or_null "$polkit_edited_backup")"
  printf '  },\n'
  printf '  "autologin": {\n'
  printf '    "override_dir": %s,\n' "$(json_str "$override_dir")"
  printf '    "status": %s,\n' "$(json_str "$autologin_status")"
  printf '    "remove_files": '
  print_json_string_array "${autologin_remove_files[@]}"
  printf ',\n'
  printf '    "keep_files": '
  print_json_string_array "${autologin_keep_files[@]}"
  printf ',\n'
  printf '    "recommended_command": %s\n' "$(json_str_or_null "$autologin_recommended_cmd")"
  printf '  },\n'
  printf '  "display_managers": {\n'
  printf '    "state_file": %s,\n' "$(json_str "$DM_STATE_FILE")"
  printf '    "status": %s,\n' "$(json_str "$dm_status")"
  printf '    "reenable": '
  print_json_string_array "${dm_reenable[@]}"
  printf ',\n'
  printf '    "skip": '
  print_json_string_array "${dm_skip[@]}"
  printf '\n  },\n'
  printf '  "dotfiles": [\n'
  for ((idx = 0; idx < ${#DRY_DOTFILE_JSON[@]}; idx++)); do
    [[ $idx -gt 0 ]] && printf ',\n'
    printf '    %s' "${DRY_DOTFILE_JSON[$idx]}"
  done
  printf '\n  ],\n'
  printf '  "shell_hooks": [\n'
  for ((idx = 0; idx < ${#DRY_SHELL_HOOK_JSON[@]}; idx++)); do
    [[ $idx -gt 0 ]] && printf ',\n'
    printf '    %s' "${DRY_SHELL_HOOK_JSON[$idx]}"
  done
  printf '\n  ],\n'
  printf '  "state_files": {\n'
  printf '    "dir": %s,\n' "$(json_str_or_null "$state_dir_val")"
  printf '    "status": %s,\n' "$(json_str "$state_status_val")"
  printf '    "remove_dir_if_empty": %s,\n' "$DRY_STATE_DIR_REMOVE"
  printf '    "files": ['
  for ((idx = 0; idx < ${#DRY_STATE_FILE_JSON[@]}; idx++)); do
    [[ $idx -gt 0 ]] && printf ', '
    printf '%s' "${DRY_STATE_FILE_JSON[$idx]}"
  done
  printf ']\n'
  printf '  },\n'
  printf '  "actions": '
  print_json_string_array "${DRY_ACTIONS[@]}"
  printf ',\n'
  printf '  "warnings": '
  print_json_string_array "${DRY_WARNINGS[@]}"
  printf ',\n'
  printf '  "notes": '
  print_json_string_array "${DRY_NOTES[@]}"
  printf '\n}\n'
}

main() {
  local keyring_only=0 dry_run=0 json_mode=0 arg
  local usage="Usage: sudo bash $0 [-h|--help] [--keyring-only] [--dry-run [--json]]"
  for arg in "$@"; do
    case "$arg" in
      -h | --help)
        if [[ $# -ne 1 ]]; then
          echo "Unknown option: $*" >&2
          echo "$usage" >&2
          exit 1
        fi
        echo "$usage"
        echo "  --keyring-only  remove only the keyring lines lightXDM added to /etc/pam.d/login (for switching to autologin)"
        echo "  --dry-run       preview the changes uninstall would make without modifying files or systemd units (no sudo needed for readable files)"
        echo "  --json          emit machine-readable JSON on stdout (requires --dry-run; implies no writes or prompts)"
        echo "Run it with sudo from your user account; as root without sudo, set TARGET_HOME=/home/<user>."
        exit 0
        ;;
      --keyring-only)
        if [[ $keyring_only -eq 1 ]]; then
          echo "Duplicate option: $arg" >&2
          echo "$usage" >&2
          exit 1
        fi
        keyring_only=1
        ;;
      --dry-run)
        if [[ $dry_run -eq 1 ]]; then
          echo "Duplicate option: $arg" >&2
          echo "$usage" >&2
          exit 1
        fi
        dry_run=1
        ;;
      --json)
        if [[ $json_mode -eq 1 ]]; then
          echo "Duplicate option: $arg" >&2
          echo "$usage" >&2
          exit 1
        fi
        json_mode=1
        ;;
      *)
        echo "Unknown option: $*" >&2
        echo "$usage" >&2
        exit 1
        ;;
    esac
  done

  if [[ $json_mode -eq 1 && $dry_run -eq 0 ]]; then
    echo "--json requires --dry-run." >&2
    echo "$usage" >&2
    exit 1
  fi

  if [[ $EUID -ne 0 && $dry_run -eq 0 ]]; then
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

    if [[ -z "${TARGET_HOME:-}" && $dry_run -eq 1 && $EUID -ne 0 ]]; then
      TARGET_HOME="${HOME:-}"
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

  if [[ $dry_run -eq 1 ]]; then
    DRY_RUN_JSON="$json_mode"
    preview_uninstall "$keyring_only" "$BACKUP_FILE"
    exit 0
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
