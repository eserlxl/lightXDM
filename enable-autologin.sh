#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# enable-autologin.sh: Enable or disable TTY1 autologin for a user using systemd override
set -e

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OVERRIDE_DIR="${OVERRIDE_DIR:-/etc/systemd/system/getty@tty1.service.d}"
OVERRIDE_FILE="$OVERRIDE_DIR/lightxdm-autologin.conf"
LEGACY_OVERRIDE_FILE="$OVERRIDE_DIR/override.conf"
LOGIN_FILE="${LOGIN_FILE:-/etc/pam.d/login}"
readonly AUTOLOGIN_EXEC_RE='^[[:space:]]*ExecStart[[:space:]]*=.*([[:space:]]--autologin([[:space:]]+|=)|[[:space:]]-a[[:space:]]+)([^-[:space:]][^[:space:]]*)'

usage() {
  echo "Usage: sudo bash $0 <username> | --disable; bash $0 --status [--json] | -h | --help" >&2
  exit 1
}

show_help() {
  cat <<EOF
Usage: sudo bash $0 <username> | --disable; bash $0 --status [--json] | -h | --help

Turn passwordless TTY1 autologin on or off (changes apply at the next login or reboot).
  <username>  log <username> in on TTY1 without a password
  --disable   remove lightXDM's autologin drop-in
  --status    show whether autologin is enabled; read-only, no sudo needed
  --json      with --status, print the read-only status as structured JSON on stdout
  -h, --help  show this help
EOF
  exit 0
}

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
  if [[ -n "${1-}" ]]; then
    json_str "$1"
  else
    printf 'null'
  fi
}

print_json_string_array() {
  local first=1 item
  printf '['
  for item in "$@"; do
    if [[ $first -eq 0 ]]; then
      printf ', '
    fi
    first=0
    json_str "$item"
  done
  printf ']'
}

inspect_login_keyring() {
  LOGIN_KEYRING_STATE="false"
  LOGIN_KEYRING_NOTE=""
  LOGIN_KEYRING_WARNING=""
  if [[ -f "$LOGIN_FILE" ]]; then
    if [[ ! -r "$LOGIN_FILE" ]]; then
      LOGIN_KEYRING_STATE="null"
      LOGIN_KEYRING_NOTE="Note: cannot read $LOGIN_FILE; run --status with sudo for an exact result."
      return 0
    fi
    if grep -Eq '^[[:space:]]*-?(auth|session)[[:space:]][^#]*(pam_kwallet5\.so|pam_gnome_keyring\.so)([[:space:]]|$)' "$LOGIN_FILE"; then
      LOGIN_KEYRING_STATE="true"
      LOGIN_KEYRING_WARNING="Warning: PAM keyring unlock is configured in $LOGIN_FILE; the keyring will not unlock automatically with autologin and will ask for its password in the desktop, unless its password is empty. To remove the keyring lines lightXDM added, run 'sudo $(printf 'bash %q' "$SCRIPT_DIR/uninstall.sh") --keyring-only'."
    fi
  elif [[ ! -e "$LOGIN_FILE" ]]; then
    local resolved probe
    resolved="$(readlink -m -- "$LOGIN_FILE" 2>/dev/null || printf '%s\n' "$LOGIN_FILE")"
    probe="$(dirname -- "$resolved")"
    while [[ "$probe" != "/" && "$probe" != "." && ! -e "$probe" && ! -L "$probe" ]]; do
      probe="$(dirname -- "$probe")"
    done
    if [[ -d "$probe" && ! -x "$probe" ]]; then
      LOGIN_KEYRING_STATE="null"
      LOGIN_KEYRING_NOTE="Note: cannot read $LOGIN_FILE; run --status with sudo for an exact result."
    fi
  fi
}

warn_keyring_unlock() {
  local LOGIN_KEYRING_STATE="" LOGIN_KEYRING_NOTE="" LOGIN_KEYRING_WARNING=""
  inspect_login_keyring
  if [[ -n "$LOGIN_KEYRING_NOTE" ]]; then
    echo "$LOGIN_KEYRING_NOTE" >&2
  elif [[ -n "$LOGIN_KEYRING_WARNING" ]]; then
    echo "$LOGIN_KEYRING_WARNING"
  fi
}

dropin_enables_autologin() {
  local file="$1" line enabled=0 LC_ALL=C
  [[ -f "$file" && -r "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $AUTOLOGIN_EXEC_RE ]]; then
      enabled=1
    elif [[ "$line" =~ ^[[:space:]]*ExecStart[[:space:]]*= ]]; then
      enabled=0
    fi
  done < "$file"
  [[ $enabled -eq 1 ]]
}

show_status() {
  local json_mode=0
  [[ "${1:-}" == "--json" ]] && json_mode=1
  local file line status_file="" target_user="" reset_file="" foreign_autologin=0 any_unreadable=0 LC_ALL=C
  local -a warnings=() notes=() dropin_files=()
  local LOGIN_KEYRING_STATE="false" LOGIN_KEYRING_NOTE="" LOGIN_KEYRING_WARNING=""
  if [[ -d "$OVERRIDE_DIR" && ! ( -r "$OVERRIDE_DIR" && -x "$OVERRIDE_DIR" ) ]]; then
    local dir_note="Note: cannot read $OVERRIDE_DIR; run --status with sudo for an exact result."
    notes+=("$dir_note")
    any_unreadable=1
    [[ $json_mode -eq 0 ]] && echo "$dir_note" >&2
  fi
  # The accepted legacy override sorts after the current lightXDM drop-in.
  for file in "$OVERRIDE_FILE" "$LEGACY_OVERRIDE_FILE"; do
    [[ -f "$file" ]] || continue
    if [[ ! -r "$file" ]]; then
      local file_note="Note: cannot read $file; run --status with sudo for an exact result."
      notes+=("$file_note")
      any_unreadable=1
      [[ $json_mode -eq 0 ]] && echo "$file_note" >&2
      continue
    fi
    if [[ "$file" == "$LEGACY_OVERRIDE_FILE" ]] && ! is_legacy_autologin_override "$file"; then
      continue
    fi
    # shellcheck disable=SC2094  # the loop only compares the path; it never writes the file
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" =~ $AUTOLOGIN_EXEC_RE ]]; then
        status_file="$file"
        target_user="${BASH_REMATCH[3]}"
        [[ "$reset_file" == "$file" ]] && reset_file=""
      elif [[ "$line" =~ ^[[:space:]]*ExecStart[[:space:]]*= && "$status_file" == "$file" ]]; then
        # A later plain ExecStart in the same file replaces the autologin command.
        status_file=""
        target_user=""
        reset_file="$file"
      fi
    done < "$file"
  done
  if [[ $json_mode -eq 0 ]]; then
    if [[ -n "$status_file" ]]; then
      echo "enabled for $target_user ($status_file)"
    else
      echo "disabled"
    fi
  fi
  for file in "$OVERRIDE_DIR"/*.conf; do
    if [[ -e "$file" || -L "$file" ]]; then
      dropin_files+=("$file")
    fi
    if [[ -f "$file" && ! -r "$file" ]]; then
      if [[ "$file" != "$OVERRIDE_FILE" && "$file" != "$LEGACY_OVERRIDE_FILE" ]]; then
        local foreign_note="Note: cannot read $file; run --status with sudo for an exact result."
        notes+=("$foreign_note")
        [[ $json_mode -eq 0 ]] && echo "$foreign_note" >&2
      fi
      any_unreadable=1
      continue
    fi
    [[ -f "$file" && -r "$file" && "$file" != "$status_file" && "$file" != "$reset_file" ]] || continue
    if dropin_enables_autologin "$file"; then
      local foreign_warn="Warning: $file still enables autologin."
      warnings+=("$foreign_warn")
      [[ $json_mode -eq 0 ]] && echo "$foreign_warn"
      foreign_autologin=1
    fi
    if [[ -n "$status_file" && "$file" > "$status_file" ]] &&
      grep -Eq '^[[:space:]]*ExecStart[[:space:]]*=' "$file"; then
      local override_warn="Warning: $file overrides autologin with a later ExecStart= setting."
      warnings+=("$override_warn")
      [[ $json_mode -eq 0 ]] && echo "$override_warn"
    fi
  done
  inspect_login_keyring
  if [[ -n "$status_file" || $foreign_autologin -eq 1 ]]; then
    if [[ -n "$LOGIN_KEYRING_NOTE" ]]; then
      notes+=("$LOGIN_KEYRING_NOTE")
      [[ $json_mode -eq 0 ]] && echo "$LOGIN_KEYRING_NOTE" >&2
    elif [[ -n "$LOGIN_KEYRING_WARNING" ]]; then
      warnings+=("$LOGIN_KEYRING_WARNING")
      [[ $json_mode -eq 0 ]] && echo "$LOGIN_KEYRING_WARNING"
    fi
  fi
  if [[ $json_mode -eq 1 ]]; then
    local state_label="disabled" json_user="" json_file=""
    if [[ -n "$status_file" ]]; then
      state_label="enabled"
      json_user="$target_user"
      json_file="$status_file"
    elif [[ $any_unreadable -eq 1 ]]; then
      state_label="unknown-needs-root"
    fi
    printf '{\n'
    printf '  "mode": "autologin-status",\n'
    printf '  "state": %s,\n' "$(json_str "$state_label")"
    printf '  "user": %s,\n' "$(json_str_or_null "$json_user")"
    printf '  "file": %s,\n' "$(json_str_or_null "$json_file")"
    printf '  "override_dir": %s,\n' "$(json_str "$OVERRIDE_DIR")"
    printf '  "login_file": %s,\n' "$(json_str "$LOGIN_FILE")"
    printf '  "keyring_configured": %s,\n' "$LOGIN_KEYRING_STATE"
    printf '  "dropin_files": '
    print_json_string_array "${dropin_files[@]}"
    printf ',\n'
    printf '  "warnings": '
    print_json_string_array "${warnings[@]}"
    printf ',\n'
    printf '  "notes": '
    print_json_string_array "${notes[@]}"
    printf '\n'
    printf '}\n'
  fi
}

main() {
  if [[ $# -eq 1 ]] && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
  fi

  local saw_status=0 saw_json=0 arg
  for arg in "$@"; do
    case "$arg" in
      --status)
        [[ $saw_status -eq 0 ]] || usage
        saw_status=1
        ;;
      --json)
        [[ $saw_json -eq 0 ]] || usage
        saw_json=1
        ;;
    esac
  done
  if [[ $saw_json -eq 1 && $saw_status -eq 0 ]]; then
    echo "--json requires --status." >&2
    usage
  fi
  if [[ $saw_status -eq 1 ]]; then
    if [[ $saw_json -eq 1 ]]; then
      [[ $# -eq 2 ]] || usage
      show_status --json
    else
      [[ $# -eq 1 ]] || usage
      show_status
    fi
    exit 0
  fi

  if [[ $# -ne 1 || -z "$1" ]]; then
    usage
  fi

  if [[ "$1" == -* && "$1" != "--disable" ]]; then
    echo "Invalid username: '$1'." >&2
    usage
  fi

  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (with sudo)."
    exit 1
  fi

  if [[ "$1" == "--disable" ]]; then
    echo "Disabling TTY1 autologin..."
    local removed=0
    if [[ -f "$OVERRIDE_FILE" || -L "$OVERRIDE_FILE" ]]; then
      echo "Removing autologin drop-in..."
      rm -f "$OVERRIDE_FILE"
      removed=1
    fi
    if [[ -f "$LEGACY_OVERRIDE_FILE" || -L "$LEGACY_OVERRIDE_FILE" ]]; then
      if is_legacy_autologin_override "$LEGACY_OVERRIDE_FILE"; then
        echo "Removing legacy autologin override..."
        rm -f "$LEGACY_OVERRIDE_FILE"
        removed=1
      else
        echo "Keeping $LEGACY_OVERRIDE_FILE (not written by lightXDM)."
      fi
    fi
    local drop_in LC_ALL=C
    for drop_in in "$OVERRIDE_DIR"/*.conf; do
      if dropin_enables_autologin "$drop_in"; then
        echo "Warning: $drop_in still enables autologin."
      fi
    done
    if [[ $removed -eq 0 ]]; then
      echo "No lightXDM autologin drop-in found; nothing to remove."
      exit 0
    fi
    systemctl daemon-reload || [[ ! -d "${SYSTEMD_RUN_DIR:-/run/systemd/system}" ]]
    echo "Autologin disabled. Change will take effect at the next login or reboot."
    exit 0
  fi

  local target_user
  target_user="$1"

  local passwd_entry
  if ! passwd_entry="$(getent passwd "$target_user")"; then
    echo "User '$target_user' does not exist."
    exit 1
  fi
  passwd_entry="$(printf '%s\n' "$passwd_entry" | head -n 1)"

  local pw_name pw_uid pw_shell
  pw_name="$(printf '%s\n' "$passwd_entry" | cut -d: -f1)"
  pw_uid="$(printf '%s\n' "$passwd_entry" | cut -d: -f3)"
  pw_shell="$(printf '%s\n' "$passwd_entry" | cut -d: -f7)"

  if [[ "$pw_name" != "$target_user" ]]; then
    echo "User '$target_user' does not exist."
    exit 1
  fi

  if [[ ! "$pw_uid" =~ ^[0-9]+$ || "$pw_uid" =~ ^0+$ ]]; then
    echo "Refusing to enable autologin for root (UID 0)."
    exit 1
  fi

  if [[ "$pw_shell" == *nologin || "$pw_shell" == *false ]]; then
    echo "User '$target_user' has non-interactive shell '$pw_shell'."
    exit 1
  fi

  local state
  state="$(systemctl is-enabled getty@tty1.service 2>/dev/null || true)"
  if [[ "$state" == masked ]]; then
    echo "getty@tty1.service is masked; autologin cannot start a TTY1 login." >&2
    echo "Run systemctl unmask getty@tty1.service and re-run this script." >&2
    exit 1
  fi

  # --status reads the drop-in without sudo, so never inherit a stricter root umask.
  umask 022
  mkdir -p "$OVERRIDE_DIR"
  # A directory left 0700 by an earlier strict umask would still hide the drop-in from --status.
  chmod 755 "$OVERRIDE_DIR"
  # An older lightXDM override.conf sorts after our drop-in and would keep the previous user.
  if is_legacy_autologin_override "$LEGACY_OVERRIDE_FILE"; then
    echo "Removing legacy autologin override..."
    rm -f "$LEGACY_OVERRIDE_FILE"
  fi
  # Atomically write a temp unit and replace any symlink at the drop-in path instead of writing through it.
  tmp_override=""
  if ! { tmp_override="$(mktemp "$OVERRIDE_DIR/.lightxdm-autologin.conf.XXXXXX")" &&
    printf "[Service]\nExecStart=\nExecStart=-/usr/bin/agetty --autologin %s --noclear %%I \$TERM\n" "$target_user" >"$tmp_override" &&
    chmod 644 -- "$tmp_override" &&
    mv -Tf -- "$tmp_override" "$OVERRIDE_FILE"; }; then
    [[ -z "$tmp_override" ]] || rm -f -- "$tmp_override" 2>/dev/null || true
    exit 1
  fi
  local drop_in LC_ALL=C
  for drop_in in "$OVERRIDE_DIR"/*.conf; do
    if [[ -f "$drop_in" && "$drop_in" > "$OVERRIDE_FILE" ]] &&
      grep -Eq '^[[:space:]]*ExecStart[[:space:]]*=' "$drop_in"; then
      echo "Warning: $drop_in overrides autologin with a later ExecStart= setting."
    fi
  done
  systemctl daemon-reload || [[ ! -d "${SYSTEMD_RUN_DIR:-/run/systemd/system}" ]]

  echo "Autologin enabled for user $target_user on tty1. Change will take effect at the next login or reboot."
  warn_keyring_unlock
}

main "$@"
