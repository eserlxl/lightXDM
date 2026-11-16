#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2025-2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
"""Validate lightXDM packaging manifests, frozen SHA-256 files, and bytecode-free Python calls."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import sys

FROZEN_POLKIT_PATH = "polkit/49-nopasswd.rules"
FROZEN_POLKIT_SHA256 = "5f0b2207f050dd9f56f748c54cb2956abbc894f5bb85aecc47cdbee230316b2a"

FROZEN_LICENSE_PATH = "LICENSE"
FROZEN_LICENSE_SHA256 = "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986"

MANDATORY_COPY_SOURCES = ("bin", "dotfiles", "pam", "alpm", "docs")
MANDATORY_POST_PACKAGE_FILES = ("install.sh", "uninstall.sh", "enable-autologin.sh", "README.md")

CONDITIONAL_MAPPINGS = {
    "lib": "usr/share/$pkgname/lib",
    "man": "usr/share/man/man1",
    "completions/bash": "usr/share/bash-completion/completions",
    "completions/zsh": "usr/share/zsh/site-functions",
    "completions/fish": "usr/share/fish/vendor_completions.d",
}

SHELL_INTERPRETERS = {"sh", "/bin/sh", "/usr/bin/sh", "bash", "/bin/bash", "/usr/bin/bash"}
PYTHON_BIN_RE = re.compile(r"^python(?:3(?:\.\d+)?)?$")
SHELL_WORDS_TAKE_VALUE = {"-W", "-X", "-Q"}
TOP_KEY_RE = re.compile(r"^([A-Za-z0-9_.-]+):\s*(?:#.*)?$")
CHILD_KEY_RE = re.compile(r"^([A-Za-z0-9_.-]+):\s*(.*)$")
LIST_ITEM_RE = re.compile(r"^-\s+(.*)$")
HEREDOC_RE = re.compile(r"(?<!<)<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")


def _strip_yaml_comment(raw: str) -> str:
    """Strip an unquoted trailing YAML comment and surrounding matching quotes."""
    in_quote: str | None = None
    out: list[str] = []
    i = 0
    while i < len(raw):
        ch = raw[i]
        if in_quote is None:
            if ch in ("'", '"'):
                in_quote = ch
                out.append(ch)
            elif ch == "#" and (i == 0 or raw[i - 1].isspace()):
                break
            else:
                out.append(ch)
        else:
            out.append(ch)
            if ch == "\\" and in_quote == '"' and i + 1 < len(raw):
                i += 1
                out.append(raw[i])
            elif ch == in_quote:
                in_quote = None
        i += 1
    cleaned = "".join(out).strip()
    if len(cleaned) >= 2 and cleaned[0] == cleaned[-1] and cleaned[0] in ("'", '"'):
        return cleaned[1:-1]
    return cleaned


def parse_aurgen_yaml(yaml_path: Path) -> tuple[dict[str, dict[str, str]], list[str]]:
    """Parse top-level sections (key/value scalars) and package.post_package entries."""
    sections: dict[str, dict[str, str]] = {}
    post_package: list[str] = []

    current_section: str | None = None
    section_child_indent: int | None = None
    active_list_key: str | None = None
    active_list_indent: int | None = None

    for raw_line in yaml_path.read_text(encoding="utf-8").splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        stripped = raw_line.strip()

        if indent == 0:
            match = TOP_KEY_RE.match(stripped)
            if match:
                current_section = match.group(1)
                sections.setdefault(current_section, {})
                section_child_indent = None
                active_list_key = None
                active_list_indent = None
            continue

        if current_section is None:
            continue

        if section_child_indent is None or indent < section_child_indent:
            section_child_indent = indent

        if active_list_key is not None and active_list_indent is not None and indent > active_list_indent:
            list_match = LIST_ITEM_RE.match(stripped)
            if list_match:
                if current_section == "package" and active_list_key == "post_package":
                    post_package.append(_strip_yaml_comment(list_match.group(1)))
                continue

        if indent == section_child_indent:
            active_list_key = None
            active_list_indent = None
            child_match = CHILD_KEY_RE.match(stripped)
            if child_match:
                key, val = child_match.group(1), child_match.group(2)
                cleaned_val = _strip_yaml_comment(val)
                if cleaned_val == "":
                    active_list_key = key
                    active_list_indent = indent
                else:
                    sections[current_section][key] = cleaned_val

    return sections, post_package


def _extract_post_package_sources(commands: list[str]) -> list[str]:
    """Extract repo-relative source file operands from package.post_package install commands."""
    sources: list[str] = []
    for cmd in commands:
        try:
            tokens = shlex.split(cmd)
        except ValueError:
            tokens = cmd.split()
        if not tokens:
            continue
        i = 1 if tokens[0] == "install" else 0
        skip_next = False
        while i < len(tokens):
            tok = tokens[i]
            if skip_next:
                skip_next = False
                i += 1
                continue
            if tok in ("-t", "--target-directory", "-m", "-o", "-g"):
                skip_next = True
                i += 1
                continue
            if tok.startswith("-"):
                i += 1
                continue
            if tok.startswith("$pkgdir") or tok.startswith("${pkgdir}") or tok.startswith("/"):
                i += 1
                continue
            sources.append(tok)
            i += 1
    return sources


def _is_safe_rel_path(rel_path: str) -> bool:
    if not rel_path or rel_path.startswith("/"):
        return False
    parts = PurePosixPath(rel_path).parts
    return bool(parts) and all(part not in ("", ".", "..") for part in parts)


def check_aurgen_manifest(root: Path, errors: list[str]) -> tuple[str, str | None, str | None]:
    """Validate aur/aurgen.install.yaml sections and return (pkgname, pam_source, pam_dest)."""
    yaml_path = root / "aur" / "aurgen.install.yaml"
    if not yaml_path.is_file():
        errors.append("Missing packaging manifest: aur/aurgen.install.yaml")
        return "lightxdm", None, None

    sections, post_package = parse_aurgen_yaml(yaml_path)
    pkgname = sections.get("package", {}).get("name", "lightxdm")

    # Copy sections are top-level sections defining BOTH source: and destination:.
    copy_sections: dict[str, dict[str, str]] = {
        name: fields
        for name, fields in sections.items()
        if "source" in fields and "destination" in fields
    }

    source_to_dest: dict[str, str] = {}
    for sec_name, fields in copy_sections.items():
        src_rel = fields["source"].rstrip("/")
        dest_rel = fields["destination"].rstrip("/")
        if not _is_safe_rel_path(src_rel):
            errors.append(f"aur/aurgen.install.yaml section '{sec_name}' has invalid source path: {fields['source']!r}")
            continue
        if not dest_rel:
            errors.append(f"aur/aurgen.install.yaml section '{sec_name}' has empty destination")
            continue
        if not (root / src_rel).is_dir():
            errors.append(f"aur/aurgen.install.yaml section '{sec_name}' source directory missing: {src_rel}")
        if src_rel in source_to_dest:
            errors.append(f"aur/aurgen.install.yaml has duplicate copy source: {src_rel}")
        source_to_dest[src_rel] = dest_rel

    for req_src in MANDATORY_COPY_SOURCES:
        if req_src not in source_to_dest:
            errors.append(f"aur/aurgen.install.yaml missing mandatory copy section for source: {req_src}")

    for opt_src, expected_dest in CONDITIONAL_MAPPINGS.items():
        if (root / opt_src).is_dir():
            actual_dest = source_to_dest.get(opt_src)
            if actual_dest is None:
                errors.append(
                    f"Optional directory '{opt_src}' exists on disk but has no copy section in aur/aurgen.install.yaml"
                )
            elif actual_dest != expected_dest:
                errors.append(
                    f"aur/aurgen.install.yaml maps '{opt_src}' to '{actual_dest}', expected '{expected_dest}'"
                )

    post_sources = _extract_post_package_sources(post_package)
    for req_file in MANDATORY_POST_PACKAGE_FILES:
        if req_file not in post_sources:
            errors.append(f"aur/aurgen.install.yaml package.post_package missing target: {req_file}")
    for src_file in post_sources:
        if not _is_safe_rel_path(src_file) or not (root / src_file).is_file():
            errors.append(f"aur/aurgen.install.yaml package.post_package references missing file: {src_file}")

    pam_fields = next((f for f in copy_sections.values() if f.get("source", "").rstrip("/") == "pam"), None)
    pam_source = pam_fields["source"].rstrip("/") if pam_fields else None
    pam_dest = pam_fields["destination"].rstrip("/") if pam_fields else None
    return pkgname, pam_source, pam_dest


def check_alpm_hook(root: Path, pkgname: str, pam_source: str | None, pam_dest: str | None, errors: list[str]) -> None:
    """Verify alpm/lightxdm-login-pacnew.hook Exec= resolves inside the pam destination."""
    hook_path = root / "alpm" / "lightxdm-login-pacnew.hook"
    if not hook_path.is_file():
        errors.append("Missing ALPM hook: alpm/lightxdm-login-pacnew.hook")
        return

    exec_value: str | None = None
    for raw_line in hook_path.read_text(encoding="utf-8").splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = re.match(r"^Exec\s*=\s*(.+)$", stripped)
        if match:
            exec_value = match.group(1).strip()
            break

    if not exec_value:
        errors.append("alpm/lightxdm-login-pacnew.hook missing Exec = line")
        return

    if pam_source is None or pam_dest is None:
        return

    expanded_pam_dest = pam_dest.replace("${pkgname}", pkgname).replace("$pkgname", pkgname)
    pam_dest_abs = "/" + expanded_pam_dest.strip("/")

    try:
        tokens = shlex.split(exec_value)
    except ValueError as exc:
        errors.append(f"alpm/lightxdm-login-pacnew.hook Exec = parse failure: {exc}")
        return
    if not tokens:
        errors.append("alpm/lightxdm-login-pacnew.hook Exec = is empty")
        return

    idx = 0
    if tokens[0] in SHELL_INTERPRETERS:
        idx = 1
    elif tokens[0] in ("env", "/usr/bin/env") and len(tokens) >= 2 and Path(tokens[1]).name in ("sh", "bash"):
        idx = 2
    while idx < len(tokens) and tokens[idx].startswith("-"):
        idx += 1

    if idx >= len(tokens):
        errors.append(f"alpm/lightxdm-login-pacnew.hook Exec = missing script path: {exec_value}")
        return

    script_target = tokens[idx]
    prefix = pam_dest_abs + "/"
    if not script_target.startswith(prefix):
        errors.append(
            f"alpm/lightxdm-login-pacnew.hook Exec = target '{script_target}' does not resolve inside pam destination '{pam_dest_abs}'"
        )
        return

    rel_script = script_target[len(prefix):]
    if not _is_safe_rel_path(rel_script) or not (root / pam_source / rel_script).is_file():
        errors.append(
            f"alpm/lightxdm-login-pacnew.hook Exec = target '{script_target}' missing on disk at '{pam_source}/{rel_script}'"
        )


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_frozen_checksums(root: Path, errors: list[str]) -> None:
    """Verify frozen polkit rule and LICENSE SHA-256 digests and uninstall.sh polkit hash list."""
    polkit_file = root / FROZEN_POLKIT_PATH
    if not polkit_file.is_file():
        errors.append(f"Missing frozen file: {FROZEN_POLKIT_PATH}")
    else:
        actual = _sha256_file(polkit_file)
        if actual != FROZEN_POLKIT_SHA256:
            errors.append(
                f"Frozen file {FROZEN_POLKIT_PATH} SHA-256 mismatch: got {actual}, expected {FROZEN_POLKIT_SHA256}"
            )

    license_file = root / FROZEN_LICENSE_PATH
    if not license_file.is_file():
        errors.append(f"Missing frozen file: {FROZEN_LICENSE_PATH}")
    else:
        actual = _sha256_file(license_file)
        if actual != FROZEN_LICENSE_SHA256:
            errors.append(
                f"Frozen file {FROZEN_LICENSE_PATH} SHA-256 mismatch: got {actual}, expected {FROZEN_LICENSE_SHA256}"
            )

    uninstall_file = root / "uninstall.sh"
    if not uninstall_file.is_file():
        errors.append("Missing uninstall.sh for LIGHTXDM_OLD_POLKIT_HASHES verification")
    else:
        text = uninstall_file.read_text(encoding="utf-8")
        match = re.search(r"LIGHTXDM_OLD_POLKIT_HASHES=\((.*?)\)", text, re.DOTALL)
        if not match:
            errors.append("uninstall.sh missing LIGHTXDM_OLD_POLKIT_HASHES=(...) array")
        else:
            hashes = re.findall(r"[0-9a-f]{64}", match.group(1))
            if FROZEN_POLKIT_SHA256 not in hashes:
                errors.append(
                    f"uninstall.sh LIGHTXDM_OLD_POLKIT_HASHES missing current frozen hash {FROZEN_POLKIT_SHA256}"
                )


def _strip_matching_quotes(tok: str) -> str:
    if len(tok) >= 2 and tok[0] == tok[-1] and tok[0] in ("'", '"'):
        return tok[1:-1]
    return tok


def _extract_subshells(text: str) -> list[str]:
    """Extract inner command strings from $(...) subshells respecting shell quoting."""
    subshells: list[str] = []
    in_quote: str | None = None
    i = 0
    n = len(text)
    while i < n:
        ch = text[i]
        if in_quote == "'":
            if ch == "'":
                in_quote = None
            i += 1
            continue
        if ch == "\\" and i + 1 < n:
            i += 2
            continue
        if in_quote == '"':
            if ch == '"':
                in_quote = None
                i += 1
                continue
        else:
            if ch in ("'", '"'):
                in_quote = ch
                i += 1
                continue
            if ch == "#":
                break
        if ch == "$" and i + 1 < n and text[i + 1] == "(":
            depth = 1
            j = i + 2
            sub_quote: str | None = None
            while j < n and depth > 0:
                c = text[j]
                if sub_quote == "'":
                    if c == "'":
                        sub_quote = None
                    j += 1
                    continue
                if c == "\\" and j + 1 < n:
                    j += 2
                    continue
                if c in ("'", '"'):
                    if sub_quote is None:
                        sub_quote = c
                    elif sub_quote == c:
                        sub_quote = None
                elif sub_quote is None:
                    if c == "$" and j + 1 < n and text[j + 1] == "(":
                        depth += 1
                        j += 2
                        continue
                    if c == "(":
                        depth += 1
                    elif c == ")":
                        depth -= 1
                        if depth == 0:
                            break
                j += 1
            if depth == 0:
                inner = text[i + 2:j]
                subshells.append(inner)
                subshells.extend(_extract_subshells(inner))
                i = j + 1
                continue
        i += 1
    return subshells


def _split_shell_statements(cmd_text: str) -> list[list[str]]:
    """Split a shell command line into per-simple-command token lists."""
    statements: list[list[str]] = []
    current_tokens: list[str] = []
    buf: list[str] = []
    in_quote: str | None = None
    i = 0
    n = len(cmd_text)

    def flush_tok() -> None:
        if buf:
            current_tokens.append("".join(buf))
            buf.clear()

    def flush_stmt() -> None:
        flush_tok()
        if current_tokens:
            statements.append(current_tokens.copy())
            current_tokens.clear()

    while i < n:
        ch = cmd_text[i]
        if in_quote == "'":
            buf.append(ch)
            if ch == "'":
                in_quote = None
            i += 1
            continue
        if in_quote == '"':
            buf.append(ch)
            if ch == "\\" and i + 1 < n:
                i += 1
                buf.append(cmd_text[i])
            elif ch == '"':
                in_quote = None
            i += 1
            continue

        if ch == "\\" and i + 1 < n:
            buf.append(ch)
            i += 1
            buf.append(cmd_text[i])
            i += 1
            continue
        if ch in ("'", '"'):
            in_quote = ch
            buf.append(ch)
            i += 1
            continue
        if ch == "#" and not buf:
            break
        if ch in (";", "|", "&", "\n", "(", ")"):
            flush_stmt()
            if i + 1 < n and cmd_text[i:i + 2] in ("&&", "||"):
                i += 2
            else:
                i += 1
            continue
        if ch.isspace():
            flush_tok()
            i += 1
            continue
        buf.append(ch)
        i += 1

    flush_stmt()
    return statements


def _check_statement_python_invocation(tokens: list[str]) -> str | None:
    """Return an error reason if tokens run a repo .py script or -m unittest without -B/PYTHONDONTWRITEBYTECODE=1."""
    idx = 0
    has_env_guard = False

    while idx < len(tokens):
        tok = tokens[idx]
        if tok in ("!", "if", "elif", "while", "until", "then", "do", "else", "{"):
            idx += 1
            continue
        if "=" in tok and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tok):
            if tok == "PYTHONDONTWRITEBYTECODE=1":
                has_env_guard = True
            idx += 1
            continue
        if tok == "env":
            idx += 1
            while idx < len(tokens) and (tokens[idx].startswith("-") or "=" in tokens[idx]):
                if tokens[idx] == "PYTHONDONTWRITEBYTECODE=1":
                    has_env_guard = True
                idx += 1
            continue
        if tok == "command":
            if idx + 1 < len(tokens) and tokens[idx + 1] in ("-v", "-V"):
                return None
            idx += 1
            continue
        break

    if idx >= len(tokens):
        return None

    cmd_name = _strip_matching_quotes(tokens[idx])
    if not PYTHON_BIN_RE.match(cmd_name):
        return None

    has_b_flag = False
    i = idx + 1
    while i < len(tokens):
        raw_arg = tokens[i]
        arg = _strip_matching_quotes(raw_arg)
        if arg == "-":
            return None
        if arg.startswith("--"):
            i += 1
            continue
        if arg.startswith("-") and len(arg) > 1:
            flags = arg[1:]
            if "B" in flags:
                has_b_flag = True
            if "c" in flags:
                return None
            if "m" in flags:
                mod_name = ""
                m_pos = flags.find("m")
                if m_pos + 1 < len(flags):
                    mod_name = flags[m_pos + 1:]
                elif i + 1 < len(tokens):
                    mod_name = _strip_matching_quotes(tokens[i + 1])
                if mod_name == "unittest" or mod_name.startswith("tests."):
                    if not (has_b_flag or has_env_guard):
                        return f"{cmd_name} -m {mod_name} invoked without -B or PYTHONDONTWRITEBYTECODE=1"
                return None
            if arg in SHELL_WORDS_TAKE_VALUE:
                i += 2
                continue
            i += 1
            continue

        # Positional script path
        if arg.endswith(".py"):
            if not (has_b_flag or has_env_guard):
                return f"{cmd_name} {raw_arg} invoked without -B or PYTHONDONTWRITEBYTECODE=1"
        return None

    return None


def _logical_shell_lines(lines: list[str]) -> list[tuple[int, str]]:
    """Join backslash-continued lines and skip verified heredoc bodies."""
    result: list[tuple[int, str]] = []
    pending_heredocs: list[tuple[str, bool]] = []
    i = 0
    total = len(lines)

    while i < total:
        line = lines[i]
        if pending_heredocs:
            tag, strip_tabs = pending_heredocs[0]
            candidate = line.lstrip("\t") if strip_tabs else line
            if candidate == tag:
                pending_heredocs.pop(0)
            i += 1
            continue

        start_line = i + 1
        combined = line
        while (len(combined) - len(combined.rstrip("\\"))) % 2 == 1 and i + 1 < total:
            i += 1
            combined = combined[:-1] + " " + lines[i].lstrip()

        stripped = combined.lstrip()
        if stripped and not stripped.startswith("#"):
            result.append((start_line, combined))
            for match in HEREDOC_RE.finditer(combined):
                strip_tabs = match.group(1) == "-"
                tag = match.group(3)
                # Confirm a matching closing delimiter exists later before entering heredoc mode.
                for lookahead in range(i + 1, total):
                    cand = lines[lookahead].lstrip("\t") if strip_tabs else lines[lookahead]
                    if cand == tag:
                        pending_heredocs.append((tag, strip_tabs))
                        break

        i += 1

    return result


def check_python_invocations(root: Path, errors: list[str]) -> None:
    """Verify shell runners invoke repo .py scripts and -m unittest with -B or PYTHONDONTWRITEBYTECODE=1."""
    targets = [
        root / "lint.sh",
        root / "tests" / "qemu-arch.sh",
        root / "tests" / "run.sh",
    ]
    cases_dir = root / "tests" / "cases"
    if cases_dir.is_dir():
        targets.extend(sorted(cases_dir.glob("*.sh")))

    for path in targets:
        if not path.is_file():
            errors.append(f"Missing shell runner for Python -B check: {path.relative_to(root)}")
            continue
        lines = path.read_text(encoding="utf-8").splitlines()
        rel_path = path.relative_to(root)
        for line_no, logical_line in _logical_shell_lines(lines):
            snippets = [logical_line, *_extract_subshells(logical_line)]
            for snippet in snippets:
                for stmt_tokens in _split_shell_statements(snippet):
                    reason = _check_statement_python_invocation(stmt_tokens)
                    if reason:
                        errors.append(f"{rel_path}:{line_no}: {reason}")


def check_no_bytecode_artifacts(root: Path, errors: list[str]) -> None:
    """Assert zero __pycache__ directories or *.py[cod] files exist under repo root."""
    excluded_dirs = {".git", ".qb", ".planwright"}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in sorted(dirnames) if d not in excluded_dirs]
        for dname in dirnames:
            if dname == "__pycache__":
                rel = Path(dirpath, dname).relative_to(root)
                errors.append(f"Unexpected __pycache__ directory present: {rel}")
        for fname in sorted(filenames):
            if fname.endswith((".pyc", ".pyo", ".pyd")):
                rel = Path(dirpath, fname).relative_to(root)
                errors.append(f"Unexpected Python bytecode file present: {rel}")


def check_repo_integrity(root: Path) -> list[str]:
    """Run all repository integrity checks against root and return a list of error strings."""
    errors: list[str] = []
    pkgname, pam_source, pam_dest = check_aurgen_manifest(root, errors)
    check_alpm_hook(root, pkgname, pam_source, pam_dest, errors)
    check_frozen_checksums(root, errors)
    check_python_invocations(root, errors)
    check_no_bytecode_artifacts(root, errors)
    return errors


def main(argv: list[str] | None = None) -> int:
    """CLI entry point for repository integrity checks."""
    parser = argparse.ArgumentParser(
        description="Verify aurgen manifest, ALPM hook path, frozen SHA-256 checksums, and -B Python hygiene."
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
        help="Repository root directory (defaults to parent of tests/).",
    )
    args = parser.parse_args(argv)
    root = args.root.resolve()
    errors = check_repo_integrity(root)
    if errors:
        for err in errors:
            print(f"Error: {err}", file=sys.stderr)
        return 1
    print("Repository integrity checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
