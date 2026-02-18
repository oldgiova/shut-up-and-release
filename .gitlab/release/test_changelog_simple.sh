#!/bin/bash
# Simplified test for changelog logic

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# Source functions (disable errexit temporarily)
set +e
source .gitlab/release/common.sh
set -e

echo "Testing changelog functions..."
echo ""

# Test 1: determine_changelog_files for RC
echo "Test 1: RC on 5.0.x branch"
# Override current_branch function for testing
current_branch() { echo "5.0.x"; }

# Source changelog.sh to get the new functions (avoid running main)
_SKIP_MAIN_EXECUTION=1
source .gitlab/release/changelog.sh

result=$(determine_changelog_files "5.0.0-rc.1")
echo "  Result: '$result'"
echo "  Expected: '-rc'"
if [[ "$result" == "-rc" ]]; then
    echo "  ✓ PASS"
else
    echo "  ✗ FAIL"
fi
echo ""

# Test 2: determine_changelog_files for stable on maintenance branch
echo "Test 2: Stable on 5.0.x branch"
result=$(determine_changelog_files "5.0.0")
echo "  Result: '$result'"
echo "  Expected: '-enterprise'"
if [[ "$result" == "-enterprise" ]]; then
    echo "  ✓ PASS"
else
    echo "  ✗ FAIL"
fi
echo ""

# Test 3: find_stable_reference_tag for v10.0.0
echo "Test 3: Reference tag for v10.0.0 on 10.0.x"
current_branch() { echo "10.0.x"; }
ref_tag=$(find_stable_reference_tag "10.0.0" "10.0.x")
echo "  Result: '$ref_tag'"
echo "  Should be a stable tag (not rc/saas)"
if [[ -n "$ref_tag" ]] && [[ "$ref_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "  ✓ PASS - Found stable tag: $ref_tag"
else
    echo "  ✗ FAIL - Invalid or missing tag: ${ref_tag:-<none>}"
fi
echo ""

# Test 4: determine_changelog_files for saas
echo "Test 4: SaaS on main branch"
current_branch() { echo "main"; }
result=$(determine_changelog_files "4.10.0-saas.1")
echo "  Result: '$result'"
echo "  Expected: '-saas'"
if [[ "$result" == "-saas" ]]; then
    echo "  ✓ PASS"
else
    echo "  ✗ FAIL"
fi
echo ""

# Test 5: determine_changelog_files for stable on main (open source)
echo "Test 5: Stable on main (open source)"
export GITHUB_REPO_URL="mendersoftware/mender-server"
result=$(determine_changelog_files "4.10.0")
echo "  Result: '$result'"
echo "  Expected: '' (empty)"
if [[ "$result" == "" ]]; then
    echo "  ✓ PASS"
else
    echo "  ✗ FAIL"
fi
echo ""

echo "All tests complete!"
