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
# resolvable via PATH on any executor. Tests point the CIRCLECI_CLI
# environment variable at a stub so no real CLI call is made.
CIRCLECI_CLI="${CIRCLECI_CLI:-/usr/bin/circleci}"

# resolve_component_name: resolve the CircleCI Deploys component name from,
# in order: an explicit value (the command parameter, already env-subst'd by
# the caller), the DEPLOY_COMPONENT_NAME environment variable (settable at
# the CircleCI Project or Context level to override the default without
# editing config), and finally CIRCLE_PROJECT_REPONAME. Both
# deploy_marker_plan and deploy_marker_update use this so a standalone
# deploy_marker_update call (e.g. from a cancellation job running in a
# separate container) resolves the exact same component name that
# with_deploy_marker used to plan the release.
#
# Args:
#   $1 - explicit component name (already env-subst'd by the caller); may
#        be an empty string, in which case the environment-based fallbacks
#        below are used.
# Returns:
#   Prints the resolved component name to stdout (no trailing newline).
#   Always exits 0.
# Side effects:
#   None. Reads DEPLOY_COMPONENT_NAME and CIRCLE_PROJECT_REPONAME from the
#   environment but does not modify either.
resolve_component_name() {
  local param_value="$1"
  if [ -n "$param_value" ]; then
    printf '%s' "$param_value"
  else
    printf '%s' "${DEPLOY_COMPONENT_NAME:-${CIRCLE_PROJECT_REPONAME:-}}"
  fi
}

# deploy_marker_plan: plan a CircleCI Deploys release marker and move it
# into existence via `circleci run release plan`. Exports
# DEPLOY_COMPONENT_NAME and DEPLOY_NAME to $BASH_ENV once resolved, so later
# steps in the same job -- and any other job that recomputes the same
# "<component>-$CIRCLE_WORKFLOW_ID" formula, such as a deploy-cancellation
# job -- agree on the same marker identity.
#
# Args:
#   None. Reads the following environment variables (set by the calling
#   orb command as PARAM_* run-step environment):
#     PARAM_COMPONENT_NAME     - explicit component name override, or ""
#     PARAM_TARGET_VERSION     - explicit target version, or ""
#                                 (falls back to $CIRCLE_SHA1)
#     PARAM_ENVIRONMENT_NAME   - CircleCI Deploys environment name, or ""
#                                 (falls back to the literal "production")
#   Also reads DEPLOY_COMPONENT_NAME, CIRCLE_PROJECT_REPONAME,
#   CIRCLE_WORKFLOW_ID and CIRCLE_SHA1 from the ambient CircleCI job
#   environment, and CIRCLECI_CLI for the build-agent CLI path.
# Returns:
#   The exit status of the underlying
#   "$CIRCLECI_CLI run release plan ..." call.
# Side effects:
#   - Appends "export DEPLOY_COMPONENT_NAME=..." and
#     "export DEPLOY_NAME=..." lines to $BASH_ENV.
#   - Invokes $CIRCLECI_CLI twice for `env subst` (parameter
#     expansion) and once for `run release plan`.
deploy_marker_plan() {
  local param_component_name
  param_component_name="$("$CIRCLECI_CLI" env subst "${PARAM_COMPONENT_NAME:-}")"
  local component_name
  component_name="$(resolve_component_name "$param_component_name")"
  local deploy_name="${component_name}-${CIRCLE_WORKFLOW_ID}"

  echo "export DEPLOY_COMPONENT_NAME=\"${component_name}\"" >> "$BASH_ENV"
  echo "export DEPLOY_NAME=\"${deploy_name}\"" >> "$BASH_ENV"

  local param_target_version
  param_target_version="$("$CIRCLECI_CLI" env subst "${PARAM_TARGET_VERSION:-}")"
  local target_version="${param_target_version:-${CIRCLE_SHA1:-}}"

  local environment_name
  environment_name="$("$CIRCLECI_CLI" env subst "${PARAM_ENVIRONMENT_NAME:-production}")"

  "$CIRCLECI_CLI" run release plan "$deploy_name" \
    --environment-name="$environment_name" \
    --component-name="$component_name" \
    --target-version="$target_version"
}

# deploy_marker_update: update a CircleCI Deploys release marker's status
# via `circleci run release update`. Used for the RUNNING / SUCCESS / FAILED
# transitions inside with_deploy_marker, and standalone (via the
# deploy_marker_update command) by jobs such as a deploy-cancellation job
# that run outside a with_deploy_marker-wrapped job and therefore cannot
# rely on its $BASH_ENV exports.
#
# Args:
#   None. Reads the following environment variables (set by the calling
#   orb command as PARAM_* run-step environment):
#     PARAM_COMPONENT_NAME  - explicit component name override, or ""
#                              (ignored if DEPLOY_NAME is already exported)
#     PARAM_STATUS          - required; RUNNING/SUCCESS/FAILED/CANCELED
#     PARAM_FAILURE_REASON  - failure detail used only when
#                              PARAM_STATUS=FAILED, or ""
#                              (falls back to $FAILURE_REASON, then to the
#                              literal "Deployment failed")
#     PARAM_TOLERATE_MISSING - "true" to swallow a failing CLI call
#                               instead of propagating it; any other value
#                               (including unset) behaves as "false"
#   Also reads DEPLOY_NAME (if already exported by a preceding
#   deploy_marker_plan call in the same job), DEPLOY_COMPONENT_NAME,
#   CIRCLE_PROJECT_REPONAME, CIRCLE_WORKFLOW_ID and FAILURE_REASON from the
#   ambient CircleCI job environment, and CIRCLECI_CLI for the
#   build-agent CLI path.
# Returns:
#   0 if the underlying "$CIRCLECI_CLI run release update ..." call
#   succeeds, or if it fails and PARAM_TOLERATE_MISSING is "true" (the
#   failure is logged and swallowed). 1 if it fails and
#   PARAM_TOLERATE_MISSING is not "true".
# Side effects:
#   Invokes $CIRCLECI_CLI for `env subst` (when PARAM_STATUS=FAILED)
#   and once for `run release update`. Prints a message to stdout when a
#   failure is tolerated.
deploy_marker_update() {
  local param_component_name
  param_component_name="$("$CIRCLECI_CLI" env subst "${PARAM_COMPONENT_NAME:-}")"
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
    param_failure_reason="$("$CIRCLECI_CLI" env subst "${PARAM_FAILURE_REASON:-}")"
    # Falls back to $FAILURE_REASON (set by a preceding deploy step on
    # failure) and then to a literal default, matching the source behavior
    # of "${FAILURE_REASON:-Deployment failed}".
    local reason="${param_failure_reason:-${FAILURE_REASON:-Deployment failed}}"
    # Cap at 500 characters defensively rather than depending on
    # server-side truncation.
    reason="${reason:0:500}"
    args+=("--failure-reason=${reason}")
  fi

  if "$CIRCLECI_CLI" "${args[@]}"; then
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

# main: dispatch to the requested deploy-marker action.
#
# Args:
#   None. Reads PARAM_ACTION from the environment ("plan" or "update"); any
#   other PARAM_ACTION value (including unset/empty) is rejected.
# Returns:
#   The exit status of deploy_marker_plan or deploy_marker_update for a
#   recognized PARAM_ACTION. Exits 1 for an unrecognized PARAM_ACTION.
# Side effects:
#   Delegates to deploy_marker_plan or deploy_marker_update (see their
#   docstrings for the side effects each performs). Writes an error message
#   to stderr and exits the process for an unrecognized PARAM_ACTION.
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
