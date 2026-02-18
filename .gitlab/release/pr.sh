#!/bin/bash
# Create and manage release PRs
# shellcheck disable=SC2155  # Declare and assign separately
# shellcheck disable=SC2312  # Consider invoking separately

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<EOF
Usage: $0 [version] [options]

Create a release PR with version bump and changelog.

Arguments:
  version     Version for this release (optional, auto-calculated from commits if not provided)
              Example: 4.1.0 or 4.1.0-rc.1

Options:
  --title TITLE       PR title (default: auto-generated)
  --body FILE         PR body file (default: auto-generated from changelog)
  --base BRANCH       Base branch (default: current branch)
  --no-push           Don't push branch (for testing)

Environment Variables:
  FORCE_PUSH          Set to 'true' to force push when remote branch has diverged
                      (default: false - will fail with helpful error instead)

Single Source of Truth:
  Version is calculated by version.sh using git-cliff based on conventional commits.
  Manual version override is possible but not recommended.

This script is idempotent: if the PR branch already exists, it will update it.

Push Safety:
  By default, this script will NOT force push. If the remote branch has diverged
  (e.g., someone else modified it), the push will fail with a clear error.
  Set FORCE_PUSH=true to override this safety check.

Examples:
  # Auto-calculate version and create PR (recommended)
  $0 --base master

  # Manual version override (not recommended)
  $0 4.2.0 --base master

  # Custom title
  $0 4.1.0 --title "chore: release 4.1.0 (promoted from RC)"
EOF
}

# Generate PR branch name (matching release-please convention)
generate_pr_branch_name() {
    local base_branch=$1
    echo "release-please--branches--${base_branch}"
}

# Generate PR title with branch scope
generate_pr_title() {
    local version=$1
    local base_branch=$2

    # Use base branch as scope (e.g., chore(master): release X.Y.Z)
    echo "chore(${base_branch}): release ${version}"
}

main() {
    init_release_scripts
    require_command gh

    local version=""
    local title=""
    local body_file=""
    local base_branch=$(current_branch)
    local original_branch="$base_branch"  # Remember where we started
    local push=true
    local _on_pr_branch=false
    local temp_body=""
    local push_output=""

    local prerelease_flag=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --prerelease) prerelease_flag="--prerelease"; shift ;;
            --no-prerelease) prerelease_flag="--no-prerelease"; shift ;;
            --title) title=$2; shift 2 ;;
            --body) body_file=$2; shift 2 ;;
            --base) base_branch=$2; shift 2 ;;
            --no-push) push=false; shift ;;
            -h|--help) usage; exit 0 ;;
            -*) error "Unknown option: $1"; usage; exit 1 ;;
            *) version=$1; shift ;;
        esac
    done

    # Validate worktree is clean before any version calculation
    if ! is_clean_worktree; then
        fatal "Working tree is not clean. Commit or stash changes first."
    fi

    # Auto-calculate version if not provided (single source of truth: git-cliff via version.sh)
    if [[ -z "$version" ]]; then
        info "No version specified, calculating from commits using version.sh..."

        # Call version.sh to calculate the version based on commits
        version=$("${SCRIPT_DIR}/version.sh" ${prerelease_flag:+"$prerelease_flag"} 2>/dev/null)
        local version_exit=$?

        if [[ $version_exit -ne 0 ]] || [[ -z "$version" ]]; then
            fatal "Failed to calculate version from version.sh"
        fi

        info "Calculated version: $version"
    else
        # Strip v prefix if present
        version="${version#v}"
        warn "Version manually specified: $version (consider letting version.sh calculate it)"
    fi

    # Generate PR branch name (matching release-please convention)
    local pr_branch=$(generate_pr_branch_name "$base_branch")

    info "Creating release PR for version: v$version"
    info "Base branch: $base_branch"
    info "PR branch: $pr_branch"

    # Check if PR branch already exists remotely
    local branch_exists=false
    if remote_branch_exists "$pr_branch"; then
        warn "PR branch already exists remotely, will update it"
        branch_exists=true
    fi

    # Create/checkout PR branch
    if git rev-parse --verify "$pr_branch" &>/dev/null; then
        info "Checking out existing local branch: $pr_branch"
        git checkout "$pr_branch"
        if [[ "$branch_exists" == "true" ]]; then
            git pull origin "$pr_branch" || warn "Could not pull from origin"
        fi
    else
        info "Creating new branch: $pr_branch"
        git checkout -b "$pr_branch" "$base_branch"
    fi

    _on_pr_branch=true

    # Combined cleanup trap: handles temp files AND branch restoration on any exit.
    # Single quotes ensure variables expand at trap execution time, not registration time.
    # _on_pr_branch=false is set before the explicit return at the end, so the trap
    # only performs the branch restore when the script exits mid-run (error/signal).
    trap 'rm -f "$temp_body" "$push_output" 2>/dev/null; \
          if [[ "$_on_pr_branch" == "true" ]]; then \
              git checkout "$original_branch" 2>/dev/null || true; \
          fi' EXIT INT TERM

    # Generate changelog (no manifest to update - version comes from git tags!)
    temp_body=$(mktemp -t "release-pr-XXXXXX")
    info "Generating changelog for version: $version..."

    "${SCRIPT_DIR}/changelog.sh" "$version" --pr-body "$temp_body"
    local changelog_exit=$?

    if [[ $changelog_exit -ne 0 ]]; then
        warn "Changelog generation had issues (exit code: $changelog_exit)"
    fi

    # Use provided body file or generated one
    if [[ -n "$body_file" ]]; then
        if [[ -f "$body_file" ]]; then
            temp_body="$body_file"
        else
            warn "Provided body file not found: $body_file, using generated"
        fi
    fi

    # Stage changelog changes (no manifest file to stage)
    git add CHANGELOG*.md 2>/dev/null || warn "No changelog files to add"

    # Check if there are changes to commit
    if git diff --cached --quiet; then
        info "No changes to commit (already up to date)"
    else
        # Commit changes
        local commit_msg=$(generate_pr_title "$version" "$base_branch")
        info "Committing changes: $commit_msg"

        git commit -s -m "$commit_msg" \
            --trailer "Co-Authored-By: release-automation <noreply@northern.tech>" || \
            fatal "Failed to commit changes"
    fi

    # Push branch
    if [[ "$push" == "true" ]]; then
        info "Pushing branch to origin..."

        # Safe push logic: try normal push first, only force if explicitly allowed
        push_output=$(mktemp -t "push-output-XXXXXX")

        if retry_git push origin "$pr_branch" 2>&1 | tee "$push_output"; then
            info "Branch pushed successfully"
            rm -f "$push_output"
        else
            # Check if rejection was due to divergence
            if grep -q "rejected.*non-fast-forward\|rejected.*fetch first\|rejected.*would clobber" "$push_output"; then
                warn "Branch has diverged from remote"
                warn "Remote branch was modified by someone else"

                # Fetch remote to get latest state
                git fetch origin "$pr_branch" 2>/dev/null || true

                # Show what will be overwritten
                info "Remote commits that will be lost:"
                git log --oneline "$pr_branch..origin/$pr_branch" 2>/dev/null || \
                    warn "Could not show remote commits (branch might not exist remotely yet)"

                # Require explicit confirmation
                if [[ "${FORCE_PUSH:-false}" == "true" ]]; then
                    warn "FORCE_PUSH=true, forcing push..."
                    retry_git push -f origin "$pr_branch" || fatal "Force push failed"
                    info "Force push completed"
                else
                    fatal "Push rejected. Remote branch has changes.\n" \
                          "  Set FORCE_PUSH=true to override, or pull changes first with:\n" \
                          "    git checkout $pr_branch && git pull origin $pr_branch"
                fi
            else
                # Some other error
                error "Push failed for unknown reason. Output:"
                cat "$push_output" >&2
                rm -f "$push_output"
                fatal "Push failed"
            fi
            rm -f "$push_output"
        fi

        # Create or update PR
        if [[ "$branch_exists" == "true" ]]; then
            # Check if PR exists
            local pr_number=$(retry_gh pr list --head "$pr_branch" --json number -q '.[0].number' 2>/dev/null || echo "")

            if [[ -n "$pr_number" ]]; then
                info "Updating existing PR #$pr_number..."
                if [[ -f "$temp_body" ]] && [[ -s "$temp_body" ]]; then
                    retry_gh pr edit "$pr_number" --body-file "$temp_body" || warn "Could not update PR body"
                fi
                info "Updated PR #$pr_number"
            else
                warn "PR branch exists but no PR found, creating new one..."
                branch_exists=false
            fi
        fi

        if [[ "$branch_exists" == "false" ]]; then
            # Create new PR
            local pr_title="${title:-$(generate_pr_title "$version" "$base_branch")}"
            info "Creating PR: $pr_title"

            local gh_args=(
                pr create
                --title "$pr_title"
                --base "$base_branch"
                --head "$pr_branch"
                --label "autorelease: pending"
            )

            # Add body if file exists and is not empty
            if [[ -f "$temp_body" ]] && [[ -s "$temp_body" ]]; then
                gh_args+=(--body-file "$temp_body")
            else
                gh_args+=(--body "Release $version")
            fi

            retry_gh "${gh_args[@]}" || fatal "Failed to create PR"

            info "PR created successfully"
        fi
    else
        info "Skipping push (--no-push specified)"
    fi

    # Cleanup temp file if we created it
    if [[ "$temp_body" != "$body_file" ]] && [[ -f "$temp_body" ]]; then
        rm -f "$temp_body"
    fi

    # Return to original branch (handle worktrees).
    # Disable the trap's branch restoration first to prevent a double-checkout.
    _on_pr_branch=false
    if [[ "$original_branch" != "$pr_branch" ]]; then
        if git checkout "$original_branch" 2>/dev/null; then
            info "Returned to original branch: $original_branch"
        else
            # Probably in a worktree where the branch is checked out elsewhere
            warn "Could not return to original branch '$original_branch' (might be in another worktree)"
            info "Currently on branch: $(git rev-parse --abbrev-ref HEAD)"
        fi
    fi

    info "Release PR prepared successfully"
}

# Only run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
