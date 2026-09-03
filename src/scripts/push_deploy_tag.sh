#!/usr/bin/env bash
set -euo pipefail

# The cimg/base image (this command's default executor) does not put
# `circleci` on PATH; the CircleCI job runtime only provides it at
# /usr/bin/circleci. Call the CLI through this variable everywhere instead
# of a bare `circleci`, so the script works unmodified on that image and
# so BATS tests can redirect it to a stub.
CIRCLECI_CLI="${CIRCLECI_CLI:-/usr/bin/circleci}"

# push_deploy_tag
#
# Computes a date-stamped release tag for the current commit and pushes it
# to the "origin" remote, skipping (without erroring) if a tag with that
# exact name already exists there. Ported from the "Push git tag on
# success" step duplicated across 5 deploy workflows in
# circleci-configurations.
#
# UTC note: the source computed the date with plain `date +<format>`
# (local-timezone dependent). This port pins to `date -u` so the tag's
# calendar date is deterministic regardless of the runner's timezone. See
# the push_deploy_tag command description / orb README / PR body for the
# full rationale (orb-circleci-configurations issue #5).
#
# Globals read:
#   PARAM_DATE_FORMAT - `date -u` format string for the tag's date portion,
#                        substituted via `"$CIRCLECI_CLI" env subst` so
#                        callers may pass pipeline-value placeholders.
#   PARAM_SHA_LENGTH  - number of leading characters of CIRCLE_SHA1 to
#                        append after the date.
#   CIRCLE_SHA1       - the commit SHA to build the tag's short-sha suffix
#                        from and to tag.
#   CIRCLECI_CLI      - path to the `circleci` CLI binary (default
#                        /usr/bin/circleci, since cimg/base does not put
#                        it on PATH); overridable so BATS can stub it.
# Arguments:
#   None.
# Outputs:
#   Writes "Tag <tag> already exists on remote, skipping." to stdout when
#   the tag is already present on the remote; otherwise no output of its
#   own (beyond whatever `git tag`/`git push` print).
# Returns:
#   0 on success (tag created and pushed, or the skip path was logged).
#   Non-zero if a `git` command fails, propagated by the script's
#   `set -euo pipefail`.
# Side effects:
#   Creates a local git tag and pushes it to "origin" when that tag name
#   is not already present on the remote.
push_deploy_tag() {
    local date_format
    local sha_length
    local tag

    date_format="$("$CIRCLECI_CLI" env subst "${PARAM_DATE_FORMAT}")"
    sha_length="${PARAM_SHA_LENGTH}"

    tag="$(date -u "+${date_format}")-${CIRCLE_SHA1:0:sha_length}"

    if git ls-remote --tags origin "${tag}" | grep -q "${tag}"; then
        echo "Tag ${tag} already exists on remote, skipping."
    else
        git tag "${tag}"
        git push origin "${tag}"
    fi
}

# main
#
# Entry point run when this script is executed directly (as opposed to
# being sourced by the bats-core test suite). Delegates to
# push_deploy_tag().
# Arguments:
#   None.
# Outputs:
#   None of its own; see push_deploy_tag().
# Returns:
#   The exit status of push_deploy_tag().
main() {
    push_deploy_tag
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
