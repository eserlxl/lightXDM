#!/usr/bin/env bash
# lint.sh: Run ShellCheck on all project shell scripts
set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

scripts=(install.sh enable-autologin.sh uninstall.sh tests/run.sh)

for script in "${scripts[@]}"; do
  if [ -f "$SCRIPT_DIR/$script" ]; then
    echo "Checking $script..."
    shellcheck "$SCRIPT_DIR/$script"
  else
    echo "Error: $SCRIPT_DIR/$script not found." >&2
    exit 1
  fi
  echo
done

echo "ShellCheck completed for all scripts."