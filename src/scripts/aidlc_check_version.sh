#!/usr/bin/env bash
set -euo pipefail

# Reports the embedded AI-DLC version next to the version the aidlc_validate
# job was written against, and fails on a mismatch only when pinning is on.

# The build agent provides the `circleci` CLI at /usr/bin/circleci in every
# job regardless of image; call it by that path (as cdk_synth.sh does).
# Overridable so BATS can point it at a stub.
CIRCLECI_CLI="${CIRCLECI_CLI:-/usr/bin/circleci}"

# Returns 0 when a boolean value means "on".
#
# CircleCI renders a boolean parameter placed in `environment:` as "1" / "0",
# not "true" / "false"; both forms are accepted.
#
# Arguments:
#   $1 - value to test.
is_true() {
  case "${1:-}" in
    1 | true) return 0 ;;
    *) return 1 ;;
  esac
}

# Compares the embedded version with the expected one.
#
# Arguments:
#   $1 - actual: output of `aidlc-utility.ts version`.
#   $2 - expected: the version this job was validated against.
#   $3 - pin: "1"/"true" to fail on a mismatch.
# Side effects:
#   Prints both versions, and a hint when they differ.
# Returns:
#   1 when pinning is on and the versions differ, 0 otherwise.
check_version() {
  local actual="$1"
  local expected="$2"
  local pin="$3"

  echo "Embedded: ${actual}"
  echo "Template validated against: ${expected}"
  if [ "${actual}" = "${expected}" ]; then
    return 0
  fi
  if is_true "${pin}"; then
    echo "Version mismatch: update the embedded AI-DLC, or set expected_aidlc_version to ${actual}." >&2
    return 1
  fi
  echo "Version differs (not pinned; set pin_version: true to fail on a mismatch)."
}

# Entry point when this script runs as a CircleCI `run` step.
#
# Arguments:
#   None. Reads PARAM_EXPECTED_VERSION, PARAM_PIN_VERSION, AIDLC_TOOLS and the
#   legacy project switch AIDLC_PIN_VERSION from the environment.
# Returns:
#   1 when the version cannot be read or a pinned mismatch is found.
main() {
  local expected actual pin

  if [ -z "${AIDLC_TOOLS:-}" ]; then
    echo "AIDLC_TOOLS is not set; run the harness detection step first." >&2
    return 1
  fi
  expected="$("${CIRCLECI_CLI}" env subst "${PARAM_EXPECTED_VERSION}")"
  if ! actual="$(bun "${AIDLC_TOOLS}/aidlc-utility.ts" version)"; then
    echo "Could not read the embedded AI-DLC version (bun ${AIDLC_TOOLS}/aidlc-utility.ts version failed)." >&2
    return 1
  fi

  pin="${PARAM_PIN_VERSION:-0}"
  # Projects set up with the pre-orb template enable pinning with this
  # project environment variable; keep honoring it.
  if [ "${AIDLC_PIN_VERSION:-}" = "1" ]; then
    pin="1"
  fi

  check_version "${actual}" "${expected}" "${pin}"
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
  main
fi
