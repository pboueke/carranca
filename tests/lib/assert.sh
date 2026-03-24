#!/usr/bin/env bash
# Shared test assertion library for carranca unit tests.
# Source from any test file:
#   source "$SCRIPT_DIR/../lib/assert.sh"
# (where SCRIPT_DIR points to tests/unit/)
#
# Provides: assert_eq, assert_contains, assert_not_contains, assert_match,
#           assert_exit_code, test_start, print_results, suite_header
# Tracks:   PASS and FAIL counters

PASS=0
FAIL=0

# --- Timing helpers ---

# Portable millisecond timestamp. Falls back to seconds if %3N is unsupported.
_assert_now_ms() {
  local ms
  ms="$(date +%s%3N 2>/dev/null)"
  # If %3N is not expanded (literal "N" in output), fall back to seconds * 1000.
  if [[ "$ms" == *N ]]; then
    echo "$(( $(date +%s) * 1000 ))"
  else
    echo "$ms"
  fi
}

_ASSERT_LAST_TS=""

# Call before an assertion (or group of assertions) to mark the start time.
# If not called, the first assert auto-starts from its own invocation time.
test_start() {
  _ASSERT_LAST_TS="$(_assert_now_ms)"
}

# Returns elapsed ms since last test_start / last assert, then resets the timer.
_assert_elapsed() {
  local now
  now="$(_assert_now_ms)"
  if [ -z "$_ASSERT_LAST_TS" ]; then
    # No explicit test_start; treat duration as 0.
    _ASSERT_LAST_TS="$now"
    echo "0"
  else
    echo "$(( now - _ASSERT_LAST_TS ))"
    _ASSERT_LAST_TS="$now"
  fi
}

# --- Assert functions ---

# assert_eq "description" "expected" "actual"
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  local ms
  ms="$(_assert_elapsed)"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc (${ms}ms)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected '$expected', got '$actual') (${ms}ms)"
    FAIL=$((FAIL + 1))
  fi
}

# assert_contains "description" "needle" "haystack"
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  local ms
  ms="$(_assert_elapsed)"
  if echo "$haystack" | grep -Fq -- "$needle"; then
    echo "  PASS: $desc (${ms}ms)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected to contain '$needle') (${ms}ms)"
    FAIL=$((FAIL + 1))
  fi
}

# assert_not_contains "description" "needle" "haystack"
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  local ms
  ms="$(_assert_elapsed)"
  if ! echo "$haystack" | grep -Fq -- "$needle"; then
    echo "  PASS: $desc (${ms}ms)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected NOT to contain '$needle') (${ms}ms)"
    FAIL=$((FAIL + 1))
  fi
}

# assert_match "description" "pattern" "actual"
assert_match() {
  local desc="$1" pattern="$2" actual="$3"
  local ms
  ms="$(_assert_elapsed)"
  if [[ "$actual" =~ $pattern ]]; then
    echo "  PASS: $desc (${ms}ms)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected match '$pattern', got '$actual') (${ms}ms)"
    FAIL=$((FAIL + 1))
  fi
}

# assert_exit_code "description" "expected_code" "actual_code"
assert_exit_code() {
  local desc="$1" expected="$2" actual="$3"
  local ms
  ms="$(_assert_elapsed)"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc (${ms}ms)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected exit code '$expected', got '$actual') (${ms}ms)"
    FAIL=$((FAIL + 1))
  fi
}

# --- Reporting ---

# suite_header "test_name.sh"
# Prints: === test_name.sh === (2026-03-24T14:30:00Z)
suite_header() {
  local name="$1"
  echo "=== $name === ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
}

# print_results
# Prints: Results: N passed, M failed
# Returns exit code 1 if any test failed.
print_results() {
  echo "Results: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}
