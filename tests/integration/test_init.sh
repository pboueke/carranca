#!/usr/bin/env bash
# Integration tests for carranca init
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export CARRANCA_HOME="$SCRIPT_DIR"

PASS=0
FAIL=0

assert_file_exists() {
  local desc="$1" path="$2"
  if [ -f "$path" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (file not found: $path)"
    FAIL=$((FAIL + 1))
  fi
}

assert_dir_exists() {
  local desc="$1" path="$2"
  if [ -d "$path" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (dir not found: $path)"
    FAIL=$((FAIL + 1))
  fi
}

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

echo "=== test_init.sh ==="

# Use a temp dir for state
TMPSTATE="$(mktemp -d)"
export CARRANCA_STATE="$TMPSTATE"

# Test 1: basic init
TMPDIR="$(mktemp -d)"
cd "$TMPDIR"
git init --quiet

bash "$CARRANCA_HOME/cli/init.sh"

assert_file_exists "init creates .carranca.yml" ".carranca.yml"
assert_dir_exists "init creates .carranca/skills/" ".carranca/skills"
assert_dir_exists "init creates carranca-managed skill dir" ".carranca/skills/carranca"
assert_dir_exists "init creates user skill dir" ".carranca/skills/user"
assert_file_exists "init copies plan skill" ".carranca/skills/carranca/plan/SKILL.md"
assert_file_exists "init copies confiskill" ".carranca/skills/carranca/confiskill/SKILL.md"
assert_contains "bare init defaults to codex agent name" "name: codex" "$(cat .carranca.yml)"
assert_contains "bare init defaults to codex adapter" "adapter: codex" "$(cat .carranca.yml)"
assert_contains "bare init defaults to codex command" "command: codex" "$(cat .carranca.yml)"

# Verify state dir created
REPO_ID="$(source "$CARRANCA_HOME/cli/lib/common.sh" && source "$CARRANCA_HOME/cli/lib/identity.sh" && carranca_repo_id)"
assert_dir_exists "init creates state session dir" "$TMPSTATE/sessions/$REPO_ID"

echo ""

# Test 2: re-init without --force fails and suggests config
if bash "$CARRANCA_HOME/cli/init.sh" 2>/dev/null; then
  echo "  FAIL: re-init without --force should fail"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: re-init without --force fails"
  PASS=$((PASS + 1))
fi

# Test 3: init --agent claude rewrites scaffold when confirmed
FORCE_OUTPUT="$(printf 'y\n' | bash "$CARRANCA_HOME/cli/init.sh" --force --agent claude 2>&1)" || true
assert_contains "force init asks for confirmation" "Overwrite existing carranca initialization?" "$FORCE_OUTPUT"
assert_contains "force init configures selected agent" "Configured for claude agent" "$FORCE_OUTPUT"
assert_contains "force init writes selected agent name" "name: claude" "$(cat .carranca.yml)"
assert_contains "force init writes selected agent adapter" "adapter: claude" "$(cat .carranca.yml)"
assert_contains "force init writes selected agent command" "command: claude" "$(cat .carranca.yml)"

assert_file_exists "config still exists after --force" ".carranca.yml"

# Cleanup
rm -rf "$TMPDIR" "$TMPSTATE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
