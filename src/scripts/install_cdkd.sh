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

install_cdkd() {
    local version="$1"

    npm install --global "@go-to-k/cdkd@${version}"
    cdkd --version
}

main() {
    local version
    version="$(circleci env subst "${PARAM_VERSION}")"

    install_cdkd "${version}"
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
