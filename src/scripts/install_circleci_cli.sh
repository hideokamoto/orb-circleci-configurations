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

circleci_cli_already_present() {
  command -v circleci >/dev/null 2>&1 && circleci api --help >/dev/null 2>&1
}

# The platform-injected build-agent binary is what implements `env subst`
# for orb parameter expansion, and CircleCI guarantees it on every job's
# PATH as bare "circleci" -- but some minimal images (e.g. cimg/base) were
# observed, outside of a real CircleCI job, to not resolve it via PATH, only
# at its fixed path /usr/bin/circleci. Fall back there so parameter
# expansion does not depend on PATH contents this command has not set up
# yet (that is what it is about to install).
circleci_cli_for_env_subst() {
  if command -v circleci >/dev/null 2>&1; then
    echo "circleci"
  elif [ -x /usr/bin/circleci ]; then
    echo "/usr/bin/circleci"
  else
    echo "circleci CLI (build-agent) not found on PATH or at /usr/bin/circleci; cannot expand parameters." >&2
    return 1
  fi
}

install_circleci_cli() {
  local cli version sha256 install_path skip_if_present
  cli="$(circleci_cli_for_env_subst)"
  version="$("${cli}" env subst "${PARAM_VERSION}")"
  sha256="$("${cli}" env subst "${PARAM_SHA256}")"
  install_path="$("${cli}" env subst "${PARAM_INSTALL_PATH}")"
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

main() {
  install_circleci_cli
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
