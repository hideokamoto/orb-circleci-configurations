#!/usr/bin/env bats
# Tests .circleci/scripts/release-config.jq, which builds the release
# pipeline's continuation config from test-deploy.yml and
# release-workflow.yml (given here as JSON fixtures, the form
# build-release-config.sh hands to jq).

setup() {
  FILTER="${BATS_TEST_DIRNAME}/../../.circleci/scripts/release-config.jq"
  TEST_DIR="$(mktemp -d)"
  cat > "${TEST_DIR}/rw.json" <<'JSON'
{"release_invocation": {"context": ["circleci", "github"], "serial-group": "g"},
 "jobs": {"release": {"steps": ["checkout"]}}}
JSON
}

teardown() {
  rm -rf "${TEST_DIR}"
}

write_td() {
  printf '%s\n' "$1" > "${TEST_DIR}/td.json"
}

build() {
  jq -s -f "${FILTER}" "${TEST_DIR}/td.json" "${TEST_DIR}/rw.json"
}

@test "drops the dev publish and makes release require every other entry" {
  write_td '{"orbs": {"configurations": {}}, "filters": {"tags": {"only": "/.*/"}},
    "jobs": {"test_a": {"steps": ["checkout"]}},
    "workflows": {"test-deploy": {"jobs": [
      {"test_a": {"filters": {}}},
      {"test_b": {"name": "renamed_b"}},
      {"orb-tools/pack": {"filters": {}}},
      {"orb-tools/publish": {"name": "publish-dev", "requires": ["test_a"]}}
    ]}}}'
  run build
  [ "$status" -eq 0 ]
  [ "$(jq -c '.workflows | keys' <<<"$output")" = '["release"]' ]
  [ "$(jq -c '[.workflows.release.jobs[] | keys[0]]' <<<"$output")" = '["test_a","test_b","orb-tools/pack","release"]' ]
  [ "$(jq -c '.workflows.release.jobs[-1].release.requires' <<<"$output")" = '["test_a","renamed_b","orb-tools/pack"]' ]
  [ "$(jq -c '.workflows.release.jobs[-1].release.context' <<<"$output")" = '["circleci","github"]' ]
}

@test "keeps test-deploy's jobs, orbs and top-level keys and adds the release job" {
  write_td '{"orbs": {"configurations": {}}, "filters": {"tags": {"only": "/.*/"}},
    "jobs": {"test_a": {"steps": ["checkout"]}},
    "workflows": {"test-deploy": {"jobs": [
      {"test_a": null}, {"orb-tools/pack": null}, {"orb-tools/publish": {"name": "publish-dev"}}
    ]}}}'
  run build
  [ "$status" -eq 0 ]
  [ "$(jq -c '.jobs | keys' <<<"$output")" = '["release","test_a"]' ]
  [ "$(jq -c '.orbs' <<<"$output")" = '{"configurations":{}}' ]
  [ "$(jq -c '.filters' <<<"$output")" = '{"tags":{"only":"/.*/"}}' ]
  [ "$(jq -c '.workflows.release.jobs[-1].release.requires' <<<"$output")" = '["test_a","orb-tools/pack"]' ]
}

@test "fails when the test-deploy workflow has no orb-tools/publish entry" {
  write_td '{"jobs": {}, "workflows": {"test-deploy": {"jobs": [{"test_a": null}, {"orb-tools/pack": null}]}}}'
  run build
  [ "$status" -ne 0 ]
  [[ "$output" == *"no orb-tools/publish entry"* ]]
}

@test "fails when orb-tools/pack is missing from the test-deploy workflow" {
  write_td '{"jobs": {}, "workflows": {"test-deploy": {"jobs": [{"test_a": null}, {"orb-tools/publish": null}]}}}'
  run build
  [ "$status" -ne 0 ]
  [[ "$output" == *"orb-tools/pack must stay"* ]]
}
