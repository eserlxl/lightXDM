#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# tests/run.sh: Behavior test harness for lightXDM scripts
# Test cases change HOME/USER inside subshells on purpose, to keep each case isolated.
# shellcheck disable=SC2030,SC2031
set -euo pipefail

strict_mode=0

print_harness_help() {
  cat <<EOF
Usage: bash $0 [-h|--help] [--strict]

Run the behavior test suite for lightXDM scripts.

Options:
  -h, --help  Show this help message and exit
  --strict    Exit 1 if any test check is skipped (also enabled by LIGHTXDM_STRICT_TESTS=1)
EOF
}

parse_harness_args() {
  local usage="Usage: bash $0 [-h|--help] [--strict]"
  local show_help=0

  if [[ "${LIGHTXDM_STRICT_TESTS:-0}" == "1" ]]; then
    strict_mode=1
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        show_help=1
        shift
        ;;
      --strict)
        strict_mode=1
        shift
        ;;
      *)
        echo "$usage" >&2
        exit 1
        ;;
    esac
  done

  if [[ $show_help -eq 1 ]]; then
    print_harness_help
    exit 0
  fi
}

passes=0
skips=0
failures=0

pass() {
  echo "PASS: $1"
  passes=$((passes + 1))
}

skip() {
  echo "SKIP: $1"
  skips=$((skips + 1))
}

fail() {
  echo "FAIL: $1"
  failures=$((failures + 1))
}

finish_harness() {
  echo "SUMMARY: PASS=$passes SKIP=$skips FAIL=$failures"
  if [[ $failures -gt 0 || ( $strict_mode -eq 1 && $skips -gt 0 ) ]]; then
    exit 1
  fi
  exit 0
}

parse_harness_args "$@"
set --

REPO_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# The command each script prints to run another one from this checkout: bash and its escaped path.
printf -v CMD_INSTALL 'bash %q' "$REPO_ROOT/install.sh"
printf -v CMD_UNINSTALL 'bash %q' "$REPO_ROOT/uninstall.sh"
printf -v CMD_AUTOLOGIN 'bash %q' "$REPO_ROOT/enable-autologin.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

unset SUDO_USER LIGHTXDM_STRICT_TESTS XDG_STATE_HOME
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
# Owner and backup-file status of the login file, for install.sh's login_file_is_stock.
if [[ "${1:-}" == -Qqo && -n "${STUB_PACMAN_OWNER:-}" ]]; then
  echo "$STUB_PACMAN_OWNER"
  exit 0
elif [[ "${1:-}" == -Qii && -n "${STUB_PACMAN_BACKUP:-}" ]]; then
  echo "Backup Files    : $STUB_PACMAN_BACKUP"
  exit 0
fi
exit "${STUB_PACMAN_EXIT:-0}"
EOF

cat >"$STUB_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == is-enabled && "${2:-}" == getty@tty1.service ]]; then
  echo enabled
  exit 0
fi
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
export SESSION_ROOT="$TMP_DIR/session_root"
mkdir -p "$SESSION_ROOT/usr/lib/security" "$SESSION_ROOT/usr/bin"
touch "$SESSION_ROOT/usr/lib/security/pam_kwallet5.so" "$SESSION_ROOT/usr/lib/security/pam_gnome_keyring.so"
cp "$STUB_BIN/chown" "$SESSION_ROOT/usr/lib/plasma-dbus-run-session-if-needed"
cp "$STUB_BIN/chown" "$SESSION_ROOT/usr/bin/startplasma-wayland"
cp "$STUB_BIN/chown" "$SESSION_ROOT/usr/bin/gnome-session"
cp "$STUB_BIN/chown" "$SESSION_ROOT/usr/bin/startbudgielabwc"
export PATH="$STUB_BIN:$PATH"
export STUB_LOG="$TMP_DIR/stub.log"
export LOGIN_FILE="$TMP_DIR/login"
export GNOME_SESSION_TYPE_DEST="$TMP_DIR/gnome-session-type.conf"
export AUTOLOGIN_DROPIN_DIR="$TMP_DIR/getty@tty1.service.d"
export POLKIT_RULE_SRC="$REPO_ROOT/polkit/49-nopasswd.rules"
export POLKIT_RULE_DEST="$TMP_DIR/49-nopasswd.rules"
export DISPLAY_MANAGER_LINK="$TMP_DIR/display-manager.service"
export DM_STATE_FILE="$TMP_DIR/lightxdm/disabled-display-managers"
export PAM_KEYRING_STATE="$TMP_DIR/lightxdm/pam-keyring"

# shellcheck source=install.sh disable=SC1091
source "$REPO_ROOT/install.sh"

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

# Case 4: prompt_de_selection returns 2 with empty stdout on Quit ("10")
set +e
output="$(prompt_de_selection <<<"10" 2>/dev/null)"
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

# Case 8b: configure_pam replaces lightXDM-added keyring lines when switching desktops and keeps pre-install backup lines
rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
write_stock_login
configure_pam "xfce" 2>/dev/null
switch_to_plasma_log="$(configure_pam "plasma" 2>&1)"
plasma_after_switch="$(cat "$LOGIN_FILE")"
configure_pam "plasma" 2>/dev/null
plasma_rerun_after_switch="$(cat "$LOGIN_FILE")"
if [[ "$plasma_after_switch" == "$plasma_rerun_after_switch" &&
  "$switch_to_plasma_log" == *"pam_gnome_keyring.so"* ]] &&
  grep -Fxq -- "$PAM_KWALLET_AUTH" "$LOGIN_FILE" &&
  grep -Fxq -- "$PAM_KWALLET_SESSION" "$LOGIN_FILE" &&
  ! grep -q 'pam_gnome_keyring\.so' "$LOGIN_FILE"; then
  pass "configure_pam xfce then plasma leaves only KWallet lines and is idempotent on rerun"
else
  fail "configure_pam xfce then plasma (content=$plasma_rerun_after_switch, log=$switch_to_plasma_log)"
fi

rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
write_stock_login
configure_pam "plasma" 2>/dev/null
switch_to_xfce_log="$(configure_pam "xfce" 2>&1)"
xfce_after_switch="$(cat "$LOGIN_FILE")"
configure_pam "xfce" 2>/dev/null
xfce_rerun_after_switch="$(cat "$LOGIN_FILE")"
if [[ "$xfce_after_switch" == "$xfce_rerun_after_switch" &&
  "$switch_to_xfce_log" == *"pam_kwallet5.so"* ]] &&
  grep -Fxq -- "$PAM_GNOME_KEYRING_AUTH" "$LOGIN_FILE" &&
  grep -Fxq -- "$PAM_GNOME_KEYRING_SESSION" "$LOGIN_FILE" &&
  ! grep -q 'pam_kwallet5\.so' "$LOGIN_FILE"; then
  pass "configure_pam plasma then xfce leaves only GNOME Keyring lines and is idempotent on rerun"
else
  fail "configure_pam plasma then xfce (content=$xfce_rerun_after_switch, log=$switch_to_xfce_log)"
fi

rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
write_stock_login
printf '%s\n' "$PAM_GNOME_KEYRING_AUTH" >>"$LOGIN_FILE"
configure_pam "xfce" 2>/dev/null
configure_pam "plasma" 2>/dev/null
preexisting_switch_content="$(cat "$LOGIN_FILE")"
if grep -Fxq -- "$PAM_GNOME_KEYRING_AUTH" "$LOGIN_FILE" &&
  ! grep -Fxq -- "$PAM_GNOME_KEYRING_SESSION" "$LOGIN_FILE" &&
  grep -Fxq -- "$PAM_KWALLET_AUTH" "$LOGIN_FILE" &&
  grep -Fxq -- "$PAM_KWALLET_SESSION" "$LOGIN_FILE"; then
  pass "configure_pam keeps a pam_gnome_keyring.so line already in the backup when switching to plasma"
else
  fail "configure_pam pre-existing pam_gnome_keyring.so on switch to plasma (content=$preexisting_switch_content)"
fi

# Case 8c: missing keyring modules warn without preventing PAM configuration
missing_module_ok=1
for keyring_de in plasma xfce custom-kwallet; do
  if [[ "$keyring_de" == plasma || "$keyring_de" == custom-kwallet ]]; then
    keyring_backend=kwallet
    keyring_module=pam_kwallet5.so
    keyring_package=kwallet-pam
    keyring_auth="$PAM_KWALLET_AUTH"
    keyring_session="$PAM_KWALLET_SESSION"
  else
    keyring_backend=gnome
    keyring_module=pam_gnome_keyring.so
    keyring_package=gnome-keyring
    keyring_auth="$PAM_GNOME_KEYRING_AUTH"
    keyring_session="$PAM_GNOME_KEYRING_SESSION"
  fi
  rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
  write_stock_login
  mv "$SESSION_ROOT/usr/lib/security/$keyring_module" "$SESSION_ROOT/usr/lib/security/$keyring_module.off"
  missing_log="$(configure_pam "$keyring_de" 0 "$keyring_backend" 2>&1)"
  if [[ "$missing_log" != *"WARNING: $keyring_module is not installed (/usr/lib/security/$keyring_module); install $keyring_package or the keyring will not unlock at login."* ]] ||
    ! grep -Fxq -- "$keyring_auth" "$LOGIN_FILE" ||
    ! grep -Fxq -- "$keyring_session" "$LOGIN_FILE"; then
    missing_module_ok=0
  fi
  mv "$SESSION_ROOT/usr/lib/security/$keyring_module.off" "$SESSION_ROOT/usr/lib/security/$keyring_module"
  rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
  write_stock_login
  installed_log="$(configure_pam "$keyring_de" 0 "$keyring_backend" 2>&1)"
  if [[ "$installed_log" == *"is not installed"* ]]; then
    missing_module_ok=0
  fi
done
if [[ "$missing_module_ok" -eq 1 ]]; then
  pass "configure_pam warns about missing keyring modules and still configures PAM"
else
  fail "configure_pam missing keyring module warning or configuration"
fi

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
    if [[ "${STUB_CHECK_SUDO:-0}" == 1 ]]; then
      ( sudo true ) || return
    fi
    if [[ "$1" == "${STUB_FAIL_STEP:-}" ]]; then
      return "${STUB_FAIL_STATUS:-1}"
    fi
  }
  if [[ "${STUB_REAL_INSTALL_PACKAGES:-0}" != 1 ]]; then
    install_packages() { stub_install_step install_packages "$@"; }
  fi
  if [[ "${STUB_REAL_TTY1_CHECK:-0}" != 1 ]]; then
    check_tty1_getty() { :; }
  fi
  if [[ "${STUB_REAL_COPY_DOTFILES:-0}" != 1 ]]; then
    copy_dotfiles() { stub_install_step copy_dotfiles "$1"; }
  fi
  configure_pam() { stub_install_step configure_pam "$1"; }
  configure_gnome_session_type() {
    if [[ "${STUB_RECORD_GNOME_STEP:-0}" == 1 || "${STUB_FAIL_STEP:-}" == configure_gnome_session_type ]]; then
      stub_install_step configure_gnome_session_type "$@"
    fi
  }
  disable_display_managers() {
    stub_install_step disable_display_managers || return
    # shellcheck disable=SC2034  # main's summary reads it through bash's dynamic scope
    display_manager_disabled="${STUB_DM_DISABLED:-0}"
  }
  enable_autologin() { stub_install_step enable_autologin "$1"; }
  main "$@"
)

# A persistent getty mask must stop the handover before any install step.
tty1_bin="$TMP_DIR/tty1_bin"
tty1_home="$TMP_DIR/tty1_home"
mkdir -p "$tty1_bin" "$tty1_home"
cat >"$tty1_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == 'is-enabled getty@tty1.service' ]]; then
  printf '%s\n' "$*" >>"$TTY1_CHECK_LOG"
  printf '%s\n' "$STUB_TTY1_STATE"
  case "$STUB_TTY1_STATE" in
    masked | masked-runtime) exit 1 ;;
    *) exit 0 ;;
  esac
fi
echo "systemctl $*" >>"$STUB_LOG"
case "${1:-}" in
  list-unit-files) exit 0 ;;
  is-enabled) echo disabled; exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tty1_bin/systemctl"
for tty1_state in masked masked-runtime enabled static; do
  : >"$STUB_LOG"
  : >"$TMP_DIR/tty1-check.log"
  set +e
  output="$(HOME="$tty1_home" STUB_REAL_TTY1_CHECK=1 STUB_RECORD_GNOME_STEP=1 \
    STUB_TTY1_STATE="$tty1_state" TTY1_CHECK_LOG="$TMP_DIR/tty1-check.log" \
    run_main_with_stubs "$tty1_bin:$sudo_pw_dir" --de i3 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  tty1_expected_log="sudo -v"
  if [[ "$tty1_state" != masked ]]; then
    tty1_expected_log+=$'\ninstall_packages i3\ncopy_dotfiles i3\nconfigure_pam i3\nconfigure_gnome_session_type i3 '"${USER:-testuser}"$'\ndisable_display_managers'
  fi
  if [[ "$(cat "$TMP_DIR/tty1-check.log")" == 'is-enabled getty@tty1.service' &&
    "$log_content" == "$tty1_expected_log" ]] &&
    { [[ "$tty1_state" == masked && $status -eq 1 &&
         "$output" == *'getty@tty1.service is masked'* &&
         "$output" == *'next boot would have no TTY1 login'* &&
         "$output" == *'sudo systemctl unmask getty@tty1.service'* &&
         "$output" != *'lightXDM install complete!'* ]] ||
      [[ "$tty1_state" != masked && $status -eq 0 &&
         "$output" == *'lightXDM install complete!'* ]]; }; then
    pass "main refuses only a persistent TTY1 getty mask ($tty1_state) before install steps"
  else
    fail "main TTY1 getty check ($tty1_state, status=$status, log=$log_content, output=$output)"
  fi

  : >"$STUB_LOG"
  : >"$TMP_DIR/tty1-check.log"
  set +e
  output="$(env -u SHELLOPTS -u SUDO_USER HOME="$tty1_home" PATH="$tty1_bin:$PATH" \
    STUB_TTY1_STATE="$tty1_state" TTY1_CHECK_LOG="$TMP_DIR/tty1-check.log" \
    bash "$REPO_ROOT/install.sh" --dry-run --de i3 2>&1)"
  status=$?
  set -e
  if [[ "$(cat "$TMP_DIR/tty1-check.log")" == 'is-enabled getty@tty1.service' ]] &&
    ! grep -Eq '^(sudo |pacman |systemctl (disable|enable|daemon-reload))' "$STUB_LOG" &&
    { [[ "$tty1_state" == masked && $status -eq 1 && ! -s "$STUB_LOG" &&
         "$output" == *'getty@tty1.service is masked'* &&
         "$output" == *'sudo systemctl unmask getty@tty1.service'* &&
         "$output" != *'Desktop:'* ]] ||
      [[ "$tty1_state" != masked && $status -eq 0 && "$output" == *'Desktop: i3'* ]]; }; then
    pass "--dry-run refuses only a persistent TTY1 getty mask ($tty1_state) without changes"
  else
    fail "--dry-run TTY1 getty check ($tty1_state, status=$status, log=$(cat "$STUB_LOG"), output=$output)"
  fi
done

# Non-interactive installs never allow sudo to prompt.
ni_bin="$TMP_DIR/non_interactive_bin"
ni_home="$TMP_DIR/non_interactive_home"
mkdir -p "$ni_bin" "$ni_home"
cat >"$ni_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NI_SUDO_LOG"
[[ "${NI_REJECT:-0}" != 1 ]]
EOF
chmod +x "$ni_bin/sudo"
export NI_SUDO_LOG="$TMP_DIR/non_interactive_sudo.log"
printf 'unchanged\n' >"$ni_home/sentinel"
: >"$NI_SUDO_LOG"
: >"$STUB_LOG"
set +e
ni_output="$(HOME="$ni_home" STUB_CHECK_SUDO=1 run_main_with_stubs "$ni_bin" --non-interactive --de i3 2>&1)"
ni_status=$?
set -e
if [[ $ni_status -eq 0 && $(wc -l <"$NI_SUDO_LOG") -gt 1 ]] && ! grep -Evq -- '^-n( |$)' "$NI_SUDO_LOG"; then
  pass "--non-interactive passes -n to every sudo call, including in subshells"
else
  fail "--non-interactive sudo arguments (status=$ni_status, output=$ni_output)"
fi
# The finished install saved its choices for --update; the checks below expect a home with only the sentinel.
rm -rf -- "$ni_home/.local"
: >"$NI_SUDO_LOG"
: >"$STUB_LOG"
set +e
ni_missing="$(HOME="$ni_home" run_main_with_stubs "$ni_bin" --non-interactive 2>&1)"
ni_missing_status=$?
ni_conflict="$(HOME="$ni_home" run_main_with_stubs "$ni_bin" --init-template --non-interactive --de i3 2>&1)"
ni_conflict_status=$?
set -e
if [[ $ni_missing_status -ne 0 && "$ni_missing" == *'--non-interactive requires --de'* &&
  $ni_conflict_status -ne 0 && "$ni_conflict" == *'--init-template takes only'* &&
  ! -s "$NI_SUDO_LOG" && ! -s "$STUB_LOG" && $(cat "$ni_home/sentinel") == unchanged &&
  $(find "$ni_home" -type f | wc -l) -eq 1 ]]; then
  pass "--non-interactive requires --de and is refused by --init-template before changes"
else
  fail "--non-interactive argument validation (missing=$ni_missing, conflict=$ni_conflict)"
fi
: >"$NI_SUDO_LOG"
: >"$STUB_LOG"
set +e
ni_denied="$(HOME="$ni_home" NI_REJECT=1 STUB_REAL_COPY_DOTFILES=1 run_main_with_stubs "$ni_bin" --non-interactive --de i3 2>&1)"
ni_denied_status=$?
set -e
if [[ $ni_denied_status -ne 0 && "$ni_denied" == *'Failed to authenticate with sudo'* &&
  $(cat "$NI_SUDO_LOG") == '-n -v' && ! -s "$STUB_LOG" &&
  $(cat "$ni_home/sentinel") == unchanged && $(find "$ni_home" -type f | wc -l) -eq 1 ]]; then
  pass "--non-interactive stops before changes when sudo credentials are unavailable"
else
  fail "--non-interactive sudo rejection (status=$ni_denied_status, output=$ni_denied)"
fi

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
if [[ $status -eq 23 && "$output" == *"Install stopped during enable_autologin; already done: install_packages copy_dotfiles configure_gnome_session_type disable_display_managers"* &&
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
for failed_install_step in install_packages copy_dotfiles configure_pam configure_gnome_session_type disable_display_managers; do
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
  grep -Fxq '=> Install stopped during disable_display_managers; already done: copy_dotfiles configure_gnome_session_type' <<<"$output"; then
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
if [[ $status -eq 1 && "$output" == *"No desktop environment was chosen. Pass --de <id> to select one (plasma, gnome, budgie, xfce, lxqt, lxde, mate, cinnamon, i3). Exiting."* && "$log_content" == "sudo -v" ]]; then
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

# Case 10c: GNOME and Budgie run on Wayland when detected or explicitly selected
for wayland_de in gnome budgie; do
  for wayland_mode in detected explicit skip-options; do
    wayland_args=()
    expected_wayland_log=$'sudo -v\ndetect_de'
    if [[ "$wayland_mode" != "detected" ]]; then
      wayland_args=(--de "$wayland_de")
      expected_wayland_log="sudo -v"
    fi
    if [[ "$wayland_mode" == "skip-options" ]]; then
      wayland_args+=(--no-packages --no-keyring --no-polkit-rule)
      expected_wayland_log+=$'\ncopy_dotfiles '"$wayland_de"$'\ndisable_display_managers'
    else
      expected_wayland_log+=$'\ninstall_packages '"$wayland_de"$'\ncopy_dotfiles '"$wayland_de"$'\nconfigure_pam '"$wayland_de"$'\ndisable_display_managers'
    fi
    : >"$STUB_LOG"
    set +e
    output="$(STUB_DETECTED_DE="$wayland_de" run_main_with_stubs "$sudo_pw_dir" "${wayland_args[@]}" 2>&1)"
    status=$?
    set -e
    log_content="$(cat "$STUB_LOG")"
    if [[ $status -eq 0 && "$log_content" == "$expected_wayland_log" &&
      "$output" == *"lightXDM install complete!"* && "$output" == *"- $wayland_de will auto-start on TTY1"* &&
      "$output" != *"startx"* && "$output" != *"Install stopped during"* ]]; then
      pass "main configures $wayland_de on Wayland ($wayland_mode)"
    else
      fail "main $wayland_de Wayland ($wayland_mode, status=$status, log=$log_content, output=$output)"
    fi
  done
done

# Case 10d: all three Wayland and all six X11 desktops run every installation step
for supported_de in plasma gnome xfce lxqt lxde mate cinnamon budgie i3; do
  : >"$STUB_LOG"
  set +e
  output="$(STUB_DETECTED_DE="$supported_de" run_main_with_stubs "$sudo_pw_dir" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -eq 0 && "$log_content" == *"install_packages $supported_de"* &&
    "$log_content" == *"copy_dotfiles $supported_de"* && "$log_content" == *"configure_pam $supported_de"* &&
    "$log_content" == *"disable_display_managers"* ]]; then
    pass "main still configures $supported_de"
  else
    fail "main with $supported_de (status=$status, log=$log_content, output=$output)"
  fi
done

: >"$STUB_LOG"
set +e
output="$(run_main_with_stubs "$sudo_pw_dir" --de plasma 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 0 && "$log_content" == $'sudo -v\ninstall_packages plasma\ncopy_dotfiles plasma\nconfigure_pam plasma\ndisable_display_managers' &&
  "$output" == *"lightXDM install complete!"* && "$output" != *"startx"* ]]; then
  pass "main --de plasma proceeds through all installation steps without startx"
else
  fail "main --de plasma (status=$status, log=$log_content, output=$output)"
fi

plasma_dotfiles_home="$TMP_DIR/home_plasma_wayland"
mkdir -p "$plasma_dotfiles_home"
(
  export HOME="$plasma_dotfiles_home"
  export USER="${USER:-testuser}"
  copy_dotfiles "plasma" 2>/dev/null
)
if [[ -f "$plasma_dotfiles_home/.wayland-session" && ! -L "$plasma_dotfiles_home/.wayland-session" &&
  "$(stat -c '%a' "$plasma_dotfiles_home/.wayland-session")" == "755" &&
  "$(sha256sum < "$plasma_dotfiles_home/.wayland-session")" == "$(sha256sum < "$REPO_ROOT/dotfiles/.wayland-session-plasma")" &&
  -f "$plasma_dotfiles_home/.gpg-agent-kwallet" && ! -e "$plasma_dotfiles_home/.gpg-agent-gnome" &&
  ! -e "$plasma_dotfiles_home/.xinitrc" && ! -L "$plasma_dotfiles_home/.xinitrc" ]]; then
  pass "copy_dotfiles plasma installs ~/.wayland-session (mode 755) and ~/.gpg-agent-kwallet without creating ~/.xinitrc"
else
  fail "copy_dotfiles plasma Wayland files"
fi

for wl_copy_de in gnome budgie; do
  wl_copy_home="$TMP_DIR/home_${wl_copy_de}_wayland"
  mkdir -p "$wl_copy_home"
  (
    export HOME="$wl_copy_home"
    copy_dotfiles "$wl_copy_de" 2>/dev/null
  )
  if [[ -f "$wl_copy_home/.wayland-session" && ! -L "$wl_copy_home/.wayland-session" &&
    "$(stat -c '%a' "$wl_copy_home/.wayland-session")" == 755 &&
    "$(sha256sum < "$wl_copy_home/.wayland-session")" == "$(sha256sum < "$REPO_ROOT/dotfiles/.wayland-session-$wl_copy_de")" &&
    -f "$wl_copy_home/.gpg-agent-gnome" && ! -e "$wl_copy_home/.gpg-agent-kwallet" &&
    ! -e "$wl_copy_home/.xinitrc" && ! -L "$wl_copy_home/.xinitrc" ]] &&
    cmp -s "$wl_copy_home/.gpg-agent-gnome" "$REPO_ROOT/dotfiles/.gpg-agent-gnome"; then
    pass "copy_dotfiles $wl_copy_de installs ~/.wayland-session (755) and ~/.gpg-agent-gnome without ~/.xinitrc"
  else
    fail "copy_dotfiles $wl_copy_de Wayland files"
  fi

  printf '# existing user xinitrc\nexec i3\n' >"$wl_copy_home/.xinitrc"
  wl_copy_xinit_hash="$(sha256sum < "$wl_copy_home/.xinitrc")"
  (
    export HOME="$wl_copy_home"
    copy_dotfiles "$wl_copy_de" 2>/dev/null
  )
  if [[ "$(sha256sum < "$wl_copy_home/.xinitrc")" == "$wl_copy_xinit_hash" &&
    ! -e "$wl_copy_home/.xinitrc.lightxdm.bak" && ! -e "$wl_copy_home/.xinitrc.lightxdm.absent" &&
    ! -e "$wl_copy_home/.wayland-session.lightxdm.bak" && ! -e "$wl_copy_home/.wayland-session.lightxdm-edited" ]]; then
    pass "copy_dotfiles $wl_copy_de preserves ~/.xinitrc and recognizes its own Wayland template on reinstall"
  else
    fail "copy_dotfiles $wl_copy_de reinstall preservation"
  fi
done

plasma_keep_xinit_home="$TMP_DIR/home_plasma_keep_xinit"
mkdir -p "$plasma_keep_xinit_home"
printf '# existing user xinitrc\nexec i3\n' >"$plasma_keep_xinit_home/.xinitrc"
plasma_keep_xinit_hash="$(sha256sum < "$plasma_keep_xinit_home/.xinitrc")"
(
  export HOME="$plasma_keep_xinit_home"
  export USER="${USER:-testuser}"
  copy_dotfiles "plasma" 2>/dev/null
)
if [[ -f "$plasma_keep_xinit_home/.xinitrc" &&
  "$(sha256sum < "$plasma_keep_xinit_home/.xinitrc")" == "$plasma_keep_xinit_hash" &&
  ! -e "$plasma_keep_xinit_home/.xinitrc.lightxdm.bak" &&
  ! -e "$plasma_keep_xinit_home/.xinitrc.lightxdm.absent" ]]; then
  pass "copy_dotfiles plasma leaves an existing ~/.xinitrc untouched"
else
  fail "copy_dotfiles plasma touched existing ~/.xinitrc"
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
    if [[ $status -eq 0 && "$output" == *"Usage:"* && "$output" == *"--status"* && ! -e "$autologin_dir/lightxdm-autologin.conf" && -z "$log_content" ]]; then
      pass "enable-autologin.sh $help_flag prints help, exits 0 and writes nothing"
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
      if [[ "$output" == *"Warning: PAM keyring unlock is configured in $status_dir/login; the keyring will not unlock automatically with autologin"* &&
        "$output" == *"run 'sudo $CMD_UNINSTALL --keyring-only'."* ]]; then
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

# Case 12b: no argument shows the usage text before any root check
set +e
output="$(bash "$REPO_ROOT/enable-autologin.sh" 2>&1)"
status=$?
set -e
if [[ $status -ne 0 && "$output" == *"Usage:"* && "$output" != *"Please run as root"* ]]; then
  pass "enable-autologin.sh checks its arguments before asking for root"
else
  fail "enable-autologin.sh no-argument usage as normal user (status=$status, output=$output)"
fi

# Case 12c: a mistyped option is named before any root check
set +e
output="$(bash "$REPO_ROOT/enable-autologin.sh" --disble 2>&1)"
status=$?
set -e
if [[ $status -ne 0 && "$output" == *"Invalid username: '--disble'"* && "$output" == *"Usage:"* && "$output" != *"Please run as root"* ]]; then
  pass "enable-autologin.sh names a rejected option before asking for root"
else
  fail "enable-autologin.sh --disble as normal user (status=$status, output=$output)"
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
elif [[ $status -eq 0 && "$output" == *"cannot read $unread_dir/getty.d/lightxdm-autologin.conf"* && "$output" != *"Permission denied"* ]] &&
  [[ $(printf '%s\n' "$output" | grep -Fc "Note: cannot read $unread_dir/getty.d/lightxdm-autologin.conf;") -eq 1 ]]; then
  pass "enable-autologin.sh --status notes an unreadable drop-in and exits 0"
else
  fail "enable-autologin.sh --status unreadable drop-in (status=$status, output=$output)"
fi

# --status notes an unreadable foreign drop-in while reporting the readable one
printf '[Service]\nExecStart=/usr/bin/agetty tty1\n' >"$unread_dir/getty.d/zz-local.conf"
chmod 000 "$unread_dir/getty.d/zz-local.conf"
set +e
output="$(env OVERRIDE_DIR="$unread_dir/getty.d" LOGIN_FILE="$unread_dir/login" bash "$REPO_ROOT/enable-autologin.sh" --status 2>&1)"
status=$?
set -e
chmod 644 "$unread_dir/getty.d/zz-local.conf"
if [[ $EUID -eq 0 ]]; then
  skip "enable-autologin.sh --status with an unreadable foreign drop-in (running as root)"
elif [[ $status -eq 0 && "$output" == *"enabled for someone"* && "$output" == *"cannot read $unread_dir/getty.d/zz-local.conf"* ]] &&
  [[ $(printf '%s\n' "$output" | grep -Fc "Note: cannot read $unread_dir/getty.d/zz-local.conf;") -eq 1 ]]; then
  pass "enable-autologin.sh --status notes an unreadable foreign drop-in once"
else
  fail "enable-autologin.sh --status unreadable foreign drop-in (status=$status, output=$output)"
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
  ! grep -q 'pam_kwallet5\.so' "$LOGIN_FILE" &&
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
output="$(TARGET_HOME="$uninstall_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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
  output="$(TARGET_HOME="$uninstall_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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
    output="$(TARGET_HOME="$uninstall_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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
  output="$(TARGET_HOME="$uninstall_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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
  output="$(TARGET_HOME="$uninstall_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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

# Case 19b: uninstall removes a marker-less rule byte-identical to the 2025 lightXDM version, keeps a foreign one
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh removes an older lightXDM Polkit rule (unshare -r unavailable)"
else
  cat >"$uninstall_polkit" <<'OLD_RULE'
// /etc/polkit-1/rules.d/49-nopasswd.rules for lightXDE
polkit.addRule(function(action, subject) {
  if (subject.isInGroup("wheel")) {
    if (action.id.match(/^org\.freedesktop\.udisks2\./) ||
        action.id.match(/^org\.freedesktop\.upower\./) ||
        action.id.match(/^org\.freedesktop\.login1\./)) {
      return polkit.Result.YES;
    }
  }
}); 
OLD_RULE
  if [[ "$(sha256sum < "$uninstall_polkit")" != "d7e2e00acab61ca5c7d081f86705d699fa81b4da85c6d4e8bdfc88cda1234fc2  -" ]]; then
    fail "older Polkit rule fixture bytes differ from 23dfd12"
  fi
  set +e
  output="$(TARGET_HOME="$uninstall_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && "$output" == *"Removing Polkit rule..."* && ! -e "$uninstall_polkit" ]]; then
    pass "uninstall.sh removes a marker-less Polkit rule byte-identical to an older lightXDM version"
  else
    fail "uninstall.sh older Polkit rule (status=$status, output=$output)"
  fi
  printf '// foreign polkit policy\n' >"$uninstall_polkit"
  set +e
  output="$(TARGET_HOME="$uninstall_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && "$output" == *"Keeping $uninstall_polkit"* && -f "$uninstall_polkit" ]]; then
    pass "uninstall.sh keeps a marker-less Polkit rule that matches no lightXDM version"
  else
    fail "uninstall.sh foreign Polkit rule (status=$status, output=$output)"
  fi
  rm -f "$uninstall_polkit"
fi

# Case 20: copy_dotfiles backs up pre-existing .bash_profile and .xinitrc once, and uninstall.sh restores them and removes gpg-agent files
temp_home="$TMP_DIR/home_with_dotfiles"
mkdir -p "$temp_home"
echo "# user original bash_profile" >"$temp_home/.bash_profile"
echo "# user original xinitrc" >"$temp_home/.xinitrc"
(
  export HOME="$temp_home"
  export USER="${USER:-testuser}"
  copy_dotfiles "xfce" 2>/dev/null
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
  output="$(TARGET_HOME="$temp_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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
  output="$(TARGET_HOME="$temp_home_fresh" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && ! -e "$temp_home_fresh/.bash_profile" && ! -e "$temp_home_fresh/.wayland-session" && ! -e "$temp_home_fresh/.xinitrc" && ! -e "$temp_home_fresh/.gpg-agent-kwallet" ]] &&
    [[ ! -e "$temp_home_fresh/.bash_profile.lightxdm-removed" && ! -e "$temp_home_fresh/.wayland-session.lightxdm-removed" && ! -e "$temp_home_fresh/.xinitrc.lightxdm-removed" ]]; then
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

# shellcheck disable=SC2043  # one helper ships; the loop keeps the body unchanged
for gpg_dotfile in .gpg-agent-gnome; do
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
if [[ $status -eq 0 && -f "$no_sudo_home/.bash_profile" && -O "$no_sudo_home/.bash_profile" && -f "$no_sudo_home/.gpg-agent-kwallet" && -f "$no_sudo_home/.gpg-agent-gnome" && -x "$no_sudo_home/.wayland-session" && ! -e "$no_sudo_home/.xinitrc" && -z "$log_content" ]]; then
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
ln -sf "$STUB_BIN/systemctl" "$no_sudo_path/systemctl"

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
gnome_commented_content="$(cat "$LOGIN_FILE")"
configure_pam "plasma" 2>/dev/null
commented_content="$(cat "$LOGIN_FILE")"
if grep -Eq '^auth[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so$' <<<"$gnome_commented_content" &&
  grep -Eq '^session[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so auto_start$' <<<"$gnome_commented_content" &&
  ! grep -Eq '^[[:space:]]*-?(auth|session)[[:space:]].*pam_gnome_keyring\.so' "$LOGIN_FILE" &&
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
    copy_dotfiles "xfce" 2>/dev/null
  )
  set +e
  output1="$(TARGET_HOME="$twice_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status1=$?
  output2="$(TARGET_HOME="$twice_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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
  output="$(TARGET_HOME="$edited_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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
  output="$(TARGET_HOME="$removed_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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
help_dir="$TMP_DIR/help_getty.d"
mkdir -p "$help_dir"
help_autologin="$help_dir/lightxdm-autologin.conf"
echo "[Service]" >"$help_autologin"
help_override="$help_dir/override.conf"
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
  for help_word in --de --list-packages --no-packages --no-keyring --from-session --update /etc/pam.d/login "display managers" uninstall.sh; do
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
if [[ $status -eq 1 && "$output" == *"Unknown option: --unknown"* && "$output" == *"Usage:"* && -z "$log_content" ]] &&
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
  output="$(TARGET_HOME="$help_home" OVERRIDE_DIR="$help_dir" POLKIT_RULE="$help_polkit" "${uninstall_runner[@]}" "$flag" 2>&1)"
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
output="$(TARGET_HOME="$help_home" OVERRIDE_DIR="$help_dir" POLKIT_RULE="$help_polkit" "${uninstall_runner[@]}" --unknown 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 1 && "$output" == *"Unknown option: --unknown"* && "$output" == *"Usage:"* && -z "$log_content" ]] &&
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
    copy_dotfiles "xfce" 2>/dev/null
    copy_dotfiles "plasma" 2>/dev/null
  )
  unshare_bin="$(command -v unshare)"
  set +e
  output="$(PATH="$no_cmp_bin" TARGET_HOME="$no_cmp_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" "$unshare_bin" -r "$no_cmp_bin/bash" "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && ! -e "$no_cmp_home/.bash_profile" && ! -e "$no_cmp_home/.xinitrc" && ! -e "$no_cmp_home/.wayland-session" ]] &&
    [[ ! -e "$no_cmp_home/.bash_profile.lightxdm-removed" && ! -e "$no_cmp_home/.xinitrc.lightxdm-removed" && ! -e "$no_cmp_home/.wayland-session.lightxdm-removed" ]] &&
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
    OVERRIDE_DIR="$refuse_dir" POLKIT_RULE="$refuse_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1
  )"
  status_unset=$?
  output_bad_user="$(
    unset TARGET_HOME
    SUDO_USER="nonexistent_lightxdm_user_99999" OVERRIDE_DIR="$refuse_dir" POLKIT_RULE="$refuse_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1
  )"
  status_bad_user=$?
  output_dash_user="$(
    unset TARGET_HOME
    SUDO_USER="-V" OVERRIDE_DIR="$refuse_dir" POLKIT_RULE="$refuse_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1
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
    "$sudo_user_home/.wayland-session" "$sudo_user_home/.gpg-agent-kwallet")
  before_refusal="$(sha256sum "${refuse_files[@]}")"
  for bad_target in missing_home root; do
    : >"$STUB_LOG"
    expected_message="Target home directory does not exist"
    set +e
    if [[ "$bad_target" == "missing_home" ]]; then
      output="$(TARGET_HOME="$refuse_dir/missing_home" OVERRIDE_DIR="$refuse_dir" POLKIT_RULE="$refuse_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
      status=$?
    else
      expected_message="Refusing to uninstall for root"
      output="$(
        unset TARGET_HOME
        PATH="$getent_stub_dir:$PATH" SUDO_USER=root OVERRIDE_DIR="$refuse_dir" POLKIT_RULE="$refuse_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1
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
    PATH="$getent_stub_dir:$PATH" SUDO_USER="stubuser" OVERRIDE_DIR="$refuse_dir" POLKIT_RULE="$refuse_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1
  )"
  status_sudo=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status_sudo -eq 0 && "$(cat "$LOGIN_FILE")" == "$stock_login" && ! -e "${LOGIN_FILE}.lightxdm.bak" ]] &&
    [[ ! -e "$refuse_autologin" && ! -e "$refuse_override" && "$log_content" == *"systemctl daemon-reload"* ]] &&
    [[ -f "$refuse_polkit" && "$(cat "$refuse_polkit")" == "// rule" && "$output_sudo" == *"Keeping $refuse_polkit"* ]] &&
    [[ "$(cat "$sudo_user_home/.bash_profile")" == "# original bash_profile" && ! -e "$sudo_user_home/.bash_profile.lightxdm.bak" ]] &&
    [[ ! -e "$sudo_user_home/.wayland-session" && ! -e "$sudo_user_home/.wayland-session.lightxdm-removed" && ! -e "$sudo_user_home/.gpg-agent-kwallet" ]]; then
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
  [[ "$log_content" == *"gnome-shell gnome-session gnome-control-center nautilus gnome-terminal gnome-keyring"* ]] &&
  [[ "$log_content" == *"lxde-common lxsession lxpanel openbox pcmanfm lxterminal gnome-keyring"* ]] &&
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
  copy_dotfiles "xfce" 2>/dev/null
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
  output="$(TARGET_HOME="$symlink_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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
  copy_dotfiles "xfce" 2>/dev/null
  copy_dotfiles "gnome" 2>/dev/null
)
if [[ ! -e "$repeat_install_home/.bash_profile.lightxdm.bak" && ! -L "$repeat_install_home/.bash_profile.lightxdm.bak" ]] &&
  [[ ! -e "$repeat_install_home/.wayland-session.lightxdm.bak" && ! -L "$repeat_install_home/.wayland-session.lightxdm.bak" ]] &&
  [[ ! -e "$repeat_install_home/.xinitrc.lightxdm.bak" && ! -L "$repeat_install_home/.xinitrc.lightxdm.bak" ]]; then
  pass "copy_dotfiles skips backing up unmodified lightXDM templates on repeated installs"
else
  fail "copy_dotfiles backed up its own template on repeated installs"
fi

if [[ $can_unshare -eq 0 ]]; then
  skip "repeated install/uninstall cycles leave no ~/.bash_profile or ~/.xinitrc (unshare -r unavailable)"
else
  set +e
  output="$(TARGET_HOME="$repeat_install_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 ]] &&
    [[ ! -e "$repeat_install_home/.bash_profile" && ! -L "$repeat_install_home/.bash_profile" ]] &&
    [[ ! -e "$repeat_install_home/.wayland-session" && ! -L "$repeat_install_home/.wayland-session" ]] &&
    [[ ! -e "$repeat_install_home/.xinitrc" && ! -L "$repeat_install_home/.xinitrc" ]] &&
    [[ ! -e "$repeat_install_home/.bash_profile.lightxdm.bak" && ! -e "$repeat_install_home/.wayland-session.lightxdm.bak" && ! -e "$repeat_install_home/.xinitrc.lightxdm.bak" ]] &&
    [[ ! -e "$repeat_install_home/.bash_profile.lightxdm-removed" && ! -e "$repeat_install_home/.wayland-session.lightxdm-removed" && ! -e "$repeat_install_home/.xinitrc.lightxdm-removed" ]] &&
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
  out_u1="$(TARGET_HOME="$cycle_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status_u1=$?
  set -e
  (
    export HOME="$cycle_home"
    export USER="${USER:-testuser}"
    copy_dotfiles "plasma" 2>/dev/null
  )
  set +e
  out_u2="$(TARGET_HOME="$cycle_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status_u2=$?
  set -e
  if [[ $status_u1 -eq 0 && $status_u2 -eq 0 ]] &&
    [[ ! -e "$cycle_home/.bash_profile" && ! -L "$cycle_home/.bash_profile" ]] &&
    [[ ! -e "$cycle_home/.wayland-session" && ! -L "$cycle_home/.wayland-session" ]] &&
    [[ ! -e "$cycle_home/.xinitrc" && ! -L "$cycle_home/.xinitrc" ]] &&
    [[ ! -e "$cycle_home/.bash_profile.lightxdm.bak" && ! -e "$cycle_home/.wayland-session.lightxdm.bak" && ! -e "$cycle_home/.xinitrc.lightxdm.bak" ]] &&
    [[ ! -e "$cycle_home/.bash_profile.lightxdm-removed" && ! -e "$cycle_home/.wayland-session.lightxdm-removed" && ! -e "$cycle_home/.xinitrc.lightxdm-removed" ]] &&
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
      greetd.service | sddm.service | getty@tty1.service) echo enabled ;;
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
  display_manager_disabled=0
  disable_display_managers 2>&1
  # main reads this flag to tell the user to reboot rather than log out.
  echo "display_manager_disabled=$display_manager_disabled"
)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 0 && -f "$DM_STATE_FILE" && "$output" == *"display_manager_disabled=1"* ]] &&
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

# A large unit listing must still find its first entry under pipefail.
dm_pipefail_dir="$TMP_DIR/dm_pipefail_bin"
dm_pipefail_state="$TMP_DIR/dm_pipefail_state"
mkdir -p "$dm_pipefail_dir"
cat >"$dm_pipefail_dir/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list-unit-files)
    printf 'sddm.service enabled\n'
    for ((i = 0; i < 10000; i++)); do
      printf 'other-unit-%05d.service disabled\n' "$i" 2>/dev/null || exit 1
    done
    ;;
  is-enabled) [[ "${2:-}" == sddm.service ]] && echo enabled ;;
  disable) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$dm_pipefail_dir/systemctl"
set +e
# shellcheck disable=SC2016  # expand inside the child shell
output="$(env PATH="$dm_pipefail_dir:$PATH" DM_STATE_FILE="$dm_pipefail_state" DISPLAY_MANAGER_LINK="$TMP_DIR/no-dm-link" \
  bash -c 'set -o pipefail; source "$1/install.sh"; disable_display_managers' bash "$REPO_ROOT" 2>&1)"
status=$?
set -e
if [[ $status -eq 0 && -f "$dm_pipefail_state" ]] &&
  [[ "$(cat "$dm_pipefail_state")" == sddm.service ]]; then
  pass "disable_display_managers finds a unit at the start of a large listing under pipefail"
else
  fail "disable_display_managers large listing under pipefail (status=$status, output=$output)"
fi

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

# A previously disabled display manager can still be running on an install rerun.
dm_rerun_stub_dir="$TMP_DIR/dm_rerun_bin"
mkdir -p "$dm_rerun_stub_dir"
cat >"$dm_rerun_stub_dir/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  is-enabled) echo disabled; exit 1 ;;
  is-active) [[ "${3:-}" == sddm.service && "${STUB_DM_ACTIVE:-0}" == 1 ]] ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$dm_rerun_stub_dir/systemctl"
printf '%s\n' sddm.service >"$TMP_DIR/dm_rerun_state"
for dm_active in 1 0; do
  set +e
  # DM_STATE_FILE is readonly once install.sh is sourced, so pass it to a child shell.
  # shellcheck disable=SC2016  # expand inside the child shell
  output="$(env PATH="$dm_rerun_stub_dir:$PATH" STUB_DM_ACTIVE="$dm_active" DM_STATE_FILE="$TMP_DIR/dm_rerun_state" \
    bash -c 'source "$1/install.sh" && display_manager_disabled=0 && disable_display_managers 2>&1 &&
      echo "display_manager_disabled=$display_manager_disabled"' bash "$REPO_ROOT")"
  status=$?
  set -e
  if [[ $status -eq 0 && "$output" == *"display_manager_disabled=$dm_active"* &&
    "$(cat "$TMP_DIR/dm_rerun_state")" == sddm.service ]]; then
    pass "disable_display_managers detects recorded display manager active=$dm_active"
  else
    fail "disable_display_managers recorded display manager active=$dm_active (status=$status, output=$output)"
  fi
done

# A recorded unit remains detectable when only sudo can read the state file.
if [[ $EUID -eq 0 ]]; then
  skip "disable_display_managers reads a protected state file (running as root)"
elif [[ $can_unshare -eq 0 ]]; then
  skip "disable_display_managers reads a protected state file (unshare -r unavailable)"
else
  dm_protected_dir="$TMP_DIR/dm_protected"
  dm_protected_stub_dir="$TMP_DIR/dm_protected_bin"
  mkdir -p "$dm_protected_dir" "$dm_protected_stub_dir"
  printf '%s\n' sddm.service >"$dm_protected_dir/state"
  chmod 000 "$dm_protected_dir/state"
  cat >"$dm_protected_stub_dir/sudo" <<'EOF'
#!/usr/bin/env bash
exec unshare -r "$@"
EOF
  chmod +x "$dm_protected_stub_dir/sudo"
  set +e
  # shellcheck disable=SC2016  # expand inside the child shell
  output="$(env PATH="$dm_protected_stub_dir:$dm_rerun_stub_dir:$PATH" STUB_DM_ACTIVE=1 DM_STATE_FILE="$dm_protected_dir/state" \
    bash -c 'source "$1/install.sh" && display_manager_disabled=0 && disable_display_managers 2>&1 &&
      echo "display_manager_disabled=$display_manager_disabled"' bash "$REPO_ROOT")"
  status=$?
  set -e
  chmod 600 "$dm_protected_dir/state"
  if [[ $status -eq 0 && "$output" == *"display_manager_disabled=1"* ]]; then
    pass "disable_display_managers reads a protected state file"
  else
    fail "disable_display_managers protected state file (status=$status, output=$output)"
  fi
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
      main --de i3
    ' bash "$REPO_ROOT/install.sh" 2>&1)"
    status=$?
    set -e
    log_content="$(cat "$STUB_LOG")"
    if [[ $status -ne 0 && ! -e "$dm_readonly_dir/state" &&
      "$output" == *"$recovery_hint"* && "$output" != *"lightXDM install complete!"* ]] &&
      grep -Fxq '=> Install stopped during disable_display_managers; already done: install_packages copy_dotfiles configure_pam configure_gnome_session_type' <<<"$output" &&
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
  output="$(env STUB_SYSTEMCTL_EXIT=1 TARGET_HOME="$dm_home" LOGIN_FILE="$TMP_DIR/dm_login" OVERRIDE_DIR="$TMP_DIR/dm_getty.d" POLKIT_RULE="$TMP_DIR/dm_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -ne 0 && -f "$DM_STATE_FILE" ]]; then
    pass "uninstall.sh keeps display manager state when enabling fails"
  else
    fail "uninstall.sh failed enable (status=$status, output=$output)"
  fi

  # Case 41c: a first unit that fails to enable does not prevent restoring the remaining units
  # (systemctl is-enabled reports an installed, unmasked unit that failed to enable as disabled)
  dm_partial_state="$TMP_DIR/dm_partial_state"
  printf '%s\n' sddm.service greetd.service >"$dm_partial_state"
  : >"$STUB_LOG"
  set +e
  output="$(env DM_STATE_FILE="$dm_partial_state" STUB_SYSTEMCTL_FAIL_UNIT=sddm.service STUB_SYSTEMCTL_STATE=disabled TARGET_HOME="$dm_home" LOGIN_FILE="$TMP_DIR/dm_login" OVERRIDE_DIR="$TMP_DIR/dm_getty.d" POLKIT_RULE="$TMP_DIR/dm_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -ne 0 && -f "$dm_partial_state" ]] &&
    [[ "$(cat "$dm_partial_state")" == 'sddm.service' ]] &&
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
    output="$(env STUB_SYSTEMCTL_FAIL_UNIT=sddm.service STUB_SYSTEMCTL_STATE="$dm_gone_state" TARGET_HOME="$dm_home" LOGIN_FILE="$TMP_DIR/dm_login" OVERRIDE_DIR="$TMP_DIR/dm_getty.d" POLKIT_RULE="$TMP_DIR/dm_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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
  output="$(env TARGET_HOME="$dm_home" LOGIN_FILE="$TMP_DIR/dm_login" OVERRIDE_DIR="$TMP_DIR/dm_getty.d" POLKIT_RULE="$TMP_DIR/dm_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -eq 0 && ! -e "$DM_STATE_FILE" && "$log_content" == 'systemctl enable sddm.service' &&
    "$output" == *"Uninstall complete. Reboot to return to sddm.service: they are enabled for the next boot, not started now."* &&
    "$output" != *"Changes will take effect at the next login or reboot."* ]]; then
    pass "uninstall.sh enables only recorded display managers and removes state"
  else
    fail "uninstall.sh display manager restore (status=$status, log=$log_content, output=$output)"
  fi

  : >"$STUB_LOG"
  set +e
  output="$(env TARGET_HOME="$dm_home" LOGIN_FILE="$TMP_DIR/dm_login" OVERRIDE_DIR="$TMP_DIR/dm_getty.d" POLKIT_RULE="$TMP_DIR/dm_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && ! -s "$STUB_LOG" &&
    "$output" == *"Uninstall complete. Changes will take effect at the next login or reboot."* &&
    "$output" != *"Reboot to return to"* ]]; then
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
if [[ $status -eq 1 && "$output" == *"plasma gnome xfce lxqt lxde mate cinnamon budgie i3"* && -z "$log_content" ]]; then
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
    "$log_content" == *"disable_display_managers"* ]]; then
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
ln -s "$STUB_BIN/systemctl" "$startup_bin/systemctl"
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
    [[ $status -eq 0 && "$log_content" == $'sudo -v\ncopy_dotfiles xfce\nconfigure_pam xfce\ndisable_display_managers' &&
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

# Bash syntax errors stop both session types before configuration, without running the template.
for syntax_session_type in x11 wayland; do
  syntax_home="$TMP_DIR/syntax_${syntax_session_type}_home"
  mkdir -p "$syntax_home/.config/lightxdm"
  syntax_id=dwm
  syntax_template="$syntax_home/.config/lightxdm/.xinitrc-$syntax_id"
  if [[ "$syntax_session_type" == wayland ]]; then
    syntax_id=sway
    syntax_template="$syntax_home/.config/lightxdm/.wayland-session-$syntax_id"
  fi
  # shellcheck disable=SC2016  # expand inside the child shell
  syntax_template_body=$'printf executed > "$HOME/template-executed"\nif true; then\nexec dwm'
  for syntax_shebang in '#!/bin/bash' '#!/usr/bin/bash' '#!/usr/bin/env bash' '#!/bin/bash   '; do
    printf '%s\n' "$syntax_shebang" "$syntax_template_body" >"$syntax_template"
    set +e
    # shellcheck disable=SC2016  # expand inside the child shell
    output="$(HOME="$syntax_home" bash -c 'source "$1/install.sh"; check_template_syntax "$2"' bash "$REPO_ROOT" "$syntax_template" 2>&1)"
    status=$?
    set -e
    if [[ $status -eq 1 && "$output" == *"Invalid Bash syntax in $syntax_template:"* &&
      "$output" == *"syntax error: unexpected end of file"* && "$output" != *$'\n'* &&
      ! -e "$syntax_home/template-executed" ]]; then
      pass "check_template_syntax refuses malformed $syntax_session_type Bash syntax ($syntax_shebang)"
    else
      fail "malformed $syntax_session_type template ($syntax_shebang, status=$status, output=$output)"
    fi
  done
  syntax_refusal="$output"

  printf 'existing profile\n' >"$syntax_home/.bash_profile"
  : >"$STUB_LOG"
  set +e
  output="$(
    HOME="$syntax_home" STUB_REAL_COPY_DOTFILES=1 STUB_RECORD_GNOME_STEP=1 \
      run_main_with_stubs "$sudo_pw_dir" --no-packages --no-keyring --de "$syntax_id" 2>&1
  )"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -eq 1 && "$log_content" == "sudo -v" &&
    "$output" == *"Invalid Bash syntax in $syntax_template:"* &&
    "$output" == *"syntax error: unexpected end of file"* &&
    "$output" != *"Skipping package installation"* &&
    "$output" != *"lightXDM install complete!"* &&
    "$(cat "$syntax_home/.bash_profile")" == 'existing profile' &&
    ! -e "$syntax_home/.bash_profile.lightxdm.bak" && ! -e "$syntax_home/.xinitrc" &&
    ! -e "$syntax_home/.wayland-session" && ! -e "$syntax_home/.gpg-agent-gnome" &&
    ! -e "$syntax_home/.config/autostart/lightxdm-gpg-agent-tty.desktop" &&
    ! -e "$syntax_home/template-executed" ]]; then
    pass "main refuses malformed $syntax_session_type Bash syntax before dotfile, PAM or display-manager changes"
  else
    fail "main malformed $syntax_session_type template (status=$status, log=$log_content, output=$output)"
  fi

  : >"$STUB_LOG"
  set +e
  output="$(env -u SHELLOPTS -u SUDO_USER HOME="$syntax_home" \
    bash "$REPO_ROOT/install.sh" --dry-run --no-packages --de "$syntax_id" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 1 && "$output" == "$syntax_refusal" && ! -s "$STUB_LOG" &&
    "$(cat "$syntax_home/.bash_profile")" == 'existing profile' &&
    ! -e "$syntax_home/.bash_profile.lightxdm.bak" && ! -e "$syntax_home/.xinitrc" &&
    ! -e "$syntax_home/.wayland-session" && ! -e "$syntax_home/.gpg-agent-gnome" &&
    ! -e "$syntax_home/.config/autostart/lightxdm-gpg-agent-tty.desktop" &&
    ! -e "$syntax_home/template-executed" ]]; then
    pass "--dry-run reports the same malformed $syntax_session_type Bash syntax refusal without changes"
  else
    fail "--dry-run malformed $syntax_session_type template (status=$status, output=$output, log=$(cat "$STUB_LOG"))"
  fi

  # Other interpreters skip Bash parsing even with the same malformed body.
  printf '%s\n' '#!/bin/sh' "$syntax_template_body" >"$syntax_template"
  set +e
  # shellcheck disable=SC2016  # expand inside the child shell
  output="$(HOME="$syntax_home" bash -c 'source "$1/install.sh"; check_template_syntax "$2"' bash "$REPO_ROOT" "$syntax_template" 2>&1)"
  status=$?
  set -e
  if [[ "$output" != *"Invalid Bash syntax"* && "$output" != *"syntax error"* &&
    ! -e "$syntax_home/template-executed" ]]; then
    pass "check_template_syntax skips Bash parsing for a non-Bash $syntax_session_type template"
  else
    fail "non-Bash $syntax_session_type template (status=$status, output=$output)"
  fi

  # A valid Bash template also stays unexecuted during preflight.
  # shellcheck disable=SC2016  # expand inside the child shell
  printf '%s\n' '#!/bin/bash' 'printf executed > "$HOME/template-executed"' 'exec dwm' >"$syntax_template"
  set +e
  # shellcheck disable=SC2016  # expand inside the child shell
  output="$(HOME="$syntax_home" bash -c 'source "$1/install.sh"; check_template_syntax "$2"' bash "$REPO_ROOT" "$syntax_template" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && -z "$output" && ! -e "$syntax_home/template-executed" ]]; then
    pass "check_template_syntax accepts valid $syntax_session_type Bash syntax without executing it"
  else
    fail "valid $syntax_session_type template (status=$status, output=$output)"
  fi

  # Extended globs are valid once the template enables them, so parsing must not reject them.
  # shellcheck disable=SC2016  # expand inside the child shell
  printf '%s\n' '#!/bin/bash' 'printf executed > "$HOME/template-executed"' 'shopt -s extglob' \
    'case "$XDG_SESSION_TYPE" in @(x11|wayland)) : ;; esac' 'exec dwm' >"$syntax_template"
  set +e
  # shellcheck disable=SC2016  # expand inside the child shell
  output="$(HOME="$syntax_home" bash -c 'source "$1/install.sh"; check_template_syntax "$2"' bash "$REPO_ROOT" "$syntax_template" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && -z "$output" && ! -e "$syntax_home/template-executed" ]]; then
    pass "check_template_syntax accepts a valid $syntax_session_type template that uses extended globs"
  else
    fail "extglob $syntax_session_type template (status=$status, output=$output)"
  fi
done

# A malformed built-in override must also stop before the real package helper reaches pacman.
syntax_packages_home="$TMP_DIR/syntax_packages_home"
mkdir -p "$syntax_packages_home/.config/lightxdm"
syntax_packages_template="$syntax_packages_home/.config/lightxdm/.xinitrc-xfce"
printf '%s\n' '#!/bin/bash' "$syntax_template_body" >"$syntax_packages_template"
printf 'existing profile\n' >"$syntax_packages_home/.bash_profile"
: >"$STUB_LOG"
set +e
output="$(
  HOME="$syntax_packages_home" STUB_REAL_INSTALL_PACKAGES=1 STUB_REAL_COPY_DOTFILES=1 STUB_RECORD_GNOME_STEP=1 \
    run_main_with_stubs "$sudo_pw_dir" --de xfce 2>&1
)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 1 && "$log_content" == "sudo -v" &&
  "$output" == *"Invalid Bash syntax in $syntax_packages_template:"* &&
  "$output" == *"syntax error: unexpected end of file"* &&
  "$output" != *"lightXDM install complete!"* &&
  "$(cat "$syntax_packages_home/.bash_profile")" == 'existing profile' &&
  ! -e "$syntax_packages_home/.bash_profile.lightxdm.bak" && ! -e "$syntax_packages_home/.xinitrc" &&
  ! -e "$syntax_packages_home/.gpg-agent-gnome" &&
  ! -e "$syntax_packages_home/.config/autostart/lightxdm-gpg-agent-tty.desktop" &&
  ! -e "$syntax_packages_home/template-executed" ]]; then
  pass "main refuses malformed built-in Bash syntax before pacman, dotfile, PAM or display-manager changes"
else
  fail "main malformed built-in template with packages enabled (status=$status, log=$log_content, output=$output)"
fi

# An unreadable custom template must stop before changing session dotfiles.
if [[ $EUID -eq 0 ]]; then
  skip "main stops before changing dotfiles when a custom template is unreadable"
else
  unreadable_home="$TMP_DIR/unreadable_template_home"
  unreadable_bin="$TMP_DIR/unreadable_template_bin"
  mkdir -p "$unreadable_home/.config/lightxdm" "$unreadable_bin"
  unreadable_template="$unreadable_home/.config/lightxdm/.xinitrc-dwm"
  sed 's/^exec i3$/exec lightxdm-test-session/' "$REPO_ROOT/dotfiles/.xinitrc-i3" >"$unreadable_template"
  cp "$STUB_BIN/chown" "$unreadable_bin/lightxdm-test-session"
  printf 'existing profile\n' >"$unreadable_home/.bash_profile"
  cp "$unreadable_home/.bash_profile" "$TMP_DIR/unreadable_profile_original"
  chmod 000 "$unreadable_template"
  set +e
  output="$(HOME="$unreadable_home" run_main_with_stubs "$unreadable_bin:$sudo_pw_dir" --no-packages --de dwm 2>&1)"
  status=$?
  set -e
  chmod 600 "$unreadable_template"
  if [[ $status -ne 0 && "$output" == *"Cannot read $unreadable_template; fix its permissions and re-run."* &&
    ! -e "$unreadable_home/.bash_profile.lightxdm.bak" && ! -e "$unreadable_home/.gpg-agent-gnome" ]] &&
    cmp -s "$unreadable_home/.bash_profile" "$TMP_DIR/unreadable_profile_original"; then
    pass "main stops before changing dotfiles when a custom template is unreadable"
  else
    fail "main unreadable custom template (status=$status, output=$output)"
  fi
fi

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

# Custom Wayland sessions select the user template and install it through main.
custom_wayland_home="$TMP_DIR/custom_wayland_home"
custom_wayland_bin="$TMP_DIR/custom_wayland_bin"
mkdir -p "$custom_wayland_home/.config/lightxdm" "$custom_wayland_bin"
custom_wayland_template="$custom_wayland_home/.config/lightxdm/.wayland-session-sway"
printf '#!/bin/bash\nexec sway\n' >"$custom_wayland_template"
cp "$STUB_BIN/chown" "$custom_wayland_bin/sway"
resolved_custom_wayland="$(HOME="$custom_wayland_home" xinitrc_template sway)"
if [[ "$resolved_custom_wayland" == "$custom_wayland_template" ]]; then
  pass "xinitrc_template selects a user's custom Wayland template"
else
  fail "xinitrc_template custom Wayland (resolved=$resolved_custom_wayland)"
fi

: >"$STUB_LOG"
set +e
output="$(HOME="$custom_wayland_home" run_main_with_stubs "$sudo_pw_dir" --de sway 2>&1)"
status=$?
set -e
if [[ $status -eq 1 && "$output" == *"Custom sessions need --no-packages"* &&
  ! -s "$STUB_LOG" && ! -e "$custom_wayland_home/.bash_profile" && ! -e "$custom_wayland_home/.wayland-session" ]]; then
  pass "custom Wayland sessions require --no-packages before any installation step"
else
  fail "custom Wayland without --no-packages (status=$status, log=$(cat "$STUB_LOG"), output=$output)"
fi

: >"$STUB_LOG"
set +e
output="$(
  HOME="$custom_wayland_home" PATH="$custom_wayland_bin:$PATH" STUB_REAL_COPY_DOTFILES=1 \
    run_main_with_stubs "$sudo_pw_dir" --no-packages --de sway 2>&1
)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 0 && "$output" == *"lightXDM install complete!"* &&
  "$log_content" == $'sudo -v\nconfigure_pam sway\ndisable_display_managers' &&
  -f "$custom_wayland_home/.wayland-session" && ! -L "$custom_wayland_home/.wayland-session" &&
  "$(stat -c '%a' "$custom_wayland_home/.wayland-session")" == 755 &&
  ! -e "$custom_wayland_home/.xinitrc" && -f "$custom_wayland_home/.gpg-agent-gnome" ]] &&
  cmp -s "$custom_wayland_template" "$custom_wayland_home/.wayland-session"; then
  pass "main --no-packages --de sway installs ~/.wayland-session and the GNOME helper without ~/.xinitrc"
else
  fail "main custom Wayland install (status=$status, log=$log_content, output=$output)"
fi

# With an isolated PATH, a missing sway must stop before dotfiles or other configuration.
missing_sway_home="$TMP_DIR/missing_sway_home"
mkdir -p "$missing_sway_home/.config/lightxdm"
cp "$custom_wayland_template" "$missing_sway_home/.config/lightxdm/.wayland-session-sway"
: >"$STUB_LOG"
set +e
output="$(
  HOME="$missing_sway_home" PATH="$startup_bin" STUB_REAL_COPY_DOTFILES=1 \
    run_main_with_stubs "$sudo_pw_dir" --no-packages --de sway 2>&1
)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 1 && "$log_content" == "sudo -v" &&
  "$output" == *"Missing command: sway. Install your session and ensure its command is on PATH"* &&
  "$output" == *"Install stopped during check_session_commands; already done: none"* &&
  "$output" != *"lightXDM install complete!"* &&
  ! -e "$missing_sway_home/.bash_profile" && ! -e "$missing_sway_home/.wayland-session" &&
  ! -e "$missing_sway_home/.xinitrc" && ! -e "$missing_sway_home/.gpg-agent-gnome" ]]; then
  pass "main stops before configuration when a custom Wayland command is missing"
else
  fail "main missing sway (status=$status, log=$log_content, output=$output)"
fi

# Refuse ambiguity before sudo or any install step, preserving both templates and existing files.
conflict_wayland_home="$TMP_DIR/conflict_wayland_home"
mkdir -p "$conflict_wayland_home/.config/lightxdm"
conflict_wayland_template="$conflict_wayland_home/.config/lightxdm/.wayland-session-sway"
conflict_x11_template="$conflict_wayland_home/.config/lightxdm/.xinitrc-sway"
cp "$custom_wayland_template" "$conflict_wayland_template"
printf '#!/bin/bash\nexec dwm\n' >"$conflict_x11_template"
printf '# original profile\n' >"$conflict_wayland_home/.bash_profile"
conflict_before="$(
  sha256sum "$conflict_wayland_template" "$conflict_x11_template" "$conflict_wayland_home/.bash_profile"
)"
for conflict_args in with-no-packages without-no-packages; do
  custom_args=(--de sway)
  if [[ "$conflict_args" == with-no-packages ]]; then
    custom_args+=(--no-packages)
  fi
  : >"$STUB_LOG"
  set +e
  output="$(HOME="$conflict_wayland_home" STUB_REAL_COPY_DOTFILES=1 run_main_with_stubs "$sudo_pw_dir" "${custom_args[@]}" 2>&1)"
  status=$?
  set -e
  conflict_after="$(
    sha256sum "$conflict_wayland_template" "$conflict_x11_template" "$conflict_wayland_home/.bash_profile"
  )"
  if [[ $status -eq 1 && ! -s "$STUB_LOG" && "$conflict_before" == "$conflict_after" &&
    "$output" == *"$conflict_wayland_template"* && "$output" == *"$conflict_x11_template"* &&
    "$output" == *"keep only one session template"* &&
    ! -e "$conflict_wayland_home/.wayland-session" && ! -e "$conflict_wayland_home/.xinitrc" &&
    ! -e "$conflict_wayland_home/.gpg-agent-gnome" && ! -e "$conflict_wayland_home/.bash_profile.lightxdm.bak" ]]; then
    pass "main refuses both custom session templates without changes ($conflict_args)"
  else
    fail "main custom template conflict ($conflict_args, status=$status, log=$(cat "$STUB_LOG"), output=$output)"
  fi
done

# Wayland checks the last literal exec command and includes ~/.local/bin on PATH.
wayland_command_home="$TMP_DIR/wayland_command_home"
mkdir -p "$wayland_command_home/.local/bin"
cp "$STUB_BIN/chown" "$wayland_command_home/.local/bin/lightxdm-local-session"
wayland_command_template="$wayland_command_home/.wayland-session-custom"
for wayland_command_case in last-exec missing-command local-bin no-exec expression; do
  expected_wayland_status=0
  wayland_command_path="$PATH"
  case "$wayland_command_case" in
    last-exec) wayland_command_content=$'exec lightxdm-missing-session\nexec dwm --example' ;;
    missing-command)
      wayland_command_content=$'exec dwm\nexec lightxdm-missing-session --example'
      expected_wayland_status=1
      ;;
    local-bin)
      wayland_command_content='exec lightxdm-local-session'
      # No startx on this PATH; the compositor is found only through ~/.local/bin.
      wayland_command_path="$custom_wayland_bin"
      ;;
    no-exec) wayland_command_content='# No exec line' ;;
    expression)
      # shellcheck disable=SC2016  # literal shell expression, never evaluated
      wayland_command_content='exec "$SESSION"'
      ;;
  esac
  printf '%s' "$wayland_command_content" >"$wayland_command_template"
  set +e
  output="$(HOME="$wayland_command_home" PATH="$wayland_command_path" check_session_commands "$wayland_command_template" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq $expected_wayland_status ]] && {
    [[ $status -eq 0 && -z "$output" ]] ||
    [[ $status -eq 1 && "$output" == *"Missing command: lightxdm-missing-session. Install your session"* ]];
  }; then
    pass "check_session_commands checks a custom Wayland template ($wayland_command_case)"
  else
    fail "custom Wayland command ($wayland_command_case, status=$status, output=$output)"
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
  copy_dotfiles "lxqt" 2>/dev/null
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
    copy_dotfiles "lxqt" 2>/dev/null
  )
  echo "# uninstall bash edit 1" >>"$uninstall_edit_home/.bash_profile"
  echo "# uninstall xinit edit 1" >>"$uninstall_edit_home/.xinitrc"
  u_bash_edit1="$(cat "$uninstall_edit_home/.bash_profile")"
  u_xinit_edit1="$(cat "$uninstall_edit_home/.xinitrc")"
  set +e
  out_u_edit1="$(TARGET_HOME="$uninstall_edit_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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
  out_u_edit2="$(TARGET_HOME="$uninstall_edit_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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

# Case 44b: uninstall.sh replaces a symlink planted at the .lightxdm-edited name instead of moving the dotfile into its target
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh does not follow a symlink planted at the .lightxdm-edited name (unshare -r unavailable)"
else
  race_dir="$TMP_DIR/uninstall_edited_race"
  race_home="$race_dir/home"
  race_victim="$race_dir/victim"
  race_real_mv="$(command -v mv)"
  mkdir -p "$race_home" "$race_victim" "$race_dir/shim" "$race_dir/override"
  echo "# user profile" >"$race_home/.bash_profile"
  : >"$race_home/.bash_profile.lightxdm.absent"
  # The shim plants the symlink right before the real mv runs, like a racing home owner.
  cat >"$race_dir/shim/mv" <<SHIM
#!/bin/bash
last="\${!#}"
if [[ "\$last" == *.lightxdm-edited ]]; then
  ln -s "$race_victim" "\$last"
fi
exec "$race_real_mv" "\$@"
SHIM
  chmod +x "$race_dir/shim/mv"
  set +e
  out_race="$(PATH="$race_dir/shim:$PATH" TARGET_HOME="$race_home" OVERRIDE_DIR="$race_dir/override" POLKIT_RULE="$race_dir/polkit.rules" \
    LOGIN_FILE="$race_dir/login" DM_STATE_FILE="$race_dir/dm-state" GNOME_SESSION_TYPE_DEST="$race_dir/gnome-session-type.conf" \
    unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status_race=$?
  set -e
  if [[ $status_race -eq 0 && ! -e "$race_victim/.bash_profile" ]] &&
    [[ -f "$race_home/.bash_profile.lightxdm-edited" && ! -L "$race_home/.bash_profile.lightxdm-edited" ]] &&
    [[ "$(cat "$race_home/.bash_profile.lightxdm-edited")" == "# user profile" ]]; then
    pass "uninstall.sh replaces a symlink planted at the .lightxdm-edited name instead of following it"
  else
    fail "uninstall.sh followed a planted .lightxdm-edited symlink (status=$status_race, output=$out_race)"
  fi
  rm -rf "$race_dir"
fi

# Case 44c: uninstall.sh restores the dotfile backup with mv -T, so a directory/symlink planted at the dotfile name is replaced, not entered
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh does not follow a symlink planted at the dotfile name during backup restore (unshare -r unavailable)"
else
  restore_dir="$TMP_DIR/uninstall_restore_race"
  restore_home="$restore_dir/home"
  restore_victim="$restore_dir/victim"
  restore_real_mv="$(command -v mv)"
  mkdir -p "$restore_home" "$restore_victim" "$restore_dir/shim" "$restore_dir/override"
  cp "$REPO_ROOT/dotfiles/.bash_profile" "$restore_home/.bash_profile"
  echo "# original" >"$restore_home/.bash_profile.lightxdm.bak"
  # The shim plants the symlink at the dotfile name right before the real mv restores the backup.
  cat >"$restore_dir/shim/mv" <<SHIM
#!/bin/bash
last="\${!#}"
if [[ "\$last" == */.bash_profile ]]; then
  ln -s "$restore_victim" "\$last"
fi
exec "$restore_real_mv" "\$@"
SHIM
  chmod +x "$restore_dir/shim/mv"
  set +e
  out_restore="$(PATH="$restore_dir/shim:$PATH" TARGET_HOME="$restore_home" OVERRIDE_DIR="$restore_dir/override" POLKIT_RULE="$restore_dir/polkit.rules" \
    LOGIN_FILE="$restore_dir/login" DM_STATE_FILE="$restore_dir/dm-state" GNOME_SESSION_TYPE_DEST="$restore_dir/gnome-session-type.conf" \
    unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status_restore=$?
  set -e
  if [[ $status_restore -eq 0 && ! -e "$restore_victim/.bash_profile.lightxdm.bak" ]] &&
    [[ -f "$restore_home/.bash_profile" && ! -L "$restore_home/.bash_profile" ]] &&
    [[ "$(cat "$restore_home/.bash_profile")" == "# original" ]]; then
    pass "uninstall.sh restores the dotfile backup over a planted symlink instead of moving it into the target"
  else
    fail "uninstall.sh followed a planted dotfile symlink during restore (status=$status_restore, output=$out_restore)"
  fi
  rm -rf "$restore_dir"
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
    TARGET_HOME="$cdpath_home" OVERRIDE_DIR="$uninstall_dir" POLKIT_RULE="$uninstall_polkit" unshare -r bash relrepo/uninstall.sh 2>&1
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

for snippet_shell in zsh fish; do
  if ! snippet_shell_path="$(command -v "$snippet_shell")"; then
    skip "$snippet_shell TTY1 snippet starts a session from ~/.local/bin (shell missing)"
    continue
  fi
  snippet_dir="$TMP_DIR/snippet_$snippet_shell"
  snippet_home="$snippet_dir/home"
  mkdir -p "$snippet_home/.local/bin" "$snippet_dir/bin"
  awk -v fence="\`\`\`$snippet_shell" '$0 == fence { in_snippet = 1; next } in_snippet && $0 == "```" { exit } in_snippet { print }' \
    "$REPO_ROOT/docs/startx-autologin.md" >"$snippet_dir/snippet"
  cat >"$snippet_home/.local/bin/lightxdm-test-session" <<'EOF'
#!/bin/sh
touch "$HOME/session-started"
EOF
  cat >"$snippet_home/.wayland-session" <<'EOF'
#!/bin/sh
exec lightxdm-test-session
EOF
  cat >"$snippet_dir/bin/tty" <<'EOF'
#!/bin/sh
echo /dev/tty1
EOF
  chmod +x "$snippet_home/.local/bin/lightxdm-test-session" "$snippet_home/.wayland-session" "$snippet_dir/bin/tty"
  for snippet_case in wayland paused startx_missing startx_nonexecutable; do
    case_home="$snippet_dir/$snippet_case/home"
    mkdir -p "$case_home/.local/bin"
    cp "$snippet_home/.local/bin/lightxdm-test-session" "$case_home/.local/bin/"
    cat >"$case_home/.local/bin/startx" <<'EOF'
#!/bin/sh
touch "$HOME/startx-started"
EOF
    chmod +x "$case_home/.local/bin/startx"
    case "$snippet_case" in
      wayland|paused)
        cp "$snippet_home/.wayland-session" "$case_home/.wayland-session"
        ;;
      startx_nonexecutable)
        cp "$snippet_home/.wayland-session" "$case_home/.wayland-session"
        chmod -x "$case_home/.wayland-session"
        ;;
    esac
    if [[ "$snippet_case" == paused ]]; then
      mkdir -p "$case_home/.config/lightxdm"
      : >"$case_home/.config/lightxdm/no-autostart"
    fi
    snippet_status=0
    if [[ "$snippet_shell" == zsh ]]; then
      # shellcheck disable=SC2016  # expand inside the child shell
      timeout 20 env -i HOME="$case_home" PATH="$snippet_dir/bin:/usr/bin:/bin" TERM=dumb \
        "$snippet_shell_path" -f -o interactive -c 'source "$1"; : > "$HOME/after-source"' zsh "$snippet_dir/snippet" || snippet_status=$?
    else
      # shellcheck disable=SC2016  # expand inside the child shell
      timeout 20 env -i HOME="$case_home" PATH="$snippet_dir/bin:/usr/bin:/bin" TERM=dumb \
        "$snippet_shell_path" --no-config -l -i -c 'source $argv[1]; touch $HOME/after-source' "$snippet_dir/snippet" || snippet_status=$?
    fi
    case "$snippet_case" in
      wayland)
        snippet_title="$snippet_shell TTY1 snippet execs a Wayland session from ~/.local/bin"
        if [[ $snippet_status -eq 0 && -f "$case_home/session-started" && ! -e "$case_home/after-source" ]]; then
          pass "$snippet_title"
        else
          fail "$snippet_title (status=$snippet_status)"
        fi
        ;;
      paused)
        snippet_title="$snippet_shell TTY1 snippet respects no-autostart"
        if [[ $snippet_status -eq 0 && ! -e "$case_home/session-started" && ! -e "$case_home/startx-started" ]]; then
          pass "$snippet_title"
        else
          fail "$snippet_title (status=$snippet_status)"
        fi
        ;;
      startx_*)
        snippet_title="$snippet_shell TTY1 snippet execs startx with $snippet_case Wayland session"
        if [[ $snippet_status -eq 0 && -f "$case_home/startx-started" && ! -e "$case_home/after-source" ]]; then
          pass "$snippet_title"
        else
          fail "$snippet_title (status=$snippet_status)"
        fi
        ;;
    esac
  done
done

for summary_shell in bash zsh fish; do
  summary_stub_dir="$TMP_DIR/getent_$summary_shell"
  for summary_dm in 0 1; do
    summary_output="$(USER=testuser STUB_DM_DISABLED="$summary_dm" run_main_with_stubs "$summary_stub_dir:$sudo_pw_dir" --no-packages --de i3 2>&1)"
    if [[ $summary_dm -eq 1 ]]; then
      if [[ "${summary_output,,}" == *"reboot to test (the disabled display manager keeps running until then, so logging out returns to it)"* &&
        "$summary_output" != *"log out to test"* ]]; then
        pass "main requires reboot after disabling a display manager ($summary_shell)"
      else
        fail "main reboot guidance after disabling a display manager ($summary_shell): $summary_output"
      fi
    elif [[ "${summary_output,,}" == *"reboot or log out to test"* ]]; then
      pass "main retains logout guidance without a disabled display manager ($summary_shell)"
    else
      fail "main logout guidance without a disabled display manager ($summary_shell): $summary_output"
    fi
  done
done

paused_home="$TMP_DIR/paused_home"
mkdir -p "$paused_home/.config/lightxdm"
: >"$paused_home/.config/lightxdm/no-autostart"
set +e
out_paused="$(HOME="$paused_home" USER=testuser run_main_with_stubs "$bash_stub_dir:$sudo_pw_dir" --no-packages --de i3 2>&1)"
status_paused=$?
out_paused_dm="$(HOME="$paused_home" USER=testuser STUB_DM_DISABLED=1 run_main_with_stubs "$bash_stub_dir:$sudo_pw_dir" --no-packages --de i3 2>&1)"
status_paused_dm=$?
set -e
if [[ $status_paused -eq 0 && "$out_paused" == *"auto-start on TTY1 stays paused"* &&
  "$out_paused" == *"rm ~/.config/lightxdm/no-autostart"*"then reboot or log out to test"* &&
  "$out_paused" != *"will auto-start on TTY1"* &&
  $status_paused_dm -eq 0 && "$out_paused_dm" == *"auto-start on TTY1 stays paused"* &&
  "$out_paused_dm" == *"rm ~/.config/lightxdm/no-autostart"*"then reboot to test"* &&
  -e "$paused_home/.config/lightxdm/no-autostart" ]]; then
  pass "main reports paused auto-start and keeps the no-autostart marker"
else
  fail "main with no-autostart marker (status=$status_paused, output=$out_paused | disabled DM status=$status_paused_dm, output=$out_paused_dm)"
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
  output="$(env OVERRIDE_DIR="$pre_dir/getty.d" POLKIT_RULE="$pre_dir/p" DM_STATE_FILE="$pre_dir/s" TARGET_HOME="$pre_dir/home" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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
  out_u_foreign="$(env OVERRIDE_DIR="$dropin_test_dir/getty.d" POLKIT_RULE="$dropin_test_dir/polkit" LOGIN_FILE="$dropin_test_dir/login" DM_STATE_FILE="$dropin_test_dir/dm" TARGET_HOME="$dropin_test_dir/home" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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
  out_u_both="$(env OVERRIDE_DIR="$dropin_test_dir/getty.d" POLKIT_RULE="$dropin_test_dir/polkit" LOGIN_FILE="$dropin_test_dir/login" DM_STATE_FILE="$dropin_test_dir/dm" TARGET_HOME="$dropin_test_dir/home" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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
  out_u_legacy="$(env OVERRIDE_DIR="$dropin_test_dir/getty.d" POLKIT_RULE="$dropin_test_dir/polkit" LOGIN_FILE="$dropin_test_dir/login" DM_STATE_FILE="$dropin_test_dir/dm" TARGET_HOME="$dropin_test_dir/home" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  st_u_legacy=$?
  set -e
  log_u_legacy="$(cat "$STUB_LOG")"
  if [[ $st_u_legacy -eq 0 && ! -e "$foreign_override" && "$log_u_legacy" == *"systemctl daemon-reload"* ]]; then
    pass "uninstall.sh removes legacy lightXDM-written override.conf"
  else
    fail "uninstall.sh legacy override.conf cleanup (status=$st_u_legacy, output=$out_u_legacy, log=$log_u_legacy)"
  fi
fi

# Case 50: uninstall restores a foreign Polkit rule from .lightxdm.bak and saves edits
polkit_test_dir="$TMP_DIR/polkit_uninstall"
mkdir -p "$polkit_test_dir/home"
rm -f "$POLKIT_RULE_DEST" "${POLKIT_RULE_DEST}.lightxdm.bak" "${POLKIT_RULE_DEST}.lightxdm.absent" "${POLKIT_RULE_DEST}.lightxdm-edited"*
printf '// administrator rule\n' >"${POLKIT_RULE_DEST}.lightxdm.bak"
polkit_original_hash="$(sha256sum < "${POLKIT_RULE_DEST}.lightxdm.bak")"
printf '// later administrator edit\n' >"${POLKIT_RULE_DEST}.lightxdm-edited"
polkit_edit_hash="$(sha256sum < "${POLKIT_RULE_DEST}.lightxdm-edited")"
printf '// second administrator edit\n' >"${POLKIT_RULE_DEST}.lightxdm-edited.1"
polkit_second_edit_hash="$(sha256sum < "${POLKIT_RULE_DEST}.lightxdm-edited.1")"
cp "$POLKIT_RULE_SRC" "$POLKIT_RULE_DEST"
printf '// administrator edit before uninstall\n' >>"$POLKIT_RULE_DEST"
polkit_uninstall_edit_hash="$(sha256sum < "$POLKIT_RULE_DEST")"
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh restores the original Polkit rule (unshare -r unavailable)"
else
  for polkit_run in 1 2; do
    set +e
    output="$(env TARGET_HOME="$polkit_test_dir/home" LOGIN_FILE="$polkit_test_dir/login" OVERRIDE_DIR="$polkit_test_dir/getty.d" DM_STATE_FILE="$polkit_test_dir/state" POLKIT_RULE="$POLKIT_RULE_DEST" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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

# Case 51: without a prior Polkit rule, uninstall removes the unmodified rule and absent marker
rm -f "$POLKIT_RULE_DEST" "${POLKIT_RULE_DEST}.lightxdm.bak" "${POLKIT_RULE_DEST}.lightxdm.absent" "${POLKIT_RULE_DEST}.lightxdm-edited"*
cp "$POLKIT_RULE_SRC" "$POLKIT_RULE_DEST"
: >"${POLKIT_RULE_DEST}.lightxdm.absent"
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh removes Polkit rule without a prior rule (unshare -r unavailable)"
else
  set +e
  output="$(env TARGET_HOME="$polkit_test_dir/home" LOGIN_FILE="$polkit_test_dir/login" OVERRIDE_DIR="$polkit_test_dir/getty.d" DM_STATE_FILE="$polkit_test_dir/state" POLKIT_RULE="$POLKIT_RULE_DEST" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && ! -e "$POLKIT_RULE_DEST" && ! -e "${POLKIT_RULE_DEST}.lightxdm.bak" && ! -e "${POLKIT_RULE_DEST}.lightxdm.absent" ]]; then
    pass "uninstall.sh removes Polkit rule without a prior rule"
  else
    fail "uninstall.sh fresh Polkit removal (status=$status, output=$output)"
  fi
fi

# Case 51b: a foreign Polkit symlink in .lightxdm.bak survives uninstall and a repeated uninstall
rm -f "$POLKIT_RULE_DEST" "${POLKIT_RULE_DEST}.lightxdm.bak" "${POLKIT_RULE_DEST}.lightxdm.absent" "${POLKIT_RULE_DEST}.lightxdm-edited"*
printf '// administrator symlink rule\n' >"$polkit_test_dir/original.rules"
polkit_link_hash="$(sha256sum < "$polkit_test_dir/original.rules")"
ln -s "$polkit_test_dir/original.rules" "${POLKIT_RULE_DEST}.lightxdm.bak"
cp "$POLKIT_RULE_SRC" "$POLKIT_RULE_DEST"
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh restores a foreign Polkit symlink (unshare -r unavailable)"
else
  for polkit_run in 1 2; do
    set +e
    output="$(env TARGET_HOME="$polkit_test_dir/home" LOGIN_FILE="$polkit_test_dir/login" OVERRIDE_DIR="$polkit_test_dir/getty.d" DM_STATE_FILE="$polkit_test_dir/state" POLKIT_RULE="$POLKIT_RULE_DEST" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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

# Case 51c: template-identical and dangling Polkit symlinks in .lightxdm.bak round-trip with later symlink edits
for polkit_link_target in "$POLKIT_RULE_SRC" "$polkit_test_dir/missing.rules"; do
  rm -f "$POLKIT_RULE_DEST" "${POLKIT_RULE_DEST}.lightxdm.bak" "${POLKIT_RULE_DEST}.lightxdm.absent" "${POLKIT_RULE_DEST}.lightxdm-edited" "${POLKIT_RULE_DEST}.lightxdm-edited.1" "${POLKIT_RULE_DEST}.lightxdm-edited.2"
  ln -s "$polkit_link_target" "${POLKIT_RULE_DEST}.lightxdm.bak"
  ln -s "$polkit_test_dir/reinstall-missing.rules" "${POLKIT_RULE_DEST}.lightxdm-edited"
  if [[ $can_unshare -eq 0 ]]; then
    skip "uninstall.sh restores Polkit symlink ($polkit_link_target; unshare -r unavailable)"
  else
    ln -s "$POLKIT_RULE_SRC" "$POLKIT_RULE_DEST"
    for polkit_run in 1 2; do
      set +e
      output="$(env TARGET_HOME="$polkit_test_dir/home" LOGIN_FILE="$polkit_test_dir/login" OVERRIDE_DIR="$polkit_test_dir/getty.d" DM_STATE_FILE="$polkit_test_dir/state" POLKIT_RULE="$POLKIT_RULE_DEST" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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

# Case 51d: a fresh Polkit rule edited before uninstall or saved on an older reinstall is saved and removed
for polkit_reinstall in 0 1; do
  rm -f "$POLKIT_RULE_DEST" "${POLKIT_RULE_DEST}.lightxdm.bak" "${POLKIT_RULE_DEST}.lightxdm.absent" "${POLKIT_RULE_DEST}.lightxdm-edited" "${POLKIT_RULE_DEST}.lightxdm-edited.1" "${POLKIT_RULE_DEST}.lightxdm-edited.2"
  cp "$POLKIT_RULE_SRC" "$POLKIT_RULE_DEST"
  : >"${POLKIT_RULE_DEST}.lightxdm.absent"
  printf '// fresh install user edit\n' >>"$POLKIT_RULE_DEST"
  polkit_fresh_edit_hash="$(sha256sum < "$POLKIT_RULE_DEST")"
  if [[ $polkit_reinstall -eq 1 ]]; then
    cp "$POLKIT_RULE_DEST" "${POLKIT_RULE_DEST}.lightxdm-edited"
    cp "$POLKIT_RULE_SRC" "$POLKIT_RULE_DEST"
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
  output="$(env TARGET_HOME="$polkit_test_dir/home" LOGIN_FILE="$polkit_test_dir/login" OVERRIDE_DIR="$polkit_test_dir/getty.d" DM_STATE_FILE="$polkit_test_dir/state" POLKIT_RULE="$POLKIT_RULE_DEST" "${polkit_uninstall_runner[@]}" "$REPO_ROOT/uninstall.sh" 2>&1)"
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
  [[ "$(sha256sum < "$REPO_ROOT/dotfiles/.gpg-agent-gnome")" == "$(sha256sum < "$gpg_reinstall_home/.gpg-agent-kwallet")" ]] &&
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
  out_gpg_u1="$(env TARGET_HOME="$gpg_u_home" LOGIN_FILE="$gpg_uninstall_dir/login" OVERRIDE_DIR="$gpg_uninstall_dir/getty.d" DM_STATE_FILE="$gpg_uninstall_dir/state" POLKIT_RULE="$gpg_uninstall_dir/polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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
  out_gpg_u2="$(env TARGET_HOME="$gpg_u_home" LOGIN_FILE="$gpg_uninstall_dir/login" OVERRIDE_DIR="$gpg_uninstall_dir/getty.d" DM_STATE_FILE="$gpg_uninstall_dir/state" POLKIT_RULE="$gpg_uninstall_dir/polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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
  out_gpg_bak="$(env TARGET_HOME="$gpg_bak_home" LOGIN_FILE="$gpg_uninstall_dir/login" OVERRIDE_DIR="$gpg_uninstall_dir/getty.d" DM_STATE_FILE="$gpg_uninstall_dir/state" POLKIT_RULE="$gpg_uninstall_dir/polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  st_gpg_bak=$?
  out_gpg_bak_twice="$(env TARGET_HOME="$gpg_bak_home" LOGIN_FILE="$gpg_uninstall_dir/login" OVERRIDE_DIR="$gpg_uninstall_dir/getty.d" DM_STATE_FILE="$gpg_uninstall_dir/state" POLKIT_RULE="$gpg_uninstall_dir/polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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

# Case 52b: the gpg-agent autostart entry installs on every desktop, reinstalls cleanly, and uninstall removes or saves it
gpg_tty_entry=".config/autostart/lightxdm-gpg-agent-tty.desktop"
gpg_tty_dir="$TMP_DIR/gpg_tty_entry"
for gpg_tty_de in xfce plasma; do
  gpg_tty_home="$gpg_tty_dir/home_$gpg_tty_de"
  mkdir -p "$gpg_tty_home"
  (
    export HOME="$gpg_tty_home"
    export USER="${USER:-testuser}"
    copy_dotfiles "$gpg_tty_de" 2>/dev/null
    copy_dotfiles "$gpg_tty_de" 2>/dev/null
  )
  if [[ -f "$gpg_tty_home/$gpg_tty_entry" && ! -L "$gpg_tty_home/$gpg_tty_entry" ]] &&
    [[ "$(stat -c '%a' "$gpg_tty_home/$gpg_tty_entry")" == "644" ]] &&
    cmp -s "$gpg_tty_home/$gpg_tty_entry" "$REPO_ROOT/dotfiles/lightxdm-gpg-agent-tty.desktop" &&
    [[ -f "$gpg_tty_home/$gpg_tty_entry.lightxdm.absent" ]] &&
    [[ ! -e "$gpg_tty_home/$gpg_tty_entry.lightxdm.bak" && ! -e "$gpg_tty_home/$gpg_tty_entry.lightxdm-edited" ]]; then
    pass "copy_dotfiles $gpg_tty_de installs ~/$gpg_tty_entry (mode 644) and reinstalls it without a backup or edited copy"
  else
    fail "copy_dotfiles $gpg_tty_de gpg-agent autostart entry"
  fi
done

if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh removes an unmodified gpg-agent autostart entry and saves an edited one (unshare -r unavailable)"
else
  gpg_tty_clean_home="$gpg_tty_dir/home_xfce"
  gpg_tty_edit_home="$gpg_tty_dir/home_plasma"
  echo "X-Edited=true" >>"$gpg_tty_edit_home/$gpg_tty_entry"
  gpg_tty_edit_content="$(cat "$gpg_tty_edit_home/$gpg_tty_entry")"
  set +e
  out_gpg_tty_clean="$(env TARGET_HOME="$gpg_tty_clean_home" LOGIN_FILE="$gpg_tty_dir/login" OVERRIDE_DIR="$gpg_tty_dir/getty.d" DM_STATE_FILE="$gpg_tty_dir/state" POLKIT_RULE="$gpg_tty_dir/polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  st_gpg_tty_clean=$?
  out_gpg_tty_edit="$(env TARGET_HOME="$gpg_tty_edit_home" LOGIN_FILE="$gpg_tty_dir/login" OVERRIDE_DIR="$gpg_tty_dir/getty.d" DM_STATE_FILE="$gpg_tty_dir/state" POLKIT_RULE="$gpg_tty_dir/polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  st_gpg_tty_edit=$?
  set -e
  if [[ $st_gpg_tty_clean -eq 0 && $st_gpg_tty_edit -eq 0 ]] &&
    [[ ! -e "$gpg_tty_clean_home/$gpg_tty_entry" && ! -e "$gpg_tty_clean_home/$gpg_tty_entry.lightxdm.absent" ]] &&
    [[ ! -e "$gpg_tty_clean_home/$gpg_tty_entry.lightxdm-edited" && -d "$gpg_tty_clean_home/.config/autostart" ]] &&
    [[ "$out_gpg_tty_clean" == *"Removing $gpg_tty_clean_home/$gpg_tty_entry..."* ]] &&
    [[ ! -e "$gpg_tty_edit_home/$gpg_tty_entry" && ! -e "$gpg_tty_edit_home/$gpg_tty_entry.lightxdm.absent" ]] &&
    [[ -f "$gpg_tty_edit_home/$gpg_tty_entry.lightxdm-edited" && "$(cat "$gpg_tty_edit_home/$gpg_tty_entry.lightxdm-edited")" == "$gpg_tty_edit_content" ]] &&
    [[ "$out_gpg_tty_edit" == *"Saving edited $gpg_tty_edit_home/$gpg_tty_entry to $gpg_tty_edit_home/$gpg_tty_entry.lightxdm-edited..."* ]]; then
    pass "uninstall.sh removes an unmodified gpg-agent autostart entry, saves an edited one as .lightxdm-edited and keeps ~/.config/autostart"
  else
    fail "uninstall.sh gpg-agent autostart entry (clean=$st_gpg_tty_clean:$out_gpg_tty_clean | edited=$st_gpg_tty_edit:$out_gpg_tty_edit)"
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
  [[ -f "$absent_home1/.wayland-session.lightxdm.absent" && ! -s "$absent_home1/.wayland-session.lightxdm.absent" ]] &&
  [[ -f "$absent_home1/.gpg-agent-kwallet.lightxdm.absent" && ! -s "$absent_home1/.gpg-agent-kwallet.lightxdm.absent" ]]; then
  absent_markers_ok=1
fi
echo "# fresh home bash edit" >>"$absent_home1/.bash_profile"
echo "# fresh home wayland edit" >>"$absent_home1/.wayland-session"
expected_absent_bash="$(cat "$absent_home1/.bash_profile")"
expected_absent_wayland="$(cat "$absent_home1/.wayland-session")"
(
  export HOME="$absent_home1"
  export USER="${USER:-testuser}"
  copy_dotfiles "plasma" 2>/dev/null
)
if [[ $absent_markers_ok -eq 1 ]] &&
  [[ ! -e "$absent_home1/.bash_profile.lightxdm.bak" && ! -e "$absent_home1/.wayland-session.lightxdm.bak" ]] &&
  [[ -f "$absent_home1/.bash_profile.lightxdm.absent" && -f "$absent_home1/.wayland-session.lightxdm.absent" ]] &&
  [[ -f "$absent_home1/.bash_profile.lightxdm-edited" && "$(cat "$absent_home1/.bash_profile.lightxdm-edited")" == "$expected_absent_bash" ]] &&
  [[ -f "$absent_home1/.wayland-session.lightxdm-edited" && "$(cat "$absent_home1/.wayland-session.lightxdm-edited")" == "$expected_absent_wayland" ]]; then
  pass "copy_dotfiles records .lightxdm.absent on fresh home and saves edits to .lightxdm-edited on reinstall"
else
  fail "copy_dotfiles .lightxdm.absent reinstall handling"
fi

if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh removes fresh-home dotfiles and saves edits when .lightxdm.absent exists (unshare -r unavailable)"
else
  set +e
  out_abs1="$(env TARGET_HOME="$absent_home1" LOGIN_FILE="$absent_dir/login" OVERRIDE_DIR="$absent_dir/getty.d" DM_STATE_FILE="$absent_dir/state" POLKIT_RULE="$absent_dir/polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
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
  out_abs2="$(env TARGET_HOME="$absent_home2" LOGIN_FILE="$absent_dir/login" OVERRIDE_DIR="$absent_dir/getty.d" DM_STATE_FILE="$absent_dir/state" POLKIT_RULE="$absent_dir/polkit" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  st_abs2=$?
  set -e

  if [[ $st_abs1 -eq 0 && $st_abs2 -eq 0 ]] &&
    [[ ! -e "$absent_home1/.bash_profile" && ! -L "$absent_home1/.bash_profile" ]] &&
    [[ ! -e "$absent_home1/.wayland-session" && ! -L "$absent_home1/.wayland-session" ]] &&
    [[ ! -e "$absent_home1/.gpg-agent-kwallet" && ! -L "$absent_home1/.gpg-agent-kwallet" ]] &&
    [[ ! -e "$absent_home1/.bash_profile.lightxdm.absent" && ! -e "$absent_home1/.wayland-session.lightxdm.absent" && ! -e "$absent_home1/.gpg-agent-kwallet.lightxdm.absent" ]] &&
    [[ -f "$absent_home1/.bash_profile.lightxdm-edited" && "$(cat "$absent_home1/.bash_profile.lightxdm-edited")" == "$expected_absent_bash" ]] &&
    [[ -f "$absent_home1/.wayland-session.lightxdm-edited" && "$(cat "$absent_home1/.wayland-session.lightxdm-edited")" == "$expected_absent_wayland" ]] &&
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
if [[ $can_unshare -eq 0 ]]; then
  skip "enable-autologin.sh removes a legacy override.conf when switching users (unshare -r unavailable)"
else
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

# Case 56: configure_pam PAM constants stay in the keyring line list uninstall.sh shares
rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
write_stock_login
configure_pam "plasma" 2>/dev/null
plasma_pam_content="$(cat "$LOGIN_FILE")"
configure_pam "gnome" 2>/dev/null
gnome_pam_content="$(cat "$LOGIN_FILE")"
pam_written_lines="$plasma_pam_content"$'\n'"$gnome_pam_content"
pam_sync_errors=()
pam_seen_lines=()
keyring_list_values="$(printf '%s\n' "${LIGHTXDM_KEYRING_LINES[@]}")"
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
  if ! grep -Fxq -- "$pam_line" <<<"$pam_written_lines"; then
    pam_sync_errors+=("${pam_const}:not-written-by-configure_pam")
  fi
  if ! grep -Fxq -- "$pam_line" <<<"$keyring_list_values"; then
    pam_sync_errors+=("${pam_const}:not-in-LIGHTXDM_KEYRING_LINES")
  fi
done
keyring_list_install="$(sed -n '/^readonly LIGHTXDM_KEYRING_LINES=(/,/^)/p' "$REPO_ROOT/install.sh")"
keyring_list_uninstall="$(sed -n '/^readonly LIGHTXDM_KEYRING_LINES=(/,/^)/p' "$REPO_ROOT/uninstall.sh")"
# Four current lines plus the auth line installs before 2026-11-03 appended.
if [[ -z "$keyring_list_install" || "$keyring_list_install" != "$keyring_list_uninstall" ||
  ${#LIGHTXDM_KEYRING_LINES[@]} -ne 5 ]] ||
  ! grep -Fxq -- "auth       optional   pam_gnome_keyring.so auto_start" <<<"$keyring_list_values"; then
  pam_sync_errors+=("keyring-list:${#LIGHTXDM_KEYRING_LINES[@]}")
fi
if [[ ${#pam_sync_errors[@]} -eq 0 ]]; then
  pass "configure_pam PAM constants are in the keyring line list install.sh and uninstall.sh share"
else
  fail "PAM constant drift between install.sh and uninstall.sh (${pam_sync_errors[*]})"
fi

# install.sh and uninstall.sh must agree on which files an older lightXDM installed.
past_helper_install="$(sed -n '/^is_past_lightxdm_template()/,/^}/p' "$REPO_ROOT/install.sh")"
past_helper_uninstall="$(sed -n '/^is_past_lightxdm_template()/,/^}/p' "$REPO_ROOT/uninstall.sh")"
if [[ -n "$past_helper_install" && "$past_helper_install" == "$past_helper_uninstall" ]]; then
  pass "install.sh and uninstall.sh share one is_past_lightxdm_template body"
else
  fail "is_past_lightxdm_template differs between install.sh and uninstall.sh"
fi
# The pinned list must name every version of every bundled home template, the current ones included.
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if template_history="$(bash "$REPO_ROOT/tests/template-history.sh")" &&
    [[ -n "$template_history" && "$template_history" == "$(<"$REPO_ROOT/dotfiles/template-history.sha256")" ]]; then
    pass "dotfiles/template-history.sha256 lists every version of the bundled home templates"
  else
    fail "dotfiles/template-history.sha256 is stale; regenerate it: bash tests/template-history.sh > dotfiles/template-history.sha256"
  fi
else
  skip "dotfiles/template-history.sha256 matches the git history (not a git checkout)"
fi

# lint.sh checks a hand-written list; every tracked shell script and session template must be on it.
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  lint_listed="$(sed -n '/^scripts=(/,/^)/p' "$REPO_ROOT/lint.sh" | sed -e '1d' -e '$d' -e 's/^[[:space:]]*//')"
  lint_missing=()
  while IFS= read -r lint_file; do
    [[ -z "$lint_file" || "$lint_file" == *.desktop ]] && continue
    grep -Fxq -- "$lint_file" <<<"$lint_listed" || lint_missing+=("$lint_file")
  done < <(git -C "$REPO_ROOT" ls-files -- '*.sh' 'dotfiles/.*')
  if [[ ${#lint_missing[@]} -eq 0 ]]; then
    pass "lint.sh lists every tracked shell script and session template"
  else
    fail "lint.sh misses tracked shell files: ${lint_missing[*]}"
  fi
else
  skip "lint.sh file-list coverage (not a git checkout)"
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
  "xfce|xfce|XFCE|<unset>|gpg-agent-gnome|0|1|startxfce4"
  "lxqt|lxqt|LXQt|<unset>|gpg-agent-gnome|0|0|startlxqt"
  "lxde|lxde|LXDE|<unset>|gpg-agent-gnome|1|0|startlxde"
  "mate|mate|MATE|<unset>|gpg-agent-gnome|0|0|mate-session"
  "cinnamon|cinnamon|X-Cinnamon|<unset>|gpg-agent-gnome|0|0|cinnamon-session"
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

# Case 57b: dotfiles/.wayland-session-plasma sets Plasma Wayland env, sources ~/.gpg-agent-kwallet when present, and execs plasma-dbus-run-session-if-needed startplasma-wayland
wl_tmpl="$REPO_ROOT/dotfiles/.wayland-session-plasma"
wl_tmpl_test_dir="$TMP_DIR/wayland_template_plasma"
mkdir -p "$wl_tmpl_test_dir"
wl_tmpl_stub="$wl_tmpl_test_dir/stub-dbus-run"
cat >"$wl_tmpl_stub" <<'EOF'
#!/bin/bash
printf 'dbus-run:%s|pid=%s|DESKTOP_SESSION=%s|XDG_CURRENT_DESKTOP=%s|XDG_SESSION_TYPE=%s|SSH_AUTH_SOCK=%s\n' \
  "$*" \
  "$$" \
  "${DESKTOP_SESSION-<unset>}" \
  "${XDG_CURRENT_DESKTOP-<unset>}" \
  "${XDG_SESSION_TYPE-<unset>}" \
  "${SSH_AUTH_SOCK-<unset>}" >>"$XINITRC_LOG"
EOF
chmod +x "$wl_tmpl_stub"
wl_tmpl_copy="$wl_tmpl_test_dir/.wayland-session-plasma"
sed "s|^exec /usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasma-wayland\$|exec $wl_tmpl_stub /usr/bin/startplasma-wayland|" "$wl_tmpl" >"$wl_tmpl_copy"
chmod 755 "$wl_tmpl_copy"

: >"$xinit_log"
: >"$xinit_err"
: >"$xinit_pid_file"
set +e
(
  exec 2>"$xinit_err"
  echo "$BASHPID" >"$xinit_pid_file"
  export HOME="$xinit_home"
  export XINITRC_LOG="$xinit_log"
  unset DESKTOP_SESSION XDG_CURRENT_DESKTOP XDG_SESSION_TYPE SSH_AUTH_SOCK
  exec bash "$wl_tmpl_copy"
)
wl_with_kw_status=$?
wl_with_kw_pid="$(cat "$xinit_pid_file")"
wl_with_kw_log="$(cat "$xinit_log")"
wl_with_kw_err="$(cat "$xinit_err")"

: >"$xinit_log"
: >"$xinit_err"
: >"$xinit_pid_file"
(
  exec 2>"$xinit_err"
  echo "$BASHPID" >"$xinit_pid_file"
  export HOME="$xinit_empty_home"
  export XINITRC_LOG="$xinit_log"
  unset DESKTOP_SESSION XDG_CURRENT_DESKTOP XDG_SESSION_TYPE SSH_AUTH_SOCK
  exec bash "$wl_tmpl_copy"
)
wl_empty_status=$?
set -e
wl_empty_pid="$(cat "$xinit_pid_file")"
wl_empty_log="$(cat "$xinit_log")"
wl_empty_err="$(cat "$xinit_err")"
wl_last_line="$(tail -n 1 "$wl_tmpl")"

# Git records only the executable bit, so the checkout's umask decides the other permission bits.
if [[ -x "$wl_tmpl" && "$(git -C "$REPO_ROOT" ls-files -s dotfiles/.wayland-session-plasma 2>/dev/null)" != 100644* && ! -e "$REPO_ROOT/dotfiles/.xinitrc-plasma" ]] &&
  [[ "$(head -n 1 "$wl_tmpl")" == "#!/bin/bash" ]] &&
  grep -Fxq '# Wayland session for lightXDM: start KDE Plasma' "$wl_tmpl" &&
  [[ "$wl_last_line" == "exec /usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasma-wayland" ]] &&
  [[ $wl_with_kw_status -eq 0 && -z "$wl_with_kw_err" ]] &&
  [[ "$wl_with_kw_log" == $'gpg-agent-kwallet\ndbus-run:/usr/bin/startplasma-wayland|pid='"$wl_with_kw_pid"'|DESKTOP_SESSION=plasma|XDG_CURRENT_DESKTOP=KDE|XDG_SESSION_TYPE=wayland|SSH_AUTH_SOCK=/tmp/kwallet-gpg-ssh.sock' ]] &&
  [[ $wl_empty_status -eq 0 && -z "$wl_empty_err" ]] &&
  [[ "$wl_empty_log" == "dbus-run:/usr/bin/startplasma-wayland|pid=${wl_empty_pid}|DESKTOP_SESSION=plasma|XDG_CURRENT_DESKTOP=KDE|XDG_SESSION_TYPE=wayland|SSH_AUTH_SOCK=<unset>" ]]; then
  pass ".wayland-session-plasma sets Wayland env, sources ~/.gpg-agent-kwallet when present, and execs startplasma-wayland via plasma-dbus-run-session-if-needed"
else
  fail ".wayland-session-plasma behavior (kw=$wl_with_kw_status:$wl_with_kw_err:$wl_with_kw_log | empty=$wl_empty_status:$wl_empty_err:$wl_empty_log | last=$wl_last_line)"
fi

# Case 57c: GNOME and Budgie templates set Wayland env, source the optional keyring helper, and exec the packaged session command
wl_session_specs=(
  "gnome|gnome|GNOME|/usr/bin/gnome-session"
  "budgie|budgie-desktop|Budgie|/usr/bin/startbudgielabwc"
)
for spec in "${wl_session_specs[@]}"; do
  IFS='|' read -r wl_de wl_ds wl_desktop wl_command <<<"$spec"
  wl_tmpl="$REPO_ROOT/dotfiles/.wayland-session-$wl_de"
  wl_tmpl_test_dir="$TMP_DIR/wayland_template_$wl_de"
  mkdir -p "$wl_tmpl_test_dir"
  wl_tmpl_stub="$wl_tmpl_test_dir/stub-session"
  cat >"$wl_tmpl_stub" <<'EOF'
#!/bin/bash
printf 'session:%s|pid=%s|DESKTOP_SESSION=%s|XDG_CURRENT_DESKTOP=%s|XDG_SESSION_TYPE=%s|GDK_BACKEND=%s|SSH_AUTH_SOCK=%s\n' \
  "$*" "$$" "${DESKTOP_SESSION-<unset>}" "${XDG_CURRENT_DESKTOP-<unset>}" \
  "${XDG_SESSION_TYPE-<unset>}" "${GDK_BACKEND-<unset>}" "${SSH_AUTH_SOCK-<unset>}" >>"$XINITRC_LOG"
EOF
  chmod 755 "$wl_tmpl_stub"
  wl_tmpl_copy="$wl_tmpl_test_dir/.wayland-session-$wl_de"
  sed "s|^exec $wl_command\$|exec $wl_tmpl_stub|" "$wl_tmpl" >"$wl_tmpl_copy"
  chmod 755 "$wl_tmpl_copy"

  # Check Git's recorded executable mode, since checkout permissions depend on umask.
  if [[ "$(git -C "$REPO_ROOT" ls-files -s "dotfiles/.wayland-session-$wl_de")" == 100755* &&
    ! -e "$REPO_ROOT/dotfiles/.xinitrc-$wl_de" &&
    "$(head -n 1 "$wl_tmpl")" == "#!/bin/bash" && "$(tail -n 1 "$wl_tmpl")" == "exec $wl_command" ]] &&
    grep -Fxq "# Wayland session for lightXDM: start $wl_desktop" "$wl_tmpl"; then
    pass ".wayland-session-$wl_de has the required header, exec path and recorded mode 100755"
  else
    fail ".wayland-session-$wl_de content or Git mode"
  fi

  for wl_helper in present absent; do
    wl_test_home="$xinit_home"
    expected_wl_log=$'gpg-agent-gnome\n'
    wl_ssh="/tmp/gnome-gpg-ssh.sock"
    if [[ "$wl_helper" == absent ]]; then
      wl_test_home="$xinit_empty_home"
      expected_wl_log=""
      wl_ssh="<unset>"
    fi
    : >"$xinit_log"
    : >"$xinit_err"
    : >"$xinit_pid_file"
    set +e
    (
      exec 2>"$xinit_err"
      echo "$BASHPID" >"$xinit_pid_file"
      export HOME="$wl_test_home" XINITRC_LOG="$xinit_log"
      unset DESKTOP_SESSION XDG_CURRENT_DESKTOP XDG_SESSION_TYPE GDK_BACKEND SSH_AUTH_SOCK
      exec bash "$wl_tmpl_copy"
    )
    wl_status=$?
    set -e
    wl_pid="$(cat "$xinit_pid_file")"
    wl_log="$(cat "$xinit_log")"
    wl_err="$(cat "$xinit_err")"
    expected_wl_log+="session:|pid=$wl_pid|DESKTOP_SESSION=$wl_ds|XDG_CURRENT_DESKTOP=$wl_desktop|XDG_SESSION_TYPE=wayland|GDK_BACKEND=<unset>|SSH_AUTH_SOCK=$wl_ssh"
    if [[ $wl_status -eq 0 && -z "$wl_err" && "$wl_log" == "$expected_wl_log" ]]; then
      pass ".wayland-session-$wl_de exports Wayland env and execs its session with keyring helper $wl_helper"
    else
      fail ".wayland-session-$wl_de behavior (helper=$wl_helper, status=$wl_status, err=$wl_err, log=$wl_log, expected=$expected_wl_log)"
    fi
  done
done

# Case 58: .bash_profile starts X only on interactive tty1 outside X without no-autostart, before .bashrc
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
cat >"$profile_bin/systemd-cat" <<'EOF'
#!/bin/bash
printf 'systemd-cat|%s\n' "$*" >>"$HOME/profile.log"
[[ $# -ge 3 && $1 == -t && $2 == lightxdm ]] || exit 1
shift 2
exec "$@"
EOF
chmod +x "$profile_bin/tty" "$profile_bin/startx" "$profile_bin/systemd-cat"

for profile_case in interactive journal journal-no-systemd-cat no-autostart autostart-restored non-interactive display tty2 missing-startx; do
  profile_flags=(-i)
  profile_display=''
  profile_tty=/dev/tty1
  profile_path="$profile_bin:/usr/bin:/bin"
  rm -f "$profile_home/.config/lightxdm/no-autostart" "$profile_home/.config/lightxdm/session-journal" \
    "$profile_home/.local/state/lightxdm/startx-attempts"
  case "$profile_case" in
    journal) touch "$profile_home/.config/lightxdm/session-journal" ;;
    journal-no-systemd-cat)
      touch "$profile_home/.config/lightxdm/session-journal"
      mv "$profile_bin/systemd-cat" "$profile_bin/systemd-cat.off"
      # Exclude any host systemd-cat; tty and startx use only Bash builtins.
      profile_path="$profile_bin"
      ;;
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
  if [[ "$profile_case" == interactive || "$profile_case" == autostart-restored ||
    "$profile_case" == journal || "$profile_case" == journal-no-systemd-cat ]]; then
    expected_log="startx|$profile_home/.local/bin:$profile_path"
    expected_output=''
  fi
  if [[ "$profile_case" == journal ]]; then
    expected_log=$'systemd-cat|-t lightxdm startx\n'"$expected_log"
  fi
  if [[ $status -eq 0 && "$actual_log" == "$expected_log" && ! -s "$profile_home/profile.err" &&
    "$output" == "$expected_output" ]]; then
    pass ".bash_profile $profile_case preserves PATH and startup order"
  else
    fail ".bash_profile $profile_case (status=$status, log=$actual_log, expected=$expected_log, output=$output, stderr=$(cat "$profile_home/profile.err"))"
  fi
  if [[ "$profile_case" == journal-no-systemd-cat ]]; then
    mv "$profile_bin/systemd-cat.off" "$profile_bin/systemd-cat"
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
  [[ ${#pause_out_lines[@]} -eq 2 &&
    "${pause_out_lines[0]}" == "TTY1 auto-start paused: the session was started 3 times within 30s; run 'rm ~/.config/lightxdm/no-autostart' to resume." &&
    "${pause_out_lines[1]}" == "after|" ]]; then
  pass ".bash_profile pauses after three recent session attempts, creates no-autostart, clears attempts, and loads .bashrc"
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

# Case 58b: .bash_profile prefers executable ~/.wayland-session over startx, works without startx, and skips launch when WAYLAND_DISPLAY is set
cat >"$profile_home/.wayland-session" <<'EOF'
#!/bin/bash
printf 'wayland-session|%s\n' "$PATH" >>"$HOME/profile.log"
EOF
chmod 755 "$profile_home/.wayland-session"
rm -f "$profile_home/.config/lightxdm/no-autostart" "$profile_attempts"
run_tty1_profile
profile_expected_wl="wayland-session|$profile_home/.local/bin:$profile_bin:/usr/bin:/bin"
if [[ $status -eq 0 && "$actual_log" == "$profile_expected_wl" && -z "$output" && ! -s "$profile_home/profile.err" ]]; then
  pass ".bash_profile execs ~/.wayland-session instead of startx when ~/.wayland-session is executable"
else
  fail ".bash_profile wayland-session over startx (status=$status, log=$actual_log, output=$output, stderr=$(cat "$profile_home/profile.err"))"
fi

# With the session-journal marker, systemd-cat wraps the selected ~/.wayland-session, not startx
mkdir -p "$profile_home/.config/lightxdm"
touch "$profile_home/.config/lightxdm/session-journal"
rm -f "$profile_home/.config/lightxdm/no-autostart" "$profile_attempts"
run_tty1_profile
rm -f "$profile_home/.config/lightxdm/session-journal"
if [[ $status -eq 0 && "$actual_log" == "systemd-cat|-t lightxdm $profile_home/.wayland-session"$'\n'"$profile_expected_wl" &&
  -z "$output" && ! -s "$profile_home/profile.err" ]]; then
  pass ".bash_profile runs ~/.wayland-session through systemd-cat when session-journal exists"
else
  fail ".bash_profile wayland-session journal (status=$status, log=$actual_log, output=$output, stderr=$(cat "$profile_home/profile.err"))"
fi

# Without startx on PATH, an executable ~/.wayland-session still launches
mv "$profile_bin/startx" "$profile_bin/startx.off"
rm -f "$profile_home/.config/lightxdm/no-autostart" "$profile_attempts"
printf '/dev/tty1\n' >"$profile_home/tty"
# shellcheck disable=SC2016
output="$(env -i HOME="$profile_home" PATH="$profile_bin:/usr/bin:/bin" TERM=dumb DISPLAY='' bash -i -c '
  exec 2>"$HOME/profile.err"
  PATH=$2
  : >"$HOME/profile.log"
  source "$1"
  printf "after|%s\n" "${!_lightxdm_*}"
' bash "$REPO_ROOT/dotfiles/.bash_profile" "$profile_bin" 2>/dev/null)" && status=0 || status=$?
actual_log="$(cat "$profile_home/profile.log")"
if [[ $status -eq 0 && "$actual_log" == "wayland-session|$profile_home/.local/bin:$profile_bin" &&
  -z "$output" && ! -s "$profile_home/profile.err" ]]; then
  pass ".bash_profile execs ~/.wayland-session on tty1 even when startx is not on PATH"
else
  fail ".bash_profile wayland-session without startx (status=$status, log=$actual_log, output=$output, stderr=$(cat "$profile_home/profile.err"))"
fi

# Non-executable ~/.wayland-session without startx does nothing and leaves no _lightxdm_* vars; with startx it falls back to startx
chmod 644 "$profile_home/.wayland-session"
rm -f "$profile_home/.config/lightxdm/no-autostart" "$profile_attempts"
# shellcheck disable=SC2016
output="$(env -i HOME="$profile_home" PATH="$profile_bin:/usr/bin:/bin" TERM=dumb DISPLAY='' bash -i -c '
  exec 2>"$HOME/profile.err"
  PATH=$2
  : >"$HOME/profile.log"
  source "$1"
  printf "after|%s\n" "${!_lightxdm_*}"
' bash "$REPO_ROOT/dotfiles/.bash_profile" "$profile_bin" 2>/dev/null)" && status=0 || status=$?
actual_log="$(cat "$profile_home/profile.log")"
no_launcher_ok=0
if [[ $status -eq 0 && "$actual_log" == "bashrc|$profile_home/.local/bin:$profile_bin" &&
  "$output" == "after|" && ! -s "$profile_home/profile.err" ]]; then
  no_launcher_ok=1
fi
mv "$profile_bin/startx.off" "$profile_bin/startx"
rm -f "$profile_home/.config/lightxdm/no-autostart" "$profile_attempts"
run_tty1_profile
if [[ $no_launcher_ok -eq 1 && $status -eq 0 && "$actual_log" == "$profile_expected_startx" &&
  -z "$output" && ! -s "$profile_home/profile.err" ]]; then
  pass ".bash_profile ignores non-executable ~/.wayland-session (falls back to startx or loads .bashrc cleanly)"
else
  fail ".bash_profile non-executable ~/.wayland-session (no_launcher=$no_launcher_ok, status=$status, log=$actual_log, output=$output)"
fi

# When WAYLAND_DISPLAY is set, .bash_profile skips launch for both Wayland and X11 setups
chmod 755 "$profile_home/.wayland-session"
for wl_disp_mode in with-wayland-session startx-only; do
  if [[ "$wl_disp_mode" == startx-only ]]; then
    rm -f "$profile_home/.wayland-session"
  fi
  rm -f "$profile_home/.config/lightxdm/no-autostart" "$profile_attempts"
  printf '/dev/tty1\n' >"$profile_home/tty"
  # shellcheck disable=SC2016
  output="$(env -i HOME="$profile_home" PATH="$profile_bin:/usr/bin:/bin" TERM=dumb \
    DISPLAY='' WAYLAND_DISPLAY=wayland-0 bash -i -c '
      exec 2>"$HOME/profile.err"
      PATH=$2
      : >"$HOME/profile.log"
      source "$1"
      printf "after|%s\n" "${!_lightxdm_*}"
    ' bash "$REPO_ROOT/dotfiles/.bash_profile" "$profile_bin:/usr/bin:/bin" 2>/dev/null)" && status=0 || status=$?
  actual_log="$(cat "$profile_home/profile.log")"
  if [[ $status -eq 0 && "$actual_log" == "$profile_expected_bashrc" &&
    "$output" == "after|" && ! -s "$profile_home/profile.err" ]]; then
    pass ".bash_profile skips session launch when WAYLAND_DISPLAY is set ($wl_disp_mode)"
  else
    fail ".bash_profile WAYLAND_DISPLAY skip ($wl_disp_mode, status=$status, log=$actual_log, output=$output, stderr=$(cat "$profile_home/profile.err"))"
  fi
done

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
    output="$(env TARGET_HOME="$ml_home" LOGIN_FILE="$ml_login" OVERRIDE_DIR="$ml_dir" POLKIT_RULE="$ml_polkit" DM_STATE_FILE="$ml_dm_state" "${ml_runner[@]}" "$REPO_ROOT/uninstall.sh" 2>&1)"
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

# A failing menu with no detected desktop names the next step
: >"$STUB_LOG"
set +e
output="$(STUB_DETECTED_DE=unknown STUB_PROMPT_RC=1 run_main_with_stubs "$sudo_pw_dir" 2>&1)"
status=$?
set -e
if [[ $status -eq 1 && "$output" == *"Pass --de <id>"* ]]; then
  pass "main names --de when the menu fails with no detected desktop"
else
  fail "main menu failure message (status=$status, output=$output)"
fi

# Case 61: install_packages and detect_de cover all nine desktops' package lists and detection pairs
expected_base_pkgs="xorg-server xorg-xinit udisks2 polkit gvfs gvfs-mtp gvfs-gphoto2 gvfs-afc"
expected_wayland_base_pkgs="udisks2 polkit gvfs gvfs-mtp gvfs-gphoto2 gvfs-afc"
de_pkg_specs=(
  "plasma|plasma-desktop|plasma-desktop konsole dolphin kwallet-pam polkit-kde-agent"
  "gnome|gnome-shell|gnome-shell gnome-session gnome-control-center nautilus gnome-terminal gnome-keyring"
  "xfce|xfce4-session|xfce4 xfce4-session xfce4-terminal gnome-keyring polkit-gnome"
  "lxqt|lxqt-session|lxqt xdg-utils lxterminal gnome-keyring lxqt-policykit"
  "lxde|lxde-common|lxde-common lxsession lxpanel openbox pcmanfm lxterminal gnome-keyring"
  "mate|mate-session-manager|mate mate-terminal gnome-keyring"
  "cinnamon|cinnamon|cinnamon gnome-terminal gnome-keyring"
  "budgie|budgie-desktop|budgie-desktop gnome-terminal gnome-keyring"
  "i3|i3-wm|i3 xterm dex gnome-keyring polkit-gnome"
)

for wl_pkg_de in plasma gnome budgie; do
  wl_pkg_list="$(list_packages "$wl_pkg_de")"
  if ! grep -Fxq 'xorg-server' <<<"$wl_pkg_list" && ! grep -Fxq 'xorg-xinit' <<<"$wl_pkg_list"; then
    pass "list_packages $wl_pkg_de omits xorg-server and xorg-xinit"
  else
    fail "list_packages $wl_pkg_de unexpectedly included Xorg packages ($wl_pkg_list)"
  fi
done

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
  de_base_pkgs="$expected_base_pkgs"
  case "$de" in
    plasma | gnome | budgie) de_base_pkgs="$expected_wayland_base_pkgs" ;;
  esac

  : >"$STUB_LOG"
  set +e
  output="$(install_packages "$de" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  expected_pacman_log="pacman -S --needed --noconfirm $de_base_pkgs $de_pkgs"
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
  de_base_pkgs="$expected_base_pkgs"
  case "$de" in
    plasma | gnome | budgie) de_base_pkgs="$expected_wayland_base_pkgs" ;;
  esac
  expected_no_kr_pkgs=()
  for pkg in $de_pkgs; do
    case "$pkg" in
      gnome-keyring | kwallet-pam) ;;
      *) expected_no_kr_pkgs+=("$pkg") ;;
    esac
  done
  expected_no_kr_log="pacman -S --needed --noconfirm $de_base_pkgs ${expected_no_kr_pkgs[*]}"

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
    [[ ! -e "$POLKIT_RULE_DEST" ]]; then
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
    [[ ! -e "$POLKIT_RULE_DEST" ]]; then
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
if [[ $status -eq 1 && "$output" == *"Unsupported desktop environment: dwm"* && "$output" == *"need --no-packages"* && ! -s "$STUB_LOG" ]]; then
  pass "main --no-keyring --de dwm still requires --no-packages for custom sessions"
else
  fail "main --no-keyring --de dwm without --no-packages (status=$status, log=$(cat "$STUB_LOG"), output=$output)"
fi

# A custom id without a template points at --init-template
: >"$STUB_LOG"
set +e
output="$(run_main_with_stubs "$sudo_pw_dir" --no-packages --de notemplate 2>&1)"
status=$?
set -e
if [[ $status -eq 1 && "$output" == *"--init-template --de notemplate"* && ! -s "$STUB_LOG" ]]; then
  pass "main suggests --init-template for a custom id without a template"
else
  fail "main custom id without template (status=$status, log=$(cat "$STUB_LOG"), output=$output)"
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
    [[ "$log_content" != *"disable_display_managers"* ]] &&
    [[ "$output" == *"$recovery_hint"* && "$output" != *"lightXDM install complete!"* ]] &&
    grep -Fxq '=> Install stopped during install_packages; already done: none' <<<"$output"; then
    pass "main ${fail_pkg_args[*]} stops on pacman failure before dotfiles, PAM, Polkit, or display managers"
  else
    fail "main ${fail_pkg_args[*]} on pacman failure (status=$status, log=$log_content, output=$output)"
  fi
done

# Case 64: --no-polkit-rule is accepted as a no-op with a note and neither it nor a plain install creates a Polkit rule
help_no_polkit_out="$(HOME="$help_home" bash "$REPO_ROOT/install.sh" --help 2>&1)"
if [[ "$help_no_polkit_out" != *"--no-polkit-rule"* && "$help_no_polkit_out" != *"Polkit rule"* ]]; then
  pass "install.sh --help omits --no-polkit-rule and Polkit rule installation"
else
  fail "install.sh --help still mentions Polkit rule (output=$help_no_polkit_out)"
fi

for default_polkit_spec in \
  "default||Auto-unlock is set" \
  "de-lxqt|--de lxqt|Auto-unlock is set" \
  "no-packages|--no-packages|Auto-unlock is set" \
  "no-keyring|--no-keyring|Keyring setup skipped"; do
  IFS='|' read -r dp_label dp_flags dp_summary <<<"$default_polkit_spec"
  dp_args=()
  if [[ -n "$dp_flags" ]]; then
    read -r -a dp_args <<<"$dp_flags"
  fi
  rm -f "$POLKIT_RULE_DEST"
  : >"$STUB_LOG"
  set +e
  output="$(USER=testuser run_main_with_stubs "$bash_stub_dir:$sudo_pw_dir" "${dp_args[@]}" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  if [[ $status -eq 0 && ! -e "$POLKIT_RULE_DEST" ]] &&
    ! grep -Fxq -- "install_polkit_rule" "$STUB_LOG" &&
    [[ "$output" != *"--no-polkit-rule"* && "$output" != *"Polkit"* && "$output" == *"- $dp_summary"* ]]; then
    pass "main ${dp_flags:-<default>} creates no Polkit rule and reports '$dp_summary'"
  else
    fail "main ${dp_label} Polkit default (status=$status, log=$log_content, output=$output)"
  fi
done

for skip_polkit_spec in \
  "alone|--no-polkit-rule|i3|1|1|Auto-unlock is set" \
  "with-de|--no-polkit-rule --de lxqt|lxqt|1|1|Auto-unlock is set" \
  "de-first|--de xfce --no-polkit-rule|xfce|1|1|Auto-unlock is set" \
  "no-packages|--no-packages --no-polkit-rule|i3|0|1|Auto-unlock is set" \
  "no-keyring|--no-keyring --no-polkit-rule|i3|1|0|Keyring setup skipped" \
  "no-pkg-no-kr|--no-packages --no-keyring --de i3 --no-polkit-rule|i3|0|0|Keyring setup skipped" \
  "all-flags|--de dwm --no-polkit-rule --no-keyring --no-packages|dwm|0|0|Keyring setup skipped"; do
  IFS='|' read -r sp_label sp_flags sp_de sp_expect_pkg sp_expect_pam sp_summary <<<"$skip_polkit_spec"
  read -r -a sp_args <<<"$sp_flags"
  rm -f "$POLKIT_RULE_DEST"
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
  if [[ $status -eq 0 && $pkg_ok -eq 1 && $pam_ok -eq 1 && ! -e "$POLKIT_RULE_DEST" ]] &&
    ! grep -Fxq -- "install_polkit_rule" "$STUB_LOG" &&
    grep -Fxq -- "copy_dotfiles $sp_de" "$STUB_LOG" &&
    grep -Fxq -- "disable_display_managers" "$STUB_LOG" &&
    [[ "$output" == *"--no-polkit-rule is no longer needed: lightXDM does not install a Polkit rule."* ]] &&
    [[ "$output" == *"- $sp_summary"* && "$output" != *"Polkit rules are set"* ]]; then
    pass "main $sp_flags prints the --no-polkit-rule note, creates no rule file, and reports '$sp_summary'"
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
  [[ "$out_zsh_nopolkit" == *"--no-polkit-rule is no longer needed"* &&
    "$out_zsh_nopolkit" == *"- Auto-unlock is set"* && "$out_zsh_nopolkit" != *"Polkit rule skipped"* &&
    "$out_zsh_nopolkit" != *"Polkit rules are set"* ]]; then
  pass "main --no-polkit-rule prints the note and closing summary for non-bash login shells too"
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
if [[ $status -eq 0 && "$output" == *"--no-polkit-rule is no longer needed"* &&
  ! -e "$POLKIT_RULE_DEST" && ! -L "$POLKIT_RULE_DEST" &&
  ! -e "${POLKIT_RULE_DEST}.lightxdm.bak" && ! -e "${POLKIT_RULE_DEST}.lightxdm.absent" ]]; then
  pass "main --no-polkit-rule creates no Polkit rule or marker when none existed"
else
  fail "main --no-polkit-rule on absent Polkit rule (status=$status, output=$output)"
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
if [[ $status -eq 0 && ! -e "$POLKIT_RULE_DEST" && ! -L "$POLKIT_RULE_DEST" &&
  ! -e "${POLKIT_RULE_DEST}.lightxdm.bak" && ! -e "${POLKIT_RULE_DEST}.lightxdm.absent" ]]; then
  pass "main without --no-polkit-rule also creates no Polkit rule or marker"
else
  fail "main default creates no Polkit rule (status=$status, output=$output)"
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
if [[ $status -eq 0 && -f "$POLKIT_RULE_DEST" &&
  "$(sha256sum < "$POLKIT_RULE_DEST")" == "$custom_polkit_hash" &&
  ! -e "${POLKIT_RULE_DEST}.lightxdm.bak" && ! -e "${POLKIT_RULE_DEST}.lightxdm.absent" &&
  ! -e "${POLKIT_RULE_DEST}.lightxdm-edited" ]]; then
  pass "main without --no-polkit-rule also leaves an existing Polkit rule untouched"
else
  fail "main default with existing Polkit rule (status=$status, output=$output)"
fi
rm -f "$POLKIT_RULE_DEST"

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

# A persistently masked TTY1 getty must be unmasked before enabling autologin.
if [[ $EUID -eq 0 ]]; then
  masked_runner=(bash)
elif [[ $can_unshare -eq 1 ]]; then
  masked_runner=(unshare -r bash)
else
  masked_runner=()
fi
if [[ ${#masked_runner[@]} -eq 0 ]]; then
  skip "enable-autologin.sh masked getty handling (unshare -r unavailable)"
else
  masked_bin="$TMP_DIR/masked_getty_bin"
  mkdir -p "$masked_bin"
  cat >"$masked_bin/getent" <<'EOF'
#!/usr/bin/env bash
echo 'testuser:x:1000:1000::/home/testuser:/bin/bash'
EOF
  cat >"$masked_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == 'is-enabled getty@tty1.service' ]]; then
  echo "$GETTY_STATE"
  # Like the real systemctl, report masked states with a failing exit status.
  case "$GETTY_STATE" in
    masked | masked-runtime) exit 1 ;;
  esac
else
  echo "$*" >>"$GETTY_LOG"
fi
EOF
  chmod +x "$masked_bin/getent" "$masked_bin/systemctl"
  for getty_state in masked masked-runtime enabled; do
    masked_dir="$TMP_DIR/getty_state_$getty_state"
    mkdir -p "$masked_dir"
    : >"$masked_dir/log"
    set +e
    output="$(env PATH="$masked_bin:$PATH" GETTY_STATE="$getty_state" GETTY_LOG="$masked_dir/log" OVERRIDE_DIR="$masked_dir/getty.d" SYSTEMD_RUN_DIR="$masked_dir/run" LOGIN_FILE="$masked_dir/login" "${masked_runner[@]}" "$REPO_ROOT/enable-autologin.sh" testuser 2>&1)"
    status=$?
    set -e
    if [[ "$getty_state" == masked ]]; then
      if [[ $status -eq 1 && "$output" == *"systemctl unmask getty@tty1.service"* && ! -e "$masked_dir/getty.d" && ! -s "$masked_dir/log" ]]; then
        pass "enable-autologin.sh refuses a masked getty without changes"
      else
        fail "enable-autologin.sh masked getty (status=$status, output=$output)"
      fi
    elif [[ $status -eq 0 && -f "$masked_dir/getty.d/lightxdm-autologin.conf" && "$(cat "$masked_dir/log")" == daemon-reload && "$output" == *"Autologin enabled for user testuser"* ]]; then
      pass "enable-autologin.sh enables autologin with getty $getty_state"
    else
      fail "enable-autologin.sh getty $getty_state (status=$status, output=$output)"
    fi
  done
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
    output="$(env STUB_SYSTEMCTL_FAIL_RELOAD=1 SYSTEMD_RUN_DIR="$reload_dir/run" TARGET_HOME="$reload_dir/home" LOGIN_FILE="$reload_dir/login" OVERRIDE_DIR="$reload_dir/getty.d" POLKIT_RULE="$reload_dir/polkit" DM_STATE_FILE="$reload_dir/state/disabled-display-managers" "${reload_runner[@]}" "$REPO_ROOT/uninstall.sh" 2>&1)"
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

# Case 67: a failing backup copy stops configure_pam before modifying LOGIN_FILE
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
    [[ "$autologin_pam_case" == with && "$output" == *"TTY1 autologin is enabled"* && "$output" == *"sudo $CMD_AUTOLOGIN --disable"* &&
      "$output" == *"sudo $CMD_UNINSTALL --keyring-only"* ]] ||
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
      OVERRIDE_DIR="$ly_dir/getty.d" \
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

# Case 70: desktop menu options 1-9, invalid-then-valid retry, and end-to-end selection through main
menu_out="$TMP_DIR/menu_out"
menu_ids=(xfce lxqt lxde mate cinnamon i3 plasma gnome budgie)
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
expected_menu_main_log=$'sudo -v\ndetect_de\ninstall_packages lxqt\ncopy_dotfiles lxqt\nconfigure_pam lxqt\ndisable_display_managers'
if [[ $status -eq 0 && "$log_content" == "$expected_menu_main_log" &&
  "$output" == *"No supported desktop environment detected."* &&
  "$output" == *"lightXDM install complete!"* && "$output" == *"- lxqt "* ]]; then
  pass "main runs install steps for lxqt when selected interactively from the desktop menu"
else
  fail "main interactive desktop menu selection (status=$status, log=$log_content, output=$output)"
fi

# Case 71: a failed PAM append stops main before display managers
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
  [[ "$log_content" != *"disable_display_managers"* &&
    "$output" == *"$recovery_hint"* && "$output" != *"lightXDM install complete!"* ]] &&
  grep -Fxq '=> Install stopped during configure_pam; already done: install_packages copy_dotfiles' <<<"$output"; then
  pass "main stops on PAM append failure before display managers"
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
  [[ ! -e "$ut_plain_home/.config/lightxdm" ]]; then
  pass "A user .config/lightxdm/.xinitrc-i3 overrides dotfiles/.xinitrc-i3 without creating ~/.config/lightxdm when absent"
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
      OVERRIDE_DIR="$user_tmpl_dir/getty.d" \
      POLKIT_RULE="$user_tmpl_dir/u_polkit1" \
      DM_STATE_FILE="$user_tmpl_dir/u_dm1" \
      "${ut_uninstall_runner[@]}" "$REPO_ROOT/uninstall.sh" 2>&1
  )"
  st_ut_custom=$?
  out_ut_override="$(
    env TARGET_HOME="$ut_override_home" \
      LOGIN_FILE="$user_tmpl_dir/u_login2" \
      OVERRIDE_DIR="$user_tmpl_dir/getty.d" \
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
      OVERRIDE_DIR="$user_tmpl_dir/getty.d" \
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
      OVERRIDE_DIR="$user_tmpl_dir/getty.d" \
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
        OVERRIDE_DIR="$ut_selected_dir/getty.d" \
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
        OVERRIDE_DIR="$ut_copy_dir/getty.d" \
        POLKIT_RULE="$ut_copy_dir/u_polkit" \
        DM_STATE_FILE="$ut_copy_dir/u_dm" \
        "${ut_uninstall_runner[@]}" "$REPO_ROOT/uninstall.sh" 2>&1
    )"
    st_u1=$?
    out_u2="$(
      env TARGET_HOME="$ut_copy_home" \
        LOGIN_FILE="$ut_copy_dir/u_login" \
        OVERRIDE_DIR="$ut_copy_dir/getty.d" \
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
      OVERRIDE_DIR="$user_tmpl_dir/getty.d" \
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
  lp_base_pkgs="$expected_base_pkgs"
  case "$lp_de" in
    plasma | gnome | budgie) lp_base_pkgs="$expected_wayland_base_pkgs" ;;
  esac
  read -r -a lp_expected_arr <<<"$lp_base_pkgs $lp_de_pkgs"
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

for lp_wayland_de in gnome budgie; do
  : >"$STUB_LOG"
  : >"$lp_err"
  set +e
  lp_wl_out="$(HOME="$lp_home" run_main_with_stubs "$sudo_pw_dir" --list-packages --de "$lp_wayland_de" 2>"$lp_err")"
  lp_wl_status=$?
  set -e
  lp_wl_err="$(cat "$lp_err")"
  if [[ $lp_wl_status -eq 0 && "$lp_wl_out" == "$(list_packages "$lp_wayland_de")" &&
    -z "$lp_wl_err" && ! -s "$STUB_LOG" ]] &&
    ! grep -Eq '^xorg-(server|xinit)$' <<<"$lp_wl_out"; then
    pass "main --list-packages --de $lp_wayland_de lists Wayland packages before sudo -v"
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

# Dry-run resolves the same destinations as a real install without changing its inputs.
dr_dir="$TMP_DIR/dry_run"
dr_bin="$dr_dir/bin"
mkdir -p "$dr_bin"
cat >"$dr_bin/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >>"$STUB_LOG"
[[ "${1:-}" == -v ]] && exit 0
exec "$@"
EOF
cat >"$dr_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$STUB_LOG"
case "$1" in
  list-unit-files)
    printf '%s\n' 'sddm.service enabled' 'lightdm.service disabled' 'gdm.service static' 'lxdm.service enabled'
    ;;
  is-enabled)
    case "$2" in
      sddm.service | lxdm.service | getty@tty1.service) echo enabled ;;
      *) echo disabled; exit 1 ;;
    esac
    ;;
  disable) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$dr_bin/sudo" "$dr_bin/systemctl"

# Invalid backend options must stop before privilege checks or any changes.
kr_reject_dir="$dr_dir/keyring-validation"
mkdir -p "$kr_reject_dir/home/.config/lightxdm" "$kr_reject_dir/system"
printf '#!/bin/bash\nexec i3\n' >"$kr_reject_dir/home/.config/lightxdm/.xinitrc-custom-keyring"
printf '#%%PAM-1.0\n' >"$kr_reject_dir/system/login"
cp -a "$kr_reject_dir/home" "$kr_reject_dir/home-before"
cp -a "$kr_reject_dir/system" "$kr_reject_dir/system-before"
for kr_reject_case in plasma gnome xfce lxqt lxde mate cinnamon budgie i3 builtin-gnome builtin-list builtin-preview \
  conflict conflict-reversed no-id missing empty invalid init-template packages; do
  kr_reject_args=(--de custom-keyring --no-packages)
  case "$kr_reject_case" in
    plasma | gnome | xfce | lxqt | lxde | mate | cinnamon | budgie | i3)
      kr_reject_args=(--de "$kr_reject_case" --no-packages --keyring kwallet)
      kr_reject_message='--keyring is only for custom ids'
      ;;
    builtin-gnome | builtin-list | builtin-preview)
      kr_reject_args=(--de i3 --keyring gnome)
      case "$kr_reject_case" in
        builtin-list) kr_reject_args+=(--list-packages) ;;
        builtin-preview) kr_reject_args+=(--dry-run) ;;
      esac
      kr_reject_message='--keyring is only for custom ids'
      ;;
    conflict | conflict-reversed)
      if [[ "$kr_reject_case" == conflict ]]; then
        kr_reject_args+=(--keyring kwallet --no-keyring)
      else
        kr_reject_args+=(--no-keyring --keyring gnome)
      fi
      kr_reject_message='--keyring cannot be combined with --no-keyring'
      ;;
    no-id) kr_reject_args=(--no-packages --keyring kwallet); kr_reject_message='--keyring requires --de <custom-id>' ;;
    missing) kr_reject_args+=(--keyring); kr_reject_message='Missing argument for --keyring' ;;
    empty) kr_reject_args+=(--keyring ''); kr_reject_message='Invalid keyring backend:' ;;
    invalid) kr_reject_args+=(--keyring kde); kr_reject_message='Invalid keyring backend: kde' ;;
    init-template)
      kr_reject_args=(--init-template --de custom-keyring --keyring kwallet)
      kr_reject_message='--init-template takes only'
      ;;
    packages)
      kr_reject_args=(--de custom-keyring --keyring kwallet)
      kr_reject_message='Custom sessions need --no-packages'
      ;;
  esac
  : >"$STUB_LOG"
  set +e
  # shellcheck disable=SC2016  # source and override check_root inside the isolated child
  kr_reject_out="$(env -u SHELLOPTS -u SUDO_USER HOME="$kr_reject_dir/home" USER=testuser \
    PATH="$dr_bin:$STUB_BIN:$PATH" LOGIN_FILE="$kr_reject_dir/system/login" \
    DM_STATE_FILE="$kr_reject_dir/system/dm-state" \
    GNOME_SESSION_TYPE_DEST="$kr_reject_dir/system/gnome-session-type.conf" \
    DISPLAY_MANAGER_LINK="$kr_reject_dir/system/display-manager.service" \
    AUTOLOGIN_DROPIN_DIR="$kr_reject_dir/system/getty.d" \
    bash -c 'source "$1/install.sh"; shift; check_root() { echo check_root >>"$STUB_LOG"; return 91; }; main "$@"' \
    _ "$REPO_ROOT" "${kr_reject_args[@]}" 2>&1)"
  kr_reject_status=$?
  set -e
  if [[ $kr_reject_status -eq 1 && "$kr_reject_out" == *"$kr_reject_message"* && ! -s "$STUB_LOG" ]] &&
    diff -r "$kr_reject_dir/home-before" "$kr_reject_dir/home" >/dev/null &&
    diff -r "$kr_reject_dir/system-before" "$kr_reject_dir/system" >/dev/null; then
    pass "--keyring rejects $kr_reject_case before privilege checks or changes"
  else
    fail "--keyring validation ($kr_reject_case, status=$kr_reject_status, output=$kr_reject_out, log=$(cat "$STUB_LOG"))"
  fi
done

# --check-keyring reads only the user's existing collection, without service activation.
ck_dir="$TMP_DIR/check-keyring"
mkdir -p "$ck_dir/bin" "$ck_dir/home"
cat >"$ck_dir/bin/busctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KEYRING_CHECK_LOG"
case "$KEYRING_CHECK_RESULT" in
  unlocked) echo 'b false' ;;
  locked) echo 'b true' ;;
  unavailable) echo 'Unknown object' >&2; exit 1 ;;
  unexpected) echo 's unexpected' ;;
  empty) exit 0 ;;
esac
EOF
chmod +x "$ck_dir/bin/busctl"

if [[ $EUID -eq 0 ]]; then
  skip "--check-keyring session results (requires a non-root user)"
else
  for ck_backend in gnome kwallet; do
    ck_collection=login
    [[ "$ck_backend" != kwallet ]] || ck_collection=kdewallet
    for ck_result in unlocked locked unavailable unexpected empty; do
      case "$ck_result" in
        unlocked) ck_expected_status=0; ck_message="collection '$ck_collection' is unlocked." ;;
        locked) ck_expected_status=1; ck_message="collection '$ck_collection' is locked." ;;
        unavailable) ck_expected_status=2; ck_message="collection '$ck_collection' is unavailable: Unknown object" ;;
        unexpected) ck_expected_status=2; ck_message="collection '$ck_collection' is unavailable: s unexpected" ;;
        empty) ck_expected_status=2; ck_message="collection '$ck_collection' is unavailable: busctl returned no output" ;;
      esac
      : >"$ck_dir/busctl.log"
      : >"$STUB_LOG"
      set +e
      ck_output="$(env -u SHELLOPTS HOME="$ck_dir/home" PATH="$ck_dir/bin:$PATH" \
        KEYRING_CHECK_LOG="$ck_dir/busctl.log" KEYRING_CHECK_RESULT="$ck_result" \
        bash "$REPO_ROOT/install.sh" --check-keyring "$ck_backend" 2>&1)"
      ck_status=$?
      set -e
      ck_args="$(cat "$ck_dir/busctl.log")"
      if [[ $ck_status -eq $ck_expected_status && "$ck_output" == *"$ck_message"* &&
        "$ck_args" == "--user --auto-start=no get-property org.freedesktop.secrets /org/freedesktop/secrets/collection/$ck_collection org.freedesktop.Secret.Collection Locked" &&
        ! -s "$STUB_LOG" ]]; then
        pass "--check-keyring $ck_backend reports $ck_result without activation or sudo"
      else
        fail "--check-keyring $ck_backend $ck_result (status=$ck_status, output=$ck_output, args=$ck_args, log=$(cat "$STUB_LOG"))"
      fi
    done
  done
fi

for ck_reject in missing flag-argument empty invalid combined combined-reversed duplicate \
  --list-packages --dry-run --non-interactive --no-packages --keyring --no-keyring --no-polkit-rule --autologin \
  --init-template --wayland --from-session; do
  ck_reject_args=(--check-keyring gnome)
  ck_message='--check-keyring cannot be combined with any other option.'
  case "$ck_reject" in
    missing) ck_reject_args=(--check-keyring); ck_message='Missing argument for --check-keyring' ;;
    flag-argument) ck_reject_args=(--check-keyring --de xfce); ck_message='Missing argument for --check-keyring' ;;
    empty) ck_reject_args=(--check-keyring ''); ck_message='Invalid keyring backend:' ;;
    invalid) ck_reject_args=(--check-keyring kde); ck_message='Invalid keyring backend: kde' ;;
    combined) ck_reject_args+=(--de xfce) ;;
    combined-reversed) ck_reject_args=(--de xfce --check-keyring kwallet) ;;
    duplicate) ck_reject_args+=(--check-keyring kwallet) ;;
    --keyring) ck_reject_args+=(--keyring kwallet) ;;
    --from-session) ck_reject_args+=(--from-session /usr/share/xsessions/custom.desktop) ;;
    *) ck_reject_args+=("$ck_reject") ;;
  esac
  : >"$ck_dir/busctl.log"
  : >"$STUB_LOG"
  set +e
  ck_output="$(env -u SHELLOPTS HOME="$ck_dir/home" PATH="$ck_dir/bin:$PATH" \
    KEYRING_CHECK_LOG="$ck_dir/busctl.log" KEYRING_CHECK_RESULT=unlocked \
    bash "$REPO_ROOT/install.sh" "${ck_reject_args[@]}" 2>&1)"
  ck_status=$?
  set -e
  if [[ $ck_status -eq 1 && "$ck_output" == *"$ck_message"* && ! -s "$ck_dir/busctl.log" && ! -s "$STUB_LOG" ]]; then
    pass "--check-keyring rejects $ck_reject before busctl or sudo"
  else
    fail "--check-keyring rejection $ck_reject (status=$ck_status, output=$ck_output)"
  fi
done

# --help wins wherever it appears, as with every other option, and runs no check.
for ck_help_order in "--check-keyring gnome --help" "--help --check-keyring gnome"; do
  read -r -a ck_help_args <<<"$ck_help_order"
  : >"$ck_dir/busctl.log"
  set +e
  ck_output="$(env -u SHELLOPTS HOME="$ck_dir/home" PATH="$ck_dir/bin:$PATH" \
    KEYRING_CHECK_LOG="$ck_dir/busctl.log" KEYRING_CHECK_RESULT=unlocked \
    bash "$REPO_ROOT/install.sh" "${ck_help_args[@]}" 2>&1)"
  ck_status=$?
  set -e
  if [[ $ck_status -eq 0 && "$ck_output" == *"--check-keyring <gnome|kwallet> report"* && ! -s "$ck_dir/busctl.log" ]]; then
    pass "--help with --check-keyring ($ck_help_order) prints usage without running the check"
  else
    fail "--help with --check-keyring ($ck_help_order) (status=$ck_status, output=$ck_output)"
  fi
done

ck_root_runner=()
if [[ $EUID -ne 0 ]]; then
  ck_root_runner=(unshare -r)
fi
if [[ $EUID -ne 0 && $can_unshare -eq 0 ]]; then
  skip "--check-keyring refuses root (unshare -r unavailable)"
else
  : >"$ck_dir/busctl.log"
  : >"$STUB_LOG"
  set +e
  ck_output="$(env -u SHELLOPTS HOME="$ck_dir/home" PATH="$ck_dir/bin:$PATH" \
    KEYRING_CHECK_LOG="$ck_dir/busctl.log" KEYRING_CHECK_RESULT=unlocked \
    "${ck_root_runner[@]}" bash "$REPO_ROOT/install.sh" --check-keyring gnome 2>&1)"
  ck_status=$?
  set -e
  if [[ $ck_status -eq 1 && "$ck_output" == *'Do not run --check-keyring as root'* &&
    ! -s "$ck_dir/busctl.log" && ! -s "$STUB_LOG" ]]; then
    pass "--check-keyring refuses root before busctl or sudo"
  else
    fail "--check-keyring root refusal (status=$ck_status, output=$ck_output)"
  fi
fi

for dr_de in xfce plasma gnome custom-x11 custom-wayland custom-gnome custom-kwallet-x11 custom-kwallet-wayland; do
  dr_case="$dr_dir/$dr_de"
  dr_preview_home="$dr_case/preview-home"
  dr_real_home="$dr_case/real-home"
  dr_flags=()
  dr_template=".xinitrc-$dr_de"
  case "$dr_de" in
    plasma | gnome) dr_template=".wayland-session-$dr_de" ;;
    custom-x11) dr_flags=(--no-packages) ;;
    custom-wayland) dr_flags=(--no-packages); dr_template=".wayland-session-$dr_de" ;;
    custom-gnome) dr_flags=(--no-packages --keyring gnome) ;;
    custom-kwallet-x11) dr_flags=(--no-packages --keyring kwallet) ;;
    custom-kwallet-wayland) dr_flags=(--no-packages --keyring kwallet); dr_template=".wayland-session-$dr_de" ;;
  esac
  for dr_home in "$dr_preview_home" "$dr_real_home"; do
    mkdir -p "$dr_home/.config/lightxdm"
    printf 'keep this file\n' >"$dr_home/keep"
    case "$dr_de" in
      custom-*) printf '#!/bin/bash\nexec i3\n' >"$dr_home/.config/lightxdm/$dr_template" ;;
      *) cp "$REPO_ROOT/dotfiles/$dr_template" "$dr_home/.config/lightxdm/$dr_template" ;;
    esac
  done
  mkdir -p "$dr_case/preview-system" "$dr_case/real-system"
  for dr_system in "$dr_case/preview-system" "$dr_case/real-system"; do
    printf '#%%PAM-1.0\nauth include system-local-login\nsession include system-local-login\n' >"$dr_system/login"
    printf 'previous.service\n' >"$dr_system/dm-state"
  done
  cp -a "$dr_preview_home" "$dr_case/home-before"
  cp -a "$dr_case/preview-system" "$dr_case/system-before"
  dr_home_tree="$(find "$dr_preview_home" -printf '%P %y %m %l\n' | sort)"
  find "$dr_real_home" -type f -printf '%P\n' | sort >"$dr_case/files-before"

  : >"$STUB_LOG"
  set +e
  dr_out="$(env -u SHELLOPTS -u SUDO_USER HOME="$dr_preview_home" USER=testuser \
    PATH="$dr_bin:$PATH" LOGIN_FILE="$dr_case/preview-system/login" \
    DM_STATE_FILE="$dr_case/preview-system/dm-state" \
    GNOME_SESSION_TYPE_DEST="$dr_case/preview-system/gnome-session-type.conf" \
    DISPLAY_MANAGER_LINK="$dr_case/preview-system/display-manager.service" \
    AUTOLOGIN_DROPIN_DIR="$dr_case/preview-system/getty.d" OVERRIDE_DIR="$dr_case/preview-system/getty.d" \
    bash "$REPO_ROOT/install.sh" --dry-run --de "$dr_de" "${dr_flags[@]}" 2>"$dr_case/preview.err")"
  dr_status=$?
  set -e
  if [[ $dr_status -eq 0 && ! -s "$dr_case/preview.err" &&
    "$dr_home_tree" == "$(find "$dr_preview_home" -printf '%P %y %m %l\n' | sort)" ]] &&
    diff -r "$dr_case/home-before" "$dr_preview_home" >/dev/null &&
    diff -r "$dr_case/system-before" "$dr_case/preview-system" >/dev/null &&
    ! grep -Eq '^(sudo |pacman |systemctl (disable|enable|daemon-reload))' "$STUB_LOG"; then
    pass "--dry-run --de $dr_de leaves HOME, PAM and display-manager state untouched without sudo"
  else
    fail "--dry-run --de $dr_de changed inputs or failed (status=$dr_status, out=$dr_out, err=$(cat "$dr_case/preview.err"), log=$(cat "$STUB_LOG"))"
  fi

  # Use the real configuration helpers with command stubs and a separate home/system.
  # shellcheck disable=SC2016  # source and override check_root inside the isolated child
  if env -u SHELLOPTS -u SUDO_USER HOME="$dr_real_home" USER=testuser \
    PATH="$dr_bin:$STUB_BIN:$PATH" LOGIN_FILE="$dr_case/real-system/login" \
    DM_STATE_FILE="$dr_case/real-system/dm-state" \
    GNOME_SESSION_TYPE_DEST="$dr_case/real-system/gnome-session-type.conf" \
    DISPLAY_MANAGER_LINK="$dr_case/real-system/display-manager.service" \
    AUTOLOGIN_DROPIN_DIR="$dr_case/real-system/getty.d" OVERRIDE_DIR="$dr_case/real-system/getty.d" \
    bash -c 'source "$1/install.sh"; shift; check_root() { :; }; main "$@"' \
    _ "$REPO_ROOT" --de "$dr_de" "${dr_flags[@]}" >"$dr_case/install.out" 2>&1; then
    dr_destinations=()
    while IFS= read -r dr_line; do
      case "$dr_line" in
        "Dotfile: $dr_preview_home/"*) dr_destinations+=("${dr_line#"Dotfile: $dr_preview_home/"}") ;;
        "Install choices: $dr_preview_home/"*) dr_destinations+=("${dr_line#"Install choices: $dr_preview_home/"}") ;;
      esac
    done <<<"$dr_out"
    printf '%s\n' "${dr_destinations[@]}" | sort >"$dr_case/preview-files"
    # Preservation markers accompany the dotfiles; they are not dotfile destinations.
    find "$dr_real_home" -type f ! -name '*.lightxdm.absent' -printf '%P\n' | sort >"$dr_case/files-after"
    comm -13 "$dr_case/files-before" "$dr_case/files-after" >"$dr_case/created-files"
    dr_packages="$(sed -n '/^Packages:$/,/^PAM keyring:/{ /^Packages:$/d; /^PAM keyring:/d; p; }' <<<"$dr_out")"
    if cmp -s "$dr_case/preview-files" "$dr_case/created-files" &&
      [[ "$dr_out" == *"Desktop: $dr_de"* && "$dr_out" == *"Template: $dr_preview_home/.config/lightxdm/$dr_template"* &&
      "$dr_out" == *'TTY1 autologin: unchanged'* ]] &&
      { [[ ${#dr_flags[@]} -gt 0 && "$dr_out" == *'Packages: skipped (--no-packages)'* ]] ||
        [[ "$dr_packages" == "$(list_packages "$dr_de")" ]]; }; then
      pass "--dry-run --de $dr_de lists exactly the real install's dotfile destinations and packages"
    else
      fail "--dry-run destinations/packages differ from the real $dr_de install (preview=$dr_out, created=$(cat "$dr_case/created-files"))"
    fi
    dr_units="$(sed -n 's/^Display manager: //p' <<<"$dr_out")"
    if [[ "$dr_units" == $'sddm.service\nlxdm.service' &&
      "$(cat "$dr_case/real-system/dm-state")" == $'previous.service\nsddm.service\nlxdm.service' ]] &&
      grep -Fxq -- "$(sed -n '/^auth.*optional/p' <<<"$dr_out")" "$dr_case/real-system/login" &&
      grep -Fxq -- "$(sed -n '/^session.*optional.*pam_\(kwallet5\|gnome_keyring\)/p' <<<"$dr_out")" "$dr_case/real-system/login"; then
      pass "--dry-run --de $dr_de agrees with real PAM additions and enabled display managers"
    else
      fail "--dry-run --de $dr_de PAM/display-manager preview (out=$dr_out)"
    fi
    case "$dr_de" in
      custom-*)
        dr_expected_auth="$PAM_GNOME_KEYRING_AUTH"
        dr_expected_session="$PAM_GNOME_KEYRING_SESSION"
        dr_other_module=pam_kwallet5.so
        if [[ "$dr_de" == custom-kwallet-* ]]; then
          dr_expected_auth="$PAM_KWALLET_AUTH"
          dr_expected_session="$PAM_KWALLET_SESSION"
          dr_other_module=pam_gnome_keyring.so
        fi
        if grep -Fxq -- "$dr_expected_auth" <<<"$dr_out" &&
          grep -Fxq -- "$dr_expected_session" <<<"$dr_out" &&
          grep -Fxq -- "$dr_expected_auth" "$dr_case/real-system/login" &&
          grep -Fxq -- "$dr_expected_session" "$dr_case/real-system/login" &&
          ! grep -Fq -- "$dr_other_module" <<<"$dr_out" &&
          ! grep -Fq -- "$dr_other_module" "$dr_case/real-system/login"; then
          pass "$dr_de preview and installation use the expected keyring backend"
        else
          fail "$dr_de keyring backend (preview=$dr_out, login=$(cat "$dr_case/real-system/login"))"
        fi
        ;;
    esac
    if [[ "$dr_de" == gnome ]] &&
      ! grep -Fxq 'session    [success=1 default=ignore] pam_succeed_if.so quiet user != testuser' <<<"$dr_out"; then
      fail "GNOME dry-run omits the resolved session-type block"
    fi
  else
    fail "real stubbed install for dry-run comparison ($dr_de): $(cat "$dr_case/install.out")"
  fi
done


# Preview the exact GNOME rules a KWallet install removes, including the legacy auth rule.
for dr_remove_de in plasma custom-kwallet; do
  dr_remove_dir="$dr_dir/removals-$dr_remove_de"
  mkdir -p "$dr_remove_dir/home/.config/lightxdm" "$dr_remove_dir/system"
  dr_remove_flags=()
  if [[ "$dr_remove_de" == plasma ]]; then
    cp "$REPO_ROOT/dotfiles/.wayland-session-plasma" "$dr_remove_dir/home/.config/lightxdm/"
  else
    printf '#!/bin/bash\nexec i3\n' >"$dr_remove_dir/home/.config/lightxdm/.xinitrc-$dr_remove_de"
    dr_remove_flags=(--no-packages --keyring kwallet)
  fi
  printf '#%%PAM-1.0\n' >"$dr_remove_dir/system/login.lightxdm.bak"
  {
    cat "$dr_remove_dir/system/login.lightxdm.bak"
    printf '%s\n' "$PAM_GNOME_KEYRING_AUTH" "$PAM_GNOME_KEYRING_SESSION" \
      'auth       optional   pam_gnome_keyring.so auto_start'
  } >"$dr_remove_dir/system/login"
  cp "$dr_remove_dir/system/login" "$dr_remove_dir/login-before"
  : >"$STUB_LOG"
  dr_remove_out="$(env -u SHELLOPTS -u SUDO_USER HOME="$dr_remove_dir/home" USER=testuser \
    PATH="$dr_bin:$STUB_BIN:$PATH" LOGIN_FILE="$dr_remove_dir/system/login" \
    DM_STATE_FILE="$dr_remove_dir/system/dm-state" AUTOLOGIN_DROPIN_DIR="$dr_remove_dir/system/getty.d" \
    DISPLAY_MANAGER_LINK="$dr_remove_dir/system/display-manager.service" \
    bash "$REPO_ROOT/install.sh" --dry-run --de "$dr_remove_de" "${dr_remove_flags[@]}")"
  # shellcheck disable=SC2016  # expand inside the child shell
  if cmp -s "$dr_remove_dir/login-before" "$dr_remove_dir/system/login" &&
    ! grep -q '^sudo ' "$STUB_LOG" &&
    env -u SHELLOPTS -u SUDO_USER HOME="$dr_remove_dir/home" USER=testuser \
      PATH="$dr_bin:$STUB_BIN:$PATH" LOGIN_FILE="$dr_remove_dir/system/login" \
      DM_STATE_FILE="$dr_remove_dir/system/dm-state" AUTOLOGIN_DROPIN_DIR="$dr_remove_dir/system/getty.d" \
      DISPLAY_MANAGER_LINK="$dr_remove_dir/system/display-manager.service" \
      bash -c 'source "$1/install.sh"; shift; check_root() { :; }; main "$@"' \
      _ "$REPO_ROOT" --de "$dr_remove_de" "${dr_remove_flags[@]}" >"$dr_remove_dir/install.out" 2>&1; then
    sed -n 's/^  remove: //p' <<<"$dr_remove_out" | sort >"$dr_remove_dir/preview-removals"
    comm -23 <(sort "$dr_remove_dir/login-before") <(sort "$dr_remove_dir/system/login") >"$dr_remove_dir/actual-removals"
    if [[ $(wc -l <"$dr_remove_dir/actual-removals") -eq 3 ]] &&
      cmp -s "$dr_remove_dir/preview-removals" "$dr_remove_dir/actual-removals" &&
      grep -Fxq -- "$PAM_KWALLET_AUTH" <<<"$dr_remove_out" &&
      grep -Fxq -- "$PAM_KWALLET_SESSION" <<<"$dr_remove_out" &&
      grep -Fxq -- "$PAM_KWALLET_AUTH" "$dr_remove_dir/system/login" &&
      grep -Fxq -- "$PAM_KWALLET_SESSION" "$dr_remove_dir/system/login" &&
      ! grep -q pam_gnome_keyring "$dr_remove_dir/system/login"; then
      pass "$dr_remove_de dry-run lists the GNOME keyring rules removed by the KWallet installation"
    else
      fail "$dr_remove_de dry-run PAM removals or KWallet setup differ from installation (preview=$dr_remove_out)"
    fi
  else
    fail "$dr_remove_de PAM removal preview changed the login file or installation failed"
  fi
done


# A legacy backup must produce the same removal preview without being adopted yet.
dr_legacy_dir="$dr_dir/legacy-removals"
mkdir -p "$dr_legacy_dir/home/.config/lightxdm" "$dr_legacy_dir/system"
printf '#%%PAM-1.0\n' >"$dr_legacy_dir/system/login.lightxde.bak.1751000000"
{
  cat "$dr_legacy_dir/system/login.lightxde.bak.1751000000"
  printf '%s\n' "$PAM_KWALLET_AUTH" "$PAM_KWALLET_SESSION"
} >"$dr_legacy_dir/system/login"
cp "$dr_legacy_dir/system/login" "$dr_legacy_dir/login-before"
: >"$STUB_LOG"
dr_legacy_out="$(env -u SHELLOPTS -u SUDO_USER HOME="$dr_legacy_dir/home" USER=testuser \
  PATH="$dr_bin:$STUB_BIN:$PATH" LOGIN_FILE="$dr_legacy_dir/system/login" \
  DM_STATE_FILE="$dr_legacy_dir/system/dm-state" AUTOLOGIN_DROPIN_DIR="$dr_legacy_dir/system/getty.d" \
  DISPLAY_MANAGER_LINK="$dr_legacy_dir/system/display-manager.service" \
  bash "$REPO_ROOT/install.sh" --dry-run --de xfce)"
# shellcheck disable=SC2016  # expand inside the child shell
if cmp -s "$dr_legacy_dir/login-before" "$dr_legacy_dir/system/login" &&
  [[ -f "$dr_legacy_dir/system/login.lightxde.bak.1751000000" && ! -e "$dr_legacy_dir/system/login.lightxdm.bak" ]] &&
  ! grep -q '^sudo ' "$STUB_LOG" &&
  env -u SHELLOPTS -u SUDO_USER HOME="$dr_legacy_dir/home" USER=testuser \
    PATH="$dr_bin:$STUB_BIN:$PATH" LOGIN_FILE="$dr_legacy_dir/system/login" \
    DM_STATE_FILE="$dr_legacy_dir/system/dm-state" AUTOLOGIN_DROPIN_DIR="$dr_legacy_dir/system/getty.d" \
    DISPLAY_MANAGER_LINK="$dr_legacy_dir/system/display-manager.service" \
    bash -c 'source "$1/install.sh"; shift; check_root() { :; }; main "$@"' \
    _ "$REPO_ROOT" --de xfce >"$dr_legacy_dir/install.out" 2>&1; then
  sed -n 's/^  remove: //p' <<<"$dr_legacy_out" | sort >"$dr_legacy_dir/preview-removals"
  comm -23 <(sort "$dr_legacy_dir/login-before") <(sort "$dr_legacy_dir/system/login") >"$dr_legacy_dir/actual-removals"
  if [[ $(wc -l <"$dr_legacy_dir/actual-removals") -eq 2 ]] &&
    cmp -s "$dr_legacy_dir/preview-removals" "$dr_legacy_dir/actual-removals" &&
    [[ -f "$dr_legacy_dir/system/login.lightxdm.bak" && ! -e "$dr_legacy_dir/system/login.lightxde.bak.1751000000" ]]; then
    pass "Xfce dry-run lists KWallet rules removed using a legacy backup"
  else
    fail "Xfce legacy backup PAM removals differ from installation (preview=$dr_legacy_out)"
  fi
else
  fail "Xfce legacy backup preview changed files or used sudo, or installation failed"
fi

: >"$STUB_LOG"
set +e
dr_missing_out="$(run_main_with_stubs "$dr_bin" --dry-run 2>&1)"
dr_missing_status=$?
dr_conflict_out="$(run_main_with_stubs "$dr_bin" --dry-run --init-template --de xfce 2>&1)"
dr_conflict_status=$?
set -e
if [[ $dr_missing_status -eq 1 && "$dr_missing_out" == *'--dry-run requires --de'* &&
  $dr_conflict_status -eq 1 && "$dr_conflict_out" == *'--init-template takes only'* && ! -s "$STUB_LOG" ]]; then
  pass "--dry-run requires --de and refuses template creation before checks or writes"
else
  fail "--dry-run argument validation ($dr_missing_status:$dr_missing_out | $dr_conflict_status:$dr_conflict_out)"
fi

: >"$STUB_LOG"
set +e
dr_skip_out="$(env HOME="$dr_preview_home" USER=testuser PATH="$dr_bin:$PATH" \
  LOGIN_FILE="$dr_case/preview-system/login" DM_STATE_FILE="$dr_case/preview-system/dm-state" \
  DISPLAY_MANAGER_LINK="$dr_case/preview-system/display-manager.service" \
  GNOME_SESSION_TYPE_DEST="$dr_case/preview-system/gnome-session-type.conf" \
  bash "$REPO_ROOT/install.sh" --dry-run --de gnome --no-packages --no-keyring --autologin 2>&1)"
dr_skip_status=$?
set -e
if [[ $dr_skip_status -eq 0 && "$dr_skip_out" == *'Packages: skipped (--no-packages)'* &&
  "$dr_skip_out" == *'PAM keyring: skipped (--no-keyring)'* &&
  "$dr_skip_out" == *'pam_env.so readenv=0 user_readenv=0'* &&
  "$dr_skip_out" == *'TTY1 autologin: enable for testuser'* &&
  "$dr_skip_out" != *pam_gnome_keyring.so* ]] &&
  ! grep -Eq '^(sudo |pacman |systemctl (disable|enable|daemon-reload))' "$STUB_LOG" &&
  diff -r "$dr_case/home-before" "$dr_preview_home" >/dev/null &&
  diff -r "$dr_case/system-before" "$dr_case/preview-system" >/dev/null; then
  pass "GNOME dry-run respects skip flags and autologin while retaining its session-type block"
else
  fail "GNOME dry-run skip/autologin flags (status=$dr_skip_status, output=$dr_skip_out)"
fi

if [[ $EUID -ne 0 ]]; then
  chmod 000 "$dr_case/preview-system/login" "$dr_case/preview-system/dm-state"
  : >"$STUB_LOG"
  set +e
  dr_private_out="$(env HOME="$dr_preview_home" USER=testuser PATH="$dr_bin:$PATH" \
    LOGIN_FILE="$dr_case/preview-system/login" DM_STATE_FILE="$dr_case/preview-system/dm-state" \
    DISPLAY_MANAGER_LINK="$dr_case/preview-system/display-manager.service" \
    GNOME_SESSION_TYPE_DEST="$dr_case/preview-system/gnome-session-type.conf" \
    bash "$REPO_ROOT/install.sh" --dry-run --de xfce 2>&1)"
  dr_private_status=$?
  set -e
  chmod 644 "$dr_case/preview-system/login" "$dr_case/preview-system/dm-state"
  if [[ $dr_private_status -eq 0 && "$dr_private_out" == *'unknown (needs root)'* &&
    "$dr_private_out" == *'existing records: unknown (needs root)'* &&
    "$dr_private_out" != *pam_gnome_keyring.so* ]] &&
    ! grep -Eq '^(sudo |pacman |systemctl (disable|enable|daemon-reload))' "$STUB_LOG" &&
    diff -r "$dr_case/system-before" "$dr_case/preview-system" >/dev/null; then
    pass "--dry-run reports unreadable PAM and display-manager records as unknown without sudo"
  else
    fail "--dry-run with unreadable inputs (status=$dr_private_status, output=$dr_private_out)"
  fi
fi

# Case 74: multi-desktop detection lists all matches and offers Wayland and X11 desktops together
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
output="$(STUB_DETECTED_DE=$'gnome\nxfce' STUB_REAL_PROMPT=1 run_main_with_stubs "$sudo_pw_dir" <<<"2" 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
expected_px_log=$'sudo -v\ndetect_de\ninstall_packages xfce\ncopy_dotfiles xfce\nconfigure_pam xfce\ndisable_display_managers'
if [[ $status -eq 0 && "$log_content" == "$expected_px_log" &&
  "$output" == *"1) GNOME"* && "$output" == *"2) XFCE"* && "$output" == *"3) Quit"* &&
  "$output" != *"Wayland-only"* &&
  "$output" == *"lightXDM install complete!"* && "$output" == *"- xfce "* ]]; then
  pass "main offers GNOME and XFCE and configures the selected XFCE"
else
  fail "main gnome+xfce (status=$status, log=$log_content, output=$output)"
fi

: >"$STUB_LOG"
set +e
output="$(STUB_DETECTED_DE=$'gnome\nbudgie\nlxqt' STUB_REAL_PROMPT=1 run_main_with_stubs "$sudo_pw_dir" <<<"3" 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
wayland_line_count="$(grep -Fc 'Wayland-only' <<<"$output" || true)"
expected_pgl_log=$'sudo -v\ndetect_de\ninstall_packages lxqt\ncopy_dotfiles lxqt\nconfigure_pam lxqt\ndisable_display_managers'
if [[ $status -eq 0 && "$log_content" == "$expected_pgl_log" &&
  "$wayland_line_count" -eq 0 &&
  "$output" == *"1) GNOME"* && "$output" == *"2) Budgie"* &&
  "$output" == *"3) LXQt"* && "$output" == *"4) Quit"* &&
  "$output" == *"lightXDM install complete!"* ]]; then
  pass "main offers GNOME, Budgie and LXQt and configures the selected LXQt"
else
  fail "main gnome+budgie+lxqt (status=$status, count=$wayland_line_count, log=$log_content, output=$output)"
fi

for all_wl_detected in $'gnome\nbudgie' $'budgie\ngnome'; do
  first_wl="${all_wl_detected%%$'\n'*}"
  : >"$STUB_LOG"
  set +e
  output="$(STUB_DETECTED_DE="$all_wl_detected" STUB_REAL_PROMPT=1 run_main_with_stubs "$sudo_pw_dir" <<<"1" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  expected_wl_log=$'sudo -v\ndetect_de\ninstall_packages '"$first_wl"$'\ncopy_dotfiles '"$first_wl"$'\nconfigure_pam '"$first_wl"$'\ndisable_display_managers'
  if [[ $status -eq 0 && "$log_content" == "$expected_wl_log" &&
    "$output" == *"$(de_label "$first_wl")"* && "$output" == *"GNOME"* && "$output" == *"Budgie"* &&
    "$output" == *"3) Quit"* && "$output" == *"lightXDM install complete!"* && "$output" != *"startx"* ]]; then
    pass "main offers both Wayland desktops and configures the selection (${all_wl_detected//$'\n'/+})"
  else
    fail "main all-Wayland multi-detect (${all_wl_detected//$'\n'/+}, status=$status, log=$log_content, output=$output)"
  fi
done

for multi_choice_detected in $'xfce\ni3' $'gnome\nxfce\ni3'; do
  multi_choice=2
  if [[ "$multi_choice_detected" == gnome* ]]; then
    multi_choice=3
  fi
  : >"$STUB_LOG"
  set +e
  output="$(STUB_DETECTED_DE="$multi_choice_detected" STUB_REAL_PROMPT=1 run_main_with_stubs "$sudo_pw_dir" <<<"$multi_choice" 2>&1)"
  status=$?
  set -e
  log_content="$(cat "$STUB_LOG")"
  expected_i3_log=$'sudo -v\ndetect_de\ninstall_packages i3\ncopy_dotfiles i3\nconfigure_pam i3\ndisable_display_managers'
  menu_ok=0
  if [[ "$multi_choice_detected" == gnome* && "$output" == *"1) GNOME"* &&
    "$output" == *"2) XFCE"* && "$output" == *"3) i3"* && "$output" == *"4) Quit"* ]] ||
    [[ "$multi_choice_detected" != gnome* && "$output" == *"1) XFCE"* &&
      "$output" == *"2) i3"* && "$output" == *"3) Quit"* ]]; then
    menu_ok=1
  fi
  if [[ $status -eq 0 && $menu_ok -eq 1 && "$log_content" == "$expected_i3_log" &&
    "$output" != *"Wayland-only"* &&
    "$output" == *"lightXDM install complete!"* && "$output" == *"- i3 "* ]]; then
    pass "main configures i3 when selected from detected chooser (${multi_choice_detected//$'\n'/+})"
  else
    fail "main multi-detect select i3 (${multi_choice_detected//$'\n'/+}, status=$status, log=$log_content, output=$output)"
  fi
done

# plasma is a supported candidate in detection alongside X11 desktops and when paired with gnome
: >"$STUB_LOG"
set +e
output="$(STUB_DETECTED_DE=$'plasma\ngnome' STUB_REAL_PROMPT=1 run_main_with_stubs "$sudo_pw_dir" <<<"1" 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
expected_pg_log=$'sudo -v\ndetect_de\ninstall_packages plasma\ncopy_dotfiles plasma\nconfigure_pam plasma\ndisable_display_managers'
if [[ $status -eq 0 && "$log_content" == "$expected_pg_log" &&
  "$output" == *"1) KDE Plasma"* && "$output" == *"2) GNOME"* && "$output" == *"3) Quit"* &&
  "$output" != *"Wayland-only"* &&
  "$output" == *"lightXDM install complete!"* && "$output" == *"- plasma "* &&
  "$output" != *"No need to run 'startx'."* ]]; then
  pass "main offers KDE Plasma and GNOME and configures the selected Plasma"
else
  fail "main plasma+gnome (status=$status, log=$log_content, output=$output)"
fi

: >"$STUB_LOG"
set +e
output="$(STUB_DETECTED_DE=$'plasma\nxfce' STUB_REAL_PROMPT=1 run_main_with_stubs "$sudo_pw_dir" <<<"1" 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 0 && "$log_content" == "$expected_pg_log" &&
  "$output" != *"Wayland-only"* &&
  "$output" == *"1) KDE Plasma"* && "$output" == *"2) XFCE"* && "$output" == *"3) Quit"* &&
  "$output" == *"- plasma "* ]]; then
  pass "main offers KDE Plasma as a normal candidate in multi-desktop detection"
else
  fail "main plasma+xfce chooser (status=$status, log=$log_content, output=$output)"
fi

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
out_plasma_init="$(HOME="$init_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template --de plasma 2>&1)"
status_plasma_init=$?
out_plasma_again="$(HOME="$init_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template --de plasma 2>&1)"
status_plasma_again=$?
out_custom="$(HOME="$init_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template --de dwm 2>&1)"
status_custom=$?
out_badid="$(HOME="$init_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template --de Dwm 2>&1)"
status_badid=$?
out_asroot=""
status_asroot=1
if [[ $can_unshare -eq 1 ]]; then
  out_asroot="$(HOME="$init_home" PATH="$sudo_pw_dir:$PATH" unshare -r bash "$REPO_ROOT/install.sh" --init-template --de openbox 2>&1)"
  status_asroot=$?
fi
out_no_de="$(HOME="$init_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template 2>&1)"
status_no_de=$?
set -e
init_xfce="$init_home/.config/lightxdm/.xinitrc-xfce"
init_plasma="$init_home/.config/lightxdm/.wayland-session-plasma"
init_dwm="$init_home/.config/lightxdm/.xinitrc-dwm"
if [[ $status_builtin -eq 0 && "$out_builtin" == *"Created $init_xfce"* ]] && cmp -s "$init_xfce" "$REPO_ROOT/dotfiles/.xinitrc-xfce" &&
  [[ "$(stat -c '%a' "$init_xfce")" == 755 && $status_again -eq 1 && "$out_again" == *"already exists"* ]]; then
  pass "install.sh --init-template copies a built-in template once and refuses to overwrite it"
else
  fail "install.sh --init-template built-in (status=$status_builtin/$status_again, output=$out_builtin / $out_again)"
fi
# A printed command names the script by its shell-escaped absolute path, so it runs from any directory.
spaced_root="$TMP_DIR/dir with space/lightxdm"
spaced_home="$TMP_DIR/spaced_home"
mkdir -p "$spaced_root" "$spaced_home"
cp -- "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh" "$REPO_ROOT/enable-autologin.sh" "$spaced_root/"
cp -r -- "$REPO_ROOT/dotfiles" "$REPO_ROOT/pam" "$spaced_root/"
set +e
spaced_out="$(cd / && HOME="$spaced_home" PATH="$sudo_pw_dir:$PATH" bash "$spaced_root/install.sh" --init-template --de plasma 2>&1)"
spaced_cmd="${spaced_out##*then run: }"
spaced_cmd="${spaced_cmd%% --de plasma*}"
spaced_help="$(cd / && eval "$spaced_cmd --help" 2>&1)"
spaced_status=$?
set -e
if [[ "$spaced_cmd" == 'bash '*'/dir\ with\ space/lightxdm/install.sh' && $spaced_status -eq 0 && "$spaced_help" == *"Usage:"* ]]; then
  pass "a printed command names the script by its shell-escaped absolute path and runs from another directory"
else
  fail "printed command from a path with a space (cmd=$spaced_cmd, status=$spaced_status)"
fi
rm -rf "$TMP_DIR/dir with space" "$spaced_home"
resolved_plasma_override="$(HOME="$init_home" xinitrc_template plasma)"
resolved_plasma_bundled="$(HOME="$TMP_DIR/empty_plasma_home" xinitrc_template plasma)"
if [[ $status_plasma_init -eq 0 && "$out_plasma_init" == *"Created $init_plasma"* &&
  "$out_plasma_init" == *"$CMD_INSTALL --de plasma"* ]] &&
  cmp -s "$init_plasma" "$REPO_ROOT/dotfiles/.wayland-session-plasma" &&
  [[ "$(stat -c '%a' "$init_plasma")" == 755 && ! -e "$init_home/.config/lightxdm/.xinitrc-plasma" &&
    $status_plasma_again -eq 1 && "$out_plasma_again" == *"already exists"* &&
    "$resolved_plasma_override" == "$init_plasma" &&
    "$resolved_plasma_bundled" == "$REPO_ROOT/dotfiles/.wayland-session-plasma" ]]; then
  pass "install.sh --init-template --de plasma creates ~/.config/lightxdm/.wayland-session-plasma (755), refuses overwrite, and xinitrc_template prefers it"
else
  fail "install.sh --init-template --de plasma (status=$status_plasma_init/$status_plasma_again, resolved=$resolved_plasma_override/$resolved_plasma_bundled, output=$out_plasma_init / $out_plasma_again)"
fi
if [[ $status_custom -eq 0 && "$(stat -c '%a' "$init_dwm" 2>/dev/null)" == 755 ]] && bash -n "$init_dwm" &&
  grep -qx 'exec dwm' "$init_dwm" && grep -qx 'export DESKTOP_SESSION=dwm' "$init_dwm" &&
  grep -qx 'export XDG_CURRENT_DESKTOP=dwm' "$init_dwm" && ! grep -q 'i3' "$init_dwm" &&
  [[ "$out_custom" == *"--no-packages --de dwm"* ]]; then
  pass "install.sh --init-template renders a custom window manager template from the i3 one"
else
  fail "install.sh --init-template custom (status=$status_custom, output=$out_custom, content=$(cat "$init_dwm" 2>/dev/null))"
fi
if [[ $status_no_de -eq 1 && "$out_no_de" == *"--init-template requires --de"* && ! -s "$STUB_LOG" ]]; then
  pass "install.sh --init-template requires --de and never calls sudo"
else
  fail "install.sh --init-template missing id (status=$status_no_de, log=$(cat "$STUB_LOG"), output=$out_no_de)"
fi
for init_wl_de in gnome budgie; do
  set +e
  out_wl_init="$(HOME="$init_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template --de "$init_wl_de" 2>&1)"
  status_wl_init=$?
  out_wl_again="$(HOME="$init_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template --de "$init_wl_de" 2>&1)"
  status_wl_again=$?
  set -e
  init_wl="$init_home/.config/lightxdm/.wayland-session-$init_wl_de"
  resolved_wl_override="$(HOME="$init_home" xinitrc_template "$init_wl_de")"
  resolved_wl_bundled="$(HOME="$TMP_DIR/empty_wayland_home" xinitrc_template "$init_wl_de")"
  if [[ $status_wl_init -eq 0 && "$out_wl_init" == *"Created $init_wl"* &&
    "$out_wl_init" == *"$CMD_INSTALL --de $init_wl_de"* ]] &&
    cmp -s "$init_wl" "$REPO_ROOT/dotfiles/.wayland-session-$init_wl_de" &&
    [[ "$(stat -c '%a' "$init_wl")" == 755 && ! -e "$init_home/.config/lightxdm/.xinitrc-$init_wl_de" &&
      $status_wl_again -eq 1 && "$out_wl_again" == *"already exists"* &&
      "$resolved_wl_override" == "$init_wl" &&
      "$resolved_wl_bundled" == "$REPO_ROOT/dotfiles/.wayland-session-$init_wl_de" && ! -s "$STUB_LOG" ]]; then
    pass "install.sh --init-template --de $init_wl_de creates a Wayland template (755), refuses overwrite, and xinitrc_template prefers it"
  else
    fail "install.sh --init-template --de $init_wl_de (status=$status_wl_init/$status_wl_again, resolved=$resolved_wl_override/$resolved_wl_bundled, output=$out_wl_init / $out_wl_again)"
  fi
done
if [[ $status_badid -eq 1 && "$out_badid" == *"Invalid desktop id: Dwm"* && ! -e "$init_home/.config/lightxdm/.xinitrc-Dwm" ]]; then
  pass "install.sh --init-template rejects an id with uppercase letters"
else
  fail "install.sh --init-template invalid id (status=$status_badid, output=$out_badid)"
fi
if [[ $can_unshare -eq 0 ]]; then
  skip "install.sh --init-template refuses root (unshare -r unavailable)"
elif [[ $status_asroot -eq 1 && "$out_asroot" == *"Do not run --init-template as root"* && ! -e "$init_home/.config/lightxdm/.xinitrc-openbox" ]]; then
  pass "install.sh --init-template refuses to run as root"
else
  fail "install.sh --init-template as root (status=$status_asroot, output=$out_asroot)"
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

# --from-session imports only [Desktop Entry], retaining literal arguments and the first desktop name.
init_session_home="$TMP_DIR/init_session_home"
mkdir -p "$init_session_home"
init_session_entry="$TMP_DIR/import.desktop"
cat >"$init_session_entry" <<'EOF'
Exec=outside-group %U
DesktopNames=Outside;
[Desktop Entry]
Name=Openbox
Exec=openbox-session --config-file "session config" "$HOME;$(false)"
DesktopNames=Openbox;Ignored;
[Desktop Action Other]
Exec=ignored\command %f
DesktopNames=Ignored;
EOF
: >"$STUB_LOG"
set +e
output="$(HOME="$init_session_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template --de imported-wm --from-session "$init_session_entry" 2>&1)"
status=$?
set -e
init_session_template="$init_session_home/.config/lightxdm/.xinitrc-imported-wm"
# shellcheck disable=SC2016  # these shell characters must remain literal arguments
if [[ $status -eq 0 && "$(stat -c '%a' "$init_session_template" 2>/dev/null)" == 755 && ! -s "$STUB_LOG" ]] &&
  grep -Fxq 'exec openbox-session --config-file session\ config \$HOME\;\$\(false\)' "$init_session_template" &&
  grep -Fxq 'export DESKTOP_SESSION=imported-wm' "$init_session_template" &&
  grep -Fxq 'export XDG_CURRENT_DESKTOP=Openbox' "$init_session_template" &&
  grep -Fxq 'export XDG_SESSION_TYPE=x11' "$init_session_template" &&
  grep -Fq 'dbus-update-activation-environment --systemd' "$init_session_template"; then
  pass "--from-session imports the session command, literal arguments and first DesktopNames from [Desktop Entry]"
else
  fail "init from session (status=$status, output=$output)"
fi

# Wayland entries can name a command and desktop independently of the custom id.
printf '%s\n' '[Desktop Entry]' 'Exec=Hyprland' 'DesktopNames=Hyprland Desktop;Ignored;' >"$init_session_entry"
set +e
output="$(HOME="$init_session_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template --wayland --de hyprland --from-session "$init_session_entry" 2>&1)"
status=$?
set -e
init_session_wayland="$init_session_home/.config/lightxdm/.wayland-session-hyprland"
if [[ $status -eq 0 && "$(stat -c '%a' "$init_session_wayland" 2>/dev/null)" == 755 && ! -s "$STUB_LOG" ]] &&
  grep -Fxq 'exec Hyprland' "$init_session_wayland" &&
  grep -Fxq 'export DESKTOP_SESSION=hyprland' "$init_session_wayland" &&
  grep -Fxq 'export XDG_CURRENT_DESKTOP=Hyprland\ Desktop' "$init_session_wayland" &&
  grep -Fxq 'export XDG_SESSION_TYPE=wayland' "$init_session_wayland"; then
  pass "--from-session initializes a custom Wayland template from its entry"
else
  fail "Wayland init from session (status=$status, output=$output)"
fi

# Imported executable paths with spaces survive the Wayland preflight.
escaped_wayland_home="$TMP_DIR/escaped_wayland_home"
escaped_wayland_dir="$TMP_DIR/wm dir"
escaped_wayland_command="$escaped_wayland_dir/compositor"
mkdir -p "$escaped_wayland_home" "$escaped_wayland_dir"
printf '#!/bin/sh\nexit 0\n' >"$escaped_wayland_command"
chmod +x "$escaped_wayland_command"
printf '[Desktop Entry]\nExec="%s"\n' "$escaped_wayland_command" >"$init_session_entry"
output="$(HOME="$escaped_wayland_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template --wayland --de escaped-wm --from-session "$init_session_entry" 2>&1)" && status=0 || status=$?
escaped_wayland_template="$escaped_wayland_home/.config/lightxdm/.wayland-session-escaped-wm"
if [[ $status -eq 0 ]]; then
  output="$(HOME="$escaped_wayland_home" SESSION_ROOT='' bash -c 'source "$1/install.sh"; check_session_commands "$2"' bash "$REPO_ROOT" "$escaped_wayland_template" 2>&1)" && status=0 || status=$?
fi
if [[ $status -eq 0 ]]; then
  pass "Wayland preflight accepts an imported escaped executable path"
else
  fail "Wayland preflight imported escaped path (status=$status, output=$output)"
fi

missing_wayland_command="$TMP_DIR/no such/compositor"
missing_wayland_template="$escaped_wayland_home/.config/lightxdm/.wayland-session-missing-wm"
printf 'exec %q\n' "$missing_wayland_command" >"$missing_wayland_template"
output="$(HOME="$escaped_wayland_home" SESSION_ROOT='' bash -c 'source "$1/install.sh"; check_session_commands "$2"' bash "$REPO_ROOT" "$missing_wayland_template" 2>&1)" && status=0 || status=$?
if [[ $status -eq 1 && "$output" == *"Missing command: $missing_wayland_command."* ]]; then
  pass "Wayland preflight reports a missing escaped executable path"
else
  fail "Wayland preflight missing escaped path (status=$status, output=$output)"
fi

# Imported templates keep the existing overwrite refusal, including user edits.
printf '# user edit\n' >>"$init_session_template"
init_session_before="$(sha256sum < "$init_session_template")"
set +e
output="$(HOME="$init_session_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template --de imported-wm --from-session "$init_session_entry" 2>&1)"
status=$?
set -e
if [[ $status -eq 1 && "$output" == *"already exists"* && ! -s "$STUB_LOG" &&
  "$(sha256sum < "$init_session_template")" == "$init_session_before" ]]; then
  pass "--from-session refuses to overwrite an edited template"
else
  fail "init from session overwrite refusal (status=$status, output=$output)"
fi

# DesktopNames is optional; tabs split literal arguments and a final newline is optional.
printf '[Desktop Entry]\nExec=startfluxbox\t--no-slit' >"$init_session_entry"
set +e
output="$(HOME="$init_session_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --from-session "$init_session_entry" --de fluxbox --init-template 2>&1)"
status=$?
set -e
if [[ $status -eq 0 && ! -s "$STUB_LOG" ]] &&
  grep -Fxq 'exec startfluxbox --no-slit' "$init_session_home/.config/lightxdm/.xinitrc-fluxbox" &&
  grep -Fxq 'export XDG_CURRENT_DESKTOP=fluxbox' "$init_session_home/.config/lightxdm/.xinitrc-fluxbox"; then
  pass "--from-session defaults XDG_CURRENT_DESKTOP to the id when DesktopNames is absent"
else
  fail "init from session desktop fallback (status=$status, output=$output)"
fi

# Unsupported entries fail before even creating the template directory.
for session_bad_case in field-file field-urls backslash single-quote unclosed-quote joined-quote unquoted-quote empty missing other-group duplicate; do
  case "$session_bad_case" in
    field-file) session_bad_lines=('Exec=startfluxbox %f') ;;
    field-urls) session_bad_lines=('Exec=startfluxbox "%U"') ;;
    backslash) session_bad_lines=('Exec=startfluxbox session\ config') ;;
    single-quote) session_bad_lines=("Exec=startfluxbox 'session config'") ;;
    unclosed-quote) session_bad_lines=('Exec=startfluxbox "session config') ;;
    joined-quote) session_bad_lines=('Exec=startfluxbox "session"config') ;;
    unquoted-quote) session_bad_lines=('Exec=startfluxbox session"config"') ;;
    empty) session_bad_lines=('Exec=   ') ;;
    missing) session_bad_lines=('Name=Missing Exec') ;;
    other-group) session_bad_lines=('[Desktop Action Other]' 'Exec=startfluxbox') ;;
    duplicate) session_bad_lines=('Exec=startfluxbox' 'Exec=other-command') ;;
  esac
  printf '%s\n' '[Desktop Entry]' "${session_bad_lines[@]}" >"$init_session_entry"
  session_bad_home="$TMP_DIR/session_bad_$session_bad_case"
  mkdir -p "$session_bad_home"
  set +e
  output="$(HOME="$session_bad_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template --de rejected --from-session "$init_session_entry" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 1 && "$output" == *Exec* && ! -e "$session_bad_home/.config" && ! -s "$STUB_LOG" ]]; then
    pass "--from-session refuses $session_bad_case before creating any template"
  else
    fail "init from session $session_bad_case refusal (status=$status, output=$output)"
  fi
done

# Every invalid option combination must stop before changes or privilege checks.
printf '%s\n' '[Desktop Entry]' 'Exec=startfluxbox' >"$init_session_entry"
session_reject_home="$TMP_DIR/session_reject_home"
mkdir -p "$session_reject_home"
for session_reject_case in no-init no-id empty-id missing-path empty-path option-path \
  plasma gnome budgie xfce lxqt lxde mate cinnamon i3 \
  --list-packages --dry-run --non-interactive --no-packages --no-keyring --keyring --no-polkit-rule --autologin; do
  session_reject_args=(--init-template --de rejected --from-session "$init_session_entry")
  session_reject_message='--init-template takes only'
  case "$session_reject_case" in
    no-init)
      session_reject_args=(--de rejected --from-session "$init_session_entry")
      session_reject_message='--from-session requires --init-template --de'
      ;;
    no-id)
      session_reject_args=(--init-template --from-session "$init_session_entry")
      session_reject_message='--from-session requires --init-template --de'
      ;;
    empty-id)
      session_reject_args=(--init-template --de '' --from-session "$init_session_entry")
      session_reject_message='--from-session requires --init-template --de'
      ;;
    missing-path | empty-path | option-path)
      session_reject_args=(--init-template --de rejected --from-session)
      case "$session_reject_case" in
        empty-path) session_reject_args+=('') ;;
        option-path) session_reject_args+=(--wayland) ;;
      esac
      session_reject_message='Missing argument for --from-session'
      ;;
    plasma | gnome | budgie | xfce | lxqt | lxde | mate | cinnamon | i3)
      session_reject_args=(--init-template --de "$session_reject_case" --from-session "$init_session_entry")
      session_reject_message='--from-session is only for custom ids'
      ;;
    --keyring) session_reject_args+=(--keyring kwallet) ;;
    --autologin) session_reject_args+=(--autologin --no-keyring) ;;
    *) session_reject_args+=("$session_reject_case") ;;
  esac
  set +e
  output="$(HOME="$session_reject_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" "${session_reject_args[@]}" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 1 && "$output" == *"$session_reject_message"* &&
    ! -e "$session_reject_home/.config" && ! -s "$STUB_LOG" ]]; then
    pass "--from-session refuses $session_reject_case before changes"
  else
    fail "from-session option refusal ($session_reject_case, status=$status, output=$output)"
  fi
done

# --init-template --wayland creates an exact minimal custom template, mode 755.
init_wayland_home="$TMP_DIR/init_wayland_home"
mkdir -p "$init_wayland_home"
expected_sway_template="$TMP_DIR/expected_wayland_sway"
cat >"$expected_sway_template" <<'EOF'
#!/bin/bash
# Wayland session for lightXDM: start sway

export DESKTOP_SESSION=sway
export XDG_CURRENT_DESKTOP=sway
export XDG_SESSION_TYPE=wayland

if [[ -f ~/.gpg-agent-gnome ]]; then
  source ~/.gpg-agent-gnome
fi

exec sway
EOF
: >"$STUB_LOG"
set +e
output="$(HOME="$init_wayland_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template --wayland --de sway 2>&1)"
status=$?
set -e
init_sway="$init_wayland_home/.config/lightxdm/.wayland-session-sway"
if [[ $status -eq 0 && "$output" == *"Created $init_sway"* &&
  "$output" == *"$CMD_INSTALL --no-packages --de sway"* && ! -s "$STUB_LOG" &&
  "$(stat -c '%a' "$init_sway")" == 755 && ! -e "$init_wayland_home/.config/lightxdm/.xinitrc-sway" ]] &&
  cmp -s "$init_sway" "$expected_sway_template"; then
  pass "--init-template --wayland --de sway creates the exact minimal template (755) without sudo"
else
  fail "init custom Wayland template (status=$status, output=$output)"
fi

printf '# user edit\n' >>"$init_sway"
init_sway_before="$(sha256sum < "$init_sway")"
set +e
output="$(HOME="$init_wayland_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template --wayland --de sway 2>&1)"
status=$?
set -e
if [[ $status -eq 1 && "$output" == *"$init_sway already exists"* && ! -s "$STUB_LOG" &&
  "$(sha256sum < "$init_sway")" == "$init_sway_before" && "$(stat -c '%a' "$init_sway")" == 755 ]]; then
  pass "--init-template --wayland refuses to overwrite an existing edited template"
else
  fail "init custom Wayland overwrite refusal (status=$status, output=$output)"
fi

# A custom id keeps one session template: --init-template refuses to add the sibling.
for sib_case in "wayland-session-sway:xinitrc-sway::sway" "xinitrc-dwm:wayland-session-dwm:--wayland:dwm"; do
  IFS=: read -r sib_have sib_new sib_flag sib_id <<<"$sib_case"
  sib_home="$TMP_DIR/init_sibling_home_$sib_id"
  mkdir -p "$sib_home/.config/lightxdm"
  : >"$sib_home/.config/lightxdm/.$sib_have"
  : >"$STUB_LOG"
  set +e
  output="$(HOME="$sib_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template ${sib_flag:+"$sib_flag"} --de "$sib_id" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 1 && "$output" == *"/.config/lightxdm/.$sib_have already exists"* &&
    ! -e "$sib_home/.config/lightxdm/.$sib_new" && ! -s "$STUB_LOG" ]]; then
    pass "--init-template ${sib_flag:+$sib_flag }--de $sib_id refuses while .$sib_have exists"
  else
    fail "init-template sibling refusal for $sib_id (status=$status, output=$output)"
  fi
done

# --wayland requires template initialization and a custom id; refuse before writing.
reject_wayland_home="$TMP_DIR/reject_wayland_home"
mkdir -p "$reject_wayland_home"
: >"$STUB_LOG"
set +e
output="$(HOME="$reject_wayland_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --wayland --no-packages --de sway 2>&1)"
status=$?
set -e
if [[ $status -eq 1 && "$output" == *"--wayland requires --init-template"* && "$output" == *"Usage:"* &&
  ! -s "$STUB_LOG" && ! -e "$reject_wayland_home/.config" ]]; then
  pass "--wayland without --init-template prints usage before any changes"
else
  fail "--wayland without --init-template (status=$status, output=$output)"
fi

for reject_wayland_de in plasma gnome budgie xfce lxqt lxde mate cinnamon i3; do
  set +e
  output="$(HOME="$reject_wayland_home" PATH="$sudo_pw_dir:$PATH" bash "$REPO_ROOT/install.sh" --init-template --wayland --de "$reject_wayland_de" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 1 && "$output" == *"--wayland is only for custom ids"* &&
    ! -s "$STUB_LOG" && ! -e "$reject_wayland_home/.config" ]]; then
    pass "--init-template --wayland refuses the built-in $reject_wayland_de id before writing"
  else
    fail "--init-template --wayland built-in rejection ($reject_wayland_de, status=$status, output=$output)"
  fi
done

# uninstall.sh --keyring-only removes lightXDM's PAM lines and leaves everything else in place
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh --keyring-only (unshare -r unavailable)"
else
  ko_dir="$TMP_DIR/keyring_only"
  mkdir -p "$ko_dir/home" "$ko_dir/getty.d"
  printf '#%%PAM-1.0\nauth       include      system-local-login\n' >"$ko_dir/login.lightxdm.bak"
  cp "$ko_dir/login.lightxdm.bak" "$ko_dir/login"
  cp "$ko_dir/login.lightxdm.bak" "$ko_dir/login.expected"
  printf 'auth       optional   pam_gnome_keyring.so\nsession    optional   pam_gnome_keyring.so auto_start\n' >>"$ko_dir/login"
  # shellcheck disable=SC2016  # the drop-in holds a literal $TERM
  printf '[Service]\nExecStart=-/sbin/agetty --autologin testuser --noclear %%I $TERM\n' >"$ko_dir/getty.d/lightxdm-autologin.conf"
  printf 'rule\n' >"$ko_dir/polkit.rules"
  printf 'xfce\n' >"$ko_dir/home/.xinitrc"
  printf 'sddm.service\n' >"$ko_dir/dm"
  : >"$STUB_LOG"
  set +e
  output="$(env -u SUDO_USER TARGET_HOME= LOGIN_FILE="$ko_dir/login" OVERRIDE_DIR="$ko_dir/getty.d" POLKIT_RULE="$ko_dir/polkit.rules" DM_STATE_FILE="$ko_dir/dm" GNOME_SESSION_TYPE_DEST="$ko_dir/gnome-session-type.conf" unshare -r bash "$REPO_ROOT/uninstall.sh" --keyring-only 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && "$output" == *"Done (--keyring-only)"* && "$output" != *"enable-autologin.sh"* && -f "$ko_dir/getty.d/lightxdm-autologin.conf" && -f "$ko_dir/polkit.rules" && -f "$ko_dir/home/.xinitrc" ]] &&
    cmp -s "$ko_dir/login" "$ko_dir/login.expected" && [[ "$(cat "$ko_dir/dm")" == sddm.service ]] && ! grep -q systemctl "$STUB_LOG"; then
    pass "uninstall.sh --keyring-only restores PAM and keeps autologin, Polkit, dotfiles and disabled display managers"
  else
    fail "uninstall.sh --keyring-only (status=$status, output=$output, login=$(cat "$ko_dir/login"))"
  fi
  rm -f "$ko_dir/getty.d/lightxdm-autologin.conf"
  set +e
  output="$(env -u SUDO_USER TARGET_HOME= LOGIN_FILE="$ko_dir/login" OVERRIDE_DIR="$ko_dir/getty.d" POLKIT_RULE="$ko_dir/polkit.rules" DM_STATE_FILE="$ko_dir/dm" GNOME_SESSION_TYPE_DEST="$ko_dir/gnome-session-type.conf" unshare -r bash "$REPO_ROOT/uninstall.sh" --keyring-only 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && "$output" == *"To log in on TTY1 without a password, run: sudo $CMD_AUTOLOGIN <user>"* ]]; then
    pass "uninstall.sh --keyring-only suggests enabling autologin when disabled"
  else
    fail "uninstall.sh --keyring-only autologin hint (status=$status, output=$output)"
  fi
  # A keyring line lightXDM did not add stays, with a warning
  printf '#%%PAM-1.0\nauth       optional   pam_kwallet5.so\n' >"$ko_dir/login"
  set +e
  output="$(env -u SUDO_USER TARGET_HOME= LOGIN_FILE="$ko_dir/login" OVERRIDE_DIR="$ko_dir/getty.d" POLKIT_RULE="$ko_dir/polkit.rules" DM_STATE_FILE="$ko_dir/dm" unshare -r bash "$REPO_ROOT/uninstall.sh" --keyring-only 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && "$output" == *"still configures PAM keyring unlock"* ]] && grep -q pam_kwallet5 "$ko_dir/login"; then
    pass "uninstall.sh --keyring-only warns about keyring lines it did not add and keeps them"
  else
    fail "uninstall.sh --keyring-only foreign keyring line (status=$status, output=$output)"
  fi
fi

# uninstall.sh removes keyring lines an install before 2026-11-03 added and restores its .lightxde backup
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh old .lightxde backup (unshare -r unavailable)"
else
  old_dir="$TMP_DIR/old_lightxde"
  mkdir -p "$old_dir/home"
  old_stock='#%PAM-1.0\nauth       include      system-local-login\n'
  old_keyring='auth       optional   pam_gnome_keyring.so auto_start\nsession    optional   pam_gnome_keyring.so auto_start\n'
  old_uninstall_env=(env -u SUDO_USER TARGET_HOME="$old_dir/home" LOGIN_FILE="$old_dir/login" OVERRIDE_DIR="$old_dir/getty.d" POLKIT_RULE="$old_dir/polkit.rules" DM_STATE_FILE="$old_dir/dm" GNOME_SESSION_TYPE_DEST="$old_dir/gnome-session-type.conf")
  printf %b "$old_stock" >"$old_dir/login.expected"
  for old_mode in full keyring-only; do
    printf %b "$old_stock$old_keyring" >"$old_dir/login"
    printf %b "$old_stock" >"$old_dir/login.lightxde.bak.1751000000"
    old_args=()
    [[ $old_mode == keyring-only ]] && old_args=(--keyring-only)
    set +e
    output="$("${old_uninstall_env[@]}" unshare -r bash "$REPO_ROOT/uninstall.sh" "${old_args[@]}" 2>&1)"
    status=$?
    set -e
    if [[ $status -eq 0 && "$output" == *"Restoring $old_dir/login from backup"* && "$output" != *"lines lightXDM did not add"* && ! -e "$old_dir/login.lightxde.bak.1751000000" ]] &&
      cmp -s "$old_dir/login" "$old_dir/login.expected"; then
      pass "uninstall.sh ($old_mode) removes old keyring lines and restores the .lightxde backup"
    else
      fail "uninstall.sh ($old_mode) old .lightxde backup (status=$status, output=$output, login=$(cat "$old_dir/login"))"
    fi
  done
  # With two old backups the oldest is the original; the newer one is left alone.
  printf %b "$old_stock$old_keyring" >"$old_dir/login"
  printf %b "$old_stock" >"$old_dir/login.lightxde.bak.1751000000"
  printf %b "$old_stock$old_keyring" >"$old_dir/login.lightxde.bak.1752000000"
  set +e
  output="$("${old_uninstall_env[@]}" unshare -r bash "$REPO_ROOT/uninstall.sh" --keyring-only 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && "$output" == *"Restoring $old_dir/login from backup"* && ! -e "$old_dir/login.lightxde.bak.1751000000" && -f "$old_dir/login.lightxde.bak.1752000000" ]] &&
    cmp -s "$old_dir/login" "$old_dir/login.expected"; then
    pass "uninstall.sh uses and removes the oldest .lightxde backup and leaves newer ones"
  else
    fail "uninstall.sh two .lightxde backups (status=$status, output=$output, login=$(cat "$old_dir/login"))"
  fi
  # After that uninstall the login file has no keyring lines, so a re-install must not adopt the
  # newer backup (it holds the old keyring lines) and uninstall must restore the original again.
  rm -f -- "$old_dir"/login.*.bak*
  printf %b "$old_stock" >"$old_dir/login"
  printf %b "$old_stock$old_keyring" >"$old_dir/login.lightxde.bak.1752000000"
  # shellcheck disable=SC2016  # expand inside the child shell
  old_pam_log="$(env LOGIN_FILE="$old_dir/login" bash -c 'source "$1/install.sh" && configure_pam xfce' bash "$REPO_ROOT" 2>&1)"
  old_fresh=0
  cmp -s "$old_dir/login.lightxdm.bak" "$old_dir/login.expected" && old_fresh=1
  set +e
  output="$("${old_uninstall_env[@]}" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && $old_fresh -eq 1 && "$old_pam_log" != *"as the original"* && -f "$old_dir/login.lightxde.bak.1752000000" ]] &&
    cmp -s "$old_dir/login" "$old_dir/login.expected"; then
    pass "configure_pam skips a .lightxde backup once the login file has no old keyring lines"
  else
    fail "configure_pam adopted a newer .lightxde backup (status=$status, log=$old_pam_log, output=$output, login=$(cat "$old_dir/login"))"
  fi
  # A re-install over an old install adopts the .lightxde backup, so uninstall still restores the original.
  rm -f -- "$old_dir/login" "$old_dir"/login.*.bak*
  printf %b "$old_stock" >"$old_dir/login.lightxde.bak.1751000000"
  printf %b "$old_stock$PAM_KWALLET_AUTH\n$PAM_KWALLET_SESSION\n" >"$old_dir/login"
  # shellcheck disable=SC2016  # expand inside the child shell
  old_pam_log="$(env LOGIN_FILE="$old_dir/login" bash -c 'source "$1/install.sh" && configure_pam xfce' bash "$REPO_ROOT" 2>&1)"
  if cmp -s "$old_dir/login.lightxdm.bak" "$old_dir/login.expected" && ! grep -q pam_kwallet5 "$old_dir/login" &&
    [[ ! -e "$old_dir/login.lightxde.bak.1751000000" && "$old_pam_log" == *"Using $old_dir/login.lightxde.bak.1751000000 as the original"* ]]; then
    pass "configure_pam adopts the oldest .lightxde backup and removes the old install's KWallet lines"
  else
    fail "configure_pam adopt .lightxde backup (log=$old_pam_log, login=$(cat "$old_dir/login"))"
  fi
  set +e
  output="$("${old_uninstall_env[@]}" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && "$output" == *"Restoring $old_dir/login from backup"* && "$output" != *"lines lightXDM did not add"* && ! -e "$old_dir/login.lightxde.bak.1751000000" ]] &&
    cmp -s "$old_dir/login" "$old_dir/login.expected"; then
    pass "uninstall.sh after a re-install over an old install restores the pre-lightXDM login file"
  else
    fail "uninstall.sh after re-install over old install (status=$status, output=$output, login=$(cat "$old_dir/login"))"
  fi
  # Switching an older GNOME keyring install to Plasma removes the legacy auth line alongside the session line.
  rm -f -- "$old_dir/login" "$old_dir"/login.*.bak*
  printf %b "$old_stock" >"$old_dir/login.lightxde.bak.1751000000"
  printf %b "$old_stock$old_keyring" >"$old_dir/login"
  # shellcheck disable=SC2016  # expand inside the child shell
  old_pam_log="$(env LOGIN_FILE="$old_dir/login" bash -c 'source "$1/install.sh" && configure_pam plasma' bash "$REPO_ROOT" 2>&1)"
  if cmp -s "$old_dir/login.lightxdm.bak" "$old_dir/login.expected" &&
    ! grep -q pam_gnome_keyring "$old_dir/login" &&
    grep -Fxq -- "$PAM_KWALLET_AUTH" "$old_dir/login" &&
    grep -Fxq -- "$PAM_KWALLET_SESSION" "$old_dir/login"; then
    pass "configure_pam plasma removes the legacy GNOME keyring auth line and adds KWallet lines"
  else
    fail "configure_pam plasma legacy GNOME keyring auth line (log=$old_pam_log, login=$(cat "$old_dir/login"))"
  fi
  # Staying on GNOME Keyring replaces the legacy auth line with the current one, as the preview says.
  rm -f -- "$old_dir/login" "$old_dir"/login.*.bak*
  printf %b "$old_stock" >"$old_dir/login.lightxde.bak.1751000000"
  printf %b "$old_stock$old_keyring" >"$old_dir/login"
  # shellcheck disable=SC2016  # expand inside the child shell
  old_preview="$(env LOGIN_FILE="$old_dir/login" bash -c 'source "$1/install.sh" && configure_pam gnome 1' bash "$REPO_ROOT" 2>&1)"
  # shellcheck disable=SC2016  # expand inside the child shell
  old_pam_log="$(env LOGIN_FILE="$old_dir/login" bash -c 'source "$1/install.sh" && configure_pam gnome' bash "$REPO_ROOT" 2>&1)"
  if grep -Fxq -- "  remove: auth       optional   pam_gnome_keyring.so auto_start" <<<"$old_preview" &&
    grep -Fxq -- "$PAM_GNOME_KEYRING_AUTH" <<<"$old_preview"; then
    pass "the GNOME preview over the legacy auth line lists its removal and the current auth line"
  else
    fail "configure_pam gnome preview of the legacy auth line refresh (preview=$old_preview)"
  fi
  if ! grep -Fxq -- "auth       optional   pam_gnome_keyring.so auto_start" "$old_dir/login" &&
    [[ "$(grep -Fxc -- "$PAM_GNOME_KEYRING_AUTH" "$old_dir/login")" -eq 1 &&
      "$(grep -Fxc -- "$PAM_GNOME_KEYRING_SESSION" "$old_dir/login")" -eq 1 ]] &&
    cmp -s "$old_dir/login.lightxdm.bak" "$old_dir/login.expected"; then
    pass "configure_pam gnome replaces the legacy GNOME keyring auth line with the current one"
  else
    fail "configure_pam gnome legacy auth line refresh (log=$old_pam_log, login=$(cat "$old_dir/login"))"
  fi
  # A legacy-looking line the original login file already had is the user's: it stays.
  rm -f -- "$old_dir/login" "$old_dir"/login.*.bak*
  printf %b "$old_stock$old_keyring" >"$old_dir/login.lightxdm.bak"
  printf %b "$old_stock$old_keyring" >"$old_dir/login"
  # shellcheck disable=SC2016  # expand inside the child shell
  old_pam_log="$(env LOGIN_FILE="$old_dir/login" bash -c 'source "$1/install.sh" && configure_pam gnome' bash "$REPO_ROOT" 2>&1)"
  if grep -Fxq -- "auth       optional   pam_gnome_keyring.so auto_start" "$old_dir/login" &&
    cmp -s "$old_dir/login" "$old_dir/login.lightxdm.bak"; then
    pass "configure_pam keeps a legacy-looking keyring line that the original login file already had"
  else
    fail "configure_pam user's own legacy-looking line (log=$old_pam_log, login=$(cat "$old_dir/login"))"
  fi
  # An existing .lightxdm.bak wins; the .lightxde backup is not moved.
  rm -f -- "$old_dir/login" "$old_dir"/login.*.bak*
  printf %b "$old_stock" >"$old_dir/login.lightxdm.bak"
  printf %b "$old_stock$old_keyring" >"$old_dir/login.lightxde.bak.1751000000"
  printf %b "$old_stock" >"$old_dir/login"
  # shellcheck disable=SC2016  # expand inside the child shell
  env LOGIN_FILE="$old_dir/login" bash -c 'source "$1/install.sh" && configure_pam xfce' bash "$REPO_ROOT" >/dev/null 2>&1 || true
  if [[ -f "$old_dir/login.lightxde.bak.1751000000" ]] && cmp -s "$old_dir/login.lightxdm.bak" "$old_dir/login.expected"; then
    pass "configure_pam leaves .lightxde backups alone when .lightxdm.bak exists"
  else
    fail "configure_pam moved a .lightxde backup despite .lightxdm.bak ($(ls "$old_dir"))"
  fi
  # configure_gnome_session_type adopts the .lightxde backup too, before it backs up the login file.
  rm -f -- "$old_dir/login" "$old_dir"/login.*.bak*
  printf %b "$old_stock" >"$old_dir/login.lightxde.bak.1751000000"
  printf %b "${old_stock}session    include      system-local-login\n$old_keyring" >"$old_dir/login"
  # shellcheck disable=SC2016  # expand inside the child shell
  old_pam_log="$(env LOGIN_FILE="$old_dir/login" GNOME_SESSION_TYPE_DEST="$old_dir/gnome-session-type.conf" bash -c 'source "$1/install.sh" && configure_gnome_session_type gnome old-user' bash "$REPO_ROOT" 2>&1)"
  if cmp -s "$old_dir/login.lightxdm.bak" "$old_dir/login.expected" && [[ ! -e "$old_dir/login.lightxde.bak.1751000000" &&
    "$old_pam_log" == *"Using $old_dir/login.lightxde.bak.1751000000 as the original"* ]]; then
    pass "configure_gnome_session_type adopts the oldest .lightxde backup"
  else
    fail "configure_gnome_session_type adopt .lightxde backup (log=$old_pam_log, $(ls "$old_dir"))"
  fi
  rm -rf -- "$old_dir"
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
  output="$(env TARGET_HOME="$ua_dir/home" LOGIN_FILE="$ua_dir/login" OVERRIDE_DIR="$ua_dir/getty.d" POLKIT_RULE="$ua_dir/polkit" DM_STATE_FILE="$ua_dir/dm" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && ! -e "$ua_dir/getty.d/lightxdm-autologin.conf" && "$output" == *"Warning: $ua_dir/getty.d/zz-local.conf still enables autologin."* &&
    "$output" != *"plain.conf"* ]]; then
    pass "uninstall.sh warns by name about an autologin drop-in it did not write"
  else
    fail "uninstall.sh remaining autologin warning (status=$status, output=$output)"
  fi
fi


# uninstall.sh removes the respawn guard's startx-attempts state without following symlinks
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh removes startx-attempts state (unshare -r unavailable)"
else
  sa_dir="$TMP_DIR/startx_attempts_cleanup"
  for sa_case in plain symlink nonempty; do
    sa_home="$sa_dir/$sa_case/home"
    mkdir -p "$sa_home/.local/state/lightxdm"
    sa_state="$sa_home/.local/state/lightxdm/startx-attempts"
    case "$sa_case" in
      plain) printf '1\n' >"$sa_state" ;;
      symlink)
        printf 'keep\n' >"$sa_dir/$sa_case/target"
        ln -s "$sa_dir/$sa_case/target" "$sa_state"
        ;;
      nonempty)
        printf '1\n' >"$sa_state"
        printf 'other\n' >"$sa_home/.local/state/lightxdm/other"
        ;;
    esac
    set +e
    output="$(env TARGET_HOME="$sa_home" LOGIN_FILE="$sa_dir/$sa_case/login" OVERRIDE_DIR="$sa_dir/$sa_case/getty.d" POLKIT_RULE="$sa_dir/$sa_case/polkit" DM_STATE_FILE="$sa_dir/$sa_case/dm/state" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
    status=$?
    set -e
    case "$sa_case" in
      plain) [[ $status -eq 0 && ! -e "$sa_state" && ! -e "$sa_home/.local/state/lightxdm" ]] ;;
      symlink) [[ $status -eq 0 && -L "$sa_state" && "$(cat "$sa_dir/$sa_case/target")" == keep ]] ;;
      nonempty) [[ $status -eq 0 && ! -e "$sa_state" && -f "$sa_home/.local/state/lightxdm/other" ]] ;;
    esac && sa_ok=1 || sa_ok=0
    if [[ $sa_ok -eq 1 ]]; then
      pass "uninstall.sh startx-attempts cleanup ($sa_case)"
    else
      fail "uninstall.sh startx-attempts cleanup ($sa_case, status=$status, output=$output)"
    fi
  done
fi

# Case 75: --help states how X11 desktops and all three Wayland desktops start
help_wl_out="$(HOME="$help_home" bash "$REPO_ROOT/install.sh" --help 2>&1)"
if [[ "$help_wl_out" == *"X11 desktops start with startx and Plasma, GNOME and Budgie start on Wayland."* &&
  "$help_wl_out" == *"plasma gnome xfce lxqt lxde mate cinnamon budgie i3"* &&
  "$help_wl_out" == *".wayland-session-<id> for Plasma, GNOME and Budgie"* ]]; then
  pass "install.sh --help documents X11 startx and Plasma, GNOME and Budgie Wayland startup"
else
  fail "install.sh --help Wayland description (output=$help_wl_out)"
fi

# Case 76: check_session_commands validates Wayland templates' absolute exec paths without requiring startx
wl_chk_dir="$TMP_DIR/wayland_check_cmd"
wl_chk_nostartx_bin="$wl_chk_dir/nostartx_bin"
mkdir -p "$wl_chk_dir/bin" "$wl_chk_nostartx_bin"
for wl_tool in bash grep tail; do
  ln -sf "$(command -v "$wl_tool")" "$wl_chk_nostartx_bin/$wl_tool"
done

printf '#!/bin/bash\nexit 0\n' >"$wl_chk_dir/bin/wrapper"
cp "$wl_chk_dir/bin/wrapper" "$wl_chk_dir/bin/compositor"
chmod 755 "$wl_chk_dir/bin/wrapper" "$wl_chk_dir/bin/compositor"
printf '#!/bin/bash\nexit 0\n' >"$wl_chk_dir/bin/nonexec"
chmod 644 "$wl_chk_dir/bin/nonexec"
mkdir -p "$wl_chk_dir/bin/adir" "$wl_chk_dir/missing_dir" "$wl_chk_dir/nonexec_dir" "$wl_chk_dir/isdir_dir"

printf '#!/bin/bash\nexec %s --flag %s\n' "$wl_chk_dir/bin/wrapper" "$wl_chk_dir/bin/compositor" >"$wl_chk_dir/.wayland-session-plasma"
printf '#!/bin/bash\nexec %s %s\n' "$wl_chk_dir/bin/wrapper" "$wl_chk_dir/bin/missing-plasma" >"$wl_chk_dir/missing_dir/.wayland-session-plasma"
printf '#!/bin/bash\nexec %s\n' "$wl_chk_dir/bin/nonexec" >"$wl_chk_dir/nonexec_dir/.wayland-session-plasma"
printf '#!/bin/bash\nexec %s\n' "$wl_chk_dir/bin/adir" >"$wl_chk_dir/isdir_dir/.wayland-session-plasma"
printf '#!/bin/bash\nexec %s --arg\n' "$wl_chk_dir/bin/compositor" >"$wl_chk_dir/.wayland-session-sway"
printf '#!/bin/bash\nexec %s\n' "$wl_chk_dir/bin/missing-sway" >"$wl_chk_dir/.wayland-session-sway-bad"

set +e
wl_ok_out="$(
  SESSION_ROOT="" PATH="$wl_chk_nostartx_bin" check_session_commands "$wl_chk_dir/.wayland-session-plasma" 2>&1
)"
wl_ok_st=$?
wl_bundled_ok_out="$(
  SESSION_ROOT="$SESSION_ROOT" PATH="$wl_chk_nostartx_bin" check_session_commands "$REPO_ROOT/dotfiles/.wayland-session-plasma" 2>&1
)"
wl_bundled_ok_st=$?
wl_custom_ok_out="$(
  SESSION_ROOT="" PATH="$wl_chk_nostartx_bin" check_session_commands "$wl_chk_dir/.wayland-session-sway" 2>&1
)"
wl_custom_ok_st=$?
wl_miss_out="$(
  SESSION_ROOT="" PATH="$wl_chk_nostartx_bin" check_session_commands "$wl_chk_dir/missing_dir/.wayland-session-plasma" 2>&1
)"
wl_miss_st=$?
wl_nonexec_out="$(
  SESSION_ROOT="" PATH="$wl_chk_nostartx_bin" check_session_commands "$wl_chk_dir/nonexec_dir/.wayland-session-plasma" 2>&1
)"
wl_nonexec_st=$?
wl_isdir_out="$(
  SESSION_ROOT="" PATH="$wl_chk_nostartx_bin" check_session_commands "$wl_chk_dir/isdir_dir/.wayland-session-plasma" 2>&1
)"
wl_isdir_st=$?
wl_generic_out="$(
  SESSION_ROOT="" PATH="$wl_chk_nostartx_bin" check_session_commands "$wl_chk_dir/.wayland-session-sway-bad" 2>&1
)"
wl_generic_st=$?
set -e

if [[ $wl_ok_st -eq 0 && -z "$wl_ok_out" &&
  $wl_bundled_ok_st -eq 0 && -z "$wl_bundled_ok_out" &&
  $wl_custom_ok_st -eq 0 && -z "$wl_custom_ok_out" ]]; then
  pass "check_session_commands accepts Wayland templates whose absolute exec paths exist without startx on PATH"
else
  fail "check_session_commands Wayland valid (ok=$wl_ok_st:$wl_ok_out | bundled=$wl_bundled_ok_st:$wl_bundled_ok_out | custom=$wl_custom_ok_st:$wl_custom_ok_out)"
fi

if [[ $wl_miss_st -eq 1 &&
  "$wl_miss_out" == *"Missing command: $wl_chk_dir/bin/missing-plasma (normally provided by plasma-workspace). Install plasma-desktop and re-run."* &&
  $wl_nonexec_st -eq 1 &&
  "$wl_nonexec_out" == *"Missing command: $wl_chk_dir/bin/nonexec (normally provided by plasma-workspace). Install plasma-desktop and re-run."* &&
  $wl_isdir_st -eq 1 &&
  "$wl_isdir_out" == *"Missing command: $wl_chk_dir/bin/adir (normally provided by plasma-workspace). Install plasma-desktop and re-run."* &&
  $wl_generic_st -eq 1 &&
  "$wl_generic_out" == *"Missing command: $wl_chk_dir/bin/missing-sway"* &&
  "$wl_generic_out" != *"plasma-workspace"* ]]; then
  pass "check_session_commands rejects missing, non-executable, or directory Wayland exec paths with plasma and generic messages"
else
  fail "check_session_commands Wayland rejection (miss=$wl_miss_st:$wl_miss_out | nonexec=$wl_nonexec_st:$wl_nonexec_out | dir=$wl_isdir_st:$wl_isdir_out | gen=$wl_generic_st:$wl_generic_out)"
fi

printf '#!/bin/bash\nexec compositor -C %s\n' "$wl_chk_dir/bin/adir" >"$wl_chk_dir/.wayland-session-labwc"
printf '#!/bin/bash\nexec %s --config %s\n' "$wl_chk_dir/bin/compositor" "$wl_chk_dir/bin/nonexec" >"$wl_chk_dir/.wayland-session-sway-cfg"
printf '#!/bin/bash\nexec %s -c x\n' "$wl_chk_dir/bin/missing-sway" >"$wl_chk_dir/.wayland-session-sway-opt-bad"

set +e
wl_opt_dir_out="$(
  SESSION_ROOT="" PATH="$wl_chk_dir/bin:$wl_chk_nostartx_bin" check_session_commands "$wl_chk_dir/.wayland-session-labwc" 2>&1
)"
wl_opt_dir_st=$?
wl_opt_file_out="$(
  SESSION_ROOT="" PATH="$wl_chk_nostartx_bin" check_session_commands "$wl_chk_dir/.wayland-session-sway-cfg" 2>&1
)"
wl_opt_file_st=$?
wl_opt_miss_out="$(
  SESSION_ROOT="" PATH="$wl_chk_nostartx_bin" check_session_commands "$wl_chk_dir/.wayland-session-sway-opt-bad" 2>&1
)"
wl_opt_miss_st=$?
set -e

if [[ $wl_opt_dir_st -eq 0 && -z "$wl_opt_dir_out" &&
  $wl_opt_file_st -eq 0 && -z "$wl_opt_file_out" &&
  $wl_opt_miss_st -eq 1 &&
  "$wl_opt_miss_out" == *"Missing command: $wl_chk_dir/bin/missing-sway"* ]]; then
  pass "check_session_commands stops checking Wayland absolute paths at the first option argument"
else
  fail "check_session_commands Wayland option arguments (dir=$wl_opt_dir_st:$wl_opt_dir_out | file=$wl_opt_file_st:$wl_opt_file_out | miss=$wl_opt_miss_st:$wl_opt_miss_out)"
fi

for wl_check_spec in "gnome|/usr/bin/gnome-session|gnome-session" "budgie|/usr/bin/startbudgielabwc|budgie-desktop"; do
  IFS='|' read -r wl_check_de wl_check_command wl_check_package <<<"$wl_check_spec"
  set +e
  wl_check_ok_out="$(SESSION_ROOT="$SESSION_ROOT" PATH="$wl_chk_nostartx_bin" check_session_commands "$REPO_ROOT/dotfiles/.wayland-session-$wl_check_de" 2>&1)"
  wl_check_ok_st=$?
  wl_check_miss_out="$(SESSION_ROOT="$wl_chk_dir/empty_root" PATH="$wl_chk_nostartx_bin" check_session_commands "$REPO_ROOT/dotfiles/.wayland-session-$wl_check_de" 2>&1)"
  wl_check_miss_st=$?
  set -e
  if [[ $wl_check_ok_st -eq 0 && -z "$wl_check_ok_out" && $wl_check_miss_st -eq 1 &&
    "$wl_check_miss_out" == "=> Missing command: $wl_check_command (normally provided by $wl_check_package). Install $wl_check_package and re-run." ]]; then
    pass "check_session_commands checks $wl_check_de absolute exec path without startx and names $wl_check_package when missing"
  else
    fail "check_session_commands $wl_check_de (ok=$wl_check_ok_st:$wl_check_ok_out, missing=$wl_check_miss_st:$wl_check_miss_out)"
  fi

  : >"$STUB_LOG"
  set +e
  output="$(SESSION_ROOT="$wl_chk_dir/empty_root" run_main_with_stubs "$sudo_pw_dir" --no-packages --de "$wl_check_de" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 1 && "$(cat "$STUB_LOG")" == "sudo -v" &&
    "$output" == *"Missing command: $wl_check_command (normally provided by $wl_check_package)."* &&
    "$output" == *"Install stopped during check_session_commands; already done: none"* &&
    "$output" != *"lightXDM install complete!"* ]]; then
    pass "main --no-packages --de $wl_check_de stops before configuration when its session command is missing"
  else
    fail "main missing $wl_check_de session command (status=$status, log=$(cat "$STUB_LOG"), output=$output)"
  fi
done

# main --no-packages --de plasma stops in check_session_commands before copy_dotfiles when startplasma-wayland is missing
wl_incomplete_root="$wl_chk_dir/incomplete_root"
mkdir -p "$wl_incomplete_root/usr/lib"
printf '#!/bin/bash\nexit 0\n' >"$wl_incomplete_root/usr/lib/plasma-dbus-run-session-if-needed"
chmod 755 "$wl_incomplete_root/usr/lib/plasma-dbus-run-session-if-needed"
: >"$STUB_LOG"
set +e
wl_main_miss_out="$(SESSION_ROOT="$wl_incomplete_root" run_main_with_stubs "$sudo_pw_dir" --no-packages --de plasma 2>&1)"
wl_main_miss_st=$?
set -e
wl_main_miss_log="$(cat "$STUB_LOG")"
if [[ $wl_main_miss_st -ne 0 &&
  "$wl_main_miss_out" == *"Missing command: /usr/bin/startplasma-wayland (normally provided by plasma-workspace). Install plasma-desktop and re-run."* &&
  "$wl_main_miss_log" != *"copy_dotfiles"* ]]; then
  pass "main --no-packages --de plasma stops before copy_dotfiles when a Wayland session command is missing"
else
  fail "main plasma missing session command (status=$wl_main_miss_st, log=$wl_main_miss_log, output=$wl_main_miss_out)"
fi

# Case 77: X11 copy_dotfiles preserves ~/.wayland-session for uninstall and removes it from the startup path
wl_switch_dir="$TMP_DIR/wayland_to_x11"

# 77a: bundled lightXDM ~/.wayland-session without backup -> removed cleanly
wl_sw_bundled="$wl_switch_dir/home_bundled"
mkdir -p "$wl_sw_bundled"
(
  export HOME="$wl_sw_bundled"
  export USER="testuser"
  copy_dotfiles "plasma" 2>/dev/null
)
wl_sw_bundled_out="$(
  export HOME="$wl_sw_bundled"
  export USER="testuser"
  copy_dotfiles "xfce" 2>&1
)"
if [[ ! -e "$wl_sw_bundled/.wayland-session" && ! -L "$wl_sw_bundled/.wayland-session" &&
  -f "$wl_sw_bundled/.wayland-session.lightxdm.absent" &&
  ! -e "$wl_sw_bundled/.wayland-session.lightxdm.bak" &&
  ! -e "$wl_sw_bundled/.wayland-session.lightxdm-edited" &&
  -x "$wl_sw_bundled/.xinitrc" &&
  "$wl_sw_bundled_out" != *"WARNING:"* ]]; then
  pass "copy_dotfiles xfce removes a bundled lightXDM ~/.wayland-session and keeps its .absent marker for uninstall"
else
  fail "copy_dotfiles xfce after bundled plasma (output=$wl_sw_bundled_out)"
fi

# 77a: an X11 install into a home without ~/.wayland-session leaves no Wayland marker behind
wl_sw_plain="$wl_switch_dir/home_x11_only"
mkdir -p "$wl_sw_plain"
(
  export HOME="$wl_sw_plain"
  export USER="testuser"
  copy_dotfiles "xfce" 2>/dev/null
)
if [[ -x "$wl_sw_plain/.xinitrc" && ! -e "$wl_sw_plain/.wayland-session" &&
  ! -e "$wl_sw_plain/.wayland-session.lightxdm.absent" && ! -e "$wl_sw_plain/.wayland-session.lightxdm.bak" ]]; then
  pass "copy_dotfiles xfce in an X11-only home creates no .wayland-session marker or backup"
else
  fail "copy_dotfiles xfce X11-only home left Wayland files ($(compgen -G "$wl_sw_plain/.wayland-session*" | tr '\n' ' '))"
fi

# 77b: a user Wayland template is removed while the original backup stays intact for uninstall
wl_sw_bak="$wl_switch_dir/home_with_bak"
mkdir -p "$wl_sw_bak/.config/lightxdm"
printf '#!/bin/bash\nexec custom-user-compositor\n' >"$wl_sw_bak/.wayland-session"
chmod 755 "$wl_sw_bak/.wayland-session"
cp "$wl_sw_bak/.wayland-session" "$wl_sw_bak/wayland.expected"
printf '#!/bin/bash\n# custom plasma override\nexec /usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasma-wayland\n' >"$wl_sw_bak/.config/lightxdm/.wayland-session-plasma"
chmod 755 "$wl_sw_bak/.config/lightxdm/.wayland-session-plasma"
(
  export HOME="$wl_sw_bak"
  export USER="testuser"
  copy_dotfiles "plasma" 2>/dev/null
)
wl_sw_bak_out="$(
  export HOME="$wl_sw_bak"
  export USER="testuser"
  copy_dotfiles "i3" 2>&1
)"
if [[ ! -e "$wl_sw_bak/.wayland-session" && ! -L "$wl_sw_bak/.wayland-session" &&
  -f "$wl_sw_bak/.wayland-session.lightxdm.bak" &&
  ! -e "$wl_sw_bak/.wayland-session.lightxdm.absent" &&
  ! -e "$wl_sw_bak/.wayland-session.lightxdm-edited" &&
  -x "$wl_sw_bak/.xinitrc" &&
  "$wl_sw_bak_out" != *"WARNING:"* ]] &&
  cmp -s "$wl_sw_bak/wayland.expected" "$wl_sw_bak/.wayland-session.lightxdm.bak"; then
  pass "copy_dotfiles i3 removes the user-template Wayland session and keeps the original backup byte-identical"
else
  fail "copy_dotfiles i3 preserves wayland backup (output=$wl_sw_bak_out)"
fi

# 77c: foreign regular files and symlinks are backed up and removed from the startup path
for wl_foreign_kind in regular symlink; do
  wl_sw_foreign="$wl_switch_dir/home_foreign_$wl_foreign_kind"
  mkdir -p "$wl_sw_foreign"
  if [[ "$wl_foreign_kind" == regular ]]; then
    printf '#!/bin/bash\nexec sway\n' >"$wl_sw_foreign/.wayland-session"
    chmod 755 "$wl_sw_foreign/.wayland-session"
  else
    ln -s "$REPO_ROOT/dotfiles/.wayland-session-plasma" "$wl_sw_foreign/.wayland-session"
  fi
  cp -P "$wl_sw_foreign/.wayland-session" "$wl_sw_foreign/wayland.expected"
  wl_sw_foreign_out="$(
    export HOME="$wl_sw_foreign"
    export USER="testuser"
    copy_dotfiles "lxqt" 2>&1
  )"
  wl_foreign_intact=0
  if [[ "$wl_foreign_kind" == regular && -f "$wl_sw_foreign/.wayland-session.lightxdm.bak" &&
    ! -L "$wl_sw_foreign/.wayland-session.lightxdm.bak" ]] &&
    cmp -s "$wl_sw_foreign/wayland.expected" "$wl_sw_foreign/.wayland-session.lightxdm.bak"; then
    wl_foreign_intact=1
  elif [[ "$wl_foreign_kind" == symlink && -L "$wl_sw_foreign/.wayland-session.lightxdm.bak" &&
    "$(readlink "$wl_sw_foreign/.wayland-session.lightxdm.bak")" == "$(readlink "$wl_sw_foreign/wayland.expected")" ]]; then
    wl_foreign_intact=1
  fi
  if [[ $wl_foreign_intact -eq 1 && -x "$wl_sw_foreign/.xinitrc" &&
    ! -e "$wl_sw_foreign/.wayland-session" && ! -L "$wl_sw_foreign/.wayland-session" &&
    ! -e "$wl_sw_foreign/.wayland-session.lightxdm.absent" &&
    ! -e "$wl_sw_foreign/.wayland-session.lightxdm-edited" &&
    "$wl_sw_foreign_out" == *"Backing up $wl_sw_foreign/.wayland-session to $wl_sw_foreign/.wayland-session.lightxdm.bak"* &&
    "$wl_sw_foreign_out" != *"WARNING:"* ]]; then
    pass "copy_dotfiles lxqt backs up foreign $wl_foreign_kind ~/.wayland-session and removes it for X11 startup"
  else
    fail "copy_dotfiles lxqt foreign $wl_foreign_kind ~/.wayland-session (intact=$wl_foreign_intact, output=$wl_sw_foreign_out)"
  fi
done

# 77d: post-install edits use preserve_dotfile's numbered save without overwriting the original backup
wl_sw_edited="$wl_switch_dir/home_edited"
mkdir -p "$wl_sw_edited"
printf '#!/bin/bash\nexec river\n' >"$wl_sw_edited/.wayland-session"
chmod 755 "$wl_sw_edited/.wayland-session"
cp "$wl_sw_edited/.wayland-session" "$wl_sw_edited/wayland.expected"
HOME="$wl_sw_edited" copy_dotfiles plasma 2>/dev/null
printf '# post-install edit\n' >>"$wl_sw_edited/.wayland-session"
cp "$wl_sw_edited/.wayland-session" "$wl_sw_edited/edited.expected"
printf '# previous saved edit\n' >"$wl_sw_edited/.wayland-session.lightxdm-edited"
wl_sw_edited_out="$(HOME="$wl_sw_edited" copy_dotfiles xfce 2>&1)"
if [[ ! -e "$wl_sw_edited/.wayland-session" && ! -L "$wl_sw_edited/.wayland-session" &&
  "$(cat "$wl_sw_edited/.wayland-session.lightxdm-edited")" == '# previous saved edit' &&
  "$wl_sw_edited_out" == *"Saving edited $wl_sw_edited/.wayland-session to $wl_sw_edited/.wayland-session.lightxdm-edited.1"* ]] &&
  cmp -s "$wl_sw_edited/wayland.expected" "$wl_sw_edited/.wayland-session.lightxdm.bak" &&
  cmp -s "$wl_sw_edited/edited.expected" "$wl_sw_edited/.wayland-session.lightxdm-edited.1"; then
  pass "copy_dotfiles xfce saves Wayland edits in .lightxdm-edited.1 and keeps the original backup intact"
else
  fail "copy_dotfiles xfce with edited Wayland session (output=$wl_sw_edited_out)"
fi

# 77e: uninstall restores the user's session byte-identically after switching to X11
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh restores Wayland sessions after X11 installs (unshare -r unavailable)"
else
  for wl_roundtrip_kind in with_bak foreign_regular foreign_symlink edited; do
    wl_roundtrip_home="$wl_switch_dir/home_$wl_roundtrip_kind"
    set +e
    output="$(env TARGET_HOME="$wl_roundtrip_home" LOGIN_FILE="$wl_switch_dir/login" \
      GNOME_SESSION_TYPE_DEST="$wl_switch_dir/gnome-session-type.conf" \
      OVERRIDE_DIR="$wl_switch_dir/getty.d" \
      POLKIT_RULE="$wl_switch_dir/polkit.rules" DM_STATE_FILE="$wl_switch_dir/dm" \
      unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
    status=$?
    set -e
    wl_restored_type=0
    if [[ "$wl_roundtrip_kind" == foreign_symlink ]]; then
      if [[ -L "$wl_roundtrip_home/.wayland-session" &&
        "$(readlink "$wl_roundtrip_home/.wayland-session")" == "$(readlink "$wl_roundtrip_home/wayland.expected")" ]]; then
        wl_restored_type=1
      fi
    elif [[ -f "$wl_roundtrip_home/.wayland-session" && ! -L "$wl_roundtrip_home/.wayland-session" ]]; then
      wl_restored_type=1
    fi
    if [[ $status -eq 0 && $wl_restored_type -eq 1 && -x "$wl_roundtrip_home/.wayland-session" &&
      ! -e "$wl_roundtrip_home/.wayland-session.lightxdm.bak" &&
      ! -L "$wl_roundtrip_home/.wayland-session.lightxdm.bak" &&
      ! -e "$wl_roundtrip_home/.wayland-session.lightxdm.absent" ]] &&
      cmp -s "$wl_roundtrip_home/wayland.expected" "$wl_roundtrip_home/.wayland-session" &&
      { [[ "$wl_roundtrip_kind" != edited ]] ||
        cmp -s "$wl_roundtrip_home/edited.expected" "$wl_roundtrip_home/.wayland-session.lightxdm-edited.1"; }; then
      pass "uninstall.sh restores the original Wayland session byte-identically after X11 ($wl_roundtrip_kind)"
    else
      fail "uninstall.sh Wayland to X11 round trip ($wl_roundtrip_kind, status=$status, output=$output)"
    fi
  done
fi

# 77f: main's X11 auto-start summary agrees with the real dotfiles installed on disk
for wl_previous_session in foreign plasma gnome budgie; do
  wl_summary_home="$wl_switch_dir/summary_$wl_previous_session"
  mkdir -p "$wl_summary_home"
  printf '#!/bin/bash\nexec custom-user-compositor\n' >"$wl_summary_home/.wayland-session"
  chmod 755 "$wl_summary_home/.wayland-session"
  cp "$wl_summary_home/.wayland-session" "$wl_summary_home/wayland.expected"
  if [[ "$wl_previous_session" != foreign ]]; then
    HOME="$wl_summary_home" copy_dotfiles "$wl_previous_session" 2>/dev/null
  fi
  set +e
  output="$(
    export HOME="$wl_summary_home" USER=testuser PATH="$bash_stub_dir:$sudo_pw_dir:$PATH"
    # shellcheck disable=SC2317,SC2329  # overrides are called indirectly through main
    configure_gnome_session_type() { :; }
    # shellcheck disable=SC2317,SC2329
    disable_display_managers() { :; }
    main --de i3 --no-packages --no-keyring --no-polkit-rule 2>&1
  )"
  status=$?
  set -e
  if [[ $status -eq 0 && "$output" == *"- i3 will auto-start on TTY1 for testuser"* &&
    "$output" == *"No need to run 'startx'."* && -x "$wl_summary_home/.xinitrc" &&
    ! -e "$wl_summary_home/.wayland-session" && ! -L "$wl_summary_home/.wayland-session" &&
    ! -x "$wl_summary_home/.wayland-session" ]] &&
    cmp -s "$wl_summary_home/wayland.expected" "$wl_summary_home/.wayland-session.lightxdm.bak"; then
    pass "main reports i3 auto-start with no Wayland session left on the startup path (after $wl_previous_session)"
  else
    fail "main X11 auto-start after $wl_previous_session (status=$status, output=$output)"
  fi
done

# Case 77g: copy_dotfiles logs when a user session template overrides the bundled one
user_tmpl_log_dir="$TMP_DIR/user_template_log"
user_tmpl_custom_home="$user_tmpl_log_dir/home_custom"
mkdir -p "$user_tmpl_custom_home/.config/lightxdm"
cp "$REPO_ROOT/dotfiles/.xinitrc-xfce" "$user_tmpl_custom_home/.config/lightxdm/.xinitrc-xfce"
echo "# user template modification" >>"$user_tmpl_custom_home/.config/lightxdm/.xinitrc-xfce"

user_tmpl_custom_out="$(
  export HOME="$user_tmpl_custom_home"
  export USER="testuser"
  copy_dotfiles "xfce" 2>&1
)"

user_tmpl_fresh_home="$user_tmpl_log_dir/home_fresh"
mkdir -p "$user_tmpl_fresh_home"
user_tmpl_fresh_out="$(
  export HOME="$user_tmpl_fresh_home"
  export USER="testuser"
  copy_dotfiles "xfce" 2>&1
)"

if [[ "$user_tmpl_custom_out" == *"Using your session template $user_tmpl_custom_home/.config/lightxdm/.xinitrc-xfce"* &&
  "$user_tmpl_fresh_out" != *"Using your session template"* ]]; then
  pass "copy_dotfiles logs when using a user session template and stays quiet for bundled templates"
else
  fail "copy_dotfiles session template logging (custom_out=$user_tmpl_custom_out, fresh_out=$user_tmpl_fresh_out)"
fi

# Case 78: main refuses when Wayland template is ~/.wayland-session itself, and backs up a symlink ~/.wayland-session pointing to the template
wl_self_dir="$TMP_DIR/wayland_self_guard"
wl_self_home="$wl_self_dir/home_self"
mkdir -p "$wl_self_home/.config/lightxdm"
cp "$REPO_ROOT/dotfiles/.wayland-session-plasma" "$wl_self_home/.wayland-session"
wl_self_hash="$(sha256sum < "$wl_self_home/.wayland-session")"
ln -s ../../.wayland-session "$wl_self_home/.config/lightxdm/.wayland-session-plasma"
: >"$STUB_LOG"
set +e
wl_self_out="$(HOME="$wl_self_home" run_main_with_stubs "$sudo_pw_dir" --no-packages --de plasma 2>&1)"
wl_self_st=$?
set -e
wl_self_log="$(cat "$STUB_LOG")"
if [[ $wl_self_st -eq 1 && "$wl_self_out" == *"template for plasma is ~/.wayland-session itself"* &&
  ! -L "$wl_self_home/.wayland-session" &&
  "$(sha256sum < "$wl_self_home/.wayland-session")" == "$wl_self_hash" &&
  ! -e "$wl_self_home/.wayland-session.lightxdm.bak" && ! -e "$wl_self_home/.wayland-session.lightxdm.absent" &&
  "$wl_self_log" == "sudo -v" ]]; then
  pass "main rejects a Wayland user template pointing to ~/.wayland-session itself without changing ~/.wayland-session"
else
  fail "main self-guard for ~/.wayland-session (status=$wl_self_st, log=$wl_self_log, output=$wl_self_out)"
fi

wl_link_home="$wl_self_dir/home_link_to_tmpl"
mkdir -p "$wl_link_home"
ln -s "$REPO_ROOT/dotfiles/.wayland-session-plasma" "$wl_link_home/.wayland-session"
printf '#%%PAM-1.0\n' >"$wl_self_dir/login"
set +e
wl_link_out="$(
  env -u SHELLOPTS -u SUDO_USER \
    HOME="$wl_link_home" \
    SESSION_ROOT="$SESSION_ROOT" \
    PATH="$sudo_pw_dir:$STUB_BIN:$PATH" \
    USER="testuser" \
    LOGIN_FILE="$wl_self_dir/login" \
    POLKIT_RULE_DEST="$wl_self_dir/polkit" \
    DISPLAY_MANAGER_LINK="$wl_self_dir/display-manager.service" \
    DM_STATE_FILE="$wl_self_dir/state/disabled-display-managers" \
    bash "$REPO_ROOT/install.sh" --no-packages --de plasma 2>&1
)"
wl_link_st=$?
set -e
if [[ $wl_link_st -eq 0 && -x "$wl_link_home/.wayland-session" && ! -L "$wl_link_home/.wayland-session" &&
  -L "$wl_link_home/.wayland-session.lightxdm.bak" &&
  "$(readlink "$wl_link_home/.wayland-session.lightxdm.bak")" == "$REPO_ROOT/dotfiles/.wayland-session-plasma" ]]; then
  pass "install.sh replaces ~/.wayland-session linked to the selected Wayland template and backs up the symlink"
else
  fail "install.sh ~/.wayland-session linked to selected template (status=$wl_link_st, output=$wl_link_out)"
fi

# Case 79: uninstall.sh removes lightXDM ~/.wayland-session, restores backed-up ~/.wayland-session, and keeps foreign ~/.wayland-session
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh ~/.wayland-session remove/restore/keep handling (unshare -r unavailable)"
else
  wl_u_dir="$TMP_DIR/uninstall_wayland_session"
  wl_u_bundled="$wl_u_dir/home_bundled"
  wl_u_user="$wl_u_dir/home_user_override"
  wl_u_bak="$wl_u_dir/home_bak"
  wl_u_foreign="$wl_u_dir/home_foreign"
  mkdir -p "$wl_u_bundled" "$wl_u_user/.config/lightxdm" "$wl_u_bak" "$wl_u_foreign"

  # Bundled template without markers (legacy / direct copy) and with .absent marker
  cp "$REPO_ROOT/dotfiles/.wayland-session-plasma" "$wl_u_bundled/.wayland-session"
  chmod 755 "$wl_u_bundled/.wayland-session"

  # User override template with .absent marker
  printf '#!/bin/bash\n# user plasma override\nexec /usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasma-wayland\n' >"$wl_u_user/.config/lightxdm/.wayland-session-plasma"
  chmod 755 "$wl_u_user/.config/lightxdm/.wayland-session-plasma"
  (
    export HOME="$wl_u_user"
    export USER="testuser"
    copy_dotfiles "plasma" 2>/dev/null
  )

  # Backed-up pre-existing ~/.wayland-session with a post-install edit
  printf '#!/bin/bash\nexec river\n' >"$wl_u_bak/.wayland-session"
  chmod 755 "$wl_u_bak/.wayland-session"
  (
    export HOME="$wl_u_bak"
    export USER="testuser"
    copy_dotfiles "plasma" 2>/dev/null
  )
  echo "# post-install wayland edit" >>"$wl_u_bak/.wayland-session"
  wl_u_expected_edit="$(cat "$wl_u_bak/.wayland-session")"

  # Foreign ~/.wayland-session with no backup/marker
  printf '#!/bin/bash\nexec hyprland\n' >"$wl_u_foreign/.wayland-session"
  chmod 755 "$wl_u_foreign/.wayland-session"

  set +e
  out_wlu_bundled="$(env TARGET_HOME="$wl_u_bundled" LOGIN_FILE="$wl_u_dir/l1" OVERRIDE_DIR="$wl_u_dir/getty.d" POLKIT_RULE="$wl_u_dir/p1" DM_STATE_FILE="$wl_u_dir/d1" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  st_wlu_bundled=$?
  out_wlu_user="$(env TARGET_HOME="$wl_u_user" LOGIN_FILE="$wl_u_dir/l2" OVERRIDE_DIR="$wl_u_dir/getty.d" POLKIT_RULE="$wl_u_dir/p2" DM_STATE_FILE="$wl_u_dir/d2" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  st_wlu_user=$?
  out_wlu_bak1="$(env TARGET_HOME="$wl_u_bak" LOGIN_FILE="$wl_u_dir/l3" OVERRIDE_DIR="$wl_u_dir/getty.d" POLKIT_RULE="$wl_u_dir/p3" DM_STATE_FILE="$wl_u_dir/d3" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  st_wlu_bak1=$?
  out_wlu_bak2="$(env TARGET_HOME="$wl_u_bak" LOGIN_FILE="$wl_u_dir/l3" OVERRIDE_DIR="$wl_u_dir/getty.d" POLKIT_RULE="$wl_u_dir/p3" DM_STATE_FILE="$wl_u_dir/d3" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  st_wlu_bak2=$?
  out_wlu_foreign="$(env TARGET_HOME="$wl_u_foreign" LOGIN_FILE="$wl_u_dir/l4" OVERRIDE_DIR="$wl_u_dir/getty.d" POLKIT_RULE="$wl_u_dir/p4" DM_STATE_FILE="$wl_u_dir/d4" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  st_wlu_foreign=$?
  set -e

  if [[ $st_wlu_bundled -eq 0 && ! -e "$wl_u_bundled/.wayland-session" ]] &&
    [[ $st_wlu_user -eq 0 && ! -e "$wl_u_user/.wayland-session" && ! -e "$wl_u_user/.wayland-session.lightxdm.absent" &&
      -f "$wl_u_user/.config/lightxdm/.wayland-session-plasma" ]] &&
    [[ $st_wlu_bak1 -eq 0 && $st_wlu_bak2 -eq 0 &&
      -f "$wl_u_bak/.wayland-session" && "$(cat "$wl_u_bak/.wayland-session")" == $'#!/bin/bash\nexec river' &&
      ! -e "$wl_u_bak/.wayland-session.lightxdm.bak" &&
      -f "$wl_u_bak/.wayland-session.lightxdm-edited" && "$(cat "$wl_u_bak/.wayland-session.lightxdm-edited")" == "$wl_u_expected_edit" &&
      "$out_wlu_bak2" == *"Keeping $wl_u_bak/.wayland-session"* ]] &&
    [[ $st_wlu_foreign -eq 0 && -f "$wl_u_foreign/.wayland-session" &&
      "$(cat "$wl_u_foreign/.wayland-session")" == $'#!/bin/bash\nexec hyprland' &&
      "$out_wlu_foreign" == *"Keeping $wl_u_foreign/.wayland-session"* ]]; then
    pass "uninstall.sh removes lightXDM ~/.wayland-session, restores backed-up ~/.wayland-session (saving edits), and keeps foreign ~/.wayland-session"
  else
    fail "uninstall.sh ~/.wayland-session handling (b=$st_wlu_bundled:$out_wlu_bundled | u=$st_wlu_user:$out_wlu_user | bak1=$st_wlu_bak1:$out_wlu_bak1 | bak2=$st_wlu_bak2:$out_wlu_bak2 | f=$st_wlu_foreign:$out_wlu_foreign)"
  fi
fi

# Case 79b: uninstall.sh recognizes the GNOME and Budgie Wayland templates without special cases
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh GNOME and Budgie Wayland templates (unshare -r unavailable)"
else
  for wl_uninstall_de in gnome budgie; do
    for wl_uninstall_mode in bundled installed override; do
      wl_uninstall_home="$TMP_DIR/uninstall_${wl_uninstall_de}_$wl_uninstall_mode"
      mkdir -p "$wl_uninstall_home"
      if [[ "$wl_uninstall_mode" == bundled ]]; then
        cp "$REPO_ROOT/dotfiles/.wayland-session-$wl_uninstall_de" "$wl_uninstall_home/.wayland-session"
      else
        if [[ "$wl_uninstall_mode" == override ]]; then
          mkdir -p "$wl_uninstall_home/.config/lightxdm"
          cp "$REPO_ROOT/dotfiles/.wayland-session-$wl_uninstall_de" "$wl_uninstall_home/.config/lightxdm/.wayland-session-$wl_uninstall_de"
          echo '# user session override' >>"$wl_uninstall_home/.config/lightxdm/.wayland-session-$wl_uninstall_de"
        fi
        HOME="$wl_uninstall_home" copy_dotfiles "$wl_uninstall_de" 2>/dev/null
      fi
      set +e
      output="$(env TARGET_HOME="$wl_uninstall_home" LOGIN_FILE="$TMP_DIR/wl_uninstall_login" \
        OVERRIDE_DIR="$TMP_DIR/wl_uninstall_getty.d" \
        POLKIT_RULE="$TMP_DIR/wl_uninstall_polkit" DM_STATE_FILE="$TMP_DIR/wl_uninstall_dm" \
        unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
      status=$?
      set -e
      if [[ $status -eq 0 && ! -e "$wl_uninstall_home/.wayland-session" &&
        ! -e "$wl_uninstall_home/.wayland-session.lightxdm.absent" &&
        ! -e "$wl_uninstall_home/.wayland-session.lightxdm-edited" &&
        ! -e "$wl_uninstall_home/.bash_profile" && ! -e "$wl_uninstall_home/.gpg-agent-gnome" ]] &&
        { [[ "$wl_uninstall_mode" != override ]] ||
          [[ -f "$wl_uninstall_home/.config/lightxdm/.wayland-session-$wl_uninstall_de" ]]; }; then
        pass "uninstall.sh removes the $wl_uninstall_mode $wl_uninstall_de Wayland session and its installed dotfiles"
      else
        fail "uninstall.sh $wl_uninstall_de Wayland ($wl_uninstall_mode, status=$status, output=$output)"
      fi
    done
  done
fi

# GNOME needs the session type in PAM before system-local-login reaches pam_systemd.
rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak" "$GNOME_SESSION_TYPE_DEST"
write_stock_login
cp "$LOGIN_FILE" "$TMP_DIR/gnome-original"
gnome_marker='# lightXDM: GNOME on TTY1 needs a wayland session type (uninstall.sh removes this)'
gnome_user='Test_i.9-user'
cat >"$TMP_DIR/gnome-expected" <<EOF
#%PAM-1.0

auth       requisite    pam_nologin.so
auth       include      system-local-login
account    include      system-local-login
$gnome_marker
session    [success=2 default=ignore] pam_succeed_if.so quiet tty notin tty1:/dev/tty1
session    [success=1 default=ignore] pam_succeed_if.so quiet user != $gnome_user
session    optional   pam_env.so readenv=0 user_readenv=0 conffile=$GNOME_SESSION_TYPE_DEST
session    include      system-local-login
password   include      system-local-login
EOF
configure_gnome_session_type gnome "$gnome_user" 2>/dev/null || fail "configure_gnome_session_type gnome \"$gnome_user\" returned $?"
if cmp -s "$LOGIN_FILE" "$TMP_DIR/gnome-expected" &&
  cmp -s "${LOGIN_FILE}.lightxdm.bak" "$TMP_DIR/gnome-original" &&
  cmp -s "$GNOME_SESSION_TYPE_DEST" "$REPO_ROOT/pam/gnome-session-type.conf" &&
  [[ "$(stat -c %a "$GNOME_SESSION_TYPE_DEST")" == 644 &&
    "$(cat "$GNOME_SESSION_TYPE_DEST")" == $'# '*$'\nXDG_SESSION_TYPE DEFAULT=wayland' &&
    "$(wc -l < "$GNOME_SESSION_TYPE_DEST")" -eq 2 ]]; then
  pass "GNOME installs the exact TTY1 PAM block before the first Arch session line and its mode 644 config"
else
  fail "GNOME PAM block, config, permissions or pristine backup differ from expected"
fi

gnome_stat="$(stat -c '%y %z %i' "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak" "$GNOME_SESSION_TYPE_DEST" 2>&1 || true)"
configure_gnome_session_type gnome "$gnome_user" 2>/dev/null || fail "configure_gnome_session_type gnome \"$gnome_user\" returned $?"
if cmp -s "$LOGIN_FILE" "$TMP_DIR/gnome-expected" &&
  [[ "$gnome_stat" == "$(stat -c '%y %z %i' "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak" "$GNOME_SESSION_TYPE_DEST")" ]]; then
  pass "GNOME session-type configuration is idempotent without rewriting any files"
else
  fail "GNOME session-type configuration rewrites files on a second run"
fi

configure_gnome_session_type gnome another.user 2>/dev/null || fail "configure_gnome_session_type gnome another.user returned $?"
configure_gnome_session_type gnome "$gnome_user" 2>/dev/null || fail "configure_gnome_session_type gnome \"$gnome_user\" returned $?"
if cmp -s "$LOGIN_FILE" "$TMP_DIR/gnome-expected" &&
  cmp -s "${LOGIN_FILE}.lightxdm.bak" "$TMP_DIR/gnome-original"; then
  pass "GNOME replaces another user's block without duplicating it or overwriting the original backup"
else
  fail "GNOME failed to replace another user's block"
fi

for gnome_bad_user in '' '-testuser' 'test user' 'test/user' 'test;user' "test\$user" 'test[user]' $'test\nuser' $'us\u00e9r'; do
  set +e
  output="$(configure_gnome_session_type gnome "$gnome_bad_user" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 1 && "$output" == *"Invalid user name:"* ]] &&
    cmp -s "$LOGIN_FILE" "$TMP_DIR/gnome-expected" &&
    cmp -s "$GNOME_SESSION_TYPE_DEST" "$REPO_ROOT/pam/gnome-session-type.conf" &&
    cmp -s "${LOGIN_FILE}.lightxdm.bak" "$TMP_DIR/gnome-original"; then
    pass "GNOME refuses invalid user name $(printf '%q' "$gnome_bad_user") without changing files"
  else
    fail "GNOME invalid user name (status=$status, output=$output)"
  fi
done

configure_gnome_session_type xfce "$gnome_user" 2>/dev/null || fail "configure_gnome_session_type xfce \"$gnome_user\" returned $?"
output="$(configure_gnome_session_type xfce "$gnome_user" 2>&1)"
if cmp -s "$LOGIN_FILE" "$TMP_DIR/gnome-original" &&
  [[ ! -e "$GNOME_SESSION_TYPE_DEST" && -z "$output" ]]; then
  pass "Switching to XFCE removes the GNOME block and config and is then a quiet no-op"
else
  fail "Switching to XFCE did not clean up GNOME session-type configuration (output=$output)"
fi

# An inserted line inside the marked block must stop both a rewrite and removal.
configure_gnome_session_type gnome "$gnome_user" 2>/dev/null || fail "configure_gnome_session_type gnome \"$gnome_user\" returned $?"
sed -i '/^session    \[success=2 default=ignore\] pam_succeed_if\.so quiet tty notin tty1:\/dev\/tty1$/a # user comment inside the GNOME block' "$LOGIN_FILE"
for gnome_edited_de in gnome xfce; do
  cp "$LOGIN_FILE" "$TMP_DIR/gnome-edited-login"
  cp "$GNOME_SESSION_TYPE_DEST" "$TMP_DIR/gnome-edited-config"
  cp "${LOGIN_FILE}.lightxdm.bak" "$TMP_DIR/gnome-edited-backup"
  set +e
  output="$(configure_gnome_session_type "$gnome_edited_de" "$gnome_user" 2>&1)"
  status=$?
  set -e
  if [[ $status -ne 0 && "$output" == *"ERROR:"* && "$output" == *"$LOGIN_FILE"* &&
    "$output" == *"remove lightXDM's GNOME lines by hand"* && "$output" == *"restore ${LOGIN_FILE}.lightxdm.bak"* ]] &&
    cmp -s "$LOGIN_FILE" "$TMP_DIR/gnome-edited-login" &&
    cmp -s "$GNOME_SESSION_TYPE_DEST" "$TMP_DIR/gnome-edited-config" &&
    cmp -s "${LOGIN_FILE}.lightxdm.bak" "$TMP_DIR/gnome-edited-backup"; then
    pass "$gnome_edited_de refuses an edited GNOME block without changing files"
  else
    fail "$gnome_edited_de edited GNOME block (status=$status, output=$output)"
  fi
  : >"$STUB_LOG"
  set +e
  output="$(env -u SHELLOPTS -u SUDO_USER HOME="$dr_preview_home" USER="$gnome_user" \
    PATH="$dr_bin:$PATH" LOGIN_FILE="$LOGIN_FILE" \
    GNOME_SESSION_TYPE_DEST="$GNOME_SESSION_TYPE_DEST" DM_STATE_FILE="$TMP_DIR/gnome-preview-dm" \
    DISPLAY_MANAGER_LINK="$TMP_DIR/gnome-preview-display-manager" \
    AUTOLOGIN_DROPIN_DIR="$TMP_DIR/gnome-preview-getty.d" \
    bash "$REPO_ROOT/install.sh" --dry-run --de "$gnome_edited_de" 2>&1)"
  status=$?
  set -e
  if [[ $status -ne 0 && "$output" == *"ERROR: Edited lightXDM GNOME block in $LOGIN_FILE; remove lightXDM's GNOME lines by hand or restore ${LOGIN_FILE}.lightxdm.bak."* ]] &&
    ! grep -q '^sudo ' "$STUB_LOG" &&
    cmp -s "$LOGIN_FILE" "$TMP_DIR/gnome-edited-login" &&
    cmp -s "$GNOME_SESSION_TYPE_DEST" "$TMP_DIR/gnome-edited-config" &&
    cmp -s "${LOGIN_FILE}.lightxdm.bak" "$TMP_DIR/gnome-edited-backup"; then
    pass "$gnome_edited_de dry-run refuses an edited GNOME block without sudo or file changes"
  else
    fail "$gnome_edited_de dry-run edited GNOME block (status=$status, output=$output)"
  fi
done
cp "$TMP_DIR/gnome-original" "$LOGIN_FILE"
rm -f "$GNOME_SESSION_TYPE_DEST"

# A missing session stack must not produce a backup, config or login edit.
rm -f "${LOGIN_FILE}.lightxdm.bak"
printf '#%%PAM-1.0\nauth include system-local-login\n' >"$LOGIN_FILE"
cp "$LOGIN_FILE" "$TMP_DIR/gnome-no-session"
set +e
output="$(configure_gnome_session_type gnome "$gnome_user" 2>&1)"
status=$?
set -e
if [[ $status -eq 1 && "$output" == *"ERROR:"* && "$output" == *"$LOGIN_FILE"* &&
  ! -e "${LOGIN_FILE}.lightxdm.bak" && ! -e "$GNOME_SESSION_TYPE_DEST" ]] &&
  cmp -s "$LOGIN_FILE" "$TMP_DIR/gnome-no-session"; then
  pass "GNOME refuses a login file without a session line and changes nothing"
else
  fail "GNOME missing session line (status=$status, output=$output)"
fi
: >"$STUB_LOG"
set +e
output="$(env -u SHELLOPTS -u SUDO_USER HOME="$dr_preview_home" USER="$gnome_user" \
  PATH="$dr_bin:$PATH" LOGIN_FILE="$LOGIN_FILE" \
  GNOME_SESSION_TYPE_DEST="$GNOME_SESSION_TYPE_DEST" DM_STATE_FILE="$TMP_DIR/gnome-no-session-dm" \
  DISPLAY_MANAGER_LINK="$TMP_DIR/gnome-no-session-display-manager" \
  AUTOLOGIN_DROPIN_DIR="$TMP_DIR/gnome-no-session-getty.d" \
  bash "$REPO_ROOT/install.sh" --dry-run --no-keyring --de gnome 2>&1)"
status=$?
set -e
if [[ $status -ne 0 && "$output" == *"ERROR: No session line in $LOGIN_FILE; lightXDM will not change it."* &&
  ! -e "${LOGIN_FILE}.lightxdm.bak" && ! -e "$GNOME_SESSION_TYPE_DEST" &&
  ! -e "$TMP_DIR/gnome-no-session-dm" && ! -e "$TMP_DIR/gnome-no-session-getty.d" ]] &&
  ! grep -q '^sudo ' "$STUB_LOG" && cmp -s "$LOGIN_FILE" "$TMP_DIR/gnome-no-session"; then
  pass "GNOME dry-run without keyring refuses a missing session line without sudo or file changes"
else
  fail "GNOME dry-run missing session line (status=$status, output=$output)"
fi

# Preserve whitespace and a missing final newline, including with a -session entry.
printf '#%%PAM-1.0\n\tauth include system-local-login\n  -session include system-local-login\npassword include system-local-login' >"$LOGIN_FILE"
cp "$LOGIN_FILE" "$TMP_DIR/gnome-no-newline"
configure_gnome_session_type gnome "$gnome_user" 2>/dev/null || fail "configure_gnome_session_type gnome \"$gnome_user\" returned $?"
if grep -Fxq -- "$gnome_marker" "$LOGIN_FILE" && [[ -n "$(tail -c 1 "$LOGIN_FILE")" ]]; then
  configure_gnome_session_type xfce "$gnome_user" 2>/dev/null || fail "configure_gnome_session_type xfce \"$gnome_user\" returned $?"
  if cmp -s "$LOGIN_FILE" "$TMP_DIR/gnome-no-newline"; then
    pass "GNOME handles an indented -session line and preserves every original byte without a final newline"
  else
    fail "GNOME changed original bytes when removing its block"
  fi
else
  fail "GNOME failed to handle -session or preserve a missing final newline"
fi

# Similar standalone module lines outside the marked block must survive a desktop switch.
rm -f "${LOGIN_FILE}.lightxdm.bak"
write_stock_login
printf '%s\n' \
  'session    [success=1 default=ignore] pam_succeed_if.so quiet user != preexisting-user' \
  'session    optional   pam_env.so readenv=0 user_readenv=0 conffile=/user/session-type.conf' >>"$LOGIN_FILE"
cp "$LOGIN_FILE" "$TMP_DIR/gnome-standalone"
configure_gnome_session_type gnome "$gnome_user" 2>/dev/null || fail "configure_gnome_session_type gnome \"$gnome_user\" returned $?"
configure_gnome_session_type xfce "$gnome_user" 2>/dev/null || fail "configure_gnome_session_type xfce \"$gnome_user\" returned $?"
if cmp -s "$LOGIN_FILE" "$TMP_DIR/gnome-standalone"; then
  pass "GNOME installation and desktop switching preserve standalone module lines outside the marked block"
else
  fail "GNOME configuration changed standalone module lines outside its block"
fi

# Fail each privileged write independently while allowing the backup copy to run.
gnome_fail_bin="$TMP_DIR/gnome-fail-bin"
mkdir -p "$gnome_fail_bin"
cat >"$gnome_fail_bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "$GNOME_FAIL_CMD" ]]; then
  exit 1
fi
exec "$@"
EOF
chmod +x "$gnome_fail_bin/sudo"

rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak" "$GNOME_SESSION_TYPE_DEST"
write_stock_login
cp "$LOGIN_FILE" "$TMP_DIR/gnome-failure-stock"
set +e
( export PATH="$gnome_fail_bin:$PATH" GNOME_FAIL_CMD=install; configure_gnome_session_type gnome "$gnome_user" ) 2>/dev/null
gnome_install_status=$?
set -e
gnome_login_unchanged=0
cmp -s "$LOGIN_FILE" "$TMP_DIR/gnome-failure-stock" && gnome_login_unchanged=1
gnome_config_absent=0
[[ ! -e "$GNOME_SESSION_TYPE_DEST" ]] && gnome_config_absent=1

rm -f "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak" "$GNOME_SESSION_TYPE_DEST"
write_stock_login
cp "$LOGIN_FILE" "$TMP_DIR/gnome-failure-stock"
set +e
( export PATH="$gnome_fail_bin:$PATH" GNOME_FAIL_CMD=tee; configure_gnome_session_type gnome "$gnome_user" ) 2>/dev/null
gnome_tee_status=$?
set -e
if [[ $gnome_install_status -ne 0 && $gnome_tee_status -ne 0 &&
  $gnome_login_unchanged -eq 1 && $gnome_config_absent -eq 1 ]]; then
  pass "GNOME session-type configuration stops when install or login write fails"
else
  fail "GNOME write failures (install status=$gnome_install_status, tee status=$gnome_tee_status, stock login unchanged=$gnome_login_unchanged, config absent=$gnome_config_absent)"
fi

# Exercise the real step through main with --no-keyring; all privileged calls use stubs.
rm -f "${LOGIN_FILE}.lightxdm.bak"
write_stock_login
mkdir -p "$TMP_DIR/gnome-main-home"
set +e
# shellcheck disable=SC2317,SC2329  # overrides are called through main
output="$(
  exec 2>&1
  export HOME="$TMP_DIR/gnome-main-home" USER="$gnome_user" PATH="$sudo_pw_dir:$PATH"
  check_root() { :; }
  copy_dotfiles() { :; }
  disable_display_managers() { :; }
  main --de gnome --no-packages --no-keyring --no-polkit-rule
)"
status=$?
set -e
if [[ $status -eq 0 && "$output" == *"lightXDM install complete!"* &&
  "$output" == *"Skipping keyring PAM configuration"* && -f "$GNOME_SESSION_TYPE_DEST" ]] &&
  cmp -s "$LOGIN_FILE" "$TMP_DIR/gnome-expected"; then
  pass "main runs the real GNOME session-type step even with --no-keyring"
else
  fail "main GNOME --no-keyring (status=$status, output=$output)"
fi

# The session-type step follows keyring PAM configuration in the main step order.
: >"$STUB_LOG"
output="$(USER="$gnome_user" STUB_RECORD_GNOME_STEP=1 run_main_with_stubs "$sudo_pw_dir" --de gnome 2>&1)"
if [[ "$(cat "$STUB_LOG")" == *$'configure_pam gnome\nconfigure_gnome_session_type gnome '"$gnome_user"$'\ndisable_display_managers'* ]]; then
  pass "main runs configure_gnome_session_type as its own step immediately after configure_pam"
else
  fail "main GNOME session-type step order (log=$(cat "$STUB_LOG"), output=$output)"
fi

output_gnome="$(USER="$gnome_user" run_main_with_stubs "$sudo_pw_dir" --de gnome --no-keyring 2>&1)"
output_xfce="$(USER="$gnome_user" run_main_with_stubs "$sudo_pw_dir" --de xfce --no-keyring 2>&1)"
if [[ "$output_gnome" == *"GNOME cannot lock the screen without GDM"* &&
  "$output_xfce" != *"GNOME cannot lock the screen without GDM"* ]]; then
  pass "main warns that GNOME cannot lock the screen without GDM and omits warning for xfce"
else
  fail "main GNOME screen-lock warning (gnome output=$output_gnome, xfce output=$output_xfce)"
fi

if [[ $can_unshare -eq 0 ]]; then
  skip "GNOME session-type uninstall modes (unshare -r unavailable)"
else
  # Add keyring lines after the block to verify --keyring-only removes only those.
  configure_pam gnome 2>/dev/null
  gnome_uninstall_env=(env TARGET_HOME="$TMP_DIR/gnome-main-home" LOGIN_FILE="$LOGIN_FILE"
    GNOME_SESSION_TYPE_DEST="$GNOME_SESSION_TYPE_DEST" OVERRIDE_DIR="$TMP_DIR/gnome-getty.d"
    POLKIT_RULE="$TMP_DIR/gnome-polkit"
    DM_STATE_FILE="$TMP_DIR/gnome-dm/state")
  output="$("${gnome_uninstall_env[@]}" unshare -r bash "$REPO_ROOT/uninstall.sh" --keyring-only 2>&1)"
  if cmp -s "$LOGIN_FILE" "$TMP_DIR/gnome-expected" &&
    cmp -s "$GNOME_SESSION_TYPE_DEST" "$REPO_ROOT/pam/gnome-session-type.conf" &&
    [[ -f "${LOGIN_FILE}.lightxdm.bak" ]]; then
    pass "uninstall --keyring-only keeps the GNOME block, config and backup while removing keyring lines"
  else
    fail "uninstall --keyring-only changed GNOME session-type configuration (output=$output)"
  fi
  output="$("${gnome_uninstall_env[@]}" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  if cmp -s "$LOGIN_FILE" "$TMP_DIR/gnome-original" &&
    [[ ! -e "${LOGIN_FILE}.lightxdm.bak" && ! -e "$GNOME_SESSION_TYPE_DEST" ]]; then
    pass "uninstall removes the GNOME block and config and restores the login file byte-identical to its backup"
  else
    fail "uninstall GNOME restore (output=$output)"
  fi

  # Matching pre-existing lines belong to the user, including a different valid user.
  cp "$TMP_DIR/gnome-expected" "$LOGIN_FILE"
  cp "$LOGIN_FILE" "${LOGIN_FILE}.lightxdm.bak"
  # A user's own pam_env line for another conffile is not lightXDM's and must survive.
  printf '%s\n' 'session    [success=1 default=ignore] pam_succeed_if.so quiet user != another-user' 'session    optional   pam_env.so readenv=0 user_readenv=0 conffile=/user/session-type.conf' \
    "$gnome_marker extra" 'session    [success=1 default=ignore] pam_succeed_if.so quiet user != -invalid' >>"$LOGIN_FILE"
  cp "$TMP_DIR/gnome-expected" "$TMP_DIR/gnome-preexisting-expected"
  printf '%s\n' 'session    optional   pam_env.so readenv=0 user_readenv=0 conffile=/user/session-type.conf' "$gnome_marker extra" 'session    [success=1 default=ignore] pam_succeed_if.so quiet user != -invalid' >>"$TMP_DIR/gnome-preexisting-expected"
  output="$("${gnome_uninstall_env[@]}" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  if cmp -s "$LOGIN_FILE" "$TMP_DIR/gnome-preexisting-expected" && [[ -f "${LOGIN_FILE}.lightxdm.bak" ]]; then
    pass "uninstall preserves GNOME lines present in the backup, nonmatching lines and a user pam_env line for another conffile, removing only a newly added valid user gate"
  else
    fail "uninstall GNOME pre-existing and anchored-line handling (output=$output)"
  fi
fi

# An early VM driver crash must not reuse a previous run's successful result.
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  qemu_stale_bin="$TMP_DIR/qemu_stale/bin"
  qemu_stale_vm="$TMP_DIR/qemu_stale/vm"
  mkdir -p "$qemu_stale_bin" "$qemu_stale_vm/run-plasma"
  printf '%s\n' 'PASS: plasma: stale' 'DONE pass=1 fail=0' >"$qemu_stale_vm/run-plasma/result"

  cat >"$qemu_stale_bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == info ]]; then
  exit 0
elif [[ "$1" == run ]]; then
  touch "$LIGHTXDM_VM_DIR/BUILD_DONE"
  exit 0
fi
exit 1
EOF
  for qemu_stale_tool in qemu-system-x86_64 ssh; do
    cat >"$qemu_stale_bin/$qemu_stale_tool" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  done
  cat >"$qemu_stale_bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -f ]]; then
    touch "$2"
    exit 0
  fi
  shift
done
exit 0
EOF
  cat >"$qemu_stale_bin/python3" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$qemu_stale_bin/docker" "$qemu_stale_bin/qemu-system-x86_64" \
    "$qemu_stale_bin/ssh" "$qemu_stale_bin/ssh-keygen" "$qemu_stale_bin/python3"

  set +e
  output="$(
    export PATH="$qemu_stale_bin:$PATH" LIGHTXDM_VM_DIR="$qemu_stale_vm"
    bash "$REPO_ROOT/tests/qemu-arch.sh" plasma 2>&1
  )"
  status=$?
  set -e
  if [[ $status -eq 1 && "$output" == *"FAIL: plasma: the VM test did not finish"* &&
    "$output" != *"PASS: plasma: stale"* ]]; then
    pass "qemu-arch.sh rejects a stale result when the VM driver exits before writing a result"
  else
    fail "qemu-arch.sh stale result after early driver exit (status=$status, output=$output)"
  fi
else
  skip "qemu-arch.sh stale result after early driver exit (/dev/kvm is not accessible)"
fi
# A +package lane builds the package in a temporary clone that carries the staged and unstaged
# changes, hands it to the VM directory, and leaves the checkout's aur/ untouched.
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  qemu_pkg="$TMP_DIR/qemu_pkg"
  mkdir -p "$qemu_pkg/bin" "$qemu_pkg/vm" "$qemu_pkg/tmp"
  git clone --quiet "$REPO_ROOT" "$qemu_pkg/repo"
  cp -- "$REPO_ROOT/tests/qemu-arch.sh" "$qemu_pkg/repo/tests/qemu-arch.sh"
  echo "<!-- unstaged marker -->" >>"$qemu_pkg/repo/README.md"
  echo "staged marker" >"$qemu_pkg/repo/staged-new-file"
  git -C "$qemu_pkg/repo" add -- staged-new-file
  cat >"$qemu_pkg/bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == info ]]; then
  exit 0
elif [[ "$1" == run ]]; then
  touch "$LIGHTXDM_VM_DIR/BUILD_DONE"
  exit 0
fi
exit 1
EOF
  for qemu_pkg_tool in qemu-system-x86_64 ssh makepkg; do
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$qemu_pkg/bin/$qemu_pkg_tool"
  done
  cat >"$qemu_pkg/bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -f ]]; then
    touch "$2"
    exit 0
  fi
  shift
done
exit 0
EOF
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$qemu_pkg/bin/python3"
  cat >"$qemu_pkg/bin/aurgen" <<'EOF'
#!/usr/bin/env bash
{
  echo "cwd=$PWD"
  echo "args=$*"
  grep -q 'unstaged marker' README.md && echo "unstaged-change-present"
  git ls-files --error-unmatch staged-new-file >/dev/null 2>&1 && echo "new-file-tracked"
} >>"$AURGEN_STUB_LOG"
mkdir -p aur && echo "stub package" >aur/lightxdm-1.0.0-1-any.pkg.tar.zst
EOF
  chmod +x "$qemu_pkg"/bin/*
  set +e
  output="$(
    export PATH="$qemu_pkg/bin:$PATH" LIGHTXDM_VM_DIR="$qemu_pkg/vm" TMPDIR="$qemu_pkg/tmp" \
      AURGEN_STUB_LOG="$qemu_pkg/aurgen.log"
    bash "$qemu_pkg/repo/tests/qemu-arch.sh" xfce+package 2>&1
  )"
  status=$?
  set -e
  qemu_pkg_log="$(cat "$qemu_pkg/aurgen.log" 2>/dev/null || true)"
  if [[ "$output" == *"Building the lightxdm package"* &&
    "$(cat "$qemu_pkg/vm/lightxdm.pkg.tar.zst" 2>/dev/null)" == "stub package" &&
    "$qemu_pkg_log" == *"cwd=$qemu_pkg/tmp/"* && "$qemu_pkg_log" == *"args=--build-only local"* &&
    "$qemu_pkg_log" == *"unstaged-change-present"* && "$qemu_pkg_log" == *"new-file-tracked"* &&
    -z "$(git -C "$qemu_pkg/repo" status --porcelain --ignored -- aur)" && -z "$(ls -A "$qemu_pkg/tmp")" &&
    "$output" == *"FAIL: xfce+package: the VM test did not finish"* ]]; then
    pass "qemu-arch.sh +package builds the package in a temporary clone with the uncommitted changes and leaves aur/ untouched"
  else
    fail "qemu-arch.sh +package build (status=$status, aurgen=$qemu_pkg_log, output=$output)"
  fi
else
  skip "qemu-arch.sh +package build (/dev/kvm is not accessible)"
fi

# qemu-arch.sh reuses a matching image and rebuilds when given --rebuild-image.
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  qemu_rebuild_bin="$TMP_DIR/qemu_rebuild/bin"
  qemu_rebuild_vm="$TMP_DIR/qemu_rebuild/vm"
  qemu_rebuild_log="$TMP_DIR/qemu_rebuild/docker-runs.log"
  mkdir -p "$qemu_rebuild_bin" "$qemu_rebuild_vm"

  cat >"$qemu_rebuild_bin/docker" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == info ]]; then
  exit 0
elif [[ "\$1" == run ]]; then
  echo "run" >>"$qemu_rebuild_log"
  while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == -v ]]; then
      shift
      case "\${1%%:*}" in
        "$TMP_DIR/qemu_rebuild/"*) ;;
        *) touch "$TMP_DIR/qemu_rebuild/invalid-mount" ;;
      esac
    fi
    shift
  done
  touch "\$LIGHTXDM_VM_DIR/BUILD_DONE"
  exit 0
fi
exit 1
EOF
  for qemu_rebuild_tool in qemu-system-x86_64 ssh; do
    cat >"$qemu_rebuild_bin/$qemu_rebuild_tool" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  done
  cat >"$qemu_rebuild_bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -f ]]; then
    touch "$2"
    exit 0
  fi
  shift
done
exit 0
EOF
  cat >"$qemu_rebuild_bin/python3" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$qemu_rebuild_bin/docker" "$qemu_rebuild_bin/qemu-system-x86_64" \
    "$qemu_rebuild_bin/ssh" "$qemu_rebuild_bin/ssh-keygen" "$qemu_rebuild_bin/python3"

  set +e
  PATH="$qemu_rebuild_bin:$PATH" LIGHTXDM_VM_DIR="$qemu_rebuild_vm" \
    bash "$REPO_ROOT/tests/qemu-arch.sh" xfce >/dev/null 2>&1
  touch "$qemu_rebuild_vm/root.img"
  rm -f "$qemu_rebuild_log"
  PATH="$qemu_rebuild_bin:$PATH" LIGHTXDM_VM_DIR="$qemu_rebuild_vm" \
    bash "$REPO_ROOT/tests/qemu-arch.sh" xfce >/dev/null 2>&1
  reused_without_docker=0
  [[ ! -e "$qemu_rebuild_log" ]] && reused_without_docker=1
  PATH="$qemu_rebuild_bin:$PATH" LIGHTXDM_VM_DIR="$qemu_rebuild_vm" \
    bash "$REPO_ROOT/tests/qemu-arch.sh" --rebuild-image xfce >/dev/null 2>&1
  rebuilt_with_docker=0
  if [[ -f "$qemu_rebuild_log" ]] && grep -Fxq "run" "$qemu_rebuild_log"; then
    rebuilt_with_docker=1
  fi
  rm -f "$qemu_rebuild_log"
  (
    cd "$TMP_DIR/qemu_rebuild" || exit 1
    PATH="$qemu_rebuild_bin:$PATH" LIGHTXDM_VM_DIR=relative-vm \
      bash "$REPO_ROOT/tests/qemu-arch.sh" xfce >/dev/null 2>&1
  )
  relative_mounts_ok=0
  if [[ -f "$qemu_rebuild_log" && -f "$TMP_DIR/qemu_rebuild/relative-vm/build-image.sh" ]] &&
    grep -Fxq "run" "$qemu_rebuild_log" && [[ ! -e "$TMP_DIR/qemu_rebuild/invalid-mount" ]]; then
    relative_mounts_ok=1
  fi
  set -e
  if [[ $reused_without_docker -eq 1 && $rebuilt_with_docker -eq 1 ]]; then
    pass "qemu-arch.sh --rebuild-image forces image rebuild while a plain run reuses it"
  else
    fail "qemu-arch.sh --rebuild-image (reused=$reused_without_docker, rebuilt=$rebuilt_with_docker)"
  fi
  if [[ $relative_mounts_ok -eq 1 ]]; then
    pass "qemu-arch.sh resolves relative VM directory mounts"
  else
    fail "qemu-arch.sh resolves relative VM directory mounts"
  fi
else
  skip "qemu-arch.sh --rebuild-image (/dev/kvm is not accessible)"
fi

# A failing docker stub and a temporary VM dir keep a missed duplicate check from reaching real VMs.
qemu_dup_bin="$TMP_DIR/qemu_dup/bin"
mkdir -p "$qemu_dup_bin"
printf '#!/usr/bin/env bash\nexit 1\n' >"$qemu_dup_bin/docker"
chmod +x "$qemu_dup_bin/docker"
set +e
output="$(PATH="$qemu_dup_bin:$PATH" LIGHTXDM_VM_DIR="$TMP_DIR/qemu_dup/vm" \
  bash "$REPO_ROOT/tests/qemu-arch.sh" xfce xfce 2>"$TMP_DIR/qemu-duplicate-stderr")"
status=$?
set -e
if [[ $status -eq 1 && -z "$output" ]] &&
  grep -Fq 'Duplicate desktop: xfce' "$TMP_DIR/qemu-duplicate-stderr"; then
  pass "qemu-arch.sh rejects duplicate desktop specs"
else
  fail "qemu-arch.sh duplicate desktop (status=$status, stdout=$output, stderr=$(cat "$TMP_DIR/qemu-duplicate-stderr"))"
fi

# Missing integration prerequisites skip by default and fail in strict mode.
strict_int_dir="$TMP_DIR/strict_int"
mkdir -p "$strict_int_dir/bin"
cat >"$strict_int_dir/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"$STRICT_INT_DOCKER_LOG"
exit 1
EOF
chmod +x "$strict_int_dir/bin/docker"
strict_int_env=(env PATH="$strict_int_dir/bin:$PATH" LIGHTXDM_VM_DIR="$strict_int_dir/vm"
  STRICT_INT_DOCKER_LOG="$strict_int_dir/docker.log")

set +e
strict_default_output="$("${strict_int_env[@]}" bash "$REPO_ROOT/tests/docker-arch.sh" 2>&1)"
strict_default_status=$?
strict_flag_output="$("${strict_int_env[@]}" bash "$REPO_ROOT/tests/docker-arch.sh" --strict 2>&1)"
strict_flag_status=$?
strict_env_output="$("${strict_int_env[@]}" LIGHTXDM_STRICT_TESTS=1 bash "$REPO_ROOT/tests/docker-arch.sh" 2>&1)"
strict_env_status=$?
rm -f "$strict_int_dir/docker.log"
strict_help_output="$("${strict_int_env[@]}" bash "$REPO_ROOT/tests/docker-arch.sh" --help 2>&1)"
strict_help_status=$?
strict_help_no_docker=0
[[ ! -e "$strict_int_dir/docker.log" ]] && strict_help_no_docker=1
strict_unknown_output="$("${strict_int_env[@]}" bash "$REPO_ROOT/tests/docker-arch.sh" --bogus 2>&1)"
strict_unknown_status=$?
strict_unknown_no_docker=0
[[ ! -e "$strict_int_dir/docker.log" ]] && strict_unknown_no_docker=1
strict_qemu_output="$("${strict_int_env[@]}" bash "$REPO_ROOT/tests/qemu-arch.sh" --strict xfce 2>&1)"
strict_qemu_status=$?
set -e
if [[ $strict_default_status -eq 0 && "$strict_default_output" == *"SKIP: docker is unavailable"* &&
  $strict_flag_status -eq 1 && "$strict_flag_output" == *"SKIP: docker is unavailable"* &&
  $strict_env_status -eq 1 && "$strict_env_output" == *"SKIP: docker is unavailable"* &&
  $strict_help_status -eq 0 && "$strict_help_output" == *"Usage"* && $strict_help_no_docker -eq 1 &&
  $strict_unknown_status -eq 1 && "$strict_unknown_output" == *"Unknown argument: --bogus"* &&
  "$strict_unknown_output" == *"Usage"* && $strict_unknown_no_docker -eq 1 &&
  $strict_qemu_status -eq 1 && "$strict_qemu_output" == *"SKIP: "* &&
  "$strict_qemu_output" != *"Unknown desktop"* ]]; then
  pass "Docker and QEMU strict mode fails on skips; Docker help and unknown arguments avoid Docker"
else
  fail "Integration strict mode (default=$strict_default_status: $strict_default_output; flag=$strict_flag_status: $strict_flag_output; env=$strict_env_status: $strict_env_output; help=$strict_help_status, no Docker=$strict_help_no_docker: $strict_help_output; unknown=$strict_unknown_status, no Docker=$strict_unknown_no_docker: $strict_unknown_output; qemu=$strict_qemu_status: $strict_qemu_output)"
fi

# The package launchers run the right script with the right option; LIGHTXDM_DIR points them here.
launcher_report=""
for launcher_case in "lightxdm-install|--help|0|Usage: bash $REPO_ROOT/install.sh " \
  "lightxdm-update|--dry-run|1|No saved install choices in $TMP_DIR/launcher_home/" \
  "lightxdm-uninstall|--help|0|Usage: sudo bash $REPO_ROOT/uninstall.sh " \
  "lightxdm-autologin|--help|0|Usage: sudo bash $REPO_ROOT/enable-autologin.sh "; do
  IFS='|' read -r launcher launcher_arg launcher_status launcher_text <<<"$launcher_case"
  set +e
  launcher_out="$(cd / && HOME="$TMP_DIR/launcher_home" LIGHTXDM_DIR="$REPO_ROOT" "$REPO_ROOT/bin/$launcher" "$launcher_arg" 2>&1)"
  status=$?
  set -e
  if [[ $status -ne $launcher_status || "$launcher_out" != *"$launcher_text"* ]]; then
    launcher_report+=" [$launcher: status=$status, output=$launcher_out]"
  fi
done
if [[ -z "$launcher_report" ]]; then
  pass "the bin/ launchers run install.sh, install.sh --update, uninstall.sh and enable-autologin.sh"
else
  fail "package launchers:$launcher_report"
fi
# The pacman hook's note prints only while a login.pacnew and lightXDM's keyring record both exist.
note_dir="$TMP_DIR/pacnew_note"
mkdir -p "$note_dir"
: >"$note_dir/login"
note_report=""
for note_case in "none||" "pacnew-only|pacnew|" "record-only||record" "both|pacnew|record"; do
  IFS='|' read -r note_name note_pacnew note_record <<<"$note_case"
  rm -f -- "$note_dir/login.pacnew" "$note_dir/pam-keyring"
  [[ -z "$note_pacnew" ]] || : >"$note_dir/login.pacnew"
  [[ -z "$note_record" ]] || echo gnome >"$note_dir/pam-keyring"
  set +e
  note_out="$(env LOGIN_FILE="$note_dir/login" PAM_KEYRING_STATE="$note_dir/pam-keyring" \
    sh "$REPO_ROOT/pam/login-pacnew-note.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -ne 0 ]] ||
    { [[ "$note_name" == both ]] && [[ "$note_out" != *"$note_dir/login.pacnew is waiting"*"run lightxdm-update"* ]]; } ||
    { [[ "$note_name" != both ]] && [[ -n "$note_out" ]]; }; then
    note_report+=" [$note_name: status=$status, output=$note_out]"
  fi
done
note_exec="$(sed -n 's/^Exec = //p' "$REPO_ROOT/alpm/lightxdm-login-pacnew.hook")"
if [[ "$note_exec" != "/usr/bin/sh /usr/share/lightxdm/pam/login-pacnew-note.sh" ]]; then
  note_report+=" [hook Exec: $note_exec]"
fi
if [[ -z "$note_report" ]]; then
  pass "the login.pacnew hook note prints only while a .pacnew and the keyring record both exist"
else
  fail "login.pacnew hook note:$note_report"
fi
# install.sh --update reruns the last finished install with its saved choices; the keyring comes from PAM.
update_home="$TMP_DIR/update_home"
update_choices="$update_home/.local/state/lightxdm/install-choices"
update_login="$TMP_DIR/update_login"
mkdir -p "$update_home"
: >"$STUB_LOG"
set +e
output="$(HOME="$update_home" run_main_with_stubs "$sudo_pw_dir" --no-packages --no-keyring --de i3 2>&1)"
status=$?
set -e
if [[ $status -eq 0 && "$(cat "$update_choices" 2>/dev/null)" == $'de=i3\nno_packages=1' ]]; then
  pass "a finished install saves its desktop and --no-packages choice for --update"
else
  fail "install choices file (status=$status, file=$(cat "$update_choices" 2>&1), output=$output)"
fi
update_record="$TMP_DIR/update_pam_keyring"
update_run() {
  env -u SHELLOPTS -u SUDO_USER HOME="$1" LOGIN_FILE="$update_login" PAM_KEYRING_STATE="$update_record" \
    STUB_PACMAN_OWNER="${STUB_PACMAN_OWNER:-}" STUB_PACMAN_BACKUP="${STUB_PACMAN_BACKUP:-}" \
    bash "$REPO_ROOT/install.sh" "${@:2}" 2>&1
}
update_ok=1
update_report=""
rm -f -- "$update_record"
printf '%s\n' "# login stack without keyring lines" >"$update_login"
set +e
output="$(update_run "$update_home" --update --dry-run)"
status=$?
set -e
if [[ $status -ne 0 || "$output" != *"Updating with the saved choices: --de i3 --no-packages --no-keyring --dry-run"* ||
  "$output" != *"PAM keyring: skipped (--no-keyring)"* ]]; then
  update_ok=0
  update_report+=" [no keyring lines: status=$status, output=$output]"
fi
printf '%s\n' "auth       optional   pam_gnome_keyring.so" "session    optional   pam_gnome_keyring.so auto_start" >"$update_login"
set +e
output="$(update_run "$update_home" --update --dry-run)"
status=$?
set -e
if [[ $status -ne 0 || "$output" != *"Updating with the saved choices: --de i3 --no-packages --dry-run"* ||
  "$output" != *"PAM keyring: $update_login"* ]]; then
  update_ok=0
  update_report+=" [built-in with keyring lines: status=$status, output=$output]"
fi
mkdir -p "${update_choices%/*}"
printf 'de=custom\nno_packages=1\n' >"$update_choices"
printf '%s\n' "auth       optional   pam_kwallet5.so" >"$update_login"
set +e
output="$(update_run "$update_home" --update --dry-run)"
set -e
if [[ "$output" != *"Updating with the saved choices: --de custom --no-packages --keyring kwallet --dry-run"* ]]; then
  update_ok=0
  update_report+=" [custom id with kwallet: output=$output]"
fi
set +e
output="$(update_run "$TMP_DIR/update_empty_home" --update --dry-run)"
status=$?
set -e
if [[ $status -ne 1 || "$output" != *"No saved install choices in $TMP_DIR/update_empty_home/.local/state/lightxdm/install-choices"* ]]; then
  update_ok=0
  update_report+=" [missing file: status=$status, output=$output]"
fi
set +e
output="$(update_run "$update_home" --update --de xfce)"
status=$?
set -e
if [[ $status -ne 1 || "$output" != *"--update reuses the saved choices and takes only --dry-run and --non-interactive"* ]]; then
  update_ok=0
  update_report+=" [extra option: status=$status, output=$output]"
fi
if [[ $update_ok -eq 1 ]]; then
  pass "install.sh --update reuses the saved choices, reads the keyring from PAM, and refuses a missing file or other options"
else
  fail "install.sh --update:$update_report"
fi
# With a keyring record, --update brings back keyring lines a .pacnew merge removed (the login file
# is back to its packaged version) and leaves a login file with the user's own edits alone.
record_ok=1
record_report=""
printf 'de=i3\nno_packages=1\n' >"$update_choices"
printf 'gnome\n' >"$update_record"
printf '%s\n' "# stock login stack after a .pacnew merge" >"$update_login"
set +e
output="$(STUB_PACMAN_OWNER=util-linux STUB_PACMAN_BACKUP="$update_login [unmodified]" \
  update_run "$update_home" --update --dry-run)"
status=$?
set -e
if [[ $status -ne 0 || "$output" != *"Updating with the saved choices: --de i3 --no-packages --dry-run"* ||
  "$output" != *"lightXDM's gnome keyring lines are missing from $update_login, which is back to the version its package ships"* ||
  "$output" != *"PAM keyring: $update_login"* ]]; then
  record_ok=0
  record_report+=" [gnome record, stock file without lines: status=$status, output=$output]"
fi
printf '%s\n' "# login stack the user edited by hand" >"$update_login"
set +e
output="$(STUB_PACMAN_OWNER=util-linux STUB_PACMAN_BACKUP="$update_login [modified]" \
  update_run "$update_home" --update --dry-run)"
status=$?
set -e
if [[ $status -ne 0 || "$output" != *"Updating with the saved choices: --de i3 --no-packages --no-keyring --dry-run"* ||
  "$output" != *"lightXDM's gnome keyring lines are not in $update_login, which has your own edits"* ||
  "$output" != *"$CMD_INSTALL --de i3 --no-packages, or turn keyring unlock off"* ||
  "$output" != *"PAM keyring: skipped (--no-keyring)"* ]]; then
  record_ok=0
  record_report+=" [gnome record, hand-edited file without lines: status=$status, output=$output]"
fi
printf '%s\n' "$PAM_GNOME_KEYRING_AUTH" "$PAM_GNOME_KEYRING_SESSION" >"$update_login"
set +e
output="$(update_run "$update_home" --update --dry-run)"
status=$?
set -e
if [[ $status -ne 0 || "$output" == *"keyring lines are missing"* ]]; then
  record_ok=0
  record_report+=" [gnome record with its lines: status=$status, output=$output]"
fi
printf 'de=custom\nno_packages=1\n' >"$update_choices"
printf 'kwallet\n' >"$update_record"
printf '%s\n' "# stock login stack after a .pacnew merge" >"$update_login"
set +e
output="$(STUB_PACMAN_OWNER=util-linux STUB_PACMAN_BACKUP="$update_login [unmodified]" \
  update_run "$update_home" --update --dry-run)"
set -e
if [[ "$output" != *"Updating with the saved choices: --de custom --no-packages --keyring kwallet --dry-run"* ||
  "$output" != *"lightXDM's kwallet keyring lines are missing"* ]]; then
  record_ok=0
  record_report+=" [kwallet record for a custom id: output=$output]"
fi
if [[ $record_ok -eq 1 ]]; then
  pass "install.sh --update restores recorded keyring lines only in a login file back to its packaged version"
else
  fail "install.sh --update keyring record:$record_report"
fi
unset -f update_run
if [[ $can_unshare -eq 0 ]]; then
  skip "uninstall.sh removes the saved install choices (unshare -r unavailable)"
else
  choices_home="$TMP_DIR/choices_home"
  mkdir -p "$choices_home/.local/state/lightxdm"
  printf 'de=i3\nno_packages=0\n' >"$choices_home/.local/state/lightxdm/install-choices"
  set +e
  output="$(env TARGET_HOME="$choices_home" LOGIN_FILE="$TMP_DIR/choices_login" DM_STATE_FILE="$TMP_DIR/choices_dm" \
    GNOME_SESSION_TYPE_DEST="$TMP_DIR/choices_gnome-session-type.conf" OVERRIDE_DIR="$TMP_DIR/choices_getty.d" \
    POLKIT_RULE="$TMP_DIR/choices_49-nopasswd.rules" unshare -r bash "$REPO_ROOT/uninstall.sh" 2>&1)"
  status=$?
  set -e
  if [[ $status -eq 0 && ! -e "$choices_home/.local/state/lightxdm" ]]; then
    pass "uninstall.sh removes the saved install choices and the emptied state directory"
  else
    fail "uninstall.sh saved install choices (status=$status, output=$output)"
  fi
  # Both uninstall modes drop the keyring record together with the keyring lines.
  record_uninstall_report=""
  for record_mode in full --keyring-only; do
    record_file="$TMP_DIR/record_uninstall/pam-keyring"
    mkdir -p "${record_file%/*}" "$TMP_DIR/record_uninstall/home"
    printf 'gnome\n' >"$record_file"
    record_args=()
    [[ "$record_mode" == full ]] || record_args=("$record_mode")
    set +e
    output="$(env TARGET_HOME="$TMP_DIR/record_uninstall/home" LOGIN_FILE="$TMP_DIR/record_uninstall/login" \
      DM_STATE_FILE="$TMP_DIR/record_uninstall/dm" PAM_KEYRING_STATE="$record_file" \
      GNOME_SESSION_TYPE_DEST="$TMP_DIR/record_uninstall/gnome-session-type.conf" \
      OVERRIDE_DIR="$TMP_DIR/record_uninstall/getty.d" POLKIT_RULE="$TMP_DIR/record_uninstall/49-nopasswd.rules" \
      unshare -r bash "$REPO_ROOT/uninstall.sh" "${record_args[@]}" 2>&1)"
    status=$?
    set -e
    if [[ $status -ne 0 || -e "$record_file" ]]; then
      record_uninstall_report+=" [$record_mode: status=$status, output=$output]"
    fi
  done
  if [[ -z "$record_uninstall_report" ]]; then
    pass "uninstall.sh and uninstall.sh --keyring-only remove the keyring record"
  else
    fail "uninstall.sh keyring record:$record_uninstall_report"
  fi
fi
# configure_pam records the backend it set up, and its preview names the record.
record_dir="$TMP_DIR/record_configure"
mkdir -p "$record_dir"
printf '%s\n' '#%PAM-1.0' 'auth       include      system-local-login' 'account    include      system-local-login' \
  'session    include      system-local-login' 'password   include      system-local-login' >"$record_dir/login"
# shellcheck disable=SC2016  # expand inside the child shell
record_out="$(env LOGIN_FILE="$record_dir/login" PAM_KEYRING_STATE="$record_dir/lightxdm/pam-keyring" bash -c '
  source "$1/install.sh" && configure_pam xfce 1 && configure_pam xfce >/dev/null 2>&1 &&
    echo "after xfce: $(cat "$PAM_KEYRING_STATE")" && configure_pam plasma >/dev/null 2>&1 &&
    echo "after plasma: $(cat "$PAM_KEYRING_STATE")"' bash "$REPO_ROOT" 2>&1)"
if [[ "$record_out" == *"  record: $record_dir/lightxdm/pam-keyring (gnome)"* &&
  "$record_out" == *"after xfce: gnome"* && "$record_out" == *"after plasma: kwallet"* ]]; then
  pass "configure_pam records the keyring backend it set up (gnome, then kwallet) and the preview names the record"
else
  fail "configure_pam keyring record (output=$record_out)"
fi
# Dotfiles equal to older lightXDM templates (pinned in a temporary copy's list, no git) count as lightXDM's own
if [[ ! -f "$REPO_ROOT/dotfiles/template-history.sha256" ]]; then
  fail "dotfiles/template-history.sha256 is missing"
else
  past_dir="$TMP_DIR/past_templates"
  past_repo="$past_dir/repo"
  rm -rf "$past_dir"
  mkdir -p "$past_repo"
  cp -- "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh" "$REPO_ROOT/enable-autologin.sh" "$past_repo/"
  cp -r -- "$REPO_ROOT/dotfiles" "$REPO_ROOT/polkit" "$past_repo/"
  # An older ~/.bash_profile template and the removed separate kwallet helper exist only in the list
  { cat "$past_repo/dotfiles/.bash_profile"; echo "# older lightXDM template line"; } >"$past_dir/old_bash_profile"
  { echo "#!/bin/bash"; echo "# old kwallet header"; tail -n +3 "$past_repo/dotfiles/.gpg-agent-gnome"; } >"$past_dir/old_gpg_agent_kwallet"
  for past_entry in "old_bash_profile dotfiles/.bash_profile" "old_gpg_agent_kwallet dotfiles/.gpg-agent-*"; do
    read -r past_file past_spec <<<"$past_entry"
    past_hash="$(sha256sum <"$past_dir/$past_file")"
    printf '%s  %s\n' "${past_hash%% *}" "$past_spec" >>"$past_repo/dotfiles/template-history.sha256"
  done

  # Case A: install neither backs up nor saves as edited an unedited older template
  past_install_ok=1
  for past_marker in "" .lightxdm.absent; do
    past_home="$past_dir/install_home${past_marker}"
    mkdir -p "$past_home"
    cp -- "$past_dir/old_bash_profile" "$past_home/.bash_profile"
    [[ -z "$past_marker" ]] || : >"$past_home/.bash_profile$past_marker"
    (
      export HOME="$past_home"
      # shellcheck disable=SC2034  # copy_dotfiles uses SCRIPT_DIR from the sourced installer
      SCRIPT_DIR="$past_repo"
      copy_dotfiles "plasma" 2>/dev/null
    )
    if [[ -e "$past_home/.bash_profile.lightxdm.bak" ]] || compgen -G "$past_home/.bash_profile.lightxdm-edited*" >/dev/null ||
      ! cmp -s "$past_home/.bash_profile" "$past_repo/dotfiles/.bash_profile"; then
      past_install_ok=0
    fi
  done
  if [[ $past_install_ok -eq 1 ]]; then
    pass "copy_dotfiles replaces an unedited older lightXDM ~/.bash_profile without a backup or an edited copy"
  else
    fail "copy_dotfiles older lightXDM template ($(ls -A "$past_dir"/install_home*))"
  fi

  if [[ $can_unshare -eq 0 ]]; then
    skip "uninstall.sh removes dotfiles and backups from older lightXDM templates (unshare -r unavailable)"
  else
    past_uninstall() {
      env TARGET_HOME="$1" LOGIN_FILE="$past_dir/login" DM_STATE_FILE="$past_dir/dm-state" \
        GNOME_SESSION_TYPE_DEST="$past_dir/gnome-session-type.conf" OVERRIDE_DIR="$past_dir/getty.d" \
        POLKIT_RULE="$past_dir/49-nopasswd.rules" \
        unshare -r bash "$past_repo/uninstall.sh" 2>&1
    }

    # Case B: a marker-less older template is removed
    past_home="$past_dir/home_b"
    mkdir -p "$past_home"
    cp -- "$past_dir/old_bash_profile" "$past_home/.bash_profile"
    set +e
    output="$(past_uninstall "$past_home")"
    status=$?
    set -e
    if [[ $status -eq 0 && ! -e "$past_home/.bash_profile" && "$output" == *"Removing $past_home/.bash_profile..."* ]] &&
      ! compgen -G "$past_home/.bash_profile.*" >/dev/null; then
      pass "uninstall.sh removes a marker-less ~/.bash_profile from an older lightXDM template"
    else
      fail "uninstall.sh older template removal (status=$status, output=$output)"
    fi

    # Case C: a backup equal to an older template is not restored
    past_home="$past_dir/home_c"
    mkdir -p "$past_home"
    cp -- "$past_repo/dotfiles/.bash_profile" "$past_home/.bash_profile"
    cp -- "$past_dir/old_bash_profile" "$past_home/.bash_profile.lightxdm.bak"
    set +e
    output="$(past_uninstall "$past_home")"
    status=$?
    set -e
    if [[ $status -eq 0 && ! -e "$past_home/.bash_profile" && ! -e "$past_home/.bash_profile.lightxdm.bak" &&
      "$output" != *"Restoring"* && "$output" == *"Removing $past_home/.bash_profile..."* ]] &&
      ! compgen -G "$past_home/.bash_profile.*" >/dev/null; then
      pass "uninstall.sh removes a ~/.bash_profile.lightxdm.bak from an older lightXDM template instead of restoring it"
    else
      fail "uninstall.sh older template backup (status=$status, output=$output)"
    fi

    # Case D: an edited older template is still kept
    past_home="$past_dir/home_d"
    mkdir -p "$past_home"
    cp -- "$past_dir/old_bash_profile" "$past_home/.bash_profile"
    echo "# user customization" >>"$past_home/.bash_profile"
    cp -- "$past_home/.bash_profile" "$past_dir/edited_bash_profile"
    set +e
    output="$(past_uninstall "$past_home")"
    status=$?
    set -e
    if [[ $status -eq 0 && "$output" == *"Keeping $past_home/.bash_profile (not an unmodified lightXDM template)."* ]] &&
      cmp -s "$past_home/.bash_profile" "$past_dir/edited_bash_profile"; then
      pass "uninstall.sh keeps an edited ~/.bash_profile from an older lightXDM template"
    else
      fail "uninstall.sh edited older template (status=$status, output=$output)"
    fi

    # Case E: an installed copy of the removed separate kwallet helper is still recognized
    past_home="$past_dir/home_e"
    mkdir -p "$past_home"
    cp -- "$past_dir/old_gpg_agent_kwallet" "$past_home/.gpg-agent-kwallet"
    set +e
    output="$(past_uninstall "$past_home")"
    status=$?
    set -e
    if [[ $status -eq 0 && ! -e "$past_home/.gpg-agent-kwallet" && "$output" == *"Removing $past_home/.gpg-agent-kwallet..."* ]]; then
      pass "uninstall.sh removes a marker-less ~/.gpg-agent-kwallet from the removed separate kwallet helper"
    else
      fail "uninstall.sh removed kwallet helper (status=$status, output=$output)"
    fi
    unset -f past_uninstall
  fi
  rm -rf "$past_dir"
fi

finish_harness
