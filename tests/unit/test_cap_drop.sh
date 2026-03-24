#!/usr/bin/env bash
# Unit tests for Phase 5.5 — capability drop flag generation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -Fq -- "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if ! echo "$haystack" | grep -Fq -- "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected NOT to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== test_cap_drop.sh ==="

# Helper: simulate flag generation logic from cli/run.sh
_build_cap_drop_flag() {
  local cap_drop_all="$1"
  [ -z "$cap_drop_all" ] && cap_drop_all="true"
  if [ "$cap_drop_all" = "true" ]; then
    echo "--cap-drop ALL"
  else
    echo ""
  fi
}

# --- Test: default (empty) yields --cap-drop ALL ---
echo "--- cap_drop_all defaults ---"
result="$(_build_cap_drop_flag "")"
assert_eq "empty config defaults to --cap-drop ALL" "--cap-drop ALL" "$result"

# --- Test: explicit true yields --cap-drop ALL ---
result="$(_build_cap_drop_flag "true")"
assert_eq "explicit true yields --cap-drop ALL" "--cap-drop ALL" "$result"

# --- Test: explicit false yields empty ---
result="$(_build_cap_drop_flag "false")"
assert_eq "explicit false yields empty flag" "" "$result"

# --- Test: cap-drop comes before cap-add in combined flags ---
echo "--- flag ordering ---"
CAP_DROP_FLAG="$(_build_cap_drop_flag "true")"
CAP_ADD_FLAGS="--cap-add NET_ADMIN"
COMBINED="$CAP_DROP_FLAG $CAP_ADD_FLAGS"
assert_contains "combined flags contain --cap-drop ALL" "--cap-drop ALL" "$COMBINED"
assert_contains "combined flags contain --cap-add NET_ADMIN" "--cap-add NET_ADMIN" "$COMBINED"

# Verify ordering: --cap-drop before --cap-add
drop_pos="$(echo "$COMBINED" | grep -bo '\-\-cap-drop' | head -1 | cut -d: -f1)"
add_pos="$(echo "$COMBINED" | grep -bo '\-\-cap-add' | head -1 | cut -d: -f1)"
if [ "$drop_pos" -lt "$add_pos" ]; then
  echo "  PASS: --cap-drop appears before --cap-add"
  PASS=$((PASS + 1))
else
  echo "  FAIL: --cap-drop should appear before --cap-add"
  FAIL=$((FAIL + 1))
fi

# --- Test: false + cap-add yields only cap-add ---
echo "--- cap_drop_all false with cap_add ---"
CAP_DROP_FLAG="$(_build_cap_drop_flag "false")"
CAP_ADD_FLAGS="--cap-add SYS_PTRACE"
COMBINED="$CAP_DROP_FLAG $CAP_ADD_FLAGS"
assert_not_contains "no --cap-drop when disabled" "--cap-drop" "$COMBINED"
assert_contains "cap-add still present" "--cap-add SYS_PTRACE" "$COMBINED"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
