#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025-2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
"""Real TTY1 login test for one desktop in a QEMU VM (driven by tests/qemu-arch.sh).

Usage: vmtest.py <desktop|from:to|desktop+autologin|desktop+lightdm|desktop+relogin|desktop+recovery|desktop+package> <repo> <vm-dir> <ssh-port>
Boots <vm-dir>/root.img with -snapshot (the image stays unchanged), copies the repo's
working tree into the VM, runs install.sh --de <desktop> as user 'tester' (or <from> then
<to> when given <from>:<to>), reboots, types the login at the TTY1 getty through QMP, and
checks the desktop session twice (the second login proves PAM unlocks an existing keyring).
With +package it copies <vm-dir>/lightxdm.pkg.tar.zst instead, installs it with pacman, sets up
with lightxdm-install, and after the two logins runs lightxdm-update, a third login,
sudo lightxdm-uninstall and pacman -R.
Writes <vm-dir>/run-<spec>/result: one PASS/FAIL line per check, then 'DONE pass=N fail=M'.
LIGHTXDM_VM_KEEP=1 leaves the VM running after the first login for debugging (ssh -p <port>
root@127.0.0.1 with <vm-dir>/id_vm).
"""
import json
import os
import socket
import subprocess
import sys
import time

DESKTOP, REPO, VM_DIR, PORT = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
spec, _, MODE = DESKTOP.partition("+")
FROM, TARGET = spec.split(":") if ":" in spec else (None, spec)
RUN = os.path.join(VM_DIR, f"run-{DESKTOP.replace(':', '-').replace('+', '-')}")
RESULT = os.path.join(RUN, "result")
QMP_SOCK = os.path.join(RUN, "qmp.sock")
USER, PASSWORD = "tester", "lightxdm-test"  # throwaway account inside the disposable VM

# desktop -> (session type, processes that must run, keyring checked over D-Bus)
DESKTOPS = {
    "plasma": ("wayland", ["kwin_wayland", "plasmashell"], "kwallet"),
    "gnome": ("wayland", ["gnome-shell"], "gnome"),
    "budgie": ("wayland", ["labwc", "budgie-panel"], "gnome"),
    "xfce": ("x11", ["xfce4-session", "xfwm4"], "gnome"),
    "lxqt": ("x11", ["lxqt-session", "lxqt-panel"], "gnome"),
    "lxde": ("x11", ["lxsession", "openbox", "lxpanel"], "gnome"),
    "mate": ("x11", ["mate-session", "marco", "mate-panel"], "gnome"),
    # cinnamon-session-binary shows as a truncated 15-character comm; check the shell instead.
    "cinnamon": ("x11", ["cinnamon"], "gnome"),
    "i3": ("x11", ["i3"], "gnome"),
}
SESSION_TYPE, PROCS, KEYRING = DESKTOPS[TARGET]
# Keys a user presses once on the first login: LXQt asks for a default window manager before it
# runs its autostart entries (the polkit agent among them); Enter accepts the highlighted one.
FIRST_LOGIN_KEYS = {"lxqt": "\n"}
# The package lane runs the installed lightxdm-* commands; every other lane the copied tree.
INSTALLER = "lightxdm-install" if MODE == "package" else f"bash /home/{USER}/lightXDM/install.sh"
PACKAGE = os.path.join(VM_DIR, "lightxdm.pkg.tar.zst")
results = []


def log(msg):
    with open(os.path.join(RUN, "driver.log"), "a") as f:
        f.write(time.strftime("%H:%M:%S ") + msg + "\n")


def check(name, ok, detail=""):
    results.append(f"{'PASS' if ok else 'FAIL'}: {DESKTOP}: {name}" + (f" ({detail})" if detail and not ok else ""))
    log(results[-1])
    with open(RESULT, "w") as f:
        f.write("\n".join(results) + "\n")


KNOWN_HOSTS = os.path.join(RUN, "known_hosts")


def pin_host_key():
    # The image's host key was made at build time; pinning it means nothing else on the
    # loopback port can receive the working tree or root commands.
    with open(os.path.join(VM_DIR, "host_key.pub")) as f:
        key = " ".join(f.read().split()[:2])
    with open(KNOWN_HOSTS, "w") as f:
        f.write(f"[127.0.0.1]:{PORT} {key}\n")


def ssh(cmd, timeout=600, stdin=None):
    p = subprocess.run(
        ["ssh", "-i", os.path.join(VM_DIR, "id_vm"), "-p", str(PORT), "-o", "StrictHostKeyChecking=yes",
         "-o", f"UserKnownHostsFile={KNOWN_HOSTS}", "-o", "HostKeyAlgorithms=ssh-ed25519",
         "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5", "root@127.0.0.1", cmd],
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
        # A monitor that stops answering must raise into main's handler, not hang the run.
        self.s.settimeout(60)
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
        names = {"-": "minus", "\n": "ret", " ": "spc", "/": "slash"}
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
    try:
        rc, out, err = ssh("cat /proc/sys/kernel/random/boot_id", timeout=15)
        old_id = out.strip()
    except subprocess.TimeoutExpired:
        rc, old_id, err = -1, "", "ssh timed out"
    if rc != 0 or not old_id:
        check(f"{tag}: VM back after reboot", False, (err or out).strip() or "failed to read boot_id")
        return False

    try:
        ssh("systemctl reboot", timeout=20)
    except subprocess.TimeoutExpired:
        pass

    end = time.time() + 300
    ok = False
    detail = "timed out waiting for reboot"
    while time.time() < end:
        try:
            rc, out, err = ssh("cat /proc/sys/kernel/random/boot_id", timeout=15)
            new_id = out.strip()
            if rc == 0 and new_id and new_id != old_id:
                ok = True
                detail = ""
                break
            if rc == 0 and new_id == old_id:
                detail = "boot id did not change"
            elif rc == 0:
                detail = "empty boot id"
            else:
                detail = (err or out).strip() or f"ssh returned {rc}"
        except subprocess.TimeoutExpired:
            detail = "ssh timed out"
        time.sleep(3)

    check(f"{tag}: VM back after reboot", ok, detail)
    if not ok:
        return False

    for _ in range(60):
        if ssh("systemctl is-active getty@tty1")[1].strip() == "active":
            break
        time.sleep(2)
    if MODE in ("autologin", "recovery"):
        return True
    time.sleep(5)
    qmp.type(USER + "\n")
    time.sleep(3)
    qmp.type(PASSWORD + "\n")
    log(f"{tag}: typed the TTY1 login")
    return True


def relogin(qmp, tag):
    logout_commands = {
        "plasma": "busctl --user call org.kde.Shutdown /Shutdown org.kde.Shutdown logout",
        "xfce": "busctl --user call org.xfce.SessionManager /org/xfce/SessionManager "
                "org.xfce.Session.Manager Logout bb false true",
        "gnome": "busctl --user call org.gnome.SessionManager /org/gnome/SessionManager "
                 "org.gnome.SessionManager Logout u 1",
    }
    desktop_logout = TARGET in logout_commands
    name = (f"{tag}: logged out through the desktop and the login prompt is back" if desktop_logout else
            f"{tag}: forced logout (loginctl terminate-user) and the login prompt is back")
    try:
        if desktop_logout:
            rc, out, err = user_bus(logout_commands[TARGET])
        else:
            rc, out, err = ssh(f"loginctl terminate-user {USER}", timeout=20)
    except subprocess.TimeoutExpired:
        check(name, False, "logout command timed out")
        return False
    if rc != 0:
        check(name, False, (out + err).strip() or f"logout command returned {rc}")
        return False

    display_server = {"plasma": "kwin_wayland", "gnome": "gnome-shell"}.get(
        TARGET, "Xorg" if SESSION_TYPE == "x11" else PROCS[0])
    display_command = ("pgrep -x Xorg" if display_server == "Xorg" else
                       f"pgrep -u {USER} -x {display_server}")
    end = time.monotonic() + 120
    ok = False
    display_state = "unknown"
    getty_state = "unknown"
    while time.monotonic() < end:
        try:
            display_state = "unknown (ssh timed out)"
            rc, _, err = ssh(display_command, timeout=min(15, end - time.monotonic()))
            display_state = "running" if rc == 0 else "exited" if rc == 1 else f"unknown: {err.strip()} (rc={rc})"
            remaining = end - time.monotonic()
            if remaining <= 0:
                break
            getty_state = "unknown (ssh timed out)"
            getty_rc, getty, getty_err = ssh("systemctl is-active getty@tty1", timeout=min(15, remaining))
            getty_state = (getty + getty_err).strip() or f"rc={getty_rc}"
            ok = rc == 1 and getty_rc == 0 and getty.strip() == "active"
            if ok:
                break
        except subprocess.TimeoutExpired:
            pass
        time.sleep(min(1, max(0, end - time.monotonic())))

    try:
        _, left, _ = ssh(f"ps -u {USER} -o comm= | sort -u | tr '\\n' ' '", timeout=15)
        log(f"{tag}: still running after logout: {left.strip() or 'nothing'}")
    except subprocess.TimeoutExpired:
        log(f"{tag}: still running after logout: unavailable (ssh timed out)")
    check(name, ok, f"{display_server}: {display_state}; getty@tty1: {getty_state}")
    if not ok:
        return False
    time.sleep(3)
    qmp.type(USER + "\n")
    time.sleep(3)
    qmp.type(PASSWORD + "\n")
    log(f"{tag}: typed the TTY1 login")
    return True


def recovery_checks(qmp):
    def wait_file(path, limit):
        end = time.monotonic() + limit
        detail = f"{path} did not appear within {limit}s"
        while time.monotonic() < end:
            try:
                rc, out, err = ssh(f"test -f {path}", timeout=min(15, end - time.monotonic()))
                if rc == 0:
                    return True, ""
                detail = (out + err).strip() or f"{path} is absent (rc={rc})"
            except subprocess.TimeoutExpired:
                detail = f"ssh timed out checking {path}"
            time.sleep(min(1, max(0, end - time.monotonic())))
        return False, f"after {limit}s: {detail}"

    # Preserve an installed Wayland launcher so this also exercises recovery on Wayland desktops.
    log("recovery: replacing the session launcher with an immediate failure")
    rc, out, err = ssh(
        f"su - {USER} -c '"
        "if [ -e ~/.wayland-session ] || [ -L ~/.wayland-session ]; then "
        "mv ~/.wayland-session ~/.wayland-session.recovery-backup; fi && "
        "printf \"#!/bin/sh\\nexit 1\\n\" > ~/.wayland-session && "
        "chmod +x ~/.wayland-session && rm -f ~/recovery-shell-ok'", timeout=20)
    check("recovery: failing launcher installed as the user", rc == 0, (out + err).strip())
    if rc != 0 or not reboot_and_login(qmp, "recovery"):
        return

    marker = f"/home/{USER}/.config/lightxdm/no-autostart"
    ok, detail = wait_file(marker, 120)
    check("recovery: crash loop pauses TTY1 auto-start", ok, detail)
    if not ok:
        return

    try:
        rc, out, err = ssh("systemctl is-active getty@tty1", timeout=15)
        ok = rc == 0 and out.strip() == "active"
        detail = (out + err).strip() or f"systemctl returned {rc}"
    except subprocess.TimeoutExpired:
        ok, detail = False, "ssh timed out checking getty@tty1"
    check("recovery: getty@tty1 remains active after the crash loop", ok, detail)
    if not ok:
        return

    qmp.type(f"touch /home/{USER}/recovery-shell-ok\n")
    log("recovery: typed the shell probe at the paused TTY1 shell")
    ok, detail = wait_file(f"/home/{USER}/recovery-shell-ok", 30)
    check("recovery: paused TTY1 shell executes a command typed through QMP", ok, detail)
    if not ok:
        return

    rc, out, err = ssh(
        f"su - {USER} -c 'rm -f ~/.wayland-session ~/.config/lightxdm/no-autostart && "
        "if [ -e ~/.wayland-session.recovery-backup ] || [ -L ~/.wayland-session.recovery-backup ]; then "
        "mv ~/.wayland-session.recovery-backup ~/.wayland-session; fi'", timeout=20)
    check("recovery: launcher repaired and auto-start pause removed", rc == 0, (out + err).strip())
    if rc != 0:
        return
    qmp.type("exit\n")
    log("recovery: exited the TTY1 shell to restart autologin with the repaired launcher")
    session_checks("recovery", qmp)


def wait_proc(name, limit=240):
    end = time.time() + limit
    while time.time() < end:
        if ssh(f"pgrep -u {USER} -x {name}")[0] == 0:
            return True
        time.sleep(5)
    return False


def user_bus(cmd):
    return ssh(f"sudo -u {USER} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u {USER})/bus {cmd}")


def launcher_stdout():
    # The TTY1 login shell execs the session launcher (through systemd-cat when the session-journal
    # marker exists), so the user's oldest process on tty1 holds the session's stdout.
    _, out, err = ssh(f"pid=$(pgrep -o -u {USER} -t tty1) && readlink /proc/$pid/fd/1")
    return (out + err).strip()


def keyring_collection():
    return "kdewallet" if KEYRING == "kwallet" else "login"


def lock_keyring(tag):
    # A keyring daemon can outlive the logout, so lock the collection first: the relogin's unlock
    # check then proves that the relogin's own PAM stack unlocked it again.
    path = f"/org/freedesktop/secrets/collection/{keyring_collection()}"
    user_bus(f"busctl --user call org.freedesktop.secrets /org/freedesktop/secrets "
             f"org.freedesktop.Secret.Service Lock ao 1 {path}")
    _, out, err = user_bus(f"busctl --user get-property org.freedesktop.secrets {path} "
                           "org.freedesktop.Secret.Collection Locked")
    check(f"{tag}: keyring collection '{keyring_collection()}' is locked before logout", out.strip() == "b true",
          (out + err).strip())


def session_checks(tag, qmp):
    check(f"{tag}: {PROCS[0]} runs for {USER}", wait_proc(PROCS[0]))
    if tag in ("login1", "recovery") and TARGET in FIRST_LOGIN_KEYS:
        time.sleep(8)
        qmp.type(FIRST_LOGIN_KEYS[TARGET])
        log(f"{tag}: answered the first-login prompt")
        time.sleep(5)
    # LXQt starts its panel only after the first-login prompt is answered.
    for proc in PROCS[1:]:
        check(f"{tag}: {proc} runs for {USER}", wait_proc(proc))
    if TARGET == "lxqt":
        # LXQt runs the window manager saved at the first-login prompt, not a fixed one.
        _, conf, _ = ssh(f"cat /home/{USER}/.config/lxqt/session.conf")
        saved = [line.split("=", 1)[1] for line in conf.splitlines() if line.startswith("window_manager=")]
        wm = os.path.basename(saved[-1].strip()) if saved else ""
        check(f"{tag}: LXQt window manager {wm or '(none saved)'} runs for {USER}", bool(wm) and wait_proc(wm),
              conf.strip())
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
        # The helper runs before the compositor; the autostart entry must refresh gpg-agent's
        # startup display from inside the session so SSH passphrase prompts reach the desktop.
        env = ""
        for _ in range(6):
            _, env, _ = ssh(f"su - {USER} -c \"gpg-connect-agent --no-autostart 'GETINFO std_startup_env' /bye\"")
            if "WAYLAND_DISPLAY=" in env:
                break
            time.sleep(5)
        # gpg-connect-agent separates entries with NUL bytes; keep the failure detail text-only.
        check(f"{tag}: gpg-agent startup env has the session WAYLAND_DISPLAY", "WAYLAND_DISPLAY=" in env,
              env.replace("\0", " ").strip())
    else:
        check(f"{tag}: Xorg server runs", has_xorg)
    time.sleep(15)
    if MODE not in ("autologin", "recovery"):
        if KEYRING == "kwallet":
            # KDE Frameworks 6.31+: PAM starts ksecretd --pam-login, which serves org.freedesktop.secrets.
            check(f"{tag}: ksecretd was started by PAM", ssh(f"pgrep -u {USER} -f 'ksecretd --pam-login'")[0] == 0)
        collection = keyring_collection()
        _, out, err = user_bus("busctl --user get-property org.freedesktop.secrets "
                               f"/org/freedesktop/secrets/collection/{collection} org.freedesktop.Secret.Collection Locked")
        check(f"{tag}: keyring collection '{collection}' is unlocked without a prompt", out.strip() == "b false",
              (out + err).strip())
        rc, out, err = user_bus(f"{INSTALLER} --check-keyring {'kwallet' if KEYRING == 'kwallet' else 'gnome'}")
        check(f"{tag}: --check-keyring reports collection '{collection}' as unlocked",
              rc == 0 and f"collection '{collection}' is unlocked" in out, (out + err).strip())
    # Ask polkitd for an action that needs authentication on behalf of a session process: with an
    # agent registered for the session it opens a dialog and pkcheck waits (timeout -> 124); without
    # one polkitd answers at once "no agent is available" (exit 2). Shell-integrated agents
    # (GNOME Shell, Cinnamon) have no process of their own, so the process list only names extras.
    # Some sessions start their agent from autostart a little later (LXQt): retry for up to a minute.
    probe = ""
    for _ in range(6):
        _, probe, _ = ssh(f"timeout 8 pkcheck --action-id org.freedesktop.policykit.exec --process "
                          f"$(pgrep -u {USER} -x {PROCS[-1]} | head -1) --allow-user-interaction >/dev/null 2>&1; echo rc=$?")
        if probe.strip() == "rc=124":
            break
        time.sleep(4)
    _, names, _ = ssh(f"ps -u {USER} -o comm= | grep -E 'polkit|policykit|lxpolkit' | sort -u | tr '\\n' ' '")
    agent = names.strip() or "built into the session"
    log(f"{tag}: polkit probe {probe.strip()}; agent processes: {agent}")
    check(f"{tag}: a polkit authentication agent answers in the session ({agent})", probe.strip() == "rc=124",
          probe.strip())
    time.sleep(2)
    qmp.cmd("screendump", filename=os.path.join(RUN, f"{tag}.png"), format="png")


def main():
    os.makedirs(RUN, exist_ok=True)
    open(RESULT, "w").close()
    pin_host_key()
    proc = boot()
    kept = False
    try:
        qmp = Qmp(QMP_SOCK)
        check("VM boots and answers SSH", wait_ssh())
        if MODE == "package":
            with open(PACKAGE, "rb") as f:
                rc, _, err = ssh("cat > /root/lightxdm.pkg.tar.zst", stdin=f.read())
            check("package copied into the VM", rc == 0, err)
            rc, out, err = ssh("pacman -U --noconfirm /root/lightxdm.pkg.tar.zst 2>&1", timeout=600)
            check("pacman -U installs lightxdm and prints the post_install note",
                  rc == 0 and "run: lightxdm-install" in out, out[-400:])
            rc, out, err = ssh("pacman -U --noconfirm /root/lightxdm.pkg.tar.zst 2>&1", timeout=600)
            check("reinstalling lightxdm prints the post_upgrade note",
                  rc == 0 and "runs: lightxdm-update" in out, out[-400:])
        else:
            # Copy the working tree (tracked and untracked, not ignored) so uncommitted changes are tested.
            files = subprocess.run(["git", "-C", REPO, "ls-files", "-z", "-co", "--exclude-standard"],
                                   capture_output=True, check=True).stdout
            # A tracked file deleted but not staged is still listed, and tar cannot read it.
            files = b"".join(p + b"\0" for p in files.split(b"\0")
                             if p and os.path.lexists(os.path.join(os.fsencode(REPO), p)))
            tar = subprocess.run(["tar", "-C", REPO, "--null", "-T", "-", "-c"], input=files,
                                 capture_output=True, check=True).stdout
            rc, _, err = ssh(f"mkdir -p /home/{USER}/lightXDM && tar -x -C /home/{USER}/lightXDM && "
                             f"chown -R {USER}: /home/{USER}/lightXDM", stdin=tar)
            check("working tree copied into the VM", rc == 0, err)
        if MODE == "lightdm":
            rc, out, err = ssh("systemctl enable lightdm.service")
            check("lightdm.service enabled before install", rc == 0, (out + err).strip())
        if FROM:
            rc, out, err = ssh(f"su - {USER} -c 'cd ~/lightXDM && bash install.sh --de {FROM}' 2>&1", timeout=1800)
            with open(os.path.join(RUN, f"install-{FROM}.log"), "w") as f:
                f.write(out + err)
            check(f"install.sh --de {FROM} exits 0", rc == 0, out[-400:])
            if rc != 0:
                return
        install_args = f"--no-keyring --autologin --de {TARGET}" if MODE in ("autologin", "recovery") else f"--de {TARGET}"
        if MODE == "package":
            install_name, install_cmd = "lightxdm-install", f"lightxdm-install {install_args}"
        else:
            install_name, install_cmd = "install.sh", f"cd ~/lightXDM && bash install.sh {install_args}"
        rc, out, err = ssh(f"su - {USER} -c '{install_cmd}' 2>&1", timeout=1800)
        with open(os.path.join(RUN, "install.log"), "w") as f:
            f.write(out + err)
        check(f"{install_name} {install_args} exits 0", rc == 0, out[-400:])
        if rc != 0:
            return
        if MODE == "package":
            # The package ships the templates without the executable bit; the installer sets it.
            launcher = ".wayland-session" if SESSION_TYPE == "wayland" else ".xinitrc"
            _, out, err = ssh(f"stat -c %a /home/{USER}/{launcher}")
            check(f"lightxdm-install made ~/{launcher} executable from the packaged template",
                  out.strip() == "755", (out + err).strip())
            # The package's pacman hook speaks up after a util-linux transaction only while login.pacnew waits.
            _, version, _ = ssh("pacman -Q util-linux | cut -d' ' -f2")
            with open(os.path.join(VM_DIR, "pkgcache", f"util-linux-{version.strip()}-x86_64.pkg.tar.zst"), "rb") as f:
                rc, _, err = ssh("cat > /root/util-linux.pkg.tar.zst", stdin=f.read())
            check("util-linux package copied into the VM", rc == 0, err)
            rc, out, err = ssh("pacman -U --noconfirm /root/util-linux.pkg.tar.zst 2>&1", timeout=600)
            check("reinstalling util-linux runs the lightXDM hook, quiet without login.pacnew",
                  rc == 0 and "(lightXDM)" in out and "login.pacnew is waiting" not in out, out[-400:])
            _, out, err = ssh("cp /etc/pam.d/login /etc/pam.d/login.pacnew && "
                              "pacman -U --noconfirm /root/util-linux.pkg.tar.zst 2>&1; rm -f /etc/pam.d/login.pacnew",
                              timeout=600)
            check("with /etc/pam.d/login.pacnew waiting, the hook reminds to run lightxdm-update",
                  "login.pacnew is waiting" in out and "run lightxdm-update" in out, out[-400:])
        if MODE == "lightdm":
            _, out, err = ssh("systemctl is-enabled lightdm.service")
            check("install.sh disabled lightdm.service", out.strip() == "disabled", (out + err).strip())
            rc, _, err = ssh("grep -Fxq lightdm.service /etc/lightxdm/disabled-display-managers")
            check("install.sh recorded lightdm.service", rc == 0, err.strip())
        if MODE in ("autologin", "recovery"):
            _, out, err = ssh(f"bash /home/{USER}/lightXDM/enable-autologin.sh --status")
            check(f"enable-autologin.sh --status reports enabled for {USER}",
                  out.startswith(f"enabled for {USER}"), (out + err).strip())
        if MODE == "recovery":
            recovery_checks(qmp)
            if os.environ.get("LIGHTXDM_VM_KEEP") == "1":
                kept = True
                log(f"LIGHTXDM_VM_KEEP=1: VM left running (qemu pid {proc.pid})")
            return
        login1_ok = reboot_and_login(qmp, "login1")
        if login1_ok:
            session_checks("login1", qmp)
            rc, out, err = ssh("journalctl -b -q -t lightxdm -o cat")
            check("login1: default session has no lightxdm journal entries", rc == 0 and not out.strip(),
                  (out + err).strip())
            stdout = launcher_stdout()
            check("login1: the default session launcher writes to /dev/tty1", stdout == "/dev/tty1", stdout)
        if os.environ.get("LIGHTXDM_VM_KEEP") == "1":
            kept = True
            log(f"LIGHTXDM_VM_KEEP=1: VM left running (qemu pid {proc.pid})")
            return
        if MODE == "relogin":
            if login1_ok:
                lock_keyring("relogin")
            if login1_ok and relogin(qmp, "relogin"):
                session_checks("relogin", qmp)
        elif login1_ok:
            rc, out, err = ssh(f"su - {USER} -c 'mkdir -p ~/.config/lightxdm && : > ~/.config/lightxdm/session-journal'")
            check("session-journal marker created as the user", rc == 0, (out + err).strip())
            if reboot_and_login(qmp, "login2"):
                session_checks("login2", qmp)
                # A quiet session (Plasma logs through systemd user units) prints nothing to the launcher,
                # so check where the launcher writes rather than whether it wrote anything.
                stdout = launcher_stdout()
                _, lines, _ = ssh("journalctl -b -q -t lightxdm -o cat | wc -l")
                check("login2: with session-journal the session launcher writes to a journal stream",
                      stdout.startswith("socket:"), f"stdout={stdout}, lightxdm journal lines={lines.strip()}")
        if MODE == "lightdm":
            rc, out, err = ssh(f"su - {USER} -c 'cd ~/lightXDM && sudo bash uninstall.sh' 2>&1", timeout=600)
            with open(os.path.join(RUN, "uninstall.log"), "w") as f:
                f.write(out + err)
            check("uninstall.sh exits 0", rc == 0, out[-400:])
            _, out, err = ssh("systemctl is-enabled lightdm.service")
            check("uninstall.sh re-enabled lightdm.service", out.strip() == "enabled", (out + err).strip())
            _, out, err = ssh("readlink -f /etc/systemd/system/display-manager.service")
            check("display-manager.service points to lightdm.service", out.strip().endswith("/lightdm.service"),
                  (out + err).strip())
            rc, _, err = ssh("test ! -e /etc/lightxdm/disabled-display-managers")
            check("uninstall.sh removed the display-manager state file", rc == 0, err.strip())
        if MODE == "package" and login1_ok:
            # Removing only lightXDM's lines by hand brings back the file util-linux ships, which pacman calls
            # unmodified, just as after a .pacnew merge; --update must still leave the user's removal alone.
            # On GNOME the hand edit also removes lightXDM's session-type block.
            strip_lightxdm = ("sed -i -E -e '/pam_(gnome_keyring|kwallet5)[.]so/d' "
                              "-e '/lightXDM: GNOME on TTY1|pam_succeed_if[.]so quiet (tty|user)|gnome-session-type[.]conf/d' "
                              "/etc/pam.d/login")
            login_stock = "LC_ALL=C pacman -Qii util-linux | grep -F '/etc/pam.d/login [unmodified]'"
            rc, out, err = ssh(f"{strip_lightxdm} && {login_stock}")
            check("removing lightXDM's lines by hand leaves /etc/pam.d/login as util-linux ships it", rc == 0,
                  (out + err).strip())
            for attempt in ("hand-edit", "hand-edit-after-merge"):
                rc, out, err = ssh(f"su - {USER} -c 'lightxdm-update' 2>&1", timeout=1800)
                with open(os.path.join(RUN, f"update-{attempt}.log"), "w") as f:
                    f.write(out + err)
                _, lines, _ = ssh("grep -cE 'pam_(gnome_keyring|kwallet5)[.]so' /etc/pam.d/login")
                check(f"{attempt}: lightxdm-update leaves out the keyring lines removed by hand and says so",
                      rc == 0 and "which has your own edits" in out and lines.strip() == "0", out[-400:])
                if TARGET == "gnome":
                    _, blocks, _ = ssh("grep -c 'lightXDM: GNOME on TTY1' /etc/pam.d/login")
                    check(f"{attempt}: lightxdm-update leaves out the GNOME block removed by hand and says so",
                          "GNOME session-type block is not in" in out and blocks.strip() == "0", out[-400:])
                if attempt == "hand-edit-after-merge":
                    rc, out, err = ssh("cp -p /root/login.restored /etc/pam.d/login && rm -f /root/login.restored")
                    check("restored lightXDM's lines for the next login", rc == 0, (out + err).strip())
                    break
                # A pacdiff merge that takes util-linux's login.pacnew drops every lightXDM line, and the version
                # it brings differs from lightXDM's backup (here, a backup taken from an older util-linux).
                rc, out, err = ssh("echo '# a line an older util-linux shipped' >> /etc/pam.d/login.lightxdm.bak && "
                                   f"{login_stock}")
                check("a simulated .pacnew merge left /etc/pam.d/login as util-linux ships it", rc == 0,
                      (out + err).strip())
                rc, out, err = ssh(f"su - {USER} -c 'lightxdm-update' 2>&1", timeout=1800)
                with open(os.path.join(RUN, "update.log"), "w") as f:
                    f.write(out + err)
                check("lightxdm-update reruns the saved choices",
                      rc == 0 and f"Updating with the saved choices: --de {TARGET}" in out, out[-400:])
                check("lightxdm-update reports the keyring lines the merge removed", "keyring lines are missing" in out,
                      out[-400:])
                _, out, err = ssh("grep -cE '^(auth|session) +optional +pam_(gnome_keyring|kwallet5)[.]so' /etc/pam.d/login")
                check("lightxdm-update added the keyring lines back", out.strip() == "2", (out + err).strip())
                if TARGET == "gnome":
                    _, out, err = ssh("grep -c 'lightXDM: GNOME on TTY1' /etc/pam.d/login")
                    check("lightxdm-update put the GNOME block back after the .pacnew merge", out.strip() == "1",
                          (out + err).strip())
                rc, out, err = ssh("test -s /etc/lightxdm/pam-login-base")
                check("lightxdm-update recorded the version the .pacnew merge brought", rc == 0, (out + err).strip())
                # Removing lightXDM's lines by hand after the merge brings back the merged version: still the user's.
                rc, out, err = ssh(f"cp -p /etc/pam.d/login /root/login.restored && {strip_lightxdm} && {login_stock}")
                check("removing lightXDM's lines after the merge leaves the merged version", rc == 0,
                      (out + err).strip())
            if reboot_and_login(qmp, "login3"):
                session_checks("login3", qmp)
            rc, out, err = ssh(f"su - {USER} -c 'sudo lightxdm-uninstall' 2>&1", timeout=600)
            with open(os.path.join(RUN, "uninstall.log"), "w") as f:
                f.write(out + err)
            check("sudo lightxdm-uninstall exits 0", rc == 0, out[-400:])
            _, out, err = ssh("grep -cE 'pam_(gnome_keyring|kwallet5)[.]so' /etc/pam.d/login")
            check("lightxdm-uninstall left no keyring line in /etc/pam.d/login", out.strip() == "0",
                  (out + err).strip())
            rc, _, err = ssh(f"test ! -e /home/{USER}/.local/state/lightxdm/install-choices")
            check("lightxdm-uninstall removed the saved install choices", rc == 0, err.strip())
            # The merged version stays: uninstall never puts the older backup back over it.
            rc, out, err = ssh(f"test ! -e /etc/lightxdm/pam-login-base && {login_stock}")
            check("lightxdm-uninstall removed the merge record and left /etc/pam.d/login as util-linux ships it",
                  rc == 0, (out + err).strip())
            rc, out, err = ssh("pacman -R --noconfirm lightxdm 2>&1", timeout=600)
            check("pacman -R removes lightxdm and prints the pre_remove note",
                  rc == 0 and "run sudo lightxdm-uninstall" in out, out[-400:])
            rc, _, err = ssh("test ! -e /usr/share/lightxdm && test ! -e /usr/bin/lightxdm-install")
            check("pacman -R left no lightxdm files", rc == 0, err.strip())
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
