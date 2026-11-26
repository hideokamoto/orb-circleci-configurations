#!/usr/bin/env bash
# Checks specs/wporg_svn_deploy.qnt, the Quint model of the wporg_svn_deploy
# command's interaction with concurrent, failing and rerun release pipelines.
#
# - as_implemented: the simulator must find no violation of `safety`.
# - unguarded: the simulator must find one. If it stops failing, the model
#   has lost the behavior the command's version checks guard against.
#
# The seed is fixed so a run is reproducible. Usage: check-quint-spec.sh
# Requires quint on PATH (npm install -g @informalsystems/quint).
set -euo pipefail

spec="specs/wporg_svn_deploy.qnt"
run=(quint run --backend=typescript --seed=0x5eed --max-samples=20000 --max-steps=16 --invariant=safety)

quint typecheck "${spec}"

if ! "${run[@]}" --main=as_implemented "${spec}"; then
    echo "NG  as_implemented: the model of the command violates safety (trace above)." >&2
    exit 1
fi
echo "ok  as_implemented: no violation of safety found"

if "${run[@]}" --main=unguarded "${spec}" > /tmp/quint-unguarded.log 2>&1; then
    cat /tmp/quint-unguarded.log
    echo "NG  unguarded: expected a violation of safety, found none." >&2
    exit 1
fi
grep -q "violation" /tmp/quint-unguarded.log || { cat /tmp/quint-unguarded.log; echo "NG  unguarded: quint failed without reporting a violation." >&2; exit 1; }
echo "ok  unguarded: violation of safety found, as expected"
