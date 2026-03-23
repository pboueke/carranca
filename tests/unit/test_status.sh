#!/usr/bin/env bash
# Unit tests for carranca status and session discovery helpers
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$SCRIPT_DIR/cli/status.sh"

PASS=0
FAIL=0

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -Fq -- "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

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

echo "=== test_status.sh ==="

TMPSTATE="$(mktemp -d)"
TMPDIR="$(mktemp -d)"
FAKEBIN="$(mktemp -d)"
export CARRANCA_STATE="$TMPSTATE"

cat > "$FAKEBIN/docker" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "info" ]; then
  exit 0
fi
if [ "$1" = "ps" ] && [ "$2" = "--format" ]; then
  printf '%s\n' "carranca-a1b2c3d4-logger" "carranca-ffffffff-agent" "unrelated-container"
  exit 0
fi
exit 1
EOF
chmod +x "$FAKEBIN/docker"
export CARRANCA_CONTAINER_RUNTIME="docker"
export PATH="$FAKEBIN:$PATH"

cd "$TMPDIR"
git init --quiet

source "$SCRIPT_DIR/cli/lib/common.sh"
source "$SCRIPT_DIR/cli/lib/runtime.sh"
REPO_ID="$(source "$SCRIPT_DIR/cli/lib/identity.sh" && carranca_repo_id)"
LOG_DIR="$TMPSTATE/sessions/$REPO_ID"
mkdir -p "$LOG_DIR"

printf '%s\n' '{"type":"session_event","event":"start","ts":"2026-03-22T10:00:00Z","session_id":"a1b2c3d4"}' > "$LOG_DIR/a1b2c3d4.jsonl"
sleep 1
cat > "$LOG_DIR/b2c3d4e5.jsonl" <<'EOF'
{"type":"session_event","event":"start","ts":"2026-03-22T11:00:00Z","session_id":"b2c3d4e5"}
{"type":"file_event","event":"CREATE","path":"/workspace/example.txt","session_id":"b2c3d4e5"}
{"type":"shell_command","command":"make test","exit_code":0,"duration_ms":123,"session_id":"b2c3d4e5"}
{"type":"session_event","event":"logger_stop","ts":"2026-03-22T11:05:00Z","session_id":"b2c3d4e5"}
EOF
sleep 1
printf '%s\n' '{"type":"session_event","event":"start","ts":"2026-03-22T12:00:00Z","session_id":"c3d4e5f6"}' > "$LOG_DIR/c3d4e5f6.jsonl"
sleep 1
printf '%s\n' '{"type":"session_event","event":"start","ts":"2026-03-22T13:00:00Z","session_id":"d4e5f6a7"}' > "$LOG_DIR/d4e5f6a7.jsonl"
sleep 1
printf '%s\n' '{"type":"session_event","event":"start","ts":"2026-03-22T14:00:00Z","session_id":"e5f6a7b8"}' > "$LOG_DIR/e5f6a7b8.jsonl"
sleep 1
printf '%s\n' '{"type":"session_event","event":"start","ts":"2026-03-22T15:00:00Z","session_id":"f6a7b8c9"}' > "$LOG_DIR/f6a7b8c9.jsonl"

source "$SCRIPT_DIR/cli/lib/session.sh"
source "$SCRIPT_DIR/cli/lib/log.sh"

RECENT_LOGS="$(carranca_session_recent_logs "$REPO_ID" 5 "$TMPSTATE")"
FIRST_RECENT="$(printf '%s\n' "$RECENT_LOGS" | head -n 1)"
RECENT_COUNT="$(printf '%s\n' "$RECENT_LOGS" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
LAST_RECENT="$(printf '%s\n' "$RECENT_LOGS" | tail -n 1)"
assert_eq "recent logs returns newest file first" "$LOG_DIR/f6a7b8c9.jsonl" "$FIRST_RECENT"
assert_eq "recent logs respects limit of 5 files" "5" "$RECENT_COUNT"
assert_eq "recent logs omits oldest sixth file" "$LOG_DIR/b2c3d4e5.jsonl" "$LAST_RECENT"

ACTIVE_CHECK=0
carranca_session_is_active "a1b2c3d4" || ACTIVE_CHECK=$?
assert_eq "session_is_active returns success for matching container" "0" "$ACTIVE_CHECK"

INACTIVE_CHECK=0
carranca_session_is_active "deadbeef" || INACTIVE_CHECK=$?
assert_eq "session_is_active returns non-zero for missing container" "1" "$INACTIVE_CHECK"

ACTIVE_IDS="$(carranca_session_active_ids "$REPO_ID" "$TMPSTATE")"
assert_eq "active ids returns only sessions with matching running containers" "a1b2c3d4" "$ACTIVE_IDS"

DISPLAY_TS="$(carranca_session_display_ts "$LOG_DIR/a1b2c3d4.jsonl")"
assert_eq "display ts prefers timestamp from log contents" "2026-03-22T10:00:00Z" "$DISPLAY_TS"

STATUS_OUTPUT="$(bash "$CLI" 2>&1)"
assert_contains "status prints repo heading" "Repo:" "$STATUS_OUTPUT"
assert_contains "status prints active session" "a1b2c3d4 (2026-03-22T10:00:00Z)" "$STATUS_OUTPUT"
assert_contains "status prints recent sessions heading" "Recent sessions:" "$STATUS_OUTPUT"
assert_contains "status prints recent log path" "$LOG_DIR/b2c3d4e5.jsonl" "$STATUS_OUTPUT"
if echo "$STATUS_OUTPUT" | grep -Fq -- "$LOG_DIR/a1b2c3d4.jsonl"; then
  echo "  FAIL: status overview should not include the sixth-oldest log"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: status overview limits recent sessions to 5"
  PASS=$((PASS + 1))
fi

DETAIL_OUTPUT="$(bash "$CLI" --session b2c3d4e5 2>&1)"
assert_contains "detailed status prints session heading" "Session: b2c3d4e5" "$DETAIL_OUTPUT"
assert_contains "detailed status prints inactive status" "Status: inactive" "$DETAIL_OUTPUT"
assert_contains "detailed status reuses summary output" "Commands run: 1 (1 succeeded, 0 failed)" "$DETAIL_OUTPUT"
assert_contains "detailed status prints top touched paths" "Top touched paths:" "$DETAIL_OUTPUT"
assert_contains "detailed status prints command list" "[0, 123ms] make test" "$DETAIL_OUTPUT"

MISSING_OUTPUT="$(bash "$CLI" --session deadbeef 2>&1)" && MISSING_RC=0 || MISSING_RC=$?
assert_eq "status detail fails for missing session id" "1" "$MISSING_RC"
assert_contains "status detail reports missing session id" "No session log found for repo" "$MISSING_OUTPUT"

rm -rf "$TMPDIR" "$TMPSTATE" "$FAKEBIN"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
