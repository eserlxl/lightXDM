#!/usr/bin/env bash
# tests/run.sh: Behavior test harness for lightXDM scripts
# Test cases change HOME/USER inside subshells on purpose, to keep each case isolated.
# shellcheck disable=SC2030,SC2031
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

unset SUDO_USER
export HOME="$TMP_DIR/home"
mkdir -p "$HOME"

STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"

cat >"$STUB_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

cat >"$STUB_BIN/pacman" <<'EOF'
#!/usr/bin/env bash
echo "pacman $*" >>"${STUB_LOG:-/dev/null}"
exit "${STUB_PACMAN_EXIT:-0}"
EOF

cat >"$STUB_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"${STUB_LOG:-/dev/null}"
exit "${STUB_SYSTEMCTL_EXIT:-0}"
EOF

cat >"$STUB_BIN/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-gn" ]]; then
  echo "users"
elif [[ "${1:-}" == "-nG" ]]; then
  echo "users wheel"
else
  echo "1000"
fi
EOF

cat >"$STUB_BIN/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$STUB_BIN/sudo" "$STUB_BIN/pacman" "$STUB_BIN/systemctl" "$STUB_BIN/id" "$STUB_BIN/chown"
export PATH="$STUB_BIN:$PATH"
export STUB_LOG="$TMP_DIR/stub.log"
export LOGIN_FILE="$TMP_DIR/login"

# shellcheck source=install.sh disable=SC1091
source "$REPO_ROOT/install.sh"

failures=0

pass() {
  echo "PASS: $1"
}

skip() {
  echo "SKIP: $1"
}

fail() {
  echo "FAIL: $1"
  failures=$((failures + 1))
}

can_unshare=0
if unshare -r true >/dev/null 2>&1; then
  can_unshare=1
fi

# Case 1: install_packages rejects an unknown DE
set +e
output="$(install_packages "nonexistent-de" 2>&1)"
status=$?
set -e
if [[ $status -eq 1 && "$output" == *"Unsupported desktop environment: nonexistent-de"* ]]; then
  pass "install_packages rejects unknown DE"
else
  fail "install_packages rejects unknown DE (status=$status, output=$output)"
fi

# Case 2: install_packages installs base and DE packages via stubbed sudo/pacman
: >"$STUB_LOG"
set +e
output="$(install_packages "i3" 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 0 && "$log_content" == *"pacman -S --needed --noconfirm"* && "$log_content" == *"i3 xterm gnome-keyring polkit-gnome"* ]]; then
  pass "install_packages invokes pacman for i3"
else
  fail "install_packages invokes pacman for i3 (status=$status, log=$log_content)"
fi

# Case 3: prompt_de_selection maps "1" to "plasma" without log or PS3 leakage
unset PS3
prompt_out="$TMP_DIR/prompt_out"
set +e
prompt_de_selection <<<"1" >"$prompt_out" 2>/dev/null
status=$?
set -e
output="$(cat "$prompt_out")"
if [[ $status -eq 0 && "$output" == "plasma" && -z "${PS3+x}" ]]; then
  pass "prompt_de_selection maps option 1 to plasma without leaking log or PS3"
else
  fail "prompt_de_selection option 1 (status=$status, output=$output, PS3=${PS3-<unset>})"
fi

# Case 4: prompt_de_selection returns non-zero with empty stdout on Quit ("10")
set +e
output="$(prompt_de_selection <<<"10" 2>/dev/null)"
status=$?
set -e
if [[ $status -ne 0 && -z "$output" ]]; then
  pass "prompt_de_selection returns non-zero on Quit"
else
  fail "prompt_de_selection Quit (status=$status, output=$output)"
fi

# Case 5: prompt_de_selection returns non-zero with empty stdout on EOF
set +e
output="$(prompt_de_selection </dev/null 2>/dev/null)"
status=$?
set -e
if [[ $status -ne 0 && -z "$output" ]]; then
  pass "prompt_de_selection returns non-zero on EOF"
else
  fail "prompt_de_selection EOF (status=$status, output=$output)"
fi

write_stock_login() {
  cat >"$LOGIN_FILE" <<'EOF'
#%PAM-1.0

auth       requisite    pam_nologin.so
auth       include      system-local-login
account    include      system-local-login
session    include      system-local-login
password   include      system-local-login
EOF
}

# Case 6: configure_pam appends KWallet lines once on stock Arch login and is idempotent
write_stock_login
configure_pam "plasma" 2>/dev/null
first_run="$(cat "$LOGIN_FILE")"
configure_pam "plasma" 2>/dev/null
second_run="$(cat "$LOGIN_FILE")"
if [[ "$first_run" == "$second_run" ]] &&
  grep -Eq '^auth[[:space:]]+optional[[:space:]]+pam_kwallet5\.so$' "$LOGIN_FILE" &&
  grep -Eq '^session[[:space:]]+optional[[:space:]]+pam_kwallet5\.so force_run$' "$LOGIN_FILE" &&
  [[ "$(grep -c 'pam_kwallet5\.so' "$LOGIN_FILE")" -eq 2 ]] &&
  [[ "$(grep -c 'system-local-login' "$LOGIN_FILE")" -eq 4 ]] &&
  [[ ! -e "${LOGIN_FILE}.orig" && ! -e "${LOGIN_FILE}.rej" ]]; then
  pass "configure_pam configures KWallet idempotently on stock Arch login"
else
  fail "configure_pam KWallet (content=$second_run)"
fi

# Case 7: configure_pam appends GNOME Keyring lines (no auto_start on auth) idempotently
write_stock_login
configure_pam "gnome" 2>/dev/null
first_run="$(cat "$LOGIN_FILE")"
configure_pam "gnome" 2>/dev/null
second_run="$(cat "$LOGIN_FILE")"
if [[ "$first_run" == "$second_run" ]] &&
  grep -Eq '^auth[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so$' "$LOGIN_FILE" &&
  grep -Eq '^session[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so auto_start$' "$LOGIN_FILE" &&
  [[ "$(grep -c 'pam_gnome_keyring\.so' "$LOGIN_FILE")" -eq 2 ]] &&
  [[ "$(grep -c 'system-local-login' "$LOGIN_FILE")" -eq 4 ]] &&
  [[ ! -e "${LOGIN_FILE}.orig" && ! -e "${LOGIN_FILE}.rej" ]]; then
  pass "configure_pam configures GNOME Keyring idempotently on stock Arch login"
else
  fail "configure_pam GNOME Keyring (content=$second_run)"
fi

# Case 8: configure_pam appends GNOME Keyring lines for non-Plasma desktops
for non_plasma_de in xfce lxqt lxde mate cinnamon budgie i3; do
  write_stock_login
  configure_pam "$non_plasma_de" 2>/dev/null
  first_run="$(cat "$LOGIN_FILE")"
  configure_pam "$non_plasma_de" 2>/dev/null
  second_run="$(cat "$LOGIN_FILE")"
  if [[ "$first_run" == "$second_run" ]] &&
    grep -Eq '^auth[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so$' "$LOGIN_FILE" &&
    grep -Eq '^session[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so auto_start$' "$LOGIN_FILE" &&
    [[ "$(grep -c 'pam_gnome_keyring\.so' "$LOGIN_FILE")" -eq 2 ]] &&
    ! grep -q 'pam_kwallet5\.so' "$LOGIN_FILE"; then
    pass "configure_pam configures GNOME Keyring idempotently for $non_plasma_de"
  else
    fail "configure_pam GNOME Keyring for $non_plasma_de (content=$second_run)"
  fi
done

# Case 9: main gets past sudo checks when sudo -n fails but sudo -v succeeds
sudo_pw_dir="$TMP_DIR/sudo_pw"
mkdir -p "$sudo_pw_dir"
cat >"$sudo_pw_dir/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-n" ]]; then
  exit 1
elif [[ "${1:-}" == "-v" ]]; then
  echo "sudo -v" >>"${STUB_LOG:-/dev/null}"
  exit 0
fi
exec "$@"
EOF
chmod +x "$sudo_pw_dir/sudo"

# shellcheck disable=SC2317,SC2329  # overrides are called indirectly through main
run_main_with_stubs() (
  export PATH="$1:$PATH"
  export USER="${USER:-testuser}"
  unset SUDO_USER
  detect_de() { echo "i3"; }
  install_packages() { echo "install_packages $1" >>"$STUB_LOG"; }
  copy_dotfiles() { echo "copy_dotfiles $1" >>"$STUB_LOG"; }
  configure_pam() { echo "configure_pam $1" >>"$STUB_LOG"; }
  install_polkit_rule() { echo "install_polkit_rule" >>"$STUB_LOG"; }
  disable_display_managers() { echo "disable_display_managers" >>"$STUB_LOG"; }
  main
)

: >"$STUB_LOG"
set +e
output="$(run_main_with_stubs "$sudo_pw_dir" 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 0 && "$log_content" == *"sudo -v"* && "$log_content" == *"install_packages i3"* ]]; then
  pass "main succeeds when sudo requires a password (-n fails, -v succeeds)"
else
  fail "main with password sudo (status=$status, log=$log_content, output=$output)"
fi

# Case 10: main fails with clear error when sudo -v fails
sudo_fail_dir="$TMP_DIR/sudo_fail"
mkdir -p "$sudo_fail_dir"
cat >"$sudo_fail_dir/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-v" || "${1:-}" == "-n" ]]; then
  exit 1
fi
exec "$@"
EOF
chmod +x "$sudo_fail_dir/sudo"

: >"$STUB_LOG"
set +e
output="$(run_main_with_stubs "$sudo_fail_dir" 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 1 && "$output" == *"ERROR: Failed to authenticate with sudo. Exiting."* && -z "$log_content" ]]; then
  pass "main exits 1 when sudo -v fails"
else
  fail "main when sudo -v fails (status=$status, log=$log_content, output=$output)"
fi

# Case 11: enable-autologin.sh --help and -h print usage and write nothing
autologin_dir="$TMP_DIR/autologin"
if [[ $can_unshare -eq 0 ]]; then
  skip "enable-autologin.sh --help/-h prints usage and writes nothing (unshare -r unavailable)"
else
  for help_flag in --help -h; do
    rm -rf "$autologin_dir"
    : >"$STUB_LOG"
    set +e
    output="$(OVERRIDE_DIR="$autologin_dir" unshare -r bash "$REPO_ROOT/enable-autologin.sh" "$help_flag" 2>&1)"
    status=$?
    set -e
    log_content="$(cat "$STUB_LOG")"
    if [[ $status -ne 0 && "$output" == *"Usage:"* && ! -e "$autologin_dir/override.conf" && -z "$log_content" ]]; then
      pass "enable-autologin.sh $help_flag prints usage and writes nothing"
    else
      fail "enable-autologin.sh $help_flag (status=$status, output=$output, log=$log_content)"
    fi
  done
fi

# Case 12: enable-autologin.sh requires exactly one argument
real_test_user="$(command -p id -un)"
if [[ $can_unshare -eq 0 ]]; then
  skip "enable-autologin.sh requires exactly one argument (unshare -r unavailable)"
else
  rm -rf "$autologin_dir"
  set +e
  output_zero="$(OVERRIDE_DIR="$autologin_dir" unshare -r bash "$REPO_ROOT/enable-autologin.sh" 2>&1)"
  status_zero=$?
  output_two="$(OVERRIDE_DIR="$autologin_dir" unshare -r bash "$REPO_ROOT/enable-autologin.sh" "$real_test_user" extra 2>&1)"
  status_two=$?
  set -e
  if [[ $status_zero -ne 0 && "$output_zero" == *"Usage:"* && $status_two -ne 0 && "$output_two" == *"Usage:"* && ! -e "$autologin_dir/override.conf" ]]; then
    pass "enable-autologin.sh requires exactly one argument"
  else
    fail "enable-autologin.sh argument count (status_zero=$status_zero, out_zero=$output_zero, status_two=$status_two, out_two=$output_two)"
  fi
fi

# Case 13: enable-autologin.sh rejects dash-prefixed and unknown usernames
if [[ $can_unshare -eq 0 ]]; then
  skip "enable-autologin.sh rejects dash-prefixed and unknown usernames (unshare -r unavailable)"
else
  for bad_user in -u --bad-flag nonexistent_autologin_user_99999; do
    expected_msg="does not exist"
    if [[ "$bad_user" == -* ]]; then
      expected_msg="Invalid username"
    fi
    rm -rf "$autologin_dir"
    : >"$STUB_LOG"
    set +e
    output="$(OVERRIDE_DIR="$autologin_dir" unshare -r bash "$REPO_ROOT/enable-autologin.sh" "$bad_user" 2>&1)"
    status=$?
    set -e
    log_content="$(cat "$STUB_LOG")"
    if [[ $status -ne 0 && "$output" == *"$expected_msg"* && ! -e "$autologin_dir/override.conf" && -z "$log_content" ]]; then
      pass "enable-autologin.sh rejects invalid user '$bad_user'"
    else
      fail "enable-autologin.sh should reject '$bad_user' (status=$status, output=$output, log=$log_content)"
    fi
  done
fi

# Case 14: enable-autologin.sh rejects root (UID 0) and nologin/false shell accounts
if [[ $can_unshare -eq 0 ]]; then
  skip "enable-autologin.sh rejects root and nologin/false accounts (unshare -r unavailable)"
else
  rm -rf "$autologin_dir"
  : >"$STUB_LOG"
  set +e
  output="$(OVERRIDE_DIR="$autologin_dir" unshare -r bash "$REPO_ROOT/enable-autologin.sh" root 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -ne 0 && "$output" == *"Refusing to enable autologin for root"* && ! -e "$autologin_dir/override.conf" && -z "$log_content" ]]; then
    pass "enable-autologin.sh rejects disallowed account 'root'"
  else
    fail "enable-autologin.sh should reject 'root' (status=$status, output=$output, log=$log_content)"
  fi

  nologin_user="nobody"
  if ! getent passwd "$nologin_user" 2>/dev/null | grep -Ev '^[^:]*:[^:]*:0:' | grep -Eq ':(.*nologin|.*false)$'; then
    nologin_user="$(getent passwd | grep -E ':(.*nologin|.*false)$' | grep -Ev '^[^:]*:[^:]*:0:|^-' | sed -n '1s/:.*//p' || true)"
  fi
  if [[ -z "$nologin_user" ]]; then
    fail "enable-autologin.sh nologin test requires a non-empty nologin user"
  else
    rm -rf "$autologin_dir"
    : >"$STUB_LOG"
    set +e
    output="$(OVERRIDE_DIR="$autologin_dir" unshare -r bash "$REPO_ROOT/enable-autologin.sh" "$nologin_user" 2>&1)"
    status=$?
    set -e
    log_content="$(cat "$STUB_LOG")"
    if [[ $status -ne 0 && "$output" == *"non-interactive shell"* && ! -e "$autologin_dir/override.conf" && -z "$log_content" ]]; then
      pass "enable-autologin.sh rejects disallowed account '$nologin_user'"
    else
      fail "enable-autologin.sh should reject '$nologin_user' (status=$status, output=$output, log=$log_content)"
    fi
  fi
fi

# Case 15: enable-autologin.sh writes override.conf with literal $TERM for valid user
if [[ $can_unshare -eq 0 ]]; then
  skip "enable-autologin.sh writes literal \$TERM for $real_test_user (unshare -r unavailable)"
else
  rm -rf "$autologin_dir"
  : >"$STUB_LOG"
  set +e
  output="$(OVERRIDE_DIR="$autologin_dir" TERM="xterm-kitty" unshare -r bash "$REPO_ROOT/enable-autologin.sh" "$real_test_user" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  expected_exec="ExecStart=-/usr/bin/agetty --autologin $real_test_user --noclear %I \$TERM"
  if [[ $status -eq 0 && -f "$autologin_dir/override.conf" ]] &&
    grep -Fqx -- "[Service]" "$autologin_dir/override.conf" &&
    grep -Fqx -- "ExecStart=" "$autologin_dir/override.conf" &&
    grep -Fqx -- "$expected_exec" "$autologin_dir/override.conf" &&
    ! grep -Fq -- "xterm-kitty" "$autologin_dir/override.conf" &&
    [[ "$log_content" == *"systemctl daemon-reload"* ]]; then
    pass "enable-autologin.sh writes literal \$TERM for $real_test_user"
  else
    override_content=""
    if [[ -f "$autologin_dir/override.conf" ]]; then
      override_content="$(cat "$autologin_dir/override.conf")"
    fi
    fail "enable-autologin.sh valid user (status=$status, output=$output, content=$override_content, log=$log_content)"
  fi
fi

# Case 16: configure_pam creates LOGIN_FILE.lightxdm.bak once and preserves it across reruns
rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
write_stock_login
stock_login="$(cat "$LOGIN_FILE")"
configure_pam "plasma" 2>/dev/null
configure_pam "plasma" 2>/dev/null
configure_pam "gnome" 2>/dev/null
backup_content=""
if [[ -f "${LOGIN_FILE}.lightxdm.bak" ]]; then
  backup_content="$(cat "${LOGIN_FILE}.lightxdm.bak")"
fi
if [[ -f "${LOGIN_FILE}.lightxdm.bak" && "$backup_content" == "$stock_login" ]] &&
  grep -q 'pam_kwallet5\.so' "$LOGIN_FILE" &&
  grep -q 'pam_gnome_keyring\.so' "$LOGIN_FILE" &&
  ! compgen -G "${LOGIN_FILE}.lightxde.bak*" >/dev/null; then
  pass "configure_pam creates login.lightxdm.bak once and keeps pristine backup on reruns"
else
  fail "configure_pam backup-once (backup=$backup_content)"
fi

# Case 17: uninstall.sh exits 1 with a message when run without root
uninstall_dir="$TMP_DIR/uninstall"
rm -rf "$uninstall_dir"
mkdir -p "$uninstall_dir"
uninstall_home="$uninstall_dir/home"
mkdir -p "$uninstall_home"
uninstall_override="$uninstall_dir/override.conf"
uninstall_polkit="$uninstall_dir/49-nopasswd.rules"
echo "[Service]" >"$uninstall_override"
echo "// rule" >"$uninstall_polkit"
: >"$STUB_LOG"
set +e
output="$(TARGET_HOME="$uninstall_home" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" bash "$REPO_ROOT/uninstall.sh" 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 1 && "$output" == *"Please run as root"* && -f "${LOGIN_FILE}.lightxdm.bak" && -f "$uninstall_override" && -f "$uninstall_polkit" && -z "$log_content" ]]; then
  pass "uninstall.sh exits 1 with message when run without root"
else
  fail "uninstall.sh non-root check (status=$status, output=$output, log=$log_content)"
fi

# Case 18: install then uninstall restores LOGIN_FILE to pre-install content and removes backup, override, and polkit rule
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh restores pre-install PAM login and removes backup, override, and polkit rule (unshare -r unavailable)"
else
  rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
  write_stock_login
  stock_login="$(cat "$LOGIN_FILE")"
  configure_pam "plasma" 2>/dev/null
  configure_pam "gnome" 2>/dev/null
  : >"$STUB_LOG"
  set +e
  output="$(TARGET_HOME="$uninstall_home" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  restored_login="$(cat "$LOGIN_FILE")"
  if [[ $status -eq 0 && "$restored_login" == "$stock_login" && ! -e "${LOGIN_FILE}.lightxdm.bak" && ! -e "$uninstall_override" && ! -e "$uninstall_polkit" && "$log_content" == *"systemctl daemon-reload"* ]]; then
    pass "uninstall.sh restores pre-install PAM login and removes backup, override, and polkit rule"
  else
    fail "uninstall.sh restore (status=$status, output=$output, restored=$restored_login, log=$log_content)"
  fi
fi

# Case 19: uninstall.sh succeeds cleanly when backup, override, and polkit rule are absent
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh skips missing files cleanly (unshare -r unavailable)"
else
  : >"$STUB_LOG"
  set +e
  output="$(TARGET_HOME="$uninstall_home" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  restored_login="$(cat "$LOGIN_FILE")"
  if [[ $status -eq 0 && "$restored_login" == "$stock_login" && -z "$log_content" ]]; then
    pass "uninstall.sh skips missing files cleanly"
  else
    fail "uninstall.sh idempotent rerun (status=$status, output=$output, restored=$restored_login, log=$log_content)"
  fi
fi

# Case 20: copy_dotfiles backs up pre-existing .bash_profile and .xinitrc once, and uninstall.sh restores them and removes gpg-agent files
temp_home="$TMP_DIR/home_with_dotfiles"
mkdir -p "$temp_home"
echo "# user original bash_profile" >"$temp_home/.bash_profile"
echo "# user original xinitrc" >"$temp_home/.xinitrc"
(
  export HOME="$temp_home"
  export USER="${USER:-testuser}"
  copy_dotfiles "plasma" 2>/dev/null
  copy_dotfiles "gnome" 2>/dev/null
)
bash_bak=""
xinit_bak=""
if [[ -f "$temp_home/.bash_profile.lightxdm.bak" ]]; then
  bash_bak="$(cat "$temp_home/.bash_profile.lightxdm.bak")"
fi
if [[ -f "$temp_home/.xinitrc.lightxdm.bak" ]]; then
  xinit_bak="$(cat "$temp_home/.xinitrc.lightxdm.bak")"
fi
if [[ "$bash_bak" == "# user original bash_profile" && "$xinit_bak" == "# user original xinitrc" ]] &&
  [[ -f "$temp_home/.gpg-agent-kwallet" && -f "$temp_home/.gpg-agent-gnome" ]] &&
  ! grep -Fq "# user original bash_profile" "$temp_home/.bash_profile"; then
  pass "copy_dotfiles backs up existing .bash_profile and .xinitrc once without overwriting on second install"
else
  fail "copy_dotfiles backup once (bash_bak=$bash_bak, xinit_bak=$xinit_bak)"
fi

if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh restores .bash_profile and .xinitrc from backup and removes gpg-agent files (unshare -r unavailable)"
else
  set +e
  output="$(TARGET_HOME="$temp_home" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  restored_bash="$(cat "$temp_home/.bash_profile")"
  restored_xinit="$(cat "$temp_home/.xinitrc")"
  if [[ $status -eq 0 && "$restored_bash" == "# user original bash_profile" && "$restored_xinit" == "# user original xinitrc" ]] &&
    [[ ! -e "$temp_home/.bash_profile.lightxdm.bak" && ! -e "$temp_home/.xinitrc.lightxdm.bak" ]] &&
    [[ ! -e "$temp_home/.gpg-agent-kwallet" && ! -e "$temp_home/.gpg-agent-gnome" ]]; then
    pass "uninstall.sh restores .bash_profile and .xinitrc from backup and removes gpg-agent files"
  else
    fail "uninstall.sh dotfile restore (status=$status, output=$output, bash=$restored_bash, xinit=$restored_xinit)"
  fi
fi

# Case 21: uninstall.sh removes lightXDM dotfiles when no prior backup existed
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh removes installed dotfiles when no backup exists (unshare -r unavailable)"
else
  temp_home_fresh="$TMP_DIR/home_fresh"
  mkdir -p "$temp_home_fresh"
  (
    export HOME="$temp_home_fresh"
    export USER="${USER:-testuser}"
    copy_dotfiles "plasma" 2>/dev/null
  )
  set +e
  output="$(TARGET_HOME="$temp_home_fresh" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && ! -e "$temp_home_fresh/.bash_profile" && ! -e "$temp_home_fresh/.xinitrc" && ! -e "$temp_home_fresh/.gpg-agent-kwallet" ]] &&
    [[ -f "$temp_home_fresh/.bash_profile.lightxdm-removed" && -f "$temp_home_fresh/.xinitrc.lightxdm-removed" ]]; then
    pass "uninstall.sh removes installed dotfiles when no backup exists"
  else
    fail "uninstall.sh fresh dotfile removal (status=$status, output=$output)"
  fi
fi

# Case 22: gpg-agent dotfiles preserve SSH_AUTH_SOCK without enable-ssh-support, set it with enable-ssh-support, and never export GPG_TTY
cat >"$STUB_BIN/gpg-connect-agent" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$STUB_BIN/gpgconf" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--list-dirs" && "${2:-}" == "agent-ssh-socket" ]]; then
  echo "/run/user/1000/gnupg/S.gpg-agent.ssh"
fi
EOF
chmod +x "$STUB_BIN/gpg-connect-agent" "$STUB_BIN/gpgconf"

for gpg_dotfile in .gpg-agent-gnome .gpg-agent-kwallet; do
  gpg_home="$TMP_DIR/gpg_home_${gpg_dotfile#.}"
  rm -rf "$gpg_home"
  mkdir -p "$gpg_home/.gnupg"

  without_out="$(
    export HOME="$gpg_home"
    export PATH="$STUB_BIN:$PATH"
    export SSH_AUTH_SOCK="/tmp/sentinel-ssh.sock"
    unset GPG_TTY
    # shellcheck disable=SC1090
    source "$REPO_ROOT/dotfiles/$gpg_dotfile"
    printf '%s|%s\n' "$SSH_AUTH_SOCK" "${GPG_TTY-<unset>}"
  )"

  echo "enable-ssh-support" >"$gpg_home/.gnupg/gpg-agent.conf"
  with_out="$(
    export HOME="$gpg_home"
    export PATH="$STUB_BIN:$PATH"
    export SSH_AUTH_SOCK="/tmp/sentinel-ssh.sock"
    unset GPG_TTY
    # shellcheck disable=SC1090
    source "$REPO_ROOT/dotfiles/$gpg_dotfile"
    printf '%s|%s\n' "$SSH_AUTH_SOCK" "${GPG_TTY-<unset>}"
  )"

  if [[ "$without_out" == "/tmp/sentinel-ssh.sock|<unset>" && "$with_out" == "/run/user/1000/gnupg/S.gpg-agent.ssh|<unset>" ]]; then
    pass "$gpg_dotfile respects enable-ssh-support and does not export GPG_TTY"
  else
    fail "$gpg_dotfile (without=$without_out, with=$with_out)"
  fi
done

# Case 23: detect_de matches exact installed package via pacman -Qq and ignores description substrings
detect_stub_dir="$TMP_DIR/pacman_i3_nemo"
mkdir -p "$detect_stub_dir"
cat >"$detect_stub_dir/pacman" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-Qq" ]]; then
  case "${2:-}" in
    i3-wm | nemo)
      echo "$2"
      exit 0
      ;;
    *)
      exit 1
      ;;
  esac
elif [[ "${1:-}" == "-Qs" ]]; then
  case "${2:-}" in
    *cinnamon* | *nemo* | *i3*)
      echo "local/nemo 6.0.0"
      echo "    Cinnamon file manager"
      exit 0
      ;;
    *)
      exit 1
      ;;
  esac
fi
exit 1
EOF
chmod +x "$detect_stub_dir/pacman"

set +e
output="$(
  set -e
  export PATH="$detect_stub_dir:$PATH"
  detect_de
)"
status=$?
set -e
if [[ $status -eq 0 && "$output" == "i3" ]]; then
  pass "detect_de detects i3 with i3-wm and nemo installed"
else
  fail "detect_de with i3-wm and nemo (status=$status, output=$output)"
fi

# Case 24: detect_de returns unknown when only unrelated packages (nemo) are installed
nemo_stub_dir="$TMP_DIR/pacman_nemo_only"
mkdir -p "$nemo_stub_dir"
cat >"$nemo_stub_dir/pacman" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-Qq" ]]; then
  case "${2:-}" in
    nemo)
      echo "$2"
      exit 0
      ;;
    *)
      exit 1
      ;;
  esac
elif [[ "${1:-}" == "-Qs" ]]; then
  case "${2:-}" in
    *cinnamon* | *nemo*)
      echo "local/nemo 6.0.0"
      echo "    Cinnamon file manager"
      exit 0
      ;;
    *)
      exit 1
      ;;
  esac
fi
exit 1
EOF
chmod +x "$nemo_stub_dir/pacman"

set +e
output="$(
  set -e
  export PATH="$nemo_stub_dir:$PATH"
  detect_de
)"
status=$?
set -e
if [[ $status -eq 0 && "$output" == "unknown" ]]; then
  pass "detect_de returns unknown when only nemo is installed"
else
  fail "detect_de with only nemo (status=$status, output=$output)"
fi

# Case 25: copy_dotfiles writes dotfiles to HOME without invoking sudo
no_sudo_home="$TMP_DIR/home_no_sudo"
mkdir -p "$no_sudo_home"
sudo_hard_fail_dir="$TMP_DIR/sudo_hard_fail"
mkdir -p "$sudo_hard_fail_dir"
cat >"$sudo_hard_fail_dir/sudo" <<'EOF'
#!/usr/bin/env bash
echo "unexpected sudo $*" >>"${STUB_LOG:-/dev/null}"
exit 1
EOF
chmod +x "$sudo_hard_fail_dir/sudo"

: >"$STUB_LOG"
set +e
output="$(
  exec 2>&1
  set -e
  export PATH="$sudo_hard_fail_dir:$PATH"
  export HOME="$no_sudo_home"
  export USER="${USER:-testuser}"
  copy_dotfiles "plasma"
  copy_dotfiles "gnome"
)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 0 && -f "$no_sudo_home/.bash_profile" && -O "$no_sudo_home/.bash_profile" && -f "$no_sudo_home/.gpg-agent-kwallet" && -f "$no_sudo_home/.gpg-agent-gnome" && -x "$no_sudo_home/.xinitrc" && -z "$log_content" ]]; then
  pass "copy_dotfiles writes dotfiles to HOME without sudo"
else
  fail "copy_dotfiles without sudo (status=$status, log=$log_content, output=$output)"
fi

# Case 26: main prints check_root message when sudo is not installed
no_sudo_path="$TMP_DIR/no_sudo_path"
mkdir -p "$no_sudo_path"
grep_bin="$(command -v grep)"
bash_bin="$(command -v bash)"
ln -sf "$STUB_BIN/id" "$no_sudo_path/id"
ln -sf "$grep_bin" "$no_sudo_path/grep"
ln -sf "$bash_bin" "$no_sudo_path/bash"

: >"$STUB_LOG"
set +e
output="$(
  exec 2>&1
  export PATH="$no_sudo_path"
  export USER="${USER:-testuser}"
  main
)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 1 && "$output" == *"sudo is required but not installed. Please install sudo and re-run."* && "$output" != *"command not found"* && -z "$log_content" ]]; then
  pass "main prints check_root message when sudo is not installed"
else
  fail "main without sudo installed (status=$status, output=$output, log=$log_content)"
fi

# Case 27: main rejects root via check_root and checks USER (not SUDO_USER) for wheel group
if [[ $can_unshare -eq 0 ]]; then
  skip "main rejects running as root via check_root (unshare -r unavailable)"
else
  : >"$STUB_LOG"
  set +e
  output="$(unshare -r bash "$REPO_ROOT/install.sh" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -eq 1 && "$output" == *"Do not run this script as root. Please run as a regular user."* && -z "$log_content" ]]; then
    pass "main rejects running as root via check_root"
  else
    fail "main root check (status=$status, output=$output, log=$log_content)"
  fi
fi

id_user_check_dir="$TMP_DIR/id_user_check"
mkdir -p "$id_user_check_dir"
cat >"$id_user_check_dir/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-nG" ]]; then
  if [[ "${2:-}" == "wheeluser" ]]; then
    echo "users wheel"
  else
    echo "users"
  fi
else
  echo "1000"
fi
EOF
chmod +x "$id_user_check_dir/id"

: >"$STUB_LOG"
set +e
output="$(
  exec 2>&1
  export PATH="$id_user_check_dir:$STUB_BIN:$PATH"
  export USER="plainuser"
  export SUDO_USER="wheeluser"
  main
)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 1 && "$output" == *"ERROR: User 'plainuser' is not in the 'wheel' group."* && -z "$log_content" ]]; then
  pass "main checks USER rather than SUDO_USER for wheel group"
else
  fail "main wheel check with SUDO_USER set (status=$status, output=$output, log=$log_content)"
fi

# Case 28: configure_pam preserves every original line when LOGIN_FILE lacks a trailing newline
rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
printf '%s' '#%PAM-1.0

auth       requisite    pam_nologin.so
auth       include      system-local-login
account    include      system-local-login
session    include      system-local-login
password   include      system-local-login' >"$LOGIN_FILE"
configure_pam "gnome" 2>/dev/null
no_nl_content="$(cat "$LOGIN_FILE")"
if grep -Fqx "#%PAM-1.0" "$LOGIN_FILE" &&
  grep -Fqx "auth       requisite    pam_nologin.so" "$LOGIN_FILE" &&
  grep -Fqx "auth       include      system-local-login" "$LOGIN_FILE" &&
  grep -Fqx "account    include      system-local-login" "$LOGIN_FILE" &&
  grep -Fqx "session    include      system-local-login" "$LOGIN_FILE" &&
  grep -Fqx "password   include      system-local-login" "$LOGIN_FILE" &&
  grep -Eq '^auth[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so$' "$LOGIN_FILE" &&
  grep -Eq '^session[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so auto_start$' "$LOGIN_FILE"; then
  pass "configure_pam preserves every original line when LOGIN_FILE has no trailing newline"
else
  fail "configure_pam without trailing newline (content=$no_nl_content)"
fi

# Case 29: configure_pam appends active rules even when commented module lines exist
rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
write_stock_login
echo "# auth optional pam_gnome_keyring.so" >>"$LOGIN_FILE"
echo "# session optional pam_kwallet5.so force_run" >>"$LOGIN_FILE"
configure_pam "gnome" 2>/dev/null
configure_pam "plasma" 2>/dev/null
commented_content="$(cat "$LOGIN_FILE")"
if grep -Eq '^auth[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so$' "$LOGIN_FILE" &&
  grep -Eq '^session[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so auto_start$' "$LOGIN_FILE" &&
  grep -Eq '^auth[[:space:]]+optional[[:space:]]+pam_kwallet5\.so$' "$LOGIN_FILE" &&
  grep -Eq '^session[[:space:]]+optional[[:space:]]+pam_kwallet5\.so force_run$' "$LOGIN_FILE"; then
  pass "configure_pam appends active rules when only commented module lines exist"
else
  fail "configure_pam with commented module lines (content=$commented_content)"
fi

# Zero-padded menu numbers are read as decimal, not octal
for padded in "08:budgie" "09:i3"; do
  set +e
  output="$(prompt_de_selection <<<"${padded%%:*}" 2>/dev/null)"
  status=$?
  set -e
  if [[ $status -eq 0 && "$output" == "${padded#*:}" ]]; then
    pass "prompt_de_selection maps ${padded%%:*} to ${padded#*:}"
  else
    fail "prompt_de_selection ${padded%%:*} (status=$status, output=$output)"
  fi
done

exit "$failures"
