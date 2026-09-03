#!/usr/bin/env bash
# Bootstraps cross-architecture Docker builds on an amd64 remote-docker
# executor: registers QEMU/binfmt arm64 emulation, asserts the emulation
# produces an aarch64 userland, creates (or reuses) a `docker buildx`
# builder, and installs a `CDK_DOCKER` shim that routes `docker build`
# through `docker buildx build --load`.
#
# Ported from the canonical
# workflows/deployment/snippets/cdk-arm64-docker-setup.sh in the source
# repo (previously duplicated across aws-cdk-arm64.yaml and
# aws-cdkd-arm64.yaml and kept in sync by a grep-based validator script;
# this command makes both the duplication and the validator unnecessary).
#
# Scope limit: the CDK_DOCKER shim only intercepts `docker build`
# invocations. It does NOT cover `docker run -v <asset>:/asset-input ...`
# bind-mount style builds (how CDK's NodejsFunction bundling invokes
# Docker) -- see the command description for detail.
set -euo pipefail

# The `circleci` CLI is not on PATH on every executor image (notably
# cimg/base, which only provides it at /usr/bin/circleci). Resolve the
# binary path once, defaulting to that full path, but let a caller (or a
# test) override it via the CIRCLECI_CLI environment variable.
CIRCLECI_CLI="${CIRCLECI_CLI:-/usr/bin/circleci}"

# Entry point: resolves the PARAM_* environment variables the command
# passes in, then runs the full bootstrap sequence (binfmt registration,
# emulation assertion, buildx bootstrap, CDK_DOCKER shim install, and an
# optional smoke build) in order.
# Arguments:
#   None (reads PARAM_BINFMT_IMAGE, PARAM_ALPINE_IMAGE, PARAM_BUILDER_NAME,
#   and PARAM_SMOKE_TEST from the environment; resolves image/builder
#   parameters via the CIRCLECI_CLI binary set at the top of this file).
# Returns:
#   0 on success. Exits non-zero (via `set -e` or an explicit `exit 1` in
#   assert_arm64_emulation) if any step fails.
# Side effects:
#   See the side effects of each function it calls below.
main() {
  local binfmt_image alpine_image builder_name smoke_test
  binfmt_image="$("${CIRCLECI_CLI}" env subst "${PARAM_BINFMT_IMAGE}")"
  alpine_image="$("${CIRCLECI_CLI}" env subst "${PARAM_ALPINE_IMAGE}")"
  builder_name="$("${CIRCLECI_CLI}" env subst "${PARAM_BUILDER_NAME}")"
  smoke_test="${PARAM_SMOKE_TEST}"

  register_binfmt "${binfmt_image}"
  assert_arm64_emulation "${alpine_image}"
  ensure_buildx_builder "${builder_name}"
  install_cdk_docker_shim

  if [ "${smoke_test}" = "true" ]; then
    run_smoke_build "${alpine_image}"
  fi
}

# Registers arm64 QEMU/binfmt emulation with the host's binfmt_misc
# handlers by running the `tonistiigi/binfmt` installer image, so that a
# subsequent `docker run --platform linux/arm64 ...` (or an arm64
# `docker build`) transparently executes under emulation.
# Arguments:
#   $1 - the pinned `tonistiigi/binfmt` image reference to run.
# Returns:
#   0 on success; the calling shell exits non-zero (via `set -e`) if the
#   `docker run` invocation fails.
# Side effects:
#   Runs a `--privileged` container that registers arm64 binfmt handlers
#   on the host kernel. No files are written and no environment variables
#   are exported.
register_binfmt() {
  local binfmt_image="$1"
  docker run --privileged --rm "${binfmt_image}" --install arm64
}

# Verifies binfmt registration actually produces an aarch64 userland by
# running `uname -m` inside an arm64 container and checking the result,
# so a broken/missing emulation setup fails here rather than deep inside
# a later `cdk deploy`.
# Arguments:
#   $1 - image reference to run the `uname -m` check against (must be
#        multi-arch and provide an arm64 variant).
# Returns:
#   0 if the reported architecture is exactly "aarch64". Exits 1 (via an
#   explicit `exit`, printing a diagnostic to stderr) on any mismatch.
# Side effects:
#   Runs one throwaway `docker run --rm` container. Writes an error
#   message to stderr on failure; writes nothing on success.
assert_arm64_emulation() {
  local alpine_image="$1"
  local arch
  arch="$(docker run --rm --platform linux/arm64 "${alpine_image}" uname -m)"
  if [ "${arch}" != "aarch64" ]; then
    echo "arm64 emulation check failed: expected aarch64, got '${arch}'" >&2
    exit 1
  fi
}

# Creates a `docker-container`-driven buildx builder with the given name
# and makes it current, or falls back to reusing an existing builder of
# the same name (idempotent across repeated invocations in the same
# job), then bootstraps it so it is ready to build.
# Arguments:
#   $1 - name of the buildx builder to create or reuse.
# Returns:
#   0 on success; the calling shell exits non-zero (via `set -e`) if
#   neither `buildx create` nor the `buildx use` fallback succeeds, or if
#   `buildx inspect --bootstrap` fails.
# Side effects:
#   Creates (or selects) a buildx builder instance as docker daemon/CLI
#   state; may pull a bootstrap image on first use. No files are written
#   and no environment variables are exported.
ensure_buildx_builder() {
  local builder_name="$1"
  docker buildx create --name "${builder_name}" --driver docker-container --use 2>/dev/null \
    || docker buildx use "${builder_name}"
  docker buildx inspect --bootstrap
}

# Writes an executable `docker` shim to /tmp/cdk-docker that rewrites a
# `build` invocation into `docker buildx build --load` (so cross-platform
# RUN steps work) and passes every other subcommand straight through to
# the real `docker` binary, then exports CDK_DOCKER (pointing at the
# shim) and DOCKER_BUILDKIT=1 to $BASH_ENV so later steps in the same
# job pick them up. AWS CDK's DockerImageAsset invokes `docker` directly
# and honors the CDK_DOCKER environment variable to redirect that
# invocation, which is what makes the shim work without patching CDK.
# Arguments:
#   None.
# Returns:
#   0 on success; the calling shell exits non-zero (via `set -e`) if
#   writing/chmod'ing the shim file fails.
# Side effects:
#   Writes an executable file to /tmp/cdk-docker (overwriting any prior
#   copy). Appends two `export` lines to $BASH_ENV, which take effect for
#   every subsequent `run` step in the same CircleCI job.
install_cdk_docker_shim() {
  # shellcheck disable=SC2016
  # These single-quoted lines are the literal shim script body being
  # written to disk -- they must NOT expand here; they expand later, when
  # the shim itself runs.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ "${1:-}" == "build" ]]; then' \
    '  exec docker buildx build --load "${@:2}"' \
    'fi' \
    'exec docker "$@"' \
    > /tmp/cdk-docker
  chmod +x /tmp/cdk-docker
  echo 'export CDK_DOCKER=/tmp/cdk-docker' >> "$BASH_ENV"
  echo 'export DOCKER_BUILDKIT=1' >> "$BASH_ENV"
}

# Builds and immediately removes a throwaway single-RUN-step arm64 image,
# reproducing CDK DockerImageAsset's failure mode (an arm64 `docker
# build` with a RUN step) so a broken emulation/buildx setup is caught
# here rather than deep inside a later `cdk deploy`. Only invoked from
# main() when the smoke_test parameter is true.
# Arguments:
#   $1 - base image to use as the smoke-test Dockerfile's FROM line
#        (must provide an arm64 variant).
# Returns:
#   0 on success; the calling shell exits non-zero (via `set -e`) if
#   either the `docker build` or `docker rmi` fails.
# Side effects:
#   Creates a temporary directory (via `mktemp -d`) containing a
#   generated Dockerfile, which is left on disk. Builds and then removes
#   a local image tagged `cdk-arm64-smoke`.
run_smoke_build() {
  local alpine_image="$1"
  local smoke_dir
  smoke_dir="$(mktemp -d)"
  printf '%s\n' \
    "FROM ${alpine_image}" \
    'RUN uname -m | grep -q aarch64' \
    > "${smoke_dir}/Dockerfile"
  docker build --platform linux/arm64 -t cdk-arm64-smoke "${smoke_dir}"
  docker rmi cdk-arm64-smoke
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
