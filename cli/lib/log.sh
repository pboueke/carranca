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
    date -u -r "$log_file" +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || printf '%s' "unknown"
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
  CARRANCA_LOG_WATCHED_EVENTS=0
  CARRANCA_LOG_UNIQUE_PATHS=0
  CARRANCA_LOG_RESOURCE_SAMPLES=0
  CARRANCA_LOG_EXECVE_EVENTS=0
  CARRANCA_LOG_NETWORK_EVENTS=0
  CARRANCA_LOG_ACCESS_EVENTS=0
  CARRANCA_LOG_POLICY_EVENTS=0
  CARRANCA_LOG_FIRST_TS=""
  CARRANCA_LOG_LAST_TS=""
  CARRANCA_LOG_AGENT_NAME=""
  CARRANCA_LOG_ADAPTER=""
  CARRANCA_LOG_ENGINE=""
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
        # Count watched-path events
        if [[ "$line" == *'"watched":true'* ]]; then
          CARRANCA_LOG_WATCHED_EVENTS=$((CARRANCA_LOG_WATCHED_EVENTS + 1))
        fi
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
      resource_event) CARRANCA_LOG_RESOURCE_SAMPLES=$((CARRANCA_LOG_RESOURCE_SAMPLES + 1)) ;;
      execve_event) CARRANCA_LOG_EXECVE_EVENTS=$((CARRANCA_LOG_EXECVE_EVENTS + 1)) ;;
      network_event) CARRANCA_LOG_NETWORK_EVENTS=$((CARRANCA_LOG_NETWORK_EVENTS + 1)) ;;
      file_access_event) CARRANCA_LOG_ACCESS_EVENTS=$((CARRANCA_LOG_ACCESS_EVENTS + 1)) ;;
      policy_event) CARRANCA_LOG_POLICY_EVENTS=$((CARRANCA_LOG_POLICY_EVENTS + 1)) ;;
      session_event)
        ts="$(carranca_json_get_string "$line" "ts")"
        [ -z "$CARRANCA_LOG_FIRST_TS" ] && CARRANCA_LOG_FIRST_TS="$ts"
        CARRANCA_LOG_LAST_TS="$ts"
        event="$(carranca_json_get_string "$line" "event")"
        if [ "$event" = "start" ]; then
          CARRANCA_LOG_AGENT_NAME="$(carranca_json_get_string "$line" "agent")"
          CARRANCA_LOG_ADAPTER="$(carranca_json_get_string "$line" "adapter")"
          CARRANCA_LOG_ENGINE="$(carranca_json_get_string "$line" "engine")"
        fi
        ;;
    esac
  done < "$log_file"

  CARRANCA_LOG_SUCCEEDED_CMDS=$((CARRANCA_LOG_TOTAL_CMDS - CARRANCA_LOG_FAILED_CMDS))
  CARRANCA_LOG_FILES_TOTAL=$((CARRANCA_LOG_FILES_CREATED + CARRANCA_LOG_FILES_MODIFIED + CARRANCA_LOG_FILES_DELETED))
}

carranca_session_print_summary() {
  local log_file="$1"

  carranca_session_collect_stats "$log_file"

  if [ -n "$CARRANCA_LOG_AGENT_NAME" ]; then
    echo "  Agent: $CARRANCA_LOG_AGENT_NAME (adapter: $CARRANCA_LOG_ADAPTER, engine: $CARRANCA_LOG_ENGINE)"
  fi
  echo "  Duration: $CARRANCA_LOG_FIRST_TS → $CARRANCA_LOG_LAST_TS"
  echo "  Unique paths touched: $CARRANCA_LOG_UNIQUE_PATHS"
  echo "  File events: $CARRANCA_LOG_FILE_EVENTS_TOTAL ($CARRANCA_LOG_FILES_CREATED create, $CARRANCA_LOG_FILES_MODIFIED modify, $CARRANCA_LOG_FILES_DELETED delete)"
  if [ "$CARRANCA_LOG_WATCHED_EVENTS" -gt 0 ]; then
    echo "  Watched path events: $CARRANCA_LOG_WATCHED_EVENTS"
  fi
  echo "  Commands run: $CARRANCA_LOG_TOTAL_CMDS ($CARRANCA_LOG_SUCCEEDED_CMDS succeeded, $CARRANCA_LOG_FAILED_CMDS failed)"
  if [ "$CARRANCA_LOG_RESOURCE_SAMPLES" -gt 0 ]; then
    echo "  Resource samples: $CARRANCA_LOG_RESOURCE_SAMPLES"
  fi
  if [ "$CARRANCA_LOG_EXECVE_EVENTS" -gt 0 ]; then
    echo "  Execve events: $CARRANCA_LOG_EXECVE_EVENTS"
  fi
  if [ "$CARRANCA_LOG_NETWORK_EVENTS" -gt 0 ]; then
    echo "  Network events: $CARRANCA_LOG_NETWORK_EVENTS"
  fi
  if [ "$CARRANCA_LOG_ACCESS_EVENTS" -gt 0 ]; then
    echo "  Access events: $CARRANCA_LOG_ACCESS_EVENTS"
  fi
  if [ "$CARRANCA_LOG_POLICY_EVENTS" -gt 0 ]; then
    echo "  Policy events: $CARRANCA_LOG_POLICY_EVENTS"
  fi
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

  local sorted_lines
  sorted_lines="$(printf '%s' "$lines" | sort -t $'\t' -k1,1nr -k2,2)"
  if [ "$limit" -gt 0 ] 2>/dev/null; then
    sorted_lines="$(printf '%s\n' "$sorted_lines" | head -n "$limit")"
  fi

  while IFS=$'\t' read -r count path; do
    [ -z "$path" ] && continue
    create_count="${CARRANCA_LOG_PATH_CREATE_COUNTS[$path]:-0}"
    modify_count="${CARRANCA_LOG_PATH_MODIFY_COUNTS[$path]:-0}"
    delete_count="${CARRANCA_LOG_PATH_DELETE_COUNTS[$path]:-0}"
    printf '  %s (%s events: %s create, %s modify, %s delete)\n' \
      "$path" "$count" "$create_count" "$modify_count" "$delete_count"
  done <<< "$sorted_lines"
}

carranca_session_verify() {
  local log_file="$1"
  local state_base="${2:-${CARRANCA_STATE:-$HOME/.local/state/carranca}}"
  local session_id repo_id key_file hmac_key
  local prev_hmac="0"
  local line seq ts payload hmac_field expected_hmac
  local line_no=0
  local errors=0

  session_id="$(basename "$log_file" .jsonl)"
  repo_id="$(basename "$(dirname "$log_file")")"
  key_file="$state_base/sessions/$repo_id/$session_id.hmac-key"

  if [ ! -f "$key_file" ]; then
    echo "FAIL: HMAC key file not found: $key_file"
    echo "  This session was recorded before HMAC signing was enabled."
    return 1
  fi

  hmac_key="$(cat "$key_file")"

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    line_no=$((line_no + 1))

    # Extract hmac field from the line
    hmac_field="$(carranca_json_get_string "$line" "hmac")"

    # Strip hmac field from line to get payload for re-computation
    # The hmac is always the last field before closing brace
    payload="$(printf '%s' "$line" | sed 's/,"hmac":"[^"]*"//g')"

    seq="$(carranca_json_get_number "$line" "seq")"
    ts="$(carranca_json_get_string "$line" "ts")"

    # Recompute HMAC
    local hmac_input="${prev_hmac}|${seq}|${ts}|${payload}"
    expected_hmac="$(printf '%s' "$hmac_input" | openssl dgst -sha256 -macopt "hexkey:$hmac_key" -hex 2>/dev/null | awk '{print $NF}')"

    if [ "$hmac_field" != "$expected_hmac" ]; then
      echo "FAIL: HMAC mismatch at line $line_no (seq=$seq)"
      echo "  expected: $expected_hmac"
      echo "  got:      $hmac_field"
      errors=$((errors + 1))
    fi
    prev_hmac="$hmac_field"
  done < "$log_file"

  # --- Checksum verification ---
  local checksum_file="${log_file%.jsonl}.checksums"
  if [ -f "$checksum_file" ]; then
    echo "Verifying checksums..."
    local checksum_line_no=0
    local checksum_errors=0
    local log_line expected_hash actual_hash
    local prev_checksum_hash=""

    exec 8< "$checksum_file"
    while IFS= read -r log_line; do
      [ -z "$log_line" ] && continue
      checksum_line_no=$((checksum_line_no + 1))
      if IFS= read -r expected_hash <&8; then
        # Chained checksum: hash includes previous checksum hash (empty for first entry)
        actual_hash="$(printf '%s' "${prev_checksum_hash}${log_line}" | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}')"
        if [ "$actual_hash" != "$expected_hash" ]; then
          # Fall back to unchained hash for backward compatibility with older sessions
          local unchained_hash
          unchained_hash="$(printf '%s' "$log_line" | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}')"
          if [ "$unchained_hash" = "$expected_hash" ]; then
            # Older session without chained checksums — reset chain tracking
            prev_checksum_hash="$expected_hash"
            continue
          fi
          echo "FAIL: Checksum mismatch at line $checksum_line_no (seq=$(carranca_json_get_number "$log_line" "seq"))"
          echo "  expected: $expected_hash"
          echo "  got:      $actual_hash"
          checksum_errors=$((checksum_errors + 1))
        fi
        prev_checksum_hash="$expected_hash"
      else
        echo "WARN: Checksum file has fewer entries than log ($checksum_line_no < $line_no)"
        checksum_errors=$((checksum_errors + 1))
      fi
    done < "$log_file"
    exec 8<&-

    if [ "$checksum_line_no" -ne "$line_no" ]; then
      echo "WARN: Checksum file has $checksum_line_no entries, log has $line_no entries"
    fi

    if [ "$checksum_errors" -gt 0 ]; then
      errors=$((errors + checksum_errors))
    fi
  else
    echo "No checksum file found (session predates checksum hardening)"
  fi

  if [ "$errors" -eq 0 ]; then
    echo "OK: $line_no events verified, chain intact"
    return 0
  else
    echo "FAIL: $errors integrity error(s) in $line_no events"
    return 1
  fi
}

carranca_session_export() {
  local log_file="$1"
  local state_base="${2:-${CARRANCA_STATE:-$HOME/.local/state/carranca}}"
  local session_id repo_id key_file checksum_file
  local archive_dir archive_tar sig_file

  session_id="$(basename "$log_file" .jsonl)"
  repo_id="$(basename "$(dirname "$log_file")")"
  key_file="$state_base/sessions/$repo_id/$session_id.hmac-key"
  checksum_file="$state_base/sessions/$repo_id/$session_id.checksums"

  # Build archive in a temp directory
  archive_dir="$(mktemp -d)"
  local bundle_dir="$archive_dir/$session_id"
  mkdir -p "$bundle_dir"

  # Copy session files into the bundle
  cp "$log_file" "$bundle_dir/"
  [ -f "$key_file" ] && cp "$key_file" "$bundle_dir/"
  [ -f "$checksum_file" ] && cp "$checksum_file" "$bundle_dir/"

  # Create tar archive
  archive_tar="$state_base/sessions/$repo_id/$session_id.tar"
  tar -cf "$archive_tar" -C "$archive_dir" "$session_id"

  # Create detached HMAC signature
  # The archive signature proves consistency with the session's HMAC chain,
  # not independent authenticity. The HMAC key lives alongside the log in
  # /state/, so anyone with /state/ access can produce valid signatures.
  # For true non-repudiation, asymmetric signing (ed25519) with an external
  # key would be needed.
  sig_file="${archive_tar}.sig"
  if [ -f "$key_file" ]; then
    local hmac_key
    hmac_key="$(cat "$key_file")"
    openssl dgst -sha256 -macopt "hexkey:$hmac_key" -hex "$archive_tar" 2>/dev/null \
      | awk '{print $NF}' > "$sig_file"
  else
    # No HMAC key — write SHA-256 hash as unsigned digest
    openssl dgst -sha256 -hex "$archive_tar" 2>/dev/null \
      | awk '{print $NF}' > "$sig_file"
    echo "WARN: No HMAC key found; signature is an unsigned SHA-256 digest"
  fi

  rm -rf "$archive_dir"

  echo "Exported: $archive_tar"
  echo "Signature: $sig_file"
  return 0
}
