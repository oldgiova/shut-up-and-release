#!/bin/bash
# Create GitHub release from existing tag
# shellcheck disable=SC2155  # Declare and assign separately
# shellcheck disable=SC2312  # Consider invoking separately

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<EOF
Usage: $0 <tag> [options]

Create GitHub release from existing git tag.

Arguments:
  tag         Git tag to create release from (e.g., v4.1.0)

Options:
  --draft             Create as draft
  --prerelease        Mark as prerelease (auto-detected from version)
  --notes FILE        Release notes file (default: extracted from CHANGELOG)
  --title TITLE       Release title (default: tag name)

Environment:
  GITHUB_TOKEN        Required for creating GitHub releases

Examples:
  # Create release from tag (auto-detects prerelease)
  $0 v4.1.0

  # Create RC release (auto-detected as prerelease)
  $0 v4.1.0-rc.1

  # Create draft release
  $0 v4.2.0 --draft

  # Create with custom notes
  $0 v4.1.0 --notes /tmp/release-notes.md

This script is idempotent: if release already exists, it will be updated.
EOF
}

# Extract changelog section for a specific version
extract_changelog_for_version() {
    local version=$1
    local changelog_file=$2

    if [[ ! -f "$changelog_file" ]]; then
        warn "Changelog file not found: $changelog_file"
        return 1
    fi

    info "Extracting changelog from: $changelog_file"

    # Find the section for this version
    # Format: ## [X.Y.Z] - YYYY-MM-DD or ## X.Y.Z - YYYY-MM-DD or ## vX.Y.Z
    local escaped_version=$(echo "$version" | sed 's/\./\\./g')

    # Try multiple patterns
    local section=$(awk "
        /^## (\[)?v?${escaped_version}(\])?( -|$)/ {found=1; next}
        found && /^## / {exit}
        found {print}
    " "$changelog_file")

    if [[ -z "$section" ]]; then
        warn "No changelog section found for version: $version"
        return 1
    fi

    echo "$section"
    return 0
}

# Post a comment on the release PR notifying that the release is published
notify_release_pr() {
    local tag=$1
    local version="${tag#v}"
    local release_url="https://github.com/${GITHUB_REPO_URL}/releases/tag/${tag}"

    # Find the merged release PR for this version (still has "autorelease: pending"
    # label until publish.sh rotates it to "autorelease: tagged")
    local pr_number
    pr_number=$(gh pr list \
        --state merged \
        --label "autorelease: pending" \
        --search "release ${version}" \
        --json number \
        --jq '.[0].number' 2>/dev/null || true)

    if [[ -z "$pr_number" ]]; then
        warn "Could not find release PR for ${version}, skipping PR comment"
        return 0
    fi

    gh pr edit "$pr_number" \
        --remove-label "autorelease: pending" \
        --add-label "autorelease: tagged" 2>/dev/null \
        || warn "Could not rotate label on PR #${pr_number}"

    info "Commenting on release PR #${pr_number}..."
    local body
    body="🎉 **Release [${tag}](${release_url}) is out!**

The GitHub release has been published: ${release_url}"

    gh pr comment "$pr_number" --body "$body" 2>/dev/null \
        || warn "Could not post comment on PR #${pr_number}"

    info "✓ PR #${pr_number}: labeled autorelease: tagged + commented"
}

# Determine which changelog file to use based on version
# Refactored to use common.sh function (Task #16)
# Saves 16 lines of duplication
get_changelog_file_for_version() {
    local version=$1
    local suffix
    suffix=$(detect_changelog_suffix "$version")
    echo "CHANGELOG${suffix}.md"
}

main() {
    init_release_scripts

    local tag=""
    local draft=false
    local prerelease_flag=""  # empty = auto-detect
    local notes_file=""
    local title=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --draft) draft=true; shift ;;
            --prerelease) prerelease_flag="--prerelease"; shift ;;
            --notes) notes_file=$2; shift 2 ;;
            --title) title=$2; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            v*) tag=$1; shift ;;
            *)
                # Accept without v prefix
                if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
                    tag="v$1"
                    shift
                else
                    error "Unknown option: $1"
                    usage
                    exit 1
                fi
                ;;
        esac
    done

    if [[ -z "$tag" ]]; then
        error "Tag required"
        usage
        exit 1
    fi

    # Validate tag format
    validate_tag "$tag"

    # Validate tag exists
    if ! tag_exists "$tag"; then
        fatal "Tag does not exist: $tag"
    fi

    # Check GitHub authentication: accept either GITHUB_TOKEN env var or gh auth login
    if [[ -z "${GITHUB_TOKEN:-}" ]] && ! gh auth status &>/dev/null; then
        fatal "GitHub authentication required: set GITHUB_TOKEN or run 'gh auth login'"
    fi

    # Extract version
    local version="${tag#v}"

    # Auto-detect prerelease if not explicitly set
    if [[ -z "$prerelease_flag" ]] && is_prerelease "$version"; then
        prerelease_flag="--prerelease"
        info "Auto-detected prerelease tag"
    fi

    # Determine changelog file
    local changelog_file=$(get_changelog_file_for_version "$version")

    info "Creating GitHub release for tag: $tag"
    info "Version: $version"
    info "Changelog file: $changelog_file"
    if [[ -n "$prerelease_flag" ]]; then
        info "Release type: prerelease"
    else
        info "Release type: stable"
    fi

    # Generate release notes
    local temp_notes=$(mktemp -t "release-notes-XXXXXX")
    trap 'rm -f "$temp_notes"' EXIT INT TERM
    local cleanup_temp=true

    if [[ -n "$notes_file" ]]; then
        if [[ ! -f "$notes_file" ]]; then
            fatal "Release notes file not found: $notes_file"
        fi
        cp "$notes_file" "$temp_notes"
        info "Using custom release notes from: $notes_file"
    else
        # Extract from changelog
        if extract_changelog_for_version "$version" "$changelog_file" > "$temp_notes"; then
            info "Extracted release notes from changelog"

            # Check if notes are empty or too short
            if [[ ! -s "$temp_notes" ]] || [[ $(wc -l < "$temp_notes") -lt 2 ]]; then
                warn "Extracted notes are empty or too short, using generic message"
                echo "Release $version" > "$temp_notes"
                echo "" >> "$temp_notes"
                echo "See [CHANGELOG]($changelog_file) for details." >> "$temp_notes"
            fi
        else
            # Fallback: generic message
            warn "Could not extract changelog, using generic message"
            echo "Release $version" > "$temp_notes"
            echo "" >> "$temp_notes"
            if [[ -f "$changelog_file" ]]; then
                echo "See [CHANGELOG]($changelog_file) for details." >> "$temp_notes"
            fi
        fi
    fi

    # Release title
    if [[ -z "$title" ]]; then
        title="$tag"
    fi

    # Check if release already exists.
    # Use plain gh here (not retry_gh): a 404 "not found" is the expected case
    # for new releases, not a transient error. retry_gh would silently fatal
    # after 3 attempts with all output suppressed by &>/dev/null.
    local release_exists=false
    if gh release view "$tag" &>/dev/null; then
        release_exists=true
        warn "Release already exists, updating..."
    fi

    # Create or update release
    if [[ "$release_exists" == "true" ]]; then
        # Update existing release
        info "Updating existing release: $tag"

        # SECURITY: Use array pattern instead of eval to prevent command injection
        local gh_args=(release edit "$tag" --notes-file "$temp_notes")

        if [[ -n "$prerelease_flag" ]]; then
            gh_args+=("$prerelease_flag")
        fi

        if [[ "$draft" == "true" ]]; then
            gh_args+=(--draft)
        fi

        retry_gh "${gh_args[@]}"
        local exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
            fatal "Failed to update release (exit code: $exit_code)"
        fi

        info "Release updated: $tag"
    else
        # Create new release
        info "Creating new release: $title"

        # SECURITY: Use array pattern instead of eval to prevent command injection
        local gh_args=(release create "$tag" --title "$title" --notes-file "$temp_notes")

        if [[ -n "$prerelease_flag" ]]; then
            gh_args+=("$prerelease_flag")
        fi

        if [[ "$draft" == "true" ]]; then
            gh_args+=(--draft)
        fi

        retry_gh "${gh_args[@]}"
        local exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
            fatal "Failed to create release (exit code: $exit_code)"
        fi

        info "Release created: $tag"
    fi

    # Cleanup
    if [[ "$cleanup_temp" == "true" ]]; then
        rm -f "$temp_notes"
    fi

    # Notify the release PR
    notify_release_pr "$tag"

    # Get release URL
    local release_url=$(gh release view "$tag" --json url -q .url 2>/dev/null || echo "")

    info ""
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "GitHub release ready: $tag"
    if [[ -n "$release_url" ]]; then
        info "URL: $release_url"
    fi
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Only run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
