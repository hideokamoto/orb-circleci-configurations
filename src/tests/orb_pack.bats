#!/usr/bin/env bats
# Guards the packed orb's shape: the digest-pinned executors are present,
# and the removed scaffold components (greet/hello) never come back.
#
# Skips (rather than fails) when the `circleci` CLI is unavailable, since
# some sandboxes this suite runs in don't have it installed.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

@test "circleci orb pack src declares the pinned executors" {
  if ! command -v circleci >/dev/null 2>&1; then
    skip "circleci CLI not available in this environment"
  fi

  run circleci orb pack "${REPO_ROOT}/src"
  [ "$status" -eq 0 ]

  echo "$output" | grep -q '^executors:'
  echo "$output" | grep -q 'base_pinned'
  echo "$output" | grep -q 'trivy'
}

@test "circleci orb pack src no longer contains the scaffold components" {
  if ! command -v circleci >/dev/null 2>&1; then
    skip "circleci CLI not available in this environment"
  fi

  run circleci orb pack "${REPO_ROOT}/src"
  [ "$status" -eq 0 ]

  ! echo "$output" | grep -q 'greet'
  ! echo "$output" | grep -q 'hello'
}
