#!/usr/bin/env bats
# Unit tests for src/scripts/install_semantic_release.sh.
#
# `npm` is stubbed on PATH and records its argv, so nothing is downloaded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/src/scripts/install_semantic_release.sh"
  WORK="$(mktemp -d)"
  mkdir -p "${WORK}/bin"
  export NPM_LOG="${WORK}/npm-calls.log"
  : >"${NPM_LOG}"
  printf '#!/usr/bin/env bash\necho "npm $*" >>"%s"\nexit 0\n' "${NPM_LOG}" >"${WORK}/bin/npm"
  chmod +x "${WORK}/bin/npm"
  export PATH="${WORK}/bin:${PATH}"
  export BASH_ENV="${WORK}/bash_env"
  : >"${BASH_ENV}"
  export RELEASE_TOOLS_DIR="${WORK}/release-tools"
  export PARAM_SEMANTIC_RELEASE_VERSION="25.0.9"
  export PARAM_CONVENTIONAL_CHANGELOG_VERSION="9.3.1"
  export PARAM_EXTRA_RELEASE_PACKAGES=""
}

teardown() {
  rm -rf "${WORK}"
}

@test "installs the pinned tools without lifecycle scripts and puts them first on PATH" {
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -qx "npm install --prefix ${RELEASE_TOOLS_DIR} --ignore-scripts --no-audit --no-fund semantic-release@25.0.9 conventional-changelog-conventionalcommits@9.3.1" "${NPM_LOG}"
  grep -qF "export PATH=\"${RELEASE_TOOLS_DIR}/node_modules/.bin:\${PATH}\"" "${BASH_ENV}"
}

@test "adds pinned extra packages, scoped or not" {
  export PARAM_EXTRA_RELEASE_PACKAGES="multi-semantic-release@3.1.0 @semantic-release/exec@7.1.0"
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -q 'conventional-changelog-conventionalcommits@9.3.1 multi-semantic-release@3.1.0 @semantic-release/exec@7.1.0$' "${NPM_LOG}"
}

@test "rejects latest as the semantic-release version before installing" {
  export PARAM_SEMANTIC_RELEASE_VERSION="latest"
  run bash "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'semantic_release_version must be an exact version'
  [ ! -s "${NPM_LOG}" ]
}

@test "rejects a range as the conventional-changelog version" {
  export PARAM_CONVENTIONAL_CHANGELOG_VERSION="^9.3.1"
  run bash "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'conventional_changelog_version must be an exact version'
  [ ! -s "${NPM_LOG}" ]
}

@test "rejects an extra package without a version" {
  export PARAM_EXTRA_RELEASE_PACKAGES="multi-semantic-release"
  run bash "${SCRIPT}"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "got 'multi-semantic-release'"
  [ ! -s "${NPM_LOG}" ]
}

@test "rejects a scoped extra package without a version" {
  export PARAM_EXTRA_RELEASE_PACKAGES="@semantic-release/exec"
  run bash "${SCRIPT}"
  [ "$status" -eq 1 ]
  [ ! -s "${NPM_LOG}" ]
}

@test "accepts a prerelease version" {
  export PARAM_SEMANTIC_RELEASE_VERSION="26.0.0-beta.1"
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  grep -q 'semantic-release@26.0.0-beta.1' "${NPM_LOG}"
}

@test "a failing npm install fails the step and leaves PATH untouched" {
  printf '#!/usr/bin/env bash\nexit 1\n' >"${WORK}/bin/npm"
  run bash "${SCRIPT}"
  [ "$status" -eq 1 ]
  [ ! -s "${BASH_ENV}" ]
}
