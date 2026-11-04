#!/usr/bin/env bash
# lightXDM install script for Arch Linux
# Installs a minimal DE, configures auto-login, KWallet, Polkit, and PAM
set -e

# --- Configuration ---
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly DM_LIST=(sddm lightdm gdm lxdm)
readonly DISPLAY_MANAGER_LINK="${DISPLAY_MANAGER_LINK:-/etc/systemd/system/display-manager.service}"
readonly DM_STATE_FILE="${DM_STATE_FILE:-/etc/lightxdm/disabled-display-managers}"
readonly LOGIN_FILE="${LOGIN_FILE:-/etc/pam.d/login}"
readonly PAM_KWALLET_AUTH="auth       optional   pam_kwallet5.so"
readonly PAM_KWALLET_SESSION="session    optional   pam_kwallet5.so force_run"
readonly PAM_GNOME_KEYRING_AUTH="auth       optional   pam_gnome_keyring.so"
readonly PAM_GNOME_KEYRING_SESSION="session    optional   pam_gnome_keyring.so auto_start"
readonly POLKIT_RULE_SRC="$SCRIPT_DIR/polkit/49-nopasswd.rules"
readonly POLKIT_RULE_DEST="${POLKIT_RULE_DEST:-/etc/polkit-1/rules.d/49-nopasswd.rules}"

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
    exit 1
  fi
}

# Detect the installed desktop environment
detect_de() {
  local pair pkg de
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
      return 0
    fi
  done
  echo "unknown"
}

# Prompt user to select a DE
prompt_de_selection() {
  local PS3 opt i
  local options=("XFCE" "LXQt" "LXDE" "MATE" "Cinnamon" "i3" "Quit")
  local ids=(xfce lxqt lxde mate cinnamon i3)

  log "No supported desktop environment detected."
  PS3="Please select a desktop environment to install: "
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
      pkgs=(plasma-desktop konsole dolphin kwallet-pam polkit-kde-agent)
      ;;
    gnome)
      pkgs=(gnome-shell gnome-session gnome-control-center nautilus gnome-terminal gnome-keyring polkit-gnome)
      ;;
    xfce)
      pkgs=(xfce4 xfce4-session xfce4-terminal gnome-keyring polkit-gnome)
      ;;
    lxqt)
      pkgs=(lxqt xdg-utils lxterminal gnome-keyring lxqt-policykit)
      ;;
    lxde)
      pkgs=(lxde-common lxsession lxpanel openbox pcmanfm lxterminal gnome-keyring polkit-gnome)
      ;;
    mate)
      pkgs=(mate mate-terminal gnome-keyring polkit-gnome)
      ;;
    cinnamon)
      pkgs=(cinnamon gnome-terminal gnome-keyring polkit-gnome)
      ;;
    budgie)
      pkgs=(budgie-desktop gnome-terminal gnome-keyring polkit-gnome)
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

# Print the .xinitrc template path for a session id
xinitrc_template() {
  if [[ -f "$HOME/.config/lightxdm/.xinitrc-$1" ]]; then
    printf '%s\n' "$HOME/.config/lightxdm/.xinitrc-$1"
  else
    printf '%s\n' "$SCRIPT_DIR/dotfiles/.xinitrc-$1"
  fi
}

# Copy dotfiles to the user's home directory
copy_dotfiles() {
  local de
  de=$1
  local user_home
  user_home=$HOME

  log "Copying dotfiles to $user_home..."
  preserve_dotfile "$user_home/.bash_profile" "$SCRIPT_DIR/dotfiles/.bash_profile"
  install -Dm644 "$SCRIPT_DIR/dotfiles/.bash_profile" "$user_home/.bash_profile"

  if [[ "$de" == "plasma" ]]; then
    preserve_dotfile "$user_home/.gpg-agent-kwallet" "$SCRIPT_DIR/dotfiles/.gpg-agent-kwallet"
    install -Dm744 "$SCRIPT_DIR/dotfiles/.gpg-agent-kwallet" "$user_home/.gpg-agent-kwallet"
  else
    preserve_dotfile "$user_home/.gpg-agent-gnome" "$SCRIPT_DIR/dotfiles/.gpg-agent-gnome"
    install -Dm744 "$SCRIPT_DIR/dotfiles/.gpg-agent-gnome" "$user_home/.gpg-agent-gnome"
  fi

  local template
  template="$(xinitrc_template "$de")"
  if [[ -f "$template" ]]; then
    local xinitrc_templates=("$SCRIPT_DIR"/dotfiles/.xinitrc-*)
    if [[ -e "$user_home/.xinitrc.lightxdm.bak" || -L "$user_home/.xinitrc.lightxdm.bak" ||
      -e "$user_home/.xinitrc.lightxdm.absent" || -L "$user_home/.xinitrc.lightxdm.absent" ]]; then
      xinitrc_templates=("$HOME"/.config/lightxdm/.xinitrc-* "${xinitrc_templates[@]}")
    fi
    preserve_dotfile "$user_home/.xinitrc" "${xinitrc_templates[@]}"
    install -Dm755 "$template" "$user_home/.xinitrc"
  else
    log "No .xinitrc template for $de. Please create $template for proper session startup."
    return 1
  fi
}

# Configure PAM for KWallet/GNOME Keyring auto-unlock
configure_pam() {
  local de
  de=$1

  log "Configuring PAM for $de..."
  local module auth_line session_line
  case "$de" in
    plasma)
      module="pam_kwallet5.so"
      auth_line="$PAM_KWALLET_AUTH"
      session_line="$PAM_KWALLET_SESSION"
      ;;
    *)
      module="pam_gnome_keyring.so"
      auth_line="$PAM_GNOME_KEYRING_AUTH"
      session_line="$PAM_GNOME_KEYRING_SESSION"
      ;;
  esac

  local module_re="${module//./\\.}"
  local lines_to_add=()
  if ! grep -Eq "^[[:space:]]*-?auth[[:space:]][^#]*${module_re}" "$LOGIN_FILE"; then
    lines_to_add+=("$auth_line")
  fi
  if ! grep -Eq "^[[:space:]]*-?session[[:space:]][^#]*${module_re}" "$LOGIN_FILE"; then
    lines_to_add+=("$session_line")
  fi

  if [[ ${#lines_to_add[@]} -gt 0 ]]; then
    local backup_file
    backup_file="${LOGIN_FILE}.lightxdm.bak"
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
}

# Install Polkit rule for passwordless actions
install_polkit_rule() {
  log "Installing Polkit rule for passwordless actions..."
  local backup="${POLKIT_RULE_DEST}.lightxdm.bak"
  local absent="${POLKIT_RULE_DEST}.lightxdm.absent"
  if ! sudo test -e "$POLKIT_RULE_DEST" && ! sudo test -L "$POLKIT_RULE_DEST" &&
    ! sudo test -e "$backup" && ! sudo test -L "$backup" &&
    ! sudo test -e "$absent" && ! sudo test -L "$absent"; then
    sudo install -Dm644 /dev/null "$absent"
  fi
  if sudo test -L "$POLKIT_RULE_DEST" ||
    { sudo test -e "$POLKIT_RULE_DEST" &&
      [[ "$(sudo sha256sum -- "$POLKIT_RULE_DEST" | cut -d' ' -f1)" != "$(sha256sum -- "$POLKIT_RULE_SRC" | cut -d' ' -f1)" ]]; }; then
    if ! sudo test -e "$backup" && ! sudo test -L "$backup" &&
      ! sudo test -e "$absent" && ! sudo test -L "$absent"; then
      log "Backing up $POLKIT_RULE_DEST to $backup"
      sudo cp -pP -- "$POLKIT_RULE_DEST" "$backup"
    else
      local edited="${POLKIT_RULE_DEST}.lightxdm-edited" n=1
      if sudo test -e "$edited" || sudo test -L "$edited"; then
        while sudo test -e "${edited}.${n}" || sudo test -L "${edited}.${n}"; do
          n=$((n + 1))
        done
        edited="${edited}.${n}"
      fi
      log "Saving edited $POLKIT_RULE_DEST to $edited"
      sudo cp -pP -- "$POLKIT_RULE_DEST" "$edited"
    fi
  fi
  sudo install -Dm644 "$POLKIT_RULE_SRC" "$POLKIT_RULE_DEST"
}

# Record a display manager before disabling it
record_and_disable_unit() {
  local unit="$1"
  if ! sudo grep -Fxq -- "$unit" "$DM_STATE_FILE" 2>/dev/null; then
    printf '%s\n' "$unit" | sudo tee -a "$DM_STATE_FILE" > /dev/null || return
  fi
  sudo systemctl disable "$unit"
}

# Disable any installed display managers
disable_display_managers() {
  log "Disabling any installed display managers..."
  sudo mkdir -p "$(dirname -- "$DM_STATE_FILE")"
  local dm dm_unit
  local disabled_dms=()
  for dm in "${DM_LIST[@]}"; do
    if systemctl list-unit-files | grep -q "${dm}.service"; then
      if [[ "$(systemctl is-enabled "${dm}.service" 2>/dev/null || true)" == "enabled" ]]; then
        record_and_disable_unit "${dm}.service" || return
        disabled_dms+=("$dm")
      fi
    fi
  done
  if [[ -L "$DISPLAY_MANAGER_LINK" ]] && dm_unit="$(readlink -f "$DISPLAY_MANAGER_LINK")"; then
    dm_unit="${dm_unit##*/}"
    dm="${dm_unit%.service}"
    if [[ " ${disabled_dms[*]} " != *" $dm "* ]] && [[ "$(systemctl is-enabled "$dm_unit" 2>/dev/null || true)" == "enabled" ]]; then
      record_and_disable_unit "$dm_unit" || return
      disabled_dms+=("$dm")
    fi
  fi
  if [[ " ${disabled_dms[*]} " != *" ly@tty1 "* ]] && [[ "$(systemctl is-enabled ly@tty1.service 2>/dev/null || true)" == "enabled" ]]; then
    record_and_disable_unit "ly@tty1.service" || return
    disabled_dms+=("ly@tty1")
  fi
  if [[ ${#disabled_dms[@]} -gt 0 ]]; then
    log "Disabled display manager(s): ${disabled_dms[*]}"
    log "Your current session will not be interrupted."
  else
    log "No enabled display managers found."
  fi
}

# --- Main ---

main() {
  local de=""
  local de_specified=0
  local list_only=0
  local no_packages=0
  local no_keyring=0
  local no_polkit_rule=0
  local usage="Usage: bash $0 [-h|--help] [--de <id>] [--list-packages] [--no-packages] [--no-keyring] [--no-polkit-rule]"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        echo "$usage"
        exit 0
        ;;
      --list-packages)
        list_only=1
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
      --no-polkit-rule)
        no_polkit_rule=1
        shift
        ;;
      --de)
        if [[ $# -lt 2 || "$2" == -* ]]; then
          log "Missing argument for --de (valid ids: xfce lxqt lxde mate cinnamon i3)"
          echo "$usage" >&2
          exit 1
        fi
        de="$2"
        de_specified=1
        shift 2
        ;;
      *)
        echo "$usage" >&2
        exit 1
        ;;
    esac
  done

  if [[ $list_only -eq 1 ]]; then
    if [[ $de_specified -eq 0 ]]; then
      log "--list-packages requires --de <id> (valid ids: xfce lxqt lxde mate cinnamon i3)"
      echo "$usage" >&2
      exit 1
    fi
    case "$de" in
      plasma | gnome | budgie)
        log "$de now runs only on Wayland and cannot be started with startx (see README.md). To configure another installed desktop, pass --de <id>."
        exit 1
        ;;
      xfce | lxqt | lxde | mate | cinnamon | i3)
        if [[ $no_keyring -eq 1 ]]; then
          list_packages "$de" --no-keyring
        else
          list_packages "$de"
        fi
        exit 0
        ;;
      *)
        log "Unsupported desktop environment: $de; --list-packages requires a built-in desktop id (valid ids: xfce lxqt lxde mate cinnamon i3)"
        exit 1
        ;;
    esac
  fi

  if [[ $de_specified -eq 1 ]]; then
    case "$de" in
      plasma | gnome | xfce | lxqt | lxde | mate | cinnamon | budgie | i3) ;;
      *)
        # Explicit character list: [a-z] ranges miss "i" under some locales (for example tr_TR).
        if [[ $no_packages -ne 1 || -z "$de" || "$de" == *[!abcdefghijklmnopqrstuvwxyz0123456789_-]* || ! -f "$(xinitrc_template "$de")" ]]; then
          log "Unsupported desktop environment: $de (valid ids: xfce lxqt lxde mate cinnamon i3)"
          exit 1
        fi
        ;;
    esac
  fi

  check_root

  # --- Wheel group and sudoers check ---
  local real_user
  real_user="${USER:-$(id -un)}"

  if ! id -nG "$real_user" | tr ' ' '\n' | grep -qx wheel; then
    log "ERROR: User '$real_user' is not in the 'wheel' group. Sudo and polkit rules will not work."
    log "Add the user to the wheel group and re-login: sudo usermod -aG wheel $real_user"
    exit 1
  fi

  # Request sudo credentials upfront
  log "Requesting sudo credentials upfront (sudo -v)..."
  if ! sudo -v; then
    log "ERROR: Failed to authenticate with sudo. Exiting."
    exit 1
  fi

  if [[ -z "$de" ]]; then
    de=$(detect_de)

    if [[ "$de" == "unknown" ]]; then
      de=$(prompt_de_selection) || {
        local menu_rc=$?
        if [[ $menu_rc -eq 2 ]]; then
          exit 0
        fi
        log "No desktop environment was chosen. Exiting."
        exit 1
      }
    else
      log "Detected desktop environment: $de"
    fi
  fi

  case "$de" in
    plasma | gnome | budgie)
      log "$de now runs only on Wayland and cannot be started with startx (see README.md). To configure another installed desktop, pass --de <id>."
      exit 1
      ;;
  esac

  local template
  template="$(xinitrc_template "$de")"
  if [[ ! -f "$template" ]]; then
    log "No .xinitrc template for $de: $template. Installation aborted."
    exit 1
  fi
  if [[ ! -L "$HOME/.xinitrc" && "$template" -ef "$HOME/.xinitrc" ]]; then
    log "The template for $de is ~/.xinitrc itself: $template. Installation aborted."
    exit 1
  fi

  if [[ $no_packages -eq 1 ]]; then
    log "Skipping package installation (--no-packages)."
  elif [[ $no_keyring -eq 1 ]]; then
    install_packages "$de" --no-keyring
  else
    install_packages "$de"
  fi
  copy_dotfiles "$de"
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
    log "WARNING: Login shell for $real_user is $login_shell, which does not read ~/.bash_profile. Add the TTY1 startx block to ~/$shell_profile (zsh and fish snippets: docs/startx-autologin.md)."
  fi
  if [[ $no_keyring -eq 1 ]]; then
    log "Skipping keyring PAM configuration (--no-keyring)."
  else
    configure_pam "$de"
  fi
  if [[ $no_polkit_rule -eq 1 ]]; then
    log "Skipping Polkit rule installation (--no-polkit-rule)."
  else
    install_polkit_rule
  fi
  disable_display_managers

  local unlock_summary="Auto-unlock and Polkit rules are set"
  if [[ $no_keyring -eq 1 && $no_polkit_rule -eq 1 ]]; then
    unlock_summary="Keyring setup and Polkit rule skipped"
  elif [[ $no_keyring -eq 1 ]]; then
    unlock_summary="Polkit rules are set (keyring setup skipped)"
  elif [[ $no_polkit_rule -eq 1 ]]; then
    unlock_summary="Auto-unlock is set (Polkit rule skipped)"
  fi

  if [[ -z "$shell_profile" ]]; then
    cat <<EOF

lightXDM install complete!
- $de will auto-start on TTY1 for $real_user
- $unlock_summary
- Reboot or log out to test

On next boot, after logging in, your desktop environment will start automatically on TTY1. No need to run 'startx'.
EOF
  else
    cat <<EOF

lightXDM install complete!
- $de is configured in ~/.xinitrc for $real_user (auto-start requires ~/$shell_profile)
- $unlock_summary
- Add the TTY1 startx block to ~/$shell_profile (see docs/startx-autologin.md), then reboot or log out to test

Your login shell ($login_shell) does not read ~/.bash_profile, so $de will not auto-start on TTY1 until you add a startx block to ~/$shell_profile (or run 'startx' manually).
EOF
  fi
}

# Run only when executed directly, so tests can source the functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
