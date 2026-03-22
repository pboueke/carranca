#!/usr/bin/env bash
# carranca/cli/lib/log.sh — Session log discovery and pretty-print helpers

carranca_session_log_dir() {
  local repo_id="$1"
  local state_base="${2:-${CARRANCA_STATE:-$HOME/.local/state/carranca}}"
  printf '%s' "$state_base/sessions/$repo_id"
}

carranca_session_latest_log() {
  local repo_id="$1"
  local state_base="${2:-${CARRANCA_STATE:-$HOME/.local/state/carranca}}"
  local log_dir

  log_dir="$(carranca_session_log_dir "$repo_id" "$state_base")"
  find "$log_dir" -maxdepth 1 -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | \
    sort -nr | head -1 | cut -d' ' -f2-
}

carranca_session_log_for_id() {
  local repo_id="$1"
  local session_id="$2"
  local state_base="${3:-${CARRANCA_STATE:-$HOME/.local/state/carranca}}"
  printf '%s' "$(carranca_session_log_dir "$repo_id" "$state_base")/$session_id.jsonl"
}

carranca_session_recent_logs() {
  local repo_id="$1"
  local limit="${2:-5}"
  local state_base="${3:-${CARRANCA_STATE:-$HOME/.local/state/carranca}}"
  local log_dir

  log_dir="$(carranca_session_log_dir "$repo_id" "$state_base")"
  find "$log_dir" -maxdepth 1 -type f -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null | \
    sort -nr | head -n "$limit" | cut -d' ' -f2-
}

carranca_session_active_ids() {
  local repo_id="$1"
  local state_base="${2:-${CARRANCA_STATE:-$HOME/.local/state/carranca}}"
  local log_file
  local session_id

  while IFS= read -r log_file; do
    [ -n "$log_file" ] || continue
    session_id="$(basename "$log_file" .jsonl)"
    if carranca_session_is_active "$session_id"; then
      printf '%s\n' "$session_id"
    fi
  done < <(carranca_session_recent_logs "$repo_id" 999999 "$state_base")
}

carranca_session_display_ts() {
  local log_file="$1"
  local ts

  ts="$(awk 'match($0, /"ts":"[^"]+"/) { print substr($0, RSTART + 6, RLENGTH - 7); exit }' "$log_file" 2>/dev/null)"
  if [ -n "$ts" ]; then
    printf '%s' "$ts"
  else
    date -u -r "$log_file" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '%s' "unknown"
  fi
}

carranca_json_get_string() {
  local line="$1"
  local key="$2"

  printf '%s\n' "$line" | awk -v key="$key" '
    function extract(line, key,    pattern, pos, rest, i, c, out, esc) {
      pattern = "\"" key "\":\""
      pos = index(line, pattern)
      if (!pos) return ""
      rest = substr(line, pos + length(pattern))
      out = ""
      esc = 0
      for (i = 1; i <= length(rest); i++) {
        c = substr(rest, i, 1)
        if (esc) {
          out = out c
          esc = 0
          continue
        }
        if (c == "\\") {
          esc = 1
          out = out c
          continue
        }
        if (c == "\"") break
        out = out c
      }
      return out
    }
    { print extract($0, key) }
  '
}

carranca_json_get_number() {
  local line="$1"
  local key="$2"
  printf '%s\n' "$line" | grep -o "\"$key\":[0-9]*" | head -1 | cut -d: -f2
}

carranca_session_collect_stats() {
  local log_file="$1"
  local line type event exit_code ts path

  CARRANCA_LOG_SESSION_ID="$(basename "$log_file" .jsonl)"
  CARRANCA_LOG_TOTAL_CMDS=0
  CARRANCA_LOG_FAILED_CMDS=0
  CARRANCA_LOG_FILES_CREATED=0
  CARRANCA_LOG_FILES_MODIFIED=0
  CARRANCA_LOG_FILES_DELETED=0
  CARRANCA_LOG_FILE_EVENTS_TOTAL=0
  CARRANCA_LOG_UNIQUE_PATHS=0
  CARRANCA_LOG_FIRST_TS=""
  CARRANCA_LOG_LAST_TS=""
  CARRANCA_LOG_COMMAND_LINES=()
  declare -gA CARRANCA_LOG_PATH_COUNTS=()
  declare -gA CARRANCA_LOG_PATH_CREATE_COUNTS=()
  declare -gA CARRANCA_LOG_PATH_MODIFY_COUNTS=()
  declare -gA CARRANCA_LOG_PATH_DELETE_COUNTS=()

  while IFS= read -r line; do
    type="$(carranca_json_get_string "$line" "type")"
    case "$type" in
      shell_command)
        CARRANCA_LOG_TOTAL_CMDS=$((CARRANCA_LOG_TOTAL_CMDS + 1))
        exit_code="$(carranca_json_get_number "$line" "exit_code")"
        [ -z "$exit_code" ] && exit_code=0
        [ "$exit_code" != "0" ] && CARRANCA_LOG_FAILED_CMDS=$((CARRANCA_LOG_FAILED_CMDS + 1))
        CARRANCA_LOG_COMMAND_LINES+=("$line")
        ;;
      file_event)
        CARRANCA_LOG_FILE_EVENTS_TOTAL=$((CARRANCA_LOG_FILE_EVENTS_TOTAL + 1))
        event="$(carranca_json_get_string "$line" "event")"
        path="$(carranca_json_get_string "$line" "path")"
        if [ -n "$path" ] && [ -z "${CARRANCA_LOG_PATH_COUNTS[$path]+x}" ]; then
          CARRANCA_LOG_UNIQUE_PATHS=$((CARRANCA_LOG_UNIQUE_PATHS + 1))
          CARRANCA_LOG_PATH_COUNTS["$path"]=0
          CARRANCA_LOG_PATH_CREATE_COUNTS["$path"]=0
          CARRANCA_LOG_PATH_MODIFY_COUNTS["$path"]=0
          CARRANCA_LOG_PATH_DELETE_COUNTS["$path"]=0
        fi
        if [ -n "$path" ]; then
          CARRANCA_LOG_PATH_COUNTS["$path"]=$((CARRANCA_LOG_PATH_COUNTS["$path"] + 1))
        fi
        case "$event" in
          CREATE)
            CARRANCA_LOG_FILES_CREATED=$((CARRANCA_LOG_FILES_CREATED + 1))
            [ -n "$path" ] && CARRANCA_LOG_PATH_CREATE_COUNTS["$path"]=$((CARRANCA_LOG_PATH_CREATE_COUNTS["$path"] + 1))
            ;;
          MODIFY)
            CARRANCA_LOG_FILES_MODIFIED=$((CARRANCA_LOG_FILES_MODIFIED + 1))
            [ -n "$path" ] && CARRANCA_LOG_PATH_MODIFY_COUNTS["$path"]=$((CARRANCA_LOG_PATH_MODIFY_COUNTS["$path"] + 1))
            ;;
          DELETE)
            CARRANCA_LOG_FILES_DELETED=$((CARRANCA_LOG_FILES_DELETED + 1))
            [ -n "$path" ] && CARRANCA_LOG_PATH_DELETE_COUNTS["$path"]=$((CARRANCA_LOG_PATH_DELETE_COUNTS["$path"] + 1))
            ;;
        esac
        ;;
      session_event)
        ts="$(carranca_json_get_string "$line" "ts")"
        [ -z "$CARRANCA_LOG_FIRST_TS" ] && CARRANCA_LOG_FIRST_TS="$ts"
        CARRANCA_LOG_LAST_TS="$ts"
        ;;
    esac
  done < "$log_file"

  CARRANCA_LOG_SUCCEEDED_CMDS=$((CARRANCA_LOG_TOTAL_CMDS - CARRANCA_LOG_FAILED_CMDS))
  CARRANCA_LOG_FILES_TOTAL=$((CARRANCA_LOG_FILES_CREATED + CARRANCA_LOG_FILES_MODIFIED + CARRANCA_LOG_FILES_DELETED))
}

carranca_session_print_summary() {
  local log_file="$1"

  carranca_session_collect_stats "$log_file"

  echo "  Duration: $CARRANCA_LOG_FIRST_TS → $CARRANCA_LOG_LAST_TS"
  echo "  Unique paths touched: $CARRANCA_LOG_UNIQUE_PATHS"
  echo "  File events: $CARRANCA_LOG_FILE_EVENTS_TOTAL ($CARRANCA_LOG_FILES_CREATED create, $CARRANCA_LOG_FILES_MODIFIED modify, $CARRANCA_LOG_FILES_DELETED delete)"
  echo "  Commands run: $CARRANCA_LOG_TOTAL_CMDS ($CARRANCA_LOG_SUCCEEDED_CMDS succeeded, $CARRANCA_LOG_FAILED_CMDS failed)"
  echo "  Action log: $log_file"
  if [ "$CARRANCA_LOG_TOTAL_CMDS" -eq 0 ] && [ "$CARRANCA_LOG_FILE_EVENTS_TOTAL" -gt 0 ]; then
    echo "  Command capture: none recorded; changes likely came from agent-native edit/tool operations"
  fi
}

carranca_session_print_commands() {
  local line command exit_code duration_ms index=1

  if [ "${#CARRANCA_LOG_COMMAND_LINES[@]}" -eq 0 ]; then
    echo "Commands:"
    echo "  (none)"
    return
  fi

  echo "Commands:"
  for line in "${CARRANCA_LOG_COMMAND_LINES[@]}"; do
    command="$(carranca_json_get_string "$line" "command")"
    exit_code="$(carranca_json_get_number "$line" "exit_code")"
    duration_ms="$(carranca_json_get_number "$line" "duration_ms")"
    [ -z "$exit_code" ] && exit_code=0
    [ -z "$duration_ms" ] && duration_ms=0
    printf '  %d. [%s, %sms] %s\n' "$index" "$exit_code" "$duration_ms" "$command"
    index=$((index + 1))
  done
}

carranca_session_print_top_paths() {
  local limit="${1:-10}"
  local path
  local lines=""
  local count create_count modify_count delete_count

  echo "Top touched paths:"
  if [ "$CARRANCA_LOG_UNIQUE_PATHS" -eq 0 ]; then
    echo "  (none)"
    return
  fi

  for path in "${!CARRANCA_LOG_PATH_COUNTS[@]}"; do
    lines="${lines}${CARRANCA_LOG_PATH_COUNTS[$path]}"$'\t'"$path"$'\n'
  done

  while IFS=$'\t' read -r count path; do
    [ -z "$path" ] && continue
    create_count="${CARRANCA_LOG_PATH_CREATE_COUNTS[$path]:-0}"
    modify_count="${CARRANCA_LOG_PATH_MODIFY_COUNTS[$path]:-0}"
    delete_count="${CARRANCA_LOG_PATH_DELETE_COUNTS[$path]:-0}"
    printf '  %s (%s events: %s create, %s modify, %s delete)\n' \
      "$path" "$count" "$create_count" "$modify_count" "$delete_count"
  done < <(printf '%s' "$lines" | sort -t $'\t' -k1,1nr -k2,2 | head -n "$limit")
}
