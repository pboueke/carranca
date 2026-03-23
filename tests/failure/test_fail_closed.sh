#!/usr/bin/env bash
# Failure mode tests: fail-closed behavior (requires a supported container runtime)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export CARRANCA_HOME="$SCRIPT_DIR"
RUNTIME="${CARRANCA_CONTAINER_RUNTIME:-podman}"

PASS=0
FAIL=0

echo "=== test_fail_closed.sh (requires $RUNTIME) ==="

# Check runtime is available
if ! "$RUNTIME" info >/dev/null 2>&1; then
  echo "  SKIP: $RUNTIME not available"
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
  engine: auto
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
  engine: auto
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
  engine: auto
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

# Test 11: running session fails closed if logger disappears mid-session
printf 'y\n' | bash "$CARRANCA_HOME/cli/init.sh" --force --agent codex >/dev/null 2>&1 || true
cat > ".carranca.yml" <<'EOF'
agents:
  - name: shell
    adapter: stdin
    command: bash -c "trap 'exit 130' INT TERM; while true; do sleep 1; done"
runtime:
  engine: auto
  network: true
EOF

RUN_OUTPUT_FILE="$TMPDIR/fail-closed-run.out"
bash "$CARRANCA_HOME/cli/run.sh" >"$RUN_OUTPUT_FILE" 2>&1 &
RUN_PID=$!

LOGGER_NAME=""
AGENT_NAME=""
for _ in $(seq 1 60); do
  LOGGER_NAME="$("$RUNTIME" ps --format '{{.Names}}' | awk '/^carranca-[0-9a-f]+-logger$/{print; exit}')"
  AGENT_NAME="$("$RUNTIME" ps --format '{{.Names}}' | awk '/^carranca-[0-9a-f]+-agent$/{print; exit}')"
  if [ -n "$LOGGER_NAME" ] && [ -n "$AGENT_NAME" ]; then
    break
  fi
  sleep 0.5
done

if [ -z "$LOGGER_NAME" ] || [ -z "$AGENT_NAME" ]; then
  sleep 2
  if kill -0 "$RUN_PID" 2>/dev/null; then
    echo "  FAIL: fail-closed setup did not start both logger and agent"
    FAIL=$((FAIL + 1))
    kill "$RUN_PID" 2>/dev/null || true
    wait "$RUN_PID" 2>/dev/null || true
  else
    if wait "$RUN_PID" 2>/dev/null; then
      RUN_RC=0
    else
      RUN_RC=$?
    fi
    RUN_OUTPUT="$(cat "$RUN_OUTPUT_FILE" 2>/dev/null || true)"

    if [ "$RUN_RC" -ne 0 ]; then
      echo "  PASS: run exits non-zero when logger dies before steady state"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: run should fail non-zero when logger dies before steady state"
      FAIL=$((FAIL + 1))
    fi

    if echo "$RUN_OUTPUT" | grep -Fq -- "fail closed"; then
      echo "  PASS: early logger loss reports fail-closed reason"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: early logger loss should report fail-closed reason"
      FAIL=$((FAIL + 1))
    fi
  fi
else
  "$RUNTIME" rm -f "$LOGGER_NAME" >/dev/null 2>&1 || true

  RUN_RC=0
  RUN_EXITED=false
  for _ in $(seq 1 40); do
    if ! kill -0 "$RUN_PID" 2>/dev/null; then
      if wait "$RUN_PID" 2>/dev/null; then
        RUN_RC=0
      else
        RUN_RC=$?
      fi
      RUN_EXITED=true
      break
    fi
    sleep 0.5
  done

  if [ "$RUN_EXITED" != true ]; then
    echo "  FAIL: run should exit when logger disappears"
    FAIL=$((FAIL + 1))
    kill "$RUN_PID" 2>/dev/null || true
    wait "$RUN_PID" 2>/dev/null || true
  elif [ "$RUN_RC" -eq 0 ]; then
    echo "  FAIL: run should fail non-zero when logger disappears"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: run exits non-zero when logger disappears"
    PASS=$((PASS + 1))
  fi

  if "$RUNTIME" ps --format '{{.Names}}' | grep -Fq -- "$AGENT_NAME"; then
    echo "  FAIL: agent should not keep running after logger disappears"
    FAIL=$((FAIL + 1))
    "$RUNTIME" rm -f "$AGENT_NAME" >/dev/null 2>&1 || true
  else
    echo "  PASS: agent stops after logger disappears"
    PASS=$((PASS + 1))
  fi

  RUN_OUTPUT="$(cat "$RUN_OUTPUT_FILE" 2>/dev/null || true)"
  if echo "$RUN_OUTPUT" | grep -Fq -- "fail closed"; then
    echo "  PASS: fail-closed run reports fail-closed reason"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: fail-closed run should report fail-closed reason"
    FAIL=$((FAIL + 1))
  fi
fi

# Cleanup
rm -rf "$TMPDIR" "$TMPSTATE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
