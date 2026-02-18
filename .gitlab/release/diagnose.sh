#!/bin/bash
# Diagnostic script to understand version calculation

# Don't exit on errors - we want to show as much diagnostic info as possible
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

echo "====================================="
echo " VERSION.SH DIAGNOSTIC"
echo "====================================="
echo ""

echo "1. Current state:"
echo "   Branch: $(git rev-parse --abbrev-ref HEAD)"
echo "   Manifest version: $(read_current_version)"
echo "   Prerelease config: $(jq -r '.prerelease // false' "$CONFIG_FILE")"
echo "   Prerelease type: $(jq -r '."prerelease-type" // "rc"' "$CONFIG_FILE")"
echo ""

current=$(read_current_version)
base_ver=$(base_version "$current")

echo "2. Version analysis:"
echo "   Current: $current"
echo "   Base version: $base_ver"
echo "   Is prerelease? $(is_prerelease "$current" && echo "YES" || echo "NO")"
echo ""

echo "3. Tag search:"
echo "   Looking for tags matching: v${base_ver}*"
git tag --list "v${base_ver}*" --sort=-version:refname 2>/dev/null | head -5 | sed 's/^/   - /' || true
echo ""

echo "4. Last tags (all):"
git tag --sort=-version:refname 2>/dev/null | head -10 | sed 's/^/   /' || true
echo ""

echo "5. What git describe finds:"
if is_prerelease "$current"; then
    echo "   (prerelease mode)"
    last_tag=$(git describe --tags --abbrev=0 --match="v${base_ver}*" 2>/dev/null || \
               git describe --tags --abbrev=0 2>/dev/null || \
               echo "(none)")
    echo "   Match v${base_ver}*: $last_tag"
else
    echo "   (stable mode)"
    last_tag=$(git tag --list "v*" --sort=-version:refname 2>/dev/null | \
               grep -v -E "(rc|saas)" | grep -v "^v${current}$" | head -n 1 || echo "(none)")
    echo "   Last stable tag: $last_tag"
fi
echo ""

echo "6. Commits since last tag:"
if [[ "$last_tag" != "(none)" ]]; then
    echo "   Reference: $last_tag"
    echo "   Commits:"
    git log --oneline "${last_tag}..HEAD" 2>/dev/null | head -10 | sed 's/^/   /' || true
    echo ""
    echo "   Breaking changes:"
    git log --oneline "${last_tag}..HEAD" 2>/dev/null | grep -E "(feat!|fix!)" || echo "   (none)"
    echo ""
    echo "   Features:"
    git log --oneline "${last_tag}..HEAD" 2>/dev/null | grep "^[a-f0-9]* feat" || echo "   (none)"
else
    echo "   No reference tag found!"
fi
echo ""

echo "7. Git-cliff test (what it returns):"
echo "   Basic --bumped-version:"
git cliff --bumped-version --use-branch-tags 2>/dev/null || echo "   ERROR"
echo ""

if [[ "$last_tag" != "(none)" ]]; then
    echo "   With --ignore-tags '.*-rc.*':"
    git cliff --bumped-version --ignore-tags '.*-rc.*' --use-branch-tags 2>/dev/null || echo "   ERROR"
    echo ""

    echo "   With --ignore-tags '.*-(rc|saas).*':"
    git cliff --bumped-version --ignore-tags '.*-(rc|saas).*' --use-branch-tags 2>/dev/null || echo "   ERROR"
fi

echo ""
echo "====================================="
echo " EXACT VERSION.SH BEHAVIOR"
echo "====================================="
echo ""

# Simulate what version.sh does
use_prerelease=$(jq -r '.prerelease // false' "$CONFIG_FILE")
prerelease_type=$(jq -r '."prerelease-type" // "rc"' "$CONFIG_FILE")

echo "8. Version.sh parameters:"
echo "   use_prerelease: $use_prerelease"
echo "   prerelease_type: $prerelease_type"
echo ""

# Determine ignore pattern (same logic as version.sh)
ignore_pattern=""
if [[ "$use_prerelease" == "true" ]]; then
    case "$prerelease_type" in
        rc)
            ignore_pattern=".*-saas.*"
            echo "   ignore_pattern: '$ignore_pattern' (ignoring saas tags for RC)"
            ;;
        saas)
            ignore_pattern=".*-rc.*"
            echo "   ignore_pattern: '$ignore_pattern' (ignoring rc tags for saas)"
            ;;
    esac
else
    ignore_pattern=".*-(rc|saas).*"
    echo "   ignore_pattern: '$ignore_pattern' (ignoring all prerelease tags)"
fi
echo ""

# Check for maintenance branch
current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
maintenance_pattern=""
tag_pattern_arg=""

if [[ "$current_branch" =~ ^([0-9]+)\.([0-9]+)\.x$ ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    maintenance_pattern="${major}.${minor}"
    tag_pattern_arg="v${maintenance_pattern}.*"
    echo "   Maintenance branch detected: $current_branch"
    echo "   tag_pattern: '$tag_pattern_arg'"
else
    echo "   Not a maintenance branch"
    echo "   tag_pattern: (none)"
fi
echo ""

echo "9. Exact git-cliff command that version.sh executes:"
echo ""

# Build the command (same as get_bumped_version_from_cliff)
cliff_cmd="git cliff --bumped-version"

if [[ -n "$tag_pattern_arg" ]]; then
    cliff_cmd="$cliff_cmd --tag-pattern '$tag_pattern_arg'"
fi

if [[ -n "$ignore_pattern" ]]; then
    cliff_cmd="$cliff_cmd --ignore-tags '$ignore_pattern'"
fi

cliff_cmd="$cliff_cmd --use-branch-tags"

if [[ "$last_tag" != "(none)" ]]; then
    cliff_cmd="$cliff_cmd ${last_tag}..HEAD"
fi

echo "   Command: $cliff_cmd"
echo ""
echo "   Output:"
result=$(eval $cliff_cmd 2>/dev/null || echo "ERROR")
echo "   $result"
echo ""

if [[ "$result" != "ERROR" ]] && [[ -n "$result" ]]; then
    result_stripped="${result#v}"
    echo "   Stripped version: $result_stripped"

    if [[ "$use_prerelease" == "true" ]]; then
        echo ""
        echo "   In prerelease mode, version.sh would:"
        if [[ "$result_stripped" =~ -(rc|saas) ]]; then
            echo "   - Detect that git-cliff returned a prerelease: $result_stripped"
            echo "   - Use it as-is (no double suffix)"
            echo "   → Final version: $result_stripped"
        else
            echo "   - Detect that git-cliff returned stable version: $result_stripped"
            echo "   - Add prerelease suffix: -${prerelease_type}.1"
            echo "   → Final version: ${result_stripped}-${prerelease_type}.1"
        fi
    else
        echo "   → Final version: $result_stripped (stable mode)"
    fi
fi

echo ""
echo "====================================="
echo " Run version.sh to see actual output"
echo "====================================="

exit 0
