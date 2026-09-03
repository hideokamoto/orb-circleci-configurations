#!/usr/bin/env bash
set -euo pipefail

# Pushes a date-stamped release tag ("<date_format>-<sha_length-char short
# SHA>") to the "origin" remote for the current commit ($CIRCLE_SHA1), and
# skips (without erroring) if a tag with that exact name already exists on
# the remote. Ported from the "Push git tag on success" step duplicated
# across 5 deploy workflows in circleci-configurations.
#
# UTC note: the source computed the date with plain `date +<format>`
# (local-timezone dependent). This port pins to `date -u` so the tag's
# calendar date is deterministic regardless of the runner's timezone. See
# the push_deploy_tag command description / orb README / PR body for the
# full rationale (orb-circleci-configurations issue #5).
push_deploy_tag() {
    local date_format
    local sha_length
    local tag

    date_format="$(circleci env subst "${PARAM_DATE_FORMAT}")"
    sha_length="${PARAM_SHA_LENGTH}"

    tag="$(date -u "+${date_format}")-${CIRCLE_SHA1:0:sha_length}"

    if git ls-remote --tags origin "${tag}" | grep -q "${tag}"; then
        echo "Tag ${tag} already exists on remote, skipping."
    else
        git tag "${tag}"
        git push origin "${tag}"
    fi
}

main() {
    push_deploy_tag
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
