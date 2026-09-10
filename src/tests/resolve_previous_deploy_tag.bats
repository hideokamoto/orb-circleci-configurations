#!/usr/bin/env bats
# Covers resolve_previous_deploy_tag.sh: the ancestor-walk approach must
# find the true previous release tag even when a naive `--sort=-refname` or
# `--sort=-creatordate` would pick the wrong one, must find none on a first
# release, and must walk correctly through a merge commit. Also covers the
# $BASH_ENV write path's safety: the release tag must be excluded from the
# candidate list as a literal string (not an unescaped regex), the
# output_env parameter must be validated as a safe shell identifier before
# anything is written, and the exported previous-tag value must round-trip
# safely through export/source even when it contains shell metacharacters.
#
# Note on fixture shape: `git log --pretty=format:'%H'` (as used by the
# unmodified migration source) does not terminate its final output line
# with a newline, so `while IFS= read -r sha` silently drops the walk's very
# last (oldest) ancestor. The script deliberately deviates from the source
# here by using `--pretty=tformat:'%H'` instead, which fixes that false
# negative (see the command description and PR description for detail); the
# "tag on the walk's oldest ancestor" test below exists specifically to
# pin that fix. Every *other* fixture still keeps an extra, untagged root
# commit ahead of whichever commit carries the tag under test, purely so
# those tests stay focused on what they're each named for rather than
# incidentally depending on this fix too.

# Runs before every @test. Builds an isolated scratch git repository (so
# tests never touch this orb repo's own history), points CIRCLECI_CLI at a
# stub standing in for the build-agent CLI at /usr/bin/circleci, points
# BASH_ENV at a throwaway file the script under test can safely append to,
# and exports the default PARAM_* wiring the command's run step would set.
# Side effects: creates TEST_TMP (a mktemp -d directory) and cds into
# TEST_TMP/repo; exports PATH, BASH_ENV, CIRCLECI_CLI, GIT_AUTHOR_*/
# GIT_COMMITTER_* and PARAM_* into the test's environment.
setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT="${REPO_ROOT}/src/scripts/resolve_previous_deploy_tag.sh"

    TEST_TMP="$(mktemp -d)"
    STUB_BIN="${TEST_TMP}/bin"
    mkdir -p "${STUB_BIN}"

    # Minimal build-agent CLI stub, standing in for /usr/bin/circleci. Only
    # `env subst` is exercised by the script, and it only needs to hand the
    # literal parameter value back through, since none of the parameter
    # defaults or test values contain a pipeline-value substitution pattern.
    cat >"${STUB_BIN}/circleci" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "env" ] && [ "$2" = "subst" ]; then
    printf '%s' "$3"
    exit 0
fi
echo "circleci stub: unhandled invocation: $*" >&2
exit 1
STUB
    chmod +x "${STUB_BIN}/circleci"
    # The script calls the CLI by full path (cimg/base does not put
    # `circleci` on PATH), so point it at the stub directly rather than
    # relying on PATH resolution.
    CIRCLECI_CLI="${STUB_BIN}/circleci"
    export CIRCLECI_CLI

    REPO_DIR="${TEST_TMP}/repo"
    mkdir -p "${REPO_DIR}"
    cd "${REPO_DIR}" || exit 1
    git init -q
    git config user.name "Test User"
    git config user.email "test@example.com"
    git config commit.gpgsign false
    git config tag.gpgsign false
    DEFAULT_BRANCH="$(git symbolic-ref --short HEAD)"
    export GIT_AUTHOR_NAME="Test User" GIT_AUTHOR_EMAIL="test@example.com"
    export GIT_COMMITTER_NAME="Test User" GIT_COMMITTER_EMAIL="test@example.com"

    BASH_ENV="${TEST_TMP}/bash_env"
    : >"${BASH_ENV}"
    export BASH_ENV

    # Default parameter wiring, as the command's run step would set it.
    export PARAM_TAG_REGEX='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]{7}$'
    export PARAM_RELEASE_TAG_ENV="RELEASE_TAG"
    export PARAM_OUTPUT_ENV="PREV_RELEASE_TAG"
}

# Runs after every @test, regardless of pass/fail. Returns to the directory
# bats started in (so a later test's `cd` in setup() isn't relative to a
# now-deleted directory) and removes the scratch TEST_TMP tree created by
# setup().
teardown() {
    cd "${BATS_TEST_DIRNAME}" || true
    rm -rf "${TEST_TMP}"
}

# Creates one commit in the scratch repo built by setup(): appends a unique
# line (message plus $RANDOM) to file.txt, in append mode so each commit's
# tree differs from the last, then stages and commits it non-interactively.
# Honors GIT_AUTHOR_DATE / GIT_COMMITTER_DATE from the environment when a
# test has exported them, so tests can force identical or ordered commit
# timestamps. Args: $1 = commit message. Side effects: mutates file.txt and
# advances HEAD in the current git repo.
make_commit() {
    local message="$1"
    echo "${message}-${RANDOM}" >>"file.txt"
    git add file.txt
    git commit -q -m "${message}"
}

# Sources $BASH_ENV in a fresh, isolated bash subshell and echoes the
# resulting value of the named variable, so tests can assert against the
# *value* a real downstream step would see after sourcing $BASH_ENV rather
# than the exact quoting/escaping style the script chose to write (which is
# an implementation detail once the line is shell-safe; printf %q only adds
# quoting when a value actually needs it). Also doubles as the vehicle for
# the export/source round-trip safety regression test: if the script ever
# stopped shell-escaping prev_tag, a malicious tag value could execute
# arbitrary commands during this very `source`. Args: $1 = variable name to
# read after sourcing. Output: the variable's value on stdout, empty string
# if it was left unset.
read_bash_env_var() {
    local var_name="$1"
    bash -c "source \"${BASH_ENV}\" && printf '%s' \"\${${var_name}:-}\""
}

@test "same-day multiple deploys: picks the true ancestor over the lexicographically largest sha7" {
    make_commit "c1"
    git tag "2026.03.01-fffffff" # would win a naive --sort=-refname (largest sha7)
    make_commit "c2"
    git tag "2026.03.01-1111111" # the true immediate previous release
    make_commit "c3"
    git tag "2026.03.01-9999999" # current release
    export RELEASE_TAG="2026.03.01-9999999"

    source "${SCRIPT}"
    run main
    [ "$status" -eq 0 ]

    [ "$(read_bash_env_var PREV_RELEASE_TAG)" = "2026.03.01-1111111" ]
}

@test "same-second tags: ancestry, not creatordate, decides the previous tag" {
    make_commit "c1"
    git tag "2026.04.01-1000000"

    # c2 and c3 land on the exact same second, so --sort=-creatordate would
    # be unable to order them reliably.
    export GIT_AUTHOR_DATE="2026-04-01T12:00:00+09:00"
    export GIT_COMMITTER_DATE="2026-04-01T12:00:00+09:00"
    make_commit "c2"
    git tag "2026.04.01-2000000"
    make_commit "c3"
    git tag "2026.04.01-3000000"
    unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE

    export RELEASE_TAG="2026.04.01-3000000"

    source "${SCRIPT}"
    run main
    [ "$status" -eq 0 ]

    [ "$(read_bash_env_var PREV_RELEASE_TAG)" = "2026.04.01-2000000" ]
}

@test "previous release tag is on the walk's oldest (last-enumerated) ancestor" {
    # No untagged root commit here, deliberately: c1 is both the tag under
    # test AND the very last line `git log --pretty=...:'%H'` emits for
    # this history, which is exactly the line `format:` leaves without a
    # trailing newline. Before the tformat: fix, `while read` would drop
    # this commit's loop iteration and this test would fail with no
    # PREV_RELEASE_TAG exported at all.
    make_commit "c1"
    git tag "2026.08.01-c1c1c1c" # the true previous release, and the oldest commit
    make_commit "c2"
    git tag "2026.08.01-c2c2c2c" # current release
    export RELEASE_TAG="2026.08.01-c2c2c2c"

    source "${SCRIPT}"
    run main
    [ "$status" -eq 0 ]

    [ "$(read_bash_env_var PREV_RELEASE_TAG)" = "2026.08.01-c1c1c1c" ]
}

@test "first release: no matching ancestor tag, nothing is exported" {
    make_commit "c1"
    git tag "2026.05.01-abc0000"
    export RELEASE_TAG="2026.05.01-abc0000"

    source "${SCRIPT}"
    run main
    [ "$status" -eq 0 ]

    ! grep -q 'PREV_RELEASE_TAG' "${BASH_ENV}"
    [[ "$output" == *"no previous release tag found"* ]]
}

@test "merge commit history: walks through both parents to find the previous tag" {
    make_commit "root" # untagged root ancestor; see file header note
    make_commit "base"
    git tag "2026.06.01-0000abc" # the true previous release

    git checkout -q -b feature
    make_commit "feature-work"
    git checkout -q "${DEFAULT_BRANCH}"
    git merge -q --no-ff -m "merge feature" feature
    git tag "2026.06.01-mmmmerg"
    export RELEASE_TAG="2026.06.01-mmmmerg"

    source "${SCRIPT}"
    run main
    [ "$status" -eq 0 ]

    [ "$(read_bash_env_var PREV_RELEASE_TAG)" = "2026.06.01-0000abc" ]
}

@test "release tag env var missing: fails fast with a clear message instead of resolving silently" {
    make_commit "c1"
    unset RELEASE_TAG

    source "${SCRIPT}"
    run main
    [ "$status" -eq 1 ]
    [[ "$output" == *'$RELEASE_TAG is not set'* ]]
}

@test "custom release_tag_env and output_env parameter names are honored" {
    make_commit "root" # untagged root ancestor; see file header note
    make_commit "c1"
    git tag "2026.07.01-aaaaaaa"
    make_commit "c2"
    git tag "2026.07.01-bbbbbbb"

    export PARAM_RELEASE_TAG_ENV="MY_RELEASE_TAG"
    export PARAM_OUTPUT_ENV="MY_PREV_TAG"
    export MY_RELEASE_TAG="2026.07.01-bbbbbbb"

    source "${SCRIPT}"
    run main
    [ "$status" -eq 0 ]

    [ "$(read_bash_env_var MY_PREV_TAG)" = "2026.07.01-aaaaaaa" ]
}

@test "release_tag treated as a literal exclusion, not a regex: release.1 does not also exclude releaseX1" {
    # Guards against the release tag being passed to `grep -v` unescaped: as
    # an ERE, "release.1" would let "." match any character, so it would
    # wrongly also exclude an ancestor tag like "releaseX1" from the
    # candidate list.
    make_commit "root" # untagged root ancestor; see file header note
    make_commit "c1"
    git tag "releaseX1" # must NOT be excluded by a "release.1" release tag
    make_commit "c2"
    git tag "release.1" # current release; "." must be matched literally

    export PARAM_TAG_REGEX='.*'
    export RELEASE_TAG="release.1"

    source "${SCRIPT}"
    run main
    [ "$status" -eq 0 ]

    [ "$(read_bash_env_var PREV_RELEASE_TAG)" = "releaseX1" ]
}

@test "output_env resolving to an unsafe identifier is rejected before \$BASH_ENV is touched" {
    make_commit "c1"
    git tag "2026.09.01-abc0000"
    export RELEASE_TAG="2026.09.01-abc0000"
    export PARAM_OUTPUT_ENV='PREV_TAG; rm -rf /tmp/should-not-run'

    source "${SCRIPT}"
    run main
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a safe environment variable name"* ]]
    [ ! -s "${BASH_ENV}" ]
}

@test "output_env resolving to a lowercase or digit-led name is rejected" {
    make_commit "c1"
    git tag "2026.09.02-abc0000"
    export RELEASE_TAG="2026.09.02-abc0000"
    export PARAM_OUTPUT_ENV='prev_release_tag'

    source "${SCRIPT}"
    run main
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a safe environment variable name"* ]]
    [ ! -s "${BASH_ENV}" ]
}

@test "syntactically invalid tag_regex is rejected before the commit history walk, not treated as a first release" {
    # Regression test: an invalid ERE (unbalanced bracket expression) makes
    # every `grep -E "${tag_regex}"` call inside the walk fail with exit
    # status 2, which the walk's trailing `|| true` previously swallowed
    # right along with the `while read` loop's expected EOF status,
    # producing an empty prev_tag indistinguishable from a legitimate first
    # release. This must fail fast instead, before any history walk runs.
    make_commit "root" # untagged root ancestor; see file header note
    make_commit "c1"
    git tag "2026.09.10-abc0000" # would be a legitimate previous release
    make_commit "c2"
    git tag "2026.09.10-def0000"
    export PARAM_TAG_REGEX='[' # unbalanced bracket expression: not a valid ERE
    export RELEASE_TAG="2026.09.10-def0000"

    source "${SCRIPT}"
    run main
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a valid extended regular expression"* ]]
    [ ! -s "${BASH_ENV}" ]
}

@test "prev_tag containing shell metacharacters round-trips safely through export and source" {
    # Regression test for the $BASH_ENV injection risk: an unescaped tag
    # value embedding a command substitution would execute when a later
    # step sources $BASH_ENV. printf %q must render it as an inert string.
    #
    # The tag literally contains the six characters `${IFS}` (no actual
    # space) so that `git tag` (which rejects tag names with a real space
    # byte) accepts it, while the payload is still a live command
    # substitution once *sourced* by bash, where `${IFS}` expands to
    # whitespace and would run `touch INJECTED` if the export line were not
    # shell-escaped.
    make_commit "root" # untagged root ancestor; see file header note
    make_commit "c1"
    git tag 'evil-$(touch${IFS}INJECTED)-tag'
    make_commit "c2"
    git tag "release-current"

    export PARAM_TAG_REGEX='.*'
    export RELEASE_TAG="release-current"

    source "${SCRIPT}"
    run main
    [ "$status" -eq 0 ]

    [ "$(read_bash_env_var PREV_RELEASE_TAG)" = 'evil-$(touch${IFS}INJECTED)-tag' ]
    [ ! -e "INJECTED" ]
}
