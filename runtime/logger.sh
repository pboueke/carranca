#!/usr/bin/env bash
# carranca logger — reads events from FIFO + file watcher, writes JSONL session log
#
# This script is the ENTRYPOINT of the logger container. It:
# 1. Creates the FIFO on the shared tmpfs
# 2. Sets chattr +a on the log file (degrades gracefully)
# 3. Starts inotifywait (or fswatch as fallback) in background (degrades gracefully)
# 4. Reads FIFO events in foreground
# 5. Merges all events with monotonic seq numbers into the JSONL log
# 6. On SIGTERM: writes logger_stop event and exits
set -uo pipefail

FIFO_PATH="/fifo/events"
SESSION_ID="${SESSION_ID:-unknown}"
REPO_ID="${REPO_ID:-unknown}"
REPO_NAME="${REPO_NAME:-unknown}"
REPO_PATH="${REPO_PATH:-unknown}"
AGENT_NAME="${AGENT_NAME:-unknown}"
AGENT_ADAPTER="${AGENT_ADAPTER:-unknown}"
ENGINE="${ENGINE:-unknown}"
LOG_FILE="/state/${SESSION_ID}.jsonl"
SEQ_FILE="/tmp/carranca-seq"
SEQ_LOCK="/tmp/carranca-seq.lock"
HMAC_KEY_FILE="/state/${SESSION_ID}.hmac-key"
HMAC_KEY=""
PREV_HMAC="0"
CHECKSUM_FILE="/state/${SESSION_ID}.checksums"

# --- Helpers ---

timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Atomically increment the seq counter and write an event to the log.
# Uses flock + a file-based counter to handle concurrent writers
# (FIFO reader + inotifywait background process).
write_log() {
  local line="$1"
  {
    flock 9
    local seq
    seq=$(cat "$SEQ_FILE" 2>/dev/null || echo 0)
    seq=$((seq + 1))
    echo "$seq" > "$SEQ_FILE"
    # Inject seq into the JSON object
    local line_with_seq="${line%\}},\"seq\":$seq}"
    # Extract ts for HMAC input
    local ts
    ts="$(printf '%s' "$line_with_seq" | grep -o '"ts":"[^"]*"' | head -1 | cut -d'"' -f4)"
    # Compute HMAC over: prev_hmac | seq | ts | line_with_seq
    local hmac_input="${PREV_HMAC}|${seq}|${ts}|${line_with_seq}"
    local hmac_value
    hmac_value="$(compute_hmac "$hmac_input")"
    PREV_HMAC="$hmac_value"
    # Inject hmac and write to log file
    local final_line="${line_with_seq%\}},\"hmac\":\"$hmac_value\"}"
    printf '%s\n' "$final_line" >> "$LOG_FILE"
    # Write parallel checksum for tamper detection
    write_checksum "$final_line"
  } 9>"$SEQ_LOCK"
}

# Check if a file path matches any watched_paths pattern.
# WATCHED_PATHS is colon-separated (e.g., ".env:secrets/:*.key").
# Matching rules:
#   - If pattern ends with "/" → prefix match (path starts with /workspace/<pattern>)
#   - If pattern starts with "*." → suffix match (path ends with the extension)
#   - Otherwise → exact basename or path-suffix match
path_is_watched() {
  local filepath="$1"
  local pattern
  local IFS=':'

  [ -z "${WATCHED_PATHS:-}" ] && return 1

  for pattern in $WATCHED_PATHS; do
    [ -z "$pattern" ] && continue
    case "$pattern" in
      */)
        # Directory prefix: check if path is under /workspace/<pattern>
        case "$filepath" in
          /workspace/"$pattern"*) return 0 ;;
        esac
        ;;
      \*.*)
        # Extension glob: check if path ends with the suffix
        local suffix="${pattern#\*}"
        case "$filepath" in
          *"$suffix") return 0 ;;
        esac
        ;;
      *)
        # Exact basename or path suffix match
        local basename="${filepath##*/}"
        if [ "$basename" = "$pattern" ] || [[ "$filepath" == */"$pattern" ]]; then
          return 0
        fi
        ;;
    esac
  done
  return 1
}

# Generate a per-session HMAC key and save it to /state/
# The key file lives outside the agent container for security.
generate_hmac_key() {
  HMAC_KEY="$(openssl rand -hex 32)"
  printf '%s\n' "$HMAC_KEY" > "$HMAC_KEY_FILE"
  chmod 0600 "$HMAC_KEY_FILE"
}

# Compute HMAC-SHA256 of a message using the session key.
compute_hmac() {
  local message="$1"
  printf '%s' "$message" | openssl dgst -sha256 -macopt "hexkey:$HMAC_KEY" -hex 2>/dev/null | awk '{print $NF}'
}

# Write SHA-256 checksum of a log line to parallel checksum file.
# This provides tamper detection even when chattr +a is unavailable.
write_checksum() {
  local line="$1"
  local hash
  hash="$(printf '%s' "$line" | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}')"
  printf '%s\n' "$hash" >> "$CHECKSUM_FILE"
}

# --- Setup ---

# Initialize seq counter
echo "0" > "$SEQ_FILE"

# Create FIFO
mkfifo "$FIFO_PATH"
chmod 0666 "$FIFO_PATH"

# Create log file and try to make it append-only
touch "$LOG_FILE"
touch "$CHECKSUM_FILE"
if chattr +a "$LOG_FILE" 2>/dev/null; then
  APPEND_ONLY=true
else
  APPEND_ONLY=false
fi

# Generate HMAC key for this session
generate_hmac_key

# Write session start event
START_EVENT="{\"type\":\"session_event\",\"source\":\"carranca\",\"event\":\"start\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"repo_id\":\"$REPO_ID\",\"repo_name\":\"$REPO_NAME\",\"repo_path\":\"$REPO_PATH\",\"agent\":\"$AGENT_NAME\",\"adapter\":\"$AGENT_ADAPTER\",\"engine\":\"$ENGINE\"}"
write_log "$START_EVENT"

# Log degraded mode for append-only if needed
if [ "$APPEND_ONLY" = false ]; then
  DEG_EVENT="{\"type\":\"session_event\",\"source\":\"carranca\",\"event\":\"degraded\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"append_only_unavailable\"}"
  write_log "$DEG_EVENT"
fi

# --- File event watcher (background, best-effort) ---

# Shared handler: tag watched paths and write to log
_handle_file_event() {
  local line="$1"
  if [ -n "${WATCHED_PATHS:-}" ]; then
    local local_path
    local_path="$(printf '%s' "$line" | grep -o '"path":"[^"]*"' | head -1 | cut -d'"' -f4)"
    if [ -n "$local_path" ] && path_is_watched "$local_path"; then
      line="${line%\}},\"watched\":true}"
    fi
  fi
  write_log "$line"
}

_start_inotifywait() {
  inotifywait -m -r -e create,modify,delete \
    --format '{"type":"file_event","source":"inotifywait","ts":"%T","event":"%e","path":"%w%f","session_id":"'"$SESSION_ID"'"}' \
    --timefmt '%Y-%m-%dT%H:%M:%SZ' \
    /workspace 2>/dev/null | while IFS= read -r line; do
      _handle_file_event "$line"
    done
}

_start_fswatch() {
  # fswatch outputs one path per line on each event.
  # We convert to the same JSON schema as inotifywait.
  # fswatch flags: -r recursive, --event Created Modified Removed
  fswatch -r --event Created --event Updated --event Removed \
    /workspace 2>/dev/null | while IFS= read -r filepath; do
      local event_type="MODIFY"
      if [ ! -e "$filepath" ]; then
        event_type="DELETE"
      elif [ -e "$filepath" ]; then
        # fswatch doesn't cleanly distinguish create vs modify;
        # new files show as Updated too. We accept MODIFY as default.
        event_type="MODIFY"
      fi
      local ts
      ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      local line="{\"type\":\"file_event\",\"source\":\"fswatch\",\"ts\":\"$ts\",\"event\":\"$event_type\",\"path\":\"$filepath\",\"session_id\":\"$SESSION_ID\"}"
      _handle_file_event "$line"
    done
}

SECRETMON_PID=""

_start_secret_monitor() {
  [ "${SECRET_MONITORING:-}" = "true" ] || return 0

  if [ ! -x /usr/local/bin/fanotify-watcher ]; then
    DEG_EVENT="{\"type\":\"session_event\",\"source\":\"carranca\",\"event\":\"degraded\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"fanotify_binary_unavailable\"}"
    write_log "$DEG_EVENT"
    return 0
  fi

  /usr/local/bin/fanotify-watcher /workspace 2>/dev/null | while IFS= read -r line; do
    local path pid
    path="$(printf '%s' "$line" | grep -o '"path":"[^"]*"' | head -1 | cut -d'"' -f4)"
    pid="$(printf '%s' "$line" | grep -o '"pid":[0-9]*' | head -1 | cut -d: -f2)"
    [ -z "$path" ] && continue
    if path_is_watched "$path"; then
      local event="{\"type\":\"file_access_event\",\"source\":\"fanotify\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"path\":\"$path\",\"pid\":${pid:-0},\"watched\":true}"
      write_log "$event"
    fi
  done

  # If we reach here, fanotify-watcher exited (likely EPERM)
  DEG_EVENT="{\"type\":\"session_event\",\"source\":\"carranca\",\"event\":\"degraded\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"sys_admin_unavailable\"}"
  write_log "$DEG_EVENT"
}

_start_secret_monitor &
SECRETMON_PID=$!

WATCHER_PID=""
if command -v inotifywait >/dev/null 2>&1; then
  _start_inotifywait &
  WATCHER_PID=$!
elif command -v fswatch >/dev/null 2>&1; then
  _start_fswatch &
  WATCHER_PID=$!
else
  DEG_EVENT="{\"type\":\"session_event\",\"source\":\"carranca\",\"event\":\"degraded\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"file_watcher_unavailable\"}"
  write_log "$DEG_EVENT"
fi

# --- Resource consumption sampler (background, best-effort) ---

RESOURCE_INTERVAL="${RESOURCE_INTERVAL:-10}"
AGENT_CONTAINER_NAME="${AGENT_CONTAINER_NAME:-}"

_find_agent_cgroup() {
  local search_key="$1"
  local base="/hostcgroup"
  local dir

  [ -d "$base" ] || return 1

  # Search top level (cgroup v2 unified: /hostcgroup/<hash>)
  for dir in "$base"/*"$search_key"*; do
    [ -d "$dir" ] && printf '%s' "$dir" && return 0
  done

  # Search one level deeper (e.g., /hostcgroup/system.slice/docker-<id>.scope)
  for dir in "$base"/*/*"$search_key"*; do
    [ -d "$dir" ] && printf '%s' "$dir" && return 0
  done

  # Search two levels deep (e.g., /hostcgroup/system.slice/docker-.../libpod-<id>)
  for dir in "$base"/*/*/*"$search_key"*; do
    [ -d "$dir" ] && printf '%s' "$dir" && return 0
  done

  return 1
}

_read_cgroup_stats() {
  local cgroup_dir="$1"
  local stats=""

  # cpu.stat — usage_usec
  if [ -f "$cgroup_dir/cpu.stat" ]; then
    local cpu_usec
    cpu_usec="$(awk '$1 == "usage_usec" { print $2 }' "$cgroup_dir/cpu.stat" 2>/dev/null)"
    if [ -n "$cpu_usec" ]; then
      stats="$stats,\"cpu_usage_us\":$cpu_usec"
    fi
  fi

  # memory.current
  if [ -f "$cgroup_dir/memory.current" ]; then
    local mem
    mem="$(cat "$cgroup_dir/memory.current" 2>/dev/null)"
    if [ -n "$mem" ]; then
      stats="$stats,\"memory_bytes\":$mem"
    fi
  fi

  # pids.current
  if [ -f "$cgroup_dir/pids.current" ]; then
    local pids
    pids="$(cat "$cgroup_dir/pids.current" 2>/dev/null)"
    if [ -n "$pids" ]; then
      stats="$stats,\"pids\":$pids"
    fi
  fi

  printf '%s' "$stats"
}

_start_resource_sampler() {
  local interval="$1"
  local container_name="$2"
  local cgroup_dir=""

  # Wait up to 15s for the resolved container ID file from run.sh
  local id_file="/state/agent-container-id"
  local attempts=0
  while [ "$attempts" -lt 15 ]; do
    if [ -f "$id_file" ]; then
      local resolved_id
      resolved_id="$(cat "$id_file" 2>/dev/null)"
      if [ -n "$resolved_id" ]; then
        cgroup_dir="$(_find_agent_cgroup "$resolved_id")" && break
      fi
    fi
    # Fallback: try container name directly
    cgroup_dir="$(_find_agent_cgroup "$container_name")" && break
    sleep 1
    attempts=$((attempts + 1))
  done

  if [ -z "$cgroup_dir" ]; then
    DEG_EVENT="{\"type\":\"session_event\",\"source\":\"carranca\",\"event\":\"degraded\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"cgroup_not_found\"}"
    write_log "$DEG_EVENT"
    return
  fi

  while true; do
    sleep "$interval"
    local stats
    stats="$(_read_cgroup_stats "$cgroup_dir")"
    if [ -n "$stats" ]; then
      local event="{\"type\":\"resource_event\",\"source\":\"carranca\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\"$stats}"
      write_log "$event"
    fi
  done
}

SAMPLER_PID=""
if [ -n "$AGENT_CONTAINER_NAME" ] && [ "${RESOURCE_INTERVAL:-0}" != "0" ] && [ -n "${RESOURCE_INTERVAL:-}" ]; then
  _start_resource_sampler "$RESOURCE_INTERVAL" "$AGENT_CONTAINER_NAME" &
  SAMPLER_PID=$!
fi

# --- Execve tracer (background, best-effort) ---

_strace_to_event() {
  local line="$1"

  # Skip lines that don't contain execve
  case "$line" in
    *execve\(*) ;;
    *) return ;;
  esac

  # Extract pid: [pid 42] prefix or default to 0
  local pid=0
  case "$line" in
    \[pid\ *)
      pid="$(printf '%s' "$line" | awk -F'[][ ]+' '{print $3}')"
      ;;
  esac

  # Extract binary path: first argument to execve("...")
  local binary
  binary="$(printf '%s' "$line" | sed -n 's/.*execve("\([^"]*\)".*/\1/p')"
  [ -z "$binary" ] && return

  # Extract argv: the bracket list ["arg0", "arg1", ...]
  local argv_str
  argv_str="$(printf '%s' "$line" | sed -n 's/.*execve([^,]*, \(\[[^]]*\]\).*/\1/p')"
  [ -z "$argv_str" ] && argv_str="[]"

  local event="{\"type\":\"execve_event\",\"source\":\"strace\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"pid\":$pid,\"binary\":\"$binary\",\"argv\":\"$argv_str\"}"
  write_log "$event"
}

TRACER_PID=""

_start_execve_tracer() {
  # Check if tracing is enabled
  if [ "${EXECVE_TRACING:-}" != "true" ]; then
    return
  fi

  # Check if strace is available
  if ! command -v strace >/dev/null 2>&1; then
    local deg_event="{\"type\":\"session_event\",\"source\":\"carranca\",\"event\":\"degraded\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"strace_unavailable\"}"
    write_log "$deg_event"
    return
  fi

  # Wait up to 10 seconds for a non-self process to appear
  local my_pid=$$
  local agent_pid=""
  local wait_count=0
  while [ "$wait_count" -lt 20 ]; do
    for pid_dir in /proc/[0-9]*; do
      local p="${pid_dir##*/}"
      [ "$p" = "$my_pid" ] && continue
      # Skip our children (watcher, subshells)
      local ppid
      ppid="$(awk '/^PPid:/{print $2}' "$pid_dir/status" 2>/dev/null || true)"
      [ "$ppid" = "$my_pid" ] && continue
      # Skip kernel threads (pid 1 is fine — it could be the agent's init)
      [ "$p" = "1" ] && { agent_pid="$p"; break; }
      agent_pid="$p"
      break
    done
    [ -n "$agent_pid" ] && break
    sleep 0.5
    wait_count=$((wait_count + 1))
  done

  if [ -z "$agent_pid" ]; then
    local deg_event="{\"type\":\"session_event\",\"source\":\"carranca\",\"event\":\"degraded\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"agent_pid_not_found\"}"
    write_log "$deg_event"
    return
  fi

  strace -f -e trace=execve -e signal=none -qq -p "$agent_pid" 2>&1 | while IFS= read -r line; do
    _strace_to_event "$line"
  done &
  TRACER_PID=$!
}

_start_execve_tracer &

# --- Network connection monitor (background, best-effort) ---

_hex_to_ip() {
  local hex="$1"
  local len=${#hex}
  if [ "$len" -eq 8 ]; then
    # IPv4 — bytes are little-endian on x86
    printf '%d.%d.%d.%d' \
      "0x${hex:6:2}" "0x${hex:4:2}" "0x${hex:2:2}" "0x${hex:0:2}"
  elif [ "$len" -eq 32 ]; then
    # IPv6 — four 32-bit words, each in little-endian byte order
    local result=""
    local i
    for i in 0 8 16 24; do
      local word="${hex:$i:8}"
      local hi lo
      hi="$(printf '%02x%02x' "0x${word:6:2}" "0x${word:4:2}")"
      lo="$(printf '%02x%02x' "0x${word:2:2}" "0x${word:0:2}")"
      if [ -n "$result" ]; then
        result="$result:"
      fi
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
    # Skip header
    case "$line" in
      *sl*local_address*) continue ;;
    esac
    # Trim leading whitespace and parse fields
    local trimmed
    trimmed="$(echo "$line" | sed 's/^[[:space:]]*//')"
    local local_addr rem_addr state
    local_addr="$(echo "$trimmed" | awk '{print $2}')"
    rem_addr="$(echo "$trimmed" | awk '{print $3}')"
    state="$(echo "$trimmed" | awk '{print $4}')"
    # Only ESTABLISHED (01) or SYN_SENT (02)
    case "$state" in
      01) ;;
      02) ;;
      *) continue ;;
    esac
    local rem_ip_hex rem_port_hex
    rem_ip_hex="${rem_addr%%:*}"
    rem_port_hex="${rem_addr##*:}"
    # Skip loopback (hex form)
    case "$rem_ip_hex" in
      0100007F) continue ;;
      00000000000000000000000001000000) continue ;;
      00000000000000000000000000000000) continue ;;
    esac
    local dest_ip dest_port state_name
    dest_ip="$(_hex_to_ip "$rem_ip_hex")"
    dest_port="$(_hex_to_port "$rem_port_hex")"
    # Filter loopback in decoded form
    case "$dest_ip" in
      127.0.0.1) continue ;;
      ::1) continue ;;
      0000:0000:0000:0000:0000:0000:0000:0001) continue ;;
    esac
    if [ "$state" = "01" ]; then
      state_name="ESTABLISHED"
    else
      state_name="SYN_SENT"
    fi
    printf '%s %s %s\n' "$dest_ip" "$dest_port" "$state_name"
  done < "$filepath"
}

_start_network_monitor() {
  [ "${NETWORK_LOGGING:-}" = "true" ] || return 0

  local interval="${NETWORK_INTERVAL:-5}"
  local prev_file
  prev_file="$(mktemp /tmp/carranca-netmon-prev.XXXXXX)"
  touch "$prev_file"

  # Check if /proc/net/tcp is readable
  if [ ! -r /proc/net/tcp ]; then
    local deg_event="{\"type\":\"session_event\",\"source\":\"carranca\",\"event\":\"degraded\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"network_logging_unavailable\"}"
    write_log "$deg_event"
    rm -f "$prev_file"
    return
  fi

  while true; do
    local current_file
    current_file="$(mktemp /tmp/carranca-netmon-cur.XXXXXX)"
    _parse_proc_net_tcp /proc/net/tcp > "$current_file" 2>/dev/null
    if [ -r /proc/net/tcp6 ]; then
      _parse_proc_net_tcp /proc/net/tcp6 >> "$current_file" 2>/dev/null
    fi
    # Sort for stable comparison
    sort -u "$current_file" -o "$current_file"
    sort -u "$prev_file" -o "$prev_file"
    # Find new connections
    local new_conns
    new_conns="$(comm -23 "$current_file" "$prev_file")"
    if [ -n "$new_conns" ]; then
      while IFS=' ' read -r ip port state; do
        local event="{\"type\":\"network_event\",\"source\":\"carranca\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"dest_ip\":\"$ip\",\"dest_port\":$port,\"protocol\":\"tcp\",\"state\":\"$state\"}"
        write_log "$event"
      done <<< "$new_conns"
    fi
    cp "$current_file" "$prev_file"
    rm -f "$current_file"
    sleep "$interval"
  done
}

NETMON_PID=""
if [ "${NETWORK_LOGGING:-}" = "true" ]; then
  _start_network_monitor &
  NETMON_PID=$!
fi

# --- SIGTERM handler ---

_cleanup() {
  STOP_EVENT="{\"type\":\"session_event\",\"source\":\"carranca\",\"event\":\"logger_stop\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\"}"
  write_log "$STOP_EVENT"
  [ -n "$NETMON_PID" ] && kill "$NETMON_PID" 2>/dev/null
  [ -n "$TRACER_PID" ] && kill "$TRACER_PID" 2>/dev/null
  [ -n "$WATCHER_PID" ] && kill "$WATCHER_PID" 2>/dev/null
  [ -n "$SAMPLER_PID" ] && kill "$SAMPLER_PID" 2>/dev/null
  [ -n "$SECRETMON_PID" ] && kill "$SECRETMON_PID" 2>/dev/null
  rm -f "$FIFO_PATH" "$SEQ_LOCK" "$SEQ_FILE"
  exit 0
}
trap _cleanup SIGTERM SIGINT

# --- Main loop: read FIFO ---

# Open FIFO for reading. We use a persistent fd so the FIFO stays open
# even between individual writes from the agent.
exec 3<>"$FIFO_PATH"

while true; do
  IFS= read -t 2 -r line <&3
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # read -t returns >128 on timeout, 1 on EOF/error
    if [ "$rc" -le 128 ]; then
      # EOF or error — FIFO closed, agent exited
      break
    fi
    # Timeout — loop back to allow SIGTERM trap to fire
    continue
  fi

  # Skip empty lines
  [ -z "$line" ] && continue

  # Basic JSON validation: must start with { and end with }
  if [[ "$line" == "{"*"}" ]]; then
    write_log "$line"
  else
    # Malformed event — log it as invalid
    ESCAPED_RAW="$(printf '%s' "$line" | head -c 200 | sed 's/\\/\\\\/g; s/"/\\"/g')"
    INVALID="{\"type\":\"invalid_event\",\"source\":\"fifo\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"raw\":\"$ESCAPED_RAW\"}"
    write_log "$INVALID"
  fi
done

# FIFO closed — agent exited
_cleanup
