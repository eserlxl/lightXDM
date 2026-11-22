#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025-2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for tests/check_repo_integrity.py."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

TESTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parent
CHECK_SCRIPT = TESTS_DIR / "check_repo_integrity.py"

FROZEN_POLKIT_SHA256 = "5f0b2207f050dd9f56f748c54cb2956abbc894f5bb85aecc47cdbee230316b2a"

BASE_YAML = """\
package:
  name: lightxdm
  source: release
  keep: [README.md, docs/, dotfiles/]
  post_package:
    - 'install -Dm644 -t "$pkgdir/usr/share/$pkgname" install.sh uninstall.sh enable-autologin.sh'
    - 'install -Dm644 -t "$pkgdir/usr/share/doc/$pkgname" README.md'

executables:
  source: bin
  destination: usr/bin

dotfiles:
  source: dotfiles
  destination: usr/share/$pkgname/dotfiles

pam:
  source: pam
  destination: usr/share/$pkgname/pam

alpm:
  source: alpm
  destination: usr/share/libalpm/hooks

docs:
  source: docs
  destination: usr/share/doc/$pkgname
"""

CONDITIONAL_YAML_BLOCKS = {
    "lib": "\nlib:\n  source: lib\n  destination: usr/share/$pkgname/lib\n",
    "man": "\nman:\n  source: man\n  destination: usr/share/man/man1\n",
    "completions/bash": (
        "\ncompletions_bash:\n  source: completions/bash\n"
        "  destination: usr/share/bash-completion/completions\n"
    ),
    "completions/zsh": (
        "\ncompletions_zsh:\n  source: completions/zsh\n"
        "  destination: usr/share/zsh/site-functions\n"
    ),
    "completions/fish": (
        "\ncompletions_fish:\n  source: completions/fish\n"
        "  destination: usr/share/fish/vendor_completions.d\n"
    ),
}


def _create_valid_fixture(root: Path) -> None:
    """Populate a minimal valid repository tree under root."""
    for rel_dir in ("aur", "bin", "dotfiles", "pam", "alpm", "docs", "polkit", "tests"):
        (root / rel_dir).mkdir(parents=True, exist_ok=True)

    (root / "aur" / "aurgen.install.yaml").write_text(BASE_YAML, encoding="utf-8")
    (root / "install.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (root / "enable-autologin.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
    (root / "README.md").write_text("# lightXDM\n", encoding="utf-8")
    (root / "uninstall.sh").write_text(
        f"LIGHTXDM_OLD_POLKIT_HASHES=(\n  {FROZEN_POLKIT_SHA256}\n)\n",
        encoding="utf-8",
    )
    (root / "pam" / "login-pacnew-note.sh").write_text("#!/usr/bin/env sh\n", encoding="utf-8")
    (root / "alpm" / "lightxdm-login-pacnew.hook").write_text(
        "[Action]\nExec = /usr/bin/sh /usr/share/lightxdm/pam/login-pacnew-note.sh\n",
        encoding="utf-8",
    )

    shutil.copyfile(REPO_ROOT / "polkit" / "49-nopasswd.rules", root / "polkit" / "49-nopasswd.rules")
    shutil.copyfile(REPO_ROOT / "LICENSE", root / "LICENSE")

    (root / "lint.sh").write_text(
        '#!/usr/bin/env bash\nPYTHONDONTWRITEBYTECODE=1 python3 -B "$SCRIPT_DIR/tests/check_repo_integrity.py"\n',
        encoding="utf-8",
    )
    (root / "tests" / "qemu-arch.sh").write_text(
        '#!/usr/bin/env bash\nPYTHONDONTWRITEBYTECODE=1 python3 -B "$REPO_ROOT/tests/qemu/vmtest.py"\n',
        encoding="utf-8",
    )
    (root / "tests" / "run.sh").write_text(
        "#!/usr/bin/env bash\n"
        "cat >\"$tmp/python3\" <<'EOF'\n"
        "#!/usr/bin/env bash\n"
        "exit 1\n"
        "EOF\n"
        "python3 - <<'PY'\n"
        "print('tests/foo.py')\n"
        "PY\n"
        "python3 -c 'print(123)'\n"
        "py_vm_output=\"$(PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s \"$REPO_ROOT/tests\" -p \"test_*.py\" 2>&1)\"\n",
        encoding="utf-8",
    )


def _run_integrity(root: Path) -> subprocess.CompletedProcess[str]:
    env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}
    return subprocess.run(
        [sys.executable, "-B", str(CHECK_SCRIPT), "--root", str(root)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


class RepoIntegrityTests(unittest.TestCase):
    def test_valid_fixture_passes_without_optional_dirs(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            _create_valid_fixture(root)
            proc = _run_integrity(root)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("Repository integrity checks passed.", proc.stdout)
            pycache_dirs = [p for p in root.rglob("__pycache__")]
            self.assertEqual(pycache_dirs, [])

    def test_missing_aurgen_source_directory_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            _create_valid_fixture(root)
            (root / "docs").rmdir()
            proc = _run_integrity(root)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("source directory missing: docs", proc.stderr)

    def test_missing_post_package_target_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            _create_valid_fixture(root)
            (root / "enable-autologin.sh").unlink()
            proc = _run_integrity(root)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("enable-autologin.sh", proc.stderr)

    def test_package_keep_list_must_keep_readme_docs_and_dotfiles(self):
        full_keep = "  keep: [README.md, docs/, dotfiles/]\n"
        self.assertIn(full_keep, BASE_YAML)
        cases = {
            "README.md": "  keep: [docs/, dotfiles/]\n",
            "docs/": "  keep: [README.md, dotfiles/]\n",
            "dotfiles/": "  keep: [README.md, docs/]\n",
        }
        for dropped, keep_line in cases.items():
            with self.subTest(dropped=dropped):
                with tempfile.TemporaryDirectory() as tmpdir:
                    root = Path(tmpdir)
                    _create_valid_fixture(root)
                    yaml_path = root / "aur" / "aurgen.install.yaml"
                    yaml_path.write_text(BASE_YAML.replace(full_keep, keep_line), encoding="utf-8")
                    proc = _run_integrity(root)
                    self.assertNotEqual(proc.returncode, 0)
                    self.assertIn(f"package.keep missing entry: {dropped}", proc.stderr)

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            _create_valid_fixture(root)
            yaml_path = root / "aur" / "aurgen.install.yaml"

            # aurgen keeps a directory only through a trailing-slash prefix entry.
            yaml_path.write_text(
                BASE_YAML.replace(full_keep, "  keep: [README.md, docs, dotfiles/]\n"), encoding="utf-8"
            )
            no_slash = _run_integrity(root)
            self.assertNotEqual(no_slash.returncode, 0)
            self.assertIn("package.keep missing entry: docs/", no_slash.stderr)

            yaml_path.write_text(BASE_YAML.replace(full_keep, ""), encoding="utf-8")
            missing = _run_integrity(root)
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("package.keep is missing", missing.stderr)

            block_keep = "  keep:\n    - README.md\n    - 'docs/'\n    - dotfiles/\n"
            yaml_path.write_text(BASE_YAML.replace(full_keep, block_keep), encoding="utf-8")
            block = _run_integrity(root)
            self.assertEqual(block.returncode, 0, block.stderr)

            yaml_path.write_text(
                BASE_YAML.replace(full_keep, "  keep:\n    - README.md\n    - docs/\n"), encoding="utf-8"
            )
            block_short = _run_integrity(root)
            self.assertNotEqual(block_short.returncode, 0)
            self.assertIn("package.keep missing entry: dotfiles/", block_short.stderr)

            yaml_path.write_text(BASE_YAML, encoding="utf-8")
            full = _run_integrity(root)
            self.assertEqual(full.returncode, 0, full.stderr)

    def test_conditional_optional_dirs_fail_when_unmapped_and_pass_when_mapped(self):
        for rel_dir, yaml_block in CONDITIONAL_YAML_BLOCKS.items():
            with self.subTest(optional_dir=rel_dir):
                with tempfile.TemporaryDirectory() as tmpdir:
                    root = Path(tmpdir)
                    _create_valid_fixture(root)
                    (root / rel_dir).mkdir(parents=True, exist_ok=True)

                    unmapped = _run_integrity(root)
                    self.assertNotEqual(unmapped.returncode, 0)
                    self.assertIn(rel_dir, unmapped.stderr)

                    yaml_path = root / "aur" / "aurgen.install.yaml"
                    yaml_path.write_text(BASE_YAML + yaml_block, encoding="utf-8")
                    mapped = _run_integrity(root)
                    self.assertEqual(mapped.returncode, 0, mapped.stderr)

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            _create_valid_fixture(root)
            for rel_dir in CONDITIONAL_YAML_BLOCKS:
                (root / rel_dir).mkdir(parents=True, exist_ok=True)
            wrong_yaml = BASE_YAML + "\nlib:\n  source: lib\n  destination: usr/share/wrong/lib\n"
            (root / "aur" / "aurgen.install.yaml").write_text(wrong_yaml, encoding="utf-8")
            wrong = _run_integrity(root)
            self.assertNotEqual(wrong.returncode, 0)
            self.assertIn("usr/share/$pkgname/lib", wrong.stderr)

            full_yaml = BASE_YAML + "".join(CONDITIONAL_YAML_BLOCKS.values())
            (root / "aur" / "aurgen.install.yaml").write_text(full_yaml, encoding="utf-8")
            all_mapped = _run_integrity(root)
            self.assertEqual(all_mapped.returncode, 0, all_mapped.stderr)

    def test_broken_alpm_hook_exec_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            _create_valid_fixture(root)
            hook_path = root / "alpm" / "lightxdm-login-pacnew.hook"
            hook_path.write_text(
                "[Action]\nExec = /usr/bin/sh /usr/share/lightxdm/other/login-pacnew-note.sh\n",
                encoding="utf-8",
            )
            proc = _run_integrity(root)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn("pam destination", proc.stderr)

            hook_path.write_text(
                "[Action]\nExec = /usr/bin/sh /usr/share/lightxdm/pam/missing.sh\n",
                encoding="utf-8",
            )
            proc_missing = _run_integrity(root)
            self.assertNotEqual(proc_missing.returncode, 0)
            self.assertIn("missing on disk", proc_missing.stderr)

    def test_altered_frozen_files_or_uninstall_hash_fail(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            _create_valid_fixture(root)
            polkit_path = root / "polkit" / "49-nopasswd.rules"
            original_polkit = polkit_path.read_bytes()
            polkit_path.write_bytes(original_polkit + b"\n// drift\n")
            proc_polkit = _run_integrity(root)
            self.assertNotEqual(proc_polkit.returncode, 0)
            self.assertIn("polkit/49-nopasswd.rules", proc_polkit.stderr)

            polkit_path.write_bytes(original_polkit)
            license_path = root / "LICENSE"
            original_license = license_path.read_bytes()
            license_path.write_bytes(original_license + b"drift")
            proc_license = _run_integrity(root)
            self.assertNotEqual(proc_license.returncode, 0)
            self.assertIn("LICENSE", proc_license.stderr)

            license_path.write_bytes(original_license)
            (root / "uninstall.sh").write_text("LIGHTXDM_OLD_POLKIT_HASHES=()\n", encoding="utf-8")
            proc_uninstall = _run_integrity(root)
            self.assertNotEqual(proc_uninstall.returncode, 0)
            self.assertIn("LIGHTXDM_OLD_POLKIT_HASHES", proc_uninstall.stderr)

    def test_unflagged_python_invocations_fail(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            _create_valid_fixture(root)
            qemu_sh = root / "tests" / "qemu-arch.sh"
            qemu_sh.write_text(
                '#!/usr/bin/env bash\npython3 "$REPO_ROOT/tests/qemu/vmtest.py"\n',
                encoding="utf-8",
            )
            proc_qemu = _run_integrity(root)
            self.assertNotEqual(proc_qemu.returncode, 0)
            self.assertIn("tests/qemu-arch.sh", proc_qemu.stderr)
            self.assertIn("vmtest.py", proc_qemu.stderr)

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            _create_valid_fixture(root)
            run_sh = root / "tests" / "run.sh"
            run_sh.write_text(
                '#!/usr/bin/env bash\npython3 -m unittest discover -s "$REPO_ROOT/tests"\n',
                encoding="utf-8",
            )
            proc_unit = _run_integrity(root)
            self.assertNotEqual(proc_unit.returncode, 0)
            self.assertIn("tests/run.sh", proc_unit.stderr)
            self.assertIn("unittest", proc_unit.stderr)

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            _create_valid_fixture(root)
            cases_dir = root / "tests" / "cases"
            cases_dir.mkdir(parents=True, exist_ok=True)
            (cases_dir / "bad.sh").write_text(
                "#!/usr/bin/env bash\npython3 tests/helper.py\n",
                encoding="utf-8",
            )
            proc_cases = _run_integrity(root)
            self.assertNotEqual(proc_cases.returncode, 0)
            self.assertIn("tests/cases/bad.sh", proc_cases.stderr)

    def test_wrapper_path_option_and_subshell_python_invocations(self):
        bad_lines = [
            "env -u SUDO_USER python3 tests/helper.py",
            "command -p python3 tests/helper.py",
            "/usr/bin/python3 -m unittest discover -s tests",
            "python3 -Ximporttime tests/helper.py",
            "python3 -WBytecode tests/helper.py",
            "python3 -Wdefault:compile tests/helper.py",
        ]
        for line in bad_lines:
            with self.subTest(bad_line=line):
                with tempfile.TemporaryDirectory() as tmpdir:
                    root = Path(tmpdir)
                    _create_valid_fixture(root)
                    (root / "tests" / "run.sh").write_text(f"#!/usr/bin/env bash\n{line}\n", encoding="utf-8")
                    proc = _run_integrity(root)
                    self.assertNotEqual(proc.returncode, 0, proc.stdout)
                    self.assertIn("tests/run.sh:2:", proc.stderr)

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            _create_valid_fixture(root)
            (root / "tests" / "run.sh").write_text(
                "#!/usr/bin/env bash\nout=$(python3 tests/helper.py)\n",
                encoding="utf-8",
            )
            proc_sub = _run_integrity(root)
            self.assertNotEqual(proc_sub.returncode, 0)
            err_lines = [ln for ln in proc_sub.stderr.splitlines() if "tests/run.sh:2:" in ln]
            self.assertEqual(len(err_lines), 1, proc_sub.stderr)

        good_lines = [
            'PYTHONDONTWRITEBYTECODE="1" python3 tests/helper.py',
            "env -u SUDO_USER PYTHONDONTWRITEBYTECODE=1 python3 tests/helper.py",
            "command -p -v python3",
            "command -pv python3",
        ]
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            _create_valid_fixture(root)
            (root / "tests" / "run.sh").write_text(
                "#!/usr/bin/env bash\n" + "\n".join(good_lines) + "\n",
                encoding="utf-8",
            )
            proc_good = _run_integrity(root)
            self.assertEqual(proc_good.returncode, 0, proc_good.stderr)

    def test_optional_tests_shell_scripts_are_scanned_for_python_invocations(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            _create_valid_fixture(root)
            docker_sh = root / "tests" / "docker-arch.sh"
            docker_sh.write_text("#!/usr/bin/env bash\npython3 tests/helper.py\n", encoding="utf-8")
            proc_bad = _run_integrity(root)
            self.assertNotEqual(proc_bad.returncode, 0)
            self.assertIn("tests/docker-arch.sh:2:", proc_bad.stderr)

            docker_sh.write_text("#!/usr/bin/env bash\nPYTHONDONTWRITEBYTECODE=1 python3 -B tests/helper.py\n", encoding="utf-8")
            proc_ok = _run_integrity(root)
            self.assertEqual(proc_ok.returncode, 0, proc_ok.stderr)

    def test_bytecode_artifacts_fail_unless_excluded(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            _create_valid_fixture(root)
            (root / ".git" / "__pycache__").mkdir(parents=True)
            (root / ".planwright" / "__pycache__").mkdir(parents=True)
            (root / ".qb" / "__pycache__").mkdir(parents=True)
            proc_clean = _run_integrity(root)
            self.assertEqual(proc_clean.returncode, 0, proc_clean.stderr)

            bad_cache = root / "tests" / "__pycache__"
            bad_cache.mkdir(parents=True)
            (bad_cache / "stale.pyc").write_bytes(b"pyc")
            proc_dirty = _run_integrity(root)
            self.assertNotEqual(proc_dirty.returncode, 0)
            self.assertIn("__pycache__", proc_dirty.stderr)
            self.assertIn(".pyc", proc_dirty.stderr)

    def test_bytecode_artifacts_ignored_local_dirs_pass(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            _create_valid_fixture(root)
            (root / "work" / "__pycache__").mkdir(parents=True)
            (root / ".remember" / "__pycache__").mkdir(parents=True)
            proc_clean = _run_integrity(root)
            self.assertEqual(proc_clean.returncode, 0, proc_clean.stderr)

            bad_cache = root / "tests" / "__pycache__"
            bad_cache.mkdir(parents=True)
            (bad_cache / "stale.pyc").write_bytes(b"pyc")
            proc_dirty = _run_integrity(root)
            self.assertNotEqual(proc_dirty.returncode, 0)
            self.assertIn("__pycache__", proc_dirty.stderr)
            self.assertIn(".pyc", proc_dirty.stderr)

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            _create_valid_fixture(root)
            deep_cache = root / "tests" / "work" / "__pycache__"
            deep_cache.mkdir(parents=True)
            (deep_cache / "stale.pyc").write_bytes(b"pyc")
            proc_deep = _run_integrity(root)
            self.assertNotEqual(proc_deep.returncode, 0)
            self.assertIn("__pycache__", proc_deep.stderr)
            self.assertIn(".pyc", proc_deep.stderr)


if __name__ == "__main__":
    unittest.main()
