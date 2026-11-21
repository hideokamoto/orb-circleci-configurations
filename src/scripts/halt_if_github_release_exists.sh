#!/usr/bin/env bash
set -euo pipefail

# Halts the current job (successfully, via `circleci-agent step halt`) when a
# GitHub Release already exists for the deploy tag held in the environment
# variable named by PARAM_TAG_ENV (default RELEASE_TAG, as exported by the
# resolve_deploy_tag command).
#
# Used by the github_release_from_deploy_tag job to stop *before* the
# release notes are generated, mirroring the source job's step order
# (cloudflare-workers.yaml's create-github-release: "Skip if release
# already exists (idempotent retry)" runs before "Resolve previous release
# tag" and "Generate release notes (Deploy Diff Summaries)"). Without this
# early check a "Rerun workflow from start" on an already-released commit
# would still call the Deploy Diff Summaries API -- and poll it for up to
# max_polls * poll_interval seconds -- only for create_github_release's own
# skip_if_exists check to discard the result. create_github_release keeps
# its own check as well: it closes the window between this step and the
# create call (two jobs racing on the same tag).
#
# Any non-zero `gh release view` exit (not found, but also an auth or
# network error) is treated as "no release yet", matching the source step;
# a real auth/network problem then surfaces at `gh release create`.
#
# Args: none.
# Reads:
#   PARAM_TAG_ENV - name of the env var holding the release tag
#                   (default RELEASE_TAG when unset or empty).
# Returns: 0 when the release does not exist yet, or after halting the job
#   because it already does; 1 if PARAM_TAG_ENV is not a valid Bash
#   identifier or the tag variable it names is empty.
# Side effects: runs `gh release view` (network call to GitHub); may call
#   `circleci-agent step halt`; writes progress messages to stdout/stderr.
halt_if_github_release_exists() {
    local tag_env tag

    tag_env="${PARAM_TAG_ENV:-RELEASE_TAG}"
    if ! [[ "${tag_env}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Error: tag env name '${tag_env}' is not a valid Bash identifier." >&2
        return 1
    fi

    tag="${!tag_env:-}"
    if [ -z "${tag}" ]; then
        echo "${tag_env} is empty; no release tag to check." >&2
        return 1
    fi

    if gh release view "${tag}" >/dev/null 2>&1; then
        echo "Release ${tag} already exists; skipping release notes and creation."
        circleci-agent step halt
        return 0
    fi

    echo "No GitHub Release for ${tag} yet; continuing."
}

# Entry point invoked when this script is executed directly (not sourced
# by bats-core; see the guard below).
# Args: none.
# Returns: the exit status of halt_if_github_release_exists.
# Side effects: same as halt_if_github_release_exists.
main() {
    halt_if_github_release_exists
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
