#!/usr/bin/env bash
# Integration tests for carranca log (requires a supported container runtime)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export CARRANCA_HOME="$SCRIPT_DIR"
source "$SCRIPT_DIR/tests/lib/integration.sh"
source "$SCRIPT_DIR/tests/lib/assert.sh"

integration_init
trap integration_cleanup EXIT

suite_header "test_log.sh (requires $RUNTIME)"

integration_require_runtime
integration_create_repo
integration_init_project

cat > ".carranca.yml" <<'EOF'
agents:
  - name: shell
    adapter: stdin
    command: bash -c "echo hello-log && touch /workspace/log-test.txt && printf updated >> /workspace/log-test.txt && exit 0"
runtime:
  engine: auto
  network: true
policy:
  docs_before_code: warn
  tests_before_impl: warn
EOF

test_start
RUN_OUTPUT="$(bash "$CARRANCA_HOME/cli/run.sh" 2>&1)" || true
assert_contains "run completes before log inspection" "complete" "$RUN_OUTPUT"

REPO_ID="$(integration_repo_id)"
LOG_DIR="$TMPSTATE/sessions/$REPO_ID"
LOG_FILE="$(find "$LOG_DIR" -maxdepth 1 -type f -name '*.jsonl' | sort | tail -1)"
SESSION_ID="$(basename "$LOG_FILE" .jsonl)"

test_start
LATEST_OUTPUT="$(bash "$CARRANCA_HOME/cli/log.sh" 2>&1)"
assert_contains "latest log prints session id" "Session: $SESSION_ID" "$LATEST_OUTPUT"
assert_contains "latest log prints unique touched paths" "Unique paths touched: 1" "$LATEST_OUTPUT"
assert_contains "latest log prints file event totals" "File events: 2 (1 create, 1 modify, 0 delete)" "$LATEST_OUTPUT"
assert_contains "latest log prints command summary" "Commands run:" "$LATEST_OUTPUT"
assert_contains "latest log prints top touched paths" "Top touched paths:" "$LATEST_OUTPUT"
assert_contains "latest log prints busiest file path" "/workspace/log-test.txt (2 events: 1 create, 1 modify, 0 delete)" "$LATEST_OUTPUT"
assert_contains "latest log prints action log path" "Action log: $LOG_FILE" "$LATEST_OUTPUT"
assert_contains "latest log prints command list" "hello-log" "$LATEST_OUTPUT"

test_start
EXACT_OUTPUT="$(bash "$CARRANCA_HOME/cli/log.sh" --session "$SESSION_ID" 2>&1)"
assert_contains "exact session output prints same session id" "Session: $SESSION_ID" "$EXACT_OUTPUT"
assert_eq "latest and exact session views match" "$LATEST_OUTPUT" "$EXACT_OUTPUT"

echo ""
print_results
