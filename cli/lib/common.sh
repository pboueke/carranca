#!/usr/bin/env bash
# carranca/cli/lib/common.sh — Shared utilities

# Colors (disabled if not a terminal)
if [ -t 1 ]; then
  _RED='\033[0;31m'
  _GREEN='\033[0;32m'
  _YELLOW='\033[0;33m'
  _BLUE='\033[0;34m'
  _NC='\033[0m'
else
  _RED='' _GREEN='' _YELLOW='' _BLUE='' _NC=''
fi

carranca_log() {
  local level="$1"; shift
  case "$level" in
    info)  printf "${_BLUE}[carranca]${_NC} %s\n" "$*" ;;
    warn)  printf "${_YELLOW}[carranca]${_NC} %s\n" "$*" >&2 ;;
    error) printf "${_RED}[carranca]${_NC} %s\n" "$*" >&2 ;;
    ok)    printf "${_GREEN}[carranca]${_NC} %s\n" "$*" ;;
  esac
}

carranca_die() {
  carranca_log error "$@"
  exit 1
}

carranca_require_cmd() {
  command -v "$1" >/dev/null 2>&1 || carranca_die "Required command not found: $1"
}

carranca_random_hex() {
  head -c 8 /dev/urandom | xxd -p
}

# Validate extra flags against an allowlist/denylist of container runtime flags.
# Returns 0 if all flags are safe, non-zero otherwise.
# Usage: carranca_validate_extra_flags "flag-source-name" "$FLAGS_STRING"
carranca_validate_extra_flags() {
  local source_name="$1"
  local flags_string="$2"

  [ -z "$flags_string" ] && return 0

  # Tokenize: split on whitespace, reassemble flag names (skip values)
  local -a tokens
  read -ra tokens <<< "$flags_string"

  local i=0
  while [ "$i" -lt "${#tokens[@]}" ]; do
    local token="${tokens[$i]}"

    # Skip non-flag tokens (values consumed by previous flag)
    case "$token" in
      -*) ;;  # it's a flag, check it
      *)  i=$((i + 1)); continue ;;
    esac

    # Extract flag name (strip =value if present)
    local flag_name="${token%%=*}"

    # --- Denylist: dangerous flags that could escape the sandbox ---
    case "$flag_name" in
      --privileged|--cap-add|--cap-drop|--security-opt|--device| \
      --pid|--ipc|--uts|--userns|--cgroupns|--network|--mount| \
      -v|--volume)
        carranca_log error "$source_name: denied flag '$flag_name' — this flag can weaken container isolation"
        return 1
        ;;
    esac

    # --- Allowlist: only these prefixes are permitted ---
    case "$flag_name" in
      --env|--label|--annotation|--hostname|--workdir|--user|--tmpfs|-e)
        # Safe — skip the value token if flag has no =
        if [ "$token" = "$flag_name" ]; then
          i=$((i + 1))  # skip the next token (the value)
        fi
        ;;
      *)
        carranca_log error "$source_name: unknown flag '$flag_name' — not in the allowed set"
        carranca_log error "Allowed flags: --env, -e, --label, --annotation, --hostname, --workdir, --user, --tmpfs"
        return 1
        ;;
    esac

    i=$((i + 1))
  done

  return 0
}
