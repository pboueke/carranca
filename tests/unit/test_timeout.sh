#!/usr/bin/env bash
# Unit tests for Phase 6.1 — --timeout flag and exit code 124
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_timeout.sh"

# --- Test --timeout arg parsing ---

echo ""
echo "--- --timeout arg parsing ---"

source "$SCRIPT_DIR/cli/lib/common.sh"
source "$SCRIPT_DIR/cli/lib/config.sh"

# Test: help shows --timeout
HELP_OUTPUT="$(bash "$SCRIPT_DIR/cli/run.sh" help 2>&1)"
assert_contains "help shows --timeout" "--timeout" "$HELP_OUTPUT"
assert_contains "help shows seconds" "<seconds>" "$HELP_OUTPUT"

# Test: --timeout without value
RC=0
bash "$SCRIPT_DIR/cli/run.sh" --timeout 2>&1 || RC=$?
assert_eq "--timeout without value exits non-zero" "1" "$RC"

# Test: --timeout with non-numeric value
RC=0
bash "$SCRIPT_DIR/cli/run.sh" --timeout abc 2>&1 || RC=$?
assert_eq "--timeout with non-numeric exits non-zero" "1" "$RC"

# Test: --timeout with zero
RC=0
bash "$SCRIPT_DIR/cli/run.sh" --timeout 0 2>&1 || RC=$?
assert_eq "--timeout 0 exits non-zero" "1" "$RC"

# Test: --timeout with negative
RC=0
bash "$SCRIPT_DIR/cli/run.sh" --timeout -5 2>&1 || RC=$?
assert_eq "--timeout negative exits non-zero" "1" "$RC"

# --- Test --timeout + config interaction ---

echo ""
echo "--- timeout config interaction ---"

TMPDIR="$(mktemp -d)"
CONFIG="$TMPDIR/test.yml"

cat > "$CONFIG" <<'EOF'
agents:
  - name: test
    command: "echo hello"
policy:
  max_duration: 600
EOF

CARRANCA_CONFIG_FILE="$CONFIG"
MAX_DURATION="$(carranca_config_get policy.max_duration "$CONFIG")"
assert_eq "config reads max_duration" "600" "$MAX_DURATION"

# Simulate --timeout logic (minimum wins)
CLI_TIMEOUT="300"
if [ -n "$CLI_TIMEOUT" ]; then
  if [ -n "$MAX_DURATION" ] && [ "$MAX_DURATION" -gt 0 ] 2>/dev/null; then
    if [ "$CLI_TIMEOUT" -lt "$MAX_DURATION" ]; then
      MAX_DURATION="$CLI_TIMEOUT"
    fi
  else
    MAX_DURATION="$CLI_TIMEOUT"
  fi
fi
assert_eq "CLI timeout wins when smaller" "300" "$MAX_DURATION"

# When config is smaller
MAX_DURATION="600"
CLI_TIMEOUT="900"
if [ -n "$CLI_TIMEOUT" ]; then
  if [ -n "$MAX_DURATION" ] && [ "$MAX_DURATION" -gt 0 ] 2>/dev/null; then
    if [ "$CLI_TIMEOUT" -lt "$MAX_DURATION" ]; then
      MAX_DURATION="$CLI_TIMEOUT"
    fi
  else
    MAX_DURATION="$CLI_TIMEOUT"
  fi
fi
assert_eq "config wins when smaller" "600" "$MAX_DURATION"

# When config is empty
MAX_DURATION=""
CLI_TIMEOUT="300"
if [ -n "$CLI_TIMEOUT" ]; then
  if [ -n "$MAX_DURATION" ] && [ "$MAX_DURATION" -gt 0 ] 2>/dev/null; then
    if [ "$CLI_TIMEOUT" -lt "$MAX_DURATION" ]; then
      MAX_DURATION="$CLI_TIMEOUT"
    fi
  else
    MAX_DURATION="$CLI_TIMEOUT"
  fi
fi
assert_eq "CLI timeout used when config empty" "300" "$MAX_DURATION"

# --- Test timeout exit code detection ---

echo ""
echo "--- timeout exit code 124 ---"

TIMEOUT_LOG="$TMPDIR/timeout.jsonl"
cat > "$TIMEOUT_LOG" <<'EOF'
{"type":"session_event","source":"carranca","event":"start","ts":"2026-03-22T00:00:00Z","session_id":"test1234"}
{"type":"policy_event","source":"carranca","ts":"2026-03-22T00:05:00Z","session_id":"test1234","policy":"max_duration","action":"timeout","detail":"session killed after 300s"}
{"type":"session_event","source":"carranca","event":"logger_stop","ts":"2026-03-22T00:05:01Z","session_id":"test1234"}
EOF

# Simulate post-agent timeout detection from run.sh
AGENT_EXIT_CODE=1
if [ "$AGENT_EXIT_CODE" != "71" ] && [ -f "$TIMEOUT_LOG" ]; then
  if grep -q '"policy":"max_duration".*"action":"timeout"' "$TIMEOUT_LOG" 2>/dev/null; then
    AGENT_EXIT_CODE=124
  fi
fi
assert_eq "timeout detected, exit code overridden to 124" "124" "$AGENT_EXIT_CODE"

# Test: no timeout event → exit code preserved
NORMAL_LOG="$TMPDIR/normal.jsonl"
cat > "$NORMAL_LOG" <<'EOF'
{"type":"session_event","source":"carranca","event":"start","ts":"2026-03-22T00:00:00Z","session_id":"test1234"}
{"type":"session_event","source":"carranca","event":"logger_stop","ts":"2026-03-22T00:05:00Z","session_id":"test1234"}
EOF

AGENT_EXIT_CODE=42
if [ "$AGENT_EXIT_CODE" != "71" ] && [ -f "$NORMAL_LOG" ]; then
  if grep -q '"policy":"max_duration".*"action":"timeout"' "$NORMAL_LOG" 2>/dev/null; then
    AGENT_EXIT_CODE=124
  fi
fi
assert_eq "no timeout: exit code preserved" "42" "$AGENT_EXIT_CODE"

# Test: logger loss (71) is not overridden
AGENT_EXIT_CODE=71
if [ "$AGENT_EXIT_CODE" != "71" ] && [ -f "$TIMEOUT_LOG" ]; then
  if grep -q '"policy":"max_duration".*"action":"timeout"' "$TIMEOUT_LOG" 2>/dev/null; then
    AGENT_EXIT_CODE=124
  fi
fi
assert_eq "logger loss (71) not overridden by timeout" "71" "$AGENT_EXIT_CODE"

rm -rf "$TMPDIR"

echo ""
print_results
