#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# lint.sh: Run ShellCheck on all project shell scripts
set -e

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

scripts=(
  install.sh
  enable-autologin.sh
  uninstall.sh
  bin/lightxdm-install
  bin/lightxdm-update
  bin/lightxdm-uninstall
  bin/lightxdm-autologin
  lint.sh
  tests/run.sh
  tests/docker-arch.sh
  tests/qemu-arch.sh
  tests/qemu/build-image.sh
  tests/template-history.sh
  pam/login-pacnew-note.sh
  dotfiles/.bash_profile
  dotfiles/.gpg-agent-gnome
  dotfiles/.wayland-session-budgie
  dotfiles/.wayland-session-gnome
  dotfiles/.wayland-session-plasma
  dotfiles/.xinitrc-cinnamon
  dotfiles/.xinitrc-i3
  dotfiles/.xinitrc-lxde
  dotfiles/.xinitrc-lxqt
  dotfiles/.xinitrc-mate
  dotfiles/.xinitrc-xfce
)

for script in "${scripts[@]}"; do
  if [ -f "$SCRIPT_DIR/$script" ]; then
    echo "Checking $script..."
    opts=()
    # The sourced gpg-agent dotfiles export a command substitution in one step (SC2155).
    case "$script" in
      dotfiles/.gpg-agent-*) opts=(-e SC2155) ;;
      # Full dataflow analysis of the 21,000+ line test suite needs about 13 GB of memory.
      tests/run.sh) opts=(--extended-analysis=false) ;;
    esac
    shellcheck "${opts[@]}" "$SCRIPT_DIR/$script"
  else
    echo "Error: $SCRIPT_DIR/$script not found." >&2
    exit 1
  fi
  echo
done

echo "ShellCheck completed for all scripts."

if command -v git >/dev/null 2>&1 && [[ -e "$SCRIPT_DIR/.git" ]] && git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  missing_scripts=()
  while IFS= read -r -d '' tracked_file; do
    [[ -z "$tracked_file" || "$tracked_file" == *.desktop ]] && continue
    listed=0
    for script in "${scripts[@]}"; do
      if [[ "$script" == "$tracked_file" ]]; then
        listed=1
        break
      fi
    done
    if [[ "$listed" -eq 0 ]]; then
      missing_scripts+=("$tracked_file")
    fi
  done < <(git -C "$SCRIPT_DIR" ls-files -z -- '*.sh' 'dotfiles/.*')
  if [[ ${#missing_scripts[@]} -gt 0 ]]; then
    echo "Error: lint.sh scripts=() misses tracked shell/dotfile files: ${missing_scripts[*]}" >&2
    exit 1
  fi
  echo "Tracked shell script and template list is complete."
else
  echo "Skipping git tracked-script completeness check (not a git checkout)."
fi

bash "$SCRIPT_DIR/tests/template-history.sh" --check

py_files=()
if [[ -d "$SCRIPT_DIR/tests" ]]; then
  while IFS= read -r -d '' py_file; do
    py_files+=("$py_file")
  done < <(find "$SCRIPT_DIR/tests" \( -name '.git' -o -name '.qb' -o -name '.planwright' \) -prune -o -type f -name '*.py' -print0 | LC_ALL=C sort -z)
fi

if [[ ${#py_files[@]} -gt 0 ]]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 not found for Python static checks." >&2
    exit 1
  fi
  py_compile_dir="$(mktemp -d)"
  trap 'rm -rf -- "$py_compile_dir"' EXIT
  PYTHONDONTWRITEBYTECODE=1 python3 -B - "$py_compile_dir" "$SCRIPT_DIR" "${py_files[@]}" <<'PY'
import ast
import os
import py_compile
import sys

compile_dir = sys.argv[1]
repo_root = sys.argv[2]
for idx, path in enumerate(sys.argv[3:]):
    rel_path = os.path.relpath(path, repo_root)
    print(f"Checking {rel_path}...")
    try:
        with open(path, "rb") as handle:
            source = handle.read()
        ast.parse(source, filename=path)
        cfile = os.path.join(compile_dir, f"mod_{idx}.pyc")
        py_compile.compile(path, cfile=cfile, doraise=True)
    except (OSError, SyntaxError, ValueError, py_compile.PyCompileError) as exc:
        print(f"Error checking {rel_path}: {exc}", file=sys.stderr)
        sys.exit(1)
PY
  rm -rf -- "$py_compile_dir"
  trap - EXIT
  echo "Python AST and bytecode checks completed for ${#py_files[@]} file(s)."
fi

PYTHONDONTWRITEBYTECODE=1 python3 -B "$SCRIPT_DIR/tests/check_repo_integrity.py"
