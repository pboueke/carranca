#!/usr/bin/env bash
# carranca/cli/lib/session.sh — Session lifecycle and container helper functions

if ! declare -F carranca_runtime_ps >/dev/null 2>&1; then
  _session_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if ! declare -F carranca_die >/dev/null 2>&1; then
    source "$_session_lib_dir/common.sh"
  fi
  source "$_session_lib_dir/runtime.sh"
  unset _session_lib_dir
fi

carranca_session_prefix() {
  local session_id="$1"
  printf 'carranca-%s' "$session_id"
}

carranca_session_logger_name() {
  local session_id="$1"
  printf '%s-logger' "$(carranca_session_prefix "$session_id")"
}

carranca_session_agent_name() {
  local session_id="$1"
  printf '%s-agent' "$(carranca_session_prefix "$session_id")"
}

carranca_session_fifo_volume() {
  local session_id="$1"
  printf '%s-fifo' "$(carranca_session_prefix "$session_id")"
}

carranca_session_logger_image() {
  local session_id="$1"
  printf '%s-logger' "$(carranca_session_prefix "$session_id")"
}

carranca_session_agent_image() {
  local session_id="$1"
  printf '%s-agent' "$(carranca_session_prefix "$session_id")"
}

carranca_session_observer_name() {
  local session_id="$1"
  printf '%s-observer' "$(carranca_session_prefix "$session_id")"
}

carranca_session_exists() {
  local session_id="$1"
  local prefix
  prefix="$(carranca_session_prefix "$session_id")"

  # Match both single-agent (carranca-<id>-{agent,logger,observer})
  # and multi-agent (carranca-<id>-<name>-{agent,logger,observer}) containers
  carranca_runtime_ps -a --format '{{.Names}}' 2>/dev/null | \
    grep -q "^${prefix}-" 2>/dev/null
}

carranca_session_is_active() {
  local session_id="$1"
  local prefix
  prefix="$(carranca_session_prefix "$session_id")"

  carranca_runtime_ps --format '{{.Names}}' 2>/dev/null | \
    grep -q "^${prefix}-" 2>/dev/null
}

carranca_session_global_active_ids() {
  carranca_runtime_ps --format '{{.Names}}' 2>/dev/null | \
    sed -n 's/^carranca-\([0-9a-f][0-9a-f]*\)-.*/\1/p' | \
    sort -u
}

carranca_session_stop() {
  local session_id="$1"
  local prefix
  prefix="$(carranca_session_prefix "$session_id")"

  # Stop all containers matching this session prefix (single or multi-agent)
  local container
  while IFS= read -r container; do
    [ -z "$container" ] && continue
    case "$container" in
      *-logger) carranca_runtime_stop -t 5 "$container" 2>/dev/null || true ;;
      *) carranca_runtime_rm -f "$container" 2>/dev/null || true ;;
    esac
  done < <(carranca_runtime_ps -a --format '{{.Names}}' 2>/dev/null | grep "^${prefix}-" || true)

  # Remove remaining containers after stopping loggers
  while IFS= read -r container; do
    [ -z "$container" ] && continue
    carranca_runtime_rm -f "$container" 2>/dev/null || true
  done < <(carranca_runtime_ps -a --format '{{.Names}}' 2>/dev/null | grep "^${prefix}-" || true)

  # Remove FIFO volumes matching this session
  local volume
  while IFS= read -r volume; do
    [ -z "$volume" ] && continue
    carranca_runtime_volume rm "$volume" 2>/dev/null || true
  done < <(carranca_runtime_volume ls --format '{{.Name}}' 2>/dev/null | grep "^${prefix}-" || true)

  # Remove transient images
  local image
  while IFS= read -r image; do
    [ -z "$image" ] && continue
    carranca_runtime_rmi "$image" 2>/dev/null || true
  done < <(carranca_runtime_call images --format '{{.Repository}}' 2>/dev/null | grep "^${prefix}-" || true)
}
