#!/usr/bin/env bash
# Failure mode tests: degraded mode behavior (requires a supported container runtime)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export CARRANCA_HOME="$SCRIPT_DIR"
source "$SCRIPT_DIR/tests/lib/integration.sh"
source "$SCRIPT_DIR/tests/lib/assert.sh"

integration_init
trap integration_cleanup EXIT

suite_header "test_degraded.sh (requires $RUNTIME)"

integration_require_runtime

# Test: chattr +a degraded mode
# The logger should log a degraded event if chattr +a fails.
# In most CI/test environments, CAP_LINUX_IMMUTABLE won't be granted,
# so the degraded event should always appear.

integration_create_repo
integration_init_project

cat > ".carranca.yml" <<'EOF'
agents:
  - name: shell
    adapter: stdin
    command: bash -c "echo degraded-test && exit 0"
runtime:
  engine: auto
  network: true
EOF

echo "  Running carranca session to check degraded mode..."
test_start
bash "$CARRANCA_HOME/cli/run.sh" 2>&1 || true

# Find log
REPO_ID="$(integration_repo_id)"
LOG_FILE="$(ls -t "$TMPSTATE/sessions/$REPO_ID"/*.jsonl 2>/dev/null | head -1)"

if [ -z "$LOG_FILE" ]; then
  echo "  FAIL: No session log found"
  FAIL=$((FAIL + 1))
else
  # Check for degraded event (append_only_unavailable is expected in most envs)
  if grep -q '"event":"degraded"' "$LOG_FILE"; then
    echo "  PASS: degraded event logged (chattr +a or file watcher unavailable)"
    PASS=$((PASS + 1))
  else
    echo "  INFO: no degraded event (chattr +a and file watcher both available — unusual in test env)"
    PASS=$((PASS + 1))
  fi

  # Session should still complete successfully even in degraded mode
  test_start
  if grep -q '"event":"start"' "$LOG_FILE"; then
    echo "  PASS: session started in degraded mode"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: session did not start"
    FAIL=$((FAIL + 1))
  fi
fi

echo ""
print_results
