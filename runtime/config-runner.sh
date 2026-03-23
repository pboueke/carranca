#!/usr/bin/env bash
set -euo pipefail

PROMPT_FILE="${CARRANCA_CONFIG_PROMPT_FILE:-/carranca-config/prompt.txt}"
AGENT_COMMAND="${CARRANCA_AGENT_COMMAND:-bash}"
AGENT_DRIVER="${CARRANCA_AGENT_DRIVER:-stdin}"

PROMPT="$(cat "$PROMPT_FILE")"

case "$AGENT_DRIVER" in
  claude)
    printf -v ESCAPED_PROMPT '%q' "$PROMPT"
    eval "$AGENT_COMMAND $ESCAPED_PROMPT"
    ;;
  codex)
    printf -v ESCAPED_PROMPT '%q' "$PROMPT"
    eval "$AGENT_COMMAND $ESCAPED_PROMPT"
    ;;
  opencode)
    printf -v ESCAPED_PROMPT '%q' "$PROMPT"
    eval "$AGENT_COMMAND $ESCAPED_PROMPT"
    ;;
  stdin)
    printf '%s\n' "$PROMPT" | eval "$AGENT_COMMAND"
    ;;
  *)
    echo "[carranca] Unsupported config agent driver: $AGENT_DRIVER" >&2
    exit 1
    ;;
esac
