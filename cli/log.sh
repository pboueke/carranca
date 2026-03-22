#!/usr/bin/env bash
# carranca log — pretty-print the latest or selected session log
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/identity.sh"
source "$SCRIPT_DIR/lib/log.sh"

STATE_BASE="${CARRANCA_STATE:-$HOME/.local/state/carranca}"
SESSION_ID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    help)
      echo "Usage: carranca log [--session <exact-id>]"
      echo ""
      echo "  Pretty-print the latest session log for the current repository."
      echo "  Use --session to print a specific session by exact id."
      echo ""
      echo "Options:"
      echo "  --session <id>  Show a specific session log by exact id"
      exit 0
      ;;
    --session)
      shift
      [ "$#" -gt 0 ] || carranca_die "Missing value for --session"
      SESSION_ID="$1"
      ;;
    -h|--help)
      echo "Usage: carranca log [--session <exact-id>]"
      echo ""
      echo "  Pretty-print the latest session log for the current repository."
      echo "  Use --session to print a specific session by exact id."
      echo ""
      echo "Options:"
      echo "  --session <id>  Show a specific session log by exact id"
      exit 0
      ;;
    *)
      carranca_die "Unknown argument: $1"
      ;;
  esac
  shift
done

REPO_ID="$(carranca_repo_id)"
REPO_NAME="$(carranca_repo_name)"
LOG_DIR="$(carranca_session_log_dir "$REPO_ID" "$STATE_BASE")"

if [ -n "$SESSION_ID" ]; then
  LOG_FILE="$(carranca_session_log_for_id "$REPO_ID" "$SESSION_ID" "$STATE_BASE")"
  [ -f "$LOG_FILE" ] || carranca_die "No session log found for repo $REPO_NAME ($REPO_ID) with id: $SESSION_ID"
else
  LOG_FILE="$(carranca_session_latest_log "$REPO_ID" "$STATE_BASE")"
  [ -n "$LOG_FILE" ] || carranca_die "No session logs found for repo $REPO_NAME ($REPO_ID)"
fi

carranca_session_collect_stats "$LOG_FILE"

echo "Session: $CARRANCA_LOG_SESSION_ID"
echo "Repo: $REPO_NAME ($REPO_ID)"
echo ""
carranca_session_print_summary "$LOG_FILE"
echo ""
carranca_session_print_top_paths
echo ""
carranca_session_print_commands
