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

# This script calls two different CircleCI CLIs, on purpose:
#   - The build-agent CLI at /usr/bin/circleci (CIRCLECI_CLI below) ships in
#     every job container regardless of PATH, and is what provides
#     `env subst`. cimg images also put a *different* CLI on PATH, so calling
#     `env subst` unqualified would use whichever one PATH resolves to.
#   - `circleci api ...` (in poll_for_summary) is deliberately left as bare
#     `circleci` on PATH: it needs the standalone CLI's `api` subcommand,
#     which the build-agent CLI does not have. That standalone CLI is
#     installed onto PATH by the install_circleci_cli command, which must
#     run before this one.
CIRCLECI_CLI="${CIRCLECI_CLI:-/usr/bin/circleci}"

# Logs why Deploy Diff Summaries is being skipped and exports the
# non-blocking fallback marker for downstream release-creation steps.
# Args:
#   $1 - reason - human-readable message explaining why the API call/poll
#        failed or the payload file was missing.
# Side effects:
#   Prints $1 to stdout; appends `export RELEASE_NOTES_SOURCE=gh-generate-notes`
#   to $BASH_ENV.
fall_back_to_gh_generate_notes() {
  local reason="$1"
  echo "$reason"
  echo "export RELEASE_NOTES_SOURCE=gh-generate-notes" >> "$BASH_ENV"
}

# Posts payload_file to deploy/diff-summaries, polls
# deploy/diff-summaries/<id> up to max_polls times (poll_interval seconds
# apart) until phase == ended, then prints the summary text on stdout.
# Prints nothing and returns 1 on any failure (missing id, timeout, or an
# empty summary). `circleci` here is deliberately bare/on-PATH — see the
# CIRCLECI_CLI note near the top of this file.
# Args:
#   $1 - payload_file  - path to the JSON payload built by
#        make_diff_summary_payload.sh.
#   $2 - max_polls     - maximum number of phase polls before giving up.
#   $3 - poll_interval - seconds to sleep between polls.
# Returns:
#   0 with the summary text on stdout on success; 1 with no stdout on
#   failure (POST didn't return an id, phase never reached "ended", or the
#   summary field was empty).
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

# Entry point for the "Fetch Deploy Diff Summary and write release notes"
# command step. No-ops when the previous step already signalled a fallback
# or left no payload file behind; otherwise polls for the summary (see
# poll_for_summary) and either writes it to the output file and exports the
# success vars, or falls back to gh-generate-notes.
# Args:
#   None. Reads RELEASE_NOTES_SOURCE, DEPLOY_DIFF_PAYLOAD_FILE,
#   PARAM_OUTPUT_FILE, PARAM_MAX_POLLS, and PARAM_POLL_INTERVAL from the
#   environment.
# Side effects:
#   Writes the release notes file on success, and/or appends exports to
#   $BASH_ENV. Always exits 0 (never fails the job).
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

  output_file="$("$CIRCLECI_CLI" env subst "${PARAM_OUTPUT_FILE:-/tmp/release-notes.md}")"
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
