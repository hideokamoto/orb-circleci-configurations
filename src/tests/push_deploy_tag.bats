#!/usr/bin/env bats
# Unit tests for scripts/push_deploy_tag.sh: pushes a date-stamped release
# tag ("<date_format>-<short-sha>") to the "origin" remote, and skips
# without erroring when a tag with that exact name already exists there.
#
# Exercises the sourced push_deploy_tag() function against a throwaway
# local git remote (a "git init --bare" repo under a temp dir) so the
# tests never touch a real upstream or require network access. The
# `circleci` CLI is likewise stubbed via CIRCLECI_CLI (see setup()) rather
# than depending on a real install.

# setup
#
# bats-core hook run automatically before each @test in this file. Builds
# a throwaway local bare git remote plus a working clone seeded with one
# empty commit, exports CIRCLE_SHA1 to that commit's SHA, points
# CIRCLECI_CLI at a local stub (cimg/base only guarantees `circleci` at
# /usr/bin/circleci, which this sandbox does not have, and the stub also
# avoids depending on the real CLI's behavior), and sources
# push_deploy_tag.sh so its push_deploy_tag() function is directly
# callable from the test body (sourcing, rather than executing, keeps
# main() from auto-running, per the script's "Will not run if sourced for
# bats-core tests" guard).
# Arguments:
#   None (invoked by bats-core with no arguments before every test).
# Outputs:
#   None of its own (git/mktemp output is not suppressed but is
#   incidental).
# Returns:
#   0 on success; a non-zero status from any of the git/mktemp setup
#   commands aborts the test as errored (bats-core does not run `set -e`
#   over hook bodies, so a failing command here is only caught if it is
#   the hook's final command or explicitly checked).
# Side effects:
#   Creates a temp directory tree (TEST_DIR containing REMOTE_DIR,
#   WORK_DIR, and the CIRCLECI_CLI stub script), changes the shell's
#   working directory to WORK_DIR, and exports CIRCLE_SHA1 and
#   CIRCLECI_CLI for the duration of the test.
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

  # Stub for the `circleci` CLI: push_deploy_tag.sh only calls
  # `"$CIRCLECI_CLI" env subst <string>`, so the stub only needs to
  # support that, echoing the string back verbatim (matching real `env
  # subst` behavior for strings with no "${...}" placeholders, which is
  # all these tests pass). Stubbing (instead of relying on a real
  # `circleci` on PATH or at /usr/bin/circleci) keeps the suite runnable
  # in environments that have neither.
  CIRCLECI_CLI="${TEST_DIR}/circleci-stub"
  cat > "${CIRCLECI_CLI}" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "env" ] && [ "$2" = "subst" ]; then
  printf '%s' "$3"
  exit 0
fi
echo "circleci-stub: unsupported invocation: $*" >&2
exit 1
STUB
  chmod +x "${CIRCLECI_CLI}"
  export CIRCLECI_CLI

  # Sourcing (rather than executing) the script keeps main() from running,
  # per the "Will not run if sourced for bats-core tests" guard at its tail,
  # and gives the test direct access to the push_deploy_tag() function.
  # CIRCLECI_CLI must already be exported above so the script's top-level
  # `CIRCLECI_CLI="${CIRCLECI_CLI:-/usr/bin/circleci}"` picks up the stub
  # instead of falling back to its default.
  source "${SCRIPT}"
}

# teardown
#
# bats-core hook run automatically after each @test in this file,
# regardless of whether the test passed or failed. Returns to a stable
# working directory and removes the temp directory tree created by
# setup(), so throwaway git remotes/clones never leak between tests or
# outlive the run.
# Arguments:
#   None (invoked by bats-core with no arguments after every test).
# Outputs:
#   None.
# Returns:
#   0.
# Side effects:
#   Changes the shell's working directory to "/" and recursively deletes
#   TEST_DIR (and everything under it, including REMOTE_DIR and
#   WORK_DIR).
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
