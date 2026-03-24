#!/usr/bin/env bash
# Unit tests for logger.sh observability orchestration functions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0
FAIL=0

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

echo "=== test_logger_observability_orchestration.sh ==="

TMPDIR="$(mktemp -d)"
LOG_FILE="$TMPDIR/test.jsonl"
SESSION_ID="test-session-1234"

timestamp() {
  printf '2026-03-23T12:00:00Z'
}

write_log() {
  printf '%s\n' "$1" >> "$LOG_FILE"
}

eval "$(sed -n '/^_start_resource_sampler()/,/^}/p' "$SCRIPT_DIR/runtime/logger.sh")"
eval "$(sed -n '/^_start_execve_tracer()/,/^}/p' "$SCRIPT_DIR/runtime/logger.sh")"
eval "$(sed -n '/^_start_network_monitor()/,/^}/p' "$SCRIPT_DIR/runtime/logger.sh")"

echo ""
echo "--- _start_resource_sampler ---"

> "$LOG_FILE"
_find_agent_cgroup() {
  return 1
}
_read_cgroup_stats() {
  printf '%s' ''
}
sleep() {
  :
}

_start_resource_sampler 1 "missing-agent"
result="$(cat "$LOG_FILE")"
assert_contains "missing cgroup emits degraded event" '"event":"degraded"' "$result"
assert_contains "missing cgroup reason is recorded" '"reason":"cgroup_not_found"' "$result"

unset -f _find_agent_cgroup _read_cgroup_stats sleep

echo ""
echo "--- _start_execve_tracer ---"

> "$LOG_FILE"
EXECVE_TRACING="true"
ORIGINAL_PATH="$PATH"
EMPTY_BIN_DIR="$TMPDIR/empty-bin"
mkdir -p "$EMPTY_BIN_DIR"
PATH="$EMPTY_BIN_DIR"

_start_execve_tracer
PATH="$ORIGINAL_PATH"
result="$(cat "$LOG_FILE")"
assert_contains "missing strace emits degraded event" '"event":"degraded"' "$result"
assert_contains "missing strace reason is recorded" '"reason":"strace_unavailable"' "$result"

unset EXECVE_TRACING
unset ORIGINAL_PATH
unset EMPTY_BIN_DIR

echo ""
echo "--- _start_network_monitor ---"

> "$LOG_FILE"
NETWORK_LOGGING="true"
NETWORK_INTERVAL="1"
PARSE_CALLS=0

_parse_proc_net_tcp() {
  PARSE_CALLS=$((PARSE_CALLS + 1))
  if [ "$PARSE_CALLS" -eq 1 ]; then
    printf '%s\n' "104.18.12.33 443 ESTABLISHED"
  fi
}

sleep() {
  kill "$BASHPID" 2>/dev/null || exit 0
}

_start_network_monitor >/dev/null 2>&1 &
NETMON_TEST_PID=$!
wait "$NETMON_TEST_PID" 2>/dev/null || true

result="$(cat "$LOG_FILE")"
assert_contains "new connection emits network_event" '"type":"network_event"' "$result"
assert_contains "network event records destination IP" '"dest_ip":"104.18.12.33"' "$result"
assert_contains "network event records destination port" '"dest_port":443' "$result"
assert_contains "network event records connection state" '"state":"ESTABLISHED"' "$result"

unset -f _parse_proc_net_tcp sleep
unset NETWORK_LOGGING NETWORK_INTERVAL

rm -rf "$TMPDIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
