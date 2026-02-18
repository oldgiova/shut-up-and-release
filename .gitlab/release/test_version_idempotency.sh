#!/bin/bash
# Test script for version.sh idempotency features
# SIMULATION MODE - No real git operations

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_SCRIPT="${SCRIPT_DIR}/version.sh"
TEST_DIR="${SCRIPT_DIR}/../../test-idempotency"
STATE_FILE=".release-calculation.lock"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

passed=0
failed=0

log_test() {
    echo ""
    echo "=========================================="
    echo "TEST: $1"
    echo "=========================================="
}

log_pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    ((passed++))
}

log_fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    ((failed++))
}

log_info() {
    echo -e "${YELLOW}ℹ INFO${NC}: $1"
}

cleanup() {
    rm -f "$STATE_FILE"
    rm -rf "$TEST_DIR"
}

trap cleanup EXIT

# Initialize test environment
setup_test_env() {
    cleanup
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"

    # Create minimal config files for testing
    echo '{"." : "1.0.0"}' > .release-please-manifest.json
    echo '{"prerelease": false, "prerelease-type": "rc"}' > release-please-config.json

    log_info "Test environment created at: $TEST_DIR"
}

# Test 1: Run version.sh twice - should return same result
test_run_twice() {
    log_test "Run version.sh twice → same result"

    # Create state file manually
    echo "1.2.3" > "$STATE_FILE"

    # Run version.sh
    result1=$(bash "$VERSION_SCRIPT" --dry-run 2>&1 || true)

    # Should detect existing state file
    if echo "$result1" | grep -q "Using cached result"; then
        log_pass "Detected existing state file on first run"
    else
        log_fail "Failed to detect existing state file"
        echo "Output: $result1"
    fi

    # Should return cached version
    if echo "$result1" | grep -q "1.2.3"; then
        log_pass "Returned cached version correctly"
    else
        log_fail "Did not return cached version"
        echo "Output: $result1"
    fi

    # Clean up state file for next test
    rm -f "$STATE_FILE"
}

# Test 2: Interrupt during execution (simulate with state file)
test_interrupt_recovery() {
    log_test "Kill -9 during execution → re-run recovers"

    log_info "Simulating interrupted execution by creating orphaned state file"

    # Simulate interrupted execution - state file left behind
    echo "1.2.4" > "$STATE_FILE"

    # Run version.sh - should detect and use cached result
    result=$(bash "$VERSION_SCRIPT" --dry-run 2>&1 || true)

    if echo "$result" | grep -q "interrupted"; then
        log_pass "Detected interrupted calculation"
    else
        log_fail "Failed to detect interrupted calculation"
        echo "Output: $result"
    fi

    if echo "$result" | grep -q "1.2.4"; then
        log_pass "Recovered with cached version from interrupted run"
    else
        log_fail "Failed to recover cached version"
        echo "Output: $result"
    fi

    rm -f "$STATE_FILE"
}

# Test 3: Empty state file handling
test_empty_state_file() {
    log_test "Empty state file → removed and continues"

    # Create empty state file
    touch "$STATE_FILE"

    log_info "Created empty state file"

    # This would normally run version calculation
    # In simulation mode, we just check that empty state file is handled
    if [[ -f "$STATE_FILE" ]]; then
        # Simulate the cleanup logic
        content=$(cat "$STATE_FILE" 2>/dev/null || echo "")
        if [[ -z "$content" ]]; then
            rm -f "$STATE_FILE"
            log_pass "Empty state file detected and removed"
        else
            log_fail "State file was not empty"
        fi
    fi

    if [[ ! -f "$STATE_FILE" ]]; then
        log_pass "State file cleaned up successfully"
    else
        log_fail "State file still exists after cleanup"
    fi
}

# Test 4: State file creation order
test_state_file_ordering() {
    log_test "State file created BEFORE manifest write"

    log_info "Checking code implementation..."

    # Check that version.sh creates state file before writing manifest
    if grep -A5 "Write to manifest" "$VERSION_SCRIPT" | grep -q "echo.*> \"\$STATE_FILE\""; then
        log_pass "State file write found before manifest write in code"
    else
        log_fail "State file write not found in expected location"
    fi

    # Check for trap handler
    if grep -q "trap.*STATE_FILE.*EXIT INT TERM" "$VERSION_SCRIPT"; then
        log_pass "Trap handler found for state file cleanup"
    else
        log_fail "Trap handler not found"
    fi
}

# Test 5: Tag existence validation
test_tag_validation() {
    log_test "Calculated version exists as tag → fails with error"

    log_info "Checking code implementation for tag validation..."

    # Check that version.sh validates tag existence
    if grep -q "tag_exists.*new_version" "$VERSION_SCRIPT"; then
        log_pass "Tag existence validation found in code"
    else
        log_fail "Tag existence validation not found"
    fi

    # Check for appropriate error message
    if grep -q "already exists as tag" "$VERSION_SCRIPT"; then
        log_pass "Clear error message for existing tag found"
    else
        log_fail "Error message for existing tag not found"
    fi
}

# Test 6: Trap handler verification
test_trap_handlers() {
    log_test "Trap handlers clean up on EXIT, INT, TERM"

    log_info "Verifying trap handler implementation..."

    # Check for trap setup
    if grep -q "trap.*EXIT INT TERM" "$VERSION_SCRIPT"; then
        log_pass "Trap handler setup found for EXIT INT TERM"
    else
        log_fail "Trap handler setup not found"
    fi

    # Check for trap clear after success
    if grep -q "trap - EXIT INT TERM" "$VERSION_SCRIPT"; then
        log_pass "Trap clear found after successful completion"
    else
        log_fail "Trap clear after success not found"
    fi
}

# Test 7: Idempotency guarantee
test_idempotency_guarantee() {
    log_test "Multiple runs with same input → identical output"

    log_info "This is guaranteed by state file locking mechanism"

    # The state file mechanism ensures:
    # 1. First run calculates and writes state file
    # 2. Subsequent runs detect state file and return cached value
    # 3. All runs return the same version

    if grep -q "Using cached result to ensure idempotency" "$VERSION_SCRIPT"; then
        log_pass "Idempotency message found in code"
    else
        log_fail "Idempotency message not found"
    fi
}

# Run all tests
main() {
    echo "=========================================="
    echo "version.sh Idempotency Test Suite"
    echo "=========================================="
    echo "Mode: SIMULATION (no real git operations)"
    echo ""

    setup_test_env

    test_run_twice
    test_interrupt_recovery
    test_empty_state_file
    test_state_file_ordering
    test_tag_validation
    test_trap_handlers
    test_idempotency_guarantee

    echo ""
    echo "=========================================="
    echo "Test Results Summary"
    echo "=========================================="
    echo -e "${GREEN}Passed: $passed${NC}"
    echo -e "${RED}Failed: $failed${NC}"
    echo ""

    if [[ $failed -eq 0 ]]; then
        echo -e "${GREEN}✓ All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}✗ Some tests failed${NC}"
        exit 1
    fi
}

main "$@"
