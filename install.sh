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
  if [[ -n "${SESSION_PREVIEW_TEMPLATE:-}" ]]; then
    printf '%s\n' "$SESSION_PREVIEW_TEMPLATE"
    return 0
  fi
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
  local LC_ALL=C json_mode=0
  [[ "${1:-}" == "--json" ]] && json_mode=1

  local xsessions_dir="${XSESSIONS_DIR:-${SESSION_ROOT:-}/usr/share/xsessions}"
  local wayland_dir="${WAYLAND_SESSIONS_DIR:-${SESSION_ROOT:-}/usr/share/wayland-sessions}"
  local xdg_data_dir="" user_xsessions_dir="${USER_XSESSIONS_DIR:-}" user_wayland_dir="${USER_WAYLAND_SESSIONS_DIR:-}"
  if [[ -z "${SESSION_ROOT:-}" && -z "${XSESSIONS_DIR:-}" && -z "${WAYLAND_SESSIONS_DIR:-}" ]]; then
    if [[ -n "${XDG_DATA_HOME:-}" ]]; then
      xdg_data_dir="${XDG_DATA_HOME%/}"
      [[ -n "$xdg_data_dir" ]] || xdg_data_dir="/"
    elif [[ -n "${HOME:-}" ]]; then
      xdg_data_dir="${HOME%/}/.local/share"
    fi
    if [[ -n "$xdg_data_dir" ]]; then
      [[ -n "$user_xsessions_dir" ]] || user_xsessions_dir="${xdg_data_dir%/}/xsessions"
      [[ -n "$user_wayland_dir" ]] || user_wayland_dir="${xdg_data_dir%/}/wayland-sessions"
    fi
  fi
  [[ "$user_xsessions_dir" == "$xsessions_dir" ]] && user_xsessions_dir=""
  [[ "$user_wayland_dir" == "$wayland_dir" ]] && user_wayland_dir=""

  local scan_types=() scan_scopes=() scan_dirs=() checked_dirs=()
  if [[ -n "$xsessions_dir" ]]; then
    scan_types+=(x11)
    scan_scopes+=(system)
    scan_dirs+=("$xsessions_dir")
    checked_dirs+=("$xsessions_dir")
  fi
  if [[ -n "$user_xsessions_dir" ]]; then
    scan_types+=(x11)
    scan_scopes+=(user)
    scan_dirs+=("$user_xsessions_dir")
    checked_dirs+=("$user_xsessions_dir")
  fi
  if [[ -n "$wayland_dir" ]]; then
    scan_types+=(wayland)
    scan_scopes+=(system)
    scan_dirs+=("$wayland_dir")
    checked_dirs+=("$wayland_dir")
  fi
  if [[ -n "$user_wayland_dir" ]]; then
    scan_types+=(wayland)
    scan_scopes+=(user)
    scan_dirs+=("$user_wayland_dir")
    checked_dirs+=("$user_wayland_dir")
  fi

  local idx session_type scope dir entry label raw_stem suggested_id status_note init_cmd install_session_cmd existing_tmpl
  local found=0 ready_count=0
  local dir_exists_json dir_readable_json dir_json entry_json
  local entry_valid entry_ready entry_status entry_error exec_value missing_cmd builtin_id tmpl_exists_json
  local dir_entries_json=() session_entries_json=() warnings_list=()
  local SESSION_ENTRY_NAME="" SESSION_ENTRY_EXEC_LINE="" SESSION_ENTRY_EXEC_CMD=""
  local SESSION_ENTRY_DESKTOP="" SESSION_ENTRY_TRY_EXEC=""
  local SESSION_ENTRY_HIDDEN=0 SESSION_ENTRY_NO_DISPLAY=0 SESSION_ENTRY_ERROR=""

  for ((idx = 0; idx < ${#scan_dirs[@]}; idx++)); do
    session_type="${scan_types[$idx]}"
    scope="${scan_scopes[$idx]}"
    dir="${scan_dirs[$idx]}"
    dir_exists_json="false"
    dir_readable_json="false"
    if [[ -d "$dir" ]]; then
      dir_exists_json="true"
      if [[ -r "$dir" && -x "$dir" ]]; then
        dir_readable_json="true"
      else
        if [[ $json_mode -eq 1 ]]; then
          warnings_list+=("cannot read session directory $dir.")
        else
          log "Note: cannot read session directory $dir."
        fi
      fi
    fi
    if [[ $json_mode -eq 1 ]]; then
      printf -v dir_json '{"session_type": %s, "scope": %s, "path": %s, "exists": %s, "readable": %s}' \
        "$(json_str "$session_type")" "$(json_str "$scope")" "$(json_str "$dir")" \
        "$dir_exists_json" "$dir_readable_json"
      dir_entries_json+=("$dir_json")
    fi
    [[ "$dir_readable_json" == true ]] || continue

    for entry in "$dir"/*.desktop; do
      [[ -e "$entry" || -L "$entry" ]] || continue
      SESSION_ENTRY_NAME=""
      SESSION_ENTRY_EXEC_LINE=""
      SESSION_ENTRY_EXEC_CMD=""
      SESSION_ENTRY_DESKTOP=""
      SESSION_ENTRY_TRY_EXEC=""
      SESSION_ENTRY_HIDDEN=0
      SESSION_ENTRY_NO_DISPLAY=0
      SESSION_ENTRY_ERROR=""

      raw_stem="${entry##*/}"
      raw_stem="${raw_stem%.desktop}"
      raw_stem="$(printf '%s' "$raw_stem" | LC_ALL=C tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')"
      builtin_id=""
      exec_value=""
      missing_cmd=""
      entry_error=""
      init_cmd=""
      install_session_cmd=""
      existing_tmpl=""
      tmpl_exists_json="false"

      if parse_desktop_session_entry "$entry"; then
        [[ $SESSION_ENTRY_HIDDEN -eq 0 && $SESSION_ENTRY_NO_DISPLAY -eq 0 ]] || continue
        found=$((found + 1))
        entry_valid="true"
        exec_value="${SESSION_ENTRY_EXEC_LINE#exec }"
        label="${SESSION_ENTRY_NAME:-${entry##*/}}"
        suggested_id="$(suggest_custom_session_id "$entry")"
        if [[ -n "$SESSION_ENTRY_TRY_EXEC" ]] && ! session_command_exists "$SESSION_ENTRY_TRY_EXEC"; then
          entry_ready="false"
          entry_status="unavailable"
          missing_cmd="$SESSION_ENTRY_TRY_EXEC"
          entry_error="missing TryExec: $SESSION_ENTRY_TRY_EXEC"
          status_note="unavailable ($entry_error)"
        elif ! session_command_exists "$SESSION_ENTRY_EXEC_CMD"; then
          entry_ready="false"
          entry_status="unavailable"
          missing_cmd="$SESSION_ENTRY_EXEC_CMD"
          entry_error="missing command: $SESSION_ENTRY_EXEC_CMD"
          status_note="unavailable ($entry_error)"
        else
          entry_ready="true"
          entry_status="ready"
          ready_count=$((ready_count + 1))
          status_note="ready"
        fi
        if [[ "$session_type" == wayland ]]; then
          existing_tmpl="$HOME/.config/lightxdm/.wayland-session-$suggested_id"
          if [[ "$entry_ready" == true ]]; then
            printf -v init_cmd '%s --init-template --wayland --de %q --from-session %q' \
              "$(script_cmd install.sh)" "$suggested_id" "$entry"
            printf -v install_session_cmd '%s --install-session %q --wayland' \
              "$(script_cmd install.sh)" "$entry"
          fi
        else
          existing_tmpl="$HOME/.config/lightxdm/.xinitrc-$suggested_id"
          if [[ "$entry_ready" == true ]]; then
            printf -v init_cmd '%s --init-template --de %q --from-session %q' \
              "$(script_cmd install.sh)" "$suggested_id" "$entry"
            printf -v install_session_cmd '%s --install-session %q' \
              "$(script_cmd install.sh)" "$entry"
          fi
        fi
        case "$raw_stem" in
          plasma | gnome | budgie | xfce | lxqt | lxde | mate | cinnamon | i3)
            builtin_id="$raw_stem"
            status_note+="; built-in: --de $raw_stem"
            ;;
        esac
        if [[ -n "$SESSION_ENTRY_DESKTOP" ]]; then
          status_note+="; desktop: $SESSION_ENTRY_DESKTOP"
        fi
        if [[ "$scope" == user ]]; then
          status_note+="; scope: user"
        fi
        if [[ -e "$existing_tmpl" || -L "$existing_tmpl" ]]; then
          tmpl_exists_json="true"
          status_note+="; template exists: $existing_tmpl"
        fi
        if [[ $json_mode -eq 0 ]]; then
          printf '[%s] %s (%s) — %s\n' "$session_type" "$label" "$entry" "$status_note"
          if [[ "$status_note" == ready* ]]; then
            printf '  init: %s\n' "$init_cmd"
          fi
        fi
      else
        [[ $SESSION_ENTRY_HIDDEN -eq 0 && $SESSION_ENTRY_NO_DISPLAY -eq 0 ]] || continue
        found=$((found + 1))
        entry_valid="false"
        entry_ready="false"
        entry_status="unsupported"
        label="${SESSION_ENTRY_NAME:-${entry##*/}}"
        suggested_id=""
        status_note="${SESSION_ENTRY_ERROR%: "$entry"}"
        entry_error="$status_note"
        if [[ $json_mode -eq 0 ]]; then
          if [[ "$scope" == user ]]; then
            printf '[%s] %s (%s) — unsupported (%s; scope: user)\n' "$session_type" "$label" "$entry" "$status_note"
          else
            printf '[%s] %s (%s) — unsupported (%s)\n' "$session_type" "$label" "$entry" "$status_note"
          fi
        fi
      fi

      if [[ $json_mode -eq 1 ]]; then
        printf -v entry_json '{"session_type": %s, "scope": %s, "file": %s, "name": %s, "stem": %s, "valid": %s, "ready": %s, "status": %s, "error": %s, "exec": %s, "try_exec": %s, "desktop_names": %s, "missing_command": %s, "builtin_id": %s, "suggested_id": %s, "template_path": %s, "template_exists": %s, "suggested_init_command": %s, "suggested_install_command": %s}' \
          "$(json_str "$session_type")" \
          "$(json_str "$scope")" \
          "$(json_str "$entry")" \
          "$(json_str "$label")" \
          "$(json_str "$raw_stem")" \
          "$entry_valid" \
          "$entry_ready" \
          "$(json_str "$entry_status")" \
          "$(json_str_or_null "$entry_error")" \
          "$(json_str_or_null "$exec_value")" \
          "$(json_str_or_null "$SESSION_ENTRY_TRY_EXEC")" \
          "$(json_str_or_null "$SESSION_ENTRY_DESKTOP")" \
          "$(json_str_or_null "$missing_cmd")" \
          "$(json_str_or_null "$builtin_id")" \
          "$(json_str_or_null "$suggested_id")" \
          "$(json_str_or_null "$existing_tmpl")" \
          "$tmpl_exists_json" \
          "$(json_str_or_null "$init_cmd")" \
          "$(json_str_or_null "$install_session_cmd")"
        session_entries_json+=("$entry_json")
      fi
    done
  done

  if [[ $json_mode -eq 1 ]]; then
    printf '{\n'
    printf '  "mode": "list-sessions",\n'
    printf '  "count": %d,\n' "$found"
    printf '  "ready_count": %d,\n' "$ready_count"
    printf '  "directories": [\n'
    for ((idx = 0; idx < ${#dir_entries_json[@]}; idx++)); do
      if [[ $idx -gt 0 ]]; then
        printf ',\n'
      fi
      printf '    %s' "${dir_entries_json[$idx]}"
    done
    if [[ ${#dir_entries_json[@]} -gt 0 ]]; then
      printf '\n'
    fi
    printf '  ],\n'
    printf '  "sessions": [\n'
    for ((idx = 0; idx < ${#session_entries_json[@]}; idx++)); do
      if [[ $idx -gt 0 ]]; then
        printf ',\n'
      fi
      printf '    %s' "${session_entries_json[$idx]}"
    done
    if [[ ${#session_entries_json[@]} -gt 0 ]]; then
      printf '\n'
    fi
    printf '  ],\n'
    if [[ ${#warnings_list[@]} -gt 0 ]]; then
      print_json_string_array "warnings" "${warnings_list[@]}"
    else
      print_json_string_array "warnings"
    fi
    printf '\n}\n'
    return 0
  fi

  if [[ $found -eq 0 ]]; then
    if [[ ${#checked_dirs[@]} -eq 2 && -z "$user_xsessions_dir" && -z "$user_wayland_dir" ]]; then
      printf 'No session entries found in %s or %s.\n' "$xsessions_dir" "$wayland_dir"
    else
      local dir_summary=""
      for ((idx = 0; idx < ${#checked_dirs[@]}; idx++)); do
        if [[ $idx -gt 0 ]]; then
          if [[ $idx -eq $((${#checked_dirs[@]} - 1)) ]]; then
            dir_summary+=" or "
          else
            dir_summary+=", "
          fi
        fi
        dir_summary+="${checked_dirs[$idx]}"
      done
      printf 'No session entries found in %s.\n' "$dir_summary"
    fi
  fi
}

# Create ~/.config/lightxdm/.xinitrc-<id> (or .wayland-session-<id>) to edit: a copy of the
# built-in template, or a custom X11 (from i3) or minimal Wayland template.
init_xinitrc_template() {
  local id="$1" wayland="${2:-0}" dest="$HOME/.config/lightxdm/.xinitrc-$1"
  local from_session="${3:-}" dest_override="${4:-}" quiet="${5:-0}"
  local exec_line="exec $1" current_desktop="$1"
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
  if [[ -n "$dest_override" ]]; then
    dest="$dest_override"
  else
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
  fi
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
  if [[ -n "$dest_override" ]]; then
    mkdir -p -- "${dest%/*}"
  else
    mkdir -p -- "$HOME/.config/lightxdm"
  fi
  case "$id" in
    plasma | gnome | budgie)
      cp -- "$SCRIPT_DIR/dotfiles/.wayland-session-$id" "$dest"
      chmod 755 "$dest"
      [[ $quiet -eq 1 ]] || log "Created $dest from the built-in $id template. Edit it, then run: $(script_cmd install.sh) --de $id"
      ;;
    xfce | lxqt | lxde | mate | cinnamon | i3)
      cp -- "$SCRIPT_DIR/dotfiles/.xinitrc-$id" "$dest"
      chmod 755 "$dest"
      [[ $quiet -eq 1 ]] || log "Created $dest from the built-in $id template. Edit it, then run: $(script_cmd install.sh) --de $id"
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
      [[ $quiet -eq 1 ]] || log "Created $dest for $id. Check its exec line, then run: $(script_cmd install.sh) --no-packages --de $id"
      ;;
  esac
}

session_entry_is_wayland() {
  local entry="$1" explicit_wayland="${2:-0}" wayland_dir resolved_entry
  [[ $explicit_wayland -eq 1 ]] && return 0
  wayland_dir="${WAYLAND_SESSIONS_DIR:-${SESSION_ROOT:-}/usr/share/wayland-sessions}"
  wayland_dir="${wayland_dir%/}"
  if [[ "$entry" == "${wayland_dir}/"* || "$entry" == */wayland-sessions/* ]]; then
    return 0
  fi
  resolved_entry="$(readlink -f -- "$entry" 2>/dev/null || true)"
  if [[ -n "$resolved_entry" ]] &&
    [[ "$resolved_entry" == "${wayland_dir}/"* || "$resolved_entry" == */wayland-sessions/* ]]; then
    return 0
  fi
  return 1
}

prepare_install_session() {
  local entry="$1" requested_de="$2" de_specified="$3" explicit_wayland="${4:-0}"
  local target_de="$requested_de" is_wl=0 dest sibling resolved_entry_check=0
  local SESSION_ENTRY_NAME="" SESSION_ENTRY_EXEC_LINE="" SESSION_ENTRY_EXEC_CMD=""
  local SESSION_ENTRY_DESKTOP="" SESSION_ENTRY_TRY_EXEC=""
  local SESSION_ENTRY_HIDDEN=0 SESSION_ENTRY_NO_DISPLAY=0 SESSION_ENTRY_ERROR=""

  if [[ $de_specified -eq 1 ]]; then
    if [[ -z "$target_de" || "$target_de" == *[!abcdefghijklmnopqrstuvwxyz0123456789_-]* ]]; then
      log "Invalid desktop id: $target_de (use lowercase letters, digits, _ and -)"
      return 1
    fi
    case "$target_de" in
      plasma | gnome | budgie | xfce | lxqt | lxde | mate | cinnamon | i3)
        log "--install-session is only for custom ids; $target_de has a built-in template."
        return 1
        ;;
    esac
  fi

  if ! parse_desktop_session_entry "$entry"; then
    log "$SESSION_ENTRY_ERROR"
    return 1
  fi
  if [[ -n "$SESSION_ENTRY_TRY_EXEC" ]] && ! session_command_exists "$SESSION_ENTRY_TRY_EXEC"; then
    log "Session entry TryExec executable not found: $SESSION_ENTRY_TRY_EXEC ($entry)"
    return 1
  fi
  if ! session_command_exists "$SESSION_ENTRY_EXEC_CMD"; then
    log "Session entry command not found: $SESSION_ENTRY_EXEC_CMD ($entry)"
    return 1
  fi

  if [[ -z "$target_de" ]]; then
    target_de="$(suggest_custom_session_id "$entry")"
  fi
  if session_entry_is_wayland "$entry" "$explicit_wayland"; then
    is_wl=1
    dest="$HOME/.config/lightxdm/.wayland-session-$target_de"
    sibling="$HOME/.config/lightxdm/.xinitrc-$target_de"
  else
    dest="$HOME/.config/lightxdm/.xinitrc-$target_de"
    sibling="$HOME/.config/lightxdm/.wayland-session-$target_de"
  fi

  local home="${HOME%/}"
  [[ -n "$home" ]] || home="/"
  if [[ -z "${HOME:-}" || -L "$home" || ! -d "$home" ]]; then
    log "Refusing unsafe home directory: ${HOME:-<unset>}"
    return 1
  fi
  if [[ -L "$home/.config" ]] || [[ -e "$home/.config" && ! -d "$home/.config" ]]; then
    log "Refusing unsafe directory path: $home/.config"
    return 1
  fi
  if [[ -L "$home/.config/lightxdm" ]] || [[ -e "$home/.config/lightxdm" && ! -d "$home/.config/lightxdm" ]]; then
    log "Refusing unsafe directory path: $home/.config/lightxdm"
    return 1
  fi
  if [[ -e "$sibling" || -L "$sibling" ]]; then
    log "$sibling already exists for $target_de; a custom id uses one session template: edit it, or remove it to switch."
    return 1
  fi
  if [[ -L "$dest" ]] || [[ -e "$dest" && ! -f "$dest" ]]; then
    log "Refusing non-regular or symlinked session template: $dest"
    return 1
  fi
  if [[ -f "$dest" ]]; then
    if [[ ! -r "$dest" ]]; then
      log "Cannot read existing session template: $dest"
      return 1
    fi
    check_template_syntax "$dest" || return 1
    check_template_not_self "$target_de" "$dest" || return 1
    check_session_commands "$dest" || return 1
    resolved_entry_check=1
  else
    if [[ $is_wl -eq 1 ]]; then
      local wl_tokens=() wl_token wl_check_path
      # Keep fresh-template Exec validation aligned with check_session_commands before sudo/home writes.
      # shellcheck disable=SC2162
      read -a wl_tokens <<< "${SESSION_ENTRY_EXEC_LINE#exec }"
      for wl_token in "${wl_tokens[@]}"; do
        [[ "$wl_token" == -* ]] && break
        [[ "$wl_token" == /* ]] || continue
        wl_check_path="${SESSION_ROOT:-}$wl_token"
        if [[ ! -f "$wl_check_path" || ! -x "$wl_check_path" ]]; then
          log "Missing command: $wl_token. Install your session and ensure $wl_token exists and is executable, then re-run."
          return 1
        fi
      done
    elif ! command -v startx >/dev/null 2>&1; then
      log "Missing command: startx (normally provided by xorg-xinit). Install xorg-xinit and re-run."
      return 1
    fi
  fi

  INSTALL_SESSION_DE="$target_de"
  INSTALL_SESSION_WAYLAND="$is_wl"
  INSTALL_SESSION_DEST="$dest"
  INSTALL_SESSION_TEMPLATE_EXISTS="$resolved_entry_check"
  return 0
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

# Resolve $1 through symlinks and print the deepest existing (or symlink) component at or above its parent dir.
pam_resolve_probe_dir() {
  local resolved probe
  resolved="$(readlink -m -- "$1" 2>/dev/null || printf '%s\n' "$1")"
  probe="$(dirname -- "$resolved")"
  while [[ "$probe" != "/" && "$probe" != "." && ! -e "$probe" && ! -L "$probe" ]]; do
    probe="$(dirname -- "$probe")"
  done
  printf '%s\n' "$probe"
}

# True when inspecting $1 ($2 == 1 for strict state files, $2 == 2 for PAM backups allowing symlinked parent dirs) cannot be settled without sudo.
pam_path_needs_sudo() {
  local file="$1" no_symlink="${2:-0}" dir probe=""
  dir="$(dirname -- "$file")"
  if [[ ( $no_symlink -eq 1 && ( -L "$dir" || -L "$file" ) ) || ( $no_symlink -eq 2 && -L "$file" ) ]]; then
    return 1
  fi
  if [[ -f "$file" && -r "$file" ]] ||
    [[ ! -e "$dir" && ! -L "$dir" && -x "$(dirname -- "$dir")" ]]; then
    return 1
  fi
  if [[ -d "$dir" && -x "$dir" && ! -e "$file" ]]; then
    if [[ ! -L "$file" ]]; then
      return 1
    fi
    probe="$(pam_resolve_probe_dir "$file")"
    if [[ -d "$probe" && -x "$probe" ]]; then
      return 1
    fi
  elif [[ -L "$dir" && ! -e "$dir" ]]; then
    probe="$(pam_resolve_probe_dir "$file")"
    if [[ -d "$probe" && -x "$probe" ]]; then
      return 1
    fi
  fi
  return 0
}

# Validate $LOGIN_FILE, permitting valid symlinks to regular files and searchable symlinked dirs
# while rejecting broken symlinks or non-regular targets. Sets LOGIN_PATH_STATE (ok|needs-root|missing|invalid)
# and LOGIN_PATH_REASON when invalid. When preview=$1 is 0, probes root-restricted paths with sudo.
inspect_login_pam_path() {
  local preview="${1:-1}" probe login_dir
  LOGIN_PATH_STATE="ok"
  LOGIN_PATH_REASON=""

  if [[ -f "$LOGIN_FILE" ]]; then
    if [[ -r "$LOGIN_FILE" || $preview -eq 0 ]]; then
      return 0
    fi
    LOGIN_PATH_STATE="needs-root"
    return 0
  fi

  if [[ -e "$LOGIN_FILE" ]]; then
    LOGIN_PATH_STATE="invalid"
    LOGIN_PATH_REASON="$LOGIN_FILE is not a regular file"
    return 0
  fi

  probe="$(pam_resolve_probe_dir "$LOGIN_FILE")"
  if [[ -d "$probe" && ! -x "$probe" ]]; then
    if [[ $preview -eq 1 ]]; then
      LOGIN_PATH_STATE="needs-root"
      return 0
    fi
    if sudo test -f "$LOGIN_FILE"; then
      LOGIN_PATH_STATE="ok"
    elif sudo test -e "$LOGIN_FILE"; then
      LOGIN_PATH_STATE="invalid"
      LOGIN_PATH_REASON="$LOGIN_FILE is not a regular file"
    elif sudo test -L "$LOGIN_FILE"; then
      LOGIN_PATH_STATE="invalid"
      LOGIN_PATH_REASON="$LOGIN_FILE is a broken symlink"
    else
      LOGIN_PATH_STATE="missing"
    fi
    return 0
  fi

  login_dir="$(dirname -- "$LOGIN_FILE")"
  if [[ -e "$probe" && ! -d "$probe" ]]; then
    LOGIN_PATH_STATE="invalid"
    LOGIN_PATH_REASON="$login_dir is not a directory"
  elif [[ -L "$LOGIN_FILE" || -L "$probe" ]]; then
    LOGIN_PATH_STATE="invalid"
    LOGIN_PATH_REASON="$LOGIN_FILE is a broken symlink"
  elif [[ -L "$login_dir" ]]; then
    LOGIN_PATH_STATE="invalid"
    LOGIN_PATH_REASON="$login_dir is a broken symlink"
  else
    LOGIN_PATH_STATE="missing"
  fi
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

# Print regular non-symlink PAM backup file $1 (permitting symlinked PAM parent dirs); use sudo only when $2 == 0.
read_pam_backup_file() {
  local file="$1" preview="${2:-0}"
  if [[ -L "$file" ]]; then
    return 1
  fi
  if [[ -f "$file" && -r "$file" ]]; then
    cat -- "$file"
  elif [[ $preview -eq 0 ]] && pam_path_needs_sudo "$file" 2 &&
    ! sudo test -L "$file" && sudo test -f "$file"; then
    sudo cat -- "$file"
  else
    return 1
  fi
}

# Back up $LOGIN_FILE to ${LOGIN_FILE}.lightxdm.bak once before editing it, replacing any
# symlink backup (even inside a root-only or symlinked PAM directory) without clobbering a real backup.
backup_login_pam_file() {
  local backup="${LOGIN_FILE}.lightxdm.bak"
  if [[ -L "$backup" ]] || { pam_path_needs_sudo "$backup" 2 && sudo test -L "$backup"; }; then
    sudo rm -f -- "$backup" || return 1
  fi
  if [[ ! -e "$backup" ]] &&
    { ! pam_path_needs_sudo "$backup" 2 || ! sudo test -e "$backup"; }; then
    log "Backing up $LOGIN_FILE to $backup"
    sudo cp -p -- "$LOGIN_FILE" "$backup" || return 1
  fi
}

# Refuse symlinked state/config parent directories (matching read_pam_state_file and --status/--doctor/--fix);
# create ($2 == 1) or chmod 755 when an existing directory is non-searchable without following symlinks.
ensure_safe_state_dir() {
  local target="$1" create="${2:-0}" dir parent_dir
  dir="$(dirname -- "$target")"
  parent_dir="$(dirname -- "$dir")"
  if [[ -L "$dir" ]] || { [[ ! -x "$parent_dir" ]] && sudo test -L "$dir"; }; then
    log "ERROR: $dir is a symlink; lightXDM ignores symlinked state directories."
    return 1
  fi
  if [[ -d "$dir" ]] || { [[ ! -x "$parent_dir" ]] && sudo test -d "$dir"; }; then
    if [[ ! -x "$dir" ]] && { [[ -x "$parent_dir" ]] || ! sudo test -x "$dir"; }; then
      sudo chmod 755 -- "$dir" || return 1
    fi
  elif [[ $create -eq 1 ]]; then
    sudo install -d -m755 -- "$dir" || return 1
  fi
}

# Installs before 2026-11-03 backed up to .lightxde.bak.<epoch>; adopt the oldest one as the
# original so a re-install does not back up a login file that already holds old keyring lines.
legacy_pam_backup_candidate() {
  local preview="${1:-0}" backup_file="${LOGIN_FILE}.lightxdm.bak" old_backup epoch oldest_epoch="" login_content login_dir=""
  if [[ -e "$backup_file" || -L "$backup_file" ]] ||
    { [[ $preview -eq 0 ]] && pam_path_needs_sudo "$backup_file" 2 && { sudo test -e "$backup_file" || sudo test -L "$backup_file"; }; }; then
    return 0
  fi
  # Without old keyring lines in the login file, an uninstall already restored the original;
  # a newer leftover backup may hold keyring lines and must not become the original.
  login_content="$(read_pam_file "$LOGIN_FILE" "$preview" 2>/dev/null)" || return 0
  grep -Fxq -f <(printf '%s\n' "${LIGHTXDM_KEYRING_LINES[@]}") <<<"$login_content" || return 0
  login_dir="$(dirname -- "$LOGIN_FILE")"
  local candidates=()
  if [[ -r "$login_dir" && -x "$login_dir" ]]; then
    for old_backup in "${LOGIN_FILE}".lightxde.bak.*; do
      if [[ -f "$old_backup" && ! -L "$old_backup" ]]; then
        candidates+=("$old_backup")
      fi
    done
  elif [[ $preview -eq 0 ]]; then
    # shellcheck disable=SC2016  # expanded by the inner root shell after globbing the restricted dir
    mapfile -t candidates < <(sudo sh -c 'for f in "$1".lightxde.bak.*; do [ -f "$f" ] && [ ! -L "$f" ] && printf "%s\n" "$f"; done' _ "$LOGIN_FILE" 2>/dev/null || true)
  fi
  for old_backup in "${candidates[@]}"; do
    epoch="${old_backup##*.lightxde.bak.}"
    if [[ "$epoch" =~ ^[0-9]+$ ]] && { [[ -z "$oldest_epoch" ]] || ((10#$epoch < 10#$oldest_epoch)); }; then
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
  if [[ ! -e "$backup_file" && ! -L "$backup_file" ]] &&
    { [[ $preview -ne 0 ]] || ! pam_path_needs_sudo "$backup_file" 2 || { ! sudo test -e "$backup_file" && ! sudo test -L "$backup_file"; }; }; then
    backup_file="$(legacy_pam_backup_candidate "$preview")"
  fi
  [[ -n "$backup_file" ]] || return 0
  backup_content="$(read_pam_backup_file "$backup_file" "$preview" 2>/dev/null)" || return 0
  login_content="$(read_pam_file "$LOGIN_FILE" "$preview")" || return 1
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

# Print the fixed keyring backend for a built-in desktop id, returning 1 for custom ids.
builtin_de_keyring_backend() {
  case "${1:-}" in
    plasma) printf 'kwallet\n' ;;
    gnome | xfce | lxqt | lxde | mate | cinnamon | budgie | i3) printf 'gnome\n' ;;
    *) return 1 ;;
  esac
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
  if [[ -n "$de" && -n "$backend" ]] && ! builtin_de_keyring_backend "$de" >/dev/null 2>&1; then
    hint+=" --keyring $backend"
  fi
  printf '%s\n' "$hint"
}

# Configure PAM for KWallet/GNOME Keyring auto-unlock, or preview the missing lines.
configure_pam() {
  local de preview="${2:-0}" keyring="${3:-gnome}"
  de=$1

  if [[ $preview -eq 1 ]]; then
    printf 'PAM keyring: %s\n' "$LOGIN_FILE"
    local LOGIN_PATH_STATE="" LOGIN_PATH_REASON=""
    inspect_login_pam_path 1
    case "$LOGIN_PATH_STATE" in
      ok) ;;
      missing)
        printf '  missing (installation would stop)\n'
        return 0
        ;;
      invalid)
        log "ERROR: $LOGIN_PATH_REASON; lightXDM will not create it."
        return 1
        ;;
      needs-root)
        printf '  unknown (needs root)\n'
        return 0
        ;;
    esac
  else
    log "Configuring PAM for $de..."
  fi
  # Never create the login PAM file: a file holding only the optional keyring lines is an unsafe login stack.
  if [[ ! -f "$LOGIN_FILE" ]]; then
    local LOGIN_PATH_STATE="" LOGIN_PATH_REASON=""
    inspect_login_pam_path "$preview"
    if [[ "$LOGIN_PATH_STATE" == "invalid" ]]; then
      log "ERROR: $LOGIN_PATH_REASON; lightXDM will not create it."
      return 1
    elif [[ "$LOGIN_PATH_STATE" != "ok" ]]; then
      log "ERROR: $LOGIN_FILE is missing; lightXDM will not create it."
      if [[ -e "${LOGIN_FILE}.lightxdm.bak" ]] ||
        { [[ $preview -eq 0 ]] && pam_path_needs_sudo "${LOGIN_FILE}.lightxdm.bak" 2 && sudo test -e "${LOGIN_FILE}.lightxdm.bak"; }; then
        log "Restore it from the backup first: sudo cp ${LOGIN_FILE}.lightxdm.bak $LOGIN_FILE"
      fi
      return 1
    fi
  fi
  local module auth_line session_line backend builtin_keyring=""
  if builtin_keyring="$(builtin_de_keyring_backend "$de" 2>/dev/null)"; then
    keyring="$builtin_keyring"
  fi
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
    if [[ -n "$preview_backup" && -f "$preview_backup" && ! -L "$preview_backup" && ! -r "$preview_backup" ]]; then
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
  ensure_safe_state_dir "$PAM_KEYRING_STATE" || return 1
  if [[ "${UPDATE_RESTORE_PAM:-0}" == 1 && -n "${UPDATE_LOGIN_SUM:-}" ]]; then
    ensure_safe_state_dir "$PAM_LOGIN_BASE_STATE" || return 1
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
  if [[ -f "$backup_file" && ! -L "$backup_file" ]] ||
    { pam_path_needs_sudo "$backup_file" 2 && ! sudo test -L "$backup_file" && sudo test -f "$backup_file"; }; then
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
    backup_login_pam_file || return 1
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
  elif [[ $preview -eq 0 ]] && pam_path_needs_sudo "$LOGIN_FILE" 0 && sudo test -f "$LOGIN_FILE"; then
    login_copy="$(mktemp)" || return 1
    # shellcheck disable=SC2024  # the temporary output file belongs to the calling user
    sudo cat -- "$LOGIN_FILE" > "$login_copy" || return 1
    login_src="$login_copy"
    login_readable=1
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
    local preview_login_state="ok"
    if [[ $login_readable -eq 0 ]]; then
      local LOGIN_PATH_STATE="" LOGIN_PATH_REASON=""
      inspect_login_pam_path 1
      preview_login_state="$LOGIN_PATH_STATE"
      if [[ "$de" == gnome ]]; then
        case "$preview_login_state" in
          invalid)
            log "ERROR: $LOGIN_PATH_REASON; lightXDM will not create it."
            return 1
            ;;
          missing)
            printf 'GNOME session type: %s\n  missing (installation would stop)\n' "$LOGIN_FILE"
            return 0
            ;;
        esac
      fi
    fi
    printf 'GNOME session type: %s\n' "$LOGIN_FILE"
    if [[ $login_readable -eq 0 && "$preview_login_state" == "needs-root" ]]; then
      printf '  existing block: unknown (needs root)\n'
    elif [[ $login_readable -eq 0 && "$preview_login_state" == "missing" ]]; then
      printf '  existing block: missing (%s)\n' "$LOGIN_FILE"
    elif [[ $login_readable -eq 0 && "$preview_login_state" == "invalid" ]]; then
      printf '  existing block: none (%s)\n' "$LOGIN_PATH_REASON"
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
      if [[ $has_block -eq 0 && ( $login_readable -eq 1 || "$preview_login_state" == "missing" || "$preview_login_state" == "invalid" ) && ! -e "$GNOME_SESSION_TYPE_DEST" && ! -L "$GNOME_SESSION_TYPE_DEST" ]]; then
        printf '  no GNOME configuration to remove\n'
      fi
    fi
    return 0
  fi
  if [[ "$de" != gnome && $has_block -eq 0 ]]; then
    if [[ -e "$GNOME_SESSION_TYPE_DEST" || -L "$GNOME_SESSION_TYPE_DEST" ]]; then
      ensure_safe_state_dir "$GNOME_SESSION_TYPE_DEST" || return 1
      sudo rm -f -- "$GNOME_SESSION_TYPE_DEST" || return 1
    fi
    return 0
  fi
  if [[ $login_readable -eq 0 && ! -f "$LOGIN_FILE" ]]; then
    local LOGIN_PATH_STATE="" LOGIN_PATH_REASON=""
    inspect_login_pam_path "$preview"
    if [[ "$LOGIN_PATH_STATE" == "invalid" ]]; then
      log "ERROR: $LOGIN_PATH_REASON; lightXDM will not create it."
      return 1
    elif [[ "$LOGIN_PATH_STATE" != "ok" ]]; then
      log "ERROR: $LOGIN_FILE is missing; lightXDM will not create it."
      return 1
    fi
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
  if [[ "$de" == gnome || -e "$GNOME_SESSION_TYPE_DEST" || -L "$GNOME_SESSION_TYPE_DEST" ]]; then
    ensure_safe_state_dir "$GNOME_SESSION_TYPE_DEST" || return 1
  fi
  if [[ "$de" == gnome && "${UPDATE_RESTORE_PAM:-0}" == 1 && -n "${UPDATE_LOGIN_SUM:-}" ]]; then
    ensure_safe_state_dir "$PAM_LOGIN_BASE_STATE" || return 1
  fi
  local changed=0
  if [[ "$(sha256sum < "$tmp")" != "$(sha256sum < "$login_src")" ]]; then
    changed=1
    backup_login_pam_file || return 1
  fi
  if [[ "$de" == gnome ]]; then
    local src="$SCRIPT_DIR/pam/gnome-session-type.conf"
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
  ensure_safe_state_dir "$DM_STATE_FILE" || return 1
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
    ensure_safe_state_dir "$DM_STATE_FILE" 1 || return 1
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
      if [[ -e "$DM_STATE_FILE" && ! -r "$DM_STATE_FILE" ]] ||
        { [[ ! -L "$(dirname -- "$DM_STATE_FILE")" && ! -L "$DM_STATE_FILE" ]] && pam_path_needs_sudo "$DM_STATE_FILE" 1; }; then
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
  printf 'Desktop: %s\nTemplate: %s\n' "$de" "${SESSION_PREVIEW_DEST:-$template}"
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
  backup_sum="$(set -o pipefail; read_pam_backup_file "$backup" "$preview" 2>/dev/null | sha256sum)" || return 1
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
  ensure_safe_state_dir "$PAM_LOGIN_BASE_STATE" || return 1
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
  local login_content="" login_readable=0 login_absent=0
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
  if login_content="$(read_pam_file "$LOGIN_FILE" "$preview" 2>/dev/null)"; then
    login_readable=1
    if grep -Eq '^[[:space:]]*-?(auth|session)[[:space:]][^#]*pam_gnome_keyring\.so' <<<"$login_content"; then
      has_gnome=1
    fi
    if grep -Eq '^[[:space:]]*-?(auth|session)[[:space:]][^#]*pam_kwallet5\.so' <<<"$login_content"; then
      has_kwallet=1
    fi
  else
    local LOGIN_PATH_STATE="" LOGIN_PATH_REASON=""
    inspect_login_pam_path "$preview"
    if [[ "$LOGIN_PATH_STATE" == "missing" ]]; then
      login_absent=1
    fi
  fi
  # The record tells keyring lines a .pacnew merge dropped from lines removed with uninstall.sh
  # --keyring-only; installs from before the record fall back to the lines themselves.
  local record="" backend="" module auth_line session_line builtin_backend=""
  builtin_backend="$(builtin_de_keyring_backend "$de" 2>/dev/null || true)"
  record="$(read_pam_state_file "$PAM_KEYRING_STATE" "$preview" 2>/dev/null)" || record=""
  case "$record" in
    gnome | kwallet)
      if [[ -n "$builtin_backend" && "$record" != "$builtin_backend" ]]; then
        log "Warning: $PAM_KEYRING_STATE records $record, which does not match built-in desktop $de ($builtin_backend); ignoring mismatched keyring record."
        record=""
      else
        backend="$record"
      fi
      ;;
  esac
  if [[ -z "$backend" ]]; then
    record=""
    case "$builtin_backend" in
      kwallet)
        [[ $has_kwallet -eq 1 ]] && backend=kwallet
        ;;
      gnome)
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
  fi
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
  if [[ -z "$builtin_backend" ]]; then
    printf '%s\n' --keyring "$backend"
  fi
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

# Print JSON string array property named $1 with remaining arguments as elements (no trailing newline).
print_json_string_array() {
  local key="$1" i comma=""
  shift
  printf '  %s: [' "$(json_str "$key")"
  for i in "$@"; do
    printf '%s%s' "$comma" "$(json_str "$i")"
    comma=", "
  done
  printf ']'
}

_DIAG_CHECKS=()

# Emit a diagnostic check as prose immediately when $1==0, or buffer (name, status, detail) when $1==1.
diag_record_check() {
  local json_mode="$1" name="$2" status="$3" detail="$4" prose_override="${5-}"
  if [[ $json_mode -eq 1 ]]; then
    _DIAG_CHECKS+=("$name" "$status" "$detail")
    return 0
  fi
  if [[ -n "$prose_override" ]]; then
    printf '%s: %s\n' "$name" "$prose_override"
    return 0
  fi
  local label="$status"
  case "$status" in
    warn) label="WARN" ;;
    fail) label="FAIL" ;;
  esac
  if [[ -n "$detail" ]]; then
    printf '%s: %s (%s)\n' "$name" "$label" "$detail"
  else
    printf '%s: %s\n' "$name" "$label"
  fi
}

# Print "checks" JSON array property from flat (name, status, detail) triples in $@.
print_diag_checks_json() {
  local count=0 comma=""
  printf '  "checks": [\n'
  while [[ $# -ge 3 ]]; do
    printf '%s    {"name": %s, "status": %s, "detail": %s}' \
      "$comma" "$(json_str "$1")" "$(json_str "$2")" "$(json_str "$3")"
    comma=$',\n'
    shift 3
    count=$((count + 1))
  done
  if [[ $count -gt 0 ]]; then
    printf '\n'
  fi
  printf '  ]\n'
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

# True when an enable-autologin.sh --status Note reports an unreadable drop-in dir or *.conf file.
autologin_note_needs_root() {
  local autologin_dir="${AUTOLOGIN_DROPIN_DIR%/}"
  [[ -n "$autologin_dir" ]] || autologin_dir="/"
  case "$1" in
    "Note: cannot read $AUTOLOGIN_DROPIN_DIR;"* | \
      "Note: cannot read $autologin_dir;"* | \
      "Note: cannot read $AUTOLOGIN_DROPIN_DIR/"*.conf";"* | \
      "Note: cannot read $autologin_dir/"*.conf";"* )
      return 0
      ;;
  esac
  return 1
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
  local LOGIN_PATH_STATE="" LOGIN_PATH_REASON=""
  inspect_login_pam_path 1
  if [[ "$LOGIN_PATH_STATE" == "ok" ]] && login_content="$(read_pam_file "$LOGIN_FILE" 1 2>/dev/null)"; then
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
  elif [[ "$LOGIN_PATH_STATE" == "missing" ]]; then
    keyring_status_id="missing-login-file"
    keyring_status="missing"
    gnome_status_id="missing-login-file"
    gnome_status="missing ($LOGIN_FILE)"
  elif [[ "$LOGIN_PATH_STATE" == "invalid" ]]; then
    keyring_status_id="invalid-login-file"
    keyring_status="invalid ($LOGIN_PATH_REASON)"
    gnome_status_id="invalid-login-file"
    gnome_status="invalid ($LOGIN_PATH_REASON)"
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
        if autologin_note_needs_root "$note_item"; then
          auto_state="unknown-needs-root"
          break
        fi
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

# Return 0 when login shell ($1: bash|zsh|fish) already has a readable TTY1 auto-start hook.
shell_has_tty1_hook() {
  local shell_kind="$1" target=""
  [[ -n "${HOME:-}" ]] || return 1
  case "$shell_kind" in
    bash) target="$HOME/.bash_profile" ;;
    zsh) target="$HOME/.zprofile" ;;
    fish) target="$HOME/.config/fish/config.fish" ;;
    *) return 1 ;;
  esac
  [[ -f "$target" && -r "$target" ]] && grep -Eq '\.wayland-session|startx' "$target" 2>/dev/null
}

# Run pre-install onboarding readiness checks cleanly without sudo or side effects
run_preflight() {
  local json_mode=0
  [[ "${1:-}" == "--json" ]] && json_mode=1
  _DIAG_CHECKS=()

  local blockers=0 warnings=0 diag_msg="" install_cmd=""
  install_cmd="$(script_cmd install.sh)"
  local current_user="${SUDO_USER:-${USER:-}}"
  if [[ -z "$current_user" ]]; then
    current_user="$(id -un 2>/dev/null || true)"
  fi

  if [[ $EUID -eq 0 ]]; then
    diag_record_check "$json_mode" "User/sudo" "fail" "running as root; run as a regular user, not root or sudo"
    blockers=$((blockers + 1))
  elif ! command -v sudo >/dev/null 2>&1; then
    diag_record_check "$json_mode" "User/sudo" "fail" "sudo not found; install as root: su -c 'pacman -S sudo'"
    blockers=$((blockers + 1))
  else
    local groups_out="" group_note=""
    groups_out="$(id -nG 2>/dev/null || true)"
    if [[ -n "$groups_out" && " $groups_out " != *" wheel "* ]]; then
      group_note="; not in wheel group (ensure sudo privileges)"
    fi
    printf -v diag_msg '%s, sudo available%s' "${current_user:-regular user}" "$group_note"
    diag_record_check "$json_mode" "User/sudo" "ok" "$diag_msg"
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
    diag_record_check "$json_mode" "System tools" "ok" "pacman, systemctl"
  else
    printf -v diag_msg 'missing: %s' "${missing_tools[*]}"
    diag_record_check "$json_mode" "System tools" "fail" "$diag_msg"
    blockers=$((blockers + 1))
  fi

  local enabled_dms=()
  if [[ $have_systemctl -eq 1 ]]; then
    local getty_state=""
    getty_state="$(systemctl is-enabled getty@tty1.service 2>/dev/null || true)"
    if [[ "$getty_state" == masked ]]; then
      diag_record_check "$json_mode" "getty@tty1.service" "fail" "masked — unmask with: sudo systemctl unmask getty@tty1.service"
      blockers=$((blockers + 1))
    else
      diag_record_check "$json_mode" "getty@tty1.service" "ok" "${getty_state:-unknown}"
    fi

    mapfile -t enabled_dms < <(detect_enabled_dms)
    if [[ ${#enabled_dms[@]} -gt 0 ]]; then
      printf -v diag_msg '%s enabled (install will disable cleanly; uninstall restores)' "${enabled_dms[*]}"
      diag_record_check "$json_mode" "Display managers" "info" "$diag_msg" "$diag_msg"
    else
      diag_record_check "$json_mode" "Display managers" "ok" "none enabled"
    fi
  else
    diag_record_check "$json_mode" "getty@tty1.service" "skipped" "systemctl unavailable"
  fi

  if [[ -n "${WAYLAND_DISPLAY:-}" || -n "${DISPLAY:-}" ]]; then
    printf -v diag_msg 'graphical (%s — safe to install; current session will stay running)' "${WAYLAND_DISPLAY:-$DISPLAY}"
    diag_record_check "$json_mode" "Current session" "info" "$diag_msg" "$diag_msg"
  else
    diag_record_check "$json_mode" "Current session" "info" "TTY/non-graphical" "TTY/non-graphical"
  fi

  local login_shell=""
  if [[ -n "$current_user" ]] && command -v getent >/dev/null 2>&1; then
    login_shell="$(getent passwd "$current_user" | cut -d: -f7 || true)"
  fi
  case "$login_shell" in
    "")
      printf -v diag_msg 'non-bash users see: %s --shell-snippet <zsh|fish>' "$install_cmd"
      diag_record_check "$json_mode" "Login shell" "unknown" "$diag_msg"
      ;;
    *bash)
      printf -v diag_msg '%s — reads ~/.bash_profile' "$login_shell"
      diag_record_check "$json_mode" "Login shell" "ok" "$diag_msg"
      ;;
    *zsh)
      if shell_has_tty1_hook zsh; then
        printf -v diag_msg '%s — TTY1 hook present in ~/.zprofile' "$login_shell"
        diag_record_check "$json_mode" "Login shell" "ok" "$diag_msg"
      else
        printf -v diag_msg '%s does not read ~/.bash_profile — run: %s --shell-snippet zsh >> ~/.zprofile' "$login_shell" "$install_cmd"
        diag_record_check "$json_mode" "Login shell" "warn" "$diag_msg"
        warnings=$((warnings + 1))
      fi
      ;;
    *fish)
      if shell_has_tty1_hook fish; then
        printf -v diag_msg '%s — TTY1 hook present in ~/.config/fish/config.fish' "$login_shell"
        diag_record_check "$json_mode" "Login shell" "ok" "$diag_msg"
      else
        printf -v diag_msg '%s does not read ~/.bash_profile — run: %s --shell-snippet fish >> ~/.config/fish/config.fish' "$login_shell" "$install_cmd"
        diag_record_check "$json_mode" "Login shell" "warn" "$diag_msg"
        warnings=$((warnings + 1))
      fi
      ;;
    *)
      printf -v diag_msg '%s does not read ~/.bash_profile — add TTY1 auto-start block per docs/startx-autologin.md' "$login_shell"
      diag_record_check "$json_mode" "Login shell" "warn" "$diag_msg"
      warnings=$((warnings + 1))
      ;;
  esac

  local detected_raw="" detected_des=() first_de="" next_step=""
  if [[ $have_pacman -eq 1 ]]; then
    detected_raw="$(detect_de 2>/dev/null || true)"
    if [[ -n "$detected_raw" && "$detected_raw" != "unknown" ]]; then
      mapfile -t detected_des <<<"$detected_raw"
      first_de="${detected_des[0]}"
      diag_record_check "$json_mode" "Detected desktop(s)" "info" "${detected_des[*]}" "${detected_des[*]}"
      printf -v next_step '%s --dry-run --de %s   (or %s)' "$install_cmd" "$first_de" "$install_cmd"
    else
      diag_record_check "$json_mode" "Detected desktop(s)" "info" "none installed" "none installed"
      printf -v next_step '%s --list-sessions   (or %s to pick a desktop)' "$install_cmd" "$install_cmd"
    fi
    if [[ $json_mode -eq 0 ]]; then
      printf 'Next step: %s\n' "$next_step"
    fi
  else
    diag_record_check "$json_mode" "Detected desktop(s)" "skipped" "pacman unavailable"
  fi

  local summary_msg=""
  if [[ $blockers -eq 0 ]]; then
    summary_msg="Preflight: PASS (ready to run lightXDM installer)"
  else
    printf -v summary_msg 'Preflight: FAIL (%d blocker(s) found above)' "$blockers"
  fi

  if [[ $json_mode -eq 1 ]]; then
    local ready_bool="false" pf_status="fail"
    if [[ $blockers -eq 0 ]]; then
      ready_bool="true"
      if [[ $warnings -gt 0 ]]; then
        pf_status="warn"
      else
        pf_status="pass"
      fi
    fi
    printf '{\n'
    printf '  "mode": "preflight",\n'
    printf '  "ready": %s,\n' "$ready_bool"
    printf '  "status": %s,\n' "$(json_str "$pf_status")"
    printf '  "blockers": %d,\n' "$blockers"
    printf '  "warnings": %d,\n' "$warnings"
    if [[ ${#detected_des[@]} -gt 0 ]]; then
      print_json_string_array "detected_desktops" "${detected_des[@]}"
    else
      print_json_string_array "detected_desktops"
    fi
    printf ',\n'
    if [[ ${#enabled_dms[@]} -gt 0 ]]; then
      print_json_string_array "enabled_display_managers" "${enabled_dms[@]}"
    else
      print_json_string_array "enabled_display_managers"
    fi
    printf ',\n'
    printf '  "next_step": %s,\n' "$(json_str_or_null "$next_step")"
    printf '  "summary": %s,\n' "$(json_str "$summary_msg")"
    if [[ ${#_DIAG_CHECKS[@]} -gt 0 ]]; then
      print_diag_checks_json "${_DIAG_CHECKS[@]}"
    else
      print_diag_checks_json
    fi
    printf '}\n'
  else
    printf '%s\n' "$summary_msg"
  fi
  [[ $blockers -eq 0 ]]
}

# Verify post-install session, shell trigger, PAM, and systemd boot-recovery health without sudo or changes.
run_doctor() {
  local json_mode=0
  [[ "${1:-}" == "--json" ]] && json_mode=1
  _DIAG_CHECKS=()

  local LC_ALL=C issues=0 warnings=0 diag_msg=""
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
    printf -v diag_msg '%s or its directory is a symlink; re-run %s --de <id>' "$choices_file" "$install_cmd"
    diag_record_check "$json_mode" "Install choices" "fail" "$diag_msg"
    issues=$((issues + 1))
  elif [[ -e "$choices_file" ]]; then
    choices_kind="unreadable"
    printf -v diag_msg '%s is unreadable; fix permissions on %s' "$choices_file" "$choices_file"
    diag_record_check "$json_mode" "Install choices" "fail" "$diag_msg"
    issues=$((issues + 1))
  fi

  local installed_any=0
  if [[ "$choices_kind" != "not-recorded" || -e "$HOME/.wayland-session" || -L "$HOME/.wayland-session" ||
    -e "$HOME/.xinitrc" || -L "$HOME/.xinitrc" ]]; then
    installed_any=1
  fi
  if [[ $installed_any -eq 0 ]]; then
    printf -v diag_msg 'lightXDM is not installed for %s — run: %s --preflight' "$HOME" "$install_cmd"
    diag_record_check "$json_mode" "Install state" "fail" "$diag_msg"
    issues=$((issues + 1))
  elif [[ "$choices_kind" == "readable" && -n "$de" ]]; then
    if [[ "$no_packages" == 1 ]]; then
      printf -v diag_msg 'de=%s, --no-packages' "$de"
    else
      printf -v diag_msg 'de=%s' "$de"
    fi
    diag_record_check "$json_mode" "Install choices" "ok" "$diag_msg"
  elif [[ "$choices_kind" == "readable" ]]; then
    printf -v diag_msg '%s has no desktop recorded' "$choices_file"
    diag_record_check "$json_mode" "Install choices" "warn" "$diag_msg"
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
        printf -v diag_msg 'missing %s for de=%s — run: %s --init-template --de %s' "$template" "$de" "$install_cmd" "$de"
        diag_record_check "$json_mode" "Session template" "fail" "$diag_msg"
        issues=$((issues + 1))
      fi
    else
      printf -v diag_msg 'cannot resolve template for de=%s — check ~/.config/lightxdm/ for conflicting .wayland-session-%s and .xinitrc-%s' "$de" "$de" "$de"
      diag_record_check "$json_mode" "Session template" "fail" "$diag_msg"
      issues=$((issues + 1))
    fi
  fi

  local wl="$HOME/.wayland-session" xi="$HOME/.xinitrc"
  if [[ "$expected_mode" == wayland ]]; then
    if [[ -L "$wl" ]]; then
      if [[ ! -e "$wl" ]]; then
        printf -v diag_msg 'broken symlink %s — restore with: %s' "$wl" "$recover_cmd"
        diag_record_check "$json_mode" "Session launcher" "fail" "$diag_msg"
        issues=$((issues + 1))
      elif [[ ! -f "$wl" ]]; then
        printf -v diag_msg '%s is a symlink to a non-regular file — restore with: %s' "$wl" "$recover_cmd"
        diag_record_check "$json_mode" "Session launcher" "fail" "$diag_msg"
        issues=$((issues + 1))
      elif [[ ! -x "$wl" ]]; then
        printf -v diag_msg '%s is not executable — fix with: chmod +x ~/.wayland-session' "$wl"
        diag_record_check "$json_mode" "Session launcher" "fail" "$diag_msg"
        issues=$((issues + 1))
      else
        printf -v diag_msg '%s is a symlink; --update ignores symlinks' "$wl"
        diag_record_check "$json_mode" "Session launcher" "warn" "$diag_msg"
        warnings=$((warnings + 1))
        active_launcher="$wl"
      fi
    elif [[ ! -f "$wl" ]]; then
      printf -v diag_msg 'missing %s for de=%s — restore with: %s' "$wl" "$de" "$recover_cmd"
      diag_record_check "$json_mode" "Session launcher" "fail" "$diag_msg"
      issues=$((issues + 1))
    elif [[ ! -x "$wl" ]]; then
      printf -v diag_msg '%s exists but is not executable — fix with: chmod +x ~/.wayland-session' "$wl"
      diag_record_check "$json_mode" "Session launcher" "fail" "$diag_msg"
      issues=$((issues + 1))
    else
      printf -v diag_msg '%s, Wayland for de=%s' "$wl" "$de"
      diag_record_check "$json_mode" "Session launcher" "ok" "$diag_msg"
      active_launcher="$wl"
    fi
  elif [[ "$expected_mode" == x11 ]]; then
    if [[ ( -e "$wl" || -L "$wl" ) && -x "$wl" ]]; then
      printf -v diag_msg '%s is executable and shadows X11 %s for de=%s — remove %s or run: chmod -x ~/.wayland-session' "$wl" "$xi" "$de" "$wl"
      diag_record_check "$json_mode" "Wayland launcher shadow" "fail" "$diag_msg"
      issues=$((issues + 1))
    fi
    if [[ -L "$xi" ]]; then
      if [[ ! -e "$xi" ]]; then
        printf -v diag_msg 'broken symlink %s — restore with: %s' "$xi" "$recover_cmd"
        diag_record_check "$json_mode" "Session launcher" "fail" "$diag_msg"
        issues=$((issues + 1))
      elif [[ ! -f "$xi" ]]; then
        printf -v diag_msg '%s is a symlink to a non-regular file — restore with: %s' "$xi" "$recover_cmd"
        diag_record_check "$json_mode" "Session launcher" "fail" "$diag_msg"
        issues=$((issues + 1))
      else
        printf -v diag_msg '%s is a symlink; --update ignores symlinks' "$xi"
        diag_record_check "$json_mode" "Session launcher" "warn" "$diag_msg"
        warnings=$((warnings + 1))
        active_launcher="$xi"
      fi
    elif [[ ! -f "$xi" ]]; then
      printf -v diag_msg 'missing %s for de=%s — restore with: %s' "$xi" "$de" "$recover_cmd"
      diag_record_check "$json_mode" "Session launcher" "fail" "$diag_msg"
      issues=$((issues + 1))
    else
      active_launcher="$xi"
    fi
    if ! command -v startx >/dev/null 2>&1; then
      diag_record_check "$json_mode" "X11 starter" "fail" "startx not found on PATH — install xorg-xinit"
      issues=$((issues + 1))
    elif [[ -n "$active_launcher" && ! -L "$xi" ]]; then
      printf -v diag_msg '%s via startx for de=%s' "$xi" "$de"
      diag_record_check "$json_mode" "Session launcher" "ok" "$diag_msg"
    fi
  elif [[ $installed_any -eq 1 ]]; then
    if [[ -L "$wl" && ! -e "$wl" ]]; then
      printf -v diag_msg 'broken symlink %s — remove or run: %s --de <id>' "$wl" "$install_cmd"
      diag_record_check "$json_mode" "Session launcher" "fail" "$diag_msg"
      issues=$((issues + 1))
    elif [[ -L "$wl" && ! -f "$wl" ]]; then
      printf -v diag_msg '%s is a symlink to a non-regular file — remove or run: %s --de <id>' "$wl" "$install_cmd"
      diag_record_check "$json_mode" "Session launcher" "fail" "$diag_msg"
      issues=$((issues + 1))
    elif [[ -e "$wl" && ! -f "$wl" ]]; then
      printf -v diag_msg '%s is not a regular file — remove or run: %s --de <id>' "$wl" "$install_cmd"
      diag_record_check "$json_mode" "Session launcher" "fail" "$diag_msg"
      issues=$((issues + 1))
    elif [[ -f "$wl" && -x "$wl" ]]; then
      if [[ -L "$wl" ]]; then
        printf -v diag_msg '%s is a symlink; --update ignores symlinks' "$wl"
        diag_record_check "$json_mode" "Session launcher" "warn" "$diag_msg"
        warnings=$((warnings + 1))
      else
        printf -v diag_msg '%s, Wayland' "$wl"
        diag_record_check "$json_mode" "Session launcher" "ok" "$diag_msg"
      fi
      active_launcher="$wl"
    elif [[ -f "$wl" ]]; then
      printf -v diag_msg '%s exists but is not executable — fix with: chmod +x ~/.wayland-session' "$wl"
      diag_record_check "$json_mode" "Session launcher" "fail" "$diag_msg"
      issues=$((issues + 1))
    elif [[ -L "$xi" && ! -e "$xi" ]]; then
      printf -v diag_msg 'broken symlink %s — restore with: %s --de <id>' "$xi" "$install_cmd"
      diag_record_check "$json_mode" "Session launcher" "fail" "$diag_msg"
      issues=$((issues + 1))
    elif [[ -L "$xi" && ! -f "$xi" ]]; then
      printf -v diag_msg '%s is a symlink to a non-regular file — restore with: %s --de <id>' "$xi" "$install_cmd"
      diag_record_check "$json_mode" "Session launcher" "fail" "$diag_msg"
      issues=$((issues + 1))
    elif [[ -e "$xi" && ! -f "$xi" ]]; then
      printf -v diag_msg '%s is not a regular file — restore with: %s --de <id>' "$xi" "$install_cmd"
      diag_record_check "$json_mode" "Session launcher" "fail" "$diag_msg"
      issues=$((issues + 1))
    elif [[ -f "$xi" ]]; then
      if ! command -v startx >/dev/null 2>&1; then
        diag_record_check "$json_mode" "X11 starter" "fail" "startx not found on PATH — install xorg-xinit"
        issues=$((issues + 1))
      else
        if [[ -L "$xi" ]]; then
          printf -v diag_msg '%s is a symlink; --update ignores symlinks' "$xi"
          diag_record_check "$json_mode" "Session launcher" "warn" "$diag_msg"
          warnings=$((warnings + 1))
        else
          printf -v diag_msg '%s via startx' "$xi"
          diag_record_check "$json_mode" "Session launcher" "ok" "$diag_msg"
        fi
        active_launcher="$xi"
      fi
    else
      printf -v diag_msg 'missing %s or %s — re-run %s --de <id>' "$wl" "$xi" "$install_cmd"
      diag_record_check "$json_mode" "Session launcher" "fail" "$diag_msg"
      issues=$((issues + 1))
    fi
  fi

  if [[ -n "$active_launcher" ]]; then
    if [[ ! -r "$active_launcher" ]]; then
      printf -v diag_msg '%s is not readable — fix with: chmod u+r %s' "$active_launcher" "$active_launcher"
      diag_record_check "$json_mode" "Session checks" "fail" "$diag_msg"
      issues=$((issues + 1))
    else
      local diag_err="" cmd_ok=1
      if ! diag_err="$(check_template_syntax "$active_launcher" 2>&1)"; then
        diag_record_check "$json_mode" "Session syntax" "fail" "${diag_err#=> }"
        issues=$((issues + 1))
        cmd_ok=0
      fi
      if ! diag_err="$(check_session_commands "$active_launcher" 2>&1)"; then
        diag_record_check "$json_mode" "Session command" "fail" "${diag_err#=> }"
        issues=$((issues + 1))
        cmd_ok=0
      fi
      if [[ $cmd_ok -eq 1 ]]; then
        printf -v diag_msg 'syntax and command verified for %s' "$active_launcher"
        diag_record_check "$json_mode" "Session checks" "ok" "$diag_msg"
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
        if shell_has_tty1_hook bash; then
          printf -v diag_msg '%s via ~/.bash_profile' "$login_shell"
          diag_record_check "$json_mode" "Login shell auto-start" "ok" "$diag_msg"
        else
          # shellcheck disable=SC2088 # literal home-relative display path for user instructions
          printf -v diag_msg '~/.bash_profile is missing or lacks TTY1 auto-start trigger — restore with: %s' "$recover_cmd"
          diag_record_check "$json_mode" "Login shell auto-start" "fail" "$diag_msg"
          issues=$((issues + 1))
        fi
        ;;
      *zsh)
        if shell_has_tty1_hook zsh; then
          printf -v diag_msg '%s via ~/.zprofile' "$login_shell"
          diag_record_check "$json_mode" "Login shell auto-start" "ok" "$diag_msg"
        else
          printf -v diag_msg 'zsh login shell lacks TTY1 auto-start block in ~/.zprofile — run: %s --shell-snippet zsh >> ~/.zprofile' "$install_cmd"
          diag_record_check "$json_mode" "Login shell auto-start" "fail" "$diag_msg"
          issues=$((issues + 1))
        fi
        ;;
      *fish)
        if shell_has_tty1_hook fish; then
          printf -v diag_msg '%s via ~/.config/fish/config.fish' "$login_shell"
          diag_record_check "$json_mode" "Login shell auto-start" "ok" "$diag_msg"
        else
          printf -v diag_msg 'fish login shell lacks TTY1 auto-start block in ~/.config/fish/config.fish — run: %s --shell-snippet fish >> ~/.config/fish/config.fish' "$install_cmd"
          diag_record_check "$json_mode" "Login shell auto-start" "fail" "$diag_msg"
          issues=$((issues + 1))
        fi
        ;;
      "")
        if shell_has_tty1_hook bash; then
          # shellcheck disable=SC2088 # literal home-relative display path for user instructions
          diag_record_check "$json_mode" "Login shell auto-start" "ok" "~/.bash_profile present"
        else
          diag_record_check "$json_mode" "Login shell auto-start" "warn" "login shell unknown; could not verify TTY1 shell auto-start hook"
          warnings=$((warnings + 1))
        fi
        ;;
      *)
        printf -v diag_msg '%s does not read ~/.bash_profile — verify TTY1 auto-start block per docs/startx-autologin.md' "$login_shell"
        diag_record_check "$json_mode" "Login shell auto-start" "warn" "$diag_msg"
        warnings=$((warnings + 1))
        ;;
    esac
  fi

  if [[ -e "$HOME/.config/lightxdm/no-autostart" || -L "$HOME/.config/lightxdm/no-autostart" ]]; then
    # shellcheck disable=SC2088 # literal home-relative display path for user instructions
    diag_record_check "$json_mode" "Auto-start pause" "fail" "~/.config/lightxdm/no-autostart disables TTY1 auto-start — check logs: journalctl -b -t lightxdm, then resume: rm ~/.config/lightxdm/no-autostart"
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
      printf -v diag_msg '%d launch attempt(s) in last 30s — check journalctl -b -t lightxdm or touch ~/.config/lightxdm/session-journal' "$recent_count"
      diag_record_check "$json_mode" "Auto-start status" "warn" "$diag_msg"
      warnings=$((warnings + 1))
    else
      diag_record_check "$json_mode" "Auto-start status" "ok" "active on TTY1"
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
    printf -v diag_msg '%s — review diff and merge' "${pending_files[*]}"
    diag_record_check "$json_mode" "Pending dotfile updates" "warn" "$diag_msg"
    warnings=$((warnings + 1))
  fi

  local pam_record="" pam_expected="" pam_mismatch=0 keyring_configured=0 builtin_backend=""
  builtin_backend="$(builtin_de_keyring_backend "$de" 2>/dev/null || true)"
  if pam_record="$(read_pam_state_file "$PAM_KEYRING_STATE" 1 2>/dev/null)"; then
    case "$pam_record" in
      gnome | kwallet)
        if [[ -n "$builtin_backend" && "$pam_record" != "$builtin_backend" ]]; then
          printf -v diag_msg '%s records %s, expected %s for de=%s — repair with: %s %s' \
            "$PAM_KEYRING_STATE" "$pam_record" "$builtin_backend" "$de" "$install_cmd" "$(pam_restore_hint "$de" "$builtin_backend")"
          diag_record_check "$json_mode" "PAM keyring state" "warn" "$diag_msg"
          warnings=$((warnings + 1))
          pam_mismatch=1
          pam_expected="$builtin_backend"
        else
          pam_expected="$pam_record"
        fi
        ;;
      *)
        printf -v diag_msg '%s has unexpected value %s' "$PAM_KEYRING_STATE" "${pam_record:-empty}"
        diag_record_check "$json_mode" "PAM keyring state" "warn" "$diag_msg"
        warnings=$((warnings + 1))
        ;;
    esac
  elif [[ -L "$(dirname -- "$PAM_KEYRING_STATE")" || -L "$PAM_KEYRING_STATE" ]]; then
    printf -v diag_msg '%s or its directory is a symlink; lightXDM ignores symlinks' "$PAM_KEYRING_STATE"
    diag_record_check "$json_mode" "PAM keyring state" "fail" "$diag_msg"
    issues=$((issues + 1))
  elif pam_path_needs_sudo "$PAM_KEYRING_STATE" 1; then
    printf -v diag_msg '%s: unknown (needs root)' "$PAM_KEYRING_STATE"
    diag_record_check "$json_mode" "PAM keyring state" "warn" "$diag_msg"
    warnings=$((warnings + 1))
  fi

  local login_content="" LOGIN_PATH_STATE="" LOGIN_PATH_REASON=""
  inspect_login_pam_path 1
  if [[ "$LOGIN_PATH_STATE" == "ok" ]] && login_content="$(read_pam_file "$LOGIN_FILE" 1 2>/dev/null)"; then
    local missing_gnome missing_kwallet has_gnome_line=0 has_kwallet_line=0
    missing_gnome="$(pam_lines_to_add "pam_gnome_keyring.so" "$PAM_GNOME_KEYRING_AUTH" "$PAM_GNOME_KEYRING_SESSION" "" 1 || true)"
    missing_kwallet="$(pam_lines_to_add "pam_kwallet5.so" "$PAM_KWALLET_AUTH" "$PAM_KWALLET_SESSION" "" 1 || true)"
    grep -Eq '^[[:space:]]*-?(auth|session)[[:space:]][^#]*pam_gnome_keyring\.so' <<<"$login_content" && has_gnome_line=1
    grep -Eq '^[[:space:]]*-?(auth|session)[[:space:]][^#]*pam_kwallet5\.so' <<<"$login_content" && has_kwallet_line=1

    if [[ -e "${LOGIN_FILE}.pacnew" || -L "${LOGIN_FILE}.pacnew" ]]; then
      if login_file_replaced_by_package 1; then
        printf -v diag_msg '%s appears replaced by package upgrade while %s.pacnew exists — restore with: %s or %s %s' \
          "$LOGIN_FILE" "$LOGIN_FILE" "$update_cmd" "$install_cmd" "$(pam_restore_hint "$de" "$pam_expected")"
        diag_record_check "$json_mode" "PAM .pacnew" "fail" "$diag_msg"
        issues=$((issues + 1))
      else
        printf -v diag_msg '%s.pacnew waiting — merge carefully without dropping lightXDM PAM lines' "$LOGIN_FILE"
        diag_record_check "$json_mode" "PAM .pacnew" "warn" "$diag_msg"
        warnings=$((warnings + 1))
      fi
    fi

    local keyring_issue=0
    if [[ "$pam_expected" == gnome && -n "$missing_gnome" ]]; then
      if [[ $pam_mismatch -eq 1 ]]; then
        printf -v diag_msg 'expected gnome keyring lines for de=%s missing from %s — restore with: %s %s' "$de" "$LOGIN_FILE" "$install_cmd" "$(pam_restore_hint "$de" gnome)"
      else
        printf -v diag_msg 'recorded gnome keyring lines missing from %s — restore with: %s %s' "$LOGIN_FILE" "$install_cmd" "$(pam_restore_hint "$de" gnome)"
      fi
      diag_record_check "$json_mode" "PAM keyring" "fail" "$diag_msg"
      issues=$((issues + 1))
      keyring_issue=1
    elif [[ "$pam_expected" == kwallet && -n "$missing_kwallet" ]]; then
      if [[ $pam_mismatch -eq 1 ]]; then
        printf -v diag_msg 'expected kwallet5 lines for de=%s missing from %s — restore with: %s %s' "$de" "$LOGIN_FILE" "$install_cmd" "$(pam_restore_hint "$de" kwallet)"
      else
        printf -v diag_msg 'recorded kwallet5 lines missing from %s — restore with: %s %s' "$LOGIN_FILE" "$install_cmd" "$(pam_restore_hint "$de" kwallet)"
      fi
      diag_record_check "$json_mode" "PAM keyring" "fail" "$diag_msg"
      issues=$((issues + 1))
      keyring_issue=1
    elif [[ -n "$builtin_backend" ]]; then
      if { [[ "$builtin_backend" == gnome && $has_gnome_line -eq 1 && -n "$missing_gnome" ]]; } ||
        { [[ "$builtin_backend" == kwallet && $has_kwallet_line -eq 1 && -n "$missing_kwallet" ]]; }; then
        printf -v diag_msg 'partial keyring PAM lines in %s — missing auth or session line; restore with: %s %s' "$LOGIN_FILE" "$install_cmd" "$(pam_restore_hint "$de" "$builtin_backend")"
        diag_record_check "$json_mode" "PAM keyring" "fail" "$diag_msg"
        issues=$((issues + 1))
        keyring_issue=1
      fi
    elif { [[ $has_gnome_line -eq 1 && -n "$missing_gnome" ]]; } || { [[ $has_kwallet_line -eq 1 && -n "$missing_kwallet" ]]; }; then
      local partial_backend="$pam_expected"
      if [[ -z "$partial_backend" ]]; then
        if [[ $has_kwallet_line -eq 1 && -n "$missing_kwallet" && $has_gnome_line -eq 0 ]]; then
          partial_backend="kwallet"
        elif [[ $has_gnome_line -eq 1 && -n "$missing_gnome" && $has_kwallet_line -eq 0 ]]; then
          partial_backend="gnome"
        fi
      fi
      printf -v diag_msg 'partial keyring PAM lines in %s — missing auth or session line; restore with: %s %s' "$LOGIN_FILE" "$install_cmd" "$(pam_restore_hint "$de" "$partial_backend")"
      diag_record_check "$json_mode" "PAM keyring" "fail" "$diag_msg"
      issues=$((issues + 1))
      keyring_issue=1
    fi

    if [[ -n "$builtin_backend" ]]; then
      if [[ "$builtin_backend" != gnome && $has_gnome_line -eq 1 && -n "$missing_gnome" ]]; then
        printf -v diag_msg 'partial gnome PAM lines in %s do not belong to de=%s (%s) — remove or complete them manually if unneeded' \
          "$LOGIN_FILE" "$de" "$builtin_backend"
        diag_record_check "$json_mode" "PAM foreign keyring" "warn" "$diag_msg"
        warnings=$((warnings + 1))
      fi
      if [[ "$builtin_backend" != kwallet && $has_kwallet_line -eq 1 && -n "$missing_kwallet" ]]; then
        printf -v diag_msg 'partial kwallet PAM lines in %s do not belong to de=%s (%s) — remove or complete them manually if unneeded' \
          "$LOGIN_FILE" "$de" "$builtin_backend"
        diag_record_check "$json_mode" "PAM foreign keyring" "warn" "$diag_msg"
        warnings=$((warnings + 1))
      fi
    fi

    local missing_keyring_mods=()
    if [[ -z "$missing_gnome" ]]; then
      keyring_configured=1
      if [[ ! -e "${SESSION_ROOT:-}/usr/lib/security/pam_gnome_keyring.so" ]]; then
        missing_keyring_mods+=("${SESSION_ROOT:-}/usr/lib/security/pam_gnome_keyring.so missing — install gnome-keyring")
      fi
    fi
    if [[ -z "$missing_kwallet" ]]; then
      keyring_configured=1
      if [[ ! -e "${SESSION_ROOT:-}/usr/lib/security/pam_kwallet5.so" ]]; then
        missing_keyring_mods+=("${SESSION_ROOT:-}/usr/lib/security/pam_kwallet5.so missing — install kwallet-pam")
      fi
    fi
    if [[ ${#missing_keyring_mods[@]} -gt 0 ]]; then
      diag_msg="${missing_keyring_mods[0]}"
      if [[ ${#missing_keyring_mods[@]} -gt 1 ]]; then
        printf -v diag_msg '%s; %s' "${missing_keyring_mods[0]}" "${missing_keyring_mods[1]}"
      fi
      diag_record_check "$json_mode" "PAM keyring module" "fail" "$diag_msg"
      issues=$((issues + 1))
      keyring_issue=1
    fi
    if [[ $keyring_issue -eq 0 && $keyring_configured -eq 1 ]]; then
      diag_record_check "$json_mode" "PAM keyring" "ok" "$LOGIN_FILE"
    fi

    local GNOME_PAM_STATUS_ID="" GNOME_PAM_STATUS_MSG=""
    inspect_gnome_pam_status "$login_content" "$real_user"
    case "$GNOME_PAM_STATUS_ID" in
      configured)
        diag_record_check "$json_mode" "PAM GNOME session type" "ok" "$GNOME_SESSION_TYPE_DEST"
        ;;
      block-present-needs-root)
        diag_record_check "$json_mode" "PAM GNOME session type" "warn" "$GNOME_PAM_STATUS_MSG"
        warnings=$((warnings + 1))
        ;;
      block-present-missing-file)
        printf -v diag_msg 'missing %s referenced by %s — restore with: %s --pam-only --de gnome' "$GNOME_SESSION_TYPE_DEST" "$LOGIN_FILE" "$install_cmd"
        diag_record_check "$json_mode" "PAM GNOME session type" "fail" "$diag_msg"
        issues=$((issues + 1))
        ;;
      edited-block)
        printf -v diag_msg 'incomplete GNOME session-type block in %s — restore with: %s --pam-only --de gnome' "$LOGIN_FILE" "$install_cmd"
        diag_record_check "$json_mode" "PAM GNOME session type" "fail" "$diag_msg"
        issues=$((issues + 1))
        ;;
      file-without-block)
        if [[ "$de" == gnome ]]; then
          printf -v diag_msg '%s — restore PAM block with: %s --pam-only --de gnome' "$GNOME_PAM_STATUS_MSG" "$install_cmd"
          diag_record_check "$json_mode" "PAM GNOME session type" "fail" "$diag_msg"
          issues=$((issues + 1))
        else
          printf -v diag_msg '%s — restore PAM block with: %s --pam-only --de gnome' "$GNOME_PAM_STATUS_MSG" "$install_cmd"
          diag_record_check "$json_mode" "PAM GNOME session type" "warn" "$diag_msg"
          warnings=$((warnings + 1))
        fi
        ;;
      unknown-needs-root)
        if [[ "$de" == gnome ]]; then
          printf -v diag_msg 'GNOME Wayland session-type PAM block missing from %s; %s: %s — fix with: %s --pam-only --de gnome' \
            "$LOGIN_FILE" "$GNOME_SESSION_TYPE_DEST" "$GNOME_PAM_STATUS_MSG" "$install_cmd"
          diag_record_check "$json_mode" "PAM GNOME session type" "fail" "$diag_msg"
          issues=$((issues + 1))
        else
          printf -v diag_msg '%s: %s' "$GNOME_SESSION_TYPE_DEST" "$GNOME_PAM_STATUS_MSG"
          diag_record_check "$json_mode" "PAM GNOME session type" "warn" "$diag_msg"
          warnings=$((warnings + 1))
        fi
        ;;
      not-configured)
        if [[ "$de" == gnome ]]; then
          printf -v diag_msg 'GNOME Wayland session-type PAM block missing from %s — fix with: %s --pam-only --de gnome' "$LOGIN_FILE" "$install_cmd"
          diag_record_check "$json_mode" "PAM GNOME session type" "fail" "$diag_msg"
          issues=$((issues + 1))
        fi
        ;;
    esac
  elif [[ "$LOGIN_PATH_STATE" == "invalid" ]]; then
    printf -v diag_msg '%s — restore pambase or re-run %s %s' "$LOGIN_PATH_REASON" "$install_cmd" "$(pam_restore_hint "$de" "$pam_expected")"
    diag_record_check "$json_mode" "PAM login" "fail" "$diag_msg"
    issues=$((issues + 1))
  elif [[ "$LOGIN_PATH_STATE" == "missing" ]]; then
    printf -v diag_msg '%s is missing — restore pambase or re-run %s %s' "$LOGIN_FILE" "$install_cmd" "$(pam_restore_hint "$de" "$pam_expected")"
    diag_record_check "$json_mode" "PAM login" "fail" "$diag_msg"
    issues=$((issues + 1))
  else
    printf -v diag_msg '%s: unknown (needs root) — inspect PAM lines separately with sudo' "$LOGIN_FILE"
    diag_record_check "$json_mode" "PAM login" "warn" "$diag_msg"
    warnings=$((warnings + 1))
  fi

  if command -v systemctl >/dev/null 2>&1; then
    local getty_state=""
    getty_state="$(systemctl is-enabled getty@tty1.service 2>/dev/null || true)"
    case "$getty_state" in
      masked)
        diag_record_check "$json_mode" "getty@tty1.service" "fail" "masked — unmask with: sudo systemctl unmask getty@tty1.service"
        issues=$((issues + 1))
        ;;
      disabled)
        diag_record_check "$json_mode" "getty@tty1.service" "fail" "disabled — enable with: sudo systemctl enable getty@tty1.service"
        issues=$((issues + 1))
        ;;
      "")
        diag_record_check "$json_mode" "getty@tty1.service" "warn" "unknown systemd state"
        warnings=$((warnings + 1))
        ;;
      *)
        diag_record_check "$json_mode" "getty@tty1.service" "ok" "$getty_state"
        ;;
    esac

    local enabled_dms=() dm_unit dm_state_content dm_state_unreadable=0
    mapfile -t enabled_dms < <(detect_enabled_dms)
    if [[ ! -L "$(dirname -- "$DM_STATE_FILE")" && ! -L "$DM_STATE_FILE" ]]; then
      if [[ -f "$DM_STATE_FILE" && -r "$DM_STATE_FILE" ]]; then
        dm_state_content="$(cat -- "$DM_STATE_FILE")"
        while IFS= read -r dm_unit || [[ -n "$dm_unit" ]]; do
          [[ -n "$dm_unit" ]] || continue
          local dm_short="${dm_unit%.service}"
          if [[ " ${enabled_dms[*]} " != *" $dm_short "* ]] &&
            [[ "$(systemctl is-enabled "$dm_unit" 2>/dev/null || true)" == "enabled" ]]; then
            enabled_dms+=("$dm_short")
          fi
        done <<<"$dm_state_content"
      elif pam_path_needs_sudo "$DM_STATE_FILE" 1; then
        dm_state_unreadable=1
      fi
    fi
    if [[ ${#enabled_dms[@]} -gt 0 ]]; then
      printf -v diag_msg '%s enabled — disable with: sudo systemctl disable %s.service' "${enabled_dms[*]}" "${enabled_dms[0]}"
      diag_record_check "$json_mode" "Display managers" "fail" "$diag_msg"
      issues=$((issues + 1))
    elif [[ $dm_state_unreadable -eq 1 ]]; then
      printf -v diag_msg '%s: unknown (needs root)' "$DM_STATE_FILE"
      diag_record_check "$json_mode" "Display managers" "warn" "$diag_msg"
      warnings=$((warnings + 1))
    else
      diag_record_check "$json_mode" "Display managers" "ok" "none enabled"
    fi
  else
    diag_record_check "$json_mode" "systemd checks" "warn" "systemctl not available"
    warnings=$((warnings + 1))
  fi

  local autologin_out auto_line auto_state="disabled" auto_user="" auto_warnings=() auto_notes=()
  local auto_needs_root=0 auto_login_needs_root=0 auto_other_notes=() auto_warn
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
  local note_item
  for note_item in "${auto_notes[@]}"; do
    if autologin_note_needs_root "$note_item"; then
      auto_needs_root=1
    elif [[ "$note_item" == "Note: cannot read $LOGIN_FILE;"* ]]; then
      auto_login_needs_root=1
    else
      auto_other_notes+=("${note_item#Note: }")
    fi
  done
  local has_keyring_auto_warn=0
  for auto_warn in "${auto_warnings[@]}"; do
    if [[ "$auto_warn" == *"PAM keyring"* ]]; then
      has_keyring_auto_warn=1
      break
    fi
  done
  local auto_details=("${auto_warnings[@]}")
  if [[ "$auto_state" == enabled ]]; then
    if [[ $has_keyring_auto_warn -eq 0 && ( -n "$pam_expected" || $keyring_configured -eq 1 ) ]]; then
      if [[ ${#auto_details[@]} -eq 0 && $auto_needs_root -eq 0 && ${#auto_other_notes[@]} -eq 0 ]]; then
        printf -v diag_msg 'enabled for %s while PAM keyring is configured; autologin leaves keyring locked — disable with: sudo %s --disable' "$auto_user" "$(script_cmd enable-autologin.sh)"
        diag_record_check "$json_mode" "Autologin" "warn" "$diag_msg"
        warnings=$((warnings + 1))
        auto_state="handled"
      else
        auto_details+=("PAM keyring is configured; autologin leaves keyring locked — disable with: sudo $(script_cmd enable-autologin.sh) --disable")
      fi
    fi
    if [[ "$auto_state" == enabled ]]; then
      [[ $auto_needs_root -eq 1 ]] && auto_details+=("$AUTOLOGIN_DROPIN_DIR: unknown (needs root)")
      [[ $auto_login_needs_root -eq 1 && -z "$pam_expected" && $keyring_configured -eq 0 ]] && auto_details+=("$LOGIN_FILE: unknown (needs root)")
      [[ ${#auto_other_notes[@]} -gt 0 ]] && auto_details+=("${auto_other_notes[@]}")
      if [[ ${#auto_details[@]} -gt 0 ]]; then
        local auto_joined=""
        printf -v auto_joined '%s; ' "${auto_details[@]}"
        printf -v diag_msg 'enabled for %s — %s' "$auto_user" "${auto_joined%; }"
        diag_record_check "$json_mode" "Autologin" "warn" "$diag_msg"
        warnings=$((warnings + 1))
      else
        printf -v diag_msg 'enabled for %s' "$auto_user"
        diag_record_check "$json_mode" "Autologin" "ok" "$diag_msg"
      fi
    fi
  elif [[ ${#auto_details[@]} -eq 0 && $auto_needs_root -eq 1 && $auto_login_needs_root -eq 0 && ${#auto_other_notes[@]} -eq 0 ]]; then
    printf -v diag_msg '%s: unknown (needs root)' "$AUTOLOGIN_DROPIN_DIR"
    diag_record_check "$json_mode" "Autologin" "warn" "$diag_msg"
    warnings=$((warnings + 1))
  else
    [[ $auto_needs_root -eq 1 ]] && auto_details+=("$AUTOLOGIN_DROPIN_DIR: unknown (needs root)")
    [[ $auto_login_needs_root -eq 1 ]] && auto_details+=("$LOGIN_FILE: unknown (needs root)")
    [[ ${#auto_other_notes[@]} -gt 0 ]] && auto_details+=("${auto_other_notes[@]}")
    if [[ ${#auto_details[@]} -gt 0 ]]; then
      local auto_joined=""
      printf -v auto_joined '%s; ' "${auto_details[@]}"
      printf -v diag_msg 'disabled — %s' "${auto_joined%; }"
      diag_record_check "$json_mode" "Autologin" "warn" "$diag_msg"
      warnings=$((warnings + 1))
    else
      diag_record_check "$json_mode" "Autologin" "ok" "disabled"
    fi
  fi

  local summary_msg=""
  if [[ $issues -eq 0 && $warnings -eq 0 ]]; then
    summary_msg="Doctor: PASS"
  elif [[ $issues -eq 0 ]]; then
    printf -v summary_msg 'Doctor: PASS (0 issue(s), %d warning(s))' "$warnings"
  elif [[ $warnings -gt 0 ]]; then
    printf -v summary_msg 'Doctor: FAIL (%d issue(s), %d warning(s) found above)' "$issues" "$warnings"
  else
    printf -v summary_msg 'Doctor: FAIL (%d issue(s) found above)' "$issues"
  fi

  if [[ $json_mode -eq 1 ]]; then
    local healthy_bool="false" doc_status="fail"
    if [[ $issues -eq 0 ]]; then
      healthy_bool="true"
      if [[ $warnings -gt 0 ]]; then
        doc_status="warn"
      else
        doc_status="pass"
      fi
    fi
    printf '{\n'
    printf '  "mode": "doctor",\n'
    printf '  "healthy": %s,\n' "$healthy_bool"
    printf '  "status": %s,\n' "$(json_str "$doc_status")"
    printf '  "issues": %d,\n' "$issues"
    printf '  "warnings": %d,\n' "$warnings"
    printf '  "de": %s,\n' "$(json_str_or_null "$de")"
    printf '  "summary": %s,\n' "$(json_str "$summary_msg")"
    if [[ ${#_DIAG_CHECKS[@]} -gt 0 ]]; then
      print_diag_checks_json "${_DIAG_CHECKS[@]}"
    else
      print_diag_checks_json
    fi
    printf '}\n'
  else
    printf '%s\n' "$summary_msg"
  fi
  [[ $issues -eq 0 ]]
}

# Resolve and validate the target desktop and session template for --recover and --fix.
validate_repair_target_de() {
  local caller_flag="$1" target_de="$2" template=""
  if [[ -z "$target_de" ]]; then
    target_de="$(saved_install_de)" || return 1
  fi
  case "$target_de" in
    plasma | gnome | xfce | lxqt | lxde | mate | cinnamon | budgie | i3) ;;
    *)
      if [[ -z "$target_de" || "$target_de" == *[!abcdefghijklmnopqrstuvwxyz0123456789_-]* ]]; then
        log "Unsupported desktop environment for $caller_flag: $target_de"
        return 1
      fi
      ;;
  esac

  template="$(xinitrc_template "$target_de")" || return 1
  if [[ ! -f "$template" ]]; then
    log "Missing session template for $target_de: $template"
    log "Create a custom template first with: $(script_cmd install.sh) --init-template --de $target_de"
    return 1
  fi
  check_template_syntax "$template" || return 1
  check_template_not_self "$target_de" "$template" || return 1
  check_session_commands "$template" || return 1
  REPAIR_TARGET_DE="$target_de"
  REPAIR_TEMPLATE="$template"
}

# Recover user session dotfiles and clear boot-loop pauses cleanly without sudo or package changes.
run_recover() {
  local LC_ALL=C target_de="$1" preview="${2:-0}" setup_shell="${3:-}" resolved_setup_shell=""
  local REPAIR_TARGET_DE="" REPAIR_TEMPLATE=""
  validate_repair_target_de "--recover" "$target_de" || return 1
  target_de="$REPAIR_TARGET_DE"
  if [[ -n "$setup_shell" ]]; then
    validate_setup_shell "$setup_shell" || return 1
    resolved_setup_shell="$(resolve_setup_shell "$setup_shell")" || return 1
  fi

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

  if [[ -n "$setup_shell" ]]; then
    apply_shell_hook "$setup_shell" "$preview" || return 1
  fi

  local real_user="${SUDO_USER:-${USER:-}}" login_shell=""
  [[ -n "$real_user" ]] || real_user="$(id -un 2>/dev/null || true)"
  if [[ -n "$real_user" ]] && command -v getent >/dev/null 2>&1; then
    login_shell="$(getent passwd "$real_user" | cut -d: -f7 || true)"
  fi
  case "$login_shell" in
    *zsh)
      if [[ "$resolved_setup_shell" != "zsh" ]] && ! shell_has_tty1_hook zsh; then
        log "Note: Login shell is $login_shell without a TTY1 trigger in ~/.zprofile; run: $(script_cmd install.sh) --shell-snippet zsh >> ~/.zprofile"
      fi
      ;;
    *fish)
      if [[ "$resolved_setup_shell" != "fish" ]] && ! shell_has_tty1_hook fish; then
        log "Note: Login shell is $login_shell without a TTY1 trigger in ~/.config/fish/config.fish; run: $(script_cmd install.sh) --shell-snippet fish >> ~/.config/fish/config.fish"
      fi
      ;;
  esac

  if [[ $preview -eq 0 ]]; then
    log "Home recovery complete for $target_de. Run '$(script_cmd install.sh) --doctor' to verify PAM and systemd health."
  fi
}

# Read-only ($1=1) or sudo-enabled ($1=0) PAM inspection for --fix, setting FIX_* caller state.
inspect_fix_pam_state() {
  local probe_preview="${1:-1}" target_de="$2" real_user="$3"
  FIX_NEED_PAM_KEYRING=0
  FIX_PAM_BACKEND=""
  FIX_NEED_GNOME_PAM=0
  FIX_GNOME_DE="$target_de"
  FIX_NEED_PAM_PROBE=0

  if [[ -L "$(dirname -- "$PAM_KEYRING_STATE")" || -L "$PAM_KEYRING_STATE" ]]; then
    log "ERROR: $PAM_KEYRING_STATE or its directory is a symlink; lightXDM ignores symlinks."
    return 1
  fi
  if [[ -L "$(dirname -- "$GNOME_SESSION_TYPE_DEST")" || -L "$GNOME_SESSION_TYPE_DEST" ]]; then
    log "ERROR: $GNOME_SESSION_TYPE_DEST or its directory is a symlink; lightXDM ignores symlinks."
    return 1
  fi

  local pam_record="" pam_expected="" pam_mismatch=0 builtin_backend=""
  builtin_backend="$(builtin_de_keyring_backend "$target_de" 2>/dev/null || true)"
  if pam_record="$(read_pam_state_file "$PAM_KEYRING_STATE" "$probe_preview" 2>/dev/null)"; then
    case "$pam_record" in
      gnome | kwallet)
        if [[ -n "$builtin_backend" && "$pam_record" != "$builtin_backend" ]]; then
          pam_mismatch=1
          pam_expected="$builtin_backend"
        else
          pam_expected="$pam_record"
        fi
        ;;
    esac
  elif [[ $probe_preview -eq 1 ]] && pam_path_needs_sudo "$PAM_KEYRING_STATE" 1; then
    FIX_NEED_PAM_PROBE=1
  fi

  local login_content="" LOGIN_PATH_STATE="" LOGIN_PATH_REASON=""
  inspect_login_pam_path "$probe_preview"
  if [[ "$LOGIN_PATH_STATE" == "ok" ]] && login_content="$(read_pam_file "$LOGIN_FILE" "$probe_preview" 2>/dev/null)"; then
    local missing_gnome="" missing_kwallet="" has_gnome_line=0 has_kwallet_line=0
    missing_gnome="$(pam_lines_to_add "pam_gnome_keyring.so" "$PAM_GNOME_KEYRING_AUTH" "$PAM_GNOME_KEYRING_SESSION" "" "$probe_preview" || true)"
    missing_kwallet="$(pam_lines_to_add "pam_kwallet5.so" "$PAM_KWALLET_AUTH" "$PAM_KWALLET_SESSION" "" "$probe_preview" || true)"
    grep -Eq '^[[:space:]]*-?(auth|session)[[:space:]][^#]*pam_gnome_keyring\.so' <<<"$login_content" && has_gnome_line=1
    grep -Eq '^[[:space:]]*-?(auth|session)[[:space:]][^#]*pam_kwallet5\.so' <<<"$login_content" && has_kwallet_line=1
    if [[ -n "$builtin_backend" ]]; then
      if [[ $pam_mismatch -eq 1 ]] ||
        { [[ "$builtin_backend" == gnome ]] && { [[ "$pam_expected" == gnome && -n "$missing_gnome" ]] || [[ $has_gnome_line -eq 1 && -n "$missing_gnome" ]]; }; } ||
        { [[ "$builtin_backend" == kwallet ]] && { [[ "$pam_expected" == kwallet && -n "$missing_kwallet" ]] || [[ $has_kwallet_line -eq 1 && -n "$missing_kwallet" ]]; }; }; then
        FIX_NEED_PAM_KEYRING=1
        FIX_PAM_BACKEND="$builtin_backend"
      fi
    elif [[ "$pam_expected" == gnome && -n "$missing_gnome" ]]; then
      FIX_NEED_PAM_KEYRING=1
      FIX_PAM_BACKEND="gnome"
    elif [[ "$pam_expected" == kwallet && -n "$missing_kwallet" ]]; then
      FIX_NEED_PAM_KEYRING=1
      FIX_PAM_BACKEND="kwallet"
    elif { [[ $has_gnome_line -eq 1 && -n "$missing_gnome" ]]; } || { [[ $has_kwallet_line -eq 1 && -n "$missing_kwallet" ]]; }; then
      FIX_NEED_PAM_KEYRING=1
      if [[ -n "$pam_expected" ]]; then
        FIX_PAM_BACKEND="$pam_expected"
      elif [[ $has_kwallet_line -eq 1 && -n "$missing_kwallet" && $has_gnome_line -eq 0 ]]; then
        FIX_PAM_BACKEND="kwallet"
      else
        FIX_PAM_BACKEND="gnome"
      fi
    fi

    local GNOME_PAM_STATUS_ID="" GNOME_PAM_STATUS_MSG=""
    inspect_gnome_pam_status "$login_content" "$real_user"
    case "$GNOME_PAM_STATUS_ID" in
      configured) ;;
      block-present-needs-root)
        if [[ $probe_preview -eq 1 ]]; then
          FIX_NEED_PAM_PROBE=1
        elif sudo test -L "$GNOME_SESSION_TYPE_DEST"; then
          log "ERROR: $GNOME_SESSION_TYPE_DEST is a symlink; lightXDM ignores symlinks."
          return 1
        elif ! sudo test -f "$GNOME_SESSION_TYPE_DEST"; then
          FIX_NEED_GNOME_PAM=1
          FIX_GNOME_DE="$target_de"
        fi
        ;;
      block-present-missing-file)
        FIX_NEED_GNOME_PAM=1
        FIX_GNOME_DE="$target_de"
        ;;
      edited-block)
        log "ERROR: Edited lightXDM GNOME block in $LOGIN_FILE; remove lightXDM's GNOME lines by hand or restore ${LOGIN_FILE}.lightxdm.bak."
        return 1
        ;;
      file-without-block)
        FIX_NEED_GNOME_PAM=1
        FIX_GNOME_DE="$target_de"
        ;;
      unknown-needs-root)
        if [[ "$target_de" == gnome ]]; then
          FIX_NEED_GNOME_PAM=1
          FIX_GNOME_DE="gnome"
        elif [[ $probe_preview -eq 1 ]]; then
          FIX_NEED_PAM_PROBE=1
        elif sudo test -L "$GNOME_SESSION_TYPE_DEST"; then
          log "ERROR: $GNOME_SESSION_TYPE_DEST is a symlink; lightXDM ignores symlinks."
          return 1
        elif sudo test -e "$GNOME_SESSION_TYPE_DEST"; then
          FIX_NEED_GNOME_PAM=1
          FIX_GNOME_DE="$target_de"
        fi
        ;;
      not-configured)
        if [[ "$target_de" == gnome ]]; then
          FIX_NEED_GNOME_PAM=1
          FIX_GNOME_DE="gnome"
        fi
        ;;
    esac
  elif [[ "$LOGIN_PATH_STATE" == "needs-root" ]]; then
    FIX_NEED_PAM_PROBE=1
  elif [[ "$LOGIN_PATH_STATE" == "invalid" ]]; then
    log "ERROR: $LOGIN_PATH_REASON; lightXDM requires a valid regular file."
    return 1
  elif [[ "$LOGIN_PATH_STATE" == "missing" ]]; then
    log "ERROR: $LOGIN_FILE is missing; lightXDM will not create it. Reinstall pambase or restore ${LOGIN_FILE}.lightxdm.bak."
    return 1
  fi
  return 0
}

# Diagnose and automatically repair home dotfiles, non-bash shell hooks, PAM rules, and systemd/DM state.
run_fix() {
  local LC_ALL=C target_de="$1" preview="${2:-0}" non_interactive="${3:-0}"
  local REPAIR_TARGET_DE="" REPAIR_TEMPLATE="" UPDATE_RUN=0 display_manager_disabled=0
  validate_repair_target_de "--fix" "$target_de" || return 1
  target_de="$REPAIR_TARGET_DE"

  local template="$REPAIR_TEMPLATE" expected_mode="x11"
  if [[ "${template##*/}" == .wayland-session-* ]]; then
    expected_mode="wayland"
  fi

  local real_user="${SUDO_USER:-${USER:-}}" login_shell=""
  [[ -n "$real_user" ]] || real_user="$(id -un 2>/dev/null || true)"
  if [[ -n "$real_user" ]] && command -v getent >/dev/null 2>&1; then
    login_shell="$(getent passwd "$real_user" | cut -d: -f7 || true)"
  fi

  local need_home_recover=0 need_shell_hook=""
  local wl="$HOME/.wayland-session" xi="$HOME/.xinitrc"
  if [[ "$expected_mode" == wayland ]]; then
    if [[ ( -L "$wl" && ( ! -e "$wl" || ! -f "$wl" ) ) || ! -f "$wl" || ! -x "$wl" || ! -r "$wl" ]] ||
      ! check_template_syntax "$wl" >/dev/null 2>&1 ||
      ! check_session_commands "$wl" >/dev/null 2>&1; then
      need_home_recover=1
    fi
  else
    if [[ ( -e "$wl" || -L "$wl" ) && -x "$wl" ]]; then
      need_home_recover=1
    elif [[ ( -L "$xi" && ( ! -e "$xi" || ! -f "$xi" ) ) || ! -f "$xi" || ! -r "$xi" ]] ||
      ! check_template_syntax "$xi" >/dev/null 2>&1 ||
      ! check_session_commands "$xi" >/dev/null 2>&1; then
      need_home_recover=1
    fi
  fi

  case "$login_shell" in
    *bash | "")
      if ! shell_has_tty1_hook bash; then
        need_home_recover=1
      fi
      ;;
    *zsh)
      if ! shell_has_tty1_hook zsh; then
        need_shell_hook="zsh"
      fi
      ;;
    *fish)
      if ! shell_has_tty1_hook fish; then
        need_shell_hook="fish"
      fi
      ;;
  esac

  if [[ -e "$HOME/.config/lightxdm/no-autostart" || -L "$HOME/.config/lightxdm/no-autostart" ]]; then
    need_home_recover=1
  fi

  if [[ -n "$need_shell_hook" ]]; then
    validate_setup_shell "$need_shell_hook" "$preview" || return 1
  fi

  local FIX_NEED_PAM_KEYRING=0 FIX_PAM_BACKEND="" FIX_NEED_GNOME_PAM=0
  local FIX_GNOME_DE="$target_de" FIX_NEED_PAM_PROBE=0
  inspect_fix_pam_state 1 "$target_de" "$real_user" || return 1

  local need_getty_unmask=0 need_getty_enable=0 need_disable_dms=0 need_dm_state_probe=0
  local enabled_dms=() extra_dm_units=() dm_unit dm_state_content
  if command -v systemctl >/dev/null 2>&1; then
    local getty_state=""
    getty_state="$(systemctl is-enabled getty@tty1.service 2>/dev/null || true)"
    case "$getty_state" in
      masked) need_getty_unmask=1 ;;
      disabled) need_getty_enable=1 ;;
    esac

    mapfile -t enabled_dms < <(detect_enabled_dms)
    if [[ ${#enabled_dms[@]} -gt 0 ]]; then
      need_disable_dms=1
    fi
    if [[ -L "$(dirname -- "$DM_STATE_FILE")" || -L "$DM_STATE_FILE" ]]; then
      log "ERROR: $DM_STATE_FILE or its directory is a symlink; lightXDM ignores symlinks."
      return 1
    fi
    if [[ -f "$DM_STATE_FILE" && -r "$DM_STATE_FILE" ]]; then
      dm_state_content="$(cat -- "$DM_STATE_FILE")"
      while IFS= read -r dm_unit || [[ -n "$dm_unit" ]]; do
        [[ -n "$dm_unit" ]] || continue
        local dm_short="${dm_unit%.service}"
        if [[ " ${enabled_dms[*]} " != *" $dm_short "* ]] &&
          [[ "$(systemctl is-enabled "$dm_unit" 2>/dev/null || true)" == "enabled" ]]; then
          extra_dm_units+=("$dm_unit")
        fi
      done <<<"$dm_state_content"
    elif { [[ ! -e "$DM_STATE_FILE" || -f "$DM_STATE_FILE" ]] && pam_path_needs_sudo "$DM_STATE_FILE" 1; }; then
      need_dm_state_probe=1
    fi
    if [[ ${#extra_dm_units[@]} -gt 0 ]]; then
      need_disable_dms=1
    fi
  fi

  local need_sudo=0
  if [[ $FIX_NEED_PAM_KEYRING -eq 1 || $FIX_NEED_GNOME_PAM -eq 1 || $FIX_NEED_PAM_PROBE -eq 1 ||
    $need_getty_unmask -eq 1 || $need_getty_enable -eq 1 || $need_disable_dms -eq 1 ||
    $need_dm_state_probe -eq 1 ]]; then
    need_sudo=1
  fi

  if [[ $preview -eq 1 ]]; then
    if [[ $need_home_recover -eq 0 && -z "$need_shell_hook" && $need_sudo -eq 0 ]]; then
      printf 'Nothing to fix for de=%s (dry run; system is healthy)\n' "$target_de"
      return 0
    fi
    printf 'Fix plan for de=%s (dry run; no files changed):\n' "$target_de"
    if [[ $need_home_recover -eq 1 ]]; then
      run_recover "$target_de" 1 "" || return 1
    fi
    if [[ -n "$need_shell_hook" ]]; then
      apply_shell_hook "$need_shell_hook" 1 || return 1
    fi
    if [[ $FIX_NEED_PAM_PROBE -eq 1 ]]; then
      printf 'PAM probe: unknown (needs root — sudo required during live --fix to inspect %s)\n' "$LOGIN_FILE"
    else
      if [[ $FIX_NEED_PAM_KEYRING -eq 1 ]]; then
        configure_pam "$target_de" 1 "${FIX_PAM_BACKEND:-gnome}" || return 1
      fi
      if [[ $FIX_NEED_GNOME_PAM -eq 1 ]]; then
        configure_gnome_session_type "$FIX_GNOME_DE" "$real_user" 1 1 || return 1
      fi
    fi
    if [[ $need_getty_unmask -eq 1 ]]; then
      printf 'Systemd: sudo systemctl unmask getty@tty1.service\n'
    fi
    if [[ $need_getty_unmask -eq 1 || $need_getty_enable -eq 1 ]]; then
      printf 'Systemd: ensure getty@tty1.service is enabled (sudo systemctl enable getty@tty1.service)\n'
    fi
    if [[ $need_disable_dms -eq 1 ]]; then
      if [[ ${#enabled_dms[@]} -gt 0 ]]; then
        disable_display_managers 1 || return 1
      fi
      for dm_unit in "${extra_dm_units[@]}"; do
        record_and_disable_unit "$dm_unit" 1 || return 1
      done
    fi
    if [[ $need_dm_state_probe -eq 1 ]]; then
      printf 'Display-manager state: unknown (needs root — sudo required during live --fix to inspect %s)\n' "$DM_STATE_FILE"
    fi
    return 0
  fi

  if [[ $need_home_recover -eq 0 && -z "$need_shell_hook" && $need_sudo -eq 0 ]]; then
    log "Nothing to fix for $target_de; verifying with doctor..."
    local healthy_status=0
    run_doctor || healthy_status=$?
    return "$healthy_status"
  fi

  if [[ $need_sudo -eq 1 ]]; then
    check_root || return $?
    authenticate_sudo "$non_interactive" "$real_user"
    if [[ $FIX_NEED_PAM_PROBE -eq 1 ]]; then
      inspect_fix_pam_state 0 "$target_de" "$real_user" || return 1
    fi
    if [[ $need_dm_state_probe -eq 1 ]]; then
      if sudo test -L "$DM_STATE_FILE"; then
        log "ERROR: $DM_STATE_FILE is a symlink; lightXDM ignores symlinks."
        return 1
      fi
      if sudo test -f "$DM_STATE_FILE"; then
        dm_state_content="$(sudo cat -- "$DM_STATE_FILE" 2>/dev/null)" || return 1
        while IFS= read -r dm_unit || [[ -n "$dm_unit" ]]; do
          [[ -n "$dm_unit" ]] || continue
          local dm_short="${dm_unit%.service}"
          if [[ " ${enabled_dms[*]} " != *" $dm_short "* ]] &&
            [[ "$(systemctl is-enabled "$dm_unit" 2>/dev/null || true)" == "enabled" ]]; then
            extra_dm_units+=("$dm_unit")
          fi
        done <<<"$dm_state_content"
        if [[ ${#extra_dm_units[@]} -gt 0 ]]; then
          need_disable_dms=1
        fi
      fi
    fi
  fi

  if [[ $need_home_recover -eq 1 ]]; then
    run_recover "$target_de" 0 "$need_shell_hook" || return 1
  elif [[ -n "$need_shell_hook" ]]; then
    apply_shell_hook "$need_shell_hook" 0 || return 1
  fi

  if [[ $FIX_NEED_PAM_KEYRING -eq 1 ]]; then
    configure_pam "$target_de" 0 "${FIX_PAM_BACKEND:-gnome}" || return 1
  fi
  if [[ $FIX_NEED_GNOME_PAM -eq 1 ]]; then
    configure_gnome_session_type "$FIX_GNOME_DE" "$real_user" 0 1 || return 1
  fi
  if [[ $need_getty_unmask -eq 1 ]]; then
    log "Unmasking getty@tty1.service..."
    sudo systemctl unmask getty@tty1.service || return 1
    if [[ "$(systemctl is-enabled getty@tty1.service 2>/dev/null || true)" == "disabled" ]]; then
      need_getty_enable=1
    fi
  fi
  if [[ $need_getty_enable -eq 1 ]]; then
    log "Enabling getty@tty1.service..."
    sudo systemctl enable getty@tty1.service || return 1
  fi
  if [[ $need_disable_dms -eq 1 ]]; then
    if [[ ${#enabled_dms[@]} -gt 0 ]]; then
      disable_display_managers 0 || return 1
    fi
    for dm_unit in "${extra_dm_units[@]}"; do
      if [[ "$(systemctl is-enabled "$dm_unit" 2>/dev/null || true)" == "enabled" ]]; then
        record_and_disable_unit "$dm_unit" 0 || return 1
      fi
    done
  fi

  local doctor_status=0
  run_doctor || doctor_status=$?
  return "$doctor_status"
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

SHELL_HOOK_BEGIN="# >>> lightXDM TTY1 auto-start >>>"
SHELL_HOOK_END="# <<< lightXDM TTY1 auto-start <<<"

resolve_setup_shell() {
  local spec="$1" real_user login_shell=""
  case "$spec" in
    zsh | fish)
      printf '%s\n' "$spec"
      return 0
      ;;
    auto)
      real_user="${SUDO_USER:-${USER:-}}"
      [[ -n "$real_user" ]] || real_user="$(id -un 2>/dev/null || true)"
      if [[ -n "$real_user" ]] && command -v getent >/dev/null 2>&1; then
        login_shell="$(getent passwd "$real_user" | cut -d: -f7 || true)"
      fi
      case "$login_shell" in
        *zsh)
          printf 'zsh\n'
          return 0
          ;;
        *fish)
          printf 'fish\n'
          return 0
          ;;
        *bash)
          printf 'bash\n'
          return 0
          ;;
        *)
          log "Unsupported or unknown login shell${login_shell:+ ($login_shell)} for --setup-shell auto (pass zsh or fish explicitly)."
          return 1
          ;;
      esac
      ;;
    *)
      log "Invalid shell for --setup-shell: $spec (valid shells: zsh fish auto)"
      return 1
      ;;
  esac
}

shell_hook_relpath() {
  case "$1" in
    zsh) printf '.zprofile\n' ;;
    fish) printf '.config/fish/config.fish\n' ;;
    *) return 1 ;;
  esac
}

check_shell_hook_path_safe() {
  local home="${HOME%/}" rel="$1" preview="${2:-0}" target parent="" seg segs=()
  if [[ -z "${HOME:-}" ]]; then
    log "HOME is unset; cannot locate shell configuration file."
    return 1
  fi
  [[ -n "$home" ]] || home="/"
  if [[ -L "$home" || ! -d "$home" ]]; then
    log "Refusing unsafe home directory for shell hook: $HOME"
    return 1
  fi
  if [[ "$rel" == */* ]]; then
    IFS=/ read -ra segs <<<"${rel%/*}"
    for seg in "${segs[@]}"; do
      [[ -n "$seg" ]] || continue
      parent+="/$seg"
      if [[ -L "${home}${parent}" ]]; then
        log "Refusing symlinked directory for shell hook: ${home}${parent}"
        return 1
      fi
      if [[ -e "${home}${parent}" && ! -d "${home}${parent}" ]]; then
        log "Refusing non-directory path for shell hook: ${home}${parent}"
        return 1
      fi
    done
  fi
  target="${home}/${rel}"
  if [[ -L "$target" ]]; then
    log "Refusing symlinked shell configuration file: $target"
    return 1
  fi
  if [[ -e "$target" && ! -f "$target" ]]; then
    log "Refusing non-regular shell configuration file: $target"
    return 1
  fi
  if [[ -f "$target" && ! -r "$target" ]]; then
    log "Cannot read existing shell configuration file: $target"
    return 1
  fi
  if [[ $preview -eq 0 && -f "$target" && ! -w "$target" ]]; then
    log "Cannot write shell configuration file: $target"
    return 1
  fi
  return 0
}

check_shell_hook_markers() {
  local target="$1" marker_info bc ec bl el
  marker_info="$(awk -v b="$SHELL_HOOK_BEGIN" -v e="$SHELL_HOOK_END" '
    $0 == b { bc++; if (!bl) bl = NR }
    $0 == e { ec++; if (!el) el = NR }
    END { printf "%d %d %d %d\n", bc+0, ec+0, bl+0, el+0 }
  ' "$target")"
  read -r bc ec bl el <<<"$marker_info"
  if [[ $bc -eq 0 && $ec -eq 0 ]]; then
    return 0
  fi
  if [[ $bc -ne 1 || $ec -ne 1 || $bl -ge $el ]]; then
    log "Found incomplete lightXDM hook markers in $target; remove them before rerunning --setup-shell."
    return 1
  fi
  return 2
}

validate_setup_shell() {
  local spec="$1" preview="${2:-0}" resolved rel target home="${HOME%/}"
  resolved="$(resolve_setup_shell "$spec")" || return 1
  if [[ "$resolved" == "bash" ]]; then
    return 0
  fi
  [[ -n "$home" ]] || home="/"
  rel="$(shell_hook_relpath "$resolved")" || return 1
  check_shell_hook_path_safe "$rel" "$preview" || return 1
  target="${home}/${rel}"
  if [[ -f "$target" ]]; then
    local marker_rc=0
    check_shell_hook_markers "$target" || marker_rc=$?
    if [[ $marker_rc -eq 1 ]]; then
      return 1
    fi
  fi
  return 0
}

apply_shell_hook() {
  local spec="$1" preview="${2:-0}" resolved rel target home="${HOME%/}"
  resolved="$(resolve_setup_shell "$spec")" || return 1
  if [[ "$resolved" == "bash" ]]; then
    if [[ $preview -eq 1 ]]; then
      printf 'Shell hook (auto): login shell is bash; ~/.bash_profile handles TTY1 auto-start (no extra hook needed)\n'
    else
      log "Login shell is bash; ~/.bash_profile already handles TTY1 auto-start (no extra shell hook needed)."
    fi
    return 0
  fi

  [[ -n "$home" ]] || home="/"
  rel="$(shell_hook_relpath "$resolved")" || return 1
  check_shell_hook_path_safe "$rel" "$preview" || return 1
  target="${home}/${rel}"

  local block_file tmp="" dest_tmp=""
  block_file="$(mktemp)" || return 1
  {
    printf '%s\n' "$SHELL_HOOK_BEGIN"
    print_shell_snippet "$resolved"
    printf '%s\n' "$SHELL_HOOK_END"
  } >"$block_file"

  if [[ -f "$target" ]]; then
    local marker_rc=0
    check_shell_hook_markers "$target" || marker_rc=$?
    if [[ $marker_rc -eq 1 ]]; then
      rm -f -- "$block_file"
      return 1
    fi
    if [[ $marker_rc -eq 2 ]]; then
      tmp="$(mktemp)" || {
        rm -f -- "$block_file"
        return 1
      }
      if ! awk -v b="$SHELL_HOOK_BEGIN" -v e="$SHELL_HOOK_END" -v bf="$block_file" '
        $0 == b {
          while ((getline line < bf) > 0) print line
          close(bf)
          skip = 1
          next
        }
        $0 == e { skip = 0; next }
        !skip { print }
      ' "$target" >"$tmp"; then
        rm -f -- "$block_file" "$tmp"
        log "Failed updating shell hook in $target."
        return 1
      fi
      if [[ "$(sha256sum < "$tmp")" == "$(sha256sum < "$target")" ]]; then
        rm -f -- "$block_file" "$tmp"
        if [[ $preview -eq 1 ]]; then
          printf 'Shell hook (%s): already up to date in %s\n' "$resolved" "$target"
        else
          log "Shell hook ($resolved) is already up to date in $target."
        fi
        return 0
      fi
      if [[ $preview -eq 1 ]]; then
        rm -f -- "$block_file" "$tmp"
        printf 'Shell hook (%s): would update managed block in %s\n' "$resolved" "$target"
        return 0
      fi
      dest_tmp="$(mktemp "${target%/*}/.${target##*/}.lightxdm.XXXXXX")" || {
        rm -f -- "$block_file" "$tmp"
        return 1
      }
      if ! { cat "$tmp" >"$dest_tmp" && chmod --reference="$target" -- "$dest_tmp" && mv -Tf -- "$dest_tmp" "$target"; }; then
        rm -f -- "$block_file" "$tmp" "$dest_tmp"
        log "Failed writing updated shell hook to $target."
        return 1
      fi
      rm -f -- "$block_file" "$tmp"
      log "Updated lightXDM shell hook ($resolved) in $target."
      return 0
    fi

    if grep -Eq '\.wayland-session|startx' "$target"; then
      rm -f -- "$block_file"
      if [[ $preview -eq 1 ]]; then
        printf 'Shell hook (%s): existing TTY1 trigger found in %s (leaving untouched)\n' "$resolved" "$target"
      else
        log "Existing TTY1 auto-start trigger already present in $target; leaving untouched."
      fi
      return 0
    fi

    if [[ $preview -eq 1 ]]; then
      rm -f -- "$block_file"
      printf 'Shell hook (%s): would append managed block to %s\n' "$resolved" "$target"
      return 0
    fi

    dest_tmp="$(mktemp "${target%/*}/.${target##*/}.lightxdm.XXXXXX")" || {
      rm -f -- "$block_file"
      return 1
    }
    if ! {
      cat "$target" >"$dest_tmp"
      if [[ -s "$target" && "$(tail -c 1 "$target" | wc -l)" -eq 0 ]]; then
        printf '\n' >>"$dest_tmp"
      fi
      cat "$block_file" >>"$dest_tmp"
      chmod --reference="$target" -- "$dest_tmp"
      mv -Tf -- "$dest_tmp" "$target"
    }; then
      rm -f -- "$block_file" "$dest_tmp"
      log "Failed writing shell hook to $target."
      return 1
    fi
    rm -f -- "$block_file"
    log "Installed lightXDM shell hook ($resolved) in $target."
    return 0
  fi

  if [[ $preview -eq 1 ]]; then
    rm -f -- "$block_file"
    printf 'Shell hook (%s): would create %s with managed TTY1 auto-start block\n' "$resolved" "$target"
    return 0
  fi

  mkdir -p -- "${target%/*}" || {
    rm -f -- "$block_file"
    return 1
  }
  dest_tmp="$(mktemp "${target%/*}/.${target##*/}.lightxdm.XXXXXX")" || {
    rm -f -- "$block_file"
    return 1
  }
  if ! { cat "$block_file" >"$dest_tmp" && chmod 644 -- "$dest_tmp" && mv -Tf -- "$dest_tmp" "$target"; }; then
    rm -f -- "$block_file" "$dest_tmp"
    log "Failed writing shell hook to $target."
    return 1
  fi
  rm -f -- "$block_file"
  log "Installed lightXDM shell hook ($resolved) in $target."
  return 0
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
  local setup_shell=""
  local preflight_only=0
  local doctor_only=0
  local recover=0
  local fix_mode=0
  local init_template=0
  local wayland=0
  local from_session=""
  local install_session=""
  local install_session_wayland=0
  local install_session_dest=""
  local install_session_template_exists=0
  local pam_only=0
  local usage="Usage: bash $0 [-h|--help] [--status [--json]] [--list-sessions [--json]] [--shell-snippet <zsh|fish>] [--setup-shell <zsh|fish|auto> [--dry-run]] [--preflight [--json]] [--doctor [--json]] [--recover [--dry-run] [--de <id>] [--setup-shell <zsh|fish|auto>]] [--fix [--dry-run] [--non-interactive] [--de <id>]] [--install-session <path> [--de <custom-id>] [--wayland]] [--de <id>] [--list-packages] [--dry-run] [--non-interactive] [--init-template [--wayland] [--from-session <path>]] [--no-packages] [--keyring <gnome|kwallet>] [--check-keyring <gnome|kwallet>] [--no-keyring] [--autologin] [--update] [--pam-only]"

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
  --install-session <path> validate a custom X11/Wayland .desktop entry, create ~/.config/lightxdm/ template if missing,
                    and run the custom install (--no-packages implied; infers Wayland for wayland-sessions or --wayland;
                    optional --de <custom-id>, --wayland, --dry-run, --non-interactive, --keyring, --no-keyring, --autologin, --setup-shell)
  --wayland         with --init-template --de <custom-id>, create a minimal Wayland template (default command: exec <id>); also accepted with --install-session <path>
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
  --json            with --status, --preflight, --doctor, or --list-sessions, print the read-only result as structured JSON on stdout
  --list-sessions   scan installed X11 and Wayland session entries (system /usr/share and user ~/.local/share),
                    check executables, and suggest --init-template --from-session commands without sudo or changes (use alone, or with --json)
  --shell-snippet <zsh|fish> print the non-bash TTY1 auto-start block for ~/.zprofile or ~/.config/fish/config.fish
                    without sudo or changes (use alone)
  --setup-shell <zsh|fish|auto> install or update the managed TTY1 auto-start hook in ~/.zprofile or
                    ~/.config/fish/config.fish (standalone with optional --dry-run, or combined with install / --recover)
  --preflight       check user/sudo, pacman/systemctl, getty@tty1.service, display managers, login shell,
                    and installed desktops without sudo or changes, then suggest the next command (use alone, or with --json)
  --doctor          verify post-install session launcher, shell hooks, PAM keyring/GNOME rules, .pacnew drift,
                    and systemd boot health without sudo or changes, with fix commands (use alone, or with --json)
  --recover         restore broken or paused home session dotfiles from validated templates without sudo or
                    package/PAM/systemd changes, saving any edits as *.lightxdm-edited* and clearing
                    ~/.config/lightxdm/no-autostart (optional --dry-run, --de <id>, and --setup-shell <zsh|fish|auto>)
  --fix             automatically diagnose and repair broken/paused home dotfiles, missing non-bash shell hooks,
                    PAM keyring/GNOME rules, masked/disabled getty@tty1.service, and re-enabled display
                    managers; preserves valid user-edited templates, elevates with sudo only when system
                    state needs repair or inspection, and re-runs --doctor
                    (optional --dry-run, --non-interactive, and --de <id>)

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
      --setup-shell)
        if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
          log "Missing argument for --setup-shell (valid shells: zsh fish auto)"
          echo "$usage" >&2
          exit 1
        fi
        case "$2" in
          zsh | fish | auto) setup_shell="$2" ;;
          *)
            log "Invalid shell for --setup-shell: $2 (valid shells: zsh fish auto)"
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
      --fix)
        fix_mode=1
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
      --install-session)
        if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
          log "Missing argument for --install-session"
          echo "$usage" >&2
          exit 1
        fi
        install_session="$2"
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

  if [[ $json_output -eq 1 && $status_only -eq 0 && $preflight_only -eq 0 && $doctor_only -eq 0 && $list_sessions -eq 0 ]]; then
    log "--json requires --status, --preflight, --doctor, or --list-sessions."
    echo "$usage" >&2
    exit 1
  fi

  if [[ $status_only -eq 1 ]]; then
    if [[ $de_specified -eq 1 || $list_only -eq 1 || $list_sessions -eq 1 || -n "$shell_snippet" || -n "$setup_shell" ||
      -n "$install_session" || $preflight_only -eq 1 || $doctor_only -eq 1 || $recover -eq 1 || $fix_mode -eq 1 || $dry_run -eq 1 ||
      $non_interactive -eq 1 || $no_packages -eq 1 || $no_keyring -eq 1 || -n "$keyring" || -n "$check_keyring" ||
      $no_polkit_rule -eq 1 || $autologin -eq 1 || $update -eq 1 || $init_template -eq 1 || $wayland -eq 1 ||
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
    if [[ $de_specified -eq 1 || $list_only -eq 1 || -n "$shell_snippet" || -n "$setup_shell" ||
      -n "$install_session" || $preflight_only -eq 1 || $doctor_only -eq 1 || $recover -eq 1 || $fix_mode -eq 1 ||
      $dry_run -eq 1 || $non_interactive -eq 1 || $no_packages -eq 1 || $no_keyring -eq 1 ||
      -n "$keyring" || -n "$check_keyring" || $no_polkit_rule -eq 1 || $autologin -eq 1 ||
      $update -eq 1 || $status_only -eq 1 || $init_template -eq 1 ||
      $wayland -eq 1 || -n "$from_session" || $pam_only -eq 1 ]]; then
      log "--list-sessions cannot be combined with any other option (except --json)."
      echo "$usage" >&2
      exit 1
    fi
    if [[ $json_output -eq 1 ]]; then
      list_desktop_sessions --json
    else
      list_desktop_sessions
    fi
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
    if [[ $de_specified -eq 1 || $list_only -eq 1 || $list_sessions -eq 1 || -n "$shell_snippet" || -n "$setup_shell" ||
      -n "$install_session" || $doctor_only -eq 1 || $recover -eq 1 || $fix_mode -eq 1 || $dry_run -eq 1 ||
      $non_interactive -eq 1 || $no_packages -eq 1 || $no_keyring -eq 1 || -n "$keyring" || -n "$check_keyring" ||
      $no_polkit_rule -eq 1 || $autologin -eq 1 || $update -eq 1 || $status_only -eq 1 || $init_template -eq 1 ||
      $wayland -eq 1 || -n "$from_session" || $pam_only -eq 1 ]]; then
      log "--preflight cannot be combined with any other option (except --json)."
      echo "$usage" >&2
      exit 1
    fi
    local preflight_status=0
    if [[ $json_output -eq 1 ]]; then
      run_preflight --json || preflight_status=$?
    else
      run_preflight || preflight_status=$?
    fi
    return "$preflight_status"
  fi

  if [[ $doctor_only -eq 1 ]]; then
    if [[ $de_specified -eq 1 || $list_only -eq 1 || $list_sessions -eq 1 || -n "$shell_snippet" || -n "$setup_shell" ||
      -n "$install_session" || $preflight_only -eq 1 || $recover -eq 1 || $fix_mode -eq 1 || $dry_run -eq 1 ||
      $non_interactive -eq 1 || $no_packages -eq 1 || $no_keyring -eq 1 || -n "$keyring" || -n "$check_keyring" ||
      $no_polkit_rule -eq 1 || $autologin -eq 1 || $update -eq 1 || $status_only -eq 1 || $init_template -eq 1 ||
      $wayland -eq 1 || -n "$from_session" || $pam_only -eq 1 ]]; then
      log "--doctor cannot be combined with any other option (except --json)."
      echo "$usage" >&2
      exit 1
    fi
    local doctor_status=0
    if [[ $json_output -eq 1 ]]; then
      run_doctor --json || doctor_status=$?
    else
      run_doctor || doctor_status=$?
    fi
    return "$doctor_status"
  fi

  if [[ $recover -eq 1 ]]; then
    if [[ $list_only -eq 1 || $list_sessions -eq 1 || -n "$shell_snippet" || -n "$install_session" || $preflight_only -eq 1 ||
      $doctor_only -eq 1 || $fix_mode -eq 1 || $non_interactive -eq 1 || $no_packages -eq 1 || $no_keyring -eq 1 ||
      -n "$keyring" || -n "$check_keyring" || $no_polkit_rule -eq 1 || $autologin -eq 1 ||
      $update -eq 1 || $init_template -eq 1 || $wayland -eq 1 || -n "$from_session" ||
      $pam_only -eq 1 || $status_only -eq 1 || $json_output -eq 1 ]]; then
      log "--recover takes only optional --dry-run, --de <id>, and --setup-shell <zsh|fish|auto>."
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
    run_recover "$de" "$dry_run" "$setup_shell" || recover_status=$?
    return "$recover_status"
  fi

  if [[ $fix_mode -eq 1 ]]; then
    if [[ $list_only -eq 1 || $list_sessions -eq 1 || -n "$shell_snippet" || -n "$setup_shell" ||
      -n "$install_session" || $preflight_only -eq 1 || $doctor_only -eq 1 || $recover -eq 1 ||
      $no_packages -eq 1 || $no_keyring -eq 1 || -n "$keyring" || -n "$check_keyring" ||
      $no_polkit_rule -eq 1 || $autologin -eq 1 || $update -eq 1 || $init_template -eq 1 ||
      $wayland -eq 1 || -n "$from_session" || $pam_only -eq 1 || $status_only -eq 1 || $json_output -eq 1 ]]; then
      log "--fix takes only optional --dry-run, --non-interactive, and --de <id>."
      echo "$usage" >&2
      exit 1
    fi
    if [[ $de_specified -eq 1 && -z "$de" ]]; then
      log "--de requires a desktop id."
      echo "$usage" >&2
      exit 1
    fi
    if [[ $EUID -eq 0 && $dry_run -eq 0 ]]; then
      log "Do not run --fix as root or with sudo; run it as the user who logs in."
      exit 1
    fi
    local fix_status=0
    run_fix "$de" "$dry_run" "$non_interactive" || fix_status=$?
    return "$fix_status"
  fi

  if [[ $update -eq 1 ]]; then
    if [[ $de_specified -eq 1 || $list_only -eq 1 || $list_sessions -eq 1 || -n "$shell_snippet" || -n "$setup_shell" || -n "$install_session" ||
      $preflight_only -eq 1 || $doctor_only -eq 1 || $recover -eq 1 || $fix_mode -eq 1 || $no_packages -eq 1 || $no_keyring -eq 1 || -n "$keyring" ||
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
        pam_path_needs_sudo "${LOGIN_FILE}.lightxdm.bak" 2 ||
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

  if [[ $wayland -eq 1 && $init_template -eq 0 && -z "$install_session" ]]; then
    log "--wayland requires --init-template --de <custom-id> or --install-session <path>."
    echo "$usage" >&2
    exit 1
  fi

  if [[ $autologin -eq 1 && $no_keyring -eq 0 ]]; then
    log "--autologin requires --no-keyring: autologin passes no password, so PAM cannot unlock the keyring."
    echo "$usage" >&2
    exit 1
  fi

  if [[ $pam_only -eq 1 ]]; then
    if [[ $autologin -eq 1 || $list_only -eq 1 || $init_template -eq 1 || -n "$setup_shell" || -n "$install_session" ]]; then
      log "--pam-only changes only $LOGIN_FILE and cannot be combined with --autologin, --list-packages, --init-template, --setup-shell or --install-session."
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
    if [[ $list_only -eq 1 || $dry_run -eq 1 || $non_interactive -eq 1 || $no_packages -eq 1 || $no_keyring -eq 1 || -n "$keyring" || $no_polkit_rule -eq 1 || $autologin -eq 1 || -n "$setup_shell" || -n "$install_session" ]]; then
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

  if [[ -n "$install_session" ]]; then
    if [[ $list_only -eq 1 ]]; then
      log "--list-packages cannot be combined with --install-session."
      echo "$usage" >&2
      exit 1
    fi
    if [[ -n "$keyring" && $no_keyring -eq 1 ]]; then
      log "--keyring cannot be combined with --no-keyring."
      exit 1
    fi
    local INSTALL_SESSION_DE="" INSTALL_SESSION_WAYLAND=0 INSTALL_SESSION_DEST="" INSTALL_SESSION_TEMPLATE_EXISTS=0
    prepare_install_session "$install_session" "$de" "$de_specified" "$wayland" || exit 1
    de="$INSTALL_SESSION_DE"
    de_specified=1
    no_packages=1
    install_session_wayland="$INSTALL_SESSION_WAYLAND"
    install_session_dest="$INSTALL_SESSION_DEST"
    install_session_template_exists="$INSTALL_SESSION_TEMPLATE_EXISTS"
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

  if [[ -n "$setup_shell" && $de_specified -eq 0 ]]; then
    if [[ $list_only -eq 1 || $no_packages -eq 1 || $no_keyring -eq 1 || $no_polkit_rule -eq 1 ]]; then
      log "Standalone --setup-shell takes only optional --dry-run (or combine with --recover or --de <id>)."
      echo "$usage" >&2
      exit 1
    fi
    if [[ $EUID -eq 0 && $dry_run -eq 0 ]]; then
      log "Do not run --setup-shell standalone as root or with sudo; run it as the user who logs in."
      exit 1
    fi
    local setup_shell_status=0
    apply_shell_hook "$setup_shell" "$dry_run" || setup_shell_status=$?
    return "$setup_shell_status"
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
    if [[ -n "$setup_shell" ]]; then
      log "--list-packages cannot be combined with --setup-shell."
      echo "$usage" >&2
      exit 1
    fi
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

  if [[ $de_specified -eq 1 && -z "$install_session" ]]; then
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
    elif [[ -n "$install_session" ]]; then
      local mode_label="x11" template_action="create" preview_rc=0 preview_tmpl_dir=""
      local SESSION_PREVIEW_TEMPLATE="" SESSION_PREVIEW_DEST=""
      [[ $install_session_wayland -eq 1 ]] && mode_label="wayland"
      [[ $install_session_template_exists -eq 1 ]] && template_action="reuse"
      printf 'Session entry: %s (de=%s, mode=%s, template=%s %s)\n' \
        "$install_session" "$de" "$mode_label" "$template_action" "$install_session_dest"
      if [[ $install_session_template_exists -eq 0 ]]; then
        local preview_tmpl_name=".xinitrc-$de"
        [[ $install_session_wayland -eq 1 ]] && preview_tmpl_name=".wayland-session-$de"
        preview_tmpl_dir="$(mktemp -d)" || return 1
        SESSION_PREVIEW_TEMPLATE="$preview_tmpl_dir/$preview_tmpl_name"
        SESSION_PREVIEW_DEST="$install_session_dest (would create from $install_session)"
        if ! init_xinitrc_template "$de" "$install_session_wayland" "$install_session" "$SESSION_PREVIEW_TEMPLATE" 1; then
          SESSION_PREVIEW_TEMPLATE=""
          SESSION_PREVIEW_DEST=""
          rm -rf -- "$preview_tmpl_dir"
          return 1
        fi
      fi
      preview_install "$de" "$no_packages" "$no_keyring" "$autologin" "$keyring" || preview_rc=$?
      if [[ -n "$preview_tmpl_dir" ]]; then
        SESSION_PREVIEW_TEMPLATE=""
        SESSION_PREVIEW_DEST=""
        rm -rf -- "$preview_tmpl_dir"
      fi
      [[ $preview_rc -eq 0 ]] || return "$preview_rc"
      if [[ -n "$setup_shell" ]]; then
        apply_shell_hook "$setup_shell" 1 || return $?
      fi
    else
      preview_install "$de" "$no_packages" "$no_keyring" "$autologin" "$keyring" || return $?
      if [[ -n "$setup_shell" ]]; then
        apply_shell_hook "$setup_shell" 1 || return $?
      fi
    fi
    return $?
  fi

  if [[ -n "$setup_shell" ]]; then
    validate_setup_shell "$setup_shell" || exit 1
  fi

  local real_user
  real_user="${USER:-$(id -un)}"
  if [[ $UPDATE_SUDO_READY -ne 1 ]]; then
    check_root
    authenticate_sudo "$non_interactive" "$real_user"
  fi

  if [[ -n "$install_session" ]]; then
    check_tty1_getty || exit 1
    if [[ $install_session_template_exists -eq 0 ]]; then
      init_xinitrc_template "$de" "$install_session_wayland" "$install_session" || exit 1
    else
      log "Using existing session template $install_session_dest (preserving customizations)."
    fi
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
  local resolved_setup_shell=""
  if [[ -n "$setup_shell" ]]; then
    install_step="apply_shell_hook"
    apply_shell_hook "$setup_shell" 0 || exit 1
    resolved_setup_shell="$(resolve_setup_shell "$setup_shell")" || exit 1
    completed_steps+=("$install_step")
  fi
  local login_shell shell_profile="" shell_hint="docs/startx-autologin.md" shell_hook_configured=0
  login_shell="$(getent passwd "$real_user" | cut -d: -f7 || true)"
  if [[ -n "$login_shell" && "$login_shell" != *bash ]]; then
    case "$login_shell" in
      *zsh)
        if [[ "$resolved_setup_shell" == "zsh" ]] || shell_has_tty1_hook zsh; then
          shell_hook_configured=1
        else
          shell_profile=".zprofile"
          shell_hint="run '$(script_cmd install.sh) --setup-shell zsh' or '$(script_cmd install.sh) --shell-snippet zsh' (see docs/startx-autologin.md)"
        fi
        ;;
      *fish)
        if [[ "$resolved_setup_shell" == "fish" ]] || shell_has_tty1_hook fish; then
          shell_hook_configured=1
        else
          shell_profile=".config/fish/config.fish"
          shell_hint="run '$(script_cmd install.sh) --setup-shell fish' or '$(script_cmd install.sh) --shell-snippet fish' (see docs/startx-autologin.md)"
        fi
        ;;
      *)
        shell_profile=".profile"
        shell_hint="see docs/startx-autologin.md"
        ;;
    esac
    if [[ $shell_hook_configured -eq 0 ]]; then
      log "WARNING: Login shell for $real_user is $login_shell, which does not read ~/.bash_profile. Add the TTY1 auto-start block to ~/$shell_profile ($shell_hint)."
    fi
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
