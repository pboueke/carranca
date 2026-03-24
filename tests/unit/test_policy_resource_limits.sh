#!/usr/bin/env bash
# Unit tests for Phase 4.4 — resource limits config parsing and OOM detection
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/cli/lib/common.sh"
source "$SCRIPT_DIR/cli/lib/config.sh"
source "$SCRIPT_DIR/cli/lib/runtime.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_policy_resource_limits.sh"

TMPDIR="$(mktemp -d)"

# --- Config parsing tests (requires yq) ---

echo ""
echo "--- config parsing ---"

if carranca_config_has_yq; then
  CONFIG="$TMPDIR/resource-limits.yml"
  cat > "$CONFIG" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
policy:
  resource_limits:
    memory: "2g"
    cpus: "2.0"
    pids: 256
EOF

  val="$(carranca_config_get policy.resource_limits.memory "$CONFIG")"
  assert_eq "policy.resource_limits.memory reads correctly" "2g" "$val"

  val="$(carranca_config_get policy.resource_limits.cpus "$CONFIG")"
  assert_eq "policy.resource_limits.cpus reads correctly" "2.0" "$val"

  val="$(carranca_config_get policy.resource_limits.pids "$CONFIG")"
  assert_eq "policy.resource_limits.pids reads correctly" "256" "$val"

  # Missing resource_limits returns empty
  CONFIG_NOLIMITS="$TMPDIR/no-limits.yml"
  cat > "$CONFIG_NOLIMITS" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
policy:
  docs_before_code: warn
EOF

  val="$(carranca_config_get policy.resource_limits.memory "$CONFIG_NOLIMITS")"
  assert_eq "missing resource_limits.memory returns empty" "" "$val"

  val="$(carranca_config_get policy.resource_limits.cpus "$CONFIG_NOLIMITS")"
  assert_eq "missing resource_limits.cpus returns empty" "" "$val"

  # Partial resource_limits
  CONFIG_PARTIAL="$TMPDIR/partial-limits.yml"
  cat > "$CONFIG_PARTIAL" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
policy:
  resource_limits:
    memory: "512m"
EOF

  val="$(carranca_config_get policy.resource_limits.memory "$CONFIG_PARTIAL")"
  assert_eq "partial resource_limits.memory reads correctly" "512m" "$val"

  val="$(carranca_config_get policy.resource_limits.cpus "$CONFIG_PARTIAL")"
  assert_eq "partial: missing cpus returns empty" "" "$val"

  # Global config fallback for policy.*
  GLOBAL_CONFIG="$TMPDIR/global.yml"
  cat > "$GLOBAL_CONFIG" <<'EOF'
policy:
  resource_limits:
    memory: "4g"
    cpus: "4.0"
EOF

  PROJECT_CONFIG="$TMPDIR/project-nopolicy.yml"
  cat > "$PROJECT_CONFIG" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
EOF

  _save_config="$CARRANCA_CONFIG_FILE"
  _save_global="$CARRANCA_GLOBAL_CONFIG"
  CARRANCA_CONFIG_FILE="$PROJECT_CONFIG"
  CARRANCA_GLOBAL_CONFIG="$GLOBAL_CONFIG"

  val="$(carranca_config_get_with_global policy.resource_limits.memory)"
  assert_eq "global fallback: policy.resource_limits.memory" "4g" "$val"

  val="$(carranca_config_get_with_global policy.resource_limits.cpus)"
  assert_eq "global fallback: policy.resource_limits.cpus" "4.0" "$val"

  CARRANCA_CONFIG_FILE="$_save_config"
  CARRANCA_GLOBAL_CONFIG="$_save_global"
else
  echo "  SKIP: resource_limits config tests (yq not installed, 3-level nesting requires yq)"
fi

# --- Flag construction tests ---

echo ""
echo "--- flag construction ---"

# Simulate the flag-building logic from run.sh
build_resource_flags() {
  local memory="$1" cpus="$2" pids="$3"
  local flags=""
  [ -n "$memory" ] && flags="$flags --memory $memory"
  [ -n "$cpus" ] && flags="$flags --cpus $cpus"
  [ -n "$pids" ] && flags="$flags --pids-limit $pids"
  printf '%s' "$flags"
}

result="$(build_resource_flags "2g" "2.0" "256")"
assert_eq "all flags set" " --memory 2g --cpus 2.0 --pids-limit 256" "$result"

result="$(build_resource_flags "512m" "" "")"
assert_eq "only memory flag" " --memory 512m" "$result"

result="$(build_resource_flags "" "1.5" "")"
assert_eq "only cpus flag" " --cpus 1.5" "$result"

result="$(build_resource_flags "" "" "100")"
assert_eq "only pids flag" " --pids-limit 100" "$result"

result="$(build_resource_flags "" "" "")"
assert_eq "no flags when all empty" "" "$result"

# --- OOM detection tests ---

echo ""
echo "--- OOM detection ---"

# Extract _read_oom_kill_count from logger.sh
eval "$(sed -n '/^_read_oom_kill_count()/,/^}/p' "$SCRIPT_DIR/runtime/logger.sh")"

# Test: reads oom_kill count from memory.events
CGROUP_DIR="$TMPDIR/cgroup-oom"
mkdir -p "$CGROUP_DIR"
cat > "$CGROUP_DIR/memory.events" <<'EOF'
low 0
high 0
max 3
oom 2
oom_kill 1
oom_group_kill 0
EOF

result="$(_read_oom_kill_count "$CGROUP_DIR")"
assert_eq "reads oom_kill count" "1" "$result"

# Test: incremented oom_kill count
cat > "$CGROUP_DIR/memory.events" <<'EOF'
low 0
high 0
max 5
oom 4
oom_kill 3
oom_group_kill 0
EOF

result="$(_read_oom_kill_count "$CGROUP_DIR")"
assert_eq "reads updated oom_kill count" "3" "$result"

# Test: missing memory.events returns 0
CGROUP_NOEVENTS="$TMPDIR/cgroup-noevents"
mkdir -p "$CGROUP_NOEVENTS"

result="$(_read_oom_kill_count "$CGROUP_NOEVENTS")"
assert_eq "missing memory.events returns 0" "0" "$result"

# Test: memory.events without oom_kill line returns 0
CGROUP_NOOOM="$TMPDIR/cgroup-nooom"
mkdir -p "$CGROUP_NOOOM"
cat > "$CGROUP_NOOOM/memory.events" <<'EOF'
low 0
high 0
max 0
oom 0
EOF

result="$(_read_oom_kill_count "$CGROUP_NOOOM")"
assert_eq "memory.events without oom_kill returns 0" "0" "$result"

rm -rf "$TMPDIR"

echo ""
print_results
