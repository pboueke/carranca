#!/usr/bin/env bash
# Unit tests for Phase 5.1 — observer PID discovery and cross-reference functions
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
  if echo "$haystack" | grep -Fq -- "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if ! echo "$haystack" | grep -Fq -- "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected NOT to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== test_observer.sh ==="

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
  date -u +%Y-%m-%dT%H:%M:%SZ
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

# Inline cross-reference function for testing
_cross_reference_events() {
  [ -f "$LOG_FILE" ] || return 0

  local cmd_times=""
  while IFS= read -r line; do
    local ts
    ts="$(printf '%s' "$line" | grep -o '"ts":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    [ -n "$ts" ] && cmd_times="$cmd_times $(_ts_to_epoch "$ts")"
  done < <(grep '"type":"shell_command"' "$LOG_FILE" 2>/dev/null || true)

  local exec_times=""
  while IFS= read -r line; do
    local ts
    ts="$(printf '%s' "$line" | grep -o '"ts":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    [ -n "$ts" ] && exec_times="$exec_times $(_ts_to_epoch "$ts")"
  done < <(grep '"type":"execve_event"' "$LOG_FILE" 2>/dev/null || true)

  for cmd_t in $cmd_times; do
    local found=false
    for exec_t in $exec_times; do
      local diff=$((cmd_t - exec_t))
      [ "$diff" -lt 0 ] && diff=$((-diff))
      [ "$diff" -le 3 ] && found=true && break
    done
    if [ "$found" = false ]; then
      local event="{\"type\":\"integrity_event\",\"source\":\"carranca\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"shell_command_without_execve\"}"
      write_log "$event"
    fi
  done

  for exec_t in $exec_times; do
    local found=false
    for cmd_t in $cmd_times; do
      local diff=$((exec_t - cmd_t))
      [ "$diff" -lt 0 ] && diff=$((-diff))
      [ "$diff" -le 3 ] && found=true && break
    done
    if [ "$found" = false ]; then
      local event="{\"type\":\"integrity_event\",\"source\":\"carranca\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"unmatched_execve_activity\"}"
      write_log "$event"
    fi
  done
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

# --- Cleanup ---
rm -rf "$TMPDIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
