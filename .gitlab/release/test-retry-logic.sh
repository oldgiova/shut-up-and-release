#!/bin/bash
# Test script for retry logic (Task #18)
#
# This script verifies that:
# 1. Retry functions execute the expected number of attempts (3)
# 2. Exponential backoff works correctly (2s, 4s, 8s)
# 3. Success on retry stops further attempts
# 4. Final failure after max attempts

set -eo pipefail

# Set dummy GITHUB_REPO_URL for testing (common.sh requires it)
export GITHUB_REPO_URL="mendersoftware/test-repo"

# Get script directory (simplified to avoid shell environment issues)
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
source "${SCRIPT_DIR}/common.sh"

# Colors
PASS='\033[0;32m'
FAIL='\033[0;31m'
INFO='\033[0;34m'
NC='\033[0m'

test_count=0
pass_count=0
fail_count=0

# Test helper functions
test_start() {
    ((test_count++))
    echo -e "\n${INFO}[TEST $test_count]${NC} $*"
}

test_pass() {
    ((pass_count++))
    echo -e "${PASS}✓ PASS${NC}"
}

test_fail() {
    ((fail_count++))
    echo -e "${FAIL}✗ FAIL${NC} $*"
}

# Mock gh command that fails N times then succeeds
mock_gh_fail_then_succeed() {
    local fail_count=$1
    local attempt_file="/tmp/gh_attempt_count_$$"

    # Initialize counter
    echo "0" > "$attempt_file"

    # Create mock gh script
    cat > /tmp/mock_gh_$$ << 'EOF'
#!/bin/bash
attempt_file="$1"
shift
fail_count="$1"
shift

# Increment attempt counter
current=$(cat "$attempt_file")
((current++))
echo "$current" > "$attempt_file"

# Fail if we haven't reached success threshold
if [ $current -le $fail_count ]; then
    echo "gh: API error (attempt $current)" >&2
    exit 1
fi

# Success!
echo "gh: success (attempt $current)"
exit 0
EOF
    chmod +x /tmp/mock_gh_$$

    echo "$attempt_file"
}

# Mock git command that always fails
mock_git_always_fail() {
    cat > /tmp/mock_git_fail_$$ << 'EOF'
#!/bin/bash
echo "git: network error" >&2
exit 1
EOF
    chmod +x /tmp/mock_git_fail_$$
}

# Test 1: Successful operation on first try (no retry)
test_1_no_retry_needed() {
    test_start "No retry needed (success on first attempt)"

    local attempt_file=$(mock_gh_fail_then_succeed 0)

    # Override gh command
    gh() {
        /tmp/mock_gh_$$ "$attempt_file" 0 "$@"
    }

    # Run retry_gh
    if retry_gh pr list &>/dev/null; then
        local attempts=$(cat "$attempt_file")
        if [ "$attempts" -eq 1 ]; then
            test_pass
        else
            test_fail "Expected 1 attempt, got $attempts"
        fi
    else
        test_fail "Command should have succeeded"
    fi

    rm -f "$attempt_file" /tmp/mock_gh_$$
    unset -f gh
}

# Test 2: Success on second attempt (1 retry)
test_2_success_on_retry() {
    test_start "Success on second attempt (1 retry)"

    local attempt_file=$(mock_gh_fail_then_succeed 1)

    # Override gh command
    gh() {
        /tmp/mock_gh_$$ "$attempt_file" 1 "$@"
    }

    # Capture timing
    local start_time=$(date +%s)

    # Run retry_gh
    if retry_gh pr list &>/dev/null; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local attempts=$(cat "$attempt_file")

        # Should be 2 attempts (1 retry) with ~2s delay
        if [ "$attempts" -eq 2 ] && [ "$duration" -ge 1 ] && [ "$duration" -le 4 ]; then
            test_pass
        else
            test_fail "Expected 2 attempts with ~2s delay, got $attempts attempts in ${duration}s"
        fi
    else
        test_fail "Command should have succeeded on retry"
    fi

    rm -f "$attempt_file" /tmp/mock_gh_$$
    unset -f gh
}

# Test 3: Success on third attempt (2 retries)
test_3_success_on_final_retry() {
    test_start "Success on third attempt (2 retries with exponential backoff)"

    local attempt_file=$(mock_gh_fail_then_succeed 2)

    # Override gh command
    gh() {
        /tmp/mock_gh_$$ "$attempt_file" 2 "$@"
    }

    # Capture timing
    local start_time=$(date +%s)

    # Run retry_gh
    if retry_gh pr list &>/dev/null; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local attempts=$(cat "$attempt_file")

        # Should be 3 attempts (2 retries) with 2s + 4s = 6s total delay
        if [ "$attempts" -eq 3 ] && [ "$duration" -ge 5 ] && [ "$duration" -le 8 ]; then
            test_pass
        else
            test_fail "Expected 3 attempts with ~6s delay, got $attempts attempts in ${duration}s"
        fi
    else
        test_fail "Command should have succeeded on final retry"
    fi

    rm -f "$attempt_file" /tmp/mock_gh_$$
    unset -f gh
}

# Test 4: Failure after max retries
test_4_final_failure() {
    test_start "Failure after max retries (3 attempts)"

    mock_git_always_fail

    # Override git command
    git() {
        /tmp/mock_git_fail_$$ "$@"
    }

    # Capture stderr
    local stderr_file=$(mktemp)

    # Run retry_git (should fail)
    if retry_git push origin main 2>"$stderr_file"; then
        test_fail "Command should have failed after 3 attempts"
    else
        # Check that error message mentions max attempts
        if grep -q "failed after 3 attempts" "$stderr_file"; then
            test_pass
        else
            test_fail "Error message should mention max attempts"
            cat "$stderr_file"
        fi
    fi

    rm -f "$stderr_file" /tmp/mock_git_fail_$$
    unset -f git
}

# Test 5: Verify exponential backoff timing
test_5_exponential_backoff() {
    test_start "Exponential backoff timing (2s, 4s)"

    local timing_file=$(mktemp)

    # Create mock that records timing
    cat > /tmp/mock_gh_timing_$$ << 'EOF'
#!/bin/bash
timing_file="$1"
shift

# Record timestamp
echo "$(date +%s)" >> "$timing_file"

# Always fail
exit 1
EOF
    chmod +x /tmp/mock_gh_timing_$$

    # Override gh command
    gh() {
        /tmp/mock_gh_timing_$$ "$timing_file" "$@"
    }

    # Run retry_gh (will fail)
    retry_gh pr list &>/dev/null || true

    # Analyze timing
    local timestamps=($(cat "$timing_file"))
    local delay1=$((timestamps[1] - timestamps[0]))
    local delay2=$((timestamps[2] - timestamps[1]))

    # Should be approximately 2s and 4s
    if [ "$delay1" -ge 1 ] && [ "$delay1" -le 3 ] && \
       [ "$delay2" -ge 3 ] && [ "$delay2" -le 6 ]; then
        test_pass
    else
        test_fail "Expected delays ~2s and ~4s, got ${delay1}s and ${delay2}s"
    fi

    rm -f "$timing_file" /tmp/mock_gh_timing_$$
    unset -f gh
}

# Test 6: Verify retry_git works the same way
test_6_retry_git() {
    test_start "retry_git works identically to retry_gh"

    local attempt_file=$(mktemp)
    echo "0" > "$attempt_file"

    # Create mock git that fails once then succeeds
    cat > /tmp/mock_git_$$ << 'EOF'
#!/bin/bash
attempt_file="$1"
shift

current=$(cat "$attempt_file")
((current++))
echo "$current" > "$attempt_file"

if [ $current -eq 1 ]; then
    echo "git: network error" >&2
    exit 1
fi

echo "git: success"
exit 0
EOF
    chmod +x /tmp/mock_git_$$

    # Override git command
    git() {
        /tmp/mock_git_$$ "$attempt_file" "$@"
    }

    # Run retry_git
    if retry_git push origin main &>/dev/null; then
        local attempts=$(cat "$attempt_file")
        if [ "$attempts" -eq 2 ]; then
            test_pass
        else
            test_fail "Expected 2 attempts, got $attempts"
        fi
    else
        test_fail "Command should have succeeded on retry"
    fi

    rm -f "$attempt_file" /tmp/mock_git_$$
    unset -f git
}

# Run all tests
main() {
    echo "======================================"
    echo "Testing Retry Logic (Task #18)"
    echo "======================================"

    test_1_no_retry_needed
    test_2_success_on_retry
    test_3_success_on_final_retry
    test_4_final_failure
    test_5_exponential_backoff
    test_6_retry_git

    echo ""
    echo "======================================"
    echo "Test Results"
    echo "======================================"
    echo "Total:  $test_count"
    echo -e "Passed: ${PASS}$pass_count${NC}"
    echo -e "Failed: ${FAIL}$fail_count${NC}"

    if [ $fail_count -eq 0 ]; then
        echo -e "\n${PASS}✓ All tests passed!${NC}"
        exit 0
    else
        echo -e "\n${FAIL}✗ Some tests failed${NC}"
        exit 1
    fi
}

main "$@"
