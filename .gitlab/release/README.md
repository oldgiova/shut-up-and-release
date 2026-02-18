# Release Management

Modular bash scripts replacing `release-please` for managing releases.
Version calculation uses **git-cliff** on conventional commits. Git tags are the single source of truth.

---

## Workflows

### Prerelease → Stable (main flow)

```
make release-pr              # creates CHANGELOG-saas.md + CHANGELOG.md (unreleased)
  ↓ review & merge PR
make release-publish         # tags v1.0.0-saas.1, creates GitHub release
  ↓ (iterate if needed: more commits → make release-pr again → merge → publish)
make release-promote         # creates a promote PR: finalizes CHANGELOG.md date
  ↓ review & merge promote PR
make release-publish         # tags v1.0.0, creates GitHub release
```

### Stable (direct, no prerelease)

```
# config: prerelease=false
make release-pr              # creates CHANGELOG.md
  ↓ review & merge PR
make release-publish         # tags v1.0.0, creates GitHub release
```

---

## Make Targets

| Target | Description |
|--------|-------------|
| `make release-pr` | Create or update release PR |
| `make release-pr PRERELEASE=true` | Force prerelease mode (override config) |
| `make release-pr PRERELEASE=false` | Force stable mode (override config) |
| `make release-publish` | Tag + push + GitHub release (run after PR is merged) |
| `make release-promote` | Create promote PR (latest prerelease → stable) |
| `make release-promote RC_TAG=vX.Y.Z-saas.1` | Promote specific prerelease tag |
| `make release-version-show` | Preview next version (dry-run, no changes) |
| `make release-status` | Show current branch, tags, and config |
| `make release-diagnose` | Debug environment and configuration issues |

---

## Script Reference

### `pr.sh` — Create or update a release PR

Idempotent: running it again updates the existing PR branch and body.

**What it does:**
1. Calculates the next version via `version.sh` (git-cliff)
2. Resets the PR branch to the current base tip (`git checkout -B`)
3. Runs `changelog.sh` to generate `CHANGELOG-{suffix}.md`
4. For prerelease versions: also updates `CHANGELOG.md` with a cumulative
   `## X.Y.Z (unreleased)` section (commits since last stable tag, ignoring rc/saas)
5. Commits and pushes the branch (force-push on updates — branch is tool-managed)
6. Creates or updates the GitHub PR with label `autorelease: pending`

**Guards:**
- Working tree must be clean
- If the changelog on the base branch already matches what would be generated
  (i.e., PR was merged but not tagged), it fails with a clear message to run
  `make release-publish` instead

### `publish.sh` — Tag, push, and create GitHub release

Run **after** the release PR is merged.

**What it does:**
1. Checks for any open `autorelease: pending` PR — if one exists, exits with a
   warning (don't publish while a PR is still open)
2. Finds the most recently **merged** PR with label `autorelease: pending` —
   this is the authoritative source for the version to publish
3. Extracts the version from the PR title (`chore(branch): release X.Y.Z`)
4. Creates and pushes the git tag
5. Optionally waits for CI (skipped with `--skip-ci-wait` or `--auto-yes`)
6. Creates the GitHub release via `release.sh`

**Guards:**
- Refuses to run if a release PR is still open (`autorelease: pending`)
- Refuses to run if no merged release PR is found (nothing to publish)
- If the tag already exists, prompts to reuse it (auto-yes: reuses it)

### `promote.sh` — Create a promote PR (prerelease → stable)

Run after the prerelease tag exists and is validated. Creates a PR; does **not**
directly create the stable tag — that is done by `make release-publish` after
the promote PR is merged.

**What it does:**
1. Validates the prerelease tag exists
2. Validates `CHANGELOG.md` has a `## X.Y.Z (unreleased)` section (created by `pr.sh`)
3. Creates a promote PR branch reset to the base tip
4. Replaces `## X.Y.Z (unreleased)` → `## X.Y.Z - YYYY-MM-DD`
5. Commits and creates a GitHub PR with label `autorelease: pending`

**After merging the promote PR:** run `make release-publish`. It finds the merged
PR, extracts `X.Y.Z`, and creates the stable tag.

**Guards:**
- Stable tag must not already exist
- `CHANGELOG.md` must have the `(unreleased)` section — if missing, run `make release-pr` first
- Working tree must be clean

### `version.sh` — Calculate next version

Read-only. Outputs the next version string or nothing (if no releasable commits).

- Uses git-cliff `--bumped-version` to analyse conventional commits
- `fix:` → patch, `feat:` → minor, `BREAKING CHANGE:` / `!` → major
- Respects `prerelease` and `prerelease-type` from `release-please-config.json`
- On maintenance branches (`X.Y.x`): filters tags to the current `X.Y.*` series
- If the calculated version already has a tag: exits 0 with no output (nothing to release)

### `changelog.sh` — Generate changelog

Wraps `generate_changelog.sh` (GitHub API) or git-cliff directly (`--local-git`).

**Changelog strategy by version type:**

| Version type | File updated |
|---|---|
| `X.Y.Z-saas.N` | `CHANGELOG-saas.md` only |
| `X.Y.Z-rc.N` | `CHANGELOG-rc.md` only |
| Stable on maintenance branch | `CHANGELOG-enterprise.md` only |
| Stable on main branch | `CHANGELOG.md` only |

The cumulative `CHANGELOG.md (unreleased)` section for prerelease cycles is
managed separately by `pr.sh`, not by `changelog.sh`.

---

## Configuration

### `release-please-config.json`

```json
{
  "prerelease": true,
  "prerelease-type": "saas"
}
```

| Field | Values | Effect |
|-------|--------|--------|
| `prerelease` | `true` | Creates prerelease versions (saas/rc suffix) |
| | `false` | Creates stable versions |
| `prerelease-type` | `"saas"` | Main branch (e.g., v1.0.0-saas.1) |
| | `"rc"` | Maintenance branches (e.g., v4.1.0-rc.2) |

---

## Tag Format

Valid tag formats (strict semver, safe for shell use):

```
vX.Y.Z                  stable     e.g. v1.0.0
vX.Y.Z-saas             prerelease e.g. v1.0.0-saas
vX.Y.Z-saas.N           prerelease e.g. v1.0.0-saas.1
vX.Y.Z-rc               prerelease e.g. v4.1.0-rc
vX.Y.Z-rc.N             prerelease e.g. v4.1.0-rc.2
```

Pre-release identifiers consist of lowercase letters, digits, and dots only —
no shell-special characters. This is enforced by `validate_tag()` in `common.sh`.

---

## Manual Version Override

Use `RELEASE_AS` to bypass git-cliff and force a specific version:

```bash
RELEASE_AS=1.0.0-saas make release-pr
RELEASE_AS=1.0.0-saas.3 make release-pr
RELEASE_AS=4.1.0 make release-pr PRERELEASE=false
```

The `v` prefix is optional — both `1.0.0-saas` and `v1.0.0-saas` work.

---

## CI/CD (Non-interactive Mode)

GitLab CI sets `CI=true` automatically. The Makefile detects this and passes
`--auto-yes` to all scripts, suppressing interactive prompts:

```makefile
CI_FLAGS := $(if $(filter true,$(CI)),--auto-yes,)
```

`--auto-yes` implies `--skip-ci-wait` in `publish.sh`.

To force non-interactive mode manually:
```bash
make release-publish CI=true
make release-promote CI=true
```

---

## Source of Truth

| What | Where |
|------|-------|
| Current version | Latest git tag |
| Version to publish | Merged PR with `autorelease: pending` label |
| Next version | git-cliff analysis of commits since last tag |
| Changelog content | git-cliff + (optionally) GitHub API via `generate_changelog.sh` |

The `.release-please-manifest.json` file is a fallback for repos with no tags yet.
It is **not** updated during normal release operations.

---

## Guards and Restrictions

| Guard | Where | Behaviour |
|-------|-------|-----------|
| Open release PR exists | `publish.sh` | Warn + exit 0 (not an error) |
| No merged release PR found | `publish.sh` | Info + exit 0 |
| Stable tag already exists | `promote.sh` | Fatal |
| `CHANGELOG.md` missing `(unreleased)` section | `promote.sh` | Fatal with instructions |
| Working tree not clean | `pr.sh`, `promote.sh` | Fatal |
| PR already merged, no tag yet | `pr.sh` | Fatal with instructions to run `release-publish` |
| Invalid tag format | all scripts | Fatal via `validate_tag()` |

---

## PR Branch Naming

| Branch | Used by |
|--------|---------|
| `release-please--branches--{base}` | `pr.sh` — prerelease/stable PR |
| `release-please--branches--{base}--promote` | `promote.sh` — promote PR |

Both branches are **fully tool-managed**: they are always reset to the base tip
on each run (`git checkout -B`). Force-push is always used for updates.
Do not commit directly to these branches.
