#!/usr/bin/env bash
# enable-autologin.sh: Enable or disable TTY1 autologin for a user using systemd override
set -e

OVERRIDE_DIR="${OVERRIDE_DIR:-/etc/systemd/system/getty@tty1.service.d}"
OVERRIDE_FILE="$OVERRIDE_DIR/lightxdm-autologin.conf"
LEGACY_OVERRIDE_FILE="$OVERRIDE_DIR/override.conf"
LOGIN_FILE="${LOGIN_FILE:-/etc/pam.d/login}"

usage() {
  echo "Usage: sudo bash $0 <username> | --disable"
  exit 1
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

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
  fi

  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (with sudo)."
    exit 1
  fi

  if [[ $# -ne 1 || -z "$1" ]]; then
    usage
  fi

  if [[ "$1" == "--disable" ]]; then
    echo "Disabling TTY1 autologin..."
    rm -f "$OVERRIDE_FILE"
    if [[ -f "$LEGACY_OVERRIDE_FILE" || -L "$LEGACY_OVERRIDE_FILE" ]]; then
      if is_legacy_autologin_override "$LEGACY_OVERRIDE_FILE"; then
        echo "Removing legacy autologin override..."
        rm -f "$LEGACY_OVERRIDE_FILE"
      else
        echo "Keeping $LEGACY_OVERRIDE_FILE (not written by lightXDM)."
      fi
    fi
    local drop_in LC_ALL=C
    for drop_in in "$OVERRIDE_DIR"/*.conf; do
      if [[ -f "$drop_in" ]] &&
        grep -Eq '^[[:space:]]*ExecStart[[:space:]]*=.*--autologin' "$drop_in"; then
        echo "Warning: $drop_in still enables autologin."
      fi
    done
    systemctl daemon-reload
    echo "Autologin disabled. Change will take effect at the next login or reboot."
    exit 0
  fi

  local target_user
  target_user="$1"

  if [[ "$target_user" == -* ]]; then
    echo "Invalid username: '$target_user'."
    exit 1
  fi

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

  mkdir -p "$OVERRIDE_DIR"
  # An older lightXDM override.conf sorts after our drop-in and would keep the previous user.
  if is_legacy_autologin_override "$LEGACY_OVERRIDE_FILE"; then
    echo "Removing legacy autologin override..."
    rm -f "$LEGACY_OVERRIDE_FILE"
  fi
  echo "[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $target_user --noclear %I \$TERM" > "$OVERRIDE_FILE"
  local drop_in LC_ALL=C
  for drop_in in "$OVERRIDE_DIR"/*.conf; do
    if [[ -f "$drop_in" && "$drop_in" > "$OVERRIDE_FILE" ]] &&
      grep -Eq '^[[:space:]]*ExecStart[[:space:]]*=' "$drop_in"; then
      echo "Warning: $drop_in overrides autologin with a later ExecStart= setting."
    fi
  done
  systemctl daemon-reload

  echo "Autologin enabled for user $target_user on tty1. Change will take effect at the next login or reboot."
  if [[ -f "$LOGIN_FILE" ]] && grep -Eq '^[[:space:]]*-?(auth|session)[[:space:]][^#]*(pam_kwallet5\.so|pam_gnome_keyring\.so)([[:space:]]|$)' "$LOGIN_FILE"; then
    echo "Warning: PAM keyring unlock is configured in $LOGIN_FILE; the keyring will not unlock automatically with autologin and will ask for its password in the desktop, unless its password is empty."
  fi
}

main "$@"
