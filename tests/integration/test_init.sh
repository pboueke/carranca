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
assert_file_exists "init copies plan skill" ".carranca/skills/plan/SKILL.md"

# Verify state dir created
REPO_ID="$(source "$CARRANCA_HOME/cli/lib/common.sh" && source "$CARRANCA_HOME/cli/lib/identity.sh" && carranca_repo_id)"
assert_dir_exists "init creates state session dir" "$TMPSTATE/sessions/$REPO_ID"

echo ""

# Test 2: re-init without --force fails
if bash "$CARRANCA_HOME/cli/init.sh" 2>/dev/null; then
  echo "  FAIL: re-init without --force should fail"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: re-init without --force fails"
  PASS=$((PASS + 1))
fi

# Test 3: re-init with --force succeeds
bash "$CARRANCA_HOME/cli/init.sh" --force
echo "  PASS: re-init with --force succeeds"
PASS=$((PASS + 1))

assert_file_exists "config still exists after --force" ".carranca.yml"

# Cleanup
rm -rf "$TMPDIR" "$TMPSTATE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
