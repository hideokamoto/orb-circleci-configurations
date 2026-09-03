#!/usr/bin/env bats
# Covers src/scripts/skip_unless_changed.sh: base-revision resolution
# (explicit param, deploy-tag fallback with and without a tag present,
# parent-commit fallback), the fail-safe continue paths, and both skip
# modes.

# bats-core lifecycle hook, run before every @test in this file. Takes no
# arguments (bats calls it with none). Builds a throwaway git fixture (a
# bare "origin" plus a clone checked out as the working repo), stubs
# circleci-agent (to record halt calls) and the circleci CLI referenced via
# CIRCLECI_CLI (so tests never depend on a real circleci binary), and
# exports the PARAM_* env vars each @test's script invocation reads, set to
# the command's own parameter defaults. Side effects: creates a temp
# directory tree, prepends it to PATH, cds into the fixture repo, and
# exports TEST_DIR/STUB_DIR/HALT_LOG/ORIGIN/REPO/CIRCLECI_CLI plus the
# PARAM_* variables for the test body to read or override.
setup() {
    SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/src/scripts/skip_unless_changed.sh"

    TEST_DIR="$(mktemp -d)"
    STUB_DIR="$TEST_DIR/stubs"
    mkdir -p "$STUB_DIR"

    # circleci-agent stub: records every call so tests can assert whether
    # (and how) the job was halted.
    HALT_LOG="$TEST_DIR/halt.log"
    cat > "$STUB_DIR/circleci-agent" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$HALT_LOG"
EOF
    chmod +x "$STUB_DIR/circleci-agent"
    PATH="$STUB_DIR:$PATH"

    # circleci CLI stub, referenced via CIRCLECI_CLI (not PATH) exactly as
    # the script does, so this suite exercises the same indirection real
    # jobs use on images without a circleci binary on PATH (e.g. cimg/base).
    # None of the fixtures below pass parameter values containing a $VAR
    # reference, so a verbatim passthrough of `env subst`'s argument is a
    # faithful enough stand-in for the real subcommand's behavior here.
    CIRCLECI_CLI="$STUB_DIR/circleci-cli"
    cat > "$CIRCLECI_CLI" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "env" ] && [ "$2" = "subst" ]; then
    printf '%s' "$3"
fi
EOF
    chmod +x "$CIRCLECI_CLI"

    # Fixture repo: a local origin plus a clone that steps run against, so
    # that "git fetch --tags origin" in the deploy_tag fallback has a real
    # remote to talk to without touching the network.
    ORIGIN="$TEST_DIR/origin.git"
    git init --quiet --bare "$ORIGIN"

    REPO="$TEST_DIR/repo"
    git clone --quiet "$ORIGIN" "$REPO"
    cd "$REPO"
    git config user.email "test@example.com"
    git config user.name "Test"

    export TEST_DIR STUB_DIR HALT_LOG ORIGIN REPO CIRCLECI_CLI

    # Defaults matching the command's parameter defaults; each test
    # overrides only what it needs.
    export PARAM_BASE_REVISION=""
    export PARAM_HEAD_REVISION=""
    export PARAM_FALLBACK="deploy_tag"
    export PARAM_MODE="skip_if_only_matches"
    export PARAM_PATTERN='(^\.claude/|\.md$)'
    export PARAM_DEPLOY_TAG_GLOB='[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]-*'
}

# bats-core lifecycle hook, run after every @test in this file. Takes no
# arguments. Side effect: recursively removes TEST_DIR (the fixture repo,
# stubs, and halt log created by setup), leaving no state behind.
teardown() {
    rm -rf "$TEST_DIR"
}

# Test helper: writes $2 as the content of file $1 (creating parent
# directories as needed), stages it, and commits it in the current git
# repo (the fixture REPO checked out by setup). Args: $1 path, $2 file
# content. No output; side effect is the new commit, and it leaves HEAD
# pointing at it.
commit_file() {
    # commit_file <path> <content>
    mkdir -p "$(dirname "$1")"
    printf '%s' "$2" > "$1"
    git add "$1"
    git commit --quiet -m "commit $1"
}

@test "base_revision parameter explicit: skips when all changed files match pattern" {
    commit_file "README.md" "one"
    BASE_SHA="$(git rev-parse HEAD)"
    commit_file "docs/notes.md" "two"
    HEAD_SHA="$(git rev-parse HEAD)"

    export PARAM_BASE_REVISION="$BASE_SHA"
    export PARAM_HEAD_REVISION="$HEAD_SHA"
    export CIRCLE_SHA1="$HEAD_SHA"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Base revision: ${BASE_SHA}"* ]]
    [[ "$output" == *"source: base_revision parameter"* ]]
    [[ "$output" == *"halting this job"* ]]
    grep -q "^step halt$" "$HALT_LOG"
}

@test "base_revision parameter explicit: continues when a changed file does not match pattern" {
    commit_file "README.md" "one"
    BASE_SHA="$(git rev-parse HEAD)"
    commit_file "docs/notes.md" "two"
    commit_file "src/app.js" "code"
    HEAD_SHA="$(git rev-parse HEAD)"

    export PARAM_BASE_REVISION="$BASE_SHA"
    export PARAM_HEAD_REVISION="$HEAD_SHA"
    export CIRCLE_SHA1="$HEAD_SHA"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"continuing"* ]]
    [ ! -f "$HALT_LOG" ]
}

@test "empty base_revision falls back to the most recent deploy tag reachable from head" {
    commit_file "app.js" "v1"
    git tag "2026.01.01-abc1234"
    commit_file "README.md" "docs only"
    HEAD_SHA="$(git rev-parse HEAD)"
    git push --quiet origin --tags

    export PARAM_BASE_REVISION=""
    export PARAM_HEAD_REVISION="$HEAD_SHA"
    export CIRCLE_SHA1="$HEAD_SHA"
    export PARAM_FALLBACK="deploy_tag"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"most recent deploy tag 2026.01.01-abc1234"* ]]
    [[ "$output" == *"halting this job"* ]]
    grep -q "^step halt$" "$HALT_LOG"
}

@test "empty base_revision with deploy_tag fallback and no tag continues (fail-safe)" {
    commit_file "app.js" "v1"
    HEAD_SHA="$(git rev-parse HEAD)"

    export PARAM_BASE_REVISION=""
    export PARAM_HEAD_REVISION="$HEAD_SHA"
    export CIRCLE_SHA1="$HEAD_SHA"
    export PARAM_FALLBACK="deploy_tag"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Could not determine a base revision; continuing"* ]]
    [[ "$output" == *"undetermined"* ]]
    [ ! -f "$HALT_LOG" ]
}

@test "empty base_revision with parent_commit fallback resolves to HEAD^1" {
    commit_file "app.js" "v1"
    commit_file "README.md" "docs only"
    HEAD_SHA="$(git rev-parse HEAD)"
    PARENT_SHA="$(git rev-parse HEAD^1)"

    export PARAM_BASE_REVISION=""
    export PARAM_HEAD_REVISION="$HEAD_SHA"
    export CIRCLE_SHA1="$HEAD_SHA"
    export PARAM_FALLBACK="parent_commit"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Base revision: ${PARENT_SHA}"* ]]
    [[ "$output" == *"HEAD^1 (fallback"* ]]
    [[ "$output" == *"halting this job"* ]]
    grep -q "^step halt$" "$HALT_LOG"
}

@test "empty base_revision with fallback=none never resolves and continues" {
    commit_file "app.js" "v1"
    git tag "2026.01.01-abc1234"
    commit_file "README.md" "docs only"
    HEAD_SHA="$(git rev-parse HEAD)"
    git push --quiet origin --tags

    export PARAM_BASE_REVISION=""
    export PARAM_HEAD_REVISION="$HEAD_SHA"
    export CIRCLE_SHA1="$HEAD_SHA"
    export PARAM_FALLBACK="none"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not resolved"* ]]
    [ ! -f "$HALT_LOG" ]
}

@test "base equal to head continues without diffing" {
    commit_file "app.js" "v1"
    HEAD_SHA="$(git rev-parse HEAD)"

    export PARAM_BASE_REVISION="$HEAD_SHA"
    export PARAM_HEAD_REVISION="$HEAD_SHA"
    export CIRCLE_SHA1="$HEAD_SHA"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Could not determine a base revision; continuing"* ]]
    [ ! -f "$HALT_LOG" ]
}

@test "empty diff between base and head continues (fail-safe)" {
    commit_file "app.js" "v1"
    BASE_SHA="$(git rev-parse HEAD)"
    git commit --quiet --allow-empty -m "empty commit"
    HEAD_SHA="$(git rev-parse HEAD)"

    export PARAM_BASE_REVISION="$BASE_SHA"
    export PARAM_HEAD_REVISION="$HEAD_SHA"
    export CIRCLE_SHA1="$HEAD_SHA"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No changed files between base and head; continuing"* ]]
    [ ! -f "$HALT_LOG" ]
}

@test "head_revision empty falls back to CIRCLE_SHA1" {
    commit_file "README.md" "one"
    BASE_SHA="$(git rev-parse HEAD)"
    commit_file "docs/more.md" "two"
    HEAD_SHA="$(git rev-parse HEAD)"

    export PARAM_BASE_REVISION="$BASE_SHA"
    export PARAM_HEAD_REVISION=""
    export CIRCLE_SHA1="$HEAD_SHA"

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Head revision: ${HEAD_SHA}"* ]]
    [[ "$output" == *"halting this job"* ]]
}

@test "mode=skip_unless_matches skips when no changed file matches pattern" {
    commit_file "src/app.js" "v1"
    BASE_SHA="$(git rev-parse HEAD)"
    commit_file "src/app.js" "v2"
    HEAD_SHA="$(git rev-parse HEAD)"

    export PARAM_BASE_REVISION="$BASE_SHA"
    export PARAM_HEAD_REVISION="$HEAD_SHA"
    export CIRCLE_SHA1="$HEAD_SHA"
    export PARAM_MODE="skip_unless_matches"
    export PARAM_PATTERN='^(\.claude/|\.cursor/|aidlc/)'

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"halting this job"* ]]
    grep -q "^step halt$" "$HALT_LOG"
}

@test "mode=skip_unless_matches continues when a changed file matches pattern" {
    commit_file "src/app.js" "v1"
    BASE_SHA="$(git rev-parse HEAD)"
    commit_file "src/app.js" "v2"
    commit_file ".claude/skills/foo.md" "skill"
    HEAD_SHA="$(git rev-parse HEAD)"

    export PARAM_BASE_REVISION="$BASE_SHA"
    export PARAM_HEAD_REVISION="$HEAD_SHA"
    export CIRCLE_SHA1="$HEAD_SHA"
    export PARAM_MODE="skip_unless_matches"
    export PARAM_PATTERN='^(\.claude/|\.cursor/|aidlc/)'

    run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"do not match the skip condition"* ]]
    [ ! -f "$HALT_LOG" ]
}
