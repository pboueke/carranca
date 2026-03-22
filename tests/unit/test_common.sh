#!/usr/bin/env bash
# Unit tests for cli/lib/common.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/cli/lib/common.sh"

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

echo "=== test_common.sh ==="

# Test carranca_random_hex produces 8 hex chars
hex="$(carranca_random_hex)"
assert_eq "random_hex length is 8" "8" "${#hex}"
assert_match "random_hex is hex chars" "^[0-9a-f]{8}$" "$hex"

# Test two calls produce different values
hex2="$(carranca_random_hex)"
if [ "$hex" != "$hex2" ]; then
  echo "  PASS: random_hex produces different values"
  PASS=$((PASS + 1))
else
  echo "  FAIL: random_hex produced identical values"
  FAIL=$((FAIL + 1))
fi

# Test carranca_require_cmd with existing command
carranca_require_cmd bash 2>/dev/null
echo "  PASS: require_cmd accepts existing command (bash)"
PASS=$((PASS + 1))

# Test carranca_require_cmd with missing command (run in subshell since die calls exit)
if (carranca_require_cmd nonexistent_cmd_xyz 2>/dev/null); then
  echo "  FAIL: require_cmd should fail for missing command"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: require_cmd rejects missing command"
  PASS=$((PASS + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
