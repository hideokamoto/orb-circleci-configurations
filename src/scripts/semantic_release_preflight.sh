#!/usr/bin/env bash
set -euo pipefail

# semantic_release_preflight.sh
#
# Fail-fast checks for the npm_semantic_release job, run before any
# dependency is installed. Mirrors the "Check prerequisites" step of
# circleci-configurations' workflows/publish/npm-polyrepo-semantic-release.yaml,
# npm-polyrepo-bun-semantic-release.yaml and npm-monorepo-semantic-release.yaml.

# Verifies the GitHub token and the semantic-release config file, then
# fetches every tag so semantic-release can find the previous release.
#
# Arguments: none.
# Reads (env): GITHUB_TOKEN (from the consuming workflow's `github` context;
#   semantic-release pushes the release tag and creates the GitHub Release
#   with it), PARAM_CONFIG_FILE (path of the semantic-release config file to
#   require; empty disables the check).
# Side effects: runs `git fetch --tags origin`; exits 1 (without printing the
#   token) when GITHUB_TOKEN is empty or the config file is missing.
preflight() {
  # The `github` context carries GITHUB_TOKEN only. Check that name, and name
  # it in the error, so a missing context is not mistaken for an expired token.
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "GITHUB_TOKEN is empty. Attach the github context (GITHUB_TOKEN with contents:write) to this job." >&2
    exit 1
  fi

  if [ -n "${PARAM_CONFIG_FILE:-}" ] && [ ! -f "${PARAM_CONFIG_FILE}" ]; then
    echo "${PARAM_CONFIG_FILE} is missing in the package directory (app_dir)." >&2
    echo "Copy workflows/publish/templates/semantic-release/.releaserc.json from circleci-configurations, or set config_file to the file you use." >&2
    exit 1
  fi

  # semantic-release finds the last release from git tags, and `checkout`
  # does not guarantee every tag is present.
  git fetch --tags origin
}

# Script entry point, run only when this file is executed directly (not
# sourced by BATS -- see the ORB_TEST_ENV guard below).
main() {
  preflight
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
