#!/bin/bash

set -e

RELEASE_VERSION=$1
CHANGELOG_SUFFIX=$2
GITHUB_REPO_URL=$3
CI_COMMIT_REF_NAME=$4

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Use absolute path so git-cliff finds both files regardless of CWD or branch context.
# git-cliff resolves --prepend paths relative to --config location, not CWD.
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
CHANGELOG_FILE="${REPO_ROOT}/CHANGELOG${CHANGELOG_SUFFIX:-}.md"
CLIFF_TOML="${SCRIPT_DIR}/cliff.toml"
CLIFF_TOML_URL="https://raw.githubusercontent.com/mendersoftware/mendertesting/master/utils/cliff.toml"

echo "INFO - Generating changelog file ${CHANGELOG_FILE} for release ${RELEASE_VERSION}"

# Download cliff.toml if it doesn't exist or is from local repo (without emojis)
if [ ! -f "${CLIFF_TOML}" ] || ! grep -q "🚀" "${CLIFF_TOML}"; then
    echo "INFO - Downloading official cliff.toml from mendertesting..."
    if wget --quiet --output-document "${CLIFF_TOML}" "${CLIFF_TOML_URL}"; then
        echo "INFO - Downloaded cliff.toml successfully"
    else
        echo "WARN - Failed to download cliff.toml, using local/default config"
    fi
fi

# Strategy for idempotency:
# 1. Find the last RELEASED tag (not the one we're about to create)
# 2. Remove everything from the top of CHANGELOG to that tag
# 3. Run git-cliff to regenerate the unreleased section fresh
# This ensures we always have a clean, up-to-date section for the current release

if [ ! -f "${CHANGELOG_FILE}" ]; then
    echo "INFO - ${CHANGELOG_FILE} does not exist, creating fresh"
    echo "---" > "${CHANGELOG_FILE}"
fi

if [ -f "${CHANGELOG_FILE}" ]; then
    echo "INFO - Removing unreleased section from ${CHANGELOG_FILE} for fresh regeneration"

    # Find the first released version in the changelog (skip any unreleased content)
    # Look for a version line that's NOT the version we're creating
    VERSION_TO_CREATE="${RELEASE_VERSION#v}"

    # Create a temp file with only the released content (everything after the first non-matching version)
    awk -v new_ver="${VERSION_TO_CREATE}" '
        BEGIN { found_released=0; skip=1 }
        /^## / {
            # Extract version from header (handles ## [X.Y.Z], ## X.Y.Z, etc.)
            if (match($0, /[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+(\.[0-9]+)?)?/)) {
                version = substr($0, RSTART, RLENGTH)
                # If this is NOT the version we are creating, we found released content
                if (version != new_ver) {
                    found_released=1
                    skip=0
                }
            }
        }
        !skip { print }
    ' "${CHANGELOG_FILE}" > "${CHANGELOG_FILE}.tmp"

    # If we found released content, use the cleaned file
    # Otherwise, start with an empty file (this is the first release)
    if [ -s "${CHANGELOG_FILE}.tmp" ]; then
        # Preserve the --- header if it exists
        if head -n1 "${CHANGELOG_FILE}" | grep -q "^---$"; then
            echo "---" > "${CHANGELOG_FILE}"
            cat "${CHANGELOG_FILE}.tmp" >> "${CHANGELOG_FILE}"
        else
            mv "${CHANGELOG_FILE}.tmp" "${CHANGELOG_FILE}"
        fi
        rm -f "${CHANGELOG_FILE}.tmp"
        echo "INFO - Cleaned ${CHANGELOG_FILE}, ready for fresh generation"
    else
        rm -f "${CHANGELOG_FILE}.tmp"
        echo "INFO - No previous releases found, starting fresh"
        echo "---" > "${CHANGELOG_FILE}"
    fi
fi

# Generate fresh changelog section for the current release
echo "INFO - Running git-cliff to generate ${RELEASE_VERSION} section"
if [ "${CHANGELOG_SUFFIX}" == "-saas" ]; then
    git cliff --config "${CLIFF_TOML}" --unreleased --prepend "${CHANGELOG_FILE}" --github-repo "${GITHUB_REPO_URL}" --use-branch-tags --tag "${RELEASE_VERSION}"
else
    git cliff --config "${CLIFF_TOML}" --unreleased --prepend "${CHANGELOG_FILE}" --github-repo "${GITHUB_REPO_URL}" --use-branch-tags --tag "${RELEASE_VERSION}" --ignore-tags saas
fi

git add "${CHANGELOG_FILE}"
echo "INFO - Successfully generated ${CHANGELOG_FILE}"
