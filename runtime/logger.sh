#!/usr/bin/env bash
# carranca logger — reads events from FIFO + inotifywait, writes JSONL session log
#
# This script is the ENTRYPOINT of the logger container. It:
# 1. Creates the FIFO on the shared tmpfs
# 2. Sets chattr +a on the log file (degrades gracefully)
# 3. Starts inotifywait in background (degrades gracefully)
# 4. Reads FIFO events in foreground
# 5. Merges all events with monotonic seq numbers into the JSONL log
# 6. On SIGTERM: writes logger_stop event and exits
set -uo pipefail

FIFO_PATH="/fifo/events"
SESSION_ID="${SESSION_ID:-unknown}"
REPO_ID="${REPO_ID:-unknown}"
REPO_NAME="${REPO_NAME:-unknown}"
REPO_PATH="${REPO_PATH:-unknown}"
LOG_FILE="/state/${SESSION_ID}.jsonl"
SEQ_FILE="/tmp/carranca-seq"
SEQ_LOCK="/tmp/carranca-seq.lock"

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
    # Inject seq into the JSON object (append before closing brace)
    printf '%s\n' "${line%\}},\"seq\":$seq}" >> "$LOG_FILE"
  } 9>"$SEQ_LOCK"
}

# --- Setup ---

# Initialize seq counter
echo "0" > "$SEQ_FILE"

# Create FIFO
mkfifo "$FIFO_PATH"
chmod 0666 "$FIFO_PATH"

# Create log file and try to make it append-only
touch "$LOG_FILE"
if chattr +a "$LOG_FILE" 2>/dev/null; then
  APPEND_ONLY=true
else
  APPEND_ONLY=false
fi

# Write session start event
START_EVENT="{\"type\":\"session_event\",\"source\":\"carranca\",\"event\":\"start\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"repo_id\":\"$REPO_ID\",\"repo_name\":\"$REPO_NAME\",\"repo_path\":\"$REPO_PATH\",\"adapter\":\"default\"}"
write_log "$START_EVENT"

# Log degraded mode for append-only if needed
if [ "$APPEND_ONLY" = false ]; then
  DEG_EVENT="{\"type\":\"session_event\",\"source\":\"carranca\",\"event\":\"degraded\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"append_only_unavailable\"}"
  write_log "$DEG_EVENT"
fi

# --- inotifywait (background, best-effort) ---

INOTIFY_PID=""
if command -v inotifywait >/dev/null 2>&1; then
  inotifywait -m -r -e create,modify,delete \
    --format '{"type":"file_event","source":"inotifywait","ts":"%T","event":"%e","path":"%w%f","session_id":"'"$SESSION_ID"'"}' \
    --timefmt '%Y-%m-%dT%H:%M:%SZ' \
    /workspace 2>/dev/null | while IFS= read -r line; do
      write_log "$line"
    done &
  INOTIFY_PID=$!
else
  DEG_EVENT="{\"type\":\"session_event\",\"source\":\"carranca\",\"event\":\"degraded\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"reason\":\"inotifywait_unavailable\"}"
  write_log "$DEG_EVENT"
fi

# --- SIGTERM handler ---

_cleanup() {
  STOP_EVENT="{\"type\":\"session_event\",\"source\":\"carranca\",\"event\":\"logger_stop\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\"}"
  write_log "$STOP_EVENT"
  [ -n "$INOTIFY_PID" ] && kill "$INOTIFY_PID" 2>/dev/null
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
