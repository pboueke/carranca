#!/usr/bin/env bash
# Unit tests for fanotify secret monitoring integration in logger.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_fanotify_watcher.sh"

# --- Setup temp environment ---

TMPDIR="$(mktemp -d)"
LOG_FILE="$TMPDIR/test.jsonl"
SEQ_FILE="$TMPDIR/seq"
SEQ_LOCK="$TMPDIR/seq.lock"
CHECKSUM_FILE="$TMPDIR/test.checksums"
SESSION_ID="test-session-1234"
echo "0" > "$SEQ_FILE"

# Stub dependencies
timestamp() {
  echo "2026-03-23T00:00:00Z"
}

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

# --- Test: SECRET_MONITORING disabled skips monitor ---

echo ""
echo "--- _start_secret_monitor disabled ---"

> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
SECRET_MONITORING=""

# Extract _start_secret_monitor from logger.sh
eval "$(sed -n '/^_start_secret_monitor()/,/^}/p' "$SCRIPT_DIR/runtime/logger.sh")"

_start_secret_monitor
line_count=$(wc -l < "$LOG_FILE")
assert_eq "secret monitor disabled writes no events" "0" "$line_count"

# --- Test: missing binary emits degraded event ---

echo ""
echo "--- _start_secret_monitor binary missing ---"

> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
SECRET_MONITORING="true"

# Ensure the binary path doesn't exist (it won't on a dev machine)
_start_secret_monitor
result="$(cat "$LOG_FILE")"
assert_contains "missing binary emits degraded event" '"event":"degraded"' "$result"
assert_contains "degraded reason is fanotify_binary_unavailable" '"reason":"fanotify_binary_unavailable"' "$result"

# --- Test: fanotify JSON parsing for watched paths ---

echo ""
echo "--- fanotify event parsing (watched path) ---"

> "$LOG_FILE"
echo "0" > "$SEQ_FILE"
WATCHED_PATHS=".env:secrets/:*.key"

# Simulate the parsing logic from _start_secret_monitor's while-read loop
_process_fanotify_line() {
  local line="$1"
  [ -z "$line" ] && return 0
  local path pid
  path="$(printf '%s' "$line" | grep -o '"path":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
  pid="$(printf '%s' "$line" | grep -o '"pid":[0-9]*' | head -1 | cut -d: -f2 || true)"
  [ -z "$path" ] && return 0
  if path_is_watched "$path"; then
    local event="{\"type\":\"file_access_event\",\"source\":\"fanotify\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"path\":\"$path\",\"pid\":${pid:-0},\"watched\":true}"
    write_log "$event"
  fi
}

# Test: .env file triggers event
_process_fanotify_line '{"path":"/workspace/.env","pid":42}'
result="$(cat "$LOG_FILE")"
assert_contains "watched .env triggers file_access_event" '"type":"file_access_event"' "$result"
assert_contains "event has fanotify source" '"source":"fanotify"' "$result"
assert_contains "event has correct path" '"path":"/workspace/.env"' "$result"
assert_contains "event has pid" '"pid":42' "$result"
assert_contains "event is tagged watched" '"watched":true' "$result"

# --- Test: secrets/ directory prefix match ---

echo ""
echo "--- fanotify event parsing (directory prefix) ---"

> "$LOG_FILE"
echo "0" > "$SEQ_FILE"

_process_fanotify_line '{"path":"/workspace/secrets/token.json","pid":99}'
result="$(cat "$LOG_FILE")"
assert_contains "secrets/ prefix triggers event" '"type":"file_access_event"' "$result"
assert_contains "secrets/ path is correct" '"path":"/workspace/secrets/token.json"' "$result"

# --- Test: *.key extension match ---

echo ""
echo "--- fanotify event parsing (extension glob) ---"

> "$LOG_FILE"
echo "0" > "$SEQ_FILE"

_process_fanotify_line '{"path":"/workspace/certs/server.key","pid":7}'
result="$(cat "$LOG_FILE")"
assert_contains "*.key extension triggers event" '"type":"file_access_event"' "$result"

# --- Test: non-watched path is skipped ---

echo ""
echo "--- fanotify event parsing (non-watched path) ---"

> "$LOG_FILE"
echo "0" > "$SEQ_FILE"

_process_fanotify_line '{"path":"/workspace/src/main.rs","pid":50}'
line_count=$(wc -l < "$LOG_FILE")
assert_eq "non-watched path produces no event" "0" "$line_count"

# --- Test: empty/malformed line is skipped ---

echo ""
echo "--- fanotify event parsing (empty line) ---"

> "$LOG_FILE"
echo "0" > "$SEQ_FILE"

_process_fanotify_line ''
line_count=$(wc -l < "$LOG_FILE")
assert_eq "empty line produces no event" "0" "$line_count"

# --- Test: stub fanotify-watcher piped output ---

echo ""
echo "--- stub fanotify-watcher piped integration ---"

> "$LOG_FILE"
echo "0" > "$SEQ_FILE"

# Create a stub script that mimics fanotify-watcher output
STUB_BIN="$TMPDIR/fanotify-watcher"
cat > "$STUB_BIN" <<'STUBEOF'
#!/bin/sh
echo '{"path":"/workspace/.env","pid":10}'
echo '{"path":"/workspace/src/app.js","pid":11}'
echo '{"path":"/workspace/secrets/db.key","pid":12}'
STUBEOF
chmod +x "$STUB_BIN"

# Pipe the stub through the same logic
"$STUB_BIN" | while IFS= read -r line; do
  _process_fanotify_line "$line"
done

result="$(cat "$LOG_FILE")"
# Should have events for .env and secrets/db.key, but not src/app.js
event_count=$(wc -l < "$LOG_FILE")
assert_eq "stub produces 2 events (watched only)" "2" "$event_count"
assert_contains "stub captures .env" '"/workspace/.env"' "$result"
assert_contains "stub captures secrets/*.key" '"/workspace/secrets/db.key"' "$result"
assert_not_contains "stub skips non-watched path" '"/workspace/src/app.js"' "$result"

# --- Cleanup ---

rm -rf "$TMPDIR"

echo ""
print_results
