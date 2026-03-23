#!/usr/bin/env bash
# Unit tests for cli/lib/config.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/cli/lib/common.sh"
source "$SCRIPT_DIR/cli/lib/config.sh"
source "$SCRIPT_DIR/cli/lib/runtime.sh"

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

TMPDIR="$(mktemp -d)"
CONFIG="$TMPDIR/.carranca.yml"
cat > "$CONFIG" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex --model gpt-5.4
  - name: shell
    adapter: default
    command: bash -c "echo test"
runtime:
  engine: auto
  network: true                 # allow network access
  extra_flags: ""
  cap_add:
    - SYS_PTRACE
    - NET_ADMIN
policy:
  docs_before_code: warn
  tests_before_impl: off
volumes:
  cache: true                   # persist agent home
  extra:
    - ~/.ssh:/home/carranca/.ssh:ro
    - ~/docs:/reference:ro
watched_paths:
  - .env
  - secrets/
EOF

val="$(carranca_config_get runtime.network "$CONFIG")"
assert_eq "inline comment stripped from runtime.network" "true" "$val"

val="$(carranca_config_strip_value '"quoted-value"')"
assert_eq "strip value removes surrounding quotes" "quoted-value" "$val"

val="$(carranca_config_get volumes.cache "$CONFIG")"
assert_eq "inline comment stripped from volumes.cache" "true" "$val"

val="$(carranca_config_get policy.docs_before_code "$CONFIG")"
assert_eq "nested key 'policy.docs_before_code' reads correctly" "warn" "$val"

val="$(carranca_config_get policy.tests_before_impl "$CONFIG")"
assert_eq "nested key 'policy.tests_before_impl' reads correctly" "off" "$val"

val="$(carranca_config_get runtime.network "$CONFIG")"
assert_eq "nested key 'runtime.network' reads correctly" "true" "$val"

val="$(carranca_config_get runtime.engine "$CONFIG")"
assert_eq "nested key 'runtime.engine' reads correctly" "auto" "$val"

val="$(carranca_config_get nonexistent "$CONFIG")"
assert_eq "missing flat key returns empty" "" "$val"

val="$(carranca_config_get runtime.nonexistent "$CONFIG")"
assert_eq "missing nested key returns empty" "" "$val"

mapfile -t names < <(carranca_config_agent_names "$CONFIG")
assert_eq "agent names list has 2 items" "2" "${#names[@]}"
assert_eq "agent names[0]" "codex" "${names[0]}"
assert_eq "agent names[1]" "shell" "${names[1]}"

count="$(carranca_config_agent_count "$CONFIG")"
assert_eq "agent count reads correctly" "2" "$count"

index="$(carranca_config_agent_index shell "$CONFIG")"
assert_eq "agent index resolves by name" "1" "$index"

val="$(carranca_config_agent_field_by_index 0 name "$CONFIG")"
assert_eq "agent field by index reads name" "codex" "$val"

val="$(carranca_config_agent_field shell command "$CONFIG")"
assert_eq "agent field by name reads command" 'bash -c "echo test"' "$val"

val="$(carranca_config_default_agent_name "$CONFIG")"
assert_eq "default agent is first entry" "codex" "$val"

val="$(carranca_config_resolve_agent_name "" "$CONFIG")"
assert_eq "empty agent selection resolves to default" "codex" "$val"

val="$(carranca_config_resolve_agent_name shell "$CONFIG")"
assert_eq "named agent selection resolves directly" "shell" "$val"

val="$(carranca_config_agent_driver_for codex "$CONFIG")"
assert_eq "explicit codex adapter resolves to codex driver" "codex" "$val"

val="$(carranca_config_agent_driver_for shell "$CONFIG")"
assert_eq "default adapter resolves to stdin for custom command" "stdin" "$val"

mapfile -t items < <(carranca_config_get_list volumes.extra "$CONFIG")
assert_eq "volumes.extra list has 2 items" "2" "${#items[@]}"
# shellcheck disable=SC2088
assert_eq "volumes.extra[0]" "~/.ssh:/home/carranca/.ssh:ro" "${items[0]}"
# shellcheck disable=SC2088
assert_eq "volumes.extra[1]" "~/docs:/reference:ro" "${items[1]}"

mapfile -t items < <(carranca_config_get_list watched_paths "$CONFIG")
assert_eq "watched_paths list has 2 items" "2" "${#items[@]}"
assert_eq "watched_paths[0]" ".env" "${items[0]}"
assert_eq "watched_paths[1]" "secrets/" "${items[1]}"

mapfile -t items < <(carranca_config_get_list runtime.cap_add "$CONFIG")
assert_eq "runtime.cap_add list has 2 items" "2" "${#items[@]}"
assert_eq "runtime.cap_add[0]" "SYS_PTRACE" "${items[0]}"
assert_eq "runtime.cap_add[1]" "NET_ADMIN" "${items[1]}"

cat > "$TMPDIR/no-caps.yml" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
EOF
mapfile -t items < <(carranca_config_get_list runtime.cap_add "$TMPDIR/no-caps.yml" 2>/dev/null || true)
assert_eq "missing runtime.cap_add returns empty list" "0" "${#items[@]}"

cd "$TMPDIR"
if (carranca_config_validate 2>/dev/null); then
  echo "  PASS: validation passes for valid config"
  PASS=$((PASS + 1))
else
  echo "  FAIL: validation should pass for valid config"
  FAIL=$((FAIL + 1))
fi

cat > ".carranca.yml" <<'EOF'
agents:
  - name: codex
    adapter: codex
runtime:
  engine: auto
  network: true
EOF

if (carranca_config_validate 2>/dev/null); then
  echo "  FAIL: validation should fail when agents[name].command is missing"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: validation fails when agents[name].command is missing"
  PASS=$((PASS + 1))
fi

cat > ".carranca.yml" <<'EOF'
runtime:
  engine: auto
  network: true
EOF

if (carranca_config_validate 2>/dev/null); then
  echo "  FAIL: validation should fail when agents is missing"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: validation fails when agents is missing"
  PASS=$((PASS + 1))
fi

cat > ".carranca.yml" <<'EOF'
agents:
  - name: codex
    adapter: invalid
    command: codex
runtime:
  engine: auto
EOF

if (carranca_config_validate 2>/dev/null); then
  echo "  FAIL: validation should fail for unsupported agent adapter"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: validation fails for unsupported agent adapter"
  PASS=$((PASS + 1))
fi

cat > ".carranca.yml" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
  - name: codex
    adapter: codex
    command: codex --fast
runtime:
  engine: auto
EOF

if (carranca_config_validate 2>/dev/null); then
  echo "  FAIL: validation should fail for duplicate agent names"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: validation fails for duplicate agent names"
  PASS=$((PASS + 1))
fi

if carranca_config_resolve_agent_name missing ".carranca.yml" >/dev/null 2>&1; then
  echo "  FAIL: resolving an unknown agent should fail"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: resolving an unknown agent fails"
  PASS=$((PASS + 1))
fi

cat > ".carranca.yml" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
runtime:
  engine: nerdctl
EOF

if (carranca_config_validate 2>/dev/null); then
  echo "  FAIL: validation should fail for unsupported runtime.engine"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: validation fails for unsupported runtime.engine"
  PASS=$((PASS + 1))
fi

# --- Global config fallback tests ---

GLOBAL_CONFIG="$TMPDIR/global-config.yml"
cat > "$GLOBAL_CONFIG" <<'EOF'
runtime:
  engine: podman
  network: false
  cap_add:
    - SYS_PTRACE
volumes:
  cache: false
  extra:
    - ~/global-mount:/data:ro
EOF

# Project config without runtime settings
PROJECT_CONFIG="$TMPDIR/project-no-runtime.yml"
cat > "$PROJECT_CONFIG" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
EOF

# Override global config path for testing
CARRANCA_GLOBAL_CONFIG="$GLOBAL_CONFIG"
CARRANCA_CONFIG_FILE="$PROJECT_CONFIG"

val="$(carranca_config_get_with_global runtime.network)"
assert_eq "global fallback: runtime.network from global" "false" "$val"

val="$(carranca_config_get_with_global runtime.engine)"
assert_eq "global fallback: runtime.engine from global" "podman" "$val"

val="$(carranca_config_get_with_global volumes.cache)"
assert_eq "global fallback: volumes.cache from global" "false" "$val"

mapfile -t items < <(carranca_config_get_list_with_global runtime.cap_add)
assert_eq "global fallback: cap_add list from global" "1" "${#items[@]}"
assert_eq "global fallback: cap_add[0] from global" "SYS_PTRACE" "${items[0]}"

mapfile -t items < <(carranca_config_get_list_with_global volumes.extra)
assert_eq "global fallback: volumes.extra from global" "1" "${#items[@]}"

# Project config overrides global
PROJECT_WITH_RUNTIME="$TMPDIR/project-with-runtime.yml"
cat > "$PROJECT_WITH_RUNTIME" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
runtime:
  network: true
  cap_add:
    - NET_ADMIN
volumes:
  cache: true
EOF

CARRANCA_CONFIG_FILE="$PROJECT_WITH_RUNTIME"

val="$(carranca_config_get_with_global runtime.network)"
assert_eq "project overrides global: runtime.network" "true" "$val"

mapfile -t items < <(carranca_config_get_list_with_global runtime.cap_add)
assert_eq "project overrides global: cap_add uses project list" "1" "${#items[@]}"
assert_eq "project overrides global: cap_add[0]" "NET_ADMIN" "${items[0]}"

val="$(carranca_config_get_with_global volumes.cache)"
assert_eq "project overrides global: volumes.cache" "true" "$val"

# Non-runtime keys don't fall back to global
val="$(carranca_config_get_with_global policy.docs_before_code)"
assert_eq "non-runtime key returns empty (no global fallback)" "" "$val"

# Restore defaults for any subsequent tests
CARRANCA_CONFIG_FILE=".carranca.yml"
CARRANCA_GLOBAL_CONFIG="${CARRANCA_CONFIG_DIR:-$HOME/.config/carranca}/config.yml"

# --- Parser compatibility check tests ---

COMPAT_CONFIG="$TMPDIR/compat-test.yml"
cat > "$COMPAT_CONFIG" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
runtime:
  network: true
EOF

# Save and force awk parser
_save_has_yq="$_CARRANCA_HAS_YQ"
_CARRANCA_HAS_YQ="no"

# Simple config should produce no warnings
compat_output="$(carranca_config_check_parser_compatibility "$COMPAT_CONFIG" 2>&1)"
assert_eq "simple config produces no parser warnings" "" "$compat_output"

# Config with multi-line strings should warn
cat > "$COMPAT_CONFIG" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
runtime:
  extra_flags: |
    --gpus all
    --shm-size 2g
EOF

compat_output="$(carranca_config_check_parser_compatibility "$COMPAT_CONFIG" 2>&1)"
if echo "$compat_output" | grep -Fq "multi-line strings"; then
  echo "  PASS: multi-line string warning emitted"
  PASS=$((PASS + 1))
else
  echo "  FAIL: multi-line string warning not emitted"
  FAIL=$((FAIL + 1))
fi

# Restore
_CARRANCA_HAS_YQ="$_save_has_yq"

# --- Parser parity test (only runs when yq is available) ---

if carranca_config_has_yq; then
  PARITY_CONFIG="$TMPDIR/parity.yml"
  cat > "$PARITY_CONFIG" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex --model gpt-5.4
runtime:
  engine: auto
  network: true
  cap_add:
    - SYS_PTRACE
    - NET_ADMIN
volumes:
  cache: true
  extra:
    - ~/.ssh:/home/carranca/.ssh:ro
watched_paths:
  - .env
  - secrets/
EOF

  # Test scalar values
  _CARRANCA_HAS_YQ="yes"
  yq_val="$(_carranca_config_get_yq runtime.network "$PARITY_CONFIG")"
  _CARRANCA_HAS_YQ="no"
  awk_val="$(carranca_config_get runtime.network "$PARITY_CONFIG")"
  assert_eq "parser parity: runtime.network" "$yq_val" "$awk_val"

  _CARRANCA_HAS_YQ="yes"
  yq_val="$(_carranca_config_get_yq runtime.engine "$PARITY_CONFIG")"
  _CARRANCA_HAS_YQ="no"
  awk_val="$(carranca_config_get runtime.engine "$PARITY_CONFIG")"
  assert_eq "parser parity: runtime.engine" "$yq_val" "$awk_val"

  # Test list values
  _CARRANCA_HAS_YQ="yes"
  mapfile -t yq_items < <(_carranca_config_get_list_yq runtime.cap_add "$PARITY_CONFIG")
  _CARRANCA_HAS_YQ="no"
  mapfile -t awk_items < <(carranca_config_get_list runtime.cap_add "$PARITY_CONFIG")
  assert_eq "parser parity: cap_add count" "${#yq_items[@]}" "${#awk_items[@]}"
  assert_eq "parser parity: cap_add[0]" "${yq_items[0]}" "${awk_items[0]}"
  assert_eq "parser parity: cap_add[1]" "${yq_items[1]}" "${awk_items[1]}"

  _CARRANCA_HAS_YQ="$_save_has_yq"
else
  echo "  SKIP: parser parity tests (yq not installed)"
fi

rm -rf "$TMPDIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
