#!/usr/bin/env bash
# Builds the release pipeline's continuation config (see release-config.jq and
# .circleci/release-workflow.yml) and writes it to the path given as $1.
#
# Requires yq v4 (mikefarah) and jq, both present in the orb-tools/continue
# executor (circleci/circleci-cli), which runs this as a pre-step.
# The output is JSON, which is valid YAML for CircleCI and for yq.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <output-path>" >&2
  exit 2
fi
out="$1"
circleci_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

yq -o=json '.' "${circleci_dir}/test-deploy.yml" > "${tmp_dir}/test-deploy.json"
yq -o=json '.' "${circleci_dir}/release-workflow.yml" > "${tmp_dir}/release-workflow.json"
jq -s -f "${circleci_dir}/scripts/release-config.jq" \
  "${tmp_dir}/test-deploy.json" "${tmp_dir}/release-workflow.json" > "${out}"
echo "Wrote ${out}: release requires $(jq -c '.workflows.release.jobs[-1].release.requires' "${out}")"
