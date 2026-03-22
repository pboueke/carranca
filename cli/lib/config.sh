#!/usr/bin/env bash
# carranca/cli/lib/config.sh — YAML config parsing and validation

CARRANCA_CONFIG_FILE=".carranca.yml"

# Read a value from .carranca.yml using grep/awk.
# Supports flat keys (network) and one-level nested keys (agent.command).
carranca_config_get() {
  local key="$1"
  local file="${2:-$CARRANCA_CONFIG_FILE}"
  local val

  [ -f "$file" ] || return 1

  if [[ "$key" == *.* ]]; then
    local parent="${key%%.*}"
    local child="${key#*.}"
    val="$(awk -v parent="$parent" -v child="$child" '
      $0 ~ "^"parent":" { in_section=1; next }
      in_section && /^[^ ]/ { in_section=0 }
      in_section && $1 == child":" {
        gsub(/^[[:space:]]*[^:]+:[[:space:]]*/, "")
        sub(/[[:space:]]+#.*$/, "")
        print; exit
      }
    ' "$file")"
  else
    val="$(awk -v key="$key" '
      $1 == key":" {
        gsub(/^[[:space:]]*[^:]+:[[:space:]]*/, "")
        sub(/[[:space:]]+#.*$/, "")
        print; exit
      }
    ' "$file")"
  fi

  # Strip surrounding quotes only if both ends match
  if [[ "$val" == \"*\" && ${#val} -ge 2 ]]; then
    val="${val:1:${#val}-2}"
  elif [[ "$val" == \'*\' && ${#val} -ge 2 ]]; then
    val="${val:1:${#val}-2}"
  fi
  printf '%s' "$val"
}

# Read list items (lines starting with "- ") under a YAML section.
# Supports one-level nested sections (e.g., volumes.extra).
# Outputs one item per line, stripped of the "- " prefix and surrounding quotes.
carranca_config_get_list() {
  local key="$1"
  local file="${2:-$CARRANCA_CONFIG_FILE}"

  [ -f "$file" ] || return 1

  local parent child
  if [[ "$key" == *.* ]]; then
    parent="${key%%.*}"
    child="${key#*.}"
  else
    parent="$key"
    child=""
  fi

  awk -v parent="$parent" -v child="$child" '
    BEGIN { in_parent=0; in_child=0 }
    # Match parent section
    $0 ~ "^"parent":" { in_parent=1; next }
    in_parent && /^[^ #]/ { in_parent=0; in_child=0 }
    # If child is set, match nested section
    in_parent && child != "" && $0 ~ "^  "child":" { in_child=1; next }
    in_parent && child != "" && in_child && /^  [^ #-]/ { in_child=0 }
    # If child is empty, read list items directly under parent
    in_parent && child == "" && /^  - / {
      sub(/^[[:space:]]*- [[:space:]]*/, "")
      gsub(/^["'\''"]|["'\''"]$/, "")
      print
    }
    # Read list items under child section
    in_parent && in_child && /^    - / {
      sub(/^[[:space:]]*- [[:space:]]*/, "")
      gsub(/^["'\''"]|["'\''"]$/, "")
      print
    }
  ' "$file"
}

carranca_config_agent_driver() {
  local file="${1:-$CARRANCA_CONFIG_FILE}"
  local adapter agent_command cmd

  adapter="$(carranca_config_get agent.adapter "$file")"
  agent_command="$(carranca_config_get agent.command "$file")"
  cmd="${agent_command%% *}"

  case "$adapter" in
    ""|default)
      case "$cmd" in
        claude) printf '%s' "claude" ;;
        codex) printf '%s' "codex" ;;
        *) printf '%s' "stdin" ;;
      esac
      ;;
    claude|codex|stdin)
      printf '%s' "$adapter"
      ;;
    *)
      return 1
      ;;
  esac
}

# Validate required config fields. Exit with error if any are missing.
carranca_config_validate() {
  local file="${1:-$CARRANCA_CONFIG_FILE}"

  [ -f "$file" ] || carranca_die "Config file not found: $file"

  local agent_command
  agent_command="$(carranca_config_get agent.command "$file")"
  if [ -z "$agent_command" ]; then
    carranca_die "Missing required config: agent.command in $file"
  fi

  # Defaults for optional fields (just validate they parse)
  local adapter
  adapter="$(carranca_config_get agent.adapter "$file")"
  if [ -z "$adapter" ]; then
    carranca_log warn "No agent.adapter set in $file, using 'default'"
  elif ! carranca_config_agent_driver "$file" >/dev/null 2>&1; then
    carranca_die "Unsupported agent.adapter in $file: $adapter (expected default, claude, codex, or stdin)"
  fi

  local network
  network="$(carranca_config_get runtime.network "$file")"
  if [ -z "$network" ]; then
    carranca_log warn "No runtime.network setting in $file, defaulting to 'true'"
  fi
}
