#!/bin/sh
# SPDX-FileCopyrightText: 2025-2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# Run by lightxdm-login-pacnew.hook after a pacman transaction touched /etc/pam.d/login. It only reads
# and prints: merging the .pacnew is the user's decision, so it never changes the login file.
login="${LOGIN_FILE:-/etc/pam.d/login}"
record="${PAM_KEYRING_STATE:-/etc/lightxdm/pam-keyring}"
gnome_conf="${GNOME_SESSION_TYPE_DEST:-/etc/lightxdm/gnome-session-type.conf}"
if [ -e "$login.pacnew" ]; then
  if [ -e "$record" ] && [ -e "$gnome_conf" ]; then
    echo "lightXDM: $login.pacnew is waiting. If you take it over $login (for example with pacdiff), run lightxdm-update afterwards so the keyring unlocks at login and GNOME starts on Wayland on TTY1 again."
  elif [ -e "$record" ]; then
    echo "lightXDM: $login.pacnew is waiting. If you take it over $login (for example with pacdiff), run lightxdm-update afterwards so the keyring unlocks at login again."
  elif [ -e "$gnome_conf" ]; then
    echo "lightXDM: $login.pacnew is waiting. If you take it over $login (for example with pacdiff), run lightxdm-update afterwards so GNOME starts on Wayland on TTY1 again."
  fi
fi
exit 0
