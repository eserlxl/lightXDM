#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025-2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
"""Real TTY1 login test for one desktop in a QEMU VM (driven by tests/qemu-arch.sh).

Usage: vmtest.py <desktop> <repo> <vm-dir> <ssh-port>
Boots <vm-dir>/root.img with -snapshot (the image stays unchanged), copies the repo's
working tree into the VM, runs install.sh --de <desktop> as user 'tester', reboots, types
the login at the TTY1 getty through QMP, and checks the desktop session twice (the second
login proves PAM unlocks an existing keyring). Writes <vm-dir>/run-<desktop>/result: one
PASS/FAIL line per check, then 'DONE pass=N fail=M'. LIGHTXDM_VM_KEEP=1 leaves the VM
running after the first login for debugging (ssh -p <port> root@127.0.0.1 with <vm-dir>/id_vm).
"""
import json
import os
import socket
import subprocess
import sys
import time

DESKTOP, REPO, VM_DIR, PORT = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
RUN = os.path.join(VM_DIR, f"run-{DESKTOP}")
RESULT = os.path.join(RUN, "result")
QMP_SOCK = os.path.join(RUN, "qmp.sock")
USER, PASSWORD = "tester", "lightxdm-test"  # throwaway account inside the disposable VM

# desktop -> (session type, processes that must run, keyring checked over D-Bus)
DESKTOPS = {
    "plasma": ("wayland", ["kwin_wayland", "plasmashell"], "kwallet"),
    "gnome": ("wayland", ["gnome-shell"], "gnome"),
    "budgie": ("wayland", ["labwc", "budgie-panel"], "gnome"),
    "xfce": ("x11", ["xfce4-session"], "gnome"),
    "lxqt": ("x11", ["lxqt-session"], "gnome"),
    "lxde": ("x11", ["lxsession"], "gnome"),
    "mate": ("x11", ["mate-session"], "gnome"),
    "cinnamon": ("x11", ["cinnamon-session"], "gnome"),
    "i3": ("x11", ["i3"], "gnome"),
}
SESSION_TYPE, PROCS, KEYRING = DESKTOPS[DESKTOP]
results = []


def log(msg):
    with open(os.path.join(RUN, "driver.log"), "a") as f:
        f.write(time.strftime("%H:%M:%S ") + msg + "\n")


def check(name, ok, detail=""):
    results.append(f"{'PASS' if ok else 'FAIL'}: {DESKTOP}: {name}" + (f" ({detail})" if detail and not ok else ""))
    log(results[-1])
    with open(RESULT, "w") as f:
        f.write("\n".join(results) + "\n")


def ssh(cmd, timeout=600, stdin=None):
    p = subprocess.run(
        ["ssh", "-i", os.path.join(VM_DIR, "id_vm"), "-p", str(PORT), "-o", "StrictHostKeyChecking=no",
         "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5",
         "root@127.0.0.1", cmd],
        input=stdin, capture_output=True, timeout=timeout)
    return p.returncode, p.stdout.decode(errors="replace"), p.stderr.decode(errors="replace")


def wait_ssh(limit=300):
    end = time.time() + limit
    while time.time() < end:
        try:
            if ssh("true", timeout=15)[0] == 0:
                return True
        except subprocess.TimeoutExpired:
            pass
        time.sleep(3)
    return False


class Qmp:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(path)
        self.f = self.s.makefile("rwb")
        self.f.readline()
        self.cmd("qmp_capabilities")

    def cmd(self, name, **args):
        self.f.write(json.dumps({"execute": name, "arguments": args}).encode() + b"\n")
        self.f.flush()
        while True:
            reply = json.loads(self.f.readline())
            if "return" in reply or "error" in reply:
                return reply

    def type(self, text):
        names = {"-": "minus", "\n": "ret"}
        for ch in text:
            self.cmd("send-key", keys=[{"type": "qcode", "data": names.get(ch, ch)}])
            time.sleep(0.08)


def boot():
    if os.path.exists(QMP_SOCK):
        os.remove(QMP_SOCK)
    args = ["qemu-system-x86_64", "-enable-kvm", "-cpu", "host", "-m", "4096", "-smp", "4",
            "-kernel", os.path.join(VM_DIR, "vmlinuz"), "-initrd", os.path.join(VM_DIR, "initramfs.img"),
            "-append", "root=/dev/vda rw console=ttyS0",
            # -snapshot keeps guest writes in a temp file under TMPDIR, so root.img stays unchanged.
            "-drive", f"file={os.path.join(VM_DIR, 'root.img')},if=virtio,format=raw", "-snapshot",
            # Standard VGA: the guest's bochs DRM driver gives KMS for Xorg and Wayland compositors.
            "-device", "VGA,vgamem_mb=64", "-display", "none",
            "-netdev", f"user,id=n0,hostfwd=tcp:127.0.0.1:{PORT}-:22", "-device", "virtio-net-pci,netdev=n0",
            "-qmp", f"unix:{QMP_SOCK},server=on,wait=off",
            "-serial", f"file:{os.path.join(RUN, 'serial.log')}"]
    with open(os.path.join(RUN, "qemu.log"), "w") as out:
        proc = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                                start_new_session=True, env={**os.environ, "TMPDIR": RUN})
    for _ in range(50):
        if os.path.exists(QMP_SOCK):
            break
        time.sleep(0.2)
    return proc


def reboot_and_login(qmp, tag):
    ssh("systemctl reboot", timeout=20)
    time.sleep(10)
    check(f"{tag}: VM back after reboot", wait_ssh())
    for _ in range(60):
        if ssh("systemctl is-active getty@tty1")[1].strip() == "active":
            break
        time.sleep(2)
    time.sleep(5)
    qmp.type(USER + "\n")
    time.sleep(3)
    qmp.type(PASSWORD + "\n")
    log(f"{tag}: typed the TTY1 login")


def wait_proc(name, limit=240):
    end = time.time() + limit
    while time.time() < end:
        if ssh(f"pgrep -u {USER} -x {name}")[0] == 0:
            return True
        time.sleep(5)
    return False


def user_bus(cmd):
    return ssh(f"sudo -u {USER} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u {USER})/bus {cmd}")


def session_checks(tag, qmp):
    for proc in PROCS:
        check(f"{tag}: {proc} runs for {USER}", wait_proc(proc))
    _, sessions, _ = ssh(f"for s in $(loginctl list-sessions --no-legend | awk '$3==\"{USER}\"{{print $1}}'); do "
                         "loginctl show-session $s -p TTY -p Service -p Active; echo; done")
    log(f"{tag}: sessions\n{sessions}")
    check(f"{tag}: {USER} has an active TTY1 login session",
          "TTY=tty1\nService=login\nActive=yes" in sessions, sessions.strip())
    rc, _, _ = ssh(f"tr '\\0' '\\n' < /proc/$(pgrep -u {USER} -x {PROCS[-1]} | head -1)/environ"
                   f" | grep -x XDG_SESSION_TYPE={SESSION_TYPE}")
    check(f"{tag}: {PROCS[-1]} runs with XDG_SESSION_TYPE={SESSION_TYPE}", rc == 0)
    has_xorg = ssh("pgrep -x Xorg")[0] == 0
    if SESSION_TYPE == "wayland":
        check(f"{tag}: no Xorg server (Xwayland only)", not has_xorg)
    else:
        check(f"{tag}: Xorg server runs", has_xorg)
    time.sleep(15)
    if KEYRING == "kwallet":
        # KDE Frameworks 6.31+: PAM starts ksecretd --pam-login, which serves org.freedesktop.secrets.
        check(f"{tag}: ksecretd was started by PAM", ssh(f"pgrep -u {USER} -f 'ksecretd --pam-login'")[0] == 0)
        collection = "kdewallet"
    else:
        collection = "login"
    _, out, err = user_bus("busctl --user get-property org.freedesktop.secrets "
                           f"/org/freedesktop/secrets/collection/{collection} org.freedesktop.Secret.Collection Locked")
    check(f"{tag}: keyring collection '{collection}' is unlocked without a prompt", out.strip() == "b false",
          (out + err).strip())
    qmp.cmd("screendump", filename=os.path.join(RUN, f"{tag}.png"), format="png")


def main():
    os.makedirs(RUN, exist_ok=True)
    open(RESULT, "w").close()
    proc = boot()
    kept = False
    try:
        qmp = Qmp(QMP_SOCK)
        check("VM boots and answers SSH", wait_ssh())
        # Copy the working tree (tracked and untracked, not ignored) so uncommitted changes are tested.
        files = subprocess.run(["git", "-C", REPO, "ls-files", "-z", "-co", "--exclude-standard"],
                               capture_output=True, check=True).stdout
        tar = subprocess.run(["tar", "-C", REPO, "--null", "-T", "-", "-c"], input=files,
                             capture_output=True, check=True).stdout
        rc, _, err = ssh(f"mkdir -p /home/{USER}/lightXDM && tar -x -C /home/{USER}/lightXDM && "
                         f"chown -R {USER}: /home/{USER}/lightXDM", stdin=tar)
        check("working tree copied into the VM", rc == 0, err)
        rc, out, err = ssh(f"su - {USER} -c 'cd ~/lightXDM && bash install.sh --de {DESKTOP}' 2>&1", timeout=1800)
        with open(os.path.join(RUN, "install.log"), "w") as f:
            f.write(out + err)
        check(f"install.sh --de {DESKTOP} exits 0", rc == 0, out[-400:])
        if rc != 0:
            return
        reboot_and_login(qmp, "login1")
        session_checks("login1", qmp)
        if os.environ.get("LIGHTXDM_VM_KEEP") == "1":
            kept = True
            log(f"LIGHTXDM_VM_KEEP=1: VM left running (qemu pid {proc.pid})")
            return
        reboot_and_login(qmp, "login2")
        session_checks("login2", qmp)
    except Exception as exc:  # report and shut down, never hang the harness
        check("driver ran without errors", False, repr(exc))
    finally:
        if not kept:
            try:
                ssh("systemctl poweroff", timeout=20)
            except Exception:
                pass
            try:
                proc.wait(timeout=60)
            except subprocess.TimeoutExpired:
                proc.kill()
        passed = sum(r.startswith("PASS") for r in results)
        failed = sum(r.startswith("FAIL") for r in results)
        with open(RESULT, "a") as f:
            f.write(f"DONE pass={passed} fail={failed}" + (" kept" if kept else "") + "\n")


main()
