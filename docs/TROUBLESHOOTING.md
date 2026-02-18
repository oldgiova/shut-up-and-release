# Troubleshooting Guide

Common issues and their solutions when using the release management system.

## Table of Contents

- [Environment Issues](#environment-issues)
- [Git and Tag Issues](#git-and-tag-issues)
- [Version Calculation Issues](#version-calculation-issues)
- [Changelog Generation Issues](#changelog-generation-issues)
- [PR Creation Issues](#pr-creation-issues)
- [Promotion Issues](#promotion-issues)
- [GitHub Release Issues](#github-release-issues)
- [Configuration Issues](#configuration-issues)

---

## Environment Issues

### "GITHUB_TOKEN not set" or authentication failures

**Symptom**: Scripts fail with authentication errors or warnings about missing token.

**Solution**:
```bash
# Export your GitHub personal access token
export GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxx"

# Verify it's set
echo $GITHUB_TOKEN | head -c 10  # Should show: ghp_xxxxxx
```

**Getting a token**:
1. Go to https://github.com/settings/tokens
2. Click "Generate new token (classic)"
3. Required scopes: `repo` (full repository access)
4. Copy token immediately (you won't see it again)
5. Store securely (e.g., password manager)

**For CI/CD**:
```yaml
# GitLab CI
variables:
  GITHUB_TOKEN: ${GITHUB_CLI_TOKEN}  # Use CI variable

# GitHub Actions
env:
  GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### "Required command not found" errors

**Symptom**: Script fails with message like "Required command not found: jq"

**Missing Dependencies**:
```bash
# Check what's missing
command -v git jq gh git-cliff

# Install missing tools:

# jq (JSON processor)
sudo apt install jq              # Debian/Ubuntu
brew install jq                  # macOS

# gh (GitHub CLI)
# See: https://github.com/cli/cli#installation

# git-cliff (changelog generator)
cargo install git-cliff          # Via Rust
# Or download binary from: https://github.com/orhun/git-cliff/releases
```

### Rate limit errors from GitHub API

**Symptom**: "API rate limit exceeded" errors when generating changelogs.

**Solution 1 - Use authenticated requests**:
```bash
# Authenticated requests get 5000/hour vs 60/hour
export GITHUB_TOKEN="ghp_..."
```

**Solution 2 - Use local git mode**:
```bash
# Bypasses GitHub API entirely (no PR links, but fast)
./.gitlab/release/changelog.sh 4.2.0 --local-git
```

**Check your rate limit**:
```bash
curl -H "Authorization: token $GITHUB_TOKEN" \
  https://api.github.com/rate_limit | jq .
```

---

## Git and Tag Issues

### "Tag does not exist" errors

**Symptom**: `promote.sh` or `release.sh` fails saying tag doesn't exist.

**Diagnosis**:
```bash
# List all tags
git tag -l

# List tags matching pattern
git tag -l "v4.1.*"

# Check if specific tag exists locally
git rev-parse v4.1.0-rc.1
```

**Solutions**:

**If tag exists remotely but not locally (worktrees)**:
```bash
# Fetch all tags from remote
git fetch --tags origin

# For specific tag
git fetch origin tag v4.1.0-rc.1
```

**If tag doesn't exist at all**:
```bash
# Create missing RC tag manually (emergency only)
git tag v4.1.0-rc.1 <commit-sha>
git push origin v4.1.0-rc.1

# Then use promote.sh
make release-promote RC_TAG=v4.1.0-rc.1
```

### "Working tree is not clean" errors

**Symptom**: `pr.sh` refuses to run with uncommitted changes.

**Solution**:
```bash
# Check what's uncommitted
git status

# Option 1: Commit changes
git add .
git commit -m "WIP: changes before release"

# Option 2: Stash changes temporarily
git stash
make release-pr
git stash pop

# Option 3: Discard changes (careful!)
git restore .
```

### Permission denied when pushing branches

**Symptom**: Failed to push release branch to origin.

**Solutions**:
```bash
# 1. Check GitHub authentication
gh auth status

# 2. Re-authenticate if needed
gh auth login

# 3. Verify you have write access to repository
gh repo view --json permissions

# 4. For worktrees, ensure origin is correct
git remote -v
```

---

## Version Calculation Issues

### "No commits found since last tag" warnings

**Symptom**: Version calculation shows no commits, defaults to patch bump.

**Diagnosis**:
```bash
# Check what git-cliff sees
./.gitlab/release/version.sh --dry-run --preview

# Verify commits exist
git log --oneline $(git describe --tags --abbrev=0)..HEAD
```

**Cause**: Usually means you're on the same commit as the last tag.

**Solution**:
- Add some commits with conventional format
- Or use manual override: `RELEASE_AS=4.1.1 make release-pr`

### Version calculation picks wrong bump type

**Symptom**: Expected minor bump (feat), got patch bump (fix).

**Diagnosis**:
```bash
# Show commit analysis
./.gitlab/release/version.sh --dry-run --preview

# Check commit messages
git log --oneline --since="1 week ago"
```

**Common Causes**:
1. Commits don't follow conventional format
   - Wrong: `added new feature`
   - Right: `feat: added new feature`

2. Typos in conventional commit prefix
   - Wrong: `feature: something`
   - Right: `feat: something`

3. Commits missing since last tag
   ```bash
   # Verify reference point
   git describe --tags --abbrev=0
   ```

**Solution**: Fix commit messages or use manual override.

### Maintenance branch picks wrong version range

**Symptom**: On branch `4.1.x` but version calculation includes `4.2.x` commits.

**Diagnosis**:
```bash
# Check what tags are being considered
git tag -l "v4.1.*"
git tag -l "v4.2.*"

# Check current branch
git rev-parse --abbrev-ref HEAD
```

**Solution**: Ensure branch name matches pattern `X.Y.x` (e.g., `4.1.x` not `4.1-maintenance`).

---

## Changelog Generation Issues

### Empty or incomplete changelog

**Symptom**: Generated changelog missing commits or sections.

**Diagnosis**:
```bash
# Preview what will be generated
./.gitlab/release/changelog.sh 4.2.0 --preview

# Check git-cliff config
cat .gitlab/cliff.toml
```

**Common Causes**:
1. **git-cliff config excludes certain commit types**
   - Check `commit_parsers` in `.gitlab/cliff.toml`

2. **Commits don't match conventional format**
   ```bash
   # Check recent commits
   git log --oneline -20
   ```

3. **Wrong tag range**
   ```bash
   # Manual test
   git-cliff --config .gitlab/cliff.toml --tag v4.2.0
   ```

### Changelog contains duplicates

**Symptom**: Same changes appear multiple times in changelog.

**Cause**: Usually happens when cherry-picking commits between branches.

**Solution**:
- Use `git-cliff`'s deduplication (should be automatic)
- Manually edit changelog before PR merge
- Consider using `--skip-commit` in git-cliff config for specific commits

### GitHub API mode fails but local git mode works

**Symptom**: `--local-git` works but normal mode fails.

**Diagnosis**:
```bash
# Test GitHub API access
gh api repos/{owner}/{repo} | jq .

# Check rate limits
gh api rate_limit | jq .
```

**Solutions**:
1. Verify GITHUB_TOKEN is set and valid
2. Check repository name is correct: `export GITHUB_REPO_URL="owner/repo"`
3. Use `--local-git` mode if API is unavailable

---

## PR Creation Issues

### PR branch already exists

**Symptom**: Script warns "PR branch already exists remotely".

**This is normal!** The script handles this automatically and updates the existing PR.

**Manual cleanup** (if needed):
```bash
# List release PR branches
git branch -r | grep release-please

# Delete old PR branch
git push origin --delete release-please--branches--main

# Locally
git branch -D release-please--branches--main
```

### PR creation fails with "No commits between base and head"

**Symptom**: `gh pr create` fails saying no commits to PR.

**Cause**: Version and changelog already match what's in base branch.

**Diagnosis**:
```bash
# Check manifest version
jq . .release-please-manifest.json

# Check if files changed
git diff HEAD..origin/main -- .release-please-manifest.json CHANGELOG*.md
```

**Solution**: This is idempotency working correctly. No PR needed if nothing changed.

### PR body is empty or generic

**Symptom**: Created PR has minimal description instead of changelog excerpt.

**Cause**: Changelog extraction failed.

**Workaround**:
```bash
# Generate PR body manually
./.gitlab/release/changelog.sh 4.2.0 --pr-body /tmp/pr-body.md

# Create PR with custom body
./.gitlab/release/pr.sh 4.2.0 --body /tmp/pr-body.md
```

---

## Promotion Issues

### "RC tag does not exist" when promoting

**Symptom**: `promote.sh` fails validation before creating PR.

**Solution**: See [Tag does not exist](#tag-does-not-exist-errors) above.

### "Stable tag already exists" when promoting

**Symptom**: `promote.sh` refuses to create promotion PR because `v4.1.0` already exists.

**Diagnosis**:
```bash
# Check if stable tag exists
git rev-parse v4.1.0

# Was it created manually?
git show v4.1.0
```

**Solutions**:
1. **If tag is correct**: Release is already done, no promotion needed
2. **If tag is incorrect**: Delete and recreate (dangerous!)
   ```bash
   # Backup first!
   git tag v4.1.0-backup v4.1.0

   # Delete wrong tag
   git tag -d v4.1.0
   git push origin :refs/tags/v4.1.0

   # Promote RC
   make release-promote RC_TAG=v4.1.0-rc.2
   ```

### Promotion changelog is incomplete

**Symptom**: Promotion PR changelog doesn't include all RC changes.

**Cause**: Changelog range calculation issue.

**Workaround**:
```bash
# Check what range promote.sh is using
# It should find last stable tag and generate from there to RC

# Manually check range
git log --oneline $(git tag -l 'v*' --sort=-version:refname | grep -v -E '(rc|saas)' | head -1)..v4.1.0-rc.2

# If incorrect, report bug and manually edit changelog in PR
```

### Not on maintenance branch error

**Symptom**: `promote.sh` fails: "Must be on maintenance branch (X.Y.x)".

**Cause**: You're on `main` or differently-named branch.

**Solution**:
```bash
# Check current branch
git rev-parse --abbrev-ref HEAD

# Checkout correct branch
git checkout 4.1.x

# Then promote
make release-promote RC_TAG=v4.1.0-rc.2
```

---

## GitHub Release Issues

### Release already exists warning

**Symptom**: `release.sh` says "Release already exists, updating...".

**This is normal!** The script is idempotent and updates existing releases.

**To force new release**:
```bash
# Delete old release first
gh release delete v4.1.0 --yes

# Create new one
make release-github TAG=v4.1.0
```

### Release notes don't match changelog

**Symptom**: GitHub release description differs from CHANGELOG.md.

**Cause**: Changelog extraction regex failed or changelog format changed.

**Workaround**:
```bash
# Create custom release notes
cat > /tmp/notes.md << 'EOF'
## What's Changed
- Fix critical bug in auth
- Add new feature X
EOF

# Create release with custom notes
./.gitlab/release/release.sh v4.1.0 --notes /tmp/notes.md
```

### Prerelease flag not set correctly

**Symptom**: RC release shows as "latest" instead of "prerelease".

**Diagnosis**:
```bash
# Check tag format
echo "v4.1.0-rc.1" | grep -E '(rc|saas)'
# Should match for prerelease

# Check release flags
gh release view v4.1.0-rc.1 --json isPrerelease
```

**Solution**:
```bash
# Force prerelease flag
./.gitlab/release/release.sh v4.1.0-rc.1 --prerelease

# Or edit existing release
gh release edit v4.1.0-rc.1 --prerelease
```

---

## Configuration Issues

### Wrong prerelease type in config

**Symptom**: Creating RC on branch configured for "saas" or vice versa.

**Check configuration**:
```bash
# Show current config
jq . release-please-config.json

# Check prerelease type
jq -r '."prerelease-type"' release-please-config.json
```

**Fix**:
```json
{
  "prerelease": true,
  "prerelease-type": "rc"    // Change to "rc" or "saas" as needed
}
```

### Manifest version out of sync with tags

**Symptom**: Manifest says `4.1.0` but latest tag is `v4.2.0`.

**Diagnosis**:
```bash
# Check manifest
jq . .release-please-manifest.json

# Check latest tag
git describe --tags --abbrev=0
```

**Solution**:
```bash
# Update manifest to match reality
jq '.".".= "4.2.0"' .release-please-manifest.json > tmp.json
mv tmp.json .release-please-manifest.json

# Commit the fix
git add .release-please-manifest.json
git commit -m "fix: sync manifest with latest tag"
```

### Config file not found errors

**Symptom**: "Config file not found: release-please-config.json"

**Check**:
```bash
# Verify files exist in repo root
ls -la .release-please-manifest.json release-please-config.json
```

**Solution**:
```bash
# If missing, create from template
cat > release-please-config.json << 'EOF'
{
  "prerelease": false,
  "packages": {
    ".": {
      "changelog-path": "CHANGELOG.md"
    }
  }
}
EOF

cat > .release-please-manifest.json << 'EOF'
{
  ".": "1.0.0"
}
EOF
```

---

## General Debugging Tips

### Enable verbose mode

```bash
# Run scripts with bash debugging
bash -x ./.gitlab/release/version.sh --dry-run

# Or add to script temporarily
set -x  # Enable debugging
set +x  # Disable debugging
```

### Test in isolation

```bash
# Test individual components

# 1. Version calculation only
./.gitlab/release/version.sh --dry-run --preview

# 2. Changelog generation only (local, fast)
./.gitlab/release/changelog.sh 4.2.0 --preview

# 3. PR creation without push
./.gitlab/release/pr.sh 4.2.0 --no-push
```

### Check script dependencies

```bash
# Verify all required tools are available
for cmd in git jq gh git-cliff; do
  if command -v $cmd &>/dev/null; then
    echo "✓ $cmd: $(command -v $cmd)"
  else
    echo "✗ $cmd: NOT FOUND"
  fi
done
```

### Dry-run everything first

Always use dry-run modes before making changes:

```bash
# Safe preview of all operations
make release-status                    # Check current state
make release-version-show              # See next version
./.gitlab/release/changelog.sh 4.2.0 --preview  # Preview changelog
./.gitlab/release/pr.sh 4.2.0 --no-push        # Test PR creation
```

---

## Getting Help

If you're still stuck:

1. **Check the FAQ**: [docs/FAQ.md](FAQ.md)
2. **Review common gotchas**: [docs/COMMON_GOTCHAS.md](COMMON_GOTCHAS.md)
3. **Read script help**: All scripts have `--help` flags
4. **Check script documentation**: [.gitlab/release/README.md](../.gitlab/release/README.md)

**For CI/CD issues**:
- Check GitLab CI logs: Pipeline → Job → Full log
- Verify CI environment variables are set
- Test scripts locally first before debugging in CI

**Report bugs**:
- Provide: command run, error message, git status, config files
- Include: script output with `-x` debugging enabled
- Sanitize: Remove tokens, internal repo names
