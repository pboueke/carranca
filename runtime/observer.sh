#!/usr/bin/env bash
# carranca observer — independent sidecar for execve tracing and network monitoring
#
# Runs outside the agent's PID/mount namespace with CAP_SYS_PTRACE.
# Writes events to the shared FIFO for the logger to record.
# Provides independent ground truth that the agent cannot interfere with.
set -uo pipefail

FIFO_PATH="/fifo/events"
SESSION_ID="${SESSION_ID:-unknown}"
AGENT_CONTAINER_NAME="${AGENT_CONTAINER_NAME:-}"
NETWORK_LOGGING="${NETWORK_LOGGING:-}"
NETWORK_INTERVAL="${NETWORK_INTERVAL:-5}"

OBSERVER_TOKEN=""

timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Read the observer authentication token from /state/ (written by logger).
# This token proves to the logger that events came from the observer, not the agent.
_read_observer_token() {
  local token_file="/state/${SESSION_ID}.observer-token"
  local attempts=0
  while [ "$attempts" -lt 30 ]; do
    if [ -f "$token_file" ]; then
      OBSERVER_TOKEN="$(cat "$token_file" 2>/dev/null)"
      [ -n "$OBSERVER_TOKEN" ] && return 0
    fi
    sleep 0.5
    attempts=$((attempts + 1))
  done
  echo "observer: token file not found after 15s" >&2
  return 1
}

# Source the shared strace parser
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRACE_EVENT_SOURCE="observer"
STRACE_WRITE_FIFO="true"
# shellcheck source=lib/strace-parser.sh
source "$SCRIPT_DIR/lib/strace-parser.sh"

# --- Wait for FIFO ---
_wait_for_fifo() {
  local attempts=0
  while [ "$attempts" -lt 60 ]; do
    [ -p "$FIFO_PATH" ] && return 0
    sleep 0.5
    attempts=$((attempts + 1))
  done
  echo "observer: FIFO not ready after 30s" >&2
  exit 1
}

# --- Find agent's host PID ---
# The agent container ID is written to /state/agent-container-id by run.sh.
# We search /proc for a process whose cgroup contains this container ID.
_find_agent_host_pid() {
  local id_file="/state/agent-container-id"
  local container_id=""
  local attempts=0

  # Wait up to 30s for the container ID file
  while [ "$attempts" -lt 30 ]; do
    if [ -f "$id_file" ]; then
      container_id="$(cat "$id_file" 2>/dev/null)"
      [ -n "$container_id" ] && break
    fi
    sleep 1
    attempts=$((attempts + 1))
  done

  if [ -z "$container_id" ]; then
    echo "observer: agent container ID not found after 30s" >&2
    return 1
  fi

  # Search /proc for all processes in the agent's cgroup, then select the
  # lowest host PID. The container's init process (PID 1 inside the namespace)
  # gets the lowest host PID among siblings, and strace -f from PID 1 will
  # trace all descendants.
  local lowest_pid=""
  local pid_dir
  for pid_dir in /proc/[0-9]*; do
    local p="${pid_dir##*/}"
    if grep -q "$container_id" "$pid_dir/cgroup" 2>/dev/null; then
      if [ -z "$lowest_pid" ] || [ "$p" -lt "$lowest_pid" ]; then
        lowest_pid="$p"
      fi
    fi
  done

  if [ -n "$lowest_pid" ]; then
    printf '%s' "$lowest_pid"
    return 0
  fi

  echo "observer: no process found for container $container_id" >&2
  return 1
}

# --- Execve tracer ---
_start_observer_tracer() {
  local agent_pid="$1"

  if ! command -v strace >/dev/null 2>&1; then
    local deg="{\"type\":\"session_event\",\"source\":\"observer\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"event\":\"degraded\",\"reason\":\"strace_unavailable\",\"_observer_token\":\"$OBSERVER_TOKEN\"}"
    printf '%s\n' "$deg" > "$FIFO_PATH"
    return
  fi

  strace -f -e trace=execve -e signal=none -qq -p "$agent_pid" 2>&1 | while IFS= read -r line; do
    strace_line_to_event "$line"
  done
}

# --- Network monitor ---
_hex_to_ip() {
  local hex="$1"
  local len=${#hex}
  if [ "$len" -eq 8 ]; then
    printf '%d.%d.%d.%d' \
      "0x${hex:6:2}" "0x${hex:4:2}" "0x${hex:2:2}" "0x${hex:0:2}"
  elif [ "$len" -eq 32 ]; then
    local result="" i
    for i in 0 8 16 24; do
      local word="${hex:$i:8}"
      local hi lo
      hi="$(printf '%02x%02x' "0x${word:6:2}" "0x${word:4:2}")"
      lo="$(printf '%02x%02x' "0x${word:2:2}" "0x${word:0:2}")"
      [ -n "$result" ] && result="$result:"
      result="$result$hi:$lo"
    done
    printf '%s' "$result"
  else
    printf '%s' "$hex"
  fi
}

_hex_to_port() {
  printf '%d' "0x$1"
}

_parse_proc_net_tcp() {
  local filepath="$1"
  [ -r "$filepath" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      *sl*local_address*) continue ;;
    esac
    local trimmed
    trimmed="$(echo "$line" | sed 's/^[[:space:]]*//')"
    local rem_addr state
    rem_addr="$(echo "$trimmed" | awk '{print $3}')"
    state="$(echo "$trimmed" | awk '{print $4}')"
    case "$state" in
      01|02) ;;
      *) continue ;;
    esac
    local rem_ip_hex rem_port_hex
    rem_ip_hex="${rem_addr%%:*}"
    rem_port_hex="${rem_addr##*:}"
    case "$rem_ip_hex" in
      0100007F|00000000000000000000000001000000|00000000000000000000000000000000) continue ;;
    esac
    local dest_ip dest_port state_name
    dest_ip="$(_hex_to_ip "$rem_ip_hex")"
    dest_port="$(_hex_to_port "$rem_port_hex")"
    case "$dest_ip" in
      127.0.0.1|::1|0000:0000:0000:0000:0000:0000:0000:0001) continue ;;
    esac
    [ "$state" = "01" ] && state_name="ESTABLISHED" || state_name="SYN_SENT"
    printf '%s %s %s\n' "$dest_ip" "$dest_port" "$state_name"
  done < "$filepath"
}

_start_observer_network_monitor() {
  local agent_pid="$1"
  local interval="${NETWORK_INTERVAL:-5}"

  # Use the agent's /proc/<pid>/net/tcp for its network namespace
  local net_tcp="/proc/$agent_pid/net/tcp"
  local net_tcp6="/proc/$agent_pid/net/tcp6"

  if [ ! -r "$net_tcp" ]; then
    local deg="{\"type\":\"session_event\",\"source\":\"observer\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"event\":\"degraded\",\"reason\":\"network_logging_unavailable\",\"_observer_token\":\"$OBSERVER_TOKEN\"}"
    printf '%s\n' "$deg" > "$FIFO_PATH"
    return
  fi

  local prev_file
  prev_file="$(mktemp /tmp/observer-netmon-prev.XXXXXX)"
  touch "$prev_file"

  while [ -d "/proc/$agent_pid" ]; do
    local current_file
    current_file="$(mktemp /tmp/observer-netmon-cur.XXXXXX)"
    _parse_proc_net_tcp "$net_tcp" > "$current_file" 2>/dev/null
    [ -r "$net_tcp6" ] && _parse_proc_net_tcp "$net_tcp6" >> "$current_file" 2>/dev/null
    sort -u "$current_file" -o "$current_file"
    sort -u "$prev_file" -o "$prev_file"
    local new_conns
    new_conns="$(comm -23 "$current_file" "$prev_file")"
    if [ -n "$new_conns" ]; then
      while IFS=' ' read -r ip port state; do
        local event="{\"type\":\"network_event\",\"source\":\"observer\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"dest_ip\":\"$ip\",\"dest_port\":$port,\"protocol\":\"tcp\",\"state\":\"$state\",\"_observer_token\":\"$OBSERVER_TOKEN\"}"
        printf '%s\n' "$event" > "$FIFO_PATH"
      done <<< "$new_conns"
    fi
    cp "$current_file" "$prev_file"
    rm -f "$current_file"
    sleep "$interval"
  done
  rm -f "$prev_file"
}

# --- Main ---

_wait_for_fifo

# Read authentication token (written by logger to /state/)
_read_observer_token || {
  echo "observer: cannot authenticate without token, exiting" >&2
  exit 1
}

AGENT_PID=""
AGENT_PID="$(_find_agent_host_pid)" || {
  DEG="{\"type\":\"session_event\",\"source\":\"observer\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"event\":\"degraded\",\"reason\":\"agent_pid_not_found\",\"_observer_token\":\"$OBSERVER_TOKEN\"}"
  printf '%s\n' "$DEG" > "$FIFO_PATH"
  exit 0
}

OBSERVER_START="{\"type\":\"session_event\",\"source\":\"observer\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"event\":\"observer_start\",\"agent_pid\":$AGENT_PID,\"_observer_token\":\"$OBSERVER_TOKEN\"}"
printf '%s\n' "$OBSERVER_START" > "$FIFO_PATH"

TRACER_PID=""
NETMON_PID=""

# Start execve tracer
_start_observer_tracer "$AGENT_PID" &
TRACER_PID=$!

# Start network monitor if enabled
if [ "${NETWORK_LOGGING:-}" = "true" ]; then
  _start_observer_network_monitor "$AGENT_PID" &
  NETMON_PID=$!
fi

# Wait for agent to exit
while [ -d "/proc/$AGENT_PID" ]; do
  sleep 1
done

# Cleanup
[ -n "$TRACER_PID" ] && kill "$TRACER_PID" 2>/dev/null || true
[ -n "$NETMON_PID" ] && kill "$NETMON_PID" 2>/dev/null || true

OBSERVER_STOP="{\"type\":\"session_event\",\"source\":\"observer\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"event\":\"observer_stop\",\"_observer_token\":\"$OBSERVER_TOKEN\"}"
printf '%s\n' "$OBSERVER_STOP" > "$FIFO_PATH" 2>/dev/null || true

exit 0
