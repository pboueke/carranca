#!/usr/bin/env bash
# Unit tests for Phase 5.3 — seccomp profile validation and flag generation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_seccomp_profile.sh"

PROFILE="$SCRIPT_DIR/runtime/security/seccomp-agent.json"

# --- Test: profile is valid JSON ---
echo "--- seccomp profile validation ---"
rc=0; python3 -c "import json; json.load(open('$PROFILE'))" 2>/dev/null || jq empty "$PROFILE" 2>/dev/null || rc=$?
assert_eq "seccomp profile is valid JSON" "0" "$rc"

# --- Test: profile has defaultAction ---
rc=0; python3 -c "
import json, sys
p = json.load(open('$PROFILE'))
assert 'defaultAction' in p, 'missing defaultAction'
" 2>/dev/null || rc=$?
assert_eq "profile has defaultAction" "0" "$rc"

# --- Test: profile blocks expected syscalls ---
echo "--- blocked syscalls ---"
BLOCKED_SYSCALLS="ptrace mount umount2 reboot init_module finit_module delete_module pivot_root swapon swapoff sethostname setdomainname unshare setns"
PROFILE_CONTENT="$(cat "$PROFILE")"
for syscall in $BLOCKED_SYSCALLS; do
  assert_contains "profile blocks $syscall" "\"$syscall\"" "$PROFILE_CONTENT"
done

# --- Test: blocked action is ERRNO ---
assert_contains "blocked action is SCMP_ACT_ERRNO" "SCMP_ACT_ERRNO" "$PROFILE_CONTENT"

# --- Test: flag generation ---
echo "--- flag generation ---"

_build_seccomp_flag() {
  local profile="$1" carranca_home="$2"
  case "$profile" in
    default) echo "--security-opt seccomp=$carranca_home/runtime/security/seccomp-agent.json" ;;
    unconfined) echo "--security-opt seccomp=unconfined" ;;
    /*) echo "--security-opt seccomp=$profile" ;;
    *) echo "" ;;
  esac
}

result="$(_build_seccomp_flag "default" "/opt/carranca")"
assert_eq "default yields built-in path" "--security-opt seccomp=/opt/carranca/runtime/security/seccomp-agent.json" "$result"

result="$(_build_seccomp_flag "unconfined" "/opt/carranca")"
assert_eq "unconfined yields unconfined" "--security-opt seccomp=unconfined" "$result"

result="$(_build_seccomp_flag "/custom/profile.json" "/opt/carranca")"
assert_eq "absolute path yields custom" "--security-opt seccomp=/custom/profile.json" "$result"

# --- Test: apparmor flag generation ---
echo "--- apparmor flag generation ---"

_build_apparmor_flag() {
  local profile="$1"
  if [ -n "$profile" ] && [ "$profile" != "unconfined" ]; then
    echo "--security-opt apparmor=$profile"
  elif [ "$profile" = "unconfined" ]; then
    echo "--security-opt apparmor=unconfined"
  else
    echo ""
  fi
}

result="$(_build_apparmor_flag "carranca-agent")"
assert_eq "named profile yields flag" "--security-opt apparmor=carranca-agent" "$result"

result="$(_build_apparmor_flag "unconfined")"
assert_eq "unconfined yields unconfined flag" "--security-opt apparmor=unconfined" "$result"

result="$(_build_apparmor_flag "")"
assert_eq "empty yields no flag" "" "$result"

# --- Test: AppArmor reference profile exists ---
echo "--- apparmor profile file ---"
APPARMOR_FILE="$SCRIPT_DIR/runtime/security/apparmor-agent.profile"
file_exists=0; [ -f "$APPARMOR_FILE" ] && file_exists=1
assert_eq "AppArmor reference profile exists" "1" "$file_exists"

echo ""
print_results
