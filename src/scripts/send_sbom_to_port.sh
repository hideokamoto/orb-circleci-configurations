#!/usr/bin/env bash
set -euo pipefail

# Posts a CycloneDX SBOM file to a Port.io webhook ingest URL. Mirrors the
# "Send SBOM to Port webhook" step in the migrated sbom-port.yaml: fail fast
# when the webhook URL isn't configured, install curl on demand for the
# alpine-based aquasec/trivy image, then POST with the same retry/timeout
# behavior the source step used.
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

main() {
    send_sbom_to_port
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
