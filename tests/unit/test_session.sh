#!/usr/bin/env bash
# Unit tests for cli/lib/session.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0

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

echo "=== test_session.sh ==="

FAKEBIN="$(mktemp -d)"
SESSION_ID="a1b2c3d4"

cat > "$FAKEBIN/docker" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "ps" ] && [ "$2" = "-a" ]; then
  printf '%s\n' "carranca-a1b2c3d4-logger" "carranca-deadbeef-agent"
  exit 0
fi
if [ "$1" = "ps" ]; then
  printf '%s\n' "carranca-a1b2c3d4-logger" "carranca-a1b2c3d4-agent" "carranca-deadbeef-agent" "unrelated"
  exit 0
fi
printf '%s\n' "$*" >> "${TEST_DOCKER_LOG:?}"
exit 0
EOF
chmod +x "$FAKEBIN/docker"

export TEST_DOCKER_LOG="$(mktemp)"
export PATH="$FAKEBIN:$PATH"

source "$SCRIPT_DIR/cli/lib/session.sh"

assert_eq "session prefix uses carranca namespace" "carranca-$SESSION_ID" "$(carranca_session_prefix "$SESSION_ID")"
assert_eq "logger name uses session id" "carranca-$SESSION_ID-logger" "$(carranca_session_logger_name "$SESSION_ID")"
assert_eq "agent name uses session id" "carranca-$SESSION_ID-agent" "$(carranca_session_agent_name "$SESSION_ID")"
assert_eq "fifo volume uses session id" "carranca-$SESSION_ID-fifo" "$(carranca_session_fifo_volume "$SESSION_ID")"
assert_eq "logger image uses session id" "carranca-$SESSION_ID-logger" "$(carranca_session_logger_image "$SESSION_ID")"
assert_eq "agent image uses session id" "carranca-$SESSION_ID-agent" "$(carranca_session_agent_image "$SESSION_ID")"

SESSION_EXISTS_RC=0
carranca_session_exists "$SESSION_ID" || SESSION_EXISTS_RC=$?
assert_eq "session exists checks all containers" "0" "$SESSION_EXISTS_RC"

SESSION_ACTIVE_RC=0
carranca_session_is_active "$SESSION_ID" || SESSION_ACTIVE_RC=$?
assert_eq "session is active when matching running containers exist" "0" "$SESSION_ACTIVE_RC"

GLOBAL_ACTIVE_IDS="$(carranca_session_global_active_ids)"
assert_eq "global active ids are unique and sorted" "$(printf '%s\n' a1b2c3d4 deadbeef)" "$GLOBAL_ACTIVE_IDS"

carranca_session_stop "$SESSION_ID"
STOP_LOG="$(cat "$TEST_DOCKER_LOG")"
assert_eq "session stop removes agent first" "rm -f carranca-a1b2c3d4-agent
stop --timeout 5 carranca-a1b2c3d4-logger
rm -f carranca-a1b2c3d4-logger
volume rm carranca-a1b2c3d4-fifo
rmi carranca-a1b2c3d4-agent carranca-a1b2c3d4-logger" "$STOP_LOG"

rm -rf "$FAKEBIN"
rm -f "$TEST_DOCKER_LOG"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
