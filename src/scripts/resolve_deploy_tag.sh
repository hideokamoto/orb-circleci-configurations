#!/usr/bin/env bash
# Resolve the deploy tag that was actually pushed to a commit, and export it
# to $BASH_ENV.
#
# Why this never recomputes the tag with `date`: the tag-pushing side of this
# workflow names tags "YYYY.MM.DD-<sha7>" at the moment it deploys. If this
# step instead ran `date +%Y.%m.%d` to guess the tag name, a commit that
# deployed just before a UTC day boundary would compute a *different* tag
# name here than the one that was really pushed, and the caller (typically
# GitHub Release creation) would silently no-op against a tag that does not
# exist. Reading the tag back off the commit with `git tag --points-at` is
# deterministic and immune to clock/timezone skew between steps.
set -euo pipefail

# cimg/base does not put the standalone `circleci` CLI on PATH; the job
# environment only guarantees the build-agent CLI at /usr/bin/circleci.
# Allow overriding for tests (bats points this at a PATH stub).
CIRCLECI_CLI="${CIRCLECI_CLI:-/usr/bin/circleci}"

# Resolve the deploy tag pointing at a commit and export it to $BASH_ENV.
#
# Arguments: none (reads its inputs from the PARAM_* environment variables
#   set by the orb command's `run` step: PARAM_TAG_REGEX, PARAM_COMMIT,
#   PARAM_OUTPUT_ENV, PARAM_HALT_IF_MISSING; also reads CIRCLE_SHA1 when
#   PARAM_COMMIT resolves to an empty string, and $CIRCLECI_CLI for the
#   `circleci` binary to run `env subst` through).
# Returns: 0 on both a resolved tag and a missing tag with
#   PARAM_HALT_IF_MISSING="false"; does not return when
#   PARAM_HALT_IF_MISSING="true" and no tag matches, since
#   `circleci-agent step halt` ends the step there.
# Side effects: runs `git fetch --tags --force origin` against the current
#   working directory's repo; on a match, appends
#   `export <PARAM_OUTPUT_ENV>="<tag>"` to $BASH_ENV so later steps in the
#   same job can read it.
resolve_deploy_tag() {
    local tag_regex commit output_env halt_if_missing tag

    tag_regex="$("$CIRCLECI_CLI" env subst "${PARAM_TAG_REGEX}")"
    commit="$("$CIRCLECI_CLI" env subst "${PARAM_COMMIT}")"
    output_env="$("$CIRCLECI_CLI" env subst "${PARAM_OUTPUT_ENV}")"
    halt_if_missing="${PARAM_HALT_IF_MISSING}"

    if [ -z "$commit" ]; then
        commit="$CIRCLE_SHA1"
    fi

    git fetch --tags --force origin

    # `|| true` keeps a no-match (grep exit 1) from tripping `set -e` /
    # pipefail; a missing tag is a normal, expected outcome here.
    tag="$(git tag --points-at "$commit" | grep -E "$tag_regex" | head -n1 || true)"

    if [ -z "$tag" ]; then
        echo "No tag matching '${tag_regex}' found on commit ${commit} (deploy was likely skipped)."
        if [ "$halt_if_missing" = "true" ]; then
            circleci-agent step halt
        fi
        return 0
    fi

    echo "Resolved deploy tag: ${tag}"
    echo "export ${output_env}=\"${tag}\"" >> "$BASH_ENV"
}

# Entry point invoked when this script is executed directly (not sourced).
#
# Arguments: none.
# Returns: whatever resolve_deploy_tag returns.
# Side effects: same as resolve_deploy_tag.
main() {
    resolve_deploy_tag
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
