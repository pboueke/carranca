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
agents:
  - name: codex
    adapter: codex
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

# Test 4: carranca config without .carranca/Containerfile
cat > ".carranca.yml" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
runtime:
  network: true
EOF

if bash "$CARRANCA_HOME/cli/config.sh" 2>/dev/null; then
  echo "  FAIL: config without .carranca/Containerfile should fail"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: config without .carranca/Containerfile fails (precondition check)"
  PASS=$((PASS + 1))
fi

mkdir -p .carranca
cat > ".carranca/Containerfile" <<'EOF'
FROM alpine:3.21
RUN apk add --no-cache bash coreutils curl git ca-certificates
COPY shell-wrapper.sh /usr/local/bin/shell-wrapper.sh
RUN chmod +x /usr/local/bin/shell-wrapper.sh
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/shell-wrapper.sh"]
EOF

if bash "$CARRANCA_HOME/cli/config.sh" 2>/dev/null; then
  echo "  FAIL: config with missing agent.command should fail"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: config with missing agent.command fails (config validation)"
  PASS=$((PASS + 1))
fi

# Test 5: carranca log with no logs for current repo
cat > ".carranca.yml" <<'EOF'
agents:
  - name: codex
    adapter: stdin
    command: bash -c "exit 0"
runtime:
  network: true
EOF

if bash "$CARRANCA_HOME/cli/log.sh" 2>/dev/null; then
  echo "  FAIL: log without prior sessions should fail"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: log without prior sessions fails"
  PASS=$((PASS + 1))
fi

# Test 6: carranca log with unknown exact session id
REPO_ID="$(source "$CARRANCA_HOME/cli/lib/common.sh" && source "$CARRANCA_HOME/cli/lib/identity.sh" && carranca_repo_id)"
mkdir -p "$TMPSTATE/sessions/$REPO_ID"
touch "$TMPSTATE/sessions/$REPO_ID/known1234.jsonl"

if bash "$CARRANCA_HOME/cli/log.sh" --session missing1234 2>/dev/null; then
  echo "  FAIL: log with missing exact session id should fail"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: log with missing exact session id fails"
  PASS=$((PASS + 1))
fi

# Test 7: run with unknown named agent
if bash "$CARRANCA_HOME/cli/run.sh" --agent missing 2>/dev/null; then
  echo "  FAIL: run with unknown named agent should fail"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: run with unknown named agent fails"
  PASS=$((PASS + 1))
fi

# Test 8: config with unknown named agent
if bash "$CARRANCA_HOME/cli/config.sh" --agent missing 2>/dev/null; then
  echo "  FAIL: config with unknown named agent should fail"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: config with unknown named agent fails"
  PASS=$((PASS + 1))
fi

# Test 9: init with unsupported agent
if bash "$CARRANCA_HOME/cli/init.sh" --agent missing 2>/dev/null; then
  echo "  FAIL: init with unsupported agent should fail"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: init with unsupported agent fails"
  PASS=$((PASS + 1))
fi

# Test 10: init with missing agent value
if bash "$CARRANCA_HOME/cli/init.sh" --agent 2>/dev/null; then
  echo "  FAIL: init with missing --agent value should fail"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: init with missing --agent value fails"
  PASS=$((PASS + 1))
fi

# Cleanup
rm -rf "$TMPDIR" "$TMPSTATE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
