#!/usr/bin/env bash
# carranca/cli/lib/config.sh — YAML config parsing and validation

CARRANCA_CONFIG_FILE=".carranca.yml"
CARRANCA_GLOBAL_CONFIG="${CARRANCA_CONFIG_DIR:-$HOME/.config/carranca}/config.yml"

carranca_config_strip_value() {
  local val="$1"

  if [[ "$val" == \"*\" && ${#val} -ge 2 ]]; then
    val="${val:1:${#val}-2}"
  elif [[ "$val" == \'*\' && ${#val} -ge 2 ]]; then
    val="${val:1:${#val}-2}"
  fi
  printf '%s' "$val"
}

# Read a value from .carranca.yml using grep/awk.
# Supports flat keys (network) and one-level nested keys (runtime.network).
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

  carranca_config_strip_value "$val"
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
    $0 ~ "^"parent":" { in_parent=1; next }
    in_parent && /^[^ #]/ { in_parent=0; in_child=0 }
    in_parent && child != "" && $0 ~ "^  "child":" { in_child=1; next }
    in_parent && child != "" && in_child && /^  [^ #-]/ { in_child=0 }
    in_parent && child == "" && /^  - / {
      sub(/^[[:space:]]*- [[:space:]]*/, "")
      gsub(/^["'\''"]|["'\''"]$/, "")
      print
    }
    in_parent && in_child && /^    - / {
      sub(/^[[:space:]]*- [[:space:]]*/, "")
      gsub(/^["'\''"]|["'\''"]$/, "")
      print
    }
  ' "$file"
}

# Read a config value with global fallback.
# Project config (.carranca.yml) takes precedence over global config.
# Only runtime.* and volumes.* keys are eligible for global fallback.
carranca_config_get_with_global() {
  local key="$1"
  local val

  # Always try project config first
  val="$(carranca_config_get "$key" "$CARRANCA_CONFIG_FILE" 2>/dev/null || true)"
  if [ -n "$val" ]; then
    printf '%s' "$val"
    return 0
  fi

  # Fall back to global only for runtime.* and volumes.* keys
  case "$key" in
    runtime.*|volumes.*)
      val="$(carranca_config_get "$key" "$CARRANCA_GLOBAL_CONFIG" 2>/dev/null || true)"
      if [ -n "$val" ]; then
        printf '%s' "$val"
        return 0
      fi
      ;;
  esac

  return 0
}

# Read a config list with global fallback.
# If the project config has the list, use it entirely. Otherwise fall back to global.
carranca_config_get_list_with_global() {
  local key="$1"
  local items

  # Try project config first
  items="$(carranca_config_get_list "$key" "$CARRANCA_CONFIG_FILE" 2>/dev/null || true)"
  if [ -n "$items" ]; then
    printf '%s\n' "$items"
    return 0
  fi

  # Fall back to global only for runtime.* and volumes.* keys
  case "$key" in
    runtime.*|volumes.*)
      items="$(carranca_config_get_list "$key" "$CARRANCA_GLOBAL_CONFIG" 2>/dev/null || true)"
      if [ -n "$items" ]; then
        printf '%s\n' "$items"
        return 0
      fi
      ;;
  esac

  return 0
}

carranca_config_agent_names() {
  local file="${1:-$CARRANCA_CONFIG_FILE}"

  [ -f "$file" ] || return 1

  awk '
    /^agents:/ { in_agents=1; next }
    in_agents && /^[^ ]/ { in_agents=0 }
    !in_agents { next }

    /^  - / {
      line=$0
      sub(/^  -[[:space:]]*/, "", line)
      if (line ~ /^name:[[:space:]]*/) {
        sub(/^name:[[:space:]]*/, "", line)
        sub(/[[:space:]]+#.*$/, "", line)
        gsub(/^["'\''"]|["'\''"]$/, "", line)
        print line
      }
      next
    }

    /^    name:/ {
      line=$0
      sub(/^    name:[[:space:]]*/, "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      gsub(/^["'\''"]|["'\''"]$/, "", line)
      print line
    }
  ' "$file"
}

carranca_config_agent_count() {
  local file="${1:-$CARRANCA_CONFIG_FILE}"
  local count=0

  while IFS= read -r _name; do
    count=$((count + 1))
  done < <(carranca_config_agent_names "$file")

  printf '%s' "$count"
}

carranca_config_agent_index() {
  local agent_name="$1"
  local file="${2:-$CARRANCA_CONFIG_FILE}"
  local idx=0
  local name

  while IFS= read -r name; do
    if [ "$name" = "$agent_name" ]; then
      printf '%s' "$idx"
      return 0
    fi
    idx=$((idx + 1))
  done < <(carranca_config_agent_names "$file")

  return 1
}

carranca_config_agent_field_by_index() {
  local index="$1"
  local field="$2"
  local file="${3:-$CARRANCA_CONFIG_FILE}"
  local val

  [ -f "$file" ] || return 1

  val="$(awk -v target="$index" -v field="$field" '
    /^agents:/ { in_agents=1; next }
    in_agents && /^[^ ]/ { in_agents=0 }
    !in_agents { next }

    /^  - / {
      current_idx += 1
      line=$0
      sub(/^  -[[:space:]]*/, "", line)
      if (current_idx - 1 == target && line ~ ("^" field ":[[:space:]]*")) {
        sub(("^" field ":[[:space:]]*"), "", line)
        sub(/[[:space:]]+#.*$/, "", line)
        print line
        exit
      }
      next
    }

    current_idx - 1 == target && $0 ~ ("^    " field ":[[:space:]]*") {
      line=$0
      sub(("^    " field ":[[:space:]]*"), "", line)
      sub(/[[:space:]]+#.*$/, "", line)
      print line
      exit
    }
  ' "$file")"

  carranca_config_strip_value "$val"
}

carranca_config_agent_field() {
  local agent_name="$1"
  local field="$2"
  local file="${3:-$CARRANCA_CONFIG_FILE}"
  local index

  index="$(carranca_config_agent_index "$agent_name" "$file")" || return 1
  carranca_config_agent_field_by_index "$index" "$field" "$file"
}

carranca_config_default_agent_name() {
  local file="${1:-$CARRANCA_CONFIG_FILE}"
  carranca_config_agent_names "$file" | head -1
}

carranca_config_resolve_agent_name() {
  local requested_name="${1:-}"
  local file="${2:-$CARRANCA_CONFIG_FILE}"
  local resolved_name

  if [ -n "$requested_name" ]; then
    carranca_config_agent_index "$requested_name" "$file" >/dev/null 2>&1 || return 1
    printf '%s' "$requested_name"
    return 0
  fi

  resolved_name="$(carranca_config_default_agent_name "$file")"
  [ -n "$resolved_name" ] || return 1
  printf '%s' "$resolved_name"
}

carranca_config_agent_driver_for() {
  local agent_name="$1"
  local file="${2:-$CARRANCA_CONFIG_FILE}"
  local adapter agent_command cmd

  adapter="$(carranca_config_agent_field "$agent_name" adapter "$file")"
  agent_command="$(carranca_config_agent_field "$agent_name" command "$file")"
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

carranca_config_validate() {
  local file="${1:-$CARRANCA_CONFIG_FILE}"
  local count name command adapter network engine
  declare -A seen_names=()

  [ -f "$file" ] || carranca_die "Config file not found: $file"

  count="$(carranca_config_agent_count "$file")"
  if [ "$count" -eq 0 ]; then
    carranca_die "Missing required config: agents in $file"
  fi

  while IFS= read -r name; do
    [ -n "$name" ] || carranca_die "Invalid agent entry in $file: missing agents[].name"
    if [ -n "${seen_names[$name]+x}" ]; then
      carranca_die "Duplicate agent name in $file: $name"
    fi
    seen_names["$name"]=1

    command="$(carranca_config_agent_field "$name" command "$file")"
    if [ -z "$command" ]; then
      carranca_die "Missing required config: agents[$name].command in $file"
    fi

    adapter="$(carranca_config_agent_field "$name" adapter "$file")"
    if [ -z "$adapter" ]; then
      carranca_log warn "No agents[$name].adapter set in $file, using 'default'"
    elif ! carranca_config_agent_driver_for "$name" "$file" >/dev/null 2>&1; then
      carranca_die "Unsupported agents[$name].adapter in $file: $adapter (expected default, claude, codex, or stdin)"
    fi
  done < <(carranca_config_agent_names "$file")

  network="$(carranca_config_get runtime.network "$file")"
  if [ -z "$network" ]; then
    carranca_log warn "No runtime.network setting in $file, defaulting to 'true'"
  fi

  engine="$(carranca_config_get runtime.engine "$file")"
  if [ -n "$engine" ] && ! carranca_runtime_validate_engine "$engine"; then
    carranca_die "Unsupported runtime.engine in $file: $engine (expected auto, docker, or podman)"
  fi
}
