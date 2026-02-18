# Release Management Scripts

Modular scripts for managing mender-server releases using git-cliff for version calculation.

## Quick Start

```bash
# Calculate next version (no changes)
./version.sh --dry-run

# Preview changelog (no changes, local git only)
./changelog.sh 4.2.0 --preview

# Generate actual changelog (writes files, uses GitHub API)
# REQUIRES: GITHUB_TOKEN environment variable
export GITHUB_TOKEN="your_token_here"
./changelog.sh 4.2.0

# Generate changelog with local git only (no token needed, no PR links)
./changelog.sh 4.2.0 --local-git

# Create release PR
./pr.sh 4.2.0

# Promote RC to stable
./promote.sh v4.1.0-rc.2

# Create GitHub release
./release.sh v4.1.0
```

## Git-cliff Modes

The scripts use git-cliff for changelog generation with two different modes:

### Local Git Mode (Default for Preview)
- Reads commit history from local `.git` directory
- **Fast** - no network calls
- **No authentication required** - no GITHUB_TOKEN needed
- **Limited metadata** - no PR links, contributor avatars, etc.
- **No rate limits**

**When to use:**
- `./changelog.sh <version> --preview` - Quick preview of changes
- `./changelog.sh <version> --local-git` - Testing without API access

### GitHub API Mode (Default for Normal)
- Reads commit history from local git + fetches metadata from GitHub API
- **Slower** - makes network calls to GitHub
- **Requires authentication** - GITHUB_TOKEN environment variable
- **Rich metadata** - PR links, contributor info, etc.
- **Subject to rate limits** - 60 req/hour without token, 5000 req/hour with token

**When to use:**
- `./changelog.sh <version>` - Generating actual changelog for release (default)

**Required environment variable:**
```bash
export GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxx"
```

Get a token from: https://github.com/settings/tokens
Permissions needed: `repo` (read access)

## Workflows

### Direct Stable Release (Open Source)

```
Configuration: prerelease=false

make release-pr
  ↓
PR for v4.2.0
  ↓
Merge → Tag v4.2.0
  ↓
make release-github TAG=v4.2.0
```

### RC Testing → Promotion (Enterprise)

```
Configuration: prerelease=true, prerelease-type=rc

make release-pr → v4.1.0-rc.1
  ↓
Test & fix bugs
  ↓
make release-pr → v4.1.0-rc.2
  ↓
QA approval
  ↓
make release-promote RC_TAG=v4.1.0-rc.2 → v4.1.0
  ↓
make release-github TAG=v4.1.0
```

### Switch to Stable (Alternative)

```
make release-pr → v4.1.0-rc.2
  ↓
Edit config: prerelease=false
  ↓
make release-pr → v4.1.0
```

## Configuration

### .release-please-manifest.json
```json
{
  ".": "4.1.0"
}
```
Single source of truth for current version per branch.

### release-please-config.json
```json
{
  "prerelease": true,
  "prerelease-type": "rc"
}
```

| Setting | Values | Effect |
|---------|--------|--------|
| `prerelease` | `true` | Creates RC/saas versions |
| | `false` | Creates stable versions |
| `prerelease-type` | `"rc"` | For maintenance branches |
| | `"saas"` | For main branch (enterprise) |

## Version Calculation

Uses **git-cliff** to analyze conventional commits:
- `fix:` → patch bump (X.Y.Z+1)
- `feat:` → minor bump (X.Y+1.0)
- `BREAKING CHANGE:` or `!:` → major bump (X+1.0.0)

**Tag Filtering**:
- Stable releases: Ignore all `.*-(rc|saas).*` tags
- RC releases: Ignore `.*-saas.*` tags
- Saas releases: Ignore `.*-rc.*` tags

## Make Targets

```makefile
make release-status              # Show current version & config
make release-version-show        # Preview next version
make release-pr                  # Create release PR
make release-pr PRERELEASE=true  # Force RC mode
make release-pr PRERELEASE=false # Force stable mode
make release-promote RC_TAG=...  # Promote RC to stable
make release-github TAG=...      # Create GitHub release
```

## Branch Configuration Examples

### Open Source Main (Direct Stable)
```json
{
  "prerelease": false
}
```

### Enterprise Main (Saas Prereleases)
```json
{
  "prerelease": true,
  "prerelease-type": "saas"
}
```

### Maintenance Branch (RC → Stable)
```json
{
  "prerelease": true,
  "prerelease-type": "rc",
  "packages": {
    ".": {
      "changelog-path": "CHANGELOG-enterprise.md"
    }
  }
}
```

## Manual Override

Emergency use only:
```bash
RELEASE_AS=4.1.0-rc.5 make release-pr
```

## Testing

```bash
# Run all tests
./.gitlab/release/tests/run_all_tests.sh

# Dry-run mode (safe)
./version.sh --dry-run --preview
```
