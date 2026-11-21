#!/usr/bin/env bats
# Unit tests for src/scripts/halt_if_github_release_exists.sh, plus a
# packed-orb check of the github_release_from_deploy_tag job that uses it.
#
# `gh` and `circleci-agent` are stubbed on PATH: the gh stub logs every call
# to CALL_LOG and answers "release view" with GH_VIEW_EXIT (default 1 = not
# found); the circleci-agent stub logs "step halt" to HALT_LOG so a halt can
# be asserted without stopping the bats process.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/src/scripts/halt_if_github_release_exists.sh"

  TEST_DIR="$(mktemp -d)"
  STUB_BIN="${TEST_DIR}/bin"
  mkdir -p "${STUB_BIN}"
  export CALL_LOG="${TEST_DIR}/gh-calls.log"
  export HALT_LOG="${TEST_DIR}/halt-calls.log"
  : > "${CALL_LOG}"
  : > "${HALT_LOG}"

  cat > "${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${CALL_LOG}"
if [ "$1" = "release" ] && [ "$2" = "view" ]; then
  exit "${GH_VIEW_EXIT:-1}"
fi
exit 0
EOF
  cat > "${STUB_BIN}/circleci-agent" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${HALT_LOG}"
EOF
  chmod +x "${STUB_BIN}/gh" "${STUB_BIN}/circleci-agent"
  export PATH="${STUB_BIN}:${PATH}"

  unset RELEASE_TAG MY_TAG GH_VIEW_EXIT PARAM_TAG_ENV
  # The dev CLI's telemetry child can hang `run` (see orb_pack.bats).
  export CIRCLECI_CLI_TELEMETRY_OPTOUT=true
}

teardown() {
  rm -rf "${TEST_DIR}"
}

dev_cli_orb_pack() {
  command -v circleci >/dev/null 2>&1 && circleci orb --help >/dev/null 2>&1
}

@test "halts when a release already exists for RELEASE_TAG" {
  export RELEASE_TAG="2026.09.03-abcdef0"
  export GH_VIEW_EXIT=0
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -qx 'release view 2026.09.03-abcdef0' "${CALL_LOG}"
  grep -qx 'step halt' "${HALT_LOG}"
  echo "$output" | grep -q 'already exists'
}

@test "continues without halting when no release exists yet" {
  export RELEASE_TAG="2026.09.03-abcdef0"
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -qx 'release view 2026.09.03-abcdef0' "${CALL_LOG}"
  [ ! -s "${HALT_LOG}" ]
  echo "$output" | grep -q 'continuing'
}

@test "treats a gh failure other than not-found as 'no release yet' (source parity)" {
  export RELEASE_TAG="2026.09.03-abcdef0"
  export GH_VIEW_EXIT=4
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ ! -s "${HALT_LOG}" ]
}

@test "reads the tag from the variable named by PARAM_TAG_ENV" {
  export PARAM_TAG_ENV=MY_TAG
  export MY_TAG="2026.01.01-1234567"
  export GH_VIEW_EXIT=0
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -qx 'release view 2026.01.01-1234567' "${CALL_LOG}"
  grep -qx 'step halt' "${HALT_LOG}"
}

@test "fails when the tag variable is empty, without calling gh" {
  run bash "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'RELEASE_TAG is empty'
  [ ! -s "${CALL_LOG}" ]
  [ ! -s "${HALT_LOG}" ]
}

@test "fails on an invalid PARAM_TAG_ENV name, without calling gh" {
  export PARAM_TAG_ENV='BAD-NAME'
  run bash "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'not a valid Bash identifier'
  [ ! -s "${CALL_LOG}" ]
}

@test "github_release_from_deploy_tag job runs its steps in the source job's order" {
  if ! dev_cli_orb_pack; then
    skip "circleci dev CLI not available in this environment"
  fi
  run circleci orb pack "${REPO_ROOT}/src"
  if [ "$status" -ne 0 ]; then echo "$output" >&2; fi
  [ "$status" -eq 0 ]

  # One line per step: the step's key (or its name, for a bare string step).
  # Accepts both yq flavours: mikefarah v4 (-o=json) and the jq wrapper.
  json="$(printf '%s\n' "$output" | yq -o=json . 2>/dev/null || printf '%s\n' "$output" | yq .)"
  steps="$(printf '%s\n' "$json" | jq -r '.jobs.github_release_from_deploy_tag.steps[]
    | if type == "string" then . else (keys[0]) end')"
  echo "$steps"

  order="$(printf '%s\n' "$steps" | paste -sd, -)"
  [ "$order" = "checkout,resolve_deploy_tag,gh/setup,run,resolve_previous_deploy_tag,when,create_github_release" ]
}
