#!/bin/sh
# SPDX-FileCopyrightText: 2025-2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# Run by lightxdm-login-pacnew.hook after a pacman transaction touched /etc/pam.d/login. It only reads
# and prints: merging the .pacnew is the user's decision, so it never changes the login file.
login="${LOGIN_FILE:-/etc/pam.d/login}"
record="${PAM_KEYRING_STATE:-/etc/lightxdm/pam-keyring}"
if [ -e "$login.pacnew" ] && [ -e "$record" ]; then
  echo "lightXDM: $login.pacnew is waiting. If you take it over $login (for example with pacdiff), run lightxdm-update afterwards so the keyring unlocks at login again."
fi
exit 0
