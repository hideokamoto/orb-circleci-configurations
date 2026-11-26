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

    version="$(read_env_var version_env "${PARAM_VERSION_ENV:-RELEASE_VERSION}")"
    version="${version#v}"
    if ! printf '%s' "${version}" | grep -Eq '^[0-9][0-9A-Za-z.-]*$'; then
        echo "The version from \$${PARAM_VERSION_ENV:-RELEASE_VERSION} ('${version}') is empty or not a plugin version." >&2
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

    if [ -d "tags/${version}" ]; then
        # trunk and the tag are committed together, so an existing tag means
        # this version was already published; a rerun has nothing to do.
        echo "tags/${version} already exists in ${svn_url}; nothing to deploy."
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
