#!/usr/bin/env bats
# Verifies install_circleci_cli.sh's three behavioral paths without ever
# touching the network or a real /usr/local/bin: curl and sudo are stubbed,
# and circleci is stubbed to control both "env subst" (parameter expansion)
# and whether "api --help" already works. A small real tar.gz fixture
# (containing a fake "circleci" binary) stands in for the release asset, so
# tar and sha256sum run for real against it.

#######################################
# bats-core "setup" hook, run before every @test in this file.
# Builds an isolated sandbox for install_circleci_cli.sh: a scratch
# install directory, a real tar.gz fixture (a fake "circleci" binary,
# packed the same way the real release asset is) with both a matching
# (GOOD_SHA256) and non-matching (BAD_SHA256) checksum precomputed, a
# curl stub that copies that fixture to the requested "-o" destination
# instead of hitting the network, a sudo stub that just execs its
# arguments (this suite never has root), and a dedicated BASH_ENV file.
# Globals:
#   BATS_TEST_FILENAME  Read (bats-core built-in) to locate the repo root.
# Arguments:
#   None.
# Outputs:
#   None.
# Side effects:
#   Sets and exports REPO_ROOT, SCRIPT, TEST_TMP, STUB_BIN, INSTALL_DIR,
#   TARBALL, GOOD_SHA256, BAD_SHA256, CURL_LOG, and BASH_ENV for the
#   duration of the test; creates files under TEST_TMP.
#######################################
setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/src/scripts/install_circleci_cli.sh"

  TEST_TMP="$(mktemp -d)"
  STUB_BIN="${TEST_TMP}/bin"
  INSTALL_DIR="${TEST_TMP}/install"
  FIXTURE_DIR="${TEST_TMP}/fixture"
  mkdir -p "$STUB_BIN" "$INSTALL_DIR" "$FIXTURE_DIR"

  # Fixture: a tiny fake "circleci" binary, packed the same way the real
  # release asset is (a tar.gz with "circleci" at its root).
  cat > "${FIXTURE_DIR}/circleci" <<'FIXTURE'
#!/usr/bin/env bash
echo "fake circleci cli"
FIXTURE
  chmod +x "${FIXTURE_DIR}/circleci"
  TARBALL="${TEST_TMP}/circleci-cli_9.9.9_linux_amd64.tar.gz"
  tar -C "$FIXTURE_DIR" -czf "$TARBALL" circleci
  GOOD_SHA256="$(sha256sum "$TARBALL" | awk '{print $1}')"
  BAD_SHA256="$(printf '0%.0s' $(seq 1 64))"
  export TARBALL GOOD_SHA256 BAD_SHA256

  CURL_LOG="${TEST_TMP}/curl.log"
  export CURL_LOG
  : > "$CURL_LOG"

  # curl stub: ignore the URL, copy the fixture tarball to "-o <dest>".
  cat > "${STUB_BIN}/curl" <<'CURL'
#!/usr/bin/env bash
echo "called" >> "${CURL_LOG}"
dest=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) dest="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cp "${TARBALL}" "${dest}"
CURL
  chmod +x "${STUB_BIN}/curl"

  # sudo stub: this suite never has root, just run the command directly.
  cat > "${STUB_BIN}/sudo" <<'SUDO'
#!/usr/bin/env bash
exec "$@"
SUDO
  chmod +x "${STUB_BIN}/sudo"

  BASH_ENV="${TEST_TMP}/bash_env"
  : > "$BASH_ENV"
  export BASH_ENV
}

#######################################
# bats-core "teardown" hook, run after every @test in this file.
# Globals:
#   TEST_TMP  Read; the sandbox directory created by setup().
# Arguments:
#   None.
# Outputs:
#   None.
# Side effects:
#   Recursively removes TEST_TMP, deleting the fixture tarball, stub
#   binaries, and any files the test run created (e.g. an installed CLI).
#######################################
teardown() {
  rm -rf "$TEST_TMP"
}

#######################################
# Writes a stub "circleci" binary into STUB_BIN, standing in for both the
# build-agent (env subst) and the standalone CLI (api --help) so a test
# controls whether install_circleci_cli.sh sees a CLI that already looks
# fully installed.
# Globals:
#   STUB_BIN  Read; directory (prepended to PATH by run_install) the stub
#             is written into.
# Arguments:
#   $1  Exit code the stub's "api --help" subcommand should return: 0 makes
#       circleci_cli_already_present() in the script under test succeed
#       (a fully working standalone CLI is already present); non-zero
#       makes it fail (e.g. only the build-agent binary is present).
#       Its "env subst X" always echoes X back unchanged, since no
#       pipeline-value expansion is exercised by these tests.
# Outputs:
#   None.
# Side effects:
#   Creates (or overwrites) an executable "${STUB_BIN}/circleci".
#######################################
stub_circleci() {
  cat > "${STUB_BIN}/circleci" <<CIRCLECI
#!/usr/bin/env bash
if [ "\$1" = "env" ] && [ "\$2" = "subst" ]; then
  echo "\$3"
  exit 0
fi
if [ "\$1" = "api" ] && [ "\$2" = "--help" ]; then
  exit ${1}
fi
exit 1
CIRCLECI
  chmod +x "${STUB_BIN}/circleci"
}

#######################################
# Runs install_circleci_cli.sh under test, with STUB_BIN (curl/sudo/
# circleci stubs) prepended to PATH, CIRCLECI_CLI pointed explicitly at the
# stubbed circleci binary (the script's "env subst" calls go through
# CIRCLECI_CLI, not a PATH lookup -- see its definition in the script), and
# PARAM_VERSION/PARAM_INSTALL_PATH fixed to the fixture's version and the
# sandbox's scratch install directory. Intended to be invoked via bats'
# "run" so its exit status and output are captured rather than propagated.
# Globals:
#   STUB_BIN     Read; prepended to PATH so circleci_cli_already_present()
#                (a real PATH lookup, unchanged from the script's original
#                behavior) sees the stubs, and used to build CIRCLECI_CLI.
#   SCRIPT       Read; path to install_circleci_cli.sh under test.
#   INSTALL_DIR  Read; passed through as PARAM_INSTALL_PATH.
# Arguments:
#   $1  sha256 to pass as PARAM_SHA256 (a real match, or a deliberately
#       wrong value, depending on what the test wants to verify).
#   $2  "true"/"false" to pass as PARAM_SKIP_IF_PRESENT.
# Outputs:
#   Whatever install_circleci_cli.sh prints (captured by "run").
# Returns:
#   install_circleci_cli.sh's exit status.
#######################################
run_install() {
  PATH="${STUB_BIN}:${PATH}" \
    CIRCLECI_CLI="${STUB_BIN}/circleci" \
    PARAM_VERSION="9.9.9" \
    PARAM_SHA256="${1}" \
    PARAM_INSTALL_PATH="${INSTALL_DIR}" \
    PARAM_SKIP_IF_PRESENT="${2}" \
    bash "$SCRIPT"
}

@test "skips the download when a working CircleCI CLI is already on PATH" {
  stub_circleci 0
  run run_install "${GOOD_SHA256}" "true"

  [ "$status" -eq 0 ]
  [ ! -s "$CURL_LOG" ]
  [ ! -e "${INSTALL_DIR}/circleci" ]
}

@test "fails when the downloaded tarball does not match the pinned sha256" {
  stub_circleci 1
  run run_install "${BAD_SHA256}" "true"

  [ "$status" -ne 0 ]
  [ -s "$CURL_LOG" ]
  [ ! -e "${INSTALL_DIR}/circleci" ]
}

@test "installs the CLI into install_path when the checksum matches and no working CLI is present" {
  stub_circleci 1
  run run_install "${GOOD_SHA256}" "true"

  [ "$status" -eq 0 ]
  [ -s "$CURL_LOG" ]
  [ -x "${INSTALL_DIR}/circleci" ]
  run "${INSTALL_DIR}/circleci"
  [ "$output" = "fake circleci cli" ]
}
