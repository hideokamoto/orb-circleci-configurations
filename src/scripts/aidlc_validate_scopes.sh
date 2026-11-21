#!/usr/bin/env bash
set -euo pipefail

# Runs `aidlc-graph.ts validate-scope` for every scope, without stopping at
# the first failure, so one run reports every broken scope.

# Overridable so BATS can point it at a stub.
CIRCLECI_CLI="${CIRCLECI_CLI:-/usr/bin/circleci}"

# Validates each scope in turn.
#
# Arguments:
#   $1 - tools_dir: the harness tools directory (e.g. .claude/tools).
#   $2 - scopes: space-separated scope names.
# Side effects:
#   Invokes bun once per scope and prints a header per scope.
# Returns:
#   1 when any scope failed or no scope was given, 0 otherwise.
validate_scopes() {
  local tools_dir="$1"
  local scopes_raw="$2"
  local scopes=()
  local failed=()
  local s

  read -r -a scopes <<< "${scopes_raw}"
  if [ "${#scopes[@]}" -eq 0 ]; then
    echo "No scopes given; set the scopes parameter." >&2
    return 1
  fi

  for s in "${scopes[@]}"; do
    echo "--- validate-scope: ${s} ---"
    if ! bun "${tools_dir}/aidlc-graph.ts" validate-scope "${s}"; then
      failed+=("${s}")
    fi
  done

  if [ "${#failed[@]}" -gt 0 ]; then
    echo "validate-scope failed for: ${failed[*]}" >&2
    return 1
  fi
  echo "All ${#scopes[@]} scopes are valid."
}

# Entry point when this script runs as a CircleCI `run` step.
#
# Arguments:
#   None. Reads PARAM_SCOPES and AIDLC_TOOLS from the environment.
# Returns:
#   The exit status of validate_scopes().
main() {
  local scopes

  if [ -z "${AIDLC_TOOLS:-}" ]; then
    echo "AIDLC_TOOLS is not set; run the harness detection step first." >&2
    return 1
  fi
  scopes="$("${CIRCLECI_CLI}" env subst "${PARAM_SCOPES}")"
  validate_scopes "${AIDLC_TOOLS}" "${scopes}"
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
  main
fi
