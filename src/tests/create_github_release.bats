#!/usr/bin/env bats
# Unit tests for src/scripts/create_github_release.sh.
#
# `gh` and `circleci-agent` are stubbed via a PATH-prepended fixture
# directory, so the tests never touch a real GitHub repo and never halt
# the actual bats process. The `gh` stub records every "release create"
# invocation (one line per call, space-joined args) to CALL_LOG, and exits
# with GH_CREATE_EXIT (default 0). "release view" is called up to twice per
# script run (the idempotency pre-check, and gh_release_create_race_safe's
# re-check after a failed create) and its exit status is tracked per call
# via GH_VIEW_CALL_COUNT_FILE: the 1st invocation exits GH_VIEW_EXIT
# (default 1 = not found), any later invocation exits GH_VIEW_EXIT_2
# (defaults to GH_VIEW_EXIT, so tests that never trigger a 2nd view call
# don't need to set it). The `circleci-agent` stub records "step halt"
# calls to HALT_LOG so a halt can be asserted without actually stopping
# the step.
#
# The script is run as a real subprocess (`bash "${SCRIPT}"`) rather than
# sourced, so its "Will not run if sourced for bats-core tests" guard does
# not apply here and main() executes exactly as it would in a real job.

# bats-core hook run before every @test in this file.
# Args: none.
# Returns: 0 (any non-zero status here would abort the test as an error).
# Side effects: resolves SCRIPT to the path under test; creates a fresh
#   TEST_DIR with a STUB_BIN directory containing `gh` and `circleci-agent`
#   stubs (prepended onto PATH) plus empty CALL_LOG / HALT_LOG files for the
#   stubs to append to and a GH_VIEW_CALL_COUNT_FILE path (left uncreated;
#   the gh stub creates it lazily on its first "release view" call);
#   exports the PARAM_* env vars the script reads by default; and unsets
#   RELEASE_TAG / PREV_RELEASE_TAG / RELEASE_NOTES_SOURCE /
#   RELEASE_NOTES_FILE so each test starts from a clean, known environment.
setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/src/scripts/create_github_release.sh"

  TEST_DIR="$(mktemp -d)"
  STUB_BIN="${TEST_DIR}/bin"
  mkdir -p "${STUB_BIN}"
  CALL_LOG="${TEST_DIR}/gh-calls.log"
  HALT_LOG="${TEST_DIR}/halt-calls.log"
  GH_VIEW_CALL_COUNT_FILE="${TEST_DIR}/gh-view-call-count"
  : > "${CALL_LOG}"
  : > "${HALT_LOG}"

  # gh stub: "release view <tag>" tracks its own call count (across the
  # whole script run) in GH_VIEW_CALL_COUNT_FILE so a test can give the
  # idempotency pre-check and gh_release_create_race_safe's post-create
  # re-check different answers -- the 1st call exits GH_VIEW_EXIT (default
  # 1 = not found), any later call exits GH_VIEW_EXIT_2 (defaults to
  # GH_VIEW_EXIT). "release create ..." logs its full argv and exits
  # GH_CREATE_EXIT (default 0 = success; set nonzero to simulate a
  # "release already exists" create failure).
  cat > "${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "release" ] && [ "$2" = "view" ]; then
  n=0
  [ -f "${GH_VIEW_CALL_COUNT_FILE}" ] && n="$(cat "${GH_VIEW_CALL_COUNT_FILE}")"
  n=$((n + 1))
  echo "${n}" > "${GH_VIEW_CALL_COUNT_FILE}"
  if [ "${n}" -eq 1 ]; then
    exit "${GH_VIEW_EXIT:-1}"
  fi
  exit "${GH_VIEW_EXIT_2:-${GH_VIEW_EXIT:-1}}"
fi
if [ "$1" = "release" ] && [ "$2" = "create" ]; then
  echo "$*" >> "${CALL_LOG}"
  exit "${GH_CREATE_EXIT:-0}"
fi
echo "unexpected gh invocation: $*" >&2
exit 1
EOF
  chmod +x "${STUB_BIN}/gh"

  # circleci-agent stub: records "step halt" so the halt path can be
  # asserted without terminating the bats process.
  cat > "${STUB_BIN}/circleci-agent" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${HALT_LOG}"
exit 0
EOF
  chmod +x "${STUB_BIN}/circleci-agent"

  export CALL_LOG HALT_LOG GH_VIEW_CALL_COUNT_FILE
  export PATH="${STUB_BIN}:${PATH}"

  export PARAM_TAG_ENV="RELEASE_TAG"
  export PARAM_PREV_TAG_ENV="PREV_RELEASE_TAG"
  export PARAM_NOTES_SOURCE_ENV="RELEASE_NOTES_SOURCE"
  export PARAM_NOTES_FILE_ENV="RELEASE_NOTES_FILE"
  export PARAM_SKIP_IF_EXISTS="true"

  unset RELEASE_TAG PREV_RELEASE_TAG RELEASE_NOTES_SOURCE RELEASE_NOTES_FILE || true
}

# bats-core hook run after every @test in this file.
# Args: none.
# Returns: 0.
# Side effects: recursively removes TEST_DIR (the stub bin, CALL_LOG, and
#   HALT_LOG created in setup), leaving no fixture state behind between
#   tests or after the run.
teardown() {
  rm -rf "${TEST_DIR}"
}

@test "halts without creating a release when one already exists for the tag" {
  export RELEASE_TAG="2026.09.03-abc1234"
  export GH_VIEW_EXIT=0

  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Release 2026.09.03-abc1234 already exists; skipping."* ]]

  grep -q "step halt" "${HALT_LOG}"
  [ ! -s "${CALL_LOG}" ]
}

@test "branch 1: uses --notes-file when the notes source is deploy-diff-summaries" {
  export RELEASE_TAG="2026.09.03-abc1234"
  export RELEASE_NOTES_SOURCE="deploy-diff-summaries"
  export RELEASE_NOTES_FILE="/tmp/release-notes.md"
  export GH_VIEW_EXIT=1

  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]

  run cat "${CALL_LOG}"
  [[ "$output" == *"release create 2026.09.03-abc1234 --notes-file /tmp/release-notes.md"* ]]
  [ ! -s "${HALT_LOG}" ]
}

@test "branch 2: uses --generate-notes --notes-start-tag when a previous release tag is set" {
  export RELEASE_TAG="2026.09.03-abc1234"
  export PREV_RELEASE_TAG="2026.09.02-0000000"
  export GH_VIEW_EXIT=1

  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]

  run cat "${CALL_LOG}"
  [[ "$output" == *"release create 2026.09.03-abc1234 --generate-notes --notes-start-tag 2026.09.02-0000000"* ]]
}

@test "branch 3: uses --generate-notes with no start tag for the first release" {
  export RELEASE_TAG="2026.09.03-abc1234"
  export GH_VIEW_EXIT=1

  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No previous release tag; creating first release without --notes-start-tag."* ]]

  run cat "${CALL_LOG}"
  [[ "$output" == *"release create 2026.09.03-abc1234 --generate-notes"* ]]
  [[ "$output" != *"--notes-start-tag"* ]]
  [[ "$output" != *"--notes-file"* ]]
}

@test "notes-source branch wins over an also-set previous release tag" {
  export RELEASE_TAG="2026.09.03-abc1234"
  export RELEASE_NOTES_SOURCE="deploy-diff-summaries"
  export RELEASE_NOTES_FILE="/tmp/release-notes.md"
  export PREV_RELEASE_TAG="2026.09.02-0000000"
  export GH_VIEW_EXIT=1

  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]

  run cat "${CALL_LOG}"
  [[ "$output" == *"--notes-file /tmp/release-notes.md"* ]]
  [[ "$output" != *"--notes-start-tag"* ]]
}

@test "skip_if_exists=false creates the release without checking gh release view first" {
  export RELEASE_TAG="2026.09.03-abc1234"
  export PARAM_SKIP_IF_EXISTS="false"
  # Even though "found" would trigger the skip path when the check runs,
  # it must never be consulted here.
  export GH_VIEW_EXIT=0

  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [ ! -s "${HALT_LOG}" ]

  run cat "${CALL_LOG}"
  [[ "$output" == *"release create 2026.09.03-abc1234 --generate-notes"* ]]
}

@test "fails fast with a clear error when the tag env var is empty" {
  export RELEASE_TAG=""
  export GH_VIEW_EXIT=1

  run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"RELEASE_TAG is empty"* ]]
  [ ! -s "${CALL_LOG}" ]
  [ ! -s "${HALT_LOG}" ]
}

@test "honors custom env var names for tag, prev tag, notes source, and notes file" {
  export PARAM_TAG_ENV="MY_TAG"
  export PARAM_PREV_TAG_ENV="MY_PREV_TAG"
  export PARAM_NOTES_SOURCE_ENV="MY_NOTES_SOURCE"
  export PARAM_NOTES_FILE_ENV="MY_NOTES_FILE"
  export MY_TAG="2026.09.03-def5678"
  export MY_NOTES_SOURCE="deploy-diff-summaries"
  export MY_NOTES_FILE="/tmp/custom-notes.md"
  export GH_VIEW_EXIT=1

  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]

  run cat "${CALL_LOG}"
  [[ "$output" == *"release create 2026.09.03-def5678 --notes-file /tmp/custom-notes.md"* ]]
}

@test "race-safe create (a): initial view finds nothing, create succeeds on the first try" {
  export RELEASE_TAG="2026.09.03-abc1234"
  export GH_VIEW_EXIT=1
  export GH_CREATE_EXIT=0

  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" != *"concurrently"* ]]

  run cat "${CALL_LOG}"
  [[ "$output" == *"release create 2026.09.03-abc1234 --generate-notes"* ]]
}

@test "race-safe create (b): create fails as already-existing, re-check confirms it, so it succeeds" {
  export RELEASE_TAG="2026.09.03-abc1234"
  # 1st gh release view (idempotency pre-check): not found.
  export GH_VIEW_EXIT=1
  # gh release create: fails, simulating a sibling job winning the race.
  export GH_CREATE_EXIT=1
  # 2nd gh release view (gh_release_create_race_safe's re-check): found.
  export GH_VIEW_EXIT_2=0

  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Release 2026.09.03-abc1234 was created concurrently by another job; treating as success."* ]]
}

@test "race-safe create (c): create fails and the re-check also fails, so the original status wins" {
  export RELEASE_TAG="2026.09.03-abc1234"
  # 1st gh release view (idempotency pre-check): not found.
  export GH_VIEW_EXIT=1
  # gh release create: fails with a distinctive exit code, to assert it
  # (and not some other status) is what ultimately propagates.
  export GH_CREATE_EXIT=17
  # 2nd gh release view (gh_release_create_race_safe's re-check): still
  # not found, so this is a genuine failure, not a concurrent creation.
  export GH_VIEW_EXIT_2=1

  run bash "${SCRIPT}"
  [ "$status" -eq 17 ]
  [[ "$output" != *"concurrently"* ]]
}
