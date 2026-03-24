#!/usr/bin/env bash
# carranca/cli/lib/workspace.sh — Workspace isolation for multi-agent orchestration (Phase 6.2)
#
# Provides workspace copies for isolated agent sessions. Uses cp -a for
# portability (overlayfs requires root and specific kernel support that
# is not available in rootless Podman).

_workspace_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F carranca_log >/dev/null 2>&1; then
  source "$_workspace_lib_dir/common.sh"
fi
unset _workspace_lib_dir

# Track created workspace copies for cleanup (file-based to survive subshells).
CARRANCA_WORKSPACE_COPIES_FILE=""

_workspace_copies_file() {
  if [ -z "$CARRANCA_WORKSPACE_COPIES_FILE" ]; then
    CARRANCA_WORKSPACE_COPIES_FILE="${STATE_DIR:?}/.workspace-copies"
  fi
  printf '%s' "$CARRANCA_WORKSPACE_COPIES_FILE"
}

# Create an isolated workspace copy for an agent.
# Args: base_workspace agent_name prev_workspace
# - base_workspace: the original project workspace
# - agent_name: used for naming the copy directory
# - prev_workspace: for pipeline carry mode, copy from previous agent's
#   workspace instead of the base. Empty string means use base.
# Returns: path to the isolated workspace copy (via stdout).
carranca_workspace_create() {
  local base_workspace="$1"
  local agent_name="$2"
  local prev_workspace="${3:-}"

  local copy_dir
  copy_dir="${STATE_DIR:?}/workspace-${SESSION_ID:?}-${agent_name}"

  if [ -d "$copy_dir" ]; then
    rm -rf "$copy_dir"
  fi

  local source_dir="$base_workspace"
  if [ -n "$prev_workspace" ] && [ -d "$prev_workspace" ]; then
    source_dir="$prev_workspace"
  fi

  carranca_log info "[$agent_name] Creating isolated workspace copy..." >&2
  cp -a "$source_dir" "$copy_dir"

  printf '%s\n' "$copy_dir" >> "$(_workspace_copies_file)"
  printf '%s' "$copy_dir"
}

# Clean up all workspace copies created during this session.
carranca_workspace_cleanup() {
  local copies_file
  copies_file="$(_workspace_copies_file)"
  if [ -f "$copies_file" ]; then
    local copy
    while IFS= read -r copy; do
      [ -z "$copy" ] && continue
      if [ -d "$copy" ]; then
        rm -rf "$copy"
      fi
    done < "$copies_file"
    rm -f "$copies_file"
  fi
}
