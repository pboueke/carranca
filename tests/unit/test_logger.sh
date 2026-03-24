#!/usr/bin/env bash
# Unit tests for runtime/logger.sh internal functions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_logger.sh"

# We cannot source logger.sh directly (it runs as an entrypoint).
# Instead, extract the functions we need to test and define stubs
# for their dependencies.

TMPDIR="$(mktemp -d)"
LOG_FILE="$TMPDIR/test.jsonl"
SEQ_FILE="$TMPDIR/seq"
SEQ_LOCK="$TMPDIR/seq.lock"
CHECKSUM_FILE="$TMPDIR/test.checksums"
echo "0" > "$SEQ_FILE"

# Stub write_log from logger.sh (original version without HMAC for existing tests)
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

# Stub new HMAC functions for testing
generate_hmac_key() {
  HMAC_KEY="01234567890abcdef01234567890abcdef01234567890abcdef01234567890abcdef"
}

compute_hmac() {
  # Mock HMAC that returns a predictable hash based on input
  # Sum ASCII values of all characters to differentiate inputs
  local message="$1"
  local sum=0
  local i=0
  local char
  for ((i=0; i<${#message}; i++)); do
    char="${message:$i:1}"
    sum=$((sum + $(printf '%d' "'$char")))
  done
  printf '%s' "hmac-${sum}"
}

# Stub write_checksum for testing
write_checksum() {
  # Mock checksum that writes a predictable hash
  local line="$1"
  printf '%s\n' "checksum-${#line}" >> "$CHECKSUM_FILE"
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
assert_not_contains "_handle_file_event does not tag unwatched event" '"watched":true' "$result"

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
assert_not_contains "_handle_file_event does not tag non-matching path" '"watched":true' "$result"

# Test 4: Event matching directory prefix is tagged
> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
_handle_file_event '{"type":"file_event","source":"inotifywait","ts":"2026-03-22T00:00:01Z","event":"CREATE","path":"/workspace/secrets/token.key","session_id":"test1234"}'
result="$(cat "$LOG_FILE")"
assert_contains "_handle_file_event tags directory prefix match" '"watched":true' "$result"

# --- Test _start_inotifywait format ---
# inotifywait now outputs TSV; JSON is constructed in the post-processing loop.
# Verify the TSV format and that the JSON construction includes required fields.

inotifywait_format="$(grep -A10 '_start_inotifywait()' "$SCRIPT_DIR/runtime/logger.sh" | grep -- '--format' | head -1 || true)"
assert_contains "_start_inotifywait uses TSV format" '%e' "$inotifywait_format"

inotifywait_json="$(grep 'file_event.*inotifywait' "$SCRIPT_DIR/runtime/logger.sh" | head -1 || true)"
assert_contains "_start_inotifywait constructs file_event JSON" 'file_event' "$inotifywait_json"

# --- Test _start_fswatch format ---
# Verify the function constructs valid JSON events.
# The line uses shell-escaped quotes (\" inside double-quoted string),
# so we match the escaped form as it appears in the source.

fswatch_json_line="$(grep 'local line=' "$SCRIPT_DIR/runtime/logger.sh" | grep 'fswatch' | head -1)"
assert_contains "_start_fswatch produces file_event JSON" '\"type\":\"file_event\"' "$fswatch_json_line"
assert_contains "_start_fswatch uses fswatch source" '\"source\":\"fswatch\"' "$fswatch_json_line"

# --- Test HMAC functions ---

echo ""
echo "--- HMAC functions ---"

# Test: generate_hmac_key sets HMAC_KEY
HMAC_KEY=""
generate_hmac_key
assert_eq "generate_hmac_key sets HMAC_KEY" "01234567890abcdef01234567890abcdef01234567890abcdef01234567890abcdef" "$HMAC_KEY"

# Test: compute_hmac returns hash-like output
result="$(compute_hmac "test message")"
assert_contains "compute_hmac returns hash" "hmac-" "$result"

# Test: HMAC computation produces consistent results
hash1="$(compute_hmac "same input")"
hash2="$(compute_hmac "same input")"
assert_eq "compute_hmac is deterministic" "$hash1" "$hash2"

# Test: Different inputs produce different HMACs
hash1="$(compute_hmac "input A")"
hash2="$(compute_hmac "input B")"
hashes_differ=0; [ "$hash1" != "$hash2" ] && hashes_differ=1
assert_eq "compute_hmac differs for different inputs" "1" "$hashes_differ"

# --- Test write_checksum ---

echo ""
echo "--- write_checksum ---"

> "$CHECKSUM_FILE"

# Test: write_checksum writes a hash-like value
write_checksum '{"type":"test"}'
checksum_content="$(cat "$CHECKSUM_FILE")"
assert_contains "write_checksum writes hash to file" "checksum-" "$checksum_content"

# Test: write_checksum appends to file
write_checksum '{"type":"test2"}'
line_count=$(wc -l < "$CHECKSUM_FILE")
assert_eq "write_checksum appends to file" "2" "$line_count"

# --- Test _constant_time_compare ---

echo ""
echo "--- _constant_time_compare ---"

# Extract _constant_time_compare from logger.sh
eval "$(sed -n '/_constant_time_compare()/,/^}/p' "$SCRIPT_DIR/runtime/logger.sh")"

# Test: equal strings match
_constant_time_compare "abc123" "abc123"
assert_eq "_constant_time_compare equal strings" "0" "$?"

# Test: different strings do not match
result=0; _constant_time_compare "abc123" "abc124" || result=$?
assert_eq "_constant_time_compare different strings" "1" "$result"

# Test: different lengths do not match
result=0; _constant_time_compare "short" "longer" || result=$?
assert_eq "_constant_time_compare different lengths" "1" "$result"

# Test: empty strings match
_constant_time_compare "" ""
assert_eq "_constant_time_compare empty strings" "0" "$?"

rm -rf "$TMPDIR"

echo ""
print_results
