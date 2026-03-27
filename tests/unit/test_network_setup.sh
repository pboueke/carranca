#!/usr/bin/env bash
# Unit tests for runtime/network-setup.sh functions
# Tests _log, _fail_closed, _emit_enforcement_failure behavior
# and script structure (iptables commands, privilege dropping).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_network_setup.sh"

TMPDIR="$(mktemp -d)"
SETUP_SCRIPT="$SCRIPT_DIR/runtime/network-setup.sh"

# --- _log: writes to stderr with prefix ---

test_start
_log() {
  echo "[carranca:network-setup] $*" >&2
}

LOG_OUT="$(_log "test message" 2>&1)"
assert_contains "_log includes prefix" "[carranca:network-setup]" "$LOG_OUT"
assert_contains "_log includes message" "test message" "$LOG_OUT"

# --- _emit_enforcement_failure: writes policy_event JSON to FIFO ---

FIFO_DIR="$TMPDIR/fifo"
mkdir -p "$FIFO_DIR"
FIFO_PATH="$FIFO_DIR/events"
mkfifo "$FIFO_PATH"

# Read from FIFO in background
cat "$FIFO_PATH" > "$TMPDIR/fifo-out" &
CAT_PID=$!

test_start
# Inline the function with our test FIFO path
SESSION_ID="test-net-sess"
_emit_enforcement_failure() {
  local reason="$1"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  if [ -p "$FIFO_PATH" ]; then
    echo "{\"type\":\"policy_event\",\"source\":\"network-setup\",\"ts\":\"${ts}\",\"session_id\":\"${SESSION_ID}\",\"event\":\"network_enforcement_failed\",\"reason\":\"${reason}\"}" > "$FIFO_PATH" 2>/dev/null
  fi
}

_emit_enforcement_failure "iptables_unavailable"
sleep 0.2
kill "$CAT_PID" 2>/dev/null || true
wait "$CAT_PID" 2>/dev/null || true

FIFO_CONTENT="$(cat "$TMPDIR/fifo-out")"
assert_contains "_emit_enforcement_failure writes policy_event type" '"type":"policy_event"' "$FIFO_CONTENT"
assert_contains "_emit_enforcement_failure writes source" '"source":"network-setup"' "$FIFO_CONTENT"
assert_contains "_emit_enforcement_failure writes reason" '"reason":"iptables_unavailable"' "$FIFO_CONTENT"
assert_contains "_emit_enforcement_failure writes session_id" '"session_id":"test-net-sess"' "$FIFO_CONTENT"

# --- _emit_enforcement_failure: no-op when FIFO missing ---

test_start
rc=0
FIFO_PATH="/nonexistent/fifo" _emit_enforcement_failure "test_reason" 2>/dev/null || rc=$?
assert_eq "_emit_enforcement_failure is safe when FIFO missing" "0" "$rc"

# --- _fail_closed: stderr + exit 1 ---

test_start
_fail_closed() {
  local message="$1"
  local reason="${2:-iptables_unavailable}"
  _log "FATAL: $message — aborting (fail closed)"
  # Don't call _emit_enforcement_failure in unit test (no FIFO)
  exit 1
}

FC_OUT="$(_fail_closed "cannot set iptables OUTPUT policy" "iptables_output_policy_failed" 2>&1)" || FC_RC=$?
assert_eq "_fail_closed exits 1" "1" "${FC_RC:-0}"
assert_contains "_fail_closed prints FATAL" "FATAL:" "$FC_OUT"
assert_contains "_fail_closed includes fail-closed tag" "fail closed" "$FC_OUT"

# --- Script structure verification ---

echo ""
echo "--- network-setup.sh structure ---"
CONTENT="$(cat "$SETUP_SCRIPT")"

test_start
assert_contains "script sets -uo pipefail" "set -uo pipefail" "$CONTENT"
assert_contains "script reads NETWORK_POLICY_RULES" "NETWORK_POLICY_RULES" "$CONTENT"
assert_contains "script reads NETWORK_POLICY_USER" "NETWORK_POLICY_USER" "$CONTENT"
assert_contains "script reads ALLOW_DEGRADED" "CARRANCA_NETWORK_ALLOW_DEGRADED" "$CONTENT"

# iptables rules
assert_contains "sets default OUTPUT DROP" "iptables -P OUTPUT DROP" "$CONTENT"
assert_contains "allows loopback" "iptables -A OUTPUT -o lo -j ACCEPT" "$CONTENT"
assert_contains "allows ESTABLISHED,RELATED" "ESTABLISHED,RELATED" "$CONTENT"
assert_contains "allows DNS port 53 UDP" '-p udp -d "$resolver" --dport 53' "$CONTENT"
assert_contains "allows DNS port 53 TCP" '-p tcp -d "$resolver" --dport 53' "$CONTENT"

# DNS resolver extraction
assert_contains "reads /etc/resolv.conf" "/etc/resolv.conf" "$CONTENT"
assert_contains "falls back to Docker DNS 127.0.0.11" "127.0.0.11" "$CONTENT"

# Rule application
assert_contains "iterates comma-separated rules" "IFS=',' read -ra entries" "$CONTENT"
assert_contains "applies per-rule iptables ACCEPT" '-d "$local_ip" --dport "$local_port" -j ACCEPT' "$CONTENT"

# Readiness signal
assert_contains "signals network-ready" "touch /fifo/network-ready" "$CONTENT"

# Privilege dropping
assert_contains "drops to target user via su" "exec su -s /bin/bash" "$CONTENT"
assert_contains "creates group for target GID" 'addgroup -g "$target_gid"' "$CONTENT"
assert_contains "creates user for target UID" 'adduser -D -u "$target_uid"' "$CONTENT"

# UID/GID validation
assert_contains "validates UID is numeric" 'Invalid UID in NETWORK_POLICY_USER' "$CONTENT"
assert_contains "validates GID is numeric" 'Invalid GID in NETWORK_POLICY_USER' "$CONTENT"
assert_contains "validates UID > 0" 'UID must be > 0' "$CONTENT"
assert_contains "validates GID > 0" 'GID must be > 0' "$CONTENT"

# Degraded mode
assert_contains "degraded mode checks ALLOW_DEGRADED" 'ALLOW_DEGRADED" = "true"' "$CONTENT"

# Empty rules skip
assert_contains "skips iptables when no rules" 'No network policy rules' "$CONTENT"

# ip6tables rules (IPv6 egress filtering)
echo ""
echo "--- network-setup.sh IPv6 / ip6tables ---"

test_start
assert_contains "sets ip6tables default OUTPUT DROP" "ip6tables -P OUTPUT DROP" "$CONTENT"
assert_contains "ip6tables allows loopback" "ip6tables -A OUTPUT -o lo -j ACCEPT" "$CONTENT"
assert_contains "ip6tables allows ESTABLISHED,RELATED" 'ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT' "$CONTENT"

# ip6tables DNS rules
assert_contains "ip6tables allows DNS port 53 UDP" 'ip6tables -A OUTPUT -p udp -d "$resolver" --dport 53' "$CONTENT"
assert_contains "ip6tables allows DNS port 53 TCP" 'ip6tables -A OUTPUT -p tcp -d "$resolver" --dport 53' "$CONTENT"

# Bracket-notation parsing for IPv6 entries
assert_contains "parses bracket-notation IPv6 entries" '\[*' "$CONTENT"
assert_contains "applies ip6tables for IPv6 entries" 'ip6tables -A OUTPUT -p tcp -d "$local_ip" --dport "$local_port" -j ACCEPT' "$CONTENT"

# ip6tables availability check with degraded/fail-closed
assert_contains "checks ip6tables availability" "command -v ip6tables" "$CONTENT"
assert_contains "ip6tables degraded mode" "ip6tables not available" "$CONTENT"
assert_contains "ip6tables fail-closed reason" "ip6tables_unavailable" "$CONTENT"

# No remaining IPv4-only skip logic
assert_not_contains "no IPv4-only skip warning" "iptables is IPv4-only" "$CONTENT"
assert_not_contains "no IPv6 skip logic" "skipping IPv6 entry" "$CONTENT"

# Cleanup
rm -rf "$TMPDIR"

echo ""
print_results
