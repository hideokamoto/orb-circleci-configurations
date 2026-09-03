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

resolve_deploy_tag() {
    local tag_regex commit output_env halt_if_missing tag

    tag_regex="$(circleci env subst "${PARAM_TAG_REGEX}")"
    commit="$(circleci env subst "${PARAM_COMMIT}")"
    output_env="$(circleci env subst "${PARAM_OUTPUT_ENV}")"
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

main() {
    resolve_deploy_tag
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
