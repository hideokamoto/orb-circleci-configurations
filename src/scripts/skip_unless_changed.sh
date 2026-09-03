#!/usr/bin/env bash
set -euo pipefail

# Decide whether the rest of this job should run, based on which paths
# changed between a base and a head revision, and halt the job when it
# should not. Mirrors two guards that were duplicated across
# circleci-configurations:
#   - deployment/*.yaml: skip a deploy when only agent-skill/docs paths
#     changed (PARAM_MODE=skip_if_only_matches)
#   - validation/aidlc-skip-unrelated.yaml: skip validation unless
#     AI-DLC related paths changed (PARAM_MODE=skip_unless_matches)
#
# Fail-safe: whenever the base revision cannot be resolved, base and head
# are the same commit, or the diff between them is empty, this script lets
# the job continue instead of guessing wrong and skipping work that should
# have run.

# The standalone `circleci` CLI is not guaranteed to be on PATH — cimg/base
# (this orb's own base_pinned executor) does not ship it there, only the
# build-agent CLI CircleCI injects into every job at /usr/bin/circleci. Call
# through this variable instead of a bare `circleci` so a PATH lookup can
# never silently fail with "command not found" under `set -e`, and so BATS
# can point it at a stub instead of requiring a real circleci binary.
# (circleci-agent, used for `step halt` below, is a separate binary that
# CircleCI does put on PATH in every job, so it is called directly.)
CIRCLECI_CLI="${CIRCLECI_CLI:-/usr/bin/circleci}"

# Resolves the head revision to diff to: PARAM_HEAD_REVISION (subst'd, so a
# caller may pass a literal $VAR reference), or $CIRCLE_SHA1 when that
# parameter is empty. Takes no arguments. Prints the resolved revision to
# stdout; has no other side effects.
resolve_head() {
    local head
    head="$("$CIRCLECI_CLI" env subst "${PARAM_HEAD_REVISION}")"
    if [ -z "$head" ]; then
        head="${CIRCLE_SHA1:-}"
    fi
    printf '%s' "$head"
}

# Resolves PARAM_FALLBACK=deploy_tag: finds the most recent tag matching
# PARAM_DEPLOY_TAG_GLOB that is reachable from $HEAD (the commit a previous
# successful deploy tagged), after a best-effort tag fetch. Takes no
# arguments and reads the $HEAD global set by main. Prints nothing; sets
# the BASE and BASE_SOURCE globals as its side effect.
resolve_base_from_deploy_tag() {
    local glob tag
    glob="$("$CIRCLECI_CLI" env subst "${PARAM_DEPLOY_TAG_GLOB}")"
    # Deploy tags land on the default branch after this checkout was made;
    # fetch them before describing. Best-effort: an unreachable/read-only
    # remote should not fail the whole job here, it should just leave no
    # tag to describe.
    git fetch --tags --force --quiet origin || true
    tag="$(git describe --tags --abbrev=0 --match "$glob" "$HEAD" 2>/dev/null || true)"
    if [ -n "$tag" ]; then
        BASE="$(git rev-parse --verify --quiet "${tag}^{commit}" || true)"
        BASE_SOURCE="most recent deploy tag ${tag} (fallback: base_revision parameter was empty)"
    else
        BASE=""
        BASE_SOURCE="undetermined (base_revision parameter was empty and no deploy tag matching '${glob}' was found)"
    fi
}

# Resolves the base revision to diff from: PARAM_BASE_REVISION (subst'd)
# when non-empty, otherwise the strategy named by PARAM_FALLBACK
# (deploy_tag / parent_commit / none). Takes no arguments and reads the
# $HEAD global, which must already be set (resolve_base_from_deploy_tag
# needs it). Prints nothing; sets the BASE and BASE_SOURCE globals. Exits
# the script with status 1 if PARAM_FALLBACK is not one of the three known
# values.
resolve_base() {
    local base
    base="$("$CIRCLECI_CLI" env subst "${PARAM_BASE_REVISION}")"
    if [ -n "$base" ]; then
        BASE="$base"
        BASE_SOURCE="base_revision parameter"
        return 0
    fi

    case "$PARAM_FALLBACK" in
        deploy_tag)
            resolve_base_from_deploy_tag
            ;;
        parent_commit)
            BASE="$(git rev-parse --verify --quiet HEAD^1 || true)"
            BASE_SOURCE="HEAD^1 (fallback: base_revision parameter was empty)"
            ;;
        none)
            BASE=""
            BASE_SOURCE="not resolved (base_revision parameter was empty, fallback=none)"
            ;;
        *)
            echo "Unknown PARAM_FALLBACK: ${PARAM_FALLBACK}" >&2
            exit 1
            ;;
    esac
}

# Lists the paths that differ between $BASE and $HEAD (the globals set by
# resolve_base/resolve_head). Takes no arguments. Prints one changed path
# per line to stdout; has no other side effects.
changed_files() {
    git diff --name-only "$BASE" "$HEAD"
}

# Decides, from the changed paths on stdin (one per line) and
# PARAM_MODE/PARAM_PATTERN, whether the job should be halted.
# skip_if_only_matches halts only when every changed path matches pattern;
# skip_unless_matches halts only when no changed path matches pattern.
# Prints nothing. Returns (exits the function with) status 0 when the job
# should halt, 1 when it should continue; exits the whole script with
# status 1 if PARAM_MODE is not one of the two known values.
should_halt() {
    local pattern
    pattern="$("$CIRCLECI_CLI" env subst "${PARAM_PATTERN}")"
    case "$PARAM_MODE" in
        skip_if_only_matches)
            # Halt only when every changed path matches pattern, i.e. none
            # of them fail to match.
            if grep -qvE "$pattern"; then
                return 1
            fi
            return 0
            ;;
        skip_unless_matches)
            # Halt only when no changed path matches pattern.
            if grep -qE "$pattern"; then
                return 1
            fi
            return 0
            ;;
        *)
            echo "Unknown PARAM_MODE: ${PARAM_MODE}" >&2
            exit 1
            ;;
    esac
}

# Entry point: resolves head and base, logs the decision inputs, and either
# halts the job (circleci-agent step halt) or lets it continue, per the
# fail-safe rules described at the top of this file. Takes no arguments and
# reads the PARAM_* environment variables the orb command sets. Side
# effects: writes progress/decision output to stdout, and calls
# `circleci-agent step halt` when the skip condition is met.
main() {
    HEAD="$(resolve_head)"
    resolve_base

    if [ -z "$BASE" ] || [ "$BASE" = "$HEAD" ] || ! git cat-file -e "${BASE}" 2>/dev/null; then
        echo "Could not determine a base revision; continuing (fail-safe). base source: [${BASE_SOURCE}] base: [${BASE}] head: [${HEAD}]"
        return 0
    fi

    echo "Base revision: ${BASE} (source: ${BASE_SOURCE}) / Head revision: ${HEAD}"

    local changed
    changed="$(changed_files)"
    echo "Changed files:"
    printf '%s\n' "$changed"

    if [ -z "$changed" ]; then
        echo "No changed files between base and head; continuing (fail-safe)."
        return 0
    fi

    if printf '%s\n' "$changed" | should_halt; then
        echo "Changed files match the skip condition (mode=${PARAM_MODE}, pattern=${PARAM_PATTERN}); halting this job."
        circleci-agent step halt
    else
        echo "Changed files do not match the skip condition (mode=${PARAM_MODE}); continuing."
    fi
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
