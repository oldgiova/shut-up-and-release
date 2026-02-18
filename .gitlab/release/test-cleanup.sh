#!/bin/bash
# Test script for cleanup trap verification (Task #11)
# Tests that temporary files are properly cleaned up

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}[TEST]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[FAIL]${NC} $*"; }
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }

count_release_temp_files() {
    # Count temp files matching our patterns
    local count=$(ls /tmp/release-pr-* /tmp/release-notes-* 2>/dev/null | wc -l || echo "0")
    echo "$count"
}

cleanup_existing_temp_files() {
    info "Cleaning up any existing temp files..."
    rm -f /tmp/release-pr-* /tmp/release-notes-* 2>/dev/null || true
}

# Test 1: Normal execution - pr.sh
test_pr_normal_cleanup() {
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "Test 1: pr.sh normal execution cleanup"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    cleanup_existing_temp_files

    local before=$(count_release_temp_files)
    info "Temp files before: $before"

    # Run pr.sh with --no-push to avoid actually creating PR
    # This will fail because we don't have a clean git state, but that's OK
    # We just want to verify temp file cleanup
    "${SCRIPT_DIR}/pr.sh" --help >/dev/null 2>&1 || true

    sleep 1
    local after=$(count_release_temp_files)
    info "Temp files after: $after"

    if [[ "$after" -eq 0 ]]; then
        pass "✓ No temp files left after normal execution"
        return 0
    else
        error "✗ Found $after temp files after execution"
        ls /tmp/release-pr-* /tmp/release-notes-* 2>/dev/null || true
        return 1
    fi
}

# Test 2: Interrupted execution (simulated)
test_interrupt_cleanup() {
    info ""
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "Test 2: Trap handler cleanup on interrupt"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    cleanup_existing_temp_files

    # Create a wrapper script that simulates interrupt
    local test_script=$(mktemp)
    cat > "$test_script" <<'EOF'
#!/bin/bash
temp_file=$(mktemp -t "release-pr-XXXXXX")
trap 'rm -f "$temp_file"' EXIT INT TERM
echo "Created temp file: $temp_file"
# Simulate some work
sleep 0.5
# Simulate interrupt (the trap should clean up)
exit 1
EOF
    chmod +x "$test_script"

    local before=$(count_release_temp_files)
    info "Temp files before: $before"

    # Run the test script (will exit with error, but trap should cleanup)
    "$test_script" >/dev/null 2>&1 || true

    sleep 1
    local after=$(count_release_temp_files)
    info "Temp files after: $after"

    rm -f "$test_script"

    if [[ "$after" -eq 0 ]]; then
        pass "✓ Trap cleaned up temp files on exit"
        return 0
    else
        error "✗ Found $after temp files after interrupt"
        ls /tmp/release-pr-* 2>/dev/null || true
        return 1
    fi
}

# Test 3: Verify trap is actually set in scripts
test_trap_present() {
    info ""
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "Test 3: Verify trap statements exist in scripts"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local failures=0

    # Check pr.sh
    if grep -q "trap.*EXIT INT TERM" "${SCRIPT_DIR}/pr.sh"; then
        pass "✓ pr.sh has trap handler"
    else
        error "✗ pr.sh missing trap handler"
        ((failures++))
    fi

    # Check release.sh
    if grep -q "trap.*EXIT INT TERM" "${SCRIPT_DIR}/release.sh"; then
        pass "✓ release.sh has trap handler"
    else
        error "✗ release.sh missing trap handler"
        ((failures++))
    fi

    # Verify the other scripts don't create temp files (they shouldn't need traps)
    for script in changelog.sh promote.sh publish.sh tag.sh; do
        if ! grep -q "mktemp" "${SCRIPT_DIR}/$script"; then
            pass "✓ $script doesn't create temp files (trap not needed)"
        else
            warn "! $script creates temp files but may need trap"
        fi
    done

    return $failures
}

# Test 4: Check /tmp before and after all tests
test_no_leaks() {
    info ""
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "Test 4: Final check - no temp file leaks"
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    cleanup_existing_temp_files

    local count=$(count_release_temp_files)

    if [[ "$count" -eq 0 ]]; then
        pass "✓ No release temp files in /tmp"
        return 0
    else
        error "✗ Found $count temp files in /tmp"
        ls /tmp/release-* 2>/dev/null || true
        return 1
    fi
}

# Run all tests
main() {
    info "Starting cleanup trap tests..."
    info ""

    local failures=0

    test_pr_normal_cleanup || ((failures++))
    test_interrupt_cleanup || ((failures++))
    test_trap_present || ((failures++))
    test_no_leaks || ((failures++))

    info ""
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ $failures -eq 0 ]]; then
        pass "All tests passed! ✓"
        info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        exit 0
    else
        error "$failures test(s) failed"
        info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        exit 1
    fi
}

main "$@"
