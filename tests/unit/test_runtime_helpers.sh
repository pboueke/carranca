#!/usr/bin/env bash
# Unit tests for runtime helper functions (shell-wrapper.sh and logger.sh)
# Tests functions that can run outside Docker without a FIFO.
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

assert_match() {
  local desc="$1" pattern="$2" actual="$3"
  if [[ "$actual" =~ $pattern ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected match '$pattern', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== test_runtime_helpers.sh ==="

# --- shell-wrapper.sh helpers ---
# Source only the pure functions (override FIFO-dependent parts)

# json_escape: escapes backslashes, quotes, tabs and strips newlines
json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr -d '\n'
}

val="$(json_escape 'hello "world"')"
assert_eq "json_escape escapes double quotes" 'hello \"world\"' "$val"

val="$(json_escape 'path\\to\\file')"
assert_eq "json_escape escapes backslashes" 'path\\\\to\\\\file' "$val"

val="$(json_escape "tab	here")"
assert_eq "json_escape escapes tabs" 'tab\there' "$val"

val="$(json_escape 'no special chars')"
assert_eq "json_escape passes plain text through" 'no special chars' "$val"

# timestamp: produces ISO 8601 UTC
timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

ts="$(timestamp)"
assert_match "timestamp is ISO 8601 UTC" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$ts"

# ms_now: produces millisecond or second epoch
ms_now() {
  date +%s%3N 2>/dev/null || date +%s
}

ms="$(ms_now)"
assert_match "ms_now is numeric" '^[0-9]+$' "$ms"

# Verify ms_now is at least 13 digits (milliseconds) or 10 (seconds fallback)
if [ "${#ms}" -ge 10 ]; then
  echo "  PASS: ms_now produces epoch timestamp (${#ms} digits)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: ms_now too short (${#ms} digits, expected >= 10)"
  FAIL=$((FAIL + 1))
fi

# --- logger.sh helpers ---

# write_log: test that it assigns seq numbers and appends JSON to a log file
TMPDIR="$(mktemp -d)"
SEQ_FILE="$TMPDIR/seq"
SEQ_LOCK="$TMPDIR/seq.lock"
LOG_FILE="$TMPDIR/test.jsonl"

echo "0" > "$SEQ_FILE"
touch "$LOG_FILE"

write_log() {
  local line="$1"
  {
    flock 9
    local seq
    seq=$(cat "$SEQ_FILE" 2>/dev/null || echo 0)
    seq=$((seq + 1))
    echo "$seq" > "$SEQ_FILE"
    printf '%s\n' "${line%\}},\"seq\":$seq}" >> "$LOG_FILE"
  } 9>"$SEQ_LOCK"
}

write_log '{"type":"test","msg":"first"}'
write_log '{"type":"test","msg":"second"}'
write_log '{"type":"test","msg":"third"}'

LINE_COUNT="$(wc -l < "$LOG_FILE" | tr -d '[:space:]')"
assert_eq "write_log writes 3 lines" "3" "$LINE_COUNT"

# Check seq numbers are injected and monotonic
SEQ1="$(sed -n '1p' "$LOG_FILE" | grep -o '"seq":[0-9]*' | cut -d: -f2)"
SEQ2="$(sed -n '2p' "$LOG_FILE" | grep -o '"seq":[0-9]*' | cut -d: -f2)"
SEQ3="$(sed -n '3p' "$LOG_FILE" | grep -o '"seq":[0-9]*' | cut -d: -f2)"
assert_eq "write_log seq 1" "1" "$SEQ1"
assert_eq "write_log seq 2" "2" "$SEQ2"
assert_eq "write_log seq 3" "3" "$SEQ3"

# Check JSON structure preserved
assert_match "write_log preserves JSON fields" '"msg":"first"' "$(sed -n '1p' "$LOG_FILE")"

# --- write_event: test FIFO write with a real FIFO ---

FIFO_PATH="$TMPDIR/fifo"
mkfifo "$FIFO_PATH"
chmod 0666 "$FIFO_PATH"

FIFO_MODE="$(stat -c '%a' "$FIFO_PATH")"
assert_eq "logger FIFO is world-readable and writable" "666" "$FIFO_MODE"

write_event() {
  printf '%s\n' "$1" > "$FIFO_PATH" 2>/dev/null
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FIFO_FAIL"
    return 1
  fi
}

# Read from FIFO in background
RECEIVED=""
cat "$FIFO_PATH" > "$TMPDIR/fifo_out" &
CAT_PID=$!

write_event '{"type":"test_event"}'
sleep 0.2
kill "$CAT_PID" 2>/dev/null || true
wait "$CAT_PID" 2>/dev/null || true

RECEIVED="$(cat "$TMPDIR/fifo_out")"
assert_eq "write_event sends JSON through FIFO" '{"type":"test_event"}' "$RECEIVED"

# --- _cleanup and _heartbeat_loop: verify they are defined in source ---
# These functions require a running container context (FIFO, Docker)
# so we verify they exist in the source rather than executing them.
# Integration tests (test_run.sh) exercise them end-to-end.

if grep -q '^_cleanup()' "$SCRIPT_DIR/runtime/logger.sh"; then
  echo "  PASS: _cleanup defined in logger.sh"
  PASS=$((PASS + 1))
else
  echo "  FAIL: _cleanup not found in logger.sh"
  FAIL=$((FAIL + 1))
fi

if grep -q '^_heartbeat_loop()' "$SCRIPT_DIR/runtime/shell-wrapper.sh"; then
  echo "  PASS: _heartbeat_loop defined in shell-wrapper.sh"
  PASS=$((PASS + 1))
else
  echo "  FAIL: _heartbeat_loop not found in shell-wrapper.sh"
  FAIL=$((FAIL + 1))
fi

if grep -q '^_fifo_watchdog_loop()' "$SCRIPT_DIR/runtime/shell-wrapper.sh"; then
  echo "  PASS: _fifo_watchdog_loop defined in shell-wrapper.sh"
  PASS=$((PASS + 1))
else
  echo "  FAIL: _fifo_watchdog_loop not found in shell-wrapper.sh"
  FAIL=$((FAIL + 1))
fi

if grep -q '^fail_closed()' "$SCRIPT_DIR/runtime/shell-wrapper.sh"; then
  echo "  PASS: fail_closed defined in shell-wrapper.sh"
  PASS=$((PASS + 1))
else
  echo "  FAIL: fail_closed not found in shell-wrapper.sh"
  FAIL=$((FAIL + 1))
fi

if grep -q '^fifo_is_healthy()' "$SCRIPT_DIR/runtime/shell-wrapper.sh"; then
  echo "  PASS: fifo_is_healthy defined in shell-wrapper.sh"
  PASS=$((PASS + 1))
else
  echo "  FAIL: fifo_is_healthy not found in shell-wrapper.sh"
  FAIL=$((FAIL + 1))
fi

# Test fifo_is_healthy behavior
FIFO_TEST_DIR="$(mktemp -d)"
FIFO_PATH="$FIFO_TEST_DIR/events"
mkfifo "$FIFO_PATH"
chmod 0666 "$FIFO_PATH"

source /dev/stdin <<FIFO_FUNC
$(grep -A3 '^fifo_is_healthy()' "$SCRIPT_DIR/runtime/shell-wrapper.sh")
FIFO_FUNC

if FIFO_PATH="$FIFO_PATH" fifo_is_healthy; then
  echo "  PASS: fifo_is_healthy returns true for valid FIFO"
  PASS=$((PASS + 1))
else
  echo "  FAIL: fifo_is_healthy should return true for valid FIFO"
  FAIL=$((FAIL + 1))
fi

rm -f "$FIFO_PATH"
if ! FIFO_PATH="$FIFO_PATH" fifo_is_healthy; then
  echo "  PASS: fifo_is_healthy returns false for missing FIFO"
  PASS=$((PASS + 1))
else
  echo "  FAIL: fifo_is_healthy should return false for missing FIFO"
  FAIL=$((FAIL + 1))
fi

rm -rf "$FIFO_TEST_DIR"

# --- cli/lib/runtime.sh helpers ---
RUNTIME_FAKEBIN="$(mktemp -d)"
RUNTIME_LOG="$(mktemp)"
export RUNTIME_LOG
export PATH="$RUNTIME_FAKEBIN:$PATH"

cat > "$RUNTIME_FAKEBIN/podman" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "info" ]; then
  if [ "${2:-}" = "--format" ]; then
    printf '%s\n' "${PODMAN_ROOTLESS:-true}"
    exit 0
  fi
  exit 0
fi
printf '%s\n' "$*" >> "${RUNTIME_LOG:?}"
exit 0
EOF
chmod +x "$RUNTIME_FAKEBIN/podman"

cat > "$RUNTIME_FAKEBIN/docker" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "info" ]; then
  if [ "${2:-}" = "--format" ]; then
    printf '%s\n' "false"
    exit 0
  fi
  exit 0
fi
printf '%s\n' "docker:$*" >> "${RUNTIME_LOG:?}"
exit 0
EOF
chmod +x "$RUNTIME_FAKEBIN/docker"

source "$SCRIPT_DIR/cli/lib/common.sh"
source "$SCRIPT_DIR/cli/lib/runtime.sh"

assert_eq "runtime validates auto engine" "0" "$(carranca_runtime_validate_engine auto; echo $?)"
assert_eq "runtime rejects unsupported engine" "1" "$(carranca_runtime_validate_engine nerdctl; echo $?)"

unset CARRANCA_CONTAINER_RUNTIME
_CARRANCA_RESOLVED_RUNTIME=""
_CARRANCA_RESOLVED_ROOTLESS=""
assert_eq "runtime auto prefers podman" "podman" "$(carranca_runtime_cmd)"
assert_eq "runtime detects rootless podman" "0" "$(carranca_runtime_is_rootless podman; echo $?)"
assert_eq "runtime uses keep-id for rootless podman logger" "--userns keep-id" "$(carranca_runtime_logger_cap_flags)"

export CARRANCA_CONTAINER_RUNTIME="docker"
_CARRANCA_RESOLVED_RUNTIME=""
_CARRANCA_RESOLVED_ROOTLESS=""
assert_eq "runtime env override selects docker" "docker" "$(carranca_runtime_cmd)"
assert_eq "runtime availability succeeds for docker" "0" "$(carranca_runtime_is_available docker; echo $?)"
assert_eq "runtime engine setting returns env override" "docker" "$(carranca_runtime_engine_setting)"
assert_eq "runtime configured engine is empty without config" "" "$(carranca_runtime_configured_engine /nonexistent)"
assert_eq "runtime adds logger cap for docker" "--cap-add LINUX_IMMUTABLE" "$(carranca_runtime_logger_cap_flags)"
assert_eq "runtime uses explicit docker user flags" "--user 1000:1000" "$(carranca_runtime_agent_identity_flags 1000 1000)"

export PODMAN_ROOTLESS="false"
unset CARRANCA_CONTAINER_RUNTIME
_CARRANCA_RESOLVED_RUNTIME=""
_CARRANCA_RESOLVED_ROOTLESS=""
assert_eq "runtime detects rootful podman" "1" "$(carranca_runtime_is_rootless podman; echo $?)"
assert_eq "runtime adds logger cap for rootful podman" "--cap-add LINUX_IMMUTABLE" "$(carranca_runtime_logger_cap_flags)"
assert_eq "runtime uses explicit rootful podman user flags" "--user 1000:1000" "$(carranca_runtime_agent_identity_flags 1000 1000)"

export CARRANCA_CONTAINER_RUNTIME="docker"
_CARRANCA_RESOLVED_RUNTIME=""
_CARRANCA_RESOLVED_ROOTLESS=""

carranca_runtime_call images
carranca_runtime_build -q test-image
carranca_runtime_run --rm busybox true
carranca_runtime_exec test-container true
carranca_runtime_ps --format '{{.Names}}'
carranca_runtime_rm -f test-container
carranca_runtime_stop test-container
carranca_runtime_rmi test-image
carranca_runtime_volume ls
carranca_runtime_require

RUNTIME_CALLS="$(cat "$RUNTIME_LOG")"
assert_match "runtime helper dispatch logs docker calls" 'docker:images' "$RUNTIME_CALLS"
assert_match "runtime helper dispatch logs build call" 'docker:build -q test-image' "$RUNTIME_CALLS"
assert_match "runtime helper dispatch logs volume call" 'docker:volume ls' "$RUNTIME_CALLS"

export CARRANCA_CONTAINER_RUNTIME="podman"
export PODMAN_ROOTLESS="true"
_CARRANCA_RESOLVED_RUNTIME=""
_CARRANCA_RESOLVED_ROOTLESS=""
assert_eq "runtime uses keep-id for rootless podman agent identity" "--userns keep-id" "$(carranca_runtime_agent_identity_flags 1000 1000)"

rm -rf "$RUNTIME_FAKEBIN"
rm -f "$RUNTIME_LOG"

# Cleanup
rm -rf "$TMPDIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
