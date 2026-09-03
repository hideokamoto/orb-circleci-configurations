#!/usr/bin/env bash
set -euo pipefail

# npm_publish_oidc.sh
#
# Publishes an npm package using npm Trusted Publishing (OIDC) instead of a
# long-lived npm token. Mirrors the "Publish to npm (OIDC trusted
# publishing)" step duplicated across circleci-configurations'
# workflows/publish/*.yaml (npm-polyrepo, npm-polyrepo-bun and
# npm-polyrepo-release-please all share the exact step body; npm-monorepo
# differs only in swapping `npm publish` for `pnpm changeset:publish`, which
# is why the publish command is parameterized rather than hardcoded).

publish() {
  # Legacy token auth must be fully disabled before requesting the OIDC
  # token: if NODE_AUTH_TOKEN / NPM_TOKEN are set (even to an empty string),
  # or a committed .npmrc still carries a
  # `//registry.npmjs.org/:_authToken=...` line, npm treats the registry as
  # token-authenticated and skips the OIDC exchange entirely -- surfacing as
  # a confusing ENEEDAUTH/E404 instead of a clear "no OIDC" error. `unset`
  # under `set -u` is safe even when the variables are already undefined.
  unset NODE_AUTH_TOKEN NPM_TOKEN

  local audience
  audience="$(circleci env subst "${PARAM_AUDIENCE}")"

  # `circleci` on PATH inside CircleCI-hosted images resolves to the bundled
  # *local* CLI (used for e.g. `circleci config validate`), which shadows
  # the build-agent CLI that actually knows how to mint OIDC tokens. `run
  # oidc get` only exists on the build-agent binary, so it must be invoked
  # by its full path rather than through PATH lookup. The path is
  # overridable via CIRCLECI_CLI_PATH so BATS tests can point it at a stub
  # instead of a real /usr/bin/circleci.
  local cli
  cli="${CIRCLECI_CLI_PATH:-/usr/bin/circleci}"

  local npm_id_token
  npm_id_token="$("${cli}" run oidc get --claims "{\"aud\": \"${audience}\"}")"

  # Fail fast, before `npm publish` turns an empty token into an opaque
  # registry error. The token value itself is never echoed here or below --
  # only its emptiness is observable in the log.
  if [ -z "${npm_id_token}" ]; then
    echo "Failed to acquire OIDC token: NPM_ID_TOKEN is empty." >&2
    echo "Ensure this job runs with a Context that grants npm Trusted Publishing OIDC access, that OIDC is enabled for this org/project, and that the package has a Trusted Publisher registered for CircleCI on npmjs.com." >&2
    exit 1
  fi

  export NPM_ID_TOKEN="${npm_id_token}"

  # With NPM_ID_TOKEN set, npm CLI auto-detects the CircleCI OIDC
  # environment and exchanges it for a short-lived publish token. npm's
  # general Trusted Publishing floor is >= 11.5.1, but CircleCI-specific
  # OIDC detection was added in npm/cli PR #8925 and only ships from
  # 11.11.0 onward, so 11.11.0 is the effective floor on CircleCI
  # (cimg/node:24.19 ships npm 11.17.0 and satisfies it out of the box).
  # Do not append --provenance to publish_command: npm explicitly excludes
  # CircleCI (`!ciInfo.CIRCLE`) from automatic provenance generation, and
  # npm's own docs state provenance generation is not currently supported
  # for CircleCI, so the flag is a guaranteed no-op there. Package
  # visibility (public vs restricted) is controlled by the package's own
  # publishConfig.access, not by this command.
  local cmd
  cmd="$(circleci env subst "${PARAM_PUBLISH_COMMAND}")"
  bash -c "${cmd}"
}

main() {
  publish
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
