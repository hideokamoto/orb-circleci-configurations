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

main() {
  local binfmt_image alpine_image builder_name smoke_test
  binfmt_image="$(circleci env subst "${PARAM_BINFMT_IMAGE}")"
  alpine_image="$(circleci env subst "${PARAM_ALPINE_IMAGE}")"
  builder_name="$(circleci env subst "${PARAM_BUILDER_NAME}")"
  smoke_test="${PARAM_SMOKE_TEST}"

  register_binfmt "${binfmt_image}"
  assert_arm64_emulation "${alpine_image}"
  ensure_buildx_builder "${builder_name}"
  install_cdk_docker_shim

  if [ "${smoke_test}" = "true" ]; then
    run_smoke_build "${alpine_image}"
  fi
}

register_binfmt() {
  local binfmt_image="$1"
  docker run --privileged --rm "${binfmt_image}" --install arm64
}

assert_arm64_emulation() {
  local alpine_image="$1"
  local arch
  arch="$(docker run --rm --platform linux/arm64 "${alpine_image}" uname -m)"
  if [ "${arch}" != "aarch64" ]; then
    echo "arm64 emulation check failed: expected aarch64, got '${arch}'" >&2
    exit 1
  fi
}

ensure_buildx_builder() {
  local builder_name="$1"
  docker buildx create --name "${builder_name}" --driver docker-container --use 2>/dev/null \
    || docker buildx use "${builder_name}"
  docker buildx inspect --bootstrap
}

install_cdk_docker_shim() {
  # CDK invokes `docker build` directly for DockerImageAsset; route that
  # invocation through buildx so cross-platform RUN steps work.
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

run_smoke_build() {
  # Reproduces CDK DockerImageAsset's failure mode: an arm64 `docker build`
  # with a RUN step. Catches a broken emulation/buildx setup here rather
  # than deep inside `cdk deploy`.
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
