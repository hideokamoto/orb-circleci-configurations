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
# Side effects: appends `export <output env>=<prev tag, printf %q-escaped>`
# to $BASH_ENV when a previous release tag is found; writes progress/result
# messages to stdout; exits 1 with a message on stderr if the release tag
# env var named by PARAM_RELEASE_TAG_ENV is unset or empty, or if the
# resolved output env var name is not a safe shell identifier.
main() {
    local tag_regex release_tag_env_name release_tag output_env_name release_commit prev_tag prev_tag_safe
    local tag_regex_probe_status

    tag_regex="$("${CIRCLECI_CLI}" env subst "${PARAM_TAG_REGEX}")"
    release_tag_env_name="${PARAM_RELEASE_TAG_ENV}"
    output_env_name="$("${CIRCLECI_CLI}" env subst "${PARAM_OUTPUT_ENV}")"

    # output_env_name becomes a literal shell identifier in an
    # `export NAME=...` line appended to $BASH_ENV. Since it is
    # parameter-derived, validate it against a conventional environment
    # variable identifier shape *before* anything is written, so a
    # malformed or hostile parameter value can never smuggle shell syntax
    # into whatever later step sources $BASH_ENV.
    if ! [[ "${output_env_name}" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
        echo "resolve_previous_deploy_tag: output_env \"${output_env_name}\" is not a safe environment variable name (expected uppercase letters, digits and underscores only, not starting with a digit); refusing to write to \$BASH_ENV." >&2
        exit 1
    fi

    # env_var_name parameter: read by indirection so callers can point this
    # command at any previously exported release-tag variable.
    release_tag="${!release_tag_env_name:-}"
    if [ -z "${release_tag}" ]; then
        echo "resolve_previous_deploy_tag: \$${release_tag_env_name} is not set; cannot resolve a previous tag without the current release tag." >&2
        exit 1
    fi

    release_commit="$(git rev-list -n1 "${release_tag}")"

    # Validate tag_regex as an extended regular expression *before* it is
    # used to walk commit history below. Without this check, a syntactically
    # invalid regex makes every `grep -E` call in the walk fail (exit status
    # 2), which the walk's trailing `|| true` (needed to absorb the `while
    # read` loop's normal EOF non-zero status) would silently swallow too —
    # producing an empty prev_tag that is indistinguishable from the
    # legitimate "no matching tag found, this is the first release" case.
    # Probing against empty input isolates a syntax error (grep exit status
    # 2) from "valid regex, simply no match" (exit status 1) without
    # depending on any real tag data.
    if grep -E -- "${tag_regex}" >/dev/null 2>&1 </dev/null; then
        :
    else
        tag_regex_probe_status=$?
        if [ "${tag_regex_probe_status}" -ge 2 ]; then
            echo "resolve_previous_deploy_tag: tag_regex \"${tag_regex}\" is not a valid extended regular expression (grep -E rejected it); refusing to walk commit history with it." >&2
            exit 1
        fi
    fi

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
                | grep -v -F -x "${release_tag}"
        done | head -n1 || true)"

    if [ -n "${prev_tag}" ]; then
        # printf %q renders prev_tag as a single shell-safe token (quoting
        # or escaping it only if its content actually requires that), so a
        # tag value containing shell metacharacters cannot be executed when
        # a later step sources $BASH_ENV.
        printf -v prev_tag_safe '%q' "${prev_tag}"
        echo "export ${output_env_name}=${prev_tag_safe}" >>"${BASH_ENV}"
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
