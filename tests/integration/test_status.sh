#!/usr/bin/env bash
# Integration tests for carranca status (requires a supported container runtime)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export CARRANCA_HOME="$SCRIPT_DIR"
RUNTIME="${CARRANCA_CONTAINER_RUNTIME:-podman}"

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

echo "=== test_status.sh (requires $RUNTIME) ==="

if ! "$RUNTIME" info >/dev/null 2>&1; then
  echo "  SKIP: $RUNTIME not available"
  exit 0
fi

TMPSTATE="$(mktemp -d)"
TMPDIR="$(mktemp -d)"
export CARRANCA_STATE="$TMPSTATE"

cleanup() {
  "$RUNTIME" run --rm --cap-add LINUX_IMMUTABLE -v "$TMPSTATE:/state" ubuntu:24.04 \
    bash -c 'find /state -type f -exec chattr -a {} \; 2>/dev/null; rm -rf /state/*' 2>/dev/null \
    || rm -rf "$TMPSTATE"/* 2>/dev/null || true
  rm -rf "$TMPDIR" "$TMPSTATE" 2>/dev/null || true
}
trap cleanup EXIT

cd "$TMPDIR"
git init --quiet

bash "$CARRANCA_HOME/cli/init.sh"

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

REPO_ID="$(source "$CARRANCA_HOME/cli/lib/common.sh" && source "$CARRANCA_HOME/cli/lib/identity.sh" && carranca_repo_id)"
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

STATUS_ACTIVE="$(bash "$CARRANCA_HOME/cli/status.sh" 2>&1)"
assert_contains "status reports active sessions section" "Active sessions:" "$STATUS_ACTIVE"
assert_contains "status reports running session id" "$SESSION_ID" "$STATUS_ACTIVE"
assert_contains "status reports recent sessions section while run is active" "Recent sessions:" "$STATUS_ACTIVE"

STATUS_DETAIL_ACTIVE="$(bash "$CARRANCA_HOME/cli/status.sh" --session "$SESSION_ID" 2>&1)"
assert_contains "status detail prints selected session id while active" "Session: $SESSION_ID" "$STATUS_DETAIL_ACTIVE"
assert_contains "status detail marks running session as active" "Status: active" "$STATUS_DETAIL_ACTIVE"
assert_contains "status detail prints command section while active" "Commands:" "$STATUS_DETAIL_ACTIVE"

wait "$RUN_PID" || true

STATUS_FINAL="$(bash "$CARRANCA_HOME/cli/status.sh" 2>&1)"
assert_contains "status reports repo heading after run completes" "Repo:" "$STATUS_FINAL"
assert_contains "status reports no active sessions after completion" "  (none)" "$STATUS_FINAL"
assert_contains "status keeps recent session after completion" "$SESSION_ID" "$STATUS_FINAL"

STATUS_DETAIL_FINAL="$(bash "$CARRANCA_HOME/cli/status.sh" --session "$SESSION_ID" 2>&1)"
assert_contains "status detail marks completed session as inactive" "Status: inactive" "$STATUS_DETAIL_FINAL"
assert_contains "status detail keeps action log path after completion" "Action log:" "$STATUS_DETAIL_FINAL"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
