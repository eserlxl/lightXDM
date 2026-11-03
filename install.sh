#!/usr/bin/env bash
# lightXDM install script for Arch Linux
# Installs a minimal DE, configures auto-login, KWallet, Polkit, and PAM
set -e

# --- Configuration ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly DM_LIST=(sddm lightdm gdm lxdm)
readonly LOGIN_FILE="${LOGIN_FILE:-/etc/pam.d/login}"
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
  local PS3 opt
  local options=("KDE Plasma" "GNOME" "XFCE" "LXQt" "LXDE" "MATE" "Cinnamon" "Budgie" "i3" "Quit")
  local ids=(plasma gnome xfce lxqt lxde mate cinnamon budgie i3)

  log "No supported desktop environment detected."
  PS3="Please select a desktop environment to install: "
  select opt in "${options[@]}"; do
    case "$opt" in
      "Quit")
        return 1
        ;;
      "")
        log "Invalid option $REPLY"
        ;;
      *)
        echo "${ids[REPLY - 1]}"
        return 0
        ;;
    esac
  done
  return 1
}

# Install required packages
install_packages() {
  local de
  de=$1
  local pkgs=()
  local base_pkgs=(xorg-server xorg-xinit udisks2 polkit gvfs gvfs-mtp gvfs-gphoto2 gvfs-afc)

  case "$de" in
    plasma)
      pkgs=(plasma-desktop konsole dolphin kwallet-pam polkit-kde-agent)
      ;;
    gnome)
      pkgs=(gnome gnome-terminal gnome-keyring polkit-gnome)
      ;;
    xfce)
      pkgs=(xfce4 xfce4-session xfce4-terminal gnome-keyring polkit-gnome)
      ;;
    lxqt)
      pkgs=(lxqt xdg-utils lxterminal gnome-keyring lxqt-policykit)
      ;;
    lxde)
      pkgs=(lxde gnome-keyring polkit-gnome)
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
      pkgs=(i3 xterm gnome-keyring polkit-gnome)
      ;;
    *)
      log "Unsupported desktop environment: $de"
      exit 1
      ;;
  esac

  log "Installing required packages for $de..."
  sudo pacman -S --needed --noconfirm "${base_pkgs[@]}" "${pkgs[@]}"
}

# Copy dotfiles to the user's home directory
copy_dotfiles() {
  local de
  de=$1
  local user_home
  user_home=$HOME

  log "Copying dotfiles to $user_home..."
  if [[ -f "$user_home/.bash_profile" && ! -e "$user_home/.bash_profile.lightxdm.bak" ]]; then
    log "Backing up $user_home/.bash_profile to $user_home/.bash_profile.lightxdm.bak"
    cp "$user_home/.bash_profile" "$user_home/.bash_profile.lightxdm.bak"
  fi
  sudo install -Dm644 "$SCRIPT_DIR/dotfiles/.bash_profile" "$user_home/.bash_profile"
  sudo chown "$USER:$(id -gn "$USER")" "$user_home/.bash_profile"

  if [[ "$de" == "plasma" ]]; then
    sudo install -Dm744 "$SCRIPT_DIR/dotfiles/.gpg-agent-kwallet" "$user_home/.gpg-agent-kwallet"
    sudo chown "$USER:$(id -gn "$USER")" "$user_home/.gpg-agent-kwallet"
  else
    sudo install -Dm744 "$SCRIPT_DIR/dotfiles/.gpg-agent-gnome" "$user_home/.gpg-agent-gnome"
    sudo chown "$USER:$(id -gn "$USER")" "$user_home/.gpg-agent-gnome"
  fi

  local xinitrc_template="$SCRIPT_DIR/dotfiles/.xinitrc-$de"
  if [[ -f "$xinitrc_template" ]]; then
    if [[ -f "$user_home/.xinitrc" && ! -e "$user_home/.xinitrc.lightxdm.bak" ]]; then
      log "Backing up $user_home/.xinitrc to $user_home/.xinitrc.lightxdm.bak"
      cp "$user_home/.xinitrc" "$user_home/.xinitrc.lightxdm.bak"
    fi
    sudo install -Dm755 "$xinitrc_template" "$user_home/.xinitrc"
    sudo chown "$USER:$(id -gn "$USER")" "$user_home/.xinitrc"
  else
    log "No .xinitrc template for $de. Please create $xinitrc_template for proper session startup."
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
      auth_line="auth       optional   pam_kwallet5.so"
      session_line="session    optional   pam_kwallet5.so force_run"
      ;;
    gnome | xfce | lxqt | lxde | mate | cinnamon | budgie | i3)
      module="pam_gnome_keyring.so"
      auth_line="auth       optional   pam_gnome_keyring.so"
      session_line="session    optional   pam_gnome_keyring.so auto_start"
      ;;
    *)
      return 0
      ;;
  esac

  if ! grep -q "$module" "$LOGIN_FILE"; then
    local backup_file
    backup_file="${LOGIN_FILE}.lightxdm.bak"
    if [[ ! -e "$backup_file" ]]; then
      log "Backing up $LOGIN_FILE to $backup_file"
      sudo cp "$LOGIN_FILE" "$backup_file"
    fi
    printf '%s\n%s\n' "$auth_line" "$session_line" | sudo tee -a "$LOGIN_FILE" > /dev/null
    log "Configured $module in $LOGIN_FILE."
  else
    log "PAM configuration for $module already exists. Skipping."
  fi
}

# Install Polkit rule for passwordless actions
install_polkit_rule() {
  log "Installing Polkit rule for passwordless actions..."
  sudo install -Dm644 "$POLKIT_RULE_SRC" "$POLKIT_RULE_DEST"
}

# Disable any installed display managers
disable_display_managers() {
  log "Disabling any installed display managers..."
  local disabled_dms=()
  for dm in "${DM_LIST[@]}"; do
    if systemctl list-unit-files | grep -q "${dm}.service"; then
      if systemctl is-enabled --quiet "${dm}.service"; then
        sudo systemctl disable "${dm}.service"
        disabled_dms+=("$dm")
      fi
    fi
  done
  if [[ ${#disabled_dms[@]} -gt 0 ]]; then
    log "Disabled display manager(s): ${disabled_dms[*]}"
    log "Your current session will not be interrupted."
  else
    log "No enabled display managers found."
  fi
}

# --- Main ---

main() {
  # --- Wheel group and sudoers check ---
  local real_user
  real_user="${SUDO_USER:-$USER}"

  if [[ $EUID -eq 0 ]]; then
    log "Do not run this script as root or with sudo. Please run as a regular user."
    exit 1
  fi

  if ! id -nG "$real_user" | grep -qw wheel; then
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

  check_root

  local de
  de=$(detect_de)

  if [[ "$de" == "unknown" ]]; then
    de=$(prompt_de_selection) || exit 0
  else
    log "Detected desktop environment: $de"
  fi

  install_packages "$de"
  copy_dotfiles "$de"
  configure_pam "$de"
  install_polkit_rule
  disable_display_managers

  cat <<EOF

lightXDM install complete!
- $de will auto-start on TTY1 for $USER
- Auto-unlock and Polkit rules are set
- Reboot or log out to test

On next boot, after logging in, your desktop environment will start automatically on TTY1. No need to run 'startx'.
EOF
}

# Run only when executed directly, so tests can source the functions.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
