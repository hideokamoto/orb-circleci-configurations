#!/usr/bin/env bats
# Unit tests for src/scripts/create_github_release.sh.
#
# `gh` and `circleci-agent` are stubbed via a PATH-prepended fixture
# directory, so the tests never touch a real GitHub repo and never halt
# the actual bats process. The `gh` stub records every "release create"
# invocation (one line per call, space-joined args) to CALL_LOG, and its
# "release view" behavior (found / not found) is controlled per test via
# GH_VIEW_EXIT. The `circleci-agent` stub records "step halt" calls to
# HALT_LOG so a halt can be asserted without actually stopping the step.
#
# The script is run as a real subprocess (`bash "${SCRIPT}"`) rather than
# sourced, so its "Will not run if sourced for bats-core tests" guard does
# not apply here and main() executes exactly as it would in a real job.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/src/scripts/create_github_release.sh"

  TEST_DIR="$(mktemp -d)"
  STUB_BIN="${TEST_DIR}/bin"
  mkdir -p "${STUB_BIN}"
  CALL_LOG="${TEST_DIR}/gh-calls.log"
  HALT_LOG="${TEST_DIR}/halt-calls.log"
  : > "${CALL_LOG}"
  : > "${HALT_LOG}"

  # gh stub: "release view <tag>" exits with GH_VIEW_EXIT (default 1 = not
  # found, matching gh's real behavior for a missing release). "release
  # create ..." logs its full argv and exits 0.
  cat > "${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "release" ] && [ "$2" = "view" ]; then
  exit "${GH_VIEW_EXIT:-1}"
fi
if [ "$1" = "release" ] && [ "$2" = "create" ]; then
  echo "$*" >> "${CALL_LOG}"
  exit 0
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

  export CALL_LOG HALT_LOG
  export PATH="${STUB_BIN}:${PATH}"

  export PARAM_TAG_ENV="RELEASE_TAG"
  export PARAM_PREV_TAG_ENV="PREV_RELEASE_TAG"
  export PARAM_NOTES_SOURCE_ENV="RELEASE_NOTES_SOURCE"
  export PARAM_NOTES_FILE_ENV="RELEASE_NOTES_FILE"
  export PARAM_SKIP_IF_EXISTS="true"

  unset RELEASE_TAG PREV_RELEASE_TAG RELEASE_NOTES_SOURCE RELEASE_NOTES_FILE || true
}

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
