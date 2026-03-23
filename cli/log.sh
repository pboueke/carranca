#!/usr/bin/env bash
# carranca log — pretty-print the latest or selected session log
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/identity.sh"
source "$SCRIPT_DIR/lib/log.sh"

STATE_BASE="${CARRANCA_STATE:-$HOME/.local/state/carranca}"
SESSION_ID=""
FILES_ONLY=false
COMMANDS_ONLY=false
TOP_N=""
VERIFY=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    help)
      echo "Usage: carranca log [--session <exact-id>] [--files-only] [--commands-only] [--top <n>]"
      echo ""
      echo "  Pretty-print the latest session log for the current repository."
      echo "  Use --session to print a specific session by exact id."
      echo ""
      echo "Options:"
      echo "  --session <id>    Show a specific session log by exact id"
      echo "  --files-only      Show only the touched file paths"
      echo "  --commands-only   Show only the executed commands"
      echo "  --top <n>         Limit top touched paths to n entries"
      echo "  --verify          Verify HMAC chain integrity and detect log tampering"
      exit 0
      ;;
    --session)
      shift
      [ "$#" -gt 0 ] || carranca_die "Missing value for --session"
      SESSION_ID="$1"
      ;;
    --files-only)
      FILES_ONLY=true
      ;;
    --commands-only)
      COMMANDS_ONLY=true
      ;;
    --top)
      shift
      [ "$#" -gt 0 ] || carranca_die "Missing value for --top"
      TOP_N="$1"
      ;;
    --verify)
      VERIFY=true
      ;;
    -h|--help)
      echo "Usage: carranca log [--session <exact-id>] [--files-only] [--commands-only] [--top <n>]"
      echo ""
      echo "  Pretty-print the latest session log for the current repository."
      echo "  Use --session to print a specific session by exact id."
      echo ""
      echo "Options:"
      echo "  --session <id>    Show a specific session log by exact id"
      echo "  --files-only      Show only the touched file paths"
      echo "  --commands-only   Show only the executed commands"
      echo "  --top <n>         Limit top touched paths to n entries"
      echo "  --verify          Verify HMAC chain integrity and detect log tampering"
      exit 0
      ;;
    *)
      carranca_die "Unknown argument: $1"
      ;;
  esac
  shift
done

if [ "$FILES_ONLY" = true ] && [ "$COMMANDS_ONLY" = true ]; then
  carranca_die "--files-only and --commands-only are mutually exclusive"
fi

if [ "$VERIFY" = true ]; then
  carranca_session_verify "$LOG_FILE" "$STATE_BASE"
  exit $?
fi

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

if [ "$FILES_ONLY" = true ]; then
  carranca_session_print_top_paths "${TOP_N:-0}"
elif [ "$COMMANDS_ONLY" = true ]; then
  carranca_session_print_commands
else
  echo "Session: $CARRANCA_LOG_SESSION_ID"
  echo "Repo: $REPO_NAME ($REPO_ID)"
  echo ""
  carranca_session_print_summary "$LOG_FILE"
  echo ""
  carranca_session_print_top_paths "${TOP_N:-10}"
  echo ""
  carranca_session_print_commands
fi
