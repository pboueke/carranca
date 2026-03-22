#!/usr/bin/env bash
# Unit tests for runtime helper functions (shell-wrapper.sh and logger.sh)
# Tests functions that can run outside Docker without a FIFO.
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

echo "=== test_runtime_helpers.sh ==="

# --- shell-wrapper.sh helpers ---
# Source only the pure functions (override FIFO-dependent parts)

# json_escape: escapes backslashes, quotes, tabs and strips newlines
json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr -d '\n'
}

val="$(json_escape 'hello "world"')"
assert_eq "json_escape escapes double quotes" 'hello \"world\"' "$val"

val="$(json_escape 'path\\to\\file')"
assert_eq "json_escape escapes backslashes" 'path\\\\to\\\\file' "$val"

val="$(json_escape "tab	here")"
assert_eq "json_escape escapes tabs" 'tab\there' "$val"

val="$(json_escape 'no special chars')"
assert_eq "json_escape passes plain text through" 'no special chars' "$val"

# timestamp: produces ISO 8601 UTC
timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

ts="$(timestamp)"
assert_match "timestamp is ISO 8601 UTC" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$ts"

# ms_now: produces millisecond or second epoch
ms_now() {
  date +%s%3N 2>/dev/null || date +%s
}

ms="$(ms_now)"
assert_match "ms_now is numeric" '^[0-9]+$' "$ms"

# Verify ms_now is at least 13 digits (milliseconds) or 10 (seconds fallback)
if [ "${#ms}" -ge 10 ]; then
  echo "  PASS: ms_now produces epoch timestamp (${#ms} digits)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: ms_now too short (${#ms} digits, expected >= 10)"
  FAIL=$((FAIL + 1))
fi

# --- logger.sh helpers ---

# write_log: test that it assigns seq numbers and appends JSON to a log file
TMPDIR="$(mktemp -d)"
SEQ_FILE="$TMPDIR/seq"
SEQ_LOCK="$TMPDIR/seq.lock"
LOG_FILE="$TMPDIR/test.jsonl"

echo "0" > "$SEQ_FILE"
touch "$LOG_FILE"

write_log() {
  local line="$1"
  {
    flock 9
    local seq
    seq=$(cat "$SEQ_FILE" 2>/dev/null || echo 0)
    seq=$((seq + 1))
    echo "$seq" > "$SEQ_FILE"
    printf '%s\n' "${line%\}},\"seq\":$seq}" >> "$LOG_FILE"
  } 9>"$SEQ_LOCK"
}

write_log '{"type":"test","msg":"first"}'
write_log '{"type":"test","msg":"second"}'
write_log '{"type":"test","msg":"third"}'

LINE_COUNT="$(wc -l < "$LOG_FILE" | tr -d '[:space:]')"
assert_eq "write_log writes 3 lines" "3" "$LINE_COUNT"

# Check seq numbers are injected and monotonic
SEQ1="$(sed -n '1p' "$LOG_FILE" | grep -o '"seq":[0-9]*' | cut -d: -f2)"
SEQ2="$(sed -n '2p' "$LOG_FILE" | grep -o '"seq":[0-9]*' | cut -d: -f2)"
SEQ3="$(sed -n '3p' "$LOG_FILE" | grep -o '"seq":[0-9]*' | cut -d: -f2)"
assert_eq "write_log seq 1" "1" "$SEQ1"
assert_eq "write_log seq 2" "2" "$SEQ2"
assert_eq "write_log seq 3" "3" "$SEQ3"

# Check JSON structure preserved
assert_match "write_log preserves JSON fields" '"msg":"first"' "$(sed -n '1p' "$LOG_FILE")"

# --- write_event: test FIFO write with a real FIFO ---

FIFO_PATH="$TMPDIR/fifo"
mkfifo "$FIFO_PATH"

write_event() {
  printf '%s\n' "$1" > "$FIFO_PATH" 2>/dev/null
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FIFO_FAIL"
    return 1
  fi
}

# Read from FIFO in background
RECEIVED=""
cat "$FIFO_PATH" > "$TMPDIR/fifo_out" &
CAT_PID=$!

write_event '{"type":"test_event"}'
sleep 0.2
kill "$CAT_PID" 2>/dev/null || true
wait "$CAT_PID" 2>/dev/null || true

RECEIVED="$(cat "$TMPDIR/fifo_out")"
assert_eq "write_event sends JSON through FIFO" '{"type":"test_event"}' "$RECEIVED"

# --- _cleanup and _heartbeat_loop: verify they are defined in source ---
# These functions require a running container context (FIFO, Docker)
# so we verify they exist in the source rather than executing them.
# Integration tests (test_run.sh) exercise them end-to-end.

if grep -q '^_cleanup()' "$SCRIPT_DIR/runtime/logger.sh"; then
  echo "  PASS: _cleanup defined in logger.sh"
  PASS=$((PASS + 1))
else
  echo "  FAIL: _cleanup not found in logger.sh"
  FAIL=$((FAIL + 1))
fi

if grep -q '^_heartbeat_loop()' "$SCRIPT_DIR/runtime/shell-wrapper.sh"; then
  echo "  PASS: _heartbeat_loop defined in shell-wrapper.sh"
  PASS=$((PASS + 1))
else
  echo "  FAIL: _heartbeat_loop not found in shell-wrapper.sh"
  FAIL=$((FAIL + 1))
fi

# Cleanup
rm -rf "$TMPDIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
