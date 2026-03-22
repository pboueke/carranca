#!/usr/bin/env bash
# Test runner for carranca
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

run_suite() {
  local suite="$1"
  local dir="$2"

  echo ""
  echo "━━━ $suite ━━━"

  for test_file in "$dir"/test_*.sh; do
    [ -f "$test_file" ] || continue
    echo ""
    if bash "$test_file"; then
      TOTAL_PASS=$((TOTAL_PASS + 1))
    else
      TOTAL_FAIL=$((TOTAL_FAIL + 1))
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
  TOTAL_SKIP=$((TOTAL_SKIP + 1))
  echo ""
  echo "━━━ Failure Mode Tests ━━━"
  echo "  SKIP: Docker not available"
  TOTAL_SKIP=$((TOTAL_SKIP + 1))
fi

echo ""
echo "╔══════════════════════════════════╗"
echo "║   Results                        ║"
echo "║   Suites passed: $TOTAL_PASS"
echo "║   Suites failed: $TOTAL_FAIL"
echo "║   Suites skipped: $TOTAL_SKIP"
echo "╚══════════════════════════════════╝"

[ "$TOTAL_FAIL" -eq 0 ] || exit 1
