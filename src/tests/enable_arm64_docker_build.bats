#!/usr/bin/env bats
# Unit tests for scripts/enable_arm64_docker_build.sh.
#
# `docker` and `circleci` are stubbed via a PATH-prepended fixture
# directory so the test never touches a real Docker daemon or performs a
# real `circleci env subst` network round-trip. The docker stub records
# every invocation (one line per call, space-joined args) to CALL_LOG so
# tests can assert both the call order and the exact arguments used.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  SCRIPT="${REPO_ROOT}/src/scripts/enable_arm64_docker_build.sh"

  TEST_DIR="$(mktemp -d)"
  STUB_BIN="${TEST_DIR}/bin"
  mkdir -p "${STUB_BIN}"
  CALL_LOG="${TEST_DIR}/calls.log"
  : > "${CALL_LOG}"

  BASH_ENV="${TEST_DIR}/bash_env"
  : > "${BASH_ENV}"
  export BASH_ENV

  # docker stub: logs "docker <args...>" per call. Fails (exit 1) only
  # when DOCKER_FAIL_ON matches the first argument, so a single test can
  # exercise a failure path (e.g. buildx create already exists).
  cat > "${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "${CALL_LOG}"
case "$1" in
  run)
    # `docker run --rm --platform linux/arm64 <image> uname -m` must
    # report aarch64 so the emulation assertion in the script passes.
    for a in "$@"; do :; done
    if [[ "$*" == *"uname -m"* ]]; then
      echo "aarch64"
    fi
    ;;
  buildx)
    if [[ "$2" == "create" && -n "${DOCKER_BUILDX_CREATE_FAILS:-}" ]]; then
      exit 1
    fi
    ;;
esac
exit 0
EOF
  chmod +x "${STUB_BIN}/docker"

  # circleci stub: `circleci env subst <string>` performs real shell
  # variable substitution so parameter defaults (which contain no $VAR
  # references in these tests) pass through unchanged.
  cat > "${STUB_BIN}/circleci" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "env" && "$2" == "subst" ]]; then
  eval "echo \"$3\""
  exit 0
fi
exit 1
EOF
  chmod +x "${STUB_BIN}/circleci"

  export CALL_LOG
  export PATH="${STUB_BIN}:${PATH}"

  export PARAM_BINFMT_IMAGE="tonistiigi/binfmt:qemu-v9.2.2"
  export PARAM_ALPINE_IMAGE="alpine:3.21"
  export PARAM_BUILDER_NAME="cdk-multiarch"
  export PARAM_SMOKE_TEST="true"
}

teardown() {
  rm -rf "${TEST_DIR}"
}

@test "registers binfmt, asserts emulation, and bootstraps buildx in order" {
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]

  # First real docker invocation must be the binfmt installer.
  first_line="$(sed -n '1p' "${CALL_LOG}")"
  [[ "${first_line}" == "docker run --privileged --rm tonistiigi/binfmt:qemu-v9.2.2 --install arm64" ]]

  # Second must be the arm64 emulation assertion against the alpine image.
  second_line="$(sed -n '2p' "${CALL_LOG}")"
  [[ "${second_line}" == "docker run --rm --platform linux/arm64 alpine:3.21 uname -m" ]]

  # Then buildx create followed by inspect --bootstrap, using the
  # parameterized builder name.
  grep -qx "docker buildx create --name cdk-multiarch --driver docker-container --use" "${CALL_LOG}"
  grep -qx "docker buildx inspect --bootstrap" "${CALL_LOG}"

  create_line=$(grep -n "buildx create" "${CALL_LOG}" | cut -d: -f1)
  inspect_line=$(grep -n "buildx inspect --bootstrap" "${CALL_LOG}" | cut -d: -f1)
  [ "${create_line}" -lt "${inspect_line}" ]
}

@test "falls back to buildx use when a builder with the same name already exists" {
  export DOCKER_BUILDX_CREATE_FAILS=1

  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]

  grep -qx "docker buildx use cdk-multiarch" "${CALL_LOG}"
}

@test "exports CDK_DOCKER shim and DOCKER_BUILDKIT to BASH_ENV" {
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]

  grep -qx 'export CDK_DOCKER=/tmp/cdk-docker' "${BASH_ENV}"
  grep -qx 'export DOCKER_BUILDKIT=1' "${BASH_ENV}"

  [ -x /tmp/cdk-docker ]
  # The shim must route `docker build` through `docker buildx build --load`
  # and pass every other subcommand straight through to `docker`.
  grep -q "if \[\[ \"\${1:-}\" == \"build\" \]\]; then" /tmp/cdk-docker
  grep -q "exec docker buildx build --load" /tmp/cdk-docker
  grep -q 'exec docker "\$@"' /tmp/cdk-docker

  rm -f /tmp/cdk-docker
}

@test "runs an arm64 smoke build after the shim is installed when smoke_test is true" {
  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]

  grep -q "^docker build --platform linux/arm64 -t cdk-arm64-smoke" "${CALL_LOG}"
  grep -qx "docker rmi cdk-arm64-smoke" "${CALL_LOG}"

  shim_line=$(grep -n "export CDK_DOCKER" "${BASH_ENV}" | cut -d: -f1)
  [ -n "${shim_line}" ]
  smoke_build_line=$(grep -n "^docker build --platform linux/arm64 -t cdk-arm64-smoke" "${CALL_LOG}" | cut -d: -f1)
  [ -n "${smoke_build_line}" ]
}

@test "skips the smoke build when smoke_test is false" {
  export PARAM_SMOKE_TEST="false"

  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]

  ! grep -q "^docker build --platform linux/arm64 -t cdk-arm64-smoke" "${CALL_LOG}"
  ! grep -qx "docker rmi cdk-arm64-smoke" "${CALL_LOG}"

  # The shim itself is still installed regardless of smoke_test.
  grep -qx 'export CDK_DOCKER=/tmp/cdk-docker' "${BASH_ENV}"
}

@test "fails fast when the emulated architecture is not aarch64" {
  # Override the docker stub's `run` handling for this one test so the
  # emulation check reports the wrong architecture.
  cat > "${STUB_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "${CALL_LOG}"
if [[ "$*" == *"uname -m"* ]]; then
  echo "x86_64"
  exit 0
fi
exit 0
EOF
  chmod +x "${STUB_BIN}/docker"

  run bash "${SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" == *"arm64 emulation check failed"* ]]

  # Must fail before touching buildx.
  ! grep -q "buildx" "${CALL_LOG}"
}

@test "resolves image parameters through circleci env subst" {
  export PARAM_ALPINE_IMAGE='${CUSTOM_ALPINE_IMAGE}'
  export CUSTOM_ALPINE_IMAGE="alpine:3.20"

  run bash "${SCRIPT}"
  [ "$status" -eq 0 ]

  grep -qx "docker run --rm --platform linux/arm64 alpine:3.20 uname -m" "${CALL_LOG}"
}
