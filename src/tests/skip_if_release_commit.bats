#!/usr/bin/env bats
# Covers src/scripts/skip_if_release_commit.sh:
#   - a release-please version-bump commit subject halts the job
#   - a normal commit whose body merely *mentions* a release-please commit
#     does not halt (the subject-only scoping is the point of this command)
#   - any of the CI-skip markers in the commit message halts the job
#   - an ordinary commit does not halt at all

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT="${REPO_ROOT}/src/scripts/skip_if_release_commit.sh"

    TEST_DIR="$(mktemp -d)"
    STUB_BIN="${TEST_DIR}/bin"
    mkdir -p "${STUB_BIN}"

    HALT_LOG="${TEST_DIR}/halt.log"
    : >"${HALT_LOG}"

    # Real `circleci env subst` is available and side-effect free, so it is
    # exercised as-is rather than stubbed.
    cat >"${STUB_BIN}/circleci-agent" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"${HALT_LOG}"
exit 0
EOF
    chmod +x "${STUB_BIN}/circleci-agent"

    PATH="${STUB_BIN}:${PATH}"

    REPO="${TEST_DIR}/repo"
    mkdir -p "${REPO}"
    git -C "${REPO}" init -q
    git -C "${REPO}" -c user.name="Test" -c user.email="test@example.com" \
        commit -q --allow-empty -m "chore: initial commit"

    export PARAM_RELEASE_SUBJECT_REGEX='^chore(\([^)]+\))?: release'
    export PARAM_SKIP_CI_REGEX='\[skip ci\]|\[ci skip\]|circleci\[skip\]|circleci:skip'
}

teardown() {
    rm -rf "${TEST_DIR}"
}

commit() {
    git -C "${REPO}" -c user.name="Test" -c user.email="test@example.com" \
        commit -q --allow-empty -m "$1"
}

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
