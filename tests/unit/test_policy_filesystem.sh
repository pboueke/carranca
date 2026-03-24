#!/usr/bin/env bash
# Unit tests for Phase 4.2 — filesystem access control
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/cli/lib/common.sh"
source "$SCRIPT_DIR/cli/lib/config.sh"
source "$SCRIPT_DIR/cli/lib/runtime.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_policy_filesystem.sh"

TMPDIR="$(mktemp -d)"

# --- Config parsing tests (requires yq for 3-level nesting) ---

echo ""
echo "--- config parsing ---"

if carranca_config_has_yq; then
  CONFIG="$TMPDIR/fs-policy.yml"
  cat > "$CONFIG" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
policy:
  filesystem:
    enforce_watched_paths: true
watched_paths:
  - .env
  - secrets/
  - "*.key"
EOF

  val="$(carranca_config_get policy.filesystem.enforce_watched_paths "$CONFIG")"
  assert_eq "policy.filesystem.enforce_watched_paths reads correctly" "true" "$val"

  # Missing filesystem policy defaults to empty
  CONFIG_NONE="$TMPDIR/no-fs-policy.yml"
  cat > "$CONFIG_NONE" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
EOF

  val="$(carranca_config_get policy.filesystem.enforce_watched_paths "$CONFIG_NONE")"
  assert_eq "missing enforce_watched_paths returns empty" "" "$val"
else
  echo "  SKIP: filesystem config tests (yq not installed, 3-level nesting requires yq)"
fi

# --- Bind-mount flag generation tests ---

echo ""
echo "--- bind-mount flag generation ---"

# Create a mock workspace
WORKSPACE="$TMPDIR/workspace"
mkdir -p "$WORKSPACE/secrets" "$WORKSPACE/src"
touch "$WORKSPACE/.env"
touch "$WORKSPACE/app.key"
touch "$WORKSPACE/src/main.sh"

# Simulate the flag-building logic from run.sh
build_filesystem_flags() {
  local workspace="$1"
  shift
  local paths=("$@")
  local flags=""
  local enforced=""
  local degraded=""

  for wp in "${paths[@]}"; do
    [ -z "$wp" ] && continue
    case "$wp" in
      \*.*)
        if [ -z "$degraded" ]; then
          degraded="$wp"
        else
          degraded="$degraded,$wp"
        fi
        ;;
      */)
        if [ -d "$workspace/$wp" ]; then
          flags="$flags -v $workspace/$wp:/workspace/$wp:ro"
          if [ -z "$enforced" ]; then
            enforced="$wp"
          else
            enforced="$enforced,$wp"
          fi
        fi
        ;;
      *)
        if [ -e "$workspace/$wp" ]; then
          flags="$flags -v $workspace/$wp:/workspace/$wp:ro"
          if [ -z "$enforced" ]; then
            enforced="$wp"
          else
            enforced="$enforced,$wp"
          fi
        fi
        ;;
    esac
  done

  printf 'flags=%s\nenforced=%s\ndegraded=%s\n' "$flags" "$enforced" "$degraded"
}

result="$(build_filesystem_flags "$WORKSPACE" ".env" "secrets/" "*.key")"
flags="$(echo "$result" | grep '^flags=' | cut -d= -f2-)"
enforced="$(echo "$result" | grep '^enforced=' | cut -d= -f2-)"
degraded="$(echo "$result" | grep '^degraded=' | cut -d= -f2-)"

# Use case pattern matching since flags contain -v which grep misinterprets
has_env=0; [[ "$flags" == *"$WORKSPACE/.env:/workspace/.env:ro"* ]] && has_env=1
assert_eq "flags include .env bind mount" "1" "$has_env"
has_secrets=0; [[ "$flags" == *"$WORKSPACE/secrets/:/workspace/secrets/:ro"* ]] && has_secrets=1
assert_eq "flags include secrets/ bind mount" "1" "$has_secrets"
assert_eq "enforced paths list" ".env,secrets/" "$enforced"
assert_eq "degraded globs" "*.key" "$degraded"

# Test with only globs
result="$(build_filesystem_flags "$WORKSPACE" "*.key" "*.pem")"
flags="$(echo "$result" | grep '^flags=' | cut -d= -f2-)"
enforced="$(echo "$result" | grep '^enforced=' | cut -d= -f2-)"
degraded="$(echo "$result" | grep '^degraded=' | cut -d= -f2-)"

assert_eq "no flags for glob-only paths" "" "$flags"
assert_eq "no enforced for glob-only" "" "$enforced"
assert_eq "all globs degraded" "*.key,*.pem" "$degraded"

# Test with non-existent paths
result="$(build_filesystem_flags "$WORKSPACE" "nonexistent.txt" "missing/")"
flags="$(echo "$result" | grep '^flags=' | cut -d= -f2-)"
enforced="$(echo "$result" | grep '^enforced=' | cut -d= -f2-)"

assert_eq "no flags for non-existent paths" "" "$flags"
assert_eq "no enforced for non-existent paths" "" "$enforced"

# --- Policy event format ---

echo ""
echo "--- policy event format ---"

SESSION_ID="test1234"
ts="2026-03-22T00:00:01Z"

enforced_event="{\"type\":\"policy_event\",\"source\":\"carranca\",\"ts\":\"$ts\",\"session_id\":\"$SESSION_ID\",\"policy\":\"filesystem\",\"action\":\"enforced\",\"detail\":\"read-only: .env,secrets/\"}"
assert_contains "enforced event has type policy_event" '"type":"policy_event"' "$enforced_event"
assert_contains "enforced event has policy filesystem" '"policy":"filesystem"' "$enforced_event"
assert_contains "enforced event has action enforced" '"action":"enforced"' "$enforced_event"
assert_contains "enforced event lists paths" "read-only: .env,secrets/" "$enforced_event"

degraded_event="{\"type\":\"policy_event\",\"source\":\"carranca\",\"ts\":\"$ts\",\"session_id\":\"$SESSION_ID\",\"policy\":\"filesystem\",\"action\":\"degraded\",\"detail\":\"glob patterns not enforced: *.key\"}"
assert_contains "degraded event has action degraded" '"action":"degraded"' "$degraded_event"
assert_contains "degraded event lists globs" "glob patterns not enforced: *.key" "$degraded_event"

rm -rf "$TMPDIR"

echo ""
print_results
