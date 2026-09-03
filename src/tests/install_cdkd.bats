#!/usr/bin/env bats
# Unit tests for scripts/install_cdkd.sh — the shell logic behind the
# install_cdkd command. Stubs npm/cdkd/circleci on PATH so no real network
# install happens; asserts the exact `<package>@<version>` string passed to
# npm and that `cdkd --version` runs afterward to surface the installed CLI.

setup() {
  ORB_SRC="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_DIR="$(mktemp -d)"
  STUB_BIN="${TEST_DIR}/bin"
  mkdir -p "$STUB_BIN"
  CALL_LOG="${TEST_DIR}/calls.log"
  export CALL_LOG

  cat >"${STUB_BIN}/npm" <<'EOF'
#!/usr/bin/env bash
echo "npm $*" >> "$CALL_LOG"
exit 0
EOF
  chmod +x "${STUB_BIN}/npm"

  cat >"${STUB_BIN}/cdkd" <<'EOF'
#!/usr/bin/env bash
echo "cdkd $*" >> "$CALL_LOG"
if [ "$1" = "--version" ]; then
  echo "0.280.15"
fi
exit 0
EOF
  chmod +x "${STUB_BIN}/cdkd"

  # Only main() calls `circleci env subst`; the install_cdkd()-only tests
  # below don't need it, but it's provided for the main() test.
  cat >"${STUB_BIN}/circleci" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "env" ] && [ "$2" = "subst" ]; then
  printf '%s' "$3"
  exit 0
fi
exit 1
EOF
  chmod +x "${STUB_BIN}/circleci"

  export PATH="${STUB_BIN}:${PATH}"
  export BASH_ENV="${TEST_DIR}/bash_env"
  : > "$BASH_ENV"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "install_cdkd installs the exact pinned version via npm" {
  source "${ORB_SRC}/scripts/install_cdkd.sh"
  run install_cdkd "0.280.15"
  [ "$status" -eq 0 ]
  grep -qF 'npm install --global @go-to-k/cdkd@0.280.15' "$CALL_LOG"
}

@test "install_cdkd prints cdkd --version after installing" {
  source "${ORB_SRC}/scripts/install_cdkd.sh"
  run install_cdkd "0.280.15"
  [ "$status" -eq 0 ]
  grep -qF 'cdkd --version' "$CALL_LOG"
  [[ "$output" == *"0.280.15"* ]]
}

@test "install_cdkd installs a caller-supplied non-default version" {
  source "${ORB_SRC}/scripts/install_cdkd.sh"
  run install_cdkd "1.2.3"
  [ "$status" -eq 0 ]
  grep -qF 'npm install --global @go-to-k/cdkd@1.2.3' "$CALL_LOG"
}

@test "main resolves PARAM_VERSION via circleci env subst before installing" {
  export PARAM_VERSION="0.280.15"
  source "${ORB_SRC}/scripts/install_cdkd.sh"
  run main
  [ "$status" -eq 0 ]
  grep -qF 'npm install --global @go-to-k/cdkd@0.280.15' "$CALL_LOG"
}

@test "script does not auto-run main when sourced under bats-core" {
  # If main() ran on source, the call log would already contain an npm
  # invocation before any test body calls install_cdkd/main explicitly.
  source "${ORB_SRC}/scripts/install_cdkd.sh"
  [ ! -s "$CALL_LOG" ]
}
