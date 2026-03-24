#!/usr/bin/env bash
# Unit tests for runtime/config-runner.sh
# Tests all driver branches and error conditions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_config_runner.sh"

TMPDIR="$(mktemp -d)"
PROMPT_FILE="$TMPDIR/prompt.txt"
OUTPUT_FILE="$TMPDIR/output.txt"
AGENT_BIN="$TMPDIR/fake-agent"

# Create a fake agent that records how it was invoked
cat > "$AGENT_BIN" <<'AGENT'
#!/usr/bin/env bash
# Record invocation: args on line 1, stdin on line 2
printf 'ARGS:%s\n' "$*"
if [ ! -t 0 ]; then
  STDIN_DATA="$(cat)"
  printf 'STDIN:%s\n' "$STDIN_DATA"
fi
AGENT
chmod +x "$AGENT_BIN"

# --- stdin driver: prompt piped to agent stdin ---

echo "Configure the repo for Node.js" > "$PROMPT_FILE"

test_start
CARRANCA_CONFIG_PROMPT_FILE="$PROMPT_FILE" \
CARRANCA_AGENT_COMMAND="$AGENT_BIN" \
CARRANCA_AGENT_DRIVER="stdin" \
  bash "$SCRIPT_DIR/runtime/config-runner.sh" > "$OUTPUT_FILE" 2>&1

assert_contains "stdin driver pipes prompt to stdin" "STDIN:Configure the repo for Node.js" "$(cat "$OUTPUT_FILE")"
assert_not_contains "stdin driver does not pass prompt as arg" "ARGS:Configure" "$(cat "$OUTPUT_FILE")"

# --- claude driver: prompt passed as argument ---

test_start
CARRANCA_CONFIG_PROMPT_FILE="$PROMPT_FILE" \
CARRANCA_AGENT_COMMAND="$AGENT_BIN" \
CARRANCA_AGENT_DRIVER="claude" \
  bash "$SCRIPT_DIR/runtime/config-runner.sh" > "$OUTPUT_FILE" 2>&1

assert_contains "claude driver passes prompt as arg" "ARGS:" "$(cat "$OUTPUT_FILE")"

# --- codex driver: prompt passed as argument ---

test_start
CARRANCA_CONFIG_PROMPT_FILE="$PROMPT_FILE" \
CARRANCA_AGENT_COMMAND="$AGENT_BIN" \
CARRANCA_AGENT_DRIVER="codex" \
  bash "$SCRIPT_DIR/runtime/config-runner.sh" > "$OUTPUT_FILE" 2>&1

assert_contains "codex driver passes prompt as arg" "ARGS:" "$(cat "$OUTPUT_FILE")"

# --- opencode driver: prompt passed as argument ---

test_start
CARRANCA_CONFIG_PROMPT_FILE="$PROMPT_FILE" \
CARRANCA_AGENT_COMMAND="$AGENT_BIN" \
CARRANCA_AGENT_DRIVER="opencode" \
  bash "$SCRIPT_DIR/runtime/config-runner.sh" > "$OUTPUT_FILE" 2>&1

assert_contains "opencode driver passes prompt as arg" "ARGS:" "$(cat "$OUTPUT_FILE")"

# --- unsupported driver: exit 1 + error message ---

test_start
rc=0
ERR_OUTPUT="$(CARRANCA_CONFIG_PROMPT_FILE="$PROMPT_FILE" \
CARRANCA_AGENT_COMMAND="$AGENT_BIN" \
CARRANCA_AGENT_DRIVER="unknown-driver" \
  bash "$SCRIPT_DIR/runtime/config-runner.sh" 2>&1)" || rc=$?

assert_eq "unsupported driver exits non-zero" "1" "$rc"
assert_contains "unsupported driver prints error" "Unsupported config agent driver: unknown-driver" "$ERR_OUTPUT"

# --- missing prompt file: exit non-zero ---

test_start
rc=0
CARRANCA_CONFIG_PROMPT_FILE="$TMPDIR/nonexistent.txt" \
CARRANCA_AGENT_COMMAND="$AGENT_BIN" \
CARRANCA_AGENT_DRIVER="stdin" \
  bash "$SCRIPT_DIR/runtime/config-runner.sh" > /dev/null 2>&1 || rc=$?

assert_eq "missing prompt file exits non-zero" "1" "$rc"

# --- prompt with special characters ---

printf 'Install "curl" & set PATH=$HOME/bin\n' > "$PROMPT_FILE"

test_start
CARRANCA_CONFIG_PROMPT_FILE="$PROMPT_FILE" \
CARRANCA_AGENT_COMMAND="$AGENT_BIN" \
CARRANCA_AGENT_DRIVER="stdin" \
  bash "$SCRIPT_DIR/runtime/config-runner.sh" > "$OUTPUT_FILE" 2>&1

assert_contains "stdin driver preserves special chars" 'STDIN:Install "curl"' "$(cat "$OUTPUT_FILE")"

# --- empty prompt ---

> "$PROMPT_FILE"

test_start
rc=0
CARRANCA_CONFIG_PROMPT_FILE="$PROMPT_FILE" \
CARRANCA_AGENT_COMMAND="$AGENT_BIN" \
CARRANCA_AGENT_DRIVER="stdin" \
  bash "$SCRIPT_DIR/runtime/config-runner.sh" > "$OUTPUT_FILE" 2>&1 || rc=$?

assert_eq "empty prompt does not crash" "0" "$rc"

# Cleanup
rm -rf "$TMPDIR"

echo ""
print_results
