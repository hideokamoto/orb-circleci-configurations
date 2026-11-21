#!/usr/bin/env bats
# Tests .circleci/scripts/check-bool-env-tests.sh, which requires every
# boolean parameter passed into a run step's environment to be tested with
# "1". Fixtures are JSON (valid YAML), read with YAML2JSON=cat so the tests
# need jq but not yq.

setup() {
  CHECK="${BATS_TEST_DIRNAME}/../../.circleci/scripts/check-bool-env-tests.sh"
  ROOT="$(mktemp -d)"
  mkdir -p "${ROOT}/src/commands" "${ROOT}/src/jobs" "${ROOT}/src/tests"
  export YAML2JSON=cat
}

teardown() {
  rm -rf "${ROOT}"
}

# write_command <name> <parameters JSON> <environment JSON> [command]
write_command() {
  local command="${4:-<<include(scripts/$1.sh)>>}"
  jq -n --argjson params "$2" --argjson env "$3" --arg command "${command}" \
    '{description: "d", parameters: $params,
      steps: [{run: {name: "n", environment: $env, command: $command}}]}' \
    > "${ROOT}/src/commands/$1.yml"
}

BOOL_PARAM='{"halt": {"type": "boolean", "default": true, "description": "d"}}'
BOOL_ENV='{"PARAM_HALT": "<<parameters.halt>>"}'

@test "passes when the script's tests set the variable to \"1\"" {
  write_command foo "${BOOL_PARAM}" "${BOOL_ENV}"
  printf '%s\n' '  export PARAM_HALT="1"' > "${ROOT}/src/tests/foo.bats"
  run bash "${CHECK}" "${ROOT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *'ok  src/commands/foo.yml: PARAM_HALT (halt)'* ]]
  [[ "$output" == *'1 boolean environment parameter(s) checked, 0 failure(s)'* ]]
}

@test "accepts an unquoted or single-quoted 1" {
  write_command foo "${BOOL_PARAM}" "${BOOL_ENV}"
  printf '%s\n' "  PARAM_HALT='1' run_script" > "${ROOT}/src/tests/foo.bats"
  run bash "${CHECK}" "${ROOT}"
  [ "$status" -eq 0 ]
  printf '%s\n' '  PARAM_HALT=1' > "${ROOT}/src/tests/foo.bats"
  run bash "${CHECK}" "${ROOT}"
  [ "$status" -eq 0 ]
}

@test "fails when the tests only set \"true\"" {
  write_command foo "${BOOL_PARAM}" "${BOOL_ENV}"
  printf '%s\n' '  export PARAM_HALT="true"' > "${ROOT}/src/tests/foo.bats"
  run bash "${CHECK}" "${ROOT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *'NG  src/commands/foo.yml: PARAM_HALT (halt) has no test in src/tests/foo.bats'* ]]
}

@test "does not count another variable that ends with the same name" {
  write_command foo "${BOOL_PARAM}" "${BOOL_ENV}"
  printf '%s\n' '  export OTHER_PARAM_HALT="1"' '  export PARAM_HALT="10"' > "${ROOT}/src/tests/foo.bats"
  run bash "${CHECK}" "${ROOT}"
  [ "$status" -eq 1 ]
}

@test "fails when the script has no BATS file" {
  write_command foo "${BOOL_PARAM}" "${BOOL_ENV}"
  run bash "${CHECK}" "${ROOT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *'no test in src/tests/foo.bats'* ]]
}

@test "fails when the variable goes to an inline script" {
  write_command foo "${BOOL_PARAM}" "${BOOL_ENV}" 'if [ "$PARAM_HALT" = true ]; then exit 0; fi'
  run bash "${CHECK}" "${ROOT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *'PARAM_HALT (halt) goes to an inline script'* ]]
}

@test "ignores string parameters and booleans that never reach environment" {
  write_command foo \
    '{"name": {"type": "string", "default": "", "description": "d"},
      "flag": {"type": "boolean", "default": false, "description": "d"}}' \
    '{"PARAM_NAME": "<<parameters.name>>", "PARAM_FIXED": "true"}'
  run bash "${CHECK}" "${ROOT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *'0 boolean environment parameter(s) checked, 0 failure(s)'* ]]
}

@test "finds run steps nested in when blocks of jobs" {
  jq -n '{description: "d",
    parameters: {notify: {type: "boolean", default: true, description: "d"}},
    steps: [{when: {condition: true, steps: [
      {run: {name: "n", environment: {PARAM_NOTIFY: "<< parameters.notify >>"},
             command: "<<include(scripts/bar.sh)>>"}}]}}]}' \
    > "${ROOT}/src/jobs/bar.yml"
  printf '%s\n' '  export PARAM_NOTIFY="true"' > "${ROOT}/src/tests/bar.bats"
  run bash "${CHECK}" "${ROOT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *'NG  src/jobs/bar.yml: PARAM_NOTIFY (notify)'* ]]
}

@test "reports every failure, not only the first" {
  write_command foo "${BOOL_PARAM}" "${BOOL_ENV}"
  write_command baz "${BOOL_PARAM}" "${BOOL_ENV}"
  run bash "${CHECK}" "${ROOT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *'2 boolean environment parameter(s) checked, 2 failure(s)'* ]]
}
