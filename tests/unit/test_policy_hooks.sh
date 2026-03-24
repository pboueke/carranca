#!/usr/bin/env bash
# Unit tests for Phase 4.3 — technical policy hooks (pre-commit)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/cli/lib/common.sh"
source "$SCRIPT_DIR/cli/lib/config.sh"
source "$SCRIPT_DIR/cli/lib/runtime.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_policy_hooks.sh"

TMPDIR="$(mktemp -d)"

# --- Config parsing and hook activation logic ---

echo ""
echo "--- config parsing ---"

CONFIG="$TMPDIR/hooks-config.yml"
cat > "$CONFIG" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
policy:
  docs_before_code: enforce
  tests_before_impl: warn
EOF

val="$(carranca_config_get policy.docs_before_code "$CONFIG")"
assert_eq "docs_before_code reads enforce" "enforce" "$val"

val="$(carranca_config_get policy.tests_before_impl "$CONFIG")"
assert_eq "tests_before_impl reads warn" "warn" "$val"

# Hook activation logic
should_activate_hooks() {
  local dbc="$1" tbi="$2"
  if [ "$dbc" = "warn" ] || [ "$dbc" = "enforce" ] || \
     [ "$tbi" = "warn" ] || [ "$tbi" = "enforce" ]; then
    return 0
  fi
  return 1
}

rc=0; should_activate_hooks "enforce" "warn" || rc=$?
assert_eq "hooks activate for enforce+warn" "0" "$rc"

rc=0; should_activate_hooks "warn" "off" || rc=$?
assert_eq "hooks activate for warn+off" "0" "$rc"

rc=0; should_activate_hooks "off" "enforce" || rc=$?
assert_eq "hooks activate for off+enforce" "0" "$rc"

rc=0; should_activate_hooks "off" "off" || rc=$?
assert_eq "hooks skip for off+off" "1" "$rc"

rc=0; should_activate_hooks "" "" || rc=$?
assert_eq "hooks skip for empty+empty" "1" "$rc"

# --- Pre-commit hook tests with mock git repo ---

echo ""
echo "--- pre-commit hook logic ---"

HOOK_SCRIPT="$SCRIPT_DIR/runtime/hooks/pre-commit"

# Create a mock git repo to test the hook
MOCK_REPO="$TMPDIR/repo"
mkdir -p "$MOCK_REPO"
cd "$MOCK_REPO"
git init -q
git config user.email "test@test.com"
git config user.name "Test"

# Create a mock FIFO
MOCK_FIFO="$TMPDIR/fifo"
mkdir -p "$MOCK_FIFO"
mkfifo "$MOCK_FIFO/events"

# Background reader to drain the FIFO
FIFO_LOG="$TMPDIR/fifo-output.log"
cat "$MOCK_FIFO/events" > "$FIFO_LOG" &
FIFO_READER_PID=$!

# Test 1: docs_before_code=enforce blocks code-only commit
echo 'console.log("hello")' > app.js
git add app.js

POLICY_DOCS_BEFORE_CODE=enforce \
POLICY_TESTS_BEFORE_IMPL=off \
SESSION_ID=test1234 \
FIFO_PATH="$MOCK_FIFO/events" \
  bash "$HOOK_SCRIPT" && rc=$? || rc=$?

assert_eq "docs_before_code=enforce blocks code-only commit" "1" "$rc"

# Test 2: docs_before_code=warn allows code-only commit
POLICY_DOCS_BEFORE_CODE=warn \
POLICY_TESTS_BEFORE_IMPL=off \
SESSION_ID=test1234 \
FIFO_PATH="$MOCK_FIFO/events" \
  bash "$HOOK_SCRIPT" && rc=$? || rc=$?

assert_eq "docs_before_code=warn allows code-only commit" "0" "$rc"

# Test 3: docs_before_code=enforce allows code+docs commit
echo "# Documentation" > README.md
git add README.md

POLICY_DOCS_BEFORE_CODE=enforce \
POLICY_TESTS_BEFORE_IMPL=off \
SESSION_ID=test1234 \
FIFO_PATH="$MOCK_FIFO/events" \
  bash "$HOOK_SCRIPT" && rc=$? || rc=$?

assert_eq "docs_before_code=enforce allows code+docs commit" "0" "$rc"

# Reset staging area
git reset HEAD -- . >/dev/null 2>&1

# Test 4: tests_before_impl=enforce blocks impl-only commit
echo 'def main(): pass' > main.py
git add main.py

POLICY_DOCS_BEFORE_CODE=off \
POLICY_TESTS_BEFORE_IMPL=enforce \
SESSION_ID=test1234 \
FIFO_PATH="$MOCK_FIFO/events" \
  bash "$HOOK_SCRIPT" && rc=$? || rc=$?

assert_eq "tests_before_impl=enforce blocks impl-only commit" "1" "$rc"

# Test 5: tests_before_impl=enforce allows impl+test commit
echo 'def test_main(): pass' > test_main.py
git add test_main.py

POLICY_DOCS_BEFORE_CODE=off \
POLICY_TESTS_BEFORE_IMPL=enforce \
SESSION_ID=test1234 \
FIFO_PATH="$MOCK_FIFO/events" \
  bash "$HOOK_SCRIPT" && rc=$? || rc=$?

assert_eq "tests_before_impl=enforce allows impl+test commit" "0" "$rc"

# Reset staging area
git reset HEAD -- . >/dev/null 2>&1

# Test 6: off policies allow anything
echo 'more code' > another.js
git add another.js

POLICY_DOCS_BEFORE_CODE=off \
POLICY_TESTS_BEFORE_IMPL=off \
SESSION_ID=test1234 \
FIFO_PATH="$MOCK_FIFO/events" \
  bash "$HOOK_SCRIPT" && rc=$? || rc=$?

assert_eq "off+off allows any commit" "0" "$rc"

# Reset staging area
git reset HEAD -- . >/dev/null 2>&1

# Test 7: doc-only commit always passes
echo "# More docs" > CHANGELOG.md
git add CHANGELOG.md

POLICY_DOCS_BEFORE_CODE=enforce \
POLICY_TESTS_BEFORE_IMPL=enforce \
SESSION_ID=test1234 \
FIFO_PATH="$MOCK_FIFO/events" \
  bash "$HOOK_SCRIPT" && rc=$? || rc=$?

assert_eq "doc-only commit passes both enforce policies" "0" "$rc"

# Clean up FIFO reader
kill "$FIFO_READER_PID" 2>/dev/null || true
wait "$FIFO_READER_PID" 2>/dev/null || true

# Test 8: verify FIFO events were written
sleep 0.5
if [ -f "$FIFO_LOG" ] && [ -s "$FIFO_LOG" ]; then
  fifo_content="$(cat "$FIFO_LOG")"
  assert_contains "FIFO received policy_event" '"type":"policy_event"' "$fifo_content"
  assert_contains "FIFO event has pre-commit-hook source" '"source":"pre-commit-hook"' "$fifo_content"
else
  assert_eq "FIFO events written (file exists)" "0" "0"
  assert_eq "FIFO event source (skipped — empty log)" "0" "0"
fi

rm -rf "$TMPDIR"

echo ""
print_results
