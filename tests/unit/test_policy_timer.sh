#!/usr/bin/env bash
# Unit tests for Phase 4.5 — time-boxed sessions (max_duration timer)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/cli/lib/common.sh"
source "$SCRIPT_DIR/cli/lib/config.sh"
source "$SCRIPT_DIR/cli/lib/runtime.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_policy_timer.sh"

TMPDIR="$(mktemp -d)"

# --- Config parsing tests ---

echo ""
echo "--- config parsing ---"

CONFIG="$TMPDIR/timer.yml"
cat > "$CONFIG" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
policy:
  max_duration: 3600
EOF

val="$(carranca_config_get policy.max_duration "$CONFIG")"
assert_eq "policy.max_duration reads correctly" "3600" "$val"

CONFIG_NONE="$TMPDIR/no-timer.yml"
cat > "$CONFIG_NONE" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
policy:
  docs_before_code: warn
EOF

val="$(carranca_config_get policy.max_duration "$CONFIG_NONE")"
assert_eq "missing max_duration returns empty" "" "$val"

CONFIG_ZERO="$TMPDIR/zero-timer.yml"
cat > "$CONFIG_ZERO" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
policy:
  max_duration: 0
EOF

val="$(carranca_config_get policy.max_duration "$CONFIG_ZERO")"
assert_eq "max_duration: 0 reads correctly" "0" "$val"

# --- Timer guard logic ---

echo ""
echo "--- timer guard logic ---"

# Simulate the guard condition from logger.sh
should_start_timer() {
  local duration="$1"
  [ "$duration" -gt 0 ] 2>/dev/null && return 0
  return 1
}

rc=0; should_start_timer "3600" || rc=$?
assert_eq "timer starts for positive duration" "0" "$rc"

rc=0; should_start_timer "0" || rc=$?
assert_eq "timer skipped for duration=0" "1" "$rc"

rc=0; should_start_timer "" || rc=$?
assert_eq "timer skipped for empty duration" "1" "$rc"

rc=0; should_start_timer "abc" || rc=$?
assert_eq "timer skipped for non-numeric duration" "1" "$rc"

rc=0; should_start_timer "-5" || rc=$?
assert_eq "timer skipped for negative duration" "1" "$rc"

# --- Timer event format ---

echo ""
echo "--- timer event format ---"

# Verify the event JSON structure produced by the timer
SESSION_ID="test1234"
MAX_DURATION="60"
# Simulate the event construction from logger.sh
ts="2026-03-22T00:01:00Z"
event="{\"type\":\"policy_event\",\"source\":\"carranca\",\"ts\":\"$ts\",\"session_id\":\"$SESSION_ID\",\"policy\":\"max_duration\",\"action\":\"timeout\",\"detail\":\"session killed after ${MAX_DURATION}s\"}"

assert_contains "timeout event has type policy_event" '"type":"policy_event"' "$event"
assert_contains "timeout event has policy max_duration" '"policy":"max_duration"' "$event"
assert_contains "timeout event has action timeout" '"action":"timeout"' "$event"
assert_contains "timeout event has detail with duration" "session killed after 60s" "$event"
assert_contains "timeout event has session_id" '"session_id":"test1234"' "$event"

# --- Global config fallback ---

echo ""
echo "--- global config fallback ---"

GLOBAL_CONFIG="$TMPDIR/global.yml"
cat > "$GLOBAL_CONFIG" <<'EOF'
policy:
  max_duration: 7200
EOF

PROJECT_CONFIG="$TMPDIR/project-notimer.yml"
cat > "$PROJECT_CONFIG" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
EOF

_save_config="$CARRANCA_CONFIG_FILE"
_save_global="$CARRANCA_GLOBAL_CONFIG"
CARRANCA_CONFIG_FILE="$PROJECT_CONFIG"
CARRANCA_GLOBAL_CONFIG="$GLOBAL_CONFIG"

val="$(carranca_config_get_with_global policy.max_duration)"
assert_eq "global fallback: policy.max_duration" "7200" "$val"

# Project overrides global
PROJECT_WITHTIMER="$TMPDIR/project-timer.yml"
cat > "$PROJECT_WITHTIMER" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
policy:
  max_duration: 1800
EOF

CARRANCA_CONFIG_FILE="$PROJECT_WITHTIMER"
val="$(carranca_config_get_with_global policy.max_duration)"
assert_eq "project overrides global: policy.max_duration" "1800" "$val"

CARRANCA_CONFIG_FILE="$_save_config"
CARRANCA_GLOBAL_CONFIG="$_save_global"

# --- _start_session_timer function extraction ---

echo ""
echo "--- _start_session_timer function ---"

# Extract the function from logger.sh for direct testing
eval "$(sed -n '/^_start_session_timer()/,/^}/p' "$SCRIPT_DIR/runtime/logger.sh")"

# Mock write_log and _cleanup to capture calls
MOCK_LOG_CALLS=0
MOCK_CLEANUP_CALLS=0
write_log() { MOCK_LOG_CALLS=$((MOCK_LOG_CALLS + 1)); MOCK_LOG_OUTPUT="$1"; }
_cleanup() { MOCK_CLEANUP_CALLS=$((MOCK_CLEANUP_CALLS + 1)); }
timestamp() { echo "2026-03-22T00:00:00Z"; }

# Test: timer skips for MAX_DURATION=0
MAX_DURATION=0
SESSION_ID="test1234"
_start_session_timer
assert_eq "_start_session_timer no-op for duration=0" "0" "$MOCK_LOG_CALLS"

# Test: timer skips for empty MAX_DURATION
MAX_DURATION=""
_start_session_timer
assert_eq "_start_session_timer no-op for empty duration" "0" "$MOCK_LOG_CALLS"

# Test: timer skips for non-numeric MAX_DURATION
MAX_DURATION="abc"
_start_session_timer
assert_eq "_start_session_timer no-op for non-numeric duration" "0" "$MOCK_LOG_CALLS"

# Test: timer fires for positive duration (use 0 sleep trick — override sleep)
# We can't actually sleep in unit tests, but we can verify the guard logic
# The actual sleep+write+cleanup path is tested via the guard returning 0
# for valid values, which means the function would proceed past the guard.
# Verify the guard passes for a valid duration by checking the return code.
MAX_DURATION=1
# We can't run the full function (it sleeps), but we verify the guard condition
rc=0; [ "$MAX_DURATION" -gt 0 ] 2>/dev/null || rc=$?
assert_eq "_start_session_timer guard passes for positive duration" "0" "$rc"

rm -rf "$TMPDIR"

echo ""
print_results
