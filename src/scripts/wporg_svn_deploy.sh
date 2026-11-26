#!/usr/bin/env bash
set -euo pipefail

# is_true
#
# Args: $1 - a boolean parameter value as CircleCI renders it into a run
#   step's environment ("1"/"0"), or "true"/"false".
# Returns: 0 when the value is 1 or true, 1 otherwise.
is_true() {
    case "${1:-}" in
        1 | true) return 0 ;;
        *) return 1 ;;
    esac
}

# read_env_var
#
# Prints the value of the environment variable whose name is $1, or nothing
# when it is unset. The name is validated first so indirection cannot be
# pointed at anything but a plain variable name.
# Arguments:
#   $1 - the parameter that carried the name (for the error message)
#   $2 - the environment variable name
# Outputs:
#   The variable's value on stdout; an error on stderr for a bad name.
# Returns:
#   0 on success, 1 when the name is not a valid variable name.
read_env_var() {
    local param="$1" name="$2"
    if ! printf '%s' "${name}" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$'; then
        echo "${param} '${name}' is not a valid environment variable name." >&2
        return 1
    fi
    printf '%s' "${!name:-}"
}

# plugin_header_version
#
# Prints the "Version:" value from a plugin's main file header. Like
# WordPress's get_file_data(), only the first 8 KiB of the file is read.
# Arguments:
#   $1 - path to the plugin's main PHP file
# Outputs:
#   The version (trailing whitespace and CR removed), or nothing.
plugin_header_version() {
    head -c 8192 "$1" |
        { grep -m1 -E '^[[:space:]]*(\*|#|//)?[[:space:]]*Version:' || true; } |
        sed -E 's/.*Version:[[:space:]]*//; s/[[:space:]]+$//'
}

# readme_stable_tag
#
# Prints the "Stable tag:" value from a plugin readme.
# Arguments:
#   $1 - path to readme.txt or readme.md
# Outputs:
#   The stable tag (trailing whitespace and CR removed), or nothing.
readme_stable_tag() {
    { grep -m1 -iE '^[[:space:]]*[*#-]*[[:space:]]*Stable tag:' "$1" || true; } |
        sed -E 's/.*[Ss][Tt][Aa][Bb][Ll][Ee] [Tt][Aa][Gg]:[[:space:]]*//; s/[[:space:]]+$//'
}

# is_plain_version
#
# Returns 0 when $1 is dot-separated whole numbers without leading zeros
# (1, 1.2, 1.2.3, 10.0.11). For these, `sort -V` orders versions the same
# way PHP's version_compare() does, which is how WordPress compares them;
# for pre-release suffixes (1.2.3-rc1) and leading zeros (1.01) the two
# disagree, so the command accepts only plain versions.
is_plain_version() {
    printf '%s' "$1" | grep -Eq '^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))*$'
}

# served_version
#
# Prints the Stable tag of a checked-out trunk's readme, which names the
# version WordPress.org serves. Prints nothing for an empty trunk, a readme
# without a Stable tag, or the legacy value "trunk": none of these names a
# version.
# Arguments:
#   $1 - the trunk/ directory of the working copy
served_version() {
    local readme tag
    for readme in "$1/readme.txt" "$1/readme.md"; do
        if [ -f "${readme}" ]; then
            tag="$(readme_stable_tag "${readme}")"
            if [ "${tag}" != "trunk" ]; then
                printf '%s' "${tag}"
            fi
            return 0
        fi
    done
}

# version_lt
#
# Returns 0 when version $1 is older than version $2, 1 otherwise. Both must
# pass is_plain_version, so that `sort -V` agrees with version_compare().
version_lt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

# find_symlinks
#
# Prints the symbolic links under directory $1, one per line. rsync -r skips
# them without failing, so the command refuses to publish a tree with any.
find_symlinks() {
    find "$1" -type l
}

# replace_kind_changes
#
# Runs in the root of the working copy after rsync. Where a versioned file
# became a directory or a directory became a file, `svn status` shows "~" and
# `svn add` fails. For each such path, moves the new item aside, schedules
# the old node for deletion, and puts the new item back, so that the
# following `svn add` schedules it as a replacement.
replace_kind_changes() {
    local changed path aside
    changed="$(svn status | { grep '^~' || true; } | cut -c9- | sort)"
    [ -n "${changed}" ] || return 0
    aside="$(mktemp -d)"
    while IFS= read -r path; do
        # A path inside one replaced earlier is gone with its parent.
        [ -e "${path}" ] || continue
        mv "${path}" "${aside}/item"
        svn rm --quiet --force "${path}@"
        mv "${aside}/item" "${path}"
    done <<<"${changed}"
    rmdir "${aside}"
}

# ensure_tools
#
# Installs subversion and rsync with apt-get when either is missing (cimg/base
# ships neither). Uses sudo when not running as root.
# Returns:
#   0 when both tools are available afterwards, non-zero otherwise.
ensure_tools() {
    local missing=()
    command -v svn >/dev/null 2>&1 || missing+=(subversion)
    command -v rsync >/dev/null 2>&1 || missing+=(rsync)
    if [ "${#missing[@]}" -eq 0 ]; then
        return 0
    fi
    local sudo=""
    if [ "$(id -u)" -ne 0 ]; then
        sudo="sudo"
    fi
    echo "Installing ${missing[*]}"
    ${sudo} apt-get update -qq
    ${sudo} env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
}

# set_asset_mime_types
#
# Sets svn:mime-type on the top-level image files of assets/, so
# WordPress.org serves banners, icons and screenshots with the right
# Content-Type (the same properties 10up's action sets).
# Arguments:
#   $1 - the assets/ directory of the working copy
set_asset_mime_types() {
    local dir="$1" file mime
    [ -d "${dir}" ] || return 0
    for file in "${dir}"/*; do
        [ -f "${file}" ] || continue
        case "${file,,}" in
            *.png) mime="image/png" ;;
            *.jpg | *.jpeg) mime="image/jpeg" ;;
            *.gif) mime="image/gif" ;;
            *.svg) mime="image/svg+xml" ;;
            *) continue ;;
        esac
        svn propset --quiet svn:mime-type "${mime}" "${file}@"
    done
}

# wporg_svn_deploy
#
# Publishes a built plugin directory to a WordPress.org plugin SVN
# repository: syncs it into trunk/, optionally syncs assets/, copies trunk to
# tags/<version>, and commits everything in one commit.
#
# Globals read:
#   PARAM_SLUG          - the plugin's WordPress.org slug (required)
#   PARAM_BUILD_DIR     - directory whose contents become trunk/ (required)
#   PARAM_MAIN_FILE     - main plugin file inside PARAM_BUILD_DIR
#                         (default: <slug>.php)
#   PARAM_ASSETS_DIR    - directory synced into assets/ (default: empty, which
#                         leaves assets/ untouched)
#   PARAM_VERSION_ENV   - name of the env var holding the version
#                         (default RELEASE_VERSION); a leading "v" is dropped
#   PARAM_USERNAME_ENV  - name of the env var holding the SVN user name
#   PARAM_PASSWORD_ENV  - name of the env var holding the SVN password
#   PARAM_SVN_URL       - repository URL (default
#                         https://plugins.svn.wordpress.org/<slug>/)
#   PARAM_DRY_RUN       - "1"/"true" to stop before the commit
# Outputs:
#   Progress and `svn status` on stdout, errors on stderr. The password is
#   never printed and is passed to svn on stdin, not on its command line.
# Returns:
#   0 on success, when the tag already exists, or after a dry run;
#   non-zero on a validation, checkout or commit failure.
wporg_svn_deploy() (
    local slug="${PARAM_SLUG:-}"
    local build_dir="${PARAM_BUILD_DIR:-}"
    local main_file="${PARAM_MAIN_FILE:-}"
    local assets_dir="${PARAM_ASSETS_DIR:-}"
    local svn_url="${PARAM_SVN_URL:-}"
    local version username password

    if ! printf '%s' "${slug}" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
        echo "slug '${slug}' must be lowercase letters, digits and hyphens." >&2
        return 1
    fi
    if [ -z "${build_dir}" ] || [ ! -d "${build_dir}" ]; then
        echo "build_dir '${build_dir}' is not a directory." >&2
        return 1
    fi
    build_dir="$(cd "${build_dir}" && pwd)"
    if [ -n "${assets_dir}" ] && [ -d "${assets_dir}" ]; then
        assets_dir="$(cd "${assets_dir}" && pwd)"
    fi
    local dir links
    for dir in "${build_dir}" "${assets_dir}"; do
        if [ -z "${dir}" ] || [ ! -d "${dir}" ]; then
            continue
        fi
        links="$(find_symlinks "${dir}")"
        if [ -n "${links}" ]; then
            echo "${dir} contains symbolic links, which would not be published:" >&2
            printf '%s\n' "${links}" >&2
            echo "Replace them with the files they point to." >&2
            return 1
        fi
    done

    version="$(read_env_var version_env "${PARAM_VERSION_ENV:-RELEASE_VERSION}")"
    version="${version#v}"
    if ! is_plain_version "${version}"; then
        echo "The version from \$${PARAM_VERSION_ENV:-RELEASE_VERSION} ('${version}') is empty or not a plain version such as 1.2.3." >&2
        echo "Pre-release suffixes and leading zeros are refused: sort -V and PHP's version_compare() order them differently." >&2
        return 1
    fi

    main_file="${main_file:-${slug}.php}"
    if [ ! -f "${build_dir}/${main_file}" ]; then
        echo "Main plugin file '${main_file}' was not found in ${build_dir}." >&2
        return 1
    fi
    local header_version
    header_version="$(plugin_header_version "${build_dir}/${main_file}")"
    if [ "${header_version}" != "${version}" ]; then
        echo "${main_file} says Version: '${header_version}', but the release version is '${version}'." >&2
        return 1
    fi

    local readme=""
    if [ -f "${build_dir}/readme.txt" ]; then
        readme="${build_dir}/readme.txt"
    elif [ -f "${build_dir}/readme.md" ]; then
        readme="${build_dir}/readme.md"
    else
        echo "No readme.txt or readme.md in ${build_dir}." >&2
        return 1
    fi
    local stable_tag
    stable_tag="$(readme_stable_tag "${readme}")"
    if [ "${stable_tag}" != "${version}" ]; then
        echo "$(basename "${readme}") says Stable tag: '${stable_tag}', but the release version is '${version}'." >&2
        echo "WordPress.org serves the version named by trunk's Stable tag, so they must match." >&2
        return 1
    fi

    username="$(read_env_var username_env "${PARAM_USERNAME_ENV:-SVN_USERNAME}")"
    password="$(read_env_var password_env "${PARAM_PASSWORD_ENV:-SVN_PASSWORD}")"
    if ! is_true "${PARAM_DRY_RUN:-}"; then
        if [ -z "${username}" ] || [ -z "${password}" ]; then
            echo "\$${PARAM_USERNAME_ENV:-SVN_USERNAME} and \$${PARAM_PASSWORD_ENV:-SVN_PASSWORD} must both be set (for example from a context) unless dry_run is true." >&2
            return 1
        fi
    fi

    ensure_tools

    svn_url="${svn_url:-https://plugins.svn.wordpress.org/${slug}/}"
    svn_url="${svn_url%/}"

    local work_dir
    work_dir="$(mktemp -d)"
    # The function body is a subshell, so the `cd` below never leaks to the
    # caller and this EXIT trap drops the working copy however it returns.
    # shellcheck disable=SC2064
    trap "rm -rf '${work_dir}'" EXIT

    echo "Checking out ${svn_url}"
    svn checkout --quiet --non-interactive --depth immediates "${svn_url}" "${work_dir}"
    cd "${work_dir}"
    if [ ! -d trunk ] || [ ! -d tags ]; then
        echo "${svn_url} has no trunk/ or tags/ directory." >&2
        return 1
    fi
    svn update --quiet --non-interactive --set-depth infinity trunk
    svn update --quiet --non-interactive --set-depth immediates tags

    # The version trunk serves now. specs/wporg_svn_deploy.qnt models the
    # checks below, with an empty value as version 0. The caller's
    # serial-group keeps two deploy jobs from running at once and skips an
    # older pipeline's job while a newer one waits or runs, but an older
    # pipeline's job that starts after the newer one finished (a rerun, or a
    # slower upstream) still runs; without the downgrade check it moves trunk
    # back to the older version. Without the tag check, a tag created without
    # trunk is reported as deployed.
    local served=""
    served="$(served_version trunk)"
    if [ -n "${served}" ] && ! is_plain_version "${served}"; then
        echo "trunk's Stable tag is '${served}', which is not a plain version such as 1.2.3, so it cannot be compared with ${version}." >&2
        echo "Nothing was committed. Fix trunk by hand." >&2
        return 1
    fi

    if [ -d "tags/${version}" ]; then
        if [ -z "${served}" ]; then
            echo "tags/${version} already exists in ${svn_url}, but trunk's readme names no version in Stable tag, so WordPress.org does not serve ${version}." >&2
            echo "The tag was not created by this command (it commits trunk and the tag together). Fix trunk by hand." >&2
            return 1
        fi
        if version_lt "${served}" "${version}"; then
            echo "tags/${version} already exists in ${svn_url}, but trunk's Stable tag is '${served}', so WordPress.org does not serve ${version}." >&2
            echo "The tag was not created by this command (it commits trunk and the tag together). Fix trunk by hand." >&2
            return 1
        fi
        # trunk and the tag are committed together, so an existing tag with
        # trunk at this version or newer means it was already published; a
        # rerun has nothing to do.
        echo "tags/${version} already exists in ${svn_url}; nothing to deploy."
        return 0
    fi

    if [ -n "${served}" ] && version_lt "${version}" "${served}"; then
        echo "trunk already serves ${served}, which is newer than ${version}; not moving trunk back. Nothing was committed."
        return 0
    fi

    echo "Syncing ${build_dir} into trunk/"
    rsync -rc --delete "${build_dir}/" trunk/

    if [ -n "${assets_dir}" ]; then
        if [ -d "${assets_dir}" ]; then
            echo "Syncing ${assets_dir} into assets/"
            if [ -d assets ]; then
                svn update --quiet --non-interactive --set-depth infinity assets
            else
                mkdir assets
            fi
            rsync -rc --delete "${assets_dir}/" assets/
        else
            echo "assets_dir '${assets_dir}' does not exist; leaving assets/ unchanged."
        fi
    fi

    replace_kind_changes
    # --no-ignore: publish exactly the build directory, including files that
    # svn's default global-ignores (.DS_Store, *.so, *~ ...) would skip.
    svn add --quiet --force --no-ignore .
    # Columns 1-8 of `svn status` are flags; the path starts at column 9.
    # The trailing "@" keeps a path containing "@" from being read as a peg
    # revision.
    svn status | { grep '^!' || true; } | cut -c9- | while IFS= read -r path; do
        svn rm --quiet "${path}@"
    done

    svn cp --quiet trunk "tags/${version}"
    set_asset_mime_types assets

    svn status

    if is_true "${PARAM_DRY_RUN:-}"; then
        echo "dry_run is true: nothing was committed to ${svn_url}."
        return 0
    fi

    echo "Committing version ${version} to ${svn_url}"
    printf '%s' "${password}" |
        svn commit --quiet --non-interactive --no-auth-cache \
            --username "${username}" --password-from-stdin \
            -m "Update to version ${version} from CircleCI"

    if ! svn ls --non-interactive "${svn_url}/tags/${version}/" >/dev/null; then
        echo "The commit returned success, but tags/${version} is not listed in ${svn_url}." >&2
        return 1
    fi
    echo "Published ${slug} ${version} to ${svn_url}."
    echo "If release confirmation is on for this plugin, approve the release from the email WordPress.org sends before it goes live."
)

# main
#
# Entry point run when this script is executed directly (as opposed to
# being sourced by the bats-core test suite). Delegates to
# wporg_svn_deploy().
# Arguments:
#   None.
# Outputs:
#   None of its own; see wporg_svn_deploy().
# Returns:
#   The exit status of wporg_svn_deploy().
main() {
    wporg_svn_deploy
}

# Will not run if sourced for bats-core tests.
ORB_TEST_ENV="bats-core"
if [ "${0#*"$ORB_TEST_ENV"}" = "$0" ]; then
    main
fi
