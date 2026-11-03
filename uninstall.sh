#!/usr/bin/env bash
# uninstall.sh: Revert changes made by install scripts (PAM, autologin, Polkit)
set -e

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (with sudo)."
  exit 1
fi

LOGIN_FILE="${LOGIN_FILE:-/etc/pam.d/login}"
BACKUP_FILE="${LOGIN_FILE}.lightxdm.bak"

# Restore /etc/pam.d/login if backup exists
if [ -f "$BACKUP_FILE" ]; then
  echo "Restoring $LOGIN_FILE from backup..."
  cp "$BACKUP_FILE" "$LOGIN_FILE"
  rm -f "$BACKUP_FILE"
else
  echo "No $BACKUP_FILE found; skipping PAM restore."
fi

# Remove autologin override
OVERRIDE_FILE="${OVERRIDE_FILE:-/etc/systemd/system/getty@tty1.service.d/override.conf}"
if [ -f "$OVERRIDE_FILE" ]; then
  echo "Removing autologin override..."
  rm -f "$OVERRIDE_FILE"
  systemctl daemon-reload
  echo "Autologin override removed. Change will take effect at the next login or reboot."
else
  echo "No autologin override found; skipping."
fi

# Remove Polkit rule
POLKIT_RULE="${POLKIT_RULE:-/etc/polkit-1/rules.d/49-nopasswd.rules}"
if [ -f "$POLKIT_RULE" ]; then
  echo "Removing Polkit rule..."
  rm -f "$POLKIT_RULE"
else
  echo "No Polkit rule found; skipping."
fi

echo "Uninstall complete. Changes will take effect at the next login or reboot."
