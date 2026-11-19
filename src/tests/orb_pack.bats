#!/usr/bin/env bats
# Guards the packed orb's shape: the digest-pinned executors are present,
# and the removed scaffold components (greet/hello) never come back.
#
# Skips (rather than fails) when the `circleci` CLI is unavailable, since
# some sandboxes this suite runs in don't have it installed.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # The dev CLI forks a `receive-telemetry` child that holds `run`'s captured
  # pipe open and hangs the test on networks that can't reach the telemetry
  # endpoint; opt out so the call returns with the pack output.
  export CIRCLECI_CLI_TELEMETRY_OPTOUT=true
}

# The dev `circleci` CLI that can pack orbs, or nothing. Generic executor
# images (e.g. cimg/base, which circleci/bats runs in) inject a build-agent
# `circleci` binary that does not implement `orb pack`; treat that the same
# as the CLI being absent.
dev_cli_orb_pack() {
  command -v circleci >/dev/null 2>&1 && circleci orb --help >/dev/null 2>&1
}

@test "circleci orb pack src declares the pinned executors" {
  if ! dev_cli_orb_pack; then
    skip "circleci dev CLI not available in this environment"
  fi

  run circleci orb pack "${REPO_ROOT}/src"
  if [ "$status" -ne 0 ]; then echo "$output" >&2; fi
  [ "$status" -eq 0 ]

  echo "$output" | grep -q '^executors:'
  echo "$output" | grep -q 'base_pinned'
  echo "$output" | grep -q 'trivy'
}

@test "circleci orb pack src no longer contains the scaffold components" {
  if ! dev_cli_orb_pack; then
    skip "circleci dev CLI not available in this environment"
  fi

  run circleci orb pack "${REPO_ROOT}/src"
  if [ "$status" -ne 0 ]; then echo "$output" >&2; fi
  [ "$status" -eq 0 ]

  ! echo "$output" | grep -q 'greet'
  ! echo "$output" | grep -q 'hello'
}
