# configurations

[![CircleCI Build Status](https://circleci.com/gh/hideokamoto/orb-circleci-configurations.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/hideokamoto/orb-circleci-configurations) [![CircleCI Orb Version](https://badges.circleci.com/orbs/hideokamoto/configurations.svg)](https://circleci.com/developer/orbs/orb/hideokamoto/configurations) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/hideokamoto/orb-circleci-configurations/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

`hideokamoto/configurations` collects CI/CD building blocks that were previously
duplicated across several projects' CircleCI Config Source YAML files, and
packages them as reusable orb commands, jobs, and executors. It covers:

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
  cancel jobs for both targets (planned; see below).
- **GitHub Release automation** — resolving the deploy tag for a commit,
  generating release notes from CircleCI Deploy Diff Summaries (with a
  `gh --generate-notes` fallback), and creating the GitHub Release
  idempotently.
- **AI-DLC config validation** — validating a repository's AI-DLC workflow
  state as a CI job (planned; see below).

Migration status (tracked in the [epic, #1](https://github.com/hideokamoto/orb-circleci-configurations/issues/1)):

- **Released:** the digest-pinned executors, the Phase 1 commands, and the
  `dependency_audit` job, all listed under [Current components](#current-components).
- **Planned:** in the epic's order, the Phase 2 jobs that need no secrets
  (#19 `node_test`, #20 `cdk_validate`, #29 `aidlc_validate`), then the
  Phase 3 examples and `v1.0.0` (#31), then the Phase 4 deploy / publish
  jobs, released as minor versions after `v1.0.0` (#21–#28: CDK / cdkd /
  Cloudflare Workers deploy and cancel, GitHub Release, npm release flows).
  This README's component list grows to match as they ship.
- **Not planned:** the arm64 Docker Buildx support for CDK (#7; the one
  pipeline that uses the arm64 template keeps its Config Source steps), SBOM
  generation and sending it to Port (#17, #30; no pipeline uses the SBOM
  template), a bun install command (#12; use `circleci/node`'s
  `install-bun`), and a skip-on-release-commit command (#16).

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
| command | `install_cdkd` | Installs a version-pinned cdkd CLI. |
| command | `create_github_release` | Idempotently creates a GitHub Release for the deploy tag resolved by `resolve_deploy_tag`. |
| command | `resolve_previous_deploy_tag` | Resolves the release tag before the current one from the commit graph. |
| command | `generate_release_notes_from_deploy_diff` | Installs the standalone CircleCI CLI (sha256-pinned), then generates release notes from CircleCI Deploy Diff Summaries, falling back to `gh release create --generate-notes`. |
| command | `npm_publish_oidc` | Publishes an npm package via npm Trusted Publishing (OIDC), without a long-lived npm token. |
| command | `deploy_marker_update` | Updates a CircleCI Deploys release marker's status (used by `with_deploy_marker`, or standalone). |
| command | `with_deploy_marker` | Wraps deployment steps in a CircleCI Deploys release marker (plan, RUNNING, then SUCCESS or FAILED). |
| command | `skip_unless_changed` | Halts the job based on the paths changed between the base and head revisions, per `mode` and `pattern`: by default (`skip_if_only_matches`) it halts when every changed path matches `pattern` (e.g. docs-only changes); `skip_unless_matches` halts when no changed path matches. |
| command | `resolve_deploy_tag` | Reads back the deploy tag pushed to a commit and exports it to `$BASH_ENV`. |
| command | `push_deploy_tag` | Pushes a date-stamped release tag for the deployed commit (default UTC `YYYY.MM.DD-<sha7>`), skipping if it already exists. If you override `date_format` / `sha_length`, keep `skip_unless_changed`'s `deploy_tag_glob` and the `tag_regex` of `resolve_deploy_tag` / `resolve_previous_deploy_tag` in sync. |
| command | `cdk_synth` | Runs `cdk synth` against a placeholder AWS account/region, so a validate job can synth without real AWS credentials. |
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

# Check that boolean parameters passed to scripts are tested with "1"
bash .circleci/scripts/check-bool-env-tests.sh
```

`.circleci/config.yml` runs the equivalent checks (`orb-tools/lint`,
`orb-tools/pack`, `orb-tools/review`, `shellcheck/check`, `bats/run`,
`check-bool-env-tests`) on every push.

A boolean parameter placed in a run step's `environment:` reaches the script
as `"1"` / `"0"`, not `"true"` / `"false"`, so scripts accept both forms
(`case ... in 1 | true)`). `check-bool-env-tests` fails when such a parameter
has no BATS test in `src/tests/<script>.bats` that sets it to `"1"`. `.circleci/test-deploy.yml` is injected with the packed orb and runs
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

CI and release run as two separate CircleCI pipelines, each with its own
config file (managed in hideokamoto/circleci-infra):

| Pipeline | Triggered by | Config | Publishes |
| --- | --- | --- | --- |
| `ci` | pull request opened (non-draft), marked ready for review, or pushed to while not a draft | `.circleci/config.yml` → `.circleci/test-deploy.yml` | `hideokamoto/configurations@dev:<commit-SHA1>` |
| `release` | push to `main` (a merged pull request) | `.circleci/release.yml` → test-deploy's tests + `.circleci/release-workflow.yml` | `hideokamoto/configurations@<version>` |

The integration tests are defined once, in `.circleci/test-deploy.yml`.
`.circleci/scripts/build-release-config.sh` builds the release pipeline's
config from it: the same test jobs and `orb-tools/pack`, with the dev orb
publish replaced by the `release` job, which requires all of them. A test
job added to `test-deploy.yml` therefore gates both the dev orb and the
release. The `check-release-config` job in `.circleci/config.yml` builds
that config on every pull request.

Production versions are released automatically when a pull request is
merged to `main`; nobody pushes a tag or drafts a GitHub Release by hand, so
a merge made by an AI coding agent releases exactly like one made by a
person. The `release` job runs
[semantic-release](https://semantic-release.gitbook.io/) (configured in
`.releaserc.json`):

1. The next version is derived from the
   [Conventional Commits](https://conventionalcommits.org/) since the last
   `v*` tag: `feat` → minor, `fix` / `perf` → patch. A merge containing only
   `docs`, `chore`, `ci`, `test`, `refactor`, ... commits releases nothing.
   Use squash-and-merge with a Conventional Commit title so each merge is
   one commit.
2. The packed orb is published to the registry as
   `hideokamoto/configurations@<version>` **before** any tag exists, so a
   failed publish leaves no tag and re-running the job retries the same
   version.
3. The `v<version>` tag and a GitHub Release (with generated notes) are then
   created as a record of what was published.

The orb is pre-GA, so versions stay at `0.x`:

- **First release.** semantic-release would start at `1.0.0`. When no `v*`
  tag exists yet, the release job tags the commit before the merge as
  `v0.0.0`, so the first release is `0.1.0`. semantic-release pushes that
  `v0.0.0` tag along with `v0.1.0`.
- **Breaking changes** (`!` or a `BREAKING CHANGE:` footer) bump the minor
  version while in `0.x` (`releaseRules` in `.releaserc.json`). To go GA,
  remove that rule; the next breaking change then releases `1.0.0`.

Prerequisites: the `circleci` context provides `CIRCLE_TOKEN` (orb
publishing) and the `github` context provides `GITHUB_TOKEN`
(`contents:write` on this repository).

If the tag push fails after the orb was published (re-running then stops
at "version already exists"), check that the registry has
`hideokamoto/configurations@<version>` built from the commit the release
job ran on, then push the missing tag at that commit
(`git tag v<version> <sha> && git push origin v<version>`); the next merge
continues from it.

### Development Orbs

The `ci` pipeline publishes a [Development orb](https://circleci.com/docs/orb-concepts/#development-orbs)
for every pull request build (`pub_type: dev`, requiring `orb-tools/pack`
and all test jobs, using the `circleci` context) — no changes are needed to
try an in-progress change before a release:

- **Every non-draft pull request** publishes
  `hideokamoto/configurations@dev:<commit-SHA1>` for its head commit (draft
  pull requests run nothing until they are marked ready for review). Use
  this to try a specific commit from another repository.
- There is no moving dev label (such as `dev:alpha`); use a released
  version, or a specific `dev:<commit-SHA1>`.

Dev orbs expire 90 days after their last publish, so long-lived pipelines
should not depend on a dev label. The job output contains a link to the
Development orb Registry page. See
[orb-tools/publish](https://circleci.com/developer/orbs/orb/circleci/orb-tools#jobs-publish)
for the full set of parameters (e.g. `enable_pr_comment`, `github_token`) if
you want to adapt this for a different repository.
