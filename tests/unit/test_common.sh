#!/usr/bin/env bash
# Unit tests for cli/lib/common.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/cli/lib/common.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_common.sh"

# Test carranca_random_hex produces 16 hex chars
hex="$(carranca_random_hex)"
assert_eq "random_hex length is 16" "16" "${#hex}"
assert_match "random_hex is hex chars" "^[0-9a-f]{16}$" "$hex"

# Test two calls produce different values
hex2="$(carranca_random_hex)"
hex_differ=0; [ "$hex" != "$hex2" ] && hex_differ=1
assert_eq "random_hex produces different values" "1" "$hex_differ"

# Test carranca_require_cmd with existing command
rc=0; carranca_require_cmd bash 2>/dev/null || rc=$?
assert_eq "require_cmd accepts existing command (bash)" "0" "$rc"

# Test carranca_require_cmd with missing command (run in subshell since die calls exit)
rc=0; (carranca_require_cmd nonexistent_cmd_xyz 2>/dev/null) || rc=$?
assert_eq "require_cmd rejects missing command" "1" "$rc"

# Test carranca_log outputs to stdout for info/ok, stderr for warn/error
info_out="$(carranca_log info "test message" 2>/dev/null)"
assert_match "carranca_log info writes to stdout" "test message" "$info_out"

ok_out="$(carranca_log ok "success" 2>/dev/null)"
assert_match "carranca_log ok writes to stdout" "success" "$ok_out"

warn_out="$(carranca_log warn "warning" 2>/dev/null 2>&1)"
assert_match "carranca_log warn contains message" "warning" "$warn_out"

error_out="$(carranca_log error "failure" 2>&1)"
assert_match "carranca_log error contains message" "failure" "$error_out"

# Test carranca_die exits with code 1 and prints error (run in subshell to catch exit)
die_out="$(carranca_die "fatal error" 2>&1)" && die_rc=0 || die_rc=$?
assert_match "carranca_die outputs error message" "fatal error" "$die_out"
assert_eq "carranca_die exits with code 1" "1" "$die_rc"

# --- Test carranca_validate_extra_flags ---

# Safe flags pass
rc=0; carranca_validate_extra_flags "test" "--env FOO=bar --label x=y" 2>/dev/null || rc=$?
assert_eq "validate_extra_flags allows safe flags" "0" "$rc"

# Denied flag --privileged
rc=0; carranca_validate_extra_flags "test" "--privileged" 2>/dev/null || rc=$?
assert_eq "validate_extra_flags denies --privileged" "1" "$rc"

# Denied flag --cap-add
rc=0; carranca_validate_extra_flags "test" "--cap-add SYS_ADMIN" 2>/dev/null || rc=$?
assert_eq "validate_extra_flags denies --cap-add" "1" "$rc"

# Unknown flag rejected
rc=0; carranca_validate_extra_flags "test" "--unknown-flag" 2>/dev/null || rc=$?
assert_eq "validate_extra_flags rejects unknown flag" "1" "$rc"

# Empty flags pass
rc=0; carranca_validate_extra_flags "test" "" 2>/dev/null || rc=$?
assert_eq "validate_extra_flags allows empty string" "0" "$rc"

echo ""
print_results
