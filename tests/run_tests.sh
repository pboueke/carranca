#!/usr/bin/env bash
# Test runner for carranca
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SUITES_PASS=0
SUITES_FAIL=0
SUITES_SKIP=0

# Count individual PASS/FAIL lines from test output
TESTS_PASS=0
TESTS_FAIL=0

run_suite() {
  local suite="$1"
  local dir="$2"

  echo ""
  echo "━━━ $suite ━━━"

  for test_file in "$dir"/test_*.sh; do
    [ -f "$test_file" ] || continue
    echo ""
    local output
    output="$(bash "$test_file" 2>&1)"
    local rc=$?
    echo "$output"

    # Count individual test results from output
    local p f
    p="$(echo "$output" | grep -c '  PASS:' || true)"
    f="$(echo "$output" | grep -c '  FAIL:' || true)"
    TESTS_PASS=$((TESTS_PASS + p))
    TESTS_FAIL=$((TESTS_FAIL + f))

    if [ "$rc" -eq 0 ]; then
      SUITES_PASS=$((SUITES_PASS + 1))
    else
      SUITES_FAIL=$((SUITES_FAIL + 1))
    fi
  done
}

echo "╔══════════════════════════════════╗"
echo "║   carranca test suite            ║"
echo "╚══════════════════════════════════╝"

# Unit tests (no Docker required)
run_suite "Unit Tests" "$SCRIPT_DIR/unit"

# Check for Docker before running integration/failure tests
if docker info >/dev/null 2>&1; then
  run_suite "Integration Tests" "$SCRIPT_DIR/integration"
  run_suite "Failure Mode Tests" "$SCRIPT_DIR/failure"
else
  echo ""
  echo "━━━ Integration Tests ━━━"
  echo "  SKIP: Docker not available"
  SUITES_SKIP=$((SUITES_SKIP + 1))
  echo ""
  echo "━━━ Failure Mode Tests ━━━"
  echo "  SKIP: Docker not available"
  SUITES_SKIP=$((SUITES_SKIP + 1))
fi

# --- Coverage: count tested vs total shell functions ---

TOTAL_FUNCS=0
TESTED_FUNCS=0

# Collect all function names from source files
for src in "$PROJECT_DIR"/cli/lib/*.sh "$PROJECT_DIR"/runtime/*.sh; do
  [ -f "$src" ] || continue
  while IFS= read -r fname; do
    TOTAL_FUNCS=$((TOTAL_FUNCS + 1))
    # Check if any test file references this function
    if grep -rq "$fname" "$SCRIPT_DIR"/unit/ "$SCRIPT_DIR"/integration/ "$SCRIPT_DIR"/failure/ 2>/dev/null; then
      TESTED_FUNCS=$((TESTED_FUNCS + 1))
    fi
  done < <(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$src" | sed 's/()//')
done

if [ "$TOTAL_FUNCS" -gt 0 ]; then
  COVERAGE_PCT=$((TESTED_FUNCS * 100 / TOTAL_FUNCS))
else
  COVERAGE_PCT=0
fi

TESTS_TOTAL=$((TESTS_PASS + TESTS_FAIL))

echo ""
echo "╔══════════════════════════════════╗"
echo "║   Results                        ║"
echo "║   Tests:  $TESTS_PASS/$TESTS_TOTAL passed"
echo "║   Suites: $SUITES_PASS passed, $SUITES_FAIL failed, $SUITES_SKIP skipped"
echo "║   Coverage: $TESTED_FUNCS/$TOTAL_FUNCS functions ($COVERAGE_PCT%)"
echo "╚══════════════════════════════════╝"

# Write badge data for README consumption
BADGE_DIR="$PROJECT_DIR/tests"
echo "{\"tests_passed\":$TESTS_PASS,\"tests_total\":$TESTS_TOTAL,\"tests_failed\":$TESTS_FAIL,\"coverage_pct\":$COVERAGE_PCT,\"coverage_funcs\":\"$TESTED_FUNCS/$TOTAL_FUNCS\"}" > "$BADGE_DIR/.results.json"

# Fail if any suite failed
if [ "$SUITES_FAIL" -ne 0 ]; then
  echo ""
  echo "FAILED: $SUITES_FAIL suite(s) failed"
  exit 1
fi

# Fail if coverage is not 100%
if [ "$COVERAGE_PCT" -lt 100 ]; then
  echo ""
  echo "FAILED: function coverage is ${COVERAGE_PCT}%, required 100%"
  echo "Untested functions:"
  for src in "$PROJECT_DIR"/cli/lib/*.sh "$PROJECT_DIR"/runtime/*.sh; do
    [ -f "$src" ] || continue
    while IFS= read -r fname; do
      if ! grep -rq "$fname" "$SCRIPT_DIR"/unit/ "$SCRIPT_DIR"/integration/ "$SCRIPT_DIR"/failure/ 2>/dev/null; then
        echo "  - $fname ($(basename "$src"))"
      fi
    done < <(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$src" | sed 's/()//')
  done
  exit 1
fi
