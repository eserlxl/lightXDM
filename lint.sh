#!/usr/bin/env bash
# lint.sh: Run ShellCheck on all project shell scripts
set -e

scripts=(install.sh enable-autologin.sh uninstall.sh tests/run.sh)

for script in "${scripts[@]}"; do
  if [ -f "$script" ]; then
    echo "Checking $script..."
    shellcheck "$script"
  else
    echo "Warning: $script not found."
  fi
  echo
done

echo "ShellCheck completed for all scripts." 