#!/usr/bin/env bats
# Covers src/scripts/deploy_marker.sh, the shared implementation behind the
# with_deploy_marker and deploy_marker_update commands. All CircleCI Deploys
# calls are made through a stubbed CIRCLECI_CLI so no real
# `circleci run release ...` call is ever attempted.

# setup: bats-core per-test hook. Builds an isolated fixture for each test
# case -- a temp $BASH_ENV file, a stubbed CIRCLECI_CLI binary (with a
# calls.log the tests assert against), and a baseline CircleCI job
# environment -- then sources deploy_marker.sh so its functions
# (resolve_component_name, deploy_marker_plan, deploy_marker_update, main)
# are callable directly from each @test block.
#
# Args:
#   None. Invoked automatically by bats-core before every @test in this
#   file; reads $BATS_TEST_FILENAME (provided by bats-core).
# Returns:
#   Always exits 0 (any failure inside would abort the test via bats-core's
#   own error handling, not a script return value).
# Side effects:
#   - Creates a temp file (BASH_ENV) and a temp directory (STUB_DIR)
#     containing the CIRCLECI_CLI stub and CLI_CALL_LOG; neither is
#     cleaned up here (see teardown).
#   - Exports BASH_ENV, CLI_CALL_LOG, CIRCLECI_CLI, CIRCLE_PROJECT_REPONAME,
#     CIRCLE_WORKFLOW_ID and CIRCLE_SHA1 into the test process's environment.
#   - Unsets DEPLOY_COMPONENT_NAME, DEPLOY_NAME, FAILURE_REASON and
#     STUB_EXIT_CODE so ambient sandbox state can't leak into a test.
#   - Sources src/scripts/deploy_marker.sh into the current shell (its
#     `main` guard does not fire because $0 here is the bats-core runner,
#     not the script itself).
setup() {
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/src/scripts/deploy_marker.sh"

  BASH_ENV="$(mktemp)"
  export BASH_ENV

  STUB_DIR="$(mktemp -d)"
  CLI_CALL_LOG="$STUB_DIR/calls.log"
  export CLI_CALL_LOG
  : > "$CLI_CALL_LOG"

  CIRCLECI_CLI="$STUB_DIR/circleci-stub"
  cat > "$CIRCLECI_CLI" <<'EOS'
#!/usr/bin/env bash
if [ "$1" = "env" ] && [ "$2" = "subst" ]; then
  # Mimic `circleci env subst`: expand $VAR / ${VAR} references in the
  # given string using the current environment. This lets tests exercise
  # deploy_marker.sh end to end (it now calls "$CIRCLECI_CLI" env subst
  # for every string parameter -- see deploy_marker.sh's top-of-file
  # comment for why -- instead of a bare `circleci`) without depending on
  # the real CLI being installed.
  eval "printf '%s' \"$3\""
  exit 0
fi
echo "$@" >> "$CLI_CALL_LOG"
exit "${STUB_EXIT_CODE:-0}"
EOS
  chmod +x "$CIRCLECI_CLI"
  export CIRCLECI_CLI

  # Isolate from any ambient CircleCI job env this sandbox happens to run in.
  unset DEPLOY_COMPONENT_NAME DEPLOY_NAME FAILURE_REASON STUB_EXIT_CODE || true
  export CIRCLE_PROJECT_REPONAME="orb-test-repo"
  export CIRCLE_WORKFLOW_ID="wf-123"
  export CIRCLE_SHA1="abcdef0123456789"

  # shellcheck disable=SC1090
  source "$SCRIPT"
}

# teardown: bats-core per-test hook. Removes the fixture setup() created,
# so no temp files or stub binaries accumulate across the suite's 25 tests.
#
# Args:
#   None. Invoked automatically by bats-core after every @test in this
#   file, regardless of whether the test passed or failed.
# Returns:
#   Always exits 0.
# Side effects:
#   Deletes the STUB_DIR directory (CIRCLECI_CLI stub + CLI_CALL_LOG)
#   and the BASH_ENV temp file that setup() created.
teardown() {
  rm -rf "$STUB_DIR" "$BASH_ENV"
}

# --- resolve_component_name precedence -------------------------------------

@test "resolve_component_name prefers an explicit value" {
  run resolve_component_name "explicit-name"
  [ "$status" -eq 0 ]
  [ "$output" = "explicit-name" ]
}

@test "resolve_component_name falls back to DEPLOY_COMPONENT_NAME" {
  export DEPLOY_COMPONENT_NAME="from-env"
  run resolve_component_name ""
  [ "$status" -eq 0 ]
  [ "$output" = "from-env" ]
}

@test "resolve_component_name falls back to CIRCLE_PROJECT_REPONAME" {
  run resolve_component_name ""
  [ "$status" -eq 0 ]
  [ "$output" = "orb-test-repo" ]
}

# --- deploy_marker_plan ------------------------------------------------------

@test "deploy_marker_plan exports DEPLOY_COMPONENT_NAME and DEPLOY_NAME to BASH_ENV" {
  export PARAM_ACTION="plan"
  export PARAM_ENVIRONMENT_NAME="ci-validation"
  export PARAM_COMPONENT_NAME=""
  export PARAM_TARGET_VERSION=""

  run deploy_marker_plan
  [ "$status" -eq 0 ]

  grep -q 'export DEPLOY_COMPONENT_NAME="orb-test-repo"' "$BASH_ENV"
  grep -q 'export DEPLOY_NAME="orb-test-repo-wf-123"' "$BASH_ENV"
}

@test "deploy_marker_plan calls release plan with the resolved name, environment and target version" {
  export PARAM_ACTION="plan"
  export PARAM_ENVIRONMENT_NAME="ci-validation"
  export PARAM_COMPONENT_NAME=""
  export PARAM_TARGET_VERSION=""

  run deploy_marker_plan
  [ "$status" -eq 0 ]

  grep -q '^run release plan orb-test-repo-wf-123 --environment-name=ci-validation --component-name=orb-test-repo --target-version=abcdef0123456789$' "$CLI_CALL_LOG"
}

@test "deploy_marker_plan honors an explicit target_version instead of CIRCLE_SHA1" {
  export PARAM_ACTION="plan"
  export PARAM_ENVIRONMENT_NAME="production"
  export PARAM_COMPONENT_NAME="svc"
  export PARAM_TARGET_VERSION="v2.3.4"

  run deploy_marker_plan
  [ "$status" -eq 0 ]

  grep -q -- '--target-version=v2.3.4' "$CLI_CALL_LOG"
}

@test "deploy_marker_plan expands \$VAR-style component_name values via env subst" {
  export MY_COMPONENT="subst-component"
  export PARAM_ACTION="plan"
  export PARAM_ENVIRONMENT_NAME="production"
  export PARAM_COMPONENT_NAME='$MY_COMPONENT'
  export PARAM_TARGET_VERSION=""

  run deploy_marker_plan
  [ "$status" -eq 0 ]

  grep -q -- '--component-name=subst-component' "$CLI_CALL_LOG"
}

# --- deploy_marker_update ----------------------------------------------------

@test "deploy_marker_update sends RUNNING without a failure reason" {
  export PARAM_ACTION="update"
  export PARAM_COMPONENT_NAME="svc"
  export PARAM_STATUS="RUNNING"

  run deploy_marker_update
  [ "$status" -eq 0 ]

  grep -q '^run release update svc-wf-123 --status=RUNNING$' "$CLI_CALL_LOG"
}

@test "deploy_marker_update sends SUCCESS without a failure reason" {
  export PARAM_ACTION="update"
  export PARAM_COMPONENT_NAME="svc"
  export PARAM_STATUS="SUCCESS"

  run deploy_marker_update
  [ "$status" -eq 0 ]

  grep -q '^run release update svc-wf-123 --status=SUCCESS$' "$CLI_CALL_LOG"
}

@test "deploy_marker_update reuses an already-exported DEPLOY_NAME over recomputing one" {
  export PARAM_ACTION="update"
  export PARAM_COMPONENT_NAME=""
  export PARAM_STATUS="SUCCESS"
  export DEPLOY_NAME="already-exported-name"

  run deploy_marker_update
  [ "$status" -eq 0 ]

  grep -q '^run release update already-exported-name --status=SUCCESS$' "$CLI_CALL_LOG"
}

@test "deploy_marker_update recomputes DEPLOY_NAME when it was never exported (standalone call)" {
  export PARAM_ACTION="update"
  export PARAM_COMPONENT_NAME="svc"
  export PARAM_STATUS="CANCELED"

  run deploy_marker_update
  [ "$status" -eq 0 ]

  grep -q '^run release update svc-wf-123 --status=CANCELED$' "$CLI_CALL_LOG"
}

@test "deploy_marker_update on FAILED defaults the failure reason to 'Deployment failed'" {
  export PARAM_ACTION="update"
  export PARAM_COMPONENT_NAME="svc"
  export PARAM_STATUS="FAILED"

  run deploy_marker_update
  [ "$status" -eq 0 ]

  grep -q -- '--failure-reason=Deployment failed' "$CLI_CALL_LOG"
}

@test "deploy_marker_update on FAILED falls back to \$FAILURE_REASON when failure_reason param is empty" {
  export PARAM_ACTION="update"
  export PARAM_COMPONENT_NAME="svc"
  export PARAM_STATUS="FAILED"
  export FAILURE_REASON="wrangler deploy exited 1"

  run deploy_marker_update
  [ "$status" -eq 0 ]

  grep -q -- '--failure-reason=wrangler deploy exited 1' "$CLI_CALL_LOG"
}

@test "deploy_marker_update on FAILED prefers an explicit failure_reason over \$FAILURE_REASON" {
  export PARAM_ACTION="update"
  export PARAM_COMPONENT_NAME="svc"
  export PARAM_STATUS="FAILED"
  export PARAM_FAILURE_REASON="explicit reason"
  export FAILURE_REASON="should not be used"

  run deploy_marker_update
  [ "$status" -eq 0 ]

  grep -q -- '--failure-reason=explicit reason' "$CLI_CALL_LOG"
  ! grep -q -- '--failure-reason=should not be used' "$CLI_CALL_LOG"
}

@test "deploy_marker_update truncates the failure reason to 500 characters" {
  export PARAM_ACTION="update"
  export PARAM_COMPONENT_NAME="svc"
  export PARAM_STATUS="FAILED"
  PARAM_FAILURE_REASON="$(printf 'x%.0s' $(seq 1 600))"
  export PARAM_FAILURE_REASON

  run deploy_marker_update
  [ "$status" -eq 0 ]

  logged_reason="$(grep -o -- '--failure-reason=.*' "$CLI_CALL_LOG")"
  logged_reason="${logged_reason#--failure-reason=}"
  [ "${#logged_reason}" -eq 500 ]
}

@test "deploy_marker_update omits --failure-reason for non-FAILED statuses" {
  export PARAM_ACTION="update"
  export PARAM_COMPONENT_NAME="svc"
  export PARAM_STATUS="RUNNING"
  export FAILURE_REASON="should not appear"

  run deploy_marker_update
  [ "$status" -eq 0 ]

  ! grep -q -- '--failure-reason' "$CLI_CALL_LOG"
}

@test "deploy_marker_update fails PARAM_STATUS is missing" {
  export PARAM_ACTION="update"
  export PARAM_COMPONENT_NAME="svc"
  unset PARAM_STATUS || true

  run deploy_marker_update
  [ "$status" -ne 0 ]
}

@test "deploy_marker_update tolerates a failing CLI call when tolerate_missing is true" {
  export PARAM_ACTION="update"
  export PARAM_COMPONENT_NAME="svc"
  export PARAM_STATUS="CANCELED"
  export PARAM_TOLERATE_MISSING="true"
  export STUB_EXIT_CODE="1"

  run deploy_marker_update
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "already resolved or not found"
}

@test "deploy_marker_update propagates a failing CLI call when tolerate_missing is false (default)" {
  export PARAM_ACTION="update"
  export PARAM_COMPONENT_NAME="svc"
  export PARAM_STATUS="CANCELED"
  export STUB_EXIT_CODE="1"

  run deploy_marker_update
  [ "$status" -ne 0 ]
}

# --- main() dispatch ---------------------------------------------------------

@test "main dispatches PARAM_ACTION=plan to deploy_marker_plan" {
  export PARAM_ACTION="plan"
  export PARAM_ENVIRONMENT_NAME="production"
  export PARAM_COMPONENT_NAME="svc"
  export PARAM_TARGET_VERSION=""

  run main
  [ "$status" -eq 0 ]
  grep -q '^run release plan svc-wf-123' "$CLI_CALL_LOG"
}

@test "main dispatches PARAM_ACTION=update to deploy_marker_update" {
  export PARAM_ACTION="update"
  export PARAM_COMPONENT_NAME="svc"
  export PARAM_STATUS="RUNNING"

  run main
  [ "$status" -eq 0 ]
  grep -q '^run release update svc-wf-123 --status=RUNNING$' "$CLI_CALL_LOG"
}

@test "main rejects an unknown PARAM_ACTION" {
  export PARAM_ACTION="bogus"

  run main
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi "unknown PARAM_ACTION"
}

# --- /usr/bin/circleci full-path invocation ----------------------------------

@test "the build-agent CLI defaults to the full path /usr/bin/circleci" {
  grep -q 'CIRCLECI_CLI:-/usr/bin/circleci' "$SCRIPT"
}
