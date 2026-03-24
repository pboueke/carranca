#!/usr/bin/env bash
# Unit tests for Phase 6.3 — carranca diff
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_diff.sh"

# --- Test help output ---

echo ""
echo "--- diff help ---"

HELP_OUTPUT="$(bash "$SCRIPT_DIR/cli/diff.sh" help 2>&1)"
assert_contains "help shows usage" "Usage: carranca diff" "$HELP_OUTPUT"
assert_contains "help shows --pretty" "--pretty" "$HELP_OUTPUT"
assert_contains "help shows --repo-a" "--repo-a" "$HELP_OUTPUT"

# --- Test argument validation ---

echo ""
echo "--- diff arg validation ---"

RC=0
bash "$SCRIPT_DIR/cli/diff.sh" 2>&1 || RC=$?
assert_eq "no args exits non-zero" "1" "$RC"

RC=0
bash "$SCRIPT_DIR/cli/diff.sh" abc 2>&1 || RC=$?
assert_eq "one arg exits non-zero" "1" "$RC"

# --- Test collect_stats extended fields ---

echo ""
echo "--- collect_stats extended fields ---"

source "$SCRIPT_DIR/cli/lib/common.sh"
source "$SCRIPT_DIR/cli/lib/log.sh"

TMPDIR="$(mktemp -d)"
LOG_A="$TMPDIR/a.jsonl"
LOG_B="$TMPDIR/b.jsonl"

cat > "$LOG_A" <<'EOF'
{"type":"session_event","source":"carranca","event":"start","ts":"2026-03-22T10:00:00Z","session_id":"aaaa1111","agent":"codex","adapter":"codex","engine":"podman"}
{"type":"shell_command","source":"shell-wrapper","ts":"2026-03-22T10:01:00Z","session_id":"aaaa1111","command":"npm test","exit_code":0,"duration_ms":5000}
{"type":"file_event","source":"inotifywait","ts":"2026-03-22T10:01:05Z","session_id":"aaaa1111","event":"MODIFY","path":"src/index.ts"}
{"type":"resource_event","source":"carranca","ts":"2026-03-22T10:01:10Z","session_id":"aaaa1111","cpu_usage_us":1000000,"memory_bytes":104857600,"pids":20}
{"type":"execve_event","source":"strace","ts":"2026-03-22T10:01:02Z","session_id":"aaaa1111","pid":42,"binary":"/usr/bin/node","argv":"[\"node\"]"}
{"type":"network_event","source":"carranca","ts":"2026-03-22T10:01:03Z","session_id":"aaaa1111","dest_ip":"1.2.3.4","dest_port":443,"protocol":"tcp","state":"ESTABLISHED"}
{"type":"session_event","source":"carranca","event":"logger_stop","ts":"2026-03-22T10:05:00Z","session_id":"aaaa1111"}
EOF

cat > "$LOG_B" <<'EOF'
{"type":"session_event","source":"carranca","event":"start","ts":"2026-03-22T14:00:00Z","session_id":"bbbb2222","agent":"claude","adapter":"claude","engine":"docker"}
{"type":"shell_command","source":"shell-wrapper","ts":"2026-03-22T14:01:00Z","session_id":"bbbb2222","command":"npm test","exit_code":0,"duration_ms":8000}
{"type":"shell_command","source":"shell-wrapper","ts":"2026-03-22T14:03:00Z","session_id":"bbbb2222","command":"npm run build","exit_code":0,"duration_ms":12000}
{"type":"file_event","source":"inotifywait","ts":"2026-03-22T14:01:05Z","session_id":"bbbb2222","event":"CREATE","path":"dist/bundle.js"}
{"type":"file_event","source":"inotifywait","ts":"2026-03-22T14:01:06Z","session_id":"bbbb2222","event":"MODIFY","path":"src/index.ts"}
{"type":"resource_event","source":"carranca","ts":"2026-03-22T14:01:10Z","session_id":"bbbb2222","cpu_usage_us":3000000,"memory_bytes":209715200,"pids":45}
{"type":"policy_event","source":"carranca","ts":"2026-03-22T14:02:00Z","session_id":"bbbb2222","policy":"docs_before_code","action":"warn","detail":"code modified without docs"}
{"type":"session_event","source":"carranca","event":"logger_stop","ts":"2026-03-22T14:12:00Z","session_id":"bbbb2222"}
EOF

# Collect stats for session A
carranca_session_collect_stats "$LOG_A"
assert_eq "A: agent name" "codex" "$CARRANCA_LOG_AGENT_NAME"
assert_eq "A: total cmds" "1" "$CARRANCA_LOG_TOTAL_CMDS"
assert_eq "A: peak cpu" "1000000" "$CARRANCA_LOG_PEAK_CPU_US"
assert_eq "A: peak memory" "104857600" "$CARRANCA_LOG_PEAK_MEMORY_BYTES"
assert_eq "A: peak pids" "20" "$CARRANCA_LOG_PEAK_PIDS"
assert_eq "A: unique cmds count" "1" "${#CARRANCA_LOG_UNIQUE_CMDS[@]}"
assert_eq "A: unique binaries count" "1" "${#CARRANCA_LOG_UNIQUE_BINARIES[@]}"
assert_eq "A: unique net dests count" "1" "${#CARRANCA_LOG_UNIQUE_NET_DESTS[@]}"
assert_eq "A: network events" "1" "$CARRANCA_LOG_NETWORK_EVENTS"
assert_eq "A: execve events" "1" "$CARRANCA_LOG_EXECVE_EVENTS"
assert_eq "A: policy events" "0" "$CARRANCA_LOG_POLICY_EVENTS"

# Collect stats for session B
carranca_session_collect_stats "$LOG_B"
assert_eq "B: agent name" "claude" "$CARRANCA_LOG_AGENT_NAME"
assert_eq "B: total cmds" "2" "$CARRANCA_LOG_TOTAL_CMDS"
assert_eq "B: peak cpu" "3000000" "$CARRANCA_LOG_PEAK_CPU_US"
assert_eq "B: peak memory" "209715200" "$CARRANCA_LOG_PEAK_MEMORY_BYTES"
assert_eq "B: peak pids" "45" "$CARRANCA_LOG_PEAK_PIDS"
assert_eq "B: unique cmds count" "2" "${#CARRANCA_LOG_UNIQUE_CMDS[@]}"
assert_eq "B: policy events" "1" "$CARRANCA_LOG_POLICY_EVENTS"
assert_eq "B: policy types" "1" "${#CARRANCA_LOG_POLICY_TYPES[@]}"
assert_eq "B: unique paths" "2" "$CARRANCA_LOG_UNIQUE_PATHS"

# --- Test orchestrator log detection ---

echo ""
echo "--- orchestrator log detection ---"

ORCH_LOG="$TMPDIR/aaaa1111.orchestrator.jsonl"
cat > "$ORCH_LOG" <<'EOF'
{"type":"orchestration_event","ts":"2026-03-22T10:00:00Z","session_id":"aaaa1111","event":"session_start","mode":"pipeline"}
{"type":"orchestration_event","ts":"2026-03-22T10:00:01Z","session_id":"aaaa1111","event":"agent_start","agent":"coder"}
{"type":"orchestration_event","ts":"2026-03-22T10:03:00Z","session_id":"aaaa1111","event":"agent_stop","agent":"coder","exit_code":0}
{"type":"orchestration_event","ts":"2026-03-22T10:05:00Z","session_id":"aaaa1111","event":"session_stop","exit_code":0}
EOF

# Rename log_A to match the session id the orchestrator expects
cp "$LOG_A" "$TMPDIR/aaaa1111.jsonl"

IS_ORCH=false
carranca_session_is_orchestrated "$TMPDIR/aaaa1111.jsonl" && IS_ORCH=true
assert_eq "orchestrated session detected" "true" "$IS_ORCH"

IS_ORCH=false
carranca_session_is_orchestrated "$LOG_B" && IS_ORCH=true
assert_eq "non-orchestrated session not flagged" "false" "$IS_ORCH"

# Test orchestrator summary output
ORCH_SUMMARY="$(carranca_session_print_orchestrator_summary "$TMPDIR/aaaa1111.jsonl")"
assert_contains "orch summary shows mode" "Mode: pipeline" "$ORCH_SUMMARY"
assert_contains "orch summary shows agent start" "Agent started: coder" "$ORCH_SUMMARY"
assert_contains "orch summary shows agent stop" "Agent stopped: coder" "$ORCH_SUMMARY"
assert_contains "orch summary shows exit code" "Overall exit code: 0" "$ORCH_SUMMARY"

rm -rf "$TMPDIR"

echo ""
print_results
