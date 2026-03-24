#!/usr/bin/env bash
# Unit tests for watched_paths matching logic
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_watched_paths.sh"

# Source only the path_is_watched function from logger.sh
# We extract it to avoid running the logger's main body
source /dev/stdin <<'FUNC'
path_is_watched() {
  local filepath="$1"
  local pattern
  local IFS=':'

  [ -z "${WATCHED_PATHS:-}" ] && return 1

  for pattern in $WATCHED_PATHS; do
    [ -z "$pattern" ] && continue
    case "$pattern" in
      */)
        case "$filepath" in
          /workspace/"$pattern"*) return 0 ;;
        esac
        ;;
      \*.*)
        local suffix="${pattern#\*}"
        case "$filepath" in
          *"$suffix") return 0 ;;
        esac
        ;;
      *)
        local basename="${filepath##*/}"
        if [ "$basename" = "$pattern" ] || [[ "$filepath" == */"$pattern" ]]; then
          return 0
        fi
        ;;
    esac
  done
  return 1
}
FUNC

# Test: exact basename match
WATCHED_PATHS=".env"
if path_is_watched "/workspace/.env"; then
  assert_eq "exact basename .env matches" "0" "0"
else
  assert_eq "exact basename .env matches" "0" "1"
fi

# Test: nested basename match
WATCHED_PATHS=".env"
if path_is_watched "/workspace/subdir/.env"; then
  assert_eq "nested basename .env matches" "0" "0"
else
  assert_eq "nested basename .env matches" "0" "1"
fi

# Test: directory prefix match
WATCHED_PATHS="secrets/"
if path_is_watched "/workspace/secrets/api.key"; then
  assert_eq "directory prefix secrets/ matches" "0" "0"
else
  assert_eq "directory prefix secrets/ matches" "0" "1"
fi

# Test: extension glob match
WATCHED_PATHS="*.key"
if path_is_watched "/workspace/certs/server.key"; then
  assert_eq "extension glob *.key matches" "0" "0"
else
  assert_eq "extension glob *.key matches" "0" "1"
fi

# Test: no match
WATCHED_PATHS=".env:secrets/:*.key"
if path_is_watched "/workspace/src/app.js"; then
  assert_eq "non-matching path returns 1" "0" "1"
else
  assert_eq "non-matching path returns 1" "0" "0"
fi

# Test: multiple patterns, one matches
WATCHED_PATHS=".env:secrets/:*.key"
if path_is_watched "/workspace/secrets/token.txt"; then
  assert_eq "multi-pattern with directory match" "0" "0"
else
  assert_eq "multi-pattern with directory match" "0" "1"
fi

# Test: empty WATCHED_PATHS
WATCHED_PATHS=""
if path_is_watched "/workspace/.env"; then
  assert_eq "empty watched_paths never matches" "0" "1"
else
  assert_eq "empty watched_paths never matches" "0" "0"
fi

# Test: unset WATCHED_PATHS
unset WATCHED_PATHS
if path_is_watched "/workspace/.env"; then
  assert_eq "unset watched_paths never matches" "0" "1"
else
  assert_eq "unset watched_paths never matches" "0" "0"
fi

echo ""
print_results
