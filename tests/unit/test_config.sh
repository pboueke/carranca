#!/usr/bin/env bash
# Unit tests for cli/lib/config.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/cli/lib/common.sh"
source "$SCRIPT_DIR/cli/lib/config.sh"

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

echo "=== test_config.sh ==="

# Create a test config
TMPDIR="$(mktemp -d)"
CONFIG="$TMPDIR/.carranca.yml"
cat > "$CONFIG" <<'EOF'
agent:
  adapter: default
  command: bash -c "echo test"
runtime:
  network: true                 # allow network access
  extra_flags: ""
policy:
  docs_before_code: warn
  tests_before_impl: off
volumes:
  cache: true                   # persist agent home
watched_paths:
  - .env
  - secrets/
EOF

# Test inline comments are stripped
val="$(carranca_config_get runtime.network "$CONFIG")"
assert_eq "inline comment stripped from runtime.network" "true" "$val"

val="$(carranca_config_get volumes.cache "$CONFIG")"
assert_eq "inline comment stripped from volumes.cache" "true" "$val"

# Test nested key parsing
val="$(carranca_config_get agent.adapter "$CONFIG")"
assert_eq "nested key 'agent.adapter' reads correctly" "default" "$val"

val="$(carranca_config_get agent.command "$CONFIG")"
assert_eq "nested key 'agent.command' reads correctly" 'bash -c "echo test"' "$val"

val="$(carranca_config_get policy.docs_before_code "$CONFIG")"
assert_eq "nested key 'policy.docs_before_code' reads correctly" "warn" "$val"

val="$(carranca_config_get policy.tests_before_impl "$CONFIG")"
assert_eq "nested key 'policy.tests_before_impl' reads correctly" "off" "$val"

val="$(carranca_config_get runtime.network "$CONFIG")"
assert_eq "nested key 'runtime.network' reads correctly" "true" "$val"

# Test missing key returns empty
val="$(carranca_config_get nonexistent "$CONFIG")"
assert_eq "missing flat key returns empty" "" "$val"

val="$(carranca_config_get agent.nonexistent "$CONFIG")"
assert_eq "missing nested key returns empty" "" "$val"

# Test validation passes with valid config
cd "$TMPDIR"
# CONFIG is already at $TMPDIR/.carranca.yml
if (carranca_config_validate 2>/dev/null); then
  echo "  PASS: validation passes for valid config"
  PASS=$((PASS + 1))
else
  echo "  FAIL: validation should pass for valid config"
  FAIL=$((FAIL + 1))
fi

# --- Test carranca_config_get_list ---

cat > ".carranca.yml" <<'EOF'
agent:
  command: claude
volumes:
  cache: true
  extra:
    - ~/.ssh:/home/user/.ssh:ro
    - ~/docs:/reference:ro
    - /tmp/data:/data:rw
watched_paths:
  - .env
  - secrets/
EOF

# Test list parsing for volumes.extra
mapfile -t items < <(carranca_config_get_list volumes.extra)
assert_eq "volumes.extra list has 3 items" "3" "${#items[@]}"
# shellcheck disable=SC2088
assert_eq "volumes.extra[0]" "~/.ssh:/home/user/.ssh:ro" "${items[0]}"
# shellcheck disable=SC2088
assert_eq "volumes.extra[1]" "~/docs:/reference:ro" "${items[1]}"
assert_eq "volumes.extra[2]" "/tmp/data:/data:rw" "${items[2]}"

# Test list parsing for watched_paths (top-level list)
mapfile -t items < <(carranca_config_get_list watched_paths)
assert_eq "watched_paths list has 2 items" "2" "${#items[@]}"
assert_eq "watched_paths[0]" ".env" "${items[0]}"
assert_eq "watched_paths[1]" "secrets/" "${items[1]}"

# Test empty list returns nothing
mapfile -t items < <(carranca_config_get_list volumes.nonexistent 2>/dev/null || true)
assert_eq "missing list returns 0 items" "0" "${#items[@]}"

# Test scalar value with cache
val="$(carranca_config_get volumes.cache)"
assert_eq "volumes.cache reads correctly" "true" "$val"

# Test cache disabled
cat > ".carranca.yml" <<'EOF'
agent:
  command: claude
volumes:
  cache: false
EOF

val="$(carranca_config_get volumes.cache)"
assert_eq "volumes.cache=false reads correctly" "false" "$val"

# Test empty extra list (section present but no items)
cat > ".carranca.yml" <<'EOF'
agent:
  command: claude
volumes:
  cache: true
  extra:
policy:
  docs_before_code: warn
EOF

mapfile -t items < <(carranca_config_get_list volumes.extra 2>/dev/null || true)
assert_eq "empty extra list returns 0 items" "0" "${#items[@]}"

# Test quoted list items
cat > ".carranca.yml" <<'EOF'
agent:
  command: claude
volumes:
  extra:
    - "~/My Documents:/docs:ro"
    - '/path with spaces:/mount:rw'
EOF

mapfile -t items < <(carranca_config_get_list volumes.extra)
# shellcheck disable=SC2088
assert_eq "quoted extra[0] strips quotes" "~/My Documents:/docs:ro" "${items[0]}"
assert_eq "quoted extra[1] strips quotes" "/path with spaces:/mount:rw" "${items[1]}"

# Test volumes section absent entirely (defaults)
cat > ".carranca.yml" <<'EOF'
agent:
  command: claude
runtime:
  network: true
EOF

val="$(carranca_config_get volumes.cache)"
assert_eq "absent volumes.cache returns empty" "" "$val"
mapfile -t items < <(carranca_config_get_list volumes.extra 2>/dev/null || true)
assert_eq "absent volumes.extra returns 0 items" "0" "${#items[@]}"

# Test validation fails with missing agent.command
cat > ".carranca.yml" <<'EOF'
agent:
  adapter: default
network: true
EOF

if (carranca_config_validate 2>/dev/null); then
  echo "  FAIL: validation should fail when agent.command is missing"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: validation fails when agent.command is missing"
  PASS=$((PASS + 1))
fi

# Cleanup
rm -rf "$TMPDIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
