#!/usr/bin/env bash
# Integration tests for carranca log (requires a supported container runtime)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export CARRANCA_HOME="$SCRIPT_DIR"
RUNTIME="${CARRANCA_CONTAINER_RUNTIME:-podman}"

PASS=0
FAIL=0

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

echo "=== test_log.sh (requires $RUNTIME) ==="

if ! "$RUNTIME" info >/dev/null 2>&1; then
  echo "  SKIP: $RUNTIME not available"
  exit 0
fi

TMPSTATE="$(mktemp -d)"
TMPDIR="$(mktemp -d)"
export CARRANCA_STATE="$TMPSTATE"

cd "$TMPDIR"
git init --quiet

bash "$CARRANCA_HOME/cli/init.sh"

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

RUN_OUTPUT="$(bash "$CARRANCA_HOME/cli/run.sh" 2>&1)" || true
assert_contains "run completes before log inspection" "complete" "$RUN_OUTPUT"

REPO_ID="$(source "$CARRANCA_HOME/cli/lib/common.sh" && source "$CARRANCA_HOME/cli/lib/identity.sh" && carranca_repo_id)"
LOG_DIR="$TMPSTATE/sessions/$REPO_ID"
LOG_FILE="$(find "$LOG_DIR" -maxdepth 1 -type f -name '*.jsonl' | sort | tail -1)"
SESSION_ID="$(basename "$LOG_FILE" .jsonl)"

LATEST_OUTPUT="$(bash "$CARRANCA_HOME/cli/log.sh" 2>&1)"
assert_contains "latest log prints session id" "Session: $SESSION_ID" "$LATEST_OUTPUT"
assert_contains "latest log prints unique touched paths" "Unique paths touched: 1" "$LATEST_OUTPUT"
assert_contains "latest log prints file event totals" "File events: 2 (1 create, 1 modify, 0 delete)" "$LATEST_OUTPUT"
assert_contains "latest log prints command summary" "Commands run:" "$LATEST_OUTPUT"
assert_contains "latest log prints top touched paths" "Top touched paths:" "$LATEST_OUTPUT"
assert_contains "latest log prints busiest file path" "/workspace/log-test.txt (2 events: 1 create, 1 modify, 0 delete)" "$LATEST_OUTPUT"
assert_contains "latest log prints action log path" "Action log: $LOG_FILE" "$LATEST_OUTPUT"
assert_contains "latest log prints command list" "hello-log" "$LATEST_OUTPUT"

EXACT_OUTPUT="$(bash "$CARRANCA_HOME/cli/log.sh" --session "$SESSION_ID" 2>&1)"
assert_contains "exact session output prints same session id" "Session: $SESSION_ID" "$EXACT_OUTPUT"
assert_eq "latest and exact session views match" "$LATEST_OUTPUT" "$EXACT_OUTPUT"

"$RUNTIME" run --rm --cap-add LINUX_IMMUTABLE -v "$TMPSTATE:/state" ubuntu:24.04 \
  bash -c 'find /state -type f -exec chattr -a {} \; 2>/dev/null; rm -rf /state/*' 2>/dev/null \
  || rm -rf "$TMPSTATE"/* 2>/dev/null || true
rm -rf "$TMPDIR" "$TMPSTATE" 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
