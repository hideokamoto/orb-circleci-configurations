#!/usr/bin/env bash
set -euo pipefail

# Deploy markers (CircleCI Deploys "release" records) are managed through
# `circleci run release ...`, a subcommand that exists only in the
# build-agent CLI CircleCI injects into every job at /usr/bin/circleci.
# cimg/* convenience images that bundle a *local* circleci CLI (e.g. for
# `circleci config validate`) put that copy earlier on PATH, and it has no
# `release` plugin -- an unqualified `circleci run release ...` would
# resolve to that shadowing binary and fail. cimg/base goes further and
# ships no `circleci` on PATH at all (only /usr/bin/circleci, injected by
# the job runner itself, exists there). We therefore call the build-agent
# CLI by its full path everywhere in this script -- including for
# `env subst`, so this script has no dependency on `circleci` being
# resolvable via PATH on any executor. Tests point the DEPLOY_MARKER_CLI
# environment variable at a stub so no real CLI call is made.
DEPLOY_MARKER_CLI="${DEPLOY_MARKER_CLI:-/usr/bin/circleci}"

# Resolves the CircleCI Deploys component name from, in order: an explicit
# value (the command parameter, already env-subst'd by the caller), the
# DEPLOY_COMPONENT_NAME environment variable (settable at the CircleCI
# Project or Context level to override the default without editing config),
# and finally CIRCLE_PROJECT_REPONAME. Both deploy_marker_plan and
# deploy_marker_update use this so a standalone deploy_marker_update call
# (e.g. from a cancellation job running in a separate container) resolves
# the exact same component name that with_deploy_marker used to plan the
# release.
resolve_component_name() {
  local param_value="$1"
  if [ -n "$param_value" ]; then
    printf '%s' "$param_value"
  else
    printf '%s' "${DEPLOY_COMPONENT_NAME:-${CIRCLE_PROJECT_REPONAME:-}}"
  fi
}

# Plans a release marker and moves it into existence. Exports
# DEPLOY_COMPONENT_NAME and DEPLOY_NAME to $BASH_ENV once resolved, so later
# steps in the same job -- and any other job that recomputes the same
# "<component>-$CIRCLE_WORKFLOW_ID" formula, such as a deploy-cancellation
# job -- agree on the same marker identity.
deploy_marker_plan() {
  local param_component_name
  param_component_name="$("$DEPLOY_MARKER_CLI" env subst "${PARAM_COMPONENT_NAME:-}")"
  local component_name
  component_name="$(resolve_component_name "$param_component_name")"
  local deploy_name="${component_name}-${CIRCLE_WORKFLOW_ID}"

  echo "export DEPLOY_COMPONENT_NAME=\"${component_name}\"" >> "$BASH_ENV"
  echo "export DEPLOY_NAME=\"${deploy_name}\"" >> "$BASH_ENV"

  local param_target_version
  param_target_version="$("$DEPLOY_MARKER_CLI" env subst "${PARAM_TARGET_VERSION:-}")"
  local target_version="${param_target_version:-${CIRCLE_SHA1:-}}"

  local environment_name
  environment_name="$("$DEPLOY_MARKER_CLI" env subst "${PARAM_ENVIRONMENT_NAME:-production}")"

  "$DEPLOY_MARKER_CLI" run release plan "$deploy_name" \
    --environment-name="$environment_name" \
    --component-name="$component_name" \
    --target-version="$target_version"
}

# Updates a release marker's status. Used for the RUNNING / SUCCESS / FAILED
# transitions inside with_deploy_marker, and standalone (via the
# deploy_marker_update command) by jobs such as a deploy-cancellation job
# that run outside a with_deploy_marker-wrapped job and therefore cannot
# rely on its $BASH_ENV exports.
deploy_marker_update() {
  local param_component_name
  param_component_name="$("$DEPLOY_MARKER_CLI" env subst "${PARAM_COMPONENT_NAME:-}")"
  local component_name
  component_name="$(resolve_component_name "$param_component_name")"
  # Prefer an already-exported DEPLOY_NAME (set by deploy_marker_plan earlier
  # in the same job); fall back to recomputing it with the same formula for
  # a standalone call in a fresh container.
  local deploy_name="${DEPLOY_NAME:-${component_name}-${CIRCLE_WORKFLOW_ID}}"

  local status
  status="${PARAM_STATUS:?PARAM_STATUS is required}"

  local args=(run release update "$deploy_name" "--status=${status}")

  if [ "$status" = "FAILED" ]; then
    local param_failure_reason
    param_failure_reason="$("$DEPLOY_MARKER_CLI" env subst "${PARAM_FAILURE_REASON:-}")"
    # Falls back to $FAILURE_REASON (set by a preceding deploy step on
    # failure) and then to a literal default, matching the source behavior
    # of "${FAILURE_REASON:-Deployment failed}".
    local reason="${param_failure_reason:-${FAILURE_REASON:-Deployment failed}}"
    # Cap at 500 characters defensively rather than depending on
    # server-side truncation.
    reason="${reason:0:500}"
    args+=("--failure-reason=${reason}")
  fi

  if "$DEPLOY_MARKER_CLI" "${args[@]}"; then
    return 0
  fi

  # cancel-deploy also runs on requires:[failed], so the deploy job's own
  # on_fail step may have already resolved the marker to FAILED (or the
  # marker may never have been planned at all, e.g. the deploy job failed
  # before reaching deploy_marker_plan). tolerate_missing lets a caller
  # accept that race/absence instead of failing its own step.
  if [ "${PARAM_TOLERATE_MISSING:-false}" = "true" ]; then
    echo "marker already resolved or not found -- nothing to reconcile"
    return 0
  fi

  return 1
}

main() {
  case "${PARAM_ACTION:-}" in
    plan)
      deploy_marker_plan
      ;;
    update)
      deploy_marker_update
      ;;
    *)
      echo "deploy_marker.sh: unknown PARAM_ACTION '${PARAM_ACTION:-}' (expected 'plan' or 'update')" >&2
      exit 1
      ;;
  esac
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
