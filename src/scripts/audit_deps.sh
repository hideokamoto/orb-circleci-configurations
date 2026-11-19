#!/usr/bin/env bash
# Detect the checkout's package manager from its lockfile and run its security
# audit. Exits with the audit's own exit code so the enclosing step fails when
# advisories at or above DEP_AUDIT_LEVEL exist.
#
# Environment:
#   DEP_AUDIT_LEVEL       audit severity threshold (default: high)
#   DEP_AUDIT_PM_OVERRIDE "pnpm" or "npm" to skip lockfile auto-detection
#   BASH_ENV              DEP_AUDIT_PM and DEP_AUDIT_RESULT ('success' or
#                         'failed', only once the audit command itself ran)
#                         are exported here for later steps. A later on_fail
#                         step (chunk_audit_fix.sh) must check
#                         DEP_AUDIT_RESULT == 'failed' explicitly rather than
#                         trusting CircleCI's job-wide on_fail: that fires
#                         whenever *anything* earlier in the job failed, not
#                         specifically this audit.

set -uo pipefail

detect_pm() {
  # An actual npm lockfile (package-lock.json/npm-shrinkwrap.json) outranks
  # bun/yarn, same as before — this only changes which check runs last: a
  # bare package.json, with none of the other lockfiles present either, is
  # the npm fallback, checked after bun/yarn so a yarn.lock/bun.lock repo
  # (which almost always also has a package.json) is never misclassified as
  # npm just because it lacks a package-lock.json.
  if [[ -f pnpm-lock.yaml || -f pnpm-workspace.yaml ]]; then
    echo pnpm
  elif [[ -f package-lock.json || -f npm-shrinkwrap.json ]]; then
    echo npm
  elif [[ -f bun.lock || -f bun.lockb ]]; then
    echo bun
  elif [[ -f yarn.lock ]]; then
    echo yarn
  elif [[ -f package.json ]]; then
    # A lockfile-less package.json is still provisionally "npm" here; the
    # npm case below is the single place that enforces a lockfile actually
    # exists, so the same check applies whether npm was auto-detected or
    # forced via DEP_AUDIT_PM_OVERRIDE.
    echo npm
  else
    return 1
  fi
}

DEP_AUDIT_LEVEL="${DEP_AUDIT_LEVEL:-high}"

# Clear any DEP_AUDIT_RESULT left by an earlier invocation in this same job
# before any precondition check or early exit below. BASH_ENV only appends,
# so without this a stale 'failed' from a prior call could make
# chunk_audit_fix.sh act on this call even though it exited early (e.g. for
# a missing lockfile) and never actually ran an audit this time.
if [[ -n "${BASH_ENV:-}" ]]; then
  echo "export DEP_AUDIT_RESULT=''" >>"$BASH_ENV"
fi

DEP_AUDIT_PM="${DEP_AUDIT_PM_OVERRIDE:-}"
if [[ -z "$DEP_AUDIT_PM" || "$DEP_AUDIT_PM" == "auto" ]]; then
  DEP_AUDIT_PM="$(detect_pm)" || {
    echo "[dependency-audit] no package.json or lockfile found; cannot pick a package manager"
    exit 2
  }
fi

# `npm audit` requires package-lock.json/npm-shrinkwrap.json and exits
# ENOLOCK without one, a failure indistinguishable from a real
# vulnerability. Check explicitly — for both the auto-detected case and
# DEP_AUDIT_PM_OVERRIDE=npm — *before* exporting DEP_AUDIT_PM: a later
# on_fail step (chunk_audit_fix.sh) only skips Chunk when DEP_AUDIT_PM
# never made it into BASH_ENV, so this failure must exit before that
# export or Chunk would be asked to fix a precondition gap as if it were
# a real npm vulnerability.
if [[ "$DEP_AUDIT_PM" == npm && ! -f package-lock.json && ! -f npm-shrinkwrap.json ]]; then
  echo "[dependency-audit] npm audit requires a lockfile (package-lock.json or npm-shrinkwrap.json); none found, so generate or commit one before auditing"
  exit 2
fi

echo "[dependency-audit] package manager: $DEP_AUDIT_PM (audit level: $DEP_AUDIT_LEVEL)"
if [[ -n "${BASH_ENV:-}" ]]; then
  echo "export DEP_AUDIT_PM='$DEP_AUDIT_PM'" >>"$BASH_ENV"
fi

case "$DEP_AUDIT_PM" in
  pnpm)
    if ! command -v pnpm >/dev/null 2>&1; then
      # Use the packageManager pin when present: stock pnpm 12's default
      # minimumReleaseAge makes installs fail on freshly released packages.
      PNPM_VERSION="$(node -p "require('./package.json').packageManager?.split('@')[1] ?? ''" 2>/dev/null || true)"
      PNPM_VERSION="${PNPM_VERSION:-latest}"
      echo "[dependency-audit] installing pnpm@${PNPM_VERSION}"
      sudo npm install -g "pnpm@${PNPM_VERSION}"
    fi
    AUDIT_CMD=(pnpm audit --audit-level="$DEP_AUDIT_LEVEL")
    ;;
  npm)
    # The lockfile is already confirmed to exist above.
    AUDIT_CMD=(npm audit --audit-level="$DEP_AUDIT_LEVEL")
    ;;
  *)
    echo "[dependency-audit] '$DEP_AUDIT_PM' is not supported (pnpm and npm only)"
    exit 2
    ;;
esac

echo "[dependency-audit] running: ${AUDIT_CMD[*]}"
"${AUDIT_CMD[@]}"
AUDIT_STATUS=$?

if [[ -n "${BASH_ENV:-}" ]]; then
  if [[ "$AUDIT_STATUS" -eq 0 ]]; then
    echo "export DEP_AUDIT_RESULT='success'" >>"$BASH_ENV"
  else
    echo "export DEP_AUDIT_RESULT='failed'" >>"$BASH_ENV"
  fi
fi
exit "$AUDIT_STATUS"
