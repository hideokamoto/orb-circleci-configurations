#!/usr/bin/env bash
# Installs the standalone CircleCI CLI (CircleCI-Public/circleci-cli) from a
# pinned GitHub Releases tarball, verified by sha256, into PARAM_INSTALL_PATH.
#
# Source of truth for this behavior: the "Install CircleCI CLI for Deploy
# Diff Summaries" step in workflows/deployment/cloudflare-workers.yaml
# (hideokamoto/circleci-configurations). See the owning command's
# description for why this shadows /usr/bin/circleci on PATH, and why
# callers that need the build-agent specifically must keep addressing it by
# full path.
set -euo pipefail

# The binary used for "env subst" parameter expansion below. Fixed to the
# build-agent's well-known full path rather than a PATH lookup: cimg/base
# jobs were observed to not have "circleci" on PATH at all, only this fixed
# path (see fd58f6f in this orb's history, and the same convention used by
# this migration's other commands). Overridable via CIRCLECI_CLI so tests
# can point it at a stub instead of the real build-agent path.
CIRCLECI_CLI="${CIRCLECI_CLI:-/usr/bin/circleci}"

#######################################
# Checks whether a working standalone CircleCI CLI is already usable.
# Globals:
#   None.
# Arguments:
#   None.
# Outputs:
#   None.
# Returns:
#   0 if a "circleci" binary is on PATH and its "api --help" subcommand
#   succeeds (i.e. it is the full standalone CLI, not just the build-agent
#   binary, which lacks "api"); non-zero otherwise.
#######################################
circleci_cli_already_present() {
  command -v circleci >/dev/null 2>&1 && circleci api --help >/dev/null 2>&1
}

#######################################
# Installs the standalone CircleCI CLI, sha256-verified, unless a working
# one is already present and skip_if_present allows skipping.
# Globals:
#   CIRCLECI_CLI        Build-agent binary invoked for "env subst" parameter
#                        expansion (see its definition above).
#   PARAM_VERSION       circleci-cli release version to install.
#   PARAM_SHA256        Expected sha256 checksum of that release's
#                        linux_amd64 tarball.
#   PARAM_INSTALL_PATH  Directory to install the "circleci" binary into.
#   PARAM_SKIP_IF_PRESENT  "true"/"false": whether to skip the install when
#                        circleci_cli_already_present already succeeds.
# Arguments:
#   None.
# Outputs:
#   Progress messages to stdout.
# Returns/Side effects:
#   Installs the "circleci" binary at "<install_path>/circleci" via
#   "sudo install" when a (re)install is needed. Because of "set -euo
#   pipefail", the function (and the script) exits non-zero if the
#   download, the sha256 verification, the extraction, or the install
#   step fails.
#######################################
install_circleci_cli() {
  local version sha256 install_path skip_if_present
  version="$("${CIRCLECI_CLI}" env subst "${PARAM_VERSION}")"
  sha256="$("${CIRCLECI_CLI}" env subst "${PARAM_SHA256}")"
  install_path="$("${CIRCLECI_CLI}" env subst "${PARAM_INSTALL_PATH}")"
  skip_if_present="${PARAM_SKIP_IF_PRESENT}"

  if [ "${skip_if_present}" = "true" ] && circleci_cli_already_present; then
    echo "circleci CLI already on PATH and its 'api' subcommand already works; skipping install."
    return 0
  fi

  local tmp_dir archive url
  tmp_dir="$(mktemp -d)"
  archive="${tmp_dir}/circleci-cli.tar.gz"
  url="https://github.com/CircleCI-Public/circleci-cli/releases/download/v${version}/circleci-cli_${version}_linux_amd64.tar.gz"

  echo "Downloading circleci-cli ${version} from ${url}"
  curl -fLSs -o "${archive}" "${url}"

  echo "Verifying sha256 checksum"
  echo "${sha256}  ${archive}" | sha256sum -c -

  tar -xzf "${archive}" -C "${tmp_dir}" circleci

  echo "Installing circleci-cli ${version} to ${install_path}/circleci"
  sudo install -m 0755 "${tmp_dir}/circleci" "${install_path}/circleci"

  rm -rf "${tmp_dir}"
}

#######################################
# Entry point run when this script is executed directly (not sourced, as
# bats-core does for unit testing).
# Globals:
#   None.
# Arguments:
#   None.
# Outputs:
#   None (see install_circleci_cli, which this delegates to entirely).
# Returns:
#   install_circleci_cli's exit status.
#######################################
main() {
  install_circleci_cli
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
