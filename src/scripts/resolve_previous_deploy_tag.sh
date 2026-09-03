#!/usr/bin/env bash
set -euo pipefail

# Full path to the CircleCI build-agent CLI. cimg/base does not put
# `circleci` on PATH (only the build agent injects a binary at
# /usr/bin/circleci for real job execution), so this is called by full
# path rather than relying on PATH resolution. Overridable via the
# CIRCLECI_CLI environment variable so BATS can point it at a stub.
CIRCLECI_CLI="${CIRCLECI_CLI:-/usr/bin/circleci}"

# Resolve the release tag immediately before the current release, using only
# commit ancestry as the source of truth. See the command description for
# the full rationale (--sort=-refname and --sort=-creatordate are both
# unsafe for this repo's tag shape).
#
# Reads (via the PARAM_* environment variables set by the command's run
# step): PARAM_TAG_REGEX (string, substituted through `circleci env subst`),
# PARAM_RELEASE_TAG_ENV (env_var_name, read by indirection), PARAM_OUTPUT_ENV
# (string, substituted through `circleci env subst`).
# Side effects: appends `export <output env>="<prev tag>"` to $BASH_ENV when
# a previous release tag is found; writes progress/result messages to
# stdout; exits 1 with a message on stderr if the release tag env var named
# by PARAM_RELEASE_TAG_ENV is unset or empty.
main() {
    local tag_regex release_tag_env_name release_tag output_env_name release_commit prev_tag

    tag_regex="$("${CIRCLECI_CLI}" env subst "${PARAM_TAG_REGEX}")"
    release_tag_env_name="${PARAM_RELEASE_TAG_ENV}"
    output_env_name="$("${CIRCLECI_CLI}" env subst "${PARAM_OUTPUT_ENV}")"

    # env_var_name parameter: read by indirection so callers can point this
    # command at any previously exported release-tag variable.
    release_tag="${!release_tag_env_name:-}"
    if [ -z "${release_tag}" ]; then
        echo "resolve_previous_deploy_tag: \$${release_tag_env_name} is not set; cannot resolve a previous tag without the current release tag." >&2
        exit 1
    fi

    release_commit="$(git rev-list -n1 "${release_tag}")"

    # Walk from the release commit toward its ancestors (git log's default
    # enumeration order guarantees a commit is listed before its ancestors).
    # The first ancestor carrying a tag_regex-matching tag other than the
    # release tag itself is the previous release. `|| true` absorbs the
    # pipefail-driven non-zero status from the `while read` loop hitting EOF
    # when no match is found (see command description for detail).
    #
    # Deliberate deviation from the migration source: this uses
    # `--pretty=tformat:'%H'`, not `--pretty=format:'%H'`. `format:` does not
    # terminate its last output line with a newline, so when the true
    # previous release tag sits on the walk's final (oldest) ancestor,
    # `read`'s last call returns a non-zero status even though it populated
    # `sha` — which makes `while` exit before ever running the loop body for
    # that commit, silently reporting "no previous release" instead.
    # `tformat:` is otherwise identical but appends a newline after every
    # entry including the last, so this fixes that false negative without
    # changing anything else about the walk.
    prev_tag="$(git log --pretty=tformat:'%H' "${release_commit}" \
        | while IFS= read -r sha; do
            git tag --points-at "${sha}" \
                | grep -E "${tag_regex}" \
                | grep -v -x "${release_tag}"
        done | head -n1 || true)"

    if [ -n "${prev_tag}" ]; then
        echo "export ${output_env_name}=\"${prev_tag}\"" >>"${BASH_ENV}"
        echo "resolve_previous_deploy_tag: previous release tag is ${prev_tag}"
    else
        echo "resolve_previous_deploy_tag: no previous release tag found (first release)"
    fi
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
