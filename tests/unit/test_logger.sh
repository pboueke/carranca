#!/usr/bin/env bash
# Unit tests for runtime/logger.sh internal functions
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

echo "=== test_logger.sh ==="

# We cannot source logger.sh directly (it runs as an entrypoint).
# Instead, extract the functions we need to test and define stubs
# for their dependencies.

TMPDIR="$(mktemp -d)"
LOG_FILE="$TMPDIR/test.jsonl"
SEQ_FILE="$TMPDIR/seq"
SEQ_LOCK="$TMPDIR/seq.lock"
echo "0" > "$SEQ_FILE"

# Stub write_log from logger.sh
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

# Extract path_is_watched from logger.sh
eval "$(sed -n '/^path_is_watched()/,/^}/p' "$SCRIPT_DIR/runtime/logger.sh")"

# Extract _handle_file_event from logger.sh
eval "$(sed -n '/^_handle_file_event()/,/^}/p' "$SCRIPT_DIR/runtime/logger.sh")"

# --- Test _handle_file_event ---

# Test 1: Event without watched paths is written as-is
WATCHED_PATHS=""
> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
_handle_file_event '{"type":"file_event","source":"inotifywait","ts":"2026-03-22T00:00:01Z","event":"MODIFY","path":"/workspace/src/app.js","session_id":"test1234"}'
result="$(cat "$LOG_FILE")"
assert_contains "_handle_file_event writes event to log" '"type":"file_event"' "$result"
if echo "$result" | grep -Fq '"watched":true'; then
  echo "  FAIL: _handle_file_event should not tag unwatched event"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: _handle_file_event does not tag unwatched event"
  PASS=$((PASS + 1))
fi

# Test 2: Event matching watched path is tagged
WATCHED_PATHS=".env:secrets/"
> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
_handle_file_event '{"type":"file_event","source":"inotifywait","ts":"2026-03-22T00:00:01Z","event":"CREATE","path":"/workspace/.env","session_id":"test1234"}'
result="$(cat "$LOG_FILE")"
assert_contains "_handle_file_event tags watched path" '"watched":true' "$result"

# Test 3: Event not matching watched path is not tagged
> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
_handle_file_event '{"type":"file_event","source":"inotifywait","ts":"2026-03-22T00:00:01Z","event":"MODIFY","path":"/workspace/src/app.js","session_id":"test1234"}'
result="$(cat "$LOG_FILE")"
if echo "$result" | grep -Fq '"watched":true'; then
  echo "  FAIL: _handle_file_event should not tag non-matching path"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: _handle_file_event does not tag non-matching path"
  PASS=$((PASS + 1))
fi

# Test 4: Event matching directory prefix is tagged
> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
_handle_file_event '{"type":"file_event","source":"inotifywait","ts":"2026-03-22T00:00:01Z","event":"CREATE","path":"/workspace/secrets/token.key","session_id":"test1234"}'
result="$(cat "$LOG_FILE")"
assert_contains "_handle_file_event tags directory prefix match" '"watched":true' "$result"

# --- Test _start_inotifywait format ---
# We test that the function is defined and produces correctly formatted events
# by verifying the inotifywait command format string

inotifywait_format="$(grep -A3 '_start_inotifywait()' "$SCRIPT_DIR/runtime/logger.sh" | grep -- '--format' | head -1)"
assert_contains "_start_inotifywait uses JSON format" '"type":"file_event"' "$inotifywait_format"
assert_contains "_start_inotifywait includes source field" '"source":"inotifywait"' "$inotifywait_format"

# --- Test _start_fswatch format ---
# Verify the function constructs valid JSON events.
# The line uses shell-escaped quotes (\" inside double-quoted string),
# so we match the escaped form as it appears in the source.

fswatch_json_line="$(grep 'local line=' "$SCRIPT_DIR/runtime/logger.sh" | grep 'fswatch' | head -1)"
assert_contains "_start_fswatch produces file_event JSON" '\"type\":\"file_event\"' "$fswatch_json_line"
assert_contains "_start_fswatch uses fswatch source" '\"source\":\"fswatch\"' "$fswatch_json_line"

rm -rf "$TMPDIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
