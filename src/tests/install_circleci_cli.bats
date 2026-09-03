#!/usr/bin/env bats
# Verifies install_circleci_cli.sh's three behavioral paths without ever
# touching the network or a real /usr/local/bin: curl and sudo are stubbed,
# and circleci is stubbed to control both "env subst" (parameter expansion)
# and whether "api --help" already works. A small real tar.gz fixture
# (containing a fake "circleci" binary) stands in for the release asset, so
# tar and sha256sum run for real against it.

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

teardown() {
  rm -rf "$TEST_TMP"
}

# circleci stub: "env subst X" always echoes X back (no pipeline values are
# exercised here); "api --help" exits with $1 so a test can choose whether
# the pre-existing CLI already looks like the standalone one (0) or not,
# e.g. the build-agent binary (non-zero).
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

run_install() {
  PATH="${STUB_BIN}:${PATH}" \
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
