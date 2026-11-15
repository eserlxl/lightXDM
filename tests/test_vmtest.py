#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025-2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
"""Host-side unit tests for tests/qemu/vmtest.py."""

import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from types import SimpleNamespace
from unittest import mock

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(TESTS_DIR)
QEMU_DIR = os.path.join(TESTS_DIR, "qemu")

if QEMU_DIR not in sys.path:
    sys.path.insert(0, QEMU_DIR)

import vmtest  # noqa: E402


def _make_fake_qmp_socket(incoming_lines):
    """Return a mock socket whose makefile('rwb') feeds incoming_lines and records writes."""
    raw_in = io.BytesIO(b"".join(
        line.encode() + b"\n" if isinstance(line, str) else line for line in incoming_lines
    ))
    raw_out = io.BytesIO()

    class FakeStream:
        def readline(self):
            return raw_in.readline()

        def write(self, data):
            return raw_out.write(data)

        def flush(self):
            raw_out.flush()

    sock = mock.MagicMock()
    sock.makefile.return_value = FakeStream()
    return sock, raw_out


class ImportHygieneTests(unittest.TestCase):
    def test_import_has_no_side_effects_when_argv_has_no_test_args(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}
            proc = subprocess.run(
                [
                    sys.executable,
                    "-B",
                    "-c",
                    (
                        "import sys; "
                        f"sys.path.insert(0, {QEMU_DIR!r}); "
                        "sys.argv = ['vmtest.py']; "
                        "import vmtest; "
                        "assert vmtest.DESKTOP is None and vmtest.results == []"
                    ),
                ],
                cwd=tmpdir,
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout, "")
            self.assertEqual(proc.stderr, "")
            self.assertEqual(os.listdir(tmpdir), [])

    def test_no_pycache_created_in_tests_tree(self):
        for root, dirs, files in os.walk(TESTS_DIR):
            self.assertNotIn("__pycache__", dirs, f"unexpected __pycache__ in {root}")
            for name in files:
                self.assertFalse(name.endswith(".pyc"), f"unexpected bytecode file {name} in {root}")


class SpecAndArgParsingTests(unittest.TestCase):
    def test_parse_spec_plain_desktops(self):
        for desktop in vmtest.DESKTOPS:
            with self.subTest(desktop=desktop):
                self.assertEqual(vmtest.parse_spec(desktop), (None, desktop, ""))

    def test_parse_spec_upgrade_and_modes(self):
        self.assertEqual(vmtest.parse_spec("xfce:plasma"), ("xfce", "plasma", ""))
        self.assertEqual(vmtest.parse_spec("xfce:plasma+package"), ("xfce", "plasma", "package"))
        for mode in ("autologin", "lightdm", "relogin", "recovery", "package"):
            with self.subTest(mode=mode):
                self.assertEqual(vmtest.parse_spec(f"plasma+{mode}"), (None, "plasma", mode))

    def test_parse_spec_rejects_invalid_inputs(self):
        invalid = [
            "",
            None,
            123,
            "unknown",
            "unknown:plasma",
            "plasma:unknown",
            ":plasma",
            "plasma:",
            "plasma:xfce:i3",
            "plasma+",
            "plasma+bogus",
            "+autologin",
            "xfce+autologin+package",
            " plasma",
        ]
        for spec in invalid:
            with self.subTest(spec=spec):
                with self.assertRaises(ValueError):
                    vmtest.parse_spec(spec)

    def test_parse_args_valid_explicit_and_sys_argv(self):
        parsed = vmtest.parse_args(["xfce:plasma+package", "/repo", "/vm", "2231"])
        self.assertEqual(parsed.desktop, "xfce:plasma+package")
        self.assertEqual(parsed.repo, "/repo")
        self.assertEqual(parsed.vm_dir, "/vm")
        self.assertEqual(parsed.port, 2231)
        self.assertEqual((parsed.from_de, parsed.target, parsed.mode), ("xfce", "plasma", "package"))

        with mock.patch.object(sys, "argv", ["vmtest.py", "gnome+relogin", "/r", "/v", "65535"]):
            from_sys = vmtest.parse_args()
        self.assertEqual(from_sys.target, "gnome")
        self.assertEqual(from_sys.mode, "relogin")
        self.assertEqual(from_sys.port, 65535)

    def test_parse_args_rejects_bad_arity_paths_and_ports(self):
        bad_argvs = [
            [],
            ["plasma"],
            ["plasma", "/repo", "/vm"],
            ["plasma", "/repo", "/vm", "2231", "extra"],
            ["bogus", "/repo", "/vm", "2231"],
            ["plasma+nope", "/repo", "/vm", "2231"],
            ["plasma", "", "/vm", "2231"],
            ["plasma", "/repo", "", "2231"],
            ["plasma", "/repo", "/vm", "0"],
            ["plasma", "/repo", "/vm", "-22"],
            ["plasma", "/repo", "/vm", "65536"],
            ["plasma", "/repo", "/vm", "not-a-port"],
            ["plasma", "/repo", "/vm", "22_31"],
            ["plasma", "/repo", "/vm", ""],
            ["plasma", "/repo", "/vm", True],
        ]
        for argv in bad_argvs:
            with self.subTest(argv=argv):
                with self.assertRaises(ValueError):
                    vmtest.parse_args(argv)

    def test_configure_initializes_globals_paths_and_installer(self):
        args_pkg = vmtest.parse_args(["xfce:plasma+package", "/tmp/repo", "/tmp/vm", "2231"])
        vmtest.configure(args_pkg)
        self.assertEqual(vmtest.DESKTOP, "xfce:plasma+package")
        self.assertEqual(vmtest.FROM, "xfce")
        self.assertEqual(vmtest.TARGET, "plasma")
        self.assertEqual(vmtest.MODE, "package")
        self.assertEqual(vmtest.RUN, os.path.join("/tmp/vm", "run-xfce-plasma-package"))
        self.assertEqual(vmtest.RESULT, os.path.join(vmtest.RUN, "result"))
        self.assertEqual(vmtest.QMP_SOCK, os.path.join(vmtest.RUN, "qmp.sock"))
        self.assertEqual(vmtest.KNOWN_HOSTS, os.path.join(vmtest.RUN, "known_hosts"))
        self.assertEqual(vmtest.SESSION_TYPE, "wayland")
        self.assertEqual(vmtest.PROCS, ["kwin_wayland", "plasmashell"])
        self.assertEqual(vmtest.KEYRING, "kwallet")
        self.assertEqual(vmtest.INSTALLER, "lightxdm-install")
        self.assertEqual(vmtest.PACKAGE, os.path.join("/tmp/vm", "lightxdm.pkg.tar.zst"))
        self.assertEqual(vmtest.results, [])

        args_tree = vmtest.parse_args(["xfce+autologin", "/tmp/repo", "/tmp/vm", "2232"])
        vmtest.configure(args_tree)
        self.assertEqual(vmtest.RUN, os.path.join("/tmp/vm", "run-xfce-autologin"))
        self.assertEqual(vmtest.SESSION_TYPE, "x11")
        self.assertEqual(vmtest.KEYRING, "gnome")
        self.assertEqual(vmtest.INSTALLER, f"bash /home/{vmtest.USER}/lightXDM/install.sh")


class RegistryParityTests(unittest.TestCase):
    def _parse_qemu_arch_case(self, func_name):
        with open(os.path.join(REPO_ROOT, "tests", "qemu-arch.sh"), encoding="utf-8") as f:
            content = f.read()
        match = re.search(rf"{func_name}\(\)\s*\{{.*?case\s+\"\$1\"\s+in\s+(.*?)\)\s*return 0 ;;", content, re.S)
        self.assertIsNotNone(match, f"Could not find {func_name}() in tests/qemu-arch.sh")
        return {item.strip() for item in match.group(1).split("|")}

    def test_desktops_and_modes_match_qemu_arch_sh(self):
        sh_desktops = self._parse_qemu_arch_case("is_desktop")
        sh_modes = self._parse_qemu_arch_case("is_mode")
        self.assertEqual(len(sh_desktops), 9)
        self.assertEqual(len(sh_modes), 5)
        self.assertEqual(set(vmtest.DESKTOPS.keys()), sh_desktops)
        self.assertEqual({m for m in vmtest.VALID_MODES if m}, sh_modes)

        for desktop, (session_type, procs, keyring) in vmtest.DESKTOPS.items():
            with self.subTest(desktop=desktop):
                self.assertIn(session_type, ("wayland", "x11"))
                self.assertTrue(procs and all(isinstance(p, str) and p for p in procs))
                self.assertIn(keyring, ("kwallet", "gnome"))

        for desktop, keys in vmtest.FIRST_LOGIN_KEYS.items():
            self.assertIn(desktop, vmtest.DESKTOPS)
            self.assertIsInstance(keys, str)
        self.assertEqual(vmtest.FIRST_LOGIN_KEYS, {"lxqt": "\n"})

    def test_keyring_collection(self):
        vmtest.configure(vmtest.parse_args(["plasma", "/r", "/v", "2231"]))
        self.assertEqual(vmtest.keyring_collection(), "kdewallet")
        for de in vmtest.DESKTOPS:
            if de == "plasma":
                continue
            with self.subTest(de=de):
                vmtest.configure(vmtest.parse_args([de, "/r", "/v", "2231"]))
                self.assertEqual(vmtest.keyring_collection(), "login")


class QmpTests(unittest.TestCase):
    def test_handshake_event_skipping_and_type_key_mappings(self):
        incoming = [
            json.dumps({"QMP": {"version": {"qemu": {"major": 9}}}}),
            json.dumps({"event": "NIC_RX_FILTER_CHANGED"}),
            json.dumps({"return": {}}),
            json.dumps({"event": "VSERPORT_CHANGE"}),
            json.dumps({"return": {}}),
            json.dumps({"error": {"class": "GenericError", "desc": "bad"}}),
        ]
        # Add enough return replies for type("a-b\nc d/1") -> 9 characters
        incoming.extend(json.dumps({"return": {}}) for _ in range(9))
        fake_sock, raw_out = _make_fake_qmp_socket(incoming)

        with mock.patch("vmtest.socket.socket", return_value=fake_sock) as sock_ctor, \
                mock.patch("vmtest.time.sleep") as sleep_mock:
            qmp = vmtest.Qmp("/tmp/fake-qmp.sock")
            reply_ok = qmp.cmd("query-status")
            reply_err = qmp.cmd("unknown-cmd")
            qmp.type("a-b\nc d/1")

        sock_ctor.assert_called_once_with(vmtest.socket.AF_UNIX)
        fake_sock.settimeout.assert_called_once_with(60)
        fake_sock.connect.assert_called_once_with("/tmp/fake-qmp.sock")
        self.assertEqual(reply_ok, {"return": {}})
        self.assertEqual(reply_err, {"error": {"class": "GenericError", "desc": "bad"}})

        sent = [json.loads(line) for line in raw_out.getvalue().decode().splitlines()]
        self.assertEqual(sent[0], {"execute": "qmp_capabilities", "arguments": {}})
        self.assertEqual(sent[1], {"execute": "query-status", "arguments": {}})
        self.assertEqual(sent[2], {"execute": "unknown-cmd", "arguments": {}})
        qcodes = [msg["arguments"]["keys"][0]["data"] for msg in sent[3:]]
        self.assertEqual(qcodes, ["a", "minus", "b", "ret", "c", "spc", "d", "slash", "1"])
        self.assertEqual(sleep_mock.call_args_list, [mock.call(0.08)] * 9)


class HelpersAndMainBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.vm_dir = os.path.join(self.tmpdir.name, "vm")
        self.repo_dir = os.path.join(self.tmpdir.name, "repo")
        os.makedirs(self.vm_dir, exist_ok=True)
        os.makedirs(self.repo_dir, exist_ok=True)
        vmtest.configure(vmtest.parse_args(["xfce", self.repo_dir, self.vm_dir, "2231"]))
        os.makedirs(vmtest.RUN, exist_ok=True)

    def test_pin_host_key_strips_comment_and_pins_port(self):
        with open(os.path.join(self.vm_dir, "host_key.pub"), "w", encoding="utf-8") as f:
            f.write("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey root@archvm\n")
        vmtest.pin_host_key()
        with open(vmtest.KNOWN_HOSTS, encoding="utf-8") as f:
            self.assertEqual(f.read(), "[127.0.0.1]:2231 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey\n")

    def test_check_formats_pass_and_fail_and_persists_logs(self):
        vmtest.check("booted", True, "ignored detail")
        vmtest.check("session failed", False, "timeout")
        vmtest.check("plain fail", False)

        expected = [
            "PASS: xfce: booted",
            "FAIL: xfce: session failed (timeout)",
            "FAIL: xfce: plain fail",
        ]
        self.assertEqual(vmtest.results, expected)
        with open(vmtest.RESULT, encoding="utf-8") as f:
            self.assertEqual(f.read(), "\n".join(expected) + "\n")
        with open(os.path.join(vmtest.RUN, "driver.log"), encoding="utf-8") as f:
            log_text = f.read()
        for line in expected:
            self.assertIn(line, log_text)

    def test_ssh_passes_pinned_options_and_decodes_invalid_utf8(self):
        fake_proc = SimpleNamespace(returncode=0, stdout=b"ok-\xff\n", stderr=b"warn-\xfe")
        with mock.patch("vmtest.subprocess.run", return_value=fake_proc) as run_mock:
            rc, out, err = vmtest.ssh("echo hi", timeout=42, stdin=b"payload")

        self.assertEqual(rc, 0)
        self.assertEqual(out, "ok-\ufffd\n")
        self.assertEqual(err, "warn-\ufffd")
        cmd = run_mock.call_args[0][0]
        self.assertEqual(cmd[0], "ssh")
        self.assertIn(os.path.join(self.vm_dir, "id_vm"), cmd)
        self.assertIn("2231", cmd)
        self.assertIn(f"UserKnownHostsFile={vmtest.KNOWN_HOSTS}", cmd)
        self.assertEqual(run_mock.call_args.kwargs["timeout"], 42)
        self.assertEqual(run_mock.call_args.kwargs["input"], b"payload")

    def test_wait_ssh_retries_timeout_and_expires(self):
        with mock.patch(
            "vmtest.ssh",
            side_effect=[subprocess.TimeoutExpired("ssh", 15), (255, "", ""), (0, "", "")],
        ) as ssh_mock, mock.patch("vmtest.time.time", side_effect=[0.0, 1.0, 4.0, 7.0]), \
                mock.patch("vmtest.time.sleep") as sleep_mock:
            self.assertTrue(vmtest.wait_ssh(limit=30))
        self.assertEqual(ssh_mock.call_count, 3)
        self.assertEqual(sleep_mock.call_count, 2)

        with mock.patch("vmtest.ssh", return_value=(255, "", "")) as ssh_mock, \
                mock.patch("vmtest.time.time", side_effect=[100.0, 101.0, 111.0]), \
                mock.patch("vmtest.time.sleep"):
            self.assertFalse(vmtest.wait_ssh(limit=10))
        self.assertEqual(ssh_mock.call_count, 1)

    def test_launcher_stdout_returns_stripped_combined_output(self):
        with mock.patch("vmtest.ssh", return_value=(0, "/dev/tty1\n", "")) as ssh_mock:
            self.assertEqual(vmtest.launcher_stdout(), "/dev/tty1")
        ssh_mock.assert_called_once_with(
            f"pid=$(pgrep -o -u {vmtest.USER} -t tty1) && readlink /proc/$pid/fd/1"
        )

    def test_main_cli_error_returns_nonzero_without_creating_run_dir(self):
        stderr = io.StringIO()
        with redirect_stderr(stderr):
            rc = vmtest.main(["invalid-de", self.repo_dir, self.vm_dir, "2231"])
        self.assertNotEqual(rc, 0)
        self.assertIn("Unknown target desktop", stderr.getvalue())
        self.assertFalse(os.path.exists(os.path.join(self.vm_dir, "run-invalid-de")))

        proc = subprocess.run(
            [sys.executable, "-B", os.path.join(QEMU_DIR, "vmtest.py"), "xfce", self.repo_dir, self.vm_dir, "0"],
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("SSH port out of range", proc.stderr)

    def test_main_exception_writes_done_and_kills_unresponsive_qemu(self):
        with open(os.path.join(self.vm_dir, "host_key.pub"), "w", encoding="utf-8") as f:
            f.write("ssh-ed25519 AAAATESTKEY\n")
        fake_proc = mock.MagicMock()
        fake_proc.wait.side_effect = subprocess.TimeoutExpired("qemu", 60)

        with mock.patch("vmtest.boot", return_value=fake_proc), \
                mock.patch("vmtest.Qmp", side_effect=OSError("qmp connect failed")), \
                mock.patch("vmtest.ssh") as ssh_mock:
            rc = vmtest.main(["xfce", self.repo_dir, self.vm_dir, "2231"])

        self.assertEqual(rc, 0)
        ssh_mock.assert_called_once_with("systemctl poweroff", timeout=20)
        fake_proc.wait.assert_called_once_with(timeout=60)
        fake_proc.kill.assert_called_once_with()
        with open(vmtest.RESULT, encoding="utf-8") as f:
            lines = f.read().splitlines()
        self.assertEqual(lines[0], "FAIL: xfce: driver ran without errors (OSError('qmp connect failed'))")
        self.assertEqual(lines[-1], "DONE pass=0 fail=1")

    def test_main_success_and_keep_mode_writes_done_line(self):
        with open(os.path.join(self.vm_dir, "host_key.pub"), "w", encoding="utf-8") as f:
            f.write("ssh-ed25519 AAAATESTKEY\n")
        fake_proc = mock.MagicMock(pid=9999)

        def fake_subprocess_run(cmd, **kwargs):
            if cmd[:2] == ["git", "-C"]:
                return SimpleNamespace(returncode=0, stdout=b"install.sh\0", stderr=b"")
            if cmd[0] == "tar":
                return SimpleNamespace(returncode=0, stdout=b"tarbytes", stderr=b"")
            raise AssertionError(f"unexpected subprocess.run: {cmd}")

        def fake_ssh(cmd, timeout=600, stdin=None):
            if "journalctl" in cmd:
                return (0, "", "")
            return (0, "ok", "")

        with mock.patch("vmtest.boot", return_value=fake_proc), \
                mock.patch("vmtest.Qmp"), \
                mock.patch("vmtest.wait_ssh", return_value=True), \
                mock.patch("vmtest.subprocess.run", side_effect=fake_subprocess_run), \
                mock.patch("vmtest.ssh", side_effect=fake_ssh), \
                mock.patch("vmtest.os.path.lexists", return_value=True), \
                mock.patch("vmtest.reboot_and_login", return_value=True), \
                mock.patch("vmtest.session_checks"), \
                mock.patch("vmtest.launcher_stdout", side_effect=["/dev/tty1", "socket:[123]"]), \
                mock.patch.dict(os.environ, {"LIGHTXDM_VM_KEEP": "0"}):
            rc = vmtest.main(["xfce", self.repo_dir, self.vm_dir, "2231"])

        self.assertEqual(rc, 0)
        fake_proc.wait.assert_called_once_with(timeout=60)
        with open(vmtest.RESULT, encoding="utf-8") as f:
            lines = f.read().splitlines()
        self.assertEqual(lines[-1], "DONE pass=7 fail=0")

        with mock.patch("vmtest.boot", return_value=fake_proc), \
                mock.patch("vmtest.Qmp"), \
                mock.patch("vmtest.wait_ssh", return_value=True), \
                mock.patch("vmtest.subprocess.run", side_effect=fake_subprocess_run), \
                mock.patch("vmtest.ssh", return_value=(0, f"enabled for {vmtest.USER}", "")), \
                mock.patch("vmtest.os.path.lexists", return_value=True), \
                mock.patch("vmtest.recovery_checks"), \
                mock.patch.dict(os.environ, {"LIGHTXDM_VM_KEEP": "1"}):
            rc_keep = vmtest.main(["xfce+recovery", self.repo_dir, self.vm_dir, "2231"])

        self.assertEqual(rc_keep, 0)
        with open(vmtest.RESULT, encoding="utf-8") as f:
            kept_lines = f.read().splitlines()
        self.assertTrue(kept_lines[-1].endswith(" kept"))
        self.assertIn("fail=0 kept", kept_lines[-1])


class VmPhaseHelpersTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.vm_dir = os.path.join(self.tmpdir.name, "vm")
        self.repo_dir = os.path.join(self.tmpdir.name, "repo")
        os.makedirs(self.vm_dir, exist_ok=True)
        os.makedirs(self.repo_dir, exist_ok=True)

    def _use_spec(self, spec):
        vmtest.configure(vmtest.parse_args([spec, self.repo_dir, self.vm_dir, "2231"]))
        os.makedirs(vmtest.RUN, exist_ok=True)

    def test_boot_removes_stale_qmp_socket_sets_tmpdir_and_waits_for_socket(self):
        self._use_spec("xfce")
        with open(vmtest.QMP_SOCK, "w", encoding="utf-8") as f:
            f.write("stale")

        fake_proc = mock.MagicMock(pid=4321)
        exists_calls = 0

        def fake_exists(path):
            nonlocal exists_calls
            if path != vmtest.QMP_SOCK:
                return False
            exists_calls += 1
            return exists_calls in (1, 3)  # 1st check triggers remove(); 3rd check ends QMP poll loop

        with mock.patch("vmtest.os.path.exists", side_effect=fake_exists), \
                mock.patch("vmtest.os.remove") as remove_mock, \
                mock.patch("vmtest.subprocess.Popen", return_value=fake_proc) as popen_mock, \
                mock.patch("vmtest.time.sleep") as sleep_mock:
            proc = vmtest.boot()

        self.assertIs(proc, fake_proc)
        remove_mock.assert_called_once_with(vmtest.QMP_SOCK)
        args = popen_mock.call_args[0][0]
        self.assertEqual(args[0], "qemu-system-x86_64")
        self.assertIn("-snapshot", args)
        self.assertIn("user,id=n0,hostfwd=tcp:127.0.0.1:2231-:22", args)
        self.assertIn(f"unix:{vmtest.QMP_SOCK},server=on,wait=off", args)
        self.assertTrue(popen_mock.call_args.kwargs["start_new_session"])
        self.assertEqual(popen_mock.call_args.kwargs["env"]["TMPDIR"], vmtest.RUN)
        self.assertEqual(sleep_mock.call_count, 1)

    def test_reboot_and_login_handles_boot_id_failure_password_and_autologin(self):
        self._use_spec("xfce")
        qmp = mock.MagicMock()

        with mock.patch("vmtest.ssh", side_effect=subprocess.TimeoutExpired("ssh", 15)):
            self.assertFalse(vmtest.reboot_and_login(qmp, "login1"))
        self.assertEqual(vmtest.results[-1], "FAIL: xfce: login1: VM back after reboot (ssh timed out)")
        qmp.type.assert_not_called()

        self._use_spec("xfce")
        ssh_replies = [
            (0, "boot-1\n", ""),
            subprocess.TimeoutExpired("ssh", 20),  # systemctl reboot timeout is ignored
            (0, "boot-1\n", ""),
            subprocess.TimeoutExpired("ssh", 15),
            (0, "boot-2\n", ""),
            (0, "inactive\n", ""),
            (0, "active\n", ""),
        ]
        with mock.patch("vmtest.ssh", side_effect=ssh_replies), \
                mock.patch("vmtest.time.time", side_effect=[0.0, 1.0, 2.0, 3.0, 4.0]), \
                mock.patch("vmtest.time.sleep"):
            self.assertTrue(vmtest.reboot_and_login(qmp, "login1"))
        self.assertEqual(vmtest.results[-1], "PASS: xfce: login1: VM back after reboot")
        self.assertEqual(
            qmp.type.call_args_list,
            [mock.call(vmtest.USER + "\n"), mock.call(vmtest.PASSWORD + "\n")],
        )

        self._use_spec("xfce+autologin")
        qmp.reset_mock()
        with mock.patch(
            "vmtest.ssh",
            side_effect=[(0, "boot-2\n", ""), (0, "", ""), (0, "boot-3\n", ""), (0, "active\n", "")],
        ), mock.patch("vmtest.time.time", side_effect=[10.0, 11.0]), mock.patch("vmtest.time.sleep"):
            self.assertTrue(vmtest.reboot_and_login(qmp, "login1"))
        qmp.type.assert_not_called()

    def test_relogin_uses_dbus_or_loginctl_and_checks_display_exit(self):
        self._use_spec("plasma+relogin")
        qmp = mock.MagicMock()
        seen_cmds = []

        def plasma_ssh(cmd, timeout=600, stdin=None):
            seen_cmds.append(cmd)
            if "org.kde.Shutdown" in cmd:
                return (0, "", "")
            if cmd == f"pgrep -u {vmtest.USER} -x kwin_wayland":
                return (1, "", "")
            if cmd == "systemctl is-active getty@tty1":
                return (0, "active\n", "")
            if "ps -u " in cmd:
                return (0, "gpg-agent\n", "")
            raise AssertionError(f"unexpected ssh cmd: {cmd}")

        with mock.patch("vmtest.ssh", side_effect=plasma_ssh), \
                mock.patch("vmtest.time.monotonic", side_effect=[0.0, 1.0, 2.0, 3.0]), \
                mock.patch("vmtest.time.sleep"):
            self.assertTrue(vmtest.relogin(qmp, "relogin"))
        self.assertTrue(any("org.kde.Shutdown logout" in c for c in seen_cmds))
        self.assertEqual(vmtest.results[-1], "PASS: plasma+relogin: relogin: logged out through the desktop and the login prompt is back")
        self.assertEqual(qmp.type.call_args_list, [mock.call(vmtest.USER + "\n"), mock.call(vmtest.PASSWORD + "\n")])

        self._use_spec("i3+relogin")
        qmp.reset_mock()

        def i3_timeout_ssh(cmd, timeout=600, stdin=None):
            if cmd == f"loginctl terminate-user {vmtest.USER}":
                return (0, "", "")
            if cmd == "pgrep -x Xorg":
                return (0, "123\n", "")
            if cmd == "systemctl is-active getty@tty1":
                return (3, "inactive\n", "")
            if "ps -u " in cmd:
                return (0, "Xorg\n", "")
            raise AssertionError(f"unexpected ssh cmd: {cmd}")

        with mock.patch("vmtest.ssh", side_effect=i3_timeout_ssh), \
                mock.patch("vmtest.time.monotonic", side_effect=[0.0, 1.0, 2.0, 3.0, 4.0, 150.0, 150.0]), \
                mock.patch("vmtest.time.sleep"):
            self.assertFalse(vmtest.relogin(qmp, "relogin"))
        self.assertIn("relogin: forced logout (loginctl terminate-user)", vmtest.results[-1])
        self.assertIn("Xorg: running; getty@tty1: inactive", vmtest.results[-1])
        qmp.type.assert_not_called()

        self._use_spec("i3+relogin")
        with mock.patch("vmtest.ssh", side_effect=subprocess.TimeoutExpired("ssh", 20)):
            self.assertFalse(vmtest.relogin(qmp, "relogin"))
        self.assertIn("logout command timed out", vmtest.results[-1])

    def test_recovery_checks_pauses_probes_shell_restores_and_runs_session_checks(self):
        self._use_spec("gnome+recovery")
        qmp = mock.MagicMock()

        def rec_ssh(cmd, timeout=600, stdin=None):
            if "recovery-backup" in cmd:
                return (0, "", "")
            if cmd == f"test -f /home/{vmtest.USER}/.config/lightxdm/no-autostart":
                return (0, "", "")
            if cmd == "systemctl is-active getty@tty1":
                return (0, "active\n", "")
            if cmd == f"test -f /home/{vmtest.USER}/recovery-shell-ok":
                return (0, "", "")
            raise AssertionError(f"unexpected recovery ssh cmd: {cmd}")

        with mock.patch("vmtest.ssh", side_effect=rec_ssh), \
                mock.patch("vmtest.reboot_and_login", return_value=True) as reboot_mock, \
                mock.patch("vmtest.session_checks") as session_mock, \
                mock.patch("vmtest.time.monotonic", return_value=1.0):
            vmtest.recovery_checks(qmp)

        reboot_mock.assert_called_once_with(qmp, "recovery")
        self.assertEqual(
            qmp.type.call_args_list,
            [mock.call(f"touch /home/{vmtest.USER}/recovery-shell-ok\n"), mock.call("exit\n")],
        )
        session_mock.assert_called_once_with("recovery", qmp)
        self.assertEqual(len(vmtest.results), 5)
        self.assertTrue(all(r.startswith("PASS: gnome+recovery: ") for r in vmtest.results))

        self._use_spec("gnome+recovery")
        qmp.reset_mock()
        with mock.patch("vmtest.ssh", return_value=(1, "", "perm denied")):
            vmtest.recovery_checks(qmp)
        self.assertEqual(vmtest.results, ["FAIL: gnome+recovery: recovery: failing launcher installed as the user (perm denied)"])
        qmp.type.assert_not_called()

    def test_wait_proc_user_bus_and_lock_keyring(self):
        self._use_spec("plasma+relogin")
        with mock.patch("vmtest.ssh", side_effect=[(1, "", ""), (0, "100\n", "")]), \
                mock.patch("vmtest.time.time", side_effect=[0.0, 1.0, 6.0]), \
                mock.patch("vmtest.time.sleep"):
            self.assertTrue(vmtest.wait_proc("plasmashell", limit=20))

        with mock.patch("vmtest.ssh", return_value=(1, "", "")), \
                mock.patch("vmtest.time.time", side_effect=[10.0, 11.0, 35.0]), \
                mock.patch("vmtest.time.sleep"):
            self.assertFalse(vmtest.wait_proc("plasmashell", limit=20))

        ssh_calls = []

        def fake_ssh(cmd, timeout=600, stdin=None):
            ssh_calls.append(cmd)
            if "get-property" in cmd:
                return (0, "b true\n", "")
            return (0, "", "")

        with mock.patch("vmtest.ssh", side_effect=fake_ssh):
            vmtest.lock_keyring("relogin")

        self.assertEqual(len(ssh_calls), 2)
        self.assertIn("Lock ao 1 /org/freedesktop/secrets/collection/kdewallet", ssh_calls[0])
        self.assertIn("sudo -u tester DBUS_SESSION_BUS_ADDRESS=", ssh_calls[0])
        self.assertEqual(
            vmtest.results[-1],
            "PASS: plasma+relogin: relogin: keyring collection 'kdewallet' is locked before logout",
        )

    def test_session_checks_covers_wayland_lxqt_and_autologin_modes(self):
        self._use_spec("plasma")
        qmp = mock.MagicMock()
        gpg_calls = 0
        pkcheck_calls = 0

        def plasma_ssh(cmd, timeout=600, stdin=None):
            nonlocal gpg_calls, pkcheck_calls
            if "loginctl list-sessions" in cmd:
                return (0, "TTY=tty1\nService=login\nActive=yes\n", "")
            if "XDG_SESSION_TYPE=wayland" in cmd:
                return (0, "", "")
            if cmd == "pgrep -x Xorg":
                return (1, "", "")
            if "gpg-connect-agent" in cmd:
                gpg_calls += 1
                return (0, "WAYLAND_DISPLAY=wayland-0\n" if gpg_calls >= 2 else "", "")
            if "ksecretd --pam-login" in cmd:
                return (0, "42\n", "")
            if "org.freedesktop.Secret.Collection Locked" in cmd:
                return (0, "b false\n", "")
            if "--check-keyring kwallet" in cmd:
                return (0, "collection 'kdewallet' is unlocked\n", "")
            if "pkcheck" in cmd:
                pkcheck_calls += 1
                return (0, "rc=124\n" if pkcheck_calls >= 2 else "rc=2\n", "")
            if "grep -E 'polkit|policykit|lxpolkit'" in cmd:
                return (0, "polkit-kde-authentication-agent-1\n", "")
            raise AssertionError(f"unexpected plasma session_checks cmd: {cmd}")

        with mock.patch("vmtest.wait_proc", return_value=True), \
                mock.patch("vmtest.ssh", side_effect=plasma_ssh), \
                mock.patch("vmtest.time.sleep"):
            vmtest.session_checks("login1", qmp)

        self.assertTrue(all(r.startswith("PASS: plasma: ") for r in vmtest.results), vmtest.results)
        self.assertEqual(len(vmtest.results), 10)
        qmp.cmd.assert_called_once_with(
            "screendump", filename=os.path.join(vmtest.RUN, "login1.png"), format="png"
        )

        self._use_spec("lxqt")
        qmp.reset_mock()
        waited_procs = []

        def fake_wait_proc(name, limit=240):
            waited_procs.append(name)
            return True

        def lxqt_ssh(cmd, timeout=600, stdin=None):
            if "session.conf" in cmd:
                return (0, "[General]\nwindow_manager=/usr/bin/openbox\n", "")
            if "loginctl list-sessions" in cmd:
                return (0, "TTY=tty1\nService=login\nActive=yes\n", "")
            if "XDG_SESSION_TYPE=x11" in cmd:
                return (0, "", "")
            if cmd == "pgrep -x Xorg":
                return (0, "99\n", "")
            if "org.freedesktop.Secret.Collection Locked" in cmd:
                return (0, "b false\n", "")
            if "--check-keyring gnome" in cmd:
                return (0, "collection 'login' is unlocked\n", "")
            if "pkcheck" in cmd:
                return (0, "rc=124\n", "")
            if "grep -E 'polkit|policykit|lxpolkit'" in cmd:
                return (0, "lxqt-policykit-agent\n", "")
            raise AssertionError(f"unexpected lxqt cmd: {cmd}")

        with mock.patch("vmtest.wait_proc", side_effect=fake_wait_proc), \
                mock.patch("vmtest.ssh", side_effect=lxqt_ssh), \
                mock.patch("vmtest.time.sleep"):
            vmtest.session_checks("login1", qmp)

        qmp.type.assert_called_once_with("\n")
        self.assertEqual(waited_procs, ["lxqt-session", "lxqt-panel", "openbox"])
        self.assertTrue(all(r.startswith("PASS: lxqt: ") for r in vmtest.results), vmtest.results)

        self._use_spec("xfce+autologin")
        qmp.reset_mock()

        def autologin_ssh(cmd, timeout=600, stdin=None):
            if "Secret" in cmd or "--check-keyring" in cmd or "ksecretd" in cmd:
                raise AssertionError(f"autologin must skip keyring checks: {cmd}")
            if "loginctl list-sessions" in cmd:
                return (0, "TTY=tty1\nService=login\nActive=yes\n", "")
            if "XDG_SESSION_TYPE=x11" in cmd or cmd == "pgrep -x Xorg":
                return (0, "", "")
            if "pkcheck" in cmd:
                return (0, "rc=124\n", "")
            if "grep -E 'polkit|policykit|lxpolkit'" in cmd:
                return (0, "polkit-gnome-authentication-agent-1\n", "")
            raise AssertionError(f"unexpected autologin cmd: {cmd}")

        with mock.patch("vmtest.wait_proc", return_value=True), \
                mock.patch("vmtest.ssh", side_effect=autologin_ssh), \
                mock.patch("vmtest.time.sleep"):
            vmtest.session_checks("login1", qmp)

        self.assertTrue(all(r.startswith("PASS: xfce+autologin: ") for r in vmtest.results), vmtest.results)
        self.assertEqual(len(vmtest.results), 6)


if __name__ == "__main__":
    unittest.main()
