#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# tests/docker-arch.sh: Test package lists, configure_pam and uninstall.sh against Arch Linux in Docker
set -euo pipefail

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<EOF
Usage: bash $0 [-h|--help] [--strict]
Run package list and real PAM checks in an Arch Linux Docker container.
--strict fails on SKIP (also enabled by LIGHTXDM_STRICT_TESTS=1).
EOF
}

strict=0
in_container=0
if [[ "${LIGHTXDM_STRICT_TESTS:-0}" == "1" ]]; then
  strict=1
fi
for arg in "$@"; do
  case "$arg" in
    -h | --help) usage; exit 0 ;;
    --strict) strict=1 ;;
    --in-container) in_container=1 ;;
    *) echo "Unknown argument: $arg" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ $in_container -eq 0 ]]; then
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "SKIP: docker is unavailable"
    exit "$strict"
  fi

  if ! docker run --rm -v "$REPO_ROOT:/repo:ro" archlinux:latest bash /repo/tests/docker-arch.sh --in-container; then
    echo "FAIL: Docker Arch package/PAM test failed"
    exit 1
  fi
  exit 0
fi

failures=0

pass() {
  echo "PASS: $1"
}

fail() {
  echo "FAIL: $1"
  failures=$((failures + 1))
}

pacman -Syu --noconfirm --needed python-pam kwallet-pam gnome-keyring

for module in /usr/lib/security/pam_kwallet5.so /usr/lib/security/pam_gnome_keyring.so; do
  if [[ ! -f "$module" ]]; then
    fail "Missing PAM module: $module"
    exit 1
  fi
  if ! python -c 'import ctypes, sys; ctypes.CDLL(sys.argv[1])' "$module"; then
    fail "Cannot load PAM module: $module"
    exit 1
  fi
done

test_user="lightxdmtest"
right_pw="TestPass_lightXDM_42!"
wrong_pw="WrongPass_lightXDM_99!"

useradd -m "$test_user"
printf '%s:%s\n' "$test_user" "$right_pw" | chpasswd

orig_login="$(mktemp)"
trap 'rm -f "$orig_login"' EXIT
cp /etc/pam.d/login "$orig_login"

# shellcheck disable=SC2317,SC2329  # invoked indirectly by sourced install.sh
sudo() {
  if [[ "${1:-}" == "pacman" && "${2:-}" == "-S" ]]; then
    shift 2
    pacman -Sp --print-format '%n' "$@"
  else
    "$@"
  fi
}

unset LOGIN_FILE SUDO_USER
# shellcheck source=install.sh disable=SC1091
source "$REPO_ROOT/install.sh"

# Resolve every desktop's full package list without installing it.
desktops=(plasma gnome xfce lxqt lxde mate cinnamon budgie i3)
declare -A desktop_packages
for desktop in "${desktops[@]}"; do
  if desktop_packages[$desktop]="$(install_packages "$desktop")"; then
    pass "Package list resolves for $desktop"
  else
    fail "Package list cannot be resolved for $desktop"
  fi
done

pacman -Fy

check_packaged_command() {
  local desktop=$1 required_path=$2 pkg_out pkg
  if ! pkg_out="$(pacman -Fq "${required_path#/}")" || [[ -z "${pkg_out//[[:space:]]/}" ]]; then
    fail "Required command for $desktop ($required_path) is not shipped by any package"
    return
  fi
  while IFS= read -r pkg; do
    # File database results may include a repository prefix.
    if [[ $'\n'${desktop_packages[$desktop]}$'\n' == *$'\n'"${pkg##*/}"$'\n'* ]]; then
      pass "Required command for $desktop ($required_path) is in its resolved package set ($pkg)"
      return
    fi
  done <<<"$pkg_out"
  fail "Required command for $desktop ($required_path) is outside its resolved package set ($pkg_out)"
}

last_exec_cmd() {
  local file=$1 line cmd=""
  local exec_re='^[[:space:]]*exec[[:space:]]+(--[[:space:]]+)?([^[:space:]#]+)'
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $exec_re && "${BASH_REMATCH[2]}" != "--" ]]; then
      cmd="${BASH_REMATCH[2]}"
    fi
  done <"$file"
  printf '%s\n' "$cmd"
}

for desktop in xfce lxqt lxde mate cinnamon i3; do
  template="$REPO_ROOT/dotfiles/.xinitrc-$desktop"
  if [[ ! -f "$template" ]]; then
    fail "Missing template for $desktop: $template"
    continue
  fi
  exec_cmd="$(last_exec_cmd "$template")"
  if [[ -z "$exec_cmd" || "$exec_cmd" == */ ]]; then
    fail "No valid exec command in template for $desktop ($exec_cmd)"
  else
    check_packaged_command "$desktop" "/usr/bin/$exec_cmd"
  fi
done

# Wayland launchers need every absolute path on their last exec line in their package set.
for desktop in plasma gnome budgie; do
  wayland_template="$REPO_ROOT/dotfiles/.wayland-session-$desktop"
  wayland_exec="$(grep -E '^[[:space:]]*exec[[:space:]]' "$wayland_template" | tail -n 1)"
  wayland_paths=0
  for token in $wayland_exec; do
    if [[ "$token" == /* ]]; then
      check_packaged_command "$desktop" "$token"
      wayland_paths=$((wayland_paths + 1))
    fi
  done
  if [[ $wayland_paths -eq 0 ]]; then
    fail "No absolute launch path on the last exec line of $wayland_template"
  fi
done

for desktop in "${desktops[@]}"; do
  case "$desktop" in plasma | gnome | budgie) continue ;; esac
  check_packaged_command "$desktop" /usr/bin/startx
done
for desktop in xfce i3; do
  check_packaged_command "$desktop" /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
done

pam_auth() {
  local user=$1
  local pw=$2
  local tty="${3:-}"
  python - "$user" "$pw" "$tty" <<'PY'
import inspect
import sys
import pam

p = pam.pam()
kwargs = {}
if sys.argv[3] and "tty" in inspect.signature(p.authenticate).parameters:
    kwargs["tty"] = sys.argv[3]
# call_end=False keeps the handle open; otherwise open_session() fails with
# PAM_SYSTEM_ERR without updating p.code, and a broken session stack passes.
if not p.authenticate(sys.argv[1], sys.argv[2], service="login", call_end=False, **kwargs):
    sys.exit(1)
if p.open_session() != 0:
    sys.exit(1)
rc = p.close_session()
p.end()
sys.exit(0 if rc == 0 else 1)
PY
}

# 1. configure_pam plasma + PAM auth/session checks
configure_pam plasma
if grep -Eq '^[[:space:]]*auth[[:space:]]+optional[[:space:]]+pam_kwallet5\.so$' /etc/pam.d/login &&
  grep -Eq '^[[:space:]]*session[[:space:]]+optional[[:space:]]+pam_kwallet5\.so force_run$' /etc/pam.d/login; then
  pass "configure_pam plasma writes pam_kwallet5.so rules to /etc/pam.d/login"
else
  fail "configure_pam plasma did not write expected pam_kwallet5.so rules"
fi

if pam_auth "$test_user" "$right_pw"; then
  pass "PAM login authenticates right password and opens/closes session after configure_pam plasma"
else
  fail "PAM login authentication or session failed after configure_pam plasma"
fi

if ! pam_auth "$test_user" "$wrong_pw"; then
  pass "PAM login rejects wrong password after configure_pam plasma"
else
  fail "PAM login accepted wrong password after configure_pam plasma"
fi
faillock --user "$test_user" --reset >/dev/null 2>&1 || true

# 2. Restore original /etc/pam.d/login, then configure_pam gnome + PAM auth/session checks
cp "$orig_login" /etc/pam.d/login
rm -f /etc/pam.d/login.lightxdm.bak

configure_pam gnome
if grep -Eq '^[[:space:]]*auth[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so$' /etc/pam.d/login &&
  grep -Eq '^[[:space:]]*session[[:space:]]+optional[[:space:]]+pam_gnome_keyring\.so auto_start$' /etc/pam.d/login; then
  pass "configure_pam gnome writes pam_gnome_keyring.so rules to /etc/pam.d/login"
else
  fail "configure_pam gnome did not write expected pam_gnome_keyring.so rules"
fi

if pam_auth "$test_user" "$right_pw"; then
  pass "PAM login authenticates right password and opens/closes session after configure_pam gnome"
else
  fail "PAM login authentication or session failed after configure_pam gnome"
fi

if ! pam_auth "$test_user" "$wrong_pw"; then
  pass "PAM login rejects wrong password after configure_pam gnome"
else
  fail "PAM login accepted wrong password after configure_pam gnome"
fi
faillock --user "$test_user" --reset >/dev/null 2>&1 || true

# GNOME's conditional environment setup must leave the real Arch PAM stack usable for every
# tty and user (a failed gate must never fail the session), and set the Wayland session type
# only for the configured user on TTY1, whichever form login uses for the tty.
other_user="lightxdmother"
useradd -m "$other_user"
printf '%s:%s\n' "$other_user" "$right_pw" | chpasswd
configure_gnome_session_type gnome "$test_user"
pam_session_matrix() {
  python - "$test_user" "$other_user" "$right_pw" <<'PY'
import ctypes
import sys
import pam

PAM_TTY = 3
test_user, other_user, password = sys.argv[1:4]
bad = 0
for user in (test_user, other_user):
    for tty in (None, "tty1", "/dev/tty1", "tty2"):
        p = pam.pam()
        if not p.authenticate(user, password, service="login", call_end=False):
            print(f"auth failed for {user} tty={tty}"); bad += 1; continue
        if tty:
            p.pam_set_item(p.handle, PAM_TTY, ctypes.c_char_p(tty.encode()))
        opened = p.open_session()
        session_type = p.getenv("XDG_SESSION_TYPE")
        closed = p.close_session()
        p.end()
        want = "wayland" if user == test_user and tty in ("tty1", "/dev/tty1") else None
        if opened != 0 or closed != 0 or session_type != want:
            print(f"{user} tty={tty}: open={opened} close={closed} XDG_SESSION_TYPE={session_type} want={want}")
            bad += 1
sys.exit(1 if bad else 0)
PY
}
if matrix_out="$(pam_session_matrix 2>&1)"; then
  pass "GNOME PAM block: sessions open and close for every tty and user; only $test_user on TTY1 gets XDG_SESSION_TYPE=wayland"
else
  fail "GNOME PAM block session matrix: $matrix_out"
fi

# 3. Run uninstall.sh as root and assert /etc/pam.d/login matches original byte-for-byte
if TARGET_HOME="/home/$test_user" bash "$REPO_ROOT/uninstall.sh"; then
  pass "uninstall.sh succeeds as root"
else
  fail "uninstall.sh failed"
fi

# cmp is in diffutils, which the base image lacks; sha256sum is in coreutils.
if [[ "$(sha256sum </etc/pam.d/login)" == "$(sha256sum <"$orig_login")" &&
  ! -e /etc/pam.d/login.lightxdm.bak && ! -e "$GNOME_SESSION_TYPE_DEST" ]]; then
  pass "uninstall.sh restores /etc/pam.d/login byte-identical to original"
else
  fail "uninstall.sh did not restore /etc/pam.d/login byte-identical to original"
fi

if [[ $failures -ne 0 ]]; then
  exit 1
fi
