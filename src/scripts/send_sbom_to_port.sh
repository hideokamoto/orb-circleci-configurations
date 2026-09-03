#!/usr/bin/env bash
set -euo pipefail

# send_sbom_to_port
#
# Role:
#   POST a CycloneDX SBOM file to a Port.io webhook ingest URL. Mirrors
#   the "Send SBOM to Port webhook" step in the migrated sbom-port.yaml:
#   fail fast when the webhook URL isn't configured, install curl on
#   demand for the alpine-based aquasec/trivy image, then POST with the
#   same retry/timeout behavior the source step used.
#
# Arguments:
#   None. Reads the orb command's parameters via the environment
#   variables the generated run step sets: PARAM_WEBHOOK_URL_ENV (name
#   of the env var holding the webhook URL), PARAM_SBOM_FILE (path to
#   the SBOM JSON file, resolved via `circleci env subst`),
#   PARAM_RETRIES and PARAM_MAX_TIME (curl --retry / --max-time values).
#
# Returns / side effects:
#   Exits 1, after printing an error to stderr, when the environment
#   variable named by PARAM_WEBHOOK_URL_ENV is unset or empty. On the
#   success path, installs curl via `apk add --no-cache curl` if it is
#   missing from PATH, issues one HTTP POST of the SBOM file, and
#   returns curl's exit status.
send_sbom_to_port() {
    local webhook_url_var="${PARAM_WEBHOOK_URL_ENV}"
    local webhook_url="${!webhook_url_var:-}"

    if [ -z "${webhook_url}" ]; then
        echo "${webhook_url_var} is not set (expected from a \"port\" context)" >&2
        exit 1
    fi

    local sbom_file
    sbom_file="$(circleci env subst "${PARAM_SBOM_FILE}")"

    # trivy's aquasec/trivy image is alpine-based and doesn't ship curl.
    command -v curl >/dev/null 2>&1 || apk add --no-cache curl

    curl --fail-with-body -sS \
        --connect-timeout 10 \
        --max-time "${PARAM_MAX_TIME}" \
        --retry "${PARAM_RETRIES}" \
        --retry-delay 2 \
        -X POST \
        -H "Content-Type: application/json" \
        --data-binary @"${sbom_file}" \
        "${webhook_url}"
}

# main
#
# Role:
#   Entry point run when this script is executed directly (as opposed
#   to being sourced by bats-core for unit tests). Delegates to
#   send_sbom_to_port.
#
# Arguments:
#   None.
#
# Returns / side effects:
#   Same as send_sbom_to_port: exits 1 on a missing/empty webhook URL,
#   otherwise returns curl's exit status.
main() {
    send_sbom_to_port
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
