#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025-2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
# Print one "<sha256>  <pathspec>" line for every version of each bundled home-dotfile template:
# every blob in the git history of the pathspecs is_past_lightxdm_template knows, plus the tracked
# working-tree files. After editing a template, regenerate the list the scripts read:
#   bash tests/template-history.sh > dotfiles/template-history.sha256
set -euo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")/.."
pathspecs=(
  'dotfiles/.bash_profile'
  'dotfiles/.xinitrc*'
  'dotfiles/.wayland-session-*'
  'dotfiles/.gpg-agent-*'
  'dotfiles/lightxdm-gpg-agent-tty.desktop'
)
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
