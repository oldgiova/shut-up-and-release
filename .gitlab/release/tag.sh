#!/bin/bash
# Create release tag from manifest version

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<EOF
Usage: $0 [options]

Create git tag using version calculated from git-cliff.
Uses git tags + commits to determine the next version (no manifest needed).

Options:
  --push          Push tag to origin after creating
  --force         Force create tag (overwrite if exists)
  -h, --help      Show this help

Examples:
  # Create tag locally
  $0

  # Create and push tag
  $0 --push

  # Force recreate tag
  $0 --force --push
EOF
}

main() {
    init_release_scripts

    local push=false
    local force=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --push) push=true; shift ;;
            --force) force="-f"; shift ;;
            -h|--help) usage; exit 0 ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    # Calculate version using version.sh (git-cliff + git tags)
    info "Calculating version from git history..."
    local version=$("${SCRIPT_DIR}/version.sh" --dry-run 2>/dev/null | tail -1)

    if [[ -z "$version" ]] || [[ "$version" == "0.0.0" ]]; then
        fatal "Could not calculate version from git history"
    fi

    local tag="v${version}"

    info "Calculated version: $version"
    info "Tag to create: $tag"

    # Check if tag already exists
    if tag_exists "$tag"; then
        if [[ -z "$force" ]]; then
            fatal "Tag already exists: $tag (use --force to overwrite)"
        else
            warn "Tag exists, will force overwrite"
        fi
    fi

    # Validate we're on a clean state
    if ! is_clean_worktree; then
        warn "Working tree is not clean"
    fi

    # Create tag
    info "Creating tag: $tag"
    git tag $force -a "$tag" -m "Release ${version}" || fatal "Failed to create tag"

    info "✓ Tag created: $tag"

    # Push if requested
    if [[ "$push" == "true" ]]; then
        info "Pushing tag to origin..."
        git push $force origin "$tag" || fatal "Failed to push tag"
        info "✓ Tag pushed to origin"
    else
        info ""
        info "To push the tag, run:"
        info "  git push origin $tag"
    fi

    echo ""
    echo "$tag"
}

# Only run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
