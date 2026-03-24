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
  local logger_name agent_name observer_name

  logger_name="$(carranca_session_logger_name "$session_id")"
  agent_name="$(carranca_session_agent_name "$session_id")"
  observer_name="$(carranca_session_observer_name "$session_id")"

  carranca_runtime_ps -a --format '{{.Names}}' 2>/dev/null | awk -v logger_name="$logger_name" -v agent_name="$agent_name" -v observer_name="$observer_name" '
    $0 == logger_name || $0 == agent_name || $0 == observer_name {
      found = 1
    }
    END {
      exit(found ? 0 : 1)
    }
  '
}

carranca_session_is_active() {
  local session_id="$1"
  local logger_name agent_name observer_name

  logger_name="$(carranca_session_logger_name "$session_id")"
  agent_name="$(carranca_session_agent_name "$session_id")"
  observer_name="$(carranca_session_observer_name "$session_id")"

  carranca_runtime_ps --format '{{.Names}}' 2>/dev/null | awk -v logger_name="$logger_name" -v agent_name="$agent_name" -v observer_name="$observer_name" '
    $0 == logger_name || $0 == agent_name || $0 == observer_name {
      found = 1
    }
    END {
      exit(found ? 0 : 1)
    }
  '
}

carranca_session_global_active_ids() {
  carranca_runtime_ps --format '{{.Names}}' 2>/dev/null | \
    sed -n 's/^carranca-\([0-9a-f][0-9a-f]*\)-\(logger\|agent\|observer\)$/\1/p' | \
    sort -u
}

carranca_session_stop() {
  local session_id="$1"
  local logger_name agent_name observer_name fifo_volume logger_image agent_image

  logger_name="$(carranca_session_logger_name "$session_id")"
  agent_name="$(carranca_session_agent_name "$session_id")"
  observer_name="$(carranca_session_observer_name "$session_id")"
  fifo_volume="$(carranca_session_fifo_volume "$session_id")"
  logger_image="$(carranca_session_logger_image "$session_id")"
  agent_image="$(carranca_session_agent_image "$session_id")"

  carranca_runtime_rm -f "$agent_name" 2>/dev/null || true
  carranca_runtime_rm -f "$observer_name" 2>/dev/null || true
  carranca_runtime_stop -t 5 "$logger_name" 2>/dev/null || true
  carranca_runtime_rm -f "$logger_name" 2>/dev/null || true
  carranca_runtime_volume rm "$fifo_volume" 2>/dev/null || true
  carranca_runtime_rmi "$agent_image" "$logger_image" 2>/dev/null || true
}
