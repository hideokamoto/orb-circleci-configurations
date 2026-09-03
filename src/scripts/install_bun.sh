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

# Downloads and runs the official bun.sh installer, pinned to one version.
#
# Arguments:
#   $1 - version - the bun version to install, without the "bun-v" / "v"
#        prefix (e.g. "1.3.14").
# Returns:
#   The installer's own exit status (non-zero on download/install failure,
#   via the pipeline under `set -euo pipefail`).
# Side effects:
#   Writes the bun toolchain to ~/.bun (creating it if absent, overwriting
#   the binary if already present). Performs a network call to
#   https://bun.sh/install. Does not touch PATH or $BASH_ENV itself.
install_bun() {
  local version="$1"
  curl -fsSL https://bun.sh/install | bash -s "bun-v${version}"
}

# Entry point: ensures a bun toolchain matching PARAM_VERSION is installed
# and on PATH, reinstalling once if a pre-existing (e.g. cache-restored)
# toolchain doesn't match.
#
# Arguments:
#   None (reads the PARAM_VERSION and CIRCLECI_CLI environment variables;
#   PARAM_VERSION is required and is expanded via `circleci env subst` so
#   callers may pass a literal version or a "$VAR" reference).
# Returns:
#   0 on success (a bun matching PARAM_VERSION ends up on PATH); exits 1 if
#   a reinstall still doesn't produce the expected version.
# Side effects:
#   May install/reinstall bun under ~/.bun (see install_bun). Appends a
#   PATH export for ~/.bun/bin to $BASH_ENV and sources it into the current
#   shell so `bun` resolves for the rest of this process and later steps.
#   On a version mismatch, deletes ~/.bun before reinstalling. Prints
#   progress/diagnostic messages to stdout.
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
