#!/usr/bin/env bash
# carranca kill — stop active carranca sessions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/runtime.sh"
source "$SCRIPT_DIR/lib/session.sh"

SESSION_ID=""

confirm_kill() {
  local prompt="$1"
  local reply

  printf '%s [y/N] ' "$prompt" >&2
  read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    help|-h|--help)
      echo "Usage: carranca kill [--session <exact-id>]"
      echo ""
      echo "  Stop active carranca sessions."
      echo "  Without --session, stops all active sessions globally after confirmation."
      echo ""
      echo "Options:"
      echo "  --session <id>  Stop a specific session by exact id after confirmation"
      exit 0
      ;;
    --session)
      shift
      [ "$#" -gt 0 ] || carranca_die "Missing value for --session"
      SESSION_ID="$1"
      ;;
    *)
      carranca_die "Unknown argument: $1"
      ;;
  esac
  shift
done

carranca_runtime_require

if [ -n "$SESSION_ID" ]; then
  if ! confirm_kill "Stop session $SESSION_ID?"; then
    carranca_log warn "Cancelled"
    exit 0
  fi

  if ! carranca_session_is_active "$SESSION_ID"; then
    carranca_log warn "Session $SESSION_ID is not active or was not found"
    exit 0
  fi

  carranca_session_stop "$SESSION_ID"
  carranca_log ok "Stopped session $SESSION_ID"
  exit 0
fi

ACTIVE_IDS="$(carranca_session_global_active_ids)"
if [ -z "$ACTIVE_IDS" ]; then
  carranca_log warn "No active sessions found"
  exit 0
fi

ACTIVE_COUNT="$(printf '%s\n' "$ACTIVE_IDS" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
if ! confirm_kill "Stop all $ACTIVE_COUNT active session(s)?"; then
  carranca_log warn "Cancelled"
  exit 0
fi

while IFS= read -r active_session_id; do
  [ -n "$active_session_id" ] || continue
  if carranca_session_is_active "$active_session_id"; then
    carranca_session_stop "$active_session_id"
    carranca_log ok "Stopped session $active_session_id"
  else
    carranca_log warn "Session $active_session_id is not active or was not found"
  fi
done <<< "$ACTIVE_IDS"
