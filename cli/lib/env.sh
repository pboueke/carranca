#!/usr/bin/env bash
# carranca/cli/lib/env.sh — Environment variable handling for agent containers
#
# Supports three mechanisms for passing env vars to agent containers:
#   1. passthrough — forward specific host env vars by name
#   2. env_file    — load vars from a .env file on the host
#   3. vars        — define vars directly in the config
#
# Priority (last wins for duplicate keys): passthrough < env_file < vars

_env_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F carranca_config_get >/dev/null 2>&1; then
  source "$_env_lib_dir/config.sh"
fi
unset _env_lib_dir

# Validate an environment variable name.
# Valid: starts with letter or underscore, followed by alphanumeric or underscore.
# Returns 0 if valid, 1 otherwise.
carranca_env_valid_name() {
  local name="$1"
  [[ "$name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]
}

# Parse a .env file and output KEY=VALUE lines.
# Handles comments, blank lines, optional 'export' prefix, and quoted values.
# Does NOT expand variable references ($VAR or ${VAR}).
carranca_env_parse_file() {
  local file="$1"

  [ -f "$file" ] || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    # Strip leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    # Skip empty lines and comments
    [ -z "$line" ] && continue
    [[ "$line" == \#* ]] && continue

    # Strip optional 'export ' prefix
    line="${line#export }"

    # Split on first '='
    local key="${line%%=*}"
    local val="${line#*=}"

    # Skip lines without '='
    [ "$key" = "$line" ] && continue

    # Strip surrounding quotes from value
    if [[ "$val" == \"*\" && ${#val} -ge 2 ]]; then
      val="${val:1:${#val}-2}"
    elif [[ "$val" == \'*\' && ${#val} -ge 2 ]]; then
      val="${val:1:${#val}-2}"
    fi

    # Validate key
    if ! carranca_env_valid_name "$key"; then
      carranca_log warn "env_file: skipping invalid variable name '$key'"
      continue
    fi

    printf '%s=%s\n' "$key" "$val"
  done < "$file"
}

# Build container -e flags from the environment config section.
# Reads from config file and outputs docker/podman -e flags.
# Usage: carranca_env_build_flags [config_file]
# Output: string of -e KEY=VALUE flags (empty if no env vars configured)
carranca_env_build_flags() {
  local file="${1:-$CARRANCA_CONFIG_FILE}"

  # Use associative array to track vars (last wins for duplicates)
  declare -A env_vars=()

  # 1. Passthrough: forward host env vars by name
  local name
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    if ! carranca_env_valid_name "$name"; then
      carranca_log warn "environment.passthrough: invalid variable name '$name' — skipping"
      continue
    fi
    # Only pass through if the var exists in the host environment
    if [ -n "${!name+x}" ]; then
      env_vars["$name"]="${!name}"
    else
      carranca_log warn "environment.passthrough: '$name' is not set in the host environment — skipping"
    fi
  done < <(carranca_config_get_list environment.passthrough "$file" 2>/dev/null || true)

  # 2. Env file: load vars from a .env file
  local env_file
  env_file="$(carranca_config_get environment.env_file "$file" 2>/dev/null || true)"
  if [ -n "$env_file" ]; then
    # Expand ~ to $HOME
    env_file="${env_file/#\~/$HOME}"

    if [ ! -f "$env_file" ]; then
      carranca_log error "environment.env_file: file not found: $env_file"
      return 1
    fi

    local kv
    while IFS= read -r kv; do
      [ -z "$kv" ] && continue
      local key="${kv%%=*}"
      local val="${kv#*=}"
      env_vars["$key"]="$val"
    done < <(carranca_env_parse_file "$env_file")
  fi

  # 3. Vars: defined directly in config (requires yq for map parsing)
  if carranca_config_has_yq; then
    local vars_type
    vars_type="$(yq eval '.environment.vars | type' "$file" 2>/dev/null || true)"
    if [ "$vars_type" = "!!map" ]; then
      local key val
      while IFS='=' read -r key val; do
        [ -z "$key" ] && continue
        if ! carranca_env_valid_name "$key"; then
          carranca_log warn "environment.vars: invalid variable name '$key' — skipping"
          continue
        fi
        env_vars["$key"]="$val"
      done < <(yq eval '.environment.vars | to_entries | .[] | .key + "=" + .value' "$file" 2>/dev/null || true)
    fi
  else
    # Awk fallback: parse simple key: value pairs under environment.vars
    local kv
    while IFS= read -r kv; do
      [ -z "$kv" ] && continue
      local key="${kv%%:*}"
      local val="${kv#*:}"
      # Strip leading whitespace from value
      val="${val#"${val%%[![:space:]]*}"}"
      key="${key#"${key%%[![:space:]]*}"}"
      key="${key%"${key##*[![:space:]]}"}"
      if [ -z "$key" ] || [ -z "$val" ]; then
        continue
      fi
      if ! carranca_env_valid_name "$key"; then
        carranca_log warn "environment.vars: invalid variable name '$key' — skipping"
        continue
      fi
      env_vars["$key"]="$val"
    done < <(awk '
      /^environment:/ { in_env=1; next }
      in_env && /^[^ ]/ { in_env=0 }
      in_env && /^  vars:/ { in_vars=1; next }
      in_env && in_vars && /^  [^ ]/ { in_vars=0 }
      in_env && in_vars && /^    [a-zA-Z_]/ {
        sub(/^[[:space:]]+/, "")
        sub(/[[:space:]]+#.*$/, "")
        print
      }
    ' "$file")
  fi

  # Build -e flags
  local flags=""
  local key
  for key in "${!env_vars[@]}"; do
    flags="$flags -e $key=${env_vars[$key]}"
  done

  printf '%s' "$flags"
}

# Validate the environment config section.
# Returns 0 if valid, non-zero on error.
carranca_env_validate() {
  local file="${1:-$CARRANCA_CONFIG_FILE}"

  # Validate passthrough names
  local name
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    if ! carranca_env_valid_name "$name"; then
      carranca_log error "environment.passthrough: invalid variable name '$name'"
      return 1
    fi
  done < <(carranca_config_get_list environment.passthrough "$file" 2>/dev/null || true)

  # Validate env_file path exists (if configured)
  local env_file
  env_file="$(carranca_config_get environment.env_file "$file" 2>/dev/null || true)"
  if [ -n "$env_file" ]; then
    env_file="${env_file/#\~/$HOME}"
    if [ ! -f "$env_file" ]; then
      carranca_log error "environment.env_file: file not found: $env_file"
      return 1
    fi
  fi

  return 0
}
