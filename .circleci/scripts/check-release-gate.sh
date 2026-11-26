#!/usr/bin/env bash
# Fails when the bats/run entry of the release pipeline (.circleci/release.yml)
# differs from the one pull requests run (.circleci/config.yml), apart from
# `filters`, which only the pull request config uses.
#
# The release pipeline runs only on pushes to main, so a bats/run parameter
# added to config.yml alone (such as setup-steps that install a tool the
# tests need) passes on the pull request and fails the release after merge.
# Requires mikefarah yq (v4) and jq, as in orb-tools/default.
set -euo pipefail

circleci_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bats_entry() {
    yq -o=json '.' "$1" |
        jq -S --arg wf "$2" '[.workflows[$wf].jobs[] | select(type == "object" and has("bats/run")) | ."bats/run" | del(.filters)]'
}

pr="$(bats_entry "${circleci_dir}/config.yml" lint-pack)"
release="$(bats_entry "${circleci_dir}/release.yml" release)"

if [ "$(jq 'length' <<<"${pr}")" -ne 1 ] || [ "$(jq 'length' <<<"${release}")" -ne 1 ]; then
    echo "Expected exactly one bats/run entry in each of config.yml (lint-pack) and release.yml (release)." >&2
    exit 1
fi
if [ "${pr}" != "${release}" ]; then
    echo "bats/run in .circleci/release.yml differs from .circleci/config.yml (filters aside):" >&2
    diff <(jq . <<<"${pr}") <(jq . <<<"${release}") >&2 || true
    exit 1
fi
echo "bats/run matches between config.yml and release.yml."
