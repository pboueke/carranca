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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/json.sh
source "$SCRIPT_DIR/lib/json.sh"

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
PREV_HMAC_FILE="/tmp/carranca-prev-hmac"
CHECKSUM_FILE="/state/${SESSION_ID}.checksums"
PREV_CHECKSUM_FILE="/tmp/carranca-prev-checksum"
CARRANCA_TMPDIR="${CARRANCA_TMPDIR:-/state}"

# FIFO forgery detection state (Phase 5.2)
SESSION_START_TS=""
PREV_FIFO_TS=""

# Observer token for authenticating observer-sourced FIFO events (Phase 5.1).
# Written to /state/ (accessible to logger and observer, not agent).
OBSERVER_TOKEN_FILE="/state/${SESSION_ID}.observer-token"
OBSERVER_TOKEN=""

# --- Helpers ---

timestamp() {
  date -u +%Y-%m-%dT%H:%M:%S.%3NZ
}

# Convert ISO 8601 timestamp to epoch seconds (portable).
_ts_to_epoch() {
  local ts="$1"
  # Remove trailing Z, replace T with space for date parsing
  local cleaned="${ts%Z}"
  cleaned="${cleaned/T/ }"
  date -u -d "$cleaned" +%s 2>/dev/null || echo 0
}

# Strip seq and hmac fields from a JSON line if present.
# The logger is the sole authority on these fields — FIFO events must not contain them.
_strip_fifo_injected_fields() {
  local line="$1"
  # Remove "seq":N and "hmac":"..." fields (with optional leading comma)
  line="$(printf '%s' "$line" | sed 's/,"seq":[0-9]*//g; s/"seq":[0-9]*,\?//g')"
  line="$(printf '%s' "$line" | sed 's/,"hmac":"[^"]*"//g; s/"hmac":"[^"]*",\?//g')"
  printf '%s' "$line"
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
    # Guard: verify the line ends with } before performing string surgery.
    # If it doesn't, skip this line to avoid producing broken JSON.
    if [[ "$line" != *"}" ]]; then
      echo "write_log: WARNING: skipping line not ending with '}': ${line:0:120}" >&2
      return
    fi
    # Read shared HMAC chain state from file (survives across subshells)
    local prev_hmac
    prev_hmac="$(cat "$PREV_HMAC_FILE" 2>/dev/null || echo 0)"
    # Inject seq into the JSON object
    local line_with_seq="${line%\}},\"seq\":$seq}"
    # Extract ts for HMAC input
    local ts
    ts="$(printf '%s' "$line_with_seq" | grep -o '"ts":"[^"]*"' | head -1 | cut -d'"' -f4)"
    # Compute HMAC over: prev_hmac | seq | ts | line_with_seq
    local hmac_input="${prev_hmac}|${seq}|${ts}|${line_with_seq}"
    local hmac_value
    hmac_value="$(compute_hmac "$hmac_input")"
    echo "$hmac_value" > "$PREV_HMAC_FILE"
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
# Each checksum chains the previous hash, so reordering or deletion is detectable.
write_checksum() {
  local line="$1"
  # Read shared checksum chain state from file (survives across subshells).
  # Called inside the flock block of write_log, so no additional locking needed.
  local prev_checksum
  prev_checksum="$(cat "$PREV_CHECKSUM_FILE" 2>/dev/null || true)"
  local hash
  hash="$(printf '%s' "${prev_checksum}${line}" | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}')"
  echo "$hash" > "$PREV_CHECKSUM_FILE"
  printf '%s\n' "$hash" >> "$CHECKSUM_FILE"
}

# Constant-time string comparison to prevent timing side-channels.
# Iterates all characters regardless of mismatch position.
_constant_time_compare() {
  local a="$1" b="$2"
  [ ${#a} -eq ${#b} ] || return 1
  local diff=0 i
  for (( i=0; i<${#a}; i++ )); do
    [ "${a:i:1}" = "${b:i:1}" ] || diff=1
  done
  return $diff
}

# Validate a FIFO event for forgery indicators (Phase 5.2).
# Returns 0 always (events are still logged). Flags issues by writing integrity_event entries.
# The validated (possibly stripped) event is printed to stdout.
_validate_fifo_event() {
  local line="$1"
  local issues=""

  # 1. Required fields: type, source, ts, session_id
  local has_type has_source has_ts has_session_id
  has_type="$(printf '%s' "$line" | grep -o '"type"' | head -1 || true)"
  has_source="$(printf '%s' "$line" | grep -o '"source"' | head -1 || true)"
  has_ts="$(printf '%s' "$line" | grep -o '"ts"' | head -1 || true)"
  has_session_id="$(printf '%s' "$line" | grep -o '"session_id"' | head -1 || true)"

  if [ -z "$has_type" ] || [ -z "$has_source" ] || [ -z "$has_ts" ] || [ -z "$has_session_id" ]; then
    issues="${issues:+$issues,}missing_required_fields"
  fi

  # 2. Timestamp bounds
  if [ -n "$has_ts" ] && [ -n "$SESSION_START_TS" ]; then
    local event_ts
    event_ts="$(printf '%s' "$line" | grep -o '"ts":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    if [ -n "$event_ts" ]; then
      local event_epoch now_epoch start_epoch
      event_epoch="$(_ts_to_epoch "$event_ts")"
      now_epoch="$(date -u +%s)"
      start_epoch="$(_ts_to_epoch "$SESSION_START_TS")"

      if [ "$event_epoch" -gt 0 ] 2>/dev/null; then
        # Before session start
        if [ "$event_epoch" -lt "$start_epoch" ] 2>/dev/null; then
          issues="${issues:+$issues,}timestamp_before_session"
        fi
        # More than 2s in the future
        if [ "$((event_epoch - now_epoch))" -gt 2 ] 2>/dev/null; then
          issues="${issues:+$issues,}timestamp_future"
        fi
        # Regression > 30s from previous event
        if [ -n "$PREV_FIFO_TS" ]; then
          local prev_epoch
          prev_epoch="$(_ts_to_epoch "$PREV_FIFO_TS")"
          if [ "$prev_epoch" -gt 0 ] 2>/dev/null && [ "$((prev_epoch - event_epoch))" -gt 30 ] 2>/dev/null; then
            issues="${issues:+$issues,}timestamp_regression"
          fi
        fi
        PREV_FIFO_TS="$event_ts"
      fi
    fi
  fi

  # 3. Seq/HMAC injection: FIFO events must not contain these fields
  local has_seq has_hmac
  has_seq="$(printf '%s' "$line" | grep -o '"seq"' | head -1 || true)"
  has_hmac="$(printf '%s' "$line" | grep -o '"hmac"' | head -1 || true)"
  if [ -n "$has_seq" ] || [ -n "$has_hmac" ]; then
    issues="${issues:+$issues,}seq_injection_attempt"
    line="$(_strip_fifo_injected_fields "$line")"
  fi

  # 4. Source impersonation: FIFO events should only come from shell-wrapper
  local source
  source="$(printf '%s' "$line" | grep -o '"source":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
  case "$source" in
    shell-wrapper|"") ;; # expected FIFO sources
    observer)
      # Observer must present a valid token to authenticate its events.
      # The token lives on /state/ which the agent cannot access.
      if [ "${INDEPENDENT_OBSERVER:-}" != "true" ]; then
        issues="${issues:+$issues,}source_impersonation"
      else
        local event_token
        event_token="$(printf '%s' "$line" | grep -o '"_observer_token":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
        if ! _constant_time_compare "$event_token" "$OBSERVER_TOKEN"; then
          issues="${issues:+$issues,}observer_token_invalid"
        fi
        # Strip the token field before logging (internal-only)
        line="$(printf '%s' "$line" | sed 's/,"_observer_token":"[^"]*"//g; s/"_observer_token":"[^"]*",\?//g')"
      fi
      ;;
    strace|inotifywait|fswatch|carranca|fanotify)
      issues="${issues:+$issues,}source_impersonation"
      ;;
  esac

  # Emit integrity_event for any issues found
  if [ -n "$issues" ]; then
    local integrity_event="{\"type\":\"integrity_event\",\"source\":\"carranca\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"$issues\",\"raw_source\":\"${source:-unknown}\"}"
    write_log "$integrity_event"
  fi

  # Return the (possibly stripped) event
  printf '%s' "$line"
}

# --- Setup ---

# Initialize seq counter and chain state files
echo "0" > "$SEQ_FILE"
echo "0" > "$PREV_HMAC_FILE"
: > "$PREV_CHECKSUM_FILE"

# Create FIFO. If AGENT_GID is set, restrict to 0620 with the agent's group
# for write access. Otherwise fall back to 0666 so sessions don't break.
mkfifo "$FIFO_PATH"
if [ -n "${AGENT_GID:-}" ] && chgrp "$AGENT_GID" "$FIFO_PATH" 2>/dev/null; then
  chmod 0620 "$FIFO_PATH"
else
  chmod 0666 "$FIFO_PATH"
fi

# Create log file and try to make it append-only
touch "$LOG_FILE"
touch "$CHECKSUM_FILE"
if chattr +a "$LOG_FILE" 2>/dev/null; then
  APPEND_ONLY=true
else
  APPEND_ONLY=false
fi

# Try to make checksum file append-only (same protection as log file)
if ! chattr +a "$CHECKSUM_FILE" 2>/dev/null; then
  CHECKSUM_APPEND_ONLY=false
else
  CHECKSUM_APPEND_ONLY=true
fi

# Generate HMAC key for this session
generate_hmac_key

# Generate observer token if independent observer is enabled (Phase 5.1).
# The token lives on /state/, which only logger and observer can access.
if [ "${INDEPENDENT_OBSERVER:-}" = "true" ]; then
  OBSERVER_TOKEN="$(openssl rand -hex 16)"
  printf '%s\n' "$OBSERVER_TOKEN" > "$OBSERVER_TOKEN_FILE"
  chmod 0600 "$OBSERVER_TOKEN_FILE"
fi

# Record session start timestamp for FIFO validation (Phase 5.2)
SESSION_START_TS="$(timestamp)"

# Write session start event (escape config-derived fields for JSON safety)
_esc_repo_name="$(json_escape "$REPO_NAME")"
_esc_repo_path="$(json_escape "$REPO_PATH")"
_esc_agent_name="$(json_escape "$AGENT_NAME")"
_esc_adapter="$(json_escape "$AGENT_ADAPTER")"
_esc_engine="$(json_escape "$ENGINE")"
START_EVENT="{\"type\":\"session_event\",\"source\":\"carranca\",\"event\":\"start\",\"ts\":\"$SESSION_START_TS\",\"session_id\":\"$SESSION_ID\",\"repo_id\":\"$REPO_ID\",\"repo_name\":\"$_esc_repo_name\",\"repo_path\":\"$_esc_repo_path\",\"agent\":\"$_esc_agent_name\",\"adapter\":\"$_esc_adapter\",\"engine\":\"$_esc_engine\"}"
write_log "$START_EVENT"

# Log degraded mode for append-only if needed
if [ "$APPEND_ONLY" = false ]; then
  DEG_EVENT="{\"type\":\"session_event\",\"source\":\"carranca\",\"event\":\"degraded\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"append_only_unavailable\"}"
  write_log "$DEG_EVENT"
fi

# Log degraded mode for checksum file append-only if needed
if [ "$CHECKSUM_APPEND_ONLY" = false ]; then
  DEG_EVENT="{\"type\":\"session_event\",\"source\":\"carranca\",\"event\":\"degraded\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"checksum_append_only_unavailable\"}"
  write_log "$DEG_EVENT"
fi

# Log filesystem enforcement policy events (4.2)
if [ "${ENFORCE_WATCHED_PATHS:-}" = "true" ]; then
  if [ -n "${ENFORCED_PATHS:-}" ]; then
    _esc_enforced="$(json_escape "$ENFORCED_PATHS")"
    FS_EVENT="{\"type\":\"policy_event\",\"source\":\"carranca\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"policy\":\"filesystem\",\"action\":\"enforced\",\"detail\":\"read-only: ${_esc_enforced}\"}"
    write_log "$FS_EVENT"
  fi
  if [ -n "${DEGRADED_GLOBS:-}" ]; then
    _esc_degraded="$(json_escape "$DEGRADED_GLOBS")"
    FS_DEG_EVENT="{\"type\":\"policy_event\",\"source\":\"carranca\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"policy\":\"filesystem\",\"action\":\"degraded\",\"detail\":\"glob patterns not enforced: ${_esc_degraded}\"}"
    write_log "$FS_DEG_EVENT"
  fi
fi

# Log network policy events (4.1)
if [ "$NETWORK_MODE" = "filtered" ] && [ -n "$NETWORK_POLICY_RULES" ]; then
  _esc_netrules="$(json_escape "$NETWORK_POLICY_RULES")"
  NET_EVENT="{\"type\":\"policy_event\",\"source\":\"carranca\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"policy\":\"network\",\"action\":\"configured\",\"detail\":\"mode:filtered rules:${_esc_netrules}\"}"
  write_log "$NET_EVENT"
fi
if [ -n "${IPV6_SKIPPED_HOSTS:-}" ]; then
  _esc_ipv6hosts="$(json_escape "$IPV6_SKIPPED_HOSTS")"
  IPV6_EVENT="{\"type\":\"policy_event\",\"source\":\"carranca\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"policy\":\"network\",\"action\":\"degraded\",\"detail\":\"IPv6 addresses not enforced for: ${_esc_ipv6hosts} (iptables is IPv4-only)\"}"
  write_log "$IPV6_EVENT"
fi

# --- File event watcher (background, best-effort) ---

# Shared handler: tag watched paths and write to log
_handle_file_event() {
  local line="$1"
  if [ -n "${WATCHED_PATHS:-}" ]; then
    local local_path
    local_path="$(printf '%s' "$line" | grep -o '"path":"[^"]*"' | head -1 | cut -d'"' -f4)"
    if [ -n "$local_path" ] && path_is_watched "$local_path"; then
      if [[ "$line" == *"}" ]]; then
        line="${line%\}},\"watched\":true}"
      fi
    fi
  fi
  write_log "$line"
}

_start_inotifywait() {
  # Output TSV (ts\tevent\tpath) to avoid injecting raw paths into JSON.
  # Post-process each line: parse fields, json_escape the path, then
  # reconstruct proper JSON.
  inotifywait -m -r -e create,modify,delete \
    --format $'%e\t%w%f' \
    /workspace 2>/dev/null | while IFS=$'\t' read -r evt_type evt_path; do
      local escaped_path evt_ts
      escaped_path="$(json_escape "$evt_path")"
      evt_ts="$(timestamp)"
      local line="{\"type\":\"file_event\",\"source\":\"inotifywait\",\"ts\":\"$evt_ts\",\"event\":\"$evt_type\",\"path\":\"$escaped_path\",\"session_id\":\"$SESSION_ID\"}"
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
      local ts escaped_path
      ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
      escaped_path="$(json_escape "$filepath")"
      local line="{\"type\":\"file_event\",\"source\":\"fswatch\",\"ts\":\"$ts\",\"event\":\"$event_type\",\"path\":\"$escaped_path\",\"session_id\":\"$SESSION_ID\"}"
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
      local escaped_path
      escaped_path="$(json_escape "$path")"
      local event="{\"type\":\"file_access_event\",\"source\":\"fanotify\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"path\":\"$escaped_path\",\"pid\":${pid:-0},\"watched\":true}"
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
RESOURCE_MEMORY_LIMIT="${RESOURCE_MEMORY_LIMIT:-}"
MAX_DURATION="${MAX_DURATION:-0}"
ENFORCE_WATCHED_PATHS="${ENFORCE_WATCHED_PATHS:-}"
ENFORCED_PATHS="${ENFORCED_PATHS:-}"
DEGRADED_GLOBS="${DEGRADED_GLOBS:-}"
NETWORK_MODE="${NETWORK_MODE:-full}"
NETWORK_POLICY_RULES="${NETWORK_POLICY_RULES:-}"
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

_read_oom_kill_count() {
  local cgroup_dir="$1"
  local events_file="$cgroup_dir/memory.events"
  [ -f "$events_file" ] || { printf '0'; return; }
  local count
  count="$(awk '$1 == "oom_kill" { print $2 }' "$events_file" 2>/dev/null)"
  printf '%s' "${count:-0}"
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

  local prev_oom_count
  prev_oom_count="$(_read_oom_kill_count "$cgroup_dir")"

  while true; do
    sleep "$interval"
    local stats
    stats="$(_read_cgroup_stats "$cgroup_dir")"
    if [ -n "$stats" ]; then
      local event="{\"type\":\"resource_event\",\"source\":\"carranca\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\"$stats}"
      write_log "$event"
    fi

    # Check for OOM kills
    local cur_oom_count
    cur_oom_count="$(_read_oom_kill_count "$cgroup_dir")"
    if [ "$cur_oom_count" -gt "$prev_oom_count" ] 2>/dev/null; then
      local _esc_memlimit
      _esc_memlimit="$(json_escape "${RESOURCE_MEMORY_LIMIT:-unset}")"
      local oom_event="{\"type\":\"policy_event\",\"source\":\"carranca\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"policy\":\"resource_limits\",\"action\":\"oom_kill\",\"detail\":\"OOM kill detected (limit: ${_esc_memlimit})\"}"
      write_log "$oom_event"
      prev_oom_count="$cur_oom_count"
    fi
  done
}

SAMPLER_PID=""
if [ -n "$AGENT_CONTAINER_NAME" ] && [ "${RESOURCE_INTERVAL:-0}" != "0" ] && [ -n "${RESOURCE_INTERVAL:-}" ]; then
  _start_resource_sampler "$RESOURCE_INTERVAL" "$AGENT_CONTAINER_NAME" &
  SAMPLER_PID=$!
fi

# --- Execve tracer (background, best-effort) ---

# Source shared strace parser (used by both logger and observer)
STRACE_EVENT_SOURCE="strace"
STRACE_WRITE_FIFO=""
# shellcheck source=lib/strace-parser.sh
source "$SCRIPT_DIR/lib/strace-parser.sh"

# Legacy wrapper for backward compatibility
_strace_to_event() {
  strace_line_to_event "$1"
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

# Skip internal tracers when independent observer is active (Phase 5.1)
if [ "${INDEPENDENT_OBSERVER:-}" != "true" ]; then
  _start_execve_tracer &
fi

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
  prev_file="$(mktemp "$CARRANCA_TMPDIR"/carranca-netmon-prev.XXXXXX)"
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
    current_file="$(mktemp "$CARRANCA_TMPDIR"/carranca-netmon-cur.XXXXXX)"
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
if [ "${NETWORK_LOGGING:-}" = "true" ] && [ "${INDEPENDENT_OBSERVER:-}" != "true" ]; then
  _start_network_monitor &
  NETMON_PID=$!
fi

# --- Session timer (4.5 time-boxed sessions) ---

TIMER_PID=""

_start_session_timer() {
  local duration="${MAX_DURATION:-0}"
  [ "$duration" -gt 0 ] 2>/dev/null || return 0

  sleep "$duration"
  TIMEOUT_EVENT="{\"type\":\"policy_event\",\"source\":\"carranca\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"policy\":\"max_duration\",\"action\":\"timeout\",\"detail\":\"session killed after ${duration}s\"}"
  write_log "$TIMEOUT_EVENT"
  # Remove the FIFO to trigger the agent's fail-closed watchdog.
  # The shell-wrapper polls FIFO health every 1s and calls fail_closed()
  # when it disappears, which kills the agent process. That causes the
  # agent container to exit, which unblocks run.sh and triggers its
  # cleanup trap (carranca_session_stop).
  rm -f "$FIFO_PATH"
}

if [ "${MAX_DURATION:-0}" != "0" ] && [ -n "${MAX_DURATION:-}" ]; then
  _start_session_timer &
  TIMER_PID=$!
fi

# --- Cross-reference events (Phase 5.1) ---
# Heuristic comparison of shell_command vs execve_event counts and timing.
# This is a best-effort anomaly signal, not a proof of forgery. A single
# background exec can only satisfy one shell_command (greedy 1:1 matching),
# and timestamp resolution is ±3s, so both false positives and false negatives
# are possible. Integrity events from cross-referencing should be treated as
# indicators for human review, not as definitive evidence.

_cross_reference_events() {
  [ "${INDEPENDENT_OBSERVER:-}" = "true" ] || return 0
  [ -f "$LOG_FILE" ] || return 0

  # Collect shell_command timestamps (epoch) into a temp file for 1:1 consumption
  local cmd_file exec_file
  cmd_file="$(mktemp "$CARRANCA_TMPDIR"/carranca-xref-cmd.XXXXXX)"
  exec_file="$(mktemp "$CARRANCA_TMPDIR"/carranca-xref-exec.XXXXXX)"

  while IFS= read -r line; do
    local ts
    ts="$(printf '%s' "$line" | grep -o '"ts":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    [ -n "$ts" ] && _ts_to_epoch "$ts" >> "$cmd_file"
  done < <(grep '"type":"shell_command"' "$LOG_FILE" 2>/dev/null || true)

  while IFS= read -r line; do
    local ts
    ts="$(printf '%s' "$line" | grep -o '"ts":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    [ -n "$ts" ] && _ts_to_epoch "$ts" >> "$exec_file"
  done < <(grep '"type":"execve_event"' "$LOG_FILE" 2>/dev/null || true)

  # Sort both lists for greedy matching
  sort -n "$cmd_file" -o "$cmd_file"
  sort -n "$exec_file" -o "$exec_file"

  # Greedy 1:1 match: for each shell_command, consume the nearest execve_event
  # within ±3s. Unmatched entries on either side are flagged.
  local matched_exec_file
  matched_exec_file="$(mktemp "$CARRANCA_TMPDIR"/carranca-xref-matched.XXXXXX)"

  while IFS= read -r cmd_t; do
    [ -z "$cmd_t" ] && continue
    local best_line="" best_diff=999999
    local line_num=0
    while IFS= read -r exec_t; do
      line_num=$((line_num + 1))
      [ -z "$exec_t" ] && continue
      # Skip already-consumed exec times
      if grep -q "^${line_num}$" "$matched_exec_file" 2>/dev/null; then
        continue
      fi
      local diff=$((cmd_t - exec_t))
      [ "$diff" -lt 0 ] && diff=$((-diff))
      if [ "$diff" -le 3 ] && [ "$diff" -lt "$best_diff" ]; then
        best_diff="$diff"
        best_line="$line_num"
      fi
    done < "$exec_file"
    if [ -n "$best_line" ]; then
      echo "$best_line" >> "$matched_exec_file"
    else
      local event="{\"type\":\"integrity_event\",\"source\":\"carranca\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"shell_command_without_execve\",\"detail\":\"command at epoch $cmd_t has no matching execve (best-effort heuristic)\"}"
      write_log "$event"
    fi
  done < "$cmd_file"

  # Check for unmatched execve_events
  local line_num=0
  while IFS= read -r exec_t; do
    line_num=$((line_num + 1))
    [ -z "$exec_t" ] && continue
    if ! grep -q "^${line_num}$" "$matched_exec_file" 2>/dev/null; then
      local event="{\"type\":\"integrity_event\",\"source\":\"carranca\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"unmatched_execve_activity\",\"detail\":\"execve at epoch $exec_t has no matching shell_command (best-effort heuristic)\"}"
      write_log "$event"
    fi
  done < "$exec_file"

  rm -f "$cmd_file" "$exec_file" "$matched_exec_file"
}

# --- SIGTERM handler ---

_cleanup() {
  # Cross-reference events before writing logger_stop (Phase 5.1)
  _cross_reference_events

  STOP_EVENT="{\"type\":\"session_event\",\"source\":\"carranca\",\"event\":\"logger_stop\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\"}"
  write_log "$STOP_EVENT"
  [ -n "$TIMER_PID" ] && kill "$TIMER_PID" 2>/dev/null
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
    # Validate FIFO event for forgery indicators (Phase 5.2)
    line="$(_validate_fifo_event "$line")"
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
