#!/usr/bin/env bash
# tests/run.sh: Behavior test harness for lightXDM scripts
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"

cat >"$STUB_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

cat >"$STUB_BIN/pacman" <<'EOF'
#!/usr/bin/env bash
echo "pacman $*" >>"${STUB_LOG:-/dev/null}"
exit "${STUB_PACMAN_EXIT:-0}"
EOF

cat >"$STUB_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"${STUB_LOG:-/dev/null}"
exit "${STUB_SYSTEMCTL_EXIT:-0}"
EOF

cat >"$STUB_BIN/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-gn" ]]; then
  echo "users"
elif [[ "${1:-}" == "-nG" ]]; then
  echo "users wheel"
else
  echo "1000"
fi
EOF

chmod +x "$STUB_BIN/sudo" "$STUB_BIN/pacman" "$STUB_BIN/systemctl" "$STUB_BIN/id"
export PATH="$STUB_BIN:$PATH"
export STUB_LOG="$TMP_DIR/stub.log"

# shellcheck source=install.sh disable=SC1091
source "$REPO_ROOT/install.sh"

failures=0

pass() {
  echo "PASS: $1"
}

fail() {
  echo "FAIL: $1"
  failures=$((failures + 1))
}

# Case 1: install_packages rejects an unknown DE
set +e
output="$(install_packages "nonexistent-de" 2>&1)"
status=$?
set -e
if [[ $status -eq 1 && "$output" == *"Unsupported desktop environment: nonexistent-de"* ]]; then
  pass "install_packages rejects unknown DE"
else
  fail "install_packages rejects unknown DE (status=$status, output=$output)"
fi

# Case 2: install_packages installs base and DE packages via stubbed sudo/pacman
: >"$STUB_LOG"
set +e
output="$(install_packages "i3" 2>&1)"
status=$?
set -e
log_content="$(cat "$STUB_LOG")"
if [[ $status -eq 0 && "$log_content" == *"pacman -S --needed --noconfirm"* && "$log_content" == *"i3 xterm gnome-keyring polkit-gnome"* ]]; then
  pass "install_packages invokes pacman for i3"
else
  fail "install_packages invokes pacman for i3 (status=$status, log=$log_content)"
fi

# Case 3: prompt_de_selection maps "1" to "plasma" without log or PS3 leakage
unset PS3
prompt_out="$TMP_DIR/prompt_out"
set +e
prompt_de_selection <<<"1" >"$prompt_out" 2>/dev/null
status=$?
set -e
output="$(cat "$prompt_out")"
if [[ $status -eq 0 && "$output" == "plasma" && -z "${PS3+x}" ]]; then
  pass "prompt_de_selection maps option 1 to plasma without leaking log or PS3"
else
  fail "prompt_de_selection option 1 (status=$status, output=$output, PS3=${PS3-<unset>})"
fi

# Case 4: prompt_de_selection returns non-zero with empty stdout on Quit ("10")
set +e
output="$(prompt_de_selection <<<"10" 2>/dev/null)"
status=$?
set -e
if [[ $status -ne 0 && -z "$output" ]]; then
  pass "prompt_de_selection returns non-zero on Quit"
else
  fail "prompt_de_selection Quit (status=$status, output=$output)"
fi

# Case 5: prompt_de_selection returns non-zero with empty stdout on EOF
set +e
output="$(prompt_de_selection </dev/null 2>/dev/null)"
status=$?
set -e
if [[ $status -ne 0 && -z "$output" ]]; then
  pass "prompt_de_selection returns non-zero on EOF"
else
  fail "prompt_de_selection EOF (status=$status, output=$output)"
fi

exit "$failures"
