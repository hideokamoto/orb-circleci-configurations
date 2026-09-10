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

# export_to_bash_env: append "export NAME=<value>" to $BASH_ENV, serializing
# the value with `printf %q` first so it survives a later
# `source "$BASH_ENV"` (run by every subsequent step in the job, in a fresh
# shell) unchanged -- instead of being re-interpreted as shell syntax if it
# contains quotes, `$`, backticks, whitespace or embedded newlines. A naive
# `echo "export NAME=\"$value\""` breaks (or, worse, executes part of the
# value) the moment $value contains a double quote or a `$(...)`/backtick
# command substitution.
#
# Args:
#   $1 - variable name to export (assumed to already be a valid shell
#        identifier; not validated here).
#   $2 - value to export, any string including one with shell-special
#        characters.
# Returns:
#   Always 0.
# Side effects:
#   Appends one line to $BASH_ENV.
export_to_bash_env() {
  local name="$1"
  local value="$2"
  printf 'export %s=%s\n' "$name" "$(printf '%q' "$value")" >> "$BASH_ENV"
}

# marker_missing_or_resolved: classify a failed
# `circleci run release update` call's combined stdout+stderr output as
# either "the release marker is missing or was already resolved" (safe to
# tolerate -- see the PARAM_TOLERATE_MISSING handling in
# deploy_marker_update) or some other failure that must propagate instead
# of being swallowed (authentication, connectivity, a malformed request,
# etc.). The build-agent CLI's exact error text for a missing/resolved
# release is not documented, so this matches conservatively on a set of
# case-insensitive substrings that describe absence or a prior resolution;
# anything that does not match one of them -- including a failure with no
# output at all -- is treated as NOT tolerable, matching the "don't swallow
# unrelated failures" requirement this function exists to enforce.
#
# Args:
#   $1 - the CLI call's combined stdout+stderr output (may be empty).
# Returns:
#   0 if the output indicates a missing or already-resolved marker
#   (tolerate). 1 otherwise (propagate), including for empty output.
# Side effects:
#   None.
marker_missing_or_resolved() {
  local output_lower
  output_lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$output_lower" in
    *"not found"*|*"no release"*|*"no such release"*|*"does not exist"*|*"already resolved"*|*"already exists with status"*|*"already in a terminal state"*|*"already terminal"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

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
#     "export DEPLOY_NAME=..." lines to $BASH_ENV via export_to_bash_env,
#     which `printf %q`-serializes each value first so a component name
#     containing shell-special characters survives a later `source
#     "$BASH_ENV"` unchanged.
#   - Invokes $CIRCLECI_CLI twice for `env subst` (parameter
#     expansion) and once for `run release plan`.
deploy_marker_plan() {
  local param_component_name
  param_component_name="$("$CIRCLECI_CLI" env subst "${PARAM_COMPONENT_NAME:-}")"
  local component_name
  component_name="$(resolve_component_name "$param_component_name")"
  local deploy_name="${component_name}-${CIRCLE_WORKFLOW_ID}"

  export_to_bash_env DEPLOY_COMPONENT_NAME "$component_name"
  export_to_bash_env DEPLOY_NAME "$deploy_name"

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
#     PARAM_TOLERATE_MISSING - "true" to swallow a failing CLI call whose
#                               output indicates the release marker is
#                               missing or was already resolved (see
#                               marker_missing_or_resolved); any other
#                               value (including unset) behaves as "false".
#                               A CLI failure whose output does NOT match
#                               that pattern (authentication, connectivity,
#                               a malformed request, etc.) always
#                               propagates, regardless of this parameter.
#   Also reads DEPLOY_NAME (if already exported by a preceding
#   deploy_marker_plan call in the same job), DEPLOY_COMPONENT_NAME,
#   CIRCLE_PROJECT_REPONAME, CIRCLE_WORKFLOW_ID and FAILURE_REASON from the
#   ambient CircleCI job environment, and CIRCLECI_CLI for the
#   build-agent CLI path.
# Returns:
#   0 if the underlying "$CIRCLECI_CLI run release update ..." call
#   succeeds, or if it fails, PARAM_TOLERATE_MISSING is "true", and the
#   call's output indicates the marker is missing or already resolved (see
#   marker_missing_or_resolved) -- that failure is logged and swallowed.
#   1 if the call fails and either PARAM_TOLERATE_MISSING is not "true", or
#   the output does not match that missing/already-resolved pattern (an
#   unrelated failure -- authentication, connectivity, a malformed
#   request, etc. -- is never swallowed, even with tolerate_missing set).
# Side effects:
#   Invokes $CIRCLECI_CLI for `env subst` (when PARAM_STATUS=FAILED)
#   and once for `run release update`, capturing its combined
#   stdout+stderr so the output can be classified. That output is always
#   echoed afterwards (to stdout on success, to stderr on failure) so it
#   still reaches the job log. Prints an additional message to stdout when
#   a failure is tolerated.
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

  # Capture the call's combined stdout+stderr instead of letting it stream
  # directly: PARAM_TOLERATE_MISSING (below) needs to inspect the output to
  # decide whether this failure is safe to swallow. The output is still
  # surfaced afterwards either way, so nothing is lost from the job log.
  local cli_output cli_status
  cli_status=0
  cli_output="$("$CIRCLECI_CLI" "${args[@]}" 2>&1)" || cli_status=$?

  if [ "$cli_status" -eq 0 ]; then
    if [ -n "$cli_output" ]; then
      printf '%s\n' "$cli_output"
    fi
    return 0
  fi

  if [ -n "$cli_output" ]; then
    printf '%s\n' "$cli_output" >&2
  fi

  # cancel-deploy also runs on requires:[failed], so the deploy job's own
  # on_fail step may have already resolved the marker to FAILED (or the
  # marker may never have been planned at all, e.g. the deploy job failed
  # before reaching deploy_marker_plan). tolerate_missing lets a caller
  # accept that specific race/absence instead of failing its own step --
  # but only when the CLI's own output confirms that's what happened.
  # Any other failure (auth, connectivity, a malformed request, ...) must
  # still propagate: swallowing those unconditionally would hide real
  # problems behind a misleading "nothing to reconcile" success.
  if [ "${PARAM_TOLERATE_MISSING:-false}" = "true" ] && marker_missing_or_resolved "$cli_output"; then
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
