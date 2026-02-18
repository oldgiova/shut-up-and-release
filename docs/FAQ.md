# Frequently Asked Questions (FAQ)

Common questions about the release management system.

## Table of Contents

- [General Questions](#general-questions)
- [Version Management](#version-management)
- [Workflows](#workflows)
- [Configuration](#configuration)
- [Changelogs](#changelogs)
- [Tags and Releases](#tags-and-releases)
- [Troubleshooting](#troubleshooting)

---

## General Questions

### Q: Why replace release-please?

**A:** release-please cannot promote RC tags to stable versions without new commits. It expects linear version increments based on commits and has no concept of "promoting" an existing tested RC to stable.

Our workflow needs:
```
v4.1.0-rc.1 → v4.1.0-rc.2 → v4.1.0  (PROMOTION, not a new release)
                              ↑
                        Missing in release-please!
```

### Q: Is this compatible with release-please?

**A:** The system uses the same config files (`.release-please-manifest.json` and `release-please-config.json`) for compatibility, but the automation is custom bash scripts using git-cliff instead of release-please.

### Q: Can I use this for non-Mender projects?

**A:** Yes! The system is designed to be generic. Just update:
- `GITHUB_REPO_URL` environment variable
- git-cliff config (`.gitlab/cliff.toml`)
- Adjust prerelease types if needed (currently: `rc`, `saas`)

### Q: What happens to existing release-please PRs?

**A:** They remain but won't auto-update. Close them manually before switching to the new system. The new system creates PRs with the same branch naming pattern for consistency.

### Q: Is this production-ready?

**A:** Yes. The system is:
- Battle-tested with comprehensive test suites
- Idempotent (safe to run multiple times)
- Auditable (all changes via PRs)
- Documented extensively

---

## Version Management

### Q: Do I need to manually update the manifest file?

**A:** No. The scripts automatically update `.release-please-manifest.json`. You only need to set it once when creating a new maintenance branch.

### Q: Why does the manifest show version X but the latest tag is version Y?

**A:** Each branch maintains its own version independently:
- `main` branch might be at `4.2.0`
- `4.1.x` maintenance branch starts at `4.1.0`

The manifest reflects the branch's version, not global version.

### Q: How do I reset version numbering?

**A:** Update `.release-please-manifest.json` manually:
```bash
# Example: Reset to 1.0.0
jq '.".".= "1.0.0"' .release-please-manifest.json > tmp.json
mv tmp.json .release-please-manifest.json
git add .release-please-manifest.json
git commit -m "chore: reset version to 1.0.0"
```

### Q: Can I skip version numbers (e.g., 4.1.0 → 4.3.0)?

**A:** Yes, using manual override:
```bash
RELEASE_AS=4.3.0 make release-pr
```

Document the reason in the PR description.

### Q: What if git-cliff calculates the wrong version bump?

**A:** Common causes:
1. Commits don't follow conventional commit format
2. Typos in commit prefixes (`feature:` vs `feat:`)
3. Missing `!` or `BREAKING CHANGE:` footer

Use `--preview` to see what git-cliff detects:
```bash
./.gitlab/release/version.sh --dry-run --preview
```

Or override manually:
```bash
RELEASE_AS=5.0.0 make release-pr
```

---

## Workflows

### Q: Which workflow should I use?

**A:**
- **Open source, main branch**: Direct stable (Workflow A)
- **Enterprise, maintenance branch (4.1.x)**: RC testing + promotion (Workflow B)
- **Enterprise, main branch (hosted)**: SaaS prereleases

See [README.md](../README.md#workflows) for details.

### Q: Can I switch between workflows?

**A:** Yes! Just change `prerelease` in `release-please-config.json`:
```json
{
  "prerelease": true   // RC mode
}
```
to:
```json
{
  "prerelease": false  // Stable mode
}
```

### Q: Do I have to use promotion? Can I go RC → stable directly?

**A:** Yes, you have options:

**Option 1: Use promotion** (recommended)
```bash
make release-pr  # Create RC
# Test, repeat RCs as needed
make release-promote RC_TAG=v4.1.0-rc.2  # Promote when ready
```

**Option 2: Switch config**
```bash
make release-pr  # Create RC (prerelease: true)
# After testing, edit config to prerelease: false
make release-pr  # Create stable
```

**Option 3: Override**
```bash
make release-pr PRERELEASE=false  # Force stable, ignore config
```

### Q: Does promotion create a PR or push directly?

**A:** **Promotion creates a PR for review**. It does NOT push tags directly. This ensures:
- Changes are reviewed (changelog, version bump)
- CI tests run before stable tag created
- Audit trail maintained

The CLAUDE.md file had an error saying "NO PR!" but that's incorrect.

### Q: Can I create multiple RCs in parallel?

**A:** No. RC versioning is sequential:
- v4.1.0-rc.1
- v4.1.0-rc.2
- v4.1.0-rc.3

Create one RC, test it, then create the next. Parallel RCs would create version conflicts.

---

## Configuration

### Q: What's the difference between `prerelease-type: rc` and `prerelease-type: saas`?

**A:**
- **`rc`**: For release candidates on maintenance branches (e.g., `v4.1.0-rc.1`)
- **`saas`**: For continuous deployment on main branch (e.g., `v4.1.0-saas.2`)

Both are prereleases, but they serve different workflows and use different changelog files.

### Q: Can I have different prerelease types on different branches?

**A:** Yes! Each branch has its own `release-please-config.json`. Example:

**main branch** (open source):
```json
{"prerelease": false}  // Direct stable
```

**main branch** (enterprise):
```json
{"prerelease": true, "prerelease-type": "saas"}  // SaaS
```

**4.1.x branch**:
```json
{"prerelease": true, "prerelease-type": "rc"}  // RC testing
```

### Q: What files are required?

**A:** Minimum:
1. `.release-please-manifest.json` - Version storage
2. `release-please-config.json` - Workflow configuration
3. `.gitlab/cliff.toml` - git-cliff configuration (for changelog)
4. `CHANGELOG.md` (or variant like `CHANGELOG-enterprise.md`)

### Q: Can I use custom changelog file names?

**A:** Yes, configure in `release-please-config.json`:
```json
{
  "packages": {
    ".": {
      "changelog-path": "CHANGELOG-custom.md"
    }
  }
}
```

---

## Changelogs

### Q: Do I need separate changelogs for RC and stable?

**A:** It depends on your workflow:

**Enterprise maintenance branches**: Yes, recommended
- `CHANGELOG-rc.md` for RC releases (incremental)
- `CHANGELOG-enterprise.md` for stable releases (full)

**Open source / SaaS**: No, single changelog is fine
- `CHANGELOG.md` for everything

### Q: How does changelog generation work?

**A:** Uses git-cliff to:
1. Analyze conventional commits since last release
2. Group by type (Features, Bug Fixes, etc.)
3. Generate markdown with links to commits and PRs
4. Append to top of CHANGELOG file

### Q: Can I manually edit changelogs?

**A:** Yes! Edit the CHANGELOG file before merging the release PR. The scripts won't overwrite your manual changes once committed.

### Q: Why are some commits missing from the changelog?

**A:** Common reasons:
1. **Commits don't follow conventional format**: `fix: something` not `fixed something`
2. **Commit type is excluded**: Check `.gitlab/cliff.toml` commit_parsers
3. **Commits are in wrong range**: Check which tags git-cliff is comparing

Debug with:
```bash
./.gitlab/release/changelog.sh 4.2.0 --preview
```

### Q: Can I generate changelog without GitHub API (no token)?

**A:** Yes:
```bash
# Local git mode (fast, no PR links)
./.gitlab/release/changelog.sh 4.2.0 --local-git

# Or preview mode
./.gitlab/release/changelog.sh 4.2.0 --preview
```

---

## Tags and Releases

### Q: When are tags created?

**A:** Tags are **NOT** created by the scripts directly. The workflow is:

1. Scripts create PR with version bump + changelog
2. You review and merge PR
3. **GitLab/GitHub CI** creates tag on merge (via webhook or pipeline)
4. Tag pipeline builds and publishes

This ensures tags are only created after PR approval.

### Q: Can I delete a tag and recreate it?

**A:** Yes, but be very careful:

```bash
# Backup first!
git tag v4.1.0-backup v4.1.0

# Delete locally
git tag -d v4.1.0

# Delete remotely (DESTRUCTIVE!)
git push origin :refs/tags/v4.1.0

# Recreate
git tag v4.1.0 <commit-sha>
git push origin v4.1.0
```

**Warning**: If images/artifacts were built from the old tag, this creates inconsistency.

### Q: What's the difference between tag and GitHub release?

**A:**
- **Git tag**: Just a pointer to a commit (created by CI)
- **GitHub release**: Rich metadata (changelog, binaries, prerelease flag) created by `release.sh`

You need both. Workflow:
1. PR merged → tag created (CI)
2. Run `make release-github TAG=vX.Y.Z` → GitHub release created

### Q: Are RC tags marked as prerelease on GitHub?

**A:** Yes, `release.sh` auto-detects `-rc` or `-saas` in tag name and marks as prerelease.

To verify:
```bash
gh release view v4.1.0-rc.1 --json isPrerelease
```

### Q: Can I have a tag without a GitHub release?

**A:** Yes. GitHub releases are optional (but recommended). Tags alone are sufficient for CI to build/deploy.

---

## Troubleshooting

### Q: Script fails with "working tree is not clean"

**A:** Commit or stash your changes first:
```bash
git status        # See what's uncommitted
git stash         # Temporarily save changes
make release-pr
git stash pop     # Restore changes
```

### Q: Version shows as "patch" but I added a feature

**A:** Your commit message likely doesn't follow conventional commits:

**Wrong**: `added new feature`

**Right**: `feat: added new feature`

Check what git-cliff sees:
```bash
./.gitlab/release/version.sh --dry-run --preview
```

### Q: How do I test scripts without making changes?

**A:** All scripts have dry-run/test modes:
```bash
# Version calculation
./.gitlab/release/version.sh --dry-run --preview

# Changelog preview
./.gitlab/release/changelog.sh 4.2.0 --preview

# PR creation (no push)
./.gitlab/release/pr.sh 4.2.0 --no-push
```

### Q: Can I run scripts locally or do they need CI?

**A:** You can run scripts locally! Requirements:
```bash
# Required tools
command -v git jq gh git-cliff

# Required env var for PR/release creation
export GITHUB_TOKEN="ghp_..."

# Then run any script
make release-status
make release-version-show
```

CI is optional for testing, but recommended for actual releases.

### Q: Script succeeds but PR not created on GitHub

**A:** Check:
1. **GITHUB_TOKEN set?** `echo $GITHUB_TOKEN`
2. **gh CLI authenticated?** `gh auth status`
3. **Repository accessible?** `gh repo view`
4. **Branch pushed?** `git log origin/release-please--branches--main`

Debug with:
```bash
# Test gh CLI
gh pr list
gh pr create --help

# Test with small example
gh pr create --title "Test" --body "Test" --draft
```

---

## Advanced Questions

### Q: Can I customize the PR title/body template?

**A:** Currently, PR title is auto-generated as `chore: release X.Y.Z`. Body is extracted from changelog.

To customize:
```bash
# Custom title
./.gitlab/release/pr.sh 4.2.0 --title "chore: release 4.2.0 (hotfix)"

# Custom body
echo "Custom PR description" > /tmp/body.md
./.gitlab/release/pr.sh 4.2.0 --body /tmp/body.md
```

### Q: How do I integrate with existing CI/CD?

**A:** See `.gitlab-ci.yml` examples in CLAUDE.md. Key points:
- Use manual triggers for release jobs
- Set GITHUB_TOKEN from CI secrets
- Use appropriate Docker image with dependencies
- Protect release branches

### Q: Can I use this with GitHub Actions instead of GitLab CI?

**A:** Yes! The scripts are bash-based and work anywhere. Example workflow:

```yaml
name: Release
on:
  workflow_dispatch:
    inputs:
      release_type:
        required: true
        type: choice
        options: [rc, stable, promote]

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Create release PR
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: make release-pr
```

### Q: What if I need to support other prerelease types (alpha, beta)?

**A:** Modify:
1. `release-please-config.json`: Add new `prerelease-type`
2. `.gitlab/release/common.sh`: Update `is_prerelease()` function
3. `.gitlab/release/version.sh`: Add version suffix logic

Example:
```json
{"prerelease-type": "alpha"}  // → v4.1.0-alpha.1
```

### Q: Can I release multiple packages from one repo (monorepo)?

**A:** The current design supports single-package releases (`.` in manifest). For monorepo support, you'd need to:
1. Extend manifest to include multiple packages
2. Modify scripts to handle package-specific versions
3. Create separate changelog per package

This is a significant extension not currently implemented.

---

## Getting More Help

- **Troubleshooting**: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
- **Common Gotchas**: [COMMON_GOTCHAS.md](COMMON_GOTCHAS.md)
- **Script Documentation**: [.gitlab/release/README.md](../.gitlab/release/README.md)
- **Usage Examples**: [.gitlab/release/USAGE.md](../.gitlab/release/USAGE.md)

**Can't find your answer?**
1. Check script help: `./.gitlab/release/<script>.sh --help`
2. Search issues in the repository
3. Ask in team chat with script output and error messages
