#!/usr/bin/env bash
set -euo pipefail

# Runs `aidlc-utility.ts doctor` against an ephemeral copy of the harness.
#
# `init` is not used: it is an unimplemented stub as of aidlc 2.6.16.
# `doctor` needs both the harness tree and aidlc/spaces/default/memory/, so
# both are copied (aidlc/ only when present). Running against a copy keeps
# doctor from writing anything into the checkout.

# Copies the harness into a temporary project and runs doctor there.
#
# Arguments:
#   $1 - harness: the harness directory name (.claude or .cursor).
# Side effects:
#   Creates and removes a temporary directory; invokes bun.
# Returns:
#   The exit status of doctor, or 1 when the harness directory is missing.
run_doctor() {
  local harness="$1"
  local tmp status

  if [ ! -d "${harness}" ]; then
    echo "Harness directory ${harness} not found." >&2
    return 1
  fi

  tmp="$(mktemp -d)"
  cp -a "${harness}" "${tmp}/"
  if [ -d aidlc ]; then
    cp -a aidlc "${tmp}/"
  fi

  status=0
  bun "${tmp}/${harness}/tools/aidlc-utility.ts" doctor --project-dir "${tmp}" || status=$?
  rm -rf "${tmp}"
  return "${status}"
}

# Entry point when this script runs as a CircleCI `run` step.
#
# Arguments:
#   None. Reads AIDLC_HARNESS from the environment.
main() {
  if [ -z "${AIDLC_HARNESS:-}" ]; then
    echo "AIDLC_HARNESS is not set; run the harness detection step first." >&2
    return 1
  fi
  run_doctor "${AIDLC_HARNESS}"
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
  main
fi
