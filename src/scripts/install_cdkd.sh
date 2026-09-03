#!/usr/bin/env bash
# Installs a version-pinned copy of the cdkd CLI (https://github.com/go-to-k/cdkd).
#
# The version is pinned rather than resolved to "latest" so that a CI run
# against a given commit is reproducible: an unpinned install can pick up a
# new cdkd release without any change to this repository, which would make
# review results and deploy behavior non-deterministic over time. Bump the
# `version` command parameter in a reviewed commit when adopting a newer
# cdkd release; do not track "latest" here.
set -euo pipefail

# cimg/base (and other job images) don't put the build-agent `circleci` CLI
# on PATH — only the local CLI (no `env subst`) may be there, or nothing at
# all. The build-agent CLI is always available at this full path, so call
# it explicitly instead of relying on PATH. Overridable so bats-core tests
# can point this at a stub.
CIRCLECI_CLI="${CIRCLECI_CLI:-/usr/bin/circleci}"

# Installs the given cdkd version globally via npm and prints the
# installed CLI's version, so the step log confirms what actually landed.
#
# Arguments:
#   $1 - version: the exact cdkd version to install (no leading "v", no
#        range), e.g. "0.280.15".
# Returns / side effects:
#   Exit status is npm's (non-zero on install failure, propagated by
#   `set -e`). Installs the "@go-to-k/cdkd" package globally on the
#   current machine/container and writes `cdkd --version`'s output to
#   stdout. No stdout on success beyond the version print.
install_cdkd() {
    local version="$1"

    npm install --global "@go-to-k/cdkd@${version}"
    cdkd --version
}

# Entry point run when this script executes as a CircleCI step (not when
# sourced for bats-core tests). Resolves the orb's `version` parameter and
# installs that pinned cdkd version.
#
# Arguments:
#   None (reads the PARAM_VERSION environment variable set by the
#   install_cdkd command's `environment:` block).
# Returns / side effects:
#   Exit status is install_cdkd's. Calls `$CIRCLECI_CLI env subst` (the
#   build-agent CLI, called by full path since it isn't guaranteed to be on
#   PATH) to resolve PARAM_VERSION, so a caller-supplied pipeline/env-var
#   reference is expanded, then delegates to install_cdkd with the
#   resolved value.
main() {
    local version
    version="$("$CIRCLECI_CLI" env subst "${PARAM_VERSION}")"

    install_cdkd "${version}"
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
