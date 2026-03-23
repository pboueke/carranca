#!/usr/bin/env bash
# Unit tests for carranca kill
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$SCRIPT_DIR/cli/kill.sh"

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

echo "=== test_kill.sh ==="

FAKEBIN="$(mktemp -d)"
DOCKER_LOG="$(mktemp)"

cat > "$FAKEBIN/docker" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "info ")
    exit 0
    ;;
  "ps --format")
    printf '%s\n' "carranca-a1b2c3d4-logger" "carranca-b2c3d4e5-agent"
    exit 0
    ;;
  "ps -a")
    printf '%s\n' "carranca-a1b2c3d4-logger" "carranca-b2c3d4e5-agent"
    exit 0
    ;;
esac
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
exit 0
EOF
chmod +x "$FAKEBIN/docker"
export DOCKER_LOG
export CARRANCA_CONTAINER_RUNTIME="docker"
export PATH="$FAKEBIN:$PATH"

HELP_OUTPUT="$(bash "$CLI" help 2>&1)"
assert_contains "help output includes usage" "Usage: carranca kill" "$HELP_OUTPUT"

CANCEL_OUTPUT="$(printf 'n\n' | bash "$CLI" --session deadbeef 2>&1)" || true
assert_contains "kill prompts for specific session confirmation" "Stop session deadbeef?" "$CANCEL_OUTPUT"
assert_contains "kill cancel reports cancellation" "Cancelled" "$CANCEL_OUTPUT"
assert_eq "kill cancel does not invoke runtime stop commands" "0" "$(wc -l < "$DOCKER_LOG" | tr -d '[:space:]')"

WARN_OUTPUT="$(printf 'y\n' | bash "$CLI" --session deadbeef 2>&1)" || true
assert_contains "kill warns for inactive session" "Session deadbeef is not active or was not found" "$WARN_OUTPUT"

>"$DOCKER_LOG"
KILL_ONE_OUTPUT="$(printf 'yes\n' | bash "$CLI" --session a1b2c3d4 2>&1)"
assert_contains "kill reports stopped session" "Stopped session a1b2c3d4" "$KILL_ONE_OUTPUT"
assert_contains "kill specific removes agent container" "rm -f carranca-a1b2c3d4-agent" "$(cat "$DOCKER_LOG")"

>"$DOCKER_LOG"
KILL_ALL_OUTPUT="$(printf 'y\n' | bash "$CLI" 2>&1)"
assert_contains "kill all asks for confirmation" "Stop all 2 active session(s)?" "$KILL_ALL_OUTPUT"
assert_contains "kill all stops first active session" "Stopped session a1b2c3d4" "$KILL_ALL_OUTPUT"
assert_contains "kill all stops second active session" "Stopped session b2c3d4e5" "$KILL_ALL_OUTPUT"

rm -rf "$FAKEBIN"
rm -f "$DOCKER_LOG"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
