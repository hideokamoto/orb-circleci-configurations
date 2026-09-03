#!/usr/bin/env bats
# Unit tests for src/scripts/install_bun.sh.
#
# `curl` and `bun` are stubbed via a PATH-prepended temp bin dir so no
# network call or real toolchain install ever happens. `curl` is stubbed to
# behave like `bun.sh/install`: it prints a tiny installer script to stdout
# (which the real command line pipes into `bash -s "bun-vX.Y.Z"`) that
# creates a fake `~/.bun/bin/bun` reporting whatever version it was asked
# to install. The script invokes the build-agent CLI by full path
# (/usr/bin/circleci, per CIRCLECI_CLI), not via PATH, so it is stubbed by
# pointing CIRCLECI_CLI at a stub script rather than by PATH-prepending —
# its `env subst` just expands the given string, enough for the plain
# version strings used here.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/src/scripts/install_bun.sh"

  TEST_TMP="$(mktemp -d)"
  STUB_BIN="${TEST_TMP}/bin"
  mkdir -p "${STUB_BIN}"

  export HOME="${TEST_TMP}/home"
  mkdir -p "${HOME}"

  export BASH_ENV="${TEST_TMP}/bash_env"
  : > "${BASH_ENV}"

  export CURL_CALL_LOG="${TEST_TMP}/curl.calls"
  : > "${CURL_CALL_LOG}"

  cat > "${STUB_BIN}/curl" <<'CURL_STUB'
#!/usr/bin/env bash
# Emulates `curl -fsSL https://bun.sh/install`: logs the call, then prints
# an installer script that creates ~/.bun/bin/bun reporting whatever
# "bun-vX.Y.Z" version it is later invoked with via `bash -s`.
echo "$@" >> "${CURL_CALL_LOG}"
cat <<'INSTALLER'
#!/usr/bin/env bash
set -euo pipefail
raw="$1"
version="${raw#bun-v}"
mkdir -p "${HOME}/.bun/bin"
cat > "${HOME}/.bun/bin/bun" <<BUNEOF
#!/usr/bin/env bash
echo "v${version}"
BUNEOF
chmod +x "${HOME}/.bun/bin/bun"
INSTALLER
CURL_STUB
  chmod +x "${STUB_BIN}/curl"

  export CIRCLECI_CLI="${STUB_BIN}/circleci"
  cat > "${CIRCLECI_CLI}" <<'CIRCLECI_STUB'
#!/usr/bin/env bash
# Stub for `circleci env subst STRING`: expands $VAR references in STRING,
# which is enough for the plain literal version strings used in these tests.
if [ "$1" = "env" ] && [ "$2" = "subst" ]; then
  eval "printf '%s' \"$3\""
fi
CIRCLECI_STUB
  chmod +x "${CIRCLECI_CLI}"

  export PATH="${STUB_BIN}:${PATH}"
}

teardown() {
  rm -rf "${TEST_TMP}"
}

@test "installs bun when it is not already present" {
  export PARAM_VERSION="1.3.14"

  [ ! -x "${HOME}/.bun/bin/bun" ]

  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]

  [ "$(wc -l < "${CURL_CALL_LOG}")" -eq 1 ]
  [ -x "${HOME}/.bun/bin/bun" ]
  [ "$("${HOME}/.bun/bin/bun" --version)" = "v1.3.14" ]
  ! echo "$output" | grep -q "reinstalling"
  grep -q 'export PATH="${HOME}/.bun/bin:${PATH}"' "${BASH_ENV}"
}

@test "reinstalls when the cached bun version does not match" {
  export PARAM_VERSION="1.3.14"

  mkdir -p "${HOME}/.bun/bin"
  cat > "${HOME}/.bun/bin/bun" <<'STALE_BUN'
#!/usr/bin/env bash
echo "v9.9.9"
STALE_BUN
  chmod +x "${HOME}/.bun/bin/bun"

  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]

  echo "$output" | grep -q "Cached bun 9.9.9 != expected 1.3.14; reinstalling."
  [ "$(wc -l < "${CURL_CALL_LOG}")" -eq 1 ]
  [ "$("${HOME}/.bun/bin/bun" --version)" = "v1.3.14" ]
}

@test "skips reinstall when the cached bun version already matches" {
  export PARAM_VERSION="1.3.14"

  mkdir -p "${HOME}/.bun/bin"
  cat > "${HOME}/.bun/bin/bun" <<'MATCHING_BUN'
#!/usr/bin/env bash
echo "v1.3.14"
MATCHING_BUN
  chmod +x "${HOME}/.bun/bin/bun"

  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]

  [ ! -s "${CURL_CALL_LOG}" ]
  ! echo "$output" | grep -q "reinstalling"
  [ "$("${HOME}/.bun/bin/bun" --version)" = "v1.3.14" ]
}

@test "fails when the reinstalled bun still does not match the expected version" {
  export PARAM_VERSION="1.3.14"

  mkdir -p "${HOME}/.bun/bin"
  cat > "${HOME}/.bun/bin/bun" <<'STALE_BUN'
#!/usr/bin/env bash
echo "v9.9.9"
STALE_BUN
  chmod +x "${HOME}/.bun/bin/bun"

  # Force the "reinstall" (curl stub) to still produce the wrong version,
  # simulating an upstream install that never converges.
  cat > "${STUB_BIN}/curl" <<'BROKEN_CURL_STUB'
#!/usr/bin/env bash
echo "$@" >> "${CURL_CALL_LOG}"
cat <<'INSTALLER'
#!/usr/bin/env bash
mkdir -p "${HOME}/.bun/bin"
cat > "${HOME}/.bun/bin/bun" <<BUNEOF
#!/usr/bin/env bash
echo "v9.9.9"
BUNEOF
chmod +x "${HOME}/.bun/bin/bun"
INSTALLER
BROKEN_CURL_STUB
  chmod +x "${STUB_BIN}/curl"

  run bash "${SCRIPT}"
  [ "$status" -eq 1 ]

  echo "$output" | grep -q "Failed to install bun 1.3.14 (got 9.9.9)"
}
