#!/usr/bin/env bash
# Unit tests for cli/lib/identity.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/cli/lib/common.sh"
source "$SCRIPT_DIR/cli/lib/identity.sh"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

assert_match() {
  local desc="$1" pattern="$2" actual="$3"
  if [[ "$actual" =~ $pattern ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected match '$pattern', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== test_identity.sh ==="

# Test repo_id produces 12 hex chars
TMPDIR_A="$(mktemp -d)"
cd "$TMPDIR_A"
git init --quiet
id_a="$(carranca_repo_id)"
assert_eq "repo_id length is 12" "12" "${#id_a}"
assert_match "repo_id is hex chars" "^[0-9a-f]{12}$" "$id_a"

# Test different paths produce different IDs (no remote, uses path hash)
TMPDIR_B="$(mktemp -d)"
cd "$TMPDIR_B"
git init --quiet
id_b="$(carranca_repo_id)"
if [ "$id_a" != "$id_b" ]; then
  echo "  PASS: different paths produce different repo_ids"
  PASS=$((PASS + 1))
else
  echo "  FAIL: different paths produced same repo_id"
  FAIL=$((FAIL + 1))
fi

# Test repo_id with git remote uses remote URL
cd "$TMPDIR_A"
git remote add origin "https://github.com/test/my-repo.git" 2>/dev/null || true
id_with_remote="$(carranca_repo_id)"
assert_eq "repo_id with remote is 12 chars" "12" "${#id_with_remote}"

# Verify same remote URL in different dir gives same ID
cd "$TMPDIR_B"
git remote add origin "https://github.com/test/my-repo.git" 2>/dev/null || true
id_same_remote="$(carranca_repo_id)"
assert_eq "same remote URL gives same repo_id" "$id_with_remote" "$id_same_remote"

# Test repo_name
cd "$TMPDIR_A"
name="$(carranca_repo_name)"
expected_name="$(basename "$TMPDIR_A")"
assert_eq "repo_name matches directory basename" "$expected_name" "$name"

# Cleanup
rm -rf "$TMPDIR_A" "$TMPDIR_B"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
