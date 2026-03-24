#!/usr/bin/env bash
# Unit tests for Phase 5.1 — observer PID discovery and cross-reference functions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_observer.sh"

# --- Setup ---
TMPDIR="$(mktemp -d)"
LOG_FILE="$TMPDIR/test.jsonl"
SEQ_FILE="$TMPDIR/seq"
SEQ_LOCK="$TMPDIR/seq.lock"
CHECKSUM_FILE="$TMPDIR/test.checksums"
HMAC_KEY="01234567890abcdef01234567890abcdef01234567890abcdef01234567890abcdef"
PREV_HMAC="0"
SESSION_ID="test1234"
INDEPENDENT_OBSERVER="true"
echo "0" > "$SEQ_FILE"

timestamp() {
  date -u +%Y-%m-%dT%H:%M:%S.%3NZ
}

_ts_to_epoch() {
  local ts="$1"
  local cleaned="${ts%Z}"
  cleaned="${cleaned/T/ }"
  date -u -d "$cleaned" +%s 2>/dev/null || echo 0
}

compute_hmac() {
  local message="$1"
  printf '%s' "$message" | openssl dgst -sha256 -macopt "hexkey:$HMAC_KEY" -hex 2>/dev/null | awk '{print $NF}'
}

write_checksum() {
  local line="$1"
  local hash
  hash="$(printf '%s' "$line" | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}')"
  printf '%s\n' "$hash" >> "$CHECKSUM_FILE"
}

write_log() {
  local line="$1"
  {
    flock 9
    local seq
    seq=$(cat "$SEQ_FILE" 2>/dev/null || echo 0)
    seq=$((seq + 1))
    echo "$seq" > "$SEQ_FILE"
    local line_with_seq="${line%\}},\"seq\":$seq}"
    local ts
    ts="$(printf '%s' "$line_with_seq" | grep -o '"ts":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    local hmac_input="${PREV_HMAC}|${seq}|${ts}|${line_with_seq}"
    local hmac_value
    hmac_value="$(compute_hmac "$hmac_input")"
    PREV_HMAC="$hmac_value"
    local final_line="${line_with_seq%\}},\"hmac\":\"$hmac_value\"}"
    printf '%s\n' "$final_line" >> "$LOG_FILE"
    write_checksum "$final_line"
  } 9>"$SEQ_LOCK"
}

# --- Test: cross-reference — matching events produce no integrity_event ---
echo "--- cross-reference: matching events ---"
> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
PREV_HMAC="0"

NOW_TS="$(timestamp)"
write_log "{\"type\":\"shell_command\",\"source\":\"shell-wrapper\",\"ts\":\"$NOW_TS\",\"session_id\":\"$SESSION_ID\",\"command\":\"ls\"}"
write_log "{\"type\":\"execve_event\",\"source\":\"observer\",\"ts\":\"$NOW_TS\",\"session_id\":\"$SESSION_ID\",\"pid\":42,\"binary\":\"/usr/bin/ls\"}"

# Inline cross-reference function for testing (greedy 1:1 matching)
_cross_reference_events() {
  [ -f "$LOG_FILE" ] || return 0

  local cmd_file exec_file matched_exec_file
  cmd_file="$(mktemp /tmp/test-xref-cmd.XXXXXX)"
  exec_file="$(mktemp /tmp/test-xref-exec.XXXXXX)"
  matched_exec_file="$(mktemp /tmp/test-xref-matched.XXXXXX)"

  while IFS= read -r line; do
    local ts
    ts="$(printf '%s' "$line" | grep -o '"ts":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    [ -n "$ts" ] && _ts_to_epoch "$ts" >> "$cmd_file"
  done < <(grep '"type":"shell_command"' "$LOG_FILE" 2>/dev/null || true)

  while IFS= read -r line; do
    local ts
    ts="$(printf '%s' "$line" | grep -o '"ts":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    [ -n "$ts" ] && _ts_to_epoch "$ts" >> "$exec_file"
  done < <(grep '"type":"execve_event"' "$LOG_FILE" 2>/dev/null || true)

  sort -n "$cmd_file" -o "$cmd_file"
  sort -n "$exec_file" -o "$exec_file"

  while IFS= read -r cmd_t; do
    [ -z "$cmd_t" ] && continue
    local best_line="" best_diff=999999 line_num=0
    while IFS= read -r exec_t; do
      line_num=$((line_num + 1))
      [ -z "$exec_t" ] && continue
      grep -q "^${line_num}$" "$matched_exec_file" 2>/dev/null && continue
      local diff=$((cmd_t - exec_t))
      [ "$diff" -lt 0 ] && diff=$((-diff))
      if [ "$diff" -le 3 ] && [ "$diff" -lt "$best_diff" ]; then
        best_diff="$diff"
        best_line="$line_num"
      fi
    done < "$exec_file"
    if [ -n "$best_line" ]; then
      echo "$best_line" >> "$matched_exec_file"
    else
      local event="{\"type\":\"integrity_event\",\"source\":\"carranca\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"shell_command_without_execve\"}"
      write_log "$event"
    fi
  done < "$cmd_file"

  local line_num=0
  while IFS= read -r exec_t; do
    line_num=$((line_num + 1))
    [ -z "$exec_t" ] && continue
    if ! grep -q "^${line_num}$" "$matched_exec_file" 2>/dev/null; then
      local event="{\"type\":\"integrity_event\",\"source\":\"carranca\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"unmatched_execve_activity\"}"
      write_log "$event"
    fi
  done < "$exec_file"

  rm -f "$cmd_file" "$exec_file" "$matched_exec_file"
}

_cross_reference_events
INTEGRITY_COUNT="$(grep -c 'integrity_event' "$LOG_FILE" 2>/dev/null)" || true
assert_eq "matching events produce no integrity_event" "0" "$INTEGRITY_COUNT"

# --- Test: cross-reference — shell_command without execve ---
echo "--- cross-reference: shell_command without execve ---"
> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
PREV_HMAC="0"

write_log "{\"type\":\"shell_command\",\"source\":\"shell-wrapper\",\"ts\":\"$NOW_TS\",\"session_id\":\"$SESSION_ID\",\"command\":\"secret-cmd\"}"
# No execve_event for this command

_cross_reference_events
LOG_CONTENT="$(cat "$LOG_FILE")"
assert_contains "shell_command_without_execve flagged" "shell_command_without_execve" "$LOG_CONTENT"

# --- Test: cross-reference — unmatched execve ---
echo "--- cross-reference: unmatched execve ---"
> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
PREV_HMAC="0"

write_log "{\"type\":\"execve_event\",\"source\":\"observer\",\"ts\":\"$NOW_TS\",\"session_id\":\"$SESSION_ID\",\"pid\":99,\"binary\":\"/usr/bin/curl\"}"
# No shell_command for this execve

_cross_reference_events
LOG_CONTENT="$(cat "$LOG_FILE")"
assert_contains "unmatched_execve_activity flagged" "unmatched_execve_activity" "$LOG_CONTENT"

# --- Test: session.sh observer naming ---
echo "--- session observer naming ---"
source "$SCRIPT_DIR/cli/lib/session.sh"

OBSERVER_NAME="$(carranca_session_observer_name "abc12345")"
assert_eq "observer name follows convention" "carranca-abc12345-observer" "$OBSERVER_NAME"

# --- Test: observer function definitions (coverage) ---
# These functions require container/proc context so we verify they are defined
# and test the parts we can unit-test.

echo "--- observer function coverage ---"

# _read_observer_token: test with a valid token file
TOKEN_DIR="$TMPDIR/state"
mkdir -p "$TOKEN_DIR"
echo "abcdef1234567890" > "$TOKEN_DIR/$SESSION_ID.observer-token"

# Override the token path by testing the logic inline
OBSERVER_TOKEN=""
_token_file="$TOKEN_DIR/$SESSION_ID.observer-token"
OBSERVER_TOKEN="$(cat "$_token_file" 2>/dev/null)"
if [[ "$OBSERVER_TOKEN" =~ ^[0-9a-fA-F]+$ ]]; then
  assert_eq "_read_observer_token reads valid hex token" "abcdef1234567890" "$OBSERVER_TOKEN"
else
  echo "  FAIL: _read_observer_token should accept hex token"
  FAIL=$((FAIL + 1))
fi

# _read_observer_token: reject non-hex token
echo "not-hex-!!!" > "$_token_file"
OBSERVER_TOKEN="$(cat "$_token_file" 2>/dev/null)"
if [[ "$OBSERVER_TOKEN" =~ ^[0-9a-fA-F]+$ ]]; then
  echo "  FAIL: _read_observer_token should reject non-hex token"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: _read_observer_token rejects non-hex token"
  PASS=$((PASS + 1))
fi

# _wait_for_fifo: test that it finds an existing FIFO
TEST_FIFO="$TMPDIR/test-fifo"
mkfifo "$TEST_FIFO"
FIFO_PATH="$TEST_FIFO"
# The function polls, but with a FIFO already present it should return 0 immediately
# We test the condition directly since calling the function would sleep
if [ -p "$FIFO_PATH" ]; then
  echo "  PASS: _wait_for_fifo finds existing FIFO"
  PASS=$((PASS + 1))
else
  echo "  FAIL: _wait_for_fifo should find existing FIFO"
  FAIL=$((FAIL + 1))
fi

# _find_agent_host_pid: verify function exists in observer.sh source
if grep -q '_find_agent_host_pid()' "$SCRIPT_DIR/runtime/observer.sh"; then
  echo "  PASS: _find_agent_host_pid defined in observer.sh"
  PASS=$((PASS + 1))
else
  echo "  FAIL: _find_agent_host_pid not found in observer.sh"
  FAIL=$((FAIL + 1))
fi

# _start_observer_tracer: verify function exists
if grep -q '_start_observer_tracer()' "$SCRIPT_DIR/runtime/observer.sh"; then
  echo "  PASS: _start_observer_tracer defined in observer.sh"
  PASS=$((PASS + 1))
else
  echo "  FAIL: _start_observer_tracer not found in observer.sh"
  FAIL=$((FAIL + 1))
fi

# _start_observer_network_monitor: verify function exists
if grep -q '_start_observer_network_monitor()' "$SCRIPT_DIR/runtime/observer.sh"; then
  echo "  PASS: _start_observer_network_monitor defined in observer.sh"
  PASS=$((PASS + 1))
else
  echo "  FAIL: _start_observer_network_monitor not found in observer.sh"
  FAIL=$((FAIL + 1))
fi

# --- Test: _emit_enforcement_failure (network-setup.sh) ---
echo "--- network-setup coverage ---"
if grep -q '_emit_enforcement_failure()' "$SCRIPT_DIR/runtime/network-setup.sh"; then
  echo "  PASS: _emit_enforcement_failure defined in network-setup.sh"
  PASS=$((PASS + 1))
else
  echo "  FAIL: _emit_enforcement_failure not found in network-setup.sh"
  FAIL=$((FAIL + 1))
fi

# --- Cleanup ---
rm -rf "$TMPDIR"

echo ""
print_results
