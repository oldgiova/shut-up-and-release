#!/bin/bash
# Promote a prerelease tag to stable release
# New simplified flow: No PR needed, direct tagging
# shellcheck disable=SC2155  # Declare and assign separately
# shellcheck disable=SC2312  # Consider invoking separately

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<EOF
Usage: $0 [prerelease-tag] [options]

Promote a prerelease tag (RC or saas) to stable release.

New simplified flow (no PR):
  1. Finalize CHANGELOG-enterprise.md (replace "unreleased" with date)
  2. Update manifest to stable version
  3. Commit changes
  4. Create and push stable tag
  5. Create GitHub release

Arguments:
  prerelease-tag  The prerelease tag to promote (optional)
                  If not provided, auto-detects latest prerelease tag
                  Examples: v4.1.0-rc.2, v10.1.0-saas.1

Options:
  --auto-yes      Skip confirmation prompts (for CI)
  --no-push       Don't push (for testing)
  --no-commit     Don't commit changes (for testing)

Examples:
  # Auto-detect latest prerelease and promote
  $0

  # Promote specific tag
  $0 v10.1.0-saas.1

  # Non-interactive (CI mode)
  $0 --auto-yes
EOF
}

main() {
    init_release_scripts
    require_command gh

    local prerelease_tag=""
    local push=true
    local auto_yes=false
    local do_commit=true

    while [[ $# -gt 0 ]]; do
        case $1 in
            --no-push) push=false; shift ;;
            --no-commit) do_commit=false; shift ;;
            --auto-yes) auto_yes=true; shift ;;
            -h|--help) usage; exit 0 ;;
            v*) prerelease_tag=$1; shift ;;
            *)
                # Accept without v prefix
                if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+-(rc|saas)\.[0-9]+$ ]]; then
                    prerelease_tag="v$1"
                    shift
                else
                    error "Unknown option: $1"
                    usage
                    exit 1
                fi
                ;;
        esac
    done

    # Auto-detect latest prerelease tag if not provided
    if [[ -z "$prerelease_tag" ]]; then
        info "Auto-detecting latest prerelease tag..."

        # Find latest RC or saas tag
        prerelease_tag=$(git tag --list "v*" --sort=-version:refname 2>/dev/null | \
                         grep -E '\-(rc|saas)\.' | head -n 1 || echo "")

        if [[ -z "$prerelease_tag" ]]; then
            fatal "No prerelease tags found (expected vX.Y.Z-rc.N or vX.Y.Z-saas.N)"
        fi

        info "Found latest prerelease: $prerelease_tag"
        echo ""

        # Ask for confirmation unless --auto-yes
        if [[ "$auto_yes" == "false" ]]; then
            # Show recent prerelease tags
            echo "Recent prerelease tags:"
            git tag --list "v*" --sort=-version:refname 2>/dev/null | \
                grep -E '\-(rc|saas)\.' | head -5 | sed 's/^/  /' || true
            echo ""

            read -p "Promote $prerelease_tag to stable? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                info "Promotion cancelled"
                exit 0
            fi
        fi
    fi

    # Validate tag format (rc or saas)
    if [[ ! "$prerelease_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-(rc|saas)\.[0-9]+$ ]]; then
        fatal "Invalid prerelease tag format: $prerelease_tag (expected: vX.Y.Z-rc.N or vX.Y.Z-saas.N)"
    fi

    # Validate prerelease tag exists
    if ! tag_exists "$prerelease_tag"; then
        fatal "Prerelease tag does not exist: $prerelease_tag"
    fi

    # Extract stable version
    local stable_version=$(base_version "$prerelease_tag")
    local stable_tag="v${stable_version}"

    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Promoting to Stable Release"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  From: $prerelease_tag"
    info "  To:   $stable_tag"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Validate stable tag doesn't already exist
    if tag_exists "$stable_tag"; then
        fatal "Stable tag already exists: $stable_tag"
    fi

    # Validate we're on a clean state
    if ! is_clean_worktree; then
        fatal "Working tree is not clean. Commit or stash changes first."
    fi

    # Step 1: Finalize CHANGELOG-enterprise.md
    info "→ Step 1/5: Finalizing CHANGELOG-enterprise.md..."

    local enterprise_changelog="CHANGELOG-enterprise.md"
    if [[ ! -f "$enterprise_changelog" ]]; then
        warn "Enterprise changelog not found: $enterprise_changelog"
        warn "Skipping changelog finalization"
    else
        # Replace "(unreleased)" with actual date
        local today=$(date +%Y-%m-%d)
        local stable_ver_escaped=$(echo "$stable_version" | sed 's/\./\\./g')

        # Update unreleased marker to actual date
        sed -i -E "s/^## ${stable_ver_escaped} \(unreleased\)/## ${stable_version} - ${today}/" "$enterprise_changelog"
        sed -i -E "s/^## v${stable_ver_escaped} \(unreleased\)/## ${stable_version} - ${today}/" "$enterprise_changelog"
        sed -i -E "s/^## \[${stable_ver_escaped}\] \(unreleased\)/## ${stable_version} - ${today}/" "$enterprise_changelog"

        info "✓ Finalized changelog with date: $today"
    fi

    echo ""

    # Step 2: Commit changes (no manifest to update - version comes from tag!)
    info "→ Step 2/4: Committing changelog changes..."

    # Note: We skip the old Step 2 (updating manifest) - no longer needed!
    if [[ "$do_commit" == "true" ]]; then
        git add "$enterprise_changelog" 2>/dev/null || warn "Could not add enterprise changelog"

        if git diff --cached --quiet; then
            info "No changes to commit"
        else
            local commit_msg="chore: promote ${prerelease_tag} to stable ${stable_tag}"
            git commit -s -m "$commit_msg" \
                --trailer "Co-Authored-By: release-automation <noreply@northern.tech>" || \
                fatal "Failed to commit changes"
            info "✓ Changes committed"
        fi
    else
        info "⊘ Skipping commit (--no-commit)"
    fi

    echo ""

    # Step 3: Create and push tag
    info "→ Step 3/4: Creating stable tag..."

    git tag -a "$stable_tag" -m "Release ${stable_version} (promoted from ${prerelease_tag})" || \
        fatal "Failed to create tag"

    info "✓ Tag created: $stable_tag"
    echo ""

    if [[ "$push" == "true" ]]; then
        info "→ Pushing changes and tag..."

        if [[ "$do_commit" == "true" ]]; then
            retry_git push origin HEAD || fatal "Failed to push commit"
            info "✓ Commit pushed"
        fi

        retry_git push origin "$stable_tag" || fatal "Failed to push tag"
        info "✓ Tag pushed to origin"
    else
        info "⊘ Skipping push (--no-push)"
    fi

    echo ""

    # Step 4: Create GitHub release
    info "→ Step 4/4: Creating GitHub release..."

    "${SCRIPT_DIR}/release.sh" "$stable_tag" || fatal "Failed to create GitHub release"

    echo ""
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "✓ Promotion complete!"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info ""
    info "  Prerelease: $prerelease_tag"
    info "  Stable:     $stable_tag"
    info "  Release:    https://github.com/${GITHUB_REPO_URL}/releases/tag/$stable_tag"
    info ""
}

# Only run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
