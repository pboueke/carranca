#!/usr/bin/env bash
# Integration tests for carranca run (requires Docker)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export CARRANCA_HOME="$SCRIPT_DIR"

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

echo "=== test_run.sh (requires Docker) ==="

# Check Docker is available
if ! docker info >/dev/null 2>&1; then
  echo "  SKIP: Docker not available"
  exit 0
fi

# Setup
TMPSTATE="$(mktemp -d)"
TMPDIR="$(mktemp -d)"
export CARRANCA_STATE="$TMPSTATE"

cd "$TMPDIR"
git init --quiet

# Init the project with a simple mock agent
bash "$CARRANCA_HOME/cli/init.sh"

# Override agent command to something that runs and exits quickly
cat > ".carranca.yml" <<'EOF'
agent:
  adapter: default
  command: bash -c "echo hello-from-agent && touch /workspace/testfile.txt && exit 0"
runtime:
  network: true
policy:
  docs_before_code: warn
  tests_before_impl: warn
EOF

# Run carranca
echo "  Running carranca session (this may take a moment on first build)..."
OUTPUT="$(bash "$CARRANCA_HOME/cli/run.sh" 2>&1)" || true

# Find the session log
REPO_ID="$(source "$CARRANCA_HOME/cli/lib/common.sh" && source "$CARRANCA_HOME/cli/lib/identity.sh" && carranca_repo_id)"
LOG_DIR="$TMPSTATE/sessions/$REPO_ID"
LOG_FILE="$(ls -t "$LOG_DIR"/*.jsonl 2>/dev/null | head -1)"

if [ -z "$LOG_FILE" ]; then
  echo "  FAIL: No session log found in $LOG_DIR"
  FAIL=$((FAIL + 1))
  rm -rf "$TMPDIR" "$TMPSTATE"
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

# Verify cache home directory was created
if [ -d "$TMPSTATE/cache/$REPO_ID/home" ]; then
  echo "  PASS: cache home directory created"
  PASS=$((PASS + 1))
else
  echo "  FAIL: cache home directory not created at $TMPSTATE/cache/$REPO_ID/home"
  FAIL=$((FAIL + 1))
fi

# Cleanup (chattr +a files need special handling)
docker run --rm --cap-add LINUX_IMMUTABLE -v "$TMPSTATE:/state" ubuntu:24.04 \
  bash -c 'find /state -type f -exec chattr -a {} \; 2>/dev/null; rm -rf /state/*' 2>/dev/null || true
rm -rf "$TMPDIR" "$TMPSTATE" 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
