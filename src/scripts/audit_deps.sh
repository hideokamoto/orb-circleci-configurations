#!/usr/bin/env bash
# Detect the checkout's package manager from its lockfile and run its security
# audit. Exits with the audit's own exit code so the enclosing step fails when
# advisories at or above DEP_AUDIT_LEVEL exist.
#
# Environment:
#   DEP_AUDIT_LEVEL       audit severity threshold (default: high)
#   DEP_AUDIT_PM_OVERRIDE "pnpm" or "npm" to skip lockfile auto-detection
#   BASH_ENV              DEP_AUDIT_PM is exported here for later steps

set -uo pipefail

detect_pm() {
  if [[ -f pnpm-lock.yaml || -f pnpm-workspace.yaml ]]; then
    echo pnpm
  elif [[ -f package-lock.json || -f npm-shrinkwrap.json ]]; then
    echo npm
  elif [[ -f bun.lock || -f bun.lockb ]]; then
    echo bun
  elif [[ -f yarn.lock ]]; then
    echo yarn
  elif [[ -f package.json ]]; then
    # No lockfile at all: assume npm, the most common case.
    echo npm
  else
    return 1
  fi
}

DEP_AUDIT_LEVEL="${DEP_AUDIT_LEVEL:-high}"
DEP_AUDIT_PM="${DEP_AUDIT_PM_OVERRIDE:-}"
if [[ -z "$DEP_AUDIT_PM" || "$DEP_AUDIT_PM" == "auto" ]]; then
  DEP_AUDIT_PM="$(detect_pm)" || {
    echo "[dependency-audit] no package.json or lockfile found; cannot pick a package manager"
    exit 2
  }
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
    AUDIT_CMD=(npm audit --audit-level="$DEP_AUDIT_LEVEL")
    ;;
  *)
    echo "[dependency-audit] '$DEP_AUDIT_PM' is not supported (pnpm and npm only)"
    exit 2
    ;;
esac

echo "[dependency-audit] running: ${AUDIT_CMD[*]}"
"${AUDIT_CMD[@]}"
