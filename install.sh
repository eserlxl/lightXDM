#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# lightXDM install script for Arch Linux
# Installs a desktop and its TTY1 session, with PAM keyring unlock and optional autologin
set -e

# --- Configuration ---
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly DM_LIST=(sddm lightdm gdm lxdm)
readonly DISPLAY_MANAGER_LINK="${DISPLAY_MANAGER_LINK:-/etc/systemd/system/display-manager.service}"
readonly DM_STATE_FILE="${DM_STATE_FILE:-/etc/lightxdm/disabled-display-managers}"
readonly LOGIN_FILE="${LOGIN_FILE:-/etc/pam.d/login}"
readonly GNOME_SESSION_TYPE_DEST="${GNOME_SESSION_TYPE_DEST:-/etc/lightxdm/gnome-session-type.conf}"
readonly PAM_KEYRING_STATE="${PAM_KEYRING_STATE:-/etc/lightxdm/pam-keyring}"
readonly PAM_LOGIN_BASE_STATE="${PAM_LOGIN_BASE_STATE:-/etc/lightxdm/pam-login-base}"
readonly AUTOLOGIN_DROPIN_DIR="${AUTOLOGIN_DROPIN_DIR:-/etc/systemd/system/getty@tty1.service.d}"
readonly PAM_KWALLET_AUTH="auth       optional   pam_kwallet5.so"
readonly PAM_KWALLET_SESSION="session    optional   pam_kwallet5.so force_run"
readonly PAM_GNOME_KEYRING_AUTH="auth       optional   pam_gnome_keyring.so"
readonly PAM_GNOME_KEYRING_SESSION="session    optional   pam_gnome_keyring.so auto_start"
# Every keyring line lightXDM ever appended to the login file: the four above and the auth line
# installs before 2026-11-03 wrote. uninstall.sh keeps an identical list.
readonly LIGHTXDM_KEYRING_LINES=(
  "auth       optional   pam_kwallet5.so"
  "session    optional   pam_kwallet5.so force_run"
  "auth       optional   pam_gnome_keyring.so"
  "auth       optional   pam_gnome_keyring.so auto_start"
  "session    optional   pam_gnome_keyring.so auto_start"
)

# --- Functions ---

# Log a message to the console
log() {
  echo "=> $1" >&2
}
# Print how to run bundled script $1 from any directory: bash and its shell-escaped path
script_cmd() {
  printf 'bash %q' "$SCRIPT_DIR/$1"
}

# Check for root privileges
check_root() {
  if [[ $EUID -eq 0 ]]; then
    log "Do not run this script as root. Please run as a regular user."
    exit 1
  fi
  if ! command -v sudo >/dev/null; then
    log "sudo is required but not installed. Please install sudo and re-run."
    log "Install it as root, then re-run: su -c 'pacman -S sudo'"
    exit 1
  fi
}

# Read the existing collection without activating the secret service or prompting.
check_keyring_unlocked() {
  local collection output status=0
  case "$1" in
    gnome) collection="login" ;;
    kwallet) collection="kdewallet" ;;
  esac
  output="$(busctl --user --auto-start=no get-property org.freedesktop.secrets \
    "/org/freedesktop/secrets/collection/$collection" org.freedesktop.Secret.Collection Locked 2>&1)" || status=$?
  if [[ $status -eq 0 ]]; then
    case "$output" in
      'b false')
        echo "Keyring collection '$collection' is unlocked."
        return 0
        ;;
      'b true')
        echo "Keyring collection '$collection' is locked."
        return 1
        ;;
    esac
  fi
  log "Keyring collection '$collection' is unavailable: ${output:-busctl returned no output (status $status)}"
  return 2
}

# Detect the installed desktop environment
detect_de() {
  local pair pkg de found=0
  local pairs=(
    plasma-desktop:plasma
    gnome-shell:gnome
    xfce4-session:xfce
    lxqt-session:lxqt
    lxde-common:lxde
    mate-session-manager:mate
    cinnamon:cinnamon
    budgie-desktop:budgie
    i3-wm:i3
  )
  for pair in "${pairs[@]}"; do
    pkg="${pair%%:*}"
    de="${pair#*:}"
    if pacman -Qq "$pkg" >/dev/null 2>&1; then
      echo "$de"
      found=1
    fi
  done
  if [[ $found -eq 0 ]]; then
    echo "unknown"
  fi
}

# Map a desktop id to its menu label
de_label() {
  case "$1" in
    plasma) echo "KDE Plasma" ;;
    gnome) echo "GNOME" ;;
    budgie) echo "Budgie" ;;
    xfce) echo "XFCE" ;;
    lxqt) echo "LXQt" ;;
    lxde) echo "LXDE" ;;
    mate) echo "MATE" ;;
    cinnamon) echo "Cinnamon" ;;
    i3) echo "i3" ;;
    *) echo "$1" ;;
  esac
}

# Run an interactive select menu for the given desktop ids
select_de_from_menu() {
  local prompt="$1"
  shift
  local ids=("$@")
  local options=() id label PS3 opt i
  for id in "${ids[@]}"; do
    label="$(de_label "$id")"
    options+=("$label")
  done
  options+=("Quit")

  PS3="$prompt"
  select opt in "${options[@]}"; do
    case "$opt" in
      "Quit")
        return 2
        ;;
      "")
        log "Invalid option $REPLY"
        ;;
      *)
        # Map the chosen label, not REPLY: select also accepts " 1" or "+1".
        for i in "${!ids[@]}"; do
          if [[ "${options[i]}" == "$opt" ]]; then
            echo "${ids[i]}"
            return 0
          fi
        done
        return 1
        ;;
    esac
  done
  return 1
}

# Prompt user to select a DE
prompt_de_selection() {
  log "No supported desktop environment detected."
  select_de_from_menu "Please select a desktop environment to install: " \
    xfce lxqt lxde mate cinnamon i3 plasma gnome budgie
}

# Prompt user to select among multiple detected DEs
prompt_detected_de_selection() {
  log "Multiple supported desktop environments detected: $*"
  select_de_from_menu "Please select a desktop environment to configure: " "$@"
}

# Print required packages for a desktop environment, one per line
list_packages() {
  local de="${1:-}" no_keyring=0
  if [[ "${2:-}" == "1" || "${2:-}" == "--no-keyring" ]]; then
    no_keyring=1
  fi
  local pkgs=()
  local base_pkgs=(xorg-server xorg-xinit udisks2 polkit gvfs gvfs-mtp gvfs-gphoto2 gvfs-afc)

  case "$de" in
    plasma)
      base_pkgs=(udisks2 polkit gvfs gvfs-mtp gvfs-gphoto2 gvfs-afc)
      pkgs=(plasma-desktop konsole dolphin kwallet-pam polkit-kde-agent)
      ;;
    gnome)
      base_pkgs=(udisks2 polkit gvfs gvfs-mtp gvfs-gphoto2 gvfs-afc)
      pkgs=(gnome-shell gnome-session gnome-control-center nautilus gnome-terminal gnome-keyring)
      ;;
    xfce)
      pkgs=(xfce4 xfce4-session xfce4-terminal gnome-keyring polkit-gnome)
      ;;
    lxqt)
      pkgs=(lxqt xdg-utils lxterminal gnome-keyring lxqt-policykit)
      ;;
    lxde)
      pkgs=(lxde-common lxsession lxpanel openbox pcmanfm lxterminal gnome-keyring)
      ;;
    mate)
      pkgs=(mate mate-terminal gnome-keyring)
      ;;
    cinnamon)
      pkgs=(cinnamon gnome-terminal gnome-keyring)
      ;;
    budgie)
      base_pkgs=(udisks2 polkit gvfs gvfs-mtp gvfs-gphoto2 gvfs-afc)
      pkgs=(budgie-desktop gnome-terminal gnome-keyring)
      ;;
    i3)
      pkgs=(i3 xterm dex gnome-keyring polkit-gnome)
      ;;
    *)
      log "Unsupported desktop environment: $de"
      return 1
      ;;
  esac

  if [[ $no_keyring -eq 1 ]]; then
    local pkg filtered_pkgs=()
    for pkg in "${pkgs[@]}"; do
      case "$pkg" in
        gnome-keyring | kwallet-pam) ;;
        *) filtered_pkgs+=("$pkg") ;;
      esac
    done
    pkgs=("${filtered_pkgs[@]}")
  fi

  printf '%s\n' "${base_pkgs[@]}" "${pkgs[@]}"
}

# Install required packages
install_packages() {
  local de="${1:-}" pkg_output pkgs=()
  pkg_output="$(list_packages "$@")" || exit 1
  mapfile -t pkgs <<<"$pkg_output"
  if [[ "${UPDATE_RUN:-0}" == 1 ]]; then
    update_packages "$de" "${pkgs[@]}"
    return
  fi

  log "Installing required packages for $de..."
  sudo pacman -S --needed --noconfirm "${pkgs[@]}" || return
  RECORDED_PACKAGES=("${pkgs[@]}")
}

# Print what --update does with each package of the desktop's list ($@): "install <pkg>" for one this
# lightXDM version added since the run that saved the list, "missing <pkg>" for a listed one that is
# not installed (the user removed it, or it never was); it stays out. Without a saved list (installs
# from before it), nothing is installed.
update_package_plan() {
  local choices_file recorded_line="" pkg
  local -a recorded=() unsatisfied=()
  choices_file="$(install_choices_file)"
  if install_choices_readable "$choices_file"; then
    recorded_line="$(sed -n 's/^packages=//p' "$choices_file" 2>/dev/null | tail -n 1)"
  fi
  read -r -a recorded <<<"$recorded_line"
  mapfile -t unsatisfied < <(pacman -T -- "$@" 2>/dev/null)
  for pkg in "$@"; do
    if [[ -n "$recorded_line" && " ${recorded[*]} " != *" $pkg "* ]]; then
      printf 'install %s\n' "$pkg"
    elif [[ " ${unsatisfied[*]} " == *" $pkg "* ]] && ! pacman -Qg -- "$pkg" >/dev/null 2>&1; then
      printf 'missing %s\n' "$pkg"
    fi
  done
}

# --update installs only the packages this lightXDM version adds and never reinstalls one the user
# removed; it says which ones it leaves out and how to install them.
update_packages() {
  local de="$1" what pkg
  shift
  local -a added=() missing=()
  while read -r what pkg; do
    case "$what" in
      install) added+=("$pkg") ;;
      missing) missing+=("$pkg") ;;
    esac
  done < <(update_package_plan "$@")
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "Not installed, so --update leaves them out: ${missing[*]} (lightXDM lists them for $de). Install them again with: sudo pacman -S --needed ${missing[*]}"
  fi
  if [[ ${#added[@]} -gt 0 ]]; then
    log "Installing the packages this lightXDM version adds for $de: ${added[*]}"
    sudo pacman -S --needed --noconfirm "${added[@]}" || return
  else
    log "No new packages for $de."
  fi
  RECORDED_PACKAGES=("$@")
  local choices_file recorded_line="" full_pkg
  local -a recorded=() full_pkgs=()
  choices_file="$(install_choices_file)"
  if install_choices_readable "$choices_file"; then
    recorded_line="$(sed -n 's/^packages=//p' "$choices_file" 2>/dev/null | tail -n 1)"
  fi
  if [[ -n "$recorded_line" ]]; then
    read -r -a recorded <<<"$recorded_line"
    mapfile -t full_pkgs < <(list_packages "$de" 2>/dev/null || true)
    for full_pkg in "${full_pkgs[@]}"; do
      case "$full_pkg" in
        gnome-keyring | kwallet-pam)
          if [[ " ${recorded[*]} " == *" $full_pkg "* && " ${RECORDED_PACKAGES[*]} " != *" $full_pkg "* ]]; then
            RECORDED_PACKAGES+=("$full_pkg")
          fi
          ;;
      esac
    done
  fi
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

# Back up a pre-existing dotfile once, or save post-install user edits before overwriting
preserve_dotfile() {
  local target="$1"
  shift
  local backup="${target}.lightxdm.bak"
  local absent="${target}.lightxdm.absent"
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    if [[ ! -e "$backup" && ! -L "$backup" && ! -e "$absent" && ! -L "$absent" ]]; then
      if [[ "$absent" == */* && ! -d "${absent%/*}" ]]; then
        mkdir -p -- "${absent%/*}" || return 1
      fi
      : > "$absent" || return 1
    fi
    return 0
  fi

  local tmpl target_sum="" recorded_sum=""
  if [[ -f "$target" && ! -L "$target" ]]; then
    if [[ ! -r "$target" ]]; then
      log "Cannot read $target to preserve it; fix permissions on $target and re-run."
      return 1
    fi
    target_sum="$(sha256sum < "$target")" || return 1
    for tmpl in "$@"; do
      [[ "$tmpl" -ef "$target" ]] && continue
      if [[ -f "$tmpl" && -r "$tmpl" && "$target_sum" == "$(sha256sum < "$tmpl")" ]]; then
        return 0
      fi
    done
    if [[ -e "$backup" || -L "$backup" || -e "$absent" || -L "$absent" ]]; then
      recorded_sum="$(recorded_dotfile_sum "$target")"
      if [[ -n "$recorded_sum" && "${target_sum%% *}" == "$recorded_sum" ]]; then
        return 0
      fi
    fi
    if is_past_lightxdm_template "$target" "${target#"$HOME"/}"; then
      return 0
    fi
  fi

  if [[ ! -e "$absent" && ! -L "$absent" ]]; then
    if [[ ! -e "$backup" && ! -L "$backup" ]]; then
      log "Backing up $target to $backup"
      cp -P "$target" "$backup" || return 1
      return 0
    fi

    if [[ -L "$target" && -L "$backup" ]]; then
      if [[ "$(readlink "$target")" == "$(readlink "$backup")" ]]; then
        return 0
      fi
    elif [[ -f "$target" && ! -L "$target" && -f "$backup" && ! -L "$backup" && -r "$backup" ]]; then
      if [[ "$target_sum" == "$(sha256sum < "$backup")" ]]; then
        return 0
      fi
    fi
  fi

  local edited="${target}.lightxdm-edited" n=1
  if [[ -e "$edited" || -L "$edited" ]]; then
    while [[ -e "${edited}.${n}" || -L "${edited}.${n}" ]]; do
      n=$((n + 1))
    done
    edited="${edited}.${n}"
  fi
  log "Saving edited $target to $edited"
  cp -P "$target" "$edited" || return 1
}

# Print the session template path for a session id
xinitrc_template() {
  local name=".xinitrc-$1"
  case "$1" in
    plasma | gnome | budgie) name=".wayland-session-$1" ;;
    xfce | lxqt | lxde | mate | cinnamon | i3) ;;
    *)
      local wayland_template="$HOME/.config/lightxdm/.wayland-session-$1"
      if [[ -f "$wayland_template" ]]; then
        if [[ -f "$HOME/.config/lightxdm/$name" ]]; then
          log "Both $HOME/.config/lightxdm/$name and $wayland_template exist; keep only one session template for $1."
          return 1
        fi
        name=".wayland-session-$1"
      fi
      ;;
  esac
  if [[ -f "$HOME/.config/lightxdm/$name" ]]; then
    printf '%s\n' "$HOME/.config/lightxdm/$name"
  else
    printf '%s\n' "$SCRIPT_DIR/dotfiles/$name"
  fi
}

# Parse [Desktop Entry] metadata and validate Exec/DesktopNames rules for --from-session and --list-sessions.
parse_desktop_session_entry() {
  local entry="$1" line key value in_desktop=0 exec_seen=0 desktop_seen=0 exec_value=""
  SESSION_ENTRY_NAME=""
  SESSION_ENTRY_EXEC_LINE=""
  SESSION_ENTRY_EXEC_CMD=""
  SESSION_ENTRY_DESKTOP=""
  SESSION_ENTRY_TRY_EXEC=""
  SESSION_ENTRY_HIDDEN=0
  SESSION_ENTRY_NO_DISPLAY=0
  SESSION_ENTRY_ERROR=""

  if [[ ! -f "$entry" || ! -r "$entry" ]]; then
    SESSION_ENTRY_ERROR="Cannot read session entry: $entry"
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      '' | \#*) continue ;;
      '[Desktop Entry]') in_desktop=1; continue ;;
      \[*\]) in_desktop=0; continue ;;
    esac
    [[ $in_desktop -eq 1 && "$line" == *=* ]] || continue
    key="${line%%=*}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    case "$key" in
      Name)
        [[ -n "$SESSION_ENTRY_NAME" ]] || SESSION_ENTRY_NAME="$value"
        ;;
      Hidden)
        case "$value" in
          true | 1 | True | TRUE) SESSION_ENTRY_HIDDEN=1 ;;
        esac
        ;;
      NoDisplay)
        case "$value" in
          true | 1 | True | TRUE) SESSION_ENTRY_NO_DISPLAY=1 ;;
        esac
        ;;
      TryExec)
        [[ -n "$SESSION_ENTRY_TRY_EXEC" ]] || SESSION_ENTRY_TRY_EXEC="$value"
        ;;
      Exec)
        if [[ $exec_seen -eq 1 ]]; then
          [[ -n "$SESSION_ENTRY_ERROR" ]] || SESSION_ENTRY_ERROR="Duplicate Exec in [Desktop Entry]: $entry"
        else
          exec_seen=1
          exec_value="$value"
        fi
        ;;
      DesktopNames)
        if [[ $desktop_seen -eq 1 || -z "${value%%;*}" ]]; then
          [[ -n "$SESSION_ENTRY_ERROR" ]] || SESSION_ENTRY_ERROR="Invalid DesktopNames in [Desktop Entry]: $entry"
        else
          desktop_seen=1
          SESSION_ENTRY_DESKTOP="${value%%;*}"
        fi
        ;;
    esac
  done <"$entry"

  [[ -z "$SESSION_ENTRY_ERROR" ]] || return 1

  # This deliberately supports only literal words and whole double-quoted words.
  # Never interpret desktop entries as shell code or expand desktop field codes.
  if [[ $exec_seen -eq 0 || "$exec_value" == *%* || "$exec_value" == *\\* ]]; then
    SESSION_ENTRY_ERROR="Missing or unsupported Exec in [Desktop Entry] (field codes and backslash escapes are refused): $entry"
    return 1
  fi
  local remaining="$exec_value" word quoted_word='^"([^"]*)"([[:space:]]|$)'
  local exec_args=()
  while :; do
    remaining="${remaining#"${remaining%%[![:space:]]*}"}"
    [[ -n "$remaining" ]] || break
    if [[ "$remaining" == \"* ]]; then
      if [[ ! "$remaining" =~ $quoted_word ]]; then
        SESSION_ENTRY_ERROR="Unsupported quoting in Exec: $entry"
        return 1
      fi
      word="${BASH_REMATCH[1]}"
      remaining="${remaining:${#BASH_REMATCH[0]}}"
    else
      word="${remaining%%[[:space:]]*}"
      remaining="${remaining:${#word}}"
      if [[ "$word" == *\"* || "$word" == *"'"* ]]; then
        SESSION_ENTRY_ERROR="Unsupported quoting in Exec: $entry"
        return 1
      fi
    fi
    exec_args+=("$word")
  done
  if [[ ${#exec_args[@]} -eq 0 || -z "${exec_args[0]}" ]]; then
    SESSION_ENTRY_ERROR="Empty Exec in [Desktop Entry]: $entry"
    return 1
  fi
  SESSION_ENTRY_EXEC_CMD="${exec_args[0]}"
  printf -v SESSION_ENTRY_EXEC_LINE '%q ' "${exec_args[@]}"
  SESSION_ENTRY_EXEC_LINE="exec ${SESSION_ENTRY_EXEC_LINE% }"
}

# True when command $1 (absolute path under SESSION_ROOT or command name on PATH) is executable.
session_command_exists() {
  local cmd="$1"
  [[ -n "$cmd" ]] || return 1
  if [[ "$cmd" == /* ]]; then
    [[ -f "${SESSION_ROOT:-}$cmd" && -x "${SESSION_ROOT:-}$cmd" ]]
  else
    PATH="$HOME/.local/bin:$PATH" command -v "$cmd" >/dev/null 2>&1
  fi
}

# Normalize a .desktop filename into a valid custom session id under LC_ALL=C.
suggest_custom_session_id() {
  local LC_ALL=C stem="${1##*/}"
  stem="${stem%.desktop}"
  stem="$(printf '%s' "$stem" | LC_ALL=C tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')"
  while [[ "$stem" == *[!abcdefghijklmnopqrstuvwxyz0123456789_-]* ]]; do
    stem="${stem/[!abcdefghijklmnopqrstuvwxyz0123456789_-]/-}"
  done
  while [[ "$stem" == -* ]]; do
    stem="${stem#-}"
  done
  [[ -n "$stem" ]] || stem="custom"
  case "$stem" in
    plasma | gnome | budgie | xfce | lxqt | lxde | mate | cinnamon | i3)
      printf '%s-custom\n' "$stem"
      ;;
    *)
      printf '%s\n' "$stem"
      ;;
  esac
}

# List installed freedesktop X11 and Wayland session entries and their --from-session compatibility.
list_desktop_sessions() {
  local LC_ALL=C
  local xsessions_dir="${XSESSIONS_DIR:-${SESSION_ROOT:-}/usr/share/xsessions}"
  local wayland_dir="${WAYLAND_SESSIONS_DIR:-${SESSION_ROOT:-}/usr/share/wayland-sessions}"
  local session_type dir entry label raw_stem suggested_id status_note init_cmd existing_tmpl found=0
  local SESSION_ENTRY_NAME="" SESSION_ENTRY_EXEC_LINE="" SESSION_ENTRY_EXEC_CMD=""
  local SESSION_ENTRY_DESKTOP="" SESSION_ENTRY_TRY_EXEC=""
  local SESSION_ENTRY_HIDDEN=0 SESSION_ENTRY_NO_DISPLAY=0 SESSION_ENTRY_ERROR=""

  for session_type in x11 wayland; do
    if [[ "$session_type" == x11 ]]; then
      dir="$xsessions_dir"
    else
      dir="$wayland_dir"
    fi
    [[ -d "$dir" ]] || continue
    if [[ ! -r "$dir" || ! -x "$dir" ]]; then
      log "Note: cannot read session directory $dir."
      continue
    fi
    for entry in "$dir"/*.desktop; do
      [[ -e "$entry" || -L "$entry" ]] || continue
      if parse_desktop_session_entry "$entry"; then
        [[ $SESSION_ENTRY_HIDDEN -eq 0 && $SESSION_ENTRY_NO_DISPLAY -eq 0 ]] || continue
        found=$((found + 1))
        label="${SESSION_ENTRY_NAME:-${entry##*/}}"
        raw_stem="${entry##*/}"
        raw_stem="${raw_stem%.desktop}"
        raw_stem="$(printf '%s' "$raw_stem" | LC_ALL=C tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')"
        suggested_id="$(suggest_custom_session_id "$entry")"
        if [[ -n "$SESSION_ENTRY_TRY_EXEC" ]] && ! session_command_exists "$SESSION_ENTRY_TRY_EXEC"; then
          status_note="unavailable (missing TryExec: $SESSION_ENTRY_TRY_EXEC)"
        elif ! session_command_exists "$SESSION_ENTRY_EXEC_CMD"; then
          status_note="unavailable (missing command: $SESSION_ENTRY_EXEC_CMD)"
        else
          status_note="ready"
        fi
        if [[ "$session_type" == wayland ]]; then
          existing_tmpl="$HOME/.config/lightxdm/.wayland-session-$suggested_id"
          printf -v init_cmd '%s --init-template --wayland --de %q --from-session %q' \
            "$(script_cmd install.sh)" "$suggested_id" "$entry"
        else
          existing_tmpl="$HOME/.config/lightxdm/.xinitrc-$suggested_id"
          printf -v init_cmd '%s --init-template --de %q --from-session %q' \
            "$(script_cmd install.sh)" "$suggested_id" "$entry"
        fi
        case "$raw_stem" in
          plasma | gnome | budgie | xfce | lxqt | lxde | mate | cinnamon | i3)
            status_note+="; built-in: --de $raw_stem"
            ;;
        esac
        if [[ -n "$SESSION_ENTRY_DESKTOP" ]]; then
          status_note+="; desktop: $SESSION_ENTRY_DESKTOP"
        fi
        if [[ -e "$existing_tmpl" || -L "$existing_tmpl" ]]; then
          status_note+="; template exists: $existing_tmpl"
        fi
        printf '[%s] %s (%s) — %s\n' "$session_type" "$label" "$entry" "$status_note"
        if [[ "$status_note" == ready* ]]; then
          printf '  init: %s\n' "$init_cmd"
        fi
      else
        [[ $SESSION_ENTRY_HIDDEN -eq 0 && $SESSION_ENTRY_NO_DISPLAY -eq 0 ]] || continue
        found=$((found + 1))
        label="${SESSION_ENTRY_NAME:-${entry##*/}}"
        status_note="${SESSION_ENTRY_ERROR%: "$entry"}"
        printf '[%s] %s (%s) — unsupported (%s)\n' "$session_type" "$label" "$entry" "$status_note"
      fi
    done
  done

  if [[ $found -eq 0 ]]; then
    printf 'No session entries found in %s or %s.\n' "$xsessions_dir" "$wayland_dir"
  fi
}

# Create ~/.config/lightxdm/.xinitrc-<id> (or .wayland-session-<id>) to edit: a copy of the
# built-in template, or a custom X11 (from i3) or minimal Wayland template.
init_xinitrc_template() {
  local id="$1" wayland="${2:-0}" dest="$HOME/.config/lightxdm/.xinitrc-$1"
  local from_session="${3:-}" exec_line="exec $1" current_desktop="$1"
  local SESSION_ENTRY_NAME="" SESSION_ENTRY_EXEC_LINE="" SESSION_ENTRY_EXEC_CMD=""
  local SESSION_ENTRY_DESKTOP="" SESSION_ENTRY_TRY_EXEC=""
  local SESSION_ENTRY_HIDDEN=0 SESSION_ENTRY_NO_DISPLAY=0 SESSION_ENTRY_ERROR=""
  case "$id" in
    plasma | gnome | budgie) dest="$HOME/.config/lightxdm/.wayland-session-$id" ;;
  esac
  # Explicit character list: [a-z] ranges miss "i" under some locales (for example tr_TR).
  if [[ -z "$id" || "$id" == *[!abcdefghijklmnopqrstuvwxyz0123456789_-]* ]]; then
    log "Invalid desktop id: $id (use lowercase letters, digits, _ and -)"
    return 1
  fi
  if [[ -n "$from_session" ]]; then
    case "$id" in
      plasma | gnome | budgie | xfce | lxqt | lxde | mate | cinnamon | i3)
        log "--from-session is only for custom ids; $id has a built-in template."
        return 1
        ;;
    esac
  fi
  if [[ $wayland -eq 1 ]]; then
    case "$id" in
      plasma | gnome | budgie)
        log "--wayland is only for custom ids; $id already has a Wayland template. Use --init-template --de $id."
        return 1
        ;;
      xfce | lxqt | lxde | mate | cinnamon | i3)
        log "--wayland is only for custom ids; $id uses an X11 template."
        return 1
        ;;
    esac
    dest="$HOME/.config/lightxdm/.wayland-session-$id"
  fi
  if [[ -e "$dest" || -L "$dest" ]]; then
    log "$dest already exists; edit it, or remove it to start over."
    return 1
  fi
  case "$id" in
    plasma | gnome | budgie | xfce | lxqt | lxde | mate | cinnamon | i3) ;;
    *)
      # install.sh refuses a custom id with both templates, so never create the second one.
      local sibling="$HOME/.config/lightxdm/.wayland-session-$id"
      [[ $wayland -eq 1 ]] && sibling="$HOME/.config/lightxdm/.xinitrc-$id"
      if [[ -e "$sibling" || -L "$sibling" ]]; then
        log "$sibling already exists for $id; a custom id uses one session template: edit it, or remove it to switch."
        return 1
      fi
      ;;
  esac
  if [[ -n "$from_session" ]]; then
    if ! parse_desktop_session_entry "$from_session"; then
      log "$SESSION_ENTRY_ERROR"
      return 1
    fi
    exec_line="$SESSION_ENTRY_EXEC_LINE"
    if [[ -n "$SESSION_ENTRY_DESKTOP" ]]; then
      current_desktop="$SESSION_ENTRY_DESKTOP"
    fi
  fi
  mkdir -p "$HOME/.config/lightxdm"
  case "$id" in
    plasma | gnome | budgie)
      cp -- "$SCRIPT_DIR/dotfiles/.wayland-session-$id" "$dest"
      chmod 755 "$dest"
      log "Created $dest from the built-in $id template. Edit it, then run: $(script_cmd install.sh) --de $id"
      ;;
    xfce | lxqt | lxde | mate | cinnamon | i3)
      cp -- "$SCRIPT_DIR/dotfiles/.xinitrc-$id" "$dest"
      chmod 755 "$dest"
      log "Created $dest from the built-in $id template. Edit it, then run: $(script_cmd install.sh) --de $id"
      ;;
    *)
      if [[ $wayland -eq 1 ]]; then
        local quoted_desktop
        printf -v quoted_desktop '%q' "$current_desktop"
        cat >"$dest" <<EOF
#!/bin/bash
# Wayland session for lightXDM: start $id

export DESKTOP_SESSION=$id
export XDG_CURRENT_DESKTOP=$quoted_desktop
export XDG_SESSION_TYPE=wayland

if [[ -f ~/.gpg-agent-gnome ]]; then
  source ~/.gpg-agent-gnome
fi

$exec_line
EOF
      else
        local template_line
        while IFS= read -r template_line || [[ -n "$template_line" ]]; do
          case "$template_line" in
            '# .xinitrc for lightXDM: start i3 '*)
              printf '# .xinitrc for lightXDM: start %s%s\n' "$id" "${template_line#'# .xinitrc for lightXDM: start i3'}" ;;
            'export XDG_CURRENT_DESKTOP=i3') printf 'export XDG_CURRENT_DESKTOP=%q\n' "$current_desktop" ;;
            # Like the earlier sed rule: every other `export NAME=i3` names the session after the id.
            'export '*'=i3') printf '%s=%s\n' "${template_line%=i3}" "$id" ;;
            '# i3 does not update the activation environment itself, unlike full desktops.')
              printf '%s\n' '# Window managers often do not update the activation environment themselves.' ;;
            'exec i3') printf '%s\n' "$exec_line" ;;
            *) printf '%s\n' "$template_line" ;;
          esac
        done <"$SCRIPT_DIR/dotfiles/.xinitrc-i3" >"$dest"
      fi
      chmod 755 "$dest"
      log "Created $dest for $id. Check its exec line, then run: $(script_cmd install.sh) --no-packages --de $id"
      ;;
  esac
}

# Parse Bash templates without executing them, before installing packages or previewing changes.
check_template_syntax() {
  local template="$1"
  # Leave unreadable templates to check_session_commands and the preview's existing reporting.
  [[ -r "$template" ]] || return 0
  local first_line="" parse_error
  IFS= read -r first_line < "$template" || true
  if [[ "$first_line" =~ ^('#!/bin/bash'|'#!/usr/bin/bash'|'#!/usr/bin/env bash')[[:blank:]]*$ ]]; then
    # Templates may enable extglob before using it; -n never runs that shopt, so enable it here.
    if ! parse_error="$(bash -O extglob -n -- "$template" 2>&1)"; then
      log "Invalid Bash syntax in $template: ${parse_error//$'\n'/ }"
      return 1
    fi
  fi
}

# Refuse a user session template that resolves to the target dotfile itself.
check_template_not_self() {
  local de="$1" template="$2"
  if [[ "${template##*/}" == .wayland-session-* ]]; then
    if [[ ! -L "$HOME/.wayland-session" && "$template" -ef "$HOME/.wayland-session" ]]; then
      log "The template for $de is ~/.wayland-session itself: $template. Installation aborted."
      return 1
    fi
  elif [[ ! -L "$HOME/.xinitrc" && "$template" -ef "$HOME/.xinitrc" ]]; then
    log "The template for $de is ~/.xinitrc itself: $template. Installation aborted."
    return 1
  fi
}

# Check startup commands before changing the user's session configuration
check_session_commands() {
  local template="$1" base="${1##*/}" line session_line="" session_command package
  if [[ ! -r "$template" ]]; then
    log "Cannot read $template; fix its permissions and re-run."
    return 1
  fi
  if [[ "$base" == .wayland-session || "$base" == .wayland-session-* ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        "exec "*) session_line="${line#exec }" ;;
      esac
    done < "$template"
    local tokens=() token check_path
    # Escapes written by printf %q for imported paths must join words as the shell does when running the template.
    # shellcheck disable=SC2162
    read -a tokens <<< "$session_line"
    for token in "${tokens[@]}"; do
      [[ "$token" == -* ]] && break
      [[ "$token" == /* ]] || continue
      check_path="${SESSION_ROOT:-}$token"
      if [[ ! -f "$check_path" || ! -x "$check_path" ]]; then
        case "$base" in
          .wayland-session-plasma)
            log "Missing command: $token (normally provided by plasma-workspace). Install plasma-desktop and re-run."
            ;;
          .wayland-session-gnome)
            log "Missing command: $token (normally provided by gnome-session). Install gnome-session and re-run."
            ;;
          .wayland-session-budgie)
            log "Missing command: $token (normally provided by budgie-desktop). Install budgie-desktop and re-run."
            ;;
          *)
            log "Missing command: $token. Install your session and ensure $token exists and is executable, then re-run."
            ;;
        esac
        return 1
      fi
    done
    read -r session_command _ <<< "$session_line"
    # As with X11 templates, inspect only a literal command name.
    if [[ "$session_command" =~ ^[[:alnum:]_][[:alnum:]_.+-]*$ ]] &&
      ! PATH="$HOME/.local/bin:$PATH" command -v "$session_command" >/dev/null 2>&1; then
      log "Missing command: $session_command. Install your session and ensure its command is on PATH, then re-run."
      return 1
    fi
    return 0
  fi

  if ! command -v startx >/dev/null 2>&1; then
    log "Missing command: startx (normally provided by xorg-xinit). Install xorg-xinit and re-run."
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "exec "*) session_line="${line#exec }" ;;
    esac
  done < "$template"
  read -r session_command _ <<< "$session_line"
  # Only inspect a literal command name; custom templates may use shell expressions or paths.
  if [[ "$session_command" =~ ^[[:alnum:]_][[:alnum:]_.+-]*$ ]] &&
    ! PATH="$HOME/.local/bin:$PATH" command -v "$session_command" >/dev/null 2>&1; then
    case "$session_command" in
      startxfce4) package="xfce4-session" ;;
      startlxqt) package="lxqt-session" ;;
      startlxde) package="lxde-common" ;;
      mate-session) package="mate-session-manager" ;;
      cinnamon-session) package="cinnamon-session" ;;
      i3) package="i3-wm" ;;
      *) package="" ;;
    esac
    if [[ -n "$package" ]]; then
      log "Missing command: $session_command (normally provided by $package). Install $package and re-run."
    else
      log "Missing command: $session_command. Install your session and ensure its command is on PATH, then re-run."
    fi
    return 1
  fi
  return 0
}

# Where lightXDM keeps the hash of what it last wrote into each home dotfile, so --update can tell
# its own unchanged copy from the user's edit.
dotfile_record_file() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/lightxdm/installed-dotfiles"
}

# Print the recorded hash of what lightXDM last wrote into home dotfile $1, if there is one.
recorded_dotfile_sum() {
  local rel="${1#"$HOME"/}" file dir line sum="" LC_ALL=C
  file="$(dotfile_record_file)"
  dir="${file%/*}"
  [[ ! -L "$dir" && -f "$file" && ! -L "$file" && -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "${line:66}" == "$rel" && "${line:64:2}" == "  " && "${line:0:64}" =~ ^[0-9a-f]{64}$ ]]; then
      sum="${line:0:64}"
    fi
  done <"$file"
  [[ -z "$sum" ]] || printf '%s\n' "$sum"
}

# Record what lightXDM just wrote into home dotfile $1 ("<sha256>  <path under HOME>" per line).
record_dotfile() {
  local target="$1" file dir rel sum line kept=() tmp="" LC_ALL=C
  file="$(dotfile_record_file)"
  dir="${file%/*}"
  [[ ! -L "$dir" ]] || return 1
  rel="${target#"$HOME"/}"
  sum="$(sha256sum <"$target")" || return 1
  if [[ -f "$file" && ! -L "$file" && -r "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "${line:66}" == "$rel" ]] || kept+=("$line")
    done <"$file"
  fi
  mkdir -p -- "$dir" || return 1
  [[ ! -L "$dir" ]] || return 1
  if ! { tmp="$(mktemp "$dir/.installed-dotfiles.XXXXXX")" &&
    printf '%s\n' "${kept[@]}" "${sum%% *}  $rel" >"$tmp" &&
    chmod 644 -- "$tmp" &&
    mv -Tf -- "$tmp" "$file"; }; then
    [[ -z "$tmp" ]] || rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
}

# True when lightXDM put home dotfile $1 there before: it recorded what it wrote, or it backed up the
# user's original or noted there was none (installs from before the record).
dotfile_installed_before() {
  local target="$1"
  [[ -n "$(recorded_dotfile_sum "$target")" || -e "${target}.lightxdm.bak" || -L "${target}.lightxdm.bak" ||
    -e "${target}.lightxdm.absent" || -L "${target}.lightxdm.absent" ]]
}

# True when home dotfile $1 is lightXDM's own unchanged copy: what lightXDM last wrote there, the
# template it would write now ($2), or a template an older lightXDM bundled.
dotfile_unchanged() {
  local target="$1" source="$2" sum
  [[ -f "$target" && ! -L "$target" && -r "$target" && -f "$source" && -r "$source" ]] || return 1
  sum="$(sha256sum <"$target")"
  [[ "${sum%% *}" == "$(recorded_dotfile_sum "$target")" || "$sum" == "$(sha256sum <"$source")" ]] ||
    is_past_lightxdm_template "$target" "${target#"$HOME"/}"
}

# --update refreshes a dotfile only while it is lightXDM's own unchanged copy. An edited file (or a
# symlink) stays, with the current template beside it as *.lightxdm-new; a dotfile the user removed
# stays removed; one this lightXDM version adds for the first time is installed.
update_dotfile() {
  local preview="$1" mode="$2" source="$3" target="$4"
  local new="${target}.lightxdm-new"
  if [[ ! -e "$target" && ! -L "$target" ]] && dotfile_installed_before "$target"; then
    if [[ "$preview" == 1 ]]; then
      printf 'Dotfile: %s (stays removed: --update)\n' "$target"
    else
      log "$target is gone, so --update leaves it out; to put it back, run: $(printf 'install -Dm%s %q %q' "$mode" "$source" "$target")"
    fi
    return 0
  fi
  if [[ ! -e "$target" && ! -L "$target" ]] || dotfile_unchanged "$target" "$source"; then
    if [[ "$preview" == 1 ]]; then
      printf 'Dotfile: %s\n' "$target"
      return 0
    fi
    if [[ ! -e "$target" ]]; then
      preserve_dotfile "$target" "$source" || return
    fi
    install -TDm"$mode" "$source" "$target" || return
    record_dotfile "$target" || log "WARNING: Could not record $target in $(dotfile_record_file)."
    rm -f -- "$new"
    return 0
  fi
  if [[ "$preview" == 1 ]]; then
    printf 'Dotfile: %s (stays: your own edits; current template to %s)\n' "$target" "$new"
    return 0
  fi
  install -TDm"$mode" "$source" "$new" || return
  log "$target has your own edits, so --update leaves it alone; the current template is in $new (compare: $(printf 'diff -u %q %q' "$target" "$new"))."
}

# Preview or preserve and install a dotfile, using the same destination and templates.
copy_dotfile() {
  local preview="$1" mode="$2" source="$3" target="$4"
  shift 4
  if [[ "${UPDATE_RUN:-0}" == 1 ]]; then
    update_dotfile "$preview" "$mode" "$source" "$target"
    return
  fi
  if [[ "$preview" == 1 ]]; then
    printf 'Dotfile: %s\n' "$target"
    return 0
  fi
  if [[ $# -eq 0 ]]; then
    preserve_dotfile "$target" "$source" || return
  else
    preserve_dotfile "$target" "$@" || return
  fi
  install -TDm"$mode" "$source" "$target" || return
  record_dotfile "$target" || log "WARNING: Could not record $target in $(dotfile_record_file); --update will treat it as edited."
}

# Copy dotfiles to the user's home directory (or print destinations with preview=1).
copy_dotfiles() {
  local de preview="${2:-0}"
  de=$1
  local user_home
  user_home=$HOME

  if [[ $preview -eq 0 ]]; then
    log "Copying dotfiles to $user_home..."
  fi
  copy_dotfile "$preview" 644 "$SCRIPT_DIR/dotfiles/.bash_profile" "$user_home/.bash_profile" || return

  if [[ "$de" == "plasma" ]]; then
    copy_dotfile "$preview" 744 "$SCRIPT_DIR/dotfiles/.gpg-agent-gnome" "$user_home/.gpg-agent-kwallet" || return
  else
    copy_dotfile "$preview" 744 "$SCRIPT_DIR/dotfiles/.gpg-agent-gnome" "$user_home/.gpg-agent-gnome" || return
  fi
  # The helper runs before a Wayland compositor starts; this re-runs its refresh inside the session.
  copy_dotfile "$preview" 644 "$SCRIPT_DIR/dotfiles/lightxdm-gpg-agent-tty.desktop" "$user_home/.config/autostart/lightxdm-gpg-agent-tty.desktop" || return

  local template base
  template="$(xinitrc_template "$de")" || return
  base="${template##*/}"
  if [[ -f "$template" ]]; then
    if [[ $preview -eq 0 && "$template" == "$user_home/.config/lightxdm/"* ]]; then
      log "Using your session template $template"
    fi
    if [[ "$base" == .wayland-session-* ]]; then
      local wayland_templates=("$SCRIPT_DIR"/dotfiles/.wayland-session-*)
      if [[ -e "$user_home/.wayland-session.lightxdm.bak" || -L "$user_home/.wayland-session.lightxdm.bak" ||
        -e "$user_home/.wayland-session.lightxdm.absent" || -L "$user_home/.wayland-session.lightxdm.absent" ]]; then
        wayland_templates=("$user_home"/.config/lightxdm/.wayland-session-* "${wayland_templates[@]}")
      fi
      copy_dotfile "$preview" 755 "$template" "$user_home/.wayland-session" "${wayland_templates[@]}" || return
    else
      local xinitrc_templates=("$SCRIPT_DIR"/dotfiles/.xinitrc-*)
      if [[ -e "$user_home/.xinitrc.lightxdm.bak" || -L "$user_home/.xinitrc.lightxdm.bak" ||
        -e "$user_home/.xinitrc.lightxdm.absent" || -L "$user_home/.xinitrc.lightxdm.absent" ]]; then
        xinitrc_templates=("$HOME"/.config/lightxdm/.xinitrc-* "${xinitrc_templates[@]}")
      fi
      copy_dotfile "$preview" 755 "$template" "$user_home/.xinitrc" "${xinitrc_templates[@]}" || return

      local wl_session="$user_home/.wayland-session"
      # An executable ~/.wayland-session would start instead of startx, so move it aside like
      # ~/.xinitrc; skip absent files so X11-only homes get no .lightxdm.absent marker.
      if [[ -e "$wl_session" || -L "$wl_session" ]]; then
        local wl_templates=("$SCRIPT_DIR"/dotfiles/.wayland-session-*)
        if [[ -e "${wl_session}.lightxdm.bak" || -L "${wl_session}.lightxdm.bak" ||
          -e "${wl_session}.lightxdm.absent" || -L "${wl_session}.lightxdm.absent" ]]; then
          wl_templates=("$user_home"/.config/lightxdm/.wayland-session-* "${wl_templates[@]}")
        fi
        if [[ "${UPDATE_RUN:-0}" == 1 ]]; then
          # Only an explicit install moves the user's file away; --update says what it changes.
          if [[ -x "$wl_session" && $preview -eq 1 ]]; then
            printf 'Dotfile: %s (stays: it starts instead of startx; --update)\n' "$wl_session"
          elif [[ -x "$wl_session" ]]; then
            log "$wl_session is executable, so TTY1 starts it instead of startx; --update leaves it alone. Remove it, or make it non-executable, to start $de on TTY1."
          fi
        elif [[ $preview -eq 1 ]]; then
          printf 'Remove dotfile (preserving existing content): %s\n' "$wl_session"
        else
          preserve_dotfile "$wl_session" "${wl_templates[@]}" || return
          rm -f -- "$wl_session"
          log "Removed $wl_session so $de can start on TTY1 (originals: ${wl_session}.lightxdm.bak; saved edits: ${wl_session}.lightxdm-edited*)."
        fi
      fi
    fi
  else
    if [[ "$base" == .wayland-session-* ]]; then
      log "No Wayland session template for $de. Please create $template for proper session startup."
    else
      log "No .xinitrc template for $de. Please create $template for proper session startup."
    fi
    return 1
  fi
}

# True when inspecting $1 ($2 == 1 for regular non-symlink backup/state files) cannot be settled without sudo.
pam_path_needs_sudo() {
  local file="$1" no_symlink="${2:-0}" dir
  dir="$(dirname -- "$file")"
  if [[ $no_symlink -eq 1 && ( -L "$dir" || -L "$file" ) ]]; then
    return 1
  fi
  if [[ -f "$file" && -r "$file" ]] ||
    [[ -d "$dir" && -x "$dir" && ! -e "$file" ]] ||
    [[ ! -e "$dir" && ! -L "$dir" && -x "$(dirname -- "$dir")" ]]; then
    return 1
  fi
  return 0
}

# Print PAM file $1; use sudo only during a real run ($2 == 0) when $1 is not user-readable.
read_pam_file() {
  local file="$1" preview="${2:-0}"
  if [[ -f "$file" && -r "$file" ]]; then
    cat -- "$file"
  elif [[ $preview -eq 0 ]] && pam_path_needs_sudo "$file" 0 && sudo test -f "$file"; then
    sudo cat -- "$file"
  else
    return 1
  fi
}

# Print regular non-symlink PAM backup or state file $1; use sudo only during a real run ($2 == 0).
read_pam_state_file() {
  local file="$1" preview="${2:-0}" dir
  dir="$(dirname -- "$file")"
  if [[ -L "$dir" || -L "$file" ]]; then
    return 1
  fi
  if [[ -f "$file" && -r "$file" ]]; then
    cat -- "$file"
  elif [[ $preview -eq 0 ]] && pam_path_needs_sudo "$file" 1 &&
    ! sudo test -L "$dir" && ! sudo test -L "$file" && sudo test -f "$file"; then
    sudo cat -- "$file"
  else
    return 1
  fi
}

# Installs before 2026-11-03 backed up to .lightxde.bak.<epoch>; adopt the oldest one as the
# original so a re-install does not back up a login file that already holds old keyring lines.
legacy_pam_backup_candidate() {
  local preview="${1:-0}" backup_file="${LOGIN_FILE}.lightxdm.bak" old_backup epoch oldest_epoch="" login_content
  if [[ -e "$backup_file" || -L "$backup_file" ]]; then
    return 0
  fi
  # Without old keyring lines in the login file, an uninstall already restored the original;
  # a newer leftover backup may hold keyring lines and must not become the original.
  login_content="$(read_pam_file "$LOGIN_FILE" "$preview" 2>/dev/null)" || return 0
  grep -Fxq -f <(printf '%s\n' "${LIGHTXDM_KEYRING_LINES[@]}") <<<"$login_content" || return 0
  for old_backup in "${LOGIN_FILE}".lightxde.bak.*; do
    epoch="${old_backup##*.lightxde.bak.}"
    if [[ -f "$old_backup" && ! -L "$old_backup" && "$epoch" =~ ^[0-9]+$ ]] && { [[ -z "$oldest_epoch" ]] || ((10#$epoch < 10#$oldest_epoch)); }; then
      oldest_epoch="$epoch"
    fi
  done
  if [[ -n "$oldest_epoch" ]]; then
    printf '%s\n' "${LOGIN_FILE}.lightxde.bak.${oldest_epoch}"
  fi
}

adopt_legacy_pam_backup() {
  local old_backup
  old_backup="$(legacy_pam_backup_candidate 0)"
  if [[ -n "$old_backup" ]]; then
    log "Using $old_backup as the original $LOGIN_FILE backup."
    sudo mv -- "$old_backup" "${LOGIN_FILE}.lightxdm.bak" || return 1
    if [[ -r "$LOGIN_FILE" && ! -r "${LOGIN_FILE}.lightxdm.bak" ]]; then
      sudo chmod --reference="$LOGIN_FILE" -- "${LOGIN_FILE}.lightxdm.bak" || return 1
    fi
  fi
}

# Print only the keyring rules missing from the current login stack; the lines in $4 (one per line)
# do not count, because configure_pam removes them first.
pam_lines_to_add() {
  local module_re="${1//./\\.}" auth_line="$2" session_line="$3" removed="${4:-}" preview="${5:-0}" login_content stack
  login_content="$(read_pam_file "$LOGIN_FILE" "$preview")" || return 1
  stack="$(grep -Fvx -f <(grep -v '^$' <<<"$removed") <<<"$login_content" || true)"
  if ! grep -Eq "^[[:space:]]*-?auth[[:space:]][^#]*${module_re}" <<<"$stack"; then
    printf '%s\n' "$auth_line"
  fi
  if ! grep -Eq "^[[:space:]]*-?session[[:space:]][^#]*${module_re}" <<<"$stack"; then
    printf '%s\n' "$session_line"
  fi
}

# Print the lightXDM keyring lines to remove: each line lightXDM ever appended that the login file
# has, the original backup lacks, and the chosen backend ($1 auth, $2 session line) no longer uses.
pam_lines_to_remove() {
  local keep_auth="$1" keep_session="$2" preview="${3:-0}" backup_file="${LOGIN_FILE}.lightxdm.bak" line module="" login_content backup_content
  if [[ ! -e "$backup_file" && ! -L "$backup_file" ]]; then
    backup_file="$(legacy_pam_backup_candidate "$preview")"
  fi
  [[ -f "$backup_file" && ! -L "$backup_file" ]] || return 0
  login_content="$(read_pam_file "$LOGIN_FILE" "$preview")" || return 1
  backup_content="$(read_pam_file "$backup_file" "$preview")" || return 1
  [[ ! "$keep_auth" =~ (pam_[[:alnum:]_]+\.so) ]] || module="${BASH_REMATCH[1]}"
  for line in "${LIGHTXDM_KEYRING_LINES[@]}"; do
    # --update refreshes only an older form of the backend's own lines: the other backend's lines are
    # the user's, since only an explicit install switches desktops.
    if [[ "${UPDATE_RUN:-0}" == 1 && "$line" != *" $module"* ]]; then
      continue
    fi
    if [[ "$line" != "$keep_auth" && "$line" != "$keep_session" ]] &&
      grep -Fxq -- "$line" <<<"$login_content" && ! grep -Fxq -- "$line" <<<"$backup_content"; then
      printf '%s\n' "$line"
    fi
  done
}

# Format `--pam-only --de <id> [--keyring <backend>]` for remediation hints, keeping built-ins
# free of --keyring while preserving the backend for custom desktop ids.
pam_restore_hint() {
  local de="${1:-}" backend="${2:-}" target_de="" hint=""
  if [[ -n "$de" ]]; then
    target_de="$de"
  elif [[ "$backend" == kwallet ]]; then
    target_de="plasma"
  elif [[ "$backend" == gnome ]]; then
    target_de="gnome"
  else
    target_de="<id>"
  fi
  hint="--pam-only --de $target_de"
  if [[ -n "$de" && -n "$backend" ]]; then
    case "$de" in
      plasma | gnome | xfce | lxqt | lxde | mate | cinnamon | budgie | i3) ;;
      *) hint+=" --keyring $backend" ;;
    esac
  fi
  printf '%s\n' "$hint"
}

# Configure PAM for KWallet/GNOME Keyring auto-unlock, or preview the missing lines.
configure_pam() {
  local de preview="${2:-0}" keyring="${3:-gnome}"
  de=$1

  if [[ $preview -eq 1 ]]; then
    printf 'PAM keyring: %s\n' "$LOGIN_FILE"
    if [[ ! -r "$LOGIN_FILE" ]]; then
      if [[ ! -e "$LOGIN_FILE" && -x "$(dirname -- "$LOGIN_FILE")" ]]; then
        printf '  missing (installation would stop)\n'
      else
        printf '  unknown (needs root)\n'
      fi
      return 0
    fi
  else
    log "Configuring PAM for $de..."
  fi
  # Never create the login PAM file: a file holding only the optional keyring lines is an unsafe login stack.
  if [[ ! -f "$LOGIN_FILE" ]]; then
    log "ERROR: $LOGIN_FILE is missing; lightXDM will not create it."
    if [[ -e "${LOGIN_FILE}.lightxdm.bak" ]]; then
      log "Restore it from the backup first: sudo cp ${LOGIN_FILE}.lightxdm.bak $LOGIN_FILE"
    fi
    return 1
  fi
  local module auth_line session_line backend
  case "$de" in
    plasma) keyring=kwallet ;;
    gnome | xfce | lxqt | lxde | mate | cinnamon | budgie | i3) keyring=gnome ;;
  esac
  case "$keyring" in
    kwallet)
      module="pam_kwallet5.so"
      auth_line="$PAM_KWALLET_AUTH"
      session_line="$PAM_KWALLET_SESSION"
      backend=kwallet
      ;;
    *)
      module="pam_gnome_keyring.so"
      auth_line="$PAM_GNOME_KEYRING_AUTH"
      session_line="$PAM_GNOME_KEYRING_SESSION"
      backend=gnome
      ;;
  esac

  if [[ $preview -eq 1 ]]; then
    local additions removals="" removal preview_backup="${LOGIN_FILE}.lightxdm.bak"
    if [[ ! -e "$preview_backup" && ! -L "$preview_backup" ]]; then
      preview_backup="$(legacy_pam_backup_candidate 1)"
    fi
    if [[ -f "$preview_backup" && ! -L "$preview_backup" && ! -r "$preview_backup" ]]; then
      printf '  removals: unknown (needs root)\n'
    else
      removals="$(pam_lines_to_remove "$auth_line" "$session_line" 1)"
      while IFS= read -r removal; do
        [[ -n "$removal" ]] && printf '  remove: %s\n' "$removal"
      done <<<"$removals"
    fi
    additions="$(pam_lines_to_add "$module" "$auth_line" "$session_line" "$removals" 1)"
    printf '%s\n' "${additions:-  no lines to add (already configured)}"
    printf '  record: %s (%s)\n' "$PAM_KEYRING_STATE" "$backend"
    if [[ -n "$additions" && "${UPDATE_RESTORE_PAM:-0}" == 1 ]]; then
      printf '  record: %s (the version the .pacnew merge brought)\n' "$PAM_LOGIN_BASE_STATE"
    fi
    return 0
  fi
  if [[ "${UPDATE_RUN:-0}" == 1 && "${UPDATE_RESTORE_PAM:-0}" != 1 && ! -r "$LOGIN_FILE" ]]; then
    local deferred_missing deferred_record="" deferred_login
    deferred_record="$(read_pam_state_file "$PAM_KEYRING_STATE" 0 2>/dev/null)" || deferred_record=""
    deferred_missing="$(pam_lines_to_add "$module" "$auth_line" "$session_line" "" 0)" || return 1
    if [[ -n "$deferred_missing" ]]; then
      deferred_login="$(read_pam_file "$LOGIN_FILE" 0)" || return 1
      if [[ "$deferred_record" == gnome || "$deferred_record" == kwallet ]] ||
        grep -Eq "^[[:space:]]*-?(auth|session)[[:space:]][^#]*${module//./\\.}" <<<"$deferred_login"; then
        local deferred_hint
        deferred_hint="$(pam_restore_hint "$de" "$backend")"
        log "Some or all of lightXDM's $backend keyring lines are not in $LOGIN_FILE (removed or commented out), which has your own edits, so --update leaves it alone. Add them back with $(script_cmd install.sh) $deferred_hint, or turn keyring unlock off with sudo $(script_cmd uninstall.sh) --keyring-only."
      fi
      return 0
    fi
  fi
  adopt_legacy_pam_backup || return 1

  local package
  if [[ "$module" == "pam_kwallet5.so" ]]; then
    package="kwallet-pam"
  else
    package="gnome-keyring"
  fi
  if [[ ! -e "${SESSION_ROOT:-}/usr/lib/security/$module" ]]; then
    log "WARNING: $module is not installed (/usr/lib/security/$module); install $package or the keyring will not unlock at login."
  fi

  local backup_file="${LOGIN_FILE}.lightxdm.bak"
  if [[ -f "$backup_file" && ! -L "$backup_file" ]]; then
    local pam_sed=() stale_lines=() stale_line
    while IFS= read -r stale_line; do
      if [[ -n "$stale_line" ]]; then
        stale_lines+=("$stale_line")
        pam_sed+=(-e "/^${stale_line//./\\.}\$/d")
      fi
    done < <(pam_lines_to_remove "$auth_line" "$session_line" 0)
    if [[ ${#pam_sed[@]} -gt 0 ]]; then
      sudo sed -i --follow-symlinks "${pam_sed[@]}" "$LOGIN_FILE"
      for stale_line in "${stale_lines[@]}"; do
        log "Removed '$stale_line' from $LOGIN_FILE."
      done
    fi
  fi

  local lines_to_add=()
  mapfile -t lines_to_add < <(pam_lines_to_add "$module" "$auth_line" "$session_line" "" 0)

  if [[ ${#lines_to_add[@]} -gt 0 ]]; then
    if [[ -L "$backup_file" ]]; then
      sudo rm -f -- "$backup_file" || return 1
    fi
    if [[ ! -e "$backup_file" ]]; then
      log "Backing up $LOGIN_FILE to $backup_file"
      sudo cp -p -- "$LOGIN_FILE" "$backup_file" || return 1
    fi
    if [[ -n "$(read_pam_file "$LOGIN_FILE" 0 | tail -c 1)" ]]; then
      printf '\n' | sudo tee -a "$LOGIN_FILE" > /dev/null
    fi
    printf '%s\n' "${lines_to_add[@]}" | sudo tee -a "$LOGIN_FILE" > /dev/null
    log "Configured $module in $LOGIN_FILE."
    record_login_base || return 1
  else
    log "PAM configuration for $module already exists. Skipping."
  fi
  # --update reads this record to tell keyring lines a .pacnew merge dropped from lines removed on purpose.
  local keyring_state_dir
  keyring_state_dir="$(dirname -- "$PAM_KEYRING_STATE")"
  if [[ -d "$keyring_state_dir" && ! -x "$keyring_state_dir" ]]; then
    sudo chmod 755 -- "$keyring_state_dir" || return 1
  fi
  if [[ ! -f "$PAM_KEYRING_STATE" || -L "$PAM_KEYRING_STATE" || ! -r "$PAM_KEYRING_STATE" ||
    "$(stat -c %a -- "$PAM_KEYRING_STATE" 2>/dev/null)" != 644 ||
    "$(cat -- "$PAM_KEYRING_STATE" 2>/dev/null)" != "$backend" ]]; then
    printf '%s\n' "$backend" | sudo install -TDm644 /dev/stdin "$PAM_KEYRING_STATE" || return 1
  fi

  # Autologin passes no password, so keyring unlock cannot work alongside it.
  local drop_in
  for drop_in in "$AUTOLOGIN_DROPIN_DIR"/*.conf; do
    if dropin_enables_autologin "$drop_in"; then
      log "WARNING: TTY1 autologin is enabled ($drop_in); it cannot unlock the keyring. Disable it with 'sudo $(script_cmd enable-autologin.sh) --disable', or keep autologin and remove the keyring lines with 'sudo $(script_cmd uninstall.sh) --keyring-only'."
      break
    fi
  done
}

# True when systemd drop-in $1 leaves an autologin ExecStart= active at end of file.
dropin_enables_autologin() {
  local file="$1" line enabled=0 LC_ALL=C
  local autologin_re='^[[:space:]]*ExecStart[[:space:]]*=.*([[:space:]]--autologin([[:space:]]+|=)|[[:space:]]-a[[:space:]]+)([^-[:space:]][^[:space:]]*)'
  [[ -f "$file" && -r "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $autologin_re ]]; then
      enabled=1
    elif [[ "$line" =~ ^[[:space:]]*ExecStart[[:space:]]*= ]]; then
      enabled=0
    fi
  done < "$file"
  [[ $enabled -eq 1 ]]
}

# Print the block shared by the GNOME configuration and its preview.
gnome_session_type_block() {
  printf '%s\n' \
    '# lightXDM: GNOME on TTY1 needs a wayland session type (uninstall.sh removes this)' \
    'session    [success=2 default=ignore] pam_succeed_if.so quiet tty notin tty1:/dev/tty1' \
    "session    [success=1 default=ignore] pam_succeed_if.so quiet user != $1" \
    "session    optional   pam_env.so readenv=0 user_readenv=0 conffile=$GNOME_SESSION_TYPE_DEST"
}

# Register GNOME's TTY1 login as Wayland before the session stack runs pam_systemd.
configure_gnome_session_type() (
  local de="$1" user="$2" preview="${3:-0}" no_keyring="${4:-0}"
  if [[ -z "$user" || "$user" == -* || "$user" == *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]* ]]; then
    log "ERROR: Invalid user name: $user (use letters, digits, ., _ and -; do not start with -)"
    return 1
  fi

  local block=()
  mapfile -t block < <(gnome_session_type_block "$user")
  local marker="${block[0]}"
  local user_re='[abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._][abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*'
  # A numeric jump in PAM means "ok" plus a jump, so a failed condition would fail the whole
  # session stack. Each gate therefore jumps when it does NOT match and ignores its own result
  # otherwise; login passes the tty as "tty1" or "/dev/tty1".
  local tty_gate="${block[1]}"
  local user_gate_re="^session    \\[success=1 default=ignore\\] pam_succeed_if\\.so quiet user != ${user_re}$"
  local env_line="${block[3]}"
  local tmp="" login_copy="" login_src="$LOGIN_FILE" login_readable=0 has_block=0
  trap 'rm -f -- ${tmp:+"$tmp"} ${login_copy:+"$login_copy"}' EXIT
  if [[ -f "$LOGIN_FILE" ]]; then
    if [[ -r "$LOGIN_FILE" ]]; then
      login_readable=1
    elif [[ $preview -eq 0 ]]; then
      login_copy="$(mktemp)" || return 1
      # shellcheck disable=SC2024  # the temporary output file belongs to the calling user
      sudo cat -- "$LOGIN_FILE" > "$login_copy" || return 1
      login_src="$login_copy"
      login_readable=1
    fi
  fi
  if [[ $login_readable -eq 1 ]] && grep -Fxq -- "$marker" "$login_src"; then
    has_block=1
  fi
  # An update must not undo a hand edit: it puts a missing block back only into a login file a
  # .pacnew merge replaced (start_update_run decided that before configure_pam ran).
  block_removed_by_user() {
    [[ $login_readable -eq 1 && "$de" == gnome && $has_block -eq 0 && "${UPDATE_RUN:-0}" == 1 && "${UPDATE_RESTORE_PAM:-0}" != 1 ]]
  }
  # An update leaves a block the user edited (a line removed or commented out) as it is; an explicit
  # install refuses to touch it (validate_gnome_block).
  block_edited_on_update() {
    [[ "${UPDATE_RUN:-0}" == 1 && $has_block -eq 1 ]] && ! validate_gnome_block >/dev/null 2>&1
  }
  validate_gnome_block() {
    if [[ $has_block -eq 1 ]]; then
      local check_line check_tty check_user check_env
      while IFS= read -r check_line || [[ -n "$check_line" ]]; do
        [[ "$check_line" == "$marker" ]] || continue
        if ! {
          IFS= read -r check_tty && [[ "$check_tty" == "$tty_gate" ]] &&
            IFS= read -r check_user && [[ "$check_user" =~ $user_gate_re ]] &&
            { IFS= read -r check_env || [[ -n "$check_env" ]]; } && [[ "$check_env" == "$env_line" ]]
        }; then
          log "ERROR: Edited lightXDM GNOME block in $LOGIN_FILE; remove lightXDM's GNOME lines by hand or restore ${LOGIN_FILE}.lightxdm.bak."
          return 1
        fi
      done < "$login_src"
    fi
  }
  if [[ $preview -eq 1 ]]; then
    if block_edited_on_update; then
      printf 'GNOME session type: %s\n  left alone: lightXDM'"'"'s block has your own edits (--update)\n' "$LOGIN_FILE"
      return 0
    fi
    validate_gnome_block || return 1
    if [[ "$de" == gnome && $no_keyring -eq 1 && $login_readable -eq 1 ]] &&
      ! grep -Eq '^[[:space:]]*-?session[[:space:]]' "$login_src"; then
      log "ERROR: No session line in $LOGIN_FILE; lightXDM will not change it."
      return 1
    fi
    printf 'GNOME session type: %s\n' "$LOGIN_FILE"
    if [[ $login_readable -eq 0 ]]; then
      printf '  existing block: unknown (needs root)\n'
    fi
    if block_removed_by_user; then
      printf '  left alone: the block is not in %s, which has your own edits (--update); add only the block back with: %s --pam-only --de gnome --no-keyring\n' "$LOGIN_FILE" "$(script_cmd install.sh)"
    elif [[ "$de" == gnome && ( "${UPDATE_RUN:-0}" != 1 || $login_readable -eq 1 ) ]]; then
      printf '%s\n' "${block[@]}"
      printf 'Session-type file: %s (from %s)\n' "$GNOME_SESSION_TYPE_DEST" "$SCRIPT_DIR/pam/gnome-session-type.conf"
      if [[ $has_block -eq 0 && "${UPDATE_RESTORE_PAM:-0}" == 1 ]]; then
        printf '  record: %s (the version the .pacnew merge brought)\n' "$PAM_LOGIN_BASE_STATE"
      fi
    elif [[ "$de" != gnome ]]; then
      if [[ $has_block -eq 1 ]]; then
        printf '  remove the lightXDM GNOME block\n'
      fi
      if [[ -e "$GNOME_SESSION_TYPE_DEST" || -L "$GNOME_SESSION_TYPE_DEST" ]]; then
        printf '  remove %s\n' "$GNOME_SESSION_TYPE_DEST"
      fi
      if [[ $has_block -eq 0 && $login_readable -eq 1 && ! -e "$GNOME_SESSION_TYPE_DEST" && ! -L "$GNOME_SESSION_TYPE_DEST" ]]; then
        printf '  no GNOME configuration to remove\n'
      fi
    fi
    return 0
  fi
  if [[ "$de" != gnome && $has_block -eq 0 ]]; then
    if [[ -e "$GNOME_SESSION_TYPE_DEST" || -L "$GNOME_SESSION_TYPE_DEST" ]]; then
      sudo rm -f -- "$GNOME_SESSION_TYPE_DEST" || return 1
    fi
    return 0
  fi
  if [[ ! -f "$LOGIN_FILE" ]]; then
    log "ERROR: $LOGIN_FILE is missing; lightXDM will not create it."
    return 1
  fi
  if block_edited_on_update; then
    log "lightXDM's GNOME session-type block in $LOGIN_FILE has your own edits, so --update leaves it alone."
    return 0
  fi
  validate_gnome_block || return 1
  if block_removed_by_user; then
    log "lightXDM's GNOME session-type block is not in $LOGIN_FILE, which has your own edits, so --update leaves it alone; GNOME on TTY1 needs it to start on Wayland. Add only the block back with $(script_cmd install.sh) --pam-only --de gnome --no-keyring."
    return 0
  fi
  adopt_legacy_pam_backup || return 1

  local line newline inserted=0 block_line=0
  tmp="$(mktemp)" || return 1
  # Preserve each original line, including whether the last line has a newline.
  while :; do
    if IFS= read -r line; then
      newline=$'\n'
    elif [[ -n "$line" ]]; then
      newline=""
    else
      break
    fi
    if [[ $has_block -eq 1 ]]; then
      if [[ "$line" == "$marker" ]]; then
        block_line=1
        continue
      elif [[ $block_line -eq 1 && "$line" == "$tty_gate" ]]; then
        block_line=2
        continue
      elif [[ $block_line -eq 2 && "$line" =~ $user_gate_re ]]; then
        block_line=3
        continue
      elif [[ $block_line -eq 3 && "$line" == "$env_line" ]]; then
        block_line=0
        continue
      fi
      block_line=0
    fi
    if [[ "$de" == gnome && $inserted -eq 0 && "$line" =~ ^[[:space:]]*-?session[[:space:]] ]]; then
      printf '%s\n' "${block[@]}"
      inserted=1
    fi
    printf '%s%s' "$line" "$newline"
  done < "$login_src" > "$tmp"

  if [[ "$de" == gnome && $inserted -eq 0 ]]; then
    log "ERROR: No session line in $LOGIN_FILE; lightXDM will not change it."
    return 1
  fi
  local changed=0 backup="${LOGIN_FILE}.lightxdm.bak"
  if [[ "$(sha256sum < "$tmp")" != "$(sha256sum < "$login_src")" ]]; then
    changed=1
    if [[ -L "$backup" ]]; then
      sudo rm -f -- "$backup" || return 1
    fi
    if [[ ! -e "$backup" ]]; then
      log "Backing up $LOGIN_FILE to $backup"
      sudo cp -p -- "$LOGIN_FILE" "$backup" || return 1
    fi
  fi
  if [[ "$de" == gnome ]]; then
    local src="$SCRIPT_DIR/pam/gnome-session-type.conf" gnome_state_dir
    gnome_state_dir="$(dirname -- "$GNOME_SESSION_TYPE_DEST")"
    if [[ -d "$gnome_state_dir" && ! -x "$gnome_state_dir" ]]; then
      sudo chmod 755 -- "$gnome_state_dir" || return 1
    fi
    if [[ ! -f "$GNOME_SESSION_TYPE_DEST" || -L "$GNOME_SESSION_TYPE_DEST" || ! -r "$GNOME_SESSION_TYPE_DEST" ]] ||
      [[ "$(sha256sum < "$src")" != "$(sha256sum < "$GNOME_SESSION_TYPE_DEST")" || "$(stat -c %a "$GNOME_SESSION_TYPE_DEST")" != 644 ]]; then
      sudo install -TDm644 "$src" "$GNOME_SESSION_TYPE_DEST" || return 1
    fi
  fi
  if [[ $changed -eq 1 ]]; then
    # shellcheck disable=SC2024  # the temporary input file belongs to the calling user
    sudo tee "$LOGIN_FILE" < "$tmp" > /dev/null || return 1
    log "Configured GNOME session type in $LOGIN_FILE for $de."
    if [[ "$de" == gnome ]]; then
      record_login_base || return 1
    fi
  fi
  if [[ "$de" != gnome && ( -e "$GNOME_SESSION_TYPE_DEST" || -L "$GNOME_SESSION_TYPE_DEST" ) ]]; then
    sudo rm -f -- "$GNOME_SESSION_TYPE_DEST" || return 1
  fi
)

# Record a display manager before disabling it
record_and_disable_unit() {
  local unit="$1"
  if [[ "${UPDATE_RUN:-0}" == 1 ]]; then
    # --update never undoes the user's choice: a display manager enabled again stays enabled.
    if [[ "${2:-0}" == 1 ]]; then
      printf 'Display manager: %s (stays enabled: --update)\n' "$unit"
    else
      log "$unit is enabled, so --update leaves it alone; while it is enabled, its login screen takes the display at boot instead of lightXDM's TTY1 login. To use lightXDM's login again, run: sudo systemctl disable $unit"
    fi
    return 0
  fi
  if [[ "${2:-0}" == 1 ]]; then
    printf 'Display manager: %s\n' "$unit"
    return 0
  fi
  local existing_raw="" line has_unit=0 kept=()
  if ! sudo test -L "$DM_STATE_FILE" && sudo test -f "$DM_STATE_FILE"; then
    existing_raw="$(sudo cat -- "$DM_STATE_FILE")" || return
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      kept+=("$line")
      [[ "$line" == "$unit" ]] && has_unit=1
    done <<<"$existing_raw"
  fi
  if [[ $has_unit -eq 0 ]]; then
    kept+=("$unit")
  fi
  if [[ $has_unit -eq 0 ]] || sudo test -L "$DM_STATE_FILE" ||
    [[ ! -r "$DM_STATE_FILE" || "$(stat -c %a -- "$DM_STATE_FILE" 2>/dev/null)" != 644 ]]; then
    printf '%s\n' "${kept[@]}" | sudo install -TDm644 /dev/stdin "$DM_STATE_FILE" || return
  fi
  sudo systemctl disable "$unit"
}

# Disable any installed display managers
enable_autologin() {
  log "Enabling TTY1 autologin for $1..."
  sudo bash "$SCRIPT_DIR/enable-autologin.sh" "$1"
}

# Refuse a handover that would leave the next boot without a TTY1 login.
check_tty1_getty() {
  local state
  state="$(systemctl is-enabled getty@tty1.service 2>/dev/null || true)"
  if [[ "$state" == masked ]]; then
    log "getty@tty1.service is masked; the next boot would have no TTY1 login."
    log "Run sudo systemctl unmask getty@tty1.service and re-run the installer."
    return 1
  fi
  return 0
}

disable_display_managers() {
  local preview="${1:-0}"
  if [[ $preview -eq 0 && "${UPDATE_RUN:-0}" != 1 ]]; then
    log "Disabling any installed display managers..."
    local dm_dir
    dm_dir="$(dirname -- "$DM_STATE_FILE")"
    if [[ ! -d "$dm_dir" ]]; then
      sudo install -d -m755 -- "$dm_dir" || return
    elif [[ ! -x "$dm_dir" ]]; then
      sudo chmod 755 -- "$dm_dir" || return
    fi
  fi
  local dm dm_unit recorded_units unit_files
  local disabled_dms=()
  unit_files="$(systemctl list-unit-files || true)"
  for dm in "${DM_LIST[@]}"; do
    if [[ -n "$unit_files" ]] && grep -E -- "^[[:space:]]*${dm}\.service([[:space:]]|$)" <<<"$unit_files" >/dev/null; then
      if [[ "$(systemctl is-enabled "${dm}.service" 2>/dev/null || true)" == "enabled" ]]; then
        record_and_disable_unit "${dm}.service" "$preview" || return
        disabled_dms+=("$dm")
      fi
    fi
  done
  if [[ -L "$DISPLAY_MANAGER_LINK" ]] && dm_unit="$(readlink -f "$DISPLAY_MANAGER_LINK")"; then
    dm_unit="${dm_unit##*/}"
    dm="${dm_unit%.service}"
    if [[ " ${disabled_dms[*]} " != *" $dm "* ]] && [[ "$(systemctl is-enabled "$dm_unit" 2>/dev/null || true)" == "enabled" ]]; then
      record_and_disable_unit "$dm_unit" "$preview" || return
      disabled_dms+=("$dm")
    fi
  fi
  if [[ " ${disabled_dms[*]} " != *" ly@tty1 "* ]] && [[ "$(systemctl is-enabled ly@tty1.service 2>/dev/null || true)" == "enabled" ]]; then
    record_and_disable_unit "ly@tty1.service" "$preview" || return
    disabled_dms+=("ly@tty1")
  fi
  if [[ $preview -eq 1 ]]; then
    if [[ ${#disabled_dms[@]} -eq 0 ]]; then
      printf 'Display managers: none enabled\n'
    fi
    if [[ "${UPDATE_RUN:-0}" != 1 ]]; then
      printf 'Display-manager state file: %s\n' "$DM_STATE_FILE"
      if [[ -e "$DM_STATE_FILE" && ! -r "$DM_STATE_FILE" ]]; then
        printf '  existing records: unknown (needs root)\n'
      fi
    fi
    return 0
  fi
  # --update disabled nothing (record_and_disable_unit printed each enabled unit instead).
  if [[ "${UPDATE_RUN:-0}" == 1 ]]; then
    return 0
  fi
  if [[ ${#disabled_dms[@]} -gt 0 ]]; then
    display_manager_disabled=1
    log "Disabled display manager(s): ${disabled_dms[*]}"
    log "Your current session will not be interrupted."
  else
    log "No enabled display managers found."
  fi
  recorded_units=""
  if ! sudo test -L "$DM_STATE_FILE" && sudo test -f "$DM_STATE_FILE"; then
    recorded_units="$(sudo cat -- "$DM_STATE_FILE" 2>/dev/null)" || recorded_units=""
  fi
  while IFS= read -r dm_unit || [[ -n "$dm_unit" ]]; do
    if [[ -n "$dm_unit" ]] && systemctl is-active --quiet "$dm_unit"; then
      display_manager_disabled=1
      break
    fi
  done <<<"$recorded_units"
}

# Preview a --pam-only run: only lightXDM's lines in /etc/pam.d/login and GNOME's session-type file.
preview_pam_only() {
  local de="$1" no_keyring="$2" keyring="${3:-}" real_user
  real_user="${USER:-$(id -un)}"
  printf 'Desktop: %s (--pam-only: no packages, dotfiles, display managers or saved choices)\n' "$de"
  if [[ $no_keyring -eq 1 ]]; then
    printf 'PAM keyring: skipped (--no-keyring)\n'
  else
    configure_pam "$de" 1 "$keyring" || return 1
  fi
  configure_gnome_session_type "$de" "$real_user" 1 "$no_keyring"
}

# Resolve the install using the configuration helpers' read-only preview paths.
preview_install() {
  local de="$1" no_packages="$2" no_keyring="$3" autologin="$4" keyring="${5:-}" template real_user
  template="$(xinitrc_template "$de")" || return 1
  check_template_syntax "$template" || return 1
  check_tty1_getty || return 1
  check_template_not_self "$de" "$template" || return 1
  real_user="${USER:-$(id -un)}"
  printf 'Desktop: %s\nTemplate: %s\n' "$de" "$template"
  if [[ ! -r "$template" ]]; then
    printf '  template contents: unknown (needs root)\n'
  fi
  copy_dotfiles "$de" 1 || return 1
  if [[ $no_packages -eq 1 ]]; then
    printf 'Packages: skipped (--no-packages)\n'
  elif [[ "${UPDATE_RUN:-0}" == 1 ]]; then
    local pkg_list what pkg
    local -a pkgs=()
    pkg_list="$(list_packages "$de" "$no_keyring")" || return 1
    mapfile -t pkgs <<<"$pkg_list"
    printf 'Packages (--update installs only the ones this lightXDM version adds):\n'
    while read -r what pkg; do
      case "$what" in
        install) printf '  install: %s\n' "$pkg" ;;
        missing) printf '  left out, not installed: %s\n' "$pkg" ;;
      esac
    done < <(update_package_plan "${pkgs[@]}")
  else
    printf 'Packages:\n'
    list_packages "$de" "$no_keyring" || return 1
  fi
  if [[ $no_keyring -eq 1 ]]; then
    printf 'PAM keyring: skipped (--no-keyring)\n'
  else
    configure_pam "$de" 1 "$keyring" || return 1
  fi
  configure_gnome_session_type "$de" "$real_user" 1 "$no_keyring" || return 1
  disable_display_managers 1 || return 1
  if [[ $autologin -eq 1 ]]; then
    printf 'TTY1 autologin: enable for %s (--autologin)\n' "$real_user"
  else
    printf 'TTY1 autologin: unchanged (--autologin not requested)\n'
  fi
  printf 'Install choices: %s\n' "$(install_choices_file)"
  printf 'Dotfile record: %s\n' "$(dotfile_record_file)"
}
# Where a finished install keeps the choices that --update reuses
install_choices_file() {
  printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/lightxdm/install-choices"
}
install_choices_readable() {
  local file="$1" dir="${1%/*}"
  [[ ! -L "$dir" && -f "$file" && ! -L "$file" && -r "$file" ]]
}
# Save the desktop id ($1), the --no-packages choice ($2) and the packages the run asked for (the
# rest; --update installs only ones missing from this list) of a finished install for --update
save_install_choices() {
  local file dir content tmp=""
  file="$(install_choices_file)"
  dir="${file%/*}"
  printf -v content 'de=%s\nno_packages=%s\n' "$1" "$2"
  if [[ $# -gt 2 ]]; then
    content+="packages=${*:3}"$'\n'
  fi
  if ! { [[ ! -L "$dir" ]] && mkdir -p -- "$dir" && [[ ! -L "$dir" ]] &&
    tmp="$(mktemp "$dir/.install-choices.XXXXXX")" &&
    printf '%s' "$content" >"$tmp" && chmod 644 -- "$tmp" && mv -Tf -- "$tmp" "$file"; } 2>/dev/null; then
    [[ -z "$tmp" ]] || rm -f -- "$tmp" 2>/dev/null || true
    log "WARNING: Could not save the install choices for --update in $file."
  fi
}
# True when a .pacnew merge replaced $LOGIN_FILE: pacman sees the version its package ships (an
# unmodified backup file), and that version is neither lightXDM's backup of the original nor the
# packaged version lightXDM already put its lines back into after an earlier merge. Removing only
# lightXDM's lines by hand brings back one of those two, so the user's removal stays. Without a
# backup there is no proof either way, so the answer is no.
login_file_replaced_by_package() {
  local preview="${1:-0}" backup="${LOGIN_FILE}.lightxdm.bak" sum backup_sum base="" owner
  sum="$(set -o pipefail; read_pam_file "$LOGIN_FILE" "$preview" 2>/dev/null | sha256sum)" || return 1
  backup_sum="$(set -o pipefail; read_pam_state_file "$backup" "$preview" 2>/dev/null | sha256sum)" || return 1
  base="$(read_pam_state_file "$PAM_LOGIN_BASE_STATE" "$preview" 2>/dev/null)" || base=""
  [[ "$sum" != "$backup_sum" && "${sum%% *}" != "$base" ]] || return 1
  owner="$(pacman -Qqo -- "$LOGIN_FILE" 2>/dev/null)" && [[ -n "$owner" ]] || return 1
  if [[ -r "$LOGIN_FILE" ]]; then
    LC_ALL=C pacman -Qii -- "$owner" 2>/dev/null | grep -Fq -- "$LOGIN_FILE [unmodified]"
  elif [[ $preview -eq 0 ]]; then
    sudo env LC_ALL=C pacman -Qii -- "$owner" 2>/dev/null | grep -Fq -- "$LOGIN_FILE [unmodified]"
  else
    return 1
  fi
}

# --update decides once, before any step changes $LOGIN_FILE, whether a .pacnew merge replaced it;
# only then do lightXDM's missing PAM lines go back in (saved_install_args, configure_gnome_session_type).
start_update_run() {
  local preview="${1:-0}" sum
  UPDATE_RUN=1
  UPDATE_RESTORE_PAM=0
  UPDATE_LOGIN_SUM=""
  if login_file_replaced_by_package "$preview"; then
    sum="$(set -o pipefail; read_pam_file "$LOGIN_FILE" "$preview" 2>/dev/null | sha256sum)" || return 1
    UPDATE_RESTORE_PAM=1
    UPDATE_LOGIN_SUM="${sum%% *}"
  fi
}

# After lightXDM's lines went back into a login file a .pacnew merge replaced, remember that packaged
# version, so a later removal of the lines by hand is not taken for another merge.
record_login_base() {
  [[ "${UPDATE_RESTORE_PAM:-0}" == 1 && -n "${UPDATE_LOGIN_SUM:-}" ]] || return 0
  local base_state_dir
  base_state_dir="$(dirname -- "$PAM_LOGIN_BASE_STATE")"
  if [[ -d "$base_state_dir" && ! -x "$base_state_dir" ]]; then
    sudo chmod 755 -- "$base_state_dir" || return 1
  fi
  if [[ ! -f "$PAM_LOGIN_BASE_STATE" || -L "$PAM_LOGIN_BASE_STATE" || ! -r "$PAM_LOGIN_BASE_STATE" ||
    "$(stat -c %a -- "$PAM_LOGIN_BASE_STATE" 2>/dev/null)" != 644 ||
    "$(cat -- "$PAM_LOGIN_BASE_STATE" 2>/dev/null)" != "$UPDATE_LOGIN_SUM" ]]; then
    printf '%s\n' "$UPDATE_LOGIN_SUM" | sudo install -TDm644 /dev/stdin "$PAM_LOGIN_BASE_STATE" || return 1
  fi
}
# Print the desktop id saved in install-choices, or fail with the --update guidance.
saved_install_de() {
  local file line de=""
  file="$(install_choices_file)"
  if install_choices_readable "$file"; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        de=*) de="${line#de=}" ;;
      esac
    done <"$file"
  fi
  if [[ -z "$de" ]]; then
    log "No saved install choices in $file; run $(script_cmd install.sh) with your options first."
    return 1
  fi
  printf '%s\n' "$de"
}

# Check wheel membership and request sudo credentials upfront.
authenticate_sudo() {
  local non_interactive="$1" real_user="${2:-${USER:-$(id -un)}}"
  # Defined after check_root, whose `command -v sudo` must still find the real binary.
  if [[ $non_interactive -eq 1 ]]; then
    sudo() { command sudo -n "$@"; }
  fi
  if ! grep -qx wheel < <(id -nG "$real_user" | tr ' ' '\n'); then
    log "ERROR: User '$real_user' is not in the 'wheel' group. Sudo and polkit rules will not work."
    log "Add the user to the wheel group as root, then log out and back in: su -c 'usermod -aG wheel $real_user'"
    exit 1
  fi
  log "Requesting sudo credentials upfront (sudo -v)..."
  if ! sudo -v; then
    log "ERROR: Failed to authenticate with sudo. Exiting."
    log "On Arch the wheel rule in /etc/sudoers ships commented out: run visudo as root (for example su -c 'EDITOR=nano visudo') and uncomment %wheel ALL=(ALL:ALL) ALL"
    exit 1
  fi
}

# Print the options --update re-runs, one per line: the saved desktop and package choice, and the
# keyring backend recorded in $PAM_KEYRING_STATE, else the one the active keyring lines in
# $LOGIN_FILE use. Autologin is never passed.
saved_install_args() {
  local preview="${1:-0}" file line de="" no_packages=0 recorded_packages="" has_gnome=0 has_kwallet=0
  local login_content="" login_readable=0 login_absent=0 login_dir
  file="$(install_choices_file)"
  if install_choices_readable "$file"; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        de=*) de="${line#de=}" ;;
        no_packages=1) no_packages=1 ;;
        no_packages=0) no_packages=0 ;;
        packages=*) recorded_packages="${line#packages=}" ;;
      esac
    done <"$file"
  fi
  if [[ -z "$de" ]]; then
    log "No saved install choices in $file; run $(script_cmd install.sh) with your options first."
    return 1
  fi
  printf '%s\n' --de "$de"
  if [[ $no_packages -eq 1 ]]; then
    printf '%s\n' --no-packages
  fi
  login_dir="$(dirname -- "$LOGIN_FILE")"
  if login_content="$(read_pam_file "$LOGIN_FILE" "$preview" 2>/dev/null)"; then
    login_readable=1
    if grep -Eq '^[[:space:]]*-?(auth|session)[[:space:]][^#]*pam_gnome_keyring\.so' <<<"$login_content"; then
      has_gnome=1
    fi
    if grep -Eq '^[[:space:]]*-?(auth|session)[[:space:]][^#]*pam_kwallet5\.so' <<<"$login_content"; then
      has_kwallet=1
    fi
  elif [[ -d "$login_dir" && -x "$login_dir" && ! -e "$LOGIN_FILE" ]] ||
    [[ ! -e "$login_dir" && ! -L "$login_dir" && -x "$(dirname -- "$login_dir")" ]] ||
    { [[ $preview -eq 0 ]] && ! sudo test -e "$LOGIN_FILE"; }; then
    login_absent=1
  fi
  # The record tells keyring lines a .pacnew merge dropped from lines removed with uninstall.sh
  # --keyring-only; installs from before the record fall back to the lines themselves.
  local record="" backend="" module auth_line session_line
  record="$(read_pam_state_file "$PAM_KEYRING_STATE" "$preview" 2>/dev/null)" || record=""
  case "$record" in
    gnome | kwallet) backend="$record" ;;
    *)
      record=""
      case "$de" in
        plasma)
          [[ $has_kwallet -eq 1 ]] && backend=kwallet
          ;;
        gnome | xfce | lxqt | lxde | mate | cinnamon | budgie | i3)
          [[ $has_gnome -eq 1 ]] && backend=gnome
          ;;
        *)
          if [[ $has_gnome -eq 1 ]]; then
            backend=gnome
          elif [[ $has_kwallet -eq 1 ]]; then
            backend=kwallet
          fi
          ;;
      esac
      ;;
  esac
  if [[ -z "$backend" ]]; then
    if [[ $login_readable -eq 1 || $login_absent -eq 1 ]] ||
      { [[ -n "$recorded_packages" && " $recorded_packages " != *" gnome-keyring "* && " $recorded_packages " != *" kwallet-pam "* ]] &&
        ! pam_path_needs_sudo "$PAM_KEYRING_STATE" 1 && [[ ! -f "$PAM_KEYRING_STATE" || -L "$PAM_KEYRING_STATE" ]]; }; then
      printf '%s\n' --no-keyring
    fi
    return 0
  fi
  if [[ "$backend" == kwallet ]]; then
    module=pam_kwallet5.so auth_line="$PAM_KWALLET_AUTH" session_line="$PAM_KWALLET_SESSION"
  else
    module=pam_gnome_keyring.so auth_line="$PAM_GNOME_KEYRING_AUTH" session_line="$PAM_GNOME_KEYRING_SESSION"
  fi
  # A keyring line the user removed or commented out stays that way, even when the other one is still
  # there: only a login file a .pacnew merge replaced lost lightXDM's lines without the user.
  if [[ $login_readable -eq 1 && -n "$(pam_lines_to_add "$module" "$auth_line" "$session_line" "" "$preview")" ]]; then
    if [[ -z "$record" || "${UPDATE_RESTORE_PAM:-0}" != 1 ]]; then
      local hint
      hint="$(pam_restore_hint "$de" "$backend")"
      log "Some or all of lightXDM's $backend keyring lines are not in $LOGIN_FILE (removed or commented out), which has your own edits, so --update leaves it alone. Add them back with $(script_cmd install.sh) $hint, or turn keyring unlock off with sudo $(script_cmd uninstall.sh) --keyring-only."
      printf '%s\n' --no-keyring
      return 0
    fi
    log "lightXDM's $backend keyring lines are missing from $LOGIN_FILE, which a .pacnew merge replaced with the version its package ships; adding them back."
  fi
  case "$de" in
    plasma | gnome | xfce | lxqt | lxde | mate | cinnamon | budgie | i3) ;;
    *) printf '%s\n' --keyring "$backend" ;;
  esac
}

# Escape $1 for a double-quoted JSON string value (without surrounding quotes).
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

# Inspect managed home dotfile $1 compared against resolved template $2 into DOTFILE_STATUS_* globals.
inspect_dotfile_status() {
  local target="$1" source="${2:-}" sum="" recorded_sum=""
  DOTFILE_STATUS_STATE=""
  DOTFILE_STATUS_SYMLINK_TARGET=""
  DOTFILE_STATUS_PENDING_UPDATE=""
  DOTFILE_STATUS_BACKUP=""
  if [[ -e "${target}.lightxdm-new" || -L "${target}.lightxdm-new" ]]; then
    DOTFILE_STATUS_PENDING_UPDATE="${target}.lightxdm-new"
  fi
  if [[ -L "$target" ]]; then
    DOTFILE_STATUS_STATE="symlink"
    DOTFILE_STATUS_SYMLINK_TARGET="$(readlink "$target" 2>/dev/null || echo '?')"
    return 0
  fi
  if [[ ! -e "$target" ]]; then
    DOTFILE_STATUS_STATE="missing"
    if [[ -e "${target}.lightxdm.bak" || -L "${target}.lightxdm.bak" ]]; then
      DOTFILE_STATUS_BACKUP="${target}.lightxdm.bak"
    fi
    return 0
  fi
  if [[ ! -f "$target" ]]; then
    DOTFILE_STATUS_STATE="not-regular"
    return 0
  fi
  if [[ ! -r "$target" ]]; then
    DOTFILE_STATUS_STATE="unreadable"
    return 0
  fi
  sum="$(sha256sum <"$target")"
  if [[ -n "$source" && -f "$source" && -r "$source" ]] && [[ "$sum" == "$(sha256sum <"$source")" ]]; then
    DOTFILE_STATUS_STATE="up-to-date"
    return 0
  fi
  recorded_sum="$(recorded_dotfile_sum "$target")"
  if [[ -n "$recorded_sum" && "${sum%% *}" == "$recorded_sum" ]]; then
    DOTFILE_STATUS_STATE="matches-recorded"
    return 0
  fi
  if is_past_lightxdm_template "$target" "${target#"$HOME"/}"; then
    DOTFILE_STATUS_STATE="matches-past-template"
    return 0
  fi
  DOTFILE_STATUS_STATE="modified"
}

# Print one status line for managed home dotfile $1 compared against resolved template $2 (when known).
dotfile_status_line() {
  local target="$1" source="${2:-}" suffix=""
  local DOTFILE_STATUS_STATE="" DOTFILE_STATUS_SYMLINK_TARGET=""
  local DOTFILE_STATUS_PENDING_UPDATE="" DOTFILE_STATUS_BACKUP=""
  inspect_dotfile_status "$target" "$source"
  [[ -z "$DOTFILE_STATUS_PENDING_UPDATE" ]] || suffix=" (pending update: $DOTFILE_STATUS_PENDING_UPDATE)"
  [[ -z "$DOTFILE_STATUS_BACKUP" ]] || suffix+=" (backup present: $DOTFILE_STATUS_BACKUP)"
  case "$DOTFILE_STATUS_STATE" in
    symlink) printf '  %s: symlink -> %s%s\n' "$target" "$DOTFILE_STATUS_SYMLINK_TARGET" "$suffix" ;;
    missing) printf '  %s: missing%s\n' "$target" "$suffix" ;;
    not-regular) printf '  %s: not a regular file%s\n' "$target" "$suffix" ;;
    unreadable) printf '  %s: unreadable%s\n' "$target" "$suffix" ;;
    up-to-date) printf '  %s: up-to-date%s\n' "$target" "$suffix" ;;
    matches-recorded) printf '  %s: matches recorded install%s\n' "$target" "$suffix" ;;
    matches-past-template) printf '  %s: matches past lightXDM template%s\n' "$target" "$suffix" ;;
    modified) printf '  %s: modified%s\n' "$target" "$suffix" ;;
  esac
}

# Inspect GNOME TTY1 pam_env status against $LOGIN_FILE ($1) and desktop user ($2) into GNOME_PAM_STATUS_*.
inspect_gnome_pam_status() {
  local login_content="$1" real_user="$2"
  local gnome_marker gnome_tty_gate gnome_env_line has_gnome_block=0
  local gnome_block=()
  mapfile -t gnome_block < <(gnome_session_type_block "$real_user")
  gnome_marker="${gnome_block[0]}"
  gnome_tty_gate="${gnome_block[1]}"
  gnome_env_line="${gnome_block[3]}"
  GNOME_PAM_STATUS_ID="not-configured"
  GNOME_PAM_STATUS_MSG="not configured"

  if grep -Fxq -- "$gnome_marker" <<<"$login_content"; then
    has_gnome_block=1
  fi
  if [[ $has_gnome_block -eq 1 ]]; then
    local user_re='[abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._][abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-]*'
    local user_gate_re="^session    \\[success=1 default=ignore\\] pam_succeed_if\\.so quiet user != ${user_re}$"
    local check_line check_tty check_user check_env block_valid=1
    while IFS= read -r check_line || [[ -n "$check_line" ]]; do
      [[ "$check_line" == "$gnome_marker" ]] || continue
      if ! {
        IFS= read -r check_tty && [[ "$check_tty" == "$gnome_tty_gate" ]] &&
          IFS= read -r check_user && [[ "$check_user" =~ $user_gate_re ]] &&
          { IFS= read -r check_env || [[ -n "$check_env" ]]; } && [[ "$check_env" == "$gnome_env_line" ]]
      }; then
        block_valid=0
        break
      fi
    done <<<"$login_content"
    if [[ $block_valid -eq 1 ]]; then
      if [[ -f "$GNOME_SESSION_TYPE_DEST" && ! -L "$GNOME_SESSION_TYPE_DEST" ]]; then
        GNOME_PAM_STATUS_ID="configured"
        GNOME_PAM_STATUS_MSG="configured ($GNOME_SESSION_TYPE_DEST)"
      elif pam_path_needs_sudo "$GNOME_SESSION_TYPE_DEST" 1; then
        GNOME_PAM_STATUS_ID="block-present-needs-root"
        GNOME_PAM_STATUS_MSG="block present ($GNOME_SESSION_TYPE_DEST: unknown, needs root)"
      else
        GNOME_PAM_STATUS_ID="block-present-missing-file"
        GNOME_PAM_STATUS_MSG="block present (missing $GNOME_SESSION_TYPE_DEST)"
      fi
    else
      GNOME_PAM_STATUS_ID="edited-block"
      GNOME_PAM_STATUS_MSG="edited block in $LOGIN_FILE"
    fi
  elif [[ -e "$GNOME_SESSION_TYPE_DEST" || -L "$GNOME_SESSION_TYPE_DEST" ]]; then
    GNOME_PAM_STATUS_ID="file-without-block"
    GNOME_PAM_STATUS_MSG="session-type file present without PAM block ($GNOME_SESSION_TYPE_DEST)"
  elif pam_path_needs_sudo "$GNOME_SESSION_TYPE_DEST" 1; then
    GNOME_PAM_STATUS_ID="unknown-needs-root"
    GNOME_PAM_STATUS_MSG="unknown (needs root)"
  fi
}

# Report the current lightXDM installation state without modifying files or invoking sudo.
show_install_status() {
  local LC_ALL=C json_mode=0
  [[ "${1:-}" == "--json" ]] && json_mode=1

  local choices_file line de="" no_packages="" choices_kind="not-recorded" choices_state="not recorded"
  choices_file="$(install_choices_file)"
  if install_choices_readable "$choices_file"; then
    choices_kind="readable"
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        de=*) de="${line#de=}" ;;
        no_packages=1) no_packages=1 ;;
        no_packages=0) no_packages=0 ;;
      esac
    done <"$choices_file"
    if [[ -n "$de" ]]; then
      choices_state="de=$de"
      if [[ "$no_packages" == 1 ]]; then
        choices_state+=", --no-packages"
      elif [[ "$no_packages" == 0 ]]; then
        choices_state+=", packages recorded"
      fi
    else
      choices_state="readable, no desktop recorded"
    fi
  elif [[ -L "${choices_file%/*}" || -L "$choices_file" ]]; then
    choices_kind="symlink-ignored"
    choices_state="symlink ignored ($choices_file)"
  elif [[ -e "$choices_file" ]]; then
    choices_kind="unreadable"
    choices_state="unreadable ($choices_file)"
  fi

  local template="" template_source="" template_text="" session_dotfile="" session_source="" gpg_dotfile="$HOME/.gpg-agent-gnome"
  if [[ -n "$de" ]]; then
    if template="$(xinitrc_template "$de" 2>/dev/null)"; then
      if [[ "$template" == "$HOME/.config/lightxdm/"* ]]; then
        template_source="user"
        template_text="$template (user template)"
      elif [[ -f "$template" ]]; then
        template_source="bundled"
        template_text="$template"
      else
        template_source="missing"
        template_text="missing ($template)"
      fi
      if [[ "${template##*/}" == .wayland-session-* ]]; then
        session_dotfile="$HOME/.wayland-session"
      else
        session_dotfile="$HOME/.xinitrc"
      fi
      [[ -f "$template" ]] && session_source="$template"
    else
      template=""
      template_source="error"
      template_text="error resolving template for $de (check ~/.config/lightxdm/)"
    fi
    [[ "$de" == plasma ]] && gpg_dotfile="$HOME/.gpg-agent-kwallet"
  fi

  local launcher_type="none" launcher_path="" launcher="none (~/.wayland-session not executable and startx not on PATH)"
  if [[ -f "$HOME/.wayland-session" && -x "$HOME/.wayland-session" ]]; then
    launcher_type="wayland"
    launcher_path="$HOME/.wayland-session"
    launcher="$HOME/.wayland-session (Wayland)"
  elif command -v startx >/dev/null 2>&1; then
    launcher_type="x11"
    launcher_path="$HOME/.xinitrc"
    launcher="startx ($HOME/.xinitrc)"
  fi

  local autostart_paused=0 session_journal=0
  if [[ -e "$HOME/.config/lightxdm/no-autostart" || -L "$HOME/.config/lightxdm/no-autostart" ]]; then
    autostart_paused=1
  fi
  if [[ -e "$HOME/.config/lightxdm/session-journal" || -L "$HOME/.config/lightxdm/session-journal" ]]; then
    session_journal=1
  fi

  local attempts_file="${XDG_STATE_HOME:-$HOME/.local/state}/lightxdm/startx-attempts"
  local recent_count=0
  if [[ -f "$attempts_file" && ! -L "$attempts_file" && -r "$attempts_file" ]]; then
    local now attempt_lines=() attempt_ts
    printf -v now '%(%s)T' -1
    mapfile -t attempt_lines 2>/dev/null <"$attempts_file" || :
    for attempt_ts in "${attempt_lines[@]}"; do
      if [[ -n "$attempt_ts" && ${#attempt_ts} -le 18 && "$attempt_ts" != *[!0123456789]* ]] &&
        ((now - 10#$attempt_ts >= 0 && now - 10#$attempt_ts <= 30)); then
        recent_count=$((recent_count + 1))
      fi
    done
  fi

  local dotfile_targets=("$HOME/.bash_profile")
  local dotfile_sources=("$SCRIPT_DIR/dotfiles/.bash_profile")
  if [[ -n "$session_dotfile" ]]; then
    dotfile_targets+=("$session_dotfile")
    dotfile_sources+=("$session_source")
  else
    if [[ -e "$HOME/.wayland-session" || -L "$HOME/.wayland-session" ]]; then
      dotfile_targets+=("$HOME/.wayland-session")
      dotfile_sources+=("")
    fi
    if [[ -e "$HOME/.xinitrc" || -L "$HOME/.xinitrc" || ! ( -e "$HOME/.wayland-session" || -L "$HOME/.wayland-session" ) ]]; then
      dotfile_targets+=("$HOME/.xinitrc")
      dotfile_sources+=("")
    fi
  fi
  if [[ -z "$de" && ( -e "$HOME/.gpg-agent-kwallet" || -L "$HOME/.gpg-agent-kwallet" ) && ! ( -e "$HOME/.gpg-agent-gnome" || -L "$HOME/.gpg-agent-gnome" ) ]]; then
    gpg_dotfile="$HOME/.gpg-agent-kwallet"
  fi
  dotfile_targets+=("$gpg_dotfile" "$HOME/.config/autostart/lightxdm-gpg-agent-tty.desktop")
  dotfile_sources+=("$SCRIPT_DIR/dotfiles/.gpg-agent-gnome" "$SCRIPT_DIR/dotfiles/lightxdm-gpg-agent-tty.desktop")

  local real_user="${USER:-$(id -un)}" pam_record="" pam_record_kind="none" pam_record_raw="" pam_record_state="none" login_content=""
  if pam_record="$(read_pam_state_file "$PAM_KEYRING_STATE" 1 2>/dev/null)"; then
    case "$pam_record" in
      gnome | kwallet)
        pam_record_kind="$pam_record"
        pam_record_state="$pam_record"
        ;;
      *)
        pam_record_kind="invalid"
        pam_record_raw="$pam_record"
        pam_record_state="invalid (${pam_record:-empty})"
        ;;
    esac
  elif [[ -L "$(dirname -- "$PAM_KEYRING_STATE")" || -L "$PAM_KEYRING_STATE" ]]; then
    pam_record_kind="symlink-ignored"
    pam_record_state="symlink ignored"
  elif pam_path_needs_sudo "$PAM_KEYRING_STATE" 1; then
    pam_record_kind="unknown-needs-root"
    pam_record_state="unknown (needs root)"
  fi

  local keyring_status_id="none" keyring_status="none"
  local gnome_status_id="not-configured" gnome_status="not configured"
  if login_content="$(read_pam_file "$LOGIN_FILE" 1 2>/dev/null)"; then
    local missing_gnome missing_kwallet has_gnome_line=0 has_kwallet_line=0
    missing_gnome="$(pam_lines_to_add "pam_gnome_keyring.so" "$PAM_GNOME_KEYRING_AUTH" "$PAM_GNOME_KEYRING_SESSION" "" 1 || true)"
    missing_kwallet="$(pam_lines_to_add "pam_kwallet5.so" "$PAM_KWALLET_AUTH" "$PAM_KWALLET_SESSION" "" 1 || true)"
    grep -Eq '^[[:space:]]*-?(auth|session)[[:space:]][^#]*pam_gnome_keyring\.so' <<<"$login_content" && has_gnome_line=1
    grep -Eq '^[[:space:]]*-?(auth|session)[[:space:]][^#]*pam_kwallet5\.so' <<<"$login_content" && has_kwallet_line=1
    if [[ -z "$missing_gnome" && -z "$missing_kwallet" ]]; then
      keyring_status_id="configured-both"
      keyring_status="configured (gnome and kwallet)"
    elif [[ -z "$missing_gnome" ]]; then
      keyring_status_id="configured-gnome"
      keyring_status="configured (gnome)"
    elif [[ -z "$missing_kwallet" ]]; then
      keyring_status_id="configured-kwallet"
      keyring_status="configured (kwallet)"
    elif [[ $has_gnome_line -eq 1 || $has_kwallet_line -eq 1 ]]; then
      keyring_status_id="partial"
      keyring_status="partial (missing auth or session line)"
    fi

    local GNOME_PAM_STATUS_ID="" GNOME_PAM_STATUS_MSG=""
    inspect_gnome_pam_status "$login_content" "$real_user"
    gnome_status_id="$GNOME_PAM_STATUS_ID"
    gnome_status="$GNOME_PAM_STATUS_MSG"
  elif [[ ! -e "$LOGIN_FILE" && -x "$(dirname -- "$LOGIN_FILE")" ]]; then
    keyring_status_id="missing-login-file"
    keyring_status="missing"
    gnome_status_id="missing-login-file"
    gnome_status="missing ($LOGIN_FILE)"
  else
    keyring_status_id="unknown-needs-root"
    keyring_status="unknown (needs root)"
    gnome_status_id="unknown-needs-root"
    gnome_status="unknown (needs root)"
  fi

  local pacnew_waiting=0 pacnew_replaced=0
  if [[ -e "${LOGIN_FILE}.pacnew" || -L "${LOGIN_FILE}.pacnew" ]]; then
    pacnew_waiting=1
    if login_file_replaced_by_package 1; then
      pacnew_replaced=1
    fi
  fi

  local getty_state
  getty_state="$(systemctl is-enabled getty@tty1.service 2>/dev/null || true)"
  [[ -n "$getty_state" ]] || getty_state="unknown"

  local dm_mode="none" dm_state_content="" dm_unit dm_state dm_units=() dm_unit_states=() dm_list=()
  if [[ -L "$(dirname -- "$DM_STATE_FILE")" || -L "$DM_STATE_FILE" ]]; then
    dm_mode="symlink-ignored"
  elif [[ -f "$DM_STATE_FILE" && -r "$DM_STATE_FILE" ]]; then
    dm_state_content="$(cat -- "$DM_STATE_FILE")"
    while IFS= read -r dm_unit || [[ -n "$dm_unit" ]]; do
      [[ -n "$dm_unit" ]] || continue
      dm_state="$(systemctl is-enabled "$dm_unit" 2>/dev/null || true)"
      dm_units+=("$dm_unit")
      dm_unit_states+=("${dm_state:-unknown}")
      if [[ "$dm_state" == enabled ]]; then
        dm_list+=("$dm_unit (re-enabled)")
      elif [[ -n "$dm_state" ]]; then
        dm_list+=("$dm_unit ($dm_state)")
      else
        dm_list+=("$dm_unit")
      fi
    done <<<"$dm_state_content"
    if [[ ${#dm_units[@]} -gt 0 ]]; then
      dm_mode="recorded"
    fi
  elif pam_path_needs_sudo "$DM_STATE_FILE" 1; then
    dm_mode="unknown-needs-root"
  fi

  local autologin_out
  autologin_out="$(env OVERRIDE_DIR="$AUTOLOGIN_DROPIN_DIR" LOGIN_FILE="$LOGIN_FILE" bash "$SCRIPT_DIR/enable-autologin.sh" --status 2>&1 || true)"

  if [[ $json_mode -eq 1 ]]; then
    local no_pkg_json="null" autostart_json="false" journal_json="false"
    local pacnew_json="false" pacnew_replaced_json="false"
    [[ "$no_packages" == 1 ]] && no_pkg_json="true"
    [[ "$no_packages" == 0 ]] && no_pkg_json="false"
    [[ $autostart_paused -eq 1 ]] && autostart_json="true"
    [[ $session_journal -eq 1 ]] && journal_json="true"
    [[ $pacnew_waiting -eq 1 ]] && pacnew_json="true"
    [[ $pacnew_replaced -eq 1 ]] && pacnew_replaced_json="true"

    local auto_state="unknown" auto_user="" auto_file="" auto_line
    local auto_warnings=() auto_notes=()
    while IFS= read -r auto_line || [[ -n "$auto_line" ]]; do
      [[ -n "$auto_line" ]] || continue
      if [[ "$auto_line" =~ ^enabled\ for\ ([^[:space:]]+)\ \((.*)\)$ ]]; then
        auto_state="enabled"
        auto_user="${BASH_REMATCH[1]}"
        auto_file="${BASH_REMATCH[2]}"
      elif [[ "$auto_line" == disabled ]]; then
        auto_state="disabled"
      elif [[ "$auto_line" == Warning:\ * ]]; then
        auto_warnings+=("$auto_line")
      elif [[ "$auto_line" == Note:\ * ]]; then
        auto_notes+=("$auto_line")
      fi
    done <<<"$autologin_out"
    if [[ "$auto_state" == disabled ]]; then
      local note_item
      for note_item in "${auto_notes[@]}"; do
        case "$note_item" in
          "Note: cannot read $AUTOLOGIN_DROPIN_DIR;"* | \
            "Note: cannot read $AUTOLOGIN_DROPIN_DIR/lightxdm-autologin.conf;"* | \
            "Note: cannot read $AUTOLOGIN_DROPIN_DIR/override.conf;"*)
            auto_state="unknown-needs-root"
            break
            ;;
        esac
      done
    fi

    printf '{\n'
    printf '  "install_choices": {\n'
    printf '    "file": %s,\n' "$(json_str "$choices_file")"
    printf '    "state": %s,\n' "$(json_str "$choices_kind")"
    printf '    "de": %s,\n' "$(json_str_or_null "$de")"
    printf '    "no_packages": %s\n' "$no_pkg_json"
    printf '  },\n'

    printf '  "session_template": {\n'
    printf '    "de": %s,\n' "$(json_str_or_null "$de")"
    printf '    "source": %s,\n' "$(json_str_or_null "$template_source")"
    printf '    "path": %s,\n' "$(json_str_or_null "$template")"
    printf '    "dotfile": %s\n' "$(json_str_or_null "$session_dotfile")"
    printf '  },\n'

    printf '  "tty1": {\n'
    printf '    "launcher_type": %s,\n' "$(json_str "$launcher_type")"
    printf '    "launcher_path": %s,\n' "$(json_str_or_null "$launcher_path")"
    printf '    "autostart_paused": %s,\n' "$autostart_json"
    printf '    "session_journal": %s,\n' "$journal_json"
    printf '    "recent_launch_attempts_30s": %d\n' "$recent_count"
    printf '  },\n'

    printf '  "dotfiles": [\n'
    local idx DOTFILE_STATUS_STATE="" DOTFILE_STATUS_SYMLINK_TARGET="" DOTFILE_STATUS_PENDING_UPDATE="" DOTFILE_STATUS_BACKUP=""
    for ((idx = 0; idx < ${#dotfile_targets[@]}; idx++)); do
      inspect_dotfile_status "${dotfile_targets[$idx]}" "${dotfile_sources[$idx]}"
      [[ $idx -gt 0 ]] && printf ',\n'
      printf '    {\n'
      printf '      "path": %s,\n' "$(json_str "${dotfile_targets[$idx]}")"
      printf '      "state": %s,\n' "$(json_str "$DOTFILE_STATUS_STATE")"
      printf '      "symlink_target": %s,\n' "$(json_str_or_null "$DOTFILE_STATUS_SYMLINK_TARGET")"
      printf '      "pending_update": %s,\n' "$(json_str_or_null "$DOTFILE_STATUS_PENDING_UPDATE")"
      printf '      "backup": %s\n' "$(json_str_or_null "$DOTFILE_STATUS_BACKUP")"
      printf '    }'
    done
    printf '\n  ],\n'

    printf '  "pam": {\n'
    printf '    "login_file": %s,\n' "$(json_str "$LOGIN_FILE")"
    printf '    "keyring_record_file": %s,\n' "$(json_str "$PAM_KEYRING_STATE")"
    printf '    "keyring_record": %s,\n' "$(json_str "$pam_record_kind")"
    if [[ "$pam_record_kind" == invalid ]]; then
      printf '    "keyring_record_raw": %s,\n' "$(json_str "$pam_record_raw")"
    else
      printf '    "keyring_record_raw": null,\n'
    fi
    printf '    "keyring_status": %s,\n' "$(json_str "$keyring_status_id")"
    printf '    "gnome_session_type_file": %s,\n' "$(json_str "$GNOME_SESSION_TYPE_DEST")"
    printf '    "gnome_session_type": %s,\n' "$(json_str "$gnome_status_id")"
    printf '    "pacnew_waiting": %s,\n' "$pacnew_json"
    printf '    "pacnew_package_replaced": %s\n' "$pacnew_replaced_json"
    printf '  },\n'

    printf '  "getty_tty1_state": %s,\n' "$(json_str "$getty_state")"

    printf '  "disabled_display_managers": {\n'
    printf '    "state_file": %s,\n' "$(json_str "$DM_STATE_FILE")"
    printf '    "state": %s,\n' "$(json_str "$dm_mode")"
    printf '    "units": ['
    for ((idx = 0; idx < ${#dm_units[@]}; idx++)); do
      [[ $idx -gt 0 ]] && printf ', '
      printf '{"unit": %s, "state": %s}' "$(json_str "${dm_units[$idx]}")" "$(json_str "${dm_unit_states[$idx]}")"
    done
    printf ']\n'
    printf '  },\n'

    printf '  "autologin": {\n'
    printf '    "state": %s,\n' "$(json_str "$auto_state")"
    printf '    "user": %s,\n' "$(json_str_or_null "$auto_user")"
    printf '    "file": %s,\n' "$(json_str_or_null "$auto_file")"
    printf '    "warnings": ['
    for ((idx = 0; idx < ${#auto_warnings[@]}; idx++)); do
      [[ $idx -gt 0 ]] && printf ', '
      json_str "${auto_warnings[$idx]}"
    done
    printf '],\n'
    printf '    "notes": ['
    for ((idx = 0; idx < ${#auto_notes[@]}; idx++)); do
      [[ $idx -gt 0 ]] && printf ', '
      json_str "${auto_notes[$idx]}"
    done
    printf ']\n'
    printf '  }\n'
    printf '}\n'
    return 0
  fi

  printf 'Install choices: %s (%s)\n' "$choices_state" "$choices_file"
  [[ -z "$de" ]] || printf 'Session template: %s\n' "$template_text"
  printf 'TTY1 launcher: %s\n' "$launcher"
  if [[ $autostart_paused -eq 1 ]]; then
    printf 'TTY1 auto-start: paused (%s exists)\n' "$HOME/.config/lightxdm/no-autostart"
  else
    printf 'TTY1 auto-start: active\n'
  fi
  if [[ $session_journal -eq 1 ]]; then
    printf 'Session journal: enabled (%s exists)\n' "$HOME/.config/lightxdm/session-journal"
  else
    printf 'Session journal: disabled\n'
  fi
  if ((recent_count > 0)); then
    printf 'Recent TTY1 launch attempts (30s): %s\n' "$recent_count"
  fi
  printf 'Dotfiles:\n'
  local idx
  for ((idx = 0; idx < ${#dotfile_targets[@]}; idx++)); do
    dotfile_status_line "${dotfile_targets[$idx]}" "${dotfile_sources[$idx]}"
  done
  printf 'PAM keyring record: %s (%s)\n' "$pam_record_state" "$PAM_KEYRING_STATE"
  printf 'PAM keyring (%s): %s\n' "$LOGIN_FILE" "$keyring_status"
  printf 'PAM GNOME session type: %s\n' "$gnome_status"
  if [[ $pacnew_waiting -eq 1 ]]; then
    if [[ $pacnew_replaced -eq 1 ]]; then
      printf 'PAM pacnew: %s.pacnew waiting; %s looks package-replaced (run lightxdm-update)\n' "$LOGIN_FILE" "$LOGIN_FILE"
    else
      printf 'PAM pacnew: %s.pacnew waiting (run lightxdm-update after merging if needed)\n' "$LOGIN_FILE"
    fi
  fi
  if [[ "$getty_state" == masked ]]; then
    printf 'getty@tty1.service: masked (unmask with: sudo systemctl unmask getty@tty1.service)\n'
  else
    printf 'getty@tty1.service: %s\n' "$getty_state"
  fi
  case "$dm_mode" in
    symlink-ignored) printf 'Disabled display managers: symlink ignored (%s)\n' "$DM_STATE_FILE" ;;
    recorded) printf 'Disabled display managers: %s\n' "${dm_list[*]}" ;;
    unknown-needs-root) printf 'Disabled display managers: unknown (needs root)\n' ;;
    none) printf 'Disabled display managers: none recorded\n' ;;
  esac
  if [[ -n "$autologin_out" ]]; then
    printf 'TTY1 autologin: %s\n' "${autologin_out//$'\n'/$'\n  '}"
  else
    printf 'TTY1 autologin: unknown\n'
  fi
}

# Emit enabled display manager ids checked via systemctl (one per line).
detect_enabled_dms() {
  local dm dm_unit unit_files="" enabled_dms=()
  unit_files="$(systemctl list-unit-files 2>/dev/null || true)"
  for dm in "${DM_LIST[@]}"; do
    if [[ -n "$unit_files" ]] && grep -E -- "^[[:space:]]*${dm}\.service([[:space:]]|$)" <<<"$unit_files" >/dev/null; then
      if [[ "$(systemctl is-enabled "${dm}.service" 2>/dev/null || true)" == "enabled" ]]; then
        enabled_dms+=("$dm")
      fi
    fi
  done
  if [[ -L "$DISPLAY_MANAGER_LINK" ]] && dm_unit="$(readlink -f "$DISPLAY_MANAGER_LINK" 2>/dev/null || true)"; then
    dm_unit="${dm_unit##*/}"
    dm="${dm_unit%.service}"
    if [[ -n "$dm_unit" && " ${enabled_dms[*]} " != *" $dm "* ]] && [[ "$(systemctl is-enabled "$dm_unit" 2>/dev/null || true)" == "enabled" ]]; then
      enabled_dms+=("$dm")
    fi
  fi
  if [[ " ${enabled_dms[*]} " != *" ly@tty1 "* ]] && [[ "$(systemctl is-enabled ly@tty1.service 2>/dev/null || true)" == "enabled" ]]; then
    enabled_dms+=("ly@tty1")
  fi
  if [[ ${#enabled_dms[@]} -gt 0 ]]; then
    printf '%s\n' "${enabled_dms[@]}"
  fi
}

# Run pre-install onboarding readiness checks cleanly without sudo or side effects
run_preflight() {
  local blockers=0
  local current_user="${SUDO_USER:-${USER:-}}"
  if [[ -z "$current_user" ]]; then
    current_user="$(id -un 2>/dev/null || true)"
  fi

  if [[ $EUID -eq 0 ]]; then
    printf 'User/sudo: FAIL (running as root; run as a regular user, not root or sudo)\n'
    blockers=$((blockers + 1))
  elif ! command -v sudo >/dev/null 2>&1; then
    printf "User/sudo: FAIL (sudo not found; install as root: su -c 'pacman -S sudo')\n"
    blockers=$((blockers + 1))
  else
    local groups_out="" group_note=""
    groups_out="$(id -nG 2>/dev/null || true)"
    if [[ -n "$groups_out" && " $groups_out " != *" wheel "* ]]; then
      group_note="; not in wheel group (ensure sudo privileges)"
    fi
    printf 'User/sudo: ok (%s, sudo available%s)\n' "${current_user:-regular user}" "$group_note"
  fi

  local have_pacman=0 have_systemctl=0 missing_tools=()
  if command -v pacman >/dev/null 2>&1; then
    have_pacman=1
  else
    missing_tools+=("pacman")
  fi
  if command -v systemctl >/dev/null 2>&1; then
    have_systemctl=1
  else
    missing_tools+=("systemctl")
  fi
  if [[ ${#missing_tools[@]} -eq 0 ]]; then
    printf 'System tools: ok (pacman, systemctl)\n'
  else
    printf 'System tools: FAIL (missing: %s)\n' "${missing_tools[*]}"
    blockers=$((blockers + 1))
  fi

  local enabled_dms=()
  if [[ $have_systemctl -eq 1 ]]; then
    local getty_state=""
    getty_state="$(systemctl is-enabled getty@tty1.service 2>/dev/null || true)"
    if [[ "$getty_state" == masked ]]; then
      printf 'getty@tty1.service: FAIL (masked — unmask with: sudo systemctl unmask getty@tty1.service)\n'
      blockers=$((blockers + 1))
    else
      printf 'getty@tty1.service: ok (%s)\n' "${getty_state:-unknown}"
    fi

    mapfile -t enabled_dms < <(detect_enabled_dms)
    if [[ ${#enabled_dms[@]} -gt 0 ]]; then
      printf 'Display managers: %s enabled (install will disable cleanly; uninstall restores)\n' "${enabled_dms[*]}"
    else
      printf 'Display managers: ok (none enabled)\n'
    fi
  else
    printf 'getty@tty1.service: skipped (systemctl unavailable)\n'
  fi

  if [[ -n "${WAYLAND_DISPLAY:-}" || -n "${DISPLAY:-}" ]]; then
    printf 'Current session: graphical (%s — safe to install; current session will stay running)\n' "${WAYLAND_DISPLAY:-$DISPLAY}"
  else
    printf 'Current session: TTY/non-graphical\n'
  fi

  local login_shell=""
  if [[ -n "$current_user" ]] && command -v getent >/dev/null 2>&1; then
    login_shell="$(getent passwd "$current_user" | cut -d: -f7 || true)"
  fi
  case "$login_shell" in
    "")
      printf 'Login shell: unknown (non-bash users see: %s --shell-snippet <zsh|fish>)\n' "$(script_cmd install.sh)"
      ;;
    *bash)
      printf 'Login shell: ok (%s — reads ~/.bash_profile)\n' "$login_shell"
      ;;
    *zsh)
      printf 'Login shell: WARN (%s does not read ~/.bash_profile — run: %s --shell-snippet zsh >> ~/.zprofile)\n' "$login_shell" "$(script_cmd install.sh)"
      ;;
    *fish)
      printf 'Login shell: WARN (%s does not read ~/.bash_profile — run: %s --shell-snippet fish >> ~/.config/fish/config.fish)\n' "$login_shell" "$(script_cmd install.sh)"
      ;;
    *)
      printf 'Login shell: WARN (%s does not read ~/.bash_profile — add TTY1 auto-start block per docs/startx-autologin.md)\n' "$login_shell"
      ;;
  esac

  local detected_raw="" detected_des=() first_de=""
  if [[ $have_pacman -eq 1 ]]; then
    detected_raw="$(detect_de 2>/dev/null || true)"
    if [[ -n "$detected_raw" && "$detected_raw" != "unknown" ]]; then
      mapfile -t detected_des <<<"$detected_raw"
      first_de="${detected_des[0]}"
      printf 'Detected desktop(s): %s\n' "${detected_des[*]}"
      printf 'Next step: %s --dry-run --de %s   (or %s)\n' "$(script_cmd install.sh)" "$first_de" "$(script_cmd install.sh)"
    else
      printf 'Detected desktop(s): none installed\n'
      printf 'Next step: %s --list-sessions   (or %s to pick a desktop)\n' "$(script_cmd install.sh)" "$(script_cmd install.sh)"
    fi
  else
    printf 'Detected desktop(s): skipped (pacman unavailable)\n'
  fi

  if [[ $blockers -eq 0 ]]; then
    printf 'Preflight: PASS (ready to run lightXDM installer)\n'
    return 0
  fi
  printf 'Preflight: FAIL (%d blocker(s) found above)\n' "$blockers"
  return 1
}

# Verify post-install session, shell trigger, PAM, and systemd boot-recovery health without sudo or changes.
run_doctor() {
  local LC_ALL=C issues=0 warnings=0
  local install_cmd update_cmd recover_cmd
  install_cmd="$(script_cmd install.sh)"
  if command -v lightxdm-update >/dev/null 2>&1; then
    update_cmd="lightxdm-update"
  else
    update_cmd="$install_cmd --update"
  fi
  recover_cmd="$install_cmd --recover"

  local real_user="${SUDO_USER:-${USER:-}}"
  if [[ -z "$real_user" ]]; then
    real_user="$(id -un 2>/dev/null || true)"
  fi

  local choices_file line de="" no_packages="" choices_kind="not-recorded"
  choices_file="$(install_choices_file)"
  if install_choices_readable "$choices_file"; then
    choices_kind="readable"
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        de=*) de="${line#de=}" ;;
        no_packages=1) no_packages=1 ;;
        no_packages=0) no_packages=0 ;;
      esac
    done <"$choices_file"
  elif [[ -L "${choices_file%/*}" || -L "$choices_file" ]]; then
    choices_kind="symlink-ignored"
    printf 'Install choices: FAIL (%s or its directory is a symlink; re-run %s --de <id>)\n' "$choices_file" "$install_cmd"
    issues=$((issues + 1))
  elif [[ -e "$choices_file" ]]; then
    choices_kind="unreadable"
    printf 'Install choices: FAIL (%s is unreadable; fix permissions on %s)\n' "$choices_file" "$choices_file"
    issues=$((issues + 1))
  fi

  local installed_any=0
  if [[ "$choices_kind" != "not-recorded" || -e "$HOME/.wayland-session" || -L "$HOME/.wayland-session" ||
    -e "$HOME/.xinitrc" || -L "$HOME/.xinitrc" ]]; then
    installed_any=1
  fi
  if [[ $installed_any -eq 0 ]]; then
    printf 'Install state: FAIL (lightXDM is not installed for %s — run: %s --preflight)\n' "$HOME" "$install_cmd"
    issues=$((issues + 1))
  elif [[ "$choices_kind" == "readable" && -n "$de" ]]; then
    if [[ "$no_packages" == 1 ]]; then
      printf 'Install choices: ok (de=%s, --no-packages)\n' "$de"
    else
      printf 'Install choices: ok (de=%s)\n' "$de"
    fi
  elif [[ "$choices_kind" == "readable" ]]; then
    printf 'Install choices: WARN (%s has no desktop recorded)\n' "$choices_file"
    warnings=$((warnings + 1))
  fi

  local template="" expected_mode="" active_launcher=""
  if [[ -n "$de" ]]; then
    if template="$(xinitrc_template "$de" 2>/dev/null)"; then
      if [[ "${template##*/}" == .wayland-session-* ]]; then
        expected_mode="wayland"
      else
        expected_mode="x11"
      fi
      if [[ ! -f "$template" ]]; then
        printf 'Session template: FAIL (missing %s for de=%s — run: %s --init-template --de %s)\n' "$template" "$de" "$install_cmd" "$de"
        issues=$((issues + 1))
      fi
    else
      printf 'Session template: FAIL (cannot resolve template for de=%s — check ~/.config/lightxdm/ for conflicting .wayland-session-%s and .xinitrc-%s)\n' "$de" "$de" "$de"
      issues=$((issues + 1))
    fi
  fi

  local wl="$HOME/.wayland-session" xi="$HOME/.xinitrc"
  if [[ "$expected_mode" == wayland ]]; then
    if [[ -L "$wl" ]]; then
      if [[ ! -e "$wl" ]]; then
        printf 'Session launcher: FAIL (broken symlink %s — restore with: %s)\n' "$wl" "$recover_cmd"
        issues=$((issues + 1))
      elif [[ ! -f "$wl" ]]; then
        printf 'Session launcher: FAIL (%s is a symlink to a non-regular file — restore with: %s)\n' "$wl" "$recover_cmd"
        issues=$((issues + 1))
      elif [[ ! -x "$wl" ]]; then
        printf 'Session launcher: FAIL (%s is not executable — fix with: chmod +x ~/.wayland-session)\n' "$wl"
        issues=$((issues + 1))
      else
        printf 'Session launcher: WARN (%s is a symlink; --update ignores symlinks)\n' "$wl"
        warnings=$((warnings + 1))
        active_launcher="$wl"
      fi
    elif [[ ! -f "$wl" ]]; then
      printf 'Session launcher: FAIL (missing %s for de=%s — restore with: %s)\n' "$wl" "$de" "$recover_cmd"
      issues=$((issues + 1))
    elif [[ ! -x "$wl" ]]; then
      printf 'Session launcher: FAIL (%s exists but is not executable — fix with: chmod +x ~/.wayland-session)\n' "$wl"
      issues=$((issues + 1))
    else
      printf 'Session launcher: ok (%s, Wayland for de=%s)\n' "$wl" "$de"
      active_launcher="$wl"
    fi
  elif [[ "$expected_mode" == x11 ]]; then
    if [[ ( -e "$wl" || -L "$wl" ) && -x "$wl" ]]; then
      printf 'Session launcher: FAIL (%s is executable and shadows X11 %s for de=%s — remove %s or run: chmod -x ~/.wayland-session)\n' "$wl" "$xi" "$de" "$wl"
      issues=$((issues + 1))
    fi
    if [[ -L "$xi" ]]; then
      if [[ ! -e "$xi" ]]; then
        printf 'Session launcher: FAIL (broken symlink %s — restore with: %s)\n' "$xi" "$recover_cmd"
        issues=$((issues + 1))
      elif [[ ! -f "$xi" ]]; then
        printf 'Session launcher: FAIL (%s is a symlink to a non-regular file — restore with: %s)\n' "$xi" "$recover_cmd"
        issues=$((issues + 1))
      else
        printf 'Session launcher: WARN (%s is a symlink; --update ignores symlinks)\n' "$xi"
        warnings=$((warnings + 1))
        active_launcher="$xi"
      fi
    elif [[ ! -f "$xi" ]]; then
      printf 'Session launcher: FAIL (missing %s for de=%s — restore with: %s)\n' "$xi" "$de" "$recover_cmd"
      issues=$((issues + 1))
    else
      active_launcher="$xi"
    fi
    if ! command -v startx >/dev/null 2>&1; then
      printf 'X11 starter: FAIL (startx not found on PATH — install xorg-xinit)\n'
      issues=$((issues + 1))
    elif [[ -n "$active_launcher" && ! -L "$xi" ]]; then
      printf 'Session launcher: ok (%s via startx for de=%s)\n' "$xi" "$de"
    fi
  elif [[ $installed_any -eq 1 ]]; then
    if [[ -L "$wl" && ! -e "$wl" ]]; then
      printf 'Session launcher: FAIL (broken symlink %s — remove or run: %s --de <id>)\n' "$wl" "$install_cmd"
      issues=$((issues + 1))
    elif [[ -f "$wl" && -x "$wl" ]]; then
      if [[ -L "$wl" ]]; then
        printf 'Session launcher: WARN (%s is a symlink; --update ignores symlinks)\n' "$wl"
        warnings=$((warnings + 1))
      else
        printf 'Session launcher: ok (%s, Wayland)\n' "$wl"
      fi
      active_launcher="$wl"
    elif [[ -f "$wl" ]]; then
      printf 'Session launcher: FAIL (%s exists but is not executable — fix with: chmod +x ~/.wayland-session)\n' "$wl"
      issues=$((issues + 1))
    elif [[ -L "$xi" && ! -e "$xi" ]]; then
      printf 'Session launcher: FAIL (broken symlink %s — restore with: %s --de <id>)\n' "$xi" "$install_cmd"
      issues=$((issues + 1))
    elif [[ -f "$xi" ]]; then
      if ! command -v startx >/dev/null 2>&1; then
        printf 'X11 starter: FAIL (startx not found on PATH — install xorg-xinit)\n'
        issues=$((issues + 1))
      else
        if [[ -L "$xi" ]]; then
          printf 'Session launcher: WARN (%s is a symlink; --update ignores symlinks)\n' "$xi"
          warnings=$((warnings + 1))
        else
          printf 'Session launcher: ok (%s via startx)\n' "$xi"
        fi
        active_launcher="$xi"
      fi
    fi
  fi

  if [[ -n "$active_launcher" ]]; then
    if [[ ! -r "$active_launcher" ]]; then
      printf 'Session checks: FAIL (%s is not readable — fix with: chmod u+r %s)\n' "$active_launcher" "$active_launcher"
      issues=$((issues + 1))
    else
      local diag_err="" cmd_ok=1
      if ! diag_err="$(check_template_syntax "$active_launcher" 2>&1)"; then
        printf 'Session syntax: FAIL (%s)\n' "${diag_err#=> }"
        issues=$((issues + 1))
        cmd_ok=0
      fi
      if ! diag_err="$(check_session_commands "$active_launcher" 2>&1)"; then
        printf 'Session command: FAIL (%s)\n' "${diag_err#=> }"
        issues=$((issues + 1))
        cmd_ok=0
      fi
      if [[ $cmd_ok -eq 1 ]]; then
        printf 'Session checks: ok (syntax and command verified for %s)\n' "$active_launcher"
      fi
    fi
  fi

  local login_shell=""
  if [[ -n "$real_user" ]] && command -v getent >/dev/null 2>&1; then
    login_shell="$(getent passwd "$real_user" | cut -d: -f7 || true)"
  fi
  if [[ $installed_any -eq 1 ]]; then
    case "$login_shell" in
      *bash)
        if [[ -f "$HOME/.bash_profile" && -r "$HOME/.bash_profile" ]] &&
          grep -Eq '\.wayland-session|startx' "$HOME/.bash_profile"; then
          printf 'Login shell auto-start: ok (%s via ~/.bash_profile)\n' "$login_shell"
        else
          printf 'Login shell auto-start: FAIL (~/.bash_profile is missing or lacks TTY1 auto-start trigger — restore with: %s)\n' "$recover_cmd"
          issues=$((issues + 1))
        fi
        ;;
      *zsh)
        if [[ -f "$HOME/.zprofile" && -r "$HOME/.zprofile" ]] &&
          grep -Eq '\.wayland-session|startx' "$HOME/.zprofile"; then
          printf 'Login shell auto-start: ok (%s via ~/.zprofile)\n' "$login_shell"
        else
          printf 'Login shell auto-start: FAIL (zsh login shell lacks TTY1 auto-start block in ~/.zprofile — run: %s --shell-snippet zsh >> ~/.zprofile)\n' "$install_cmd"
          issues=$((issues + 1))
        fi
        ;;
      *fish)
        if [[ -f "$HOME/.config/fish/config.fish" && -r "$HOME/.config/fish/config.fish" ]] &&
          grep -Eq '\.wayland-session|startx' "$HOME/.config/fish/config.fish"; then
          printf 'Login shell auto-start: ok (%s via ~/.config/fish/config.fish)\n' "$login_shell"
        else
          printf 'Login shell auto-start: FAIL (fish login shell lacks TTY1 auto-start block in ~/.config/fish/config.fish — run: %s --shell-snippet fish >> ~/.config/fish/config.fish)\n' "$install_cmd"
          issues=$((issues + 1))
        fi
        ;;
      "")
        if [[ -f "$HOME/.bash_profile" && -r "$HOME/.bash_profile" ]] &&
          grep -Eq '\.wayland-session|startx' "$HOME/.bash_profile"; then
          printf 'Login shell auto-start: ok (~/.bash_profile present)\n'
        else
          printf 'Login shell auto-start: WARN (login shell unknown; could not verify TTY1 shell auto-start hook)\n'
          warnings=$((warnings + 1))
        fi
        ;;
      *)
        printf 'Login shell auto-start: WARN (%s does not read ~/.bash_profile — verify TTY1 auto-start block per docs/startx-autologin.md)\n' "$login_shell"
        warnings=$((warnings + 1))
        ;;
    esac
  fi

  if [[ -e "$HOME/.config/lightxdm/no-autostart" || -L "$HOME/.config/lightxdm/no-autostart" ]]; then
    printf 'Auto-start pause: FAIL (~/.config/lightxdm/no-autostart disables TTY1 auto-start — check logs: journalctl -b -t lightxdm, then resume: rm ~/.config/lightxdm/no-autostart)\n'
    issues=$((issues + 1))
  else
    local attempts_file="${XDG_STATE_HOME:-$HOME/.local/state}/lightxdm/startx-attempts"
    local recent_count=0
    if [[ -f "$attempts_file" && ! -L "$attempts_file" && -r "$attempts_file" ]]; then
      local now attempt_lines=() attempt_ts
      printf -v now '%(%s)T' -1
      mapfile -t attempt_lines 2>/dev/null <"$attempts_file" || :
      for attempt_ts in "${attempt_lines[@]}"; do
        if [[ -n "$attempt_ts" && ${#attempt_ts} -le 18 && "$attempt_ts" != *[!0123456789]* ]] &&
          ((now - 10#$attempt_ts >= 0 && now - 10#$attempt_ts <= 30)); then
          recent_count=$((recent_count + 1))
        fi
      done
    fi
    if [[ $recent_count -gt 0 ]]; then
      printf 'Auto-start status: WARN (%d launch attempt(s) in last 30s — check journalctl -b -t lightxdm or touch ~/.config/lightxdm/session-journal)\n' "$recent_count"
      warnings=$((warnings + 1))
    else
      printf 'Auto-start status: ok (active on TTY1)\n'
    fi
  fi

  local pending_files=() candidate_dot
  for candidate_dot in \
    "$HOME/.bash_profile" "$HOME/.wayland-session" "$HOME/.xinitrc" \
    "$HOME/.gpg-agent-gnome" "$HOME/.gpg-agent-kwallet" \
    "$HOME/.config/autostart/lightxdm-gpg-agent-tty.desktop"; do
    if [[ -e "${candidate_dot}.lightxdm-new" || -L "${candidate_dot}.lightxdm-new" ]]; then
      pending_files+=("${candidate_dot}.lightxdm-new")
    fi
  done
  if [[ ${#pending_files[@]} -gt 0 ]]; then
    printf 'Pending dotfile updates: WARN (%s — review diff and merge)\n' "${pending_files[*]}"
    warnings=$((warnings + 1))
  fi

  local pam_record="" pam_expected="" keyring_configured=0
  if pam_record="$(read_pam_state_file "$PAM_KEYRING_STATE" 1 2>/dev/null)"; then
    case "$pam_record" in
      gnome | kwallet) pam_expected="$pam_record" ;;
      *)
        printf 'PAM keyring state: WARN (%s has unexpected value %s)\n' "$PAM_KEYRING_STATE" "${pam_record:-empty}"
        warnings=$((warnings + 1))
        ;;
    esac
  elif [[ -L "$(dirname -- "$PAM_KEYRING_STATE")" || -L "$PAM_KEYRING_STATE" ]]; then
    printf 'PAM keyring state: FAIL (%s or its directory is a symlink; lightXDM ignores symlinks)\n' "$PAM_KEYRING_STATE"
    issues=$((issues + 1))
  elif pam_path_needs_sudo "$PAM_KEYRING_STATE" 1; then
    printf 'PAM keyring state: WARN (%s: unknown (needs root))\n' "$PAM_KEYRING_STATE"
    warnings=$((warnings + 1))
  fi

  local login_content=""
  if [[ -L "$(dirname -- "$LOGIN_FILE")" || -L "$LOGIN_FILE" ]]; then
    printf 'PAM login: FAIL (%s or its directory is a symlink; lightXDM ignores symlinks)\n' "$LOGIN_FILE"
    issues=$((issues + 1))
  elif login_content="$(read_pam_file "$LOGIN_FILE" 1 2>/dev/null)"; then
    local missing_gnome missing_kwallet has_gnome_line=0 has_kwallet_line=0
    missing_gnome="$(pam_lines_to_add "pam_gnome_keyring.so" "$PAM_GNOME_KEYRING_AUTH" "$PAM_GNOME_KEYRING_SESSION" "" 1 || true)"
    missing_kwallet="$(pam_lines_to_add "pam_kwallet5.so" "$PAM_KWALLET_AUTH" "$PAM_KWALLET_SESSION" "" 1 || true)"
    grep -Eq '^[[:space:]]*-?(auth|session)[[:space:]][^#]*pam_gnome_keyring\.so' <<<"$login_content" && has_gnome_line=1
    grep -Eq '^[[:space:]]*-?(auth|session)[[:space:]][^#]*pam_kwallet5\.so' <<<"$login_content" && has_kwallet_line=1

    if [[ -e "${LOGIN_FILE}.pacnew" || -L "${LOGIN_FILE}.pacnew" ]]; then
      if login_file_replaced_by_package 1; then
        printf 'PAM .pacnew: FAIL (%s appears replaced by package upgrade while %s.pacnew exists — restore with: %s or %s %s)\n' \
          "$LOGIN_FILE" "$LOGIN_FILE" "$update_cmd" "$install_cmd" "$(pam_restore_hint "$de" "$pam_expected")"
        issues=$((issues + 1))
      else
        printf 'PAM .pacnew: WARN (%s.pacnew waiting — merge carefully without dropping lightXDM PAM lines)\n' "$LOGIN_FILE"
        warnings=$((warnings + 1))
      fi
    fi

    local keyring_issue=0
    if [[ "$pam_expected" == gnome && -n "$missing_gnome" ]]; then
      printf 'PAM keyring: FAIL (recorded gnome keyring lines missing from %s — restore with: %s %s)\n' "$LOGIN_FILE" "$install_cmd" "$(pam_restore_hint "$de" gnome)"
      issues=$((issues + 1))
      keyring_issue=1
    elif [[ "$pam_expected" == kwallet && -n "$missing_kwallet" ]]; then
      printf 'PAM keyring: FAIL (recorded kwallet5 lines missing from %s — restore with: %s %s)\n' "$LOGIN_FILE" "$install_cmd" "$(pam_restore_hint "$de" kwallet)"
      issues=$((issues + 1))
      keyring_issue=1
    elif { [[ $has_gnome_line -eq 1 && -n "$missing_gnome" ]]; } || { [[ $has_kwallet_line -eq 1 && -n "$missing_kwallet" ]]; }; then
      local partial_backend="$pam_expected"
      if [[ -z "$partial_backend" ]]; then
        if [[ $has_kwallet_line -eq 1 && -n "$missing_kwallet" && $has_gnome_line -eq 0 ]]; then
          partial_backend="kwallet"
        elif [[ $has_gnome_line -eq 1 && -n "$missing_gnome" && $has_kwallet_line -eq 0 ]]; then
          partial_backend="gnome"
        fi
      fi
      printf 'PAM keyring: FAIL (partial keyring PAM lines in %s — missing auth or session line; restore with: %s %s)\n' "$LOGIN_FILE" "$install_cmd" "$(pam_restore_hint "$de" "$partial_backend")"
      issues=$((issues + 1))
      keyring_issue=1
    fi

    if [[ -z "$missing_gnome" ]]; then
      keyring_configured=1
      if [[ ! -e "${SESSION_ROOT:-}/usr/lib/security/pam_gnome_keyring.so" ]]; then
        printf 'PAM keyring module: FAIL (%s/usr/lib/security/pam_gnome_keyring.so missing — install gnome-keyring)\n' "${SESSION_ROOT:-}"
        issues=$((issues + 1))
        keyring_issue=1
      fi
    fi
    if [[ -z "$missing_kwallet" ]]; then
      keyring_configured=1
      if [[ ! -e "${SESSION_ROOT:-}/usr/lib/security/pam_kwallet5.so" ]]; then
        printf 'PAM keyring module: FAIL (%s/usr/lib/security/pam_kwallet5.so missing — install kwallet-pam)\n' "${SESSION_ROOT:-}"
        issues=$((issues + 1))
        keyring_issue=1
      fi
    fi
    if [[ $keyring_issue -eq 0 && $keyring_configured -eq 1 ]]; then
      printf 'PAM keyring: ok (%s)\n' "$LOGIN_FILE"
    fi

    local GNOME_PAM_STATUS_ID="" GNOME_PAM_STATUS_MSG=""
    inspect_gnome_pam_status "$login_content" "$real_user"
    case "$GNOME_PAM_STATUS_ID" in
      configured)
        printf 'PAM GNOME session type: ok (%s)\n' "$GNOME_SESSION_TYPE_DEST"
        ;;
      block-present-needs-root)
        printf 'PAM GNOME session type: WARN (%s)\n' "$GNOME_PAM_STATUS_MSG"
        warnings=$((warnings + 1))
        ;;
      block-present-missing-file)
        printf 'PAM GNOME session type: FAIL (missing %s referenced by %s — restore with: %s --pam-only --de gnome)\n' "$GNOME_SESSION_TYPE_DEST" "$LOGIN_FILE" "$install_cmd"
        issues=$((issues + 1))
        ;;
      edited-block)
        printf 'PAM GNOME session type: FAIL (incomplete GNOME session-type block in %s — restore with: %s --pam-only --de gnome)\n' "$LOGIN_FILE" "$install_cmd"
        issues=$((issues + 1))
        ;;
      file-without-block)
        if [[ "$de" == gnome ]]; then
          printf 'PAM GNOME session type: FAIL (%s — restore PAM block with: %s --pam-only --de gnome)\n' "$GNOME_PAM_STATUS_MSG" "$install_cmd"
          issues=$((issues + 1))
        else
          printf 'PAM GNOME session type: WARN (%s — restore PAM block with: %s --pam-only --de gnome)\n' "$GNOME_PAM_STATUS_MSG" "$install_cmd"
          warnings=$((warnings + 1))
        fi
        ;;
      not-configured)
        if [[ "$de" == gnome ]]; then
          printf 'PAM GNOME session type: FAIL (GNOME Wayland session-type PAM block missing from %s — fix with: %s --pam-only --de gnome)\n' "$LOGIN_FILE" "$install_cmd"
          issues=$((issues + 1))
        fi
        ;;
    esac
  elif [[ ! -e "$LOGIN_FILE" && -x "$(dirname -- "$LOGIN_FILE")" ]]; then
    printf 'PAM login: FAIL (%s is missing — restore pambase or re-run %s %s)\n' "$LOGIN_FILE" "$install_cmd" "$(pam_restore_hint "$de" "$pam_expected")"
    issues=$((issues + 1))
  else
    printf 'PAM login: WARN (%s: unknown (needs root) — inspect PAM lines separately with sudo)\n' "$LOGIN_FILE"
    warnings=$((warnings + 1))
  fi

  if command -v systemctl >/dev/null 2>&1; then
    local getty_state=""
    getty_state="$(systemctl is-enabled getty@tty1.service 2>/dev/null || true)"
    case "$getty_state" in
      masked)
        printf 'getty@tty1.service: FAIL (masked — unmask with: sudo systemctl unmask getty@tty1.service)\n'
        issues=$((issues + 1))
        ;;
      disabled)
        printf 'getty@tty1.service: FAIL (disabled — enable with: sudo systemctl enable getty@tty1.service)\n'
        issues=$((issues + 1))
        ;;
      "")
        printf 'getty@tty1.service: WARN (unknown systemd state)\n'
        warnings=$((warnings + 1))
        ;;
      *)
        printf 'getty@tty1.service: ok (%s)\n' "$getty_state"
        ;;
    esac

    local enabled_dms=() dm_unit dm_state_content
    mapfile -t enabled_dms < <(detect_enabled_dms)
    if [[ ! -L "$DM_STATE_FILE" && -f "$DM_STATE_FILE" && -r "$DM_STATE_FILE" ]]; then
      dm_state_content="$(cat -- "$DM_STATE_FILE")"
      while IFS= read -r dm_unit || [[ -n "$dm_unit" ]]; do
        [[ -n "$dm_unit" ]] || continue
        local dm_short="${dm_unit%.service}"
        if [[ " ${enabled_dms[*]} " != *" $dm_short "* ]] &&
          [[ "$(systemctl is-enabled "$dm_unit" 2>/dev/null || true)" == "enabled" ]]; then
          enabled_dms+=("$dm_short")
        fi
      done <<<"$dm_state_content"
    fi
    if [[ ${#enabled_dms[@]} -gt 0 ]]; then
      printf 'Display managers: FAIL (%s enabled — disable with: sudo systemctl disable %s.service)\n' "${enabled_dms[*]}" "${enabled_dms[0]}"
      issues=$((issues + 1))
    else
      printf 'Display managers: ok (none enabled)\n'
    fi
  else
    printf 'systemd checks: WARN (systemctl not available)\n'
    warnings=$((warnings + 1))
  fi

  local autologin_out auto_line auto_state="disabled" auto_user="" auto_warnings=() auto_notes=() auto_needs_root=0
  autologin_out="$(env OVERRIDE_DIR="$AUTOLOGIN_DROPIN_DIR" LOGIN_FILE="$LOGIN_FILE" bash "$SCRIPT_DIR/enable-autologin.sh" --status 2>&1 || true)"
  while IFS= read -r auto_line || [[ -n "$auto_line" ]]; do
    [[ -n "$auto_line" ]] || continue
    if [[ "$auto_line" =~ ^enabled\ for\ ([^[:space:]]+)\ \(.*\)$ ]]; then
      auto_state="enabled"
      auto_user="${BASH_REMATCH[1]}"
    elif [[ "$auto_line" == disabled ]]; then
      auto_state="disabled"
    elif [[ "$auto_line" == Warning:\ * ]]; then
      auto_warnings+=("${auto_line#Warning: }")
    elif [[ "$auto_line" == Note:\ * ]]; then
      auto_notes+=("$auto_line")
    fi
  done <<<"$autologin_out"
  if [[ "$auto_state" == disabled ]]; then
    local note_item
    for note_item in "${auto_notes[@]}"; do
      case "$note_item" in
        "Note: cannot read $AUTOLOGIN_DROPIN_DIR;"* | \
          "Note: cannot read $AUTOLOGIN_DROPIN_DIR/lightxdm-autologin.conf;"* | \
          "Note: cannot read $AUTOLOGIN_DROPIN_DIR/override.conf;"*)
          auto_needs_root=1
          break
          ;;
      esac
    done
  fi
  if [[ $auto_needs_root -eq 1 ]]; then
    printf 'Autologin: WARN (%s: unknown (needs root))\n' "$AUTOLOGIN_DROPIN_DIR"
    warnings=$((warnings + 1))
  elif [[ "$auto_state" == enabled ]]; then
    if [[ ${#auto_warnings[@]} -gt 0 ]]; then
      printf 'Autologin: WARN (enabled for %s — %s)\n' "$auto_user" "${auto_warnings[*]}"
      warnings=$((warnings + 1))
    elif [[ -n "$pam_expected" || $keyring_configured -eq 1 ]]; then
      printf 'Autologin: WARN (enabled for %s while PAM keyring is configured; autologin leaves keyring locked — disable with: sudo %s --disable)\n' "$auto_user" "$(script_cmd enable-autologin.sh)"
      warnings=$((warnings + 1))
    else
      printf 'Autologin: ok (enabled for %s)\n' "$auto_user"
    fi
  elif [[ ${#auto_warnings[@]} -gt 0 ]]; then
    printf 'Autologin: WARN (disabled — %s)\n' "${auto_warnings[*]}"
    warnings=$((warnings + 1))
  else
    printf 'Autologin: ok (disabled)\n'
  fi

  if [[ $issues -eq 0 && $warnings -eq 0 ]]; then
    printf 'Doctor: PASS\n'
    return 0
  elif [[ $issues -eq 0 ]]; then
    printf 'Doctor: PASS (0 issue(s), %d warning(s))\n' "$warnings"
    return 0
  elif [[ $warnings -gt 0 ]]; then
    printf 'Doctor: FAIL (%d issue(s), %d warning(s) found above)\n' "$issues" "$warnings"
    return 1
  fi
  printf 'Doctor: FAIL (%d issue(s) found above)\n' "$issues"
  return 1
}

# Recover user session dotfiles and clear boot-loop pauses cleanly without sudo or package changes.
run_recover() {
  local LC_ALL=C target_de="$1" preview="${2:-0}"
  if [[ -z "$target_de" ]]; then
    target_de="$(saved_install_de)" || return 1
  fi
  case "$target_de" in
    plasma | gnome | xfce | lxqt | lxde | mate | cinnamon | budgie | i3) ;;
    *)
      if [[ -z "$target_de" || "$target_de" == *[!abcdefghijklmnopqrstuvwxyz0123456789_-]* ]]; then
        log "Unsupported desktop environment for --recover: $target_de"
        return 1
      fi
      ;;
  esac

  local template
  template="$(xinitrc_template "$target_de")" || return 1
  if [[ ! -f "$template" ]]; then
    log "Missing session template for $target_de: $template"
    log "Create a custom template first with: $(script_cmd install.sh) --init-template --de $target_de"
    return 1
  fi
  check_template_syntax "$template" || return 1
  check_template_not_self "$target_de" "$template" || return 1
  check_session_commands "$template" || return 1

  # Force fresh preservation/restoration semantics in copy_dotfile rather than --update skipping edits.
  local UPDATE_RUN=0
  if [[ $preview -eq 1 ]]; then
    printf 'Recovering lightXDM home session for de=%s (dry run; no files changed)\n' "$target_de"
  else
    log "Recovering lightXDM home session dotfiles for $target_de (preserving any existing originals/edits)..."
  fi
  copy_dotfiles "$target_de" "$preview" || return 1

  local candidate_dot candidate_parent
  for candidate_dot in \
    "$HOME/.bash_profile" "$HOME/.wayland-session" "$HOME/.xinitrc" \
    "$HOME/.gpg-agent-gnome" "$HOME/.gpg-agent-kwallet" \
    "$HOME/.config/autostart/lightxdm-gpg-agent-tty.desktop"; do
    if [[ -e "${candidate_dot}.lightxdm-new" || -L "${candidate_dot}.lightxdm-new" ]]; then
      candidate_parent="${candidate_dot%/*}"
      if [[ -L "$candidate_parent" ]] ||
        { [[ "$candidate_dot" == "$HOME/.config/"* ]] && [[ -L "$HOME/.config" ]]; }; then
        log "WARNING: Refusing to modify ${candidate_dot}.lightxdm-new inside symlinked directory $candidate_parent."
        continue
      fi
      if [[ $preview -eq 1 ]]; then
        printf 'Remove pending update: %s.lightxdm-new\n' "$candidate_dot"
      else
        rm -f -- "${candidate_dot}.lightxdm-new"
      fi
    fi
  done

  local pause_marker="$HOME/.config/lightxdm/no-autostart"
  if [[ -e "$pause_marker" || -L "$pause_marker" ]]; then
    if [[ -L "$HOME/.config" || -L "$HOME/.config/lightxdm" ]]; then
      log "WARNING: Refusing to modify $pause_marker inside a symlinked config directory."
    elif [[ $preview -eq 1 ]]; then
      printf 'Remove auto-start pause marker: %s\n' "$pause_marker"
    else
      rm -f -- "$pause_marker"
      log "Removed auto-start pause marker $pause_marker"
    fi
  fi

  local attempts_file="${XDG_STATE_HOME:-$HOME/.local/state}/lightxdm/startx-attempts"
  if [[ -e "$attempts_file" || -L "$attempts_file" ]]; then
    if [[ -L "${attempts_file%/*}" ]] ||
      { [[ "$attempts_file" == "$HOME/.local/state/"* ]] && [[ -L "$HOME/.local" || -L "$HOME/.local/state" ]]; }; then
      log "WARNING: Refusing to clear $attempts_file inside a symlinked state directory."
    elif [[ $preview -eq 1 ]]; then
      printf 'Clear crash-loop attempt counter: %s\n' "$attempts_file"
    else
      rm -f -- "$attempts_file"
    fi
  fi

  local real_user="${SUDO_USER:-${USER:-}}" login_shell=""
  [[ -n "$real_user" ]] || real_user="$(id -un 2>/dev/null || true)"
  if [[ -n "$real_user" ]] && command -v getent >/dev/null 2>&1; then
    login_shell="$(getent passwd "$real_user" | cut -d: -f7 || true)"
  fi
  case "$login_shell" in
    *zsh)
      if [[ ! -f "$HOME/.zprofile" ]] || ! grep -Eq '\.wayland-session|startx' "$HOME/.zprofile" 2>/dev/null; then
        log "Note: Login shell is $login_shell without a TTY1 trigger in ~/.zprofile; run: $(script_cmd install.sh) --shell-snippet zsh >> ~/.zprofile"
      fi
      ;;
    *fish)
      if [[ ! -f "$HOME/.config/fish/config.fish" ]] || ! grep -Eq '\.wayland-session|startx' "$HOME/.config/fish/config.fish" 2>/dev/null; then
        log "Note: Login shell is $login_shell without a TTY1 trigger in ~/.config/fish/config.fish; run: $(script_cmd install.sh) --shell-snippet fish >> ~/.config/fish/config.fish"
      fi
      ;;
  esac

  if [[ $preview -eq 0 ]]; then
    log "Home recovery complete for $target_de. Run '$(script_cmd install.sh) --doctor' to verify PAM and systemd health."
  fi
}

# Emit the canonical non-bash TTY1 auto-start block cleanly on stdout
print_shell_snippet() {
  case "$1" in
    zsh)
      cat <<'EOF'
if [[ -o interactive && -z $DISPLAY && -z $WAYLAND_DISPLAY && $(tty) == /dev/tty1 && ! -e ~/.config/lightxdm/no-autostart ]]; then
  export PATH="$HOME/.local/bin:$PATH"
  if [[ -f ~/.wayland-session && -x ~/.wayland-session ]]; then
    exec ~/.wayland-session
  elif command -v startx >/dev/null 2>&1; then
    exec startx
  fi
fi
EOF
      ;;
    fish)
      cat <<'EOF'
if status is-login; and status is-interactive; and test -z "$DISPLAY"; and test -z "$WAYLAND_DISPLAY"; and test (tty) = /dev/tty1; and not test -e ~/.config/lightxdm/no-autostart
  set -gx PATH $HOME/.local/bin $PATH
  if test -f ~/.wayland-session; and test -x ~/.wayland-session
    exec ~/.wayland-session
  else if command -q startx
    exec startx
  end
end
EOF
      ;;
    *)
      log "Invalid shell for --shell-snippet: $1 (valid shells: zsh fish)"
      return 1
      ;;
  esac
}

# --- Main ---

main() {
  local UPDATE_SUDO_READY="${UPDATE_SUDO_READY:-0}"
  local display_manager_disabled=0
  local de=""
  local de_specified=0
  local list_only=0
  local dry_run=0
  local non_interactive=0
  local no_packages=0
  local no_keyring=0
  local keyring=""
  local check_keyring=""
  local argument_count=$#
  local no_polkit_rule=0
  local autologin=0
  local update=0
  local status_only=0
  local json_output=0
  local list_sessions=0
  local shell_snippet=""
  local preflight_only=0
  local doctor_only=0
  local recover=0
  local init_template=0
  local wayland=0
  local from_session=""
  local pam_only=0
  local usage="Usage: bash $0 [-h|--help] [--status [--json]] [--list-sessions] [--shell-snippet <zsh|fish>] [--preflight] [--doctor] [--recover [--dry-run] [--de <id>]] [--de <id>] [--list-packages] [--dry-run] [--non-interactive] [--init-template [--wayland] [--from-session <path>]] [--no-packages] [--keyring <gnome|kwallet>] [--check-keyring <gnome|kwallet>] [--no-keyring] [--autologin] [--update] [--pam-only]"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        echo "$usage"
        cat <<'EOF'

Sets up a desktop from a TTY1 login instead of a display manager: X11 desktops start with startx and Plasma, GNOME and Budgie start on Wayland.
A default run, as your regular user, asks for your sudo password up front (again only if the package download outlasts sudo's timeout):
  - installs the packages for the desktop (detected, chosen from a menu, or --de)
  - copies ~/.bash_profile and ~/.xinitrc (or ~/.wayland-session for Wayland sessions), backing up or saving any existing copies
  - appends keyring unlock lines to /etc/pam.d/login (backup at /etc/pam.d/login.lightxdm.bak)
  - for GNOME, adds a TTY1-only PAM line to register the login session as Wayland
  - disables installed display managers (uninstall.sh re-enables them)

Options:
  --de <id>         configure this desktop: plasma gnome xfce lxqt lxde mate cinnamon budgie i3, or a custom
                    id with a ~/.config/lightxdm/.xinitrc-<id> or .wayland-session-<id> template
                    (requires --no-packages; defaults to GNOME Keyring; refuses if both templates exist)
  --list-packages   print the packages for --de <id> and exit; changes nothing
  --dry-run         preview the resolved install for --de <id> and exit; no sudo or file changes
  --non-interactive require --de and fail instead of prompting for sudo credentials
  --init-template   create ~/.config/lightxdm/.xinitrc-<id> (or .wayland-session-<id> for Plasma, GNOME and Budgie) for --de <id> to edit, and exit
                    (any lowercase id: a custom one starts from the i3 template unless --wayland is used)
  --from-session <path> with --init-template --de <custom-id>, use a session entry's Exec and first DesktopNames entry
                    (literal arguments or plain double-quoted words only; no field codes or backslash escapes)
  --wayland         with --init-template --de <custom-id>, create a minimal Wayland template (default command: exec <id>)
  --no-packages     skip package installation
  --keyring <gnome|kwallet> choose the PAM keyring backend for a custom id (requires --no-packages;
                    cannot combine with --no-keyring or --init-template)
  --check-keyring <gnome|kwallet> report the existing collection's state from your desktop session and exit
                    (use alone, without sudo; no service activation or prompts; 0=unlocked, 1=locked, 2=unavailable)
  --no-keyring      skip keyring packages and keyring PAM lines (use with autologin)
  --autologin       also log in on TTY1 without a password (requires --no-keyring)
  --update          apply a newer lightXDM to the last finished install with its saved choices, changing
                    only what lightXDM installed and you left as it was: edited dotfiles stay (the template
                    goes beside them as *.lightxdm-new), removed packages stay removed, display managers you
                    enabled stay enabled, PAM lines you removed stay removed (ones a .pacnew merge removed
                    come back); autologin stays as it is (combinable with --dry-run and --non-interactive)
  --pam-only        only add lightXDM's lines for --de <id> to /etc/pam.d/login (keyring unlock, and GNOME's
                    session-type block); no packages, dotfiles, display managers or saved choices change
                    (with --no-keyring, only GNOME's block)
  --status          show the current lightXDM configuration, dotfile state, PAM state, disabled display
                    managers and TTY1 autologin status without sudo or changes (use alone, or with --json)
  --json            with --status, print the read-only status summary as structured JSON on stdout
  --list-sessions   scan installed X11 and Wayland session entries, check executables, and suggest
                    --init-template --from-session commands without sudo or changes (use alone)
  --shell-snippet <zsh|fish> print the non-bash TTY1 auto-start block for ~/.zprofile or ~/.config/fish/config.fish
                    without sudo or changes (use alone)
  --preflight       check user/sudo, pacman/systemctl, getty@tty1.service, display managers, login shell,
                    and installed desktops without sudo or changes, then suggest the next command (use alone)
  --doctor          verify post-install session launcher, shell hooks, PAM keyring/GNOME rules, .pacnew drift,
                    and systemd boot health without sudo or changes, with fix commands (use alone)
  --recover         restore broken or paused home session dotfiles from validated templates without sudo or
                    package/PAM/systemd changes, saving any edits as *.lightxdm-edited* and clearing
                    ~/.config/lightxdm/no-autostart (optional --dry-run and --de <id>)

uninstall.sh reverts these changes; installed packages stay.
EOF
        exit 0
        ;;
      --list-packages)
        list_only=1
        shift
        ;;
      --list-sessions)
        list_sessions=1
        shift
        ;;
      --preflight)
        preflight_only=1
        shift
        ;;
      --doctor)
        doctor_only=1
        shift
        ;;
      --shell-snippet)
        if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
          log "Missing argument for --shell-snippet (valid shells: zsh fish)"
          echo "$usage" >&2
          exit 1
        fi
        case "$2" in
          zsh | fish) shell_snippet="$2" ;;
          *)
            log "Invalid shell for --shell-snippet: $2 (valid shells: zsh fish)"
            exit 1
            ;;
        esac
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --non-interactive)
        non_interactive=1
        shift
        ;;
      --no-packages)
        no_packages=1
        shift
        ;;
      --no-keyring)
        no_keyring=1
        shift
        ;;
      --keyring)
        if [[ $# -lt 2 || "$2" == -* ]]; then
          log "Missing argument for --keyring (valid backends: gnome kwallet)"
          echo "$usage" >&2
          exit 1
        fi
        case "$2" in
          gnome | kwallet) keyring="$2" ;;
          *)
            log "Invalid keyring backend: $2 (valid backends: gnome kwallet)"
            exit 1
            ;;
        esac
        shift 2
        ;;
      --check-keyring)
        if [[ $# -lt 2 || "$2" == -* ]]; then
          log "Missing argument for --check-keyring (valid backends: gnome kwallet)"
          echo "$usage" >&2
          exit 1
        fi
        case "$2" in
          gnome | kwallet) check_keyring="$2" ;;
          *)
            log "Invalid keyring backend: $2 (valid backends: gnome kwallet)"
            exit 1
            ;;
        esac
        shift 2
        ;;
      --no-polkit-rule)
        no_polkit_rule=1
        shift
        ;;
      --autologin)
        autologin=1
        shift
        ;;
      --update)
        update=1
        shift
        ;;
      --recover)
        recover=1
        shift
        ;;
      --status)
        status_only=1
        shift
        ;;
      --pam-only)
        pam_only=1
        shift
        ;;
      --init-template)
        init_template=1
        shift
        ;;
      --wayland)
        wayland=1
        shift
        ;;
      --json)
        json_output=1
        shift
        ;;
      --from-session)
        if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
          log "Missing argument for --from-session"
          echo "$usage" >&2
          exit 1
        fi
        from_session="$2"
        shift 2
        ;;
      --de)
        if [[ $# -lt 2 || "$2" == -* ]]; then
          log "Missing argument for --de (valid ids: plasma gnome xfce lxqt lxde mate cinnamon budgie i3)"
          echo "$usage" >&2
          exit 1
        fi
        de="$2"
        de_specified=1
        shift 2
        ;;
      *)
        log "Unknown option: $1"
        echo "$usage" >&2
        exit 1
        ;;
    esac
  done

  if [[ $json_output -eq 1 && $status_only -eq 0 ]]; then
    log "--json requires --status."
    echo "$usage" >&2
    exit 1
  fi

  if [[ $status_only -eq 1 ]]; then
    if [[ $de_specified -eq 1 || $list_only -eq 1 || $list_sessions -eq 1 || -n "$shell_snippet" ||
      $preflight_only -eq 1 || $doctor_only -eq 1 || $recover -eq 1 || $dry_run -eq 1 || $non_interactive -eq 1 || $no_packages -eq 1 ||
      $no_keyring -eq 1 || -n "$keyring" || -n "$check_keyring" || $no_polkit_rule -eq 1 ||
      $autologin -eq 1 || $update -eq 1 || $init_template -eq 1 || $wayland -eq 1 ||
      -n "$from_session" || $pam_only -eq 1 ]]; then
      log "--status cannot be combined with any other option."
      echo "$usage" >&2
      exit 1
    fi
    if [[ $json_output -eq 1 ]]; then
      show_install_status --json
    else
      show_install_status
    fi
    return 0
  fi

  if [[ $list_sessions -eq 1 ]]; then
    if [[ $de_specified -eq 1 || $list_only -eq 1 || -n "$shell_snippet" || $preflight_only -eq 1 || $doctor_only -eq 1 || $recover -eq 1 ||
      $dry_run -eq 1 || $non_interactive -eq 1 || $no_packages -eq 1 || $no_keyring -eq 1 ||
      -n "$keyring" || -n "$check_keyring" || $no_polkit_rule -eq 1 || $autologin -eq 1 ||
      $update -eq 1 || $status_only -eq 1 || $json_output -eq 1 || $init_template -eq 1 ||
      $wayland -eq 1 || -n "$from_session" || $pam_only -eq 1 ]]; then
      log "--list-sessions cannot be combined with any other option."
      echo "$usage" >&2
      exit 1
    fi
    list_desktop_sessions
    return 0
  fi

  if [[ -n "$shell_snippet" ]]; then
    if [[ $argument_count -ne 2 ]]; then
      log "--shell-snippet cannot be combined with any other option."
      echo "$usage" >&2
      exit 1
    fi
    print_shell_snippet "$shell_snippet"
    return 0
  fi

  if [[ $preflight_only -eq 1 ]]; then
    if [[ $argument_count -ne 1 ]]; then
      log "--preflight cannot be combined with any other option."
      echo "$usage" >&2
      exit 1
    fi
    local preflight_status=0
    run_preflight || preflight_status=$?
    return "$preflight_status"
  fi

  if [[ $doctor_only -eq 1 ]]; then
    if [[ $argument_count -ne 1 ]]; then
      log "--doctor cannot be combined with any other option."
      echo "$usage" >&2
      exit 1
    fi
    local doctor_status=0
    run_doctor || doctor_status=$?
    return "$doctor_status"
  fi

  if [[ $recover -eq 1 ]]; then
    if [[ $list_only -eq 1 || $list_sessions -eq 1 || -n "$shell_snippet" || $preflight_only -eq 1 ||
      $doctor_only -eq 1 || $non_interactive -eq 1 || $no_packages -eq 1 || $no_keyring -eq 1 ||
      -n "$keyring" || -n "$check_keyring" || $no_polkit_rule -eq 1 || $autologin -eq 1 ||
      $update -eq 1 || $init_template -eq 1 || $wayland -eq 1 || -n "$from_session" ||
      $pam_only -eq 1 || $status_only -eq 1 || $json_output -eq 1 ]]; then
      log "--recover takes only optional --dry-run and --de <id>."
      echo "$usage" >&2
      exit 1
    fi
    if [[ $de_specified -eq 1 && -z "$de" ]]; then
      log "--de requires a desktop id."
      echo "$usage" >&2
      exit 1
    fi
    if [[ $EUID -eq 0 && $dry_run -eq 0 ]]; then
      log "Do not run --recover as root or with sudo; run it as the user who logs in."
      exit 1
    fi
    local recover_status=0
    run_recover "$de" "$dry_run" || recover_status=$?
    return "$recover_status"
  fi

  if [[ $update -eq 1 ]]; then
    if [[ $de_specified -eq 1 || $list_only -eq 1 || $list_sessions -eq 1 || -n "$shell_snippet" ||
      $preflight_only -eq 1 || $doctor_only -eq 1 || $recover -eq 1 || $no_packages -eq 1 || $no_keyring -eq 1 || -n "$keyring" ||
      -n "$check_keyring" || $no_polkit_rule -eq 1 || $autologin -eq 1 || $init_template -eq 1 ||
      $wayland -eq 1 || -n "$from_session" || $pam_only -eq 1 || $status_only -eq 1 ||
      $json_output -eq 1 ]]; then
      log "--update reuses the saved choices and takes only --dry-run and --non-interactive; to change a choice, run $(script_cmd install.sh) with its options."
      exit 1
    fi
    if [[ $dry_run -eq 0 ]]; then
      check_root || exit $?
    fi
    saved_install_de >/dev/null || exit 1
    if [[ $dry_run -eq 0 ]] && {
      pam_path_needs_sudo "$LOGIN_FILE" 0 ||
        pam_path_needs_sudo "${LOGIN_FILE}.lightxdm.bak" 1 ||
        pam_path_needs_sudo "$PAM_KEYRING_STATE" 1 ||
        pam_path_needs_sudo "$PAM_LOGIN_BASE_STATE" 1
    }; then
      authenticate_sudo "$non_interactive"
      UPDATE_SUDO_READY=1
    fi
    start_update_run "$dry_run"
    local saved_output saved_args=()
    saved_output="$(saved_install_args "$dry_run")" || exit 1
    mapfile -t saved_args <<<"$saved_output"
    if [[ $dry_run -eq 1 ]]; then
      saved_args+=(--dry-run)
    fi
    if [[ $non_interactive -eq 1 ]]; then
      saved_args+=(--non-interactive)
    fi
    log "Updating with the saved choices: ${saved_args[*]}"
    main "${saved_args[@]}"
    return
  fi
  if [[ -n "$check_keyring" ]]; then
    if [[ $argument_count -ne 2 ]]; then
      log "--check-keyring cannot be combined with any other option."
      exit 1
    fi
    if [[ $EUID -eq 0 ]]; then
      log "Do not run --check-keyring as root or with sudo; run it in the desktop user's session."
      exit 1
    fi
    local check_status=0
    check_keyring_unlocked "$check_keyring" || check_status=$?
    exit "$check_status"
  fi

  if [[ -n "$from_session" ]]; then
    if [[ $init_template -eq 0 || $de_specified -eq 0 || -z "$de" ]]; then
      log "--from-session requires --init-template --de <custom-id>."
      echo "$usage" >&2
      exit 1
    fi
    case "$de" in
      plasma | gnome | budgie | xfce | lxqt | lxde | mate | cinnamon | i3)
        log "--from-session is only for custom ids; $de has a built-in template."
        exit 1
        ;;
    esac
  fi

  if [[ $wayland -eq 1 && $init_template -eq 0 ]]; then
    log "--wayland requires --init-template --de <custom-id>."
    echo "$usage" >&2
    exit 1
  fi

  if [[ $autologin -eq 1 && $no_keyring -eq 0 ]]; then
    log "--autologin requires --no-keyring: autologin passes no password, so PAM cannot unlock the keyring."
    echo "$usage" >&2
    exit 1
  fi

  if [[ $pam_only -eq 1 ]]; then
    if [[ $autologin -eq 1 || $list_only -eq 1 || $init_template -eq 1 ]]; then
      log "--pam-only changes only $LOGIN_FILE and cannot be combined with --autologin, --list-packages or --init-template."
      echo "$usage" >&2
      exit 1
    fi
    if [[ $de_specified -eq 0 ]]; then
      log "--pam-only requires --de <id>"
      echo "$usage" >&2
      exit 1
    fi
    # A PAM-only run installs no packages (custom ids need --no-packages anyway).
    no_packages=1
  fi

  if [[ $init_template -eq 1 ]]; then
    if [[ $list_only -eq 1 || $dry_run -eq 1 || $non_interactive -eq 1 || $no_packages -eq 1 || $no_keyring -eq 1 || -n "$keyring" || $no_polkit_rule -eq 1 || $autologin -eq 1 ]]; then
      log "--init-template takes only --de <id> and optional --wayland and --from-session <path> for custom ids; it creates the template and exits without installing."
      echo "$usage" >&2
      exit 1
    fi
    if [[ $de_specified -eq 0 ]]; then
      log "--init-template requires --de <id>"
      echo "$usage" >&2
      exit 1
    fi
    # The template belongs in the desktop user's home, not root's.
    if [[ $EUID -eq 0 ]]; then
      log "Do not run --init-template as root or with sudo; run it as the user who will log in."
      exit 1
    fi
    init_xinitrc_template "$de" "$wayland" "$from_session"
    exit $?
  fi

  if [[ -n "$keyring" ]]; then
    if [[ $no_keyring -eq 1 ]]; then
      log "--keyring cannot be combined with --no-keyring."
      exit 1
    fi
    if [[ $de_specified -eq 0 ]]; then
      log "--keyring requires --de <custom-id>."
      exit 1
    fi
    case "$de" in
      plasma | gnome | xfce | lxqt | lxde | mate | cinnamon | budgie | i3)
        log "--keyring is only for custom ids; $de already has a keyring backend."
        exit 1
        ;;
    esac
  fi

  if [[ $non_interactive -eq 1 && $de_specified -eq 0 ]]; then
    log "--non-interactive requires --de <id>"
    echo "$usage" >&2
    exit 1
  fi

  if [[ $no_polkit_rule -eq 1 ]]; then
    log "--no-polkit-rule is no longer needed: lightXDM does not install a Polkit rule."
  fi

  if [[ $dry_run -eq 1 ]]; then
    if [[ $de_specified -eq 0 ]]; then
      log "--dry-run requires --de <id>"
      echo "$usage" >&2
      exit 1
    fi
    if [[ $list_only -eq 1 ]]; then
      log "Use either --dry-run or --list-packages."
      exit 1
    fi
  fi

  if [[ $list_only -eq 1 ]]; then
    if [[ $de_specified -eq 0 ]]; then
      log "--list-packages requires --de <id> (valid ids: plasma gnome xfce lxqt lxde mate cinnamon budgie i3)"
      echo "$usage" >&2
      exit 1
    fi
    case "$de" in
      plasma | gnome | xfce | lxqt | lxde | mate | cinnamon | budgie | i3)
        if [[ $no_keyring -eq 1 ]]; then
          list_packages "$de" --no-keyring
        else
          list_packages "$de"
        fi
        exit 0
        ;;
      *)
        log "Unsupported desktop environment: $de; --list-packages requires a built-in desktop id (valid ids: plasma gnome xfce lxqt lxde mate cinnamon budgie i3)"
        exit 1
        ;;
    esac
  fi

  if [[ $de_specified -eq 1 ]]; then
    case "$de" in
      plasma | gnome | xfce | lxqt | lxde | mate | cinnamon | budgie | i3) ;;
      *)
        # Explicit character list: [a-z] ranges miss "i" under some locales (for example tr_TR).
        local custom_template=""
        if [[ -n "$de" && "$de" != *[!abcdefghijklmnopqrstuvwxyz0123456789_-]* ]]; then
          custom_template="$(xinitrc_template "$de")" || exit 1
        fi
        if [[ $no_packages -ne 1 || -z "$de" || "$de" == *[!abcdefghijklmnopqrstuvwxyz0123456789_-]* || ! -f "$custom_template" ]]; then
          log "Unsupported desktop environment: $de (valid ids: plasma gnome xfce lxqt lxde mate cinnamon budgie i3)"
          if [[ -n "$de" && "$de" != *[!abcdefghijklmnopqrstuvwxyz0123456789_-]* ]]; then
            if [[ ! -f "$custom_template" ]]; then
              log "For a custom session, create its template first: $(script_cmd install.sh) --init-template --de $de"
            else
              log "Custom sessions need --no-packages (install their packages yourself): $(script_cmd install.sh) --no-packages --de $de"
            fi
          fi
          exit 1
        fi
        ;;
    esac
  fi

  if [[ $dry_run -eq 1 ]]; then
    if [[ $pam_only -eq 1 ]]; then
      preview_pam_only "$de" "$no_keyring" "$keyring"
    else
      preview_install "$de" "$no_packages" "$no_keyring" "$autologin" "$keyring"
    fi
    return $?
  fi

  local real_user
  real_user="${USER:-$(id -un)}"
  if [[ $UPDATE_SUDO_READY -ne 1 ]]; then
    check_root
    authenticate_sudo "$non_interactive" "$real_user"
  fi

  if [[ -z "$de" ]]; then
    local detected_output detected_des=()
    detected_output="$(detect_de)"
    if [[ -n "$detected_output" ]]; then
      mapfile -t detected_des <<<"$detected_output"
    fi

    if [[ ${#detected_des[@]} -le 1 ]]; then
      de="${detected_des[0]:-unknown}"
      if [[ "$de" == "unknown" ]]; then
        de=$(prompt_de_selection) || {
          local menu_rc=$?
          if [[ $menu_rc -eq 2 ]]; then
            exit 0
          fi
          log "No desktop environment was chosen. Pass --de <id> to select one (plasma, gnome, budgie, xfce, lxqt, lxde, mate, cinnamon, i3). Exiting."
          exit 1
        }
      else
        log "Detected desktop environment: $de"
      fi
    else
      local candidate supported_des=()
      for candidate in "${detected_des[@]}"; do
        case "$candidate" in
          unknown | "") ;;
          *)
            supported_des+=("$candidate")
            ;;
        esac
      done

      if [[ ${#supported_des[@]} -eq 0 ]]; then
        de="${detected_des[0]}"
        log "Detected desktop environment: $de"
      else
        if [[ ${#supported_des[@]} -eq 1 ]]; then
          de="${supported_des[0]}"
          log "Detected desktop environment: $de"
        else
          de=$(prompt_detected_de_selection "${supported_des[@]}") || {
            local menu_rc=$?
            if [[ $menu_rc -eq 2 ]]; then
              exit 0
            fi
            log "No desktop environment was chosen. Pass --de <id> to select one (detected: ${supported_des[*]}). Exiting."
            exit 1
          }
        fi
      fi
    fi
  fi

  if [[ $pam_only -eq 1 ]]; then
    if [[ $no_keyring -eq 1 ]]; then
      log "Skipping keyring PAM configuration (--no-keyring)."
    else
      configure_pam "$de" 0 "$keyring"
    fi
    configure_gnome_session_type "$de" "$real_user"
    log "Done (--pam-only): only $LOGIN_FILE and GNOME's session-type file were set up; packages, dotfiles, display managers and saved choices are unchanged."
    return 0
  fi

  local template is_wayland=0 session_dotfile=".xinitrc" manual_start="startx"
  template="$(xinitrc_template "$de")"
  install_step="check_template_syntax"
  check_template_syntax "$template" || exit 1
  install_step="check_tty1_getty"
  check_tty1_getty || exit 1
  if [[ "${template##*/}" == .wayland-session-* ]]; then
    is_wayland=1
    session_dotfile=".wayland-session"
    # shellcheck disable=SC2088  # shown to the user as text, never expanded
    manual_start="~/.wayland-session"
  fi
  if [[ ! -f "$template" ]]; then
    if [[ $is_wayland -eq 1 ]]; then
      log "No Wayland session template for $de: $template. Installation aborted."
    else
      log "No .xinitrc template for $de: $template. Installation aborted."
    fi
    exit 1
  fi
  check_template_not_self "$de" "$template" || exit 1

  # Globals, not locals: the EXIT trap runs after main's locals are gone.
  install_step=""
  completed_steps=()
  # shellcheck disable=SC2154  # install_status is assigned inside the trap string
  trap '
    install_status=$?
    if [[ $install_status -ne 0 && -n "${install_step:-}" ]]; then
      log "Install stopped during $install_step; already done: ${completed_steps[*]:-none}"
      log "After fixing the error, rerunning install.sh is safe; uninstall.sh reverts configuration changes (installed packages stay)."
    fi
    exit "$install_status"
  ' EXIT

  RECORDED_PACKAGES=()
  if [[ $no_packages -eq 1 ]]; then
    log "Skipping package installation (--no-packages)."
  else
    install_step="install_packages"
    if [[ $no_keyring -eq 1 ]]; then
      install_packages "$de" --no-keyring
    else
      install_packages "$de"
    fi
    completed_steps+=("$install_step")
  fi
  install_step="check_session_commands"
  check_session_commands "$template" || exit 1
  install_step="copy_dotfiles"
  copy_dotfiles "$de"
  completed_steps+=("$install_step")
  local login_shell shell_profile="" shell_hint="docs/startx-autologin.md"
  login_shell="$(getent passwd "$real_user" | cut -d: -f7 || true)"
  if [[ -n "$login_shell" && "$login_shell" != *bash ]]; then
    case "$login_shell" in
      *zsh)
        shell_profile=".zprofile"
        shell_hint="run '$(script_cmd install.sh) --shell-snippet zsh' or see docs/startx-autologin.md"
        ;;
      *fish)
        shell_profile=".config/fish/config.fish"
        shell_hint="run '$(script_cmd install.sh) --shell-snippet fish' or see docs/startx-autologin.md"
        ;;
      *)
        shell_profile=".profile"
        shell_hint="see docs/startx-autologin.md"
        ;;
    esac
    log "WARNING: Login shell for $real_user is $login_shell, which does not read ~/.bash_profile. Add the TTY1 auto-start block to ~/$shell_profile ($shell_hint)."
  fi
  if [[ $no_keyring -eq 1 ]]; then
    log "Skipping keyring PAM configuration (--no-keyring)."
  else
    install_step="configure_pam"
    configure_pam "$de" 0 "$keyring"
    completed_steps+=("$install_step")
  fi
  install_step="configure_gnome_session_type"
  configure_gnome_session_type "$de" "$real_user"
  completed_steps+=("$install_step")
  install_step="disable_display_managers"
  disable_display_managers
  completed_steps+=("$install_step")
  if [[ $autologin -eq 1 ]]; then
    install_step="enable_autologin"
    enable_autologin "$real_user"
    completed_steps+=("$install_step")
  fi

  local unlock_summary="Auto-unlock is set"
  local test_summary="Reboot or log out to test"
  local test_summary_after_then="reboot or log out to test"
  if [[ $display_manager_disabled -eq 1 ]]; then
    test_summary="Reboot to test (the disabled display manager keeps running until then, so logging out returns to it)"
    test_summary_after_then="reboot to test (the disabled display manager keeps running until then, so logging out returns to it)"
  fi
  if [[ $no_keyring -eq 1 ]]; then
    unlock_summary="Keyring setup skipped"
  fi

  if [[ $autologin -eq 1 ]]; then
    unlock_summary+="; TTY1 autologin is enabled (sudo $(script_cmd enable-autologin.sh) --disable reverts it)"
  fi

  trap - EXIT
  save_install_choices "$de" "$no_packages" "${RECORDED_PACKAGES[@]}"
  if [[ -z "$shell_profile" && -e "$HOME/.config/lightxdm/no-autostart" ]]; then
    cat <<EOF

lightXDM install complete!
- $de is configured in ~/$session_dotfile for $real_user
- $unlock_summary
- Desktop auto-start on TTY1 stays paused because ~/.config/lightxdm/no-autostart exists

Run 'rm ~/.config/lightxdm/no-autostart' to start $de automatically at the next TTY1 login, then $test_summary_after_then.
EOF
  elif [[ -z "$shell_profile" && $is_wayland -eq 1 ]]; then
    cat <<EOF

lightXDM install complete!
- $de will auto-start on TTY1 for $real_user
- $unlock_summary
- $test_summary

On next boot, after logging in, your desktop environment will start automatically on TTY1.
EOF
  elif [[ -z "$shell_profile" ]]; then
    cat <<EOF

lightXDM install complete!
- $de will auto-start on TTY1 for $real_user
- $unlock_summary
- $test_summary

On next boot, after logging in, your desktop environment will start automatically on TTY1. No need to run 'startx'.
EOF
  else
    cat <<EOF

lightXDM install complete!
- $de is configured in ~/$session_dotfile for $real_user (auto-start requires ~/$shell_profile)
- $unlock_summary
- Add the TTY1 auto-start block to ~/$shell_profile ($shell_hint), then $test_summary_after_then

Your login shell ($login_shell) does not read ~/.bash_profile, so $de will not auto-start on TTY1 until you add the auto-start block to ~/$shell_profile (or run '$manual_start' manually).
EOF
  fi

  if [[ "$de" == gnome ]]; then
    log "WARNING: GNOME cannot lock the screen without GDM (see README.md, Before you install)."
  fi
}

# Run only when executed directly, so tests can source the functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
