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
  head -c 4 /dev/urandom | xxd -p
}
