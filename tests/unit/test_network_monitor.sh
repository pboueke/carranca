#!/usr/bin/env bash
# Unit tests for network monitor functions in runtime/logger.sh
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
  if echo "$haystack" | grep -Fq "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -Fq "$needle"; then
    echo "  FAIL: $desc (should not contain '$needle')"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  fi
}

echo "=== test_network_monitor.sh ==="

# Extract network monitor functions from logger.sh
eval "$(sed -n '/^_hex_to_ip()/,/^}/p' "$SCRIPT_DIR/runtime/logger.sh")"
eval "$(sed -n '/^_hex_to_port()/,/^}/p' "$SCRIPT_DIR/runtime/logger.sh")"
eval "$(sed -n '/^_parse_proc_net_tcp()/,/^}/p' "$SCRIPT_DIR/runtime/logger.sh")"

TMPDIR="$(mktemp -d)"

# --- Test _hex_to_ip ---

echo ""
echo "--- _hex_to_ip ---"

# 0100007F = 127.0.0.1 (little-endian: 7F=127, 00=0, 00=0, 01=1)
result="$(_hex_to_ip "0100007F")"
assert_eq "_hex_to_ip 0100007F -> 127.0.0.1" "127.0.0.1" "$result"

# 6812680A — little-endian: 0A=10, 68=104, 12=18, 68=104
result="$(_hex_to_ip "6812680A")"
assert_eq "_hex_to_ip 6812680A -> 10.104.18.104" "10.104.18.104" "$result"

# 0101A8C0 = 192.168.1.1 (little-endian: C0=192, A8=168, 01=1, 01=1)
result="$(_hex_to_ip "0101A8C0")"
assert_eq "_hex_to_ip 0101A8C0 -> 192.168.1.1" "192.168.1.1" "$result"

# IPv6: 32 hex chars — verify it produces colon-separated output
result="$(_hex_to_ip "00000000000000000000000001000000")"
assert_contains "_hex_to_ip produces colon notation for IPv6" ":" "$result"

echo ""
echo "--- _hex_to_port ---"

result="$(_hex_to_port "01BB")"
assert_eq "_hex_to_port 01BB -> 443" "443" "$result"

result="$(_hex_to_port "0050")"
assert_eq "_hex_to_port 0050 -> 80" "80" "$result"

result="$(_hex_to_port "1F90")"
assert_eq "_hex_to_port 1F90 -> 8080" "8080" "$result"

result="$(_hex_to_port "0016")"
assert_eq "_hex_to_port 0016 -> 22" "22" "$result"

# --- Test _parse_proc_net_tcp ---

echo ""
echo "--- _parse_proc_net_tcp ---"

# Create a synthetic /proc/net/tcp file
FAKE_TCP="$TMPDIR/fake_tcp"
cat > "$FAKE_TCP" << 'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:0035 0100007F:A1B2 01 00000000:00000000 00:00000000 00000000     0        0 12345 1 0000000000000000 100 0 0 10 0
   1: 0101A8C0:C000 DB0814AC:01BB 01 00000000:00000000 00:00000000 00000000  1000        0 23456 1 0000000000000000 100 0 0 10 0
   2: 0101A8C0:C001 2E16A4D8:0050 02 00000000:00000000 00:00000000 00000000  1000        0 34567 1 0000000000000000 100 0 0 10 0
   3: 0101A8C0:C002 0101A8C0:1F90 06 00000000:00000000 00:00000000 00000000  1000        0 45678 1 0000000000000000 100 0 0 10 0
   4: 0101A8C0:C003 5E38A9D1:01BB 0A 00000000:00000000 00:00000000 00000000  1000        0 56789 1 0000000000000000 100 0 0 10 0
EOF

# Parse and capture output
result="$(_parse_proc_net_tcp "$FAKE_TCP")"

# Line 0: loopback remote (0100007F) — should be filtered out
assert_not_contains "loopback connections are filtered" "127.0.0.1" "$result"

# Line 1: ESTABLISHED to 172.20.8.219:443 (DB0814AC little-endian: AC=172, 14=20, 08=8, DB=219)
assert_contains "ESTABLISHED connection to 172.20.8.219" "172.20.8.219 443 ESTABLISHED" "$result"

# Line 2: SYN_SENT to 216.164.22.46:80 (2E16A4D8 little-endian: D8=216, A4=164, 16=22, 2E=46)
assert_contains "SYN_SENT connection to 216.164.22.46" "216.164.22.46 80 SYN_SENT" "$result"

# Line 3: TIME_WAIT (state 06) — should be excluded
line_count="$(echo "$result" | wc -l)"
assert_eq "_parse_proc_net_tcp returns exactly 2 connections" "2" "$line_count"

# Line 4: LISTEN (state 0A) — should be excluded
assert_not_contains "LISTEN state is excluded" "LISTEN" "$result"

# Test with non-existent file (should return empty, not error)
result="$(_parse_proc_net_tcp "$TMPDIR/nonexistent" 2>&1)"
assert_eq "_parse_proc_net_tcp with missing file returns empty" "" "$result"

# Test with only loopback connections
LOOPBACK_ONLY="$TMPDIR/loopback_tcp"
cat > "$LOOPBACK_ONLY" << 'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:0035 0100007F:A1B2 01 00000000:00000000 00:00000000 00000000     0        0 12345 1 0000000000000000 100 0 0 10 0
EOF
result="$(_parse_proc_net_tcp "$LOOPBACK_ONLY")"
assert_eq "loopback-only file returns empty" "" "$result"

# Test with only non-matching states
STATE_ONLY="$TMPDIR/state_tcp"
cat > "$STATE_ONLY" << 'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0101A8C0:C000 DB0814AC:01BB 06 00000000:00000000 00:00000000 00000000  1000        0 23456 1 0000000000000000 100 0 0 10 0
   1: 0101A8C0:C001 DB0814AC:01BB 0A 00000000:00000000 00:00000000 00000000  1000        0 34567 1 0000000000000000 100 0 0 10 0
EOF
result="$(_parse_proc_net_tcp "$STATE_ONLY")"
assert_eq "non-matching states return empty" "" "$result"

rm -rf "$TMPDIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
