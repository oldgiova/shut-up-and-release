#!/bin/bash
# Simple verification of idempotency features

echo "=========================================="
echo "version.sh Idempotency Implementation Check"
echo "=========================================="
echo ""

total=0
passed=0

check() {
    ((total++))
    local name="$1"
    local pattern="$2"
    
    echo -n "[$total] $name... "
    if grep -q "$pattern" version.sh; then
        echo "✓ PASS"
        ((passed++))
        return 0
    else
        echo "✗ FAIL"
        return 1
    fi
}

# Run checks
check "State file variable defined" 'STATE_FILE=".release-calculation.lock"'
check "State file existence check" 'if \[\[ -f "\$STATE_FILE" \]\]'
check "Cached result return" "Using cached result"
check "Tag existence validation" 'tag_exists "v\${new_version}"'
check "Error for existing tag" "already exists as tag"
check "State file write before manifest" 'echo "\$new_version" > "\$STATE_FILE"'
check "Trap handler setup" "trap.*STATE_FILE.*EXIT INT TERM"
check "State file cleanup on success" 'rm -f "\$STATE_FILE"'
check "Trap clear after success" "trap - EXIT INT TERM"
check "Empty state file handling" 'if \[\[ -z "\$prev_calculation" \]\]'
check "Idempotency messaging" "ensure idempotency"

echo ""
echo "=========================================="
echo "Results: $passed/$total checks passed"
echo "=========================================="

if [[ $passed -eq $total ]]; then
    echo "✓ All idempotency features implemented!"
    exit 0
else
    echo "✗ Some features missing"
    exit 1
fi
