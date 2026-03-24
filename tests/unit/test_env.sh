#!/usr/bin/env bash
# Unit tests for cli/lib/env.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/cli/lib/common.sh"
source "$SCRIPT_DIR/cli/lib/config.sh"
source "$SCRIPT_DIR/cli/lib/env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_env.sh"

TMPDIR="$(mktemp -d)"

# --- carranca_env_valid_name ---

rc=0; carranca_env_valid_name "FOO" || rc=$?
assert_eq "valid name: simple" "0" "$rc"

rc=0; carranca_env_valid_name "_FOO" || rc=$?
assert_eq "valid name: underscore prefix" "0" "$rc"

rc=0; carranca_env_valid_name "My_Var_123" || rc=$?
assert_eq "valid name: mixed case" "0" "$rc"

rc=0; carranca_env_valid_name "1FOO" || rc=$?
assert_eq "invalid name: starts with digit" "1" "$rc"

rc=0; carranca_env_valid_name "FOO-BAR" || rc=$?
assert_eq "invalid name: contains dash" "1" "$rc"

rc=0; carranca_env_valid_name "" || rc=$?
assert_eq "invalid name: empty" "1" "$rc"

rc=0; carranca_env_valid_name "FOO BAR" || rc=$?
assert_eq "invalid name: contains space" "1" "$rc"

# --- carranca_env_parse_file ---

ENV_FILE="$TMPDIR/.env.test"
cat > "$ENV_FILE" <<'EOF'
# This is a comment
SIMPLE=value
QUOTED="double quoted"
SINGLE='single quoted'
export EXPORTED=exported_val
  WHITESPACE=trimmed

EMPTY_LINE_ABOVE=yes
NO_EQUALS_LINE
# Another comment
MULTI_WORD=hello world
EOF

mapfile -t parsed < <(carranca_env_parse_file "$ENV_FILE")
assert_eq "parse_file: line count" "7" "${#parsed[@]}"
assert_eq "parse_file: simple" "SIMPLE=value" "${parsed[0]}"
assert_eq "parse_file: double quoted" "QUOTED=double quoted" "${parsed[1]}"
assert_eq "parse_file: single quoted" "SINGLE=single quoted" "${parsed[2]}"
assert_eq "parse_file: export prefix stripped" "EXPORTED=exported_val" "${parsed[3]}"
assert_eq "parse_file: whitespace trimmed" "WHITESPACE=trimmed" "${parsed[4]}"
assert_eq "parse_file: empty line skipped" "EMPTY_LINE_ABOVE=yes" "${parsed[5]}"
assert_eq "parse_file: multi-word value" "MULTI_WORD=hello world" "${parsed[6]}"

# Missing file returns error
rc=0; carranca_env_parse_file "$TMPDIR/nonexistent" || rc=$?
assert_eq "parse_file: missing file returns 1" "1" "$rc"

# --- carranca_env_build_flags: passthrough ---

CONFIG="$TMPDIR/passthrough.yml"
cat > "$CONFIG" <<'EOF'
agents:
  - name: test
    command: test
environment:
  passthrough:
    - TEST_PASSTHROUGH_VAR
EOF

export TEST_PASSTHROUGH_VAR="hello_from_host"
CARRANCA_CONFIG_FILE="$CONFIG"
flags="$(carranca_env_build_flags "$CONFIG")"
assert_contains "passthrough: flag contains var" "TEST_PASSTHROUGH_VAR=hello_from_host" "$flags"
unset TEST_PASSTHROUGH_VAR

# Passthrough with missing host var: should warn and skip
flags="$(carranca_env_build_flags "$CONFIG" 2>/dev/null)"
case "$flags" in
  *TEST_PASSTHROUGH_VAR*) assert_eq "passthrough: missing host var should be skipped" "skipped" "present" ;;
  *) assert_eq "passthrough: missing host var correctly skipped" "skipped" "skipped" ;;
esac

# --- carranca_env_build_flags: env_file ---

ENV_FILE2="$TMPDIR/.env.agent"
cat > "$ENV_FILE2" <<'EOF'
API_KEY=sk-test-123
REGION=us-east-1
EOF

CONFIG2="$TMPDIR/envfile.yml"
cat > "$CONFIG2" <<EOF
agents:
  - name: test
    command: test
environment:
  env_file: $ENV_FILE2
EOF

CARRANCA_CONFIG_FILE="$CONFIG2"
flags="$(carranca_env_build_flags "$CONFIG2")"
assert_contains "env_file: contains API_KEY" "API_KEY=sk-test-123" "$flags"
assert_contains "env_file: contains REGION" "REGION=us-east-1" "$flags"

# --- carranca_env_build_flags: vars (with yq) ---

if command -v yq >/dev/null 2>&1; then
  CONFIG3="$TMPDIR/vars.yml"
  cat > "$CONFIG3" <<'EOF'
agents:
  - name: test
    command: test
environment:
  vars:
    CUSTOM_VAR: custom_value
    ANOTHER: second
EOF

  CARRANCA_CONFIG_FILE="$CONFIG3"
  flags="$(carranca_env_build_flags "$CONFIG3")"
  assert_contains "vars (yq): contains CUSTOM_VAR" "CUSTOM_VAR=custom_value" "$flags"
  assert_contains "vars (yq): contains ANOTHER" "ANOTHER=second" "$flags"
else
  echo "  SKIP: vars (yq) tests — yq not installed"
fi

# --- carranca_env_build_flags: priority (env_file overrides passthrough) ---

ENV_FILE3="$TMPDIR/.env.priority"
cat > "$ENV_FILE3" <<'EOF'
SHARED=from_envfile
ENVONLY=envfile_val
EOF

export SHARED="from_host"
export HOSTONLY="host_val"

CONFIG4="$TMPDIR/priority.yml"
cat > "$CONFIG4" <<EOF
agents:
  - name: test
    command: test
environment:
  passthrough:
    - SHARED
    - HOSTONLY
  env_file: $ENV_FILE3
EOF

CARRANCA_CONFIG_FILE="$CONFIG4"
flags="$(carranca_env_build_flags "$CONFIG4")"
# env_file should override passthrough for SHARED
assert_contains "priority: env_file overrides passthrough" "SHARED=from_envfile" "$flags"
assert_contains "priority: passthrough-only var present" "HOSTONLY=host_val" "$flags"
assert_contains "priority: envfile-only var present" "ENVONLY=envfile_val" "$flags"
unset SHARED HOSTONLY

# --- carranca_env_build_flags: empty config ---

CONFIG5="$TMPDIR/empty.yml"
cat > "$CONFIG5" <<'EOF'
agents:
  - name: test
    command: test
EOF

CARRANCA_CONFIG_FILE="$CONFIG5"
flags="$(carranca_env_build_flags "$CONFIG5")"
assert_eq "empty config: no flags" "" "$flags"

# --- carranca_env_validate ---

CONFIG6="$TMPDIR/invalid_name.yml"
cat > "$CONFIG6" <<'EOF'
agents:
  - name: test
    command: test
environment:
  passthrough:
    - VALID_NAME
    - 1INVALID
EOF

CARRANCA_CONFIG_FILE="$CONFIG6"
rc=0; carranca_env_validate "$CONFIG6" 2>/dev/null || rc=$?
assert_eq "validate: invalid passthrough name" "1" "$rc"

# Missing env_file
CONFIG7="$TMPDIR/missing_envfile.yml"
cat > "$CONFIG7" <<'EOF'
agents:
  - name: test
    command: test
environment:
  env_file: /tmp/nonexistent_env_file_xyz
EOF

CARRANCA_CONFIG_FILE="$CONFIG7"
rc=0; carranca_env_validate "$CONFIG7" 2>/dev/null || rc=$?
assert_eq "validate: missing env_file" "1" "$rc"

# Valid config
CONFIG8="$TMPDIR/valid_env.yml"
cat > "$CONFIG8" <<'EOF'
agents:
  - name: test
    command: test
environment:
  passthrough:
    - HOME
    - PATH
EOF

CARRANCA_CONFIG_FILE="$CONFIG8"
rc=0; carranca_env_validate "$CONFIG8" || rc=$?
assert_eq "validate: valid passthrough" "0" "$rc"

# --- carranca_env_build_flags: vars without yq (awk fallback) ---

CONFIG9="$TMPDIR/vars_awk.yml"
cat > "$CONFIG9" <<'EOF'
agents:
  - name: test
    command: test
environment:
  vars:
    AWK_VAR: awk_value
    ANOTHER_AWK: second_awk
EOF

_CARRANCA_HAS_YQ_SAVED="$_CARRANCA_HAS_YQ"
_CARRANCA_HAS_YQ="no"
CARRANCA_CONFIG_FILE="$CONFIG9"
flags="$(carranca_env_build_flags "$CONFIG9")"
assert_contains "vars (awk): contains AWK_VAR" "AWK_VAR=awk_value" "$flags"
assert_contains "vars (awk): contains ANOTHER_AWK" "ANOTHER_AWK=second_awk" "$flags"
_CARRANCA_HAS_YQ="$_CARRANCA_HAS_YQ_SAVED"

# --- carranca_env_parse_file: edge cases ---

ENV_EDGE="$TMPDIR/.env.edge"
cat > "$ENV_EDGE" <<'EOF'
# empty value
EMPTY=
# value with equals sign
HAS_EQUALS=key=val=ue
EOF

mapfile -t parsed < <(carranca_env_parse_file "$ENV_EDGE")
assert_eq "parse_file edge: empty value" "EMPTY=" "${parsed[0]}"
assert_eq "parse_file edge: value with equals" "HAS_EQUALS=key=val=ue" "${parsed[1]}"

rm -rf "$TMPDIR"

echo ""
print_results
