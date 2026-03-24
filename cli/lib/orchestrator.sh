#!/usr/bin/env bash
# carranca/cli/lib/orchestrator.sh — Multi-agent orchestration (Phase 6.2)
#
# Supports running multiple agents in pipeline (sequential) or parallel mode.
# Each agent gets its own container, FIFO, logger, and security boundary.

_orchestrator_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F carranca_lifecycle_build_images >/dev/null 2>&1; then
  source "$_orchestrator_lib_dir/lifecycle.sh"
fi
if ! declare -F carranca_workspace_create >/dev/null 2>&1; then
  source "$_orchestrator_lib_dir/workspace.sh"
fi
unset _orchestrator_lib_dir

# Read orchestration config from .carranca.yml.
# Sets: ORCH_MODE, ORCH_WORKSPACE, ORCH_MERGE
carranca_orchestrator_read_config() {
  ORCH_MODE="$(carranca_config_get orchestration.mode 2>/dev/null || true)"
  ORCH_WORKSPACE="$(carranca_config_get orchestration.workspace 2>/dev/null || true)"
  ORCH_MERGE="$(carranca_config_get orchestration.merge 2>/dev/null || true)"

  if [ -z "$ORCH_MODE" ]; then ORCH_MODE="pipeline"; fi
  if [ -z "$ORCH_WORKSPACE" ]; then ORCH_WORKSPACE="isolated"; fi
  if [ -z "$ORCH_MERGE" ]; then ORCH_MERGE="carry"; fi
}

# Validate orchestration config.
carranca_orchestrator_validate() {
  case "$ORCH_MODE" in
    pipeline|parallel) ;;
    *) carranca_die "Invalid orchestration.mode '$ORCH_MODE' — must be 'pipeline' or 'parallel'" ;;
  esac
  case "$ORCH_WORKSPACE" in
    isolated|shared) ;;
    *) carranca_die "Invalid orchestration.workspace '$ORCH_WORKSPACE' — must be 'isolated' or 'shared'" ;;
  esac
  case "$ORCH_MERGE" in
    carry|discard) ;;
    *) carranca_die "Invalid orchestration.merge '$ORCH_MERGE' — must be 'carry' or 'discard'" ;;
  esac

  local count
  count="$(carranca_config_agent_count)"
  if [ "$count" -lt 2 ]; then
    carranca_die "Orchestration requires at least 2 agents (found $count)"
  fi
}

# Write an event to the orchestrator log.
# Args: event_json
_orch_write_event() {
  local event="$1"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
  printf '{"type":"orchestration_event","ts":"%s","session_id":"%s",%s}\n' \
    "$ts" "$SESSION_ID" "$event" >> "$ORCH_LOG_FILE"
}

# Container naming for multi-agent: carranca-<SESSION>-<AGENT_NAME>-{agent,logger,observer,fifo}
_orch_set_agent_names() {
  local agent_name="$1"
  LOGGER_NAME="carranca-${SESSION_ID}-${agent_name}-logger"
  AGENT_CONTAINER_NAME="carranca-${SESSION_ID}-${agent_name}-agent"
  OBSERVER_NAME="carranca-${SESSION_ID}-${agent_name}-observer"
  FIFO_VOLUME="carranca-${SESSION_ID}-${agent_name}-fifo"
  LOGGER_IMAGE="carranca-${SESSION_ID}-${agent_name}-logger"
  AGENT_IMAGE="carranca-${SESSION_ID}-${agent_name}-agent"
}

# Stop all containers for one agent sub-session.
_orch_stop_agent() {
  local agent_name="$1"
  _orch_set_agent_names "$agent_name"
  carranca_runtime_rm -f "$AGENT_CONTAINER_NAME" 2>/dev/null || true
  carranca_runtime_rm -f "$OBSERVER_NAME" 2>/dev/null || true
  carranca_runtime_stop -t 5 "$LOGGER_NAME" 2>/dev/null || true
  carranca_runtime_rm -f "$LOGGER_NAME" 2>/dev/null || true
  carranca_runtime_volume rm "$FIFO_VOLUME" 2>/dev/null || true
  carranca_runtime_rmi "$AGENT_IMAGE" "$LOGGER_IMAGE" 2>/dev/null || true
}

# Run a single agent sub-session. Returns the agent exit code.
# Args: agent_name workspace_path
# Uses globals for security/policy flags.
_orch_run_agent() {
  local agent_name="$1"
  local agent_workspace="$2"
  local orig_workspace="$WORKSPACE"
  local orig_session_id="$SESSION_ID"
  local orig_agent_name="$SELECTED_AGENT_NAME"
  local orig_agent_command="$AGENT_COMMAND"
  local orig_agent_adapter="$AGENT_ADAPTER"

  # Set per-agent globals
  _orch_set_agent_names "$agent_name"
  SELECTED_AGENT_NAME="$agent_name"
  AGENT_COMMAND="$(carranca_config_agent_field "$agent_name" command)"
  AGENT_ADAPTER="$(carranca_config_agent_driver_for "$agent_name")"
  WORKSPACE="$agent_workspace"

  # Per-agent empty dir overlay
  CARRANCA_EMPTY_DIR="$STATE_DIR/${SESSION_ID}-${agent_name}.carranca-overlay"
  mkdir -p "$CARRANCA_EMPTY_DIR"

  _orch_write_event "\"event\":\"agent_start\",\"agent\":\"$agent_name\",\"mode\":\"$ORCH_MODE\""
  carranca_log info "[$agent_name] Starting agent..."

  local agent_exit=0

  carranca_lifecycle_build_images
  carranca_lifecycle_create_fifo
  carranca_lifecycle_start_logger
  carranca_lifecycle_wait_fifo
  carranca_lifecycle_start_observer
  carranca_lifecycle_resolve_agent_id &
  carranca_lifecycle_run_agent

  # Post-agent: detect logger loss and timeout
  local logger_running
  logger_running="$(carranca_runtime_call inspect --format '{{.State.Running}}' "$LOGGER_NAME" 2>/dev/null || true)"
  if [ "$logger_running" != "true" ]; then
    carranca_log error "[$agent_name] Logger lost — fail closed"
    AGENT_EXIT_CODE=71
  fi

  _orch_stop_agent "$agent_name"
  sleep 1

  # Detect timeout
  local log_file="$STATE_DIR/$SESSION_ID.jsonl"
  if [ "$AGENT_EXIT_CODE" != "71" ] && [ -f "$log_file" ]; then
    if grep -q '"policy":"max_duration".*"action":"timeout"' "$log_file" 2>/dev/null; then
      AGENT_EXIT_CODE=124
    fi
  fi

  agent_exit="$AGENT_EXIT_CODE"
  _orch_write_event "\"event\":\"agent_stop\",\"agent\":\"$agent_name\",\"exit_code\":$agent_exit"
  carranca_log info "[$agent_name] Finished (exit code: $agent_exit)"

  # Restore globals
  WORKSPACE="$orig_workspace"
  SESSION_ID="$orig_session_id"
  SELECTED_AGENT_NAME="$orig_agent_name"
  AGENT_COMMAND="$orig_agent_command"
  AGENT_ADAPTER="$orig_agent_adapter"

  return "$agent_exit"
}

# Pipeline mode: run agents sequentially, fail-fast on first failure.
carranca_orchestrator_pipeline() {
  local agent_names=()
  local name

  while IFS= read -r name; do
    [ -z "$name" ] && continue
    agent_names+=("$name")
  done < <(carranca_config_agent_names)

  _orch_write_event "\"event\":\"pipeline_start\",\"agents\":\"${agent_names[*]}\",\"workspace\":\"$ORCH_WORKSPACE\",\"merge\":\"$ORCH_MERGE\""
  carranca_log info "Pipeline: ${agent_names[*]} (workspace: $ORCH_WORKSPACE, merge: $ORCH_MERGE)"

  local overall_exit=0
  local agent_workspace="$WORKSPACE"
  local prev_workspace=""

  for name in "${agent_names[@]}"; do
    # Workspace isolation
    if [ "$ORCH_WORKSPACE" = "isolated" ]; then
      agent_workspace="$(carranca_workspace_create "$WORKSPACE" "$name" "$prev_workspace")"
    fi

    local agent_exit=0
    _orch_run_agent "$name" "$agent_workspace" || agent_exit=$?

    if [ "$ORCH_WORKSPACE" = "isolated" ] && [ "$ORCH_MERGE" = "carry" ]; then
      prev_workspace="$agent_workspace"
    fi

    if [ "$agent_exit" -ne 0 ]; then
      overall_exit="$agent_exit"
      carranca_log error "Pipeline aborted: $name failed with exit code $agent_exit"
      _orch_write_event "\"event\":\"pipeline_abort\",\"agent\":\"$name\",\"exit_code\":$agent_exit"
      break
    fi
  done

  _orch_write_event "\"event\":\"pipeline_stop\",\"exit_code\":$overall_exit"
  return "$overall_exit"
}

# Parallel mode: run all agents concurrently, wait for all to complete.
carranca_orchestrator_parallel() {
  local agent_names=()
  local name

  while IFS= read -r name; do
    [ -z "$name" ] && continue
    agent_names+=("$name")
  done < <(carranca_config_agent_names)

  _orch_write_event "\"event\":\"parallel_start\",\"agents\":\"${agent_names[*]}\",\"workspace\":\"$ORCH_WORKSPACE\""
  carranca_log info "Parallel: ${agent_names[*]} (workspace: $ORCH_WORKSPACE)"

  local pids=()
  local pid_names=()
  local exit_file
  exit_file="$(mktemp -d)/exits"
  mkdir -p "$exit_file"

  for name in "${agent_names[@]}"; do
    local agent_workspace="$WORKSPACE"
    if [ "$ORCH_WORKSPACE" = "isolated" ]; then
      agent_workspace="$(carranca_workspace_create "$WORKSPACE" "$name" "")"
    fi

    (
      local rc=0
      _orch_run_agent "$name" "$agent_workspace" || rc=$?
      echo "$rc" > "$exit_file/$name"
    ) &
    pids+=($!)
    pid_names+=("$name")
  done

  # Wait for all agents to complete
  local i=0
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
    i=$((i + 1))
  done

  # Determine overall exit code (maximum/worst)
  local overall_exit=0
  for name in "${agent_names[@]}"; do
    if [ -f "$exit_file/$name" ]; then
      local agent_exit
      agent_exit="$(cat "$exit_file/$name")"
      if [ "$agent_exit" -gt "$overall_exit" ] 2>/dev/null; then
        overall_exit="$agent_exit"
      fi
    fi
  done

  rm -rf "$(dirname "$exit_file")"

  _orch_write_event "\"event\":\"parallel_stop\",\"exit_code\":$overall_exit"
  return "$overall_exit"
}

# Main entry point for multi-agent orchestration.
# Globals: SESSION_ID, STATE_DIR, WORKSPACE, plus all config/security globals.
carranca_orchestrate_session() {
  carranca_orchestrator_read_config
  carranca_orchestrator_validate

  ORCH_LOG_FILE="$STATE_DIR/$SESSION_ID.orchestrator.jsonl"
  _orch_write_event "\"event\":\"session_start\",\"mode\":\"$ORCH_MODE\",\"workspace\":\"$ORCH_WORKSPACE\""

  local exit_code=0
  case "$ORCH_MODE" in
    pipeline) carranca_orchestrator_pipeline || exit_code=$? ;;
    parallel) carranca_orchestrator_parallel || exit_code=$? ;;
  esac

  _orch_write_event "\"event\":\"session_stop\",\"exit_code\":$exit_code"
  carranca_log info "Orchestration complete (exit code: $exit_code)"

  return "$exit_code"
}
