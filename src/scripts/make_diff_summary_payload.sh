#!/usr/bin/env bash
# Resolve the diff range for a release and build the Deploy Diff Summaries
# API payload for it, or signal a non-blocking fallback to
# `gh release create --generate-notes` when a prerequisite (CircleCI project
# id, API token, resolvable organization id, or head revision) is missing.
#
# Ported from workflows/deployment/scripts/make-diff-summary-payload.sh and
# the "Generate release notes (Deploy Diff Summaries)" step of the
# create-github-release job in workflows/deployment/cloudflare-workers.yaml
# (hideokamoto/circleci-configurations), which previously kept an inline
# copy of this logic in sync with the standalone script by hand.
set -uo pipefail
# Intentionally not `-e`: every prerequisite check below is expected to be
# able to fail and fall through to the gh-generate-notes fallback branch
# instead of aborting the step non-zero (this command must never block a
# release on Deploy Diff Summaries being unavailable).

# Maps a `git diff --name-status` letter to the payload's status vocabulary.
status_to_word() {
  case "$1" in
    A) echo "added" ;;
    M) echo "modified" ;;
    T) echo "modified" ;;
    D) echo "deleted" ;;
    R*) echo "renamed" ;;
    C*) echo "renamed" ;;
    *) echo "modified" ;;
  esac
}

# Builds the payload's `files` array for a git revision range.
#
# `git diff --name-status -z -M --diff-filter=ACDMRT` emits rename/copy
# entries as two NUL-terminated records (old path, then new path) instead of
# one; every other status emits a single record. The loop below reads
# accordingly, discarding the old path so only the current filename is used
# to look up numstat/patch.
build_files_json() {
  local range="$1"
  local files_json="[]"
  local status filename status_word additions deletions additions_num deletions_num file_obj _discard

  while IFS= read -r -d '' status; do
    filename=""
    if [[ "$status" == R* ]] || [[ "$status" == C* ]]; then
      IFS= read -r -d '' _discard
      IFS= read -r -d '' filename
    else
      IFS= read -r -d '' filename
    fi
    [ -z "$filename" ] && continue

    status_word="$(status_to_word "$status")"
    IFS=$'\t' read -r additions deletions _discard < <(git diff --numstat "$range" -- "$filename" | head -n1)

    # Binary files report numstat counts as "-"; treat as 0 so jq gets a
    # number rather than failing on a non-numeric --argjson.
    if [ "${additions:-}" = "-" ] || [ -z "${additions:-}" ]; then
      additions_num=0
    else
      additions_num="$additions"
    fi
    if [ "${deletions:-}" = "-" ] || [ -z "${deletions:-}" ]; then
      deletions_num=0
    else
      deletions_num="$deletions"
    fi

    file_obj="$(
      git diff "$range" -- "$filename" | jq -R -s \
        --arg filename "$filename" --arg status "$status_word" \
        --argjson additions "$additions_num" --argjson deletions "$deletions_num" \
        '{filename: $filename, status: $status, additions: $additions, deletions: $deletions, patch: .}'
    )"
    files_json="$(echo "$files_json" | jq --argjson f "$file_obj" '. + [$f]')"
  done < <(git diff --name-status -z -M --diff-filter=ACDMRT "$range")

  printf '%s' "$files_json"
}

# Builds the full Deploy Diff Summaries API payload for a revision range.
build_payload() {
  local base_ref="$1" head_ref="$2" org_id="$3" project_id="$4"
  local range="${base_ref}..${head_ref}"
  local commit_messages_json files_json

  commit_messages_json="$(git log --format=%s "$range" | jq -R -s 'split("\n") | map(select(length > 0))')"
  files_json="$(build_files_json "$range")"

  jq -n \
    --arg org_id "$org_id" \
    --arg project_id "$project_id" \
    --argjson commit_messages "$commit_messages_json" \
    --argjson files "$files_json" \
    '{org_id: $org_id, project_id: $project_id, diff: {commit_messages: $commit_messages, files: $files}}'
}

# Resolves the CircleCI organization id: $CIRCLE_ORGANIZATION_ID when set
# (normal case in an actual CircleCI job), else `circleci api projects/<id>`.
resolve_org_id() {
  local project_id="$1"
  if [ -n "${CIRCLE_ORGANIZATION_ID:-}" ]; then
    printf '%s' "$CIRCLE_ORGANIZATION_ID"
    return 0
  fi
  circleci api "projects/${project_id}" --jq '.data.references.org.id' 2>/dev/null || true
}

# base_ref resolution order: explicit parameter > the tag
# resolve_previous_deploy_tag exported ($PREV_RELEASE_TAG) > the repository
# root commit (first release ever, so there is nothing earlier to diff).
resolve_base_ref() {
  local param_base_ref="$1"
  if [ -n "$param_base_ref" ]; then
    printf '%s' "$param_base_ref"
  elif [ -n "${PREV_RELEASE_TAG:-}" ]; then
    printf '%s' "$PREV_RELEASE_TAG"
  else
    git rev-list --max-parents=0 HEAD
  fi
}

# head_ref resolution order: explicit parameter > the tag resolve_deploy_tag
# exported ($RELEASE_TAG).
resolve_head_ref() {
  local param_head_ref="$1"
  if [ -n "$param_head_ref" ]; then
    printf '%s' "$param_head_ref"
  else
    printf '%s' "${RELEASE_TAG:-}"
  fi
}

fall_back_to_gh_generate_notes() {
  local reason="$1"
  echo "$reason"
  echo "export RELEASE_NOTES_SOURCE=gh-generate-notes" >> "$BASH_ENV"
}

main() {
  local base_ref head_ref token_env token_value project_id org_id payload_file

  base_ref="$(circleci env subst "${PARAM_BASE_REF:-}")"
  head_ref="$(circleci env subst "${PARAM_HEAD_REF:-}")"
  token_env="${PARAM_CIRCLE_TOKEN_ENV:-CIRCLE_TOKEN}"
  token_value="${!token_env:-}"
  payload_file="${DEPLOY_DIFF_PAYLOAD_FILE:-/tmp/diff-summary-payload.json}"

  project_id="${CIRCLE_PROJECT_ID:-}"
  if [ -z "$project_id" ]; then
    fall_back_to_gh_generate_notes "CIRCLE_PROJECT_ID is missing; falling back to gh --generate-notes."
    exit 0
  fi

  if [ -z "$token_value" ]; then
    fall_back_to_gh_generate_notes "\$${token_env} is missing; falling back to gh --generate-notes. Add a CircleCI Personal API Token as \$${token_env} (e.g. in the circleci context)."
    exit 0
  fi

  org_id="$(resolve_org_id "$project_id")"
  if [ -z "$org_id" ]; then
    fall_back_to_gh_generate_notes "Could not resolve organization id; falling back to gh --generate-notes."
    exit 0
  fi

  base_ref="$(resolve_base_ref "$base_ref")"
  head_ref="$(resolve_head_ref "$head_ref")"
  if [ -z "$head_ref" ]; then
    fall_back_to_gh_generate_notes "head_ref could not be resolved (no head_ref parameter and \$RELEASE_TAG is unset); falling back to gh --generate-notes."
    exit 0
  fi

  echo "Building Deploy Diff Summaries payload for ${base_ref}..${head_ref}"
  if ! build_payload "$base_ref" "$head_ref" "$org_id" "$project_id" > "$payload_file"; then
    rm -f "$payload_file"
    fall_back_to_gh_generate_notes "Failed to build the Deploy Diff Summaries payload; falling back to gh --generate-notes."
    exit 0
  fi

  echo "Diff summary payload size: $(wc -c < "$payload_file") bytes"
  echo "export DEPLOY_DIFF_PAYLOAD_FILE=\"$payload_file\"" >> "$BASH_ENV"
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
