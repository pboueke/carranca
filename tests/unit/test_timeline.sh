#!/usr/bin/env bash
# Unit tests for cli/lib/timeline.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/cli/lib/log.sh"
source "$SCRIPT_DIR/cli/lib/timeline.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_timeline.sh"

TMPDIR="$(mktemp -d)"

# --- Test: full session timeline ---

echo ""
echo "--- Full session timeline ---"

cat > "$TMPDIR/abc12345.jsonl" <<'EOF'
{"type":"session_event","source":"carranca","event":"start","ts":"2026-03-22T09:45:00Z","session_id":"abc12345","repo_id":"r123","repo_name":"test-repo","repo_path":"/workspace","agent":"codex","adapter":"codex","engine":"podman","seq":1}
{"type":"session_event","source":"shell-wrapper","event":"agent_start","ts":"2026-03-22T09:45:02Z","session_id":"abc12345","seq":2}
{"type":"file_event","source":"inotifywait","event":"CREATE","ts":"2026-03-22T09:45:03Z","path":"/workspace/src/index.ts","session_id":"abc12345","seq":3}
{"type":"shell_command","source":"shell-wrapper","ts":"2026-03-22T09:45:04Z","session_id":"abc12345","command":"npm test","exit_code":0,"duration_ms":3420,"cwd":"/workspace","seq":4}
{"type":"file_event","source":"inotifywait","event":"MODIFY","ts":"2026-03-22T09:45:05Z","path":"/workspace/.env","session_id":"abc12345","watched":true,"seq":5}
{"type":"heartbeat","source":"shell-wrapper","ts":"2026-03-22T09:45:32Z","session_id":"abc12345","seq":6}
{"type":"shell_command","source":"shell-wrapper","ts":"2026-03-22T09:45:40Z","session_id":"abc12345","command":"cat /etc/passwd","exit_code":1,"duration_ms":5,"cwd":"/workspace","seq":7}
{"type":"session_event","source":"shell-wrapper","event":"agent_stop","ts":"2026-03-22T09:57:34Z","session_id":"abc12345","exit_code":0,"seq":8}
{"type":"session_event","source":"carranca","event":"logger_stop","ts":"2026-03-22T09:57:35Z","session_id":"abc12345","seq":9}
EOF

output="$(carranca_session_render_timeline "$TMPDIR/abc12345.jsonl")"

assert_contains "timeline header shows session id" "session abc12345" "$output"
assert_contains "session start shows glyph and agent" ">>  session start (codex via podman)" "$output"
assert_contains "agent start shows glyph" ">>  agent start" "$output"
assert_contains "file create shows F+ glyph" "F+  /workspace/src/index.ts CREATE" "$output"
assert_contains "command shows dollar glyph" '$  npm test (exit=0, 3420ms)' "$output"
assert_contains "watched file shows tag" "[watched]" "$output"
assert_contains "heartbeat shows dot glyph" ".  heartbeat" "$output"
assert_contains "failed command shows exit code" 'exit=1' "$output"
assert_contains "agent stop shows glyph and exit" "<<  agent stop (exit=0)" "$output"
assert_contains "logger stop shows glyph" "<<  logger stop" "$output"
assert_contains "summary shows command count" "2 commands" "$output"
assert_contains "summary shows file count" "2 file events" "$output"
assert_contains "summary shows failure count" "1 failures" "$output"
assert_contains "summary shows duration" "Duration:" "$output"

# --- Test: empty session ---

echo ""
echo "--- Empty session ---"

cat > "$TMPDIR/empty.jsonl" <<'EOF'
{"type":"session_event","source":"carranca","event":"start","ts":"2026-03-22T09:00:00Z","session_id":"empty001","seq":1}
{"type":"session_event","source":"carranca","event":"logger_stop","ts":"2026-03-22T09:00:01Z","session_id":"empty001","seq":2}
EOF

output="$(carranca_session_render_timeline "$TMPDIR/empty.jsonl")"
assert_contains "empty session shows zero commands" "0 commands" "$output"
assert_contains "empty session shows zero files" "0 file events" "$output"
assert_contains "empty session shows zero failures" "0 failures" "$output"

# --- Test: degraded event ---

echo ""
echo "--- Degraded event ---"

cat > "$TMPDIR/degraded.jsonl" <<'EOF'
{"type":"session_event","source":"carranca","event":"start","ts":"2026-03-22T09:00:00Z","session_id":"deg00001","seq":1}
{"type":"session_event","source":"carranca","event":"degraded","ts":"2026-03-22T09:00:00Z","session_id":"deg00001","reason":"append_only_unavailable","seq":2}
EOF

output="$(carranca_session_render_timeline "$TMPDIR/degraded.jsonl")"
assert_contains "degraded shows bang glyph" "!!  degraded: append_only_unavailable" "$output"

# --- Test: file delete ---

echo ""
echo "--- File delete event ---"

cat > "$TMPDIR/delete.jsonl" <<'EOF'
{"type":"file_event","source":"inotifywait","event":"DELETE","ts":"2026-03-22T09:00:01Z","path":"/workspace/old.txt","session_id":"del00001","seq":1}
EOF

output="$(carranca_session_render_timeline "$TMPDIR/delete.jsonl")"
assert_contains "file delete shows F- glyph" "F-  /workspace/old.txt DELETE" "$output"

# --- Test: future event types render gracefully ---

echo ""
echo "--- Future/unknown event types ---"

cat > "$TMPDIR/future.jsonl" <<'EOF'
{"type":"execve_event","source":"strace","ts":"2026-03-22T09:00:01Z","session_id":"fut00001","pid":42,"binary":"/usr/bin/npm","seq":1}
{"type":"network_event","source":"carranca","ts":"2026-03-22T09:00:02Z","session_id":"fut00001","dest_ip":"104.18.12.33","dest_port":443,"protocol":"tcp","state":"ESTABLISHED","seq":2}
{"type":"resource_event","source":"carranca","ts":"2026-03-22T09:00:03Z","session_id":"fut00001","cpu_usage_us":1234567,"memory_bytes":52428800,"pids":12,"seq":3}
{"type":"file_access_event","source":"fanotify","ts":"2026-03-22T09:00:04Z","session_id":"fut00001","path":"/workspace/.env","pid":42,"watched":true,"seq":4}
{"type":"policy_event","source":"carranca","ts":"2026-03-22T09:00:05Z","session_id":"fut00001","policy":"resource_limits","action":"oom_kill","detail":"OOM kill detected","seq":5}
{"type":"completely_unknown","ts":"2026-03-22T09:00:06Z","session_id":"fut00001","seq":6}
EOF

output="$(carranca_session_render_timeline "$TMPDIR/future.jsonl")"
assert_contains "execve shows X glyph" "X  /usr/bin/npm (pid=42)" "$output"
assert_contains "network shows N glyph" "N  104.18.12.33:443 tcp ESTABLISHED" "$output"
assert_contains "resource shows R glyph" "R  cpu=1234567us mem=52428800B pids=12" "$output"
assert_contains "file access shows A glyph" "A  /workspace/.env read" "$output"
assert_contains "policy shows P glyph" "P  [resource_limits] oom_kill: OOM kill detected" "$output"
assert_contains "unknown shows ? glyph" "?  completely_unknown" "$output"

rm -rf "$TMPDIR"

echo ""
print_results
