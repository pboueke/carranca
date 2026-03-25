#!/usr/bin/env bash
# Integration tests for the write_log → carranca_session_verify roundtrip.
# Validates that events written by the logger can be verified by the CLI,
# including the HMAC chain and chained checksums across multiple processes
# (the bug that motivated this test: subshell-isolated chain state variables).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

# Source the CLI verify function and its JSON helpers
source "$SCRIPT_DIR/cli/lib/log.sh"

suite_header "test_log_verify.sh"

# --- Helpers: extract real functions from logger.sh ---
# We cannot source logger.sh (it runs as an entrypoint), so we extract
# the functions we need and set up the state files they depend on.

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

LOG_FILE="$TMPDIR/test-session.jsonl"
SEQ_FILE="$TMPDIR/seq"
SEQ_LOCK="$TMPDIR/seq.lock"
CHECKSUM_FILE="$TMPDIR/test-session.checksums"
PREV_HMAC_FILE="$TMPDIR/prev-hmac"
PREV_CHECKSUM_FILE="$TMPDIR/prev-checksum"
HMAC_KEY_FILE="$TMPDIR/test-session.hmac-key"
HMAC_KEY=""

# Extract real functions from logger.sh
eval "$(sed -n '/^compute_hmac()/,/^}/p' "$SCRIPT_DIR/runtime/logger.sh")"
eval "$(sed -n '/^generate_hmac_key()/,/^}/p' "$SCRIPT_DIR/runtime/logger.sh")"

# Real write_checksum (file-backed chain state, matching the fix)
write_checksum() {
  local line="$1"
  local prev_checksum
  prev_checksum="$(cat "$PREV_CHECKSUM_FILE" 2>/dev/null || true)"
  local hash
  hash="$(printf '%s' "${prev_checksum}${line}" | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}')"
  echo "$hash" > "$PREV_CHECKSUM_FILE"
  printf '%s\n' "$hash" >> "$CHECKSUM_FILE"
}

# Real write_log (file-backed HMAC chain state, matching the fix)
write_log() {
  local line="$1"
  {
    flock 9
    local seq
    seq=$(cat "$SEQ_FILE" 2>/dev/null || echo 0)
    seq=$((seq + 1))
    echo "$seq" > "$SEQ_FILE"
    if [[ "$line" != *"}" ]]; then
      return
    fi
    local prev_hmac
    prev_hmac="$(cat "$PREV_HMAC_FILE" 2>/dev/null || echo 0)"
    local line_with_seq="${line%\}},\"seq\":$seq}"
    local ts
    ts="$(printf '%s' "$line_with_seq" | grep -o '"ts":"[^"]*"' | head -1 | cut -d'"' -f4)"
    local hmac_input="${prev_hmac}|${seq}|${ts}|${line_with_seq}"
    local hmac_value
    hmac_value="$(compute_hmac "$hmac_input")"
    echo "$hmac_value" > "$PREV_HMAC_FILE"
    local final_line="${line_with_seq%\}},\"hmac\":\"$hmac_value\"}"
    printf '%s\n' "$final_line" >> "$LOG_FILE"
    write_checksum "$final_line"
  } 9>"$SEQ_LOCK"
}

# Initialize state for a fresh session
init_session() {
  > "$LOG_FILE"
  > "$CHECKSUM_FILE"
  echo "0" > "$SEQ_FILE"
  echo "0" > "$PREV_HMAC_FILE"
  : > "$PREV_CHECKSUM_FILE"
  HMAC_KEY=""
  generate_hmac_key
  echo "$HMAC_KEY" > "$HMAC_KEY_FILE"
}

# Build the state directory layout that carranca_session_verify expects:
#   <state_base>/sessions/<repo_id>/<session_id>.hmac-key
STATE_BASE="$TMPDIR/state"
REPO_ID="testrepo"
SESSION_DIR="$STATE_BASE/sessions/$REPO_ID"
mkdir -p "$SESSION_DIR"

# Helper: copy session files into the verify-expected layout and run verify
run_verify() {
  cp "$LOG_FILE" "$SESSION_DIR/test-session.jsonl"
  cp "$CHECKSUM_FILE" "$SESSION_DIR/test-session.checksums"
  cp "$HMAC_KEY_FILE" "$SESSION_DIR/test-session.hmac-key"
  carranca_session_verify "$SESSION_DIR/test-session.jsonl" "$STATE_BASE" 2>&1
}

# ============================================================
# Test 1: Single-process sequential writes verify cleanly
# ============================================================
echo ""
echo "--- Sequential writes (single process) ---"

init_session

write_log '{"type":"session_event","source":"carranca","event":"start","ts":"2026-03-25T10:00:00.000Z","session_id":"test-session"}'
write_log '{"type":"file_event","source":"inotifywait","event":"CREATE","ts":"2026-03-25T10:00:01.000Z","path":"/workspace/a.txt","session_id":"test-session"}'
write_log '{"type":"shell_command","source":"shell-wrapper","ts":"2026-03-25T10:00:02.000Z","command":"echo hello","exit_code":0,"duration_ms":5,"cwd":"/workspace","session_id":"test-session"}'
write_log '{"type":"session_event","source":"carranca","event":"stop","ts":"2026-03-25T10:00:03.000Z","session_id":"test-session","exit_code":0}'

line_count="$(wc -l < "$LOG_FILE")"
assert_eq "wrote 4 log lines" "4" "$line_count"

verify_output="$(run_verify)"
verify_rc=0; run_verify >/dev/null 2>&1 || verify_rc=$?
assert_eq "sequential writes verify OK" "0" "$verify_rc"
assert_contains "verify reports 4 events" "4 events verified" "$verify_output"

# ============================================================
# Test 2: Cross-subshell writes verify cleanly (the original bug)
# ============================================================
echo ""
echo "--- Cross-subshell writes ---"

init_session

# Event 1: main process
write_log '{"type":"session_event","source":"carranca","event":"start","ts":"2026-03-25T11:00:00.000Z","session_id":"test-session"}'

# Events 2-3: written from a subshell (simulates background inotifywait)
(
  write_log '{"type":"file_event","source":"inotifywait","event":"CREATE","ts":"2026-03-25T11:00:01.000Z","path":"/workspace/b.txt","session_id":"test-session"}'
  write_log '{"type":"file_event","source":"inotifywait","event":"MODIFY","ts":"2026-03-25T11:00:02.000Z","path":"/workspace/b.txt","session_id":"test-session"}'
)

# Event 4: back in main process
write_log '{"type":"shell_command","source":"shell-wrapper","ts":"2026-03-25T11:00:03.000Z","command":"cat b.txt","exit_code":0,"duration_ms":3,"cwd":"/workspace","session_id":"test-session"}'

# Event 5: another subshell (simulates a different background watcher)
(
  write_log '{"type":"file_event","source":"fswatch","event":"MODIFY","ts":"2026-03-25T11:00:04.000Z","path":"/workspace/c.txt","session_id":"test-session"}'
)

# Event 6: main process again
write_log '{"type":"session_event","source":"carranca","event":"stop","ts":"2026-03-25T11:00:05.000Z","session_id":"test-session","exit_code":0}'

line_count="$(wc -l < "$LOG_FILE")"
assert_eq "wrote 6 cross-subshell log lines" "6" "$line_count"

verify_output="$(run_verify)"
verify_rc=0; run_verify >/dev/null 2>&1 || verify_rc=$?
assert_eq "cross-subshell writes verify OK" "0" "$verify_rc"
assert_contains "verify reports 6 events" "6 events verified" "$verify_output"

# ============================================================
# Test 3: Concurrent subshell writes verify cleanly
# ============================================================
echo ""
echo "--- Concurrent subshell writes ---"

init_session

write_log '{"type":"session_event","source":"carranca","event":"start","ts":"2026-03-25T12:00:00.000Z","session_id":"test-session"}'

# Launch two subshells writing concurrently (the flock serializes them)
(
  for i in 1 2 3; do
    write_log "{\"type\":\"file_event\",\"source\":\"inotifywait\",\"event\":\"MODIFY\",\"ts\":\"2026-03-25T12:00:0${i}.000Z\",\"path\":\"/workspace/f${i}.txt\",\"session_id\":\"test-session\"}"
  done
) &
pid1=$!

(
  for i in 4 5 6; do
    write_log "{\"type\":\"file_event\",\"source\":\"fswatch\",\"event\":\"CREATE\",\"ts\":\"2026-03-25T12:00:0${i}.000Z\",\"path\":\"/workspace/g${i}.txt\",\"session_id\":\"test-session\"}"
  done
) &
pid2=$!

wait "$pid1" "$pid2"

write_log '{"type":"session_event","source":"carranca","event":"stop","ts":"2026-03-25T12:00:09.000Z","session_id":"test-session","exit_code":0}'

line_count="$(wc -l < "$LOG_FILE")"
assert_eq "wrote 8 concurrent log lines" "8" "$line_count"

verify_output="$(run_verify)"
verify_rc=0; run_verify >/dev/null 2>&1 || verify_rc=$?
assert_eq "concurrent subshell writes verify OK" "0" "$verify_rc"
assert_contains "verify reports 8 events" "8 events verified" "$verify_output"

# ============================================================
# Test 4: HMAC chain detects tampered line
# ============================================================
echo ""
echo "--- Tamper detection ---"

init_session

write_log '{"type":"session_event","source":"carranca","event":"start","ts":"2026-03-25T13:00:00.000Z","session_id":"test-session"}'
write_log '{"type":"file_event","source":"inotifywait","event":"CREATE","ts":"2026-03-25T13:00:01.000Z","path":"/workspace/x.txt","session_id":"test-session"}'
write_log '{"type":"session_event","source":"carranca","event":"stop","ts":"2026-03-25T13:00:02.000Z","session_id":"test-session","exit_code":0}'

# Copy to verify layout, then tamper with line 2
cp "$LOG_FILE" "$SESSION_DIR/test-session.jsonl"
cp "$CHECKSUM_FILE" "$SESSION_DIR/test-session.checksums"
cp "$HMAC_KEY_FILE" "$SESSION_DIR/test-session.hmac-key"

# Replace the path in line 2 to simulate tampering
sed -i '2s|/workspace/x.txt|/workspace/EVIL.txt|' "$SESSION_DIR/test-session.jsonl"

tamper_output="$(carranca_session_verify "$SESSION_DIR/test-session.jsonl" "$STATE_BASE" 2>&1 || true)"
tamper_rc=0; carranca_session_verify "$SESSION_DIR/test-session.jsonl" "$STATE_BASE" >/dev/null 2>&1 || tamper_rc=$?
assert_eq "tampered log fails verification" "1" "$tamper_rc"
assert_contains "tamper detected at line 2" "HMAC mismatch at line 2" "$tamper_output"

# ============================================================
# Test 5: Checksum chain detects reordered lines
# ============================================================
echo ""
echo "--- Reorder detection ---"

init_session

write_log '{"type":"session_event","source":"carranca","event":"start","ts":"2026-03-25T14:00:00.000Z","session_id":"test-session"}'
write_log '{"type":"file_event","source":"inotifywait","event":"CREATE","ts":"2026-03-25T14:00:01.000Z","path":"/workspace/a.txt","session_id":"test-session"}'
write_log '{"type":"file_event","source":"inotifywait","event":"MODIFY","ts":"2026-03-25T14:00:02.000Z","path":"/workspace/b.txt","session_id":"test-session"}'
write_log '{"type":"session_event","source":"carranca","event":"stop","ts":"2026-03-25T14:00:03.000Z","session_id":"test-session","exit_code":0}'

# Copy and swap lines 2 and 3 in both log and checksum files
cp "$LOG_FILE" "$SESSION_DIR/test-session.jsonl"
cp "$CHECKSUM_FILE" "$SESSION_DIR/test-session.checksums"
cp "$HMAC_KEY_FILE" "$SESSION_DIR/test-session.hmac-key"

sed -i '2{h;d}; 3{p;x}' "$SESSION_DIR/test-session.jsonl"
sed -i '2{h;d}; 3{p;x}' "$SESSION_DIR/test-session.checksums"

reorder_rc=0; carranca_session_verify "$SESSION_DIR/test-session.jsonl" "$STATE_BASE" >/dev/null 2>&1 || reorder_rc=$?
assert_eq "reordered log fails verification" "1" "$reorder_rc"

# ============================================================
# Test 6: Deleted line breaks both HMAC and checksum chains
# ============================================================
echo ""
echo "--- Deletion detection ---"

init_session

write_log '{"type":"session_event","source":"carranca","event":"start","ts":"2026-03-25T15:00:00.000Z","session_id":"test-session"}'
write_log '{"type":"file_event","source":"inotifywait","event":"CREATE","ts":"2026-03-25T15:00:01.000Z","path":"/workspace/d.txt","session_id":"test-session"}'
write_log '{"type":"file_event","source":"inotifywait","event":"MODIFY","ts":"2026-03-25T15:00:02.000Z","path":"/workspace/d.txt","session_id":"test-session"}'
write_log '{"type":"session_event","source":"carranca","event":"stop","ts":"2026-03-25T15:00:03.000Z","session_id":"test-session","exit_code":0}'

# Copy and delete line 2 from both files
cp "$LOG_FILE" "$SESSION_DIR/test-session.jsonl"
cp "$CHECKSUM_FILE" "$SESSION_DIR/test-session.checksums"
cp "$HMAC_KEY_FILE" "$SESSION_DIR/test-session.hmac-key"

sed -i '2d' "$SESSION_DIR/test-session.jsonl"
sed -i '2d' "$SESSION_DIR/test-session.checksums"

delete_rc=0; carranca_session_verify "$SESSION_DIR/test-session.jsonl" "$STATE_BASE" >/dev/null 2>&1 || delete_rc=$?
assert_eq "deleted line fails verification" "1" "$delete_rc"

echo ""
print_results
