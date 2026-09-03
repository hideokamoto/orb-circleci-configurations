#!/usr/bin/env bats
# Covers src/scripts/skip_if_release_commit.sh:
#   - a release-please version-bump commit subject halts the job
#   - a normal commit whose body merely *mentions* a release-please commit
#     does not halt (the subject-only scoping is the point of this command)
#   - any of the CI-skip markers in the commit message halts the job
#   - an ordinary commit does not halt at all

# Prepares an isolated fixture for one test case: resolves the script
# under test, creates a scratch directory holding a stubbed
# `circleci-agent` (that appends its arguments to a halt log instead of
# actually halting anything) and a stubbed `circleci` CLI (that
# implements just enough of `env subst` for the script under test) and a
# fresh git repo, and exports the two orb parameters as the PARAM_* env
# vars the script reads. Both stubs are pointed to via env vars
# (CIRCLECI_CLI) or PATH (circleci-agent) rather than relying on either
# binary's real installed location, since production only guarantees the
# circleci CLI at the full path /usr/bin/circleci.
# Arguments:
#   None (bats-core calls this automatically before every @test).
# Outputs:
#   None.
# Returns:
#   0 on success (aborts the test via bats if any setup command fails).
# Side effects:
#   Creates REPO_ROOT/SCRIPT/TEST_DIR/STUB_BIN/HALT_LOG/REPO globals for
#   the test body to use; prepends STUB_BIN to PATH; exports
#   PARAM_RELEASE_SUBJECT_REGEX, PARAM_SKIP_CI_REGEX and CIRCLECI_CLI;
#   writes files under TEST_DIR (a mktemp -d directory) and initializes a
#   git repo.
setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT="${REPO_ROOT}/src/scripts/skip_if_release_commit.sh"

    TEST_DIR="$(mktemp -d)"
    STUB_BIN="${TEST_DIR}/bin"
    mkdir -p "${STUB_BIN}"

    HALT_LOG="${TEST_DIR}/halt.log"
    : >"${HALT_LOG}"

    cat >"${STUB_BIN}/circleci-agent" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"${HALT_LOG}"
exit 0
EOF
    chmod +x "${STUB_BIN}/circleci-agent"

    # Stub for the circleci CLI: the script under test only ever calls
    # `$CIRCLECI_CLI env subst <string>`, so implement just that as a
    # passthrough (none of the default regex parameters contain `$`
    # references for env subst to actually substitute).
    cat >"${STUB_BIN}/circleci" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "env" ] && [ "$2" = "subst" ]; then
    printf '%s' "$3"
    exit 0
fi
echo "circleci stub: unsupported invocation: $*" >&2
exit 1
EOF
    chmod +x "${STUB_BIN}/circleci"

    PATH="${STUB_BIN}:${PATH}"
    CIRCLECI_CLI="${STUB_BIN}/circleci"

    REPO="${TEST_DIR}/repo"
    mkdir -p "${REPO}"
    git -C "${REPO}" init -q
    git -C "${REPO}" -c user.name="Test" -c user.email="test@example.com" \
        commit -q --allow-empty -m "chore: initial commit"

    export PARAM_RELEASE_SUBJECT_REGEX='^chore(\([^)]+\))?: release'
    export PARAM_SKIP_CI_REGEX='\[skip ci\]|\[ci skip\]|circleci\[skip\]|circleci:skip'
    export CIRCLECI_CLI
}

# Removes the per-test scratch directory (fixture repo, stub bin, halt
# log) created by setup(), so nothing leaks between test cases or past
# the bats run.
# Arguments:
#   None (bats-core calls this automatically after every @test).
# Outputs:
#   None.
# Returns:
#   0 always.
# Side effects:
#   Recursively deletes TEST_DIR (and everything setup() put under it).
teardown() {
    rm -rf "${TEST_DIR}"
}

# Creates an empty commit in the fixture repo with the given commit
# message, used by each @test to set up the exact subject/body under
# test.
# Arguments:
#   $1 - the full commit message (subject line, optionally followed by a
#        blank line and a body) to pass to `git commit -m`.
# Outputs:
#   None (git's own commit output is suppressed via -q).
# Returns:
#   git commit's exit status (non-zero aborts the test via bats).
# Side effects:
#   Adds one empty commit to the git repo at REPO.
commit() {
    git -C "${REPO}" -c user.name="Test" -c user.email="test@example.com" \
        commit -q --allow-empty -m "$1"
}

# Runs the script under test against the fixture repo's current HEAD
# commit, capturing its exit status and output via bats-core's `run`
# helper for the calling @test's assertions.
# Arguments:
#   None (operates on the REPO/SCRIPT globals set up by setup()).
# Outputs:
#   None directly; bats-core's `run` captures the script's stdout into
#   $output.
# Returns:
#   0 always; the script's own exit status is captured into $status by
#   bats-core's `run` rather than propagated here.
# Side effects:
#   Changes the shell's working directory to REPO for the remainder of
#   the test (each @test runs in its own bats-core subshell, so this
#   does not leak across test cases); may append to HALT_LOG via the
#   stubbed circleci-agent if the script halts.
run_script() {
    cd "${REPO}"
    run bash "${SCRIPT}"
}

@test "halts on a release-please version-bump subject (scoped, no context)" {
    commit "chore: release 1.2.3"

    run_script

    [ "$status" -eq 0 ]
    [ "$(wc -l <"${HALT_LOG}")" -eq 1 ]
    grep -q "^step halt$" "${HALT_LOG}"
}

@test "halts on a release-please version-bump subject (scoped, with context)" {
    commit "chore(main): release 1.2.3"

    run_script

    [ "$status" -eq 0 ]
    [ "$(wc -l <"${HALT_LOG}")" -eq 1 ]
}

@test "does not halt when a release commit is only mentioned in the body" {
    commit "fix: retry release upload

Follow-up to the chore(main): release 1.2.0 commit that shipped the
broken artifact."

    run_script

    [ "$status" -eq 0 ]
    [ ! -s "${HALT_LOG}" ]
}

@test "halts on a [skip ci] marker anywhere in the commit message" {
    commit "docs: update README

Not a code change [skip ci]"

    run_script

    [ "$status" -eq 0 ]
    [ "$(wc -l <"${HALT_LOG}")" -eq 1 ]
}

@test "halts on a circleci:skip marker anywhere in the commit message" {
    commit "chore: tweak internal tooling

circleci:skip"

    run_script

    [ "$status" -eq 0 ]
    [ "$(wc -l <"${HALT_LOG}")" -eq 1 ]
}

@test "does not halt on an ordinary commit" {
    commit "feat: add new widget endpoint"

    run_script

    [ "$status" -eq 0 ]
    [ ! -s "${HALT_LOG}" ]
}
