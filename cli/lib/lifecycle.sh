#!/usr/bin/env bash
# carranca/cli/lib/lifecycle.sh — Reusable session lifecycle functions
#
# These functions encapsulate the container operations for running a single
# agent session: image build, logger start, FIFO wait, observer start, agent
# run, post-agent checks, and summary.
#
# Callers must set these globals before calling lifecycle functions:
#   CARRANCA_HOME, STATE_BASE, WORKSPACE, SESSION_ID, STATE_DIR,
#   REPO_ID, REPO_NAME, SELECTED_AGENT_NAME, AGENT_COMMAND, AGENT_ADAPTER,
#   CONTAINER_RUNTIME, HOST_UID, HOST_GID, HOST_GROUPS, AGENT_HOME,
#   LOGGER_CAP_FLAGS, AGENT_IDENTITY_FLAGS,
#   (and all policy/security/volume flags computed by run.sh config phase)
#
# For multi-agent orchestration, the caller overrides naming globals
# (LOGGER_NAME, AGENT_CONTAINER_NAME, etc.) per agent before calling.

_lifecycle_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F carranca_runtime_run >/dev/null 2>&1; then
  source "$_lifecycle_lib_dir/runtime.sh"
fi
if ! declare -F carranca_session_prefix >/dev/null 2>&1; then
  source "$_lifecycle_lib_dir/session.sh"
fi
unset _lifecycle_lib_dir

# Build logger and agent images for a session.
# Globals: CARRANCA_HOME, LOGGER_IMAGE, AGENT_IMAGE
carranca_lifecycle_build_images() {
  carranca_log info "Building images..."
  carranca_runtime_build -q -t "$LOGGER_IMAGE" -f "$CARRANCA_HOME/runtime/Containerfile.logger" "$CARRANCA_HOME/runtime" >/dev/null
  carranca_runtime_build -q -t "$AGENT_IMAGE" -f ".carranca/Containerfile" ".carranca" >/dev/null
}

# Create the shared FIFO tmpfs volume.
# Globals: FIFO_VOLUME
carranca_lifecycle_create_fifo() {
  carranca_runtime_volume create "$FIFO_VOLUME" --driver local --opt type=tmpfs --opt device=tmpfs >/dev/null
}

# Start the logger container (detached).
# Globals: LOGGER_NAME, FIFO_VOLUME, WORKSPACE, STATE_DIR, SESSION_ID,
#          REPO_ID, REPO_NAME, SELECTED_AGENT_NAME, AGENT_ADAPTER,
#          CONTAINER_RUNTIME, AGENT_CONTAINER_NAME, LOGGER_CAP_FLAGS,
#          PTRACE_CAP_FLAG, SECRETMON_CAP_FLAG, LOGGER_EXTRA_FLAGS,
#          LOGGER_IMAGE, WATCHED_PATHS_ENV, EXECVE_TRACING, RESOURCE_INTERVAL,
#          SECRET_MONITORING, NETWORK_LOGGING, NETWORK_INTERVAL, MAX_DURATION,
#          RESOURCE_MEMORY, ENFORCE_WATCHED_PATHS, ENFORCED_PATHS,
#          DEGRADED_GLOBS, NETWORK_MODE, NETWORK_POLICY_RULES,
#          INDEPENDENT_OBSERVER, HOST_GID
carranca_lifecycle_start_logger() {
  carranca_log info "Starting logger..."
  # shellcheck disable=SC2086
  carranca_runtime_run -d --rm \
    --name "$LOGGER_NAME" \
    $LOGGER_CAP_FLAGS \
    $PTRACE_CAP_FLAG \
    -v "$FIFO_VOLUME:/fifo" \
    -v "$WORKSPACE:/workspace:ro" \
    -v "$STATE_DIR:/state" \
    -e "SESSION_ID=$SESSION_ID" \
    -e "REPO_ID=$REPO_ID" \
    -e "REPO_NAME=$REPO_NAME" \
    -e "REPO_PATH=$WORKSPACE" \
    -e "WATCHED_PATHS=$WATCHED_PATHS_ENV" \
    -e "AGENT_NAME=$SELECTED_AGENT_NAME" \
    -e "AGENT_ADAPTER=$AGENT_ADAPTER" \
    -e "ENGINE=$CONTAINER_RUNTIME" \
    -e "EXECVE_TRACING=${EXECVE_TRACING:-}" \
    -v /sys/fs/cgroup:/hostcgroup:ro \
    -e "RESOURCE_INTERVAL=${RESOURCE_INTERVAL:-}" \
    -e "AGENT_CONTAINER_NAME=$AGENT_CONTAINER_NAME" \
    -e "SECRET_MONITORING=${SECRET_MONITORING:-}" \
    -e "NETWORK_LOGGING=${NETWORK_LOGGING:-}" \
    -e "NETWORK_INTERVAL=${NETWORK_INTERVAL:-}" \
    -e "MAX_DURATION=${MAX_DURATION:-}" \
    -e "RESOURCE_MEMORY_LIMIT=${RESOURCE_MEMORY:-}" \
    -e "ENFORCE_WATCHED_PATHS=${ENFORCE_WATCHED_PATHS:-}" \
    -e "ENFORCED_PATHS=${ENFORCED_PATHS:-}" \
    -e "DEGRADED_GLOBS=${DEGRADED_GLOBS:-}" \
    -e "NETWORK_MODE=${NETWORK_MODE:-full}" \
    -e "NETWORK_POLICY_RULES=${NETWORK_POLICY_RULES:-}" \
    -e "INDEPENDENT_OBSERVER=${INDEPENDENT_OBSERVER:-}" \
    -e "AGENT_GID=$HOST_GID" \
    $SECRETMON_CAP_FLAG \
    $LOGGER_EXTRA_FLAGS \
    "$LOGGER_IMAGE" >/dev/null
}

# Wait for the FIFO to become ready inside the logger container.
# Globals: LOGGER_NAME
carranca_lifecycle_wait_fifo() {
  local wait=0
  while [ "$wait" -lt 30 ]; do
    if carranca_runtime_exec "$LOGGER_NAME" test -p /fifo/events 2>/dev/null; then
      return 0
    fi
    sleep 0.5
    wait=$((wait + 1))
  done
  carranca_die "Logger FIFO not ready after 15s — fail closed (session cannot proceed without logging)"
}

# Start the independent observer sidecar (optional).
# Globals: INDEPENDENT_OBSERVER, OBSERVER_NAME, FIFO_VOLUME, STATE_DIR,
#          SESSION_ID, AGENT_CONTAINER_NAME, NETWORK_LOGGING,
#          NETWORK_INTERVAL, LOGGER_IMAGE
carranca_lifecycle_start_observer() {
  [ "$INDEPENDENT_OBSERVER" = "true" ] || return 0
  carranca_log info "Starting independent observer..."
  # shellcheck disable=SC2086
  carranca_runtime_run -d --rm \
    --name "$OBSERVER_NAME" \
    --pid=host \
    --cap-add SYS_PTRACE \
    -v "$FIFO_VOLUME:/fifo" \
    -v "$STATE_DIR:/state" \
    -e "SESSION_ID=$SESSION_ID" \
    -e "AGENT_CONTAINER_NAME=$AGENT_CONTAINER_NAME" \
    -e "NETWORK_LOGGING=${NETWORK_LOGGING:-}" \
    -e "NETWORK_INTERVAL=${NETWORK_INTERVAL:-}" \
    --entrypoint /usr/local/bin/observer.sh \
    "$LOGGER_IMAGE" >/dev/null
}

# Resolve agent container ID (and host PID) in background.
# The container ID is used by the resource sampler for cgroup lookup.
# The host PID is written for the observer's fallback when cgroup-based
# PID discovery fails (common with rootless Podman on cgroup v2).
# Uses a single inspect call to avoid extra podman lock contention.
# Globals: AGENT_CONTAINER_NAME, STATE_DIR
carranca_lifecycle_resolve_agent_id() {
  local attempts=0
  while [ "$attempts" -lt 30 ]; do
    local info
    info="$(carranca_runtime_call inspect --format '{{.Id}}|{{.State.Pid}}' "$AGENT_CONTAINER_NAME" 2>/dev/null || true)"
    if [ -n "$info" ]; then
      local cid="${info%%|*}"
      local host_pid="${info##*|}"
      if [ -n "$cid" ]; then
        printf '%s' "$cid" > "$STATE_DIR/agent-container-id"
        if [ -n "$host_pid" ] && [ "$host_pid" -gt 0 ] 2>/dev/null; then
          printf '%s' "$host_pid" > "$STATE_DIR/agent-host-pid"
        fi
        return 0
      fi
    fi
    sleep 1
    attempts=$((attempts + 1))
  done
}

# Run the agent container interactively. Sets AGENT_EXIT_CODE.
# Globals: AGENT_CONTAINER_NAME, AGENT_IDENTITY_FLAGS, PID_NS_FLAG,
#          FIFO_VOLUME, WORKSPACE, CARRANCA_EMPTY_DIR, AGENT_HOME,
#          CACHE_FLAGS, CUSTOM_VOLUME_FLAGS, SKILL_MOUNT_FLAGS,
#          EXTRA_GROUP_FLAGS, SECCOMP_FLAG, APPARMOR_FLAG,
#          CAP_DROP_FLAG, CAP_ADD_FLAGS, AGENT_COMMAND, SESSION_ID,
#          NETWORK_FLAG, RESOURCE_LIMIT_FLAGS, READ_ONLY_FLAGS,
#          FILESYSTEM_RO_FLAGS, POLICY_HOOKS_FLAGS, POLICY_HOOKS_ENV,
#          NETWORK_POLICY_FLAGS, NETWORK_POLICY_ENV,
#          NETWORK_POLICY_ENTRYPOINT, EXTRA_FLAGS, AGENT_ENV_FLAGS, AGENT_IMAGE
carranca_lifecycle_run_agent() {
  local tty_flags="-i"
  if [ -t 0 ]; then
    tty_flags="-it"
  fi

  local effective_identity_flags="$AGENT_IDENTITY_FLAGS"
  if [ -n "$NETWORK_POLICY_ENTRYPOINT" ]; then
    effective_identity_flags=""
  fi

  AGENT_EXIT_CODE=0
  # shellcheck disable=SC2086
  carranca_runtime_run $tty_flags --rm \
    --name "$AGENT_CONTAINER_NAME" \
    $effective_identity_flags \
    $PID_NS_FLAG \
    -v "$FIFO_VOLUME:/fifo" \
    -v "$WORKSPACE:/workspace:rw" \
    -v "$CARRANCA_EMPTY_DIR:/workspace/.carranca:ro" \
    -v /dev/null:/workspace/.carranca.yml:ro \
    -e "HOME=$AGENT_HOME" \
    -e "USER=carranca" \
    $CACHE_FLAGS \
    $CUSTOM_VOLUME_FLAGS \
    $SKILL_MOUNT_FLAGS \
    $EXTRA_GROUP_FLAGS \
    $SECCOMP_FLAG \
    $APPARMOR_FLAG \
    $CAP_DROP_FLAG \
    $CAP_ADD_FLAGS \
    -e "AGENT_COMMAND=$AGENT_COMMAND" \
    -e "SESSION_ID=$SESSION_ID" \
    $NETWORK_FLAG \
    $RESOURCE_LIMIT_FLAGS \
    $READ_ONLY_FLAGS \
    $FILESYSTEM_RO_FLAGS \
    $POLICY_HOOKS_FLAGS \
    $POLICY_HOOKS_ENV \
    $NETWORK_POLICY_FLAGS \
    $NETWORK_POLICY_ENV \
    $NETWORK_POLICY_ENTRYPOINT \
    $AGENT_ENV_FLAGS \
    $EXTRA_FLAGS \
    "$AGENT_IMAGE" || AGENT_EXIT_CODE=$?
}

# Post-agent checks: detect logger loss (exit 71) and timeout (exit 124).
# Reads and may override AGENT_EXIT_CODE.
# Globals: AGENT_EXIT_CODE, LOGGER_NAME, SESSION_ID, STATE_DIR
carranca_lifecycle_post_agent() {
  # Detect logger loss
  local logger_running
  logger_running="$(carranca_runtime_call inspect --format '{{.State.Running}}' "$LOGGER_NAME" 2>/dev/null || true)"
  if [ "$logger_running" != "true" ]; then
    carranca_log error "Logger lost during session — fail closed (audit trail interrupted)"
    AGENT_EXIT_CODE=71  # EX_OSERR — audit trail lost
  fi

  if carranca_session_is_active "$SESSION_ID"; then
    carranca_log info "Stopping session..."
    carranca_session_stop "$SESSION_ID"
  fi
  # Prevent duplicate cleanup from trap handlers
  SESSION_CLEANED_UP=1

  # Give the logger time to flush remaining FIFO events
  sleep 1

  # Detect timeout
  local log_file="$STATE_DIR/$SESSION_ID.jsonl"
  if [ "$AGENT_EXIT_CODE" != "71" ] && [ -f "$log_file" ]; then
    if grep -q '"policy":"max_duration".*"action":"timeout"' "$log_file" 2>/dev/null; then
      AGENT_EXIT_CODE=124
    fi
  fi
}

# Print session summary.
# Globals: SESSION_ID, STATE_DIR
carranca_lifecycle_print_summary() {
  local log_file="$STATE_DIR/$SESSION_ID.jsonl"
  echo ""
  if [ -f "$log_file" ]; then
    carranca_log ok "Session $SESSION_ID complete"
    echo ""
    carranca_session_print_summary "$log_file"
    echo ""
  else
    carranca_log warn "Session $SESSION_ID — no log file found"
  fi
}
