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
readonly AUTOLOGIN_DROPIN_DIR="${AUTOLOGIN_DROPIN_DIR:-/etc/systemd/system/getty@tty1.service.d}"
readonly PAM_KWALLET_AUTH="auth       optional   pam_kwallet5.so"
readonly PAM_KWALLET_SESSION="session    optional   pam_kwallet5.so force_run"
readonly PAM_GNOME_KEYRING_AUTH="auth       optional   pam_gnome_keyring.so"
readonly PAM_GNOME_KEYRING_SESSION="session    optional   pam_gnome_keyring.so auto_start"

# --- Functions ---

# Log a message to the console
log() {
  echo "=> $1" >&2
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

  log "Installing required packages for $de..."
  sudo pacman -S --needed --noconfirm "${pkgs[@]}"
}

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

# Back up a pre-existing dotfile once, or save post-install user edits before overwriting
preserve_dotfile() {
  local target="$1"
  shift
  local backup="${target}.lightxdm.bak"
  local absent="${target}.lightxdm.absent"
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    if [[ ! -e "$backup" && ! -L "$backup" && ! -e "$absent" && ! -L "$absent" ]]; then
      if [[ "$absent" == */* && ! -d "${absent%/*}" ]]; then
        mkdir -p -- "${absent%/*}"
      fi
      : > "$absent"
    fi
    return 0
  fi

  local tmpl target_sum=""
  if [[ -f "$target" && ! -L "$target" ]]; then
    target_sum="$(sha256sum < "$target")"
    for tmpl in "$@"; do
      [[ "$tmpl" -ef "$target" ]] && continue
      if [[ -f "$tmpl" && "$target_sum" == "$(sha256sum < "$tmpl")" ]]; then
        return 0
      fi
    done
    if is_past_lightxdm_template "$target" "${target#"$HOME"/}"; then
      return 0
    fi
  fi

  if [[ ! -e "$absent" && ! -L "$absent" ]]; then
    if [[ ! -e "$backup" && ! -L "$backup" ]]; then
      log "Backing up $target to $backup"
      cp -P "$target" "$backup"
      return 0
    fi

    if [[ -L "$target" && -L "$backup" ]]; then
      if [[ "$(readlink "$target")" == "$(readlink "$backup")" ]]; then
        return 0
      fi
    elif [[ -f "$target" && ! -L "$target" && -f "$backup" && ! -L "$backup" ]]; then
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
  cp -P "$target" "$edited"
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

# Create ~/.config/lightxdm/.xinitrc-<id> (or .wayland-session-<id>) to edit: a copy of the
# built-in template, or a custom X11 (from i3) or minimal Wayland template.
init_xinitrc_template() {
  local id="$1" wayland="${2:-0}" dest="$HOME/.config/lightxdm/.xinitrc-$1"
  local from_session="${3:-}" exec_line="exec $1" current_desktop="$1"
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
    if [[ ! -f "$from_session" || ! -r "$from_session" ]]; then
      log "Cannot read session entry: $from_session"
      return 1
    fi
    local line key value in_desktop=0 exec_seen=0 desktop_seen=0 exec_value=""
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
        Exec)
          if [[ $exec_seen -eq 1 ]]; then
            log "Duplicate Exec in [Desktop Entry]: $from_session"
            return 1
          fi
          exec_seen=1
          exec_value="$value"
          ;;
        DesktopNames)
          if [[ $desktop_seen -eq 1 || -z "${value%%;*}" ]]; then
            log "Invalid DesktopNames in [Desktop Entry]: $from_session"
            return 1
          fi
          desktop_seen=1
          current_desktop="${value%%;*}"
          ;;
      esac
    done <"$from_session"
    # This deliberately supports only literal words and whole double-quoted words.
    # Never interpret desktop entries as shell code or expand desktop field codes.
    if [[ $exec_seen -eq 0 || "$exec_value" == *%* || "$exec_value" == *\\* ]]; then
      log "Missing or unsupported Exec in [Desktop Entry] (field codes and backslash escapes are refused): $from_session"
      return 1
    fi
    local remaining="$exec_value" word quoted_word='^"([^"]*)"([[:space:]]|$)'
    local exec_args=()
    while :; do
      remaining="${remaining#"${remaining%%[![:space:]]*}"}"
      [[ -n "$remaining" ]] || break
      if [[ "$remaining" == \"* ]]; then
        if [[ ! "$remaining" =~ $quoted_word ]]; then
          log "Unsupported quoting in Exec: $from_session"
          return 1
        fi
        word="${BASH_REMATCH[1]}"
        remaining="${remaining:${#BASH_REMATCH[0]}}"
      else
        word="${remaining%%[[:space:]]*}"
        remaining="${remaining:${#word}}"
        if [[ "$word" == *\"* || "$word" == *"'"* ]]; then
          log "Unsupported quoting in Exec: $from_session"
          return 1
        fi
      fi
      exec_args+=("$word")
    done
    if [[ ${#exec_args[@]} -eq 0 || -z "${exec_args[0]}" ]]; then
      log "Empty Exec in [Desktop Entry]: $from_session"
      return 1
    fi
    printf -v exec_line '%q ' "${exec_args[@]}"
    exec_line="exec ${exec_line% }"
  fi
  mkdir -p "$HOME/.config/lightxdm"
  case "$id" in
    plasma | gnome | budgie)
      cp -- "$SCRIPT_DIR/dotfiles/.wayland-session-$id" "$dest"
      chmod 755 "$dest"
      log "Created $dest from the built-in $id template. Edit it, then run: bash install.sh --de $id"
      ;;
    xfce | lxqt | lxde | mate | cinnamon | i3)
      cp -- "$SCRIPT_DIR/dotfiles/.xinitrc-$id" "$dest"
      chmod 755 "$dest"
      log "Created $dest from the built-in $id template. Edit it, then run: bash install.sh --de $id"
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
      log "Created $dest for $id. Check its exec line, then run: bash install.sh --no-packages --de $id"
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

# Check startup commands before changing the user's session configuration
check_session_commands() {
  local template="$1" base="${1##*/}" line session_line="" session_command package
  if [[ ! -r "$template" ]]; then
    log "Cannot read $template; fix its permissions and re-run."
    return 1
  fi
  if [[ "$base" == .wayland-session-* ]]; then
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

# Preview or preserve and install a dotfile, using the same destination and templates.
copy_dotfile() {
  local preview="$1" mode="$2" source="$3" target="$4"
  shift 4
  if [[ "$preview" == 1 ]]; then
    printf 'Dotfile: %s\n' "$target"
    return 0
  fi
  if [[ $# -eq 0 ]]; then
    preserve_dotfile "$target" "$source"
  else
    preserve_dotfile "$target" "$@"
  fi
  install -Dm"$mode" "$source" "$target"
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
  copy_dotfile "$preview" 644 "$SCRIPT_DIR/dotfiles/.bash_profile" "$user_home/.bash_profile"

  if [[ "$de" == "plasma" ]]; then
    copy_dotfile "$preview" 744 "$SCRIPT_DIR/dotfiles/.gpg-agent-gnome" "$user_home/.gpg-agent-kwallet"
  else
    copy_dotfile "$preview" 744 "$SCRIPT_DIR/dotfiles/.gpg-agent-gnome" "$user_home/.gpg-agent-gnome"
  fi
  # The helper runs before a Wayland compositor starts; this re-runs its refresh inside the session.
  copy_dotfile "$preview" 644 "$SCRIPT_DIR/dotfiles/lightxdm-gpg-agent-tty.desktop" "$user_home/.config/autostart/lightxdm-gpg-agent-tty.desktop"

  local template base
  template="$(xinitrc_template "$de")"
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
      copy_dotfile "$preview" 755 "$template" "$user_home/.wayland-session" "${wayland_templates[@]}"
    else
      local xinitrc_templates=("$SCRIPT_DIR"/dotfiles/.xinitrc-*)
      if [[ -e "$user_home/.xinitrc.lightxdm.bak" || -L "$user_home/.xinitrc.lightxdm.bak" ||
        -e "$user_home/.xinitrc.lightxdm.absent" || -L "$user_home/.xinitrc.lightxdm.absent" ]]; then
        xinitrc_templates=("$HOME"/.config/lightxdm/.xinitrc-* "${xinitrc_templates[@]}")
      fi
      copy_dotfile "$preview" 755 "$template" "$user_home/.xinitrc" "${xinitrc_templates[@]}"

      local wl_session="$user_home/.wayland-session"
      # An executable ~/.wayland-session would start instead of startx, so move it aside like
      # ~/.xinitrc; skip absent files so X11-only homes get no .lightxdm.absent marker.
      if [[ -e "$wl_session" || -L "$wl_session" ]]; then
        local wl_templates=("$SCRIPT_DIR"/dotfiles/.wayland-session-* "$user_home"/.config/lightxdm/.wayland-session-*)
        if [[ $preview -eq 1 ]]; then
          printf 'Remove dotfile (preserving existing content): %s\n' "$wl_session"
        else
          preserve_dotfile "$wl_session" "${wl_templates[@]}"
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

# Installs before 2026-11-03 backed up to .lightxde.bak.<epoch>; adopt the oldest one as the
# original so a re-install does not back up a login file that already holds old keyring lines.
legacy_pam_backup_candidate() {
  local backup_file="${LOGIN_FILE}.lightxdm.bak" old_backup epoch oldest_epoch=""
  if [[ -e "$backup_file" || -L "$backup_file" ]]; then
    return 0
  fi
  # Without old keyring lines in the login file, an uninstall already restored the original;
  # a newer leftover backup may hold keyring lines and must not become the original.
  grep -Fxq -e "$PAM_KWALLET_AUTH" -e "$PAM_KWALLET_SESSION" -e "$PAM_GNOME_KEYRING_AUTH" \
    -e "$PAM_GNOME_KEYRING_SESSION" -e "auth       optional   pam_gnome_keyring.so auto_start" \
    -- "$LOGIN_FILE" 2>/dev/null || return 0
  for old_backup in "${LOGIN_FILE}".lightxde.bak.*; do
    epoch="${old_backup##*.lightxde.bak.}"
    if [[ -f "$old_backup" && "$epoch" =~ ^[0-9]+$ ]] && { [[ -z "$oldest_epoch" ]] || ((10#$epoch < 10#$oldest_epoch)); }; then
      oldest_epoch="$epoch"
    fi
  done
  if [[ -n "$oldest_epoch" ]]; then
    printf '%s\n' "${LOGIN_FILE}.lightxde.bak.${oldest_epoch}"
  fi
}

adopt_legacy_pam_backup() {
  local old_backup
  old_backup="$(legacy_pam_backup_candidate)"
  if [[ -n "$old_backup" ]]; then
    log "Using $old_backup as the original $LOGIN_FILE backup."
    sudo mv -- "$old_backup" "${LOGIN_FILE}.lightxdm.bak" || return 1
  fi
}

# Print only the keyring rules missing from the current login stack.
pam_lines_to_add() {
  local module_re="${1//./\\.}" auth_line="$2" session_line="$3"
  if ! grep -Eq "^[[:space:]]*-?auth[[:space:]][^#]*${module_re}" "$LOGIN_FILE"; then
    printf '%s\n' "$auth_line"
  fi
  if ! grep -Eq "^[[:space:]]*-?session[[:space:]][^#]*${module_re}" "$LOGIN_FILE"; then
    printf '%s\n' "$session_line"
  fi
}

# Print other keyring rules introduced since the original backup.
pam_lines_to_remove() {
  local other_module="$1" other_auth_line="$2" other_session_line="$3"
  local backup_file="${LOGIN_FILE}.lightxdm.bak" other_line
  local other_lines=("$other_auth_line" "$other_session_line")
  if [[ ! -e "$backup_file" && ! -L "$backup_file" ]]; then
    backup_file="$(legacy_pam_backup_candidate)"
  fi
  [[ -f "$backup_file" ]] || return 0
  if [[ "$other_module" == "pam_gnome_keyring.so" ]]; then
    other_lines+=("auth       optional   pam_gnome_keyring.so auto_start")
  fi
  for other_line in "${other_lines[@]}"; do
    if grep -Fxq -- "$other_line" "$LOGIN_FILE" && ! grep -Fxq -- "$other_line" "$backup_file"; then
      printf '%s\n' "$other_line"
    fi
  done
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
  local module auth_line session_line other_module other_auth_line other_session_line
  case "$de" in
    plasma) keyring=kwallet ;;
    gnome | xfce | lxqt | lxde | mate | cinnamon | budgie | i3) keyring=gnome ;;
  esac
  case "$keyring" in
    kwallet)
      module="pam_kwallet5.so"
      auth_line="$PAM_KWALLET_AUTH"
      session_line="$PAM_KWALLET_SESSION"
      other_module="pam_gnome_keyring.so"
      other_auth_line="$PAM_GNOME_KEYRING_AUTH"
      other_session_line="$PAM_GNOME_KEYRING_SESSION"
      ;;
    *)
      module="pam_gnome_keyring.so"
      auth_line="$PAM_GNOME_KEYRING_AUTH"
      session_line="$PAM_GNOME_KEYRING_SESSION"
      other_module="pam_kwallet5.so"
      other_auth_line="$PAM_KWALLET_AUTH"
      other_session_line="$PAM_KWALLET_SESSION"
      ;;
  esac

  if [[ $preview -eq 1 ]]; then
    local additions removals removal
    if [[ -e "${LOGIN_FILE}.lightxdm.bak" && ! -r "${LOGIN_FILE}.lightxdm.bak" ]]; then
      printf '  removals: unknown (needs root)\n'
    else
      removals="$(pam_lines_to_remove "$other_module" "$other_auth_line" "$other_session_line")"
      while IFS= read -r removal; do
        [[ -n "$removal" ]] && printf '  remove: %s\n' "$removal"
      done <<<"$removals"
    fi
    additions="$(pam_lines_to_add "$module" "$auth_line" "$session_line")"
    printf '%s\n' "${additions:-  no lines to add (already configured)}"
    return 0
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
  if [[ -f "$backup_file" ]]; then
    local pam_sed=() other_line
    while IFS= read -r other_line; do
      [[ -n "$other_line" ]] && pam_sed+=(-e "/^${other_line//./\\.}\$/d")
    done < <(pam_lines_to_remove "$other_module" "$other_auth_line" "$other_session_line")
    if [[ ${#pam_sed[@]} -gt 0 ]]; then
      sudo sed -i --follow-symlinks "${pam_sed[@]}" "$LOGIN_FILE"
      log "Removed $other_module from $LOGIN_FILE."
    fi
  fi

  local lines_to_add=()
  mapfile -t lines_to_add < <(pam_lines_to_add "$module" "$auth_line" "$session_line")

  if [[ ${#lines_to_add[@]} -gt 0 ]]; then
    if [[ ! -e "$backup_file" ]]; then
      log "Backing up $LOGIN_FILE to $backup_file"
      sudo cp "$LOGIN_FILE" "$backup_file"
    fi
    if [[ -s "$LOGIN_FILE" && -n "$(tail -c 1 "$LOGIN_FILE")" ]]; then
      printf '\n' | sudo tee -a "$LOGIN_FILE" > /dev/null
    fi
    printf '%s\n' "${lines_to_add[@]}" | sudo tee -a "$LOGIN_FILE" > /dev/null
    log "Configured $module in $LOGIN_FILE."
  else
    log "PAM configuration for $module already exists. Skipping."
  fi

  # Autologin passes no password, so keyring unlock cannot work alongside it.
  local drop_in
  for drop_in in "$AUTOLOGIN_DROPIN_DIR"/*.conf; do
    if [[ -f "$drop_in" ]] && grep -Eqs '^[[:space:]]*ExecStart[[:space:]]*=.*--autologin' "$drop_in"; then
      log "WARNING: TTY1 autologin is enabled ($drop_in); it cannot unlock the keyring. Disable it with 'sudo bash enable-autologin.sh --disable', or keep autologin and remove the keyring lines with 'sudo bash uninstall.sh --keyring-only'."
      break
    fi
  done
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
  local has_block=0
  if [[ -f "$LOGIN_FILE" && ( $preview -eq 0 || -r "$LOGIN_FILE" ) ]] && grep -Fxq -- "$marker" "$LOGIN_FILE"; then
    has_block=1
  fi
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
      done < "$LOGIN_FILE"
    fi
  }
  if [[ $preview -eq 1 ]]; then
    validate_gnome_block || return 1
    if [[ "$de" == gnome && $no_keyring -eq 1 && -r "$LOGIN_FILE" ]] &&
      ! grep -Eq '^[[:space:]]*-?session[[:space:]]' "$LOGIN_FILE"; then
      log "ERROR: No session line in $LOGIN_FILE; lightXDM will not change it."
      return 1
    fi
    printf 'GNOME session type: %s\n' "$LOGIN_FILE"
    if [[ ! -r "$LOGIN_FILE" ]]; then
      printf '  existing block: unknown (needs root)\n'
    fi
    if [[ "$de" == gnome ]]; then
      printf '%s\n' "${block[@]}"
      printf 'Session-type file: %s (from %s)\n' "$GNOME_SESSION_TYPE_DEST" "$SCRIPT_DIR/pam/gnome-session-type.conf"
    else
      if [[ $has_block -eq 1 ]]; then
        printf '  remove the lightXDM GNOME block\n'
      fi
      if [[ -e "$GNOME_SESSION_TYPE_DEST" ]]; then
        printf '  remove %s\n' "$GNOME_SESSION_TYPE_DEST"
      fi
      if [[ $has_block -eq 0 && -r "$LOGIN_FILE" && ! -e "$GNOME_SESSION_TYPE_DEST" ]]; then
        printf '  no GNOME configuration to remove\n'
      fi
    fi
    return 0
  fi
  if [[ "$de" != gnome && $has_block -eq 0 ]]; then
    if [[ -e "$GNOME_SESSION_TYPE_DEST" ]]; then
      sudo rm -f -- "$GNOME_SESSION_TYPE_DEST" || return 1
    fi
    return 0
  fi
  if [[ ! -f "$LOGIN_FILE" ]]; then
    log "ERROR: $LOGIN_FILE is missing; lightXDM will not create it."
    return 1
  fi
  validate_gnome_block || return 1
  adopt_legacy_pam_backup || return 1

  local tmp line newline inserted=0 block_line=0
  tmp="$(mktemp)" || return 1
  trap 'rm -f -- "$tmp"' EXIT
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
  done < "$LOGIN_FILE" > "$tmp"

  if [[ "$de" == gnome && $inserted -eq 0 ]]; then
    log "ERROR: No session line in $LOGIN_FILE; lightXDM will not change it."
    return 1
  fi
  local changed=0 backup="${LOGIN_FILE}.lightxdm.bak"
  if [[ "$(sha256sum < "$tmp")" != "$(sha256sum < "$LOGIN_FILE")" ]]; then
    changed=1
    if [[ ! -e "$backup" ]]; then
      log "Backing up $LOGIN_FILE to $backup"
      sudo cp "$LOGIN_FILE" "$backup" || return 1
    fi
  fi
  if [[ "$de" == gnome ]]; then
    local src="$SCRIPT_DIR/pam/gnome-session-type.conf"
    if [[ ! -f "$GNOME_SESSION_TYPE_DEST" ]] ||
      [[ "$(sha256sum < "$src")" != "$(sha256sum < "$GNOME_SESSION_TYPE_DEST")" || "$(stat -c %a "$GNOME_SESSION_TYPE_DEST")" != 644 ]]; then
      sudo install -Dm644 "$src" "$GNOME_SESSION_TYPE_DEST" || return 1
    fi
  fi
  if [[ $changed -eq 1 ]]; then
    # shellcheck disable=SC2024  # the temporary input file belongs to the calling user
    sudo tee "$LOGIN_FILE" < "$tmp" > /dev/null || return 1
    log "Configured GNOME session type in $LOGIN_FILE for $de."
  fi
  if [[ "$de" != gnome && -e "$GNOME_SESSION_TYPE_DEST" ]]; then
    sudo rm -f -- "$GNOME_SESSION_TYPE_DEST" || return 1
  fi
)

# Record a display manager before disabling it
record_and_disable_unit() {
  local unit="$1"
  if [[ "${2:-0}" == 1 ]]; then
    printf 'Display manager: %s\n' "$unit"
    return 0
  fi
  if ! sudo grep -Fxq -- "$unit" "$DM_STATE_FILE" 2>/dev/null; then
    printf '%s\n' "$unit" | sudo tee -a "$DM_STATE_FILE" > /dev/null || return
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
  if [[ $preview -eq 0 ]]; then
    log "Disabling any installed display managers..."
    sudo mkdir -p "$(dirname -- "$DM_STATE_FILE")"
  fi
  local dm dm_unit recorded_units
  local disabled_dms=()
  for dm in "${DM_LIST[@]}"; do
    if grep -q -- "${dm}.service" < <(systemctl list-unit-files); then
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
    printf 'Display-manager state file: %s\n' "$DM_STATE_FILE"
    if [[ -e "$DM_STATE_FILE" && ! -r "$DM_STATE_FILE" ]]; then
      printf '  existing records: unknown (needs root)\n'
    fi
    return 0
  fi
  if [[ ${#disabled_dms[@]} -gt 0 ]]; then
    display_manager_disabled=1
    log "Disabled display manager(s): ${disabled_dms[*]}"
    log "Your current session will not be interrupted."
  else
    log "No enabled display managers found."
  fi
  recorded_units="$(sudo cat -- "$DM_STATE_FILE" 2>/dev/null)" || recorded_units=""
  while IFS= read -r dm_unit || [[ -n "$dm_unit" ]]; do
    if [[ -n "$dm_unit" ]] && systemctl is-active --quiet "$dm_unit"; then
      display_manager_disabled=1
      break
    fi
  done <<<"$recorded_units"
}

# Resolve the install using the configuration helpers' read-only preview paths.
preview_install() {
  local de="$1" no_packages="$2" no_keyring="$3" autologin="$4" keyring="${5:-}" template real_user
  template="$(xinitrc_template "$de")" || return 1
  check_template_syntax "$template" || return 1
  check_tty1_getty || return 1
  real_user="${USER:-$(id -un)}"
  printf 'Desktop: %s\nTemplate: %s\n' "$de" "$template"
  if [[ ! -r "$template" ]]; then
    printf '  template contents: unknown (needs root)\n'
  fi
  copy_dotfiles "$de" 1 || return 1
  if [[ $no_packages -eq 1 ]]; then
    printf 'Packages: skipped (--no-packages)\n'
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
}

# --- Main ---

main() {
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
  local init_template=0
  local wayland=0
  local from_session=""
  local usage="Usage: bash $0 [-h|--help] [--de <id>] [--list-packages] [--dry-run] [--non-interactive] [--init-template [--wayland] [--from-session <path>]] [--no-packages] [--keyring <gnome|kwallet>] [--check-keyring <gnome|kwallet>] [--no-keyring] [--autologin]"

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

uninstall.sh reverts these changes; installed packages stay.
EOF
        exit 0
        ;;
      --list-packages)
        list_only=1
        shift
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
      --init-template)
        init_template=1
        shift
        ;;
      --wayland)
        wayland=1
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
              log "For a custom session, create its template first: bash install.sh --init-template --de $de"
            else
              log "Custom sessions need --no-packages (install their packages yourself): bash install.sh --no-packages --de $de"
            fi
          fi
          exit 1
        fi
        ;;
    esac
  fi

  if [[ $dry_run -eq 1 ]]; then
    preview_install "$de" "$no_packages" "$no_keyring" "$autologin" "$keyring"
    return $?
  fi

  check_root
  # Defined after check_root, whose `command -v sudo` must still find the real binary.
  if [[ $non_interactive -eq 1 ]]; then
    sudo() { command sudo -n "$@"; }
  fi

  # --- Wheel group and sudoers check ---
  local real_user
  real_user="${USER:-$(id -un)}"

  if ! grep -qx wheel < <(id -nG "$real_user" | tr ' ' '\n'); then
    log "ERROR: User '$real_user' is not in the 'wheel' group. Sudo and polkit rules will not work."
    log "Add the user to the wheel group as root, then log out and back in: su -c 'usermod -aG wheel $real_user'"
    exit 1
  fi

  # Request sudo credentials upfront
  log "Requesting sudo credentials upfront (sudo -v)..."
  if ! sudo -v; then
    log "ERROR: Failed to authenticate with sudo. Exiting."
    log "On Arch the wheel rule in /etc/sudoers ships commented out: run visudo as root (for example su -c 'EDITOR=nano visudo') and uncomment %wheel ALL=(ALL:ALL) ALL"
    exit 1
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
  if [[ $is_wayland -eq 1 ]]; then
    if [[ ! -L "$HOME/.wayland-session" && "$template" -ef "$HOME/.wayland-session" ]]; then
      log "The template for $de is ~/.wayland-session itself: $template. Installation aborted."
      exit 1
    fi
  elif [[ ! -L "$HOME/.xinitrc" && "$template" -ef "$HOME/.xinitrc" ]]; then
    log "The template for $de is ~/.xinitrc itself: $template. Installation aborted."
    exit 1
  fi

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
  local login_shell shell_profile=""
  login_shell="$(getent passwd "$real_user" | cut -d: -f7 || true)"
  if [[ -n "$login_shell" && "$login_shell" != *bash ]]; then
    case "$login_shell" in
      *zsh)
        shell_profile=".zprofile"
        ;;
      *fish)
        shell_profile=".config/fish/config.fish"
        ;;
      *)
        shell_profile=".profile"
        ;;
    esac
    log "WARNING: Login shell for $real_user is $login_shell, which does not read ~/.bash_profile. Add the TTY1 auto-start block to ~/$shell_profile (zsh and fish snippets: docs/startx-autologin.md)."
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
    unlock_summary+="; TTY1 autologin is enabled (sudo bash enable-autologin.sh --disable reverts it)"
  fi

  trap - EXIT
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
- Add the TTY1 auto-start block to ~/$shell_profile (see docs/startx-autologin.md), then $test_summary_after_then

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
