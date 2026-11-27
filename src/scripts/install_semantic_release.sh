#!/usr/bin/env bash
set -euo pipefail

# install_semantic_release.sh
#
# Installs a pinned semantic-release (plus the conventionalcommits preset and
# any extra pinned packages, e.g. multi-semantic-release) into a directory
# outside the project, without lifecycle scripts, and puts its bin directory
# first on PATH for later steps. Mirrors the "Install release tools (without
# lifecycle scripts)" step of circleci-configurations'
# workflows/publish/*semantic-release.yaml templates.

# Succeeds when the value is an exact semver version ("25.0.9",
# "1.0.0-beta.1"), not a range, dist-tag or empty string.
#
# Arguments: $1 - the version string to check.
is_exact_version() {
  # Strict SemVer 2.0.0 (https://semver.org): no leading zeros in numeric
  # identifiers and no empty prerelease / build identifiers. npm does not
  # resolve anything else as an exact version.
  local num='(0|[1-9][0-9]*)'
  local pre='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
  local build='[0-9A-Za-z-]+'
  local re="^${num}\\.${num}\\.${num}(-${pre}(\\.${pre})*)?(\\+${build}(\\.${build})*)?$"
  [[ "$1" =~ ${re} ]]
}

# Succeeds when the value is "<package>@<exact version>", scoped or not.
#
# Arguments: $1 - the package spec to check.
is_pinned_spec() {
  local spec="$1"
  local name="${spec%@*}"
  local version="${spec##*@}"
  [ "${name}" != "${spec}" ] || return 1
  [[ "${name}" =~ ^(@[a-z0-9._~-]+/)?[a-z0-9._~-]+$ ]] || return 1
  is_exact_version "${version}"
}

# Arguments: none.
# Reads (env): PARAM_SEMANTIC_RELEASE_VERSION, PARAM_CONVENTIONAL_CHANGELOG_VERSION
#   (exact versions), PARAM_EXTRA_RELEASE_PACKAGES (space-separated
#   "<package>@<exact version>" specs, may be empty), RELEASE_TOOLS_DIR
#   (optional install prefix; defaults to $HOME/release-tools), BASH_ENV.
# Side effects: runs `npm install --prefix`; appends a PATH export to
#   $BASH_ENV; exits 1 before installing anything when a version is not
#   pinned to an exact version.
install_tools() {
  # Tools that receive a contents:write token are never run from @latest or
  # a range: a new upstream release must not reach this job unreviewed.
  if ! is_exact_version "${PARAM_SEMANTIC_RELEASE_VERSION:-}"; then
    echo "semantic_release_version must be an exact version (got '${PARAM_SEMANTIC_RELEASE_VERSION:-}')." >&2
    exit 1
  fi
  if ! is_exact_version "${PARAM_CONVENTIONAL_CHANGELOG_VERSION:-}"; then
    echo "conventional_changelog_version must be an exact version (got '${PARAM_CONVENTIONAL_CHANGELOG_VERSION:-}')." >&2
    exit 1
  fi

  local -a packages=(
    "semantic-release@${PARAM_SEMANTIC_RELEASE_VERSION}"
    "conventional-changelog-conventionalcommits@${PARAM_CONVENTIONAL_CHANGELOG_VERSION}"
  )
  local -a extra=()
  read -r -a extra <<< "${PARAM_EXTRA_RELEASE_PACKAGES:-}"
  local spec
  for spec in ${extra[@]+"${extra[@]}"}; do
    if ! is_pinned_spec "${spec}"; then
      echo "extra_release_packages entries must be <package>@<exact version> (got '${spec}')." >&2
      exit 1
    fi
    packages+=("${spec}")
  done

  local prefix="${RELEASE_TOOLS_DIR:-${HOME}/release-tools}"
  echo "Installing into ${prefix}: ${packages[*]}"
  npm install --prefix "${prefix}" --ignore-scripts --no-audit --no-fund "${packages[@]}"

  # Later steps (the release command run by npm_publish_oidc) find the pinned
  # tools first on PATH, ahead of any copy in the project's node_modules.
  printf 'export PATH=%q\n' "${prefix}/node_modules/.bin:\$PATH" >> "${BASH_ENV}"
}

# Script entry point, run only when this file is executed directly (not
# sourced by BATS -- see the ORB_TEST_ENV guard below).
main() {
  install_tools
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
