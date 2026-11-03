#!/usr/bin/env bash
# tests/docker-arch.sh: Test configure_pam and uninstall.sh against real Arch Linux PAM in Docker
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${1:-}" != "--in-container" ]]; then
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "SKIP: docker is unavailable"
    exit 0
  fi

  if ! docker run --rm -v "$REPO_ROOT:/repo:ro" archlinux:latest bash /repo/tests/docker-arch.sh --in-container; then
    echo "FAIL: Docker Arch PAM test failed"
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

pacman -Sy --noconfirm --needed python-pam kwallet-pam gnome-keyring

for module in /usr/lib/security/pam_kwallet5.so /usr/lib/security/pam_gnome_keyring.so; do
  if [[ ! -f "$module" ]]; then
    fail "Missing PAM module: $module"
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
sudo() { "$@"; }

unset LOGIN_FILE SUDO_USER
# shellcheck source=install.sh disable=SC1091
source "$REPO_ROOT/install.sh"

pam_auth() {
  local user=$1
  local pw=$2
  python - "$user" "$pw" <<'PY'
import sys
import pam

p = pam.pam()
if not p.authenticate(sys.argv[1], sys.argv[2], service="login"):
    sys.exit(1)
p.open_session()
if p.code != 0:
    sys.exit(1)
p.close_session()
sys.exit(0 if p.code == 0 else 1)
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
