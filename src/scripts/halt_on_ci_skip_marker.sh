#!/usr/bin/env bash
set -euo pipefail

# Halts the current job (successfully, via `circleci-agent step halt`) when the
# HEAD commit message carries a skip-ci marker: [skip ci], [ci skip],
# circleci[skip] or circleci:skip. Same markers and pattern as the
# `skip-if-ci-skip-marker` command of circleci-configurations'
# workflows/publish/*-semantic-release.yaml, so switching a release job to this
# orb keeps that behavior.
#
# Args: none. Reads the HEAD commit of the current git repository.
# Returns: 0 (after halting the job when a marker is found).
# Side effects: may call `circleci-agent step halt`; writes a message to stdout.
halt_on_ci_skip_marker() {
    local message
    message="$(git log -1 --pretty=%B)"
    # A here-string instead of `printf | grep -q`: under pipefail, grep -q
    # exiting at the first match can SIGPIPE the writer of a long message
    # and turn a match into a failed condition.
    if grep -qE '\[skip ci\]|\[ci skip\]|circleci\[skip\]|circleci:skip' <<<"${message}"; then
        echo "Skip CI marker detected; skipping the rest of this job."
        circleci-agent step halt
    fi
}

# Entry point invoked when this script is executed directly (not sourced
# by bats-core; see the guard below).
main() {
    halt_on_ci_skip_marker
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
