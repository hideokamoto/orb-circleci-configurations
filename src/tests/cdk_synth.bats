#!/usr/bin/env bats
# Unit tests for scripts/cdk_synth.sh: placeholder application and
# existing-env priority for CDK_DEFAULT_ACCOUNT / CDK_DEFAULT_REGION, plus
# that the configured package manager / synth script are actually invoked.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/src/scripts/cdk_synth.sh"

  # Source for bats-core: main() must not run.
  ORB_TEST_ENV="bats-core"
  # shellcheck disable=SC1090
  source "$SCRIPT"

  # Stub package manager: records the args it was called with and the
  # CDK_DEFAULT_* env it saw, instead of running a real synth.
  CALL_LOG="$(mktemp)"

  fake_pkg_manager() {
    {
      echo "args: $*"
      echo "CDK_DEFAULT_ACCOUNT=${CDK_DEFAULT_ACCOUNT:-}"
      echo "CDK_DEFAULT_REGION=${CDK_DEFAULT_REGION:-}"
    } >"$CALL_LOG"
  }

  unset CDK_DEFAULT_ACCOUNT CDK_DEFAULT_REGION || true
}

teardown() {
  rm -f "$CALL_LOG"
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
