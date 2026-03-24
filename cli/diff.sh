#!/usr/bin/env bash
# carranca diff — compare two session logs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/identity.sh"
source "$SCRIPT_DIR/lib/log.sh"

STATE_BASE="${CARRANCA_STATE:-$HOME/.local/state/carranca}"
SESSION_A=""
SESSION_B=""
REPO_A=""
REPO_B=""
PRETTY=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    help|-h|--help)
      echo "Usage: carranca diff <session-a> <session-b> [--pretty] [--repo-a <id>] [--repo-b <id>]"
      echo ""
      echo "  Compare two session logs across multiple dimensions:"
      echo "  duration, agent, commands, files, resources, network, and policy."
      echo ""
      echo "Options:"
      echo "  --pretty         Human-readable formatted output (default: compact)"
      echo "  --repo-a <id>    Repository id for session A (default: current repo)"
      echo "  --repo-b <id>    Repository id for session B (default: current repo)"
      exit 0
      ;;
    --pretty)
      PRETTY=true
      ;;
    --repo-a)
      shift
      [ "$#" -gt 0 ] || carranca_die "Missing value for --repo-a"
      REPO_A="$1"
      ;;
    --repo-b)
      shift
      [ "$#" -gt 0 ] || carranca_die "Missing value for --repo-b"
      REPO_B="$1"
      ;;
    -*)
      carranca_die "Unknown option: $1"
      ;;
    *)
      if [ -z "$SESSION_A" ]; then
        SESSION_A="$1"
      elif [ -z "$SESSION_B" ]; then
        SESSION_B="$1"
      else
        carranca_die "Too many arguments. Usage: carranca diff <session-a> <session-b>"
      fi
      ;;
  esac
  shift
done

[ -n "$SESSION_A" ] || carranca_die "Missing session A. Usage: carranca diff <session-a> <session-b>"
[ -n "$SESSION_B" ] || carranca_die "Missing session B. Usage: carranca diff <session-a> <session-b>"

# Default repo to current repo
if [ -z "$REPO_A" ]; then
  REPO_A="$(carranca_repo_id)"
fi
if [ -z "$REPO_B" ]; then
  REPO_B="$(carranca_repo_id)"
fi

# Locate log files
LOG_A="$(carranca_session_log_for_id "$REPO_A" "$SESSION_A" "$STATE_BASE")"
LOG_B="$(carranca_session_log_for_id "$REPO_B" "$SESSION_B" "$STATE_BASE")"

[ -f "$LOG_A" ] || carranca_die "Session log not found: $LOG_A"
[ -f "$LOG_B" ] || carranca_die "Session log not found: $LOG_B"

# --- Collect stats for both sessions ---

carranca_session_collect_stats "$LOG_A"
# Save A stats into prefixed variables
A_SESSION_ID="$CARRANCA_LOG_SESSION_ID"
A_FIRST_TS="$CARRANCA_LOG_FIRST_TS"
A_LAST_TS="$CARRANCA_LOG_LAST_TS"
A_AGENT_NAME="$CARRANCA_LOG_AGENT_NAME"
A_ADAPTER="$CARRANCA_LOG_ADAPTER"
A_ENGINE="$CARRANCA_LOG_ENGINE"
A_TOTAL_CMDS="$CARRANCA_LOG_TOTAL_CMDS"
A_FAILED_CMDS="$CARRANCA_LOG_FAILED_CMDS"
A_SUCCEEDED_CMDS="$CARRANCA_LOG_SUCCEEDED_CMDS"
A_UNIQUE_PATHS="$CARRANCA_LOG_UNIQUE_PATHS"
A_FILE_EVENTS="$CARRANCA_LOG_FILE_EVENTS_TOTAL"
A_RESOURCE_SAMPLES="$CARRANCA_LOG_RESOURCE_SAMPLES"
A_EXECVE_EVENTS="$CARRANCA_LOG_EXECVE_EVENTS"
A_NETWORK_EVENTS="$CARRANCA_LOG_NETWORK_EVENTS"
A_POLICY_EVENTS="$CARRANCA_LOG_POLICY_EVENTS"
A_PEAK_CPU_US="$CARRANCA_LOG_PEAK_CPU_US"
A_PEAK_MEMORY_BYTES="$CARRANCA_LOG_PEAK_MEMORY_BYTES"
A_PEAK_PIDS="$CARRANCA_LOG_PEAK_PIDS"

# Save associative arrays as newline-delimited key lists
A_CMDS="$(printf '%s\n' "${!CARRANCA_LOG_UNIQUE_CMDS[@]}")"
A_PATHS="$(printf '%s\n' "${!CARRANCA_LOG_PATH_COUNTS[@]}")"
A_BINARIES="$(printf '%s\n' "${!CARRANCA_LOG_UNIQUE_BINARIES[@]}")"
A_NET_DESTS="$(printf '%s\n' "${!CARRANCA_LOG_UNIQUE_NET_DESTS[@]}")"
A_POLICY_TYPES="$(printf '%s\n' "${!CARRANCA_LOG_POLICY_TYPES[@]}")"
# Save per-path counts for shared-path comparison
declare -A A_PATH_COUNTS=()
for p in "${!CARRANCA_LOG_PATH_COUNTS[@]}"; do
  A_PATH_COUNTS["$p"]="${CARRANCA_LOG_PATH_COUNTS[$p]}"
done

carranca_session_collect_stats "$LOG_B"
B_SESSION_ID="$CARRANCA_LOG_SESSION_ID"
B_FIRST_TS="$CARRANCA_LOG_FIRST_TS"
B_LAST_TS="$CARRANCA_LOG_LAST_TS"
B_AGENT_NAME="$CARRANCA_LOG_AGENT_NAME"
B_ADAPTER="$CARRANCA_LOG_ADAPTER"
B_ENGINE="$CARRANCA_LOG_ENGINE"
B_TOTAL_CMDS="$CARRANCA_LOG_TOTAL_CMDS"
B_FAILED_CMDS="$CARRANCA_LOG_FAILED_CMDS"
B_SUCCEEDED_CMDS="$CARRANCA_LOG_SUCCEEDED_CMDS"
B_UNIQUE_PATHS="$CARRANCA_LOG_UNIQUE_PATHS"
B_FILE_EVENTS="$CARRANCA_LOG_FILE_EVENTS_TOTAL"
B_RESOURCE_SAMPLES="$CARRANCA_LOG_RESOURCE_SAMPLES"
B_EXECVE_EVENTS="$CARRANCA_LOG_EXECVE_EVENTS"
B_NETWORK_EVENTS="$CARRANCA_LOG_NETWORK_EVENTS"
B_POLICY_EVENTS="$CARRANCA_LOG_POLICY_EVENTS"
B_PEAK_CPU_US="$CARRANCA_LOG_PEAK_CPU_US"
B_PEAK_MEMORY_BYTES="$CARRANCA_LOG_PEAK_MEMORY_BYTES"
B_PEAK_PIDS="$CARRANCA_LOG_PEAK_PIDS"

B_CMDS="$(printf '%s\n' "${!CARRANCA_LOG_UNIQUE_CMDS[@]}")"
B_PATHS="$(printf '%s\n' "${!CARRANCA_LOG_PATH_COUNTS[@]}")"
B_BINARIES="$(printf '%s\n' "${!CARRANCA_LOG_UNIQUE_BINARIES[@]}")"
B_NET_DESTS="$(printf '%s\n' "${!CARRANCA_LOG_UNIQUE_NET_DESTS[@]}")"
B_POLICY_TYPES="$(printf '%s\n' "${!CARRANCA_LOG_POLICY_TYPES[@]}")"
declare -A B_PATH_COUNTS=()
for p in "${!CARRANCA_LOG_PATH_COUNTS[@]}"; do
  B_PATH_COUNTS["$p"]="${CARRANCA_LOG_PATH_COUNTS[$p]}"
done

# --- Helpers ---

# Compute duration in seconds from two ISO timestamps
_duration_seconds() {
  local start="$1" end="$2"
  local s_epoch e_epoch
  s_epoch="$(date -u -d "${start%Z}" +%s 2>/dev/null || echo 0)"
  e_epoch="$(date -u -d "${end%Z}" +%s 2>/dev/null || echo 0)"
  echo $((e_epoch - s_epoch))
}

_format_duration() {
  local secs="$1"
  if [ "$secs" -ge 3600 ]; then
    printf '%dh %dm %ds' $((secs / 3600)) $(((secs % 3600) / 60)) $((secs % 60))
  elif [ "$secs" -ge 60 ]; then
    printf '%dm %ds' $((secs / 60)) $((secs % 60))
  else
    printf '%ds' "$secs"
  fi
}

_format_bytes() {
  local bytes="$1"
  if [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
    printf '%dGB' $((bytes / 1073741824))
  elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
    printf '%dMB' $((bytes / 1048576))
  elif [ "$bytes" -ge 1024 ] 2>/dev/null; then
    printf '%dKB' $((bytes / 1024))
  else
    printf '%dB' "$bytes"
  fi
}

# Set difference: lines in $1 not in $2
_set_only_in() {
  local set_a="$1" set_b="$2"
  local item
  while IFS= read -r item; do
    [ -z "$item" ] && continue
    if ! printf '%s\n' "$set_b" | grep -qxF "$item"; then
      printf '%s\n' "$item"
    fi
  done <<< "$set_a"
}

# Set intersection
_set_both() {
  local set_a="$1" set_b="$2"
  local item
  while IFS= read -r item; do
    [ -z "$item" ] && continue
    if printf '%s\n' "$set_b" | grep -qxF "$item"; then
      printf '%s\n' "$item"
    fi
  done <<< "$set_a"
}

# --- Output ---

_sign() {
  local val="$1"
  if [ "$val" -gt 0 ] 2>/dev/null; then
    printf '+%s' "$val"
  else
    printf '%s' "$val"
  fi
}

if [ "$PRETTY" = "true" ]; then
  # --- Pretty output ---
  echo "Session diff: $A_SESSION_ID vs $B_SESSION_ID"
  echo ""

  # Duration
  A_DUR="$(_duration_seconds "$A_FIRST_TS" "$A_LAST_TS")"
  B_DUR="$(_duration_seconds "$B_FIRST_TS" "$B_LAST_TS")"
  DELTA=$((B_DUR - A_DUR))
  echo "  Duration"
  echo "    $A_SESSION_ID: $A_FIRST_TS → $A_LAST_TS ($(_format_duration "$A_DUR"))"
  echo "    $B_SESSION_ID: $B_FIRST_TS → $B_LAST_TS ($(_format_duration "$B_DUR"))"
  echo "    delta: $(_sign "$DELTA")s ($(_format_duration "${DELTA#-}"))"
  echo ""

  # Agent
  echo "  Agent"
  echo "    $A_SESSION_ID: ${A_AGENT_NAME:-unknown} (adapter: ${A_ADAPTER:-unknown}, engine: ${A_ENGINE:-unknown})"
  echo "    $B_SESSION_ID: ${B_AGENT_NAME:-unknown} (adapter: ${B_ADAPTER:-unknown}, engine: ${B_ENGINE:-unknown})"
  echo ""

  # Commands
  echo "  Commands ($A_SESSION_ID: $A_TOTAL_CMDS, $B_SESSION_ID: $B_TOTAL_CMDS)"
  only_a="$(_set_only_in "$A_CMDS" "$B_CMDS")"
  only_b="$(_set_only_in "$B_CMDS" "$A_CMDS")"
  [ -n "$only_a" ] && echo "    Only in $A_SESSION_ID: $(echo "$only_a" | paste -sd', ')"
  [ -n "$only_b" ] && echo "    Only in $B_SESSION_ID: $(echo "$only_b" | paste -sd', ')"
  [ -z "$only_a" ] && [ -z "$only_b" ] && echo "    (identical command sets)"
  echo ""

  # Files
  echo "  Files touched ($A_SESSION_ID: $A_UNIQUE_PATHS paths, $B_SESSION_ID: $B_UNIQUE_PATHS paths)"
  only_a_paths="$(_set_only_in "$A_PATHS" "$B_PATHS")"
  only_b_paths="$(_set_only_in "$B_PATHS" "$A_PATHS")"
  shared_paths="$(_set_both "$A_PATHS" "$B_PATHS")"
  [ -n "$only_a_paths" ] && echo "    Only in $A_SESSION_ID: $(echo "$only_a_paths" | paste -sd', ')"
  [ -n "$only_b_paths" ] && echo "    Only in $B_SESSION_ID: $(echo "$only_b_paths" | paste -sd', ')"
  # Show shared paths with different event counts
  diff_shared=""
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    ac="${A_PATH_COUNTS[$p]:-0}"
    bc="${B_PATH_COUNTS[$p]:-0}"
    if [ "$ac" != "$bc" ]; then
      diff_shared="${diff_shared}${diff_shared:+, }$p ($ac vs $bc)"
    fi
  done <<< "$shared_paths"
  [ -n "$diff_shared" ] && echo "    Shared (different counts): $diff_shared"
  echo ""

  # Resources
  if [ "$A_RESOURCE_SAMPLES" -gt 0 ] || [ "$B_RESOURCE_SAMPLES" -gt 0 ]; then
    echo "  Resource usage (peak)"
    printf '    CPU:    %s: %ss    %s: %ss\n' \
      "$A_SESSION_ID" "$((A_PEAK_CPU_US / 1000000))" \
      "$B_SESSION_ID" "$((B_PEAK_CPU_US / 1000000))"
    printf '    Memory: %s: %s   %s: %s\n' \
      "$A_SESSION_ID" "$(_format_bytes "$A_PEAK_MEMORY_BYTES")" \
      "$B_SESSION_ID" "$(_format_bytes "$B_PEAK_MEMORY_BYTES")"
    printf '    PIDs:   %s: %s      %s: %s\n' \
      "$A_SESSION_ID" "$A_PEAK_PIDS" \
      "$B_SESSION_ID" "$B_PEAK_PIDS"
    echo ""
  fi

  # Network
  if [ "$A_NETWORK_EVENTS" -gt 0 ] || [ "$B_NETWORK_EVENTS" -gt 0 ]; then
    echo "  Network ($A_SESSION_ID: $A_NETWORK_EVENTS events, $B_SESSION_ID: $B_NETWORK_EVENTS events)"
    only_a_net="$(_set_only_in "$A_NET_DESTS" "$B_NET_DESTS")"
    only_b_net="$(_set_only_in "$B_NET_DESTS" "$A_NET_DESTS")"
    [ -n "$only_a_net" ] && echo "    Only in $A_SESSION_ID: $(echo "$only_a_net" | paste -sd', ')"
    [ -n "$only_b_net" ] && echo "    Only in $B_SESSION_ID: $(echo "$only_b_net" | paste -sd', ')"
    echo ""
  fi

  # Execve
  if [ "$A_EXECVE_EVENTS" -gt 0 ] || [ "$B_EXECVE_EVENTS" -gt 0 ]; then
    echo "  Execve ($A_SESSION_ID: $A_EXECVE_EVENTS events, $B_SESSION_ID: $B_EXECVE_EVENTS events)"
    only_a_bin="$(_set_only_in "$A_BINARIES" "$B_BINARIES")"
    only_b_bin="$(_set_only_in "$B_BINARIES" "$A_BINARIES")"
    [ -n "$only_a_bin" ] && echo "    Only in $A_SESSION_ID: $(echo "$only_a_bin" | paste -sd', ')"
    [ -n "$only_b_bin" ] && echo "    Only in $B_SESSION_ID: $(echo "$only_b_bin" | paste -sd', ')"
    echo ""
  fi

  # Policy
  echo "  Policy violations"
  echo "    $A_SESSION_ID: $A_POLICY_EVENTS${A_POLICY_TYPES:+ ($(echo "$A_POLICY_TYPES" | paste -sd', '))}"
  echo "    $B_SESSION_ID: $B_POLICY_EVENTS${B_POLICY_TYPES:+ ($(echo "$B_POLICY_TYPES" | paste -sd', '))}"
else
  # --- Compact output (tab-separated) ---
  echo "session_a	$A_SESSION_ID"
  echo "session_b	$B_SESSION_ID"

  A_DUR="$(_duration_seconds "$A_FIRST_TS" "$A_LAST_TS")"
  B_DUR="$(_duration_seconds "$B_FIRST_TS" "$B_LAST_TS")"
  echo "duration_s	$A_DUR	$B_DUR	$((B_DUR - A_DUR))"

  echo "agent	${A_AGENT_NAME:-unknown}	${B_AGENT_NAME:-unknown}"
  echo "adapter	${A_ADAPTER:-unknown}	${B_ADAPTER:-unknown}"
  echo "engine	${A_ENGINE:-unknown}	${B_ENGINE:-unknown}"

  echo "commands	$A_TOTAL_CMDS	$B_TOTAL_CMDS	$((B_TOTAL_CMDS - A_TOTAL_CMDS))"
  echo "commands_failed	$A_FAILED_CMDS	$B_FAILED_CMDS	$((B_FAILED_CMDS - A_FAILED_CMDS))"
  echo "files_touched	$A_UNIQUE_PATHS	$B_UNIQUE_PATHS	$((B_UNIQUE_PATHS - A_UNIQUE_PATHS))"
  echo "file_events	$A_FILE_EVENTS	$B_FILE_EVENTS	$((B_FILE_EVENTS - A_FILE_EVENTS))"

  echo "resource_samples	$A_RESOURCE_SAMPLES	$B_RESOURCE_SAMPLES"
  echo "peak_cpu_us	$A_PEAK_CPU_US	$B_PEAK_CPU_US	$((B_PEAK_CPU_US - A_PEAK_CPU_US))"
  echo "peak_memory_bytes	$A_PEAK_MEMORY_BYTES	$B_PEAK_MEMORY_BYTES	$((B_PEAK_MEMORY_BYTES - A_PEAK_MEMORY_BYTES))"
  echo "peak_pids	$A_PEAK_PIDS	$B_PEAK_PIDS	$((B_PEAK_PIDS - A_PEAK_PIDS))"

  echo "network_events	$A_NETWORK_EVENTS	$B_NETWORK_EVENTS	$((B_NETWORK_EVENTS - A_NETWORK_EVENTS))"
  echo "execve_events	$A_EXECVE_EVENTS	$B_EXECVE_EVENTS	$((B_EXECVE_EVENTS - A_EXECVE_EVENTS))"
  echo "policy_events	$A_POLICY_EVENTS	$B_POLICY_EVENTS	$((B_POLICY_EVENTS - A_POLICY_EVENTS))"
fi
