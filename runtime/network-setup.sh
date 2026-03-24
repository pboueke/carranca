#!/usr/bin/env bash
# carranca network-setup — sets up iptables rules for fine-grained network policies
#
# This script runs as the agent container entrypoint when network policies are active.
# It starts as root (container default), applies iptables rules, then drops
# privileges to the target user before exec-ing shell-wrapper.
#
# Environment:
#   NETWORK_POLICY_RULES  — comma-separated IP:PORT pairs (pre-resolved by cli/run.sh)
#   NETWORK_POLICY_USER   — UID:GID to drop to after iptables setup
#   CARRANCA_NETWORK_ALLOW_DEGRADED — if "true", warn-and-continue when iptables
#       is unavailable instead of aborting (preserves legacy behavior).
#   All shell-wrapper env vars are passed through.
set -uo pipefail

RULES="${NETWORK_POLICY_RULES:-}"
TARGET_USER="${NETWORK_POLICY_USER:-}"
ALLOW_DEGRADED="${CARRANCA_NETWORK_ALLOW_DEGRADED:-false}"

_log() {
  echo "[carranca:network-setup] $*" >&2
}

_emit_enforcement_failure() {
  local reason="$1"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  if [ -p "/fifo/events" ]; then
    echo "{\"type\":\"policy_event\",\"source\":\"network-setup\",\"ts\":\"${ts}\",\"session_id\":\"${SESSION_ID:-unknown}\",\"event\":\"network_enforcement_failed\",\"reason\":\"${reason}\"}" > /fifo/events 2>/dev/null
  fi
}

_fail_closed() {
  local message="$1"
  local reason="${2:-iptables_unavailable}"
  _log "FATAL: $message — aborting (fail closed)"
  _emit_enforcement_failure "$reason"
  exit 1
}

# --- Apply iptables rules ---

if [ -z "$RULES" ]; then
  _log "No network policy rules — skipping iptables setup"
  exec /usr/local/bin/shell-wrapper.sh
fi

if ! command -v iptables >/dev/null 2>&1; then
  if [ "$ALLOW_DEGRADED" = "true" ]; then
    _log "WARNING: iptables not available — network policy not enforced (degraded mode)"
    exec /usr/local/bin/shell-wrapper.sh
  fi
  _fail_closed "iptables required for network policy but not available" "iptables_unavailable"
fi

# Default policy: drop all outbound traffic
iptables -P OUTPUT DROP 2>/dev/null || {
  if [ "$ALLOW_DEGRADED" = "true" ]; then
    _log "WARNING: iptables failed (likely insufficient privileges) — network policy not enforced (degraded mode)"
    exec /usr/local/bin/shell-wrapper.sh
  fi
  _fail_closed "cannot set iptables OUTPUT policy" "iptables_output_policy_failed"
}

# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT

# Allow established/related connections (for DNS responses, etc.)
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow DNS only to the container's configured resolvers (not to arbitrary IPs).
# This prevents exfiltration of data via DNS to attacker-controlled nameservers.
dns_resolvers=""
if [ -f /etc/resolv.conf ]; then
  dns_resolvers="$(awk '/^nameserver/ { print $2 }' /etc/resolv.conf)"
fi

if [ -z "$dns_resolvers" ]; then
  # Fallback: Docker internal DNS + default gateway
  dns_resolvers="127.0.0.11"
  default_gw="$(ip route show default 2>/dev/null | awk '/default/ { print $3 }' | head -1)"
  if [ -n "$default_gw" ]; then
    dns_resolvers="$dns_resolvers $default_gw"
  fi
  _log "No resolvers in /etc/resolv.conf — allowing DNS to fallback targets: $dns_resolvers"
fi

for resolver in $dns_resolvers; do
  iptables -A OUTPUT -p udp -d "$resolver" --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp -d "$resolver" --dport 53 -j ACCEPT
done

# Apply allow rules from NETWORK_POLICY_RULES
# Format: IP1:PORT1,IP2:PORT2,... (IPv4 only — IPv6 filtered out by cli/run.sh)
IFS=',' read -ra entries <<< "$RULES"
for entry in "${entries[@]}"; do
  [ -z "$entry" ] && continue
  local_ip="${entry%%:*}"
  local_port="${entry##*:}"
  # Defense in depth: skip entries that look like IPv6 (contain colons in IP part)
  case "$local_ip" in
    *:*) _log "WARNING: skipping IPv6 entry $entry (iptables is IPv4-only)"; continue ;;
  esac
  if [ -n "$local_ip" ] && [ -n "$local_port" ]; then
    iptables -A OUTPUT -p tcp -d "$local_ip" --dport "$local_port" -j ACCEPT
    _log "Allowed: $local_ip:$local_port"
  fi
done

# Signal that network rules are ready
if [ -d "/fifo" ]; then
  touch /fifo/network-ready
fi

_log "Network policy applied ($(echo "$RULES" | tr ',' ' ' | wc -w) rules)"

# Drop privileges and exec shell-wrapper.
# TARGET_USER is UID:GID from the host, passed via NETWORK_POLICY_USER.
if [ -n "$TARGET_USER" ]; then
  target_uid="${TARGET_USER%%:*}"
  target_gid="${TARGET_USER##*:}"

  # Create a group and user matching the host UID:GID
  addgroup -g "$target_gid" carranca 2>/dev/null || true
  adduser -D -u "$target_uid" -G carranca -h /home/carranca -s /bin/bash carranca 2>/dev/null || true

  exec su -s /bin/bash -c "/usr/local/bin/shell-wrapper.sh" carranca
else
  exec /usr/local/bin/shell-wrapper.sh
fi
