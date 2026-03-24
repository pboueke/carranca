#!/usr/bin/env bash
# Unit tests for shared strace parser (runtime/lib/strace-parser.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_strace_parser.sh"

# Setup: mock environment for the parser
TMPDIR="$(mktemp -d)"
SESSION_ID="test1234"
LOG_FILE="$TMPDIR/test.jsonl"

timestamp() {
  date -u +%Y-%m-%dT%H:%M:%S.%3NZ
}

write_log() {
  printf '%s\n' "$1" >> "$LOG_FILE"
}

# Source the parser
STRACE_EVENT_SOURCE="strace"
STRACE_WRITE_FIFO=""
source "$SCRIPT_DIR/runtime/lib/strace-parser.sh"

# --- Test: basic execve parsing ---
echo "--- basic execve ---"
> "$LOG_FILE"
strace_line_to_event 'execve("/usr/bin/ls", ["ls", "-la"], 0x7ffe8b6c1e60 /* 50 vars */) = 0'
LINE="$(cat "$LOG_FILE")"
assert_contains "type is execve_event" '"type":"execve_event"' "$LINE"
assert_contains "source is strace" '"source":"strace"' "$LINE"
assert_contains "binary is /usr/bin/ls" '"binary":"/usr/bin/ls"' "$LINE"
assert_contains "argv contains ls" '[\"ls\", \"-la\"]' "$LINE"

# --- Test: pid extraction ---
echo "--- pid extraction ---"
> "$LOG_FILE"
strace_line_to_event '[pid 42] execve("/usr/bin/cat", ["cat", "file.txt"], 0x7ffe8b6c1e60 /* 50 vars */) = 0'
LINE="$(cat "$LOG_FILE")"
assert_contains "pid extracted" '"pid":42' "$LINE"
assert_contains "binary is /usr/bin/cat" '"binary":"/usr/bin/cat"' "$LINE"

# --- Test: non-execve lines skipped ---
echo "--- non-execve lines ---"
> "$LOG_FILE"
strace_line_to_event '--- SIGCHLD {si_signo=SIGCHLD} ---'
strace_line_to_event '+++ exited with 0 +++'
strace_line_to_event 'write(1, "hello", 5) = 5'
COUNT="$(wc -l < "$LOG_FILE")"
assert_eq "non-execve lines produce no output" "0" "$COUNT"

# --- Test: custom source ---
echo "--- custom source ---"
> "$LOG_FILE"
STRACE_EVENT_SOURCE="observer"
strace_line_to_event 'execve("/bin/echo", ["echo", "hi"], 0) = 0'
LINE="$(cat "$LOG_FILE")"
assert_contains "custom source is observer" '"source":"observer"' "$LINE"

# --- Test: empty binary skipped ---
echo "--- empty binary skipped ---"
STRACE_EVENT_SOURCE="strace"
> "$LOG_FILE"
strace_line_to_event 'execve("", [], 0) = -1 ENOENT'
COUNT="$(wc -l < "$LOG_FILE")"
assert_eq "empty binary produces no output" "0" "$COUNT"

# Cleanup
rm -rf "$TMPDIR"

echo ""
print_results
