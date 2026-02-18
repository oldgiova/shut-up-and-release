#!/bin/bash
# Version calculation using git-cliff
# git-cliff is the source of truth for version bumping
# shellcheck disable=SC2155  # Declare and assign separately
# shellcheck disable=SC2312  # Consider invoking separately

# Get script directory - use absolute path resolution to avoid shell hooks
SCRIPT_DIR="$(unset -f cd pwd 2>/dev/null; unalias cd pwd 2>/dev/null; builtin cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && command pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<EOF
Usage: $0 [options]

Calculate next version using git-cliff's --bumped-version feature.
git-cliff analyzes commits: fix: → patch, feat: → minor, BREAKING → major

Version Calculation:
  - Global mode: Uses last released tag from any branch
  - Maintenance branch mode: On branches matching X.Y.x (e.g., 4.1.x, 10.2.x),
    only tags matching vX.Y.* are considered for version calculation

Options:
  --prerelease    Force prerelease mode (add -rc or -saas suffix)
  --no-prerelease Force stable mode (no suffix)
  --preview       Show commit analysis (git log)
  --dry-run       Accepted for backwards compatibility (no-op: writes nothing)

Environment:
  RELEASE_AS      Override version (format: X.Y.Z or X.Y.Z-type.N)
  PRERELEASE_TYPE Prerelease type: rc or saas (default: from config)

Examples:
  # Let git-cliff calculate next version
  $0

  # Show commits that will be analyzed
  $0 --preview

  # Force prerelease mode
  $0 --prerelease

  # Manual override (emergency use)
  RELEASE_AS=4.1.0-rc.3 $0
EOF
}

# Show commits for preview
preview_commits() {
    local since_ref=$1

    echo "==================================="
    echo "Commits since $since_ref"
    echo "==================================="
    git log --oneline --no-decorate "${since_ref}..HEAD" 2>/dev/null || echo "(no commits)"
    echo "==================================="
}

# Get bumped version from git-cliff
get_bumped_version_from_cliff() {
    local current_version=$1
    local ignore_pattern=$2     # Pattern for tags to ignore (rc, saas, or both)
    local since_ref=$3          # Reference point (tag or commit)
    local tag_pattern=$4        # Optional: tag pattern for maintenance branches

    # Build git-cliff arguments
    local cliff_args="--bumped-version"

    # Add tag pattern if provided (for maintenance branches)
    if [[ -n "$tag_pattern" ]]; then
        cliff_args="$cliff_args --tag-pattern '$tag_pattern'"
    fi

    # Add ignore pattern if provided
    if [[ -n "$ignore_pattern" ]]; then
        cliff_args="$cliff_args --ignore-tags '$ignore_pattern'"
    fi

    # Use --use-branch-tags to only consider tags on current branch
    cliff_args="$cliff_args --use-branch-tags"

    # If we have a reference point, add range
    if [[ -n "$since_ref" ]] && [[ "$since_ref" != "(initial)" ]]; then
        cliff_args="$cliff_args ${since_ref}..HEAD"
    fi

    # Use git-cliff to determine the bumped version
    # The --bumped-version flag analyzes unreleased commits
    local bumped
    bumped=$(eval git cliff $cliff_args 2>/dev/null || echo "")

    if [[ -z "$bumped" ]] || [[ "$bumped" == "v0.1.0" ]] || [[ "$bumped" == "0.1.0" ]]; then
        # Fallback: if git-cliff returns 0.1.0 or empty (no tags found)
        # Use manifest version as base and bump it
        warn "git-cliff returned no version or 0.1.0 (no tags found)"
        info "Using manifest version as base: $current_version"
        bump_patch "$(base_version "$current_version")"
    else
        # git-cliff returns version with 'v' prefix, strip it
        echo "${bumped#v}"
    fi
}

# Deprecated: use bump_version() from common.sh (Task #16)
# Kept for backwards compatibility, delegates to common.sh function
bump_patch() {
    bump_version "$1" "patch"
}

add_prerelease_suffix() {
    local version=$1
    local type=$2

    # If already a prerelease of this type with number, increment it
    if [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-${type}\.([0-9]+)$ ]]; then
        local base="${BASH_REMATCH[1]}"
        local num="${BASH_REMATCH[2]}"
        echo "${base}-${type}.$((num + 1))"
    # If already a prerelease of this type WITHOUT number, add .1
    elif [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-${type}$ ]]; then
        echo "${version}.1"
    # If already a prerelease of different type, error
    elif is_prerelease "$version"; then
        fatal "Version $version is already a prerelease of different type"
    # Otherwise, add prerelease suffix
    else
        echo "${version}-${type}.1"
    fi
}

main() {
    init_release_scripts
    require_command git-cliff || require_command git

    local prerelease=""  # empty = use config, true/false = override
    local preview=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run) shift ;;  # accepted for backwards compatibility, now a no-op
            --prerelease) prerelease=true; shift ;;
            --no-prerelease) prerelease=false; shift ;;
            --preview) preview=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    # Read current version
    local current=$(read_current_version)
    info "Current version: $current"

    # Determine if we should create prerelease
    local use_prerelease
    if [[ "$prerelease" == "" ]]; then
        # Use config file setting
        if is_prerelease_enabled; then
            use_prerelease=true
        else
            use_prerelease=false
        fi
        info "Using prerelease setting from config: $use_prerelease"
    else
        # Use explicit parameter
        use_prerelease="$prerelease"
        info "Using explicit prerelease setting: $use_prerelease"
    fi

    # Check for manual override
    if [[ -n "${RELEASE_AS:-}" ]]; then
        local new_version="${RELEASE_AS#v}"  # strip v prefix if present
        validate_tag "v$new_version"
        info "Manual override: $new_version"
    else
        # Detect maintenance branch (pattern: X.Y.x)
        local current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        local maintenance_pattern=""

        if [[ "$current_branch" =~ ^([0-9]+)\.([0-9]+)\.x$ ]]; then
            local major="${BASH_REMATCH[1]}"
            local minor="${BASH_REMATCH[2]}"
            maintenance_pattern="${major}.${minor}"
            info "Detected maintenance branch: $current_branch (filtering tags to v${maintenance_pattern}.*)"
        fi

        # Find reference point (last tag)
        local last_tag=""
        local base_ver=$(base_version "$current")

        # Try to find last tag (consider both stable and prerelease tags)
        if [[ -n "$maintenance_pattern" ]]; then
            # On maintenance branch: only consider tags matching X.Y.* (both stable and prerelease)
            # Use --merged HEAD to only consider reachable tags
            last_tag=$(git tag --list "v${maintenance_pattern}.*" --sort=-version:refname --merged HEAD 2>/dev/null | \
                       grep -v "^v${current}$" | head -n 1 || echo "")
        else
            # Global: consider all tags
            if is_prerelease "$current"; then
                # For prerelease in manifest, look for previous prereleases or stable
                last_tag=$(git tag --list "v${base_ver}*" --sort=-version:refname --merged HEAD 2>/dev/null | \
                           grep -v "^v${current}$" | head -n 1 || \
                           git tag --list "v*" --sort=-version:refname --merged HEAD 2>/dev/null | \
                           grep -v "^v${current}$" | head -n 1 || echo "")
            else
                # For stable in manifest, look for ANY previous tags (stable or prerelease)
                # This handles the case where we're about to create first RC after stable
                last_tag=$(git tag --list "v*" --sort=-version:refname --merged HEAD 2>/dev/null | \
                           grep -v "^v${current}$" | head -n 1 || echo "")
            fi
        fi

        # Fallback for maintenance branches: try previous minor version
        if [[ -z "$last_tag" ]] && [[ -n "$maintenance_pattern" ]]; then
            local major="${maintenance_pattern%%.*}"
            local minor="${maintenance_pattern##*.}"

            # Try previous minor version (e.g., 5.0.x → 4.9.x, or 5.1.x → 5.0.x)
            if [[ "$minor" -gt 0 ]]; then
                # Same major, previous minor (e.g., 5.1.x → 5.0.x)
                local prev_minor=$((minor - 1))
                local prev_pattern="v${major}.${prev_minor}.*"
                warn "No tags found for v${maintenance_pattern}.*, checking ${prev_pattern}"

                if is_prerelease "$current"; then
                    last_tag=$(git tag --list "$prev_pattern" --sort=-version:refname 2>/dev/null | head -n 1 || echo "")
                else
                    last_tag=$(git tag --list "$prev_pattern" --sort=-version:refname 2>/dev/null | \
                               grep -v -E "(rc|saas)" | head -n 1 || echo "")
                fi

                if [[ -n "$last_tag" ]]; then
                    info "Found fallback tag from previous minor: $last_tag"
                fi
            elif [[ "$major" -gt 0 ]]; then
                # minor=0, so try previous major with highest minor (e.g., 5.0.x → 4.*.*)
                local prev_major=$((major - 1))
                local prev_pattern="v${prev_major}.*"
                warn "No tags found for v${maintenance_pattern}.*, checking ${prev_pattern}"

                if is_prerelease "$current"; then
                    last_tag=$(git tag --list "$prev_pattern" --sort=-version:refname 2>/dev/null | head -n 1 || echo "")
                else
                    last_tag=$(git tag --list "$prev_pattern" --sort=-version:refname 2>/dev/null | \
                               grep -v -E "(rc|saas)" | head -n 1 || echo "")
                fi

                if [[ -n "$last_tag" ]]; then
                    info "Found fallback tag from previous major: $last_tag"
                fi
            fi
        fi

        if [[ -z "$last_tag" ]]; then
            warn "No previous tag found"
            last_tag="(initial)"
        fi

        info "Reference point: $last_tag"

        # Show preview if requested
        if [[ "$preview" == "true" ]] && [[ "$last_tag" != "(initial)" ]]; then
            preview_commits "$last_tag"
        fi

        # Determine which tags to ignore based on prerelease type
        local ignore_pattern=""
        if [[ "$use_prerelease" == "true" ]]; then
            local prerelease_type="${PRERELEASE_TYPE:-$(get_prerelease_type)}"

            # If creating RC releases, ignore saas tags (and vice versa)
            case "$prerelease_type" in
                rc)
                    ignore_pattern=".*-saas.*"
                    info "Ignoring saas tags for RC release calculation"
                    ;;
                saas)
                    ignore_pattern=".*-rc.*"
                    info "Ignoring rc tags for saas release calculation"
                    ;;
            esac
        else
            # For stable releases, ignore ALL prerelease tags
            ignore_pattern=".*-(rc|saas).*"
            info "Ignoring all prerelease tags for stable release calculation"
        fi

        # Prepare tag pattern for maintenance branches
        local tag_pattern_arg=""
        if [[ -n "$maintenance_pattern" ]]; then
            tag_pattern_arg="v${maintenance_pattern}.*"
            info "Using tag pattern for maintenance branch: $tag_pattern_arg"
        fi

        # Always use git-cliff to determine version (single source of truth)
        info "Using git-cliff to calculate version bump..."
        local base_new=$(get_bumped_version_from_cliff "$current" "$ignore_pattern" "$last_tag" "$tag_pattern_arg")

        # If in prerelease mode, add/increment the prerelease suffix
        if [[ "$use_prerelease" == "true" ]]; then
            local prerelease_type="${PRERELEASE_TYPE:-$(get_prerelease_type)}"

            # Check if git-cliff already returned a prerelease version
            if is_prerelease "$base_new"; then
                # Git-cliff returned a prerelease - use it as-is or increment if same type
                if [[ "$base_new" =~ -${prerelease_type} ]]; then
                    new_version="$base_new"
                    info "Git-cliff returned prerelease: $base_new (using as-is)"
                else
                    # Different prerelease type - this shouldn't happen, but add our suffix
                    new_version=$(add_prerelease_suffix "$base_new" "$prerelease_type")
                    info "Git-cliff returned different prerelease type, converting: $base_new → $new_version"
                fi
            else
                # Git-cliff returned stable version - add prerelease suffix
                new_version="${base_new}-${prerelease_type}.1"
                info "Git-cliff bumped: $(base_version "$current") → ${base_new}, adding prerelease: $new_version"
            fi
        else
            new_version="$base_new"
            info "Git-cliff bumped: $(base_version "$current") → ${base_new}"
        fi
    fi

    info "New version: $new_version"

    # Validate calculated version doesn't already exist as tag
    if tag_exists "v${new_version}"; then
        fatal "Calculated version already exists as tag: v${new_version}"
    fi

    # Output version for use in other scripts.
    # version.sh is read-only: it never writes to disk.
    # Git tags are the source of truth; the manifest is not updated here.
    echo "$new_version"
}

# Only run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
