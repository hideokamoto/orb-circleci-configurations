#!/usr/bin/env bash
# POST the Deploy Diff Summaries payload built by make_diff_summary_payload.sh
# to the CircleCI API, poll until the summary is ready, and write it to the
# release notes file — or signal a non-blocking fallback to
# `gh release create --generate-notes` on any failure (no payload, API
# error, timeout, empty summary).
#
# Ported from workflows/deployment/scripts/fetch-deploy-diff-summary.sh and
# the "Generate release notes (Deploy Diff Summaries)" step of the
# create-github-release job in workflows/deployment/cloudflare-workers.yaml
# (hideokamoto/circleci-configurations), which previously kept an inline
# copy of this logic in sync with the standalone script by hand.
#
# Requires the standalone CircleCI CLI (`circleci api ...`) on PATH; run the
# install_circleci_cli command first.
set -uo pipefail
# Intentionally not `-e`: API/poll failures are expected and must fall
# through to the gh-generate-notes fallback branch instead of aborting the
# step non-zero (this command must never block a release).

fall_back_to_gh_generate_notes() {
  local reason="$1"
  echo "$reason"
  echo "export RELEASE_NOTES_SOURCE=gh-generate-notes" >> "$BASH_ENV"
}

# Posts payload_file to deploy/diff-summaries, polls
# deploy/diff-summaries/<id> up to max_polls times (poll_interval seconds
# apart) until phase == ended, then prints the summary text on stdout.
# Prints nothing and returns 1 on any failure (missing id, timeout, or an
# empty summary).
poll_for_summary() {
  local payload_file="$1" max_polls="$2" poll_interval="$3"
  local summary_id phase summary i

  summary_id="$(circleci api deploy/diff-summaries -d "@${payload_file}" 2>/dev/null | jq -r '.data.id // empty')"
  [ -n "$summary_id" ] || return 1

  phase=""
  for ((i = 0; i < max_polls; i++)); do
    phase="$(circleci api "deploy/diff-summaries/${summary_id}" --jq '.data.attributes.phase' 2>/dev/null || true)"
    [ "$phase" = "ended" ] && break
    sleep "$poll_interval"
  done
  [ "$phase" = "ended" ] || return 1

  summary="$(circleci api "deploy/diff-summaries/${summary_id}" 2>/dev/null | jq -r '.data.attributes.summary // empty')"
  [ -n "$summary" ] || return 1
  printf '%s' "$summary"
}

main() {
  local payload_file output_file max_polls poll_interval summary

  # make_diff_summary_payload.sh already decided this run is not eligible
  # (missing project id/token/org id/head_ref) and exported the fallback;
  # there is nothing to POST.
  if [ "${RELEASE_NOTES_SOURCE:-}" = "gh-generate-notes" ]; then
    echo "Deploy Diff Summaries payload was not built; skipping API call."
    exit 0
  fi

  payload_file="${DEPLOY_DIFF_PAYLOAD_FILE:-}"
  if [ -z "$payload_file" ] || [ ! -f "$payload_file" ]; then
    fall_back_to_gh_generate_notes "Deploy Diff Summaries payload file is missing; falling back to gh --generate-notes."
    exit 0
  fi

  output_file="$(circleci env subst "${PARAM_OUTPUT_FILE:-/tmp/release-notes.md}")"
  max_polls="${PARAM_MAX_POLLS:-30}"
  poll_interval="${PARAM_POLL_INTERVAL:-2}"

  if summary="$(poll_for_summary "$payload_file" "$max_polls" "$poll_interval")"; then
    printf '%s\n' "$summary" > "$output_file"
    echo "export RELEASE_NOTES_FILE=\"$output_file\"" >> "$BASH_ENV"
    echo "export RELEASE_NOTES_SOURCE=deploy-diff-summaries" >> "$BASH_ENV"
    echo "Deploy Diff Summaries succeeded; release notes written to $output_file."
  else
    fall_back_to_gh_generate_notes "Deploy Diff Summaries failed; falling back to gh --generate-notes."
  fi
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
