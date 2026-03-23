#!/usr/bin/env bash
# Unit tests for cli/lib/log.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/cli/lib/log.sh"

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

echo "=== test_log.sh ==="

TMPSTATE="$(mktemp -d)"
REPO_ID="abc123def456"
LOG_DIR="$TMPSTATE/sessions/$REPO_ID"
mkdir -p "$LOG_DIR"

cat > "$LOG_DIR/11111111.jsonl" <<'EOF'
{"type":"session_event","event":"agent_start","ts":"2026-03-22T00:00:00Z","session_id":"11111111"}
{"type":"file_event","event":"CREATE","ts":"2026-03-22T00:00:01Z","session_id":"11111111","path":"/workspace/a.txt"}
{"type":"shell_command","source":"shell-wrapper","ts":"2026-03-22T00:00:02Z","session_id":"11111111","command":"echo first","exit_code":0,"duration_ms":12,"cwd":"/workspace"}
{"type":"session_event","event":"agent_stop","ts":"2026-03-22T00:00:03Z","session_id":"11111111","exit_code":0}
EOF

cat > "$LOG_DIR/22222222.jsonl" <<'EOF'
{"type":"session_event","source":"carranca","event":"start","ts":"2026-03-22T00:00:09Z","session_id":"22222222","repo_id":"abc123def456","repo_name":"test-repo","repo_path":"/workspace","agent":"codex","adapter":"codex","engine":"podman"}
{"type":"session_event","event":"agent_start","ts":"2026-03-22T00:00:10Z","session_id":"22222222"}
{"type":"file_event","event":"CREATE","ts":"2026-03-22T00:00:10Z","session_id":"22222222","path":"/workspace/b.txt"}
{"type":"file_event","event":"MODIFY","ts":"2026-03-22T00:00:11Z","session_id":"22222222","path":"/workspace/b.txt"}
{"type":"file_event","event":"DELETE","ts":"2026-03-22T00:00:11Z","session_id":"22222222","path":"/workspace/c.txt"}
{"type":"shell_command","source":"shell-wrapper","ts":"2026-03-22T00:00:12Z","session_id":"22222222","command":"echo second","exit_code":1,"duration_ms":34,"cwd":"/workspace"}
{"type":"session_event","event":"agent_stop","ts":"2026-03-22T00:00:13Z","session_id":"22222222","exit_code":1}
EOF

cat > "$LOG_DIR/33333333.jsonl" <<'EOF'
{"type":"session_event","event":"agent_start","ts":"2026-03-22T00:00:20Z","session_id":"33333333"}
{"type":"file_event","event":"MODIFY","ts":"2026-03-22T00:00:21Z","session_id":"33333333","path":"/workspace/only-tools.txt"}
{"type":"session_event","event":"agent_stop","ts":"2026-03-22T00:00:22Z","session_id":"33333333","exit_code":0}
EOF

cat > "$LOG_DIR/44444444.jsonl" <<'EOF'
{"type":"session_event","event":"agent_start","ts":"2026-03-22T00:00:30Z","session_id":"44444444"}
{"type":"session_event","event":"agent_stop","ts":"2026-03-22T00:00:31Z","session_id":"44444444","exit_code":0}
EOF

cat > "$LOG_DIR/55555555.jsonl" <<'EOF'
{"type":"session_event","source":"carranca","event":"start","ts":"2026-03-22T00:00:39Z","session_id":"55555555","repo_id":"abc123def456","repo_name":"test-repo","repo_path":"/workspace","agent":"claude","adapter":"claude","engine":"docker"}
{"type":"session_event","event":"agent_start","ts":"2026-03-22T00:00:40Z","session_id":"55555555"}
{"type":"file_event","event":"MODIFY","ts":"2026-03-22T00:00:41Z","session_id":"55555555","path":"/workspace/.env","watched":true}
{"type":"file_event","event":"CREATE","ts":"2026-03-22T00:00:42Z","session_id":"55555555","path":"/workspace/secrets/api.key","watched":true}
{"type":"file_event","event":"MODIFY","ts":"2026-03-22T00:00:43Z","session_id":"55555555","path":"/workspace/src/app.js"}
{"type":"session_event","event":"agent_stop","ts":"2026-03-22T00:00:44Z","session_id":"55555555","exit_code":0}
EOF

touch -d '2026-03-22T00:00:03Z' "$LOG_DIR/11111111.jsonl"
touch -d '2026-03-22T00:00:13Z' "$LOG_DIR/22222222.jsonl"
touch -d '2026-03-22T00:00:12Z' "$LOG_DIR/33333333.jsonl"
touch -d '2026-03-22T00:00:11Z' "$LOG_DIR/44444444.jsonl"
touch -d '2026-03-22T00:00:09Z' "$LOG_DIR/55555555.jsonl"

latest="$(carranca_session_latest_log "$REPO_ID" "$TMPSTATE")"
assert_eq "latest log lookup returns newest file" "$LOG_DIR/22222222.jsonl" "$latest"

log_dir="$(carranca_session_log_dir "$REPO_ID" "$TMPSTATE")"
assert_eq "session log dir resolves expected path" "$LOG_DIR" "$log_dir"

selected="$(carranca_session_log_for_id "$REPO_ID" "11111111" "$TMPSTATE")"
assert_eq "exact session id resolves correct log path" "$LOG_DIR/11111111.jsonl" "$selected"

json_line='{"type":"shell_command","command":"echo \"quoted\"","exit_code":7,"duration_ms":34}'
assert_eq "json string helper extracts escaped string values" 'echo \"quoted\"' "$(carranca_json_get_string "$json_line" "command")"
assert_eq "json number helper extracts numeric values" "7" "$(carranca_json_get_number "$json_line" "exit_code")"

carranca_session_collect_stats "$LOG_DIR/22222222.jsonl"
assert_eq "session summary keeps exact session id" "22222222" "$CARRANCA_LOG_SESSION_ID"
assert_eq "session summary counts commands" "1" "$CARRANCA_LOG_TOTAL_CMDS"
assert_eq "session summary counts failures" "1" "$CARRANCA_LOG_FAILED_CMDS"
assert_eq "session summary counts file events" "3" "$CARRANCA_LOG_FILE_EVENTS_TOTAL"
assert_eq "session summary counts unique touched paths" "2" "$CARRANCA_LOG_UNIQUE_PATHS"
assert_eq "session summary counts created events" "1" "$CARRANCA_LOG_FILES_CREATED"
assert_eq "session summary counts modified files" "1" "$CARRANCA_LOG_FILES_MODIFIED"
assert_eq "session summary counts deleted files" "1" "$CARRANCA_LOG_FILES_DELETED"
assert_eq "session summary start timestamp" "2026-03-22T00:00:09Z" "$CARRANCA_LOG_FIRST_TS"
assert_eq "session summary end timestamp" "2026-03-22T00:00:13Z" "$CARRANCA_LOG_LAST_TS"
assert_eq "session metadata agent name" "codex" "$CARRANCA_LOG_AGENT_NAME"
assert_eq "session metadata adapter" "codex" "$CARRANCA_LOG_ADAPTER"
assert_eq "session metadata engine" "podman" "$CARRANCA_LOG_ENGINE"

summary_output="$(carranca_session_print_summary "$LOG_DIR/22222222.jsonl")"
assert_contains "pretty summary includes duration" "Duration: 2026-03-22T00:00:09Z → 2026-03-22T00:00:13Z" "$summary_output"
assert_contains "summary includes agent metadata" "Agent: codex (adapter: codex, engine: podman)" "$summary_output"
assert_contains "pretty summary includes unique touched paths" "Unique paths touched: 2" "$summary_output"
assert_contains "pretty summary includes file event totals" "File events: 3 (1 create, 1 modify, 1 delete)" "$summary_output"
assert_contains "pretty summary includes command counts" "Commands run: 1 (0 succeeded, 1 failed)" "$summary_output"

top_paths_output="$(carranca_session_print_top_paths)"
assert_contains "top touched paths includes busiest file" "/workspace/b.txt (2 events: 1 create, 1 modify, 0 delete)" "$top_paths_output"
assert_contains "top touched paths includes deleted file" "/workspace/c.txt (1 events: 0 create, 0 modify, 1 delete)" "$top_paths_output"

limited_top_paths_output="$(carranca_session_print_top_paths 1)"
assert_contains "top touched paths limit keeps busiest file" "/workspace/b.txt (2 events: 1 create, 1 modify, 0 delete)" "$limited_top_paths_output"
if echo "$limited_top_paths_output" | grep -Fq "/workspace/c.txt"; then
  echo "  FAIL: top touched paths limit should omit lower-ranked file"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: top touched paths limit omits lower-ranked file"
  PASS=$((PASS + 1))
fi

commands_output="$(carranca_session_print_commands)"
assert_contains "command list includes exit code and duration" "[1, 34ms] echo second" "$commands_output"

carranca_session_collect_stats "$LOG_DIR/33333333.jsonl"
tool_only_summary="$(carranca_session_print_summary "$LOG_DIR/33333333.jsonl")"
assert_contains "tool-only summary explains missing command capture" "Command capture: none recorded; changes likely came from agent-native edit/tool operations" "$tool_only_summary"

carranca_session_collect_stats "$LOG_DIR/44444444.jsonl"
no_path_top_output="$(carranca_session_print_top_paths)"
assert_contains "top touched paths handles sessions without file events" "  (none)" "$no_path_top_output"

carranca_session_collect_stats "$LOG_DIR/55555555.jsonl"
assert_eq "watched events count is correct" "2" "$CARRANCA_LOG_WATCHED_EVENTS"
assert_eq "total file events with watched" "3" "$CARRANCA_LOG_FILE_EVENTS_TOTAL"

watched_summary="$(carranca_session_print_summary "$LOG_DIR/55555555.jsonl")"
assert_contains "summary includes watched path events" "Watched path events: 2" "$watched_summary"

carranca_session_collect_stats "$LOG_DIR/22222222.jsonl"
assert_eq "no watched events in normal session" "0" "$CARRANCA_LOG_WATCHED_EVENTS"
no_watched_summary="$(carranca_session_print_summary "$LOG_DIR/22222222.jsonl")"
if echo "$no_watched_summary" | grep -Fq "Watched path events"; then
  echo "  FAIL: summary should not show watched line when no watched events"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: summary hides watched line when no watched events"
  PASS=$((PASS + 1))
fi

# Test print_top_paths with limit=0 (show all)
carranca_session_collect_stats "$LOG_DIR/22222222.jsonl"
all_paths_output="$(carranca_session_print_top_paths 0)"
assert_contains "top paths limit=0 shows all paths (b.txt)" "/workspace/b.txt" "$all_paths_output"
assert_contains "top paths limit=0 shows all paths (c.txt)" "/workspace/c.txt" "$all_paths_output"

rm -rf "$TMPSTATE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
