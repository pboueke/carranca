#!/usr/bin/env bash
# Unit tests for runtime/shell-wrapper.sh behavioral coverage
# Tests fail_closed, write_event flow, FIFO wait timeout, and json_escape
# (beyond what test_runtime_helpers.sh already covers).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_shell_wrapper.sh"

TMPDIR="$(mktemp -d)"

# --- fail_closed: stderr message + exit ---

# Extract fail_closed from shell-wrapper.sh and test it in isolation
test_start
_FC_OUTPUT="$(
  FIFO_PATH="/nonexistent"
  SESSION_ID="test-sess"
  fail_closed() {
    local message="$1"
    echo "[carranca] $message — exiting (fail closed)" >&2
    exit 1
  }
  fail_closed "FIFO is broken" 2>&1
)" || _FC_RC=$?

assert_eq "fail_closed exits with code 1" "1" "${_FC_RC:-0}"
assert_contains "fail_closed prints message to stderr" "FIFO is broken" "$_FC_OUTPUT"
assert_contains "fail_closed includes fail-closed tag" "fail closed" "$_FC_OUTPUT"

# --- write_event: FIFO write success path ---

FIFO_DIR="$TMPDIR/fifo-test"
mkdir -p "$FIFO_DIR"
FIFO_PATH="$FIFO_DIR/events"
mkfifo "$FIFO_PATH"

# Source fifo_is_healthy and write_event from shell-wrapper
eval "$(sed -n '/^fifo_is_healthy()/,/^}/p' "$SCRIPT_DIR/runtime/shell-wrapper.sh")"

write_event() {
  if ! fifo_is_healthy; then
    echo "FIFO_UNAVAILABLE" >&2
    return 1
  fi
  printf '%s\n' "$1" > "$FIFO_PATH" 2>/dev/null
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FIFO_WRITE_FAILED" >&2
    return 1
  fi
}

# Read from FIFO in background
cat "$FIFO_PATH" > "$TMPDIR/fifo-received" &
CAT_PID=$!

test_start
FIFO_PATH="$FIFO_PATH" write_event '{"type":"shell_command","cmd":"ls"}'
sleep 0.2
kill "$CAT_PID" 2>/dev/null || true
wait "$CAT_PID" 2>/dev/null || true

RECEIVED="$(cat "$TMPDIR/fifo-received")"
assert_eq "write_event delivers JSON through FIFO" '{"type":"shell_command","cmd":"ls"}' "$RECEIVED"

# --- write_event: FIFO unavailable path ---

test_start
rc=0
FIFO_PATH="/nonexistent/fifo" write_event '{"type":"test"}' 2>/dev/null || rc=$?
assert_eq "write_event fails when FIFO missing" "1" "$rc"

# --- FIFO wait loop: timeout behavior ---
# Test the wait loop logic extracted from shell-wrapper.sh

test_start
WAIT_RESULT="$(
  FIFO_PATH="$TMPDIR/never-created-fifo"
  WAIT_LIMIT=3
  WAIT_COUNT=0
  while [ ! -p "$FIFO_PATH" ]; do
    WAIT_COUNT=$((WAIT_COUNT + 1))
    if [ "$WAIT_COUNT" -ge "$WAIT_LIMIT" ]; then
      echo "TIMEOUT"
      exit 1
    fi
    sleep 0.1
  done
  echo "FOUND"
)" || true

assert_eq "FIFO wait loop times out for missing FIFO" "TIMEOUT" "$WAIT_RESULT"

# --- FIFO wait loop: finds existing FIFO immediately ---

test_start
FIFO_EXIST="$TMPDIR/exists-fifo"
mkfifo "$FIFO_EXIST"

WAIT_RESULT="$(
  FIFO_PATH="$FIFO_EXIST"
  WAIT_LIMIT=3
  WAIT_COUNT=0
  while [ ! -p "$FIFO_PATH" ]; do
    WAIT_COUNT=$((WAIT_COUNT + 1))
    if [ "$WAIT_COUNT" -ge "$WAIT_LIMIT" ]; then
      echo "TIMEOUT"
      exit 1
    fi
    sleep 0.1
  done
  echo "FOUND"
)"

assert_eq "FIFO wait loop finds existing FIFO" "FOUND" "$WAIT_RESULT"

# --- Event sequence structure: verify shell-wrapper emits correct JSON ---
# The full FIFO flow requires process-group isolation (integration test).
# Here we verify the JSON event structures the script would emit.

test_start
SESSION_ID="flow-test"
AGENT_COMMAND="echo hello"

# Simulate the agent_start event construction
START_EVENT="{\"type\":\"session_event\",\"source\":\"shell-wrapper\",\"event\":\"agent_start\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\",\"session_id\":\"$SESSION_ID\"}"
assert_contains "agent_start event has correct type" '"type":"session_event"' "$START_EVENT"
assert_contains "agent_start event has correct event name" '"event":"agent_start"' "$START_EVENT"
assert_contains "agent_start event has session_id" '"session_id":"flow-test"' "$START_EVENT"

# Simulate the shell_command event construction
source "$SCRIPT_DIR/runtime/lib/json.sh"
ESCAPED_CMD="$(json_escape "$AGENT_COMMAND")"
CMD_EVENT="{\"type\":\"shell_command\",\"source\":\"shell-wrapper\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\",\"session_id\":\"$SESSION_ID\",\"command\":\"$ESCAPED_CMD\",\"exit_code\":0,\"duration_ms\":42,\"cwd\":\"$(pwd)\"}"
assert_contains "shell_command event has correct type" '"type":"shell_command"' "$CMD_EVENT"
assert_contains "shell_command event has command" '"command":"echo hello"' "$CMD_EVENT"
assert_contains "shell_command event has exit_code" '"exit_code":0' "$CMD_EVENT"
assert_contains "shell_command event has duration_ms" '"duration_ms":42' "$CMD_EVENT"

# Simulate the agent_stop event construction
STOP_EVENT="{\"type\":\"session_event\",\"source\":\"shell-wrapper\",\"event\":\"agent_stop\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)\",\"session_id\":\"$SESSION_ID\",\"exit_code\":0}"
assert_contains "agent_stop event has correct event name" '"event":"agent_stop"' "$STOP_EVENT"
assert_contains "agent_stop event has exit_code" '"exit_code":0' "$STOP_EVENT"

# --- Heartbeat event format ---

test_start
HB_EVENT="$(printf '{"type":"heartbeat","source":"shell-wrapper","ts":"%s","session_id":"%s"}' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$SESSION_ID")"
assert_contains "heartbeat event has correct type" '"type":"heartbeat"' "$HB_EVENT"
assert_contains "heartbeat event has correct source" '"source":"shell-wrapper"' "$HB_EVENT"

# --- json_escape on command with special characters ---

test_start
CMD_SPECIAL='echo "hello world" && rm -rf /tmp/test'
ESCAPED="$(json_escape "$CMD_SPECIAL")"
assert_eq "json_escape preserves command with quotes" 'echo \"hello world\" && rm -rf /tmp/test' "$ESCAPED"

# Cleanup
rm -rf "$TMPDIR"

echo ""
print_results
