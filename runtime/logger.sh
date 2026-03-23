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

# --- SIGTERM handler ---

_cleanup() {
  STOP_EVENT="{\"type\":\"session_event\",\"source\":\"carranca\",\"event\":\"logger_stop\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\"}"
  write_log "$STOP_EVENT"
  [ -n "$WATCHER_PID" ] && kill "$WATCHER_PID" 2>/dev/null
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
