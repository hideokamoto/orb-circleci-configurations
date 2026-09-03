#!/usr/bin/env bash
set -euo pipefail

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

cdk_synth() {
  local account_placeholder="$1"
  local region_placeholder="$2"
  local pkg_manager="$3"
  local synth_script="$4"

  export CDK_DEFAULT_ACCOUNT="${CDK_DEFAULT_ACCOUNT:-${account_placeholder}}"
  export CDK_DEFAULT_REGION="${CDK_DEFAULT_REGION:-${region_placeholder}}"

  "${pkg_manager}" run "${synth_script}"
}

main() {
  local account_placeholder region_placeholder synth_script

  account_placeholder="$(circleci env subst "${PARAM_ACCOUNT_PLACEHOLDER}")"
  region_placeholder="$(circleci env subst "${PARAM_REGION_PLACEHOLDER}")"
  synth_script="$(circleci env subst "${PARAM_SYNTH_SCRIPT}")"

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
