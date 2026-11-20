# configurations

[![CircleCI Build Status](https://circleci.com/gh/hideokamoto/orb-circleci-configurations.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/hideokamoto/orb-circleci-configurations) [![CircleCI Orb Version](https://badges.circleci.com/orbs/hideokamoto/configurations.svg)](https://circleci.com/developer/orbs/orb/hideokamoto/configurations) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/hideokamoto/orb-circleci-configurations/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

`hideokamoto/configurations` collects CI/CD building blocks that were previously
duplicated across several projects' CircleCI Config Source YAML files, and
packages them as reusable orb commands, jobs, and executors. Once published,
it will provide:

- **Deploy markers** — wrapping a deployment's steps with `circleci run
  release` plan / start / success / failure updates, so CircleCI Deploys
  history stays accurate even when a deploy is canceled or fails partway
  through.
- **Path-based skip logic** — skipping a job when the changed files don't
  match a given pattern, with a deterministic base-revision / tag fallback
  chain.
- **npm publish over OIDC** — publishing packages without a long-lived npm
  token, using CircleCI's OIDC identity federation.
- **AWS CDK and Cloudflare Workers deploy jobs** — parameterized deploy /
  cancel jobs for both targets, including an arm64 Docker Buildx variant for
  CDK.
- **GitHub Release automation** — resolving the deploy tag for a commit,
  generating release notes from CircleCI Deploy Diff Summaries (with a
  `gh --generate-notes` fallback), and creating the GitHub Release
  idempotently.
- **AI-DLC config validation** — validating a repository's AI-DLC workflow
  state as a CI job.
- **SBOM generation** — producing a CycloneDX SBOM with Trivy and forwarding
  it to a webhook (e.g. Port).

This repository is in **Phase 0** of its migration: besides the digest-pinned
base executors, a dependency-audit command/job has also landed early. The
rest of the items listed above land in later phases (tracked in this repo's
issues) and this README's component list will grow to match as they ship.
Each component's own `description` (visible via `circleci orb info` and the
orb registry) is the source of truth for its exact contract; this README is
the map, not the spec.

---

## Current components

| Type | Name | Purpose |
| --- | --- | --- |
| executor | `base_pinned` | Digest-pinned `cimg/base` image for lightweight, non-language-specific steps. |
| executor | `trivy` | Digest-pinned `aquasec/trivy` image for SBOM generation and vulnerability scanning. |
| command | `audit_deps` | Detects the checkout's package manager (pnpm/npm) and runs its security audit. |
| command | `chunk_audit_fix` | Asks CircleCI's Chunk agent to open a `fix(deps):` PR after a failed dependency audit. |
| command | `npm_publish_oidc` | Publishes an npm package via npm Trusted Publishing (OIDC), without a long-lived npm token. |
| job | `dependency_audit` | Runs `audit_deps`, then on failure `chunk_audit_fix` and a Slack notification. |

Both executors pin their Docker image by digest rather than by a mutable tag
(such as `:current`), so a given commit's CI behavior stays reproducible over
time. See each executor's `description` in `src/executors/` for the full
update procedure (monthly tag check for `base_pinned`, Aqua Security advisory
review for `trivy`); in short:

1. Pull the new tag and resolve its current digest:
   ```bash
   docker pull cimg/base:<new-tag>
   docker inspect --format='{{index .RepoDigests 0}}' cimg/base:<new-tag>

   # Trivy: same idea, review Aqua Security's advisories for the new tag first
   docker pull aquasec/trivy:<new-tag>
   docker inspect --format='{{index .RepoDigests 0}}' aquasec/trivy:<new-tag>
   ```
2. Update the executor's `digest` parameter default (not the tag reference
   in an `image:` field — both executors only hold the digest there, pinned
   via the `digest` parameter) together with the corresponding tag mentioned
   in that parameter's own `description` — never the digest alone, since that
   would silently decouple the human-readable tag from what actually runs.

## `src/` layout and development flow

```
src/
  @orb.yml        # description / display / imported orbs (node, aws-cli, gh)
  commands/       # reusable step sequences (added from Phase 1)
  jobs/           # ready-to-call jobs (added from Phase 2)
  executors/      # base_pinned, trivy
  scripts/        # shell backing commands, included via <<include(...)>> (added from Phase 1)
  tests/          # BATS unit tests for scripts, run by circleci/bats in CI
  examples/       # usage examples shown on the orb registry page
```

Design rationale for each component — why a parameter exists, why a piece of
logic behaves the way it does — lives in that component's `description` field
(orb registry pages don't preserve YAML comments) and, where broader context
is useful, in this README.

Before opening a PR, run the same checks CI runs, from the repository root:

```bash
# Pack the orb source into a single orb.yml and validate it
circleci orb pack src > /tmp/orb.yml
circleci orb validate /tmp/orb.yml --skip-update-check

# Lint shell scripts backing commands (skips cleanly when none exist yet)
if compgen -G 'src/scripts/*.sh' > /dev/null; then shellcheck src/scripts/*.sh; fi

# Run BATS unit tests
bats src/tests

# Lint YAML style
yamllint -c .yamllint src .circleci
```

`.circleci/config.yml` runs the equivalent checks (`orb-tools/lint`,
`orb-tools/pack`, `orb-tools/review`, `shellcheck/check`, `bats/run`) on every
push. `.circleci/test-deploy.yml` is injected with the packed orb and runs
integration-style jobs against real orb components (see
`test_base_pinned_executor` / `test_trivy_executor`) before any dev or
production publish.

---

## Resources

[CircleCI Orb Registry Page](https://circleci.com/developer/orbs/orb/hideokamoto/configurations) - The official registry page of this orb for all versions, executors, commands, and jobs described.

[CircleCI Orb Docs](https://circleci.com/docs/orb-intro/#section=configuration) - Docs for using, creating, and publishing CircleCI Orbs.

### How to Contribute

We welcome [issues](https://github.com/hideokamoto/orb-circleci-configurations/issues) to and [pull requests](https://github.com/hideokamoto/orb-circleci-configurations/pulls) against this repository!

### How to Publish An Update

Production versions are released automatically when a pull request is
merged to `main`; nobody pushes a tag or drafts a GitHub Release by hand, so
a merge made by an AI coding agent releases exactly like one made by a
person. The `release` job in `.circleci/test-deploy.yml` runs
[semantic-release](https://semantic-release.gitbook.io/) (configured in
`.releaserc.json`) after every test job and `orb-tools/pack` pass on `main`:

1. The next version is derived from the
   [Conventional Commits](https://conventionalcommits.org/) since the last
   `v*` tag: `feat` → minor, `fix` / `perf` → patch, `!` or a
   `BREAKING CHANGE:` footer → major. A merge containing only `docs`,
   `chore`, `ci`, `test`, `refactor`, ... commits releases nothing. Use
   squash-and-merge with a Conventional Commit title so each merge is one
   commit.
2. The packed orb is published to the registry as
   `hideokamoto/configurations@<version>` **before** any tag exists, so a
   failed publish leaves nothing behind and re-running the job retries the
   same version.
3. The `v<version>` tag and a GitHub Release (with generated notes) are then
   created as a record of what was published.

With no `v*` tag in the history yet, the first release is `1.0.0`.
Prerequisites: the `circleci` context provides `CIRCLE_TOKEN` (orb
publishing) and the `github` context provides `GITHUB_TOKEN`
(`contents:write` on this repository).

If the tag push fails after the orb was published (re-running then stops
at "version already exists"), push the missing tag at the commit the
release job ran on (`git tag v<version> <sha> && git push origin
v<version>`), and the next merge continues from it.

### Development Orbs

`.circleci/test-deploy.yml` already publishes a [Development orb](https://circleci.com/docs/orb-concepts/#development-orbs)
on every non-tag build (`pub_type: dev`, requiring `orb-tools/pack` and all
test jobs, using the `circleci` context) — no changes are needed to try an
in-progress change before a release:

- **Every branch** publishes `hideokamoto/configurations@dev:<commit-SHA1>`.
  Use this to try a specific commit or an open PR from another repository.
- **Only `main`** also moves `hideokamoto/configurations@dev:alpha`, so
  `dev:alpha` always means "latest reviewed `main`" and a PR build can never
  change what `dev:alpha` consumers run.

Dev orbs expire 90 days after their last publish, so long-lived pipelines
should not depend on a dev label. The job output contains a link to the
Development orb Registry page. See
[orb-tools/publish](https://circleci.com/developer/orbs/orb/circleci/orb-tools#jobs-publish)
for the full set of parameters (e.g. `enable_pr_comment`, `github_token`) if
you want to adapt this for a different repository.
