#!/usr/bin/env bats
# Unit tests for src/scripts/make_diff_summary_payload.sh and
# src/scripts/fetch_deploy_diff_summary.sh (the two steps behind the
# generate_release_notes_from_deploy_diff command).

PAYLOAD_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/make_diff_summary_payload.sh"
FETCH_SCRIPT="${BATS_TEST_DIRNAME}/../scripts/fetch_deploy_diff_summary.sh"

setup() {
  TEST_DIR="$(mktemp -d)"
  BIN_DIR="${TEST_DIR}/bin"
  mkdir -p "$BIN_DIR"
  PATH="${BIN_DIR}:${PATH}"

  REPO_DIR="${TEST_DIR}/repo"
  mkdir -p "$REPO_DIR"
  cd "$REPO_DIR" || return 1
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test User"

  BASH_ENV="${TEST_DIR}/bash_env"
  : > "$BASH_ENV"
  export BASH_ENV

  export CIRCLE_PROJECT_ID="proj-123"
  export CIRCLE_ORGANIZATION_ID="org-abc"
  export CIRCLE_TOKEN="tok-xyz"
  export PARAM_CIRCLE_TOKEN_ENV="CIRCLE_TOKEN"
  unset RELEASE_TAG PREV_RELEASE_TAG DEPLOY_DIFF_PAYLOAD_FILE RELEASE_NOTES_SOURCE RELEASE_NOTES_FILE
  unset PARAM_BASE_REF PARAM_HEAD_REF PARAM_OUTPUT_FILE PARAM_MAX_POLLS PARAM_POLL_INTERVAL

  # `circleci env subst` passthrough stub (identity — no ${...} in fixtures)
  # plus a `circleci api` stub whose response is driven by the STUB_*
  # env vars a test sets before calling the fetch script.
  cat > "${BIN_DIR}/circleci" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "env" ] && [ "$2" = "subst" ]; then
  printf '%s' "${3:-}"
  exit 0
fi
if [ "$1" = "api" ]; then
  shift
  if [ "$1" = "deploy/diff-summaries" ] && [ "$2" = "-d" ]; then
    # POST: create a new diff summary
    if [ "${STUB_CIRCLECI_POST_FAIL:-false}" = "true" ]; then
      exit 1
    fi
    printf '{"data":{"id":"%s"}}' "${STUB_CIRCLECI_ID:-summary-1}"
    exit 0
  fi
  if [[ "$1" == deploy/diff-summaries/* ]]; then
    if [ "$2" = "--jq" ]; then
      printf '%s' "${STUB_CIRCLECI_PHASE:-ended}"
      exit 0
    fi
    printf '{"data":{"attributes":{"phase":"%s","summary":"%s"}}}' \
      "${STUB_CIRCLECI_PHASE:-ended}" "${STUB_CIRCLECI_SUMMARY:-Release summary text}"
    exit 0
  fi
  if [ "$1" = "projects/proj-123" ]; then
    # Real `circleci api ... --jq '<filter>'` prints only the filtered
    # value, not the enclosing JSON — mirror that here.
    printf '%s' "${STUB_CIRCLECI_ORG_ID:-}"
    exit 0
  fi
  exit 1
fi
exit 1
STUB
  chmod +x "${BIN_DIR}/circleci"
}

teardown() {
  cd /
  rm -rf "$TEST_DIR"
}

commit_file() {
  # commit_file <path> <content> -- writes content and commits it.
  printf '%s' "$2" > "$1"
  git add "$1"
  git commit -q -m "commit $1"
}

# ---- make_diff_summary_payload.sh: status_to_word -------------------------

@test "status_to_word maps git status letters to payload vocabulary" {
  source "$PAYLOAD_SCRIPT" bats-core
  [ "$(status_to_word A)" = "added" ]
  [ "$(status_to_word M)" = "modified" ]
  [ "$(status_to_word T)" = "modified" ]
  [ "$(status_to_word D)" = "deleted" ]
  [ "$(status_to_word R100)" = "renamed" ]
  [ "$(status_to_word C100)" = "renamed" ]
}

# ---- make_diff_summary_payload.sh: build_files_json ------------------------

@test "build_files_json reports a rename with its new filename" {
  commit_file "old-name.txt" "same content across the rename
line two
"
  BASE_SHA="$(git rev-parse HEAD)"
  git mv old-name.txt new-name.txt
  git commit -q -m "rename old-name.txt to new-name.txt"
  HEAD_SHA="$(git rev-parse HEAD)"

  source "$PAYLOAD_SCRIPT" bats-core
  result="$(build_files_json "${BASE_SHA}..${HEAD_SHA}")"

  [ "$(echo "$result" | jq 'length')" -eq 1 ]
  [ "$(echo "$result" | jq -r '.[0].filename')" = "new-name.txt" ]
  [ "$(echo "$result" | jq -r '.[0].status')" = "renamed" ]
}

@test "build_files_json performs the rename/copy two-pass read (discards the old path)" {
  # git diff --name-status only ever emits C when copy detection (-C) is
  # enabled, which this script does not pass; exercise the two-pass read
  # for a copy status directly by overriding `git` for the name-status
  # call only, and delegating every other invocation to the real binary.
  commit_file "copy-source.txt" "shared content"

  git() {
    if [ "$1" = "diff" ] && [ "$2" = "--name-status" ]; then
      printf 'C100\0copy-source.txt\0copy-dest.txt\0'
      return 0
    fi
    command git "$@"
  }

  source "$PAYLOAD_SCRIPT" bats-core
  result="$(build_files_json "HEAD..HEAD")"

  [ "$(echo "$result" | jq 'length')" -eq 1 ]
  [ "$(echo "$result" | jq -r '.[0].filename')" = "copy-dest.txt" ]
  [ "$(echo "$result" | jq -r '.[0].status')" = "renamed" ]
}

@test "build_files_json rounds binary numstat '-' additions/deletions to 0" {
  printf '\x00\x01\x02binary-v1\xff' > binary.bin
  git add binary.bin
  git commit -q -m "add binary"
  BASE_SHA="$(git rev-parse HEAD)"
  printf '\x00\x01\x02binary-v2-different\xff\xfe' > binary.bin
  git add binary.bin
  git commit -q -m "change binary"
  HEAD_SHA="$(git rev-parse HEAD)"

  source "$PAYLOAD_SCRIPT" bats-core
  result="$(build_files_json "${BASE_SHA}..${HEAD_SHA}")"

  [ "$(echo "$result" | jq 'length')" -eq 1 ]
  [ "$(echo "$result" | jq -r '.[0].filename')" = "binary.bin" ]
  [ "$(echo "$result" | jq -r '.[0].additions')" = "0" ]
  [ "$(echo "$result" | jq -r '.[0].deletions')" = "0" ]
}

# ---- make_diff_summary_payload.sh: build_payload / empty range -------------

@test "build_payload returns empty commit_messages and files for an empty range" {
  commit_file "a.txt" "hello"
  SHA="$(git rev-parse HEAD)"

  source "$PAYLOAD_SCRIPT" bats-core
  result="$(build_payload "$SHA" "$SHA" "org-abc" "proj-123")"

  [ "$(echo "$result" | jq -r '.diff.commit_messages | length')" -eq 0 ]
  [ "$(echo "$result" | jq -r '.diff.files | length')" -eq 0 ]
  [ "$(echo "$result" | jq -r '.org_id')" = "org-abc" ]
  [ "$(echo "$result" | jq -r '.project_id')" = "proj-123" ]
}

# ---- make_diff_summary_payload.sh: base/head ref resolution ---------------

@test "resolve_base_ref prefers the explicit parameter" {
  source "$PAYLOAD_SCRIPT" bats-core
  PREV_RELEASE_TAG="ignored-tag"
  [ "$(resolve_base_ref "explicit-ref")" = "explicit-ref" ]
}

@test "resolve_base_ref falls back to PREV_RELEASE_TAG, then the root commit" {
  commit_file "a.txt" "hello"
  ROOT_SHA="$(git rev-parse HEAD)"

  source "$PAYLOAD_SCRIPT" bats-core

  PREV_RELEASE_TAG="2026.01.01-abcdef0"
  [ "$(resolve_base_ref "")" = "2026.01.01-abcdef0" ]

  unset PREV_RELEASE_TAG
  [ "$(resolve_base_ref "")" = "$ROOT_SHA" ]
}

@test "resolve_head_ref prefers the explicit parameter, else RELEASE_TAG" {
  source "$PAYLOAD_SCRIPT" bats-core
  [ "$(resolve_head_ref "explicit-ref")" = "explicit-ref" ]

  RELEASE_TAG="2026.02.02-1234567"
  [ "$(resolve_head_ref "")" = "2026.02.02-1234567" ]

  unset RELEASE_TAG
  [ "$(resolve_head_ref "")" = "" ]
}

# ---- make_diff_summary_payload.sh: main() fallback / success paths --------

@test "main falls back to gh-generate-notes when CIRCLE_PROJECT_ID is missing" {
  unset CIRCLE_PROJECT_ID
  run bash "$PAYLOAD_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^export RELEASE_NOTES_SOURCE=gh-generate-notes$' "$BASH_ENV"
}

@test "main falls back to gh-generate-notes when the token env var is unset (non-blocking, exit 0)" {
  export PARAM_CIRCLE_TOKEN_ENV="NONEXISTENT_TOKEN_VAR"
  run bash "$PAYLOAD_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^export RELEASE_NOTES_SOURCE=gh-generate-notes$' "$BASH_ENV"
  [ ! -f "${DEPLOY_DIFF_PAYLOAD_FILE:-/tmp/diff-summary-payload.json}" ] || rm -f "${DEPLOY_DIFF_PAYLOAD_FILE:-/tmp/diff-summary-payload.json}"
}

@test "main falls back to gh-generate-notes when the org id cannot be resolved" {
  unset CIRCLE_ORGANIZATION_ID
  export STUB_CIRCLECI_ORG_ID=""
  export RELEASE_TAG="2026.03.03-abc1234"
  commit_file "a.txt" "hello"
  run bash "$PAYLOAD_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^export RELEASE_NOTES_SOURCE=gh-generate-notes$' "$BASH_ENV"
}

@test "main falls back to gh-generate-notes when head_ref cannot be resolved" {
  commit_file "a.txt" "hello"
  run bash "$PAYLOAD_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^export RELEASE_NOTES_SOURCE=gh-generate-notes$' "$BASH_ENV"
}

@test "main builds the payload and exports DEPLOY_DIFF_PAYLOAD_FILE on success" {
  commit_file "a.txt" "hello"
  BASE_SHA="$(git rev-parse HEAD)"
  commit_file "b.txt" "world"
  HEAD_SHA="$(git rev-parse HEAD)"

  export PARAM_BASE_REF="$BASE_SHA"
  export PARAM_HEAD_REF="$HEAD_SHA"
  PAYLOAD_FILE="${TEST_DIR}/payload.json"
  export DEPLOY_DIFF_PAYLOAD_FILE="$PAYLOAD_FILE"

  run bash "$PAYLOAD_SCRIPT"
  [ "$status" -eq 0 ]
  ! grep -q 'RELEASE_NOTES_SOURCE' "$BASH_ENV"
  grep -q "export DEPLOY_DIFF_PAYLOAD_FILE=\"${PAYLOAD_FILE}\"" "$BASH_ENV"
  [ -f "$PAYLOAD_FILE" ]
  [ "$(jq -r '.org_id' "$PAYLOAD_FILE")" = "org-abc" ]
  [ "$(jq -r '.diff.commit_messages | length' "$PAYLOAD_FILE")" -eq 1 ]
}

# ---- fetch_deploy_diff_summary.sh ------------------------------------------

@test "fetch main is a no-op when make_diff_summary_payload already fell back" {
  echo "export RELEASE_NOTES_SOURCE=gh-generate-notes" >> "$BASH_ENV"
  run bash "$FETCH_SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "/tmp/release-notes.md" ]
}

@test "fetch main falls back when the payload file is missing" {
  export DEPLOY_DIFF_PAYLOAD_FILE="${TEST_DIR}/does-not-exist.json"
  run bash "$FETCH_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^export RELEASE_NOTES_SOURCE=gh-generate-notes$' "$BASH_ENV"
}

@test "fetch main falls back immediately when the POST does not return an id" {
  echo '{}' > "${TEST_DIR}/payload.json"
  export DEPLOY_DIFF_PAYLOAD_FILE="${TEST_DIR}/payload.json"
  export STUB_CIRCLECI_POST_FAIL="true"
  export PARAM_MAX_POLLS="2"
  export PARAM_POLL_INTERVAL="0"
  run bash "$FETCH_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^export RELEASE_NOTES_SOURCE=gh-generate-notes$' "$BASH_ENV"
}

@test "fetch main falls back on poll timeout (phase never reaches ended)" {
  echo '{}' > "${TEST_DIR}/payload.json"
  export DEPLOY_DIFF_PAYLOAD_FILE="${TEST_DIR}/payload.json"
  export STUB_CIRCLECI_PHASE="running"
  export PARAM_MAX_POLLS="2"
  export PARAM_POLL_INTERVAL="0"
  run bash "$FETCH_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^export RELEASE_NOTES_SOURCE=gh-generate-notes$' "$BASH_ENV"
}

@test "fetch main writes the summary and exports success vars" {
  echo '{}' > "${TEST_DIR}/payload.json"
  export DEPLOY_DIFF_PAYLOAD_FILE="${TEST_DIR}/payload.json"
  export STUB_CIRCLECI_ID="summary-42"
  export STUB_CIRCLECI_PHASE="ended"
  export STUB_CIRCLECI_SUMMARY="Notable changes this release."
  export PARAM_OUTPUT_FILE="${TEST_DIR}/release-notes.md"
  export PARAM_MAX_POLLS="5"
  export PARAM_POLL_INTERVAL="0"

  run bash "$FETCH_SCRIPT"
  [ "$status" -eq 0 ]
  grep -q "export RELEASE_NOTES_FILE=\"${TEST_DIR}/release-notes.md\"" "$BASH_ENV"
  grep -q '^export RELEASE_NOTES_SOURCE=deploy-diff-summaries$' "$BASH_ENV"
  [ "$(cat "${TEST_DIR}/release-notes.md")" = "Notable changes this release." ]
}
