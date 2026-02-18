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

Single Source of Truth:
  Version is calculated by version.sh using git-cliff based on conventional commits.
  Manual version override is possible but not recommended.

This script is idempotent: if the PR branch already exists, it will update it.
The PR branch is always reset to the base branch tip before regenerating the
changelog, so new commits on the base branch are always included. Updates use
--force since the branch is fully managed by this script.

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

# For prerelease PRs, maintain CHANGELOG.md with a cumulative (unreleased) section
# so that promote.sh can later open a PR replacing "(unreleased)" with the release date.
#
# Strategy:
#   1. Find last stable tag to use as the range start for git-cliff
#   2. Run git-cliff for stable_version over that range (ignoring rc/saas tags)
#   3. Extract the ## {stable_version} section and replace the date with "(unreleased)"
#   4. Splice that section into CHANGELOG.md (replacing an existing one if present)
update_unreleased_stable_changelog() {
    local stable_version=$1  # e.g. "0.0.6" (no v prefix)

    info "Updating CHANGELOG.md with ## ${stable_version} (unreleased) section..."

    # Find last stable tag for commit range
    local last_stable_tag
    last_stable_tag=$(git tag --list "v*" --sort=-version:refname 2>/dev/null | \
                      grep -v -E -- '-(rc|saas)' | head -n 1 || echo "")

    local range_arg
    if [[ -n "$last_stable_tag" ]]; then
        range_arg="${last_stable_tag}..HEAD"
        info "  git-cliff range: ${last_stable_tag}..HEAD"
    else
        range_arg="--unreleased"
        info "  No previous stable tag found, using --unreleased"
    fi

    # Generate full changelog output using git-cliff (local only, no API calls)
    local temp_cliff_out
    temp_cliff_out=$(mktemp -t "cliff-out-XXXXXX")

    if ! git cliff ${range_arg} \
            --tag "v${stable_version}" \
            --ignore-tags '.*-(rc|saas).*' \
            --use-branch-tags \
            --no-exec > "$temp_cliff_out" 2>/dev/null; then
        warn "git-cliff failed for CHANGELOG.md unreleased section, skipping"
        rm -f "$temp_cliff_out"
        return 0
    fi

    if [[ ! -s "$temp_cliff_out" ]]; then
        warn "git-cliff produced empty output, skipping CHANGELOG.md unreleased section"
        rm -f "$temp_cliff_out"
        return 0
    fi

    # Extract just the ## {stable_version} section body from the full git-cliff output
    local escaped_version
    escaped_version=$(echo "$stable_version" | sed 's/\./\\./g')

    local new_section_file
    new_section_file=$(mktemp -t "section-XXXXXX")

    # Write the header with (unreleased) marker
    echo "## ${stable_version} (unreleased)" > "$new_section_file"

    # Append the body lines (between the ## heading and the next ## heading)
    awk "/^## (\[)?v?${escaped_version}(\])?( -|$)/ {found=1; next} \
         found && /^## / {exit} \
         found {print}" \
        "$temp_cliff_out" >> "$new_section_file"

    rm -f "$temp_cliff_out"

    # Validate we got at least one content line beyond the header
    if [[ $(wc -l < "$new_section_file") -le 1 ]]; then
        warn "No content extracted for ## ${stable_version}, skipping CHANGELOG.md update"
        rm -f "$new_section_file"
        return 0
    fi

    # Splice into CHANGELOG.md:
    #   - If a ## {stable_version} (unreleased) section already exists, replace it.
    #   - Otherwise, insert the new section before the first ## heading.
    local changelog="CHANGELOG.md"

    if [[ ! -f "$changelog" ]]; then
        { echo "# Changelog"; echo ""; cat "$new_section_file"; } > "$changelog"
        rm -f "$new_section_file"
        info "✓ Created CHANGELOG.md with ## ${stable_version} (unreleased) section"
        return 0
    fi

    local temp_out
    temp_out=$(mktemp -t "changelog-out-XXXXXX")

    # Use awk to replace or insert the section.
    # index() for the match avoids regex dot-as-wildcard issues with version numbers.
    awk -v stable_ver="${stable_version}" -v sf="${new_section_file}" '
        BEGIN {
            inserted = 0; skip = 0
            # Load new section content
            while ((getline ln < sf) > 0) new_sec = new_sec ln "\n"
            close(sf)
        }
        # Skip existing (unreleased) section for this exact version
        index($0, "## " stable_ver " (unreleased)") == 1 { skip = 1; next }
        skip && /^## / { skip = 0 }
        skip { next }
        # Insert before the first ## heading
        /^## / && !inserted { printf "%s\n", new_sec; inserted = 1 }
        { print }
    ' "$changelog" > "$temp_out"

    mv "$temp_out" "$changelog"
    rm -f "$new_section_file"

    info "✓ Updated CHANGELOG.md with ## ${stable_version} (unreleased) section"
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

        if [[ $version_exit -ne 0 ]]; then
            fatal "Failed to calculate version from version.sh"
        fi

        if [[ -z "$version" ]]; then
            # version.sh exits 0 with no output when there's nothing new to release.
            info "No releasable commits since the last release — nothing to do"
            exit 0
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

    # Always reset PR branch to the current tip of base branch.
    # The PR branch is fully managed by this script — its only extra commit is
    # the changelog update. Resetting ensures new commits on the base branch are
    # picked up when the changelog is regenerated on each run.
    info "Resetting PR branch to base: $pr_branch → $base_branch"
    git checkout -B "$pr_branch" "$base_branch"

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

    # For prerelease versions, maintain CHANGELOG.md with a cumulative (unreleased)
    # section. promote.sh will later open a PR replacing "(unreleased)" with the date.
    if is_prerelease "$version"; then
        if command -v git-cliff &>/dev/null; then
            update_unreleased_stable_changelog "$(base_version "$version")"
        else
            warn "git-cliff not found, skipping CHANGELOG.md unreleased section update"
        fi
    fi

    # Stage changelog changes (no manifest file to stage)
    git add CHANGELOG*.md 2>/dev/null || warn "No changelog files to add"

    # Check if there are changes to commit
    if git diff --cached --quiet; then
        # No changelog changes after reset means the CHANGELOG on base already
        # matches what we'd generate — the release PR was merged but not tagged yet.
        fatal "Release v${version} is already merged into ${base_branch} but has no tag yet.
  Run 'make release-publish' to create the tag and GitHub release, then
  run 'make release-pr' again for the next version."
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

        if [[ "$branch_exists" == "true" ]]; then
            # Force push: the PR branch is fully managed by this script and is
            # always regenerated from the base branch, so its history is always
            # rewritten. No human commits should ever land directly on this branch,
            # making --force safe and --force-with-lease unreliable (stale info).
            retry_git push --force origin "$pr_branch" || fatal "Force push failed"
        else
            retry_git push origin "$pr_branch" || fatal "Push failed"
        fi

        info "Branch pushed successfully"

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
