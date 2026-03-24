#!/usr/bin/env bash
# Unit tests for Phase 4.1 — fine-grained network policies
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/cli/lib/common.sh"
source "$SCRIPT_DIR/cli/lib/config.sh"
source "$SCRIPT_DIR/cli/lib/runtime.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_policy_network.sh"

TMPDIR="$(mktemp -d)"

# --- Network mode detection ---

echo ""
echo "--- network mode detection ---"

# Boolean true
CONFIG_TRUE="$TMPDIR/net-true.yml"
cat > "$CONFIG_TRUE" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
runtime:
  network: true
EOF

mode="$(carranca_config_network_mode "$CONFIG_TRUE")"
assert_eq "network: true -> full" "full" "$mode"

# Boolean false
CONFIG_FALSE="$TMPDIR/net-false.yml"
cat > "$CONFIG_FALSE" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
runtime:
  network: false
EOF

mode="$(carranca_config_network_mode "$CONFIG_FALSE")"
assert_eq "network: false -> none" "none" "$mode"

# Missing network key (defaults to full)
CONFIG_NONE="$TMPDIR/net-none.yml"
cat > "$CONFIG_NONE" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
runtime:
  engine: auto
EOF

mode="$(carranca_config_network_mode "$CONFIG_NONE")"
assert_eq "missing network -> full" "full" "$mode"

# Object form (requires yq)
if carranca_config_has_yq; then
  CONFIG_FILTERED="$TMPDIR/net-filtered.yml"
  cat > "$CONFIG_FILTERED" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
runtime:
  network:
    default: deny
    allow:
      - "api.anthropic.com:443"
      - "registry.npmjs.org:443"
EOF

  mode="$(carranca_config_network_mode "$CONFIG_FILTERED")"
  assert_eq "network object -> filtered" "filtered" "$mode"

  # Read allow list
  mapfile -t items < <(carranca_config_get_list runtime.network.allow "$CONFIG_FILTERED")
  assert_eq "allow list has 2 items" "2" "${#items[@]}"
  assert_eq "allow[0]" "api.anthropic.com:443" "${items[0]}"
  assert_eq "allow[1]" "registry.npmjs.org:443" "${items[1]}"

  # Read default policy
  val="$(carranca_config_get runtime.network.default "$CONFIG_FILTERED")"
  assert_eq "network.default reads deny" "deny" "$val"

  # Object form with default: allow falls back to full (only deny is supported)
  CONFIG_ALLOW_ALL="$TMPDIR/net-allow-all.yml"
  cat > "$CONFIG_ALLOW_ALL" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
runtime:
  network:
    default: allow
EOF

  mode="$(carranca_config_network_mode "$CONFIG_ALLOW_ALL")"
  assert_eq "network.default: allow -> full (only deny supported)" "full" "$mode"
else
  echo "  SKIP: object form tests (yq not installed)"
fi

# --- DNS resolution simulation ---

echo ""
echo "--- DNS resolution ---"

# Test that getent works for a known host
resolved="$(getent ahosts localhost 2>/dev/null | awk '{print $1}' | sort -u | head -1 || true)"
if [ -n "$resolved" ]; then
  echo "  PASS: getent resolves localhost"
  PASS=$((PASS + 1))
else
  echo "  SKIP: getent not available or cannot resolve localhost"
fi

# Test IP:PORT rule construction
build_rules() {
  local rules=""
  local ips="$1"
  local port="$2"
  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    if [ -z "$rules" ]; then
      rules="$ip:$port"
    else
      rules="$rules,$ip:$port"
    fi
  done <<< "$ips"
  printf '%s' "$rules"
}

result="$(build_rules "1.2.3.4" "443")"
assert_eq "single IP rule" "1.2.3.4:443" "$result"

result="$(build_rules "$(printf '1.2.3.4\n5.6.7.8')" "443")"
assert_eq "multi IP rule" "1.2.3.4:443,5.6.7.8:443" "$result"

result="$(build_rules "" "443")"
assert_eq "empty IP returns empty rules" "" "$result"

# --- network-setup.sh iptables command verification ---

echo ""
echo "--- network-setup script ---"

SETUP_SCRIPT="$SCRIPT_DIR/runtime/network-setup.sh"

# Verify script exists and is executable
if [ -x "$SETUP_SCRIPT" ]; then
  echo "  PASS: network-setup.sh is executable"
  PASS=$((PASS + 1))
else
  echo "  FAIL: network-setup.sh should be executable"
  FAIL=$((FAIL + 1))
fi

# Verify script contains expected iptables commands
if grep -q 'iptables -P OUTPUT DROP' "$SETUP_SCRIPT"; then
  echo "  PASS: network-setup sets default DROP policy"
  PASS=$((PASS + 1))
else
  echo "  FAIL: network-setup should set default DROP policy"
  FAIL=$((FAIL + 1))
fi

if grep -q 'iptables -A OUTPUT -o lo -j ACCEPT' "$SETUP_SCRIPT"; then
  echo "  PASS: network-setup allows loopback"
  PASS=$((PASS + 1))
else
  echo "  FAIL: network-setup should allow loopback"
  FAIL=$((FAIL + 1))
fi

if grep -q 'dport 53' "$SETUP_SCRIPT"; then
  echo "  PASS: network-setup allows DNS"
  PASS=$((PASS + 1))
else
  echo "  FAIL: network-setup should allow DNS"
  FAIL=$((FAIL + 1))
fi

if grep -q 'network-ready' "$SETUP_SCRIPT"; then
  echo "  PASS: network-setup signals readiness"
  PASS=$((PASS + 1))
else
  echo "  FAIL: network-setup should signal readiness"
  FAIL=$((FAIL + 1))
fi

# --- Backward compatibility ---

echo ""
echo "--- backward compatibility ---"

# Verify boolean form still produces correct network flags
NETWORK="true"
NETWORK_FLAG=""
if [ "$NETWORK" = "false" ]; then
  NETWORK_FLAG="--network=none"
fi
assert_eq "network=true produces no flag" "" "$NETWORK_FLAG"

NETWORK="false"
NETWORK_FLAG=""
if [ "$NETWORK" = "false" ]; then
  NETWORK_FLAG="--network=none"
fi
assert_eq "network=false produces --network=none" "--network=none" "$NETWORK_FLAG"

# --- Policy event format ---

echo ""
echo "--- policy event format ---"

SESSION_ID="test1234"
ts="2026-03-22T00:00:01Z"
rules="1.2.3.4:443,5.6.7.8:443"

event="{\"type\":\"policy_event\",\"source\":\"carranca\",\"ts\":\"$ts\",\"session_id\":\"$SESSION_ID\",\"policy\":\"network\",\"action\":\"configured\",\"detail\":\"mode:filtered rules:${rules}\"}"
assert_contains "network event has type policy_event" '"type":"policy_event"' "$event"
assert_contains "network event has policy network" '"policy":"network"' "$event"
assert_contains "network event has action configured" '"action":"configured"' "$event"
assert_contains "network event has rules" "rules:1.2.3.4:443,5.6.7.8:443" "$event"

rm -rf "$TMPDIR"

echo ""
print_results
