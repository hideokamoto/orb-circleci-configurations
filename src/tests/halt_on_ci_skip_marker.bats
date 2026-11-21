#!/usr/bin/env bats
# Covers halt_on_ci_skip_marker.sh: the job halts (via circleci-agent step
# halt) when the HEAD commit message carries one of the skip-ci markers the
# pre-orb template recognised, and continues otherwise.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT="${REPO_ROOT}/src/scripts/halt_on_ci_skip_marker.sh"
    TEST_TMP="$(mktemp -d)"
    mkdir -p "${TEST_TMP}/bin" "${TEST_TMP}/repo"
    # Stub for circleci-agent: records the call instead of halting.
    cat >"${TEST_TMP}/bin/circleci-agent" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"${TEST_TMP}/agent_calls"
STUB
    chmod +x "${TEST_TMP}/bin/circleci-agent"
    export PATH="${TEST_TMP}/bin:${PATH}"
    cd "${TEST_TMP}/repo" || exit 1
    git init -q
    git config user.name "Test User"
    git config user.email "test@example.com"
    git config commit.gpgsign false
}

teardown() {
    cd "${BATS_TEST_DIRNAME}" || true
    rm -rf "${TEST_TMP}"
}

commit_with_message() {
    echo "$RANDOM" >>file.txt
    git add file.txt
    git commit -q -m "$1"
}

@test "an ordinary commit message does not halt" {
    commit_with_message "feat: add a thing"
    source "${SCRIPT}"
    run main
    [ "$status" -eq 0 ]
    [ ! -f "${TEST_TMP}/agent_calls" ]
}

@test "[skip ci] in the subject halts the job" {
    commit_with_message "chore: bump [skip ci]"
    source "${SCRIPT}"
    run main
    [ "$status" -eq 0 ]
    [ "$(cat "${TEST_TMP}/agent_calls")" = "step halt" ]
}

@test "[ci skip], circleci[skip] and circleci:skip also halt" {
    for marker in "[ci skip]" "circleci[skip]" "circleci:skip"; do
        rm -f "${TEST_TMP}/agent_calls"
        commit_with_message "docs: update ${marker}"
        source "${SCRIPT}"
        run main
        [ "$status" -eq 0 ]
        [ "$(cat "${TEST_TMP}/agent_calls")" = "step halt" ]
    done
}

@test "a marker in the commit body (not only the subject) halts the job" {
    commit_with_message "$(printf 'fix: something\n\nbody line\n[skip ci]')"
    source "${SCRIPT}"
    run main
    [ "$status" -eq 0 ]
    [ "$(cat "${TEST_TMP}/agent_calls")" = "step halt" ]
}

@test "a near-miss such as 'skip ci' without brackets does not halt" {
    commit_with_message "fix: do not skip ci checks"
    source "${SCRIPT}"
    run main
    [ "$status" -eq 0 ]
    [ ! -f "${TEST_TMP}/agent_calls" ]
}

@test "a marker at the start of a message larger than a pipe buffer still halts" {
    # With `printf | grep -q` under pipefail, grep exits at the first match
    # and printf can get SIGPIPE, which made the pipeline (and the check)
    # fail for long messages.
    {
        printf '[skip ci] long message\n\n'
        head -c 300000 /dev/zero | tr '\0' 'a' | fold -w 100
    } >"${TEST_TMP}/msg"
    echo "$RANDOM" >>file.txt
    git add file.txt
    git commit -q -F "${TEST_TMP}/msg"
    source "${SCRIPT}"
    run main
    [ "$status" -eq 0 ]
    [ "$(cat "${TEST_TMP}/agent_calls")" = "step halt" ]
}
