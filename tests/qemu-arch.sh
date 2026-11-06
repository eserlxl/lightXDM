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
Usage: bash $0 [-h|--help] [--strict] [--rebuild-image] [desktop | <from>:<to> | <desktop>+autologin | <desktop>+lightdm | <desktop>+relogin | <desktop>+recovery | <desktop>+package ...]   (default: plasma xfce)

Builds an Arch Linux VM image in Docker (once per package set), then for each desktop boots a
VM, runs install.sh --de <desktop> as a test user, reboots, types the password at the TTY1
login and checks that the desktop session starts and PAM unlocks the keyring, twice.
An argument <from>:<to> installs <from>, then <to> in the same VM, and checks <to>.
An argument <desktop>+autologin installs with --no-keyring --autologin and boots without typing a password.
An argument <desktop>+lightdm checks that install.sh disables LightDM and uninstall.sh restores it after both logins.
An argument <desktop>+relogin logs out and back in on TTY1 in the same boot instead of rebooting for the second login.
An argument <desktop>+recovery installs with autologin, makes the session crash at once, and checks that TTY1 auto-start pauses, the TTY1 shell works and a repaired launcher starts the desktop.
An argument <desktop>+package builds the lightxdm package from the tracked files with aurgen (in a temporary
clone, so aur/ stays untouched; needs aurgen and makepkg), installs it with pacman, sets up with
lightxdm-install, checks both logins, runs lightxdm-update and a third login, then sudo
lightxdm-uninstall and pacman -R.
Prints one PASS/FAIL line per check; exits 1 if any check fails, 0 with SKIP if a tool is missing.
--strict exits 1 on any SKIP (also enabled by LIGHTXDM_STRICT_TESTS=1).
--rebuild-image rebuilds the VM image even when the package set is unchanged, to test current Arch packages.

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
    autologin | lightdm | relogin | recovery | package) return 0 ;;
    *) return 1 ;;
  esac
}

strict=0
rebuild_image=0
if [[ "${LIGHTXDM_STRICT_TESTS:-0}" == "1" ]]; then
  strict=1
fi
desktops=()
for arg in "$@"; do
  if [[ "$arg" == "--strict" ]]; then
    strict=1
    continue
  fi
  if [[ "$arg" == "--rebuild-image" ]]; then
    rebuild_image=1
    continue
  fi
  for desktop in "${desktops[@]}"; do
    if [[ "$arg" == "$desktop" ]]; then
      echo "Duplicate desktop: $arg" >&2; usage >&2; exit 1
    fi
  done
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
    exit "$strict"
  fi
done
package_lane=0
[[ " ${desktops[*]} " != *"+package "* ]] || package_lane=1
if [[ $package_lane -eq 1 ]]; then
  for tool in aurgen makepkg; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "SKIP: $tool is unavailable (needed for +package)"
      exit "$strict"
    fi
  done
fi
if ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker is unavailable"
  exit "$strict"
fi
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
  echo "SKIP: /dev/kvm is not accessible"
  exit "$strict"
fi

mkdir -p "$VM_DIR/pkgcache"
VM_DIR="$(CDPATH='' cd -- "$VM_DIR" && pwd)"
# pacman inside the container downloads as its own unprivileged user.
chmod 0777 "$VM_DIR/pkgcache"
[[ -f "$VM_DIR/id_vm" ]] || ssh-keygen -q -t ed25519 -N '' -f "$VM_DIR/id_vm"

# The image holds every requested desktop's packages, as install.sh lists them.
pkgs="$(
  # shellcheck source=install.sh disable=SC1091
  source "$REPO_ROOT/install.sh"
  for de in "${desktops[@]}"; do
    if [[ "${de#*+}" == lightdm ]]; then
      printf '%s\n' lightdm lightdm-gtk-greeter
    fi
    de="${de%+*}"
    for part in ${de/:/ }; do list_packages "$part"; done
  done | sort -u | tr '\n' ' '
)"
stamp="$(printf '%s\n' "$pkgs" | cat - "$REPO_ROOT/tests/qemu/build-image.sh" | sha256sum | cut -d' ' -f1)"
if [[ "$(cat "$VM_DIR/image.stamp" 2>/dev/null || true)" != "$stamp" || ! -f "$VM_DIR/root.img" || $rebuild_image -eq 1 ]]; then
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
if [[ $package_lane -eq 1 ]]; then
  # Build like a release does, from the tracked files (staged or not), in a temporary clone so
  # aurgen's generated files never replace the checkout's aur/ ones.
  echo "Building the lightxdm package (log: $VM_DIR/package-build.log)"
  pkg_clone="$(mktemp -d)"
  trap 'rm -rf -- "$pkg_clone"' EXIT
  rm -f -- "$VM_DIR/lightxdm.pkg.tar.zst"
  if ! {
    git clone --quiet --shared "$REPO_ROOT" "$pkg_clone/lightXDM" &&
      git -C "$pkg_clone/lightXDM" remote set-url origin "$(git -C "$REPO_ROOT" remote get-url origin)" &&
      git -C "$REPO_ROOT" diff HEAD --binary | git -C "$pkg_clone/lightXDM" apply --index --allow-empty &&
      (cd "$pkg_clone/lightXDM" && aurgen --build-only local </dev/null) &&
      cp -- "$pkg_clone"/lightXDM/aur/lightxdm-*-any.pkg.tar.zst "$VM_DIR/lightxdm.pkg.tar.zst"
  } >"$VM_DIR/package-build.log" 2>&1; then
    echo "FAIL: lightxdm package build failed (see $VM_DIR/package-build.log)"
    exit 1
  fi
  rm -rf -- "$pkg_clone"
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
