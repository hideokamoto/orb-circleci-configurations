#!/usr/bin/env bash
# Ask CircleCI's Chunk agent to open a `fix(deps):` pull request for a failed
# scheduled dependency audit.
#
# All identifiers are resolved through the APIs at runtime — nothing (org id,
# project id, pipeline definition id) is stored in the repository:
#   org/project  <- GET /api/v2/project/gh/<owner>/<repo>
#   definition   <- GET /api/v2/projects/<project>/pipeline-definitions
#                   entry named "chunk-task-pipeline" (auto-created by CircleCI
#                   when Chunk is enabled for the project)
#   trigger      <- POST /api/v2/agents/org/<org>/project/<project>/runs
#                   (same shape as `chunk task run` in chunk-cli)
#
# Skips (exit 0) when: CIRCLE_TOKEN/GITHUB_TOKEN are absent, the open-PR list
# cannot be fetched, an open `circleci-app[bot]` `fix(deps):` PR already exists,
# or the project has no chunk-task-pipeline definition. Exits 1 only when the
# trigger POST itself fails.
#
# Environment:
#   CIRCLE_TOKEN, GITHUB_TOKEN   from the circleci / github contexts
#   DEP_AUDIT_LEVEL              severity that failed (default: high)
#   DEP_AUDIT_PM                 set by audit_deps.sh
#   DEP_AUDIT_RESULT             set by audit_deps.sh; must be 'failed' or
#                                this script skips, since a caller-supplied
#                                `when: on_fail` fires on any job failure,
#                                not specifically this audit's
#   BASH_ENV                     CHUNK_AUDIT_FIX_SUMMARY is exported here for
#                                a later slack/notify step

set -uo pipefail

PREFIX='[chunk-audit-fix]'
FIX_PR_AUTHOR='circleci-app[bot]'
FIX_PR_TITLE_PREFIX='fix(deps):'
CHUNK_DEFINITION_NAME='chunk-task-pipeline'

# Print the log line, export a single-line summary for Slack, then exit.
finish() {
  local code="$1" summary="$2"
  if [[ -n "${BASH_ENV:-}" ]]; then
    printf 'export CHUNK_AUDIT_FIX_SUMMARY=%q\n' "$(printf '%s' "$summary" | tr '"\\\n' "'  ")" >>"$BASH_ENV"
  fi
  echo "$PREFIX $summary"
  exit "$code"
}

# Call without command substitution: `http` writes the response body into
# $HTTP_BODY and the status into $HTTP_STATUS of the calling shell.
http() {
  local method="$1" url="$2" body="${3:-}"
  local -a args=(curl -sS -X "$method" -w $'\n%{http_code}')
  case "$url" in
    https://circleci.com/*) args+=(-H "Circle-Token: $CIRCLE_TOKEN") ;;
    https://api.github.com/*) args+=(-H "Authorization: Bearer $GITHUB_TOKEN" -H 'Accept: application/vnd.github+json') ;;
  esac
  if [[ -n "$body" ]]; then
    args+=(-H 'Content-Type: application/json' -d "$body")
  fi
  local resp
  resp="$("${args[@]}" "$url")" || return 1
  HTTP_STATUS="${resp##*$'\n'}"
  HTTP_BODY="${resp%$'\n'*}"
}

for key in CIRCLE_TOKEN GITHUB_TOKEN; do
  if [[ -z "${!key:-}" ]]; then
    finish 0 "$key が無いため Chunk を起動していません（circleci / github context を確認）"
  fi
done
command -v jq >/dev/null 2>&1 || finish 0 "jq が無いため Chunk を起動していません"

# audit_deps.sh exits before exporting DEP_AUDIT_PM when it could not
# identify a package manager at all (no package.json or lockfile). Treat
# that the same as an unsupported package manager rather than defaulting
# to npm, which would send Chunk npm-flavored fix instructions for a
# failure that was never actually an npm audit.
if [[ -z "${DEP_AUDIT_PM:-}" ]]; then
  finish 0 "DEP_AUDIT_PM が設定されていない（パッケージマネージャーを判定できなかった）ため Chunk を起動していません"
fi

# This public command is meant to be called after audit_deps in a
# caller-defined job, typically with `when: on_fail`. CircleCI's on_fail is
# job-wide — it fires if *anything* earlier in the job failed, not
# specifically this audit — so DEP_AUDIT_PM being set (even from a
# successful audit) isn't enough to know the audit itself failed. Require
# audit_deps.sh's own explicit result instead.
if [[ "${DEP_AUDIT_RESULT:-}" != failed ]]; then
  finish 0 "DEP_AUDIT_RESULT が 'failed' ではない（audit_deps 自体は失敗していない可能性がある）ため Chunk を起動していません"
fi

BRANCH="${CIRCLE_BRANCH:-main}"
OWNER="${CIRCLE_PROJECT_USERNAME:?CIRCLE_PROJECT_USERNAME is not set}"
REPO_NAME="${CIRCLE_PROJECT_REPONAME:?CIRCLE_PROJECT_REPONAME is not set}"
REPO="$OWNER/$REPO_NAME"
DEP_AUDIT_LEVEL="${DEP_AUDIT_LEVEL:-high}"

# ---- Open fix PR already exists? ------------------------------------------
open_fix_prs=''
page=1
while :; do
  if ! http GET "https://api.github.com/repos/${REPO}/pulls?state=open&base=${BRANCH}&per_page=100&page=${page}"; then
    HTTP_STATUS=0
  fi
  if [[ "$HTTP_STATUS" != "200" ]]; then
    finish 0 "PR 一覧を取得できない (HTTP ${HTTP_STATUS}) ため、重複を避けて Chunk を起動していません"
  fi
  prs="$(jq -r --arg a "$FIX_PR_AUTHOR" --arg p "$FIX_PR_TITLE_PREFIX" \
    '.[] | select(.user.login == $a and (.title | startswith($p))) | .html_url' <<<"$HTTP_BODY")"
  # `if` blocks, not `[[ ]] &&` lists: CircleCI runs each `run` step under
  # `bash -eo pipefail`, and a failed `[[ ]]` left side of `&&` exits the
  # shell before later pages or the summary can run.
  if [[ -n "$prs" ]]; then
    open_fix_prs+=$'\n'"$prs"
  fi
  if [[ "$(jq 'length' <<<"$HTTP_BODY")" -lt 100 ]]; then
    break
  fi
  page=$((page + 1))
done
open_fix_prs="$(grep -v '^$' <<<"$open_fix_prs" || true)"
if [[ -n "$open_fix_prs" ]]; then
  finish 0 "修正 PR が既に開いているため Chunk は起動していません: ${open_fix_prs//$'\n'/, }"
fi

# ---- Resolve org / project / chunk definition -------------------------------
if ! http GET "https://circleci.com/api/v2/project/gh/${REPO}"; then
  HTTP_STATUS=0
fi
[[ "$HTTP_STATUS" == "200" ]] || finish 0 "CircleCI project を解決できない (HTTP ${HTTP_STATUS}) ため Chunk を起動していません"
PROJECT_ID="$(jq -r '.id' <<<"$HTTP_BODY")"
ORG_ID="$(jq -r '.organization_id' <<<"$HTTP_BODY")"

if ! http GET "https://circleci.com/api/v2/projects/${PROJECT_ID}/pipeline-definitions"; then
  HTTP_STATUS=0
fi
[[ "$HTTP_STATUS" == "200" ]] || finish 0 "pipeline definitions を取得できない (HTTP ${HTTP_STATUS}) ため Chunk を起動していません"
DEFINITION_ID="$(jq -r --arg n "$CHUNK_DEFINITION_NAME" \
  '[.items[]? | select(.name == $n)][0].id // empty' <<<"$HTTP_BODY")"
if [[ -z "$DEFINITION_ID" ]]; then
  finish 0 "${CHUNK_DEFINITION_NAME} が存在しないため Chunk を起動していません（project の Chunk を有効化してください）"
fi

# ---- Build the fix prompt ---------------------------------------------------
# DEP_AUDIT_PM is guaranteed non-empty here (checked above).
case "$DEP_AUDIT_PM" in
  pnpm)
    FIX_PROMPT="The scheduled dependency audit (pnpm audit --audit-level=${DEP_AUDIT_LEVEL}) failed on branch ${BRANCH}. Fix it.
1. Run \`pnpm install --frozen-lockfile\` and \`pnpm audit --audit-level=${DEP_AUDIT_LEVEL}\` to list the advisories.
2. Fix each with the smallest change: if the vulnerable package is a direct dependency, bump it; otherwise add an override for the vulnerable range mapped to the patched version, following this repository's existing pnpm version and override configuration (the \`pnpm.overrides\` field in package.json, or the \`overrides\` field in pnpm-workspace.yaml, whichever this repo already uses) rather than introducing a new location.
3. Regenerate pnpm-lock.yaml only with \`pnpm install\` (never edit it by hand; never use npm or yarn). The lockfile diff must touch only the packages you fixed.
4. Verify: \`pnpm audit --audit-level=${DEP_AUDIT_LEVEL}\` exits 0, then the repo's build and test commands pass.
5. Commit with a message starting \`${FIX_PR_TITLE_PREFIX}\` and open a pull request against ${BRANCH} titled with the same prefix, whose description lists each advisory (GHSA id, package, vulnerable and patched range), the change, and the verification output.
Change nothing unrelated. If the audit already exits 0, make no changes and report that."
    ;;
  npm)
    FIX_PROMPT="The scheduled dependency audit (npm audit --audit-level=${DEP_AUDIT_LEVEL}) failed on branch ${BRANCH}. Fix it.
1. Run \`npm ci\` and \`npm audit --audit-level=${DEP_AUDIT_LEVEL}\` to list the advisories.
2. Fix each with the smallest change: if the vulnerable package is a direct dependency, bump it; otherwise add an entry to \`overrides\` in package.json mapping the vulnerable range to the patched version.
3. Regenerate package-lock.json only with \`npm install --package-lock-only\` (never edit it by hand). The lockfile diff must touch only the packages you fixed.
4. Verify: \`npm audit --audit-level=${DEP_AUDIT_LEVEL}\` exits 0, then the repo's build and test commands pass.
5. Commit with a message starting \`${FIX_PR_TITLE_PREFIX}\` and open a pull request against ${BRANCH} titled with the same prefix, whose description lists each advisory (GHSA id, package, vulnerable and patched range), the change, and the verification output.
Change nothing unrelated. If the audit already exits 0, make no changes and report that."
    ;;
  *)
    finish 0 "'${DEP_AUDIT_PM}' はサポート対象外のパッケージマネージャーのため Chunk を起動していません（pnpm / npm のみ対応）"
    ;;
esac

# ---- Trigger the Chunk run ---------------------------------------------------
payload="$(jq -n \
  --arg def_id "$DEFINITION_ID" \
  --arg branch "$BRANCH" \
  --arg prompt "$FIX_PROMPT" \
  '{
    agent_type: "prompt",
    definition_id: $def_id,
    checkout_branch: $branch,
    trigger_source: "chunk-cli",
    trigger_type: "api",
    parameters: {
      "agent-type": "prompt",
      "custom-prompt": $prompt,
      "run-pipeline-as-a-tool": true,
      "create-new-branch": true
    },
    stats: {prompt: $prompt, checkout_branch: $branch}
  }')"
if ! http POST "https://circleci.com/api/v2/agents/org/${ORG_ID}/project/${PROJECT_ID}/runs" "$payload"; then
  HTTP_STATUS=0
fi
if [[ "$HTTP_STATUS" != "200" && "$HTTP_STATUS" != "201" && "$HTTP_STATUS" != "202" ]]; then
  echo "$PREFIX trigger failed (HTTP ${HTTP_STATUS}): $HTTP_BODY"
  finish 1 "Chunk の起動に失敗しました (HTTP ${HTTP_STATUS})"
fi
RUN_ID="$(jq -r '.runId // empty' <<<"$HTTP_BODY")"
finish 0 "Chunk に修正 PR の作成を依頼しました: https://app.circleci.com/agents/gh/${OWNER}/chat/${RUN_ID}"
