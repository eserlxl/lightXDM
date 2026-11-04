#!/usr/bin/env bash
# tests/docker-arch.sh: Test package lists, configure_pam and uninstall.sh against Arch Linux in Docker
set -euo pipefail

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${1:-}" != "--in-container" ]]; then
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "SKIP: docker is unavailable"
    exit 0
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
    pacman -Sp "$@"
  else
    "$@"
  fi
}

unset LOGIN_FILE SUDO_USER
# shellcheck source=install.sh disable=SC1091
source "$REPO_ROOT/install.sh"

# Resolve every desktop's full package list without installing it.
for desktop in plasma gnome xfce lxqt lxde mate cinnamon budgie i3; do
  if install_packages "$desktop"; then
    pass "Package list resolves for $desktop"
  else
    fail "Package list cannot be resolved for $desktop"
  fi
done

pacman -Fy

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
  elif pkg_out="$(pacman -F "usr/bin/$exec_cmd")" && [[ -n "${pkg_out//[[:space:]]/}" ]]; then
    pass "Exec command for $desktop ($exec_cmd) is shipped (${pkg_out%%$'\n'*})"
  else
    fail "Exec command for $desktop ($exec_cmd) is not shipped by any package"
  fi
done

for required_path in /usr/bin/startx /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1; do
  if pkg_out="$(pacman -F "${required_path#/}")" && [[ -n "${pkg_out//[[:space:]]/}" ]]; then
    pass "Required command $required_path is shipped (${pkg_out%%$'\n'*})"
  else
    fail "Required command $required_path is not shipped by any package"
  fi
done

pam_auth() {
  local user=$1
  local pw=$2
  python - "$user" "$pw" <<'PY'
import sys
import pam

p = pam.pam()
# call_end=False keeps the handle open; otherwise open_session() fails with
# PAM_SYSTEM_ERR without updating p.code, and a broken session stack passes.
if not p.authenticate(sys.argv[1], sys.argv[2], service="login", call_end=False):
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

# 3. Run uninstall.sh as root and assert /etc/pam.d/login matches original byte-for-byte
if TARGET_HOME="/home/$test_user" bash "$REPO_ROOT/uninstall.sh"; then
  pass "uninstall.sh succeeds as root"
else
  fail "uninstall.sh failed"
fi

# cmp is in diffutils, which the base image lacks; sha256sum is in coreutils.
if [[ "$(sha256sum </etc/pam.d/login)" == "$(sha256sum <"$orig_login")" && ! -e /etc/pam.d/login.lightxdm.bak ]]; then
  pass "uninstall.sh restores /etc/pam.d/login byte-identical to original"
else
  fail "uninstall.sh did not restore /etc/pam.d/login byte-identical to original"
fi

if [[ $failures -ne 0 ]]; then
  exit 1
fi
