#!/usr/bin/env bats
# Unit tests for src/scripts/npm_publish_oidc.sh.
#
# The script talks to two external commands:
#   - the CircleCI build-agent CLI, invoked by full path (CIRCLECI_CLI_PATH
#     overrides the default /usr/bin/circleci so it can point at a stub here)
#   - `circleci env subst`, used to interpolate parameter values; the real
#     `circleci` CLI on PATH is used for this (it is installed in this
#     environment and requires no network access or auth for `env subst`)
#
# `publish_command` is exercised via a marker file rather than relying on
# stdout parsing, so assertions about "was publish invoked" and "did the
# token leak" stay independent of each other.

# bats-core hook run before every @test in this file.
#
# Arguments: none. Side effects: creates a per-test temp dir holding a stub
# build-agent CLI (its recorded argv and emitted token are controlled per
# test via STUB_CLI_ARGS_FILE / STUB_OIDC_TOKEN), points CIRCLECI_CLI_PATH
# at that stub, and pre-seeds NODE_AUTH_TOKEN / NPM_TOKEN so tests can assert
# the script clears them.
setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/src/scripts/npm_publish_oidc.sh"

  TEST_TMPDIR="$(mktemp -d)"
  MARKER_FILE="${TEST_TMPDIR}/publish-called"

  # A fake build-agent CLI. Its behavior (token value / exit code) is
  # controlled per-test via env vars read by the stub itself, and the real
  # script is told to use it via CIRCLECI_CLI_PATH instead of /usr/bin/circleci.
  STUB_CLI="${TEST_TMPDIR}/circleci-stub"
  cat > "${STUB_CLI}" <<'STUB'
#!/usr/bin/env bash
# Records the full argv it was called with, then prints STUB_OIDC_TOKEN
# (possibly empty) to emulate `circleci run oidc get --claims '...'`.
echo "$*" > "${STUB_CLI_ARGS_FILE}"
printf '%s' "${STUB_OIDC_TOKEN-}"
STUB
  chmod +x "${STUB_CLI}"

  export CIRCLECI_CLI_PATH="${STUB_CLI}"
  export STUB_CLI_ARGS_FILE="${TEST_TMPDIR}/cli-args"

  # Make sure legacy token vars pre-exist so we can assert the script clears
  # them before the publish_command runs (mirrors a repo mid-migration off
  # static npm tokens).
  export NODE_AUTH_TOKEN="stale-node-auth-token"
  export NPM_TOKEN="stale-npm-token"

  unset NPM_ID_TOKEN
}

# bats-core hook run after every @test in this file.
#
# Arguments: none. Side effects: removes the per-test temp dir created by
# setup() and unsets every env var setup()/the tests export, so state never
# leaks between tests.
teardown() {
  rm -rf "${TEST_TMPDIR}"
  unset CIRCLECI_CLI_PATH STUB_CLI_ARGS_FILE STUB_OIDC_TOKEN
  unset NODE_AUTH_TOKEN NPM_TOKEN PARAM_AUDIENCE PARAM_PUBLISH_COMMAND
}

@test "publishes and exports NPM_ID_TOKEN to publish_command without leaking it to the log" {
  export STUB_OIDC_TOKEN="s3cr3t-oidc-token-value"
  export PARAM_AUDIENCE="npm:registry.npmjs.org"
  # Assert the token actually reached the publish command's environment
  # (functional correctness) via a marker file, rather than by echoing the
  # token itself (which is exactly what must not happen).
  export PARAM_PUBLISH_COMMAND="[ \"\${NPM_ID_TOKEN}\" = \"${STUB_OIDC_TOKEN}\" ] && touch '${MARKER_FILE}'"

  run bash "${SCRIPT}"

  [ "$status" -eq 0 ]
  [ -f "${MARKER_FILE}" ]
  # The raw token value must never appear in stdout/stderr.
  [[ "$output" != *"${STUB_OIDC_TOKEN}"* ]]
}

@test "fails fast with exit 1 and does not run publish_command when the OIDC token is empty" {
  export STUB_OIDC_TOKEN=""
  export PARAM_AUDIENCE="npm:registry.npmjs.org"
  export PARAM_PUBLISH_COMMAND="touch '${MARKER_FILE}'"

  run bash "${SCRIPT}"

  [ "$status" -eq 1 ]
  [ ! -f "${MARKER_FILE}" ]
  [[ "$output" == *"Failed to acquire OIDC token"* ]]
  [[ "$output" == *"NPM_ID_TOKEN is empty"* ]]
}

@test "clears NODE_AUTH_TOKEN and NPM_TOKEN before invoking publish_command" {
  export STUB_OIDC_TOKEN="token-for-unset-check"
  export PARAM_AUDIENCE="npm:registry.npmjs.org"
  export PARAM_PUBLISH_COMMAND="[ -z \"\${NODE_AUTH_TOKEN-}\" ] && [ -z \"\${NPM_TOKEN-}\" ] && touch '${MARKER_FILE}'"

  run bash "${SCRIPT}"

  [ "$status" -eq 0 ]
  [ -f "${MARKER_FILE}" ]
}

@test "publish_command is fully overridable (e.g. Changesets monorepo publish)" {
  export STUB_OIDC_TOKEN="token-for-command-override"
  export PARAM_AUDIENCE="npm:registry.npmjs.org"
  export PARAM_PUBLISH_COMMAND="echo changeset-publish-ran > '${MARKER_FILE}'"

  run bash "${SCRIPT}"

  [ "$status" -eq 0 ]
  [ -f "${MARKER_FILE}" ]
  [ "$(cat "${MARKER_FILE}")" = "changeset-publish-ran" ]
}

@test "requests the OIDC token with the audience parameter as the aud claim" {
  export STUB_OIDC_TOKEN="token-for-audience-check"
  export PARAM_AUDIENCE="npm:custom-registry.example.com"
  export PARAM_PUBLISH_COMMAND="true"

  run bash "${SCRIPT}"

  [ "$status" -eq 0 ]
  run cat "${STUB_CLI_ARGS_FILE}"
  [[ "$output" == *'run oidc get --claims {"aud": "npm:custom-registry.example.com"}'* ]]
}
