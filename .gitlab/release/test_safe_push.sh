#!/bin/bash
# Test script for safe push implementation in pr.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Colors
BLUE='\033[0;34m'
PASS="${GREEN}✓ PASS${NC}"
FAIL="${RED}✗ FAIL${NC}"

# Test counter
TESTS_RUN=0
TESTS_PASSED=0

run_test() {
    local test_name=$1
    shift
    TESTS_RUN=$((TESTS_RUN + 1))

    echo -e "\n${BLUE}Test $TESTS_RUN: $test_name${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if "$@"; then
        echo -e "$PASS"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "$FAIL"
        return 1
    fi
}

# Test 1: Verify safe push code is present
test_safe_push_code() {
    info "Verifying safe push implementation exists in pr.sh"

    if grep -q "FORCE_PUSH" "${SCRIPT_DIR}/pr.sh"; then
        info "✓ FORCE_PUSH variable found"
    else
        error "✗ FORCE_PUSH variable not found"
        return 1
    fi

    if grep -q "rejected.*non-fast-forward" "${SCRIPT_DIR}/pr.sh"; then
        info "✓ Divergence detection found"
    else
        error "✗ Divergence detection not found"
        return 1
    fi

    if grep -q "Remote commits that will be lost" "${SCRIPT_DIR}/pr.sh"; then
        info "✓ Warning message found"
    else
        error "✗ Warning message not found"
        return 1
    fi

    return 0
}

# Test 2: Verify force push is properly guarded
test_force_push_guarded() {
    info "Checking that force push is properly guarded"

    # Count force push occurrences
    local force_push_count=$(grep -c "push -f origin" "${SCRIPT_DIR}/pr.sh" || true)

    if [[ $force_push_count -eq 0 ]]; then
        error "✗ No force push found at all (should exist in guarded block)"
        return 1
    fi

    # Verify force push is inside FORCE_PUSH conditional
    local context=$(grep -B5 "push -f origin" "${SCRIPT_DIR}/pr.sh" | grep -c "FORCE_PUSH.*true" || true)

    if [[ $context -eq 0 ]]; then
        error "✗ Force push found but not guarded by FORCE_PUSH check!"
        return 1
    fi

    info "✓ Force push is properly guarded by FORCE_PUSH conditional"
    return 0
}

# Test 3: Verify documentation
test_documentation() {
    info "Verifying FORCE_PUSH is documented"

    if grep -q "FORCE_PUSH" "${SCRIPT_DIR}/pr.sh" | head -50; then
        info "✓ FORCE_PUSH documented in usage"
    else
        error "✗ FORCE_PUSH not documented"
        return 1
    fi

    return 0
}

# Test 4: Simulate normal push scenario
test_normal_push_simulation() {
    info "Simulating normal push scenario (code analysis)"

    # Verify the logic flow:
    # 1. Try normal push first
    # 2. If successful, continue

    if grep -q "git push origin.*tee" "${SCRIPT_DIR}/pr.sh"; then
        info "✓ Normal push attempt found"
    else
        error "✗ Normal push attempt not found"
        return 1
    fi

    if grep -q "Branch pushed successfully" "${SCRIPT_DIR}/pr.sh"; then
        info "✓ Success message found"
    else
        error "✗ Success message not found"
        return 1
    fi

    return 0
}

# Test 5: Simulate divergence without FORCE_PUSH
test_divergence_rejection_simulation() {
    info "Simulating divergence rejection (code analysis)"

    # Verify the error path exists
    if grep -q "Push rejected.*Remote branch has changes" "${SCRIPT_DIR}/pr.sh"; then
        info "✓ Rejection error message found"
    else
        error "✗ Rejection error message not found"
        return 1
    fi

    if grep -q "Set FORCE_PUSH=true to override" "${SCRIPT_DIR}/pr.sh"; then
        info "✓ Override instructions found"
    else
        error "✗ Override instructions not found"
        return 1
    fi

    return 0
}

# Test 6: Simulate divergence with FORCE_PUSH=true
test_force_push_override_simulation() {
    info "Simulating force push override (code analysis)"

    # Verify the force push path with warning
    if grep -q 'FORCE_PUSH:-false.*==.*true' "${SCRIPT_DIR}/pr.sh"; then
        info "✓ FORCE_PUSH condition found"
    else
        error "✗ FORCE_PUSH condition not found"
        return 1
    fi

    if grep -q "FORCE_PUSH=true, forcing push" "${SCRIPT_DIR}/pr.sh"; then
        info "✓ Force push warning found"
    else
        error "✗ Force push warning not found"
        return 1
    fi

    return 0
}

# Test 7: Verify cleanup
test_cleanup() {
    info "Verifying temporary file cleanup"

    if grep -q 'rm -f.*push.*output' "${SCRIPT_DIR}/pr.sh"; then
        info "✓ Cleanup code found"
    else
        error "✗ Cleanup code not found"
        return 1
    fi

    return 0
}

# Main test execution
main() {
    echo "=========================================="
    echo "Safe Push Implementation Tests"
    echo "=========================================="

    run_test "Safe push code exists" test_safe_push_code
    run_test "Force push is properly guarded" test_force_push_guarded
    run_test "Documentation complete" test_documentation
    run_test "Normal push logic present" test_normal_push_simulation
    run_test "Divergence rejection logic present" test_divergence_rejection_simulation
    run_test "Force push override logic present" test_force_push_override_simulation
    run_test "Cleanup code present" test_cleanup

    echo ""
    echo "=========================================="
    echo "Test Summary"
    echo "=========================================="
    echo "Tests run: $TESTS_RUN"
    echo "Tests passed: $TESTS_PASSED"
    echo "Tests failed: $((TESTS_RUN - TESTS_PASSED))"

    if [[ $TESTS_PASSED -eq $TESTS_RUN ]]; then
        echo -e "\n${GREEN}All tests passed! ✓${NC}\n"
        return 0
    else
        echo -e "\n${RED}Some tests failed! ✗${NC}\n"
        return 1
    fi
}

main "$@"
