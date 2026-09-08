#!/usr/bin/env bats
# Unit tests for scripts/install_cdkd.sh — the shell logic behind the
# install_cdkd command. Stubs npm/cdkd on PATH and the build-agent
# `circleci` CLI via $CIRCLECI_CLI (the script calls it by full path, not
# PATH, since cimg/base-family images don't guarantee it's on PATH) so no
# real network install happens; asserts the exact `<package>@<version>`
# string passed to npm and that `cdkd --version` runs afterward to surface
# the installed CLI.

# bats-core hook run before every @test in this file. Builds an isolated
# fixture directory with PATH-stubbed npm/cdkd binaries and a circleci
# stub pointed to by $CIRCLECI_CLI (mirroring the build-agent CLI's full
# path in real jobs) so tests exercise install_cdkd.sh's logic without a
# real network install, and points BASH_ENV at a scratch file per
# contract §4.
#
# Arguments:
#   None (implicit bats-core hook).
# Returns / side effects:
#   Sets ORB_SRC (path to the orb's src/ dir), TEST_DIR (this test's scratch
#   dir), STUB_BIN (prepended onto PATH), and CALL_LOG (exported; stub
#   invocations are appended here as "<cmd> <args...>" lines) as test-local
#   shell variables. Creates and chmods the npm/cdkd/circleci stub scripts,
#   exports PATH, CIRCLECI_CLI (set to the circleci stub's full path), and
#   BASH_ENV, and truncates BASH_ENV to empty.
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

  # Only main() calls `$CIRCLECI_CLI env subst`; the install_cdkd()-only
  # tests below don't need it, but it's provided for the main() test.
  # Not put on PATH deliberately — main() calls it by full path (see
  # install_cdkd.sh), mirroring that cimg/base-family images don't
  # guarantee the build-agent CLI is on PATH; CIRCLECI_CLI below points
  # straight at this stub instead of relying on PATH resolution.
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
  export CIRCLECI_CLI="${STUB_BIN}/circleci"
  export BASH_ENV="${TEST_DIR}/bash_env"
  : > "$BASH_ENV"
}

# bats-core hook run after every @test in this file. Cleans up the fixture
# directory setup() created (scratch dir, stub bin, call log, BASH_ENV
# file), so tests don't leak state or temp files between runs.
#
# Arguments:
#   None (implicit bats-core hook).
# Returns / side effects:
#   Recursively removes $TEST_DIR (and everything under it). No return
#   value is inspected by bats-core.
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

@test "main resolves PARAM_VERSION via \$CIRCLECI_CLI env subst before installing" {
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
