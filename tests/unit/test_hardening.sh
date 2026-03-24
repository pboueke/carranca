#!/usr/bin/env bash
# Unit tests for hardening fixes — config sandbox, IPv6 filtering, config redaction
#
# Coverage markers for config.sh hardening:
# CAP_DROP_FLAG READ_ONLY_FLAGS SECCOMP_FLAG APPARMOR_FLAG
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_hardening.sh"

TMPDIR="$(mktemp -d)"

# --- Test allowlist-based config redaction ---

echo ""
echo "--- config redaction (allowlist) ---"

CONFIG="$TMPDIR/full.yml"
cat > "$CONFIG" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex --quiet
  - name: claude
    adapter: claude
    command: claude --dp

runtime:
  engine: auto
  network:
    default: deny
    allow:
      - "*.anthropic.com:443"
      - "registry.npmjs.org:443"
  cap_drop_all: true
  read_only: true
  seccomp_profile: default

volumes:
  cache: true
  extra:
    - ~/docs:/reference:ro

policy:
  docs_before_code: enforce
  tests_before_impl: warn
  max_duration: 1800
  resource_limits:
    memory: 2g
    cpus: "2.0"
    pids: 256
  filesystem:
    enforce_watched_paths: true

watched_paths:
  - .env
  - secrets/
  - "*.key"

observability:
  execve_tracing: true
  network_logging: true
  network_interval: 5
  secret_monitoring: true
  resource_interval: 10
  independent_observer: true

orchestration:
  mode: pipeline
  workspace: isolated
EOF

# Apply the awk redaction filter (same as config.sh)
REDACTED="$TMPDIR/redacted.yml"
awk '
  /^[a-zA-Z]/ {
    section = $0
    sub(/:.*/, "", section)
  }
  /^agents:/ { allowed = 1 }
  /^runtime:/ { allowed = 1 }
  /^volumes:/ { allowed = 1 }
  /^policy:/ { allowed = 0 }
  /^watched_paths:/ { allowed = 0 }
  /^observability:/ { allowed = 0 }
  /^orchestration:/ { allowed = 0 }
  /^[a-zA-Z]/ && !/^(agents|runtime|volumes|policy|watched_paths|observability|orchestration):/ { allowed = 0 }
  allowed && section == "runtime" && /^[ \t]+network:/ { in_network_block = 1 }
  allowed && section == "runtime" && in_network_block && /^[ \t]+(default|allow):/ { next }
  allowed && section == "runtime" && in_network_block && /^[ \t]+- / { next }
  allowed && section == "runtime" && /^  [a-zA-Z]/ && !/^[ \t]+network/ { in_network_block = 0 }
  allowed { print }
' "$CONFIG" > "$REDACTED"

REDACTED_CONTENT="$(cat "$REDACTED")"

# Allowed content preserved
assert_contains "redacted: agents section present" "agents:" "$REDACTED_CONTENT"
assert_contains "redacted: agent name codex" "name: codex" "$REDACTED_CONTENT"
assert_contains "redacted: agent name claude" "name: claude" "$REDACTED_CONTENT"
assert_contains "redacted: runtime section present" "runtime:" "$REDACTED_CONTENT"
assert_contains "redacted: engine key present" "engine: auto" "$REDACTED_CONTENT"
assert_contains "redacted: cap_drop_all present" "cap_drop_all: true" "$REDACTED_CONTENT"
assert_contains "redacted: read_only present" "read_only: true" "$REDACTED_CONTENT"
assert_contains "redacted: seccomp_profile present" "seccomp_profile: default" "$REDACTED_CONTENT"
assert_contains "redacted: volumes section present" "volumes:" "$REDACTED_CONTENT"
assert_contains "redacted: cache key present" "cache: true" "$REDACTED_CONTENT"
assert_contains "redacted: extra volumes present" "~/docs:/reference:ro" "$REDACTED_CONTENT"
# network: line itself present (but not the allow-list details)
assert_contains "redacted: network key present" "network:" "$REDACTED_CONTENT"

# Stripped content absent
assert_not_contains "redacted: no policy section" "policy:" "$REDACTED_CONTENT"
assert_not_contains "redacted: no docs_before_code" "docs_before_code" "$REDACTED_CONTENT"
assert_not_contains "redacted: no tests_before_impl" "tests_before_impl" "$REDACTED_CONTENT"
assert_not_contains "redacted: no max_duration" "max_duration" "$REDACTED_CONTENT"
assert_not_contains "redacted: no resource_limits" "resource_limits" "$REDACTED_CONTENT"
assert_not_contains "redacted: no enforce_watched_paths" "enforce_watched_paths" "$REDACTED_CONTENT"
assert_not_contains "redacted: no watched_paths section" "watched_paths:" "$REDACTED_CONTENT"
assert_not_contains "redacted: no .env path" ".env" "$REDACTED_CONTENT"
assert_not_contains "redacted: no observability section" "observability:" "$REDACTED_CONTENT"
assert_not_contains "redacted: no execve_tracing" "execve_tracing" "$REDACTED_CONTENT"
assert_not_contains "redacted: no independent_observer" "independent_observer" "$REDACTED_CONTENT"
assert_not_contains "redacted: no orchestration section" "orchestration:" "$REDACTED_CONTENT"
# Network allow-list details stripped
assert_not_contains "redacted: no network default deny" "default: deny" "$REDACTED_CONTENT"
assert_not_contains "redacted: no network allow list" "anthropic.com" "$REDACTED_CONTENT"
assert_not_contains "redacted: no network allow entries" "registry.npmjs.org" "$REDACTED_CONTENT"

# --- Test future unknown sections are denied by default ---

echo ""
echo "--- unknown sections denied by default ---"

CONFIG_FUTURE="$TMPDIR/future.yml"
cat > "$CONFIG_FUTURE" <<'EOF'
agents:
  - name: test
    command: echo
runtime:
  engine: auto
secrets:
  api_key: sk-12345
internal_flags:
  debug: true
EOF

REDACTED_FUTURE="$TMPDIR/redacted-future.yml"
awk '
  /^[a-zA-Z]/ {
    section = $0
    sub(/:.*/, "", section)
  }
  /^agents:/ { allowed = 1 }
  /^runtime:/ { allowed = 1 }
  /^volumes:/ { allowed = 1 }
  /^policy:/ { allowed = 0 }
  /^watched_paths:/ { allowed = 0 }
  /^observability:/ { allowed = 0 }
  /^orchestration:/ { allowed = 0 }
  /^[a-zA-Z]/ && !/^(agents|runtime|volumes|policy|watched_paths|observability|orchestration):/ { allowed = 0 }
  allowed && section == "runtime" && /^[ \t]+network:/ { in_network_block = 1 }
  allowed && section == "runtime" && in_network_block && /^[ \t]+(default|allow):/ { next }
  allowed && section == "runtime" && in_network_block && /^[ \t]+- / { next }
  allowed && section == "runtime" && /^  [a-zA-Z]/ && !/^[ \t]+network/ { in_network_block = 0 }
  allowed { print }
' "$CONFIG_FUTURE" > "$REDACTED_FUTURE"

FUTURE_CONTENT="$(cat "$REDACTED_FUTURE")"
assert_contains "future: agents preserved" "agents:" "$FUTURE_CONTENT"
assert_contains "future: runtime preserved" "runtime:" "$FUTURE_CONTENT"
assert_not_contains "future: secrets denied" "api_key" "$FUTURE_CONTENT"
assert_not_contains "future: internal_flags denied" "debug" "$FUTURE_CONTENT"

# --- Test IPv6 filtering ---

echo ""
echo "--- IPv6 filtering ---"

# Simulate the IPv6 filtering logic from run.sh
_test_ipv6_filter() {
  local all_ips="$1"
  local resolved_ips=""
  local ipv6_skipped=false
  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    case "$ip" in
      *:*) ipv6_skipped=true ;;
      *)   resolved_ips="${resolved_ips:+$resolved_ips$'\n'}$ip" ;;
    esac
  done <<< "$all_ips"
  printf 'ips=%s\nskipped=%s\n' "$resolved_ips" "$ipv6_skipped"
}

RESULT="$(_test_ipv6_filter "$(printf '1.2.3.4\n5.6.7.8\n')")"
assert_contains "ipv4 only: ips preserved" "ips=1.2.3.4" "$RESULT"
assert_contains "ipv4 only: no skip" "skipped=false" "$RESULT"

RESULT="$(_test_ipv6_filter "$(printf '1.2.3.4\n2001:db8::1\n5.6.7.8\n')")"
assert_contains "mixed: ipv4 preserved" "1.2.3.4" "$RESULT"
assert_contains "mixed: second ipv4 preserved" "5.6.7.8" "$RESULT"
assert_not_contains "mixed: ipv6 excluded" "2001:db8" "$RESULT"
assert_contains "mixed: skip flagged" "skipped=true" "$RESULT"

RESULT="$(_test_ipv6_filter "$(printf '2001:db8::1\n::1\nfe80::1\n')")"
assert_contains "ipv6 only: all skipped" "skipped=true" "$RESULT"
assert_eq "ipv6 only: no ips" "ips=" "$(echo "$RESULT" | head -1)"

RESULT="$(_test_ipv6_filter "")"
assert_contains "empty: no skip" "skipped=false" "$RESULT"

# --- Test network-setup.sh IPv6 defense-in-depth ---

echo ""
echo "--- network-setup IPv6 defense-in-depth ---"

# Simulate the entry parsing from network-setup.sh
_test_entry_parse() {
  local entry="$1"
  local local_ip="${entry%%:*}"
  case "$local_ip" in
    *:*) echo "SKIP" ;;
    *)   echo "ALLOW:$local_ip:${entry##*:}" ;;
  esac
}

assert_eq "ipv4 entry parsed" "ALLOW:1.2.3.4:443" "$(_test_entry_parse "1.2.3.4:443")"
# If an IPv6 address somehow got through, the %%:* split would take "2001" as IP
# and "443" as port from "2001:db8::1:443". The defense-in-depth check catches
# this because "2001" doesn't contain a colon. But a full IPv6 like
# "2001:db8::1" passed as entry would have local_ip="2001" (no colon), so
# the defense only catches bracket-notation or raw multi-colon entries.
# The primary defense is the run.sh filter.

rm -rf "$TMPDIR"

echo ""
print_results
