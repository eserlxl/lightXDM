#!/usr/bin/env bash
# tests/run.sh: Behavior test harness for lightXDM scripts
# Test cases change HOME/USER inside subshells on purpose, to keep each case isolated.
# shellcheck disable=SC2030,SC2031
set -euo pipefail

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
if [[ "${1:-}" == "daemon-reload" && "${STUB_SYSTEMCTL_FAIL_RELOAD:-0}" == "1" ]]; then
  exit 1
fi
if [[ "${1:-}" == "enable" && "${2:-}" == "${STUB_SYSTEMCTL_FAIL_UNIT:-}" ]]; then
  exit 1
fi
if [[ "${1:-}" == "is-enabled" && -n "${STUB_SYSTEMCTL_STATE:-}" ]]; then
  echo "$STUB_SYSTEMCTL_STATE"
  exit 1
fi
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
for startup_command in startx startxfce4 startlxqt startlxde mate-session cinnamon-session i3 dwm; do
  cp "$STUB_BIN/chown" "$STUB_BIN/$startup_command"
done
export PATH="$STUB_BIN:$PATH"
export STUB_LOG="$TMP_DIR/stub.log"
export LOGIN_FILE="$TMP_DIR/login"
export AUTOLOGIN_DROPIN_DIR="$TMP_DIR/getty@tty1.service.d"
export POLKIT_RULE_DEST="$TMP_DIR/49-nopasswd.rules"
export DISPLAY_MANAGER_LINK="$TMP_DIR/display-manager.service"
export DM_STATE_FILE="$TMP_DIR/lightxdm/disabled-display-managers"

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
if [[ $status -eq 0 && "$log_content" == *"pacman -S --needed --noconfirm"* && "$log_content" == *"i3 xterm dex gnome-keyring polkit-gnome"* ]]; then
  pass "install_packages invokes pacman for i3"
else
  fail "install_packages invokes pacman for i3 (status=$status, log=$log_content)"
fi

# Case 3: prompt_de_selection maps "1" to "xfce" without log or PS3 leakage
unset PS3
prompt_out="$TMP_DIR/prompt_out"
set +e
prompt_de_selection <<<"1" >"$prompt_out" 2>/dev/null
status=$?
set -e
output="$(cat "$prompt_out")"
if [[ $status -eq 0 && "$output" == "xfce" && -z "${PS3+x}" ]]; then
  pass "prompt_de_selection maps option 1 to xfce without leaking log or PS3"
else
  fail "prompt_de_selection option 1 (status=$status, output=$output, PS3=${PS3-<unset>})"
fi

# Case 4: prompt_de_selection returns 2 with empty stdout on Quit ("7")
set +e
output="$(prompt_de_selection <<<"7" 2>/dev/null)"
status=$?
set -e
if [[ $status -eq 2 && -z "$output" ]]; then
  pass "prompt_de_selection returns 2 on Quit"
else
  fail "prompt_de_selection Quit (status=$status, output=$output)"
fi

# Case 5: prompt_de_selection returns 1 with empty stdout on EOF
set +e
output="$(prompt_de_selection </dev/null 2>/dev/null)"
status=$?
set -e
if [[ $status -eq 1 && -z "$output" ]]; then
  pass "prompt_de_selection returns 1 on EOF"
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
for non_plasma_de in xfce lxqt lxde mate cinnamon budgie i3 dwm; do
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
  shift
  export USER="${USER:-testuser}"
  unset SUDO_USER
  detect_de() {
    echo "detect_de" >>"$STUB_LOG"
    printf '%s\n' "${STUB_DETECTED_DE:-i3}"
  }
  if [[ "${STUB_REAL_PROMPT:-0}" != "1" ]]; then
    prompt_de_selection() {
      echo "prompt_de_selection" >>"$STUB_LOG"
      return "${STUB_PROMPT_RC:-1}"
    }
    prompt_detected_de_selection() {
      echo "prompt_detected_de_selection $*" >>"$STUB_LOG"
      if [[ -n "${STUB_PROMPT_DE:-}" ]]; then
        printf '%s\n' "$STUB_PROMPT_DE"
      fi
      return "${STUB_PROMPT_RC:-1}"
    }
  fi
  stub_install_step() {
    echo "$*" >>"$STUB_LOG"
    if [[ "$1" == "${STUB_FAIL_STEP:-}" ]]; then
      return "${STUB_FAIL_STATUS:-1}"
    fi
  }
  install_packages() { stub_install_step install_packages "$@"; }
  copy_dotfiles() { stub_install_step copy_dotfiles "$1"; }
  configure_pam() { stub_install_step configure_pam "$1"; }
  install_polkit_rule() { stub_install_step install_polkit_rule; }
  disable_display_managers() { stub_install_step disable_display_managers; }
  enable_autologin() { stub_install_step enable_autologin "$1"; }
  main "$@"
)

# --autologin needs --no-keyring, and then enables autologin for the user after the display managers
: >"$STUB_LOG"
set +e
output="$(run_main_with_stubs "$sudo_pw_dir" --de i3 --autologin 2>&1)"
status=$?
set -e
if [[ $status -ne 0 && "$output" == *"--autologin requires --no-keyring"* && ! -s "$STUB_LOG" ]]; then
  pass "install.sh refuses --autologin without --no-keyring before changing anything"
else
  fail "install.sh --autologin without --no-keyring (status=$status, log=$(cat "$STUB_LOG"), output=$output)"
fi
: >"$STUB_LOG"
set +e
output="$(run_main_with_stubs "$sudo_pw_dir" --de i3 --no-keyring --autologin 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 0 && "$log_content" == *$'disable_display_managers\nenable_autologin '"${USER:-testuser}"* &&
  "$output" == *"TTY1 autologin is enabled"* ]]; then
  pass "install.sh --no-keyring --autologin enables autologin after the display managers"
else
  fail "install.sh --no-keyring --autologin (status=$status, log=$log_content, output=$output)"
fi
: >"$STUB_LOG"
output="$(run_main_with_stubs "$sudo_pw_dir" --de i3 --no-keyring 2>&1)"
if [[ "$(cat "$STUB_LOG")" != *enable_autologin* && "$output" != *"TTY1 autologin is enabled"* ]]; then
  pass "install.sh without --autologin leaves autologin alone"
else
  fail "install.sh without --autologin ran enable_autologin (log=$(cat "$STUB_LOG"))"
fi

# A failed enable_autologin step reports the steps already done and keeps its status
: >"$STUB_LOG"
set +e
output="$(
  exec 2>&1
  set -e
  STUB_FAIL_STEP=enable_autologin STUB_FAIL_STATUS=23 run_main_with_stubs "$sudo_pw_dir" --de i3 --no-keyring --autologin
)"
status=$?
set -e
if [[ $status -eq 23 && "$output" == *"Install stopped during enable_autologin; already done: install_packages copy_dotfiles install_polkit_rule disable_display_managers"* &&
  "$output" != *"lightXDM install complete!"* ]]; then
  pass "install.sh reports a failed enable_autologin step and keeps its exit status"
else
  fail "install.sh failed enable_autologin step (status=$status, output=$output)"
fi

# enable_autologin runs the bundled enable-autologin.sh through sudo for the given user
autologin_call_dir="$TMP_DIR/autologin_call"
mkdir -p "$autologin_call_dir"
cat >"$autologin_call_dir/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >>"$STUB_LOG"
EOF
chmod +x "$autologin_call_dir/sudo"
: >"$STUB_LOG"
# shellcheck disable=SC2016  # expand inside the child shell
env -u SHELLOPTS PATH="$autologin_call_dir:$PATH" bash -c 'source "$1/install.sh"; enable_autologin someone' bash "$REPO_ROOT" >/dev/null 2>&1 || true
if [[ "$(cat "$STUB_LOG")" == "sudo bash $REPO_ROOT/enable-autologin.sh someone" ]]; then
  pass "enable_autologin calls enable-autologin.sh through sudo for the user"
else
  fail "enable_autologin call (log=$(cat "$STUB_LOG"))"
fi

: >"$STUB_LOG"
set +e
output="$(run_main_with_stubs "$sudo_pw_dir" 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 0 && "$log_content" == *"sudo -v"* && "$log_content" == *"install_packages i3"* &&
  "$output" != *"Install stopped during"* && "$output" != *"rerunning install.sh is safe"* ]]; then
  pass "main succeeds when sudo requires a password (-n fails, -v succeeds)"
else
  fail "main with password sudo (status=$status, log=$log_content, output=$output)"
fi

# A failure at any install step reports only completed steps and preserves status.
completed_install_steps=()
recovery_hint="After fixing the error, rerunning install.sh is safe; uninstall.sh reverts configuration changes (installed packages stay)."
for failed_install_step in install_packages copy_dotfiles configure_pam install_polkit_rule disable_display_managers; do
  for failed_install_status in 1 23; do
    : >"$STUB_LOG"
    set +e
    # exec 2>&1: main's EXIT trap runs after a per-call redirection is undone.
    output="$(
      exec 2>&1
      set -e
      STUB_FAIL_STEP="$failed_install_step" STUB_FAIL_STATUS="$failed_install_status" \
        run_main_with_stubs "$sudo_pw_dir" --de i3
    )"
    status=$?
    set -e
    expected_stopped="=> Install stopped during $failed_install_step; already done: ${completed_install_steps[*]:-none}"
    if [[ $status -eq $failed_install_status && "$output" == *"$recovery_hint"* &&
      "$output" != *"lightXDM install complete!"* ]] &&
      grep -Fxq -- "$expected_stopped" <<<"$output"; then
      pass "main reports $failed_install_step failure and completed steps (status=$status)"
    else
      fail "main step failure ($failed_install_step, status=$status, output=$output)"
    fi
  done
  completed_install_steps+=("$failed_install_step")
done

# Skipped steps must not appear in the completed list.
: >"$STUB_LOG"
set +e
output="$(
  exec 2>&1
  set -e
  STUB_FAIL_STEP=disable_display_managers run_main_with_stubs "$sudo_pw_dir" \
    --de i3 --no-packages --no-keyring --no-polkit-rule
)"
status=$?
set -e
if [[ $status -eq 1 && "$output" == *"$recovery_hint"* &&
  "$output" != *"lightXDM install complete!"* ]] &&
  grep -Fxq '=> Install stopped during disable_display_managers; already done: copy_dotfiles' <<<"$output"; then
  pass "main excludes skipped steps from failure report"
else
  fail "main skipped steps failure report (status=$status, output=$output)"
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
if [[ $status -eq 1 && "$output" == *"ERROR: Failed to authenticate with sudo. Exiting."* &&
  "$output" == *"uncomment %wheel ALL=(ALL:ALL) ALL"* && -z "$log_content" &&
  "$output" != *"Install stopped during"* ]]; then
  pass "main exits 1 when sudo -v fails"
else
  fail "main when sudo -v fails (status=$status, log=$log_content, output=$output)"
fi

# Case 10a: main fails with a message when the desktop menu reaches EOF
: >"$STUB_LOG"
set +e
output="$(
  exec 2>&1
  export PATH="$sudo_pw_dir:$PATH"
  export USER="${USER:-testuser}"
  # shellcheck disable=SC2317,SC2329  # override is called indirectly through main
  detect_de() { echo "unknown"; }
  main </dev/null
)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 1 && "$output" == *"No desktop environment was chosen. Exiting."* && "$log_content" == "sudo -v" ]]; then
  pass "main exits 1 with a message on desktop menu EOF"
else
  fail "main desktop menu EOF (status=$status, output=$output, log=$log_content)"
fi

# Case 10b: a missing session template stops main before any installation step
missing_template_dir="$TMP_DIR/missing_template"
mkdir -p "$missing_template_dir"
cp -r "$REPO_ROOT/dotfiles" "$REPO_ROOT/polkit" "$missing_template_dir/"
rm "$missing_template_dir/dotfiles/.xinitrc-i3"
for missing_template_mode in packages no-packages; do
  missing_template_args=(--de i3)
  if [[ "$missing_template_mode" == "no-packages" ]]; then
    missing_template_args+=(--no-packages)
  fi
  : >"$STUB_LOG"
  set +e
  output="$(
    # shellcheck disable=SC2034  # main uses SCRIPT_DIR from the sourced installer
    SCRIPT_DIR="$missing_template_dir"
    run_main_with_stubs "$sudo_pw_dir" "${missing_template_args[@]}" 2>&1
  )"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -eq 1 && "$output" == *"No .xinitrc template for i3: $missing_template_dir/dotfiles/.xinitrc-i3"* && "$log_content" == "sudo -v" ]]; then
    pass "main stops before installation when the session template is missing ($missing_template_mode)"
  else
    fail "main with missing session template ($missing_template_mode, status=$status, log=$log_content, output=$output)"
  fi
done

# Case 10c: Wayland-only desktops are refused before any installation step
for refused_de in plasma gnome budgie; do
  for refused_mode in detected explicit skip-options; do
    refused_args=()
    expected_refusal_log=$'sudo -v\ndetect_de'
    if [[ "$refused_mode" != "detected" ]]; then
      refused_args=(--de "$refused_de")
      expected_refusal_log="sudo -v"
    fi
    if [[ "$refused_mode" == "skip-options" ]]; then
      refused_args+=(--no-packages --no-keyring --no-polkit-rule)
    fi
    : >"$STUB_LOG"
    set +e
    output="$(STUB_DETECTED_DE="$refused_de" run_main_with_stubs "$sudo_pw_dir" "${refused_args[@]}" 2>&1)"
    status=$?
    set -e
    log_content="$(cat "$STUB_LOG")"
    if [[ $status -eq 1 && "$output" == *"$refused_de now runs only on Wayland and cannot be started with startx (see README.md)."* &&
      "$log_content" == "$expected_refusal_log" && "$output" != *"lightXDM install complete!"* &&
      "$output" != *"Install stopped during"* ]]; then
      pass "main refuses $refused_de before any installation step ($refused_mode)"
    else
      fail "main refusal of $refused_de ($refused_mode, status=$status, log=$log_content, output=$output)"
    fi
  done
done

# Case 10d: all six X11 desktops still run every installation step
for supported_de in xfce lxqt lxde mate cinnamon i3; do
  : >"$STUB_LOG"
  set +e
  output="$(STUB_DETECTED_DE="$supported_de" run_main_with_stubs "$sudo_pw_dir" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -eq 0 && "$log_content" == *"install_packages $supported_de"* &&
    "$log_content" == *"copy_dotfiles $supported_de"* && "$log_content" == *"configure_pam $supported_de"* &&
    "$log_content" == *"install_polkit_rule"* && "$log_content" == *"disable_display_managers"* ]]; then
    pass "main still configures $supported_de"
  else
    fail "main with $supported_de (status=$status, log=$log_content, output=$output)"
  fi
done

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
    if [[ $status -ne 0 && "$output" == *"Usage:"* && ! -e "$autologin_dir/lightxdm-autologin.conf" && -z "$log_content" ]]; then
      pass "enable-autologin.sh $help_flag prints usage and writes nothing"
    else
      fail "enable-autologin.sh $help_flag (status=$status, output=$output, log=$log_content)"
    fi
  done
fi

# Status runs directly, without unshare -r, so normal users exercise the read-only path.
status_dir="$TMP_DIR/autologin_status"
for status_case in disabled missing enabled legacy both foreign later kwallet gnome commented reset keyring-disabled foreign-keyring reset-legacy; do
  rm -rf "$status_dir"
  mkdir -p "$status_dir/getty.d"
  printf '# PAM login\n' >"$status_dir/login"
  expected_status="disabled"
  case "$status_case" in
    enabled|both|later|kwallet|gnome|commented|reset|reset-legacy)
      # shellcheck disable=SC2016  # $TERM is literal systemd syntax
      printf '[Service]\nExecStart=\nExecStart=-/usr/bin/agetty --autologin testuser --noclear %%I $TERM\n' >"$status_dir/getty.d/lightxdm-autologin.conf"
      expected_status="enabled for testuser ($status_dir/getty.d/lightxdm-autologin.conf)"
      ;;
  esac
  case "$status_case" in
    missing)
      rmdir "$status_dir/getty.d"
      ;;
    legacy|both)
      # shellcheck disable=SC2016
      printf '[Service]\nExecStart=\nExecStart=-/usr/bin/agetty --autologin legacyuser --noclear %%I $TERM\n' >"$status_dir/getty.d/override.conf"
      expected_status="enabled for legacyuser ($status_dir/getty.d/override.conf)"
      ;;
    foreign)
      printf '[Service]\n  ExecStart = /usr/bin/agetty --autologin foreignuser tty1\n' >"$status_dir/getty.d/00-foreign.conf"
      cp "$status_dir/getty.d/00-foreign.conf" "$status_dir/getty.d/override.conf"
      ;;
    later)
      printf '[Service]\nExecStart=/usr/bin/agetty tty1\n' >"$status_dir/getty.d/zz-later.conf"
      ;;
    kwallet)
      printf 'auth optional pam_kwallet5.so\n' >"$status_dir/login"
      ;;
    gnome)
      printf '%s\n' '-session optional pam_gnome_keyring.so auto_start' >"$status_dir/login"
      ;;
    foreign-keyring)
      printf '[Service]\nExecStart=\nExecStart=/usr/bin/agetty --autologin foreignuser tty1\n' >"$status_dir/getty.d/00-foreign.conf"
      printf 'auth optional pam_gnome_keyring.so\n' >"$status_dir/login"
      ;;
    reset-legacy)
      # shellcheck disable=SC2016
      printf 'ExecStart=\nExecStart=-/usr/bin/agetty --noclear %%I $TERM\n' >>"$status_dir/getty.d/lightxdm-autologin.conf"
      # shellcheck disable=SC2016
      printf '[Service]\nExecStart=\nExecStart=-/usr/bin/agetty --autologin legacyuser --noclear %%I $TERM\n' >"$status_dir/getty.d/override.conf"
      expected_status="enabled for legacyuser ($status_dir/getty.d/override.conf)"
      ;;
    keyring-disabled)
      printf 'auth optional pam_gnome_keyring.so\n' >"$status_dir/login"
      ;;
    reset)
      # shellcheck disable=SC2016
      printf 'ExecStart=\nExecStart=-/usr/bin/agetty --noclear %%I $TERM\n' >>"$status_dir/getty.d/lightxdm-autologin.conf"
      expected_status="disabled"
      ;;
    commented)
      printf '# auth optional pam_kwallet5.so\nsession optional pam_other.so # pam_gnome_keyring.so\n' >"$status_dir/login"
      printf '[Service]\nExecStart=/usr/bin/agetty tty1\n' >"$status_dir/getty.d/00-earlier.conf"
      printf '# ExecStart=/usr/bin/agetty --autologin ignored tty1\n' >"$status_dir/getty.d/zz-commented.conf"
      ;;
  esac
  : >"$STUB_LOG"
  status_before="$(find "$status_dir" -printf '%P %y %m %s %T@ %C@ %l\n' -type f -exec sha256sum {} \; | LC_ALL=C sort)"
  set +e
  output="$(env OVERRIDE_DIR="$status_dir/getty.d" LOGIN_FILE="$status_dir/login" bash "$REPO_ROOT/enable-autologin.sh" --status 2>&1)"
  status=$?
  set -e
  status_after="$(find "$status_dir" -printf '%P %y %m %s %T@ %C@ %l\n' -type f -exec sha256sum {} \; | LC_ALL=C sort)"
  log_content="$(cat "$STUB_LOG")"
  status_warnings_ok=0
  case "$status_case" in
    both)
      if [[ "$output" == *"Warning: $status_dir/getty.d/lightxdm-autologin.conf still enables autologin."* ]]; then
        status_warnings_ok=1
      fi
      ;;
    foreign)
      if [[ "$output" == *"Warning: $status_dir/getty.d/00-foreign.conf still enables autologin."* &&
        "$output" == *"Warning: $status_dir/getty.d/override.conf still enables autologin."* &&
        "$output" != *"overrides autologin with a later ExecStart="* ]]; then
        status_warnings_ok=1
      fi
      ;;
    later)
      if [[ "$output" == *"Warning: $status_dir/getty.d/zz-later.conf overrides autologin with a later ExecStart="* ]]; then
        status_warnings_ok=1
      fi
      ;;
    foreign-keyring)
      if [[ "$output" == *"Warning: $status_dir/getty.d/00-foreign.conf still enables autologin."* &&
        "$output" == *"Warning: PAM keyring unlock is configured in $status_dir/login"* ]]; then
        status_warnings_ok=1
      fi
      ;;
    kwallet|gnome)
      if [[ "$output" == *"Warning: PAM keyring unlock is configured in $status_dir/login; the keyring will not unlock automatically with autologin"* ]]; then
        status_warnings_ok=1
      fi
      ;;
    *)
      if [[ "$output" != *"Warning:"* ]]; then
        status_warnings_ok=1
      fi
      ;;
  esac
  if [[ $status -eq 0 && "${output%%$'\n'*}" == "$expected_status" && $status_warnings_ok -eq 1 &&
    "$status_before" == "$status_after" && -z "$log_content" ]]; then
    pass "enable-autologin.sh --status reports $status_case without changing files or calling systemctl"
  else
    fail "enable-autologin.sh --status $status_case (status=$status, output=$output, log=$log_content, unchanged=$([[ "$status_before" == "$status_after" ]] && echo yes || echo no))"
  fi
done

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
  if [[ $status_zero -ne 0 && "$output_zero" == *"Usage:"* && $status_two -ne 0 && "$output_two" == *"Usage:"* && ! -e "$autologin_dir/lightxdm-autologin.conf" ]]; then
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
    if [[ $status -ne 0 && "$output" == *"$expected_msg"* && ! -e "$autologin_dir/lightxdm-autologin.conf" && -z "$log_content" ]]; then
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
  if [[ $status -ne 0 && "$output" == *"Refusing to enable autologin for root"* && ! -e "$autologin_dir/lightxdm-autologin.conf" && -z "$log_content" ]]; then
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
    if [[ $status -ne 0 && "$output" == *"non-interactive shell"* && ! -e "$autologin_dir/lightxdm-autologin.conf" && -z "$log_content" ]]; then
      pass "enable-autologin.sh rejects disallowed account '$nologin_user'"
    else
      fail "enable-autologin.sh should reject '$nologin_user' (status=$status, output=$output, log=$log_content)"
    fi
  fi
fi

# Case 15: enable-autologin.sh writes lightxdm-autologin.conf with literal $TERM for valid user
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
  if [[ $status -eq 0 && -f "$autologin_dir/lightxdm-autologin.conf" && ! -e "$autologin_dir/override.conf" ]] &&
    grep -Fqx -- "[Service]" "$autologin_dir/lightxdm-autologin.conf" &&
    grep -Fqx -- "ExecStart=" "$autologin_dir/lightxdm-autologin.conf" &&
    grep -Fqx -- "$expected_exec" "$autologin_dir/lightxdm-autologin.conf" &&
    ! grep -Fq -- "xterm-kitty" "$autologin_dir/lightxdm-autologin.conf" &&
    [[ "$log_content" == *"systemctl daemon-reload"* ]]; then
    pass "enable-autologin.sh writes literal \$TERM for $real_test_user"
  else
    override_content=""
    if [[ -f "$autologin_dir/lightxdm-autologin.conf" ]]; then
      override_content="$(cat "$autologin_dir/lightxdm-autologin.conf")"
    fi
    fail "enable-autologin.sh valid user (status=$status, output=$output, content=$override_content, log=$log_content)"
  fi
fi

# Case 15a: the drop-in is a readable regular file even under a strict umask or a symlink at its path
if [[ $can_unshare -eq 0 ]]; then
  skip "enable-autologin.sh writes a readable regular drop-in (unshare -r unavailable)"
else
  perm_dir="$TMP_DIR/autologin_perm"
  mkdir -p "$perm_dir/getty.d"
  perm_target="$perm_dir/elsewhere.conf"
  : >"$perm_target"
  ln -s "$perm_target" "$perm_dir/getty.d/lightxdm-autologin.conf"
  chmod 700 "$perm_dir/getty.d"
  set +e
  output="$(umask 077; env OVERRIDE_DIR="$perm_dir/getty.d" LOGIN_FILE="$perm_dir/login" unshare -r bash "$REPO_ROOT/enable-autologin.sh" "$real_test_user" 2>&1)"
  status=$?
  set -e
  perm_dropin="$perm_dir/getty.d/lightxdm-autologin.conf"
  if [[ $status -eq 0 && -f "$perm_dropin" && ! -L "$perm_dropin" && ! -s "$perm_target" ]] &&
    [[ "$(stat -c '%a' "$perm_dropin")" == 644 && "$(stat -c '%a' "$perm_dir/getty.d")" == 755 ]] &&
    grep -q -- "--autologin $real_test_user" "$perm_dropin"; then
    pass "enable-autologin.sh replaces a symlinked drop-in with a 0644 regular file under umask 077"
  else
    fail "enable-autologin.sh drop-in mode/symlink (status=$status, mode=$(stat -c '%a' "$perm_dropin" 2>/dev/null), link=$([[ -L "$perm_dropin" ]] && echo yes || echo no), output=$output)"
  fi
fi

# --status skips an unreadable drop-in with a note instead of failing
unread_dir="$TMP_DIR/autologin_unreadable"
mkdir -p "$unread_dir/getty.d"
# shellcheck disable=SC2016  # $TERM is literal systemd syntax
printf '[Service]\nExecStart=\nExecStart=-/usr/bin/agetty --autologin someone --noclear %%I $TERM\n' >"$unread_dir/getty.d/lightxdm-autologin.conf"
chmod 000 "$unread_dir/getty.d/lightxdm-autologin.conf"
set +e
output="$(env OVERRIDE_DIR="$unread_dir/getty.d" LOGIN_FILE="$unread_dir/login" bash "$REPO_ROOT/enable-autologin.sh" --status 2>&1)"
status=$?
set -e
chmod 644 "$unread_dir/getty.d/lightxdm-autologin.conf"
if [[ $EUID -eq 0 ]]; then
  skip "enable-autologin.sh --status with an unreadable drop-in (running as root)"
elif [[ $status -eq 0 && "$output" == *"cannot read $unread_dir/getty.d/lightxdm-autologin.conf"* && "$output" != *"Permission denied"* ]]; then
  pass "enable-autologin.sh --status notes an unreadable drop-in and exits 0"
else
  fail "enable-autologin.sh --status unreadable drop-in (status=$status, output=$output)"
fi

# --status notes an unreadable drop-in directory instead of silently reporting disabled
chmod 700 "$unread_dir/getty.d"
chmod 000 "$unread_dir/getty.d"
set +e
output="$(env OVERRIDE_DIR="$unread_dir/getty.d" LOGIN_FILE="$unread_dir/login" bash "$REPO_ROOT/enable-autologin.sh" --status 2>&1)"
status=$?
set -e
chmod 755 "$unread_dir/getty.d"
if [[ $EUID -eq 0 ]]; then
  skip "enable-autologin.sh --status with an unreadable drop-in directory (running as root)"
elif [[ $status -eq 0 && "$output" == *"cannot read $unread_dir/getty.d;"* ]]; then
  pass "enable-autologin.sh --status notes an unreadable drop-in directory"
else
  fail "enable-autologin.sh --status unreadable drop-in directory (status=$status, output=$output)"
fi

# Case 15b: only later drop-ins with an active ExecStart setting warn about overriding autologin
if [[ $can_unshare -eq 0 ]]; then
  skip "enable-autologin.sh warns about later ExecStart drop-ins (unshare -r unavailable)"
else
  warning_dir="$TMP_DIR/autologin_warning"
  mkdir -p "$warning_dir"
  printf '[Service]\nExecStart=/usr/bin/agetty tty1\n' >"$warning_dir/00-earlier.conf"
  for override_setting in '# ExecStart=/usr/bin/agetty tty1' '  ExecStart = /usr/bin/agetty tty1'; do
    printf '[Service]\nTTYVTDisallocate=no\n%s\n' "$override_setting" >"$warning_dir/override.conf"
    set +e
    output="$(env OVERRIDE_DIR="$warning_dir" LOGIN_FILE="$warning_dir/login" unshare -r bash "$REPO_ROOT/enable-autologin.sh" "$real_test_user" 2>&1)"
    status=$?
    set -e
    if [[ "$override_setting" == '#'* ]]; then
      if [[ $status -eq 0 && "$output" != *"Warning:"* ]]; then
        pass "enable-autologin.sh does not warn for earlier or commented ExecStart settings"
      else
        fail "enable-autologin.sh unexpected override warning (status=$status, output=$output)"
      fi
    elif [[ $status -eq 0 && "$output" == *"Warning: $warning_dir/override.conf overrides autologin"* && "$output" != *"Warning: $warning_dir/00-earlier.conf"* ]]; then
      pass "enable-autologin.sh warns by name when a later drop-in overrides autologin"
    else
      fail "enable-autologin.sh missing override warning (status=$status, output=$output)"
    fi
  done
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
uninstall_autologin="$uninstall_dir/lightxdm-autologin.conf"
uninstall_override="$uninstall_dir/override.conf"
uninstall_polkit="$uninstall_dir/49-nopasswd.rules"
printf "[Service]\nExecStart=\nExecStart=-/usr/bin/agetty --autologin testuser --noclear %%I \$TERM\n" >"$uninstall_autologin"
cp "$uninstall_autologin" "$uninstall_override"
echo "// rule" >"$uninstall_polkit"
: >"$STUB_LOG"
set +e
output="$(TARGET_HOME="$uninstall_home" AUTOLOGIN_DROPIN="$uninstall_autologin" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" bash "$REPO_ROOT/uninstall.sh" 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 1 && "$output" == *"Please run as root"* && -f "${LOGIN_FILE}.lightxdm.bak" && -f "$uninstall_autologin" && -f "$uninstall_override" && -f "$uninstall_polkit" && -z "$log_content" ]]; then
  pass "uninstall.sh exits 1 with message when run without root"
else
  fail "uninstall.sh non-root check (status=$status, output=$output, log=$log_content)"
fi

# Case 18: install then uninstall restores LOGIN_FILE to pre-install content and removes backup, autologin drop-in, legacy override, and polkit rule
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh restores pre-install PAM login and removes backup, autologin drop-in, legacy override, and polkit rule (unshare -r unavailable)"
else
  rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
  write_stock_login
  stock_login="$(cat "$LOGIN_FILE")"
  stock_login_hash="$(sha256sum < "$LOGIN_FILE")"
  configure_pam "plasma" 2>/dev/null
  configure_pam "gnome" 2>/dev/null
  cp "$POLKIT_RULE_SRC" "$uninstall_polkit"
  : >"$STUB_LOG"
  set +e
  output="$(TARGET_HOME="$uninstall_home" AUTOLOGIN_DROPIN="$uninstall_autologin" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  restored_login="$(cat "$LOGIN_FILE")"
  if [[ $status -eq 0 && "$(sha256sum < "$LOGIN_FILE")" == "$stock_login_hash" && ! -e "${LOGIN_FILE}.lightxdm.bak" && ! -e "$uninstall_autologin" && ! -e "$uninstall_override" && ! -e "$uninstall_polkit" && "$log_content" == *"systemctl daemon-reload"* ]]; then
    pass "uninstall.sh restores pre-install PAM login and removes backup, autologin drop-in, legacy override, and polkit rule"
  else
    fail "uninstall.sh restore (status=$status, output=$output, restored=$restored_login, log=$log_content)"
  fi
fi

# Case 18b: uninstall restores exact PAM bytes for unusual original file endings
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh restores PAM bytes with unusual endings (unshare -r unavailable)"
else
  for pam_original in '' "$stock_login" "$stock_login"$'\n\n'; do
    printf '%s' "$pam_original" >"$LOGIN_FILE"
    original_hash="$(sha256sum < "$LOGIN_FILE")"
    configure_pam "gnome" 2>/dev/null
    set +e
    output="$(TARGET_HOME="$uninstall_home" AUTOLOGIN_DROPIN="$uninstall_autologin" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
    status=$?
    set -e
    if [[ $status -eq 0 && "$(sha256sum < "$LOGIN_FILE")" == "$original_hash" && ! -e "${LOGIN_FILE}.lightxdm.bak" ]]; then
      pass "uninstall.sh restores exact PAM bytes (original size=${#pam_original})"
    else
      fail "uninstall.sh PAM byte restoration (status=$status, output=$output)"
    fi
  done
fi

# Case 18c: later PAM edits survive, including near matches and a missing final newline
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh keeps later PAM edits and backup for review (unshare -r unavailable)"
else
  write_stock_login
  original_hash="$(sha256sum < "$LOGIN_FILE")"
  pam_edits='# auth       optional   pam_kwallet5.so
auth       optional   pam_kwallet5.so custom_option
session    optional   pam_kwallet5.so force_run custom_option
auth       optional   pam_gnome_keyring.so custom_option
session    optional   pam_gnome_keyring.so auto_start custom_option
auth required pam_u2f.so'
  edited_hash="$( { cat "$LOGIN_FILE"; printf '%s' "$pam_edits"; } | sha256sum)"
  configure_pam "plasma" 2>/dev/null
  configure_pam "gnome" 2>/dev/null
  printf '%s' "$pam_edits" >>"$LOGIN_FILE"
  set +e
  output="$(TARGET_HOME="$uninstall_home" AUTOLOGIN_DROPIN="$uninstall_autologin" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && "$(sha256sum < "$LOGIN_FILE")" == "$edited_hash" &&
    -f "${LOGIN_FILE}.lightxdm.bak" && "$(sha256sum < "${LOGIN_FILE}.lightxdm.bak")" == "$original_hash" &&
    "$output" == *"backup kept for review"* ]]; then
    pass "uninstall.sh removes only exact PAM lines, keeping later edits and backup for review"
  else
    fail "uninstall.sh PAM edit preservation (status=$status, output=$output)"
  fi
  cp "${LOGIN_FILE}.lightxdm.bak" "$LOGIN_FILE"
  rm -f "${LOGIN_FILE}.lightxdm.bak"
fi

# Case 19: uninstall.sh succeeds cleanly when backup, override, and polkit rule are absent
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh skips missing files cleanly (unshare -r unavailable)"
else
  : >"$STUB_LOG"
  set +e
  output="$(TARGET_HOME="$uninstall_home" AUTOLOGIN_DROPIN="$uninstall_autologin" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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
  output="$(TARGET_HOME="$temp_home" AUTOLOGIN_DROPIN="$uninstall_autologin" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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
  output="$(TARGET_HOME="$temp_home_fresh" AUTOLOGIN_DROPIN="$uninstall_autologin" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && ! -e "$temp_home_fresh/.bash_profile" && ! -e "$temp_home_fresh/.xinitrc" && ! -e "$temp_home_fresh/.gpg-agent-kwallet" ]] &&
    [[ ! -e "$temp_home_fresh/.bash_profile.lightxdm-removed" && ! -e "$temp_home_fresh/.xinitrc.lightxdm-removed" ]]; then
    pass "uninstall.sh removes installed dotfiles when no backup exists"
  else
    fail "uninstall.sh fresh dotfile removal (status=$status, output=$output)"
  fi
fi

# Case 22: gpg-agent dotfiles respect SSH_AUTH_SOCK priority, fall back to GCR, and never export GPG_TTY
cat >"$STUB_BIN/gpg-connect-agent" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
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
  gpg_runtime="$gpg_home/runtime"
  mkdir -p "$gpg_home/.gnupg" "$gpg_runtime/gcr"
  python3 - "$gpg_runtime/gcr/ssh" <<'PY'
import socket
import sys

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as agent:
    agent.bind(sys.argv[1])
PY
  : >"$STUB_LOG"

  gcr_out="$(
    export HOME="$gpg_home"
    export XDG_RUNTIME_DIR="$gpg_runtime"
    export PATH="$STUB_BIN:$PATH"
    unset SSH_AUTH_SOCK GPG_TTY GNUPGHOME
    # shellcheck disable=SC1090
    source "$REPO_ROOT/dotfiles/$gpg_dotfile"
    printf '%s|%s\n' "${SSH_AUTH_SOCK-<unset>}" "${GPG_TTY-<unset>}"
  )"

  without_out="$(
    export HOME="$gpg_home"
    export XDG_RUNTIME_DIR="$gpg_runtime"
    export PATH="$STUB_BIN:$PATH"
    export SSH_AUTH_SOCK="/tmp/sentinel-ssh.sock"
    unset GPG_TTY GNUPGHOME
    # shellcheck disable=SC1090
    source "$REPO_ROOT/dotfiles/$gpg_dotfile"
    printf '%s|%s\n' "$SSH_AUTH_SOCK" "${GPG_TTY-<unset>}"
  )"

  echo "enable-ssh-support" >"$gpg_home/.gnupg/gpg-agent.conf"
  with_out="$(
    export HOME="$gpg_home"
    export XDG_RUNTIME_DIR="$gpg_runtime"
    export PATH="$STUB_BIN:$PATH"
    export SSH_AUTH_SOCK="/tmp/sentinel-ssh.sock"
    unset GPG_TTY GNUPGHOME
    # shellcheck disable=SC1090
    source "$REPO_ROOT/dotfiles/$gpg_dotfile"
    printf '%s|%s\n' "$SSH_AUTH_SOCK" "${GPG_TTY-<unset>}"
  )"

  echo "  enable-ssh-support" >"$gpg_home/.gnupg/gpg-agent.conf"
  indented_out="$(
    export HOME="$gpg_home"
    export XDG_RUNTIME_DIR="$gpg_runtime"
    export PATH="$STUB_BIN:$PATH"
    export SSH_AUTH_SOCK="/tmp/sentinel-ssh.sock"
    unset GPG_TTY GNUPGHOME
    # shellcheck disable=SC1090
    source "$REPO_ROOT/dotfiles/$gpg_dotfile"
    printf '%s|%s\n' "$SSH_AUTH_SOCK" "${GPG_TTY-<unset>}"
  )"

  rm -f "$gpg_home/.gnupg/gpg-agent.conf"
  mkdir -p "$gpg_home/custom-gnupg"
  echo "enable-ssh-support" >"$gpg_home/custom-gnupg/gpg-agent.conf"
  gnupghome_out="$(
    export HOME="$gpg_home"
    export XDG_RUNTIME_DIR="$gpg_runtime"
    export GNUPGHOME="$gpg_home/custom-gnupg"
    export PATH="$STUB_BIN:$PATH"
    export SSH_AUTH_SOCK="/tmp/sentinel-ssh.sock"
    unset GPG_TTY
    # shellcheck disable=SC1090
    source "$REPO_ROOT/dotfiles/$gpg_dotfile"
    printf '%s|%s\n' "$SSH_AUTH_SOCK" "${GPG_TTY-<unset>}"
  )"

  python3 - "$gpg_runtime/ssh-agent.socket" <<'PY'
import socket
import sys

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as agent:
    agent.bind(sys.argv[1])
PY
  both_sockets_out="$(
    export HOME="$gpg_home"
    export XDG_RUNTIME_DIR="$gpg_runtime"
    export PATH="$STUB_BIN:$PATH"
    unset SSH_AUTH_SOCK GPG_TTY GNUPGHOME
    # shellcheck disable=SC1090
    source "$REPO_ROOT/dotfiles/$gpg_dotfile"
    printf '%s|%s\n' "${SSH_AUTH_SOCK-<unset>}" "${GPG_TTY-<unset>}"
  )"

  preset_openssh_out="$(
    export HOME="$gpg_home"
    export XDG_RUNTIME_DIR="$gpg_runtime"
    export PATH="$STUB_BIN:$PATH"
    export SSH_AUTH_SOCK="/tmp/sentinel-ssh.sock"
    unset GPG_TTY GNUPGHOME
    # shellcheck disable=SC1090
    source "$REPO_ROOT/dotfiles/$gpg_dotfile"
    printf '%s|%s\n' "$SSH_AUTH_SOCK" "${GPG_TTY-<unset>}"
  )"

  rm -f "$gpg_runtime/gcr/ssh"
  openssh_out="$(
    export HOME="$gpg_home"
    export XDG_RUNTIME_DIR="$gpg_runtime"
    export PATH="$STUB_BIN:$PATH"
    unset SSH_AUTH_SOCK GPG_TTY GNUPGHOME
    # shellcheck disable=SC1090
    source "$REPO_ROOT/dotfiles/$gpg_dotfile"
    printf '%s|%s\n' "${SSH_AUTH_SOCK-<unset>}" "${GPG_TTY-<unset>}"
  )"

  rm -f "$gpg_runtime/ssh-agent.socket"
  no_socket_out="$(
    export HOME="$gpg_home"
    export XDG_RUNTIME_DIR="$gpg_runtime"
    export PATH="$STUB_BIN:$PATH"
    unset SSH_AUTH_SOCK GPG_TTY GNUPGHOME
    # shellcheck disable=SC1090
    source "$REPO_ROOT/dotfiles/$gpg_dotfile"
    printf '%s|%s\n' "${SSH_AUTH_SOCK-<unset>}" "${GPG_TTY-<unset>}"
  )"

  expected_gpg_out="/run/user/1000/gnupg/S.gpg-agent.ssh|<unset>"
  if [[ "$without_out" == "/tmp/sentinel-ssh.sock|<unset>" &&
    "$with_out" == "$expected_gpg_out" &&
    "$indented_out" == "$expected_gpg_out" &&
    "$gnupghome_out" == "$expected_gpg_out" ]]; then
    pass "$gpg_dotfile respects enable-ssh-support (including indented and custom GNUPGHOME) and does not export GPG_TTY"
  else
    fail "$gpg_dotfile (without=$without_out, with=$with_out, indented=$indented_out, gnupghome=$gnupghome_out)"
  fi

  if [[ "$gcr_out" == "$gpg_runtime/gcr/ssh|<unset>" && "$no_socket_out" == "<unset>|<unset>" ]]; then
    pass "$gpg_dotfile uses the GCR socket when SSH_AUTH_SOCK is unset and leaves it unset without a socket"
  else
    fail "$gpg_dotfile GCR fallback (socket=$gcr_out, no_socket=$no_socket_out)"
  fi

  if [[ "$both_sockets_out" == "$gpg_runtime/ssh-agent.socket|<unset>" && "$openssh_out" == "$gpg_runtime/ssh-agent.socket|<unset>" &&
    "$preset_openssh_out" == "/tmp/sentinel-ssh.sock|<unset>" ]]; then
    pass "$gpg_dotfile prefers the OpenSSH agent socket over the GCR socket when SSH_AUTH_SOCK is unset"
  else
    fail "$gpg_dotfile OpenSSH fallback (both=$both_sockets_out, openssh=$openssh_out, preset=$preset_openssh_out)"
  fi

  # Each of the nine configurations must start the agent, then refresh its tty.
  expected_gpg_calls=$'/bye\nupdatestartuptty /bye'
  expected_gpg_log="$(printf '%s\n' "$expected_gpg_calls" "$expected_gpg_calls" "$expected_gpg_calls" "$expected_gpg_calls" "$expected_gpg_calls" "$expected_gpg_calls" "$expected_gpg_calls" "$expected_gpg_calls" "$expected_gpg_calls")"
  gpg_log="$(cat "$STUB_LOG")"
  if [[ "$gpg_log" == "$expected_gpg_log" ]]; then
    pass "$gpg_dotfile starts the agent and refreshes its tty in order for all configurations"
  else
    fail "$gpg_dotfile gpg-connect-agent calls (log=$gpg_log)"
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
if [[ $status -eq 1 && "$output" == *"sudo is required but not installed. Please install sudo and re-run."* &&
  "$output" == *"su -c 'pacman -S sudo'"* && "$output" != *"command not found"* && -z "$log_content" &&
  "$output" != *"Install stopped during"* ]]; then
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
  if [[ $status -eq 1 && "$output" == *"Do not run this script as root. Please run as a regular user."* && -z "$log_content" &&
    "$output" != *"Install stopped during"* ]]; then
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
if [[ $status -eq 1 && "$output" == *"ERROR: User 'plainuser' is not in the 'wheel' group."* &&
  "$output" == *"su -c 'usermod -aG wheel plainuser'"* && "$output" != *"sudo usermod"* && -z "$log_content" &&
  "$output" != *"Install stopped during"* ]]; then
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
for padded in "05:cinnamon" "06:i3"; do
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

# Case 30: uninstall.sh preserves restored originals on second run, keeps edited/foreign dotfiles, and never overwrites .lightxdm-removed
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh preserves restored/edited dotfiles and existing .lightxdm-removed (unshare -r unavailable)"
else
  twice_home="$TMP_DIR/home_uninstall_twice"
  mkdir -p "$twice_home"
  echo "# user original bash_profile" >"$twice_home/.bash_profile"
  echo "# user original xinitrc" >"$twice_home/.xinitrc"
  (
    export HOME="$twice_home"
    export USER="${USER:-testuser}"
    copy_dotfiles "plasma" 2>/dev/null
  )
  set +e
  output1="$(TARGET_HOME="$twice_home" AUTOLOGIN_DROPIN="$uninstall_autologin" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status1=$?
  output2="$(TARGET_HOME="$twice_home" AUTOLOGIN_DROPIN="$uninstall_autologin" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status2=$?
  set -e
  twice_bash=""
  twice_xinit=""
  if [[ -f "$twice_home/.bash_profile" ]]; then
    twice_bash="$(cat "$twice_home/.bash_profile")"
  fi
  if [[ -f "$twice_home/.xinitrc" ]]; then
    twice_xinit="$(cat "$twice_home/.xinitrc")"
  fi
  if [[ $status1 -eq 0 && $status2 -eq 0 ]] &&
    [[ "$twice_bash" == "# user original bash_profile" && "$twice_xinit" == "# user original xinitrc" ]] &&
    [[ ! -e "$twice_home/.bash_profile.lightxdm-removed" && ! -e "$twice_home/.xinitrc.lightxdm-removed" ]] &&
    [[ "$output2" == *"Keeping $twice_home/.bash_profile"* && "$output2" == *"Keeping $twice_home/.xinitrc"* ]]; then
    pass "uninstall.sh leaves restored .bash_profile and .xinitrc in place on second run"
  else
    fail "uninstall.sh second run (s1=$status1, s2=$status2, bash=$twice_bash, xinit=$twice_xinit, out1=$output1, out2=$output2)"
  fi

  edited_home="$TMP_DIR/home_edited_dotfiles"
  mkdir -p "$edited_home"
  cp "$REPO_ROOT/dotfiles/.bash_profile" "$edited_home/.bash_profile"
  echo "# user customization" >>"$edited_home/.bash_profile"
  echo "exec openbox-session" >"$edited_home/.xinitrc"
  expected_edited_bash="$(cat "$edited_home/.bash_profile")"
  set +e
  output="$(TARGET_HOME="$edited_home" AUTOLOGIN_DROPIN="$uninstall_autologin" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  actual_edited_bash=""
  actual_foreign_xinit=""
  if [[ -f "$edited_home/.bash_profile" ]]; then
    actual_edited_bash="$(cat "$edited_home/.bash_profile")"
  fi
  if [[ -f "$edited_home/.xinitrc" ]]; then
    actual_foreign_xinit="$(cat "$edited_home/.xinitrc")"
  fi
  if [[ $status -eq 0 && "$actual_edited_bash" == "$expected_edited_bash" && "$actual_foreign_xinit" == "exec openbox-session" ]] &&
    [[ ! -e "$edited_home/.bash_profile.lightxdm-removed" && ! -e "$edited_home/.xinitrc.lightxdm-removed" ]] &&
    [[ "$output" == *"Keeping $edited_home/.bash_profile"* && "$output" == *"Keeping $edited_home/.xinitrc"* ]]; then
    pass "uninstall.sh never moves user-edited or foreign dotfiles"
  else
    fail "uninstall.sh edited/foreign dotfiles (status=$status, output=$output)"
  fi

  removed_home="$TMP_DIR/home_existing_removed"
  mkdir -p "$removed_home"
  echo "# previous removed bash_profile" >"$removed_home/.bash_profile.lightxdm-removed"
  echo "# previous removed xinitrc" >"$removed_home/.xinitrc.lightxdm-removed"
  (
    export HOME="$removed_home"
    export USER="${USER:-testuser}"
    copy_dotfiles "xfce" 2>/dev/null
  )
  set +e
  output="$(TARGET_HOME="$removed_home" AUTOLOGIN_DROPIN="$uninstall_autologin" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  prev_bash=""
  prev_xinit=""
  if [[ -f "$removed_home/.bash_profile.lightxdm-removed" ]]; then
    prev_bash="$(cat "$removed_home/.bash_profile.lightxdm-removed")"
  fi
  if [[ -f "$removed_home/.xinitrc.lightxdm-removed" ]]; then
    prev_xinit="$(cat "$removed_home/.xinitrc.lightxdm-removed")"
  fi
  if [[ $status -eq 0 && ! -e "$removed_home/.bash_profile" && ! -e "$removed_home/.xinitrc" && "$prev_bash" == "# previous removed bash_profile" && "$prev_xinit" == "# previous removed xinitrc" ]]; then
    pass "uninstall.sh never overwrites existing .lightxdm-removed files"
  else
    fail "uninstall.sh existing .lightxdm-removed (status=$status, bash=$prev_bash, xinit=$prev_xinit, output=$output)"
  fi
fi

# Case 31: install.sh and uninstall.sh handle -h/--help (exit 0) and unknown args (exit 1) with no side effects
help_home="$TMP_DIR/help_home"
mkdir -p "$help_home"
echo "# untouched bash_profile" >"$help_home/.bash_profile"
echo "# backup bash_profile" >"$help_home/.bash_profile.lightxdm.bak"
echo "# untouched login" >"$LOGIN_FILE"
echo "# backup login" >"${LOGIN_FILE}.lightxdm.bak"
help_autologin="$TMP_DIR/help_autologin.conf"
echo "[Service]" >"$help_autologin"
help_override="$TMP_DIR/help_override.conf"
echo "[Service]" >"$help_override"
help_polkit="$TMP_DIR/help_polkit.rules"
echo "// rule" >"$help_polkit"

for flag in --help -h; do
  : >"$STUB_LOG"
  set +e
  output="$(HOME="$help_home" bash "$REPO_ROOT/install.sh" "$flag" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  help_options_ok=1
  for help_word in --de --list-packages --no-packages --no-keyring --no-polkit-rule /etc/pam.d/login Polkit "display managers" uninstall.sh; do
    [[ "$output" == *"$help_word"*"$help_word"* || ( "$help_word" != --* && "$output" == *"$help_word"* ) ]] || help_options_ok=0
  done
  if [[ $status -eq 0 && "$output" == *"Usage:"* && $help_options_ok -eq 1 && -z "$log_content" &&
    "$output" != *"Install stopped during"* && "$output" != *"rerunning install.sh is safe"* ]] &&
    [[ "$(cat "$help_home/.bash_profile")" == "# untouched bash_profile" ]] &&
    [[ "$(cat "$LOGIN_FILE")" == "# untouched login" ]]; then
    pass "install.sh $flag prints usage and the effect of every option, exits 0, and changes nothing"
  else
    fail "install.sh $flag (status=$status, output=$output, log=$log_content)"
  fi
done

: >"$STUB_LOG"
set +e
output="$(HOME="$help_home" bash "$REPO_ROOT/install.sh" --unknown 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 1 && "$output" == *"Usage:"* && -z "$log_content" ]] &&
  [[ "$(cat "$help_home/.bash_profile")" == "# untouched bash_profile" ]] &&
  [[ "$(cat "$LOGIN_FILE")" == "# untouched login" ]]; then
  pass "install.sh rejects unknown argument with usage and exits 1"
else
  fail "install.sh --unknown (status=$status, output=$output, log=$log_content)"
fi

uninstall_runner=(bash "$REPO_ROOT/uninstall.sh")
if [[ $can_unshare -eq 1 ]]; then
  uninstall_runner=(unshare -r bash "$REPO_ROOT/uninstall.sh")
fi

for flag in --help -h; do
  : >"$STUB_LOG"
  set +e
  output="$(TARGET_HOME="$help_home" AUTOLOGIN_DROPIN="$help_autologin" OVERRIDE_FILE="$help_override" POLKIT_RULE="$help_polkit" "${uninstall_runner[@]}" "$flag" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -eq 0 && "$output" == *"Usage:"* && -z "$log_content" ]] &&
    [[ -f "${LOGIN_FILE}.lightxdm.bak" && "$(cat "$LOGIN_FILE")" == "# untouched login" ]] &&
    [[ -f "$help_autologin" && -f "$help_override" && -f "$help_polkit" ]] &&
    [[ -f "$help_home/.bash_profile.lightxdm.bak" && "$(cat "$help_home/.bash_profile")" == "# untouched bash_profile" ]]; then
    pass "uninstall.sh $flag prints usage, exits 0, and changes nothing"
  else
    fail "uninstall.sh $flag (status=$status, output=$output, log=$log_content)"
  fi
done

: >"$STUB_LOG"
set +e
output="$(TARGET_HOME="$help_home" AUTOLOGIN_DROPIN="$help_autologin" OVERRIDE_FILE="$help_override" POLKIT_RULE="$help_polkit" "${uninstall_runner[@]}" --unknown 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 1 && "$output" == *"Usage:"* && -z "$log_content" ]] &&
  [[ -f "${LOGIN_FILE}.lightxdm.bak" && "$(cat "$LOGIN_FILE")" == "# untouched login" ]] &&
  [[ -f "$help_autologin" && -f "$help_override" && -f "$help_polkit" ]] &&
  [[ -f "$help_home/.bash_profile.lightxdm.bak" && "$(cat "$help_home/.bash_profile")" == "# untouched bash_profile" ]]; then
  pass "uninstall.sh rejects unknown argument with usage and exits 1"
else
  fail "uninstall.sh --unknown (status=$status, output=$output, log=$log_content)"
fi

# Case 32: enable-autologin.sh warns when LOGIN_FILE has active keyring PAM lines and stays quiet otherwise
if [[ $can_unshare -eq 0 ]]; then
  skip "enable-autologin.sh keyring PAM warning check (unshare -r unavailable)"
else
  rm -rf "$autologin_dir"
  rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
  write_stock_login
  echo "# auth       optional   pam_kwallet5.so" >>"$LOGIN_FILE"
  echo "# session    optional   pam_gnome_keyring.so auto_start" >>"$LOGIN_FILE"
  set +e
  out_no_keyring="$(OVERRIDE_DIR="$autologin_dir" unshare -r bash "$REPO_ROOT/enable-autologin.sh" "$real_test_user" 2>&1)"
  status_no_keyring=$?
  set -e

  rm -rf "$autologin_dir"
  rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
  write_stock_login
  configure_pam "plasma" 2>/dev/null
  set +e
  out_kwallet="$(OVERRIDE_DIR="$autologin_dir" unshare -r bash "$REPO_ROOT/enable-autologin.sh" "$real_test_user" 2>&1)"
  status_kwallet=$?
  set -e

  rm -rf "$autologin_dir"
  rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
  write_stock_login
  configure_pam "gnome" 2>/dev/null
  set +e
  out_gkr="$(OVERRIDE_DIR="$autologin_dir" unshare -r bash "$REPO_ROOT/enable-autologin.sh" "$real_test_user" 2>&1)"
  status_gkr=$?
  set -e

  if [[ $status_no_keyring -eq 0 && "$out_no_keyring" != *"Warning:"* && "$out_no_keyring" != *"will not unlock"* ]] &&
    [[ $status_kwallet -eq 0 && "$out_kwallet" == *"Warning:"* && "$out_kwallet" == *"will not unlock automatically with autologin"* && "$out_kwallet" == *"empty"* ]] &&
    [[ $status_gkr -eq 0 && "$out_gkr" == *"Warning:"* && "$out_gkr" == *"will not unlock automatically with autologin"* && "$out_gkr" == *"empty"* ]]; then
    pass "enable-autologin.sh warns only when active PAM keyring lines are present"
  else
    fail "enable-autologin.sh keyring warning (no_kr=$status_no_keyring:$out_no_keyring | kw=$status_kwallet:$out_kwallet | gkr=$status_gkr:$out_gkr)"
  fi
fi

# Case 33: uninstall.sh removes unmodified lightXDM dotfiles when cmp is absent from PATH
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh removes unmodified dotfiles without cmp in PATH (unshare -r unavailable)"
else
  no_cmp_bin="$TMP_DIR/no_cmp_bin"
  mkdir -p "$no_cmp_bin"
  for tool in bash dirname cp rm mv sha256sum sed tail cat; do
    ln -sf "$(command -v "$tool")" "$no_cmp_bin/$tool"
  done
  ln -sf "$STUB_BIN/systemctl" "$no_cmp_bin/systemctl"

  no_cmp_home="$TMP_DIR/home_no_cmp"
  mkdir -p "$no_cmp_home"
  (
    export HOME="$no_cmp_home"
    export USER="${USER:-testuser}"
    copy_dotfiles "plasma" 2>/dev/null
  )
  unshare_bin="$(command -v unshare)"
  set +e
  output="$(PATH="$no_cmp_bin" TARGET_HOME="$no_cmp_home" AUTOLOGIN_DROPIN="$uninstall_autologin" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" "$unshare_bin" -r "$no_cmp_bin/bash" "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && ! -e "$no_cmp_home/.bash_profile" && ! -e "$no_cmp_home/.xinitrc" ]] &&
    [[ ! -e "$no_cmp_home/.bash_profile.lightxdm-removed" && ! -e "$no_cmp_home/.xinitrc.lightxdm-removed" ]] &&
    [[ "$output" != *"command not found"* ]]; then
    pass "uninstall.sh removes unmodified dotfiles without cmp in PATH"
  else
    fail "uninstall.sh without cmp (status=$status, output=$output)"
  fi
fi

# Case 34: uninstall.sh refuses early when no target user can be resolved, leaving PAM, override, and Polkit rule untouched, and succeeds via SUDO_USER
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh refuses when target user is unknown and leaves PAM, override, and rule untouched (unshare -r unavailable)"
else
  refuse_dir="$TMP_DIR/refuse_uninstall"
  mkdir -p "$refuse_dir"
  refuse_autologin="$refuse_dir/lightxdm-autologin.conf"
  refuse_override="$refuse_dir/override.conf"
  refuse_polkit="$refuse_dir/49-nopasswd.rules"
  refuse_legacy_content="[Service]"$'\n'"ExecStart="$'\n'"ExecStart=-/usr/bin/agetty --autologin stubuser --noclear %I \$TERM"
  echo "$refuse_legacy_content" >"$refuse_autologin"
  echo "$refuse_legacy_content" >"$refuse_override"
  echo "// rule" >"$refuse_polkit"

  rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
  write_stock_login
  stock_login="$(cat "$LOGIN_FILE")"
  configure_pam "plasma" 2>/dev/null
  configured_login="$(cat "$LOGIN_FILE")"

  : >"$STUB_LOG"
  set +e
  output_unset="$(
    unset TARGET_HOME SUDO_USER
    AUTOLOGIN_DROPIN="$refuse_autologin" OVERRIDE_FILE="$refuse_override" POLKIT_RULE="$refuse_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1
  )"
  status_unset=$?
  output_bad_user="$(
    unset TARGET_HOME
    SUDO_USER="nonexistent_lightxdm_user_99999" AUTOLOGIN_DROPIN="$refuse_autologin" OVERRIDE_FILE="$refuse_override" POLKIT_RULE="$refuse_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1
  )"
  status_bad_user=$?
  output_dash_user="$(
    unset TARGET_HOME
    SUDO_USER="-V" AUTOLOGIN_DROPIN="$refuse_autologin" OVERRIDE_FILE="$refuse_override" POLKIT_RULE="$refuse_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1
  )"
  status_dash_user=$?
  set -e
  log_content="$(cat "$STUB_LOG")"

  if [[ $status_unset -eq 1 && "$output_unset" == *"sudo"* && "$output_unset" == *"TARGET_HOME"* ]] &&
    [[ $status_bad_user -eq 1 && "$output_bad_user" == *"sudo"* && "$output_bad_user" == *"TARGET_HOME"* ]] &&
    [[ $status_dash_user -eq 1 && "$output_dash_user" == *"sudo"* && "$output_dash_user" == *"TARGET_HOME"* ]] &&
    [[ -f "${LOGIN_FILE}.lightxdm.bak" && "$(cat "${LOGIN_FILE}.lightxdm.bak")" == "$stock_login" ]] &&
    [[ "$(cat "$LOGIN_FILE")" == "$configured_login" ]] &&
    [[ -f "$refuse_autologin" && "$(cat "$refuse_autologin")" == "$refuse_legacy_content" ]] &&
    [[ -f "$refuse_override" && "$(cat "$refuse_override")" == "$refuse_legacy_content" ]] &&
    [[ -f "$refuse_polkit" && "$(cat "$refuse_polkit")" == "// rule" ]] &&
    [[ -z "$log_content" ]]; then
    pass "uninstall.sh exits 1 without changes when target user cannot be resolved"
  else
    fail "uninstall.sh early refusal (s_unset=$status_unset:$output_unset | s_bad=$status_bad_user:$output_bad_user | s_dash=$status_dash_user:$output_dash_user | log=$log_content)"
  fi

  sudo_user_home="$refuse_dir/sudo_home"
  mkdir -p "$sudo_user_home"
  echo "# original bash_profile" >"$sudo_user_home/.bash_profile"
  (
    export HOME="$sudo_user_home"
    export USER="stubuser"
    copy_dotfiles "plasma" 2>/dev/null
  )
  getent_stub_dir="$refuse_dir/bin"
  mkdir -p "$getent_stub_dir"
  cat >"$getent_stub_dir/getent" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "passwd" && ( "\${2:-}" == "stubuser" || "\${2:-}" == "root" ) ]]; then
  uid=1000
  [[ "\$2" != "root" ]] || uid=0
  echo "\$2:x:\$uid:1000::${sudo_user_home}:/bin/bash"
  exit 0
fi
exit 2
EOF
  chmod +x "$getent_stub_dir/getent"

  refuse_files=("$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak" "$refuse_autologin" "$refuse_override" "$refuse_polkit"
    "$sudo_user_home/.bash_profile" "$sudo_user_home/.bash_profile.lightxdm.bak"
    "$sudo_user_home/.xinitrc" "$sudo_user_home/.gpg-agent-kwallet")
  before_refusal="$(sha256sum "${refuse_files[@]}")"
  for bad_target in missing_home root; do
    : >"$STUB_LOG"
    expected_message="Target home directory does not exist"
    set +e
    if [[ "$bad_target" == "missing_home" ]]; then
      output="$(TARGET_HOME="$refuse_dir/missing_home" AUTOLOGIN_DROPIN="$refuse_autologin" OVERRIDE_FILE="$refuse_override" POLKIT_RULE="$refuse_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
      status=$?
    else
      expected_message="Refusing to uninstall for root"
      output="$(
        unset TARGET_HOME
        PATH="$getent_stub_dir:$PATH" SUDO_USER=root AUTOLOGIN_DROPIN="$refuse_autologin" OVERRIDE_FILE="$refuse_override" POLKIT_RULE="$refuse_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1
      )"
      status=$?
    fi
    set -e
    after_refusal="$(sha256sum "${refuse_files[@]}" 2>/dev/null || true)"
    log_content="$(cat "$STUB_LOG")"
    if [[ $status -eq 1 && "$output" == *"$expected_message"* && "$after_refusal" == "$before_refusal" ]] &&
      [[ ! -e "$refuse_dir/missing_home" && -z "$log_content" ]]; then
      pass "uninstall.sh refuses $bad_target without changing any files"
    else
      fail "uninstall.sh refuses $bad_target (status=$status, output=$output, log=$log_content)"
    fi
  done

  : >"$STUB_LOG"
  set +e
  output_sudo="$(
    unset TARGET_HOME
    PATH="$getent_stub_dir:$PATH" SUDO_USER="stubuser" AUTOLOGIN_DROPIN="$refuse_autologin" OVERRIDE_FILE="$refuse_override" POLKIT_RULE="$refuse_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1
  )"
  status_sudo=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status_sudo -eq 0 && "$(cat "$LOGIN_FILE")" == "$stock_login" && ! -e "${LOGIN_FILE}.lightxdm.bak" ]] &&
    [[ ! -e "$refuse_autologin" && ! -e "$refuse_override" && "$log_content" == *"systemctl daemon-reload"* ]] &&
    [[ -f "$refuse_polkit" && "$(cat "$refuse_polkit")" == "// rule" && "$output_sudo" == *"Keeping $refuse_polkit"* ]] &&
    [[ "$(cat "$sudo_user_home/.bash_profile")" == "# original bash_profile" && ! -e "$sudo_user_home/.bash_profile.lightxdm.bak" ]] &&
    [[ ! -e "$sudo_user_home/.xinitrc" && ! -e "$sudo_user_home/.xinitrc.lightxdm-removed" && ! -e "$sudo_user_home/.gpg-agent-kwallet" ]]; then
    pass "uninstall.sh resolves TARGET_HOME from SUDO_USER and completes full uninstall"
  else
    fail "uninstall.sh SUDO_USER resolution (status=$status_sudo, output=$output_sudo, log=$log_content)"
  fi
fi

# Case 35: install_packages for gnome and lxde installs minimal session packages without gdm, lxdm, or bare group names
: >"$STUB_LOG"
set +e
out_gnome="$(install_packages "gnome" 2>&1)"
status_gnome=$?
out_lxde="$(install_packages "lxde" 2>&1)"
status_lxde=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status_gnome -eq 0 && $status_lxde -eq 0 ]] &&
  [[ "$log_content" == *"gnome-shell gnome-session gnome-control-center nautilus gnome-terminal gnome-keyring polkit-gnome"* ]] &&
  [[ "$log_content" == *"lxde-common lxsession lxpanel openbox pcmanfm lxterminal gnome-keyring polkit-gnome"* ]] &&
  ! grep -Eq '(^|[[:space:]])(gdm|lxdm|gnome|lxde)([[:space:]]|$)' "$STUB_LOG"; then
  pass "install_packages for gnome and lxde avoids display managers and bare group names"
else
  fail "install_packages gnome/lxde minimal packages (s_gnome=$status_gnome:$out_gnome | s_lxde=$status_lxde:$out_lxde | log=$log_content)"
fi

# Case 36: symlinked and dangling-symlink dotfiles survive copy_dotfiles and uninstall.sh as the same links
symlink_home="$TMP_DIR/home_symlink_dotfiles"
mkdir -p "$symlink_home/dotfiles"
echo "# stow managed bash_profile" >"$symlink_home/dotfiles/bash_profile"
ln -s "$symlink_home/dotfiles/bash_profile" "$symlink_home/.bash_profile"
ln -s "$symlink_home/dotfiles/missing_xinitrc" "$symlink_home/.xinitrc"
(
  export HOME="$symlink_home"
  export USER="${USER:-testuser}"
  copy_dotfiles "plasma" 2>/dev/null
  copy_dotfiles "gnome" 2>/dev/null
)
if [[ -L "$symlink_home/.bash_profile.lightxdm.bak" && "$(readlink "$symlink_home/.bash_profile.lightxdm.bak")" == "$symlink_home/dotfiles/bash_profile" ]] &&
  [[ -L "$symlink_home/.xinitrc.lightxdm.bak" && "$(readlink "$symlink_home/.xinitrc.lightxdm.bak")" == "$symlink_home/dotfiles/missing_xinitrc" ]] &&
  [[ -f "$symlink_home/.bash_profile" && ! -L "$symlink_home/.bash_profile" ]] &&
  [[ -f "$symlink_home/.xinitrc" && ! -L "$symlink_home/.xinitrc" ]] &&
  [[ "$(cat "$symlink_home/dotfiles/bash_profile")" == "# stow managed bash_profile" ]] &&
  [[ ! -e "$symlink_home/dotfiles/missing_xinitrc" ]]; then
  pass "copy_dotfiles backs up symlinked and dangling-symlink dotfiles as links without clobbering targets"
else
  fail "copy_dotfiles symlink backup"
fi

if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh restores symlinked and dangling-symlink dotfiles (unshare -r unavailable)"
else
  set +e
  output="$(TARGET_HOME="$symlink_home" AUTOLOGIN_DROPIN="$uninstall_autologin" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 ]] &&
    [[ -L "$symlink_home/.bash_profile" && "$(readlink "$symlink_home/.bash_profile")" == "$symlink_home/dotfiles/bash_profile" ]] &&
    [[ "$(cat "$symlink_home/.bash_profile")" == "# stow managed bash_profile" ]] &&
    [[ -L "$symlink_home/.xinitrc" && ! -e "$symlink_home/.xinitrc" && "$(readlink "$symlink_home/.xinitrc")" == "$symlink_home/dotfiles/missing_xinitrc" ]] &&
    [[ ! -e "$symlink_home/.bash_profile.lightxdm.bak" && ! -L "$symlink_home/.bash_profile.lightxdm.bak" ]] &&
    [[ ! -e "$symlink_home/.xinitrc.lightxdm.bak" && ! -L "$symlink_home/.xinitrc.lightxdm.bak" ]]; then
    pass "uninstall.sh restores symlinked and dangling-symlink dotfiles with their original targets"
  else
    fail "uninstall.sh symlink dotfile restore (status=$status, output=$output)"
  fi
fi

# Case 37: repeated install/uninstall cycles on an empty home leave no lightXDM dotfiles behind
repeat_install_home="$TMP_DIR/home_repeat_install"
mkdir -p "$repeat_install_home"
(
  export HOME="$repeat_install_home"
  export USER="${USER:-testuser}"
  copy_dotfiles "plasma" 2>/dev/null
  copy_dotfiles "plasma" 2>/dev/null
  copy_dotfiles "gnome" 2>/dev/null
)
if [[ ! -e "$repeat_install_home/.bash_profile.lightxdm.bak" && ! -L "$repeat_install_home/.bash_profile.lightxdm.bak" ]] &&
  [[ ! -e "$repeat_install_home/.xinitrc.lightxdm.bak" && ! -L "$repeat_install_home/.xinitrc.lightxdm.bak" ]]; then
  pass "copy_dotfiles skips backing up unmodified lightXDM templates on repeated installs"
else
  fail "copy_dotfiles backed up its own template on repeated installs"
fi

if [[ $can_unshare -eq 0 ]]; then
  skip "repeated install/uninstall cycles leave no ~/.bash_profile or ~/.xinitrc (unshare -r unavailable)"
else
  set +e
  output="$(TARGET_HOME="$repeat_install_home" AUTOLOGIN_DROPIN="$uninstall_autologin" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 ]] &&
    [[ ! -e "$repeat_install_home/.bash_profile" && ! -L "$repeat_install_home/.bash_profile" ]] &&
    [[ ! -e "$repeat_install_home/.xinitrc" && ! -L "$repeat_install_home/.xinitrc" ]] &&
    [[ ! -e "$repeat_install_home/.bash_profile.lightxdm.bak" && ! -e "$repeat_install_home/.xinitrc.lightxdm.bak" ]] &&
    [[ ! -e "$repeat_install_home/.bash_profile.lightxdm-removed" && ! -e "$repeat_install_home/.xinitrc.lightxdm-removed" ]] &&
    [[ ! -e "$repeat_install_home/.gpg-agent-kwallet" && ! -e "$repeat_install_home/.gpg-agent-gnome" ]]; then
    pass "install twice then uninstall on empty home leaves no ~/.bash_profile or ~/.xinitrc"
  else
    fail "install twice then uninstall (status=$status, output=$output)"
  fi

  cycle_home="$TMP_DIR/home_install_uninstall_twice"
  mkdir -p "$cycle_home"
  (
    export HOME="$cycle_home"
    export USER="${USER:-testuser}"
    copy_dotfiles "plasma" 2>/dev/null
  )
  set +e
  out_u1="$(TARGET_HOME="$cycle_home" AUTOLOGIN_DROPIN="$uninstall_autologin" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status_u1=$?
  set -e
  (
    export HOME="$cycle_home"
    export USER="${USER:-testuser}"
    copy_dotfiles "plasma" 2>/dev/null
  )
  set +e
  out_u2="$(TARGET_HOME="$cycle_home" AUTOLOGIN_DROPIN="$uninstall_autologin" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status_u2=$?
  set -e
  if [[ $status_u1 -eq 0 && $status_u2 -eq 0 ]] &&
    [[ ! -e "$cycle_home/.bash_profile" && ! -L "$cycle_home/.bash_profile" ]] &&
    [[ ! -e "$cycle_home/.xinitrc" && ! -L "$cycle_home/.xinitrc" ]] &&
    [[ ! -e "$cycle_home/.bash_profile.lightxdm.bak" && ! -e "$cycle_home/.xinitrc.lightxdm.bak" ]] &&
    [[ ! -e "$cycle_home/.bash_profile.lightxdm-removed" && ! -e "$cycle_home/.xinitrc.lightxdm-removed" ]] &&
    [[ ! -e "$cycle_home/.gpg-agent-kwallet" && ! -e "$cycle_home/.gpg-agent-gnome" ]]; then
    pass "install, uninstall, install, uninstall on empty home leaves no ~/.bash_profile or ~/.xinitrc"
  else
    fail "install/uninstall twice cycle (s1=$status_u1:$out_u1 | s2=$status_u2:$out_u2)"
  fi
fi

# select accepts " 1" and "+1" as item 1
for spaced in " 1" "+1"; do
  set +e
  output="$(prompt_de_selection <<<"$spaced" 2>/dev/null)"
  status=$?
  set -e
  if [[ $status -eq 0 && "$output" == "xfce" ]]; then
    pass "prompt_de_selection maps '$spaced' to xfce"
  else
    fail "prompt_de_selection '$spaced' (status=$status, output=$output)"
  fi
done

# Case 38: configure_pam appends only the missing line when only auth or only session is present
rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
write_stock_login
echo "auth       optional   pam_gnome_keyring.so" >>"$LOGIN_FILE"
auth_only_before="$(cat "$LOGIN_FILE")"
configure_pam "gnome" 2>/dev/null
auth_only_after="$(cat "$LOGIN_FILE")"
if [[ -f "${LOGIN_FILE}.lightxdm.bak" && "$(cat "${LOGIN_FILE}.lightxdm.bak")" == "$auth_only_before" ]] &&
  [[ "$(grep -Ec '^[[:space:]]*-?auth[[:space:]].*pam_gnome_keyring\.so' "$LOGIN_FILE")" -eq 1 ]] &&
  grep -Eq '^session[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so auto_start$' "$LOGIN_FILE" &&
  [[ "$(grep -c 'pam_gnome_keyring\.so' "$LOGIN_FILE")" -eq 2 ]]; then
  pass "configure_pam adds only session line when auth line already exists"
else
  fail "configure_pam auth-only file (content=$auth_only_after)"
fi

rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
write_stock_login
echo "session    optional   pam_kwallet5.so force_run" >>"$LOGIN_FILE"
session_only_before="$(cat "$LOGIN_FILE")"
configure_pam "plasma" 2>/dev/null
session_only_after="$(cat "$LOGIN_FILE")"
if [[ -f "${LOGIN_FILE}.lightxdm.bak" && "$(cat "${LOGIN_FILE}.lightxdm.bak")" == "$session_only_before" ]] &&
  grep -Eq '^auth[[:space:]]+optional[[:space:]]+pam_kwallet5\.so$' "$LOGIN_FILE" &&
  [[ "$(grep -Ec '^[[:space:]]*-?session[[:space:]].*pam_kwallet5\.so' "$LOGIN_FILE")" -eq 1 ]] &&
  [[ "$(grep -c 'pam_kwallet5\.so' "$LOGIN_FILE")" -eq 2 ]]; then
  pass "configure_pam adds only auth line when session line already exists"
else
  fail "configure_pam session-only file (content=$session_only_after)"
fi

# Case 39: configure_pam treats -auth and -session lines as configured and adds nothing
rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
write_stock_login
cat >>"$LOGIN_FILE" <<'EOF'
-auth      optional     pam_gnome_keyring.so
-session   optional     pam_gnome_keyring.so auto_start
EOF
dash_before="$(cat "$LOGIN_FILE")"
configure_pam "gnome" 2>/dev/null
dash_after="$(cat "$LOGIN_FILE")"
if [[ "$dash_after" == "$dash_before" && ! -e "${LOGIN_FILE}.lightxdm.bak" ]]; then
  pass "configure_pam adds nothing when -auth and -session lines already exist"
else
  fail "configure_pam -auth/-session file (content=$dash_after)"
fi

# Case 40: configure_pam adds both lines when module is only mentioned in trailing # comments
rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
cat >"$LOGIN_FILE" <<'EOF'
#%PAM-1.0

auth       requisite    pam_nologin.so
auth       include      system-local-login # pam_gnome_keyring.so
account    include      system-local-login
session    include      system-local-login # pam_gnome_keyring.so auto_start
password   include      system-local-login
EOF
configure_pam "gnome" 2>/dev/null
trailing_comment_after="$(cat "$LOGIN_FILE")"
if grep -Eq '^auth[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so$' "$LOGIN_FILE" &&
  grep -Eq '^session[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so auto_start$' "$LOGIN_FILE"; then
  pass "configure_pam adds both lines when module appears only in trailing # comments"
else
  fail "configure_pam trailing # comment mention (content=$trailing_comment_after)"
fi

# Case 41: record enabled DMs from the known list and display-manager.service
dm_stub_dir="$TMP_DIR/dm_bin"
mkdir -p "$dm_stub_dir"
: >"$TMP_DIR/greetd.service"
ln -s "$TMP_DIR/greetd.service" "$DISPLAY_MANAGER_LINK"
cat >"$dm_stub_dir/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$STUB_LOG"
case "$1" in
  list-unit-files)
    if [[ "${STUB_DM_ALIAS_ONLY:-0}" != 1 ]]; then
      printf '%s\n' "sddm.service enabled" "lightdm.service disabled" "gdm.service indirect" "lxdm.service static" "greetd.service enabled"
    fi
    ;;
  is-enabled)
    case "${3:-$2}" in
      greetd.service | sddm.service) echo enabled ;;
      gdm.service | ly@.service) echo indirect ;;
      lxdm.service | static-dm.service) echo static ;;
      *) echo disabled; exit 1 ;;
    esac
    ;;
  disable) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$dm_stub_dir/systemctl"
: >"$STUB_LOG"
set +e
output="$(
  export PATH="$dm_stub_dir:$PATH"
  disable_display_managers 2>&1
)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 0 && -f "$DM_STATE_FILE" ]] &&
  [[ "$(cat "$DM_STATE_FILE")" == $'sddm.service\ngreetd.service' ]] &&
  grep -Fxq 'systemctl disable greetd.service' "$STUB_LOG" &&
  grep -Fxq 'systemctl disable sddm.service' "$STUB_LOG" &&
  ! grep -Fxq 'systemctl disable lightdm.service' "$STUB_LOG" &&
  ! grep -Fxq 'systemctl disable gdm.service' "$STUB_LOG" &&
  ! grep -Fxq 'systemctl disable lxdm.service' "$STUB_LOG" &&
  [[ "$output" == *"Disabled display manager(s): sddm greetd"* ]]; then
  pass "disable_display_managers records only disabled sddm and greetd units"
else
  fail "disable_display_managers alias (status=$status, log=$log_content, output=$output)"
fi

# Indirect and static units behind display-manager.service are also skipped.
for dm_unit in ly@.service static-dm.service; do
  : >"$TMP_DIR/$dm_unit"
  ln -sf "$TMP_DIR/$dm_unit" "$DISPLAY_MANAGER_LINK"
  : >"$STUB_LOG"
  set +e
  output="$(PATH="$dm_stub_dir:$PATH" disable_display_managers 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && -f "$DM_STATE_FILE" ]] &&
    [[ "$(cat "$DM_STATE_FILE")" == $'sddm.service\ngreetd.service' ]] &&
    ! grep -Fxq "systemctl disable $dm_unit" "$STUB_LOG"; then
    pass "disable_display_managers skips $dm_unit behind display-manager.service"
  else
    fail "disable_display_managers non-enabled alias (unit=$dm_unit, status=$status, output=$output)"
  fi
done

# Case 41a: rerunning install and finding sddm through both paths adds no duplicates
ln -sf "$TMP_DIR/sddm.service" "$DISPLAY_MANAGER_LINK"
: >"$TMP_DIR/sddm.service"
: >"$STUB_LOG"
set +e
output="$(PATH="$dm_stub_dir:$PATH" disable_display_managers 2>&1)"
status=$?
set -e
if [[ $status -eq 0 && -f "$DM_STATE_FILE" ]] &&
  [[ "$(cat "$DM_STATE_FILE")" == $'sddm.service\ngreetd.service' ]] &&
  [[ "$(grep -Fxc 'systemctl disable sddm.service' "$STUB_LOG")" == 1 ]]; then
  pass "disable_display_managers keeps unique state across reruns and alias overlap"
else
  fail "disable_display_managers duplicate state (status=$status, output=$output)"
fi

# State write failures must prevent disabling units through either path.
dm_readonly_dir="$TMP_DIR/dm_readonly"
mkdir -p "$dm_readonly_dir"
chmod 555 "$dm_readonly_dir"
if [[ -w "$dm_readonly_dir" ]]; then
  skip "disable_display_managers state write failure (directory remains writable)"
else
  ln -sf "$TMP_DIR/greetd.service" "$DISPLAY_MANAGER_LINK"
  for dm_alias_only in 0 1; do
    : >"$STUB_LOG"
    set +e
    # shellcheck disable=SC2016 # Expand arguments and exit status in the child shell.
    output="$(env PATH="$dm_stub_dir:$sudo_pw_dir:$PATH" DM_STATE_FILE="$dm_readonly_dir/state" STUB_DM_ALIAS_ONLY="$dm_alias_only" bash -c '
      source "$1"
      check_root() { :; }
      install_packages() { :; }
      copy_dotfiles() { :; }
      configure_pam() { :; }
      install_polkit_rule() { :; }
      main --de i3
    ' bash "$REPO_ROOT/install.sh" 2>&1)"
    status=$?
    set -e
    log_content="$(cat "$STUB_LOG")"
    if [[ $status -ne 0 && ! -e "$dm_readonly_dir/state" &&
      "$output" == *"$recovery_hint"* && "$output" != *"lightXDM install complete!"* ]] &&
      grep -Fxq '=> Install stopped during disable_display_managers; already done: install_packages copy_dotfiles configure_pam install_polkit_rule' <<<"$output" &&
      grep -Fq 'systemctl is-enabled' "$STUB_LOG" &&
      ! grep -Fq 'systemctl disable' "$STUB_LOG"; then
      pass "disable_display_managers stops before disabling when state write fails (alias_only=$dm_alias_only)"
    else
      fail "disable_display_managers state write failure (alias_only=$dm_alias_only, status=$status, log=$log_content, output=$output)"
    fi
  done
fi
chmod 755 "$dm_readonly_dir"

# Case 41b: uninstall preserves state on failure, then restores exactly its units
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh restores recorded display managers (unshare -r unavailable)"
else
  dm_home="$TMP_DIR/dm_home"
  mkdir -p "$dm_home"
  set +e
  output="$(env STUB_SYSTEMCTL_EXIT=1 TARGET_HOME="$dm_home" LOGIN_FILE="$TMP_DIR/dm_login" AUTOLOGIN_DROPIN="$TMP_DIR/dm_autologin" OVERRIDE_FILE="$TMP_DIR/dm_override" POLKIT_RULE="$TMP_DIR/dm_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -ne 0 && -f "$DM_STATE_FILE" ]]; then
    pass "uninstall.sh keeps display manager state when enabling fails"
  else
    fail "uninstall.sh failed enable (status=$status, output=$output)"
  fi

  # Case 41c: a missing first unit does not prevent restoring the remaining units
  : >"$STUB_LOG"
  set +e
  output="$(env STUB_SYSTEMCTL_FAIL_UNIT=sddm.service TARGET_HOME="$dm_home" LOGIN_FILE="$TMP_DIR/dm_login" AUTOLOGIN_DROPIN="$TMP_DIR/dm_autologin" OVERRIDE_FILE="$TMP_DIR/dm_override" POLKIT_RULE="$TMP_DIR/dm_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -ne 0 && -f "$DM_STATE_FILE" ]] &&
    [[ "$(cat "$DM_STATE_FILE")" == 'sddm.service' ]] &&
    [[ "$log_content" == $'systemctl enable sddm.service\nsystemctl is-enabled sddm.service\nsystemctl enable greetd.service' ]] &&
    [[ "$output" == *"Failed to re-enable display manager(s): sddm.service"* ]]; then
    pass "uninstall.sh restores later display managers and keeps only failed units"
  else
    fail "uninstall.sh partial display manager restore (status=$status, log=$log_content, output=$output)"
  fi

  # A recorded unit that was removed or masked since install is skipped, not kept forever.
  for dm_gone_state in not-found masked masked-runtime; do
    mkdir -p "$(dirname -- "$DM_STATE_FILE")"
    printf '%s\n' sddm.service greetd.service >"$DM_STATE_FILE"
    : >"$STUB_LOG"
    set +e
    output="$(env STUB_SYSTEMCTL_FAIL_UNIT=sddm.service STUB_SYSTEMCTL_STATE="$dm_gone_state" TARGET_HOME="$dm_home" LOGIN_FILE="$TMP_DIR/dm_login" AUTOLOGIN_DROPIN="$TMP_DIR/dm_autologin" OVERRIDE_FILE="$TMP_DIR/dm_override" POLKIT_RULE="$TMP_DIR/dm_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
    status=$?
    set -e
    log_content="$(cat "$STUB_LOG")"
    if [[ $status -eq 0 && ! -e "$DM_STATE_FILE" && "$output" == *"Warning: sddm.service is"* &&
      "$log_content" == *"systemctl enable greetd.service"* ]]; then
      pass "uninstall.sh skips a $dm_gone_state display manager and finishes"
    else
      fail "uninstall.sh with $dm_gone_state display manager (status=$status, log=$log_content, output=$output)"
    fi
  done
  mkdir -p "$(dirname -- "$DM_STATE_FILE")"
  printf '%s\n' sddm.service >"$DM_STATE_FILE"

  : >"$STUB_LOG"
  set +e
  output="$(env TARGET_HOME="$dm_home" LOGIN_FILE="$TMP_DIR/dm_login" AUTOLOGIN_DROPIN="$TMP_DIR/dm_autologin" OVERRIDE_FILE="$TMP_DIR/dm_override" POLKIT_RULE="$TMP_DIR/dm_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -eq 0 && ! -e "$DM_STATE_FILE" && "$log_content" == 'systemctl enable sddm.service' ]]; then
    pass "uninstall.sh enables only recorded display managers and removes state"
  else
    fail "uninstall.sh display manager restore (status=$status, log=$log_content, output=$output)"
  fi

  : >"$STUB_LOG"
  set +e
  output="$(env TARGET_HOME="$dm_home" LOGIN_FILE="$TMP_DIR/dm_login" AUTOLOGIN_DROPIN="$TMP_DIR/dm_autologin" OVERRIDE_FILE="$TMP_DIR/dm_override" POLKIT_RULE="$TMP_DIR/dm_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && ! -s "$STUB_LOG" ]]; then
    pass "uninstall.sh enables nothing when display manager state is absent"
  else
    fail "uninstall.sh missing display manager state (status=$status, output=$output)"
  fi
fi

# Case 42: main --de <id> overrides detect_de/prompt_de_selection and rejects invalid or missing ids
: >"$STUB_LOG"
set +e
output="$(STUB_DETECTED_DE=xfce run_main_with_stubs "$sudo_pw_dir" --de i3 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 0 && "$log_content" == *"install_packages i3"* && "$log_content" == *"copy_dotfiles i3"* && "$log_content" == *"configure_pam i3"* ]] &&
  [[ "$log_content" != *"detect_de"* && "$log_content" != *"prompt_de_selection"* && "$log_content" != *"xfce"* ]]; then
  pass "main --de i3 configures i3 and skips detect_de even when xfce would be detected"
else
  fail "main --de i3 override (status=$status, log=$log_content, output=$output)"
fi

: >"$STUB_LOG"
set +e
output="$(run_main_with_stubs "$sudo_pw_dir" --de bogus 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 1 && "$output" == *"xfce lxqt lxde mate cinnamon i3"* && -z "$log_content" ]]; then
  pass "main --de bogus prints valid ids and exits 1"
else
  fail "main --de bogus (status=$status, log=$log_content, output=$output)"
fi

: >"$STUB_LOG"
set +e
output="$(run_main_with_stubs "$sudo_pw_dir" --de 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 1 && "$output" == *"Usage:"* && -z "$log_content" ]]; then
  pass "main --de without id prints usage and exits 1"
else
  fail "main --de missing arg (status=$status, log=$log_content, output=$output)"
fi

# Case 43: main --no-packages skips packages and runs every other setup step, with or without --de
for de_id in "" i3; do
  no_packages_args=(--no-packages)
  if [[ -n "$de_id" ]]; then
    no_packages_args+=(--de "$de_id")
  fi
  : >"$STUB_LOG"
  set +e
  output="$(run_main_with_stubs "$sudo_pw_dir" "${no_packages_args[@]}" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -eq 0 && "$output" == *"Skipping package installation (--no-packages)."* &&
    "$log_content" != *"install_packages"* && "$log_content" == *"sudo -v"* &&
    "$log_content" == *"copy_dotfiles i3"* && "$log_content" == *"configure_pam i3"* &&
    "$log_content" == *"install_polkit_rule"* && "$log_content" == *"disable_display_managers"* ]]; then
    pass "main ${no_packages_args[*]} skips packages and runs all other setup steps"
  else
    fail "main ${no_packages_args[*]} (status=$status, log=$log_content, output=$output)"
  fi
done

# Missing startup commands stop before any configuration, even after package installation.
startup_bin="$TMP_DIR/startup_bin"
mkdir -p "$startup_bin"
for startup_tool in bash id tr grep getent cut cat; do
  ln -s "$(command -v "$startup_tool")" "$startup_bin/$startup_tool"
done
for missing_startup_command in startx startxfce4; do
  for startup_command in startx startxfce4; do
    rm -f "$startup_bin/$startup_command"
    if [[ "$startup_command" != "$missing_startup_command" ]]; then
      ln -s "$STUB_BIN/$startup_command" "$startup_bin/$startup_command"
    fi
  done
  for startup_mode in no-packages packages; do
    startup_args=(--de xfce)
    expected_startup_log="sudo -v"
    expected_startup_done="none"
    if [[ "$startup_mode" == "no-packages" ]]; then
      startup_args+=(--no-packages)
    else
      expected_startup_log+=$'\ninstall_packages xfce'
      expected_startup_done="install_packages"
    fi
    expected_startup_package="xorg-xinit"
    if [[ "$missing_startup_command" == "startxfce4" ]]; then
      expected_startup_package="xfce4-session"
    fi
    : >"$STUB_LOG"
    set +e
    output="$(
      exec 2>&1
      export PATH="$startup_bin"
      run_main_with_stubs "$sudo_pw_dir" "${startup_args[@]}"
    )"
    status=$?
    set -e
    log_content="$(cat "$STUB_LOG")"
    if [[ $status -eq 1 && "$log_content" == "$expected_startup_log" &&
      "$output" == *"Missing command: $missing_startup_command (normally provided by $expected_startup_package)."* &&
      "$output" == *"Install stopped during check_session_commands; already done: $expected_startup_done"* &&
      "$output" != *"lightXDM install complete!"* ]]; then
      pass "main stops before configuration when $missing_startup_command is missing ($startup_mode)"
    else
      fail "main missing $missing_startup_command ($startup_mode, status=$status, log=$log_content, output=$output)"
    fi
  done
done

# Check the selected user template's last exec line without evaluating shell expressions.
startup_home="$TMP_DIR/startup_home"
mkdir -p "$startup_home/.config/lightxdm"
for startup_template_case in last-exec missing-session no-exec expression path local-bin; do
  expected_startup_status=0
  case "$startup_template_case" in
    last-exec) startup_template=$'exec lightxdm-missing-session\nexec startxfce4 --example' ;;
    missing-session)
      startup_template=$'exec startxfce4\nexec lightxdm-missing-session --example'
      expected_startup_status=1
      ;;
    no-exec) startup_template='# No exec line' ;;
    expression)
      # shellcheck disable=SC2016  # a literal shell expression in the template, not expanded here
      startup_template='exec "$SESSION"'
      ;;
    path) startup_template='exec /custom/session' ;;
    local-bin)
      # .bash_profile puts ~/.local/bin on PATH before startx, so a session there is valid.
      mkdir -p "$startup_home/.local/bin"
      printf '#!/bin/sh\n' >"$startup_home/.local/bin/lightxdm-local-session"
      chmod +x "$startup_home/.local/bin/lightxdm-local-session"
      startup_template='exec lightxdm-local-session'
      ;;
  esac
  printf '%s' "$startup_template" >"$startup_home/.config/lightxdm/.xinitrc-xfce"
  : >"$STUB_LOG"
  set +e
  output="$(
    exec 2>&1
    HOME="$startup_home" run_main_with_stubs "$sudo_pw_dir" --no-packages --de xfce
  )"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -eq $expected_startup_status ]] && {
    [[ $status -eq 0 && "$log_content" == $'sudo -v\ncopy_dotfiles xfce\nconfigure_pam xfce\ninstall_polkit_rule\ndisable_display_managers' &&
      "$output" == *"lightXDM install complete!"* ]] ||
    [[ $status -eq 1 && "$log_content" == "sudo -v" &&
      "$output" == *"Missing command: lightxdm-missing-session. Install your session"* &&
      "$output" == *"Install stopped during check_session_commands; already done: none"* ]];
  }; then
    pass "main checks the selected template's session command ($startup_template_case)"
  else
    fail "main selected template ($startup_template_case, status=$status, log=$log_content, output=$output)"
  fi
done

# Case 43a: custom session templates work with --no-packages in either option order
custom_template_dir="$TMP_DIR/custom_template"
mkdir -p "$custom_template_dir"
cp -r "$REPO_ROOT/dotfiles" "$REPO_ROOT/polkit" "$custom_template_dir/"
cp "$custom_template_dir/dotfiles/.xinitrc-i3" "$custom_template_dir/dotfiles/.xinitrc-dwm"
for custom_order in packages-first de-first; do
  custom_args=(--no-packages --de dwm)
  if [[ "$custom_order" == "de-first" ]]; then
    custom_args=(--de dwm --no-packages)
  fi
  : >"$STUB_LOG"
  set +e
  output="$(
    # shellcheck disable=SC2034  # main uses SCRIPT_DIR from the sourced installer
    SCRIPT_DIR="$custom_template_dir"
    run_main_with_stubs "$sudo_pw_dir" "${custom_args[@]}" 2>&1
  )"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -eq 0 && "$log_content" == *"copy_dotfiles dwm"* &&
    "$log_content" == *"configure_pam dwm"* && "$log_content" != *"install_packages"* &&
    "$log_content" != *"detect_de"* && "$log_content" != *"prompt_de_selection"* ]]; then
    pass "main accepts a custom session template ($custom_order)"
  else
    fail "main custom session ($custom_order, status=$status, log=$log_content, output=$output)"
  fi
done

# Case 43b: custom ids require --no-packages, a template, and the allowed characters
cp "$custom_template_dir/dotfiles/.xinitrc-dwm" "$custom_template_dir/dotfiles/.xinitrc-Dwm"
for custom_rejection in packages missing-template invalid-id empty-id; do
  custom_args=(--no-packages --de dwm)
  case "$custom_rejection" in
    packages) custom_args=(--de dwm) ;;
    missing-template) rm "$custom_template_dir/dotfiles/.xinitrc-dwm" ;;
    invalid-id) custom_args=(--no-packages --de Dwm) ;;
    empty-id) custom_args=(--no-packages --de "") ;;
  esac
  : >"$STUB_LOG"
  set +e
  output="$(
    # shellcheck disable=SC2034  # main uses SCRIPT_DIR from the sourced installer
    SCRIPT_DIR="$custom_template_dir"
    run_main_with_stubs "$sudo_pw_dir" "${custom_args[@]}" 2>&1
  )"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -eq 1 && "$output" == *"Unsupported desktop environment:"* && -z "$log_content" ]]; then
    pass "main rejects a custom session ($custom_rejection)"
  else
    fail "main custom session rejection ($custom_rejection, status=$status, log=$log_content, output=$output)"
  fi
done

# Case 44: copy_dotfiles and uninstall.sh preserve post-install user edits in <file>.lightxdm-edited without overwriting existing ones
reinstall_edit_home="$TMP_DIR/home_reinstall_edited"
mkdir -p "$reinstall_edit_home"
echo "# skel bash_profile" >"$reinstall_edit_home/.bash_profile"
echo "# orig xinitrc" >"$reinstall_edit_home/.xinitrc"
(
  export HOME="$reinstall_edit_home"
  export USER="${USER:-testuser}"
  copy_dotfiles "plasma" 2>/dev/null
)
echo "# post-install bash edit 1" >>"$reinstall_edit_home/.bash_profile"
echo "# post-install xinit edit 1" >>"$reinstall_edit_home/.xinitrc"
expected_bash_edit1="$(cat "$reinstall_edit_home/.bash_profile")"
expected_xinit_edit1="$(cat "$reinstall_edit_home/.xinitrc")"
(
  export HOME="$reinstall_edit_home"
  export USER="${USER:-testuser}"
  copy_dotfiles "xfce" 2>/dev/null
)
# Also verify matching the backup does not create a spurious .lightxdm-edited copy, while a new edit does without clobbering the first
cp "$reinstall_edit_home/.bash_profile.lightxdm.bak" "$reinstall_edit_home/.bash_profile"
(
  export HOME="$reinstall_edit_home"
  export USER="${USER:-testuser}"
  copy_dotfiles "gnome" 2>/dev/null
)
no_dup_after_bak_match=0
if [[ ! -e "$reinstall_edit_home/.bash_profile.lightxdm-edited.1" ]]; then
  no_dup_after_bak_match=1
fi
echo "# post-install bash edit 2" >"$reinstall_edit_home/.bash_profile"
echo "# post-install xinit edit 2" >"$reinstall_edit_home/.xinitrc"
(
  export HOME="$reinstall_edit_home"
  export USER="${USER:-testuser}"
  copy_dotfiles "i3" 2>/dev/null
)
if [[ "$(cat "$reinstall_edit_home/.bash_profile.lightxdm.bak")" == "# skel bash_profile" ]] &&
  [[ "$(cat "$reinstall_edit_home/.xinitrc.lightxdm.bak")" == "# orig xinitrc" ]] &&
  [[ -f "$reinstall_edit_home/.bash_profile.lightxdm-edited" && "$(cat "$reinstall_edit_home/.bash_profile.lightxdm-edited")" == "$expected_bash_edit1" ]] &&
  [[ -f "$reinstall_edit_home/.xinitrc.lightxdm-edited" && "$(cat "$reinstall_edit_home/.xinitrc.lightxdm-edited")" == "$expected_xinit_edit1" ]] &&
  [[ $no_dup_after_bak_match -eq 1 ]] &&
  [[ -f "$reinstall_edit_home/.bash_profile.lightxdm-edited.1" && "$(cat "$reinstall_edit_home/.bash_profile.lightxdm-edited.1")" == "# post-install bash edit 2" ]] &&
  [[ -f "$reinstall_edit_home/.xinitrc.lightxdm-edited.1" && "$(cat "$reinstall_edit_home/.xinitrc.lightxdm-edited.1")" == "# post-install xinit edit 2" ]] &&
  [[ "$(sha256sum < "$reinstall_edit_home/.bash_profile")" == "$(sha256sum < "$REPO_ROOT/dotfiles/.bash_profile")" ]] &&
  [[ "$(sha256sum < "$reinstall_edit_home/.xinitrc")" == "$(sha256sum < "$REPO_ROOT/dotfiles/.xinitrc-i3")" ]]; then
  pass "copy_dotfiles saves post-install edits to .lightxdm-edited without clobbering backups or prior saved edits"
else
  fail "copy_dotfiles post-install edits preservation"
fi

if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh saves post-install edits to .lightxdm-edited before restoring backup (unshare -r unavailable)"
else
  uninstall_edit_home="$TMP_DIR/home_uninstall_edited"
  mkdir -p "$uninstall_edit_home"
  echo "# skel bash_profile" >"$uninstall_edit_home/.bash_profile"
  echo "# orig xinitrc" >"$uninstall_edit_home/.xinitrc"
  (
    export HOME="$uninstall_edit_home"
    export USER="${USER:-testuser}"
    copy_dotfiles "plasma" 2>/dev/null
  )
  echo "# uninstall bash edit 1" >>"$uninstall_edit_home/.bash_profile"
  echo "# uninstall xinit edit 1" >>"$uninstall_edit_home/.xinitrc"
  u_bash_edit1="$(cat "$uninstall_edit_home/.bash_profile")"
  u_xinit_edit1="$(cat "$uninstall_edit_home/.xinitrc")"
  set +e
  out_u_edit1="$(TARGET_HOME="$uninstall_edit_home" AUTOLOGIN_DROPIN="$uninstall_autologin" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status_u_edit1=$?
  set -e

  (
    export HOME="$uninstall_edit_home"
    export USER="${USER:-testuser}"
    copy_dotfiles "xfce" 2>/dev/null
  )
  echo "# uninstall bash edit 2" >"$uninstall_edit_home/.bash_profile"
  echo "# uninstall xinit edit 2" >"$uninstall_edit_home/.xinitrc"
  set +e
  out_u_edit2="$(TARGET_HOME="$uninstall_edit_home" AUTOLOGIN_DROPIN="$uninstall_autologin" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status_u_edit2=$?
  set -e

  if [[ $status_u_edit1 -eq 0 && $status_u_edit2 -eq 0 ]] &&
    [[ "$out_u_edit1" == *"$uninstall_edit_home/.bash_profile.lightxdm-edited"* ]] &&
    [[ "$out_u_edit1" == *"$uninstall_edit_home/.xinitrc.lightxdm-edited"* ]] &&
    [[ "$out_u_edit2" == *"$uninstall_edit_home/.bash_profile.lightxdm-edited.1"* ]] &&
    [[ "$out_u_edit2" == *"$uninstall_edit_home/.xinitrc.lightxdm-edited.1"* ]] &&
    [[ "$(cat "$uninstall_edit_home/.bash_profile")" == "# skel bash_profile" ]] &&
    [[ "$(cat "$uninstall_edit_home/.xinitrc")" == "# orig xinitrc" ]] &&
    [[ ! -e "$uninstall_edit_home/.bash_profile.lightxdm.bak" && ! -e "$uninstall_edit_home/.xinitrc.lightxdm.bak" ]] &&
    [[ -f "$uninstall_edit_home/.bash_profile.lightxdm-edited" && "$(cat "$uninstall_edit_home/.bash_profile.lightxdm-edited")" == "$u_bash_edit1" ]] &&
    [[ -f "$uninstall_edit_home/.xinitrc.lightxdm-edited" && "$(cat "$uninstall_edit_home/.xinitrc.lightxdm-edited")" == "$u_xinit_edit1" ]] &&
    [[ -f "$uninstall_edit_home/.bash_profile.lightxdm-edited.1" && "$(cat "$uninstall_edit_home/.bash_profile.lightxdm-edited.1")" == "# uninstall bash edit 2" ]] &&
    [[ -f "$uninstall_edit_home/.xinitrc.lightxdm-edited.1" && "$(cat "$uninstall_edit_home/.xinitrc.lightxdm-edited.1")" == "# uninstall xinit edit 2" ]]; then
    pass "uninstall.sh saves post-install edits to .lightxdm-edited without overwriting existing ones before restoring backup"
  else
    fail "uninstall.sh post-install edits preservation (s1=$status_u_edit1:$out_u_edit1 | s2=$status_u_edit2:$out_u_edit2)"
  fi
fi

# Case 45: main requires exact wheel membership (rejecting wheel-dev) and falls back to id -un when USER is unset
id_wheel_dev_dir="$TMP_DIR/id_wheel_dev"
mkdir -p "$id_wheel_dev_dir"
cat >"$id_wheel_dev_dir/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-un" ]]; then
  echo "devuser"
elif [[ "${1:-}" == "-nG" ]]; then
  echo "users wheel-dev adm"
else
  echo "1000"
fi
EOF
chmod +x "$id_wheel_dev_dir/id"

: >"$STUB_LOG"
set +e
output="$(run_main_with_stubs "$id_wheel_dev_dir:$sudo_pw_dir" --no-packages --de i3 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 1 && "$output" == *"is not in the 'wheel' group"* && -z "$log_content" ]]; then
  pass "main rejects non-exact wheel-dev group membership"
else
  fail "main wheel-dev group check (status=$status, log=$log_content, output=$output)"
fi

id_unset_user_dir="$TMP_DIR/id_unset_user"
mkdir -p "$id_unset_user_dir"
cat >"$id_unset_user_dir/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-un" ]]; then
  echo "wheeluser"
elif [[ "${1:-}" == "-nG" ]]; then
  if [[ "${2:-}" == "wheeluser" ]]; then
    echo "users wheel"
    exit 0
  fi
  exit 1
else
  echo "1000"
fi
EOF
chmod +x "$id_unset_user_dir/id"

: >"$STUB_LOG"
set +e
output="$(
  exec 2>&1
  export PATH="$id_unset_user_dir:$sudo_pw_dir:$PATH"
  unset USER SUDO_USER
  # shellcheck disable=SC2317,SC2329
  copy_dotfiles() { echo "copy_dotfiles $1" >>"$STUB_LOG"; }
  # shellcheck disable=SC2317,SC2329
  configure_pam() { echo "configure_pam $1" >>"$STUB_LOG"; }
  # shellcheck disable=SC2317,SC2329
  install_polkit_rule() { echo "install_polkit_rule" >>"$STUB_LOG"; }
  # shellcheck disable=SC2317,SC2329
  disable_display_managers() { echo "disable_display_managers" >>"$STUB_LOG"; }
  main --no-packages --de i3
)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 0 && "$log_content" == *"sudo -v"* && "$log_content" == *"copy_dotfiles i3"* && "$output" == *"for wheeluser"* ]]; then
  pass "main succeeds with USER unset when id -un resolves a wheel member"
else
  fail "main with USER unset (status=$status, log=$log_content, output=$output)"
fi

# Case 46: CDPATH=. yields a single-line SCRIPT_DIR when sourcing install.sh and running uninstall.sh
ln -s "$REPO_ROOT" "$TMP_DIR/relrepo"
cdpath_home="$TMP_DIR/home_cdpath"
mkdir -p "$cdpath_home"
set +e
cdpath_script_dir="$(
  cd "$TMP_DIR"
  export CDPATH=.
  export HOME="$cdpath_home"
  # shellcheck disable=SC2016
  bash -c 'source relrepo/install.sh && copy_dotfiles i3 2>/dev/null && printf "%s" "$SCRIPT_DIR"'
)"
cdpath_status=$?
set -e
if [[ $cdpath_status -eq 0 && "$cdpath_script_dir" == "$TMP_DIR/relrepo" && "$cdpath_script_dir" != *$'\n'* ]] &&
  [[ -f "$cdpath_home/.bash_profile" && -f "$cdpath_home/.xinitrc" ]]; then
  pass "CDPATH=. yields single-line SCRIPT_DIR and working copy_dotfiles when sourcing install.sh"
else
  fail "CDPATH=. with install.sh (status=$cdpath_status, SCRIPT_DIR=$cdpath_script_dir)"
fi

if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh ignores CDPATH=. when resolving SCRIPT_DIR (unshare -r unavailable)"
else
  set +e
  cdpath_u_out="$(
    cd "$TMP_DIR"
    export CDPATH=.
    TARGET_HOME="$cdpath_home" AUTOLOGIN_DROPIN="$uninstall_autologin" OVERRIDE_FILE="$uninstall_override" POLKIT_RULE="$uninstall_polkit" unshare -r bash relrepo/uninstall.sh 2>&1
  )"
  cdpath_u_status=$?
  set -e
  if [[ $cdpath_u_status -eq 0 && ! -e "$cdpath_home/.bash_profile" && ! -e "$cdpath_home/.xinitrc" ]]; then
    pass "uninstall.sh ignores CDPATH=. when resolving SCRIPT_DIR"
  else
    fail "CDPATH=. with uninstall.sh (status=$cdpath_u_status, output=$cdpath_u_out)"
  fi
fi

# Case 47: main warns when login shell is not bash (zsh, fish) and leaves bash output unchanged
zsh_stub_dir="$TMP_DIR/getent_zsh"
mkdir -p "$zsh_stub_dir"
cat >"$zsh_stub_dir/getent" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "passwd" && "${2:-}" == "testuser" ]]; then
  echo "testuser:x:1000:1000::/home/testuser:/usr/bin/zsh"
  exit 0
fi
exit 2
EOF
chmod +x "$zsh_stub_dir/getent"

fish_stub_dir="$TMP_DIR/getent_fish"
mkdir -p "$fish_stub_dir"
cat >"$fish_stub_dir/getent" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "passwd" && "${2:-}" == "testuser" ]]; then
  echo "testuser:x:1000:1000::/home/testuser:/usr/bin/fish"
  exit 0
fi
exit 2
EOF
chmod +x "$fish_stub_dir/getent"

bash_stub_dir="$TMP_DIR/getent_bash"
mkdir -p "$bash_stub_dir"
cat >"$bash_stub_dir/getent" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "passwd" && "${2:-}" == "testuser" ]]; then
  echo "testuser:x:1000:1000::/home/testuser:/usr/bin/bash"
  exit 0
fi
exit 2
EOF
chmod +x "$bash_stub_dir/getent"

set +e
out_zsh="$(USER=testuser run_main_with_stubs "$zsh_stub_dir:$sudo_pw_dir" --no-packages --de i3 2>&1)"
status_zsh=$?
out_fish="$(USER=testuser run_main_with_stubs "$fish_stub_dir:$sudo_pw_dir" --no-packages --de i3 2>&1)"
status_fish=$?
out_bash="$(USER=testuser run_main_with_stubs "$bash_stub_dir:$sudo_pw_dir" --no-packages --de i3 2>&1)"
status_bash=$?
set -e

if [[ $status_zsh -eq 0 && "$out_zsh" == *"WARNING:"* && "$out_zsh" == *'~/.zprofile'* &&
  "$out_zsh" != *"will auto-start on TTY1"* && "$out_zsh" != *"No need to run 'startx'"* &&
  $status_fish -eq 0 && "$out_fish" == *"WARNING:"* && "$out_fish" == *'~/.config/fish/config.fish'* &&
  "$out_fish" != *"will auto-start on TTY1"* && "$out_fish" != *"No need to run 'startx'"* &&
  $status_bash -eq 0 && "$out_bash" != *"WARNING:"* &&
  "$out_bash" == *"- i3 will auto-start on TTY1 for testuser"* && "$out_bash" == *"No need to run 'startx'."* ]]; then
  pass "main warns for non-bash login shells (zsh, fish) and keeps bash closing message unchanged"
else
  fail "main login shell check (zsh=$status_zsh:$out_zsh | fish=$status_fish:$out_fish | bash=$status_bash:$out_bash)"
fi

paused_home="$TMP_DIR/paused_home"
mkdir -p "$paused_home/.config/lightxdm"
: >"$paused_home/.config/lightxdm/no-autostart"
set +e
out_paused="$(HOME="$paused_home" USER=testuser run_main_with_stubs "$bash_stub_dir:$sudo_pw_dir" --no-packages --de i3 2>&1)"
status_paused=$?
set -e
if [[ $status_paused -eq 0 && "$out_paused" == *"auto-start on TTY1 stays paused"* &&
  "$out_paused" == *"rm ~/.config/lightxdm/no-autostart"* && "$out_paused" != *"will auto-start on TTY1"* &&
  -e "$paused_home/.config/lightxdm/no-autostart" ]]; then
  pass "main reports paused auto-start and keeps the no-autostart marker"
else
  fail "main with no-autostart marker (status=$status_paused, output=$out_paused)"
fi

# A PAM line that existed before install survives uninstall
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh keeps a PAM line that existed before install (unshare -r unavailable)"
else
  pre_dir="$TMP_DIR/pam_pre"
  mkdir -p "$pre_dir/home"
  rm -f "${LOGIN_FILE}.lightxdm.bak"
  printf '#%%PAM-1.0\nauth       optional   pam_kwallet5.so\naccount    include      system-local-login\n' >"$LOGIN_FILE"
  configure_pam plasma 2>/dev/null
  set +e
  output="$(env AUTOLOGIN_DROPIN="$pre_dir/a" OVERRIDE_FILE="$pre_dir/o" POLKIT_RULE="$pre_dir/p" DM_STATE_FILE="$pre_dir/s" TARGET_HOME="$pre_dir/home" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 ]] && grep -qx 'auth       optional   pam_kwallet5.so' "$LOGIN_FILE" &&
    ! grep -q 'force_run' "$LOGIN_FILE"; then
    pass "uninstall.sh keeps a PAM line that existed before install"
  else
    fail "uninstall.sh pre-existing PAM line (status=$status, output=$output, content=$(cat "$LOGIN_FILE"))"
  fi
fi

# Case 49: foreign getty override.conf survives enable-autologin.sh (--disable) and uninstall.sh, while legacy lightXDM override.conf is cleaned up
if [[ $can_unshare -eq 0 ]]; then
  skip "foreign override.conf preservation and legacy override.conf cleanup (unshare -r unavailable)"
else
  dropin_test_dir="$TMP_DIR/dropin_isolation"
  mkdir -p "$dropin_test_dir/home" "$dropin_test_dir/getty.d"
  foreign_override="$dropin_test_dir/getty.d/override.conf"
  dedicated_dropin="$dropin_test_dir/getty.d/lightxdm-autologin.conf"
  cat >"$foreign_override" <<'EOF'
[Service]
TTYVTDisallocate=no
EOF
  foreign_hash="$(sha256sum < "$foreign_override")"

  set +e
  out_en="$(env OVERRIDE_DIR="$dropin_test_dir/getty.d" LOGIN_FILE="$dropin_test_dir/login" unshare -r bash "$REPO_ROOT/enable-autologin.sh" "$real_test_user" 2>&1)"
  st_en=$?
  set -e
  en_foreign_ok=0
  if [[ $st_en -eq 0 && -f "$dedicated_dropin" && -f "$foreign_override" && "$(sha256sum < "$foreign_override")" == "$foreign_hash" ]]; then
    en_foreign_ok=1
  fi

  set +e
  out_dis="$(env OVERRIDE_DIR="$dropin_test_dir/getty.d" LOGIN_FILE="$dropin_test_dir/login" unshare -r bash "$REPO_ROOT/enable-autologin.sh" --disable 2>&1)"
  st_dis=$?
  set -e
  if [[ $en_foreign_ok -eq 1 && $st_dis -eq 0 && ! -e "$dedicated_dropin" && -f "$foreign_override" && "$(sha256sum < "$foreign_override")" == "$foreign_hash" ]]; then
    pass "enable-autologin.sh creates and removes lightxdm-autologin.conf without touching foreign override.conf"
  else
    fail "enable-autologin.sh foreign override.conf preservation (en=$st_en:$out_en | dis=$st_dis:$out_dis)"
  fi

  : >"$STUB_LOG"
  set +e
  out_u_foreign="$(env AUTOLOGIN_DROPIN="$dedicated_dropin" OVERRIDE_FILE="$foreign_override" POLKIT_RULE="$dropin_test_dir/polkit" LOGIN_FILE="$dropin_test_dir/login" DM_STATE_FILE="$dropin_test_dir/dm" TARGET_HOME="$dropin_test_dir/home" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  st_u_foreign=$?
  set -e
  log_u_foreign="$(cat "$STUB_LOG")"

  # Also test when lightxdm-autologin.conf and a customized/near-match override.conf both exist
  cat >"$foreign_override" <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin customuser --noclear %I $TERM
TTYVTDisallocate=no
EOF
  mixed_hash="$(sha256sum < "$foreign_override")"
  env OVERRIDE_DIR="$dropin_test_dir/getty.d" LOGIN_FILE="$dropin_test_dir/login" unshare -r bash "$REPO_ROOT/enable-autologin.sh" "$real_test_user" >/dev/null 2>&1
  : >"$STUB_LOG"
  set +e
  out_u_both="$(env AUTOLOGIN_DROPIN="$dedicated_dropin" OVERRIDE_FILE="$foreign_override" POLKIT_RULE="$dropin_test_dir/polkit" LOGIN_FILE="$dropin_test_dir/login" DM_STATE_FILE="$dropin_test_dir/dm" TARGET_HOME="$dropin_test_dir/home" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  st_u_both=$?
  set -e
  log_u_both="$(cat "$STUB_LOG")"

  if [[ $st_u_foreign -eq 0 && -f "$foreign_override" && "$out_u_foreign" == *"$foreign_override"* && -z "$log_u_foreign" ]] &&
    [[ $st_u_both -eq 0 && ! -e "$dedicated_dropin" && -f "$foreign_override" && "$(sha256sum < "$foreign_override")" == "$mixed_hash" ]] &&
    [[ "$out_u_both" == *"$foreign_override"* && "$log_u_both" == *"systemctl daemon-reload"* ]]; then
    pass "uninstall.sh keeps foreign override.conf (with message) while removing lightxdm-autologin.conf"
  else
    fail "uninstall.sh foreign override.conf survival (s1=$st_u_foreign:$out_u_foreign [$log_u_foreign] | s2=$st_u_both:$out_u_both [$log_u_both])"
  fi

  cat >"$foreign_override" <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin legacyuser --noclear %I $TERM
EOF
  : >"$STUB_LOG"
  set +e
  out_u_legacy="$(env AUTOLOGIN_DROPIN="$dedicated_dropin" OVERRIDE_FILE="$foreign_override" POLKIT_RULE="$dropin_test_dir/polkit" LOGIN_FILE="$dropin_test_dir/login" DM_STATE_FILE="$dropin_test_dir/dm" TARGET_HOME="$dropin_test_dir/home" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  st_u_legacy=$?
  set -e
  log_u_legacy="$(cat "$STUB_LOG")"
  if [[ $st_u_legacy -eq 0 && ! -e "$foreign_override" && "$log_u_legacy" == *"systemctl daemon-reload"* ]]; then
    pass "uninstall.sh removes legacy lightXDM-written override.conf"
  else
    fail "uninstall.sh legacy override.conf cleanup (status=$st_u_legacy, output=$out_u_legacy, log=$log_u_legacy)"
  fi
fi

# Case 50: Polkit install backs up foreign rules once and uninstall restores them
printf '// administrator rule\n' >"$POLKIT_RULE_DEST"
polkit_original_hash="$(sha256sum < "$POLKIT_RULE_DEST")"
install_polkit_rule 2>/dev/null
install_polkit_rule 2>/dev/null
if [[ -f "${POLKIT_RULE_DEST}.lightxdm.bak" ]] &&
  [[ "$(sha256sum < "${POLKIT_RULE_DEST}.lightxdm.bak")" == "$polkit_original_hash" ]] &&
  [[ "$(sha256sum < "$POLKIT_RULE_SRC")" == "$(sha256sum < "$POLKIT_RULE_DEST")" ]]; then
  pass "install_polkit_rule backs up a foreign rule and installs the shipped rule"
else
  fail "install_polkit_rule foreign rule backup"
fi

printf '// later administrator edit\n' >"$POLKIT_RULE_DEST"
polkit_edit_hash="$(sha256sum < "$POLKIT_RULE_DEST")"
install_polkit_rule 2>/dev/null
printf '// second administrator edit\n' >"$POLKIT_RULE_DEST"
polkit_second_edit_hash="$(sha256sum < "$POLKIT_RULE_DEST")"
install_polkit_rule 2>/dev/null
install_polkit_rule 2>/dev/null
if [[ -f "${POLKIT_RULE_DEST}.lightxdm.bak" ]] &&
  [[ "$(sha256sum < "${POLKIT_RULE_DEST}.lightxdm.bak")" == "$polkit_original_hash" ]] &&
  [[ -f "${POLKIT_RULE_DEST}.lightxdm-edited" && "$(sha256sum < "${POLKIT_RULE_DEST}.lightxdm-edited")" == "$polkit_edit_hash" ]] &&
  [[ -f "${POLKIT_RULE_DEST}.lightxdm-edited.1" && "$(sha256sum < "${POLKIT_RULE_DEST}.lightxdm-edited.1")" == "$polkit_second_edit_hash" ]] &&
  [[ ! -e "${POLKIT_RULE_DEST}.lightxdm-edited.2" ]] &&
  [[ "$(sha256sum < "$POLKIT_RULE_DEST")" == "$(sha256sum < "$POLKIT_RULE_SRC")" ]]; then
  pass "install_polkit_rule preserves the original backup and successive edits on reinstall"
else
  fail "install_polkit_rule backup or edit preservation on reinstall"
fi

polkit_test_dir="$TMP_DIR/polkit_uninstall"
mkdir -p "$polkit_test_dir/home"
printf '// administrator edit before uninstall\n' >>"$POLKIT_RULE_DEST"
polkit_uninstall_edit_hash="$(sha256sum < "$POLKIT_RULE_DEST")"
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh restores the original Polkit rule (unshare -r unavailable)"
else
  for polkit_run in 1 2; do
    set +e
    output="$(env TARGET_HOME="$polkit_test_dir/home" LOGIN_FILE="$polkit_test_dir/login" AUTOLOGIN_DROPIN="$polkit_test_dir/autologin" OVERRIDE_FILE="$polkit_test_dir/override" DM_STATE_FILE="$polkit_test_dir/state" POLKIT_RULE="$POLKIT_RULE_DEST" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
    status=$?
    set -e
    if [[ $status -eq 0 && -f "$POLKIT_RULE_DEST" && ! -e "${POLKIT_RULE_DEST}.lightxdm.bak" ]] &&
      [[ "$(sha256sum < "$POLKIT_RULE_DEST")" == "$polkit_original_hash" ]] &&
      [[ "$(sha256sum < "${POLKIT_RULE_DEST}.lightxdm-edited")" == "$polkit_edit_hash" ]] &&
      [[ "$(sha256sum < "${POLKIT_RULE_DEST}.lightxdm-edited.1")" == "$polkit_second_edit_hash" ]] &&
      [[ -f "${POLKIT_RULE_DEST}.lightxdm-edited.2" && "$(sha256sum < "${POLKIT_RULE_DEST}.lightxdm-edited.2")" == "$polkit_uninstall_edit_hash" ]] &&
      [[ ! -e "${POLKIT_RULE_DEST}.lightxdm-edited.3" ]] &&
      [[ $polkit_run -eq 1 || "$output" == *"Keeping $POLKIT_RULE_DEST"* ]]; then
      pass "uninstall.sh preserves edits and keeps the original Polkit rule after run $polkit_run"
    else
      fail "uninstall.sh Polkit restore (run=$polkit_run, status=$status, output=$output)"
    fi
  done
fi

# Case 51: without a prior Polkit rule, install creates no backup and uninstall removes it
rm -f "$POLKIT_RULE_DEST" "${POLKIT_RULE_DEST}.lightxdm.bak"
install_polkit_rule 2>/dev/null
install_polkit_rule 2>/dev/null
if [[ ! -e "${POLKIT_RULE_DEST}.lightxdm.bak" ]] &&
  [[ -f "${POLKIT_RULE_DEST}.lightxdm.absent" && ! -s "${POLKIT_RULE_DEST}.lightxdm.absent" ]] &&
  [[ "$(sha256sum < "$POLKIT_RULE_SRC")" == "$(sha256sum < "$POLKIT_RULE_DEST")" ]]; then
  pass "install_polkit_rule creates no backup for a fresh or identical rule"
else
  fail "install_polkit_rule fresh install or identical rule"
fi
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh removes Polkit rule without a prior rule (unshare -r unavailable)"
else
  set +e
  output="$(env TARGET_HOME="$polkit_test_dir/home" LOGIN_FILE="$polkit_test_dir/login" AUTOLOGIN_DROPIN="$polkit_test_dir/autologin" OVERRIDE_FILE="$polkit_test_dir/override" DM_STATE_FILE="$polkit_test_dir/state" POLKIT_RULE="$POLKIT_RULE_DEST" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && ! -e "$POLKIT_RULE_DEST" && ! -e "${POLKIT_RULE_DEST}.lightxdm.bak" && ! -e "${POLKIT_RULE_DEST}.lightxdm.absent" ]]; then
    pass "uninstall.sh removes Polkit rule without a prior rule"
  else
    fail "uninstall.sh fresh Polkit removal (status=$status, output=$output)"
  fi
fi

# Case 51b: a foreign Polkit symlink survives install/uninstall and a repeated uninstall
rm -f "$POLKIT_RULE_DEST" "${POLKIT_RULE_DEST}.lightxdm.bak" "${POLKIT_RULE_DEST}.lightxdm.absent"
printf '// administrator symlink rule\n' >"$polkit_test_dir/original.rules"
polkit_link_hash="$(sha256sum < "$polkit_test_dir/original.rules")"
ln -s "$polkit_test_dir/original.rules" "$POLKIT_RULE_DEST"
install_polkit_rule 2>/dev/null
if [[ -L "${POLKIT_RULE_DEST}.lightxdm.bak" && ! -L "$POLKIT_RULE_DEST" ]] &&
  [[ "$(readlink "${POLKIT_RULE_DEST}.lightxdm.bak")" == "$polkit_test_dir/original.rules" ]] &&
  [[ "$(sha256sum < "$polkit_test_dir/original.rules")" == "$polkit_link_hash" ]]; then
  pass "install_polkit_rule preserves a foreign symlink in its backup"
else
  fail "install_polkit_rule foreign symlink backup"
fi
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh restores a foreign Polkit symlink (unshare -r unavailable)"
else
  for polkit_run in 1 2; do
    set +e
    output="$(env TARGET_HOME="$polkit_test_dir/home" LOGIN_FILE="$polkit_test_dir/login" AUTOLOGIN_DROPIN="$polkit_test_dir/autologin" OVERRIDE_FILE="$polkit_test_dir/override" DM_STATE_FILE="$polkit_test_dir/state" POLKIT_RULE="$POLKIT_RULE_DEST" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
    status=$?
    set -e
    if [[ $status -eq 0 && -L "$POLKIT_RULE_DEST" && ! -e "${POLKIT_RULE_DEST}.lightxdm.bak" && ! -L "${POLKIT_RULE_DEST}.lightxdm.bak" ]] &&
      [[ "$(readlink "$POLKIT_RULE_DEST")" == "$polkit_test_dir/original.rules" ]] &&
      [[ "$(sha256sum < "$POLKIT_RULE_DEST")" == "$polkit_link_hash" ]]; then
      pass "uninstall.sh keeps the original Polkit symlink after run $polkit_run"
    else
      fail "uninstall.sh Polkit symlink restore (run=$polkit_run, status=$status, output=$output)"
    fi
  done
fi

# Case 51c: template-identical and dangling Polkit symlinks round-trip with later symlink edits
for polkit_link_target in "$POLKIT_RULE_SRC" "$polkit_test_dir/missing.rules"; do
  rm -f "$POLKIT_RULE_DEST" "${POLKIT_RULE_DEST}.lightxdm.bak" "${POLKIT_RULE_DEST}.lightxdm-edited" "${POLKIT_RULE_DEST}.lightxdm-edited.1" "${POLKIT_RULE_DEST}.lightxdm-edited.2"
  ln -s "$polkit_link_target" "$POLKIT_RULE_DEST"
  install_polkit_rule 2>/dev/null
  rm -f "$POLKIT_RULE_DEST"
  ln -s "$polkit_test_dir/reinstall-missing.rules" "$POLKIT_RULE_DEST"
  install_polkit_rule 2>/dev/null
  if [[ -L "${POLKIT_RULE_DEST}.lightxdm.bak" && "$(readlink "${POLKIT_RULE_DEST}.lightxdm.bak")" == "$polkit_link_target" ]] &&
    [[ -L "${POLKIT_RULE_DEST}.lightxdm-edited" && "$(readlink "${POLKIT_RULE_DEST}.lightxdm-edited")" == "$polkit_test_dir/reinstall-missing.rules" ]] &&
    [[ -f "$POLKIT_RULE_DEST" && ! -L "$POLKIT_RULE_DEST" ]] &&
    [[ "$(sha256sum < "$POLKIT_RULE_DEST")" == "$(sha256sum < "$POLKIT_RULE_SRC")" ]]; then
    pass "install_polkit_rule preserves original and edited symlinks ($polkit_link_target)"
  else
    fail "install_polkit_rule symlink preservation ($polkit_link_target)"
  fi
  if [[ $can_unshare -eq 0 ]]; then
    skip "uninstall.sh restores Polkit symlink ($polkit_link_target; unshare -r unavailable)"
  else
    rm -f "$POLKIT_RULE_DEST"
    ln -s "$POLKIT_RULE_SRC" "$POLKIT_RULE_DEST"
    for polkit_run in 1 2; do
      set +e
      output="$(env TARGET_HOME="$polkit_test_dir/home" LOGIN_FILE="$polkit_test_dir/login" AUTOLOGIN_DROPIN="$polkit_test_dir/autologin" OVERRIDE_FILE="$polkit_test_dir/override" DM_STATE_FILE="$polkit_test_dir/state" POLKIT_RULE="$POLKIT_RULE_DEST" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
      status=$?
      set -e
      if [[ $status -eq 0 && -L "$POLKIT_RULE_DEST" && "$(readlink "$POLKIT_RULE_DEST")" == "$polkit_link_target" ]] &&
        [[ ! -e "${POLKIT_RULE_DEST}.lightxdm.bak" && ! -L "${POLKIT_RULE_DEST}.lightxdm.bak" ]] &&
        [[ -L "${POLKIT_RULE_DEST}.lightxdm-edited" && "$(readlink "${POLKIT_RULE_DEST}.lightxdm-edited")" == "$polkit_test_dir/reinstall-missing.rules" ]] &&
        [[ -L "${POLKIT_RULE_DEST}.lightxdm-edited.1" && "$(readlink "${POLKIT_RULE_DEST}.lightxdm-edited.1")" == "$POLKIT_RULE_SRC" ]] &&
        [[ ! -e "${POLKIT_RULE_DEST}.lightxdm-edited.2" && ! -L "${POLKIT_RULE_DEST}.lightxdm-edited.2" ]]; then
        pass "uninstall.sh preserves edited and original Polkit symlinks after run $polkit_run ($polkit_link_target)"
      else
        fail "uninstall.sh Polkit symlink round-trip (target=$polkit_link_target, run=$polkit_run, status=$status, output=$output)"
      fi
    done
  fi
done

# Case 51d: a fresh Polkit rule edited before uninstall or reinstall is saved and removed
for polkit_reinstall in 0 1; do
  rm -f "$POLKIT_RULE_DEST" "${POLKIT_RULE_DEST}.lightxdm.bak" "${POLKIT_RULE_DEST}.lightxdm.absent" "${POLKIT_RULE_DEST}.lightxdm-edited" "${POLKIT_RULE_DEST}.lightxdm-edited.1" "${POLKIT_RULE_DEST}.lightxdm-edited.2"
  install_polkit_rule 2>/dev/null
  printf '// fresh install user edit\n' >>"$POLKIT_RULE_DEST"
  polkit_fresh_edit_hash="$(sha256sum < "$POLKIT_RULE_DEST")"
  if [[ $polkit_reinstall -eq 1 ]]; then
    install_polkit_rule 2>/dev/null
  fi
  if [[ -f "${POLKIT_RULE_DEST}.lightxdm.absent" && ! -e "${POLKIT_RULE_DEST}.lightxdm.bak" && ! -L "${POLKIT_RULE_DEST}.lightxdm.bak" ]] &&
    { [[ $polkit_reinstall -eq 0 ]] ||
      { [[ -f "${POLKIT_RULE_DEST}.lightxdm-edited" ]] &&
        [[ "$(sha256sum < "${POLKIT_RULE_DEST}.lightxdm-edited")" == "$polkit_fresh_edit_hash" ]] &&
        [[ "$(sha256sum < "$POLKIT_RULE_DEST")" == "$(sha256sum < "$POLKIT_RULE_SRC")" ]]; }; }; then
    pass "install_polkit_rule remembers an absent original and preserves edits (reinstall=$polkit_reinstall)"
  else
    fail "install_polkit_rule fresh edited rule (reinstall=$polkit_reinstall)"
  fi

  if [[ $EUID -eq 0 ]]; then
    polkit_uninstall_runner=(bash)
  elif [[ $can_unshare -eq 1 ]]; then
    polkit_uninstall_runner=(unshare -r bash)
  else
    skip "uninstall.sh saves fresh Polkit edits (reinstall=$polkit_reinstall; unshare -r unavailable)"
    continue
  fi
  set +e
  output="$(env TARGET_HOME="$polkit_test_dir/home" LOGIN_FILE="$polkit_test_dir/login" AUTOLOGIN_DROPIN="$polkit_test_dir/autologin" OVERRIDE_FILE="$polkit_test_dir/override" DM_STATE_FILE="$polkit_test_dir/state" POLKIT_RULE="$POLKIT_RULE_DEST" "${polkit_uninstall_runner[@]}" "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && ! -e "$POLKIT_RULE_DEST" && ! -L "$POLKIT_RULE_DEST" ]] &&
    [[ ! -e "${POLKIT_RULE_DEST}.lightxdm.absent" && ! -L "${POLKIT_RULE_DEST}.lightxdm.absent" ]] &&
    [[ ! -e "${POLKIT_RULE_DEST}.lightxdm.bak" && ! -L "${POLKIT_RULE_DEST}.lightxdm.bak" ]] &&
    [[ -f "${POLKIT_RULE_DEST}.lightxdm-edited" && ! -e "${POLKIT_RULE_DEST}.lightxdm-edited.1" ]] &&
    [[ "$(sha256sum < "${POLKIT_RULE_DEST}.lightxdm-edited")" == "$polkit_fresh_edit_hash" ]]; then
    pass "uninstall.sh removes the fresh Polkit rule and saves edits (reinstall=$polkit_reinstall)"
  else
    fail "uninstall.sh fresh Polkit edits (reinstall=$polkit_reinstall, status=$status, output=$output)"
  fi
done

# Case 52: gpg-agent helper edits survive reinstall and uninstall without overwriting saved copies
gpg_reinstall_home="$TMP_DIR/home_gpg_reinstall"
mkdir -p "$gpg_reinstall_home"
echo "# pre-existing gnome helper" >"$gpg_reinstall_home/.gpg-agent-gnome"
(
  export HOME="$gpg_reinstall_home"
  export USER="${USER:-testuser}"
  copy_dotfiles "plasma" 2>/dev/null
  copy_dotfiles "plasma" 2>/dev/null
  copy_dotfiles "gnome" 2>/dev/null
  copy_dotfiles "gnome" 2>/dev/null
)
unmodified_kwallet_clean=0
if [[ ! -e "$gpg_reinstall_home/.gpg-agent-kwallet.lightxdm.bak" && ! -e "$gpg_reinstall_home/.gpg-agent-kwallet.lightxdm-edited" ]]; then
  unmodified_kwallet_clean=1
fi
echo "# kwallet edit 1" >>"$gpg_reinstall_home/.gpg-agent-kwallet"
echo "# gnome edit 1" >>"$gpg_reinstall_home/.gpg-agent-gnome"
expected_kw_edit1="$(cat "$gpg_reinstall_home/.gpg-agent-kwallet")"
expected_gn_edit1="$(cat "$gpg_reinstall_home/.gpg-agent-gnome")"
(
  export HOME="$gpg_reinstall_home"
  export USER="${USER:-testuser}"
  copy_dotfiles "plasma" 2>/dev/null
  copy_dotfiles "gnome" 2>/dev/null
)
echo "# kwallet edit 2" >"$gpg_reinstall_home/.gpg-agent-kwallet"
echo "# gnome edit 2" >"$gpg_reinstall_home/.gpg-agent-gnome"
(
  export HOME="$gpg_reinstall_home"
  export USER="${USER:-testuser}"
  copy_dotfiles "plasma" 2>/dev/null
  copy_dotfiles "gnome" 2>/dev/null
)
if [[ $unmodified_kwallet_clean -eq 1 ]] &&
  [[ ! -e "$gpg_reinstall_home/.gpg-agent-kwallet.lightxdm.bak" && -f "$gpg_reinstall_home/.gpg-agent-kwallet.lightxdm.absent" ]] &&
  [[ -f "$gpg_reinstall_home/.gpg-agent-kwallet.lightxdm-edited" && "$(cat "$gpg_reinstall_home/.gpg-agent-kwallet.lightxdm-edited")" == "$expected_kw_edit1" ]] &&
  [[ -f "$gpg_reinstall_home/.gpg-agent-kwallet.lightxdm-edited.1" && "$(cat "$gpg_reinstall_home/.gpg-agent-kwallet.lightxdm-edited.1")" == "# kwallet edit 2" ]] &&
  [[ -f "$gpg_reinstall_home/.gpg-agent-gnome.lightxdm.bak" && "$(cat "$gpg_reinstall_home/.gpg-agent-gnome.lightxdm.bak")" == "# pre-existing gnome helper" ]] &&
  [[ -f "$gpg_reinstall_home/.gpg-agent-gnome.lightxdm-edited" && "$(cat "$gpg_reinstall_home/.gpg-agent-gnome.lightxdm-edited")" == "$expected_gn_edit1" ]] &&
  [[ -f "$gpg_reinstall_home/.gpg-agent-gnome.lightxdm-edited.1" && "$(cat "$gpg_reinstall_home/.gpg-agent-gnome.lightxdm-edited.1")" == "# gnome edit 2" ]] &&
  [[ "$(sha256sum < "$REPO_ROOT/dotfiles/.gpg-agent-kwallet")" == "$(sha256sum < "$gpg_reinstall_home/.gpg-agent-kwallet")" ]] &&
  [[ "$(sha256sum < "$REPO_ROOT/dotfiles/.gpg-agent-gnome")" == "$(sha256sum < "$gpg_reinstall_home/.gpg-agent-gnome")" ]]; then
  pass "copy_dotfiles preserves edited gpg-agent helpers across reinstalls without overwriting backups or prior edits"
else
  fail "copy_dotfiles edited gpg-agent helper preservation"
fi

if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh preserves edited gpg-agent helpers and restores .lightxdm.bak (unshare -r unavailable)"
else
  gpg_uninstall_dir="$TMP_DIR/gpg_uninstall"
  gpg_u_home="$gpg_uninstall_dir/home_edited"
  gpg_bak_home="$gpg_uninstall_dir/home_bak"
  mkdir -p "$gpg_u_home" "$gpg_bak_home"

  (
    export HOME="$gpg_u_home"
    export USER="${USER:-testuser}"
    copy_dotfiles "plasma" 2>/dev/null
  )
  cp "$REPO_ROOT/dotfiles/.gpg-agent-gnome" "$gpg_u_home/.gpg-agent-gnome"
  echo "# gnome uninstall edit 1" >>"$gpg_u_home/.gpg-agent-gnome"
  expected_u_gn1="$(cat "$gpg_u_home/.gpg-agent-gnome")"
  set +e
  out_gpg_u1="$(env TARGET_HOME="$gpg_u_home" LOGIN_FILE="$gpg_uninstall_dir/login" AUTOLOGIN_DROPIN="$gpg_uninstall_dir/autologin" OVERRIDE_FILE="$gpg_uninstall_dir/override" DM_STATE_FILE="$gpg_uninstall_dir/state" POLKIT_RULE="$gpg_uninstall_dir/polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  st_gpg_u1=$?
  set -e
  if [[ $st_gpg_u1 -eq 0 && -f "$gpg_u_home/.gpg-agent-gnome" ]] &&
    [[ "$(cat "$gpg_u_home/.gpg-agent-gnome")" == "$expected_u_gn1" ]] &&
    [[ ! -e "$gpg_u_home/.gpg-agent-gnome.lightxdm-edited" ]] &&
    [[ "$out_gpg_u1" == *"Keeping $gpg_u_home/.gpg-agent-gnome"* ]]; then
    pass "uninstall.sh keeps an edited helper without a backup in place"
  else
    fail "uninstall.sh helper without backup (status=$st_gpg_u1, output=$out_gpg_u1)"
  fi

  (
    export HOME="$gpg_u_home"
    export USER="${USER:-testuser}"
    copy_dotfiles "gnome" 2>/dev/null
  )
  echo "# gnome uninstall edit 2" >"$gpg_u_home/.gpg-agent-gnome"
  set +e
  out_gpg_u2="$(env TARGET_HOME="$gpg_u_home" LOGIN_FILE="$gpg_uninstall_dir/login" AUTOLOGIN_DROPIN="$gpg_uninstall_dir/autologin" OVERRIDE_FILE="$gpg_uninstall_dir/override" DM_STATE_FILE="$gpg_uninstall_dir/state" POLKIT_RULE="$gpg_uninstall_dir/polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  st_gpg_u2=$?
  set -e

  echo "# orig kwallet helper" >"$gpg_bak_home/.gpg-agent-kwallet"
  echo "# orig gnome helper" >"$gpg_bak_home/.gpg-agent-gnome"
  (
    export HOME="$gpg_bak_home"
    export USER="${USER:-testuser}"
    copy_dotfiles "plasma" 2>/dev/null
    copy_dotfiles "gnome" 2>/dev/null
  )
  echo "# post-install kwallet edit" >"$gpg_bak_home/.gpg-agent-kwallet"
  set +e
  out_gpg_bak="$(env TARGET_HOME="$gpg_bak_home" LOGIN_FILE="$gpg_uninstall_dir/login" AUTOLOGIN_DROPIN="$gpg_uninstall_dir/autologin" OVERRIDE_FILE="$gpg_uninstall_dir/override" DM_STATE_FILE="$gpg_uninstall_dir/state" POLKIT_RULE="$gpg_uninstall_dir/polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  st_gpg_bak=$?
  out_gpg_bak_twice="$(env TARGET_HOME="$gpg_bak_home" LOGIN_FILE="$gpg_uninstall_dir/login" AUTOLOGIN_DROPIN="$gpg_uninstall_dir/autologin" OVERRIDE_FILE="$gpg_uninstall_dir/override" DM_STATE_FILE="$gpg_uninstall_dir/state" POLKIT_RULE="$gpg_uninstall_dir/polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  st_gpg_bak_twice=$?
  set -e

  if [[ $st_gpg_u1 -eq 0 && $st_gpg_u2 -eq 0 && $st_gpg_bak -eq 0 && $st_gpg_bak_twice -eq 0 ]] &&
    [[ ! -e "$gpg_u_home/.gpg-agent-kwallet" && ! -e "$gpg_u_home/.gpg-agent-kwallet.lightxdm-edited" ]] &&
    [[ -f "$gpg_u_home/.gpg-agent-gnome" && "$(cat "$gpg_u_home/.gpg-agent-gnome")" == "$expected_u_gn1" ]] &&
    [[ -f "$gpg_u_home/.gpg-agent-gnome.lightxdm-edited" && "$(cat "$gpg_u_home/.gpg-agent-gnome.lightxdm-edited")" == "# gnome uninstall edit 2" ]] &&
    [[ ! -e "$gpg_u_home/.gpg-agent-gnome.lightxdm-edited.1" ]] &&
    [[ "$out_gpg_u2" == *"$gpg_u_home/.gpg-agent-gnome.lightxdm-edited"* ]] &&
    [[ "$(cat "$gpg_bak_home/.gpg-agent-kwallet")" == "# orig kwallet helper" ]] &&
    [[ "$(cat "$gpg_bak_home/.gpg-agent-gnome")" == "# orig gnome helper" ]] &&
    [[ ! -e "$gpg_bak_home/.gpg-agent-kwallet.lightxdm.bak" && ! -e "$gpg_bak_home/.gpg-agent-gnome.lightxdm.bak" ]] &&
    [[ -f "$gpg_bak_home/.gpg-agent-kwallet.lightxdm-edited" && "$(cat "$gpg_bak_home/.gpg-agent-kwallet.lightxdm-edited")" == "# post-install kwallet edit" ]] &&
    [[ ! -e "$gpg_bak_home/.gpg-agent-kwallet.lightxdm-edited.1" ]] &&
    [[ ! -e "$gpg_bak_home/.gpg-agent-gnome.lightxdm-edited" ]] &&
    [[ "$out_gpg_bak" == *"$gpg_bak_home/.gpg-agent-kwallet.lightxdm-edited"* ]] &&
    [[ "$out_gpg_bak_twice" == *"Keeping $gpg_bak_home/.gpg-agent-kwallet"* && "$out_gpg_bak_twice" == *"Keeping $gpg_bak_home/.gpg-agent-gnome"* ]]; then
    pass "uninstall.sh saves helper edits before restoring backups and keeps restored helpers after two runs"
  else
    fail "uninstall.sh edited gpg-agent helper preservation (u1=$st_gpg_u1:$out_gpg_u1 | u2=$st_gpg_u2:$out_gpg_u2 | bak=$st_gpg_bak:$out_gpg_bak | twice=$st_gpg_bak_twice:$out_gpg_bak_twice)"
  fi
fi

# Case 53: fresh home -> install -> edit -> reinstall -> uninstall leaves no dotfiles and saves edits
absent_dir="$TMP_DIR/absent_dotfile"
absent_home1="$absent_dir/home_reinstall"
absent_home2="$absent_dir/home_edit_before_uninstall"
mkdir -p "$absent_home1" "$absent_home2"

(
  export HOME="$absent_home1"
  export USER="${USER:-testuser}"
  copy_dotfiles "plasma" 2>/dev/null
)
absent_markers_ok=0
if [[ -f "$absent_home1/.bash_profile.lightxdm.absent" && ! -s "$absent_home1/.bash_profile.lightxdm.absent" ]] &&
  [[ -f "$absent_home1/.xinitrc.lightxdm.absent" && ! -s "$absent_home1/.xinitrc.lightxdm.absent" ]] &&
  [[ -f "$absent_home1/.gpg-agent-kwallet.lightxdm.absent" && ! -s "$absent_home1/.gpg-agent-kwallet.lightxdm.absent" ]]; then
  absent_markers_ok=1
fi
echo "# fresh home bash edit" >>"$absent_home1/.bash_profile"
echo "# fresh home xinit edit" >>"$absent_home1/.xinitrc"
expected_absent_bash="$(cat "$absent_home1/.bash_profile")"
expected_absent_xinit="$(cat "$absent_home1/.xinitrc")"
(
  export HOME="$absent_home1"
  export USER="${USER:-testuser}"
  copy_dotfiles "plasma" 2>/dev/null
)
if [[ $absent_markers_ok -eq 1 ]] &&
  [[ ! -e "$absent_home1/.bash_profile.lightxdm.bak" && ! -e "$absent_home1/.xinitrc.lightxdm.bak" ]] &&
  [[ -f "$absent_home1/.bash_profile.lightxdm.absent" && -f "$absent_home1/.xinitrc.lightxdm.absent" ]] &&
  [[ -f "$absent_home1/.bash_profile.lightxdm-edited" && "$(cat "$absent_home1/.bash_profile.lightxdm-edited")" == "$expected_absent_bash" ]] &&
  [[ -f "$absent_home1/.xinitrc.lightxdm-edited" && "$(cat "$absent_home1/.xinitrc.lightxdm-edited")" == "$expected_absent_xinit" ]]; then
  pass "copy_dotfiles records .lightxdm.absent on fresh home and saves edits to .lightxdm-edited on reinstall"
else
  fail "copy_dotfiles .lightxdm.absent reinstall handling"
fi

if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh removes fresh-home dotfiles and saves edits when .lightxdm.absent exists (unshare -r unavailable)"
else
  set +e
  out_abs1="$(env TARGET_HOME="$absent_home1" LOGIN_FILE="$absent_dir/login" AUTOLOGIN_DROPIN="$absent_dir/autologin" OVERRIDE_FILE="$absent_dir/override" DM_STATE_FILE="$absent_dir/state" POLKIT_RULE="$absent_dir/polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  st_abs1=$?
  set -e

  (
    export HOME="$absent_home2"
    export USER="${USER:-testuser}"
    copy_dotfiles "i3" 2>/dev/null
  )
  echo "# edit before reinstall" >>"$absent_home2/.bash_profile"
  expected_abs2_edit1="$(cat "$absent_home2/.bash_profile")"
  (
    export HOME="$absent_home2"
    export USER="${USER:-testuser}"
    copy_dotfiles "i3" 2>/dev/null
  )
  echo "# edit after reinstall" >>"$absent_home2/.bash_profile"
  echo "# xinit edit without reinstall" >>"$absent_home2/.xinitrc"
  echo "# gnome helper edit without reinstall" >>"$absent_home2/.gpg-agent-gnome"
  expected_abs2_edit2="$(cat "$absent_home2/.bash_profile")"
  expected_abs2_xinit="$(cat "$absent_home2/.xinitrc")"
  expected_abs2_gn="$(cat "$absent_home2/.gpg-agent-gnome")"
  set +e
  out_abs2="$(env TARGET_HOME="$absent_home2" LOGIN_FILE="$absent_dir/login" AUTOLOGIN_DROPIN="$absent_dir/autologin" OVERRIDE_FILE="$absent_dir/override" DM_STATE_FILE="$absent_dir/state" POLKIT_RULE="$absent_dir/polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  st_abs2=$?
  set -e

  if [[ $st_abs1 -eq 0 && $st_abs2 -eq 0 ]] &&
    [[ ! -e "$absent_home1/.bash_profile" && ! -L "$absent_home1/.bash_profile" ]] &&
    [[ ! -e "$absent_home1/.xinitrc" && ! -L "$absent_home1/.xinitrc" ]] &&
    [[ ! -e "$absent_home1/.gpg-agent-kwallet" && ! -L "$absent_home1/.gpg-agent-kwallet" ]] &&
    [[ ! -e "$absent_home1/.bash_profile.lightxdm.absent" && ! -e "$absent_home1/.xinitrc.lightxdm.absent" && ! -e "$absent_home1/.gpg-agent-kwallet.lightxdm.absent" ]] &&
    [[ -f "$absent_home1/.bash_profile.lightxdm-edited" && "$(cat "$absent_home1/.bash_profile.lightxdm-edited")" == "$expected_absent_bash" ]] &&
    [[ -f "$absent_home1/.xinitrc.lightxdm-edited" && "$(cat "$absent_home1/.xinitrc.lightxdm-edited")" == "$expected_absent_xinit" ]] &&
    [[ ! -e "$absent_home2/.bash_profile" && ! -e "$absent_home2/.xinitrc" && ! -e "$absent_home2/.gpg-agent-gnome" ]] &&
    [[ ! -e "$absent_home2/.bash_profile.lightxdm.absent" && ! -e "$absent_home2/.xinitrc.lightxdm.absent" && ! -e "$absent_home2/.gpg-agent-gnome.lightxdm.absent" ]] &&
    [[ -f "$absent_home2/.bash_profile.lightxdm-edited" && "$(cat "$absent_home2/.bash_profile.lightxdm-edited")" == "$expected_abs2_edit1" ]] &&
    [[ -f "$absent_home2/.bash_profile.lightxdm-edited.1" && "$(cat "$absent_home2/.bash_profile.lightxdm-edited.1")" == "$expected_abs2_edit2" ]] &&
    [[ -f "$absent_home2/.xinitrc.lightxdm-edited" && "$(cat "$absent_home2/.xinitrc.lightxdm-edited")" == "$expected_abs2_xinit" ]] &&
    [[ -f "$absent_home2/.gpg-agent-gnome.lightxdm-edited" && "$(cat "$absent_home2/.gpg-agent-gnome.lightxdm-edited")" == "$expected_abs2_gn" ]]; then
    pass "fresh home -> install -> edit -> reinstall -> uninstall leaves no dotfiles and saves edits"
  else
    fail "uninstall.sh .lightxdm.absent handling (s1=$st_abs1:$out_abs1 | s2=$st_abs2:$out_abs2)"
  fi
fi

# Case 54: enable-autologin.sh --disable removes legacy lightXDM override.conf and keeps foreign override.conf with a message
if [[ $can_unshare -eq 0 ]]; then
  skip "enable-autologin.sh --disable legacy vs foreign override.conf handling (unshare -r unavailable)"
else
  dis_legacy_dir="$TMP_DIR/disable_legacy_override"
  mkdir -p "$dis_legacy_dir/getty.d"
  dis_override="$dis_legacy_dir/getty.d/override.conf"
  dis_dropin="$dis_legacy_dir/getty.d/lightxdm-autologin.conf"

  cat >"$dis_override" <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin legacyuser --noclear %I $TERM
EOF
  : >"$STUB_LOG"
  set +e
  out_dis_legacy="$(env OVERRIDE_DIR="$dis_legacy_dir/getty.d" LOGIN_FILE="$dis_legacy_dir/login" unshare -r bash "$REPO_ROOT/enable-autologin.sh" --disable 2>&1)"
  st_dis_legacy=$?
  set -e
  log_dis_legacy="$(cat "$STUB_LOG")"
  # Record now: the enable step below also removes a legacy override.conf.
  dis_legacy_gone=0
  [[ -e "$dis_override" ]] || dis_legacy_gone=1

  cat >"$dis_override" <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin legacyuser --noclear %I $TERM
EOF
  env OVERRIDE_DIR="$dis_legacy_dir/getty.d" LOGIN_FILE="$dis_legacy_dir/login" unshare -r bash "$REPO_ROOT/enable-autologin.sh" "$real_test_user" >/dev/null 2>&1
  : >"$STUB_LOG"
  set +e
  out_dis_both_legacy="$(env OVERRIDE_DIR="$dis_legacy_dir/getty.d" LOGIN_FILE="$dis_legacy_dir/login" unshare -r bash "$REPO_ROOT/enable-autologin.sh" --disable 2>&1)"
  st_dis_both_legacy=$?
  set -e
  log_dis_both_legacy="$(cat "$STUB_LOG")"

  if [[ $st_dis_legacy -eq 0 && $dis_legacy_gone -eq 1 && "$out_dis_legacy" != *"Keeping"* && "$log_dis_legacy" == *"systemctl daemon-reload"* ]] &&
    [[ $st_dis_both_legacy -eq 0 && ! -e "$dis_dropin" && ! -e "$dis_override" && "$log_dis_both_legacy" == *"systemctl daemon-reload"* ]]; then
    pass "enable-autologin.sh --disable removes legacy lightXDM override.conf"
  else
    fail "enable-autologin.sh --disable legacy override.conf (solo=$st_dis_legacy:$out_dis_legacy [$log_dis_legacy] | both=$st_dis_both_legacy:$out_dis_both_legacy [$log_dis_both_legacy])"
  fi

  cat >"$dis_override" <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin customuser --noclear %I $TERM
TTYVTDisallocate=no
EOF
  near_hash="$(sha256sum < "$dis_override")"
  env OVERRIDE_DIR="$dis_legacy_dir/getty.d" LOGIN_FILE="$dis_legacy_dir/login" unshare -r bash "$REPO_ROOT/enable-autologin.sh" "$real_test_user" >/dev/null 2>&1
  : >"$STUB_LOG"
  set +e
  out_dis_near="$(env OVERRIDE_DIR="$dis_legacy_dir/getty.d" LOGIN_FILE="$dis_legacy_dir/login" unshare -r bash "$REPO_ROOT/enable-autologin.sh" --disable 2>&1)"
  st_dis_near=$?
  set -e
  log_dis_near="$(cat "$STUB_LOG")"
  near_kept=0
  if [[ ! -e "$dis_dropin" && -f "$dis_override" && ! -L "$dis_override" && "$(sha256sum < "$dis_override")" == "$near_hash" ]]; then
    near_kept=1
  fi

  rm -f "$dis_override"
  cat >"$dis_legacy_dir/linked-legacy.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin legacyuser --noclear %I $TERM
EOF
  link_target_hash="$(sha256sum < "$dis_legacy_dir/linked-legacy.conf")"
  ln -s "$dis_legacy_dir/linked-legacy.conf" "$dis_override"
  set +e
  out_dis_link="$(env OVERRIDE_DIR="$dis_legacy_dir/getty.d" LOGIN_FILE="$dis_legacy_dir/login" unshare -r bash "$REPO_ROOT/enable-autologin.sh" --disable 2>&1)"
  st_dis_link=$?
  set -e

  if [[ $st_dis_near -eq 0 && $near_kept -eq 1 ]] &&
    [[ "$out_dis_near" == *"Keeping $dis_override"* && "$log_dis_near" == *"systemctl daemon-reload"* ]] &&
    [[ $st_dis_link -eq 0 && -L "$dis_override" && "$(sha256sum < "$dis_legacy_dir/linked-legacy.conf")" == "$link_target_hash" ]] &&
    [[ "$out_dis_link" == *"Keeping $dis_override"* ]]; then
    pass "enable-autologin.sh --disable keeps foreign override.conf untouched and reports it"
  else
    fail "enable-autologin.sh --disable foreign override.conf (near=$st_dis_near:$out_dis_near [$log_dis_near] | link=$st_dis_link:$out_dis_link)"
  fi
fi

# Enabling autologin replaces a legacy lightXDM override.conf for another user
if [[ $can_unshare -eq 1 ]]; then
  switch_dir="$TMP_DIR/autologin_switch"
  mkdir -p "$switch_dir/getty.d"
  # shellcheck disable=SC2016  # $TERM is a literal for systemd, not a shell expansion
  printf '[Service]\nExecStart=\nExecStart=-/usr/bin/agetty --autologin olduser --noclear %%I $TERM\n' >"$switch_dir/getty.d/override.conf"
  set +e
  output="$(env OVERRIDE_DIR="$switch_dir/getty.d" LOGIN_FILE="$switch_dir/login" unshare -r bash "$REPO_ROOT/enable-autologin.sh" "$(command -p id -un)" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && ! -e "$switch_dir/getty.d/override.conf" ]] &&
    grep -q -- "--autologin $(command -p id -un) " "$switch_dir/getty.d/lightxdm-autologin.conf"; then
    pass "enable-autologin.sh removes a legacy override.conf when switching users"
  else
    fail "enable-autologin.sh legacy override on enable (status=$status, output=$output)"
  fi
fi

# Case 55: enable-autologin.sh --disable warns by name when a remaining drop-in still enables autologin, and stays quiet otherwise
if [[ $can_unshare -eq 0 ]]; then
  skip "enable-autologin.sh --disable warns about remaining autologin drop-ins (unshare -r unavailable)"
else
  dis_warn_dir="$TMP_DIR/disable_autologin_warning"
  mkdir -p "$dis_warn_dir"
  cat >"$dis_warn_dir/10-plain.conf" <<'EOF'
[Service]
# ExecStart=-/usr/bin/agetty --autologin commented --noclear %I $TERM
ExecStart=-/usr/bin/agetty --noclear %I $TERM
EOF
  cat >"$dis_warn_dir/90-extra.conf" <<'EOF'
[Service]
  ExecStart = -/usr/bin/agetty --autologin extrauser --noclear %I $TERM
EOF
  cat >"$dis_warn_dir/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin customuser --noclear %I $TERM
TTYVTDisallocate=no
EOF
  env OVERRIDE_DIR="$dis_warn_dir" LOGIN_FILE="$dis_warn_dir/login" unshare -r bash "$REPO_ROOT/enable-autologin.sh" "$real_test_user" >/dev/null 2>&1
  set +e
  out_dis_warn="$(env OVERRIDE_DIR="$dis_warn_dir" LOGIN_FILE="$dis_warn_dir/login" unshare -r bash "$REPO_ROOT/enable-autologin.sh" --disable 2>&1)"
  st_dis_warn=$?
  set -e

  rm -f "$dis_warn_dir/90-extra.conf"
  cat >"$dis_warn_dir/override.conf" <<'EOF'
[Service]
TTYVTDisallocate=no
# ExecStart=-/usr/bin/agetty --autologin commented --noclear %I $TERM
EOF
  set +e
  out_dis_quiet="$(env OVERRIDE_DIR="$dis_warn_dir" LOGIN_FILE="$dis_warn_dir/login" unshare -r bash "$REPO_ROOT/enable-autologin.sh" --disable 2>&1)"
  st_dis_quiet=$?
  set -e

  if [[ $st_dis_warn -eq 0 && ! -e "$dis_warn_dir/lightxdm-autologin.conf" && -f "$dis_warn_dir/override.conf" ]] &&
    [[ "$out_dis_warn" == *"Warning: $dis_warn_dir/90-extra.conf"*"Warning: $dis_warn_dir/override.conf"*"Autologin disabled."* ]] &&
    [[ "$out_dis_warn" != *"$dis_warn_dir/10-plain.conf"* ]] &&
    [[ $st_dis_quiet -eq 0 && "$out_dis_quiet" == *"Keeping $dis_warn_dir/override.conf"* && "$out_dis_quiet" != *"Warning:"* ]]; then
    pass "enable-autologin.sh --disable warns by name only for drop-ins still enabling autologin"
  else
    fail "enable-autologin.sh --disable autologin warning (warn=$st_dis_warn:$out_dis_warn | quiet=$st_dis_quiet:$out_dis_quiet)"
  fi
fi

# Case 56: configure_pam PAM constants stay in sync with uninstall.sh strip patterns
rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
write_stock_login
configure_pam "plasma" 2>/dev/null
configure_pam "gnome" 2>/dev/null
pam_sync_errors=()
pam_seen_lines=()
uninstall_active_lines="$(grep -Ev '^[[:space:]]*#' "$REPO_ROOT/uninstall.sh")"
for pam_const in PAM_KWALLET_AUTH PAM_KWALLET_SESSION PAM_GNOME_KEYRING_AUTH PAM_GNOME_KEYRING_SESSION; do
  pam_decl="$(declare -p "$pam_const" 2>/dev/null || true)"
  pam_line="${!pam_const-}"
  if [[ "$pam_decl" != "declare -r ${pam_const}="* || -z "$pam_line" ]]; then
    pam_sync_errors+=("${pam_const}:not-readonly")
    continue
  fi
  if [[ ${#pam_seen_lines[@]} -gt 0 ]]; then
    for seen_line in "${pam_seen_lines[@]}"; do
      if [[ "$seen_line" == "$pam_line" ]]; then
        pam_sync_errors+=("${pam_const}:duplicate")
        continue 2
      fi
    done
  fi
  pam_seen_lines+=("$pam_line")
  if ! grep -Fxq -- "$pam_line" "$LOGIN_FILE"; then
    pam_sync_errors+=("${pam_const}:not-written-by-configure_pam")
  fi
  pam_pattern="^${pam_line//./\\.}\$"
  if ! grep -Fq -- "$pam_pattern" <<<"$uninstall_active_lines"; then
    pam_sync_errors+=("${pam_const}:${pam_pattern}")
  fi
done
uninstall_pam_count="$(grep -Ec '\^-?(auth|session|account|password)[[:space:]]' <<<"$uninstall_active_lines" || true)"
if [[ "$uninstall_pam_count" -ne 4 ]]; then
  pam_sync_errors+=("uninstall_pam_count=${uninstall_pam_count}")
fi
if [[ ${#pam_sync_errors[@]} -eq 0 ]]; then
  pass "configure_pam PAM constants match uninstall.sh strip patterns"
else
  fail "PAM constant drift between install.sh and uninstall.sh (${pam_sync_errors[*]})"
fi

# Case 57: .xinitrc-* templates merge X resources/keymaps, export session vars, source xinitrc.d before gpg-agent, manage activation/polkit per DE, and exec the session command
xinit_test_dir="$TMP_DIR/xinitrc_templates"
xinit_home="$xinit_test_dir/home"
xinit_empty_home="$xinit_test_dir/empty_home"
xinit_sys_xresources="$xinit_test_dir/sys.Xresources"
xinit_sys_xmodmap="$xinit_test_dir/sys.Xmodmap"
xinit_sys_xprofile="$xinit_test_dir/sys.xprofile"
xinit_d="$xinit_test_dir/xinitrc.d"
xinit_empty_d="$xinit_test_dir/empty_xinitrc.d"
xinit_bin="$xinit_test_dir/bin"
xinit_no_xtools_bin="$xinit_test_dir/no_xtools_bin"
xinit_log="$xinit_test_dir/calls.log"
xinit_err="$xinit_test_dir/stderr.log"
xinit_pid_file="$xinit_test_dir/subshell.pid"
mkdir -p "$xinit_home" "$xinit_empty_home" "$xinit_d" "$xinit_empty_d" "$xinit_bin" "$xinit_no_xtools_bin"

: >"$xinit_sys_xresources"
: >"$xinit_sys_xmodmap"
cat >"$xinit_sys_xprofile" <<'EOF'
echo "sys-xprofile" >>"$XINITRC_LOG"
EOF
: >"$xinit_home/.Xresources"
: >"$xinit_home/.Xmodmap"
cat >"$xinit_home/.xprofile" <<'EOF'
echo "xprofile" >>"$XINITRC_LOG"
EOF
cat >"$xinit_home/.gpg-agent-kwallet" <<'EOF'
export SSH_AUTH_SOCK="/tmp/kwallet-gpg-ssh.sock"
echo "gpg-agent-kwallet" >>"$XINITRC_LOG"
EOF
cat >"$xinit_home/.gpg-agent-gnome" <<'EOF'
export SSH_AUTH_SOCK="/tmp/gnome-gpg-ssh.sock"
echo "gpg-agent-gnome" >>"$XINITRC_LOG"
EOF

cat >"$xinit_d/50-test.sh" <<'EOF'
#!/usr/bin/env bash
export SSH_AUTH_SOCK="/tmp/xinitrcd-ssh.sock"
echo "xinitrc.d" >>"$XINITRC_LOG"
EOF
chmod +x "$xinit_d/50-test.sh"

cat >"$xinit_bin/xrdb" <<'EOF'
#!/usr/bin/env bash
echo "xrdb $*" >>"$XINITRC_LOG"
EOF
cat >"$xinit_bin/xmodmap" <<'EOF'
#!/usr/bin/env bash
echo "xmodmap $*" >>"$XINITRC_LOG"
EOF
cat >"$xinit_bin/dbus-update-activation-environment" <<'EOF'
#!/usr/bin/env bash
printf 'dbus-update-activation-environment %s|DESKTOP_SESSION=%s|XDG_CURRENT_DESKTOP=%s|XDG_SESSION_TYPE=%s|SSH_AUTH_SOCK=%s\n' \
  "$*" \
  "${DESKTOP_SESSION-<unset>}" \
  "${XDG_CURRENT_DESKTOP-<unset>}" \
  "${XDG_SESSION_TYPE-<unset>}" \
  "${SSH_AUTH_SOCK-<unset>}" >>"$XINITRC_LOG"
EOF
cat >"$xinit_bin/polkit-gnome-authentication-agent-1" <<'EOF'
#!/usr/bin/env bash
echo "polkit-gnome-authentication-agent-1${*:+ $*}" >>"$XINITRC_LOG"
EOF
chmod +x "$xinit_bin/xrdb" "$xinit_bin/xmodmap" "$xinit_bin/dbus-update-activation-environment" "$xinit_bin/polkit-gnome-authentication-agent-1"

for xinit_tool in bash sleep; do
  ln -sf "$(command -v "$xinit_tool")" "$xinit_no_xtools_bin/$xinit_tool"
done
ln -sf "$xinit_bin/dbus-update-activation-environment" "$xinit_no_xtools_bin/dbus-update-activation-environment"
ln -sf "$xinit_bin/polkit-gnome-authentication-agent-1" "$xinit_no_xtools_bin/polkit-gnome-authentication-agent-1"

xinit_specs=(
  "plasma|plasma|KDE|<unset>|gpg-agent-kwallet|0|0|startplasma-x11"
  "gnome|gnome|GNOME|x11|gpg-agent-gnome|0|0|gnome-session"
  "xfce|xfce|XFCE|<unset>|gpg-agent-gnome|0|1|startxfce4"
  "lxqt|lxqt|LXQt|<unset>|gpg-agent-gnome|0|0|startlxqt"
  "lxde|lxde|LXDE|<unset>|gpg-agent-gnome|1|0|startlxde"
  "mate|mate|MATE|<unset>|gpg-agent-gnome|0|0|mate-session"
  "cinnamon|cinnamon|X-Cinnamon|<unset>|gpg-agent-gnome|0|0|cinnamon-session"
  "budgie|budgie|Budgie:GNOME|<unset>|gpg-agent-gnome|0|0|budgie-desktop"
  "i3|i3|i3|<unset>|gpg-agent-gnome|1|1|i3"
)

for spec in "${xinit_specs[@]}"; do
  IFS='|' read -r _ _ _ _ _ _ _ session_cmd <<<"$spec"
  cat >"$xinit_bin/$session_cmd" <<EOF
#!/usr/bin/env bash
for ((_i = 0; _i < 200; _i++)); do
  [[ -r "/proc/\$\$/task/\$\$/children" ]] || break
  IFS= read -r _children <"/proc/\$\$/task/\$\$/children" || true
  [[ -n "\$_children" ]] || break
  sleep 0.01
done
printf 'session:%s|pid=%s|DESKTOP_SESSION=%s|XDG_CURRENT_DESKTOP=%s|XDG_SESSION_TYPE=%s|GDK_BACKEND=%s|SSH_AUTH_SOCK=%s\n' \
  "$session_cmd" \
  "\$\$" \
  "\${DESKTOP_SESSION-<unset>}" \
  "\${XDG_CURRENT_DESKTOP-<unset>}" \
  "\${XDG_SESSION_TYPE-<unset>}" \
  "\${GDK_BACKEND-<unset>}" \
  "\${SSH_AUTH_SOCK-<unset>}" >>"\$XINITRC_LOG"
EOF
  chmod +x "$xinit_bin/$session_cmd"
  ln -sf "$xinit_bin/$session_cmd" "$xinit_no_xtools_bin/$session_cmd"
done

xinit_template_files=("$REPO_ROOT"/dotfiles/.xinitrc-*)
if [[ ${#xinit_template_files[@]} -eq ${#xinit_specs[@]} ]]; then
  pass "all .xinitrc-* templates are covered by behavior specs"
else
  fail "expected ${#xinit_specs[@]} .xinitrc-* templates, found ${#xinit_template_files[@]}"
fi

for spec in "${xinit_specs[@]}"; do
  IFS='|' read -r de exp_ds exp_desktop exp_gdk exp_gpg exp_dbus exp_polkit exp_cmd <<<"$spec"
  tmpl="$REPO_ROOT/dotfiles/.xinitrc-$de"
  exp_ssh="/tmp/gnome-gpg-ssh.sock"
  if [[ "$exp_gpg" == "gpg-agent-kwallet" ]]; then
    exp_ssh="/tmp/kwallet-gpg-ssh.sock"
  fi

  common_lines=(
    "xprofile"
    "xinitrc.d"
    "$exp_gpg"
  )
  if [[ "$exp_dbus" -eq 1 ]]; then
    common_lines+=(
      "dbus-update-activation-environment --systemd XDG_CURRENT_DESKTOP DESKTOP_SESSION XDG_SESSION_TYPE SSH_AUTH_SOCK|DESKTOP_SESSION=$exp_ds|XDG_CURRENT_DESKTOP=$exp_desktop|XDG_SESSION_TYPE=x11|SSH_AUTH_SOCK=$exp_ssh"
    )
  fi
  if [[ "$exp_polkit" -eq 1 ]]; then
    common_lines+=("polkit-gnome-authentication-agent-1")
  fi

  : >"$xinit_log"
  : >"$xinit_err"
  : >"$xinit_pid_file"
  set +e
  (
    exec 2>"$xinit_err"
    echo "$BASHPID" >"$xinit_pid_file"
    export HOME="$xinit_home"
    export PATH="$xinit_bin:$PATH"
    export SYS_XRESOURCES="$xinit_sys_xresources"
    export SYS_XMODMAP="$xinit_sys_xmodmap"
    export SYS_XPROFILE="$xinit_sys_xprofile"
    export XINITRC_D="$xinit_d"
    export POLKIT_GNOME_AGENT="$xinit_bin/polkit-gnome-authentication-agent-1"
    export XINITRC_LOG="$xinit_log"
    unset DESKTOP_SESSION XDG_CURRENT_DESKTOP XDG_SESSION_TYPE GDK_BACKEND SSH_AUTH_SOCK
    exec bash "$tmpl"
  )
  status=$?
  set -e

  subshell_pid="$(cat "$xinit_pid_file")"
  expected_lines=(
    "xrdb -merge $xinit_sys_xresources"
    "xrdb -merge $xinit_home/.Xresources"
    "xmodmap $xinit_sys_xmodmap"
    "xmodmap $xinit_home/.Xmodmap"
    "sys-xprofile"
    "${common_lines[@]}"
    "session:$exp_cmd|pid=$subshell_pid|DESKTOP_SESSION=$exp_ds|XDG_CURRENT_DESKTOP=$exp_desktop|XDG_SESSION_TYPE=x11|GDK_BACKEND=$exp_gdk|SSH_AUTH_SOCK=$exp_ssh"
  )
  expected_log="$(printf '%s\n' "${expected_lines[@]}")"
  actual_log="$(cat "$xinit_log")"
  full_err="$(cat "$xinit_err")"

  : >"$xinit_log"
  : >"$xinit_err"
  : >"$xinit_pid_file"
  set +e
  (
    exec 2>"$xinit_err"
    echo "$BASHPID" >"$xinit_pid_file"
    export HOME="$xinit_home"
    export PATH="$xinit_bin:$PATH"
    export SYS_XRESOURCES="$xinit_test_dir/missing_Xresources"
    export SYS_XMODMAP="$xinit_test_dir/missing_Xmodmap"
    export SYS_XPROFILE="$xinit_test_dir/missing_xprofile"
    export XINITRC_D="$xinit_d"
    export POLKIT_GNOME_AGENT="$xinit_bin/polkit-gnome-authentication-agent-1"
    export XINITRC_LOG="$xinit_log"
    unset DESKTOP_SESSION XDG_CURRENT_DESKTOP XDG_SESSION_TYPE GDK_BACKEND SSH_AUTH_SOCK
    exec bash "$tmpl"
  )
  user_only_status=$?
  set -e

  user_only_pid="$(cat "$xinit_pid_file")"
  expected_user_only_lines=(
    "xrdb -merge $xinit_home/.Xresources"
    "xmodmap $xinit_home/.Xmodmap"
    "${common_lines[@]}"
    "session:$exp_cmd|pid=$user_only_pid|DESKTOP_SESSION=$exp_ds|XDG_CURRENT_DESKTOP=$exp_desktop|XDG_SESSION_TYPE=x11|GDK_BACKEND=$exp_gdk|SSH_AUTH_SOCK=$exp_ssh"
  )
  expected_user_only_log="$(printf '%s\n' "${expected_user_only_lines[@]}")"
  actual_user_only_log="$(cat "$xinit_log")"
  user_only_err="$(cat "$xinit_err")"

  : >"$xinit_log"
  : >"$xinit_err"
  : >"$xinit_pid_file"
  set +e
  (
    exec 2>"$xinit_err"
    echo "$BASHPID" >"$xinit_pid_file"
    export HOME="$xinit_home"
    export PATH="$xinit_no_xtools_bin"
    export SYS_XRESOURCES="$xinit_sys_xresources"
    export SYS_XMODMAP="$xinit_sys_xmodmap"
    export SYS_XPROFILE="$xinit_sys_xprofile"
    export XINITRC_D="$xinit_d"
    export POLKIT_GNOME_AGENT="$xinit_no_xtools_bin/polkit-gnome-authentication-agent-1"
    export XINITRC_LOG="$xinit_log"
    unset DESKTOP_SESSION XDG_CURRENT_DESKTOP XDG_SESSION_TYPE GDK_BACKEND SSH_AUTH_SOCK
    exec "$xinit_no_xtools_bin/bash" "$tmpl"
  )
  no_xtools_status=$?
  set -e

  no_xtools_pid="$(cat "$xinit_pid_file")"
  expected_no_xtools_lines=(
    "sys-xprofile"
    "${common_lines[@]}"
    "session:$exp_cmd|pid=$no_xtools_pid|DESKTOP_SESSION=$exp_ds|XDG_CURRENT_DESKTOP=$exp_desktop|XDG_SESSION_TYPE=x11|GDK_BACKEND=$exp_gdk|SSH_AUTH_SOCK=$exp_ssh"
  )
  expected_no_xtools_log="$(printf '%s\n' "${expected_no_xtools_lines[@]}")"
  actual_no_xtools_log="$(cat "$xinit_log")"
  no_xtools_err="$(cat "$xinit_err")"

  : >"$xinit_log"
  : >"$xinit_err"
  : >"$xinit_pid_file"
  set +e
  (
    exec 2>"$xinit_err"
    echo "$BASHPID" >"$xinit_pid_file"
    export HOME="$xinit_empty_home"
    export PATH="$xinit_bin:$PATH"
    export SYS_XRESOURCES="$xinit_test_dir/missing_Xresources"
    export SYS_XMODMAP="$xinit_test_dir/missing_Xmodmap"
    export SYS_XPROFILE="$xinit_test_dir/missing_xprofile"
    export XINITRC_D="$xinit_empty_d"
    export POLKIT_GNOME_AGENT="$xinit_test_dir/missing_polkit_agent"
    export XINITRC_LOG="$xinit_log"
    unset DESKTOP_SESSION XDG_CURRENT_DESKTOP XDG_SESSION_TYPE GDK_BACKEND SSH_AUTH_SOCK
    exec bash "$tmpl"
  )
  empty_status=$?
  set -e

  empty_pid="$(cat "$xinit_pid_file")"
  expected_empty_lines=()
  if [[ "$exp_dbus" -eq 1 ]]; then
    expected_empty_lines+=(
      "dbus-update-activation-environment --systemd XDG_CURRENT_DESKTOP DESKTOP_SESSION XDG_SESSION_TYPE|DESKTOP_SESSION=$exp_ds|XDG_CURRENT_DESKTOP=$exp_desktop|XDG_SESSION_TYPE=x11|SSH_AUTH_SOCK=<unset>"
    )
  fi
  expected_empty_lines+=(
    "session:$exp_cmd|pid=$empty_pid|DESKTOP_SESSION=$exp_ds|XDG_CURRENT_DESKTOP=$exp_desktop|XDG_SESSION_TYPE=x11|GDK_BACKEND=$exp_gdk|SSH_AUTH_SOCK=<unset>"
  )
  expected_empty_log="$(printf '%s\n' "${expected_empty_lines[@]}")"
  actual_empty_log="$(cat "$xinit_log")"
  empty_err="$(cat "$xinit_err")"

  # shellcheck disable=SC2016  # matching literal parameter default expressions in templates
  {
    tmpl_active="$(grep -Ev '^[[:space:]]*#' "$tmpl")"
    defaults_ok=1
    if [[ "$tmpl_active" != *'${SYS_XRESOURCES:-/etc/X11/xinit/.Xresources}'* ||
      "$tmpl_active" != *'${SYS_XMODMAP:-/etc/X11/xinit/.Xmodmap}'* ||
      "$tmpl_active" != *'${SYS_XPROFILE:-/etc/xprofile}'* ||
      "$tmpl_active" != *'${XINITRC_D:-/etc/X11/xinit/xinitrc.d}'* ]]; then
      defaults_ok=0
    fi
    if [[ "$exp_polkit" -eq 1 && "$tmpl_active" != *'${POLKIT_GNOME_AGENT:-/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1}'* ]]; then
      defaults_ok=0
    fi
  }

  if [[ $status -eq 0 && -z "$full_err" && "$actual_log" == "$expected_log" &&
    $user_only_status -eq 0 && -z "$user_only_err" && "$actual_user_only_log" == "$expected_user_only_log" &&
    $no_xtools_status -eq 0 && -z "$no_xtools_err" && "$actual_no_xtools_log" == "$expected_no_xtools_log" &&
    $empty_status -eq 0 && -z "$empty_err" && "$actual_empty_log" == "$expected_empty_log" &&
    $defaults_ok -eq 1 ]]; then
    pass ".xinitrc-$de merges X resources/keymaps, exports session env, runs xinitrc.d before $exp_gpg, and execs $exp_cmd"
  else
    fail ".xinitrc-$de (status=$status, err=$full_err, log=$actual_log, expected=$expected_log, user_only=$user_only_status:$user_only_err:$actual_user_only_log, no_xtools=$no_xtools_status:$no_xtools_err:$actual_no_xtools_log, empty_status=$empty_status, empty_err=$empty_err, empty_log=$actual_empty_log, defaults_ok=$defaults_ok)"
  fi
done

# Case 58: .bash_profile starts X only on interactive tty1 outside X without the marker, before .bashrc
profile_home="$TMP_DIR/bash_profile/home"
profile_bin="$TMP_DIR/bash_profile/bin"
mkdir -p "$profile_home/.local/bin" "$profile_home/.config/lightxdm" "$profile_bin"
cat >"$profile_home/.bashrc" <<'EOF'
printf 'bashrc|%s\n' "$PATH" >>"$HOME/profile.log"
EOF
cat >"$profile_bin/tty" <<'EOF'
#!/bin/bash
IFS= read -r device <"$HOME/tty"
printf '%s\n' "$device"
EOF
cat >"$profile_bin/startx" <<'EOF'
#!/bin/bash
printf 'startx|%s\n' "$PATH" >>"$HOME/profile.log"
EOF
chmod +x "$profile_bin/tty" "$profile_bin/startx"

for profile_case in interactive no-autostart autostart-restored non-interactive display tty2 missing-startx; do
  profile_flags=(-i)
  profile_display=''
  profile_tty=/dev/tty1
  profile_path="$profile_bin:/usr/bin:/bin"
  rm -f "$profile_home/.config/lightxdm/no-autostart" "$profile_home/.local/state/lightxdm/startx-attempts"
  case "$profile_case" in
    no-autostart) touch "$profile_home/.config/lightxdm/no-autostart" ;;
    non-interactive) profile_flags=() ;;
    display) profile_display=:0 ;;
    tty2) profile_tty=/dev/tty2 ;;
    missing-startx)
      mv "$profile_bin/startx" "$profile_bin/startx.off"
      # Exclude any host startx; tty uses only Bash builtins in this case.
      profile_path="$profile_bin"
      ;;
  esac
  printf '%s\n' "$profile_tty" >"$profile_home/tty"
  # shellcheck disable=SC2016  # expanded by the isolated child shell
  output="$(env -i HOME="$profile_home" PATH="$profile_bin:/usr/bin:/bin" TERM=dumb \
    DISPLAY="$profile_display" bash "${profile_flags[@]}" -c '
      exec 2>"$HOME/profile.err"
      PATH=$2
      # Discard the automatic interactive .bashrc read before this command.
      : >"$HOME/profile.log"
      source "$1"
      echo after
    ' bash "$REPO_ROOT/dotfiles/.bash_profile" "$profile_path" 2>/dev/null)" && status=0 || status=$?
  actual_log="$(cat "$profile_home/profile.log")"
  expected_log="bashrc|$profile_home/.local/bin:$profile_path"
  expected_output=after
  if [[ "$profile_case" == interactive || "$profile_case" == autostart-restored ]]; then
    expected_log="startx|$profile_home/.local/bin:$profile_path"
    expected_output=''
  fi
  if [[ $status -eq 0 && "$actual_log" == "$expected_log" && ! -s "$profile_home/profile.err" &&
    "$output" == "$expected_output" ]]; then
    pass ".bash_profile $profile_case preserves PATH and startup order"
  else
    fail ".bash_profile $profile_case (status=$status, log=$actual_log, expected=$expected_log, output=$output, stderr=$(cat "$profile_home/profile.err"))"
  fi
done
mv "$profile_bin/startx.off" "$profile_bin/startx"

run_tty1_profile() {
  local state_home="${1:-}"
  local env_args=(
    HOME="$profile_home"
    PATH="$profile_bin:/usr/bin:/bin"
    TERM=dumb
    DISPLAY=''
  )
  if [[ -n "$state_home" ]]; then
    env_args+=(XDG_STATE_HOME="$state_home")
  fi
  printf '/dev/tty1\n' >"$profile_home/tty"
  # shellcheck disable=SC2016  # expanded by the isolated child shell
  output="$(env -i "${env_args[@]}" bash -i -c '
    exec 2>"$HOME/profile.err"
    PATH=$2
    # Discard the automatic interactive .bashrc read before this command.
    : >"$HOME/profile.log"
    source "$1"
    printf "after|%s\n" "${!_lightxdm_*}"
  ' bash "$REPO_ROOT/dotfiles/.bash_profile" "$profile_bin:/usr/bin:/bin" 2>/dev/null)" && status=0 || status=$?
  actual_log="$(cat "$profile_home/profile.log")"
}

profile_expected_bashrc="bashrc|$profile_home/.local/bin:$profile_bin:/usr/bin:/bin"
profile_expected_startx="startx|$profile_home/.local/bin:$profile_bin:/usr/bin:/bin"
profile_attempts="$profile_home/.local/state/lightxdm/startx-attempts"

rm -rf "$profile_home/.config/lightxdm" "$profile_home/.local/state"
mkdir -p "${profile_attempts%/*}"
printf -v profile_now '%(%s)T' -1
printf '%s\n' "$((profile_now - 25))" "$((profile_now - 10))" "$((profile_now - 1))" >"$profile_attempts"
run_tty1_profile
pause_out_lines=()
if [[ -n "$output" ]]; then
  mapfile -t pause_out_lines <<<"$output"
fi
if [[ $status -eq 0 && "$actual_log" == "$profile_expected_bashrc" && ! -s "$profile_home/profile.err" ]] &&
  [[ -f "$profile_home/.config/lightxdm/no-autostart" && ! -s "$profile_attempts" ]] &&
  [[ ${#pause_out_lines[@]} -eq 2 && "${pause_out_lines[0]}" == *"paused"* &&
    "${pause_out_lines[0]}" == *"rm ~/.config/lightxdm/no-autostart"* && "${pause_out_lines[1]}" == "after|" ]]; then
  pass ".bash_profile pauses after three recent startx attempts, creates no-autostart, clears attempts, and loads .bashrc"
else
  fail ".bash_profile pause on three recent attempts (status=$status, log=$actual_log, output=$output, stderr=$(cat "$profile_home/profile.err"))"
fi

rm -f "$profile_home/.config/lightxdm/no-autostart"
run_tty1_profile
recorded_lines=()
if [[ -f "$profile_attempts" ]]; then
  mapfile -t recorded_lines <"$profile_attempts"
fi
if [[ $status -eq 0 && "$actual_log" == "$profile_expected_startx" && -z "$output" && ! -s "$profile_home/profile.err" ]] &&
  [[ ! -e "$profile_home/.config/lightxdm/no-autostart" && ${#recorded_lines[@]} -eq 1 ]]; then
  pass ".bash_profile resumes exec startx after removing no-autostart"
else
  fail ".bash_profile resume after removing no-autostart (status=$status, log=$actual_log, count=${#recorded_lines[@]}, output=$output, stderr=$(cat "$profile_home/profile.err"))"
fi

printf -v profile_now '%(%s)T' -1
printf '%s\n' "$((profile_now - 120))" "$((profile_now - 60))" "$((profile_now - 31))" >"$profile_attempts"
run_tty1_profile
recorded_lines=()
if [[ -f "$profile_attempts" ]]; then
  mapfile -t recorded_lines <"$profile_attempts"
fi
if [[ $status -eq 0 && "$actual_log" == "$profile_expected_startx" && -z "$output" && ! -s "$profile_home/profile.err" ]] &&
  [[ ! -e "$profile_home/.config/lightxdm/no-autostart" && ${#recorded_lines[@]} -eq 1 ]]; then
  pass ".bash_profile drops entries older than 30s and execs startx"
else
  fail ".bash_profile old attempts pruning (status=$status, log=$actual_log, count=${#recorded_lines[@]}, output=$output, stderr=$(cat "$profile_home/profile.err"))"
fi

# Entries from the future (the clock stepped back) are not recent attempts.
printf -v profile_now '%(%s)T' -1
printf '%s\n' "$((profile_now + 600))" "$((profile_now + 700))" "$((profile_now + 800))" >"$profile_attempts"
run_tty1_profile
if [[ $status -eq 0 && "$actual_log" == "$profile_expected_startx" && -z "$output" && ! -s "$profile_home/profile.err" ]] &&
  [[ ! -e "$profile_home/.config/lightxdm/no-autostart" ]]; then
  pass ".bash_profile ignores attempt times in the future and execs startx"
else
  fail ".bash_profile future attempts (status=$status, log=$actual_log, output=$output, stderr=$(cat "$profile_home/profile.err"))"
fi

printf -v profile_now '%(%s)T' -1
printf '%s\n' "$((profile_now - 90))" "$((profile_now - 31))" "$((profile_now - 12))" "$((profile_now - 3))" >"$profile_attempts"
run_tty1_profile
recorded_lines=()
if [[ -f "$profile_attempts" ]]; then
  mapfile -t recorded_lines <"$profile_attempts"
fi
if [[ $status -eq 0 && "$actual_log" == "$profile_expected_startx" && -z "$output" && ! -s "$profile_home/profile.err" ]] &&
  [[ ! -e "$profile_home/.config/lightxdm/no-autostart" && ${#recorded_lines[@]} -eq 3 ]]; then
  pass ".bash_profile keeps only the two recent entries plus the new launch without pausing"
else
  fail ".bash_profile mixed old and recent attempts (status=$status, log=$actual_log, count=${#recorded_lines[@]}, output=$output, stderr=$(cat "$profile_home/profile.err"))"
fi

rm -f "$profile_home/.config/lightxdm/no-autostart" "$profile_attempts"
rapid_launches_ok=1
for attempt_num in 1 2 3; do
  run_tty1_profile
  recorded_lines=()
  if [[ -f "$profile_attempts" ]]; then
    mapfile -t recorded_lines <"$profile_attempts"
  fi
  if [[ $status -ne 0 || "$actual_log" != "$profile_expected_startx" || -n "$output" || -s "$profile_home/profile.err" ||
    -e "$profile_home/.config/lightxdm/no-autostart" || ${#recorded_lines[@]} -ne $attempt_num ]]; then
    rapid_launches_ok=0
  fi
done
run_tty1_profile
if [[ $rapid_launches_ok -eq 1 && $status -eq 0 && "$actual_log" == "$profile_expected_bashrc" && ! -s "$profile_home/profile.err" ]] &&
  [[ -f "$profile_home/.config/lightxdm/no-autostart" && ! -s "$profile_attempts" &&
    "$output" == *"rm ~/.config/lightxdm/no-autostart"* ]]; then
  pass ".bash_profile launches startx three times then pauses on the fourth login"
else
  fail ".bash_profile four rapid logins (launches_ok=$rapid_launches_ok, status=$status, log=$actual_log, output=$output, stderr=$(cat "$profile_home/profile.err"))"
fi

custom_state_home="$TMP_DIR/bash_profile/xdg_state"
rm -rf "$profile_home/.config/lightxdm/no-autostart" "$profile_home/.local/state" "$custom_state_home"
mkdir -p "$custom_state_home/lightxdm"
printf -v profile_now '%(%s)T' -1
printf '%s\n' "$((profile_now - 8))" "$((profile_now - 4))" "$((profile_now - 1))" >"$custom_state_home/lightxdm/startx-attempts"
run_tty1_profile "$custom_state_home"
if [[ $status -eq 0 && "$actual_log" == "$profile_expected_bashrc" && ! -s "$profile_home/profile.err" ]] &&
  [[ -f "$profile_home/.config/lightxdm/no-autostart" && ! -s "$custom_state_home/lightxdm/startx-attempts" && ! -e "$profile_home/.local/state" ]]; then
  pass ".bash_profile uses XDG_STATE_HOME when set"
else
  fail ".bash_profile XDG_STATE_HOME (status=$status, log=$actual_log, output=$output, stderr=$(cat "$profile_home/profile.err"))"
fi

ro_state_home="$TMP_DIR/bash_profile/ro_state"
rm -f "$profile_home/.config/lightxdm/no-autostart"
mkdir -p "$ro_state_home/lightxdm"
chmod 555 "$ro_state_home" "$ro_state_home/lightxdm"
if [[ -w "$ro_state_home/lightxdm" ]]; then
  chmod 755 "$ro_state_home" "$ro_state_home/lightxdm"
  skip ".bash_profile unwritable state directory stays quiet and starts X (directory remains writable)"
else
  run_tty1_profile "$ro_state_home"
  ro_existing_ok=0
  if [[ $status -eq 0 && "$actual_log" == "$profile_expected_startx" && -z "$output" && ! -s "$profile_home/profile.err" &&
    ! -e "$ro_state_home/lightxdm/startx-attempts" ]]; then
    ro_existing_ok=1
  fi
  run_tty1_profile "$ro_state_home/missing"
  chmod 755 "$ro_state_home" "$ro_state_home/lightxdm"
  if [[ $ro_existing_ok -eq 1 && $status -eq 0 && "$actual_log" == "$profile_expected_startx" &&
    -z "$output" && ! -s "$profile_home/profile.err" ]]; then
    pass ".bash_profile stays quiet and starts X when the state directory cannot be written"
  else
    fail ".bash_profile unwritable state directory (existing_ok=$ro_existing_ok, status=$status, log=$actual_log, output=$output, stderr=$(cat "$profile_home/profile.err"))"
  fi
fi

# Case 59: polkit/49-nopasswd.rules grants YES only for the eight login1 power actions on local active seat0 wheel subjects
if ! command -v node >/dev/null 2>&1; then
  skip "polkit/49-nopasswd.rules grants and refusals (node unavailable)"
else
  cat >"$TMP_DIR/eval-polkit.js" <<'EOF'
const assert = require("node:assert");
const fs = require("node:fs");
const vm = require("node:vm");

const rulePath = process.argv[2];
const rules = [];
const polkit = {
  Result: { YES: "YES" },
  addRule(fn) {
    if (typeof fn !== "function") {
      throw new TypeError("addRule expects a function");
    }
    rules.push(fn);
  },
};

vm.runInNewContext(fs.readFileSync(rulePath, "utf8"), { polkit }, { filename: rulePath });
assert.ok(rules.length > 0, "expected at least one polkit.addRule() registration");

const evaluate = (id, subject) => {
  for (const fn of rules) {
    const res = fn({ id }, subject);
    if (res !== undefined) return res;
  }
  return undefined;
};

const makeSubject = (overrides = {}) => {
  const groups = overrides.groups ?? ["wheel"];
  return {
    local: true,
    active: true,
    seat: "seat0",
    ...overrides,
    groups,
    isInGroup(group) {
      return typeof group === "string" && groups.includes(group);
    },
  };
};

const powerActions = [
  "org.freedesktop.login1.power-off",
  "org.freedesktop.login1.power-off-multiple-sessions",
  "org.freedesktop.login1.reboot",
  "org.freedesktop.login1.reboot-multiple-sessions",
  "org.freedesktop.login1.suspend",
  "org.freedesktop.login1.suspend-multiple-sessions",
  "org.freedesktop.login1.hibernate",
  "org.freedesktop.login1.hibernate-multiple-sessions",
];

const refusedActions = [
  "org.freedesktop.policykit.exec",
  "org.freedesktop.udisks2.filesystem-mount",
  "org.freedesktop.udisks2.filesystem-mount-system",
  "org.freedesktop.login1.power-off-ignore-inhibit",
  "org.freedesktop.login1.reboot-ignore-inhibit",
  "org.freedesktop.login1.suspend-ignore-inhibit",
  "org.freedesktop.login1.hibernate-ignore-inhibit",
];

const qualifying = makeSubject();
for (const id of powerActions) {
  assert.strictEqual(evaluate(id, qualifying), "YES", `expected YES for ${id}`);
}

for (const id of refusedActions) {
  assert.strictEqual(evaluate(id, qualifying), undefined, `expected no result for ${id}`);
}

const negatedSubjects = [
  ["not-wheel", makeSubject({ groups: ["users"] })],
  ["not-local", makeSubject({ local: false })],
  ["not-active", makeSubject({ active: false })],
  ["not-seat0", makeSubject({ seat: "seat1" })],
];

for (const [label, subject] of negatedSubjects) {
  for (const id of powerActions) {
    assert.strictEqual(evaluate(id, subject), undefined, `expected no result for ${label} on ${id}`);
  }
}
EOF
  set +e
  output="$(node "$TMP_DIR/eval-polkit.js" "$REPO_ROOT/polkit/49-nopasswd.rules" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 ]]; then
    pass "polkit/49-nopasswd.rules grants YES only for the eight login1 power actions on qualifying subjects"
  else
    fail "polkit/49-nopasswd.rules evaluation (status=$status, output=$output)"
  fi
fi

# A custom id containing "i" is accepted under the Turkish locale too
if locale -a 2>/dev/null | grep -qi '^tr_TR\.utf-\?8$'; then
  cp "$custom_template_dir/dotfiles/.xinitrc-i3" "$custom_template_dir/dotfiles/.xinitrc-qtile"
  : >"$STUB_LOG"
  set +e
  output="$(
    # shellcheck disable=SC2034  # main uses SCRIPT_DIR from the sourced installer
    SCRIPT_DIR="$custom_template_dir"
    export LC_ALL=tr_TR.UTF-8
    run_main_with_stubs "$sudo_pw_dir" --no-packages --de qtile 2>&1
  )"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -eq 0 && "$log_content" == *"copy_dotfiles qtile"* ]]; then
    pass "main accepts custom id qtile under LC_ALL=tr_TR.UTF-8"
  else
    fail "main custom id under tr_TR (status=$status, log=$log_content, output=$output)"
  fi
else
  skip "main custom id under tr_TR (locale not installed)"
fi

# Case 60: uninstall.sh restores missing or dangling LOGIN_FILE from backup and finishes all steps
if [[ $EUID -eq 0 ]]; then
  ml_runner=(bash)
elif [[ $can_unshare -eq 1 ]]; then
  ml_runner=(unshare -r bash)
else
  ml_runner=()
fi
if [[ ${#ml_runner[@]} -eq 0 ]]; then
  skip "uninstall.sh restores missing or dangling LOGIN_FILE from backup (unshare -r unavailable)"
else
  for login_state in missing dangling; do
    ml_dir="$TMP_DIR/missing_login_${login_state}"
    ml_home="$ml_dir/home"
    ml_login="$ml_dir/login"
    ml_autologin="$ml_dir/lightxdm-autologin.conf"
    ml_polkit="$ml_dir/49-nopasswd.rules"
    ml_dm_state="$ml_dir/lightxdm/disabled-display-managers"
    mkdir -p "$ml_home" "$(dirname "$ml_dm_state")"
    (
      export HOME="$ml_home"
      export USER="${USER:-testuser}"
      copy_dotfiles "i3" 2>/dev/null
    )
    printf '#%%PAM-1.0\nauth       include      system-local-login\n' >"${ml_login}.lightxdm.bak"
    ml_backup_hash="$(sha256sum < "${ml_login}.lightxdm.bak")"
    if [[ "$login_state" == "dangling" ]]; then
      ln -s "$ml_dir/nonexistent_target" "$ml_login"
    fi
    # shellcheck disable=SC2016  # $TERM is literal in systemd drop-in
    printf '[Service]\nExecStart=\nExecStart=-/usr/bin/agetty --autologin testuser --noclear %%I $TERM\n' >"$ml_autologin"
    cp "$POLKIT_RULE_SRC" "$ml_polkit"
    printf 'sddm.service\n' >"$ml_dm_state"
    : >"$STUB_LOG"
    set +e
    output="$(env TARGET_HOME="$ml_home" LOGIN_FILE="$ml_login" AUTOLOGIN_DROPIN="$ml_autologin" OVERRIDE_FILE="$ml_dir/override.conf" POLKIT_RULE="$ml_polkit" DM_STATE_FILE="$ml_dm_state" "${ml_runner[@]}" "$REPO_ROOT/uninstall.sh" 2>&1)"
    status=$?
    set -e
    log_content="$(cat "$STUB_LOG")"
    if [[ $status -eq 0 && "$output" == *"Uninstall complete."* ]] &&
      [[ -f "$ml_login" && ! -L "$ml_login" && "$(sha256sum < "$ml_login")" == "$ml_backup_hash" ]] &&
      [[ ! -e "${ml_login}.lightxdm.bak" && ! -e "$ml_dir/nonexistent_target" ]] &&
      [[ ! -e "$ml_autologin" && ! -e "$ml_polkit" && ! -e "$ml_dm_state" ]] &&
      [[ ! -e "$ml_home/.bash_profile" && ! -e "$ml_home/.xinitrc" && ! -e "$ml_home/.gpg-agent-gnome" ]] &&
      [[ "$log_content" == *"systemctl daemon-reload"* && "$log_content" == *"systemctl enable sddm.service"* ]]; then
      pass "uninstall.sh restores $login_state LOGIN_FILE from backup and completes all cleanup steps"
    else
      fail "uninstall.sh $login_state LOGIN_FILE restore (status=$status, output=$output, log=$log_content)"
    fi
  done
fi

# --de followed by another flag prints usage instead of taking the flag as the id
for flag_after_de in --help --list-packages --no-packages --no-keyring --no-polkit-rule; do
  : >"$STUB_LOG"
  set +e
  output="$(run_main_with_stubs "$sudo_pw_dir" --de "$flag_after_de" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 1 && "$output" == *"Usage:"* && "$output" == *"Missing argument for --de"* && "$(cat "$STUB_LOG")" != *"sudo -v"* ]]; then
    pass "main --de $flag_after_de prints usage and exits 1"
  else
    fail "main --de $flag_after_de (status=$status, output=$output)"
  fi
done

# Quit in the desktop menu exits 0 without running any install step
: >"$STUB_LOG"
set +e
output="$(STUB_DETECTED_DE=unknown STUB_PROMPT_RC=2 run_main_with_stubs "$sudo_pw_dir" 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 0 && "$log_content" == *"prompt_de_selection"* && "$log_content" != *"install_packages"* && "$log_content" != *"copy_dotfiles"* && "$log_content" != *"configure_pam"* ]]; then
  pass "main exits 0 with no install step when Quit is chosen"
else
  fail "main Quit (status=$status, log=$log_content, output=$output)"
fi

# Case 61: install_packages and detect_de cover all nine desktops' package lists and detection pairs
expected_base_pkgs="xorg-server xorg-xinit udisks2 polkit gvfs gvfs-mtp gvfs-gphoto2 gvfs-afc"
de_pkg_specs=(
  "plasma|plasma-desktop|plasma-desktop konsole dolphin kwallet-pam polkit-kde-agent"
  "gnome|gnome-shell|gnome-shell gnome-session gnome-control-center nautilus gnome-terminal gnome-keyring polkit-gnome"
  "xfce|xfce4-session|xfce4 xfce4-session xfce4-terminal gnome-keyring polkit-gnome"
  "lxqt|lxqt-session|lxqt xdg-utils lxterminal gnome-keyring lxqt-policykit"
  "lxde|lxde-common|lxde-common lxsession lxpanel openbox pcmanfm lxterminal gnome-keyring polkit-gnome"
  "mate|mate-session-manager|mate mate-terminal gnome-keyring polkit-gnome"
  "cinnamon|cinnamon|cinnamon gnome-terminal gnome-keyring polkit-gnome"
  "budgie|budgie-desktop|budgie-desktop gnome-terminal gnome-keyring polkit-gnome"
  "i3|i3-wm|i3 xterm dex gnome-keyring polkit-gnome"
)

detect_pair_bin="$TMP_DIR/pacman_detect_pair"
mkdir -p "$detect_pair_bin"
cat >"$detect_pair_bin/pacman" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-Qq" && $# -eq 2 && "$2" == "${STUB_DETECT_PKG:-}" ]]; then
  echo "$2"
  exit 0
fi
exit 1
EOF
chmod +x "$detect_pair_bin/pacman"

for spec in "${de_pkg_specs[@]}"; do
  IFS='|' read -r de detect_pkg de_pkgs <<<"$spec"

  : >"$STUB_LOG"
  set +e
  output="$(install_packages "$de" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  expected_pacman_log="pacman -S --needed --noconfirm $expected_base_pkgs $de_pkgs"
  if [[ $status -eq 0 && "$log_content" == "$expected_pacman_log" ]]; then
    pass "install_packages installs base and $de packages"
  else
    fail "install_packages $de (status=$status, log=$log_content, expected=$expected_pacman_log, output=$output)"
  fi

  set +e
  output="$(
    set -e
    export PATH="$detect_pair_bin:$PATH"
    export STUB_DETECT_PKG="$detect_pkg"
    detect_de
  )"
  status=$?
  set -e
  if [[ $status -eq 0 && "$output" == "$de" ]]; then
    pass "detect_de maps $detect_pkg to $de"
  else
    fail "detect_de $detect_pkg -> $de (status=$status, output=$output)"
  fi
done

# Case 62: --no-keyring skips configure_pam and omits gnome-keyring and kwallet-pam from packages
help_no_keyring_out="$(HOME="$help_home" bash "$REPO_ROOT/install.sh" --help 2>&1)"
if [[ "$help_no_keyring_out" == *"--no-keyring"* ]]; then
  pass "install.sh --help documents --no-keyring"
else
  fail "install.sh --help missing --no-keyring (output=$help_no_keyring_out)"
fi

for spec in "${de_pkg_specs[@]}"; do
  IFS='|' read -r de _ de_pkgs <<<"$spec"
  expected_no_kr_pkgs=()
  for pkg in $de_pkgs; do
    case "$pkg" in
      gnome-keyring | kwallet-pam) ;;
      *) expected_no_kr_pkgs+=("$pkg") ;;
    esac
  done
  expected_no_kr_log="pacman -S --needed --noconfirm $expected_base_pkgs ${expected_no_kr_pkgs[*]}"

  : >"$STUB_LOG"
  set +e
  output="$(install_packages "$de" --no-keyring 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -eq 0 && "$log_content" == "$expected_no_kr_log" ]] &&
    [[ "$log_content" != *"gnome-keyring"* && "$log_content" != *"kwallet-pam"* ]]; then
    pass "install_packages $de --no-keyring omits keyring packages"
  else
    fail "install_packages $de --no-keyring (status=$status, log=$log_content, expected=$expected_no_kr_log, output=$output)"
  fi
done

no_kr_specs=(
  "detected-i3|i3|--no-keyring|i3 xterm dex polkit-gnome|.gpg-agent-gnome"
  "de-lxqt|lxqt|--no-keyring --de lxqt|lxqt xdg-utils lxterminal lxqt-policykit|.gpg-agent-gnome"
  "de-first-xfce|xfce|--de xfce --no-keyring|xfce4 xfce4-session xfce4-terminal polkit-gnome|.gpg-agent-gnome"
)
for spec in "${no_kr_specs[@]}"; do
  IFS='|' read -r label exp_de flag_str exp_de_pkgs exp_gpg_file <<<"$spec"
  read -r -a no_kr_args <<<"$flag_str"
  no_kr_home="$TMP_DIR/home_no_kr_${label}"
  mkdir -p "$no_kr_home"
  rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak" "$POLKIT_RULE_DEST" "${POLKIT_RULE_DEST}.lightxdm.bak" "${POLKIT_RULE_DEST}.lightxdm.absent"
  write_stock_login
  stock_kr_hash="$(sha256sum < "$LOGIN_FILE")"
  : >"$STUB_LOG"
  set +e
  output="$(
    export HOME="$no_kr_home"
    export PATH="$sudo_pw_dir:$STUB_BIN:$PATH"
    export USER="testuser"
    unset SUDO_USER
    # shellcheck disable=SC2317,SC2329
    detect_de() { echo "i3"; }
    # shellcheck disable=SC2317,SC2329
    configure_pam() { echo "configure_pam $*" >>"$STUB_LOG"; }
    main "${no_kr_args[@]}" 2>&1
  )"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  expected_kr_pacman="pacman -S --needed --noconfirm $expected_base_pkgs $exp_de_pkgs"
  if [[ $status -eq 0 ]] &&
    [[ "$log_content" != *"configure_pam"* ]] &&
    [[ "$log_content" != *"gnome-keyring"* && "$log_content" != *"kwallet-pam"* ]] &&
    grep -Fxq -- "$expected_kr_pacman" "$STUB_LOG" &&
    grep -Fxq -- "sudo -v" "$STUB_LOG" &&
    grep -Fq -- "systemctl list-unit-files" "$STUB_LOG" &&
    [[ "$(sha256sum < "$LOGIN_FILE")" == "$stock_kr_hash" && ! -e "${LOGIN_FILE}.lightxdm.bak" ]] &&
    [[ -f "$no_kr_home/.bash_profile" && -f "$no_kr_home/.xinitrc" && -f "$no_kr_home/$exp_gpg_file" ]] &&
    [[ "$(sha256sum < "$no_kr_home/.xinitrc")" == "$(sha256sum < "$REPO_ROOT/dotfiles/.xinitrc-$exp_de")" ]] &&
    [[ -f "$POLKIT_RULE_DEST" && "$(sha256sum < "$POLKIT_RULE_DEST")" == "$(sha256sum < "$POLKIT_RULE_SRC")" ]]; then
    pass "main $flag_str skips configure_pam, omits keyring packages, and completes remaining setup"
  else
    fail "main $flag_str (status=$status, log=$log_content, output=$output)"
  fi
done

no_kr_custom_dir="$TMP_DIR/no_kr_custom"
mkdir -p "$no_kr_custom_dir"
cp -r "$REPO_ROOT/dotfiles" "$REPO_ROOT/polkit" "$no_kr_custom_dir/"
cp "$no_kr_custom_dir/dotfiles/.xinitrc-i3" "$no_kr_custom_dir/dotfiles/.xinitrc-dwm"

for combo_spec in \
  "detected|--no-keyring --no-packages|i3" \
  "custom-np-first|--no-packages --no-keyring --de dwm|dwm" \
  "custom-de-first|--de dwm --no-keyring --no-packages|dwm"; do
  IFS='|' read -r combo_label combo_flags combo_de <<<"$combo_spec"
  read -r -a combo_args <<<"$combo_flags"
  combo_home="$TMP_DIR/home_no_kr_combo_${combo_label}"
  mkdir -p "$combo_home"
  rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak" "$POLKIT_RULE_DEST" "${POLKIT_RULE_DEST}.lightxdm.bak" "${POLKIT_RULE_DEST}.lightxdm.absent"
  write_stock_login
  stock_combo_hash="$(sha256sum < "$LOGIN_FILE")"
  : >"$STUB_LOG"
  set +e
  output="$(
    # shellcheck disable=SC2034  # main uses SCRIPT_DIR from the sourced installer
    SCRIPT_DIR="$no_kr_custom_dir"
    export HOME="$combo_home"
    export PATH="$sudo_pw_dir:$STUB_BIN:$PATH"
    export USER="testuser"
    unset SUDO_USER
    # shellcheck disable=SC2317,SC2329
    detect_de() { echo "i3"; }
    # shellcheck disable=SC2317,SC2329
    configure_pam() { echo "configure_pam $*" >>"$STUB_LOG"; }
    main "${combo_args[@]}" 2>&1
  )"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -eq 0 ]] &&
    [[ "$log_content" != *"configure_pam"* && "$log_content" != *"pacman"* ]] &&
    [[ "$log_content" != *"gnome-keyring"* && "$log_content" != *"kwallet-pam"* ]] &&
    grep -Fxq -- "sudo -v" "$STUB_LOG" &&
    grep -Fq -- "systemctl list-unit-files" "$STUB_LOG" &&
    [[ "$(sha256sum < "$LOGIN_FILE")" == "$stock_combo_hash" && ! -e "${LOGIN_FILE}.lightxdm.bak" ]] &&
    [[ -f "$combo_home/.bash_profile" && -f "$combo_home/.xinitrc" ]] &&
    [[ "$(sha256sum < "$combo_home/.xinitrc")" == "$(sha256sum < "$no_kr_custom_dir/dotfiles/.xinitrc-$combo_de")" ]] &&
    [[ -f "$POLKIT_RULE_DEST" && "$(sha256sum < "$POLKIT_RULE_DEST")" == "$(sha256sum < "$POLKIT_RULE_SRC")" ]]; then
    pass "main $combo_flags skips packages and configure_pam while configuring $combo_de"
  else
    fail "main $combo_flags (status=$status, log=$log_content, output=$output)"
  fi
done

: >"$STUB_LOG"
set +e
output="$(
  # shellcheck disable=SC2034  # main uses SCRIPT_DIR from the sourced installer
  SCRIPT_DIR="$no_kr_custom_dir"
  run_main_with_stubs "$sudo_pw_dir" --no-keyring --de dwm 2>&1
)"
status=$?
set -e
if [[ $status -eq 1 && "$output" == *"Unsupported desktop environment: dwm"* && ! -s "$STUB_LOG" ]]; then
  pass "main --no-keyring --de dwm still requires --no-packages for custom sessions"
else
  fail "main --no-keyring --de dwm without --no-packages (status=$status, log=$(cat "$STUB_LOG"), output=$output)"
fi

# Case 63: a failing pacman run stops main before dotfiles, PAM, Polkit, or display managers
for fail_pkg_flag in "" "--no-keyring"; do
  fail_pkg_args=(--de i3)
  if [[ -n "$fail_pkg_flag" ]]; then
    fail_pkg_args+=("$fail_pkg_flag")
  fi
  fail_pkg_home="$TMP_DIR/home_fail_pkg${fail_pkg_flag:+_no_kr}"
  mkdir -p "$fail_pkg_home"
  : >"$STUB_LOG"
  set +e
  # shellcheck disable=SC2016  # expand inside the child shell so install.sh owns errexit
  output="$(
    env -u SHELLOPTS -u SUDO_USER \
      HOME="$fail_pkg_home" \
      PATH="$sudo_pw_dir:$STUB_BIN:$PATH" \
      STUB_PACMAN_EXIT=1 \
      USER="testuser" \
      bash -c '
        source "$1/install.sh"
        copy_dotfiles() { echo "copy_dotfiles $*" >>"$STUB_LOG"; }
        configure_pam() { echo "configure_pam $*" >>"$STUB_LOG"; }
        install_polkit_rule() { echo "install_polkit_rule" >>"$STUB_LOG"; }
        disable_display_managers() { echo "disable_display_managers" >>"$STUB_LOG"; }
        shift
        main "$@"
      ' bash "$REPO_ROOT" "${fail_pkg_args[@]}" 2>&1
  )"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -ne 0 ]] &&
    grep -Fxq -- "sudo -v" "$STUB_LOG" &&
    grep -Fq -- "pacman -S --needed --noconfirm" "$STUB_LOG" &&
    [[ "$log_content" != *"copy_dotfiles"* ]] &&
    [[ "$log_content" != *"configure_pam"* ]] &&
    [[ "$log_content" != *"install_polkit_rule"* ]] &&
    [[ "$log_content" != *"disable_display_managers"* ]] &&
    [[ "$output" == *"$recovery_hint"* && "$output" != *"lightXDM install complete!"* ]] &&
    grep -Fxq '=> Install stopped during install_packages; already done: none' <<<"$output"; then
    pass "main ${fail_pkg_args[*]} stops on pacman failure before dotfiles, PAM, Polkit, or display managers"
  else
    fail "main ${fail_pkg_args[*]} on pacman failure (status=$status, log=$log_content, output=$output)"
  fi
done

# Case 64: --no-polkit-rule skips install_polkit_rule and leaves Polkit untouched, while omitting it calls install_polkit_rule
help_no_polkit_out="$(HOME="$help_home" bash "$REPO_ROOT/install.sh" --help 2>&1)"
if [[ "$help_no_polkit_out" == *"--no-polkit-rule"* ]]; then
  pass "install.sh --help documents --no-polkit-rule"
else
  fail "install.sh --help missing --no-polkit-rule (output=$help_no_polkit_out)"
fi

for default_polkit_spec in \
  "default||Auto-unlock and Polkit rules are set" \
  "de-lxqt|--de lxqt|Auto-unlock and Polkit rules are set" \
  "no-packages|--no-packages|Auto-unlock and Polkit rules are set" \
  "no-keyring|--no-keyring|Polkit rules are set (keyring setup skipped)"; do
  IFS='|' read -r dp_label dp_flags dp_summary <<<"$default_polkit_spec"
  dp_args=()
  if [[ -n "$dp_flags" ]]; then
    read -r -a dp_args <<<"$dp_flags"
  fi
  : >"$STUB_LOG"
  set +e
  output="$(USER=testuser run_main_with_stubs "$bash_stub_dir:$sudo_pw_dir" "${dp_args[@]}" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -eq 0 ]] &&
    grep -Fxq -- "install_polkit_rule" "$STUB_LOG" &&
    [[ "$output" != *"Skipping Polkit rule"* && "$output" == *"- $dp_summary"* ]]; then
    pass "main ${dp_flags:-<default>} calls install_polkit_rule and reports '$dp_summary'"
  else
    fail "main ${dp_label} Polkit default (status=$status, log=$log_content, output=$output)"
  fi
done

for skip_polkit_spec in \
  "alone|--no-polkit-rule|i3|1|1|Auto-unlock is set (Polkit rule skipped)" \
  "with-de|--no-polkit-rule --de lxqt|lxqt|1|1|Auto-unlock is set (Polkit rule skipped)" \
  "de-first|--de xfce --no-polkit-rule|xfce|1|1|Auto-unlock is set (Polkit rule skipped)" \
  "no-packages|--no-packages --no-polkit-rule|i3|0|1|Auto-unlock is set (Polkit rule skipped)" \
  "no-keyring|--no-keyring --no-polkit-rule|i3|1|0|Keyring setup and Polkit rule skipped" \
  "all-flags|--de dwm --no-polkit-rule --no-keyring --no-packages|dwm|0|0|Keyring setup and Polkit rule skipped"; do
  IFS='|' read -r sp_label sp_flags sp_de sp_expect_pkg sp_expect_pam sp_summary <<<"$skip_polkit_spec"
  read -r -a sp_args <<<"$sp_flags"
  : >"$STUB_LOG"
  set +e
  output="$(
    # shellcheck disable=SC2034  # main uses SCRIPT_DIR from the sourced installer
    SCRIPT_DIR="$no_kr_custom_dir"
    USER=testuser run_main_with_stubs "$bash_stub_dir:$sudo_pw_dir" "${sp_args[@]}" 2>&1
  )"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  pkg_ok=0
  if [[ $sp_expect_pkg -eq 1 && "$log_content" == *"install_packages $sp_de"* ]] ||
    [[ $sp_expect_pkg -eq 0 && "$log_content" != *"install_packages"* ]]; then
    pkg_ok=1
  fi
  pam_ok=0
  if [[ $sp_expect_pam -eq 1 && "$log_content" == *"configure_pam $sp_de"* ]] ||
    [[ $sp_expect_pam -eq 0 && "$log_content" != *"configure_pam"* ]]; then
    pam_ok=1
  fi
  if [[ $status -eq 0 && $pkg_ok -eq 1 && $pam_ok -eq 1 ]] &&
    ! grep -Fxq -- "install_polkit_rule" "$STUB_LOG" &&
    grep -Fxq -- "copy_dotfiles $sp_de" "$STUB_LOG" &&
    grep -Fxq -- "disable_display_managers" "$STUB_LOG" &&
    [[ "$output" == *"Skipping Polkit rule installation (--no-polkit-rule)."* ]] &&
    [[ "$output" == *"- $sp_summary"* && "$output" != *"Polkit rules are set"* ]]; then
    pass "main $sp_flags skips install_polkit_rule and reports '$sp_summary'"
  else
    fail "main $sp_label ($sp_flags, status=$status, log=$log_content, output=$output)"
  fi
done

: >"$STUB_LOG"
set +e
out_zsh_nopolkit="$(USER=testuser run_main_with_stubs "$zsh_stub_dir:$sudo_pw_dir" --no-packages --no-polkit-rule --de i3 2>&1)"
st_zsh_nopolkit=$?
set -e
if [[ $st_zsh_nopolkit -eq 0 ]] &&
  ! grep -Fxq -- "install_polkit_rule" "$STUB_LOG" &&
  [[ "$out_zsh_nopolkit" == *"- Auto-unlock is set (Polkit rule skipped)"* && "$out_zsh_nopolkit" != *"Polkit rules are set"* ]]; then
  pass "main --no-polkit-rule adjusts closing summary for non-bash login shells too"
else
  fail "main --no-polkit-rule non-bash summary (status=$st_zsh_nopolkit, output=$out_zsh_nopolkit)"
fi

: >"$STUB_LOG"
set +e
output="$(
  # shellcheck disable=SC2034  # main uses SCRIPT_DIR from the sourced installer
  SCRIPT_DIR="$no_kr_custom_dir"
  run_main_with_stubs "$sudo_pw_dir" --no-polkit-rule --de dwm 2>&1
)"
status=$?
set -e
if [[ $status -eq 1 && "$output" == *"Unsupported desktop environment: dwm"* && ! -s "$STUB_LOG" ]]; then
  pass "main --no-polkit-rule --de dwm still requires --no-packages for custom sessions"
else
  fail "main --no-polkit-rule --de dwm without --no-packages (status=$status, log=$(cat "$STUB_LOG"), output=$output)"
fi

no_polkit_fs_home="$TMP_DIR/home_no_polkit_fs"
mkdir -p "$no_polkit_fs_home"
rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak" "$POLKIT_RULE_DEST" "${POLKIT_RULE_DEST}.lightxdm.bak" "${POLKIT_RULE_DEST}.lightxdm.absent" "${POLKIT_RULE_DEST}.lightxdm-edited"
write_stock_login
: >"$STUB_LOG"
set +e
output="$(
  export HOME="$no_polkit_fs_home"
  export PATH="$sudo_pw_dir:$STUB_BIN:$PATH"
  export USER="testuser"
  unset SUDO_USER
  main --no-packages --no-polkit-rule --de i3 2>&1
)"
status=$?
set -e
if [[ $status -eq 0 && ! -e "$POLKIT_RULE_DEST" && ! -L "$POLKIT_RULE_DEST" &&
  ! -e "${POLKIT_RULE_DEST}.lightxdm.bak" && ! -e "${POLKIT_RULE_DEST}.lightxdm.absent" ]]; then
  pass "main --no-polkit-rule creates no Polkit rule or marker when none existed"
else
  fail "main --no-polkit-rule on absent Polkit rule (status=$status, output=$output)"
fi

printf '// custom user polkit policy\n' >"$POLKIT_RULE_DEST"
custom_polkit_hash="$(sha256sum < "$POLKIT_RULE_DEST")"
set +e
output="$(
  # shellcheck disable=SC2034  # main uses SCRIPT_DIR from the sourced installer
  SCRIPT_DIR="$no_kr_custom_dir"
  export HOME="$no_polkit_fs_home"
  export PATH="$sudo_pw_dir:$STUB_BIN:$PATH"
  export USER="testuser"
  unset SUDO_USER
  main --no-packages --no-keyring --no-polkit-rule --de dwm 2>&1
)"
status=$?
set -e
if [[ $status -eq 0 && -f "$POLKIT_RULE_DEST" &&
  "$(sha256sum < "$POLKIT_RULE_DEST")" == "$custom_polkit_hash" &&
  ! -e "${POLKIT_RULE_DEST}.lightxdm.bak" && ! -e "${POLKIT_RULE_DEST}.lightxdm.absent" &&
  ! -e "${POLKIT_RULE_DEST}.lightxdm-edited" ]]; then
  pass "main --no-polkit-rule leaves an existing Polkit rule untouched without backups"
else
  fail "main --no-polkit-rule with existing Polkit rule (status=$status, output=$output)"
fi

set +e
output="$(
  export HOME="$no_polkit_fs_home"
  export PATH="$sudo_pw_dir:$STUB_BIN:$PATH"
  export USER="testuser"
  unset SUDO_USER
  main --no-packages --de i3 2>&1
)"
status=$?
set -e
if [[ $status -eq 0 && -f "$POLKIT_RULE_DEST" && -f "${POLKIT_RULE_DEST}.lightxdm.bak" &&
  "$(sha256sum < "$POLKIT_RULE_DEST")" == "$(sha256sum < "$POLKIT_RULE_SRC")" &&
  "$(sha256sum < "${POLKIT_RULE_DEST}.lightxdm.bak")" == "$custom_polkit_hash" ]]; then
  pass "main without --no-polkit-rule backs up the existing rule and installs 49-nopasswd.rules"
else
  fail "main default Polkit install after --no-polkit-rule (status=$status, output=$output)"
fi

# Case 65: a failing dotfile backup or edit-save copy stops copy_dotfiles before overwriting ~/.bash_profile
fail_cp_home="$TMP_DIR/home_fail_cp"
fail_cp_bin="$TMP_DIR/bin_fail_cp"
mkdir -p "$fail_cp_home" "$fail_cp_bin"
printf '# user custom bash_profile\nexport EDITOR=vim\n' >"$fail_cp_home/.bash_profile"
fail_cp_hash="$(sha256sum < "$fail_cp_home/.bash_profile")"
cat >"$fail_cp_bin/cp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$fail_cp_bin/cp"
set +e
# shellcheck disable=SC2016  # expand inside the child shell so install.sh owns errexit
output="$(
  env -u SHELLOPTS -u SUDO_USER \
    HOME="$fail_cp_home" \
    PATH="$fail_cp_bin:$sudo_pw_dir:$STUB_BIN:$PATH" \
    USER="testuser" \
    bash -c '
      source "$1/install.sh"
      check_root() { :; }
      install_packages() { :; }
      configure_pam() { :; }
      install_polkit_rule() { :; }
      disable_display_managers() { :; }
      main --de i3
    ' bash "$REPO_ROOT" 2>&1
)"
status=$?
set -e
if [[ $status -ne 0 && "$output" == *"$recovery_hint"* && "$output" != *"lightXDM install complete!"* ]] &&
  grep -Fxq '=> Install stopped during copy_dotfiles; already done: install_packages' <<<"$output" &&
  [[ -f "$fail_cp_home/.bash_profile" && ! -L "$fail_cp_home/.bash_profile" ]] &&
  [[ "$(sha256sum < "$fail_cp_home/.bash_profile")" == "$fail_cp_hash" ]] &&
  [[ ! -e "$fail_cp_home/.bash_profile.lightxdm.bak" && ! -L "$fail_cp_home/.bash_profile.lightxdm.bak" ]] &&
  [[ ! -e "$fail_cp_home/.bash_profile.lightxdm.absent" && ! -e "$fail_cp_home/.bash_profile.lightxdm-edited" ]] &&
  [[ ! -e "$fail_cp_home/.gpg-agent-gnome" && ! -e "$fail_cp_home/.xinitrc" ]]; then
  pass "copy_dotfiles aborts on failed backup without overwriting ~/.bash_profile"
else
  fail "copy_dotfiles on failed backup (status=$status, output=$output)"
fi

fail_cp_edit_home="$TMP_DIR/home_fail_cp_edited"
mkdir -p "$fail_cp_edit_home"
printf '# original skel bash_profile\n' >"$fail_cp_edit_home/.bash_profile.lightxdm.bak"
fail_cp_bak_hash="$(sha256sum < "$fail_cp_edit_home/.bash_profile.lightxdm.bak")"
printf '# post-install user edit\nexport EDITOR=nvim\n' >"$fail_cp_edit_home/.bash_profile"
fail_cp_edit_hash="$(sha256sum < "$fail_cp_edit_home/.bash_profile")"
set +e
# shellcheck disable=SC2016  # expand inside the child shell so install.sh owns errexit
output="$(
  env -u SHELLOPTS -u SUDO_USER \
    HOME="$fail_cp_edit_home" \
    PATH="$fail_cp_bin:$STUB_BIN:$PATH" \
    USER="testuser" \
    bash -c '
      source "$1/install.sh"
      copy_dotfiles "i3"
    ' bash "$REPO_ROOT" 2>&1
)"
status=$?
set -e
if [[ $status -ne 0 ]] &&
  [[ -f "$fail_cp_edit_home/.bash_profile" && ! -L "$fail_cp_edit_home/.bash_profile" ]] &&
  [[ "$(sha256sum < "$fail_cp_edit_home/.bash_profile")" == "$fail_cp_edit_hash" ]] &&
  [[ -f "$fail_cp_edit_home/.bash_profile.lightxdm.bak" && ! -L "$fail_cp_edit_home/.bash_profile.lightxdm.bak" ]] &&
  [[ "$(sha256sum < "$fail_cp_edit_home/.bash_profile.lightxdm.bak")" == "$fail_cp_bak_hash" ]] &&
  [[ ! -e "$fail_cp_edit_home/.bash_profile.lightxdm.absent" && ! -L "$fail_cp_edit_home/.bash_profile.lightxdm.absent" ]] &&
  [[ ! -e "$fail_cp_edit_home/.bash_profile.lightxdm-edited" && ! -L "$fail_cp_edit_home/.bash_profile.lightxdm-edited" ]] &&
  [[ ! -e "$fail_cp_edit_home/.gpg-agent-gnome" && ! -e "$fail_cp_edit_home/.xinitrc" ]]; then
  pass "copy_dotfiles aborts on failed edit save without overwriting ~/.bash_profile"
else
  fail "copy_dotfiles on failed edit save (status=$status, output=$output)"
fi

# Case 66: reload failures are tolerated only when systemd is not running
if [[ $EUID -eq 0 ]]; then
  reload_runner=(bash)
elif [[ $can_unshare -eq 1 ]]; then
  reload_runner=(unshare -r bash)
else
  reload_runner=()
fi
if [[ ${#reload_runner[@]} -eq 0 ]]; then
  skip "daemon-reload failure handling (unshare -r unavailable)"
else
  reload_bin="$TMP_DIR/reload_bin"
  mkdir -p "$reload_bin"
  cat >"$reload_bin/getent" <<'EOF'
#!/usr/bin/env bash
echo 'testuser:x:1000:1000::/home/testuser:/bin/bash'
EOF
  chmod +x "$reload_bin/getent"
  for systemd_state in missing running; do
    reload_dir="$TMP_DIR/reload_$systemd_state"
    mkdir -p "$reload_dir/home" "$reload_dir/getty.d" "$reload_dir/state"
    if [[ "$systemd_state" == running ]]; then
      mkdir -p "$reload_dir/run"
    fi
    printf 'auth optional pam_gnome_keyring.so\n' >"$reload_dir/login"
    for autologin_action in testuser --disable; do
      printf '[Service]\n' >"$reload_dir/getty.d/lightxdm-autologin.conf"
      : >"$STUB_LOG"
      set +e
      output="$(env PATH="$reload_bin:$PATH" STUB_SYSTEMCTL_FAIL_RELOAD=1 SYSTEMD_RUN_DIR="$reload_dir/run" OVERRIDE_DIR="$reload_dir/getty.d" LOGIN_FILE="$reload_dir/login" "${reload_runner[@]}" "$REPO_ROOT/enable-autologin.sh" "$autologin_action" 2>&1)"
      status=$?
      set -e
      log_content="$(cat "$STUB_LOG")"
      if [[ "$autologin_action" == testuser ]]; then
        completion_message="Autologin enabled for user testuser"
        autologin_changed=0
        if grep -Fq -- '--autologin testuser ' "$reload_dir/getty.d/lightxdm-autologin.conf"; then
          autologin_changed=1
        fi
      else
        completion_message="Autologin disabled."
        autologin_changed=0
        if [[ ! -e "$reload_dir/getty.d/lightxdm-autologin.conf" ]]; then
          autologin_changed=1
        fi
      fi
      if [[ $autologin_changed -eq 1 && "$log_content" == "systemctl daemon-reload" ]] &&
        { { [[ "$systemd_state" == missing && $status -eq 0 && "$output" == *"$completion_message"* ]] &&
            [[ "$autologin_action" == --disable || "$output" == *"Warning: PAM keyring unlock"* ]]; } ||
          [[ "$systemd_state" == running && $status -ne 0 && "$output" != *"$completion_message"* && "$output" != *"Warning: PAM keyring unlock"* ]]; }; then
        pass "enable-autologin.sh $autologin_action handles reload failure with systemd $systemd_state"
      else
        fail "enable-autologin.sh reload failure (action=$autologin_action, systemd=$systemd_state, status=$status, output=$output, log=$log_content)"
      fi
    done

    printf '[Service]\n' >"$reload_dir/getty.d/lightxdm-autologin.conf"
    cp "$POLKIT_RULE_SRC" "$reload_dir/polkit"
    printf '// original rule\n' >"$reload_dir/polkit.lightxdm.bak"
    cp "$REPO_ROOT/dotfiles/.bash_profile" "$reload_dir/home/.bash_profile"
    printf '# original profile\n' >"$reload_dir/home/.bash_profile.lightxdm.bak"
    printf 'sddm.service\n' >"$reload_dir/state/disabled-display-managers"
    : >"$STUB_LOG"
    set +e
    output="$(env STUB_SYSTEMCTL_FAIL_RELOAD=1 SYSTEMD_RUN_DIR="$reload_dir/run" TARGET_HOME="$reload_dir/home" LOGIN_FILE="$reload_dir/login" AUTOLOGIN_DROPIN="$reload_dir/getty.d/lightxdm-autologin.conf" OVERRIDE_FILE="$reload_dir/getty.d/override.conf" POLKIT_RULE="$reload_dir/polkit" DM_STATE_FILE="$reload_dir/state/disabled-display-managers" "${reload_runner[@]}" "$REPO_ROOT/uninstall.sh" 2>&1)"
    status=$?
    set -e
    log_content="$(cat "$STUB_LOG")"
    if [[ ! -e "$reload_dir/getty.d/lightxdm-autologin.conf" && "$log_content" == *"systemctl daemon-reload"* ]] &&
      { [[ "$systemd_state" == missing && $status -eq 0 && "$output" == *"Uninstall complete."* &&
           "$(cat "$reload_dir/polkit")" == '// original rule' &&
           "$(cat "$reload_dir/home/.bash_profile")" == '# original profile' &&
           ! -e "$reload_dir/polkit.lightxdm.bak" && ! -e "$reload_dir/home/.bash_profile.lightxdm.bak" &&
           ! -e "$reload_dir/state/disabled-display-managers" && "$log_content" == *"systemctl enable sddm.service"* ]] ||
        [[ "$systemd_state" == running && $status -ne 0 && "$output" != *"Uninstall complete."* &&
           -f "$reload_dir/polkit.lightxdm.bak" && -f "$reload_dir/home/.bash_profile.lightxdm.bak" &&
           -f "$reload_dir/state/disabled-display-managers" && "$log_content" != *"systemctl enable"* ]]; }; then
      pass "uninstall.sh handles reload failure with systemd $systemd_state"
    else
      fail "uninstall.sh reload failure (systemd=$systemd_state, status=$status, output=$output, log=$log_content)"
    fi
  done
fi

# Case 67: a failing backup copy stops configure_pam and install_polkit_rule before modifying targets
fail_sys_cp_dir="$TMP_DIR/sys_fail_cp"
mkdir -p "$fail_sys_cp_dir"
fail_pam_login="$fail_sys_cp_dir/login"
printf '#%%PAM-1.0\nauth       include      system-local-login\nsession    include      system-local-login\n' >"$fail_pam_login"
fail_pam_hash="$(sha256sum < "$fail_pam_login")"
set +e
# shellcheck disable=SC2016  # expand inside the child shell so install.sh owns errexit
output="$(
  env -u SHELLOPTS -u SUDO_USER \
    LOGIN_FILE="$fail_pam_login" \
    PATH="$fail_cp_bin:$STUB_BIN:$PATH" \
    bash -c '
      source "$1/install.sh"
      configure_pam "i3"
    ' bash "$REPO_ROOT" 2>&1
)"
status=$?
set -e
if [[ $status -ne 0 ]] &&
  [[ -f "$fail_pam_login" && ! -L "$fail_pam_login" ]] &&
  [[ "$(sha256sum < "$fail_pam_login")" == "$fail_pam_hash" ]] &&
  [[ ! -e "${fail_pam_login}.lightxdm.bak" && ! -L "${fail_pam_login}.lightxdm.bak" ]]; then
  pass "configure_pam aborts on failed backup without modifying LOGIN_FILE"
else
  fail "configure_pam on failed backup (status=$status, output=$output)"
fi

# configure_pam warns when a tty1 autologin drop-in is active, and stays quiet without one
autologin_pam_dir="$TMP_DIR/autologin_pam"
mkdir -p "$autologin_pam_dir/getty.d"
printf '#%%PAM-1.0\nauth       include      system-local-login\n' >"$autologin_pam_dir/login"
for autologin_pam_case in without with; do
  if [[ "$autologin_pam_case" == with ]]; then
    # shellcheck disable=SC2016  # $TERM is literal systemd syntax
    printf '[Service]\nExecStart=\nExecStart=-/usr/bin/agetty --autologin someone --noclear %%I $TERM\n' >"$autologin_pam_dir/getty.d/lightxdm-autologin.conf"
  fi
  set +e
  # shellcheck disable=SC2016  # expand inside the child shell so install.sh owns errexit
  output="$(
    env -u SHELLOPTS -u SUDO_USER \
      LOGIN_FILE="$autologin_pam_dir/login" \
      AUTOLOGIN_DROPIN_DIR="$autologin_pam_dir/getty.d" \
      PATH="$STUB_BIN:$PATH" \
      bash -c '
        source "$1/install.sh"
        configure_pam "i3"
      ' bash "$REPO_ROOT" 2>&1
  )"
  status=$?
  set -e
  if [[ $status -eq 0 ]] && {
    [[ "$autologin_pam_case" == with && "$output" == *"TTY1 autologin is enabled"* && "$output" == *"enable-autologin.sh --disable"* &&
      "$output" == *"sudo bash uninstall.sh --keyring-only"* ]] ||
    [[ "$autologin_pam_case" == without && "$output" != *"TTY1 autologin is enabled"* ]];
  }; then
    pass "configure_pam autologin warning ($autologin_pam_case autologin drop-in)"
  else
    fail "configure_pam autologin warning ($autologin_pam_case, status=$status, output=$output)"
  fi
done

# A missing LOGIN_FILE is never created, even when an earlier backup exists
missing_pam_dir="$TMP_DIR/missing_pam"
mkdir -p "$missing_pam_dir"
missing_pam_login="$missing_pam_dir/login"
printf '#%%PAM-1.0\nauth       include      system-local-login\n' >"${missing_pam_login}.lightxdm.bak"
set +e
# shellcheck disable=SC2016  # expand inside the child shell so install.sh owns errexit
output="$(
  env -u SHELLOPTS -u SUDO_USER \
    LOGIN_FILE="$missing_pam_login" \
    PATH="$STUB_BIN:$PATH" \
    bash -c '
      source "$1/install.sh"
      configure_pam "i3"
    ' bash "$REPO_ROOT" 2>&1
)"
status=$?
set -e
if [[ $status -ne 0 && ! -e "$missing_pam_login" && "$output" == *"is missing; lightXDM will not create it"* &&
  "$output" == *"sudo cp ${missing_pam_login}.lightxdm.bak $missing_pam_login"* ]]; then
  pass "configure_pam refuses a missing LOGIN_FILE and points at the backup"
else
  fail "configure_pam with missing LOGIN_FILE (status=$status, exists=$([[ -e "$missing_pam_login" ]] && echo yes || echo no), output=$output)"
fi

for polkit_cp_case in backup edited; do
  fail_polkit_rule="$fail_sys_cp_dir/${polkit_cp_case}.rules"
  printf '// foreign administrator rule (%s)\n' "$polkit_cp_case" >"$fail_polkit_rule"
  fail_polkit_hash="$(sha256sum < "$fail_polkit_rule")"
  if [[ "$polkit_cp_case" == "edited" ]]; then
    : >"${fail_polkit_rule}.lightxdm.absent"
  fi
  set +e
  # shellcheck disable=SC2016  # expand inside the child shell so install.sh owns errexit
  output="$(
    env -u SHELLOPTS -u SUDO_USER \
      POLKIT_RULE_DEST="$fail_polkit_rule" \
      PATH="$fail_cp_bin:$STUB_BIN:$PATH" \
      bash -c '
        source "$1/install.sh"
        install_polkit_rule
      ' bash "$REPO_ROOT" 2>&1
  )"
  status=$?
  set -e
  if [[ $status -ne 0 ]] &&
    [[ -f "$fail_polkit_rule" && ! -L "$fail_polkit_rule" ]] &&
    [[ "$(sha256sum < "$fail_polkit_rule")" == "$fail_polkit_hash" ]] &&
    [[ ! -e "${fail_polkit_rule}.lightxdm.bak" && ! -e "${fail_polkit_rule}.lightxdm-edited" ]]; then
    pass "install_polkit_rule aborts on failed $polkit_cp_case copy without overwriting POLKIT_RULE_DEST"
  else
    fail "install_polkit_rule on failed $polkit_cp_case copy (status=$status, output=$output)"
  fi
done

# Case 68: Polkit probes must use sudo when the rule directory is inaccessible
restricted_polkit_dir="$TMP_DIR/restricted-polkit"
restricted_polkit_bin="$TMP_DIR/restricted-polkit-bin"
restricted_polkit_rule="$restricted_polkit_dir/49-nopasswd.rules"
mkdir -p "$restricted_polkit_dir" "$restricted_polkit_bin"
chmod 000 "$restricted_polkit_dir"
if [[ -r "$restricted_polkit_dir" || -x "$restricted_polkit_dir" ]]; then
  chmod 700 "$restricted_polkit_dir"
  skip "install_polkit_rule uses sudo for inaccessible rule directory (permissions bypassed, e.g. root)"
else
  cat >"$restricted_polkit_bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -e
chmod 700 "$POLKIT_RULE_DIR"
trap 'chmod 000 "$POLKIT_RULE_DIR"' EXIT
"$@"
EOF
  chmod +x "$restricted_polkit_bin/sudo"

  polkit_path_state() {
    if [[ -L "$1" ]]; then
      printf 'link:%s' "$(readlink -- "$1")"
    elif [[ -f "$1" ]]; then
      printf 'file:%s' "$(sha256sum < "$1")"
    else
      printf 'missing'
    fi
  }

  shipped_polkit_state="$(polkit_path_state "$POLKIT_RULE_SRC")"
  polkit_marker_suffixes=(.lightxdm.bak .lightxdm.absent .lightxdm-edited .lightxdm-edited.1 .lightxdm-edited.2)
  for restricted_fixture in foreign shipped dangling \
    backup-missing backup-link-missing absent-missing absent-link-missing \
    backup backup-link absent absent-link edited edited-link numbered numbered-link; do
    chmod 700 "$restricted_polkit_dir"
    rm -f -- "$restricted_polkit_dir/"*
    printf '// foreign administrator rule\n' >"$restricted_polkit_rule"
    case "$restricted_fixture" in
      shipped) cp "$POLKIT_RULE_SRC" "$restricted_polkit_rule" ;;
      dangling)
        rm "$restricted_polkit_rule"
        ln -s missing-rule "$restricted_polkit_rule"
        ;;
      *-missing) rm "$restricted_polkit_rule" ;;
    esac
    case "$restricted_fixture" in
      backup-link*) ln -s missing-backup "${restricted_polkit_rule}.lightxdm.bak" ;;
      backup*|edited*|numbered*) printf '// original backup\n' >"${restricted_polkit_rule}.lightxdm.bak" ;;
      absent-link*) ln -s missing-marker "${restricted_polkit_rule}.lightxdm.absent" ;;
      absent*) printf 'preserve marker\n' >"${restricted_polkit_rule}.lightxdm.absent" ;;
    esac
    case "$restricted_fixture" in
      edited-link) ln -s missing-edit "${restricted_polkit_rule}.lightxdm-edited" ;;
      edited|numbered*) printf '// previous edit\n' >"${restricted_polkit_rule}.lightxdm-edited" ;;
    esac
    case "$restricted_fixture" in
      numbered) printf '// numbered edit\n' >"${restricted_polkit_rule}.lightxdm-edited.1" ;;
      numbered-link) ln -s missing-numbered-edit "${restricted_polkit_rule}.lightxdm-edited.1" ;;
    esac

    expected_polkit_markers=()
    for suffix in "${polkit_marker_suffixes[@]}"; do
      expected_polkit_markers+=("$(polkit_path_state "$restricted_polkit_rule$suffix")")
    done
    case "$restricted_fixture" in
      foreign|dangling) expected_polkit_markers[0]="$(polkit_path_state "$restricted_polkit_rule")" ;;
      backup|backup-link|absent|absent-link) expected_polkit_markers[2]="$(polkit_path_state "$restricted_polkit_rule")" ;;
      edited|edited-link) expected_polkit_markers[3]="$(polkit_path_state "$restricted_polkit_rule")" ;;
      numbered*) expected_polkit_markers[4]="$(polkit_path_state "$restricted_polkit_rule")" ;;
    esac

    chmod 000 "$restricted_polkit_dir"
    set +e
    # shellcheck disable=SC2016  # source with the destination set before readonly declarations
    output="$(env -u SHELLOPTS POLKIT_RULE_DEST="$restricted_polkit_rule" \
      POLKIT_RULE_DIR="$restricted_polkit_dir" PATH="$restricted_polkit_bin:$PATH" \
      bash -c 'source "$1/install.sh"; install_polkit_rule' bash "$REPO_ROOT" 2>&1)"
    status=$?
    set -e
    chmod 700 "$restricted_polkit_dir"
    restricted_polkit_ok=1
    if [[ $status -ne 0 || "$(polkit_path_state "$restricted_polkit_rule")" != "$shipped_polkit_state" ]]; then
      restricted_polkit_ok=0
    fi
    for marker_index in "${!polkit_marker_suffixes[@]}"; do
      if [[ "$(polkit_path_state "$restricted_polkit_rule${polkit_marker_suffixes[marker_index]}")" != "${expected_polkit_markers[marker_index]}" ]]; then
        restricted_polkit_ok=0
      fi
    done
    if [[ $restricted_polkit_ok -eq 1 ]]; then
      pass "install_polkit_rule preserves $restricted_fixture rule state using sudo in an inaccessible directory"
    else
      fail "install_polkit_rule inaccessible directory ($restricted_fixture, status=$status, output=$output)"
    fi
  done
fi

# Case 69: disable_display_managers records and disables an enabled ly@tty1.service while leaving ly@tty2.service untouched
ly_dir="$TMP_DIR/ly_dm"
ly_bin="$ly_dir/bin"
ly_state="$ly_dir/state/disabled-display-managers"
ly_missing_link="$ly_dir/display-manager.service"
mkdir -p "$ly_bin"
cat >"$ly_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$STUB_LOG"
case "${1:-}" in
  list-unit-files)
    printf '%s\n' "ly@.service disabled"
    ;;
  is-enabled)
    case "${3:-${2:-}}" in
      ly@tty1.service)
        printf '%s\n' "${STUB_LY_TTY1_STATE:-enabled}"
        [[ "${STUB_LY_TTY1_STATE:-enabled}" == "enabled" ]]
        ;;
      ly@tty2.service)
        echo enabled
        ;;
      ly@.service)
        echo indirect
        ;;
      *)
        echo disabled
        exit 1
        ;;
    esac
    ;;
  disable)
    if [[ -f "${DM_STATE_FILE:-}" ]] && grep -Fxq -- "${2:-}" "$DM_STATE_FILE"; then
      echo "recorded-before-disable ${2:-}" >>"$STUB_LOG"
    fi
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$ly_bin/systemctl"

: >"$STUB_LOG"
set +e
# shellcheck disable=SC2016  # source with DM_STATE_FILE and DISPLAY_MANAGER_LINK set before readonly declarations
output="$(
  env -u SHELLOPTS \
    PATH="$ly_bin:$STUB_BIN:$PATH" \
    DM_STATE_FILE="$ly_state" \
    DISPLAY_MANAGER_LINK="$ly_missing_link" \
    bash -c 'source "$1/install.sh"; disable_display_managers' bash "$REPO_ROOT" 2>&1
)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 0 && -f "$ly_state" ]] &&
  [[ "$(cat "$ly_state")" == "ly@tty1.service" ]] &&
  grep -Fxq 'recorded-before-disable ly@tty1.service' "$STUB_LOG" &&
  [[ "$(grep -Fxc 'systemctl disable ly@tty1.service' "$STUB_LOG")" -eq 1 ]] &&
  ! grep -Fq 'ly@tty2.service' "$ly_state" &&
  ! grep -Fq 'ly@tty2.service' "$STUB_LOG" &&
  [[ "$(PATH="$ly_bin:$PATH" systemctl is-enabled ly@tty2.service)" == "enabled" ]] &&
  [[ "$output" == *"Disabled display manager(s): ly@tty1"* ]]; then
  pass "disable_display_managers records and disables enabled ly@tty1.service and leaves ly@tty2.service alone"
else
  fail "disable_display_managers ly@tty1.service (status=$status, state=$(cat "$ly_state" 2>/dev/null || true), log=$log_content, output=$output)"
fi

set +e
# shellcheck disable=SC2016
output="$(
  env -u SHELLOPTS \
    PATH="$ly_bin:$STUB_BIN:$PATH" \
    DM_STATE_FILE="$ly_state" \
    DISPLAY_MANAGER_LINK="$ly_missing_link" \
    bash -c 'source "$1/install.sh"; disable_display_managers' bash "$REPO_ROOT" 2>&1
)"
status=$?
set -e
if [[ $status -eq 0 && "$(cat "$ly_state")" == "ly@tty1.service" ]]; then
  pass "disable_display_managers keeps a single ly@tty1.service entry across reruns"
else
  fail "disable_display_managers ly@tty1.service rerun (status=$status, state=$(cat "$ly_state" 2>/dev/null || true), output=$output)"
fi

for ly_non_enabled in disabled indirect enabled-runtime; do
  ly_other_state="$ly_dir/state_${ly_non_enabled}/disabled-display-managers"
  : >"$STUB_LOG"
  set +e
  # shellcheck disable=SC2016
  output="$(
    env -u SHELLOPTS \
      PATH="$ly_bin:$STUB_BIN:$PATH" \
      STUB_LY_TTY1_STATE="$ly_non_enabled" \
      DM_STATE_FILE="$ly_other_state" \
      DISPLAY_MANAGER_LINK="$ly_missing_link" \
      bash -c 'source "$1/install.sh"; disable_display_managers' bash "$REPO_ROOT" 2>&1
  )"
  status=$?
  set -e
  if [[ $status -eq 0 && ! -e "$ly_other_state" ]] &&
    ! grep -Fq 'systemctl disable' "$STUB_LOG" &&
    [[ "$output" == *"No enabled display managers found."* ]]; then
    pass "disable_display_managers ignores ly@tty1.service when is-enabled reports $ly_non_enabled"
  else
    fail "disable_display_managers ly@tty1.service $ly_non_enabled (status=$status, log=$(cat "$STUB_LOG"), output=$output)"
  fi
done

ly_readonly_dir="$ly_dir/readonly"
mkdir -p "$ly_readonly_dir"
chmod 555 "$ly_readonly_dir"
if [[ -w "$ly_readonly_dir" ]]; then
  skip "disable_display_managers ly@tty1.service state write failure (directory remains writable)"
else
  : >"$STUB_LOG"
  set +e
  # shellcheck disable=SC2016
  output="$(
    env -u SHELLOPTS \
      PATH="$ly_bin:$STUB_BIN:$PATH" \
      DM_STATE_FILE="$ly_readonly_dir/state" \
      DISPLAY_MANAGER_LINK="$ly_missing_link" \
      bash -c 'source "$1/install.sh"; disable_display_managers || exit $?' bash "$REPO_ROOT" 2>&1
  )"
  status=$?
  set -e
  if [[ $status -ne 0 && ! -e "$ly_readonly_dir/state" ]] &&
    grep -Fxq 'systemctl is-enabled ly@tty1.service' "$STUB_LOG" &&
    ! grep -Fq 'systemctl disable' "$STUB_LOG"; then
    pass "disable_display_managers stops before disabling ly@tty1.service when state write fails"
  else
    fail "disable_display_managers ly@tty1.service state write failure (status=$status, log=$(cat "$STUB_LOG"), output=$output)"
  fi
fi
chmod 755 "$ly_readonly_dir"

if [[ $EUID -eq 0 ]]; then
  ly_uninstall_runner=(bash)
elif [[ $can_unshare -eq 1 ]]; then
  ly_uninstall_runner=(unshare -r bash)
else
  ly_uninstall_runner=()
fi
if [[ ${#ly_uninstall_runner[@]} -eq 0 ]]; then
  skip "uninstall.sh re-enables recorded ly@tty1.service (unshare -r unavailable)"
else
  mkdir -p "$ly_dir/home"
  : >"$STUB_LOG"
  set +e
  output="$(
    env TARGET_HOME="$ly_dir/home" \
      LOGIN_FILE="$ly_dir/login" \
      AUTOLOGIN_DROPIN="$ly_dir/autologin" \
      OVERRIDE_FILE="$ly_dir/override" \
      POLKIT_RULE="$ly_dir/polkit" \
      DM_STATE_FILE="$ly_state" \
      "${ly_uninstall_runner[@]}" "$REPO_ROOT/uninstall.sh" 2>&1
  )"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -eq 0 && ! -e "$ly_state" && "$log_content" == "systemctl enable ly@tty1.service" ]]; then
    pass "uninstall.sh re-enables recorded ly@tty1.service and removes state"
  else
    fail "uninstall.sh ly@tty1.service restore (status=$status, log=$log_content, output=$output)"
  fi
fi

# Case 70: desktop menu options 1-6, invalid-then-valid retry, and end-to-end selection through main
menu_out="$TMP_DIR/menu_out"
menu_ids=(xfce lxqt lxde mate cinnamon i3)
for menu_idx in "${!menu_ids[@]}"; do
  menu_choice=$((menu_idx + 1))
  expected_menu_id="${menu_ids[menu_idx]}"
  set +e
  prompt_de_selection <<<"$menu_choice" >"$menu_out" 2>/dev/null
  status=$?
  set -e
  output="$(cat "$menu_out")"
  if [[ $status -eq 0 && "$output" == "$expected_menu_id" &&
    "$(sha256sum < "$menu_out")" == "$(printf '%s\n' "$expected_menu_id" | sha256sum)" ]]; then
    pass "prompt_de_selection maps option $menu_choice to $expected_menu_id"
  else
    fail "prompt_de_selection option $menu_choice (status=$status, output=$output)"
  fi
done

set +e
prompt_de_selection <<<$'99\n2\n' >"$menu_out" 2>/dev/null
status=$?
set -e
output="$(cat "$menu_out")"
if [[ $status -eq 0 && "$output" == "lxqt" &&
  "$(sha256sum < "$menu_out")" == "$(printf 'lxqt\n' | sha256sum)" ]]; then
  pass "prompt_de_selection retries after invalid option 99 and outputs lxqt"
else
  fail "prompt_de_selection retry 99->2 (status=$status, output=$output)"
fi

: >"$STUB_LOG"
set +e
output="$(STUB_DETECTED_DE=unknown STUB_REAL_PROMPT=1 run_main_with_stubs "$sudo_pw_dir" <<<"2" 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
expected_menu_main_log=$'sudo -v\ndetect_de\ninstall_packages lxqt\ncopy_dotfiles lxqt\nconfigure_pam lxqt\ninstall_polkit_rule\ndisable_display_managers'
if [[ $status -eq 0 && "$log_content" == "$expected_menu_main_log" &&
  "$output" == *"No supported desktop environment detected."* &&
  "$output" == *"lightXDM install complete!"* && "$output" == *"- lxqt "* ]]; then
  pass "main runs install steps for lxqt when selected interactively from the desktop menu"
else
  fail "main interactive desktop menu selection (status=$status, log=$log_content, output=$output)"
fi

# Case 71: a failed PAM append stops main before Polkit or display managers
fail_pam_append_dir="$TMP_DIR/fail_pam_append"
mkdir -p "$fail_pam_append_dir"
printf '#%%PAM-1.0\nauth include system-local-login\nsession include system-local-login\n' >"$fail_pam_append_dir/login"
cat >"$fail_pam_append_dir/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-v" ]]; then
  echo "sudo -v" >>"$STUB_LOG"
  exit 0
fi
if [[ "${1:-}" == "tee" && "${2:-}" == "-a" && "${3:-}" == "$LOGIN_FILE" ]]; then
  echo "failed PAM append" >>"$STUB_LOG"
  exit 1
fi
exec "$@"
EOF
chmod +x "$fail_pam_append_dir/sudo"
: >"$STUB_LOG"
set +e
# shellcheck disable=SC2016  # expand inside the child shell so install.sh owns errexit
output="$(
  env -u SHELLOPTS -u SUDO_USER \
    LOGIN_FILE="$fail_pam_append_dir/login" \
    PATH="$fail_pam_append_dir:$STUB_BIN:$PATH" \
    USER="testuser" \
    bash -c '
      source "$1/install.sh"
      check_root() { echo "check_root" >>"$STUB_LOG"; }
      install_packages() { echo "install_packages $*" >>"$STUB_LOG"; }
      copy_dotfiles() { echo "copy_dotfiles $*" >>"$STUB_LOG"; }
      install_polkit_rule() { echo "install_polkit_rule" >>"$STUB_LOG"; }
      disable_display_managers() { echo "disable_display_managers" >>"$STUB_LOG"; }
      main --de i3
    ' bash "$REPO_ROOT" 2>&1
)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -ne 0 ]] &&
  grep -Fxq -- "install_packages i3" "$STUB_LOG" &&
  grep -Fxq -- "copy_dotfiles i3" "$STUB_LOG" &&
  grep -Fxq -- "failed PAM append" "$STUB_LOG" &&
  [[ "$log_content" != *"install_polkit_rule"* && "$log_content" != *"disable_display_managers"* &&
    "$output" == *"$recovery_hint"* && "$output" != *"lightXDM install complete!"* ]] &&
  grep -Fxq '=> Install stopped during configure_pam; already done: install_packages copy_dotfiles' <<<"$output"; then
  pass "main stops on PAM append failure before Polkit or display managers"
else
  fail "main on PAM append failure (status=$status, log=$log_content, output=$output)"
fi

# Case 72: ~/.config/lightxdm/.xinitrc-<id> supports custom sessions, overrides bundled templates, survives reruns, and is recognized by uninstall.sh
user_tmpl_dir="$TMP_DIR/user_templates"
ut_custom_home="$user_tmpl_dir/home_custom"
ut_override_home="$user_tmpl_dir/home_override"
ut_plain_home="$user_tmpl_dir/home_plain"
ut_reject_home="$user_tmpl_dir/home_reject"
ut_login="$user_tmpl_dir/login"
ut_polkit="$user_tmpl_dir/49-nopasswd.rules"
ut_dm_state="$user_tmpl_dir/state/disabled-display-managers"
mkdir -p "$ut_custom_home/.config/lightxdm" "$ut_override_home/.config/lightxdm" "$ut_plain_home" "$ut_reject_home/.config/lightxdm"

printf '#!/bin/sh\nexec dwm\n' >"$ut_custom_home/.config/lightxdm/.xinitrc-dwm"
ut_dwm_hash="$(sha256sum < "$ut_custom_home/.config/lightxdm/.xinitrc-dwm")"

ut_resolved_custom="$(HOME="$ut_custom_home" xinitrc_template "dwm")"
ut_resolved_fallback="$(HOME="$ut_custom_home" xinitrc_template "i3")"
if [[ "$ut_resolved_custom" == "$ut_custom_home/.config/lightxdm/.xinitrc-dwm" &&
  "$ut_resolved_fallback" == "$REPO_ROOT/dotfiles/.xinitrc-i3" ]]; then
  pass "xinitrc_template prefers ~/.config/lightxdm/.xinitrc-<id> and falls back to dotfiles/"
else
  fail "xinitrc_template resolution (custom=$ut_resolved_custom, fallback=$ut_resolved_fallback)"
fi

cp "$ut_custom_home/.config/lightxdm/.xinitrc-dwm" "$ut_reject_home/.config/lightxdm/.xinitrc-dwm"
cp "$ut_custom_home/.config/lightxdm/.xinitrc-dwm" "$ut_reject_home/.config/lightxdm/.xinitrc-Dwm"
for ut_reject_case in no-packages-missing invalid-id missing-template; do
  ut_reject_args=(--no-packages --de dwm)
  case "$ut_reject_case" in
    no-packages-missing) ut_reject_args=(--de dwm) ;;
    invalid-id) ut_reject_args=(--no-packages --de Dwm) ;;
    missing-template) ut_reject_args=(--no-packages --de awesome) ;;
  esac
  : >"$STUB_LOG"
  set +e
  output="$(HOME="$ut_reject_home" run_main_with_stubs "$sudo_pw_dir" "${ut_reject_args[@]}" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 1 && "$output" == *"Unsupported desktop environment:"* && ! -s "$STUB_LOG" ]]; then
    pass "main rejects ~/.config/lightxdm custom session when $ut_reject_case"
  else
    fail "main ~/.config/lightxdm rejection ($ut_reject_case, status=$status, log=$(cat "$STUB_LOG"), output=$output)"
  fi
done

printf '#%%PAM-1.0\nauth       include      system-local-login\nsession    include      system-local-login\n' >"$ut_login"
set +e
output="$(
  env -u SHELLOPTS -u SUDO_USER \
    HOME="$ut_custom_home" \
    PATH="$sudo_pw_dir:$STUB_BIN:$PATH" \
    USER="testuser" \
    LOGIN_FILE="$ut_login" \
    POLKIT_RULE_DEST="$ut_polkit" \
    DISPLAY_MANAGER_LINK="$user_tmpl_dir/display-manager.service" \
    DM_STATE_FILE="$ut_dm_state" \
    bash "$REPO_ROOT/install.sh" --no-packages --de dwm 2>&1
)"
status=$?
set -e
if [[ $status -eq 0 && ! -e "$REPO_ROOT/dotfiles/.xinitrc-dwm" ]] &&
  [[ -x "$ut_custom_home/.xinitrc" && ! -L "$ut_custom_home/.xinitrc" ]] &&
  [[ "$(sha256sum < "$ut_custom_home/.xinitrc")" == "$ut_dwm_hash" ]] &&
  [[ -f "$ut_custom_home/.xinitrc.lightxdm.absent" && ! -e "$ut_custom_home/.xinitrc.lightxdm.bak" && ! -e "$ut_custom_home/.xinitrc.lightxdm-edited" ]] &&
  [[ "$(sha256sum < "$ut_custom_home/.config/lightxdm/.xinitrc-dwm")" == "$ut_dwm_hash" ]]; then
  pass "install.sh --no-packages --de dwm installs ~/.config/lightxdm/.xinitrc-dwm without touching checkout"
else
  fail "install.sh custom ~/.config/lightxdm/.xinitrc-dwm (status=$status, output=$output)"
fi

set +e
output="$(
  env -u SHELLOPTS -u SUDO_USER \
    HOME="$ut_custom_home" \
    PATH="$sudo_pw_dir:$STUB_BIN:$PATH" \
    USER="testuser" \
    LOGIN_FILE="$ut_login" \
    POLKIT_RULE_DEST="$ut_polkit" \
    DISPLAY_MANAGER_LINK="$user_tmpl_dir/display-manager.service" \
    DM_STATE_FILE="$ut_dm_state" \
    bash "$REPO_ROOT/install.sh" --de dwm --no-packages 2>&1
)"
status_rerun=$?
set -e
(
  export HOME="$ut_custom_home"
  export USER="testuser"
  copy_dotfiles "i3" 2>/dev/null
  copy_dotfiles "dwm" 2>/dev/null
)
if [[ $status_rerun -eq 0 ]] &&
  [[ "$(sha256sum < "$ut_custom_home/.xinitrc")" == "$ut_dwm_hash" ]] &&
  [[ ! -e "$ut_custom_home/.xinitrc.lightxdm-edited" && ! -e "$ut_custom_home/.xinitrc.lightxdm.bak" ]] &&
  [[ "$(sha256sum < "$ut_custom_home/.config/lightxdm/.xinitrc-dwm")" == "$ut_dwm_hash" ]]; then
  pass "rerunning install/copy_dotfiles with ~/.config/lightxdm template does not create .xinitrc.lightxdm-edited"
else
  fail "rerun with ~/.config/lightxdm template (status=$status_rerun, output=$output)"
fi

printf '# pre-existing user xinitrc\n' >"$ut_override_home/.xinitrc"
printf '#!/bin/sh\nexec i3 --shmlog-size=0\n' >"$ut_override_home/.config/lightxdm/.xinitrc-i3"
ut_i3_override_hash="$(sha256sum < "$ut_override_home/.config/lightxdm/.xinitrc-i3")"
ut_missing_bundled_dir="$user_tmpl_dir/missing_bundled"
mkdir -p "$ut_missing_bundled_dir"
cp -r "$REPO_ROOT/dotfiles" "$REPO_ROOT/polkit" "$ut_missing_bundled_dir/"
rm "$ut_missing_bundled_dir/dotfiles/.xinitrc-i3"

rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak" "$POLKIT_RULE_DEST" "${POLKIT_RULE_DEST}.lightxdm.bak" "${POLKIT_RULE_DEST}.lightxdm.absent"
write_stock_login
set +e
output="$(
  # shellcheck disable=SC2034  # main uses SCRIPT_DIR from the sourced installer
  SCRIPT_DIR="$ut_missing_bundled_dir"
  export HOME="$ut_override_home"
  export PATH="$sudo_pw_dir:$STUB_BIN:$PATH"
  export USER="testuser"
  unset SUDO_USER
  main --de i3 2>&1
)"
status_override_missing=$?
set -e
(
  export HOME="$ut_override_home"
  export USER="testuser"
  copy_dotfiles "i3" 2>/dev/null
)
(
  export HOME="$ut_plain_home"
  export USER="testuser"
  copy_dotfiles "i3" 2>/dev/null
)
if [[ $status_override_missing -eq 0 ]] &&
  [[ -x "$ut_override_home/.xinitrc" ]] &&
  [[ "$(sha256sum < "$ut_override_home/.xinitrc")" == "$ut_i3_override_hash" ]] &&
  [[ "$(sha256sum < "$ut_override_home/.xinitrc")" != "$(sha256sum < "$REPO_ROOT/dotfiles/.xinitrc-i3")" ]] &&
  [[ -f "$ut_override_home/.xinitrc.lightxdm.bak" && "$(cat "$ut_override_home/.xinitrc.lightxdm.bak")" == "# pre-existing user xinitrc" ]] &&
  [[ ! -e "$ut_override_home/.xinitrc.lightxdm-edited" ]] &&
  [[ ! -e "$ut_plain_home/.config" ]]; then
  pass "A user .config/lightxdm/.xinitrc-i3 overrides dotfiles/.xinitrc-i3 without creating ~/.config when absent"
else
  fail "user .config/lightxdm/.xinitrc-i3 override (status=$status_override_missing, output=$output)"
fi

if [[ $EUID -eq 0 ]]; then
  ut_uninstall_runner=(bash)
elif [[ $can_unshare -eq 1 ]]; then
  ut_uninstall_runner=(unshare -r bash)
else
  ut_uninstall_runner=()
fi
if [[ ${#ut_uninstall_runner[@]} -eq 0 ]]; then
  skip "uninstall.sh handles ~/.config/lightxdm templates (unshare -r unavailable)"
else
  set +e
  out_ut_custom="$(
    env TARGET_HOME="$ut_custom_home" \
      LOGIN_FILE="$user_tmpl_dir/u_login1" \
      AUTOLOGIN_DROPIN="$user_tmpl_dir/u_auto1" \
      OVERRIDE_FILE="$user_tmpl_dir/u_over1" \
      POLKIT_RULE="$user_tmpl_dir/u_polkit1" \
      DM_STATE_FILE="$user_tmpl_dir/u_dm1" \
      "${ut_uninstall_runner[@]}" "$REPO_ROOT/uninstall.sh" 2>&1
  )"
  st_ut_custom=$?
  out_ut_override="$(
    env TARGET_HOME="$ut_override_home" \
      LOGIN_FILE="$user_tmpl_dir/u_login2" \
      AUTOLOGIN_DROPIN="$user_tmpl_dir/u_auto2" \
      OVERRIDE_FILE="$user_tmpl_dir/u_over2" \
      POLKIT_RULE="$user_tmpl_dir/u_polkit2" \
      DM_STATE_FILE="$user_tmpl_dir/u_dm2" \
      "${ut_uninstall_runner[@]}" "$REPO_ROOT/uninstall.sh" 2>&1
  )"
  st_ut_override=$?
  set -e
  if [[ $st_ut_custom -eq 0 && $st_ut_override -eq 0 ]] &&
    [[ ! -e "$ut_custom_home/.xinitrc" && ! -L "$ut_custom_home/.xinitrc" ]] &&
    [[ ! -e "$ut_custom_home/.xinitrc.lightxdm.absent" && ! -e "$ut_custom_home/.xinitrc.lightxdm-edited" ]] &&
    [[ -f "$ut_custom_home/.config/lightxdm/.xinitrc-dwm" && "$(sha256sum < "$ut_custom_home/.config/lightxdm/.xinitrc-dwm")" == "$ut_dwm_hash" ]] &&
    [[ -f "$ut_override_home/.xinitrc" && "$(cat "$ut_override_home/.xinitrc")" == "# pre-existing user xinitrc" ]] &&
    [[ ! -e "$ut_override_home/.xinitrc.lightxdm.bak" && ! -e "$ut_override_home/.xinitrc.lightxdm-edited" ]] &&
    [[ -f "$ut_override_home/.config/lightxdm/.xinitrc-i3" && "$(sha256sum < "$ut_override_home/.config/lightxdm/.xinitrc-i3")" == "$ut_i3_override_hash" ]]; then
    pass "uninstall.sh removes or restores ~/.xinitrc installed from ~/.config/lightxdm and leaves ~/.config/lightxdm intact"
  else
    fail "uninstall.sh ~/.config/lightxdm templates (c=$st_ut_custom:$out_ut_custom | o=$st_ut_override:$out_ut_override)"
  fi
fi

# Case 72b: a user template pointing to ~/.xinitrc must not identify it as a lightXDM file
for ut_link_de in xfce dwm; do
  ut_link_dir="$user_tmpl_dir/link_$ut_link_de"
  ut_link_home="$ut_link_dir/home"
  mkdir -p "$ut_link_home/.config/lightxdm"
  printf '# user xinitrc\nexec dwm\n' >"$ut_link_home/.xinitrc"
  ut_link_hash="$(sha256sum < "$ut_link_home/.xinitrc")"
  ln -s ../../.xinitrc "$ut_link_home/.config/lightxdm/.xinitrc-dwm"
  printf '#%%PAM-1.0\n' >"$ut_link_dir/login"
  set +e
  output="$(
    env -u SHELLOPTS -u SUDO_USER \
      HOME="$ut_link_home" \
      PATH="$sudo_pw_dir:$STUB_BIN:$PATH" \
      USER="testuser" \
      LOGIN_FILE="$ut_link_dir/login" \
      POLKIT_RULE_DEST="$ut_link_dir/polkit" \
      DISPLAY_MANAGER_LINK="$ut_link_dir/display-manager.service" \
      DM_STATE_FILE="$ut_link_dir/state/disabled-display-managers" \
      bash "$REPO_ROOT/install.sh" --no-packages --de "$ut_link_de" 2>&1
  )"
  status=$?
  set -e
  if [[ "$ut_link_de" == xfce ]]; then
    if [[ $status -eq 0 && -f "$ut_link_home/.xinitrc.lightxdm.bak" ]] &&
      [[ "$(sha256sum < "$ut_link_home/.xinitrc.lightxdm.bak")" == "$ut_link_hash" ]] &&
      [[ "$(sha256sum < "$ut_link_home/.xinitrc")" == "$(sha256sum < "$REPO_ROOT/dotfiles/.xinitrc-xfce")" ]]; then
      pass "install.sh backs up ~/.xinitrc when another session's user template links to it"
    else
      fail "install.sh backup with linked user template (status=$status, output=$output)"
    fi
  else
    if [[ $status -eq 1 && "$output" == *"template for dwm is ~/.xinitrc itself"* && ! -L "$ut_link_home/.xinitrc" ]] &&
      [[ "$(sha256sum < "$ut_link_home/.xinitrc")" == "$ut_link_hash" ]] &&
      [[ "$ut_link_home/.config/lightxdm/.xinitrc-dwm" -ef "$ut_link_home/.xinitrc" ]] &&
      [[ ! -e "$ut_link_home/.xinitrc.lightxdm.bak" && ! -e "$ut_link_home/.xinitrc.lightxdm.absent" && ! -e "$ut_link_home/.xinitrc.lightxdm-edited" ]]; then
      pass "install.sh rejects a user template pointing to ~/.xinitrc without changing ~/.xinitrc"
    else
      fail "install.sh rejects self template (status=$status, output=$output)"
    fi
  fi
done

if [[ ${#ut_uninstall_runner[@]} -eq 0 ]]; then
  skip "uninstall.sh keeps ~/.xinitrc when a user template links to it (unshare -r unavailable)"
else
  ut_link_keep_home="$user_tmpl_dir/home_link_keep"
  mkdir -p "$ut_link_keep_home/.config/lightxdm"
  printf '# user xinitrc\nexec dwm\n' >"$ut_link_keep_home/.xinitrc"
  ut_link_keep_hash="$(sha256sum < "$ut_link_keep_home/.xinitrc")"
  ln -s ../../.xinitrc "$ut_link_keep_home/.config/lightxdm/.xinitrc-dwm"
  set +e
  output="$(
    env TARGET_HOME="$ut_link_keep_home" \
      LOGIN_FILE="$user_tmpl_dir/u_link_login" \
      AUTOLOGIN_DROPIN="$user_tmpl_dir/u_link_auto" \
      OVERRIDE_FILE="$user_tmpl_dir/u_link_over" \
      POLKIT_RULE="$user_tmpl_dir/u_link_polkit" \
      DM_STATE_FILE="$user_tmpl_dir/u_link_dm" \
      "${ut_uninstall_runner[@]}" "$REPO_ROOT/uninstall.sh" 2>&1
  )"
  status=$?
  set -e
  if [[ $status -eq 0 && -f "$ut_link_keep_home/.xinitrc" ]] &&
    [[ "$(sha256sum < "$ut_link_keep_home/.xinitrc")" == "$ut_link_keep_hash" ]] &&
    [[ -L "$ut_link_keep_home/.config/lightxdm/.xinitrc-dwm" && "$ut_link_keep_home/.config/lightxdm/.xinitrc-dwm" -ef "$ut_link_keep_home/.xinitrc" ]]; then
    pass "uninstall.sh keeps ~/.xinitrc when a user template links to it"
  else
    fail "uninstall.sh with linked user template (status=$status, output=$output)"
  fi

  # With an install marker, user templates count; the linked one must still not match ~/.xinitrc itself.
  ut_link_marker_home="$user_tmpl_dir/home_link_marker"
  mkdir -p "$ut_link_marker_home/.config/lightxdm"
  printf '# user xinitrc\nexec dwm\n' >"$ut_link_marker_home/.xinitrc"
  : >"$ut_link_marker_home/.xinitrc.lightxdm.absent"
  ln -s ../../.xinitrc "$ut_link_marker_home/.config/lightxdm/.xinitrc-dwm"
  set +e
  output="$(
    env TARGET_HOME="$ut_link_marker_home" \
      LOGIN_FILE="$user_tmpl_dir/u_link_marker_login" \
      AUTOLOGIN_DROPIN="$user_tmpl_dir/u_link_marker_auto" \
      OVERRIDE_FILE="$user_tmpl_dir/u_link_marker_over" \
      POLKIT_RULE="$user_tmpl_dir/u_link_marker_polkit" \
      DM_STATE_FILE="$user_tmpl_dir/u_link_marker_dm" \
      "${ut_uninstall_runner[@]}" "$REPO_ROOT/uninstall.sh" 2>&1
  )"
  status=$?
  set -e
  if [[ $status -eq 0 && -f "$ut_link_marker_home/.xinitrc.lightxdm-edited" ]] &&
    [[ "$(sha256sum < "$ut_link_marker_home/.xinitrc.lightxdm-edited")" == "$ut_link_keep_hash" ]]; then
    pass "uninstall.sh saves a marker-backed ~/.xinitrc that a user template links to instead of deleting it"
  else
    fail "uninstall.sh with marker and linked user template (status=$status, output=$output)"
  fi
fi

# A ~/.xinitrc symlink to the selected user or bundled template is replaced and restored
for ut_selected_kind in user bundled; do
  ut_selected_dir="$user_tmpl_dir/selected_$ut_selected_kind"
  ut_selected_home="$ut_selected_dir/home"
  mkdir -p "$ut_selected_home/.config/lightxdm"
  if [[ "$ut_selected_kind" == user ]]; then
    ut_selected_de=dwm
    ut_selected_target=.config/lightxdm/.xinitrc-dwm
    printf '#!/bin/sh\nexec dwm\n' >"$ut_selected_home/$ut_selected_target"
    ut_selected_template="$ut_selected_home/$ut_selected_target"
  else
    ut_selected_de=xfce
    ut_selected_target="$REPO_ROOT/dotfiles/.xinitrc-xfce"
    ut_selected_template="$ut_selected_target"
  fi
  ut_selected_hash="$(sha256sum < "$ut_selected_template")"
  ln -s "$ut_selected_target" "$ut_selected_home/.xinitrc"
  printf '#%%PAM-1.0\n' >"$ut_selected_dir/login"
  set +e
  output="$(
    env -u SHELLOPTS -u SUDO_USER \
      HOME="$ut_selected_home" \
      PATH="$sudo_pw_dir:$STUB_BIN:$PATH" \
      USER="testuser" \
      LOGIN_FILE="$ut_selected_dir/login" \
      POLKIT_RULE_DEST="$ut_selected_dir/polkit" \
      DISPLAY_MANAGER_LINK="$ut_selected_dir/display-manager.service" \
      DM_STATE_FILE="$ut_selected_dir/state/disabled-display-managers" \
      bash "$REPO_ROOT/install.sh" --no-packages --de "$ut_selected_de" 2>&1
  )"
  status=$?
  set -e
  if [[ $status -eq 0 && -x "$ut_selected_home/.xinitrc" && ! -L "$ut_selected_home/.xinitrc" ]] &&
    [[ "$(sha256sum < "$ut_selected_home/.xinitrc")" == "$ut_selected_hash" ]] &&
    [[ -L "$ut_selected_home/.xinitrc.lightxdm.bak" && "$(readlink "$ut_selected_home/.xinitrc.lightxdm.bak")" == "$ut_selected_target" ]] &&
    [[ "$(sha256sum < "$ut_selected_template")" == "$ut_selected_hash" ]]; then
    pass "install.sh replaces ~/.xinitrc linked to the selected $ut_selected_kind template and backs up the link"
  else
    fail "install.sh with ~/.xinitrc linked to selected $ut_selected_kind template (status=$status, output=$output)"
  fi
  if [[ ${#ut_uninstall_runner[@]} -eq 0 ]]; then
    skip "uninstall.sh restores ~/.xinitrc linked to selected $ut_selected_kind template (unshare -r unavailable)"
  else
    set +e
    output="$(
      env TARGET_HOME="$ut_selected_home" \
        LOGIN_FILE="$ut_selected_dir/u_login" \
        AUTOLOGIN_DROPIN="$ut_selected_dir/u_auto" \
        OVERRIDE_FILE="$ut_selected_dir/u_over" \
        POLKIT_RULE="$ut_selected_dir/u_polkit" \
        DM_STATE_FILE="$ut_selected_dir/u_dm" \
        "${ut_uninstall_runner[@]}" "$REPO_ROOT/uninstall.sh" 2>&1
    )"
    status=$?
    set -e
    if [[ $status -eq 0 && -L "$ut_selected_home/.xinitrc" && "$(readlink "$ut_selected_home/.xinitrc")" == "$ut_selected_target" ]] &&
      [[ ! -e "$ut_selected_home/.xinitrc.lightxdm.bak" && ! -L "$ut_selected_home/.xinitrc.lightxdm.bak" ]] &&
      [[ "$(sha256sum < "$ut_selected_template")" == "$ut_selected_hash" ]]; then
      pass "uninstall.sh restores ~/.xinitrc linked to selected $ut_selected_kind template"
    else
      fail "uninstall.sh with ~/.xinitrc linked to selected $ut_selected_kind template (status=$status, output=$output)"
    fi
  fi
done

# Case 72c: a pre-existing ~/.xinitrc copied to ~/.config/lightxdm is backed up on first install, restored by uninstall, and kept without markers
for ut_copy_de in xfce dwm; do
  ut_copy_dir="$user_tmpl_dir/copy_$ut_copy_de"
  ut_copy_home="$ut_copy_dir/home"
  mkdir -p "$ut_copy_home/.config/lightxdm"
  printf '#!/bin/sh\nexec dwm\n' >"$ut_copy_home/.xinitrc"
  ut_copy_hash="$(sha256sum < "$ut_copy_home/.xinitrc")"
  cp "$ut_copy_home/.xinitrc" "$ut_copy_home/.config/lightxdm/.xinitrc-dwm"
  printf '#%%PAM-1.0\n' >"$ut_copy_dir/login"
  set +e
  output="$(
    env -u SHELLOPTS -u SUDO_USER \
      HOME="$ut_copy_home" \
      PATH="$sudo_pw_dir:$STUB_BIN:$PATH" \
      USER="testuser" \
      LOGIN_FILE="$ut_copy_dir/login" \
      POLKIT_RULE_DEST="$ut_copy_dir/polkit" \
      DISPLAY_MANAGER_LINK="$ut_copy_dir/display-manager.service" \
      DM_STATE_FILE="$ut_copy_dir/state/disabled-display-managers" \
      bash "$REPO_ROOT/install.sh" --no-packages --de "$ut_copy_de" 2>&1
  )"
  status=$?
  set -e
  (
    export HOME="$ut_copy_home"
    export USER="testuser"
    copy_dotfiles "$ut_copy_de" 2>/dev/null
  )
  ut_expected_installed_hash="$ut_copy_hash"
  if [[ "$ut_copy_de" == "xfce" ]]; then
    ut_expected_installed_hash="$(sha256sum < "$REPO_ROOT/dotfiles/.xinitrc-xfce")"
  fi
  if [[ $status -eq 0 && -f "$ut_copy_home/.xinitrc.lightxdm.bak" ]] &&
    [[ "$(sha256sum < "$ut_copy_home/.xinitrc.lightxdm.bak")" == "$ut_copy_hash" ]] &&
    [[ "$(sha256sum < "$ut_copy_home/.xinitrc")" == "$ut_expected_installed_hash" ]] &&
    [[ ! -e "$ut_copy_home/.xinitrc.lightxdm.absent" && ! -e "$ut_copy_home/.xinitrc.lightxdm-edited" ]]; then
    pass "install.sh backs up pre-existing ~/.xinitrc equal to user template (--de $ut_copy_de)"
  else
    fail "install.sh backup with copied user template (--de $ut_copy_de, status=$status, output=$output)"
  fi

  if [[ ${#ut_uninstall_runner[@]} -eq 0 ]]; then
    skip "uninstall.sh restores ~/.xinitrc backed up despite matching user template (--de $ut_copy_de; unshare -r unavailable)"
  else
    set +e
    out_u1="$(
      env TARGET_HOME="$ut_copy_home" \
        LOGIN_FILE="$ut_copy_dir/u_login" \
        AUTOLOGIN_DROPIN="$ut_copy_dir/u_auto" \
        OVERRIDE_FILE="$ut_copy_dir/u_over" \
        POLKIT_RULE="$ut_copy_dir/u_polkit" \
        DM_STATE_FILE="$ut_copy_dir/u_dm" \
        "${ut_uninstall_runner[@]}" "$REPO_ROOT/uninstall.sh" 2>&1
    )"
    st_u1=$?
    out_u2="$(
      env TARGET_HOME="$ut_copy_home" \
        LOGIN_FILE="$ut_copy_dir/u_login" \
        AUTOLOGIN_DROPIN="$ut_copy_dir/u_auto" \
        OVERRIDE_FILE="$ut_copy_dir/u_over" \
        POLKIT_RULE="$ut_copy_dir/u_polkit" \
        DM_STATE_FILE="$ut_copy_dir/u_dm" \
        "${ut_uninstall_runner[@]}" "$REPO_ROOT/uninstall.sh" 2>&1
    )"
    st_u2=$?
    set -e
    if [[ $st_u1 -eq 0 && $st_u2 -eq 0 && -f "$ut_copy_home/.xinitrc" ]] &&
      [[ "$(sha256sum < "$ut_copy_home/.xinitrc")" == "$ut_copy_hash" ]] &&
      [[ ! -e "$ut_copy_home/.xinitrc.lightxdm.bak" && ! -e "$ut_copy_home/.xinitrc.lightxdm.absent" && ! -e "$ut_copy_home/.xinitrc.lightxdm-edited" ]] &&
      [[ -f "$ut_copy_home/.config/lightxdm/.xinitrc-dwm" && "$(sha256sum < "$ut_copy_home/.config/lightxdm/.xinitrc-dwm")" == "$ut_copy_hash" ]] &&
      [[ "$out_u2" == *"Keeping $ut_copy_home/.xinitrc"* ]]; then
      pass "uninstall.sh restores ~/.xinitrc equal to user template and keeps it on repeat uninstall (--de $ut_copy_de)"
    else
      fail "uninstall.sh restore/keep with copied user template (--de $ut_copy_de, s1=$st_u1:$out_u1 | s2=$st_u2:$out_u2)"
    fi
  fi
done

if [[ ${#ut_uninstall_runner[@]} -eq 0 ]]; then
  skip "uninstall.sh keeps pre-existing ~/.xinitrc copied to ~/.config/lightxdm when no markers exist (unshare -r unavailable)"
else
  ut_nomarker_home="$user_tmpl_dir/home_copy_nomarker"
  mkdir -p "$ut_nomarker_home/.config/lightxdm"
  printf '#!/bin/sh\nexec dwm\n' >"$ut_nomarker_home/.xinitrc"
  ut_nomarker_hash="$(sha256sum < "$ut_nomarker_home/.xinitrc")"
  cp "$ut_nomarker_home/.xinitrc" "$ut_nomarker_home/.config/lightxdm/.xinitrc-dwm"
  set +e
  output="$(
    env TARGET_HOME="$ut_nomarker_home" \
      LOGIN_FILE="$user_tmpl_dir/u_nm_login" \
      AUTOLOGIN_DROPIN="$user_tmpl_dir/u_nm_auto" \
      OVERRIDE_FILE="$user_tmpl_dir/u_nm_over" \
      POLKIT_RULE="$user_tmpl_dir/u_nm_polkit" \
      DM_STATE_FILE="$user_tmpl_dir/u_nm_dm" \
      "${ut_uninstall_runner[@]}" "$REPO_ROOT/uninstall.sh" 2>&1
  )"
  status=$?
  set -e
  if [[ $status -eq 0 && -f "$ut_nomarker_home/.xinitrc" ]] &&
    [[ "$(sha256sum < "$ut_nomarker_home/.xinitrc")" == "$ut_nomarker_hash" ]] &&
    [[ -f "$ut_nomarker_home/.config/lightxdm/.xinitrc-dwm" && "$(sha256sum < "$ut_nomarker_home/.config/lightxdm/.xinitrc-dwm")" == "$ut_nomarker_hash" ]] &&
    [[ ! -e "$ut_nomarker_home/.xinitrc.lightxdm-edited" ]] &&
    [[ "$output" == *"Keeping $ut_nomarker_home/.xinitrc"* ]]; then
    pass "uninstall.sh keeps ~/.xinitrc equal to user template when no markers exist"
  else
    fail "uninstall.sh no-marker copied user template (status=$status, output=$output)"
  fi
fi

# Case 73: --list-packages prints the package set one per line without sudo, root/wheel checks, or side effects
help_list_pkgs_out="$(HOME="$help_home" bash "$REPO_ROOT/install.sh" --help 2>&1)"
if [[ "$help_list_pkgs_out" == *"--list-packages"* ]]; then
  pass "install.sh --help documents --list-packages"
else
  fail "install.sh --help missing --list-packages (output=$help_list_pkgs_out)"
fi

lp_dir="$TMP_DIR/list_packages"
lp_home="$lp_dir/home"
lp_bin="$lp_dir/bin"
lp_no_sudo_bin="$lp_dir/no_sudo_bin"
lp_login="$lp_dir/login"
lp_polkit="$lp_dir/49-nopasswd.rules"
lp_dm_state="$lp_dir/state/disabled-display-managers"
lp_out_file="$lp_dir/stdout"
lp_err="$lp_dir/stderr"
mkdir -p "$lp_home/.config/lightxdm" "$lp_bin" "$lp_no_sudo_bin"
printf '#!/bin/sh\nexec dwm\n' >"$lp_home/.config/lightxdm/.xinitrc-dwm"
lp_dwm_hash="$(sha256sum < "$lp_home/.config/lightxdm/.xinitrc-dwm")"
printf '# untouched login\n' >"$lp_login"
lp_login_hash="$(sha256sum < "$lp_login")"

cat >"$lp_bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >>"${STUB_LOG:-/dev/null}"
exit 1
EOF
cat >"$lp_bin/id" <<'EOF'
#!/usr/bin/env bash
echo "id $*" >>"${STUB_LOG:-/dev/null}"
echo "users"
EOF
chmod +x "$lp_bin/sudo" "$lp_bin/id"
for lp_tool in bash dirname; do
  ln -sf "$(command -v "$lp_tool")" "$lp_no_sudo_bin/$lp_tool"
done
ln -sf "$lp_bin/id" "$lp_no_sudo_bin/id"
ln -sf "$STUB_BIN/pacman" "$lp_no_sudo_bin/pacman"
ln -sf "$STUB_BIN/systemctl" "$lp_no_sudo_bin/systemctl"

for spec in "${de_pkg_specs[@]}"; do
  IFS='|' read -r lp_de _ lp_de_pkgs <<<"$spec"
  case "$lp_de" in
    plasma | gnome | budgie) continue ;;
  esac
  read -r -a lp_expected_arr <<<"$expected_base_pkgs $lp_de_pkgs"
  lp_expected_out="$(printf '%s\n' "${lp_expected_arr[@]}")"
  lp_expected_sum="$(printf '%s\n' "${lp_expected_arr[@]}" | sha256sum)"

  lp_no_kr_arr=()
  for lp_pkg in "${lp_expected_arr[@]}"; do
    case "$lp_pkg" in
      gnome-keyring | kwallet-pam) ;;
      *) lp_no_kr_arr+=("$lp_pkg") ;;
    esac
  done
  lp_expected_no_kr_out="$(printf '%s\n' "${lp_no_kr_arr[@]}")"
  lp_expected_no_kr_sum="$(printf '%s\n' "${lp_no_kr_arr[@]}" | sha256sum)"

  : >"$STUB_LOG"
  : >"$lp_out_file"
  : >"$lp_err"
  set +e
  env -u SHELLOPTS -u SUDO_USER \
    HOME="$lp_home" \
    PATH="$lp_bin:$STUB_BIN:$PATH" \
    USER="plainuser" \
    LOGIN_FILE="$lp_login" \
    POLKIT_RULE_DEST="$lp_polkit" \
    DISPLAY_MANAGER_LINK="$lp_dir/display-manager.service" \
    DM_STATE_FILE="$lp_dm_state" \
    bash "$REPO_ROOT/install.sh" --list-packages --de "$lp_de" >"$lp_out_file" 2>"$lp_err"
  lp_status=$?
  set -e
  lp_out="$(cat "$lp_out_file")"
  lp_stderr="$(cat "$lp_err")"
  if [[ $lp_status -eq 0 && "$lp_out" == "$lp_expected_out" &&
    "$(sha256sum < "$lp_out_file")" == "$lp_expected_sum" &&
    -z "$lp_stderr" && ! -s "$STUB_LOG" ]] &&
    [[ ! -e "$lp_home/.bash_profile" && ! -e "$lp_home/.xinitrc" && ! -e "$lp_polkit" && ! -e "$lp_dm_state" ]] &&
    [[ "$(sha256sum < "$lp_login")" == "$lp_login_hash" ]] &&
    [[ "$(sha256sum < "$lp_home/.config/lightxdm/.xinitrc-dwm")" == "$lp_dwm_hash" ]]; then
    pass "install.sh --list-packages --de $lp_de prints exact package list without stubs or side effects"
  else
    fail "install.sh --list-packages --de $lp_de (status=$lp_status, out=$lp_out, err=$lp_stderr, log=$(cat "$STUB_LOG"))"
  fi

  for lp_kr_flags in "--list-packages --no-keyring --de $lp_de" "--de $lp_de --no-keyring --list-packages"; do
    read -r -a lp_kr_args <<<"$lp_kr_flags"
    : >"$STUB_LOG"
    : >"$lp_out_file"
    : >"$lp_err"
    set +e
    env -u SHELLOPTS -u SUDO_USER \
      HOME="$lp_home" \
      PATH="$lp_bin:$STUB_BIN:$PATH" \
      USER="plainuser" \
      LOGIN_FILE="$lp_login" \
      POLKIT_RULE_DEST="$lp_polkit" \
      DISPLAY_MANAGER_LINK="$lp_dir/display-manager.service" \
      DM_STATE_FILE="$lp_dm_state" \
      bash "$REPO_ROOT/install.sh" "${lp_kr_args[@]}" >"$lp_out_file" 2>"$lp_err"
    lp_kr_status=$?
    set -e
    lp_kr_out="$(cat "$lp_out_file")"
    lp_kr_stderr="$(cat "$lp_err")"
    if [[ $lp_kr_status -eq 0 && "$lp_kr_out" == "$lp_expected_no_kr_out" &&
      "$(sha256sum < "$lp_out_file")" == "$lp_expected_no_kr_sum" &&
      "$lp_kr_out" != *"gnome-keyring"* && "$lp_kr_out" != *"kwallet-pam"* &&
      -z "$lp_kr_stderr" && ! -s "$STUB_LOG" ]]; then
      pass "install.sh $lp_kr_flags omits keyring packages and calls no stub"
    else
      fail "install.sh $lp_kr_flags (status=$lp_kr_status, out=$lp_kr_out, err=$lp_kr_stderr, log=$(cat "$STUB_LOG"))"
    fi
  done

  : >"$STUB_LOG"
  set +e
  install_packages "$lp_de" 2>/dev/null
  lp_inst_status=$?
  set -e
  lp_inst_log="$(cat "$STUB_LOG")"
  if [[ $lp_inst_status -eq 0 && "$lp_inst_log" == "pacman -S --needed --noconfirm ${lp_expected_arr[*]}" ]]; then
    pass "install_packages $lp_de passes the exact listed packages to pacman"
  else
    fail "install_packages $lp_de vs list_packages (status=$lp_inst_status, log=$lp_inst_log)"
  fi
done

: >"$STUB_LOG"
: >"$lp_err"
set +e
lp_nosudo_out="$(
  env -u SHELLOPTS -u SUDO_USER \
    HOME="$lp_home" \
    PATH="$lp_no_sudo_bin" \
    USER="plainuser" \
    "$lp_no_sudo_bin/bash" "$REPO_ROOT/install.sh" --list-packages --de i3 2>"$lp_err"
)"
lp_nosudo_status=$?
lp_stub_main_out="$(STUB_DETECTED_DE=xfce run_main_with_stubs "$lp_bin" --list-packages --de i3 2>>"$lp_err")"
lp_stub_main_status=$?
set -e
lp_expected_i3="$(printf '%s\n' xorg-server xorg-xinit udisks2 polkit gvfs gvfs-mtp gvfs-gphoto2 gvfs-afc i3 xterm dex gnome-keyring polkit-gnome)"
if [[ $lp_nosudo_status -eq 0 && $lp_stub_main_status -eq 0 &&
  "$lp_nosudo_out" == "$lp_expected_i3" && "$lp_stub_main_out" == "$lp_expected_i3" &&
  ! -s "$lp_err" && ! -s "$STUB_LOG" ]]; then
  pass "--list-packages --de i3 succeeds without sudo or wheel membership and via main"
else
  fail "--list-packages without sudo/wheel (ns=$lp_nosudo_status:$lp_nosudo_out | main=$lp_stub_main_status:$lp_stub_main_out | err=$(cat "$lp_err") | log=$(cat "$STUB_LOG"))"
fi

if [[ $can_unshare -eq 0 ]]; then
  skip "--list-packages --de xfce exits 0 as root before check_root (unshare -r unavailable)"
else
  : >"$STUB_LOG"
  : >"$lp_err"
  set +e
  lp_root_out="$(PATH="$lp_bin:$STUB_BIN:$PATH" unshare -r bash "$REPO_ROOT/install.sh" --list-packages --de xfce 2>"$lp_err")"
  lp_root_status=$?
  set -e
  lp_expected_xfce="$(printf '%s\n' xorg-server xorg-xinit udisks2 polkit gvfs gvfs-mtp gvfs-gphoto2 gvfs-afc xfce4 xfce4-session xfce4-terminal gnome-keyring polkit-gnome)"
  if [[ $lp_root_status -eq 0 && "$lp_root_out" == "$lp_expected_xfce" && ! -s "$lp_err" && ! -s "$STUB_LOG" ]]; then
    pass "--list-packages --de xfce exits 0 before check_root even when EUID is 0"
  else
    fail "--list-packages as root (status=$lp_root_status, out=$lp_root_out, err=$(cat "$lp_err"), log=$(cat "$STUB_LOG"))"
  fi
fi

for lp_missing_de_flags in "--list-packages" "--list-packages --no-keyring"; do
  read -r -a lp_missing_de_args <<<"$lp_missing_de_flags"
  : >"$STUB_LOG"
  : >"$lp_err"
  set +e
  lp_miss_out="$(HOME="$lp_home" run_main_with_stubs "$sudo_pw_dir" "${lp_missing_de_args[@]}" 2>"$lp_err")"
  lp_miss_status=$?
  set -e
  lp_miss_err="$(cat "$lp_err")"
  if [[ $lp_miss_status -eq 1 && -z "$lp_miss_out" && "$lp_miss_err" == *"--de"* && ! -s "$STUB_LOG" ]]; then
    pass "main $lp_missing_de_flags fails without --de before running any checks or stubs"
  else
    fail "main $lp_missing_de_flags (status=$lp_miss_status, out=$lp_miss_out, err=$lp_miss_err, log=$(cat "$STUB_LOG"))"
  fi
done

for lp_wayland_de in plasma gnome budgie; do
  : >"$STUB_LOG"
  : >"$lp_err"
  set +e
  lp_wl_out="$(HOME="$lp_home" run_main_with_stubs "$sudo_pw_dir" --list-packages --de "$lp_wayland_de" 2>"$lp_err")"
  lp_wl_status=$?
  set -e
  lp_wl_err="$(cat "$lp_err")"
  if [[ $lp_wl_status -eq 1 && -z "$lp_wl_out" &&
    "$lp_wl_err" == *"$lp_wayland_de now runs only on Wayland and cannot be started with startx (see README.md)."* &&
    ! -s "$STUB_LOG" ]]; then
    pass "main --list-packages --de $lp_wayland_de refuses with Wayland message before sudo -v"
  else
    fail "main --list-packages --de $lp_wayland_de (status=$lp_wl_status, out=$lp_wl_out, err=$lp_wl_err, log=$(cat "$STUB_LOG"))"
  fi
done

for lp_bad_case in custom custom-no-packages unknown empty; do
  lp_bad_args=(--list-packages --de dwm)
  case "$lp_bad_case" in
    custom-no-packages) lp_bad_args=(--list-packages --no-packages --de dwm) ;;
    unknown) lp_bad_args=(--list-packages --de bogus) ;;
    empty) lp_bad_args=(--list-packages --de "") ;;
  esac
  : >"$STUB_LOG"
  : >"$lp_err"
  set +e
  lp_bad_out="$(HOME="$lp_home" run_main_with_stubs "$sudo_pw_dir" "${lp_bad_args[@]}" 2>"$lp_err")"
  lp_bad_status=$?
  set -e
  lp_bad_err="$(cat "$lp_err")"
  if [[ $lp_bad_status -eq 1 && -z "$lp_bad_out" && "$lp_bad_err" == *"Unsupported desktop environment:"* && ! -s "$STUB_LOG" ]]; then
    pass "main rejects non-built-in --list-packages target ($lp_bad_case) before sudo -v"
  else
    fail "main --list-packages rejection ($lp_bad_case, status=$lp_bad_status, out=$lp_bad_out, err=$lp_bad_err, log=$(cat "$STUB_LOG"))"
  fi
done

# Case 74: multi-desktop detection lists all matches, skips Wayland-only desktops when supported ones exist, and prompts when two or more supported desktops remain
multi_detect_bin="$TMP_DIR/pacman_multi_detect"
mkdir -p "$multi_detect_bin"
cat >"$multi_detect_bin/pacman" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-Qq" && $# -eq 2 ]]; then
  case "$2" in
    xfce4-session | i3-wm)
      echo "$2"
      exit 0
      ;;
  esac
fi
exit 1
EOF
chmod +x "$multi_detect_bin/pacman"

multi_detect_out="$TMP_DIR/multi_detect_out"
set +e
(
  set -e
  export PATH="$multi_detect_bin:$PATH"
  detect_de
) >"$multi_detect_out"
status=$?
set -e
output="$(cat "$multi_detect_out")"
if [[ $status -eq 0 && "$output" == $'xfce\ni3' &&
  "$(sha256sum < "$multi_detect_out")" == "$(printf 'xfce\ni3\n' | sha256sum)" ]]; then
  pass "detect_de lists two installed desktops one per line"
else
  fail "detect_de two desktops (status=$status, output=$output)"
fi

unset PS3
multi_prompt_out="$TMP_DIR/multi_prompt_out"
multi_prompt_err="$TMP_DIR/multi_prompt_err"
set +e
prompt_detected_de_selection xfce i3 <<<$'99\n2\n' >"$multi_prompt_out" 2>"$multi_prompt_err"
status=$?
set -e
output="$(cat "$multi_prompt_out")"
err_output="$(cat "$multi_prompt_err")"
if [[ $status -eq 0 && "$output" == "i3" && -z "${PS3+x}" &&
  "$(sha256sum < "$multi_prompt_out")" == "$(printf 'i3\n' | sha256sum)" &&
  "$err_output" == *"1) XFCE"* && "$err_output" == *"2) i3"* && "$err_output" == *"3) Quit"* &&
  "$err_output" != *"LXQt"* && "$err_output" == *"Invalid option 99"* ]]; then
  pass "prompt_detected_de_selection offers only detected labels plus Quit and maps choice without leaking PS3"
else
  fail "prompt_detected_de_selection xfce i3 (status=$status, out=$output, err=$err_output, PS3=${PS3-<unset>})"
fi

: >"$STUB_LOG"
set +e
output="$(STUB_DETECTED_DE=$'plasma\nxfce' run_main_with_stubs "$sudo_pw_dir" 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
expected_px_log=$'sudo -v\ndetect_de\ninstall_packages xfce\ncopy_dotfiles xfce\nconfigure_pam xfce\ninstall_polkit_rule\ndisable_display_managers'
if [[ $status -eq 0 && "$log_content" == "$expected_px_log" &&
  "$output" == *"Wayland-only"* && "$output" == *"plasma"* &&
  "$output" == *"Detected desktop environment: xfce"* &&
  "$output" == *"lightXDM install complete!"* && "$output" == *"- xfce "* ]]; then
  pass "main skips Wayland-only plasma and configures xfce when plasma and xfce are detected"
else
  fail "main plasma+xfce (status=$status, log=$log_content, output=$output)"
fi

: >"$STUB_LOG"
set +e
output="$(STUB_DETECTED_DE=$'plasma\ngnome\nlxqt' run_main_with_stubs "$sudo_pw_dir" 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
wayland_line_count="$(grep -Fc 'Wayland-only' <<<"$output" || true)"
expected_pgl_log=$'sudo -v\ndetect_de\ninstall_packages lxqt\ncopy_dotfiles lxqt\nconfigure_pam lxqt\ninstall_polkit_rule\ndisable_display_managers'
if [[ $status -eq 0 && "$log_content" == "$expected_pgl_log" &&
  "$wayland_line_count" -eq 1 &&
  "$output" == *"plasma gnome"* &&
  "$output" == *"Detected desktop environment: lxqt"* ]]; then
  pass "main logs multiple Wayland-only desktops once and configures remaining lxqt"
else
  fail "main plasma+gnome+lxqt (status=$status, count=$wayland_line_count, log=$log_content, output=$output)"
fi

for all_wl_detected in $'plasma\ngnome' $'gnome\nbudgie'; do
  first_wl="${all_wl_detected%%$'\n'*}"
  : >"$STUB_LOG"
  set +e
  output="$(STUB_DETECTED_DE="$all_wl_detected" run_main_with_stubs "$sudo_pw_dir" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -eq 1 && "$log_content" == $'sudo -v\ndetect_de' &&
    "$output" == *"$first_wl now runs only on Wayland and cannot be started with startx (see README.md)."* &&
    "$output" != *"lightXDM install complete!"* ]]; then
    pass "main keeps Wayland refusal when only Wayland desktops are detected (${all_wl_detected//$'\n'/+})"
  else
    fail "main all-Wayland multi-detect (${all_wl_detected//$'\n'/+}, status=$status, log=$log_content, output=$output)"
  fi
done

for multi_choice_detected in $'xfce\ni3' $'plasma\nxfce\ni3'; do
  : >"$STUB_LOG"
  set +e
  output="$(STUB_DETECTED_DE="$multi_choice_detected" STUB_REAL_PROMPT=1 run_main_with_stubs "$sudo_pw_dir" <<<"2" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  expected_i3_log=$'sudo -v\ndetect_de\ninstall_packages i3\ncopy_dotfiles i3\nconfigure_pam i3\ninstall_polkit_rule\ndisable_display_managers'
  wl_note_ok=0
  if [[ "$multi_choice_detected" == plasma* && "$output" == *"Wayland-only"* && "$output" == *"plasma"* ]] ||
    [[ "$multi_choice_detected" != plasma* && "$output" != *"Wayland-only"* ]]; then
    wl_note_ok=1
  fi
  if [[ $status -eq 0 && $wl_note_ok -eq 1 && "$log_content" == "$expected_i3_log" &&
    "$output" == *"1) XFCE"* && "$output" == *"2) i3"* && "$output" == *"3) Quit"* &&
    "$output" == *"lightXDM install complete!"* && "$output" == *"- i3 "* ]]; then
    pass "main configures i3 when selected from detected chooser (${multi_choice_detected//$'\n'/+})"
  else
    fail "main multi-detect select i3 (${multi_choice_detected//$'\n'/+}, status=$status, log=$log_content, output=$output)"
  fi
done

: >"$STUB_LOG"
set +e
output="$(STUB_DETECTED_DE=$'xfce\ni3' STUB_REAL_PROMPT=1 run_main_with_stubs "$sudo_pw_dir" <<<"3" 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 0 && "$log_content" == $'sudo -v\ndetect_de' &&
  "$output" != *"lightXDM install complete!"* ]]; then
  pass "main exits 0 without installing when Quit is chosen from detected chooser"
else
  fail "main detected chooser Quit via stdin (status=$status, log=$log_content, output=$output)"
fi

: >"$STUB_LOG"
set +e
output="$(STUB_DETECTED_DE=$'xfce\ni3' STUB_PROMPT_RC=2 run_main_with_stubs "$sudo_pw_dir" 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 0 && "$log_content" == $'sudo -v\ndetect_de\nprompt_detected_de_selection xfce i3' &&
  "$output" != *"lightXDM install complete!"* ]]; then
  pass "main exits 0 without installing when stubbed detected chooser returns 2"
else
  fail "main detected chooser Quit via STUB_PROMPT_RC=2 (status=$status, log=$log_content, output=$output)"
fi

: >"$STUB_LOG"
set +e
output="$(STUB_DETECTED_DE=$'xfce\ni3' STUB_REAL_PROMPT=1 run_main_with_stubs "$sudo_pw_dir" </dev/null 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 1 && "$log_content" == $'sudo -v\ndetect_de' &&
  "$output" == *"No desktop environment was chosen"* && "$output" == *"--de"* &&
  "$output" != *"lightXDM install complete!"* ]]; then
  pass "main exits 1 with a --de hint on detected chooser EOF"
else
  fail "main detected chooser EOF (status=$status, log=$log_content, output=$output)"
fi

# --init-template writes an editable user template and exits before sudo or any system change
init_home="$TMP_DIR/init_home"
mkdir -p "$init_home"
: >"$STUB_LOG"
set +e
out_builtin="$(HOME="$init_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template --de xfce 2>&1)"
status_builtin=$?
out_again="$(HOME="$init_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template --de xfce 2>&1)"
status_again=$?
out_custom="$(HOME="$init_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template --de dwm 2>&1)"
status_custom=$?
out_wayland="$(HOME="$init_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template --de gnome 2>&1)"
status_wayland=$?
out_no_de="$(HOME="$init_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template 2>&1)"
status_no_de=$?
set -e
init_xfce="$init_home/.config/lightxdm/.xinitrc-xfce"
init_dwm="$init_home/.config/lightxdm/.xinitrc-dwm"
if [[ $status_builtin -eq 0 && "$out_builtin" == *"Created $init_xfce"* ]] && cmp -s "$init_xfce" "$REPO_ROOT/dotfiles/.xinitrc-xfce" &&
  [[ "$(stat -c '%a' "$init_xfce")" == 755 && $status_again -eq 1 && "$out_again" == *"already exists"* ]]; then
  pass "install.sh --init-template copies a built-in template once and refuses to overwrite it"
else
  fail "install.sh --init-template built-in (status=$status_builtin/$status_again, output=$out_builtin / $out_again)"
fi
if [[ $status_custom -eq 0 && "$(stat -c '%a' "$init_dwm" 2>/dev/null)" == 755 ]] && bash -n "$init_dwm" &&
  grep -qx 'exec dwm' "$init_dwm" && grep -qx 'export DESKTOP_SESSION=dwm' "$init_dwm" &&
  grep -qx 'export XDG_CURRENT_DESKTOP=dwm' "$init_dwm" && ! grep -q 'i3' "$init_dwm" &&
  [[ "$out_custom" == *"--no-packages --de dwm"* ]]; then
  pass "install.sh --init-template renders a custom window manager template from the i3 one"
else
  fail "install.sh --init-template custom (status=$status_custom, output=$out_custom, content=$(cat "$init_dwm" 2>/dev/null))"
fi
if [[ $status_wayland -eq 1 && ! -e "$init_home/.config/lightxdm/.xinitrc-gnome" && $status_no_de -eq 1 &&
  "$out_no_de" == *"--init-template requires --de"* && ! -s "$STUB_LOG" ]]; then
  pass "install.sh --init-template refuses Wayland-only ids and a missing --de, and never calls sudo"
else
  fail "install.sh --init-template refusals (status=$status_wayland/$status_no_de, log=$(cat "$STUB_LOG"), output=$out_wayland / $out_no_de)"
fi

set +e
out_mixed="$(HOME="$init_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --list-packages --init-template --de lxqt 2>&1)"
status_mixed=$?
set -e
if [[ $status_mixed -eq 1 && "$out_mixed" == *"--init-template takes only --de"* && ! -e "$init_home/.config/lightxdm/.xinitrc-lxqt" ]]; then
  pass "install.sh --init-template refuses other options before writing"
else
  fail "install.sh --init-template with --list-packages (status=$status_mixed, output=$out_mixed)"
fi

# uninstall.sh --keyring-only removes lightXDM's PAM lines and leaves everything else in place
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh --keyring-only (unshare -r unavailable)"
else
  ko_dir="$TMP_DIR/keyring_only"
  mkdir -p "$ko_dir/home"
  printf '#%%PAM-1.0\nauth       include      system-local-login\n' >"$ko_dir/login.lightxdm.bak"
  cp "$ko_dir/login.lightxdm.bak" "$ko_dir/login"
  cp "$ko_dir/login.lightxdm.bak" "$ko_dir/login.expected"
  printf 'auth       optional   pam_gnome_keyring.so\nsession    optional   pam_gnome_keyring.so auto_start\n' >>"$ko_dir/login"
  printf '[Service]\n' >"$ko_dir/autologin.conf"
  printf 'rule\n' >"$ko_dir/polkit.rules"
  printf 'xfce\n' >"$ko_dir/home/.xinitrc"
  set +e
  output="$(env -u SUDO_USER TARGET_HOME= LOGIN_FILE="$ko_dir/login" AUTOLOGIN_DROPIN="$ko_dir/autologin.conf" POLKIT_RULE="$ko_dir/polkit.rules" DM_STATE_FILE="$ko_dir/dm" unshare -r bash "$REPO_ROOT/uninstall.sh" --keyring-only 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && "$output" == *"Done (--keyring-only)"* && -f "$ko_dir/autologin.conf" && -f "$ko_dir/polkit.rules" && -f "$ko_dir/home/.xinitrc" ]] &&
    cmp -s "$ko_dir/login" "$ko_dir/login.expected"; then
    pass "uninstall.sh --keyring-only restores PAM and keeps autologin, Polkit and dotfiles"
  else
    fail "uninstall.sh --keyring-only (status=$status, output=$output, login=$(cat "$ko_dir/login"))"
  fi
fi

# uninstall.sh warns about an autologin drop-in it did not write
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh warns about remaining autologin drop-ins (unshare -r unavailable)"
else
  ua_dir="$TMP_DIR/uninstall_autologin_warn"
  mkdir -p "$ua_dir/getty.d" "$ua_dir/home"
  # shellcheck disable=SC2016  # $TERM is literal systemd syntax
  printf '[Service]\nExecStart=\nExecStart=-/usr/bin/agetty --autologin someone --noclear %%I $TERM\n' >"$ua_dir/getty.d/lightxdm-autologin.conf"
  cp "$ua_dir/getty.d/lightxdm-autologin.conf" "$ua_dir/getty.d/zz-local.conf"
  printf '[Service]\nTTYVTDisallocate=no\n' >"$ua_dir/getty.d/plain.conf"
  set +e
  output="$(env TARGET_HOME="$ua_dir/home" LOGIN_FILE="$ua_dir/login" AUTOLOGIN_DROPIN="$ua_dir/getty.d/lightxdm-autologin.conf" OVERRIDE_FILE="$ua_dir/getty.d/override.conf" POLKIT_RULE="$ua_dir/polkit" DM_STATE_FILE="$ua_dir/dm" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && ! -e "$ua_dir/getty.d/lightxdm-autologin.conf" && "$output" == *"Warning: $ua_dir/getty.d/zz-local.conf still enables autologin."* &&
    "$output" != *"plain.conf"* ]]; then
    pass "uninstall.sh warns by name about an autologin drop-in it did not write"
  else
    fail "uninstall.sh remaining autologin warning (status=$status, output=$output)"
  fi
fi

exit "$failures"
