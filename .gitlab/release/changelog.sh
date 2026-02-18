#!/bin/bash
# Changelog generation wrapper around generate_changelog.sh
# shellcheck disable=SC2155  # Declare and assign separately
# shellcheck disable=SC2312  # Consider invoking separately
#
# Git-cliff Modes:
#   - Preview mode (--preview): Uses LOCAL git history only (--no-exec)
#     - Fast, no API calls, no rate limits
#     - No GITHUB_TOKEN required
#
#   - Normal mode (default): Uses GitHub API via generate_changelog.sh
#     - Fetches PR metadata, contributor links, etc.
#     - REQUIRES: GITHUB_TOKEN environment variable
#     - May hit rate limits if token not set
#
#   - Normal mode with --local-git: Uses LOCAL git history only
#     - Bypasses generate_changelog.sh
#     - No PR links or metadata
#     - No GITHUB_TOKEN required
#     - Use for testing without API access

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<EOF
Usage: $0 <version> [options]

Generate changelog using git-cliff via generate_changelog.sh.

Arguments:
  version     Version to generate changelog for (e.g., 4.1.0 or 4.1.0-rc.1)

Options:
  --suffix SUFFIX   Changelog suffix (-saas, -rc, -enterprise, or empty)
  --pr-body FILE    Also generate PR body to FILE
  --preview         Don't modify files, just show what would be generated
                    (uses local git only, no GITHUB_TOKEN needed)
  --local-git       Use local git history instead of GitHub API
                    (no PR links, no GITHUB_TOKEN needed)

Environment:
  GITHUB_REPO_URL   Repository URL (default: mendersoftware/mender-server)
  GITHUB_TOKEN      Required for normal mode (GitHub API access)
                    Not required for --preview or --local-git modes

Examples:
  # Preview changelog (local git, no token needed)
  $0 4.2.0 --preview

  # Generate changelog with GitHub API (GITHUB_TOKEN required)
  $0 4.2.0

  # Generate changelog with local git only (no token needed)
  $0 4.2.0 --local-git

  # Generate changelog for RC
  $0 4.1.0-rc.1

  # Generate with custom suffix
  $0 4.1.0 --suffix -enterprise

  # Generate PR body too
  $0 4.2.0 --pr-body /tmp/pr-body.md
EOF
}

# Determine which changelog file(s) to update based on version and branch
# Returns: space-separated list of changelog files (without CHANGELOG prefix)
determine_changelog_files() {
    local version=$1
    local branch=$(current_branch)
    local files=()

    if [[ "$version" =~ -saas ]]; then
        # SaaS prerelease (main branch)
        files+=("-saas")
        info "Changelog strategy: SaaS prerelease → CHANGELOG-saas.md only"

    elif [[ "$version" =~ -rc ]]; then
        # RC prerelease (maintenance branch)
        files+=("-rc")
        info "Changelog strategy: RC prerelease → CHANGELOG-rc.md only"
        # CRITICAL: Do NOT update CHANGELOG-enterprise.md here

    elif [[ "$branch" =~ ^[0-9]+\.[0-9]+\.x$ ]]; then
        # Stable release on maintenance branch
        files+=("-enterprise")
        info "Changelog strategy: Stable on maintenance branch → CHANGELOG-enterprise.md only"
        # Do NOT update CHANGELOG-rc.md here

    else
        # Stable release on main branch (open source)
        files+=("")
        info "Changelog strategy: Stable on main branch → CHANGELOG.md only"
    fi

    echo "${files[@]}"
}

# Find the correct reference tag for stable release changelog generation
# This ensures v5.0.0 shows full diff from v4.9.13 (last stable of previous maintenance branch)
find_stable_reference_tag() {
    local version=$1
    local branch=$2

    # Extract major.minor from version
    if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\. ]]; then
        local major="${BASH_REMATCH[1]}"
        local minor="${BASH_REMATCH[2]}"

        info "Finding reference tag for v${version} on branch ${branch}"
        info "Current major.minor: ${major}.${minor}"

        # Strategy 1: Try to find last stable from current major.minor series
        # (for v5.0.1 → find v5.0.0)
        local ref_tag=$(git tag --list "v${major}.${minor}.*" --sort=-version:refname 2>/dev/null | \
                       grep -vE -- '-(rc|saas)' | grep -v "^v${version}$" | head -n 1)

        if [[ -n "$ref_tag" ]]; then
            info "Found reference in current series: ${ref_tag}"
            echo "$ref_tag"
            return 0
        fi

        # Strategy 2: Try previous minor version (for v5.0.0 → find v4.9.x)
        # Start from current minor-1 and work backwards
        for ((prev_minor=minor-1; prev_minor>=0; prev_minor--)); do
            ref_tag=$(git tag --list "v${major}.${prev_minor}.*" --sort=-version:refname 2>/dev/null | \
                     grep -vE -- '-(rc|saas)' | head -n 1)

            if [[ -n "$ref_tag" ]]; then
                info "Found reference in previous minor series: ${ref_tag}"
                echo "$ref_tag"
                return 0
            fi
        done

        # Strategy 3: Try previous major version
        if [[ "$major" -gt 0 ]]; then
            local prev_major=$((major - 1))
            ref_tag=$(git tag --list "v${prev_major}.*" --sort=-version:refname 2>/dev/null | \
                     grep -vE -- '-(rc|saas)' | head -n 1)

            if [[ -n "$ref_tag" ]]; then
                info "Found reference in previous major series: ${ref_tag}"
                echo "$ref_tag"
                return 0
            fi
        fi
    fi

    # Fallback: find any previous stable tag (older than current version)
    # Use git tag --merged to only get tags reachable from current HEAD
    # This ensures we don't accidentally pick a newer tag
    local all_stable_tags=$(git tag --list 'v*' --sort=-version:refname 2>/dev/null | \
                           grep -vE -- '-(rc|saas)')

    # Find the first tag that is NOT the current version and is older
    local ref_tag=""
    while IFS= read -r tag; do
        # Skip the current version
        [[ "$tag" == "v${version}" ]] && continue

        # Check if this tag is older than current version (using sort -V)
        local older=$(printf "%s\n%s\n" "$tag" "v${version}" | sort -V | head -n 1)
        if [[ "$older" == "$tag" ]]; then
            # This tag is older, use it
            ref_tag="$tag"
            break
        fi
    done <<< "$all_stable_tags"

    if [[ -n "$ref_tag" ]]; then
        warn "Using fallback reference tag: ${ref_tag}"
        echo "$ref_tag"
        return 0
    fi

    warn "No reference tag found - will generate changelog from repository start"
    echo ""
    return 0
}

# Auto-detect changelog suffix from version and config (DEPRECATED - use determine_changelog_files)
# Refactored to use common.sh function (Task #16)
# Saves 16 lines of duplication
detect_suffix() {
    detect_changelog_suffix "$1"
}

main() {
    init_release_scripts

    local version=""
    local suffix=""
    local pr_body_file=""
    local preview=false
    local local_git=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --suffix) suffix=$2; shift 2 ;;
            --pr-body) pr_body_file=$2; shift 2 ;;
            --preview) preview=true; shift ;;
            --local-git) local_git=true; shift ;;
            -h|--help) usage; exit 0 ;;
            -*) error "Unknown option: $1"; usage; exit 1 ;;
            *) version=$1; shift ;;
        esac
    done

    if [[ -z "$version" ]]; then
        error "Version required"
        usage
        exit 1
    fi

    # Strip v prefix if present
    version="${version#v}"

    # Auto-detect suffix if not provided
    if [[ -z "$suffix" ]]; then
        suffix=$(detect_suffix "$version")
        info "Auto-detected suffix: '${suffix:-<empty>}'"
    fi

    info "Generating changelog for version: v$version"
    info "Changelog file: CHANGELOG${suffix}.md"
    info "Repository: $GITHUB_REPO_URL"

    if [[ "$preview" == "true" ]]; then
        info "Preview mode: using LOCAL git history (no GITHUB_TOKEN needed)"
        info "No files will be modified"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Preview: CHANGELOG${suffix}.md for v${version}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""

        # Determine ignore pattern (same logic as generate_changelog.sh)
        local ignore_pattern=""
        if [[ "$suffix" == "-saas" ]]; then
            ignore_pattern=".*-rc.*"
        elif [[ "$suffix" == "-rc" ]]; then
            ignore_pattern=".*-saas.*"
        elif [[ "$suffix" == "-enterprise" ]]; then
            ignore_pattern=".*-(rc|saas).*"
        else
            ignore_pattern=".*-(rc|saas).*"
        fi

        # Determine range
        local range="--unreleased"
        if [[ ! "$version" =~ (rc|saas) ]]; then
            # Stable release: use new reference tag finding logic
            local branch=$(current_branch)
            local last_stable=$(find_stable_reference_tag "$version" "$branch")

            if [[ -n "$last_stable" ]]; then
                range="${last_stable}..HEAD"
                info "Range: ${last_stable}..HEAD (full diff for stable release)"
            else
                info "Range: --unreleased (no previous stable found)"
            fi
        else
            info "Range: --unreleased (prerelease)"
        fi

        # Call git-cliff to preview
        # Use --no-exec to prevent external API calls (local git only)
        local cliff_cmd="git cliff ${range} --tag v${version} --use-branch-tags --no-exec"
        if [[ -n "$ignore_pattern" ]]; then
            cliff_cmd="$cliff_cmd --ignore-tags '$ignore_pattern'"
        fi

        info "Command: $cliff_cmd"
        echo ""

        # Execute and show output
        eval "$cliff_cmd" 2>&1 | head -100
        local exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
            echo ""
            warn "git-cliff exited with code: $exit_code"
        fi

        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        info "Preview complete (no files modified)"
        exit 0
    fi

    # Check for local-git mode
    if [[ "$local_git" == "true" ]]; then
        info "Local git mode: using LOCAL git history (no GITHUB_TOKEN needed)"
        info "WARNING: No PR links or metadata will be included"

        # Determine ignore pattern and range (same as preview)
        local ignore_pattern=""
        if [[ "$suffix" == "-saas" ]]; then
            ignore_pattern=".*-rc.*"
        elif [[ "$suffix" == "-rc" ]]; then
            ignore_pattern=".*-saas.*"
        elif [[ "$suffix" == "-enterprise" ]]; then
            ignore_pattern=".*-(rc|saas).*"
        else
            ignore_pattern=".*-(rc|saas).*"
        fi

        local range="--unreleased"
        if [[ ! "$version" =~ (rc|saas) ]]; then
            # Stable release: use new reference tag finding logic
            local branch=$(current_branch)
            local last_stable=$(find_stable_reference_tag "$version" "$branch")

            if [[ -n "$last_stable" ]]; then
                range="${last_stable}..HEAD"
                info "Range: ${last_stable}..HEAD (full diff for stable release)"
            fi
        fi

        # Generate changelog with local git only
        local changelog_file="CHANGELOG${suffix}.md"
        local cliff_cmd="git cliff ${range} --tag v${version} --use-branch-tags --no-exec -o ${changelog_file}"
        if [[ -n "$ignore_pattern" ]]; then
            cliff_cmd="$cliff_cmd --ignore-tags '$ignore_pattern'"
        fi

        info "Generating changelog: $changelog_file"
        info "Command: $cliff_cmd"

        eval "$cliff_cmd"
        local exit_code=$?

        if [[ $exit_code -ne 0 ]]; then
            fatal "git-cliff failed with exit code: $exit_code"
        fi

        info "Changelog generated successfully"
        info "Updated: $changelog_file"

        # Generate PR body if requested
        if [[ -n "$pr_body_file" ]]; then
            info "Generating PR body: $pr_body_file"
            # Extract the version section from changelog
            # Escape dots in version for regex matching
            local version_escaped=$(echo "$version" | sed 's/\./\\./g')
            sed -n "/^## \(\[\)\?v\?${version_escaped}/,/^## [0-9]/p" "$changelog_file" | head -n -1 > "$pr_body_file"
            info "Generated PR body: $pr_body_file ($(wc -l < "$pr_body_file") lines)"
        fi

        exit 0
    fi

    # Find the generate_changelog.sh script
    local generate_script="${SCRIPT_DIR}/../generate_changelog.sh"

    if [[ ! -f "$generate_script" ]]; then
        fatal "Changelog generator not found: $generate_script"
    fi

    if [[ ! -x "$generate_script" ]]; then
        fatal "Changelog generator not executable: $generate_script"
    fi

    # Call generate_changelog.sh with arguments
    # This uses GitHub API and REQUIRES GITHUB_TOKEN
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        warn "GITHUB_TOKEN not set - may encounter rate limits or missing PR metadata"
        warn "Set GITHUB_TOKEN environment variable for full functionality"
        warn "Or use --local-git flag to bypass GitHub API (no PR links)"
    fi

    info "Calling generate_changelog.sh (uses GitHub API)..."

    # Note: generate_changelog.sh doesn't support PR body file generation
    # So we just call it normally and extract the PR body ourselves
    "$generate_script" "v$version" "$suffix" "$GITHUB_REPO_URL"

    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        fatal "generate_changelog.sh failed with exit code: $exit_code"
    fi

    info "Changelog generated successfully"

    # Verify changelog file was created/updated
    local changelog_file="CHANGELOG${suffix}.md"
    if [[ ! -f "$changelog_file" ]]; then
        warn "Changelog file not found after generation: $changelog_file"
    else
        info "Updated: $changelog_file"
    fi

    # Extract PR body from generated changelog if requested
    if [[ -n "$pr_body_file" ]]; then
        info "Extracting PR body from changelog: $pr_body_file"
        info "Current directory: $(pwd)"
        info "Changelog file: $changelog_file"
        info "File exists: $([ -f "$changelog_file" ] && echo "yes" || echo "no")"

        if [[ ! -f "$changelog_file" ]]; then
            warn "Changelog file not found for extraction: $changelog_file"
            echo "Release $version" > "$pr_body_file"
            echo "" >> "$pr_body_file"
            echo "See [CHANGELOG${suffix}.md](CHANGELOG${suffix}.md) for details." >> "$pr_body_file"
        else
            # Extract the section for this version from the changelog
            # Format: ## X.Y.Z - YYYY-MM-DD (possibly with v prefix or brackets)
            # Escape dots in version for regex matching
            local version_escaped=$(echo "$version" | sed 's/\./\\./g')
            info "Searching for: ^## ${version_escaped}"

            # Use sed to extract from current version to next version header
            sed -n "/^## \(\[\)\?v\?${version_escaped}/,/^## [0-9]/p" "$changelog_file" | head -n -1 > "$pr_body_file"

            if [[ -s "$pr_body_file" ]]; then
                info "Generated PR body: $pr_body_file ($(wc -l < "$pr_body_file") lines)"
            else
                warn "PR body is empty after extraction, using fallback"
                echo "Release $version" > "$pr_body_file"
                echo "" >> "$pr_body_file"
                echo "See [CHANGELOG${suffix}.md](CHANGELOG${suffix}.md) for details." >> "$pr_body_file"
            fi
        fi
    fi

    # REMOVED: Dual-update logic that was updating both RC and enterprise changelogs
    # Per Task #13: RC releases should ONLY update CHANGELOG-rc.md
    # Stable releases should ONLY update CHANGELOG-enterprise.md
}

# Only run main if script is executed directly (not sourced)
# Also check for _SKIP_MAIN_EXECUTION flag (for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ -z "${_SKIP_MAIN_EXECUTION:-}" ]]; then
    main "$@"
fi
