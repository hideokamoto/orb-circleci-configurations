#!/usr/bin/env bash
set -euo pipefail

# Idempotently creates a GitHub Release for the tag left by resolve_deploy_tag
# (env var named by PARAM_TAG_ENV, default RELEASE_TAG). Ported from the
# "Skip if release already exists (idempotent retry)" and "Create GitHub
# Release" steps in cloudflare-workers.yaml's create-github-release job.
# Requires gh/setup (contents:write) to have already run.
#
# Idempotency: when PARAM_SKIP_IF_EXISTS is true, `gh release view <tag>` is
# checked first and the step halts (circleci-agent step halt) without
# failing the job if a release already exists, so a retried job or a
# re-triggered workflow run is a safe no-op instead of an error.
#
# Release notes source (3 branches, evaluated in this order, matching the
# source step exactly):
#   1. notes_source_env resolves to "deploy-diff-summaries" (set by
#      generate_release_notes_from_deploy_diff on success): use the file
#      named by notes_file_env via --notes-file.
#   2. prev_tag_env is set (set by resolve_previous_deploy_tag): use gh's
#      own --generate-notes with --notes-start-tag so the notes only cover
#      commits since the previous release.
#   3. Otherwise (first release for this repo, or Deploy Diff Summaries and
#      resolve_previous_deploy_tag both found nothing): --generate-notes
#      with no start tag.
#
# Args: none (takes no positional arguments).
# Reads (indirectly, via the PARAM_*_ENV name parameters, all exported by
# the calling orb command step):
#   PARAM_TAG_ENV           - name of the env var holding the release tag
#   PARAM_SKIP_IF_EXISTS    - "true"/"false"; whether to no-op on an
#                             existing release for the tag
#   PARAM_NOTES_SOURCE_ENV  - name of the env var selecting the notes source
#   PARAM_PREV_TAG_ENV      - name of the env var holding the previous tag
#   PARAM_NOTES_FILE_ENV    - name of the env var holding the notes file path
# Returns: 0 on success (including the idempotent-skip no-op path); exits 1
#   if the resolved release tag is empty.
# Side effects: may run `gh release view` / `gh release create` (network
#   call to GitHub), may call `circleci-agent step halt` (halts the step
#   without failing the job), and writes progress messages to stdout/stderr.
create_github_release() {
    local tag_env tag
    local prev_tag_env prev_tag
    local notes_source_env notes_source
    local notes_file_env notes_file

    tag_env="${PARAM_TAG_ENV}"
    tag="${!tag_env:-}"
    if [ -z "${tag}" ]; then
        echo "${tag_env} is empty; no release tag to act on." >&2
        exit 1
    fi

    if [ "${PARAM_SKIP_IF_EXISTS}" = "true" ]; then
        if gh release view "${tag}" >/dev/null 2>&1; then
            echo "Release ${tag} already exists; skipping."
            circleci-agent step halt
            return 0
        fi
    fi

    notes_source_env="${PARAM_NOTES_SOURCE_ENV}"
    notes_source="${!notes_source_env:-}"

    prev_tag_env="${PARAM_PREV_TAG_ENV}"
    prev_tag="${!prev_tag_env:-}"

    if [ "${notes_source}" = "deploy-diff-summaries" ]; then
        notes_file_env="${PARAM_NOTES_FILE_ENV}"
        notes_file="${!notes_file_env:-}"
        gh release create "${tag}" --notes-file "${notes_file}"
    elif [ -n "${prev_tag}" ]; then
        gh release create "${tag}" --generate-notes --notes-start-tag "${prev_tag}"
    else
        echo "No previous release tag; creating first release without --notes-start-tag."
        gh release create "${tag}" --generate-notes
    fi
}

# Entry point invoked when this script is executed directly (not sourced
# by bats-core; see the guard below).
# Args: none.
# Returns: the exit status of create_github_release.
# Side effects: same as create_github_release (gh release view/create,
#   possible circleci-agent step halt).
main() {
    create_github_release
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
