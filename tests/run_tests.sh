#!/usr/bin/env bash
# Test runner for carranca
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_RUNTIME="${CARRANCA_TEST_RUNTIME:-}"
TEST_JOBS="${CARRANCA_TEST_JOBS:-2}"
SUITES_PASS=0
SUITES_FAIL=0
SUITES_SKIP=0

# Count individual PASS/FAIL lines from test output
TESTS_PASS=0
TESTS_FAIL=0

TEST_LOG="$PROJECT_DIR/test.log"
exec > >(tee "$TEST_LOG") 2>&1

_record_suite_output() {
  local output="$1"
  local rc="$2"

  echo "$output"

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
}

run_suite_sequential() {
  local suite="$1"
  local dir="$2"
  local test_file output rc

  echo ""
  echo "━━━ $suite ━━━ ($(date -u '+%Y-%m-%dT%H:%M:%SZ'))"

  for test_file in "$dir"/test_*.sh; do
    [ -f "$test_file" ] || continue
    echo ""
    output="$(bash "$test_file" 2>&1)"
    rc=$?
    _record_suite_output "$output" "$rc"
  done
}

run_suite_parallel() {
  local suite="$1"
  local dir="$2"
  local jobs="$3"
  local tmpdir test_file count slot rc output
  local -a files=()
  local -a pids=()

  echo ""
  echo "━━━ $suite ━━━ ($(date -u '+%Y-%m-%dT%H:%M:%SZ'))"

  for test_file in "$dir"/test_*.sh; do
    [ -f "$test_file" ] || continue
    files+=("$test_file")
  done

  [ "${#files[@]}" -gt 0 ] || return 0

  tmpdir="$(mktemp -d)"

  count=0
  for test_file in "${files[@]}"; do
    slot="$count"
    (
      bash "$test_file" >"$tmpdir/$slot.out" 2>&1
      printf '%s\n' "$?" >"$tmpdir/$slot.rc"
    ) &
    pids+=("$!")
    count=$((count + 1))

    if [ "${#pids[@]}" -ge "$jobs" ]; then
      wait "${pids[0]}"
      pids=("${pids[@]:1}")
    fi
  done

  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  for slot in $(seq 0 $((count - 1))); do
    echo ""
    output="$(cat "$tmpdir/$slot.out")"
    rc="$(cat "$tmpdir/$slot.rc")"
    _record_suite_output "$output" "$rc"
  done

  rm -rf "$tmpdir"
}

run_suite() {
  local suite="$1"
  local dir="$2"
  local mode="${3:-sequential}"

  if [ "$mode" = "parallel" ]; then
    run_suite_parallel "$suite" "$dir" "$TEST_JOBS"
  else
    run_suite_sequential "$suite" "$dir"
  fi
}

echo "╔══════════════════════════════════╗"
echo "║   carranca test suite            ║"
echo "╚══════════════════════════════════╝"
echo "Started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [ -z "$TEST_RUNTIME" ]; then
  if podman info >/dev/null 2>&1; then
    TEST_RUNTIME="podman"
  elif docker info >/dev/null 2>&1; then
    TEST_RUNTIME="docker"
  fi
fi

if [ -n "$TEST_RUNTIME" ]; then
  export CARRANCA_CONTAINER_RUNTIME="$TEST_RUNTIME"
fi

# Unit tests (no Docker required)
run_suite "Unit Tests" "$SCRIPT_DIR/unit"

# Check for a supported container runtime before running integration/failure tests
if [ -n "$TEST_RUNTIME" ]; then
  run_suite "Integration Tests" "$SCRIPT_DIR/integration" parallel
  run_suite "Failure Mode Tests" "$SCRIPT_DIR/failure" parallel
else
  echo ""
  echo "━━━ Integration Tests ━━━"
  echo "  SKIP: Podman or Docker not available"
  SUITES_SKIP=$((SUITES_SKIP + 1))
  echo ""
  echo "━━━ Failure Mode Tests ━━━"
  echo "  SKIP: Podman or Docker not available"
  SUITES_SKIP=$((SUITES_SKIP + 1))
fi

# --- Coverage: count tested vs total shell functions ---

TOTAL_FUNCS=0
TESTED_FUNCS=0

# Collect all function names from source files
for src in "$PROJECT_DIR"/cli/lib/*.sh "$PROJECT_DIR"/runtime/*.sh "$PROJECT_DIR"/runtime/lib/*.sh; do
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

# Build result lines and compute dynamic box width
_result_lines=(
  "  Results"
  "  Tests:    $TESTS_PASS/$TESTS_TOTAL passed"
  "  Suites:   $SUITES_PASS passed, $SUITES_FAIL failed, $SUITES_SKIP skipped"
  "  Coverage: $TESTED_FUNCS/$TOTAL_FUNCS functions ($COVERAGE_PCT%)"
)
_box_width=0
for _line in "${_result_lines[@]}"; do
  _len=${#_line}
  [ "$_len" -gt "$_box_width" ] && _box_width="$_len"
done
_box_width=$((_box_width + 4)) # padding for borders and spacing

_border=""
for (( _i=0; _i<_box_width; _i++ )); do _border+="═"; done

echo "╔${_border}╗"
for _line in "${_result_lines[@]}"; do
  printf '║%-*s║\n' "$_box_width" "$_line"
done
echo "╚${_border}╝"

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
  for src in "$PROJECT_DIR"/cli/lib/*.sh "$PROJECT_DIR"/runtime/*.sh "$PROJECT_DIR"/runtime/lib/*.sh; do
    [ -f "$src" ] || continue
    while IFS= read -r fname; do
      if ! grep -rq "$fname" "$SCRIPT_DIR"/unit/ "$SCRIPT_DIR"/integration/ "$SCRIPT_DIR"/failure/ 2>/dev/null; then
        echo "  - $fname ($(basename "$src"))"
      fi
    done < <(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$src" | sed 's/()//')
  done
  exit 1
fi
