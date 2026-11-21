#!/usr/bin/env bash
set -euo pipefail

# Detects which AI-DLC v2 harness the checkout embeds and exports its paths
# for the later steps of the aidlc_validate job.
#
# v2 splits the harness per tool (core/ is the shared source; each tool gets
# its own distributed tree):
#   - Claude Code: .claude/tools/ + aidlc/spaces/default/memory/
#   - Cursor:      .cursor/tools/ + aidlc/spaces/default/memory/
# .claude wins when both exist, matching the pre-orb template.

# Writes AIDLC_TOOLS / AIDLC_HARNESS exports for the detected harness.
#
# Arguments:
#   $1 - bash_env: file the exports are appended to (CircleCI's $BASH_ENV,
#        sourced at the start of every later step).
# Side effects:
#   Appends two export lines to $1 and prints the detected harness.
# Returns:
#   0 when a harness was found, 1 when neither tools directory exists.
detect_harness() {
  local bash_env="$1"
  local harness

  if [ -d .claude/tools ]; then
    harness=".claude"
  elif [ -d .cursor/tools ]; then
    harness=".cursor"
  else
    echo "No .claude/tools or .cursor/tools found. Is AI-DLC embedded in this repository?" >&2
    return 1
  fi

  {
    echo "export AIDLC_TOOLS=\"${harness}/tools\""
    echo "export AIDLC_HARNESS=\"${harness}\""
  } >> "${bash_env}"
  echo "Detected harness: ${harness}"
}

# Entry point when this script runs as a CircleCI `run` step.
#
# Arguments:
#   None. Reads BASH_ENV from the environment.
# Returns:
#   The exit status of detect_harness().
main() {
  if [ -z "${BASH_ENV:-}" ]; then
    echo "BASH_ENV is not set; cannot export the harness paths to later steps." >&2
    return 1
  fi
  detect_harness "${BASH_ENV}"
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
  main
fi
