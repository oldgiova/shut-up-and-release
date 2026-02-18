#!/bin/bash
# Publish a release: create tag, push it, and create GitHub release

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<EOF
Usage: $0 [options]

Complete release workflow. MUST be run after the release PR is merged:
  1. Verify no release PR is still open
  2. Determine version from the merged release PR (autorelease: pending label)
  3. Create git tag and push it
  4. Wait for CI pipeline (optional)
  5. Create GitHub release

Workflow:
  make release-pr       → open (or update) the release PR
  <merge the PR>        ← you must do this before running release-publish
  make release-publish  → tag + push + GitHub release

Options:
  --skip-tag      Skip tag creation (if already exists)
  --skip-ci-wait  Don't wait for CI pipeline
  --force-tag     Force recreate tag if exists
  -h, --help      Show this help

Examples:
  # Complete release (recommended)
  $0

  # Release but don't wait for CI
  $0 --skip-ci-wait

  # Tag already exists, just create GitHub release
  $0 --skip-tag
EOF
}

wait_for_ci() {
    local tag=$1

    info "Waiting for CI pipeline to complete..."
    info "Check pipeline at: https://github.com/${GITHUB_REPO_URL}/actions"
    echo ""

    # Simple wait with user confirmation
    read -p "Press ENTER when CI pipeline is GREEN (or Ctrl+C to abort)..."
    echo ""
}

main() {
    init_release_scripts
    require_command gh

    local skip_tag=false
    local force_tag=""
    local skip_ci_wait=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-tag) skip_tag=true; shift ;;
            --force-tag) force_tag="--force"; shift ;;
            --skip-ci-wait) skip_ci_wait=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) error "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    # Guard: refuse to publish while a release PR is still open.
    # version.sh calculates the same version whether the PR is merged or not
    # (the commits are already on the base branch either way), so without this
    # check publish.sh would happily tag with a stale CHANGELOG.
    info "Checking for open release PRs..."
    local open_pr
    open_pr=$(gh pr list \
        --state open \
        --label "autorelease: pending" \
        --json number,title \
        --jq '.[0] | select(. != null) | "#\(.number): \(.title)"' 2>/dev/null || echo "")

    if [[ -n "$open_pr" ]]; then
        warn "Release PR is still open: ${open_pr}"
        warn "Merge it first, then run 'make release-publish'."
        exit 0
    fi

    # Find the version from the most recently merged release PR.
    # publish.sh does NOT use version.sh: version.sh answers "what should the
    # next version be?", while publish.sh needs "what did we just prepare?".
    # The merged release PR (still labeled 'autorelease: pending' until we tag it)
    # is the authoritative source for the version to publish.
    info "Finding version from merged release PR..."
    local pr_info
    pr_info=$(gh pr list \
        --state merged \
        --label "autorelease: pending" \
        --limit 1 \
        --json number,title \
        --jq '.[0] | select(. != null) | "\(.number)|\(.title)"' 2>/dev/null || echo "")

    if [[ -z "$pr_info" ]]; then
        info "No merged release PR found (label: 'autorelease: pending') — nothing to publish"
        exit 0
    fi

    local pr_number="${pr_info%%|*}"
    local pr_title="${pr_info##*|}"

    # Extract version from PR title: "chore(branch): release X.Y.Z[-type.N]"
    local version
    version=$(echo "$pr_title" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?")

    if [[ -z "$version" ]]; then
        fatal "Could not extract version from PR title: '$pr_title'"
    fi

    validate_tag "v${version}"
    info "Version from merged PR #${pr_number}: $version"

    local tag="v${version}"

    info "Publishing release: $version"
    echo ""

    # Step 1: Create and push tag
    if [[ "$skip_tag" == "true" ]]; then
        info "⊘ Skipping tag creation (--skip-tag)"

        # Verify tag exists
        if ! tag_exists "$tag"; then
            fatal "Tag does not exist: $tag (remove --skip-tag to create it)"
        fi
    else
        info "→ Step 1/3: Creating and pushing tag..."

        # Check if tag exists
        if tag_exists "$tag"; then
            if [[ -z "$force_tag" ]]; then
                warn "Tag already exists: $tag"
                read -p "Recreate tag? (y/N): " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    info "Using existing tag"
                else
                    force_tag="--force"
                fi
            fi
        fi

        # Create tag
        if [[ -n "$force_tag" ]]; then
            info "Force creating tag: $tag"
            git tag -f -a "$tag" -m "Release ${version}"
        else
            if ! tag_exists "$tag"; then
                info "Creating tag: $tag"
                git tag -a "$tag" -m "Release ${version}"
            fi
        fi

        # Push tag
        info "Pushing tag to origin..."
        git push $force_tag origin "$tag" || fatal "Failed to push tag"

        info "✓ Tag created and pushed: $tag"
        echo ""
    fi

    # Step 2: Wait for CI
    if [[ "$skip_ci_wait" == "false" ]]; then
        info "→ Step 2/3: CI Pipeline"
        wait_for_ci "$tag"
    else
        info "⊘ Skipping CI wait (--skip-ci-wait)"
        echo ""
    fi

    # Step 3: Create GitHub release
    info "→ Step 3/3: Creating GitHub release..."

    # Check if release already exists
    if gh release view "$tag" &>/dev/null; then
        warn "GitHub release already exists for $tag"
        read -p "Update it? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Skipping GitHub release"
            echo ""
            info "✓ Release published: $tag"
            return 0
        fi
    fi

    "${SCRIPT_DIR}/release.sh" "$tag" || fatal "Failed to create GitHub release"

    echo ""
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "✓ Release published successfully!"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info ""
    info "  Tag:     $tag"
    info "  Release: https://github.com/${GITHUB_REPO_URL}/releases/tag/$tag"
    if [[ -n "$pr_number" ]]; then
        info "  PR:      #$pr_number (labeled: autorelease: tagged)"
    fi
    info ""
}

# Only run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
