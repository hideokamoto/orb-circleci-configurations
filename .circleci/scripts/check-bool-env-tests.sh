#!/usr/bin/env bash
# Fails when a boolean parameter reaches a script through `environment:`
# without a BATS test that sets it to "1".
#
# CircleCI renders a boolean in a run step's `environment:` as "1" / "0" at
# run time, not "true" / "false": orb-tools/continue's "Prep Workspace" step
# sets `ORB_VAL_UNTAR: true` and tests `[[ $ORB_VAL_UNTAR == '1' ]]`, and this
# repository's own CI log shows that branch taken. A script that only accepts
# "true" therefore ignores the parameter in a real job while its tests, which
# set "true", still pass. That happened three times (create_github_release
# skip_if_exists, deploy_marker tolerate_missing, resolve_deploy_tag
# halt_if_missing). Requiring a test with "1" makes the BATS suite exercise
# the value CircleCI actually passes.
#
# For every boolean parameter that a command or job in src/ passes into a run
# step's environment, the step must <<include>> a script from src/scripts/,
# and src/tests/<script>.bats must set that variable to "1".
#
# Usage: check-bool-env-tests.sh [repository-root]   (default: .)
# Requires yq v4 (mikefarah) and jq, both present in the orb-tools/default
# executor. YAML2JSON overrides the YAML-to-JSON command (the tests use cat on
# JSON fixtures, which are valid YAML).
set -euo pipefail

root="${1:-.}"
read -ra yaml2json <<< "${YAML2JSON:-yq -o=json .}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
filter="${script_dir}/bool-env-params.jq"

entries=()
for file in "${root}"/src/commands/*.yml "${root}"/src/jobs/*.yml; do
  [ -e "${file}" ] || continue
  rel="${file#"${root}"/}"
  if ! json="$("${yaml2json[@]}" "${file}")"; then
    echo "ERROR: could not convert ${rel} to JSON" >&2
    exit 2
  fi
  while IFS= read -r line; do
    [ -n "${line}" ] && entries+=("${line}")
  done < <(jq -c --arg file "${rel}" '{file: $file, doc: .}' <<< "${json}" | jq -r -f "${filter}")
done

failures=0
for entry in ${entries[@]+"${entries[@]}"}; do
  IFS=$'\t' read -r file var param script <<< "${entry}"
  if [ "${script}" = "(inline)" ]; then
    echo "NG  ${file}: ${var} (${param}) goes to an inline script; move it to src/scripts/ and test it with ${var}=\"1\""
    failures=$((failures + 1))
    continue
  fi
  bats_file="src/tests/$(basename "${script}" .sh).bats"
  if [ -f "${root}/${bats_file}" ] \
    && grep -Eq "(^|[^A-Za-z0-9_])${var}=[\"']?1[\"']?([[:space:]]|$)" "${root}/${bats_file}"; then
    echo "ok  ${file}: ${var} (${param}) is tested with \"1\" in ${bats_file}"
  else
    echo "NG  ${file}: ${var} (${param}) has no test in ${bats_file} that sets ${var}=\"1\" (the value CircleCI passes for true)"
    failures=$((failures + 1))
  fi
done

echo "${#entries[@]} boolean environment parameter(s) checked, ${failures} failure(s)"
[ "${failures}" -eq 0 ]
