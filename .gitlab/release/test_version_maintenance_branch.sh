#!/bin/bash
# Test script for maintenance branch version scoping in version.sh
# This validates Task #9 implementation

set -euo pipefail

# Get absolute path to script directory - use builtin cd to avoid shell aliases
SCRIPT_DIR="$(builtin cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR=$(mktemp -d -t version-test-XXXXXX)
RESULTS_FILE="$TEST_DIR/test_results.txt"

# Validate scripts exist before running tests
if [[ ! -f "${SCRIPT_DIR}/common.sh" ]]; then
    echo "ERROR: common.sh not found at: ${SCRIPT_DIR}/common.sh"
    ls -la "${SCRIPT_DIR}/" 2>&1 | head -20
    exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/version.sh" ]]; then
    echo "ERROR: version.sh not found at: ${SCRIPT_DIR}/version.sh"
    ls -la "${SCRIPT_DIR}/" 2>&1 | head -20
    exit 1
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
test_header() { echo -e "\n${BLUE}==== $* ====${NC}"; }

cleanup() {
    if [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}

trap cleanup EXIT

# Create test git repo with specific scenario
create_test_repo() {
    local repo_dir="$1"
    mkdir -p "$repo_dir"
    cd "$repo_dir"

    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Copy release scripts to test repo
    mkdir -p .gitlab/release
    cp "$SCRIPT_DIR/common.sh" .gitlab/release/
    cp "$SCRIPT_DIR/version.sh" .gitlab/release/
    chmod +x .gitlab/release/version.sh

    # Create dummy git-cliff config
    cat > cliff.toml <<'EOF'
[changelog]
header = ""
body = ""
trim = true

[git]
conventional_commits = true
filter_unconventional = false
split_commits = false
commit_parsers = [
  { message = "^feat", group = "Features"},
  { message = "^fix", group = "Bug Fixes"},
  { message = "^doc", group = "Documentation"},
  { message = "^perf", group = "Performance"},
  { message = "^refactor", group = "Refactor"},
  { message = "^style", group = "Styling"},
  { message = "^test", group = "Testing"},
  { message = "^chore\\(release\\):", skip = true},
  { message = "^chore", group = "Miscellaneous Tasks"},
  { body = ".*security", group = "Security"},
]
protect_breaking_commits = false
filter_commits = false
tag_pattern = "v[0-9]*"
skip_tags = ""
ignore_tags = ""
topo_order = false
sort_commits = "oldest"
link_parsers = []
EOF

    # Create release-please config files
    cat > release-please-config.json <<EOF
{
  "packages": {
    ".": {
      "changelog-path": "CHANGELOG.md"
    }
  },
  "prerelease": true,
  "prerelease-type": "rc",
  "release-type": "simple"
}
EOF

    cat > .release-please-manifest.json <<EOF
{
  ".": "5.0.0"
}
EOF

    # Initial commit
    git add .
    git commit -q -m "chore: initial commit"

    info "Created test repo at $repo_dir"
}

# Add commits to repo
add_commits() {
    local count=$1
    local type=${2:-fix}

    for i in $(seq 1 "$count"); do
        echo "change $i" >> test.txt
        git add test.txt
        git commit -q -m "$type: test commit $i"
    done
}

# Test Case 1: Branch 5.0.x with no v5.0.* tags → fallback to v4.9.*
test_case_1() {
    test_header "TEST CASE 1: Branch 5.0.x with no tags → fallback to v4.9.*"

    local repo="$TEST_DIR/test1"
    create_test_repo "$repo"

    # Create v4.9.13 tag on main
    git tag v4.9.13

    # Create 5.0.x branch
    git checkout -q -b 5.0.x

    # Add some commits
    add_commits 2 "feat"

    # Run version.sh from test repo
    info "Running version.sh --dry-run --preview..."
    local result
    result=$(.gitlab/release/version.sh --dry-run --preview 2>&1 || true)

    echo "$result"
    echo "---"

    # Validate
    if echo "$result" | grep -q "Detected maintenance branch: 5.0.x"; then
        echo -e "${GREEN}✓${NC} Maintenance branch detected" | tee -a "$RESULTS_FILE"
    else
        echo -e "${RED}✗${NC} Maintenance branch NOT detected" | tee -a "$RESULTS_FILE"
        return 1
    fi

    if echo "$result" | grep -q "No tags found for v5.0.\*, checking v4.9.\*"; then
        echo -e "${GREEN}✓${NC} Fallback to v4.9.* triggered" | tee -a "$RESULTS_FILE"
    else
        echo -e "${RED}✗${NC} Fallback NOT triggered" | tee -a "$RESULTS_FILE"
        return 1
    fi

    if echo "$result" | grep -q "Found fallback tag from previous minor: v4.9.13"; then
        echo -e "${GREEN}✓${NC} Fallback tag found: v4.9.13" | tee -a "$RESULTS_FILE"
    else
        echo -e "${RED}✗${NC} Fallback tag NOT found" | tee -a "$RESULTS_FILE"
        return 1
    fi

    if echo "$result" | grep -q "New version: 5.0.0-rc.1"; then
        echo -e "${GREEN}✓${NC} Correct version calculated: 5.0.0-rc.1" | tee -a "$RESULTS_FILE"
    else
        echo -e "${RED}✗${NC} Wrong version calculated" | tee -a "$RESULTS_FILE"
        return 1
    fi

    echo -e "${GREEN}✓ TEST CASE 1 PASSED${NC}\n" | tee -a "$RESULTS_FILE"
}

# Test Case 2: Branch 5.0.x with v5.0.0-rc.1 → uses v5.0.0-rc.1 (not v4.9.13)
test_case_2() {
    test_header "TEST CASE 2: Branch 5.0.x with v5.0.0-rc.1 → uses v5.0.0-rc.1"

    local repo="$TEST_DIR/test2"
    create_test_repo "$repo"

    # Create tags
    git tag v4.9.13
    git checkout -q -b 5.0.x
    git tag v5.0.0-rc.1

    # Add commits
    add_commits 2 "fix"

    # Run version.sh from test repo
    info "Running version.sh --dry-run..."
    local result
    result=$(.gitlab/release/version.sh --dry-run 2>&1 || true)

    echo "$result"
    echo "---"

    # Validate
    if echo "$result" | grep -q "Detected maintenance branch: 5.0.x"; then
        echo -e "${GREEN}✓${NC} Maintenance branch detected" | tee -a "$RESULTS_FILE"
    else
        echo -e "${RED}✗${NC} Maintenance branch NOT detected" | tee -a "$RESULTS_FILE"
        return 1
    fi

    if echo "$result" | grep -q "Reference point: v5.0.0-rc.1"; then
        echo -e "${GREEN}✓${NC} Using v5.0.0-rc.1 as reference (not v4.9.13)" | tee -a "$RESULTS_FILE"
    else
        echo -e "${RED}✗${NC} Wrong reference point" | tee -a "$RESULTS_FILE"
        return 1
    fi

    # Should increment to rc.2
    if echo "$result" | grep -q "New version: 5.0.0-rc.2"; then
        echo -e "${GREEN}✓${NC} Correct version: 5.0.0-rc.2" | tee -a "$RESULTS_FILE"
    else
        echo -e "${RED}✗${NC} Wrong version calculated" | tee -a "$RESULTS_FILE"
        return 1
    fi

    echo -e "${GREEN}✓ TEST CASE 2 PASSED${NC}\n" | tee -a "$RESULTS_FILE"
}

# Test Case 3: Branch 5.0.x with v5.0.0 stable → uses v5.0.0 for next patch
test_case_3() {
    test_header "TEST CASE 3: Branch 5.0.x with v5.0.0 stable → uses v5.0.0 for next patch"

    local repo="$TEST_DIR/test3"
    create_test_repo "$repo"

    # Update manifest to stable
    cat > .release-please-manifest.json <<EOF
{
  ".": "5.0.0"
}
EOF

    # Update config to stable mode
    cat > release-please-config.json <<EOF
{
  "packages": {
    ".": {
      "changelog-path": "CHANGELOG.md"
    }
  },
  "prerelease": false,
  "release-type": "simple"
}
EOF

    git add .
    git commit -q -m "chore: prepare for stable"

    # Create tags
    git tag v4.9.13
    git checkout -q -b 5.0.x
    git tag v5.0.0

    # Add fix commits
    add_commits 1 "fix"

    # Run version.sh in stable mode from test repo
    info "Running version.sh --dry-run --no-prerelease..."
    local result
    result=$(.gitlab/release/version.sh --dry-run --no-prerelease 2>&1 || true)

    echo "$result"
    echo "---"

    # Validate
    if echo "$result" | grep -q "Detected maintenance branch: 5.0.x"; then
        echo -e "${GREEN}✓${NC} Maintenance branch detected" | tee -a "$RESULTS_FILE"
    else
        echo -e "${RED}✗${NC} Maintenance branch NOT detected" | tee -a "$RESULTS_FILE"
        return 1
    fi

    if echo "$result" | grep -q "Reference point: v5.0.0"; then
        echo -e "${GREEN}✓${NC} Using v5.0.0 as reference" | tee -a "$RESULTS_FILE"
    else
        echo -e "${RED}✗${NC} Wrong reference point" | tee -a "$RESULTS_FILE"
        return 1
    fi

    # Should bump to 5.0.1
    if echo "$result" | grep -q "New version: 5.0.1"; then
        echo -e "${GREEN}✓${NC} Correct version: 5.0.1" | tee -a "$RESULTS_FILE"
    else
        echo -e "${RED}✗${NC} Wrong version calculated" | tee -a "$RESULTS_FILE"
        return 1
    fi

    echo -e "${GREEN}✓ TEST CASE 3 PASSED${NC}\n" | tee -a "$RESULTS_FILE"
}

# Test Case 4: Main branch → no filtering (uses all tags)
test_case_4() {
    test_header "TEST CASE 4: Main branch → no filtering (uses all tags)"

    local repo="$TEST_DIR/test4"
    create_test_repo "$repo"

    # Update manifest
    cat > .release-please-manifest.json <<EOF
{
  ".": "5.1.0"
}
EOF

    git add .
    git commit -q -m "chore: update manifest"

    # Create various tags on main branch
    git tag v4.9.13
    git tag v5.0.0
    git tag v5.1.0

    # Add commits
    add_commits 1 "feat"

    # Run version.sh in stable mode from test repo
    info "Running version.sh --dry-run --no-prerelease..."
    local result
    result=$(.gitlab/release/version.sh --dry-run --no-prerelease 2>&1 || true)

    echo "$result"
    echo "---"

    # Validate - should NOT have maintenance branch detection
    if echo "$result" | grep -q "Detected maintenance branch:"; then
        echo -e "${RED}✗${NC} Should NOT detect maintenance branch on main" | tee -a "$RESULTS_FILE"
        return 1
    else
        echo -e "${GREEN}✓${NC} No maintenance branch detection on main" | tee -a "$RESULTS_FILE"
    fi

    # Should use latest tag v5.1.0 and bump to 5.2.0 (feat = minor)
    if echo "$result" | grep -q "Reference point: v5.1.0"; then
        echo -e "${GREEN}✓${NC} Using latest tag v5.1.0" | tee -a "$RESULTS_FILE"
    else
        echo -e "${RED}✗${NC} Wrong reference point" | tee -a "$RESULTS_FILE"
        return 1
    fi

    if echo "$result" | grep -q "New version: 5.2.0"; then
        echo -e "${GREEN}✓${NC} Correct version: 5.2.0" | tee -a "$RESULTS_FILE"
    else
        echo -e "${RED}✗${NC} Wrong version calculated" | tee -a "$RESULTS_FILE"
        return 1
    fi

    echo -e "${GREEN}✓ TEST CASE 4 PASSED${NC}\n" | tee -a "$RESULTS_FILE"
}

# Test Case 5: Branch 1.0.x (minor=0) → no fallback available
test_case_5() {
    test_header "TEST CASE 5: Branch 1.0.x (minor=0) → no fallback, uses initial"

    local repo="$TEST_DIR/test5"
    create_test_repo "$repo"

    # Update manifest
    cat > .release-please-manifest.json <<EOF
{
  ".": "1.0.0"
}
EOF

    git add .
    git commit -q -m "chore: update manifest"

    # Create 1.0.x branch (minor = 0, so no previous minor to fall back to)
    git checkout -q -b 1.0.x

    # Add commits
    add_commits 1 "feat"

    # Run version.sh from test repo
    info "Running version.sh --dry-run..."
    local result
    result=$(.gitlab/release/version.sh --dry-run 2>&1 || true)

    echo "$result"
    echo "---"

    # Validate
    if echo "$result" | grep -q "Detected maintenance branch: 1.0.x"; then
        echo -e "${GREEN}✓${NC} Maintenance branch detected" | tee -a "$RESULTS_FILE"
    else
        echo -e "${RED}✗${NC} Maintenance branch NOT detected" | tee -a "$RESULTS_FILE"
        return 1
    fi

    # Should NOT try fallback (minor=0)
    if echo "$result" | grep -q "checking v1.-1.\*"; then
        echo -e "${RED}✗${NC} Should NOT try negative minor fallback" | tee -a "$RESULTS_FILE"
        return 1
    else
        echo -e "${GREEN}✓${NC} No fallback attempted for minor=0" | tee -a "$RESULTS_FILE"
    fi

    if echo "$result" | grep -q "Reference point: (initial)"; then
        echo -e "${GREEN}✓${NC} Using (initial) as reference" | tee -a "$RESULTS_FILE"
    else
        echo -e "${RED}✗${NC} Should use (initial) reference" | tee -a "$RESULTS_FILE"
        return 1
    fi

    echo -e "${GREEN}✓ TEST CASE 5 PASSED${NC}\n" | tee -a "$RESULTS_FILE"
}

# Run all tests
main() {
    echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  Version.sh Maintenance Branch Test Suite     ║${NC}"
    echo -e "${BLUE}║  Task #9 Implementation Validation            ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}\n"

    info "Test directory: $TEST_DIR"
    info "Results file: $RESULTS_FILE"

    local failed=0

    test_case_1 || failed=$((failed + 1))
    test_case_2 || failed=$((failed + 1))
    test_case_3 || failed=$((failed + 1))
    test_case_4 || failed=$((failed + 1))
    test_case_5 || failed=$((failed + 1))

    # Summary
    echo -e "\n${BLUE}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  TEST SUMMARY                                  ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}\n"

    local total=5
    local passed=$((total - failed))

    if [[ $failed -eq 0 ]]; then
        echo -e "${GREEN}✓ ALL TESTS PASSED${NC} ($passed/$total)\n"
        cat "$RESULTS_FILE"
        return 0
    else
        echo -e "${RED}✗ SOME TESTS FAILED${NC} ($passed/$total passed, $failed failed)\n"
        cat "$RESULTS_FILE"
        return 1
    fi
}

main "$@"
