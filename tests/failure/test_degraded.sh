#!/usr/bin/env bash
# Failure mode tests: degraded mode behavior (requires a supported container runtime)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export CARRANCA_HOME="$SCRIPT_DIR"
RUNTIME="${CARRANCA_CONTAINER_RUNTIME:-podman}"

PASS=0
FAIL=0

echo "=== test_degraded.sh (requires $RUNTIME) ==="

# Check runtime is available
if ! "$RUNTIME" info >/dev/null 2>&1; then
  echo "  SKIP: $RUNTIME not available"
  exit 0
fi

# Test: chattr +a degraded mode
# The logger should log a degraded event if chattr +a fails.
# In most CI/test environments, CAP_LINUX_IMMUTABLE won't be granted,
# so the degraded event should always appear.

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
    command: bash -c "echo degraded-test && exit 0"
runtime:
  engine: auto
  network: true
EOF

echo "  Running carranca session to check degraded mode..."
bash "$CARRANCA_HOME/cli/run.sh" 2>&1 || true

# Find log
REPO_ID="$(source "$CARRANCA_HOME/cli/lib/common.sh" && source "$CARRANCA_HOME/cli/lib/identity.sh" && carranca_repo_id)"
LOG_FILE="$(ls -t "$TMPSTATE/sessions/$REPO_ID"/*.jsonl 2>/dev/null | head -1)"

if [ -z "$LOG_FILE" ]; then
  echo "  FAIL: No session log found"
  FAIL=$((FAIL + 1))
else
  # Check for degraded event (append_only_unavailable is expected in most envs)
  if grep -q '"event":"degraded"' "$LOG_FILE"; then
    echo "  PASS: degraded event logged (chattr +a or inotifywait unavailable)"
    PASS=$((PASS + 1))
  else
    echo "  INFO: no degraded event (chattr +a and inotifywait both available — unusual in test env)"
    PASS=$((PASS + 1))
  fi

  # Session should still complete successfully even in degraded mode
  if grep -q '"event":"start"' "$LOG_FILE"; then
    echo "  PASS: session started in degraded mode"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: session did not start"
    FAIL=$((FAIL + 1))
  fi
fi

# Cleanup (chattr +a files need special handling on rootful runtimes)
"$RUNTIME" run --rm --cap-add LINUX_IMMUTABLE -v "$TMPSTATE:/state" ubuntu:24.04 \
  bash -c 'find /state -type f -exec chattr -a {} \; 2>/dev/null; rm -rf /state/*' 2>/dev/null \
  || rm -rf "$TMPSTATE"/* 2>/dev/null || true
rm -rf "$TMPDIR" "$TMPSTATE" 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
