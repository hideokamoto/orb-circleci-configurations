#!/usr/bin/env bats
# Unit tests for scripts/wporg_svn_deploy.sh: publishes a built plugin
# directory to a WordPress.org-style SVN repository (trunk/, tags/<version>/,
# assets/) in one commit.
#
# Each test runs against a throwaway local repository made with `svnadmin
# create` and reached over file://, so nothing touches plugins.svn.wordpress.org
# and no network or real credentials are needed. svn and rsync must be on
# PATH (the bats/run job installs them in its setup steps).

# setup
#
# bats-core hook run before each @test. Creates a local SVN repository with
# the trunk/, tags/ and assets/ layout WordPress.org uses, a build directory
# holding a minimal plugin at version 1.2.3, and the PARAM_* and credential
# variables the script reads, then sources the script so wporg_svn_deploy()
# can be called directly without main() running.
# Arguments:
#   None.
# Outputs:
#   None of its own.
# Returns:
#   0 on success; a failing setup command errors the test.
# Side effects:
#   Creates TEST_DIR (repository, build and assets directories, an isolated
#   HOME so svn writes no auth cache or config outside it) and exports the
#   variables above.
setup() {
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/src/scripts/wporg_svn_deploy.sh"
  TEST_DIR="$(mktemp -d)"
  export HOME="${TEST_DIR}/home"
  mkdir -p "${HOME}"

  REPO="${TEST_DIR}/repo"
  REPO_URL="file://${REPO}"
  svnadmin create "${REPO}"
  svn mkdir --quiet -m "init" "${REPO_URL}/trunk" "${REPO_URL}/tags" "${REPO_URL}/assets"

  BUILD="${TEST_DIR}/build"
  mkdir -p "${BUILD}/includes"
  write_plugin 1.2.3
  echo "<?php // helper" > "${BUILD}/includes/helper.php"

  export PARAM_SLUG="my-plugin"
  export PARAM_BUILD_DIR="${BUILD}"
  export PARAM_MAIN_FILE=""
  export PARAM_ASSETS_DIR=""
  export PARAM_VERSION_ENV="RELEASE_VERSION"
  export PARAM_USERNAME_ENV="SVN_USERNAME"
  export PARAM_PASSWORD_ENV="SVN_PASSWORD"
  export PARAM_SVN_URL="${REPO_URL}/"
  export PARAM_DRY_RUN="0"
  export RELEASE_VERSION="1.2.3"
  export SVN_USERNAME="deployer"
  export SVN_PASSWORD="s3cret-value"

  # shellcheck source=/dev/null
  source "${SCRIPT}"
}

# teardown
#
# bats-core hook run after each @test. Removes TEST_DIR.
teardown() {
  rm -rf "${TEST_DIR}"
}

# write_plugin
#
# Writes my-plugin.php and readme.txt into BUILD with the given versions.
# Arguments:
#   $1 - the plugin header Version
#   $2 - the readme Stable tag (default: $1)
write_plugin() {
  cat > "${BUILD}/my-plugin.php" <<PHP
<?php
/**
 * Plugin Name: My Plugin
 * Version: $1
 */
PHP
  printf '=== My Plugin ===\nStable tag: %s\nLicense: GPLv2\n' "${2:-$1}" > "${BUILD}/readme.txt"
}

# head_revision
#
# Prints the youngest revision of the test repository.
head_revision() {
  svnlook youngest "${REPO}"
}

@test "publishes trunk and tags/<version> in a single commit" {
  run wporg_svn_deploy
  [ "$status" -eq 0 ]
  [ "$(head_revision)" -eq 2 ]
  svn cat "${REPO_URL}/trunk/my-plugin.php" | grep -q "Version: 1.2.3"
  svn cat "${REPO_URL}/tags/1.2.3/includes/helper.php" | grep -q "helper"
  [ "$(svn log -q -r HEAD "${REPO_URL}" | sed -n 2p | cut -d'|' -f2 | tr -d ' ')" = "deployer" ]
  svn log -r HEAD "${REPO_URL}" | grep -q "Update to version 1.2.3 from CircleCI"
}

@test "never prints the password" {
  run wporg_svn_deploy
  [ "$status" -eq 0 ]
  [[ "$output" != *"s3cret-value"* ]]
}

@test "drops a leading v from the version" {
  export RELEASE_VERSION="v1.2.3"
  run wporg_svn_deploy
  [ "$status" -eq 0 ]
  svn ls "${REPO_URL}/tags/1.2.3/" >/dev/null
}

@test "removes files from trunk that are no longer in the build" {
  run wporg_svn_deploy
  [ "$status" -eq 0 ]
  rm "${BUILD}/includes/helper.php"
  write_plugin 1.2.4
  export RELEASE_VERSION="1.2.4"
  run wporg_svn_deploy
  [ "$status" -eq 0 ]
  run svn ls "${REPO_URL}/trunk/includes/"
  [ -z "$output" ]
  svn ls "${REPO_URL}/tags/1.2.3/includes/helper.php" >/dev/null
}

@test "handles file names with spaces and @" {
  echo "x" > "${BUILD}/includes/with space@2x.txt"
  run wporg_svn_deploy
  [ "$status" -eq 0 ]
  svn ls "${REPO_URL}/trunk/includes/" | grep -qx "with space@2x.txt"
  rm "${BUILD}/includes/with space@2x.txt"
  write_plugin 1.2.4
  export RELEASE_VERSION="1.2.4"
  run wporg_svn_deploy
  [ "$status" -eq 0 ]
  ! svn ls "${REPO_URL}/trunk/includes/" | grep -q "with space"
}

@test "publishes files that svn's default global-ignores would skip" {
  echo "x" > "${BUILD}/.DS_Store"
  run wporg_svn_deploy
  [ "$status" -eq 0 ]
  svn ls "${REPO_URL}/trunk/" | grep -qx ".DS_Store"
}

@test "syncs assets_dir into assets/ and sets image mime types" {
  mkdir -p "${TEST_DIR}/assets"
  printf 'png' > "${TEST_DIR}/assets/banner-772x250.png"
  printf '<svg/>' > "${TEST_DIR}/assets/icon.svg"
  export PARAM_ASSETS_DIR="${TEST_DIR}/assets"
  run wporg_svn_deploy
  [ "$status" -eq 0 ]
  [ "$(svn propget svn:mime-type "${REPO_URL}/assets/banner-772x250.png")" = "image/png" ]
  [ "$(svn propget svn:mime-type "${REPO_URL}/assets/icon.svg")" = "image/svg+xml" ]
  ! svn ls "${REPO_URL}/tags/1.2.3/" | grep -q "banner"
}

@test "leaves assets/ alone when assets_dir does not exist" {
  export PARAM_ASSETS_DIR="${TEST_DIR}/no-such-dir"
  run wporg_svn_deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"leaving assets/ unchanged"* ]]
  svn ls "${REPO_URL}/tags/1.2.3/" >/dev/null
}

@test "uses main_file when the main file is not <slug>.php" {
  mv "${BUILD}/my-plugin.php" "${BUILD}/plugin.php"
  export PARAM_MAIN_FILE="plugin.php"
  run wporg_svn_deploy
  [ "$status" -eq 0 ]
  svn ls "${REPO_URL}/tags/1.2.3/plugin.php" >/dev/null
}

@test "succeeds without committing when tags/<version> already exists" {
  run wporg_svn_deploy
  [ "$status" -eq 0 ]
  local before
  before="$(head_revision)"
  run wporg_svn_deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
  [ "$(head_revision)" -eq "${before}" ]
}

@test "dry_run \"1\" stops before the commit and needs no credentials" {
  export PARAM_DRY_RUN="1"
  unset SVN_USERNAME SVN_PASSWORD
  run wporg_svn_deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing was committed"* ]]
  [[ "$output" == *"tags/1.2.3"* ]]
  [ "$(head_revision)" -eq 1 ]
}

@test "dry_run \"true\" also stops before the commit" {
  export PARAM_DRY_RUN="true"
  run wporg_svn_deploy
  [ "$status" -eq 0 ]
  [ "$(head_revision)" -eq 1 ]
}

@test "fails when the plugin header Version differs from the release version" {
  write_plugin 1.2.2 1.2.3
  run wporg_svn_deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"Version: '1.2.2'"* ]]
  [ "$(head_revision)" -eq 1 ]
}

@test "fails when the readme Stable tag differs from the release version" {
  write_plugin 1.2.3 1.2.2
  run wporg_svn_deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"Stable tag: '1.2.2'"* ]]
  [ "$(head_revision)" -eq 1 ]
}

@test "fails without credentials when dry_run is off" {
  unset SVN_PASSWORD
  run wporg_svn_deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"must both be set"* ]]
}

@test "reads credentials from the env vars named by username_env and password_env" {
  export PARAM_USERNAME_ENV="WPORG_USER" PARAM_PASSWORD_ENV="WPORG_PASS"
  export WPORG_USER="other-user" WPORG_PASS="pw"
  unset SVN_USERNAME SVN_PASSWORD
  run wporg_svn_deploy
  [ "$status" -eq 0 ]
  [ "$(svn log -q -r HEAD "${REPO_URL}" | sed -n 2p | cut -d'|' -f2 | tr -d ' ')" = "other-user" ]
}

@test "fails when the version is empty" {
  unset RELEASE_VERSION
  run wporg_svn_deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty or not a plugin version"* ]]
}

@test "rejects a version_env that is not a variable name" {
  export PARAM_VERSION_ENV='X;rm'
  run wporg_svn_deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a valid environment variable name"* ]]
}

@test "rejects a slug with characters WordPress.org does not use" {
  export PARAM_SLUG="My_Plugin"
  run wporg_svn_deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"lowercase letters"* ]]
}

@test "fails when the repository has no trunk/" {
  svn rm --quiet -m "drop trunk" "${REPO_URL}/trunk"
  run wporg_svn_deploy
  [ "$status" -ne 0 ]
  [[ "$output" == *"no trunk/ or tags/"* ]]
}

@test "returns to the caller's directory" {
  cd "${TEST_DIR}"
  wporg_svn_deploy >/dev/null
  [ "$PWD" = "${TEST_DIR}" ]
}
