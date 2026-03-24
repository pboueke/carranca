#!/usr/bin/env bash
# Integration tests for carranca status (requires a supported container runtime)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export CARRANCA_HOME="$SCRIPT_DIR"
source "$SCRIPT_DIR/tests/lib/integration.sh"
source "$SCRIPT_DIR/tests/lib/assert.sh"

integration_init
trap integration_cleanup EXIT

suite_header "test_status.sh (requires $RUNTIME)"

integration_require_runtime
integration_create_repo
integration_init_project

cat > ".carranca.yml" <<'EOF'
agents:
  - name: shell
    adapter: stdin
    command: bash -c "echo status-run && touch /workspace/status-test.txt && sleep 5 && exit 0"
runtime:
  engine: auto
  network: true
policy:
  docs_before_code: warn
  tests_before_impl: warn
EOF

bash "$CARRANCA_HOME/cli/run.sh" >"$TMPDIR/run.out" 2>&1 &
RUN_PID=$!

REPO_ID="$(integration_repo_id)"
LOG_DIR="$TMPSTATE/sessions/$REPO_ID"

SESSION_ID=""
for _ in $(seq 1 40); do
  LOG_FILE="$(find "$LOG_DIR" -maxdepth 1 -type f -name '*.jsonl' 2>/dev/null | head -n 1)"
  if [ -n "$LOG_FILE" ]; then
    SESSION_ID="$(basename "$LOG_FILE" .jsonl)"
    if "$RUNTIME" ps --format '{{.Names}}' | grep -Fq -- "carranca-$SESSION_ID-logger"; then
      break
    fi
  fi
  sleep 0.5
done

test_start
STATUS_ACTIVE="$(bash "$CARRANCA_HOME/cli/status.sh" 2>&1)"
assert_contains "status reports active sessions section" "Active sessions:" "$STATUS_ACTIVE"
assert_contains "status reports running session id" "$SESSION_ID" "$STATUS_ACTIVE"
assert_contains "status reports recent sessions section while run is active" "Recent sessions:" "$STATUS_ACTIVE"

test_start
STATUS_DETAIL_ACTIVE="$(bash "$CARRANCA_HOME/cli/status.sh" --session "$SESSION_ID" 2>&1)"
assert_contains "status detail prints selected session id while active" "Session: $SESSION_ID" "$STATUS_DETAIL_ACTIVE"
assert_contains "status detail marks running session as active" "Status: active" "$STATUS_DETAIL_ACTIVE"
assert_contains "status detail prints command section while active" "Commands:" "$STATUS_DETAIL_ACTIVE"

wait "$RUN_PID" || true

test_start
STATUS_FINAL="$(bash "$CARRANCA_HOME/cli/status.sh" 2>&1)"
assert_contains "status reports repo heading after run completes" "Repo:" "$STATUS_FINAL"
assert_contains "status reports no active sessions after completion" "  (none)" "$STATUS_FINAL"
assert_contains "status keeps recent session after completion" "$SESSION_ID" "$STATUS_FINAL"

test_start
STATUS_DETAIL_FINAL="$(bash "$CARRANCA_HOME/cli/status.sh" --session "$SESSION_ID" 2>&1)"
assert_contains "status detail marks completed session as inactive" "Status: inactive" "$STATUS_DETAIL_FINAL"
assert_contains "status detail keeps action log path after completion" "Action log:" "$STATUS_DETAIL_FINAL"

echo ""
print_results
