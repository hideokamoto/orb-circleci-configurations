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
#   WORK_DIR, a throwaway HOME, and the CIRCLECI_CLI stub script), changes
#   the shell's working directory to WORK_DIR, and exports CIRCLE_SHA1,
#   CIRCLECI_CLI, HOME, and GIT_CONFIG_NOSYSTEM for the duration of the
#   test (the latter two isolate git from this machine's real
#   ~/.gitconfig).
setup() {
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/src/scripts/push_deploy_tag.sh"

  TEST_DIR="$(mktemp -d)"
  REMOTE_DIR="${TEST_DIR}/remote.git"
  WORK_DIR="${TEST_DIR}/work"

  # Isolate git from this machine's real ~/.gitconfig for the whole test
  # (a throwaway HOME, plus GIT_CONFIG_NOSYSTEM): the ambient config in
  # this environment sets push.negotiate=true and commit.gpgsign=true,
  # neither of which this disposable local-remote fixture needs, and the
  # former intermittently prints a spurious "push negotiation failed"
  # warning that has no bearing on these tests.
  export HOME="${TEST_DIR}/home"
  mkdir -p "${HOME}"
  export GIT_CONFIG_NOSYSTEM=1

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

@test "rejects a sha_length of 0" {
  export PARAM_DATE_FORMAT="%Y.%m.%d"
  export PARAM_SHA_LENGTH="0"

  run push_deploy_tag
  [ "$status" -eq 1 ]
  [[ "$output" == *"sha_length must be an integer between 1 and"* ]]

  # no tag was created or pushed
  run git tag -l
  [ -z "$output" ]
  run git ls-remote --tags origin
  [ -z "$output" ]
}

@test "rejects a negative sha_length" {
  export PARAM_DATE_FORMAT="%Y.%m.%d"
  export PARAM_SHA_LENGTH="-1"

  run push_deploy_tag
  [ "$status" -eq 1 ]
  [[ "$output" == *"sha_length must be an integer between 1 and"* ]]

  run git tag -l
  [ -z "$output" ]
  run git ls-remote --tags origin
  [ -z "$output" ]
}

@test "recovers when a concurrent job already pushed the same tag for the same commit" {
  export PARAM_DATE_FORMAT="%Y.%m.%d"
  export PARAM_SHA_LENGTH="7"

  expected_tag="$(date -u +%Y.%m.%d)-${CIRCLE_SHA1:0:7}"

  # Simulate a second job racing this one against the same commit: it
  # clones the same origin and pushes the identical tag right as this
  # test's push_deploy_tag() has already passed its own pre-push
  # existence check (the race window CodeRabbit flagged) and is about to
  # push. Note this does NOT rely on git's local push rejecting a
  # same-name/same-target lightweight tag — a live re-negotiation with
  # the remote (which every `git push` performs) sees the two as already
  # equal and reports "Everything up-to-date" rather than a rejection, so
  # that natural path can't deterministically reproduce a real CI
  # ref-update race in a sequential test. Instead the shadowed `git`
  # below forces this job's own `git push origin <tag>` call to return
  # non-zero regardless, standing in for the compare-and-swap rejection a
  # real concurrent push can hit — so what's under test is solely
  # push_deploy_tag()'s recovery path: does it correctly treat "push
  # failed, but the tag is now on the remote pointing at CIRCLE_SHA1" as
  # success?
  OTHER_CLONE="${TEST_DIR}/other-work"
  # --branch main: the bare remote's own default-branch symref was never
  # updated to "main" (only the "main" ref itself was created, by
  # setup()'s `git push origin HEAD:main`), so a plain clone would follow
  # that stale default and check out nothing.
  git clone --branch main --quiet "${REMOTE_DIR}" "${OTHER_CLONE}"

  git() {
    if [ "$1" = "push" ] && [ "$2" = "origin" ] && [ "$3" = "${expected_tag}" ]; then
      ( cd "${OTHER_CLONE}" && command git tag "${expected_tag}" && command git push --quiet origin "${expected_tag}" ) >/dev/null
      return 1
    fi
    command git "$@"
  }

  run push_deploy_tag
  unset -f git
  [ "$status" -eq 0 ]
  [[ "$output" == *"created concurrently"* ]]

  # the remote ends up with exactly one such tag, pointing at CIRCLE_SHA1
  run git ls-remote --tags origin "refs/tags/${expected_tag}"
  [ "$status" -eq 0 ]
  [[ "$output" == "${CIRCLE_SHA1}"$'\t'"refs/tags/${expected_tag}" ]]
}

@test "still fails when git push is rejected and the tag is not found on recheck" {
  export PARAM_DATE_FORMAT="%Y.%m.%d"
  export PARAM_SHA_LENGTH="7"

  expected_tag="$(date -u +%Y.%m.%d)-${CIRCLE_SHA1:0:7}"

  # Force every `git push` to fail, and never let the tag actually land on
  # the remote, so the post-push recheck must find nothing and this must
  # still fail (not be swallowed as a false "concurrent" success).
  git() {
    if [ "$1" = "push" ]; then
      return 17
    fi
    command git "$@"
  }

  run push_deploy_tag
  unset -f git
  [ "$status" -eq 17 ]
  [[ "$output" != *"created concurrently"* ]]

  run git ls-remote --tags origin
  [ -z "$output" ]
}
