#!/usr/bin/env bash
# carranca status — show active sessions and recent logs for the current repo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/identity.sh"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/session.sh"

STATE_BASE="${CARRANCA_STATE:-$HOME/.local/state/carranca}"
RECENT_LIMIT=5
SESSION_ID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    help|-h|--help)
      echo "Usage: carranca status [--session <exact-id>]"
      echo ""
      echo "  Show active carranca sessions and the 5 most recent session logs"
      echo "  for the current repository."
      echo "  Use --session to show detailed status for a specific session."
      echo ""
      echo "Options:"
      echo "  --session <id>  Show detailed status for a specific session by exact id"
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

REPO_ID="$(carranca_repo_id)"
REPO_NAME="$(carranca_repo_name)"

echo "Repo: $REPO_NAME ($REPO_ID)"

if [ -n "$SESSION_ID" ]; then
  LOG_FILE="$(carranca_session_log_for_id "$REPO_ID" "$SESSION_ID" "$STATE_BASE")"
  [ -f "$LOG_FILE" ] || carranca_die "No session log found for repo $REPO_NAME ($REPO_ID) with id: $SESSION_ID"

  if command -v docker >/dev/null 2>&1 && carranca_session_is_active "$SESSION_ID"; then
    SESSION_STATE="active"
  else
    SESSION_STATE="inactive"
  fi

  carranca_session_collect_stats "$LOG_FILE"

  echo "Session: $SESSION_ID"
  echo "Status: $SESSION_STATE"
  echo ""
  carranca_session_print_summary "$LOG_FILE"
  echo ""
  carranca_session_print_top_paths
  echo ""
  carranca_session_print_commands
else
  echo ""
  echo "Active sessions:"

  if command -v docker >/dev/null 2>&1; then
    ACTIVE_IDS="$(carranca_session_active_ids "$REPO_ID" "$STATE_BASE")"
  else
    ACTIVE_IDS=""
  fi

  if [ -z "$ACTIVE_IDS" ]; then
    echo "  (none)"
  else
    while IFS= read -r session_id; do
      [ -n "$session_id" ] || continue
      log_file="$(carranca_session_log_for_id "$REPO_ID" "$session_id" "$STATE_BASE")"
      ts="$(carranca_session_display_ts "$log_file")"
      printf '  %s (%s)\n' "$session_id" "$ts"
    done <<< "$ACTIVE_IDS"
  fi

  echo ""
  echo "Recent sessions:"

  RECENT_LOGS="$(carranca_session_recent_logs "$REPO_ID" "$RECENT_LIMIT" "$STATE_BASE")"
  if [ -z "$RECENT_LOGS" ]; then
    echo "  (none)"
  else
    while IFS= read -r log_file; do
      [ -n "$log_file" ] || continue
      session_id="$(basename "$log_file" .jsonl)"
      ts="$(carranca_session_display_ts "$log_file")"
      printf '  %s (%s) %s\n' "$session_id" "$ts" "$log_file"
    done <<< "$RECENT_LOGS"
  fi
fi
