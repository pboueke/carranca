#!/usr/bin/env bash
# Failure mode tests: fail-closed behavior (requires Docker)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export CARRANCA_HOME="$SCRIPT_DIR"

PASS=0
FAIL=0

echo "=== test_fail_closed.sh (requires Docker) ==="

# Check Docker is available
if ! docker info >/dev/null 2>&1; then
  echo "  SKIP: Docker not available"
  exit 0
fi

# Test 1: carranca run without Docker running
# (Can't easily test this without stopping Docker, so we test other preconditions)

# Test 2: carranca run without .carranca.yml
TMPDIR="$(mktemp -d)"
TMPSTATE="$(mktemp -d)"
export CARRANCA_STATE="$TMPSTATE"
cd "$TMPDIR"
git init --quiet

if bash "$CARRANCA_HOME/cli/run.sh" 2>/dev/null; then
  echo "  FAIL: run without .carranca.yml should fail"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: run without .carranca.yml fails (precondition check)"
  PASS=$((PASS + 1))
fi

# Test 3: carranca run with missing agent.command
cat > ".carranca.yml" <<'EOF'
agent:
  adapter: default
runtime:
  network: true
EOF

if bash "$CARRANCA_HOME/cli/run.sh" 2>/dev/null; then
  echo "  FAIL: run with missing agent.command should fail"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: run with missing agent.command fails (config validation)"
  PASS=$((PASS + 1))
fi

# Cleanup
rm -rf "$TMPDIR" "$TMPSTATE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
