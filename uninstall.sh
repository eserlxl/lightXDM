#!/usr/bin/env bash
# uninstall.sh: Revert changes made by install scripts (PAM, autologin, Polkit)
set -e

# Restore /etc/pam.d/login if backup exists
if [ -f /etc/pam.d/login.backup ]; then
  echo "Restoring /etc/pam.d/login from backup..."
  cp /etc/pam.d/login.backup /etc/pam.d/login
else
  echo "No /etc/pam.d/login.backup found; skipping PAM restore."
fi

# Remove autologin override
OVERRIDE_FILE="/etc/systemd/system/getty@tty1.service.d/override.conf"
if [ -f "$OVERRIDE_FILE" ]; then
  echo "Removing autologin override..."
  rm -f "$OVERRIDE_FILE"
  systemctl daemon-reload
  echo "Autologin override removed. Change will take effect at the next login or reboot."
else
  echo "No autologin override found; skipping."
fi

# Remove Polkit rule
POLKIT_RULE="/etc/polkit-1/rules.d/49-nopasswd.rules"
if [ -f "$POLKIT_RULE" ]; then
  echo "Removing Polkit rule..."
  rm -f "$POLKIT_RULE"
else
  echo "No Polkit rule found; skipping."
fi

echo "Uninstall complete. Changes will take effect at the next login or reboot."