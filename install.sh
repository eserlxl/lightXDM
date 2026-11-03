#!/usr/bin/env bash
# lightXDM install script for Arch Linux
# Installs a minimal DE, configures auto-login, KWallet, Polkit, and PAM
set -e

# --- Configuration ---
readonly DM_LIST=(sddm lightdm gdm lxdm)
readonly LOGIN_FILE="/etc/pam.d/login"
readonly POLKIT_RULE_SRC="polkit/49-nopasswd.rules"
readonly POLKIT_RULE_DEST="/etc/polkit-1/rules.d/49-nopasswd.rules"
readonly PAM_KWALLET_PATCH_FILE="pam/login-pam-kwallet.patch"
readonly PAM_GNOME_KEYRING_PATCH_FILE="pam/login-pam-gnome-keyring.patch"

# --- Functions ---

# Log a message to the console
log() {
  echo "=> $1"
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
  if pacman -Qs plasma-desktop >/dev/null; then
    echo "plasma"
  elif pacman -Qs gnome-shell >/dev/null; then
    echo "gnome"
  elif pacman -Qs xfce4-session >/dev/null; then
    echo "xfce"
  elif pacman -Qs lxqt-session >/dev/null; then
    echo "lxqt"
  elif pacman -Qs lxde-session >/dev/null; then
    echo "lxde"
  elif pacman -Qs mate-session-manager >/dev/null; then
    echo "mate"
  elif pacman -Qs cinnamon >/dev/null; then
    echo "cinnamon"
  elif pacman -Qs budgie-desktop >/dev/null; then
    echo "budgie"
  elif pacman -Qs i3-wm >/dev/null; then
    echo "i3"
  else
    echo "unknown"
  fi
}

# Prompt user to select a DE
prompt_de_selection() {
  log "No supported desktop environment detected."
  PS3="Please select a desktop environment to install: "
  options=("KDE Plasma" "GNOME" "XFCE" "LXQt" "LXDE" "MATE" "Cinnamon" "Budgie" "i3" "Quit")
  select opt in "${options[@]}"; do
    case $opt in
      "KDE Plasma")
        echo "plasma"
        break
        ;;
      "GNOME")
        echo "gnome"
        break
        ;;
      "XFCE")
        echo "xfce"
        break
        ;;
      "LXQt")
        echo "lxqt"
        break
        ;;
      "LXDE")
        echo "lxde"
        break
        ;;
      "MATE")
        echo "mate"
        break
        ;;
      "Cinnamon")
        echo "cinnamon"
        break
        ;;
      "Budgie")
        echo "budgie"
        break
        ;;
      "i3")
        echo "i3"
        break
        ;;
      "Quit")
        exit 0
        ;;
      *)
        log "Invalid option $REPLY"
        ;;
    esac
  done
}

# Install required packages
install_packages() {
  local de
  de=$1
  local pkgs=()
  local base_pkgs=(xorg-server xorg-xinit udisks2 polkit gvfs gvfs-mtp gvfs-gphoto2 gvfs-afc patch)

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
  sudo install -Dm644 "dotfiles/.bash_profile" "$user_home/.bash_profile"
  sudo chown "$USER:$(id -gn "$USER")" "$user_home/.bash_profile"

  if [[ "$de" == "plasma" ]]; then
    sudo install -Dm744 "dotfiles/.gpg-agent-kwallet" "$user_home/.gpg-agent-kwallet"
    sudo chown "$USER:$(id -gn "$USER")" "$user_home/.gpg-agent-kwallet"
  else
    sudo install -Dm744 "dotfiles/.gpg-agent-gnome" "$user_home/.gpg-agent-gnome"
    sudo chown "$USER:$(id -gn "$USER")" "$user_home/.gpg-agent-gnome"
  fi

  local xinitrc_template="dotfiles/.xinitrc-$de"
  if [[ -f "$xinitrc_template" ]]; then
    sudo install -Dm644 "$xinitrc_template" "$user_home/.xinitrc"
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
  local backup_file
  backup_file="${LOGIN_FILE}.lightxde.bak.$(date +%s)"
  if [[ "$de" == "plasma" ]]; then
    if ! grep -q "pam_kwallet5.so" "$LOGIN_FILE"; then
      log "Backing up $LOGIN_FILE to $backup_file"
      sudo cp "$LOGIN_FILE" "$backup_file"
      patch_output=""
      patch_status=0
      if ! patch_output=$(sudo patch "$LOGIN_FILE" "$PAM_KWALLET_PATCH_FILE" 2>&1); then
        patch_status=$?
      fi
      if [ $patch_status -eq 0 ]; then
        log "PAM patched successfully."
      else
        log "Patching failed! Output was:\n$patch_output"
        log "Restoring original $LOGIN_FILE. Attempting manual fallback."
        sudo cp "$backup_file" "$LOGIN_FILE"
        echo "auth       optional   pam_kwallet5.so" | sudo tee -a "$LOGIN_FILE" > /dev/null
        echo "session    optional   pam_kwallet5.so force_run" | sudo tee -a "$LOGIN_FILE" > /dev/null
        log "[WARN] Patch failed, pam_kwallet5.so lines were appended manually to $LOGIN_FILE. Please verify manually."
      fi
    else
      log "PAM configuration for KWallet already exists. Skipping."
    fi
  elif [[ "$de" == "gnome" ]]; then
    if ! grep -q "pam_gnome_keyring.so" "$LOGIN_FILE"; then
      log "Backing up $LOGIN_FILE to $backup_file"
      sudo cp "$LOGIN_FILE" "$backup_file"
      patch_output=""
      patch_status=0
      if ! patch_output=$(sudo patch "$LOGIN_FILE" "$PAM_GNOME_KEYRING_PATCH_FILE" 2>&1); then
        patch_status=$?
      fi
      if [ $patch_status -eq 0 ]; then
        log "PAM patched successfully."
      else
        log "Patching failed! Output was:\n$patch_output"
        log "Restoring original $LOGIN_FILE. Attempting manual fallback."
        sudo cp "$backup_file" "$LOGIN_FILE"
        echo "auth       optional   pam_gnome_keyring.so auto_start" | sudo tee -a "$LOGIN_FILE" > /dev/null
        echo "session    optional   pam_gnome_keyring.so auto_start" | sudo tee -a "$LOGIN_FILE" > /dev/null
        log "[WARN] Patch failed, pam_gnome_keyring.so lines were appended manually to $LOGIN_FILE. Please verify manually."
      fi
    else
      log "PAM configuration for GNOME Keyring already exists. Skipping."
    fi
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

# Check for active %wheel sudoers rule in /etc/sudoers and /etc/sudoers.d
check_wheel_sudoers() {
  local user_regex
  user_regex="^[[:space:]]*(%wheel|$real_user)[[:space:]]+ALL=\\(ALL(:ALL)?\\)[[:space:]]+ALL"

  # Search for uncommented %wheel or user lines in /etc/sudoers
  if sudo grep -E "$user_regex" /etc/sudoers | grep -vq '^[[:space:]]*#'; then
    return 0
  fi

  # Search for uncommented %wheel or user lines in all /etc/sudoers.d/* files
  if [[ -d /etc/sudoers.d ]]; then
    for f in /etc/sudoers.d/*; do
      [[ -f "$f" ]] || continue
      if sudo grep -E "$user_regex" "$f" | grep -vq '^[[:space:]]*#'; then
        return 0
      fi
    done
  fi

  # If we reach here, no active rule was found
  log "ERROR: No active '%wheel ALL=(ALL:ALL) ALL', '$real_user ALL=(ALL:ALL) ALL', or similar rule found in /etc/sudoers or /etc/sudoers.d/."
  log "Users in the wheel group or user '$real_user' will NOT be able to use sudo."
  log "To fix, run: sudo visudo and add or uncomment a '%wheel ALL=(ALL:ALL) ALL' or '$real_user ALL=(ALL:ALL) ALL' line."
  exit 1
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

  check_wheel_sudoers

  # Check if user can actually run sudo non-interactively
  if ! sudo -n true 2>/dev/null; then
    log "ERROR: User '$real_user' cannot run sudo without a password or is not in the sudoers file."
    log "Please ensure your user is in the wheel group and the sudoers file is configured."
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
    de=$(prompt_de_selection)
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
