#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# Print one "<sha256>  <pathspec>" line for every version of each bundled home-dotfile template:
# every blob in the git history of the pathspecs is_past_lightxdm_template knows, plus the tracked
# working-tree files. After editing a template, regenerate the list the scripts read:
#   bash tests/template-history.sh > dotfiles/template-history.sha256
set -euo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")/.."

usage() {
  cat <<'EOF'
Usage: bash tests/template-history.sh [--check | -h | --help]

Print one "<sha256>  <pathspec>" line for every version of each bundled
home-dotfile template in git history and tracked working-tree files.

  (no args)   Print sorted "<sha256>  <pathspec>" lines to stdout.
  --check     Compare generated lines against dotfiles/template-history.sha256
              (skips with exit 0 when .git is absent; exits 1 on drift).
  -h, --help  Show this help message and exit.
EOF
}

mode="generate"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      mode="check"
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

pathspecs=(
  'dotfiles/.bash_profile'
  'dotfiles/.xinitrc*'
  'dotfiles/.wayland-session-*'
  'dotfiles/.gpg-agent-*'
  'dotfiles/lightxdm-gpg-agent-tty.desktop'
)

generate_history() {
  local pathspec hash _ blob file old new
  for pathspec in "${pathspecs[@]}"; do
    {
      # Raw lines read ":<mode> <mode> <old-blob> <new-blob> <status>\t<path>"; an all-zero id is no file.
      git log --format= --raw --no-abbrev -- "$pathspec" | while read -r _ _ old new _; do
        for blob in "$old" "$new"; do
          [[ -z "${blob//0/}" ]] || git cat-file blob "$blob" | sha256sum
        done
      done
      git ls-files -z -- "$pathspec" | while IFS= read -r -d '' file; do
        sha256sum <"$file"
      done
    } | while read -r hash _; do
      printf '%s  %s\n' "$hash" "$pathspec"
    done
  done | LC_ALL=C sort -u
}

if [[ "$mode" == "check" ]]; then
  if [[ ! -e .git ]] || ! command -v git >/dev/null 2>&1 || ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Skipping dotfiles/template-history.sha256 check (.git absent or not a git work tree)."
    exit 0
  fi
  if [[ ! -f dotfiles/template-history.sha256 ]]; then
    echo "Error: dotfiles/template-history.sha256 is missing; regenerate it: bash tests/template-history.sh > dotfiles/template-history.sha256" >&2
    exit 1
  fi
  generated="$(generate_history)"
  generated_hash="$(printf '%s\n' "$generated" | sha256sum)"
  expected_hash="$(sha256sum <dotfiles/template-history.sha256)"
  if [[ -n "$generated" && "$generated_hash" == "$expected_hash" ]]; then
    echo "dotfiles/template-history.sha256 is up to date."
    exit 0
  fi
  echo "Error: dotfiles/template-history.sha256 is stale; regenerate it: bash tests/template-history.sh > dotfiles/template-history.sha256" >&2
  if command -v diff >/dev/null 2>&1; then
    diff -u dotfiles/template-history.sha256 <(printf '%s\n' "$generated") >&2 || true
  fi
  exit 1
fi

generate_history
