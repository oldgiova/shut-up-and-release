# Example: CHANGELOG-enterprise.md for v5.0.0

This demonstrates what the changelog would look like for the critical requirement:
**"v5.0.0 must show full diff from v4.9.13 (or v4.9.0 in this repo)"**

---

## [5.0.0] - 2026-02-14

**Reference Range:** v4.9.0..v5.0.0

This stable release includes ALL changes since the last stable release (v4.9.0) from the previous maintenance branch series.

### Key Points

1. **Full diff from v4.9.0**: This changelog entry includes ALL commits between v4.9.0 and v5.0.0
2. **No RC noise**: RC releases (v5.0.0-rc.1, v5.0.0-rc.2, etc.) do NOT appear in this changelog
3. **Enterprise only**: This file contains ONLY stable releases from maintenance branches

### Generated Using

```bash
# Reference tag found by find_stable_reference_tag():
ref_tag="v4.9.0"  # Last stable from previous series

# Git-cliff range:
git cliff --tag v5.0.0 --range "${ref_tag}..v5.0.0" --ignore-tags '.*-(rc|saas).*' -o CHANGELOG-enterprise.md
```

### Sample Changelog Content

```markdown
## [5.0.0] - 2026-02-14

### Added
- New feature A from commits in v4.9.0..v5.0.0 range
- New feature B from commits in v4.9.0..v5.0.0 range
- Enhancement C from commits in v4.9.0..v5.0.0 range

### Changed
- Updated component X (from v4.9.0..v5.0.0 range)
- Improved performance of Y (from v4.9.0..v5.0.0 range)

### Fixed
- Bug fix 1 (from v4.9.0..v5.0.0 range)
- Bug fix 2 (from v4.9.0..v5.0.0 range)

### Breaking Changes
- Breaking change A (if any in range)

[Full Changelog](https://github.com/mendersoftware/mender-server-enterprise/compare/v4.9.0...v5.0.0)
```

---

## Comparison: What Was Wrong Before

### Before (Incorrect Behavior)

**Problem:** RC releases were updating BOTH changelogs:
```
v5.0.0-rc.1 released → Updates CHANGELOG-rc.md AND CHANGELOG-enterprise.md (wrong!)
v5.0.0-rc.2 released → Updates CHANGELOG-rc.md AND CHANGELOG-enterprise.md (wrong!)
v5.0.0 released → Only incremental changes since last RC (wrong! missing full diff)
```

**Result:** CHANGELOG-enterprise.md would have:
```markdown
## [5.0.0] (unreleased)  ← Added by RC releases (wrong!)
### ... changes since v5.0.0-rc.2 only ...

## [5.0.0-rc.2] (unreleased)  ← Should NOT be here!
## [5.0.0-rc.1] (unreleased)  ← Should NOT be here!
```

### After (Correct Behavior)

**Fix:** RC releases update ONLY CHANGELOG-rc.md, stable updates ONLY CHANGELOG-enterprise.md:
```
v5.0.0-rc.1 released → Updates CHANGELOG-rc.md ONLY (correct!)
v5.0.0-rc.2 released → Updates CHANGELOG-rc.md ONLY (correct!)
v5.0.0 released → Updates CHANGELOG-enterprise.md with FULL diff from v4.9.0 (correct!)
```

**Result:** CHANGELOG-enterprise.md has:
```markdown
## [5.0.0] - 2026-02-14  ← Stable release only, with date
### ... ALL changes from v4.9.0 to v5.0.0 ...  ← Full diff!
```

**Result:** CHANGELOG-rc.md has (separate file, internal use):
```markdown
## [5.0.0-rc.2] - 2026-02-10  ← RC releases go here
## [5.0.0-rc.1] - 2026-02-05  ← Not mixed with enterprise!
```

---

## Verification

To verify this works correctly in a real scenario:

```bash
# 1. On 5.0.x branch, create RC
./gitlab/release/changelog.sh 5.0.0-rc.1 --preview

# Expected output:
#   → Updates CHANGELOG-rc.md
#   → Does NOT touch CHANGELOG-enterprise.md

# 2. On 5.0.x branch, create stable
./gitlab/release/changelog.sh 5.0.0 --preview

# Expected output:
#   → Updates CHANGELOG-enterprise.md
#   → Range: v4.9.0..v5.0.0 (full diff)
#   → Does NOT touch CHANGELOG-rc.md
```

---

## Summary

✅ **Critical requirement satisfied:**
- v5.0.0 shows full diff from v4.9.0 (last stable of previous series)
- RC releases do NOT pollute CHANGELOG-enterprise.md
- Each changelog has a distinct, correct purpose
- No manual intervention needed for changelog separation
