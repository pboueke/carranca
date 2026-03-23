#!/usr/bin/env bash
# carranca/cli/lib/timeline.sh — ASCII timeline renderer for session logs

carranca_session_render_timeline() {
  local log_file="$1"
  local session_id
  session_id="$(basename "$log_file" .jsonl)"

  local line type event ts source path command exit_code duration_ms
  local binary pid dest_ip dest_port protocol state reason
  local cpu_usage_us memory_bytes pids_count
  local time_part glyph detail
  local total_cmds=0 total_files=0 total_failures=0 total_events=0
  local first_ts="" last_ts=""
  local agent_name="" adapter="" engine=""

  echo "Timeline: session $session_id"
  echo "──────────────────────────────────────────────────────────────"
  printf '%-17s %s\n' "TIME" "EVENT"
  echo "──────────────────────────────────────────────────────────────"

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    total_events=$((total_events + 1))

    type="$(carranca_json_get_string "$line" "type")"
    ts="$(carranca_json_get_string "$line" "ts")"

    [ -z "$first_ts" ] && first_ts="$ts"
    last_ts="$ts"

    # Extract HH:MM:SS from ISO timestamp
    time_part="$(printf '%s' "$ts" | grep -o '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]' | head -1)"
    [ -z "$time_part" ] && time_part="??:??:??"

    glyph="?"
    detail="$type"

    case "$type" in
      session_event)
        event="$(carranca_json_get_string "$line" "event")"
        case "$event" in
          start)
            glyph=">>"
            agent_name="$(carranca_json_get_string "$line" "agent")"
            adapter="$(carranca_json_get_string "$line" "adapter")"
            engine="$(carranca_json_get_string "$line" "engine")"
            detail="session start ($agent_name via $engine)"
            ;;
          agent_start)
            glyph=">>"
            detail="agent start"
            ;;
          agent_stop)
            glyph="<<"
            exit_code="$(carranca_json_get_number "$line" "exit_code")"
            detail="agent stop (exit=$exit_code)"
            ;;
          logger_stop)
            glyph="<<"
            detail="logger stop"
            ;;
          degraded)
            glyph="!!"
            reason="$(carranca_json_get_string "$line" "reason")"
            detail="degraded: $reason"
            ;;
          *)
            glyph=">>"
            detail="$event"
            ;;
        esac
        ;;
      shell_command)
        glyph=" $"
        command="$(carranca_json_get_string "$line" "command")"
        exit_code="$(carranca_json_get_number "$line" "exit_code")"
        duration_ms="$(carranca_json_get_number "$line" "duration_ms")"
        [ -z "$exit_code" ] && exit_code=0
        [ -z "$duration_ms" ] && duration_ms=0
        detail="$command (exit=$exit_code, ${duration_ms}ms)"
        total_cmds=$((total_cmds + 1))
        [ "$exit_code" != "0" ] && total_failures=$((total_failures + 1))
        ;;
      file_event)
        event="$(carranca_json_get_string "$line" "event")"
        path="$(carranca_json_get_string "$line" "path")"
        case "$event" in
          CREATE) glyph="F+" ;;
          MODIFY) glyph="F~" ;;
          DELETE) glyph="F-" ;;
          *)      glyph="F?" ;;
        esac
        detail="$path $event"
        if [[ "$line" == *'"watched":true'* ]]; then
          detail="$detail [watched]"
        fi
        total_files=$((total_files + 1))
        ;;
      heartbeat)
        glyph=" ."
        detail="heartbeat"
        ;;
      execve_event)
        glyph=" X"
        binary="$(carranca_json_get_string "$line" "binary")"
        pid="$(carranca_json_get_number "$line" "pid")"
        detail="$binary (pid=$pid)"
        ;;
      network_event)
        glyph=" N"
        dest_ip="$(carranca_json_get_string "$line" "dest_ip")"
        dest_port="$(carranca_json_get_number "$line" "dest_port")"
        protocol="$(carranca_json_get_string "$line" "protocol")"
        state="$(carranca_json_get_string "$line" "state")"
        detail="$dest_ip:$dest_port $protocol $state"
        ;;
      resource_event)
        glyph=" R"
        cpu_usage_us="$(carranca_json_get_number "$line" "cpu_usage_us")"
        memory_bytes="$(carranca_json_get_number "$line" "memory_bytes")"
        pids_count="$(carranca_json_get_number "$line" "pids")"
        detail="cpu=${cpu_usage_us}us mem=${memory_bytes}B pids=${pids_count}"
        ;;
      file_access_event)
        glyph=" A"
        path="$(carranca_json_get_string "$line" "path")"
        detail="$path read"
        ;;
      invalid_event)
        glyph="??"
        detail="invalid event"
        ;;
      *)
        glyph=" ?"
        detail="$type"
        ;;
    esac

    printf '%s  %2s  %s\n' "$time_part" "$glyph" "$detail"
  done < "$log_file"

  echo "──────────────────────────────────────────────────────────────"

  # Duration calculation
  local duration_str="unknown"
  if [ -n "$first_ts" ] && [ -n "$last_ts" ]; then
    local start_epoch end_epoch diff_s
    start_epoch="$(date -d "$first_ts" +%s 2>/dev/null || true)"
    end_epoch="$(date -d "$last_ts" +%s 2>/dev/null || true)"
    if [ -n "$start_epoch" ] && [ -n "$end_epoch" ]; then
      diff_s=$((end_epoch - start_epoch))
      if [ "$diff_s" -ge 3600 ]; then
        duration_str="$((diff_s / 3600))h $((diff_s % 3600 / 60))m $((diff_s % 60))s"
      elif [ "$diff_s" -ge 60 ]; then
        duration_str="$((diff_s / 60))m $((diff_s % 60))s"
      else
        duration_str="${diff_s}s"
      fi
    fi
  fi

  printf 'Duration: %s | %d commands | %d file events | %d failures\n' \
    "$duration_str" "$total_cmds" "$total_files" "$total_failures"
}
