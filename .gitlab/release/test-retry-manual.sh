#!/bin/bash
# Manual test for retry logic (Task #18)
# This is a simplified test that demonstrates retry functionality

export GITHUB_REPO_URL="test/repo"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "${SCRIPT_DIR}/common.sh"

echo "======================================"
echo "Manual Retry Logic Test"
echo "======================================"
echo ""

# Test 1: Mock gh that fails twice then succeeds
echo "Test 1: gh command that fails twice then succeeds"
echo "--------------------------------------"

# Create a counter file
COUNTER_FILE="/tmp/retry_test_$$"
echo "0" > "$COUNTER_FILE"

# Mock gh command
gh() {
    local count=$(cat "$COUNTER_FILE")
    ((count++))
    echo "$count" > "$COUNTER_FILE"

    echo "  → Attempt $count"

    if [ $count -le 2 ]; then
        echo "  ✗ Failed (simulated network error)"
        return 1
    else
        echo "  ✓ Success!"
        return 0
    fi
}

# Run retry_gh
echo ""
echo "Running: retry_gh pr list"
echo ""

if retry_gh pr list 2>&1 | sed 's/^/  /'; then
    attempts=$(cat "$COUNTER_FILE")
    echo ""
    echo "Result: Success after $attempts attempts"
    if [ "$attempts" -eq 3 ]; then
        echo "✓ PASS: Correct number of attempts"
    else
        echo "✗ FAIL: Expected 3 attempts, got $attempts"
    fi
else
    echo "✗ FAIL: Command failed when it should have succeeded"
fi

rm -f "$COUNTER_FILE"
unset -f gh

echo ""
echo "======================================"

# Test 2: Mock git that always fails
echo "Test 2: git command that always fails (max retries)"
echo "--------------------------------------"

COUNTER_FILE="/tmp/retry_test_$$"
echo "0" > "$COUNTER_FILE"

# Mock git command that always fails
git() {
    local count=$(cat "$COUNTER_FILE")
    ((count++))
    echo "$count" > "$COUNTER_FILE"

    echo "  → Attempt $count"
    echo "  ✗ Failed (simulated network error)"
    return 1
}

echo ""
echo "Running: retry_git push origin main"
echo ""

if retry_git push origin main 2>&1 | sed 's/^/  /'; then
    echo "✗ FAIL: Command succeeded when it should have failed"
else
    attempts=$(cat "$COUNTER_FILE")
    echo ""
    echo "Result: Failed after $attempts attempts"
    if [ "$attempts" -eq 3 ]; then
        echo "✓ PASS: Correct number of attempts (3 max retries)"
    else
        echo "✗ FAIL: Expected 3 attempts, got $attempts"
    fi
fi

rm -f "$COUNTER_FILE"
unset -f git

echo ""
echo "======================================"
echo "Manual Test Complete"
echo "======================================"
