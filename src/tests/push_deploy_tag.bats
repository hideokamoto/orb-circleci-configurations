#!/usr/bin/env bats
# Unit tests for scripts/push_deploy_tag.sh: pushes a date-stamped release
# tag ("<date_format>-<short-sha>") to the "origin" remote, and skips
# without erroring when a tag with that exact name already exists there.
#
# Exercises the sourced push_deploy_tag() function against a throwaway
# local git remote (a "git init --bare" repo under a temp dir) so the
# tests never touch a real upstream or require network access.

setup() {
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/src/scripts/push_deploy_tag.sh"

  TEST_DIR="$(mktemp -d)"
  REMOTE_DIR="${TEST_DIR}/remote.git"
  WORK_DIR="${TEST_DIR}/work"

  git init --quiet --bare "${REMOTE_DIR}"
  git clone --quiet "${REMOTE_DIR}" "${WORK_DIR}"

  cd "${WORK_DIR}"
  git config user.email "orb-test@example.com"
  git config user.name "Orb Test"
  git commit --quiet --allow-empty -m "seed commit"
  git push --quiet origin HEAD:main

  CIRCLE_SHA1="$(git rev-parse HEAD)"
  export CIRCLE_SHA1

  # Sourcing (rather than executing) the script keeps main() from running,
  # per the "Will not run if sourced for bats-core tests" guard at its tail,
  # and gives the test direct access to the push_deploy_tag() function.
  source "${SCRIPT}"
}

teardown() {
  cd /
  rm -rf "${TEST_DIR}"
}

@test "creates and pushes a tag when none exists yet on the remote" {
  export PARAM_DATE_FORMAT="%Y.%m.%d"
  export PARAM_SHA_LENGTH="7"

  run push_deploy_tag
  [ "$status" -eq 0 ]

  expected_tag="$(date -u +%Y.%m.%d)-${CIRCLE_SHA1:0:7}"
  run git ls-remote --tags origin "${expected_tag}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${expected_tag}"* ]]

  # the local tag was also created
  run git tag -l "${expected_tag}"
  [ "$output" = "${expected_tag}" ]
}

@test "skips without error when the tag already exists on the remote" {
  export PARAM_DATE_FORMAT="%Y.%m.%d"
  export PARAM_SHA_LENGTH="7"

  expected_tag="$(date -u +%Y.%m.%d)-${CIRCLE_SHA1:0:7}"
  git tag "${expected_tag}"
  git push --quiet origin "${expected_tag}"
  git tag -d "${expected_tag}" >/dev/null

  run push_deploy_tag
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists on remote, skipping"* ]]

  # the skip path must not have re-created the tag locally or pushed again
  run git tag -l "${expected_tag}"
  [ -z "$output" ]

  run git ls-remote --tags origin
  count="$(printf '%s\n' "$output" | grep -c "${expected_tag}" || true)"
  [ "$count" -eq 1 ]
}

@test "honors a custom date_format and sha_length" {
  export PARAM_DATE_FORMAT="%Y-%m-%d"
  export PARAM_SHA_LENGTH="10"

  run push_deploy_tag
  [ "$status" -eq 0 ]

  expected_tag="$(date -u +%Y-%m-%d)-${CIRCLE_SHA1:0:10}"
  run git ls-remote --tags origin "${expected_tag}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${expected_tag}"* ]]
}

@test "running twice in a row is idempotent (second run hits the skip path)" {
  export PARAM_DATE_FORMAT="%Y.%m.%d"
  export PARAM_SHA_LENGTH="7"

  run push_deploy_tag
  [ "$status" -eq 0 ]

  run push_deploy_tag
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists on remote, skipping"* ]]

  expected_tag="$(date -u +%Y.%m.%d)-${CIRCLE_SHA1:0:7}"
  run git ls-remote --tags origin
  count="$(printf '%s\n' "$output" | grep -c "${expected_tag}" || true)"
  [ "$count" -eq 1 ]
}
