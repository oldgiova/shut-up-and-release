# Common Gotchas

Things to watch out for when using the release management system.

## Table of Contents

- [Version Numbering](#version-numbering)
- [Git and Tags](#git-and-tags)
- [Conventional Commits](#conventional-commits)
- [Changelog Generation](#changelog-generation)
- [PR Management](#pr-management)
- [Branch Configuration](#branch-configuration)
- [Promotion Workflow](#promotion-workflow)
- [CI/CD Integration](#cicd-integration)

---

## Version Numbering

### Gotcha: New maintenance branch starts with wrong version

**Problem**: You create branch `4.1.x` from `main` which is at `4.2.0`, and releases start at `4.2.1` instead of `4.1.0`.

**Why**: The manifest file was copied from `main` without updating.

**Fix**:
```bash
# After creating 4.1.x branch:
# 1. Update manifest to correct base version
jq '.".".= "4.1.0"' .release-please-manifest.json > tmp.json
mv tmp.json .release-please-manifest.json

# 2. Commit
git add .release-please-manifest.json
git commit -m "chore: set base version for 4.1.x branch"
```

**Rule of thumb**:
- **First release on X.Y.x branch**: Set manifest to `X.Y.0`
- **Patch releases**: Manifest matches last stable (e.g., `4.1.0` → next will be `4.1.1`)

### Gotcha: RC numbers reset unexpectedly

**Problem**: You have `v4.1.0-rc.2` and next release becomes `v4.2.0-rc.1` instead of `v4.1.0-rc.3`.

**Why**: A `feat:` commit caused a minor version bump.

**Expected behavior**: Version bumps apply to base version even in RC mode:
- `fix:` on `4.1.0-rc.2` → `4.1.1-rc.1` (patch bump)
- `feat:` on `4.1.0-rc.2` → `4.2.0-rc.1` (minor bump)

**Workarounds**:
1. **Don't add features during RC cycle** - only bug fixes
2. **Or**: Use manual override: `RELEASE_AS=4.1.0-rc.3 make release-pr`

### Gotcha: Version skips numbers after promotion

**Problem**: After promoting `v4.1.0-rc.2` to `v4.1.0`, next release jumps to `v4.1.2`.

**Why**: Manifest still shows `4.1.0-rc.2` and script increments from there.

**Prevention**: The promotion script should update manifest to stable version (`4.1.0`). If it doesn't, do manually:

```bash
# After promotion, verify manifest
jq . .release-please-manifest.json
# Should show: {"." : "4.1.0"}

# If it shows 4.1.0-rc.2, fix it:
jq '.".".= "4.1.0"' .release-please-manifest.json > tmp.json
mv tmp.json .release-please-manifest.json
git add .release-please-manifest.json
git commit -m "chore: update manifest after promotion"
```

---

## Git and Tags

### Gotcha: Tags exist remotely but not in worktree

**Problem**: `promote.sh` or `release.sh` fails saying tag doesn't exist, but you can see it on GitHub.

**Why**: Git worktrees don't automatically sync tags.

**Fix**:
```bash
# Fetch all tags
git fetch --tags origin

# For specific tag
git fetch origin tag v4.1.0-rc.2

# Verify
git tag -l "v4.1.0*"
```

**Prevention**: Add to your workflow:
```bash
# Before any release operation
git fetch --tags origin
make release-status
```

### Gotcha: Tag points to wrong commit after rebase

**Problem**: You created tag `v4.1.0-rc.1`, then rebased branch, and now tag points to orphaned commit.

**Why**: Tags point to specific commit SHA, not branch HEAD.

**Fix** (if tag not pushed yet):
```bash
# Move tag to current HEAD
git tag -f v4.1.0-rc.1
git push -f origin v4.1.0-rc.1
```

**Prevention**: **Don't rebase after tagging!** Tags are permanent. If you need to fix commits, create a new RC:
```bash
# Instead of rebasing v4.1.0-rc.1, create:
make release-pr  # → v4.1.0-rc.2
```

### Gotcha: Deleted tag still exists remotely

**Problem**: You deleted tag locally but it still shows on GitHub and in CI.

**Why**: Local delete doesn't affect remote.

**Fix**:
```bash
# Delete remotely (CAREFUL!)
git push origin :refs/tags/v4.1.0-rc.1

# Or using GitHub CLI
gh release delete v4.1.0-rc.1 --yes  # Deletes release + tag
```

**Prevention**: Think twice before deleting tags. They're meant to be permanent.

---

## Conventional Commits

### Gotcha: Version bump smaller than expected

**Problem**: You wrote a new feature but got patch bump (4.1.0 → 4.1.1) instead of minor bump.

**Why**: Commit message doesn't follow conventional format.

**Common mistakes**:

| ❌ Wrong | ✅ Right | Bump |
|---------|---------|------|
| `added new auth` | `feat: add new auth` | minor |
| `fix bug in parser` | `fix: parser bug` | patch |
| `BREAKING: new API` | `feat!: new API` or footer | major |
| `feature: new API` | `feat: new API` | minor |
| `bugfix: crash` | `fix: crash` | patch |

**Check what git-cliff sees**:
```bash
./.gitlab/release/version.sh --dry-run --preview
```

**Fix old commits**:
```bash
# If commits not pushed yet
git rebase -i HEAD~3
# Change commit messages

# If commits pushed, live with it or use override
RELEASE_AS=4.2.0 make release-pr
```

### Gotcha: Breaking change not detected

**Problem**: You made a breaking change but version didn't bump to major.

**Why**: git-cliff looks for specific patterns:

**These DON'T work**:
```
feat: breaking change to API
fix: BREAKING change
```

**These DO work**:
```
feat!: change API signature

fix!: remove deprecated method

feat: add new API

BREAKING CHANGE: This removes the old API
```

**Format**: Either `!` after type or `BREAKING CHANGE:` footer.

### Gotcha: Non-conventional commits pollute changelog

**Problem**: Changelog includes commits like "wip", "fixup", "temp".

**Why**: git-cliff includes all commits unless filtered.

**Fix**: Configure `.gitlab/cliff.toml`:
```toml
[git]
# Skip commits matching these patterns
commit_parsers = [
  { message = "^wip", skip = true },
  { message = "^fixup", skip = true },
  { message = "^temp", skip = true },
  { message = "^chore\\(release\\)", skip = true },
]
```

**Prevention**: Use proper conventional commits always, or squash before merging.

---

## Changelog Generation

### Gotcha: Changelog has duplicate entries

**Problem**: Same PR/commit appears twice in changelog.

**Why**: Usually from cherry-picking between branches (e.g., backport to maintenance branch).

**Fix**: Manually edit CHANGELOG before merging PR, or configure git-cliff deduplication.

### Gotcha: Changelog missing recent commits

**Problem**: You just merged a fix but it's not in generated changelog.

**Why**: git-cliff generates from last tag to HEAD. If you're on the wrong commit, it misses recent changes.

**Check**:
```bash
# What commits will be included?
git log $(git describe --tags --abbrev=0)..HEAD --oneline

# Preview changelog
./.gitlab/release/changelog.sh 4.2.0 --preview
```

**Fix**: Ensure you're on the right branch and have latest commits:
```bash
git checkout main
git pull origin main
make release-pr
```

### Gotcha: PR links broken in changelog

**Problem**: Changelog shows `[#123]` but link is wrong or missing.

**Why**: `GITHUB_REPO_URL` environment variable is wrong or not set.

**Fix**:
```bash
# Set correct repo URL
export GITHUB_REPO_URL="mendersoftware/mender-server"

# Regenerate changelog
./.gitlab/release/changelog.sh 4.2.0
```

### Gotcha: Changelog generates slowly or times out

**Problem**: Changelog generation takes minutes or fails with timeout.

**Why**: GitHub API rate limiting or network issues.

**Solutions**:

1. **Use authenticated requests** (5000 req/hour):
   ```bash
   export GITHUB_TOKEN="ghp_..."
   ```

2. **Use local-git mode** (no API calls):
   ```bash
   ./.gitlab/release/changelog.sh 4.2.0 --local-git
   ```

3. **Check rate limit**:
   ```bash
   curl -H "Authorization: token $GITHUB_TOKEN" \
     https://api.github.com/rate_limit | jq .
   ```

---

## PR Management

### Gotcha: PR branch exists from previous release

**Problem**: Running `make release-pr` shows "PR branch already exists".

**Is this bad?** **No!** This is normal and handled automatically. The script updates the existing PR.

**When to worry**: If you want a fresh PR, delete the old branch first:
```bash
# Delete old PR branch
git push origin --delete release-please--branches--main
git branch -D release-please--branches--main

# Then create new PR
make release-pr
```

### Gotcha: PR has no changes after re-running script

**Problem**: You run `make release-pr` again but PR shows "No changes" or no new commits.

**Why**: This is idempotency! The script detected version/changelog already match target state.

**This is good**: It means PR is already correct. No action needed.

### Gotcha: PR merge doesn't create tag

**Problem**: You merged release PR but no tag was created.

**Why**: Tag creation is usually done by CI webhook/pipeline, not the merge itself.

**Check**:
1. **CI pipeline running?** Check GitLab/GitHub Actions
2. **CI configured to create tags?** See `.gitlab-ci.yml` or workflow file
3. **Permissions?** CI needs write access to create tags

**Manual workaround**:
```bash
# Create tag manually (emergency only)
git checkout main
git pull origin main
git tag v4.2.0
git push origin v4.2.0
```

### Gotcha: Multiple release PRs open for same branch

**Problem**: Two PRs both claiming to be release PRs.

**Why**: PR branch naming conflict or manual PR creation alongside automated PR.

**Fix**: Close one PR, delete its branch:
```bash
# Close PR #456 (via GitHub UI or CLI)
gh pr close 456

# Delete its branch
git push origin --delete release-please--branches--main-old
```

**Prevention**: Use only `make release-pr`, don't create release PRs manually.

---

## Branch Configuration

### Gotcha: Wrong changelog file used

**Problem**: Creating RC on `4.1.x` branch but it updates `CHANGELOG.md` instead of `CHANGELOG-enterprise.md`.

**Why**: Branch config not updated after branching from main.

**Fix**:
```json
// release-please-config.json
{
  "prerelease": true,
  "prerelease-type": "rc",
  "packages": {
    ".": {
      "changelog-path": "CHANGELOG-enterprise.md"  // ← Add this
    }
  }
}
```

### Gotcha: Branch creates stable release when expecting RC

**Problem**: On maintenance branch `4.1.x` but `make release-pr` creates `v4.1.0` instead of `v4.1.0-rc.1`.

**Why**: Config has `prerelease: false`.

**Fix**:
```json
// release-please-config.json
{
  "prerelease": true,           // ← Must be true
  "prerelease-type": "rc"       // ← Must be rc
}
```

### Gotcha: Enterprise and open source configs clash

**Problem**: Enterprise repo forked from open source, now release configs conflict.

**Why**: Open source has `prerelease: false`, enterprise needs `prerelease: true`.

**Fix**: Maintain separate configs per branch:

```bash
# Open source main branch
git checkout main
# Config: prerelease=false

# Enterprise main branch (for SaaS)
git checkout enterprise-main
# Config: prerelease=true, type=saas

# Enterprise maintenance branch
git checkout 4.1.x
# Config: prerelease=true, type=rc
```

**Each branch has its own config!**

---

## Promotion Workflow

### Gotcha: Promotion creates PR (not direct tag)

**Problem**: Expected `make release-promote` to immediately create `v4.1.0` tag, but it created a PR instead.

**Why**: This is the **correct behavior**! Promotion creates a PR for review.

**The flow is**:
```bash
make release-promote RC_TAG=v4.1.0-rc.2
# → Creates PR for v4.1.0
# You review and merge PR
# → Tag v4.1.0 created by CI
```

**Why PR not direct push?**: Safety, review, CI tests.

**Note**: The CLAUDE.md file incorrectly claimed "NO PR!" for this workflow. That's been corrected.

### Gotcha: Promotion changelog incomplete

**Problem**: Promoted changelog missing changes from earlier RCs.

**Why**: Changelog generation range is from "last stable" to "promoted RC". If last stable is old, should include all RCs.

**Check**:
```bash
# What range will be used?
# Last stable:
git tag -l 'v*' --sort=-version:refname | grep -v -E '(rc|saas)' | head -1

# To promoted RC:
v4.1.0-rc.2

# All commits in range:
git log <last-stable>..v4.1.0-rc.2 --oneline
```

**Fix**: If range is wrong, manually edit changelog in promotion PR before merging.

### Gotcha: Can't find RC tag to promote

**Problem**: `make release-promote RC_TAG=v4.1.0-rc.2` fails, tag not found.

**Why**: Tag exists remotely but not locally (worktree issue).

**Fix**:
```bash
# Fetch tags first
git fetch --tags origin

# Verify tag exists
git tag -l "v4.1.0-rc.*"

# Then promote
make release-promote RC_TAG=v4.1.0-rc.2
```

### Gotcha: Promoted version doesn't match RC base

**Problem**: Promoting `v4.1.0-rc.2` creates `v4.2.0` instead of `v4.1.0`.

**Why**: Manifest has wrong version, or manual override was used.

**Check**:
```bash
# Check manifest
jq . .release-please-manifest.json

# Should show 4.1.0-rc.2 or similar
```

**Prevention**: Don't manually edit manifest during RC cycle.

---

## CI/CD Integration

### Gotcha: CI fails with "GITHUB_TOKEN not set"

**Problem**: Local scripts work but CI fails with missing token.

**Why**: Environment variable not configured in CI.

**Fix**:

**GitLab CI**:
```yaml
variables:
  GITHUB_TOKEN: ${GITHUB_CLI_TOKEN}  # Use protected CI variable
```

**GitHub Actions**:
```yaml
env:
  GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

**Set CI variable**:
- GitLab: Settings → CI/CD → Variables
- GitHub: Settings → Secrets → Actions

### Gotcha: CI creates tags on every commit

**Problem**: Every commit to main triggers tag creation.

**Why**: CI trigger rules too broad.

**Fix**: Restrict release jobs to protected branches + manual trigger:

```yaml
# GitLab
release:
  rules:
    - if: '$CI_COMMIT_REF_PROTECTED == "true"'
      when: manual  # ← Must be manual!
```

### Gotcha: Tag created but no GitHub release

**Problem**: Tag `v4.2.0` exists but no release on GitHub.

**Why**: `make release-github` step not run or failed.

**Check**:
```bash
# Does release exist?
gh release view v4.2.0

# If not, create manually
make release-github TAG=v4.2.0
```

**Fix in CI**: Ensure release job runs after tag creation:

```yaml
release:github:
  stage: .post  # Runs after all other stages
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+/'
  script:
    - make release-github TAG=$CI_COMMIT_TAG
```

### Gotcha: Release job stuck in pending state

**Problem**: GitLab CI shows "release" job but it never runs.

**Why**: Job is `when: manual` and waiting for you to click "Play".

**This is expected!** Release jobs should be manual to prevent accidental releases.

---

## General Gotchas

### Gotcha: Scripts work locally but not in CI

**Common causes**:

1. **Different working directory**:
   ```yaml
   # CI needs to be in repo root
   before_script:
     - cd /path/to/repo
   ```

2. **Missing environment variables**:
   ```yaml
   variables:
     GITHUB_REPO_URL: "owner/repo"
     GITHUB_TOKEN: ${SECRET_TOKEN}
   ```

3. **Missing dependencies**:
   ```yaml
   before_script:
     - command -v git jq gh git-cliff || exit 1
   ```

4. **Git config not set**:
   ```yaml
   before_script:
     - git config --global user.email "bot@example.com"
     - git config --global user.name "Release Bot"
   ```

### Gotcha: Command exists but version outdated

**Problem**: Script fails with unexpected errors despite having `jq` installed.

**Why**: Old version of tool missing features.

**Check versions**:
```bash
jq --version       # Need 1.6+
gh --version       # Need 2.0+
git --version      # Need 2.20+
git-cliff --version # Need 1.0+
```

**Fix**: Update tools to latest versions.

### Gotcha: Make targets don't work

**Problem**: `make release-pr` fails with "No such file or directory".

**Why**: Running from wrong directory or Makefile not present.

**Check**:
```bash
# Must be in repo root
pwd
ls -la Makefile

# If Makefile missing, you're in wrong directory
```

---

## Best Practices to Avoid Gotchas

1. **Always fetch tags before release operations**:
   ```bash
   git fetch --tags origin
   make release-status
   ```

2. **Use preview/dry-run modes first**:
   ```bash
   make release-version-show
   ./.gitlab/release/changelog.sh X.Y.Z --preview
   ```

3. **Follow conventional commits strictly**:
   - Use `feat:` for features
   - Use `fix:` for bug fixes
   - Use `!` or `BREAKING CHANGE:` for breaking changes

4. **Don't rebase after tagging**:
   - Tags are permanent
   - Create new RC instead

5. **Each branch has its own config**:
   - Don't assume config from main applies to maintenance branch
   - Update config when creating new branches

6. **Test locally before CI**:
   - Run `make release-pr` locally with `--no-push`
   - Verify PR contents
   - Then run in CI

7. **Document overrides**:
   - If you use `RELEASE_AS=X.Y.Z`, explain why in PR description
   - Future you will thank present you

---

## Quick Checklist Before Release

Before running `make release-pr`:

- [ ] Fetched latest tags: `git fetch --tags origin`
- [ ] On correct branch: `git rev-parse --abbrev-ref HEAD`
- [ ] Working tree clean: `git status`
- [ ] Commits follow conventions: `git log --oneline -10`
- [ ] Preview looks good: `make release-version-show`
- [ ] Config is correct: `cat release-please-config.json`
- [ ] GITHUB_TOKEN is set: `echo $GITHUB_TOKEN | head -c 10`

If all checks pass, proceed with confidence!

---

**See also**:
- [Troubleshooting Guide](TROUBLESHOOTING.md) - Fixing issues
- [FAQ](FAQ.md) - Common questions
- [README](../README.md) - Main documentation
