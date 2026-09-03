#!/usr/bin/env bats

setup() {
    ORIG_PATH="$PATH"
    TEST_DIR="$(mktemp -d)"
    BIN_DIR="$TEST_DIR/bin"
    mkdir -p "$BIN_DIR"

    export BASH_ENV="$TEST_DIR/bash_env"
    : > "$BASH_ENV"

    HALT_LOG="$TEST_DIR/halt.log"
    cat > "$BIN_DIR/circleci-agent" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$HALT_LOG"
exit 0
EOF
    chmod +x "$BIN_DIR/circleci-agent"

    # Stub for `circleci env subst <value>`: none of these tests feed pipeline
    # value templates through the parameters, so it just echoes its argument
    # back, matching env subst's behavior on plain strings.
    cat > "$BIN_DIR/circleci" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "env" ] && [ "$2" = "subst" ]; then
    printf '%s' "$3"
    exit 0
fi
exit 1
EOF
    chmod +x "$BIN_DIR/circleci"

    export PATH="$BIN_DIR:$PATH"

    REPO_DIR="$TEST_DIR/repo"
    REMOTE_DIR="$TEST_DIR/remote.git"
    git init --quiet --bare "$REMOTE_DIR"
    git init --quiet "$REPO_DIR"
    cd "$REPO_DIR" || return 1
    git config user.email "test@example.com"
    git config user.name "Test"
    git remote add origin "$REMOTE_DIR"
    echo one > file.txt
    git add file.txt
    git commit --quiet -m "first"
    git push --quiet origin HEAD:main

    CIRCLE_SHA1="$(git rev-parse HEAD)"
    export CIRCLE_SHA1

    SCRIPT="$BATS_TEST_DIRNAME/../scripts/resolve_deploy_tag.sh"

    export PARAM_TAG_REGEX='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]{7}$'
    export PARAM_COMMIT=""
    export PARAM_OUTPUT_ENV="RELEASE_TAG"
    export PARAM_HALT_IF_MISSING="true"
}

teardown() {
    cd / || true
    export PATH="$ORIG_PATH"
    rm -rf "$TEST_DIR"
}

@test "halts via circleci-agent when no tag matches the commit" {
    run bash "$SCRIPT"

    [ "$status" -eq 0 ]
    [ -f "$HALT_LOG" ]
    grep -q "step halt" "$HALT_LOG"
    ! grep -q "RELEASE_TAG" "$BASH_ENV"
}

@test "does not halt when halt_if_missing is false and no tag matches" {
    export PARAM_HALT_IF_MISSING="false"

    run bash "$SCRIPT"

    [ "$status" -eq 0 ]
    [ ! -f "$HALT_LOG" ]
    ! grep -q "RELEASE_TAG" "$BASH_ENV"
}

@test "returns the alphabetically-first regex-matching tag when several match the same commit" {
    git tag 2026.09.03-bbbbbbb
    git tag 2026.09.03-aaaaaaa
    git tag not-a-release-tag

    run bash "$SCRIPT"

    [ "$status" -eq 0 ]
    [ ! -f "$HALT_LOG" ]
    grep -q 'export RELEASE_TAG="2026.09.03-aaaaaaa"' "$BASH_ENV"
}

@test "ignores tags that do not match tag_regex" {
    git tag release-v9
    git tag 2026.01.01-1234567

    run bash "$SCRIPT"

    [ "$status" -eq 0 ]
    grep -q 'export RELEASE_TAG="2026.01.01-1234567"' "$BASH_ENV"
    ! grep -q "release-v9" "$BASH_ENV"
}

@test "falls back to CIRCLE_SHA1 when commit parameter is empty" {
    git tag 2026.05.05-deadbee

    run bash "$SCRIPT"

    [ "$status" -eq 0 ]
    grep -q 'export RELEASE_TAG="2026.05.05-deadbee"' "$BASH_ENV"
}

@test "honors a custom output_env name" {
    git tag 2026.05.05-deadbee
    export PARAM_OUTPUT_ENV="MY_TAG"

    run bash "$SCRIPT"

    [ "$status" -eq 0 ]
    grep -q 'export MY_TAG="2026.05.05-deadbee"' "$BASH_ENV"
}

@test "resolves an explicit commit parameter instead of CIRCLE_SHA1" {
    echo two > file2.txt
    git add file2.txt
    git commit --quiet -m "second"
    SECOND_SHA="$(git rev-parse HEAD)"
    git tag 2026.06.06-cafebee "$SECOND_SHA"

    export PARAM_COMMIT="$SECOND_SHA"
    export CIRCLE_SHA1="0000000000000000000000000000000000000"

    run bash "$SCRIPT"

    [ "$status" -eq 0 ]
    grep -q 'export RELEASE_TAG="2026.06.06-cafebee"' "$BASH_ENV"
}
