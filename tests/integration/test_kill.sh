#!/usr/bin/env bash
# Integration tests for carranca kill (requires a supported container runtime)
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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -Fq -- "$needle"; then
    echo "  FAIL: $desc (did not expect '$needle')"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  fi
}

echo "=== test_kill.sh (requires $RUNTIME) ==="

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
  "$RUNTIME" ps -a --format '{{.Names}}' | awk '/^carranca-[0-9a-f]+-(logger|agent)$/{print $0}' | xargs -r "$RUNTIME" rm -f >/dev/null 2>&1 || true
  "$RUNTIME" volume ls --format '{{.Name}}' | awk '/^carranca-[0-9a-f]+-fifo$/{print $0}' | xargs -r "$RUNTIME" volume rm >/dev/null 2>&1 || true
  "$RUNTIME" images --format '{{.Repository}}' | awk '/^carranca-[0-9a-f]+-(logger|agent)$/{print $1}' | xargs -r "$RUNTIME" rmi >/dev/null 2>&1 || true
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

KILL_ONE_OUTPUT="$(printf 'y\n' | bash "$CARRANCA_HOME/cli/kill.sh" --session "$FIRST_SESSION" 2>&1)"
assert_contains "kill specific confirms stopped session" "Stopped session $FIRST_SESSION" "$KILL_ONE_OUTPUT"

sleep 1
NAMES_AFTER_ONE="$("$RUNTIME" ps --format '{{.Names}}')"
assert_not_contains "kill specific removes first logger" "carranca-$FIRST_SESSION-logger" "$NAMES_AFTER_ONE"
assert_contains "kill specific leaves second logger running" "carranca-$SECOND_SESSION-logger" "$NAMES_AFTER_ONE"

KILL_ALL_OUTPUT="$(printf 'yes\n' | bash "$CARRANCA_HOME/cli/kill.sh" 2>&1)"
assert_contains "kill all stops remaining session" "Stopped session $SECOND_SESSION" "$KILL_ALL_OUTPUT"

sleep 1
NAMES_AFTER_ALL="$("$RUNTIME" ps --format '{{.Names}}')"
assert_not_contains "kill all removes all carranca loggers" "carranca-$SECOND_SESSION-logger" "$NAMES_AFTER_ALL"

wait "$RUN1_PID" || true
wait "$RUN2_PID" || true

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
