#!/usr/bin/env bats
# Unit tests for scripts/cdk_synth.sh: placeholder application and
# existing-env priority for CDK_DEFAULT_ACCOUNT / CDK_DEFAULT_REGION, that
# the configured package manager / synth script are actually invoked, and
# that the full-path CircleCI CLI ($CIRCLECI_CLI) is used instead of a bare
# `circleci` (cimg/base and other minimal executors don't put one on PATH).

# bats-core hook run before every @test in this file.
#
# Arguments:
#   None (bats-core calls this with no arguments).
# Side effects:
#   Points CIRCLECI_CLI at a stub executable (recording invocations to
#   CLI_CALL_LOG and echoing back `env subst`'s argument) before sourcing
#   scripts/cdk_synth.sh, so the script's default-if-unset resolves to the
#   stub instead of the real /usr/bin/circleci; sources the script (with
#   main() suppressed via ORB_TEST_ENV) so its cdk_synth()/main() functions
#   are available to the test; defines the fake_pkg_manager() stub used in
#   place of a real package manager; creates a fresh CALL_LOG temp file; and
#   unsets CDK_DEFAULT_ACCOUNT / CDK_DEFAULT_REGION so each test starts from
#   a clean, placeholder-eligible environment.
# Returns:
#   Implicit 0 (nothing in this hook is expected to fail).
setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/src/scripts/cdk_synth.sh"

  # Stub for the full-path CircleCI CLI. Records "$*" for each call to
  # CLI_CALL_LOG, and for `env subst <value>` echoes <value> back unchanged
  # (adequate for the literal, unexpanded PARAM_* values these tests use).
  CLI_CALL_LOG="$(mktemp)"
  export CLI_CALL_LOG
  CIRCLECI_CLI="$(mktemp)"
  cat >"$CIRCLECI_CLI" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CLI_CALL_LOG"
if [ "$1" = "env" ] && [ "$2" = "subst" ]; then
  printf '%s' "$3"
fi
STUB
  chmod +x "$CIRCLECI_CLI"
  export CIRCLECI_CLI

  # Source for bats-core: main() must not run. CIRCLECI_CLI is already
  # exported above, so the script's top-level
  # CIRCLECI_CLI="${CIRCLECI_CLI:-/usr/bin/circleci}" resolves to the stub
  # rather than the real build-agent CLI.
  ORB_TEST_ENV="bats-core"
  # shellcheck disable=SC1090
  source "$SCRIPT"

  # Stub package manager: records the args it was called with and the
  # CDK_DEFAULT_* env it saw, instead of running a real synth.
  CALL_LOG="$(mktemp)"

  # Test double for a real package manager (pnpm/npm/yarn), passed to
  # cdk_synth() as its $3 (pkg_manager) argument in place of an actual
  # executable.
  #
  # Arguments:
  #   $* - whatever cdk_synth() invokes it with, i.e. "run <synth_script>".
  # Side effects:
  #   Overwrites $CALL_LOG with the received arguments and the
  #   CDK_DEFAULT_ACCOUNT / CDK_DEFAULT_REGION values visible in its
  #   environment at call time, so a test can assert on both without
  #   actually running a synth.
  # Returns:
  #   0 (the redirected block always succeeds).
  fake_pkg_manager() {
    {
      echo "args: $*"
      echo "CDK_DEFAULT_ACCOUNT=${CDK_DEFAULT_ACCOUNT:-}"
      echo "CDK_DEFAULT_REGION=${CDK_DEFAULT_REGION:-}"
    } >"$CALL_LOG"
  }

  unset CDK_DEFAULT_ACCOUNT CDK_DEFAULT_REGION || true
}

# bats-core hook run after every @test in this file.
#
# Arguments:
#   None (bats-core calls this with no arguments).
# Side effects:
#   Removes the $CALL_LOG, $CIRCLECI_CLI, and $CLI_CALL_LOG temp files
#   created in setup().
# Returns:
#   The exit status of `rm -f`, which does not fail on a missing file.
teardown() {
  rm -f "$CALL_LOG" "$CIRCLECI_CLI" "$CLI_CALL_LOG"
}

@test "applies the account/region placeholders when unset" {
  cdk_synth "123456789012" "us-east-1" "fake_pkg_manager" "synth"

  run cat "$CALL_LOG"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "CDK_DEFAULT_ACCOUNT=123456789012"
  echo "$output" | grep -qx "CDK_DEFAULT_REGION=us-east-1"
}

@test "prefers a pre-existing CDK_DEFAULT_ACCOUNT / CDK_DEFAULT_REGION over the placeholders" {
  export CDK_DEFAULT_ACCOUNT="999988887777"
  export CDK_DEFAULT_REGION="ap-northeast-1"

  cdk_synth "123456789012" "us-east-1" "fake_pkg_manager" "synth"

  run cat "$CALL_LOG"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "CDK_DEFAULT_ACCOUNT=999988887777"
  echo "$output" | grep -qx "CDK_DEFAULT_REGION=ap-northeast-1"
}

@test "invokes '<pkg_manager> run <synth_script>'" {
  cdk_synth "123456789012" "us-east-1" "fake_pkg_manager" "synth"

  run cat "$CALL_LOG"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "args: run synth"
}

@test "passes through a custom synth_script name" {
  cdk_synth "123456789012" "us-east-1" "fake_pkg_manager" "cdk:synth"

  run cat "$CALL_LOG"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "args: run cdk:synth"
}

@test "leaves only CDK_DEFAULT_ACCOUNT overridden when just that one is pre-set" {
  export CDK_DEFAULT_ACCOUNT="999988887777"

  cdk_synth "123456789012" "us-east-1" "fake_pkg_manager" "synth"

  run cat "$CALL_LOG"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "CDK_DEFAULT_ACCOUNT=999988887777"
  echo "$output" | grep -qx "CDK_DEFAULT_REGION=us-east-1"
}

@test "main() resolves PARAM_* through the full-path CircleCI CLI, not a bare 'circleci', and delegates to cdk_synth" {
  export PARAM_ACCOUNT_PLACEHOLDER="123456789012"
  export PARAM_REGION_PLACEHOLDER="us-east-1"
  export PARAM_SYNTH_SCRIPT="synth"
  export PARAM_PKG_MANAGER="fake_pkg_manager"

  main

  run cat "$CALL_LOG"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "CDK_DEFAULT_ACCOUNT=123456789012"
  echo "$output" | grep -qx "CDK_DEFAULT_REGION=us-east-1"
  echo "$output" | grep -qx "args: run synth"

  # Confirms main() actually went through $CIRCLECI_CLI (the stub) rather
  # than a bare `circleci` lookup on PATH.
  run cat "$CLI_CALL_LOG"
  [ "$status" -eq 0 ]
  [ -s "$CLI_CALL_LOG" ]
  echo "$output" | grep -q "^env subst "
}
