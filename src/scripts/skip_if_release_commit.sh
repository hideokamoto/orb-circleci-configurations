#!/usr/bin/env bash
set -euo pipefail

# Halt the current job when the current commit is a release-please version
# bump commit, or when the commit message carries an explicit CI-skip
# marker. Must run after `checkout`.
#
# The release-commit check is intentionally scoped to the commit *subject*
# (first line) only, matched with a leading-anchor regex. Matching against
# the full commit body instead would false-positive on ordinary commits
# whose body merely references a release-please commit (for example, a
# follow-up commit whose body reads "Follow-up to the chore(main): release
# 1.2.0 commit ..."). The CI-skip marker check intentionally scans the full
# commit message body, matching the common `[skip ci]` / `[ci skip]`
# convention used across CI providers.
#
# Globals (read):
#   PARAM_RELEASE_SUBJECT_REGEX - grep -E pattern matched against the commit
#                                 subject only (orb parameter release_subject_regex,
#                                 passed through `circleci env subst`).
#   PARAM_SKIP_CI_REGEX         - grep -E pattern matched against the full
#                                 commit message body (orb parameter
#                                 skip_ci_regex, passed through
#                                 `circleci env subst`).
# Arguments:
#   None.
# Outputs:
#   Writes a one-line explanation to stdout when either check matches.
# Returns:
#   0 always (bash's implicit last-command status when neither check
#   matches, or an explicit `return 0` right after halting).
# Side effects:
#   Calls `circleci-agent step halt` (terminating the job step in a real
#   CircleCI run) when either check matches.
main() {
    local release_subject_regex skip_ci_regex commit_subject commit_message

    release_subject_regex="$(circleci env subst "${PARAM_RELEASE_SUBJECT_REGEX}")"
    skip_ci_regex="$(circleci env subst "${PARAM_SKIP_CI_REGEX}")"

    commit_subject="$(git log -1 --pretty=%s)"
    if echo "${commit_subject}" | grep -qE "${release_subject_regex}"; then
        echo "Release-please version commit detected (subject: ${commit_subject}) — skipping."
        circleci-agent step halt
        # In a real job, `circleci-agent step halt` terminates step
        # execution immediately. This explicit return keeps behavior
        # deterministic when the agent is stubbed (e.g. under bats-core).
        return 0
    fi

    commit_message="$(git log -1 --pretty=%B)"
    if echo "${commit_message}" | grep -qE "${skip_ci_regex}"; then
        echo "Skip CI marker detected in commit message — skipping."
        circleci-agent step halt
        return 0
    fi
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
