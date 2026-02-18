#!/bin/bash
# Simplified test for maintenance branch version scoping
# Task #9 implementation validation

set -euo pipefail

REPO_ROOT="/home/giova/src/github/mendersoftware/worktrees/nt-boilerplate-pipeline/release-please-replacement-agents"
TEST_TEMP=$(mktemp -d)

cleanup() {
    rm -rf "$TEST_TEMP"
}
trap cleanup EXIT

echo "========================================="
echo "Maintenance Branch Version Scoping Test"
echo "========================================="
echo

# Create a test git repo
setup_test_repo() {
    local name=$1
    local dir="$TEST_TEMP/$name"

    mkdir -p "$dir"/.gitlab/release
    cp "$REPO_ROOT"/.gitlab/release/common.sh "$dir"/.gitlab/release/
    cp "$REPO_ROOT"/.gitlab/release/version.sh "$dir"/.gitlab/release/

    cd "$dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"

    # Create config files
    cat > release-please-config.json <<'EOF'
{
  "packages": {".": {}},
  "prerelease": true,
  "prerelease-type": "rc"
}
EOF

    cat > .release-please-manifest.json <<'EOF'
{
  ".": "5.0.0"
}
EOF

    # Add git-cliff config (minimal)
    cat > cliff.toml <<'EOF'
[git]
conventional_commits = true
filter_commits = false
tag_pattern = "v[0-9]*"
EOF

    git add .
    git commit -q -m "initial"
}

# Debug function
show_state() {
    echo "  Current branch: $(git branch --show-current)"
    echo "  Manifest version: $(cat .release-please-manifest.json)"
    echo "  Tags: $(git tag -l | xargs)"
}

# TEST 1: Fallback to previous minor
echo "TEST 1: Branch 5.0.x with no v5.0.* tags → fallback to v4.9.*"
setup_test_repo "test1"
git tag v4.9.13
git checkout -qb 5.0.x
echo "fix" >> test.txt
git add test.txt
git commit -q -m "fix: test"

show_state

echo "Running version.sh..."
export GITHUB_REPO_URL="test/repo"
result=$(.gitlab/release/version.sh --dry-run --preview 2>&1 || echo "FAILED")

# Debug output
echo "--- version.sh output ---"
echo "$result"
echo "-------------------------"

if echo "$result" | grep -q "Detected maintenance branch: 5.0.x"; then
    echo "✓ Maintenance branch detected"
else
    echo "✗ Maintenance branch NOT detected"
    echo "$result"
    exit 1
fi

if echo "$result" | grep -q "checking v4.\*"; then
    echo "✓ Fallback to previous major (v4.*) triggered"
else
    echo "✗ Fallback NOT triggered"
    echo "$result"
    exit 1
fi

if echo "$result" | grep -q "Found fallback tag from previous major: v4.9.13"; then
    echo "✓ Found fallback tag v4.9.13"
else
    echo "✗ Fallback tag NOT found"
    echo "$result"
    exit 1
fi

if echo "$result" | grep -q "Reference point: v4.9.13"; then
    echo "✓ Using v4.9.13 as reference point"
else
    echo "✗ Wrong reference point"
    echo "$result"
    exit 1
fi

echo "✓ TEST 1 PASSED"
echo

# TEST 2: Use existing v5.0.0-rc.1 (don't fallback)
echo "TEST 2: Branch 5.0.x with v5.0.0-rc.1 → uses v5.0.0-rc.1"
setup_test_repo "test2"
git tag v4.9.13
git checkout -qb 5.0.x
git tag v5.0.0-rc.1
echo "fix" >> test.txt
git add test.txt
git commit -q -m "fix: test"

export GITHUB_REPO_URL="test/repo"
result=$(.gitlab/release/version.sh --dry-run 2>&1)

if echo "$result" | grep -q "Reference point: v5.0.0-rc.1"; then
    echo "✓ Using v5.0.0-rc.1 (not v4.9.13)"
else
    echo "✗ Wrong reference point"
    echo "$result"
    exit 1
fi

echo "✓ TEST 2 PASSED"
echo

# TEST 3: Main branch - no filtering
echo "TEST 3: Main branch → no maintenance branch filtering"
setup_test_repo "test3"
git tag v4.9.13
git tag v5.0.0
echo "feat" >> test.txt
git add test.txt
git commit -q -m "feat: test"

export GITHUB_REPO_URL="test/repo"
result=$(.gitlab/release/version.sh --dry-run --no-prerelease 2>&1)

if echo "$result" | grep -q "Detected maintenance branch:"; then
    echo "✗ Should NOT detect maintenance branch on main"
    echo "$result"
    exit 1
else
    echo "✓ No maintenance branch detection on main"
fi

echo "✓ TEST 3 PASSED"
echo

echo "========================================="
echo "✓ ALL TESTS PASSED"
echo "========================================="
