#!/bin/bash
# Test: cascading branch bug fix in pr.sh
# Verifies that pr.sh restores the original branch on failure (exit trap),
# not just on success.
#
# The bug: before the fix, if pr.sh failed after git checkout -b <pr-branch>,
# the shell stayed on the PR branch. Next invocation would read it as
# base_branch and generate a doubly-nested branch name.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; ((FAILURES++)); }
info() { echo -e "${YELLOW}[TEST]${NC} $*"; }

FAILURES=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup_test_repo() {
    local repo_dir
    repo_dir=$(mktemp -d)

    git init -q "$repo_dir"
    git -C "$repo_dir" config user.email "test@test.com"
    git -C "$repo_dir" config user.name "Test User"
    git -C "$repo_dir" config commit.gpgsign false
    git -C "$repo_dir" config tag.gpgsign false

    # Required config files
    printf '{ ".": "0.1.0" }\n' > "$repo_dir/.release-please-manifest.json"
    cat > "$repo_dir/release-please-config.json" <<'EOF'
{
  "prerelease": false,
  "prerelease-type": "rc",
  "packages": {
    ".": {
      "changelog-path": "CHANGELOG.md"
    }
  }
}
EOF
    echo "---" > "$repo_dir/CHANGELOG.md"

    git -C "$repo_dir" add .
    git -C "$repo_dir" commit -q -m "chore: initial commit"
    git -C "$repo_dir" tag v0.1.0

    # Copy real scripts
    mkdir -p "$repo_dir/.gitlab/release"
    cp "$SCRIPT_DIR/common.sh"  "$repo_dir/.gitlab/release/"
    cp "$SCRIPT_DIR/pr.sh"      "$repo_dir/.gitlab/release/"

    echo "$repo_dir"
}

# Mock version.sh: just echoes a fixed version, no git-cliff needed
install_mock_version_sh() {
    local repo_dir=$1
    cat > "$repo_dir/.gitlab/release/version.sh" <<'EOF'
#!/bin/bash
echo "0.2.0"
EOF
    chmod +x "$repo_dir/.gitlab/release/version.sh"
}

# Mock changelog.sh: writes a small change to CHANGELOG.md so git has something
# to commit (which then hits the pre-commit hook), and fills the pr-body file
install_mock_changelog_sh() {
    local repo_dir=$1
    cat > "$repo_dir/.gitlab/release/changelog.sh" <<'EOF'
#!/bin/bash
echo "## 0.2.0" >> CHANGELOG.md
while [[ $# -gt 0 ]]; do
    case $1 in
        --pr-body) echo "Test release body" > "$2"; shift 2 ;;
        *) shift ;;
    esac
done
exit 0
EOF
    chmod +x "$repo_dir/.gitlab/release/changelog.sh"
}

# Mock gh: exists so require_command gh passes, but we never reach it in the
# error-path tests (failure happens before any gh call)
install_mock_gh() {
    local bin_dir=$1
    cat > "$bin_dir/gh" <<'EOF'
#!/bin/bash
echo "mock gh: $*" >&2
exit 0
EOF
    chmod +x "$bin_dir/gh"
}

# ---------------------------------------------------------------------------
# Test 1: Error path — failure AFTER branch switch restores branch
# ---------------------------------------------------------------------------
test_error_path_restores_branch() {
    info "Test 1: branch is restored when pr.sh fails after branch switch"

    local repo_dir
    repo_dir=$(setup_test_repo)
    local mock_bin_dir
    mock_bin_dir=$(mktemp -d)
    trap 'rm -rf "$repo_dir" "$mock_bin_dir"' RETURN

    install_mock_version_sh  "$repo_dir"
    install_mock_changelog_sh "$repo_dir"
    install_mock_gh           "$mock_bin_dir"

    # Pre-commit hook that fails → git commit fails → fatal() → EXIT trap fires
    mkdir -p "$repo_dir/.git/hooks"
    cat > "$repo_dir/.git/hooks/pre-commit" <<'EOF'
#!/bin/bash
echo "SIMULATED: pre-commit hook fails to trigger branch restoration test" >&2
exit 1
EOF
    chmod +x "$repo_dir/.git/hooks/pre-commit"

    local original_branch
    original_branch=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)
    info "  Original branch: $original_branch"

    # Run pr.sh — expects failure (pre-commit hook kills the commit)
    local pr_sh_output
    pr_sh_output=$(
        cd "$repo_dir"
        PATH="$mock_bin_dir:$PATH" \
            bash .gitlab/release/pr.sh --no-push 2>&1
    ) || true  # expected to fail

    local current_branch
    current_branch=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)
    info "  Branch after failure: $current_branch"

    if [[ "$current_branch" == "$original_branch" ]]; then
        pass "Branch restored to '$original_branch' after mid-run failure"
    else
        fail "Branch NOT restored: expected '$original_branch', got '$current_branch'"
        echo "  pr.sh output:"
        echo "$pr_sh_output" | sed 's/^/    /'
    fi

    # Verify no nested branch names exist
    local nested
    nested=$(git -C "$repo_dir" branch | grep "release-please.*release-please" || true)
    if [[ -z "$nested" ]]; then
        pass "No nested release branch names created"
    else
        fail "Found nested release branch names: $nested"
    fi
}

# ---------------------------------------------------------------------------
# Test 2: Success path — branch is still restored at the end
# ---------------------------------------------------------------------------
test_success_path_restores_branch() {
    info ""
    info "Test 2: branch is restored when pr.sh succeeds (--no-push)"

    local repo_dir
    repo_dir=$(setup_test_repo)
    local mock_bin_dir
    mock_bin_dir=$(mktemp -d)
    trap 'rm -rf "$repo_dir" "$mock_bin_dir"' RETURN

    install_mock_version_sh  "$repo_dir"
    install_mock_changelog_sh "$repo_dir"
    install_mock_gh           "$mock_bin_dir"
    # No failing pre-commit hook — let the commit succeed

    local original_branch
    original_branch=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)
    info "  Original branch: $original_branch"

    local pr_sh_output
    pr_sh_output=$(
        cd "$repo_dir"
        PATH="$mock_bin_dir:$PATH" \
            bash .gitlab/release/pr.sh --no-push 2>&1
    )

    local current_branch
    current_branch=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)
    info "  Branch after success: $current_branch"

    if [[ "$current_branch" == "$original_branch" ]]; then
        pass "Branch back to '$original_branch' after successful run"
    else
        fail "Branch NOT restored: expected '$original_branch', got '$current_branch'"
        echo "  pr.sh output:"
        echo "$pr_sh_output" | sed 's/^/    /'
    fi
}

# ---------------------------------------------------------------------------
# Test 3: Running pr.sh twice on error doesn't produce nested branch names
# ---------------------------------------------------------------------------
test_no_nested_branches_after_two_failures() {
    info ""
    info "Test 3: two consecutive failures don't produce nested branch names"

    local repo_dir
    repo_dir=$(setup_test_repo)
    local mock_bin_dir
    mock_bin_dir=$(mktemp -d)
    trap 'rm -rf "$repo_dir" "$mock_bin_dir"' RETURN

    install_mock_version_sh  "$repo_dir"
    install_mock_changelog_sh "$repo_dir"
    install_mock_gh           "$mock_bin_dir"

    # Failing pre-commit hook
    mkdir -p "$repo_dir/.git/hooks"
    cat > "$repo_dir/.git/hooks/pre-commit" <<'EOF'
#!/bin/bash
exit 1
EOF
    chmod +x "$repo_dir/.git/hooks/pre-commit"

    # Run pr.sh twice — simulates the original cascading bug scenario
    for run in 1 2; do
        info "  Run #$run..."
        (cd "$repo_dir"; PATH="$mock_bin_dir:$PATH" bash .gitlab/release/pr.sh --no-push 2>&1) || true
    done

    # Check for the cascading bug pattern
    local nested
    nested=$(git -C "$repo_dir" branch | grep "release-please.*release-please" || true)
    local branch_list
    branch_list=$(git -C "$repo_dir" branch)
    info "  Branches after two runs:"
    echo "$branch_list" | sed 's/^/    /'

    if [[ -z "$nested" ]]; then
        pass "No nested branch names after two consecutive failures"
    else
        fail "Cascading bug reproduced: found nested branch names\n$nested"
    fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
main() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "Branch restoration tests for pr.sh"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    test_error_path_restores_branch
    test_success_path_restores_branch
    test_no_nested_branches_after_two_failures

    echo ""
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ $FAILURES -eq 0 ]]; then
        pass "All tests passed"
        exit 0
    else
        echo -e "${RED}[FAIL]${NC} $FAILURES test(s) failed"
        exit 1
    fi
}

main "$@"
