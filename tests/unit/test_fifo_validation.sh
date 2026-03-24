#!/usr/bin/env bash
# Unit tests for Phase 5.2 — FIFO forgery detection
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_fifo_validation.sh"

# --- Setup: extract functions from logger.sh for testing ---

TMPDIR="$(mktemp -d)"
LOG_FILE="$TMPDIR/test.jsonl"
SEQ_FILE="$TMPDIR/seq"
SEQ_LOCK="$TMPDIR/seq.lock"
CHECKSUM_FILE="$TMPDIR/test.checksums"
HMAC_KEY="01234567890abcdef01234567890abcdef01234567890abcdef01234567890abcdef"
PREV_HMAC="0"
echo "0" > "$SEQ_FILE"
SESSION_ID="test1234"

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

_strip_fifo_injected_fields() {
  local line="$1"
  line="$(printf '%s' "$line" | sed 's/,"seq":[0-9]*//g; s/"seq":[0-9]*,\?//g')"
  line="$(printf '%s' "$line" | sed 's/,"hmac":"[^"]*"//g; s/"hmac":"[^"]*",\?//g')"
  printf '%s' "$line"
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
    ts="$(printf '%s' "$line_with_seq" | grep -o '"ts":"[^"]*"' | head -1 | cut -d'"' -f4)"
    local hmac_input="${PREV_HMAC}|${seq}|${ts}|${line_with_seq}"
    local hmac_value
    hmac_value="$(compute_hmac "$hmac_input")"
    PREV_HMAC="$hmac_value"
    local final_line="${line_with_seq%\}},\"hmac\":\"$hmac_value\"}"
    printf '%s\n' "$final_line" >> "$LOG_FILE"
    write_checksum "$final_line"
  } 9>"$SEQ_LOCK"
}

# Set session start to "now"
SESSION_START_TS="$(timestamp)"
PREV_FIFO_TS=""

# Source the _validate_fifo_event function
_validate_fifo_event() {
  local line="$1"
  local issues=""

  local has_type has_source has_ts has_session_id
  has_type="$(printf '%s' "$line" | grep -o '"type"' | head -1 || true)"
  has_source="$(printf '%s' "$line" | grep -o '"source"' | head -1 || true)"
  has_ts="$(printf '%s' "$line" | grep -o '"ts"' | head -1 || true)"
  has_session_id="$(printf '%s' "$line" | grep -o '"session_id"' | head -1 || true)"

  if [ -z "$has_type" ] || [ -z "$has_source" ] || [ -z "$has_ts" ] || [ -z "$has_session_id" ]; then
    issues="${issues:+$issues,}missing_required_fields"
  fi

  if [ -n "$has_ts" ] && [ -n "$SESSION_START_TS" ]; then
    local event_ts
    event_ts="$(printf '%s' "$line" | grep -o '"ts":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    if [ -n "$event_ts" ]; then
      local event_epoch now_epoch start_epoch
      event_epoch="$(_ts_to_epoch "$event_ts")"
      now_epoch="$(date -u +%s)"
      start_epoch="$(_ts_to_epoch "$SESSION_START_TS")"

      if [ "$event_epoch" -gt 0 ] 2>/dev/null; then
        if [ "$event_epoch" -lt "$start_epoch" ] 2>/dev/null; then
          issues="${issues:+$issues,}timestamp_before_session"
        fi
        if [ "$((event_epoch - now_epoch))" -gt 2 ] 2>/dev/null; then
          issues="${issues:+$issues,}timestamp_future"
        fi
        if [ -n "$PREV_FIFO_TS" ]; then
          local prev_epoch
          prev_epoch="$(_ts_to_epoch "$PREV_FIFO_TS")"
          if [ "$prev_epoch" -gt 0 ] 2>/dev/null && [ "$((prev_epoch - event_epoch))" -gt 30 ] 2>/dev/null; then
            issues="${issues:+$issues,}timestamp_regression"
          fi
        fi
        PREV_FIFO_TS="$event_ts"
      fi
    fi
  fi

  local has_seq has_hmac
  has_seq="$(printf '%s' "$line" | grep -o '"seq"' | head -1 || true)"
  has_hmac="$(printf '%s' "$line" | grep -o '"hmac"' | head -1 || true)"
  if [ -n "$has_seq" ] || [ -n "$has_hmac" ]; then
    issues="${issues:+$issues,}seq_injection_attempt"
    line="$(_strip_fifo_injected_fields "$line")"
  fi

  local source
  source="$(printf '%s' "$line" | grep -o '"source":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
  case "$source" in
    shell-wrapper|"") ;;
    observer)
      if [ "${INDEPENDENT_OBSERVER:-}" != "true" ]; then
        issues="${issues:+$issues,}source_impersonation"
      else
        local event_token
        event_token="$(printf '%s' "$line" | grep -o '"_observer_token":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
        if [ "$event_token" != "$OBSERVER_TOKEN" ]; then
          issues="${issues:+$issues,}observer_token_invalid"
        fi
        line="$(printf '%s' "$line" | sed 's/,"_observer_token":"[^"]*"//g; s/"_observer_token":"[^"]*",\?//g')"
      fi
      ;;
    strace|inotifywait|fswatch|carranca|fanotify)
      issues="${issues:+$issues,}source_impersonation"
      ;;
  esac

  if [ -n "$issues" ]; then
    local integrity_event="{\"type\":\"integrity_event\",\"source\":\"carranca\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"$issues\",\"raw_source\":\"${source:-unknown}\"}"
    write_log "$integrity_event"
  fi

  printf '%s' "$line"
}

# --- Test: valid event passes without integrity_event ---
echo "--- valid event ---"
> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
PREV_FIFO_TS=""

VALID="{\"type\":\"shell_command\",\"source\":\"shell-wrapper\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"command\":\"ls\"}"
result="$(_validate_fifo_event "$VALID")"
assert_eq "valid event passes through unchanged" "$VALID" "$result"

INTEGRITY_COUNT="$(grep -c 'integrity_event' "$LOG_FILE" 2>/dev/null)" || true
assert_eq "no integrity_event for valid event" "0" "$INTEGRITY_COUNT"

# --- Test: missing required fields ---
echo "--- missing required fields ---"
> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
PREV_FIFO_TS=""

MISSING="{\"command\":\"ls\"}"
_validate_fifo_event "$MISSING" > /dev/null
LOG_CONTENT="$(cat "$LOG_FILE")"
assert_contains "missing fields flagged" "missing_required_fields" "$LOG_CONTENT"

# --- Test: future timestamp ---
echo "--- future timestamp ---"
> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
PREV_FIFO_TS=""

FUTURE_TS="2099-01-01T00:00:00Z"
FUTURE="{\"type\":\"shell_command\",\"source\":\"shell-wrapper\",\"ts\":\"$FUTURE_TS\",\"session_id\":\"$SESSION_ID\"}"
_validate_fifo_event "$FUTURE" > /dev/null
LOG_CONTENT="$(cat "$LOG_FILE")"
assert_contains "future timestamp flagged" "timestamp_future" "$LOG_CONTENT"

# --- Test: timestamp before session ---
echo "--- timestamp before session ---"
> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
PREV_FIFO_TS=""

PAST_TS="2020-01-01T00:00:00Z"
PAST="{\"type\":\"shell_command\",\"source\":\"shell-wrapper\",\"ts\":\"$PAST_TS\",\"session_id\":\"$SESSION_ID\"}"
_validate_fifo_event "$PAST" > /dev/null
LOG_CONTENT="$(cat "$LOG_FILE")"
assert_contains "before-session timestamp flagged" "timestamp_before_session" "$LOG_CONTENT"

# --- Test: seq injection stripped and flagged ---
echo "--- seq injection ---"
> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
PREV_FIFO_TS=""

INJECTED="{\"type\":\"shell_command\",\"source\":\"shell-wrapper\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"seq\":999,\"hmac\":\"fake\"}"
result="$(_validate_fifo_event "$INJECTED")"
LOG_CONTENT="$(cat "$LOG_FILE")"
assert_contains "seq injection flagged" "seq_injection_attempt" "$LOG_CONTENT"
assert_not_contains "seq stripped from result" "\"seq\"" "$result"
assert_not_contains "hmac stripped from result" "\"hmac\"" "$result"

# --- Test: source impersonation ---
echo "--- source impersonation ---"
> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
PREV_FIFO_TS=""

IMPERSONATION="{\"type\":\"execve_event\",\"source\":\"strace\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\"}"
_validate_fifo_event "$IMPERSONATION" > /dev/null
LOG_CONTENT="$(cat "$LOG_FILE")"
assert_contains "source impersonation flagged" "source_impersonation" "$LOG_CONTENT"

# --- Test: carranca source impersonation ---
echo "--- carranca source impersonation ---"
> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
PREV_FIFO_TS=""

CARRANCA_IMPERSONATION="{\"type\":\"session_event\",\"source\":\"carranca\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\"}"
_validate_fifo_event "$CARRANCA_IMPERSONATION" > /dev/null
LOG_CONTENT="$(cat "$LOG_FILE")"
assert_contains "carranca source impersonation flagged" "source_impersonation" "$LOG_CONTENT"

# --- Test: _strip_fifo_injected_fields ---
echo "--- field stripping ---"
INJECTED_LINE="{\"type\":\"shell_command\",\"seq\":42,\"hmac\":\"abc123\",\"data\":\"ok\"}"
STRIPPED="$(_strip_fifo_injected_fields "$INJECTED_LINE")"
assert_not_contains "seq removed" "\"seq\"" "$STRIPPED"
assert_not_contains "hmac removed" "\"hmac\"" "$STRIPPED"
assert_contains "data preserved" "\"data\":\"ok\"" "$STRIPPED"

# --- Test: observer with valid token accepted ---
echo "--- observer with valid token ---"
> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
PREV_FIFO_TS=""
INDEPENDENT_OBSERVER="true"
OBSERVER_TOKEN="secret123"

VALID_OBS="{\"type\":\"execve_event\",\"source\":\"observer\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"_observer_token\":\"secret123\"}"
result="$(_validate_fifo_event "$VALID_OBS")"
INTEGRITY_COUNT="$(grep -c 'integrity_event' "$LOG_FILE" 2>/dev/null)" || true
assert_eq "valid observer token produces no integrity_event" "0" "$INTEGRITY_COUNT"
assert_not_contains "token stripped from output" "_observer_token" "$result"

# --- Test: observer with invalid token flagged ---
echo "--- observer with invalid token ---"
> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
PREV_FIFO_TS=""

FAKE_OBS="{\"type\":\"execve_event\",\"source\":\"observer\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"_observer_token\":\"wrong\"}"
_validate_fifo_event "$FAKE_OBS" > /dev/null
LOG_CONTENT="$(cat "$LOG_FILE")"
assert_contains "invalid observer token flagged" "observer_token_invalid" "$LOG_CONTENT"

# --- Test: observer with missing token flagged ---
echo "--- observer with missing token ---"
> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
PREV_FIFO_TS=""

NO_TOK_OBS="{\"type\":\"execve_event\",\"source\":\"observer\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\"}"
_validate_fifo_event "$NO_TOK_OBS" > /dev/null
LOG_CONTENT="$(cat "$LOG_FILE")"
assert_contains "missing observer token flagged" "observer_token_invalid" "$LOG_CONTENT"

# Reset
INDEPENDENT_OBSERVER=""
OBSERVER_TOKEN=""

# --- Cleanup ---
rm -rf "$TMPDIR"

echo ""
print_results
