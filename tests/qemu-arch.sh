#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# tests/qemu-arch.sh: real TTY1 login tests in QEMU VMs (needs Docker, QEMU with KVM, python3, ssh)
set -euo pipefail

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VM_DIR="${LIGHTXDM_VM_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/lightxdm-vm}"
JOBS="${LIGHTXDM_VM_JOBS:-2}"

usage() {
  cat <<EOF
Usage: bash $0 [-h|--help] [desktop | <from>:<to> | <desktop>+autologin ...]   (default: plasma xfce)

Builds an Arch Linux VM image in Docker (once per package set), then for each desktop boots a
VM, runs install.sh --de <desktop> as a test user, reboots, types the password at the TTY1
login and checks that the desktop session starts and PAM unlocks the keyring, twice.
An argument <from>:<to> installs <from>, then <to> in the same VM, and checks <to>.
An argument <desktop>+autologin installs with --no-keyring --autologin and boots without typing a password.
Prints one PASS/FAIL line per check; exits 1 if any check fails, 0 with SKIP if a tool is missing.

Environment:
  LIGHTXDM_VM_DIR   image, cache and logs (default: \${XDG_CACHE_HOME:-~/.cache}/lightxdm-vm)
  LIGHTXDM_VM_JOBS  VMs run at once, 4 GiB of memory each (default: 2)
  LIGHTXDM_VM_KEEP  set to 1 to leave each VM running after its first login, for debugging
EOF
}

is_desktop() {
  case "$1" in
    plasma | gnome | budgie | xfce | lxqt | lxde | mate | cinnamon | i3) return 0 ;;
    *) return 1 ;;
  esac
}

is_mode() {
  case "$1" in
    autologin) return 0 ;;
    *) return 1 ;;
  esac
}

desktops=()
for arg in "$@"; do
  case "$arg" in
    -h | --help) usage; exit 0 ;;
    *:*:*) echo "Unknown desktop: $arg" >&2; usage >&2; exit 1 ;;
    *+*)
      if is_desktop "${arg%%+*}" && is_mode "${arg#*+}"; then
        desktops+=("$arg")
      else
        echo "Unknown desktop: $arg" >&2; usage >&2; exit 1
      fi
      ;;
    *:*)
      if is_desktop "${arg%%:*}" && is_desktop "${arg#*:}"; then
        desktops+=("$arg")
      else
        echo "Unknown desktop: $arg" >&2; usage >&2; exit 1
      fi
      ;;
    *)
      if is_desktop "$arg"; then
        desktops+=("$arg")
      else
        echo "Unknown desktop: $arg" >&2; usage >&2; exit 1
      fi
      ;;
  esac
done
[[ ${#desktops[@]} -gt 0 ]] || desktops=(plasma xfce)
if [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "LIGHTXDM_VM_JOBS must be a positive integer" >&2
  exit 1
fi

for tool in docker qemu-system-x86_64 python3 ssh ssh-keygen git tar; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: $tool is unavailable"
    exit 0
  fi
done
if ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker is unavailable"
  exit 0
fi
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
  echo "SKIP: /dev/kvm is not accessible"
  exit 0
fi

mkdir -p "$VM_DIR/pkgcache"
# pacman inside the container downloads as its own unprivileged user.
chmod 0777 "$VM_DIR/pkgcache"
[[ -f "$VM_DIR/id_vm" ]] || ssh-keygen -q -t ed25519 -N '' -f "$VM_DIR/id_vm"

# The image holds every requested desktop's packages, as install.sh lists them.
pkgs="$(
  # shellcheck source=install.sh disable=SC1091
  source "$REPO_ROOT/install.sh"
  for de in "${desktops[@]}"; do
    de="${de%+*}"
    for part in ${de/:/ }; do list_packages "$part"; done
  done | sort -u | tr '\n' ' '
)"
stamp="$(printf '%s\n' "$pkgs" | cat - "$REPO_ROOT/tests/qemu/build-image.sh" | sha256sum | cut -d' ' -f1)"
if [[ "$(cat "$VM_DIR/image.stamp" 2>/dev/null || true)" != "$stamp" || ! -f "$VM_DIR/root.img" ]]; then
  echo "Building the VM image for: ${desktops[*]} (a few minutes; packages are cached in $VM_DIR/pkgcache)"
  printf '%s\n' "$pkgs" >"$VM_DIR/pkgs.txt"
  cp "$REPO_ROOT/tests/qemu/build-image.sh" "$VM_DIR/build-image.sh"
  rm -f "$VM_DIR/BUILD_DONE" "$VM_DIR/BUILD_FAILED" "$VM_DIR/image.stamp"
  if ! docker run --rm --privileged -v "$VM_DIR:/out" -v "$VM_DIR/pkgcache:/var/cache/pacman/pkg" \
    archlinux:latest bash /out/build-image.sh "$(id -u)" "$(id -g)" >"$VM_DIR/build.log" 2>&1 ||
    [[ ! -f "$VM_DIR/BUILD_DONE" ]]; then
    echo "FAIL: VM image build failed (see $VM_DIR/build.log)"
    exit 1
  fi
  printf '%s\n' "$stamp" >"$VM_DIR/image.stamp"
fi

port=2230
running=0
for de in "${desktops[@]}"; do
  if [[ $running -ge $JOBS ]]; then
    wait -n || true
    running=$((running - 1))
  fi
  port=$((port + 1))
  run_dir="$VM_DIR/run-${de//[:+]/-}"
  mkdir -p "$run_dir"
  rm -f -- "$run_dir/result"
  echo "Testing $de (log: $run_dir/driver.log)"
  python3 "$REPO_ROOT/tests/qemu/vmtest.py" "$de" "$REPO_ROOT" "$VM_DIR" "$port" >"$run_dir/vmtest.out" 2>&1 &
  running=$((running + 1))
done
wait || true

failures=0
for de in "${desktops[@]}"; do
  run_dir="$VM_DIR/run-${de//[:+]/-}"
  result="$run_dir/result"
  if [[ -f "$result" ]] && grep -q '^DONE' "$result"; then
    grep -E '^(PASS|FAIL)' "$result" || true
    grep -q '^FAIL' "$result" && failures=$((failures + 1))
  else
    echo "FAIL: $de: the VM test did not finish (see $run_dir/vmtest.out)"
    failures=$((failures + 1))
  fi
done
echo "SUMMARY: ${#desktops[@]} desktop(s), $failures with failures"
[[ $failures -eq 0 ]]
