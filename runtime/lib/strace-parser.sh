#!/usr/bin/env bash
# carranca/runtime/lib/strace-parser.sh — shared strace execve output parser
# Sourced by both logger.sh (legacy path) and observer.sh (independent observer).
#
# Requires: $SESSION_ID, timestamp(), write_log() or a FIFO_PATH to be set by the caller.
# The caller sets STRACE_EVENT_SOURCE to control the "source" field in events.

STRACE_EVENT_SOURCE="${STRACE_EVENT_SOURCE:-strace}"

# Parse a single strace output line and emit an execve_event.
# Usage: strace_line_to_event "$line"
# Writes to FIFO if STRACE_WRITE_FIFO is set, otherwise calls write_log().
strace_line_to_event() {
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

  local token_field=""
  if [ -n "${OBSERVER_TOKEN:-}" ]; then
    token_field=",\"_observer_token\":\"$OBSERVER_TOKEN\""
  fi

  local event="{\"type\":\"execve_event\",\"source\":\"$STRACE_EVENT_SOURCE\",\"ts\":\"$(timestamp)\",\"session_id\":\"$SESSION_ID\",\"pid\":$pid,\"binary\":\"$binary\",\"argv\":\"$argv_str\"$token_field}"

  if [ "${STRACE_WRITE_FIFO:-}" = "true" ] && [ -p "${FIFO_PATH:-}" ]; then
    printf '%s\n' "$event" > "$FIFO_PATH"
  else
    write_log "$event"
  fi
}
