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
  printf '#!/usr/bin/env bash\necho "[stub] %s $*" "$(basename "$0")"\nexit 0\n' \
    >"${STUBBIN}/stub.sh"
  chmod +x "${STUBBIN}/stub.sh"
  for pm in pnpm npm; do ln -s "${STUBBIN}/stub.sh" "${STUBBIN}/${pm}"; done
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
  echo "$output" | grep -q 'pnpm audit --audit-level=high'
  grep -q "DEP_AUDIT_PM='pnpm'" "$BASH_ENV"
}

@test "audit_deps.sh detects npm from package-lock.json and runs npm audit" {
  printf '{"name":"fixture"}\n' >package.json
  touch package-lock.json
  run bash "${REPO_ROOT}/src/scripts/audit_deps.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'package manager: npm'
  echo "$output" | grep -q 'npm audit --audit-level=high'
  grep -q "DEP_AUDIT_PM='npm'" "$BASH_ENV"
}

@test "audit_deps.sh fails when nothing identifies a package manager" {
  run bash "${REPO_ROOT}/src/scripts/audit_deps.sh"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'cannot pick a package manager'
}

@test "chunk_audit_fix.sh skips cleanly when CIRCLE_TOKEN is unset" {
  run bash "${REPO_ROOT}/src/scripts/chunk_audit_fix.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'CIRCLE_TOKEN'
  grep -q 'CHUNK_AUDIT_FIX_SUMMARY' "$BASH_ENV"
}
