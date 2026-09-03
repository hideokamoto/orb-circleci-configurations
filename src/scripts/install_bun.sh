#!/usr/bin/env bash
# Installs a pinned bun toolchain, matching the install/verify/reinstall
# behavior duplicated across workflows/validation/aidlc*.yaml and
# workflows/publish/npm-polyrepo-bun.yaml in the source repo:
#   1. If ~/.bun/bin/bun is not already present (e.g. restored from cache),
#      install the pinned version.
#   2. Put ~/.bun/bin on PATH via $BASH_ENV so later steps see it.
#   3. Verify the resolved `bun --version` matches the pinned version; a
#      stale cache entry must never be trusted silently.
#   4. On mismatch, wipe ~/.bun and reinstall, then fail fast (exit 1) if
#      the reinstall still doesn't produce the expected version.
#
# restore_cache / save_cache around this script are handled by the calling
# command (install_bun.yml), gated on the `cache` parameter.
set -euo pipefail

# The build-agent CLI is injected at /usr/bin/circleci on job images (it is
# not on PATH on cimg/base, see test_base_pinned_executor in
# .circleci/test-deploy.yml); override via CIRCLECI_CLI in tests to stub it.
CIRCLECI_CLI="${CIRCLECI_CLI:-/usr/bin/circleci}"

install_bun() {
  local version="$1"
  curl -fsSL https://bun.sh/install | bash -s "bun-v${version}"
}

main() {
  local expected_version
  expected_version="$("${CIRCLECI_CLI}" env subst "${PARAM_VERSION}")"

  if [ ! -x "${HOME}/.bun/bin/bun" ]; then
    install_bun "${expected_version}"
  fi

  echo "export PATH=\"\${HOME}/.bun/bin:\${PATH}\"" >> "$BASH_ENV"
  # shellcheck disable=SC1090
  source "$BASH_ENV"

  local actual_version
  actual_version="$(bun --version | sed 's/^v//')"

  if [ "$actual_version" != "$expected_version" ]; then
    echo "Cached bun ${actual_version} != expected ${expected_version}; reinstalling."
    rm -rf "${HOME}/.bun"
    install_bun "${expected_version}"
    actual_version="$(bun --version | sed 's/^v//')"
    if [ "$actual_version" != "$expected_version" ]; then
      echo "Failed to install bun ${expected_version} (got ${actual_version})"
      exit 1
    fi
  fi
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
