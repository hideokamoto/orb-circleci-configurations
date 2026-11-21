#!/usr/bin/env bats
# Covers src/scripts/aidlc_check_version.sh: matching and mismatching
# versions, with pinning off, on via the pin_version parameter (both the
# "1" CircleCI passes and "true"), and on via the legacy AIDLC_PIN_VERSION
# project switch.

# bats-core lifecycle hook. Stubs `bun` (prints $FAKE_AIDLC_VERSION for
# `aidlc-utility.ts version`, or fails when FAKE_BUN_FAIL=1) and the
# circleci CLI used for `env subst`, and sets the PARAM_* defaults.
setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/src/scripts/aidlc_check_version.sh"

  TEST_DIR="$(mktemp -d)"
  mkdir -p "${TEST_DIR}/bin"
  cat > "${TEST_DIR}/bin/bun" <<'STUB'
#!/usr/bin/env bash
if [ "${FAKE_BUN_FAIL:-}" = "1" ]; then exit 1; fi
echo "${FAKE_AIDLC_VERSION}"
STUB
  chmod +x "${TEST_DIR}/bin/bun"
  PATH="${TEST_DIR}/bin:${PATH}"

  CIRCLECI_CLI="${TEST_DIR}/bin/circleci-cli"
  cat > "${CIRCLECI_CLI}" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "env" ] && [ "$2" = "subst" ]; then printf '%s' "$3"; fi
STUB
  chmod +x "${CIRCLECI_CLI}"

  export PATH CIRCLECI_CLI
  export AIDLC_TOOLS=".claude/tools"
  export PARAM_EXPECTED_VERSION="aidlc 2.6.16"
  export PARAM_PIN_VERSION="0"
  export FAKE_AIDLC_VERSION="aidlc 2.6.16"
  unset AIDLC_PIN_VERSION FAKE_BUN_FAIL
}

teardown() {
  rm -rf "${TEST_DIR}"
}

@test "passes when the embedded version matches" {
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Embedded: aidlc 2.6.16"* ]]
}

@test "reports but passes a mismatch when pinning is off" {
  export FAKE_AIDLC_VERSION="aidlc 2.7.0"
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Embedded: aidlc 2.7.0"* ]]
  [[ "$output" == *"not pinned"* ]]
}

@test "fails a mismatch when pin_version is \"1\" (what CircleCI passes for true)" {
  export FAKE_AIDLC_VERSION="aidlc 2.7.0"
  export PARAM_PIN_VERSION="1"
  run bash "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Version mismatch"* ]]
}

@test "fails a mismatch when pin_version is \"true\"" {
  export FAKE_AIDLC_VERSION="aidlc 2.7.0"
  export PARAM_PIN_VERSION="true"
  run bash "${SCRIPT}"
  [ "$status" -eq 1 ]
}

@test "passes a match when pin_version is \"1\"" {
  export PARAM_PIN_VERSION="1"
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
}

@test "the legacy AIDLC_PIN_VERSION=1 project switch also pins" {
  export FAKE_AIDLC_VERSION="aidlc 2.7.0"
  export AIDLC_PIN_VERSION="1"
  run bash "${SCRIPT}"
  [ "$status" -eq 1 ]
}

@test "fails when the version cannot be read" {
  export FAKE_BUN_FAIL="1"
  run bash "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not read the embedded AI-DLC version"* ]]
}

@test "fails when AIDLC_TOOLS was not exported by the detection step" {
  unset AIDLC_TOOLS
  run bash "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"AIDLC_TOOLS is not set"* ]]
}
