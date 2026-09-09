#!/bin/sh
set -eu

# cimg/base (and other job images) don't reliably put `circleci` on PATH —
# the CLI is provided at a fixed path. Call it via this variable rather
# than bare `circleci` so the command works regardless of PATH, and so
# BATS can redirect it to a stub. Override with $CIRCLECI_CLI for images
# that install it elsewhere.
CIRCLECI_CLI="${CIRCLECI_CLI:-/usr/bin/circleci}"

# send_sbom_to_port
#
# Role:
#   POST a CycloneDX SBOM file to a Port.io webhook ingest URL. Mirrors
#   the "Send SBOM to Port webhook" step in the migrated sbom-port.yaml:
#   fail fast when the webhook URL isn't configured, install curl on
#   demand for the alpine-based aquasec/trivy image, then POST with the
#   same retry/timeout behavior the source step used. Written in POSIX
#   sh (no bashisms, no `local`, no `pipefail`) because CircleCI falls
#   back to `/bin/sh -eo pipefail` on any job container without bash,
#   and this command's primary target, aquasec/trivy, is one such
#   alpine-based container; the orb command also pins `shell: /bin/sh`
#   so this always runs under sh, never an autodetected bash.
#
# Arguments:
#   None. Reads the orb command's parameters via the environment
#   variables the generated run step sets: PARAM_WEBHOOK_URL_ENV (name
#   of the env var holding the webhook URL), PARAM_SBOM_FILE (path to
#   the SBOM JSON file, resolved via `$CIRCLECI_CLI env subst`),
#   PARAM_RETRIES and PARAM_MAX_TIME (curl --retry / --max-time values).
#
# Returns / side effects:
#   Exits 1, after printing an error to stderr, when the environment
#   variable named by PARAM_WEBHOOK_URL_ENV is unset or empty. On the
#   success path, installs curl via `apk add --no-cache curl` if it is
#   missing from PATH, issues one HTTP POST of the SBOM file, and
#   returns curl's exit status.
send_sbom_to_port() {
    webhook_url_var="${PARAM_WEBHOOK_URL_ENV}"

    # POSIX sh has no bash-only "${!name}" indirect expansion. Build and
    # eval "webhook_url=${<name>-}" instead: pure shell builtins, so it
    # works identically under bash, dash, and busybox ash (no external
    # `printenv` dependency). webhook_url_var only ever holds the orb's
    # env_var_name-typed webhook_url_env parameter — a caller-configured
    # *variable name*, never free-form input — so this eval only ever
    # expands a variable reference; it never runs caller-supplied code.
    eval "webhook_url=\${${webhook_url_var}-}"

    if [ -z "${webhook_url}" ]; then
        echo "${webhook_url_var} is not set (expected from a \"port\" context)" >&2
        exit 1
    fi

    sbom_file="$("${CIRCLECI_CLI}" env subst "${PARAM_SBOM_FILE}")"

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
