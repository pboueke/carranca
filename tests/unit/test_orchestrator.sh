#!/usr/bin/env bash
# Unit tests for Phase 6.2 — orchestrator config parsing and workspace isolation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_orchestrator.sh"

# Set up fake docker to prevent runtime errors
FAKEBIN="$(mktemp -d)"
cat > "$FAKEBIN/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKEBIN/docker"
export CARRANCA_CONTAINER_RUNTIME="docker"
export PATH="$FAKEBIN:$PATH"

source "$SCRIPT_DIR/cli/lib/common.sh"
source "$SCRIPT_DIR/cli/lib/config.sh"
source "$SCRIPT_DIR/cli/lib/runtime.sh"
source "$SCRIPT_DIR/cli/lib/session.sh"
source "$SCRIPT_DIR/cli/lib/lifecycle.sh"
source "$SCRIPT_DIR/cli/lib/orchestrator.sh"

TMPDIR="$(mktemp -d)"
STATE_DIR="$TMPDIR/state"
SESSION_ID="test1234"
mkdir -p "$STATE_DIR"

# --- Test orchestrator config parsing ---

echo ""
echo "--- orchestrator config parsing ---"

CONFIG="$TMPDIR/pipeline.yml"
cat > "$CONFIG" <<'EOF'
agents:
  - name: coder
    command: "echo code"
  - name: reviewer
    command: "echo review"
orchestration:
  mode: pipeline
  workspace: isolated
  merge: carry
EOF

CARRANCA_CONFIG_FILE="$CONFIG"
carranca_orchestrator_read_config
assert_eq "mode reads pipeline" "pipeline" "$ORCH_MODE"
assert_eq "workspace reads isolated" "isolated" "$ORCH_WORKSPACE"
assert_eq "merge reads carry" "carry" "$ORCH_MERGE"

# Test: defaults
CONFIG_DEFAULT="$TMPDIR/default.yml"
cat > "$CONFIG_DEFAULT" <<'EOF'
agents:
  - name: a
    command: "echo a"
  - name: b
    command: "echo b"
EOF

CARRANCA_CONFIG_FILE="$CONFIG_DEFAULT"
carranca_orchestrator_read_config
assert_eq "default mode is pipeline" "pipeline" "$ORCH_MODE"
assert_eq "default workspace is isolated" "isolated" "$ORCH_WORKSPACE"
assert_eq "default merge is carry" "carry" "$ORCH_MERGE"

# Test: parallel mode
CONFIG_PAR="$TMPDIR/parallel.yml"
cat > "$CONFIG_PAR" <<'EOF'
agents:
  - name: linter
    command: "lint"
  - name: tester
    command: "test"
orchestration:
  mode: parallel
  workspace: shared
EOF

CARRANCA_CONFIG_FILE="$CONFIG_PAR"
carranca_orchestrator_read_config
assert_eq "parallel mode reads correctly" "parallel" "$ORCH_MODE"
assert_eq "shared workspace reads correctly" "shared" "$ORCH_WORKSPACE"

# --- Test validation ---

echo ""
echo "--- orchestrator validation ---"

ORCH_MODE="pipeline"
ORCH_WORKSPACE="isolated"
ORCH_MERGE="carry"
CARRANCA_CONFIG_FILE="$CONFIG"

# Valid config should pass
RC=0
carranca_orchestrator_validate 2>/dev/null || RC=$?
assert_eq "valid config passes validation" "0" "$RC"

# Invalid mode (run in subshell since carranca_die exits)
ORCH_MODE="invalid"
RC=0
(carranca_orchestrator_validate) 2>/dev/null || RC=$?
assert_eq "invalid mode fails validation" "1" "$RC"
ORCH_MODE="pipeline"

# Invalid workspace
ORCH_WORKSPACE="invalid"
RC=0
(carranca_orchestrator_validate) 2>/dev/null || RC=$?
assert_eq "invalid workspace fails validation" "1" "$RC"
ORCH_WORKSPACE="isolated"

# Invalid merge
ORCH_MERGE="invalid"
RC=0
(carranca_orchestrator_validate) 2>/dev/null || RC=$?
assert_eq "invalid merge fails validation" "1" "$RC"
ORCH_MERGE="carry"

# Too few agents
CONFIG_ONE="$TMPDIR/one.yml"
cat > "$CONFIG_ONE" <<'EOF'
agents:
  - name: solo
    command: "echo solo"
EOF
CARRANCA_CONFIG_FILE="$CONFIG_ONE"
RC=0
(carranca_orchestrator_validate) 2>/dev/null || RC=$?
assert_eq "single agent fails validation" "1" "$RC"

# --- Test workspace isolation ---

echo ""
echo "--- workspace isolation ---"

source "$SCRIPT_DIR/cli/lib/workspace.sh"

WORKSPACE_BASE="$TMPDIR/workspace"
mkdir -p "$WORKSPACE_BASE"
echo "hello" > "$WORKSPACE_BASE/file.txt"
mkdir -p "$WORKSPACE_BASE/subdir"
echo "nested" > "$WORKSPACE_BASE/subdir/nested.txt"

# Create isolated workspace
COPY_PATH="$(carranca_workspace_create "$WORKSPACE_BASE" "agent1" "")"
assert_contains "workspace copy is in state dir" "$STATE_DIR" "$COPY_PATH"
assert_eq "copy has file.txt" "hello" "$(cat "$COPY_PATH/file.txt")"
assert_eq "copy has nested file" "nested" "$(cat "$COPY_PATH/subdir/nested.txt")"

# Modify the copy
echo "modified" > "$COPY_PATH/file.txt"
echo "new" > "$COPY_PATH/new.txt"

# Create carry workspace from previous
CARRY_PATH="$(carranca_workspace_create "$WORKSPACE_BASE" "agent2" "$COPY_PATH")"
assert_eq "carry has modified file" "modified" "$(cat "$CARRY_PATH/file.txt")"
assert_eq "carry has new file" "new" "$(cat "$CARRY_PATH/new.txt")"

# Create discard workspace (from base, ignoring prev)
DISCARD_PATH="$(carranca_workspace_create "$WORKSPACE_BASE" "agent3" "")"
assert_eq "discard has original file" "hello" "$(cat "$DISCARD_PATH/file.txt")"
RC=0
[ -f "$DISCARD_PATH/new.txt" ] || RC=1
assert_eq "discard does not have new file" "1" "$RC"

# Cleanup
carranca_workspace_cleanup
RC=0
[ -d "$COPY_PATH" ] || RC=1
assert_eq "cleanup removes workspace copies" "1" "$RC"

# --- Test multi-agent container naming ---

echo ""
echo "--- multi-agent naming ---"

# The orchestrator sets per-agent container names
_orch_set_agent_names "coder"
assert_eq "logger name includes agent" "carranca-test1234-coder-logger" "$LOGGER_NAME"
assert_eq "agent name includes agent" "carranca-test1234-coder-agent" "$AGENT_CONTAINER_NAME"
assert_eq "fifo volume includes agent" "carranca-test1234-coder-fifo" "$FIFO_VOLUME"
assert_eq "observer includes agent" "carranca-test1234-coder-observer" "$OBSERVER_NAME"

rm -rf "$TMPDIR" "$FAKEBIN"

echo ""
print_results
