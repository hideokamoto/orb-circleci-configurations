#!/usr/bin/env bash
set -euo pipefail

# Checks the Cursor harness rule file, when the project has one.
#
# v2 Cursor harness: .cursor/rules/aidlc.mdc only points at the memory
# directory, so the files it references must exist; the rule's customized
# body is not validated here. The legacy harness (an aidlc.mdc that calls
# into .claude directly) is still accepted for backward compatibility, as
# long as it references the orchestration entry points.

# Validates the Cursor rule file.
#
# Arguments:
#   $1 - rule: path of the Cursor rule file (relative to the checkout).
#   $2 - memory_dir: the v2 memory directory the rule should point at.
# Side effects:
#   Prints which layout was recognized, or which reference is missing.
# Returns:
#   0 when the rule is absent (Claude Code only project) or valid, 1 otherwise.
check_cursor_rule() {
  local rule="$1"
  local memory_dir="$2"
  local f

  if [ ! -f "${rule}" ]; then
    echo "No ${rule}; skipping Cursor harness checks (Claude Code only project?)"
    return 0
  fi

  if grep -qF "${memory_dir}/" "${rule}"; then
    for f in org.md team.md project.md; do
      if [ ! -f "${memory_dir}/${f}" ]; then
        echo "Missing ${memory_dir}/${f} (referenced by ${rule})" >&2
        return 1
      fi
    done
    echo "Cursor harness rule OK (v2 memory layout)"
    return 0
  fi

  grep -q 'aidlc-orchestrate\.ts next' "${rule}" || { echo "Missing orchestrate next reference in ${rule}" >&2; return 1; }
  grep -q 'aidlc-orchestrate\.ts report' "${rule}" || { echo "Missing orchestrate report reference in ${rule}" >&2; return 1; }
  grep -q '\.claude/skills/aidlc/SKILL\.md' "${rule}" || { echo "Missing SKILL.md reference in ${rule}" >&2; return 1; }
  grep -q 'aidlc-utility\.ts doctor' "${rule}" || { echo "Missing doctor reference in ${rule}" >&2; return 1; }
  echo "Cursor harness rule OK (legacy orchestration layout)"
}

# Entry point when this script runs as a CircleCI `run` step.
main() {
  check_cursor_rule ".cursor/rules/aidlc.mdc" "aidlc/spaces/default/memory"
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
  main
fi
