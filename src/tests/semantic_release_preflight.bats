#!/usr/bin/env bats
# Unit tests for src/scripts/semantic_release_preflight.sh.
#
# `git` is stubbed on PATH and records its argv, so no real remote is
# contacted. The token value is a fixed marker so tests can assert it never
# reaches the output.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/src/scripts/semantic_release_preflight.sh"
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/bin"
  export GIT_LOG="${WORK}/git-calls.log"
  : >"${GIT_LOG}"
  printf '#!/usr/bin/env bash\necho "git $*" >>"%s"\nexit 0\n' "${GIT_LOG}" >"${WORK}/bin/git"
  chmod +x "${WORK}/bin/git"
  export PATH="${WORK}/bin:${PATH}"
  export GITHUB_TOKEN="ghs_secret_marker_value"
  export PARAM_CONFIG_FILE=".releaserc.json"
  unset GH_TOKEN
  cd "${WORK}"
}

teardown() {
  rm -rf "${WORK}"
}

@test "passes and fetches tags when GITHUB_TOKEN and the config file are present" {
  echo '{}' >.releaserc.json
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -qx 'git fetch --tags origin' "${GIT_LOG}"
  # The token value never reaches the log.
  ! echo "$output" | grep -q 'ghs_secret_marker_value' || false
}

@test "fails naming GITHUB_TOKEN when it is empty, before fetching" {
  echo '{}' >.releaserc.json
  export GITHUB_TOKEN=""
  run bash "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'GITHUB_TOKEN is empty'
  [ ! -s "${GIT_LOG}" ]
}

@test "GH_TOKEN alone does not satisfy the check (github context carries GITHUB_TOKEN only)" {
  echo '{}' >.releaserc.json
  unset GITHUB_TOKEN
  export GH_TOKEN="legacy"
  run bash "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'GITHUB_TOKEN is empty'
}

@test "fails when the config file is missing" {
  run bash "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '.releaserc.json is missing'
  [ ! -s "${GIT_LOG}" ]
}

@test "honours a custom config_file" {
  echo 'module.exports = {}' >release.config.js
  export PARAM_CONFIG_FILE="release.config.js"
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
}

@test "an empty config_file skips the config check" {
  export PARAM_CONFIG_FILE=""
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -qx 'git fetch --tags origin' "${GIT_LOG}"
}

@test "a failing tag fetch fails the step" {
  echo '{}' >.releaserc.json
  printf '#!/usr/bin/env bash\nexit 128\n' >"${WORK}/bin/git"
  run bash "${SCRIPT}"
  [ "$status" -eq 128 ]
}
