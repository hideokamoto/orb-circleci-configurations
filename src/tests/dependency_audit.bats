#!/usr/bin/env bats
# dependency_audit のスクリプト層テスト。
# audit_deps.sh: lockfile から pm を判定して <pm> audit を呼ぶ。
# chunk_audit_fix.sh: CIRCLE_TOKEN / GITHUB_TOKEN が無いときは何もせず終了する。
# circleci / GitHub の API には出ない（curl は stub 化しない: token 欠如で
# API 呼び出しより前に finish する経路だけを見る）。

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  WORK="$(mktemp -d)"
  STUBBIN="${WORK}/bin"
  mkdir -p "$STUBBIN"
  # Each stub records its own invocation (name + args) to STUB_LOG, so tests
  # can assert the audit command actually ran instead of grepping stdout —
  # which also contains the script's own pre-announcement of that command.
  export STUB_LOG="${WORK}/stub-calls.log"
  : >"$STUB_LOG"
  for pm in pnpm npm; do
    printf '#!/usr/bin/env bash\necho "%s $*" >>"%s"\nexit 0\n' "$pm" "$STUB_LOG" \
      >"${STUBBIN}/${pm}"
    chmod +x "${STUBBIN}/${pm}"
  done
  export PATH="${STUBBIN}:${PATH}"
  export BASH_ENV="${WORK}/bash_env"
  : >"$BASH_ENV"
  export DEP_AUDIT_LEVEL=high
  unset CIRCLE_TOKEN GITHUB_TOKEN DEP_AUDIT_PM_OVERRIDE
  cd "$WORK"
}

teardown() {
  rm -rf "$WORK"
}

@test "audit_deps.sh detects pnpm from pnpm-lock.yaml and runs pnpm audit" {
  printf '{"name":"fixture"}\n' >package.json
  touch pnpm-lock.yaml
  run bash "${REPO_ROOT}/src/scripts/audit_deps.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'package manager: pnpm'
  grep -q "DEP_AUDIT_PM='pnpm'" "$BASH_ENV"
  grep -qx 'pnpm audit --audit-level=high' "$STUB_LOG"
}

@test "audit_deps.sh detects npm from package-lock.json and runs npm audit" {
  printf '{"name":"fixture"}\n' >package.json
  touch package-lock.json
  run bash "${REPO_ROOT}/src/scripts/audit_deps.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'package manager: npm'
  grep -q "DEP_AUDIT_PM='npm'" "$BASH_ENV"
  grep -qx 'npm audit --audit-level=high' "$STUB_LOG"
}

@test "audit_deps.sh fails when nothing identifies a package manager" {
  run bash "${REPO_ROOT}/src/scripts/audit_deps.sh"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'cannot pick a package manager'
  [ ! -s "$STUB_LOG" ]
}

@test "audit_deps.sh fails explicitly when package.json has no lockfile, without exporting DEP_AUDIT_PM" {
  printf '{"name":"fixture"}\n' >package.json
  run bash "${REPO_ROOT}/src/scripts/audit_deps.sh"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'requires a lockfile'
  [ ! -s "$STUB_LOG" ]
  # Not exporting DEP_AUDIT_PM here is what makes chunk_audit_fix.sh's own
  # "skip when DEP_AUDIT_PM is unset" guard apply to this failure too,
  # instead of a later on_fail step asking Chunk to fix an npm audit that
  # never actually ran.
  ! grep -q 'DEP_AUDIT_PM' "$BASH_ENV"
}

@test "audit_deps.sh fails explicitly when DEP_AUDIT_PM_OVERRIDE=npm has no lockfile, without exporting DEP_AUDIT_PM" {
  export DEP_AUDIT_PM_OVERRIDE=npm
  printf '{"name":"fixture"}\n' >package.json
  run bash "${REPO_ROOT}/src/scripts/audit_deps.sh"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'requires a lockfile'
  [ ! -s "$STUB_LOG" ]
  ! grep -q 'DEP_AUDIT_PM' "$BASH_ENV"
}

@test "audit_deps.sh detects yarn from yarn.lock even with a package.json present, and refuses to audit it" {
  printf '{"name":"fixture"}\n' >package.json
  touch yarn.lock
  run bash "${REPO_ROOT}/src/scripts/audit_deps.sh"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'package manager: yarn'
  echo "$output" | grep -q 'is not supported'
  [ ! -s "$STUB_LOG" ]
}

@test "audit_deps.sh detects bun from bun.lock even with a package.json present, and refuses to audit it" {
  printf '{"name":"fixture"}\n' >package.json
  touch bun.lock
  run bash "${REPO_ROOT}/src/scripts/audit_deps.sh"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'package manager: bun'
  echo "$output" | grep -q 'is not supported'
  [ ! -s "$STUB_LOG" ]
}

@test "audit_deps.sh prefers npm's own lockfile over a coexisting yarn.lock" {
  printf '{"name":"fixture"}\n' >package.json
  touch package-lock.json yarn.lock
  run bash "${REPO_ROOT}/src/scripts/audit_deps.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'package manager: npm'
  grep -qx 'npm audit --audit-level=high' "$STUB_LOG"
}

@test "chunk_audit_fix.sh skips cleanly when CIRCLE_TOKEN is unset" {
  run bash "${REPO_ROOT}/src/scripts/chunk_audit_fix.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'CIRCLE_TOKEN'
  grep -q 'CHUNK_AUDIT_FIX_SUMMARY' "$BASH_ENV"
}

@test "chunk_audit_fix.sh skips cleanly when DEP_AUDIT_PM is unset" {
  export CIRCLE_TOKEN=dummy GITHUB_TOKEN=dummy
  unset DEP_AUDIT_PM
  run bash "${REPO_ROOT}/src/scripts/chunk_audit_fix.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'DEP_AUDIT_PM'
  grep -q 'CHUNK_AUDIT_FIX_SUMMARY' "$BASH_ENV"
}
