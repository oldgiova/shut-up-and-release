#!/bin/bash
# Promote a prerelease tag to stable release via PR
#
# New PR-based flow:
#   1. Validate prerelease tag and CHANGELOG.md (unreleased) section
#   2. Create a promote PR that replaces "(unreleased)" with the release date
#   3. After PR is merged, run 'make release-publish' to tag + GitHub release
#
# shellcheck disable=SC2155  # Declare and assign separately
# shellcheck disable=SC2312  # Consider invoking separately

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<EOF
Usage: $0 [prerelease-tag] [options]

Promote a prerelease tag (RC or saas) to stable release via a PR.

New PR-based flow:
  1. Validate prerelease tag and CHANGELOG.md '(unreleased)' section
  2. Create a promote PR replacing "(unreleased)" with the actual release date
  3. After merging the PR, run 'make release-publish' to create tag + GitHub release

Note: CHANGELOG.md must already have a '## X.Y.Z (unreleased)' section.
  Run 'make release-pr' (prerelease) first — it creates this section automatically.

Arguments:
  prerelease-tag  The prerelease tag to promote (optional)
                  If not provided, auto-detects latest prerelease tag
                  Examples: v4.1.0-rc.2, v10.1.0-saas.1

Options:
  --auto-yes      Skip confirmation prompts (for CI)
  --no-push       Don't push branch or create PR (for testing)
  -h, --help      Show this help

Examples:
  # Auto-detect latest prerelease and create promote PR
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

    while [[ $# -gt 0 ]]; do
        case $1 in
            --no-push) push=false; shift ;;
            --auto-yes) auto_yes=true; shift ;;
            -h|--help) usage; exit 0 ;;
            v*) prerelease_tag=$1; shift ;;
            *)
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

        prerelease_tag=$(git tag --list "v*" --sort=-version:refname 2>/dev/null | \
                         grep -E '\-(rc|saas)' | head -n 1 || echo "")

        if [[ -z "$prerelease_tag" ]]; then
            fatal "No prerelease tags found (expected vX.Y.Z-rc.N or vX.Y.Z-saas.N)"
        fi

        info "Found latest prerelease: $prerelease_tag"
        echo ""

        if [[ "$auto_yes" == "false" ]]; then
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

    # Validate tag format (rc or saas, with optional .N suffix per semver)
    if [[ ! "$prerelease_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-(rc|saas)(\.[0-9]+)?$ ]]; then
        fatal "Invalid prerelease tag format: $prerelease_tag (expected: vX.Y.Z-rc or vX.Y.Z-saas, optionally with .N suffix)"
    fi

    # Validate prerelease tag exists
    if ! tag_exists "$prerelease_tag"; then
        fatal "Prerelease tag does not exist: $prerelease_tag"
    fi

    # Extract stable version
    local stable_version
    stable_version=$(base_version "$prerelease_tag")
    local stable_tag="v${stable_version}"

    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  Promoting to Stable Release (via PR)"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  From: $prerelease_tag"
    info "  To:   $stable_tag"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Guard: stable tag must not already exist
    if tag_exists "$stable_tag"; then
        fatal "Stable tag already exists: $stable_tag"
    fi

    # Guard: CHANGELOG.md must have the (unreleased) section for this version
    local changelog="CHANGELOG.md"
    local escaped_version
    escaped_version=$(echo "$stable_version" | sed 's/\./\\./g')

    if [[ ! -f "$changelog" ]]; then
        fatal "CHANGELOG.md not found.
  Run 'make release-pr' (prerelease) first — it creates the '## ${stable_version} (unreleased)' section."
    fi

    if ! grep -qE "^## ${escaped_version} \(unreleased\)" "$changelog" 2>/dev/null; then
        fatal "CHANGELOG.md has no '## ${stable_version} (unreleased)' section.
  Run 'make release-pr' (prerelease) first — it creates this section automatically."
    fi

    # Guard: working tree must be clean
    if ! is_clean_worktree; then
        fatal "Working tree is not clean. Commit or stash changes first."
    fi

    local base_branch
    base_branch=$(current_branch)
    local original_branch="$base_branch"
    local pr_branch="release-please--branches--${base_branch}--promote"
    local _on_pr_branch=false

    # Cleanup trap: restore original branch on any unexpected exit
    trap 'if [[ "$_on_pr_branch" == "true" ]]; then
              git checkout "$original_branch" 2>/dev/null || true
          fi' EXIT INT TERM

    # Always reset the promote branch to the current base tip
    info "Creating promote PR branch: $pr_branch"
    git checkout -B "$pr_branch" "$base_branch"
    _on_pr_branch=true

    # Step 1: Replace "(unreleased)" with actual date in CHANGELOG.md
    info "→ Step 1/3: Finalizing CHANGELOG.md..."

    local today
    today=$(date +%Y-%m-%d)

    sed -i -E "s/^## ${escaped_version} \(unreleased\)/## ${stable_version} - ${today}/" "$changelog"

    if git diff --quiet "$changelog"; then
        fatal "sed did not modify CHANGELOG.md — the pattern '## ${stable_version} (unreleased)' was not found"
    fi

    info "✓ '## ${stable_version} (unreleased)' → '## ${stable_version} - ${today}'"
    echo ""

    # Step 2: Commit
    info "→ Step 2/3: Committing..."

    git add "$changelog"
    local commit_msg="chore(${base_branch}): release ${stable_version}"
    git commit -s -m "$commit_msg" \
        --trailer "Co-Authored-By: release-automation <noreply@northern.tech>" || \
        fatal "Failed to commit changes"

    info "✓ Committed: $commit_msg"
    echo ""

    # Step 3: Push and create PR
    if [[ "$push" == "true" ]]; then
        info "→ Step 3/3: Pushing branch and creating PR..."

        local branch_exists=false
        if remote_branch_exists "$pr_branch"; then
            branch_exists=true
            retry_git push --force origin "$pr_branch" || fatal "Force push failed"
        else
            retry_git push origin "$pr_branch" || fatal "Push failed"
        fi

        # Check for existing PR on this branch
        if [[ "$branch_exists" == "true" ]]; then
            local pr_number
            pr_number=$(retry_gh pr list --head "$pr_branch" --json number \
                        -q '.[0].number' 2>/dev/null || echo "")
            if [[ -n "$pr_number" ]]; then
                info "Updating existing PR #${pr_number}..."
                retry_gh pr edit "$pr_number" --title "$commit_msg" || \
                    warn "Could not update PR title"
                info "✓ Updated PR #${pr_number}"
            else
                branch_exists=false
            fi
        fi

        if [[ "$branch_exists" == "false" ]]; then
            local pr_body
            pr_body="Promote \`${prerelease_tag}\` to stable \`${stable_tag}\`.

After merging this PR, run \`make release-publish\` to create the tag and GitHub release."
            retry_gh pr create \
                --title "$commit_msg" \
                --base "$base_branch" \
                --head "$pr_branch" \
                --label "autorelease: pending" \
                --body "$pr_body" || fatal "Failed to create PR"
            info "✓ Promote PR created"
        fi
    else
        info "⊘ Skipping push (--no-push)"
    fi

    echo ""

    # Return to original branch
    _on_pr_branch=false
    if [[ "$original_branch" != "$pr_branch" ]]; then
        if git checkout "$original_branch" 2>/dev/null; then
            info "Returned to original branch: $original_branch"
        else
            warn "Could not return to original branch '$original_branch' (might be in another worktree)"
            info "Currently on branch: $(git rev-parse --abbrev-ref HEAD)"
        fi
    fi

    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "✓ Promote PR ready!"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info ""
    info "  Prerelease:  $prerelease_tag"
    info "  Stable:      $stable_tag"
    info ""
    info "Next steps:"
    info "  1. Review and merge the promote PR on GitHub"
    info "  2. Run 'make release-publish' to tag and create GitHub release"
    info ""
}

# Only run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
