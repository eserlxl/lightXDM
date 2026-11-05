#!/bin/bash
# SPDX-FileCopyrightText: 2025-2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# tests/qemu/build-image.sh: run by tests/qemu-arch.sh inside a privileged archlinux container.
# Builds /out/root.img (ext4) plus kernel and initramfs for a direct-kernel QEMU boot, with the
# packages listed in /out/pkgs.txt and root's SSH key from /out/id_vm.pub.
# Writes /out/BUILD_DONE on success or /out/BUILD_FAILED on error.
set -euo pipefail
trap 'echo "rc=$?" > /out/BUILD_FAILED' ERR
uid=$1 gid=$2
pacman -Sy --noconfirm --needed arch-install-scripts e2fsprogs >/dev/null
root=/build/root
mkdir -p "$root"
# The container's pacman.conf has NoExtract rules (pacman.conf, mirrorlist, locales, man pages)
# that pacstrap would apply to the VM too; use a copy without them.
grep -v '^NoExtract' /etc/pacman.conf > /build/pacman.conf
mapfile -t pkgs < <(tr -s ' ' '\n' < /out/pkgs.txt | grep -v '^$')
pacstrap -C /build/pacman.conf -c -K "$root" base linux mkinitcpio openssh sudo "${pkgs[@]}"
cp /etc/pacman.d/mirrorlist "$root/etc/pacman.d/mirrorlist"
test -f "$root/etc/pacman.conf"

echo lightxdm-vm > "$root/etc/hostname"
echo '/dev/vda / ext4 rw,relatime 0 1' > "$root/etc/fstab"
cat > "$root/etc/systemd/network/20-wired.network" <<'EOF'
[Match]
Name=en*
[Network]
DHCP=yes
EOF
ln -sf /run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
install -d -m700 "$root/root/.ssh"
# SSH is key-only: the test user's fixed password must work only at the TTY1 console.
printf '%s\n' 'PasswordAuthentication no' 'KbdInteractiveAuthentication no' > "$root/etc/ssh/sshd_config.d/10-lightxdm-test.conf"
install -m600 /out/id_vm.pub "$root/root/.ssh/authorized_keys"
# The test user runs install.sh, which calls sudo; inside this throwaway VM it needs no password.
echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > "$root/etc/sudoers.d/10-wheel"
chmod 440 "$root/etc/sudoers.d/10-wheel"
# shellcheck disable=SC2016  # the script expands inside the chroot
arch-chroot "$root" bash -euc '
  systemctl enable systemd-networkd systemd-resolved sshd
  # Host keys made now stay fixed in the image, so the harness can pin them.
  ssh-keygen -A
  useradd -m -G wheel -s /bin/bash tester
  echo "tester:lightxdm-test" | chpasswd
  kver=$(ls /usr/lib/modules)
  # No autodetect: the container would detect the build host, not the VM.
  mkinitcpio -k "$kver" -S autodetect -g /boot/initramfs-vm.img
'
cp "$root/etc/ssh/ssh_host_ed25519_key.pub" /out/host_key.pub
cp "$root/boot/vmlinuz-linux" /out/vmlinuz
cp "$root/boot/initramfs-vm.img" /out/initramfs.img
rm -f /out/root.img
mkfs.ext4 -q -L root -d "$root" /out/root.img 16G
chown "$uid:$gid" /out/root.img /out/vmlinuz /out/initramfs.img /out/host_key.pub
echo rc=0 > /out/BUILD_DONE
