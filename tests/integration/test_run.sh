#!/usr/bin/env bash
# Integration tests for carranca run (requires a supported container runtime)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export CARRANCA_HOME="$SCRIPT_DIR"
source "$SCRIPT_DIR/tests/lib/integration.sh"

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

assert_gt() {
  local desc="$1" threshold="$2" actual="$3"
  if [ "$actual" -gt "$threshold" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected > $threshold, got $actual)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

integration_init
trap integration_cleanup EXIT

echo "=== test_run.sh (requires $RUNTIME) ==="

integration_require_runtime
integration_create_repo
integration_init_project

# Override agent command to something that runs and exits quickly
cat > ".carranca.yml" <<'EOF'
agents:
  - name: codex
    adapter: stdin
    command: bash -c "echo default-agent > /workspace/selected-agent.txt && exit 0"
  - name: shell
    adapter: stdin
    command: bash -c "echo hello-from-agent && echo shell > /workspace/selected-agent.txt && printf '%s' \"\$HOME\" > /workspace/agent-home.txt && id -g > /workspace/agent-gid.txt && id -G > /workspace/agent-groups.txt && touch /workspace/testfile.txt && exit 0"
runtime:
  network: true
policy:
  docs_before_code: warn
  tests_before_impl: warn
EOF

# Run carranca
echo "  Running carranca session (this may take a moment on first build)..."
OUTPUT="$(bash "$CARRANCA_HOME/cli/run.sh" --agent shell 2>&1)" || true

# Find the session log
REPO_ID="$(integration_repo_id)"
LOG_DIR="$TMPSTATE/sessions/$REPO_ID"
LOG_FILE="$(ls -t "$LOG_DIR"/*.jsonl 2>/dev/null | head -1)"

if [ -z "$LOG_FILE" ]; then
  echo "  FAIL: No session log found in $LOG_DIR"
  FAIL=$((FAIL + 1))
  echo ""
  echo "Results: $PASS passed, $FAIL failed"
  exit 1
fi

echo "  Log file: $LOG_FILE"

# Verify session log contents
LOG_CONTENT="$(cat "$LOG_FILE")"

# Check for session start event
assert_contains "log contains session start event" '"event":"start"' "$LOG_CONTENT"

# Check for shell_command events
SHELL_CMD_COUNT="$(grep -c '"type":"shell_command"' "$LOG_FILE" 2>/dev/null || true)"
SHELL_CMD_COUNT="$(echo "$SHELL_CMD_COUNT" | tr -d '[:space:]')"
[ -z "$SHELL_CMD_COUNT" ] && SHELL_CMD_COUNT=0
assert_gt "log contains shell_command events" 0 "$SHELL_CMD_COUNT"

# Check for session stop or logger_stop event
if echo "$LOG_CONTENT" | grep -q '"event":"agent_stop"\|"event":"logger_stop"'; then
  echo "  PASS: log contains stop event"
  PASS=$((PASS + 1))
else
  echo "  FAIL: log missing stop event"
  FAIL=$((FAIL + 1))
fi

# Check seq numbers are present and monotonic
SEQS="$(grep -o '"seq":[0-9]*' "$LOG_FILE" | cut -d: -f2)"
PREV=0
SEQ_OK=true
for s in $SEQS; do
  if [ "$s" -le "$PREV" ]; then
    SEQ_OK=false
    break
  fi
  PREV=$s
done
if [ "$SEQ_OK" = true ]; then
  echo "  PASS: seq numbers are monotonically increasing"
  PASS=$((PASS + 1))
else
  echo "  FAIL: seq numbers are not monotonic"
  FAIL=$((FAIL + 1))
fi

# Check for file_event (Linux only, best-effort)
if grep -q '"type":"file_event"' "$LOG_FILE"; then
  echo "  PASS: log contains file_event (inotifywait working)"
  PASS=$((PASS + 1))
else
  echo "  INFO: no file_event in log (may be expected on non-Linux or timing issue)"
fi

# Check session summary was printed
assert_contains "output contains session complete" "complete" "$OUTPUT"
assert_contains "output mentions selected agent" "Agent: shell" "$OUTPUT"

SELECTED_AGENT="$(cat "$TMPDIR/selected-agent.txt" 2>/dev/null || true)"
assert_eq "run --agent selects configured named agent" "shell" "$SELECTED_AGENT"

# Verify workspace writes keep host ownership on Linux bind mounts
EXPECTED_UID="$(id -u)"
EXPECTED_GID="$(id -g)"
ACTUAL_UID="$(stat -c '%u' "$TMPDIR/testfile.txt")"
assert_eq "workspace file is owned by invoking host uid" "$EXPECTED_UID" "$ACTUAL_UID"

if [ "$ACTUAL_UID" != "0" ]; then
  echo "  PASS: workspace file is not owned by root"
  PASS=$((PASS + 1))
else
  echo "  FAIL: workspace file should not be owned by root"
  FAIL=$((FAIL + 1))
fi

AGENT_HOME="$(cat "$TMPDIR/agent-home.txt" 2>/dev/null || true)"
assert_eq "agent HOME is non-root cache path" "/home/carranca" "$AGENT_HOME"

AGENT_GID="$(cat "$TMPDIR/agent-gid.txt" 2>/dev/null || true)"
assert_eq "agent primary gid matches invoking host gid" "$EXPECTED_GID" "$AGENT_GID"

HOST_GROUPS="$(id -G)"
AGENT_GROUPS="$(cat "$TMPDIR/agent-groups.txt" 2>/dev/null || true)"
for gid in $HOST_GROUPS; do
  if echo " $AGENT_GROUPS " | grep -q " $gid "; then
    echo "  PASS: agent groups include host gid $gid"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: agent groups missing host gid $gid"
    FAIL=$((FAIL + 1))
  fi
done

# Verify cache home directory was created
if [ -d "$TMPSTATE/cache/$REPO_ID/home" ]; then
  echo "  PASS: cache home directory created"
  PASS=$((PASS + 1))
else
  echo "  FAIL: cache home directory not created at $TMPSTATE/cache/$REPO_ID/home"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
