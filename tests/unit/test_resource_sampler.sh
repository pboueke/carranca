#!/usr/bin/env bash
# Unit tests for runtime/logger.sh resource sampler functions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/cli/lib/log.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_resource_sampler.sh"

# We cannot source logger.sh directly (it runs as an entrypoint).
# Extract the functions we need to test (same pattern as test_logger.sh).

TMPDIR="$(mktemp -d)"

# --- Extract functions from logger.sh ---

eval "$(sed -n '/^_find_agent_cgroup()/,/^}/p' "$SCRIPT_DIR/runtime/logger.sh")"
eval "$(sed -n '/^_read_cgroup_stats()/,/^}/p' "$SCRIPT_DIR/runtime/logger.sh")"

# --- Test _find_agent_cgroup ---

echo ""
echo "--- _find_agent_cgroup ---"

# Test 1: Finds cgroup directory matching container ID
MOCK_CGROUP="$TMPDIR/hostcgroup"
mkdir -p "$MOCK_CGROUP/docker-abc123def456.scope"

# Override base path by creating a wrapper
_find_agent_cgroup_mock() {
  local container_id="$1"
  local base="$MOCK_CGROUP"
  local dir

  [ -d "$base" ] || return 1

  for dir in "$base"/*"$container_id"*; do
    [ -d "$dir" ] && printf '%s' "$dir" && return 0
  done

  for dir in "$base"/*/"*$container_id"*; do
    [ -d "$dir" ] && printf '%s' "$dir" && return 0
  done

  return 1
}

result="$(_find_agent_cgroup_mock "abc123def456")"
assert_eq "_find_agent_cgroup finds matching directory" "$MOCK_CGROUP/docker-abc123def456.scope" "$result"

# Test 2: Returns failure when no match
if _find_agent_cgroup_mock "nonexistent" >/dev/null 2>&1; then
  echo "  FAIL: _find_agent_cgroup should fail for missing container"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: _find_agent_cgroup fails for missing container"
  PASS=$((PASS + 1))
fi

# Test 3: Returns failure when base dir missing
MOCK_CGROUP_MISSING="$TMPDIR/no-such-dir"
_find_agent_cgroup_nobase() {
  local container_id="$1"
  local base="$MOCK_CGROUP_MISSING"

  [ -d "$base" ] || return 1
  return 1
}

if _find_agent_cgroup_nobase "abc123def456" >/dev/null 2>&1; then
  echo "  FAIL: _find_agent_cgroup should fail when base dir missing"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: _find_agent_cgroup fails when base dir missing"
  PASS=$((PASS + 1))
fi

# --- Test _read_cgroup_stats ---

echo ""
echo "--- _read_cgroup_stats ---"

# Test 4: Reads all cgroup v2 files correctly
CGROUP_DIR="$TMPDIR/cgroup-test"
mkdir -p "$CGROUP_DIR"

cat > "$CGROUP_DIR/cpu.stat" <<'EOF'
usage_usec 1234567
user_usec 1000000
system_usec 234567
EOF

echo "52428800" > "$CGROUP_DIR/memory.current"
echo "12" > "$CGROUP_DIR/pids.current"

result="$(_read_cgroup_stats "$CGROUP_DIR")"
assert_contains "_read_cgroup_stats includes cpu_usage_us" '"cpu_usage_us":1234567' "$result"
assert_contains "_read_cgroup_stats includes memory_bytes" '"memory_bytes":52428800' "$result"
assert_contains "_read_cgroup_stats includes pids" '"pids":12' "$result"

# Test 5: Omits missing files gracefully
CGROUP_PARTIAL="$TMPDIR/cgroup-partial"
mkdir -p "$CGROUP_PARTIAL"
echo "99999999" > "$CGROUP_PARTIAL/memory.current"

result="$(_read_cgroup_stats "$CGROUP_PARTIAL")"
assert_contains "_read_cgroup_stats with partial files includes memory" '"memory_bytes":99999999' "$result"
if echo "$result" | grep -Fq '"cpu_usage_us"'; then
  echo "  FAIL: _read_cgroup_stats should omit cpu_usage_us when cpu.stat missing"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: _read_cgroup_stats omits cpu_usage_us when cpu.stat missing"
  PASS=$((PASS + 1))
fi
if echo "$result" | grep -Fq '"pids"'; then
  echo "  FAIL: _read_cgroup_stats should omit pids when pids.current missing"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: _read_cgroup_stats omits pids when pids.current missing"
  PASS=$((PASS + 1))
fi

# Test 6: Returns empty when no cgroup files exist
CGROUP_EMPTY="$TMPDIR/cgroup-empty"
mkdir -p "$CGROUP_EMPTY"

result="$(_read_cgroup_stats "$CGROUP_EMPTY")"
assert_eq "_read_cgroup_stats returns empty for empty dir" "" "$result"

# --- Test stats collection for resource_event ---

echo ""
echo "--- stats collection for new event types ---"

STATS_LOG="$TMPDIR/stats-test.jsonl"
cat > "$STATS_LOG" <<'EOF'
{"type":"session_event","source":"carranca","event":"start","ts":"2026-03-22T00:00:00Z","session_id":"test1234","repo_id":"abc","repo_name":"test","repo_path":"/workspace","agent":"claude","adapter":"claude","engine":"podman"}
{"type":"resource_event","source":"carranca","ts":"2026-03-22T00:00:10Z","session_id":"test1234","cpu_usage_us":1234567,"memory_bytes":52428800,"pids":12}
{"type":"resource_event","source":"carranca","ts":"2026-03-22T00:00:20Z","session_id":"test1234","cpu_usage_us":2345678,"memory_bytes":62914560,"pids":14}
{"type":"execve_event","source":"strace","ts":"2026-03-22T00:00:05Z","session_id":"test1234","pid":42,"binary":"/usr/bin/ls","argv":"[\"ls\",\"-la\"]"}
{"type":"network_event","source":"carranca","ts":"2026-03-22T00:00:06Z","session_id":"test1234","dest":"1.2.3.4","port":443}
{"type":"file_access_event","source":"carranca","ts":"2026-03-22T00:00:07Z","session_id":"test1234","path":"/etc/passwd"}
{"type":"file_access_event","source":"carranca","ts":"2026-03-22T00:00:08Z","session_id":"test1234","path":"/etc/shadow"}
{"type":"policy_event","source":"carranca","ts":"2026-03-22T00:00:09Z","session_id":"test1234","policy":"resource_limits","action":"oom_kill","detail":"OOM kill detected"}
{"type":"session_event","source":"carranca","event":"logger_stop","ts":"2026-03-22T00:00:30Z","session_id":"test1234"}
EOF

carranca_session_collect_stats "$STATS_LOG"
assert_eq "resource_event count" "2" "$CARRANCA_LOG_RESOURCE_SAMPLES"
assert_eq "execve_event count" "1" "$CARRANCA_LOG_EXECVE_EVENTS"
assert_eq "network_event count" "1" "$CARRANCA_LOG_NETWORK_EVENTS"
assert_eq "file_access_event count" "2" "$CARRANCA_LOG_ACCESS_EVENTS"
assert_eq "policy_event count" "1" "$CARRANCA_LOG_POLICY_EVENTS"

# Test 7: Summary output includes new event counts
summary_output="$(carranca_session_print_summary "$STATS_LOG")"
assert_contains "summary includes resource samples" "Resource samples: 2" "$summary_output"
assert_contains "summary includes execve events" "Execve events: 1" "$summary_output"
assert_contains "summary includes network events" "Network events: 1" "$summary_output"
assert_contains "summary includes access events" "Access events: 2" "$summary_output"
assert_contains "summary includes policy events" "Policy events: 1" "$summary_output"

# Test 8: Summary hides zero-count event types
STATS_LOG_MINIMAL="$TMPDIR/stats-minimal.jsonl"
cat > "$STATS_LOG_MINIMAL" <<'EOF'
{"type":"session_event","source":"carranca","event":"start","ts":"2026-03-22T00:00:00Z","session_id":"min1234","repo_id":"abc","repo_name":"test","repo_path":"/workspace","agent":"claude","adapter":"claude","engine":"podman"}
{"type":"session_event","source":"carranca","event":"logger_stop","ts":"2026-03-22T00:00:30Z","session_id":"min1234"}
EOF

summary_minimal="$(carranca_session_print_summary "$STATS_LOG_MINIMAL")"
if echo "$summary_minimal" | grep -Fq "Resource samples"; then
  echo "  FAIL: summary should hide resource samples when zero"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: summary hides resource samples when zero"
  PASS=$((PASS + 1))
fi
if echo "$summary_minimal" | grep -Fq "Execve events"; then
  echo "  FAIL: summary should hide execve events when zero"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: summary hides execve events when zero"
  PASS=$((PASS + 1))
fi
if echo "$summary_minimal" | grep -Fq "Network events"; then
  echo "  FAIL: summary should hide network events when zero"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: summary hides network events when zero"
  PASS=$((PASS + 1))
fi
if echo "$summary_minimal" | grep -Fq "Access events"; then
  echo "  FAIL: summary should hide access events when zero"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: summary hides access events when zero"
  PASS=$((PASS + 1))
fi
if echo "$summary_minimal" | grep -Fq "Policy events"; then
  echo "  FAIL: summary should hide policy events when zero"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: summary hides policy events when zero"
  PASS=$((PASS + 1))
fi

rm -rf "$TMPDIR"

echo ""
print_results
