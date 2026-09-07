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
#                        append after the date. Validated before use: must
#                        be an integer from 1 through the length of
#                        CIRCLE_SHA1 (typically 40), since 0 would leave a
#                        trailing "-" on the tag and a negative value would
#                        silently drop characters off the *end* of the SHA
#                        rather than take a leading substring.
#   CIRCLE_SHA1       - the commit SHA to build the tag's short-sha suffix
#                        from and to tag.
#   CIRCLECI_CLI      - path to the `circleci` CLI binary (default
#                        /usr/bin/circleci, since cimg/base does not put
#                        it on PATH); overridable so BATS can stub it.
# Arguments:
#   None.
# Outputs:
#   Writes a "sha_length must be an integer between 1 and <N>..." message
#   to stderr when PARAM_SHA_LENGTH fails validation. Writes "Tag <tag>
#   already exists on remote, skipping." to stdout when the pre-push
#   existence check finds the tag. Writes "Tag <tag> was created
#   concurrently by another push targeting the same commit; treating as
#   success." to stdout when `git push` was rejected but a post-push
#   recheck finds the expected tag already on the remote, pointing at this
#   same commit (see the concurrent-retry note below). Otherwise no output
#   of its own (beyond whatever `git tag`/`git push` print).
# Returns:
#   0 on success: the tag was created and pushed, the pre-push check found
#   it already present, or the post-push concurrent-retry recheck found it
#   present and pointing at CIRCLE_SHA1. 1 when PARAM_SHA_LENGTH fails
#   validation. Otherwise the `git push` command's own non-zero exit
#   status, when the push was rejected and the recheck did not confirm an
#   equivalent, already-pushed tag.
# Side effects:
#   Creates a local git tag and attempts to push it to "origin" when the
#   tag name is not already present on the remote.
push_deploy_tag() {
    local date_format
    local sha_length
    local tag
    local push_status
    local remote_sha1

    date_format="$("$CIRCLECI_CLI" env subst "${PARAM_DATE_FORMAT}")"
    sha_length="${PARAM_SHA_LENGTH}"

    if ! [[ "${sha_length}" =~ ^-?[0-9]+$ ]] \
        || [ "${sha_length}" -lt 1 ] \
        || [ "${sha_length}" -gt "${#CIRCLE_SHA1}" ]; then
        echo "sha_length must be an integer between 1 and ${#CIRCLE_SHA1} (the length of CIRCLE_SHA1); got: '${sha_length}'" >&2
        return 1
    fi

    tag="$(date -u "+${date_format}")-${CIRCLE_SHA1:0:sha_length}"

    # Exact-match the ref name (rather than the previous `grep -q "${tag}"`
    # substring test): `git ls-remote`'s pattern matching is tail-anchored
    # at "/" boundaries, so an unqualified "${tag}" pattern also matches
    # any ref that has it as a slash-separated tail component — e.g.
    # "refs/tags/decoy/${tag}" — even though "refs/tags/${tag}" itself was
    # never pushed, and `grep -q "${tag}"` would then accept that as
    # "already exists". `--refs` drops peeled `^{}` entries for annotated
    # tags so they can't cause a spurious duplicate match either.
    if git ls-remote --tags --refs origin "refs/tags/${tag}" |
        awk -v expected="refs/tags/${tag}" '$2 == expected { found=1 } END { exit !found }'; then
        echo "Tag ${tag} already exists on remote, skipping."
        return 0
    fi

    git tag "${tag}"

    push_status=0
    git push origin "${tag}" || push_status=$?
    if [ "${push_status}" -eq 0 ]; then
        return 0
    fi

    # The push was rejected. This can legitimately happen when two jobs
    # target the same commit concurrently (or one is a retry of the
    # other): both can pass the "does the tag exist yet" check above
    # before either has pushed, so whichever job's `git push` loses the
    # race gets a rejection even though nothing is actually wrong. Re-check
    # the remote: only if the tag now exists there *and* points at this
    # same commit do we treat the rejection as a successful, idempotent
    # outcome. Any other failure (auth, network, or — more concerningly —
    # the tag existing but pointing at a *different* commit) still fails
    # with git's original exit status.
    remote_sha1="$(git ls-remote --tags origin "refs/tags/${tag}" 2>/dev/null | awk '{print $1}')" || true
    if [ "${remote_sha1}" = "${CIRCLE_SHA1}" ]; then
        echo "Tag ${tag} was created concurrently by another push targeting the same commit; treating as success."
        return 0
    fi

    return "${push_status}"
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
