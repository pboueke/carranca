#!/usr/bin/env bash
# Unit tests for carranca help routing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$SCRIPT_DIR/cli/carranca"

PASS=0
FAIL=0

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -Fq -- "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== test_help.sh ==="

main_help="$(bash "$CLI" help 2>&1)"
assert_contains "main help shows help subcommand usage" "carranca help <command>" "$main_help"

run_help_from_root="$(bash "$CLI" help run 2>&1)"
assert_contains "root help routes to run help" "Usage: carranca run [--agent <name>]" "$run_help_from_root"
assert_contains "run help documents agent option" "--agent <name>" "$run_help_from_root"

run_help_from_subcommand="$(bash "$CLI" run help 2>&1)"
assert_eq "run help matches between root and subcommand forms" "$run_help_from_root" "$run_help_from_subcommand"

run_help_flag="$(bash "$CLI" run --help 2>&1)"
assert_eq "run help matches --help form" "$run_help_from_root" "$run_help_flag"

log_help_from_root="$(bash "$CLI" help log 2>&1)"
assert_contains "root help routes to log help" "Usage: carranca log [--session <exact-id>]" "$log_help_from_root"
assert_contains "log help documents session option" "--session <id>" "$log_help_from_root"
assert_contains "log help documents --files-only flag" "--files-only" "$log_help_from_root"
assert_contains "log help documents --commands-only flag" "--commands-only" "$log_help_from_root"
assert_contains "log help documents --top flag" "--top <n>" "$log_help_from_root"

log_help_from_subcommand="$(bash "$CLI" log help 2>&1)"
assert_eq "log help matches between root and subcommand forms" "$log_help_from_root" "$log_help_from_subcommand"

log_help_flag="$(bash "$CLI" log --help 2>&1)"
assert_eq "log help matches --help form" "$log_help_from_root" "$log_help_flag"

status_help_from_root="$(bash "$CLI" help status 2>&1)"
assert_contains "root help routes to status help" "Usage: carranca status [--session <exact-id>]" "$status_help_from_root"
assert_contains "status help describes active sessions" "Show active carranca sessions" "$status_help_from_root"
assert_contains "status help documents session option" "--session <id>" "$status_help_from_root"

status_help_from_subcommand="$(bash "$CLI" status help 2>&1)"
assert_eq "status help matches between root and subcommand forms" "$status_help_from_root" "$status_help_from_subcommand"

status_help_flag="$(bash "$CLI" status --help 2>&1)"
assert_eq "status help matches --help form" "$status_help_from_root" "$status_help_flag"

config_help_from_root="$(bash "$CLI" help config 2>&1)"
assert_contains "root help routes to config help" "Usage: carranca config [--agent <name>] [--prompt <text>] [--dangerously-skip-confirmation]" "$config_help_from_root"
assert_contains "config help documents agent option" "--agent <name>" "$config_help_from_root"
assert_contains "config help documents prompt option" "--prompt <text>" "$config_help_from_root"
config_help_from_subcommand="$(bash "$CLI" config help 2>&1)"
assert_eq "config help matches between root and subcommand forms" "$config_help_from_root" "$config_help_from_subcommand"

config_help_flag="$(bash "$CLI" config --help 2>&1)"
assert_eq "config help matches --help form" "$config_help_from_root" "$config_help_flag"

init_help_from_root="$(bash "$CLI" help init 2>&1)"
assert_contains "root help routes to init help" "Usage: carranca init [--agent <name>] [--force]" "$init_help_from_root"
assert_contains "init help documents agent option" "--agent <name>" "$init_help_from_root"
init_help_from_subcommand="$(bash "$CLI" init help 2>&1)"
assert_eq "init help matches between root and subcommand forms" "$init_help_from_root" "$init_help_from_subcommand"

init_help_flag="$(bash "$CLI" init --help 2>&1)"
assert_eq "init help matches --help form" "$init_help_from_root" "$init_help_flag"

unknown_help="$(bash "$CLI" help nope 2>&1)" && unknown_rc=0 || unknown_rc=$?
assert_eq "help on unknown command exits non-zero" "1" "$unknown_rc"
assert_contains "help on unknown command reports error" "unknown command 'nope'" "$unknown_help"

log_missing_session_output="$(bash "$CLI" log --session 2>&1)" && log_missing_session_rc=0 || log_missing_session_rc=$?
assert_eq "log without session value exits non-zero" "1" "$log_missing_session_rc"
assert_contains "log without session value reports error" "Missing value for --session" "$log_missing_session_output"

log_unknown_arg_output="$(bash "$CLI" log --bogus 2>&1)" && log_unknown_arg_rc=0 || log_unknown_arg_rc=$?
assert_eq "log with unknown argument exits non-zero" "1" "$log_unknown_arg_rc"
assert_contains "log with unknown argument reports error" "Unknown argument: --bogus" "$log_unknown_arg_output"

log_missing_top_output="$(bash "$CLI" log --top 2>&1)" && log_missing_top_rc=0 || log_missing_top_rc=$?
assert_eq "log without --top value exits non-zero" "1" "$log_missing_top_rc"
assert_contains "log without --top value reports error" "Missing value for --top" "$log_missing_top_output"

log_mutex_output="$(bash "$CLI" log --files-only --commands-only 2>&1)" && log_mutex_rc=0 || log_mutex_rc=$?
assert_eq "log with --files-only and --commands-only exits non-zero" "1" "$log_mutex_rc"
assert_contains "log with --files-only and --commands-only reports error" "--files-only and --commands-only are mutually exclusive" "$log_mutex_output"

status_unknown_arg_output="$(bash "$CLI" status --bogus 2>&1)" && status_unknown_arg_rc=0 || status_unknown_arg_rc=$?
assert_eq "status with unknown argument exits non-zero" "1" "$status_unknown_arg_rc"
assert_contains "status with unknown argument reports error" "Unknown argument: --bogus" "$status_unknown_arg_output"

status_missing_session_output="$(bash "$CLI" status --session 2>&1)" && status_missing_session_rc=0 || status_missing_session_rc=$?
assert_eq "status without session value exits non-zero" "1" "$status_missing_session_rc"
assert_contains "status without session value reports error" "Missing value for --session" "$status_missing_session_output"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
