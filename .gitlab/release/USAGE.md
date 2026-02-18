# Release Scripts Usage Guide

All scripts are now implemented and ready to use!

## Prerequisites

```bash
# Set GitHub token for API access
export GITHUB_TOKEN="ghp_your_token_here"

# Set repository URL (optional, auto-detected)
export GITHUB_REPO_URL="mendersoftware/mender-server"
```

## Complete Workflow Examples

### Example 1: Direct Stable Release (Open Source)

```bash
# 1. Check current status
cd /path/to/repo
./.gitlab/release/version.sh --dry-run --preview

# 2. Preview what will be released
./.gitlab/release/changelog.sh 4.2.0 --preview

# 3. Create release PR
./.gitlab/release/pr.sh 4.2.0

# 4. (After PR is merged and tag v4.2.0 is created)
# Create GitHub release
./.gitlab/release/release.sh v4.2.0
```

### Example 2: RC Testing → Promotion (Enterprise)

```bash
# Phase 1: Create RC
# ==================

# 1. Calculate next version
./.gitlab/release/version.sh --dry-run --preview

# 2. Create RC release PR
./.gitlab/release/pr.sh 4.1.0-rc.1

# 3. (After merge) Tag v4.1.0-rc.1 is created
# Create GitHub prerelease
./.gitlab/release/release.sh v4.1.0-rc.1  # Auto-detects prerelease

# 4. Test in QA... bugs found, fix them

# 5. Create next RC
./.gitlab/release/pr.sh 4.1.0-rc.2

# 6. (After merge) Tag v4.1.0-rc.2 is created
./.gitlab/release/release.sh v4.1.0-rc.2

# 7. QA approves ✅

# Phase 2: Promote to Stable
# ===========================

# 8. Promote RC to stable
./.gitlab/release/promote.sh v4.1.0-rc.2

# This will:
# - Validate v4.1.0-rc.2 exists
# - Create PR for v4.1.0 (stable)
# - Generate full changelog from last stable to RC

# 9. (After PR merge) Tag v4.1.0 is created
# Create GitHub stable release
./.gitlab/release/release.sh v4.1.0
```

## Individual Script Usage

### version.sh - Calculate Next Version

```bash
# Dry-run with details
./version.sh --dry-run --preview

# Force prerelease mode
./version.sh --prerelease --dry-run

# Force stable mode
./version.sh --no-prerelease --dry-run

# Manual override (emergency)
RELEASE_AS=4.1.0-rc.5 ./version.sh --dry-run
```

### changelog.sh - Generate Changelog

```bash
# Preview (local git only, no token needed)
./changelog.sh 4.2.0 --preview

# Generate with GitHub API (requires GITHUB_TOKEN)
export GITHUB_TOKEN="ghp_..."
./changelog.sh 4.2.0

# Generate with local git (no PR links, no token)
./changelog.sh 4.2.0 --local-git

# Generate with PR body for PR description
./changelog.sh 4.2.0 --pr-body /tmp/pr-body.md

# Custom suffix
./changelog.sh 4.1.0 --suffix -enterprise
```

### pr.sh - Create Release PR

```bash
# Create release PR
./pr.sh 4.2.0

# With custom title
./pr.sh 4.1.0 --title "chore: release 4.1.0 (hotfix)"

# Test mode (no push)
./pr.sh 4.2.0 --no-push
```

### promote.sh - Promote RC to Stable

```bash
# Promote RC to stable (requires GITHUB_TOKEN)
export GITHUB_TOKEN="ghp_..."
./promote.sh v4.1.0-rc.2

# Test mode (no push)
./promote.sh v4.1.0-rc.2 --no-push

# Works with or without 'v' prefix
./promote.sh 4.1.0-rc.2
```

### release.sh - Create GitHub Release

```bash
# Create stable release (requires GITHUB_TOKEN)
export GITHUB_TOKEN="ghp_..."
./release.sh v4.2.0

# Create RC release (auto-detects prerelease)
./release.sh v4.1.0-rc.1

# Create as draft
./release.sh v4.2.0 --draft

# Force prerelease flag
./release.sh v4.2.0 --prerelease

# Custom release notes
./release.sh v4.1.0 --notes /tmp/custom-notes.md

# Custom title
./release.sh v4.1.0 --title "Release 4.1.0 - Major Update"
```

## Testing Scenarios

### Test Scenario 1: Preview Without Changes

```bash
# Safe to run anytime - no changes made
./version.sh --dry-run --preview
./changelog.sh 4.2.0 --preview
```

### Test Scenario 2: Test PR Creation Without Push

```bash
# Creates local branch and commits but doesn't push
./pr.sh 4.2.0 --no-push

# Check the changes
git log -1
git show HEAD

# Cleanup if needed
git reset --hard origin/$(git rev-parse --abbrev-ref HEAD)
git branch -D release-please--branches--*
```

### Test Scenario 3: Full RC → Stable Workflow (Dry-Run)

```bash
# 1. Create RC PR (test mode)
./pr.sh 4.1.0-rc.1 --no-push

# 2. Simulate promotion (test mode)
# (First, you'd need an actual RC tag to exist)
git tag v4.1.0-rc.1
./promote.sh v4.1.0-rc.1 --no-push

# Cleanup
git tag -d v4.1.0-rc.1
```

## Troubleshooting

### "GITHUB_TOKEN not set" warning

```bash
# Set your GitHub token
export GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxx"

# Get token from: https://github.com/settings/tokens
# Permissions needed: repo (read access)
```

### "Tag does not exist" error

```bash
# Check available tags
git tag -l

# For worktrees, you may need to fetch tags
git fetch --tags
```

### "Working tree is not clean" error

```bash
# Check status
git status

# Commit or stash your changes
git stash
# or
git commit -am "WIP"
```

### Rate limit errors from GitHub API

```bash
# Check your rate limit status
curl -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/rate_limit

# Use --local-git mode to avoid API calls
./changelog.sh 4.2.0 --local-git
```

## Environment Variables

| Variable | Required | Purpose | Example |
|----------|----------|---------|---------|
| `GITHUB_TOKEN` | For PR/release creation | GitHub API authentication | `ghp_abc123...` |
| `GITHUB_REPO_URL` | Optional | Repository identifier | `mendersoftware/mender-server` |
| `RELEASE_AS` | Optional | Manual version override | `4.1.0-rc.5` |

## Script Dependencies

All scripts require:
- `git` - Version control operations
- `jq` - JSON parsing for manifest/config
- `gh` - GitHub CLI for PR/release management (requires GITHUB_TOKEN)
- `git-cliff` - Changelog generation (used by `generate_changelog.sh`)

Check dependencies:
```bash
command -v git jq gh git-cliff
```

## Getting Help

Each script has built-in help:
```bash
./version.sh --help
./changelog.sh --help
./pr.sh --help
./promote.sh --help
./release.sh --help
```
