#!/usr/bin/env bats
# Unit tests for src/scripts/send_sbom_to_port.sh. External commands
# (circleci, curl, apk) are stubbed via a PATH directory so no real HTTP
# request or package install ever happens.

# setup
#
# Role:
#   bats-core hook run automatically before every @test in this file.
#   Builds an isolated PATH directory holding stub `circleci`, `curl`,
#   and `apk` executables so the script under test never performs a
#   real HTTP request, package install, or depends on the real
#   CircleCI CLI, and seeds the PARAM_* environment variables the
#   command normally receives from orb parameters.
#
# Arguments:
#   None (bats-core invokes this with no arguments before each test).
#
# Returns / side effects:
#   Creates two temporary directories on disk (STUB_DIR, WORK_DIR) and
#   sets REPO_ROOT, SCRIPT, CURL_CALLS, APK_CALLS as test-local
#   variables; exports PARAM_WEBHOOK_URL_ENV, PARAM_SBOM_FILE,
#   PARAM_RETRIES, and PARAM_MAX_TIME for the test that follows.
setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT="${REPO_ROOT}/src/scripts/send_sbom_to_port.sh"

    STUB_DIR="$(mktemp -d)"
    WORK_DIR="$(mktemp -d)"
    CURL_CALLS="${STUB_DIR}/curl-calls.log"
    APK_CALLS="${STUB_DIR}/apk-calls.log"

    # Fake `circleci env subst`: expands $VAR / ${VAR} references in its
    # argument the same way the real CLI subcommand does, without needing
    # the actual circleci binary.
    cat >"${STUB_DIR}/circleci" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "env" ] && [ "$2" = "subst" ]; then
    shift 2
    eval "printf '%s' \"$1\""
    exit 0
fi
echo "unexpected circleci invocation: $*" >&2
exit 1
EOF
    chmod +x "${STUB_DIR}/circleci"

    # Fake curl: records every argument it was called with, then succeeds.
    cat >"${STUB_DIR}/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${CURL_CALLS}"
exit 0
EOF
    chmod +x "${STUB_DIR}/curl"

    # Fake apk: records the call, then installs a stub "curl" into PATH so
    # the script's subsequent curl invocation succeeds.
    cat >"${STUB_DIR}/apk" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${APK_CALLS}"
cat > "${STUB_DIR}/curl" <<'CURLEOF'
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${CURL_CALLS}"
exit 0
CURLEOF
chmod +x "${STUB_DIR}/curl"
exit 0
EOF
    chmod +x "${STUB_DIR}/apk"

    export PARAM_WEBHOOK_URL_ENV="TEST_WEBHOOK_URL"
    export PARAM_SBOM_FILE="sbom.cdx.json"
    export PARAM_RETRIES="3"
    export PARAM_MAX_TIME="60"
}

# teardown
#
# Role:
#   bats-core hook run automatically after every @test in this file.
#   Cleans up the temporary directories and environment variables that
#   setup() (and the tests themselves) created, so no state leaks into
#   the next test.
#
# Arguments:
#   None (bats-core invokes this with no arguments after each test).
#
# Returns / side effects:
#   Removes STUB_DIR and WORK_DIR from disk; unsets TEST_WEBHOOK_URL
#   and CUSTOM_SBOM_PATH from the environment.
teardown() {
    rm -rf "${STUB_DIR}" "${WORK_DIR}"
    unset TEST_WEBHOOK_URL CUSTOM_SBOM_PATH
}

@test "exits 1 when the webhook url env var is unset" {
    unset TEST_WEBHOOK_URL

    PATH="${STUB_DIR}:${PATH}" run "${SCRIPT}"

    [ "$status" -eq 1 ]
    [[ "$output" == *"TEST_WEBHOOK_URL is not set"* ]]
    [ ! -f "${CURL_CALLS}" ]
}

@test "exits 1 when the webhook url env var is set but empty" {
    export TEST_WEBHOOK_URL=""

    PATH="${STUB_DIR}:${PATH}" run "${SCRIPT}"

    [ "$status" -eq 1 ]
    [[ "$output" == *"TEST_WEBHOOK_URL is not set"* ]]
    [ ! -f "${CURL_CALLS}" ]
}

@test "posts the sbom file to the webhook url with the configured retry/timeout flags" {
    export TEST_WEBHOOK_URL="https://ingest.example.invalid/webhook/abc"
    export PARAM_RETRIES="5"
    export PARAM_MAX_TIME="120"

    PATH="${STUB_DIR}:${PATH}" run "${SCRIPT}"

    [ "$status" -eq 0 ]
    [ -f "${CURL_CALLS}" ]

    run cat "${CURL_CALLS}"
    [[ "$output" == *"--fail-with-body"* ]]
    [[ "$output" == *"--connect-timeout"*"10"* ]]
    [[ "$output" == *"--max-time"*"120"* ]]
    [[ "$output" == *"--retry"*"5"* ]]
    [[ "$output" == *"-X"*"POST"* ]]
    [[ "$output" == *"Content-Type: application/json"* ]]
    [[ "$output" == *"--data-binary"*"@sbom.cdx.json"* ]]
    [[ "$output" == *"https://ingest.example.invalid/webhook/abc"* ]]
}

@test "resolves \$VAR references in sbom_file via circleci env subst" {
    export TEST_WEBHOOK_URL="https://ingest.example.invalid/webhook/abc"
    export CUSTOM_SBOM_PATH="${WORK_DIR}/custom-sbom.cdx.json"
    export PARAM_SBOM_FILE='$CUSTOM_SBOM_PATH'

    PATH="${STUB_DIR}:${PATH}" run "${SCRIPT}"

    [ "$status" -eq 0 ]
    run cat "${CURL_CALLS}"
    [[ "$output" == *"--data-binary"*"@${WORK_DIR}/custom-sbom.cdx.json"* ]]
}

@test "installs curl via apk when curl is not already on PATH" {
    export TEST_WEBHOOK_URL="https://ingest.example.invalid/webhook/abc"
    rm -f "${STUB_DIR}/curl"

    # Build a PATH with no real curl on it at all (the sandbox's own PATH
    # has one), so "command -v curl" genuinely fails until the apk stub
    # below creates one. Only the interpreter and our stubs are exposed.
    NO_CURL_BIN="$(mktemp -d)"
    for bin in bash env chmod cat; do
        ln -s "$(command -v "${bin}")" "${NO_CURL_BIN}/${bin}"
    done

    PATH="${STUB_DIR}:${NO_CURL_BIN}" run "${SCRIPT}"

    [ "$status" -eq 0 ]
    [ -f "${APK_CALLS}" ]
    run cat "${APK_CALLS}"
    [[ "$output" == *"add"* ]]
    [[ "$output" == *"--no-cache"* ]]
    [[ "$output" == *"curl"* ]]
    [ -f "${CURL_CALLS}" ]

    rm -rf "${NO_CURL_BIN}"
}

@test "skips apk install when curl is already on PATH" {
    export TEST_WEBHOOK_URL="https://ingest.example.invalid/webhook/abc"

    PATH="${STUB_DIR}:${PATH}" run "${SCRIPT}"

    [ "$status" -eq 0 ]
    [ ! -f "${APK_CALLS}" ]
}
