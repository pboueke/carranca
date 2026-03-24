#!/usr/bin/env bash
# Integration tests for carranca kill (requires a supported container runtime)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export CARRANCA_HOME="$SCRIPT_DIR"
source "$SCRIPT_DIR/tests/lib/integration.sh"
source "$SCRIPT_DIR/tests/lib/assert.sh"

integration_init
trap integration_cleanup EXIT

suite_header "test_kill.sh (requires $RUNTIME)"

integration_require_runtime
integration_create_repo
integration_init_project

cat > ".carranca.yml" <<'EOF'
agents:
  - name: shell
    adapter: stdin
    command: bash -c "echo kill-test && trap 'exit 130' INT TERM && sleep 60"
runtime:
  engine: auto
  network: true
policy:
  docs_before_code: warn
  tests_before_impl: warn
EOF

bash "$CARRANCA_HOME/cli/run.sh" >"$TMPDIR/run1.out" 2>&1 &
RUN1_PID=$!
bash "$CARRANCA_HOME/cli/run.sh" >"$TMPDIR/run2.out" 2>&1 &
RUN2_PID=$!

SESSION_IDS=""
for _ in $(seq 1 60); do
  SESSION_IDS="$("$RUNTIME" ps --format '{{.Names}}' | sed -n 's/^carranca-\([0-9a-f][0-9a-f]*\)-logger$/\1/p' | sort -u)"
  if [ "$(printf '%s\n' "$SESSION_IDS" | sed '/^$/d' | wc -l | tr -d '[:space:]')" = "2" ]; then
    break
  fi
  sleep 0.5
done

FIRST_SESSION="$(printf '%s\n' "$SESSION_IDS" | sed -n '1p')"
SECOND_SESSION="$(printf '%s\n' "$SESSION_IDS" | sed -n '2p')"

test_start
KILL_ONE_OUTPUT="$(printf 'y\n' | bash "$CARRANCA_HOME/cli/kill.sh" --session "$FIRST_SESSION" 2>&1)"
assert_contains "kill specific confirms stopped session" "Stopped session $FIRST_SESSION" "$KILL_ONE_OUTPUT"

sleep 1
NAMES_AFTER_ONE="$("$RUNTIME" ps --format '{{.Names}}')"
assert_not_contains "kill specific removes first logger" "carranca-$FIRST_SESSION-logger" "$NAMES_AFTER_ONE"
assert_contains "kill specific leaves second logger running" "carranca-$SECOND_SESSION-logger" "$NAMES_AFTER_ONE"

test_start
KILL_ALL_OUTPUT="$(printf 'yes\n' | bash "$CARRANCA_HOME/cli/kill.sh" 2>&1)"
assert_contains "kill all stops remaining session" "Stopped session $SECOND_SESSION" "$KILL_ALL_OUTPUT"

sleep 1
NAMES_AFTER_ALL="$("$RUNTIME" ps --format '{{.Names}}')"
assert_not_contains "kill all removes all carranca loggers" "carranca-$SECOND_SESSION-logger" "$NAMES_AFTER_ALL"

wait "$RUN1_PID" || true
wait "$RUN2_PID" || true

echo ""
print_results
