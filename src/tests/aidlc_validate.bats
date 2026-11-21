#!/usr/bin/env bats
# Covers the aidlc_validate job's scripts other than the version check
# (src/tests/aidlc_check_version.bats): harness detection, the all-scopes
# loop, the Cursor rule check, and doctor on an ephemeral copy.

# bats-core lifecycle hook. Creates an empty fixture checkout, stubs `bun`
# (logs its arguments; fails `validate-scope <s>` for each scope listed in
# FAKE_FAILING_SCOPES and `doctor` when FAKE_DOCTOR_FAIL=1) and the circleci
# CLI used for `env subst`.
setup() {
  SCRIPTS="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/src/scripts"

  TEST_DIR="$(mktemp -d)"
  mkdir -p "${TEST_DIR}/bin" "${TEST_DIR}/repo"
  BUN_LOG="${TEST_DIR}/bun.log"
  cat > "${TEST_DIR}/bin/bun" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${BUN_LOG}"
if [ "$2" = "validate-scope" ]; then
  for s in ${FAKE_FAILING_SCOPES:-}; do
    if [ "$s" = "$3" ]; then echo "scope $3 invalid" >&2; exit 1; fi
  done
fi
if [ "$2" = "doctor" ]; then
  project_dir="$4"
  # Record what the ephemeral workspace contained when doctor ran.
  (cd "${project_dir}" && find . -mindepth 1 | sort) > "${BUN_LOG}.doctor-tree"
  if [ "${FAKE_DOCTOR_FAIL:-}" = "1" ]; then exit 3; fi
fi
exit 0
STUB
  chmod +x "${TEST_DIR}/bin/bun"
  PATH="${TEST_DIR}/bin:${PATH}"

  CIRCLECI_CLI="${TEST_DIR}/bin/circleci-cli"
  cat > "${CIRCLECI_CLI}" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "env" ] && [ "$2" = "subst" ]; then printf '%s' "$3"; fi
STUB
  chmod +x "${CIRCLECI_CLI}"

  export PATH CIRCLECI_CLI BUN_LOG
  export BASH_ENV="${TEST_DIR}/bash_env"
  : > "${BASH_ENV}"
  unset FAKE_FAILING_SCOPES FAKE_DOCTOR_FAIL AIDLC_TOOLS AIDLC_HARNESS
  cd "${TEST_DIR}/repo"
}

teardown() {
  rm -rf "${TEST_DIR}"
}

# --- aidlc_detect_harness.sh ---

@test "detect: exports the Claude Code harness paths" {
  mkdir -p .claude/tools
  run bash "${SCRIPTS}/aidlc_detect_harness.sh"
  [ "$status" -eq 0 ]
  grep -qx 'export AIDLC_TOOLS=".claude/tools"' "${BASH_ENV}"
  grep -qx 'export AIDLC_HARNESS=".claude"' "${BASH_ENV}"
}

@test "detect: exports the Cursor harness paths" {
  mkdir -p .cursor/tools
  run bash "${SCRIPTS}/aidlc_detect_harness.sh"
  [ "$status" -eq 0 ]
  grep -qx 'export AIDLC_TOOLS=".cursor/tools"' "${BASH_ENV}"
  grep -qx 'export AIDLC_HARNESS=".cursor"' "${BASH_ENV}"
}

@test "detect: prefers .claude when both harnesses exist" {
  mkdir -p .claude/tools .cursor/tools
  run bash "${SCRIPTS}/aidlc_detect_harness.sh"
  [ "$status" -eq 0 ]
  grep -qx 'export AIDLC_HARNESS=".claude"' "${BASH_ENV}"
}

@test "detect: fails when no harness is embedded" {
  run bash "${SCRIPTS}/aidlc_detect_harness.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Is AI-DLC embedded"* ]]
  [ ! -s "${BASH_ENV}" ]
}

@test "detect: a .claude directory without tools/ is not a harness" {
  mkdir -p .claude/skills
  run bash "${SCRIPTS}/aidlc_detect_harness.sh"
  [ "$status" -eq 1 ]
}

# --- aidlc_validate_scopes.sh ---

@test "scopes: validates every scope when all pass" {
  export AIDLC_TOOLS=".claude/tools" PARAM_SCOPES="feature mvp poc"
  run bash "${SCRIPTS}/aidlc_validate_scopes.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'validate-scope' "${BUN_LOG}")" -eq 3 ]
  grep -qx '.claude/tools/aidlc-graph.ts validate-scope poc' "${BUN_LOG}"
}

@test "scopes: keeps going after a failure and reports every failed scope" {
  export AIDLC_TOOLS=".claude/tools" PARAM_SCOPES="feature mvp poc bugfix"
  export FAKE_FAILING_SCOPES="mvp bugfix"
  run bash "${SCRIPTS}/aidlc_validate_scopes.sh"
  [ "$status" -eq 1 ]
  [ "$(grep -c 'validate-scope' "${BUN_LOG}")" -eq 4 ]
  [[ "$output" == *"validate-scope failed for: mvp bugfix"* ]]
}

@test "scopes: tolerates extra whitespace between scope names" {
  export AIDLC_TOOLS=".claude/tools" PARAM_SCOPES="  feature   mvp "
  run bash "${SCRIPTS}/aidlc_validate_scopes.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'validate-scope' "${BUN_LOG}")" -eq 2 ]
}

@test "scopes: fails on an empty scope list instead of passing vacuously" {
  export AIDLC_TOOLS=".claude/tools" PARAM_SCOPES=""
  run bash "${SCRIPTS}/aidlc_validate_scopes.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"No scopes given"* ]]
}

@test "scopes: fails when AIDLC_TOOLS is not set" {
  export PARAM_SCOPES="feature"
  run bash "${SCRIPTS}/aidlc_validate_scopes.sh"
  [ "$status" -eq 1 ]
}

# --- aidlc_check_cursor_rule.sh ---

@test "cursor rule: skips when the project has no Cursor rule" {
  run bash "${SCRIPTS}/aidlc_check_cursor_rule.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping Cursor harness checks"* ]]
}

@test "cursor rule: accepts the v2 memory layout when the memory files exist" {
  mkdir -p .cursor/rules aidlc/spaces/default/memory
  echo 'see aidlc/spaces/default/memory/ for rules' > .cursor/rules/aidlc.mdc
  touch aidlc/spaces/default/memory/{org,team,project}.md
  run bash "${SCRIPTS}/aidlc_check_cursor_rule.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"v2 memory layout"* ]]
}

@test "cursor rule: fails the v2 layout when a referenced memory file is missing" {
  mkdir -p .cursor/rules aidlc/spaces/default/memory
  echo 'see aidlc/spaces/default/memory/ for rules' > .cursor/rules/aidlc.mdc
  touch aidlc/spaces/default/memory/{org,team}.md
  run bash "${SCRIPTS}/aidlc_check_cursor_rule.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing aidlc/spaces/default/memory/project.md"* ]]
}

@test "cursor rule: accepts the legacy orchestration layout" {
  mkdir -p .cursor/rules
  cat > .cursor/rules/aidlc.mdc <<'MDC'
bun .claude/tools/aidlc-orchestrate.ts next
bun .claude/tools/aidlc-orchestrate.ts report
read .claude/skills/aidlc/SKILL.md
bun .claude/tools/aidlc-utility.ts doctor
MDC
  run bash "${SCRIPTS}/aidlc_check_cursor_rule.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"legacy orchestration layout"* ]]
}

@test "cursor rule: fails the legacy layout when a reference is missing" {
  mkdir -p .cursor/rules
  cat > .cursor/rules/aidlc.mdc <<'MDC'
bun .claude/tools/aidlc-orchestrate.ts next
read .claude/skills/aidlc/SKILL.md
bun .claude/tools/aidlc-utility.ts doctor
MDC
  run bash "${SCRIPTS}/aidlc_check_cursor_rule.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing orchestrate report reference"* ]]
}

# --- aidlc_doctor.sh ---

@test "doctor: runs on a copy holding the harness and aidlc/, and cleans it up" {
  mkdir -p .claude/tools aidlc/spaces/default/memory
  touch .claude/tools/aidlc-utility.ts aidlc/spaces/default/memory/org.md
  export AIDLC_HARNESS=".claude"
  run bash "${SCRIPTS}/aidlc_doctor.sh"
  [ "$status" -eq 0 ]
  grep -q 'aidlc-utility.ts doctor --project-dir ' "${BUN_LOG}"
  grep -qx './.claude/tools/aidlc-utility.ts' "${BUN_LOG}.doctor-tree"
  grep -qx './aidlc/spaces/default/memory/org.md' "${BUN_LOG}.doctor-tree"
  tmp_dir="$(sed -n 's/.*--project-dir //p' "${BUN_LOG}")"
  [ ! -e "${tmp_dir}" ]
}

@test "doctor: does not need an aidlc/ directory" {
  mkdir -p .cursor/tools
  touch .cursor/tools/aidlc-utility.ts
  export AIDLC_HARNESS=".cursor"
  run bash "${SCRIPTS}/aidlc_doctor.sh"
  [ "$status" -eq 0 ]
  ! grep -q '^./aidlc' "${BUN_LOG}.doctor-tree" || false
}

@test "doctor: propagates doctor's failure status" {
  mkdir -p .claude/tools
  export AIDLC_HARNESS=".claude" FAKE_DOCTOR_FAIL="1"
  run bash "${SCRIPTS}/aidlc_doctor.sh"
  [ "$status" -eq 3 ]
}

@test "doctor: fails when AIDLC_HARNESS is not set" {
  run bash "${SCRIPTS}/aidlc_doctor.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"AIDLC_HARNESS is not set"* ]]
}
