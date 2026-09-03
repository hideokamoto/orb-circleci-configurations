#!/usr/bin/env bash
set -euo pipefail

# cimg/base (and other minimal executors) do not put `circleci` on PATH; the
# CLI CircleCI's build agent provides for every job lives at the fixed path
# /usr/bin/circleci regardless of image. Call it by full path so this script
# does not depend on which (if any) CLI a given executor puts on PATH.
# Overridable so BATS can point it at a stub.
CIRCLECI_CLI="${CIRCLECI_CLI:-/usr/bin/circleci}"

# CDK synth against a placeholder AWS account/region, so a validate-style job
# (build + synth, no deploy) can succeed without real AWS credentials.
#
# CDK_DEFAULT_ACCOUNT / CDK_DEFAULT_REGION are only defaulted when unset: a
# real value already exported by a Context or Project env var (or set
# earlier in the job) always wins, so jobs that legitimately need a specific
# account/region are unaffected.
#
# If the CDK app defines a NodejsFunction, its devDependencies must include
# esbuild. With esbuild present locally, CDK bundles the function without
# Docker; without it, CDK falls back to bundling via `docker run`, and a job
# with no Docker daemon available fails with
# "Cannot connect to the Docker daemon".

# Runs the actual synth invocation, defaulting the CDK placeholder env vars
# only when they are not already set.
#
# Arguments:
#   $1 - account_placeholder: AWS account id to export as CDK_DEFAULT_ACCOUNT
#        when that variable is unset.
#   $2 - region_placeholder: AWS region to export as CDK_DEFAULT_REGION when
#        that variable is unset.
#   $3 - pkg_manager: executable name/path used to run the synth script
#        (e.g. "pnpm", "npm", "yarn").
#   $4 - synth_script: name of the package.json script to run.
# Side effects:
#   Exports CDK_DEFAULT_ACCOUNT and CDK_DEFAULT_REGION into the current shell
#   (only if unset), then execs "<pkg_manager> run <synth_script>".
# Returns:
#   The exit status of the "<pkg_manager> run <synth_script>" invocation.
cdk_synth() {
  local account_placeholder="$1"
  local region_placeholder="$2"
  local pkg_manager="$3"
  local synth_script="$4"

  export CDK_DEFAULT_ACCOUNT="${CDK_DEFAULT_ACCOUNT:-${account_placeholder}}"
  export CDK_DEFAULT_REGION="${CDK_DEFAULT_REGION:-${region_placeholder}}"

  "${pkg_manager}" run "${synth_script}"
}

# Entry point when this script runs as a CircleCI `run` step (not sourced
# for bats-core tests). Resolves the orb's PARAM_* environment variables
# (populated by the command's `environment:` block) into plain values and
# hands them to cdk_synth().
#
# Arguments:
#   None. Reads PARAM_ACCOUNT_PLACEHOLDER, PARAM_REGION_PLACEHOLDER,
#   PARAM_SYNTH_SCRIPT, and PARAM_PKG_MANAGER from the environment, and
#   resolves the string parameters via the full-path CircleCI CLI
#   ($CIRCLECI_CLI).
# Side effects:
#   Invokes "$CIRCLECI_CLI env subst" for each string parameter, then
#   delegates to cdk_synth(), which exports CDK_DEFAULT_ACCOUNT /
#   CDK_DEFAULT_REGION and runs the package manager's synth script.
# Returns:
#   The exit status of cdk_synth().
main() {
  local account_placeholder region_placeholder synth_script

  account_placeholder="$("${CIRCLECI_CLI}" env subst "${PARAM_ACCOUNT_PLACEHOLDER}")"
  region_placeholder="$("${CIRCLECI_CLI}" env subst "${PARAM_REGION_PLACEHOLDER}")"
  synth_script="$("${CIRCLECI_CLI}" env subst "${PARAM_SYNTH_SCRIPT}")"

  # PARAM_PKG_MANAGER is an orb `enum` parameter: its value is one of a
  # fixed set of literals resolved at pack time, never a pipeline
  # expression, so it needs no circleci env subst.
  cdk_synth "${account_placeholder}" "${region_placeholder}" "${PARAM_PKG_MANAGER}" "${synth_script}"
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
