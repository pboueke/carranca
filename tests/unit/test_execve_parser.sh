#!/usr/bin/env bash
# Unit tests for _strace_to_event parser from runtime/logger.sh
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
  if echo "$haystack" | grep -Fq "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if ! echo "$haystack" | grep -Fq "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected NOT to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== test_execve_parser.sh ==="

TMPDIR="$(mktemp -d)"
LOG_FILE="$TMPDIR/test.jsonl"

# Stub write_log to just append to log file
write_log() {
  printf '%s\n' "$1" >> "$LOG_FILE"
}

# Stub timestamp to return a fixed value
timestamp() {
  printf '2026-01-15T12:00:00Z'
}

SESSION_ID="test-session-123"

# Source the shared strace parser
STRACE_EVENT_SOURCE="strace"
STRACE_WRITE_FIFO=""
source "$SCRIPT_DIR/runtime/lib/strace-parser.sh"

# _strace_to_event is the legacy wrapper name
_strace_to_event() {
  strace_line_to_event "$1"
}

# --- Test: strace line with pid prefix ---

echo ""
echo "--- Test: parse execve with [pid N] prefix ---"
> "$LOG_FILE"
_strace_to_event '[pid 42] execve("/usr/bin/npm", ["npm", "test"], 0x7fff /* 30 vars */) = 0'
OUTPUT="$(cat "$LOG_FILE")"
assert_contains "contains type execve_event" '"type":"execve_event"' "$OUTPUT"
assert_contains "contains source strace" '"source":"strace"' "$OUTPUT"
assert_contains "contains pid 42" '"pid":42' "$OUTPUT"
assert_contains "contains binary /usr/bin/npm" '"binary":"/usr/bin/npm"' "$OUTPUT"
assert_contains "contains argv with npm" '"npm", "test"' "$OUTPUT"
assert_contains "contains session_id" '"session_id":"test-session-123"' "$OUTPUT"
assert_contains "contains timestamp" '"ts":"2026-01-15T12:00:00Z"' "$OUTPUT"

# --- Test: strace line without pid prefix ---

echo ""
echo "--- Test: parse execve without pid prefix ---"
> "$LOG_FILE"
_strace_to_event 'execve("/bin/sh", ["/bin/sh", "-c", "echo hello"], 0x7fff /* 20 vars */) = 0'
OUTPUT="$(cat "$LOG_FILE")"
assert_contains "contains type execve_event" '"type":"execve_event"' "$OUTPUT"
assert_contains "default pid is 0" '"pid":0' "$OUTPUT"
assert_contains "contains binary /bin/sh" '"binary":"/bin/sh"' "$OUTPUT"
assert_contains "contains argv with sh" '"/bin/sh", "-c", "echo hello"' "$OUTPUT"

# --- Test: execve with error return (ENOENT) ---

echo ""
echo "--- Test: parse execve with ENOENT ---"
> "$LOG_FILE"
_strace_to_event '[pid 99] execve("/usr/bin/git", ["git", "status"], 0x7fff /* 25 vars */) = -1 ENOENT'
OUTPUT="$(cat "$LOG_FILE")"
assert_contains "contains pid 99" '"pid":99' "$OUTPUT"
assert_contains "contains binary /usr/bin/git" '"binary":"/usr/bin/git"' "$OUTPUT"
assert_contains "contains argv with git" '"git", "status"' "$OUTPUT"

# --- Test: non-execve lines are skipped ---

echo ""
echo "--- Test: skip non-execve lines ---"
> "$LOG_FILE"
_strace_to_event '--- SIGCHLD {si_signo=SIGCHLD, si_code=CLD_EXITED} ---'
_strace_to_event '+++ exited with 0 +++'
_strace_to_event '[pid 50] read(3, "", 4096) = 0'
_strace_to_event ''
OUTPUT="$(cat "$LOG_FILE" 2>/dev/null || true)"
assert_eq "no output for non-execve lines" "" "$OUTPUT"

# --- Cleanup ---

rm -rf "$TMPDIR"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
