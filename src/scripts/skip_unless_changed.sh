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

resolve_head() {
    local head
    head="$(circleci env subst "${PARAM_HEAD_REVISION}")"
    if [ -z "$head" ]; then
        head="${CIRCLE_SHA1:-}"
    fi
    printf '%s' "$head"
}

# Sets the BASE and BASE_SOURCE globals.
resolve_base_from_deploy_tag() {
    local glob tag
    glob="$(circleci env subst "${PARAM_DEPLOY_TAG_GLOB}")"
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

# Sets the BASE and BASE_SOURCE globals. Requires HEAD to already be set.
resolve_base() {
    local base
    base="$(circleci env subst "${PARAM_BASE_REVISION}")"
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

# Echoes 1 changed path per line.
changed_files() {
    git diff --name-only "$BASE" "$HEAD"
}

# Returns 0 (true) when the changed paths mean this job should halt, 1
# (false) when it should continue. Expects the changed paths on stdin.
should_halt() {
    local pattern
    pattern="$(circleci env subst "${PARAM_PATTERN}")"
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
