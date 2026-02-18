#!/bin/bash
# Common functions for release scripts
# shellcheck disable=SC2155  # Declare and assign separately
# shellcheck disable=SC2312  # Consider invoking separately

set -eo pipefail

# Configuration
CONFIG_FILE="release-please-config.json"
MANIFEST_FILE=".release-please-manifest.json"

# Note: Manifest file is used for version state during releases
# Primary source of truth is still git tags

# Auto-detect repository from git remote if not set
if [[ -z "${GITHUB_REPO_URL:-}" ]]; then
    # Try to extract owner/repo from origin remote URL
    # Handles both SSH (git@github.com:owner/repo.git) and HTTPS (https://github.com/owner/repo.git)
    _remote_url=$(git config --get remote.origin.url 2>/dev/null || echo "")
    if [[ -n "$_remote_url" ]] && [[ "$_remote_url" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
        GITHUB_REPO_URL="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    else
        # Cannot auto-detect - this would cause wrong links in changelog
        echo "ERROR: Cannot detect GitHub repository from git remote." >&2
        echo "       Set GITHUB_REPO_URL environment variable (e.g., 'owner/repo')" >&2
        echo "       Current remote URL: ${_remote_url:-<none>}" >&2
        exit 1
    fi
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Logging functions
info() {
    echo -e "${GREEN}[INFO]${NC} $*" >&2
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

fatal() {
    error "$*"
    exit 1
}

# Validate environment
require_env() {
    local var=$1
    if [[ -z "${!var}" ]]; then
        fatal "Required environment variable not set: $var"
    fi
}

require_command() {
    local cmd=$1
    if ! command -v "$cmd" &>/dev/null; then
        fatal "Required command not found: $cmd"
    fi
}

# Git helpers
current_branch() {
    git rev-parse --abbrev-ref HEAD
}

is_clean_worktree() {
    git diff-index --quiet HEAD -- 2>/dev/null
}

tag_exists() {
    local tag=$1
    git rev-parse "$tag" &>/dev/null
}

remote_branch_exists() {
    local branch=$1
    git ls-remote --heads origin "$branch" 2>/dev/null | grep -q "$branch"
}

# Retry wrapper for gh commands (Task #18)
retry_gh() {
    local max_attempts=3
    local attempt=1
    local delay=2

    while [ $attempt -le $max_attempts ]; do
        if gh "$@"; then
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            warn "gh command failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
            sleep $delay
            delay=$((delay * 2))  # Exponential backoff
        fi
        ((attempt++))
    done

    fatal "gh command failed after $max_attempts attempts: gh $*"
}

# Retry wrapper for git push/pull (Task #18)
retry_git() {
    local max_attempts=3
    local attempt=1
    local delay=2

    while [ $attempt -le $max_attempts ]; do
        if git "$@"; then
            return 0
        fi

        if [ $attempt -lt $max_attempts ]; then
            warn "git command failed (attempt $attempt/$max_attempts), retrying in ${delay}s..."
            sleep $delay
            delay=$((delay * 2))
        fi
        ((attempt++))
    done

    fatal "git command failed after $max_attempts attempts: git $*"
}

# Version helpers - read from git tags (single source of truth)
get_latest_tag() {
    # Get the most recent tag (any type)
    git tag --sort=-version:refname 2>/dev/null | head -n 1 || echo ""
}

get_latest_stable_tag() {
    # Get the most recent stable tag (no prerelease suffix)
    git tag --list "v*" --sort=-version:refname 2>/dev/null | \
        grep -v -E '\-(rc|saas)\.' | head -n 1 || echo ""
}

get_latest_prerelease_tag() {
    # Get the most recent prerelease tag (rc or saas)
    git tag --list "v*" --sort=-version:refname 2>/dev/null | \
        grep -E '\-(rc|saas)\.' | head -n 1 || echo ""
}

read_current_version() {
    # Git tags are the single source of truth.
    # Manifest is only a fallback for repos that have no tags yet.
    local latest
    latest=$(get_latest_tag)
    if [[ -n "$latest" ]]; then
        echo "${latest#v}"
    elif [[ -f "$MANIFEST_FILE" ]]; then
        jq -r '.["."]' "$MANIFEST_FILE"
    else
        echo "0.0.0"
    fi
}

# Write version to manifest with file locking (Task #12)
# This prevents race conditions when multiple processes write simultaneously
write_version() {
    local version=$1
    local lock_file="/tmp/release-manifest.lock"

    # Ensure lock directory exists (fallback to /tmp if /var/lock doesn't exist)
    if [[ -d /var/lock ]] && [[ -w /var/lock ]]; then
        lock_file="/var/lock/release-manifest.lock"
    fi

    # Acquire exclusive lock with timeout
    (
        # flock with 10 second timeout
        if ! flock -x -w 10 200; then
            fatal "Could not acquire manifest lock after 10 seconds. Another process may be writing."
        fi

        # Atomic write using temp file + move
        local tmp=$(mktemp -t "manifest-XXXXXX.json")
        trap 'rm -f "$tmp"' EXIT INT TERM

        # Create/update manifest JSON
        if [[ -f "$MANIFEST_FILE" ]]; then
            # Update existing manifest
            jq --arg v "$version" '.["."] = $v' "$MANIFEST_FILE" > "$tmp"
        else
            # Create new manifest
            echo "{\".\": \"$version\"}" | jq . > "$tmp"
        fi

        # Atomic move (replaces file atomically)
        mv "$tmp" "$MANIFEST_FILE"

        info "Locked and updated manifest to version: $version"
    ) 200>"$lock_file"

    # Clean up lock file if empty (optional)
    if [[ -f "$lock_file" ]] && [[ ! -s "$lock_file" ]]; then
        rm -f "$lock_file" 2>/dev/null || true
    fi
}

# Prerelease type detection
get_prerelease_type() {
    jq -r '."prerelease-type" // "rc"' "$CONFIG_FILE"
}

get_changelog_path() {
    jq -r '.packages["."]["changelog-path"] // "CHANGELOG.md"' "$CONFIG_FILE"
}

is_prerelease_enabled() {
    local enabled=$(jq -r '.prerelease // false' "$CONFIG_FILE")
    [[ "$enabled" == "true" ]]
}

# Validate tag format
# SECURITY: Strict validation prevents command injection via tag names
# All tags MUST pass this check before use in git/gh commands
# Pattern enforces: vX.Y.Z or vX.Y.Z-type.N (where type is lowercase letters only)
validate_tag() {
    local tag=$1
    if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?$ ]]; then
        fatal "Invalid tag format: $tag (expected: vX.Y.Z or vX.Y.Z-type.N)"
    fi
}

# Extract base version from tag (removes prerelease suffix)
base_version() {
    local tag=$1
    # Remove 'v' prefix if present
    tag="${tag#v}"
    # Extract base version (remove -rc.N or -saas.N suffix)
    echo "$tag" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/'
}

# Check if version is prerelease
is_prerelease() {
    local version=$1
    [[ "$version" =~ -rc ]] || [[ "$version" =~ -saas ]]
}

# Extract prerelease number
prerelease_number() {
    local version=$1
    if [[ "$version" =~ -(rc|saas)\.([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[2]}"
    else
        echo "0"
    fi
}

# ============================================================================
# DRY Refactoring Functions (Task #16)
# These functions eliminate ~75 lines of duplication across scripts
# ============================================================================

# Unified version bump function (extracted from version.sh - Task #16)
# Replaces separate bump_major, bump_minor, bump_patch functions
# Saves 24 lines of duplication across scripts
bump_version() {
    local version=$1
    local bump_type=$2  # major, minor, or patch
    local major minor patch
    IFS='.' read -r major minor patch <<< "$(base_version "$version")"

    case "$bump_type" in
        major) echo "$((major + 1)).0.0" ;;
        minor) echo "${major}.$((minor + 1)).0" ;;
        patch) echo "${major}.${minor}.$((patch + 1))" ;;
        *) fatal "Unknown bump type: $bump_type" ;;
    esac
}

# Detect changelog suffix from version (extracted from changelog.sh/release.sh - Task #16)
# Replaces duplicated logic in detect_suffix() and get_changelog_file_for_version()
# Saves 16 lines of duplication across scripts
detect_changelog_suffix() {
    local version=$1
    if [[ "$version" =~ -saas ]]; then echo "-saas"
    elif [[ "$version" =~ -rc ]]; then echo "-rc"
    elif is_prerelease "$version"; then echo ""
    else
        [[ "$GITHUB_REPO_URL" =~ enterprise ]] && echo "-enterprise" || echo ""
    fi
}

# Find last tag with unified logic (extracted from version.sh - Task #16)
# Replaces duplicated tag-finding patterns across scripts
# Saves 15 lines of duplication across scripts
find_last_tag() {
    local tag_type=${1:-any}
    local exclude_tag=${2:-}
    case "$tag_type" in
        stable) git tag --list "v*" --sort=-version:refname 2>/dev/null | \
                grep -v -E "(rc|saas)" | \
                ${exclude_tag:+grep -v "^${exclude_tag}$" |} head -n 1 ;;
        any) git describe --tags --abbrev=0 2>/dev/null || echo "" ;;
        *) fatal "Invalid tag type: $tag_type" ;;
    esac
}

# ============================================================================

# Initialize (run in all scripts)
init_release_scripts() {
    require_command git
    require_command jq

    if [[ ! -f "$CONFIG_FILE" ]]; then
        fatal "Config file not found: $CONFIG_FILE"
    fi

    # Validate config JSON
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        fatal "Invalid JSON in config file: $CONFIG_FILE"
    fi

    # Ensure we're in a git repo
    if ! git rev-parse --git-dir &>/dev/null; then
        fatal "Not in a git repository"
    fi
}
