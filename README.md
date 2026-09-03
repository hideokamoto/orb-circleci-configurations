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

This repository is in **Phase 0** of its migration: the orb currently ships
only the digest-pinned base executors described below. Commands, jobs, and
the remaining executors land in later phases (tracked in this repo's issues)
and this README's component list will grow to match as they ship. Each
component's own `description` (visible via `circleci orb info` and the orb
registry) is the source of truth for its exact contract; this README is the
map, not the spec.

---

## Current components

| Type | Name | Purpose |
| --- | --- | --- |
| executor | `base_pinned` | Digest-pinned `cimg/base` image for lightweight, non-language-specific steps. |
| executor | `trivy` | Digest-pinned `aquasec/trivy` image for SBOM generation and vulnerability scanning. |

Both executors pin their Docker image by digest rather than by a mutable tag
(such as `:current`), so a given commit's CI behavior stays reproducible over
time. See each executor's `description` in `src/executors/` for the update
procedure — in short, update the tag and digest together after confirming the
new image is safe to use.

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
`test_base_pinned_executor` / `test_trivy_executor`) before a release publish.

---

## Resources

[CircleCI Orb Registry Page](https://circleci.com/developer/orbs/orb/hideokamoto/configurations) - The official registry page of this orb for all versions, executors, commands, and jobs described.

[CircleCI Orb Docs](https://circleci.com/docs/orb-intro/#section=configuration) - Docs for using, creating, and publishing CircleCI Orbs.

### How to Contribute

We welcome [issues](https://github.com/hideokamoto/orb-circleci-configurations/issues) to and [pull requests](https://github.com/hideokamoto/orb-circleci-configurations/pulls) against this repository!

### How to Publish An Update
1. Merge pull requests with desired changes to the main branch.
    - For the best experience, squash-and-merge and use [Conventional Commit Messages](https://conventionalcommits.org/).
2. Find the current version of the orb.
    - You can run `circleci orb info hideokamoto/configurations | grep "Latest"` to see the current version.
3. Create a [new Release](https://github.com/hideokamoto/orb-circleci-configurations/releases/new) on GitHub.
    - Click "Choose a tag" and _create_ a new [semantically versioned](http://semver.org/) tag. (ex: v1.0.0)
      - We will have an opportunity to change this before we publish if needed after the next step.
4.  Click _"+ Auto-generate release notes"_.
    - This will create a summary of all of the merged pull requests since the previous release.
    - If you have used _[Conventional Commit Messages](https://conventionalcommits.org/)_ it will be easy to determine what types of changes were made, allowing you to ensure the correct version tag is being published.
5. Now ensure the version tag selected is semantically accurate based on the changes included.
6. Click _"Publish Release"_.
    - This will push a new tag and trigger your publishing pipeline on CircleCI.

### Development Orbs

Prerequisites:

- An initial sevmer deployment must be performed in order for Development orbs to be published and seen in the [Orb Registry](https://circleci.com/developer/orbs).

A [Development orb](https://circleci.com/docs/orb-concepts/#development-orbs) can be created to help with rapid development or testing. To create a Development orb, change the `orb-tools/publish` job in `test-deploy.yml` to be the following:

```yaml
- orb-tools/publish:
    orb_name: hideokamoto/configurations
    vcs_type: << pipeline.project.type >>
    pub_type: dev
    # Ensure this job requires all test jobs and the pack job.
    requires:
      - orb-tools/pack
      - command-test
    context: orb-publishing
    filters: *filters
```

The job output will contain a link to the Development orb Registry page. The parameters `enable_pr_comment` and `github_token` can be set to add the relevant publishing information onto a pull request. Please refer to the [orb-tools/publish](https://circleci.com/developer/orbs/orb/circleci/orb-tools#jobs-publish) documentation for more information and options.
