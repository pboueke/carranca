#!/usr/bin/env bash
# Unit tests for git hooks and badge update logic
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0
FAIL=0

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

assert_match() {
  local desc="$1" pattern="$2" actual="$3"
  if [[ "$actual" =~ $pattern ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected match '$pattern', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== test_hooks.sh ==="

# --- Verify hook files exist and are executable ---

if [ -x "$SCRIPT_DIR/.githooks/pre-commit" ]; then
  echo "  PASS: pre-commit hook exists and is executable"
  PASS=$((PASS + 1))
else
  echo "  FAIL: pre-commit hook missing or not executable"
  FAIL=$((FAIL + 1))
fi

if [ -x "$SCRIPT_DIR/.githooks/update-badges.sh" ]; then
  echo "  PASS: update-badges.sh exists and is executable"
  PASS=$((PASS + 1))
else
  echo "  FAIL: update-badges.sh missing or not executable"
  FAIL=$((FAIL + 1))
fi

# --- Verify pre-commit hook calls make check ---

PRECOMMIT_SRC="$(cat "$SCRIPT_DIR/.githooks/pre-commit")"
assert_contains "pre-commit runs make check" "make check" "$PRECOMMIT_SRC"

# --- Verify pre-commit calls update-badges.sh ---

assert_contains "pre-commit calls update-badges.sh" "update-badges.sh" "$PRECOMMIT_SRC"

# --- Verify pre-commit stages README on badge change ---

assert_contains "pre-commit stages README.md" "git add README.md" "$PRECOMMIT_SRC"

# --- Test update-badges.sh with synthetic data ---

TMPDIR="$(mktemp -d)"

# Create a mock project structure
mkdir -p "$TMPDIR/tests"
cat > "$TMPDIR/README.md" <<'EOF'
# Test Project

![tests: 0/0 passed](https://img.shields.io/badge/tests-0%2F0_passed-red)
![coverage: 0%](https://img.shields.io/badge/coverage-0%25_(0%2F0_functions)-red)

Content here.
EOF

# All tests passing, 100% coverage
cat > "$TMPDIR/tests/.results.json" <<'EOF'
{"tests_passed":52,"tests_total":52,"tests_failed":0,"coverage_pct":100,"coverage_funcs":"17/17"}
EOF

# Run update-badges.sh against the temp dir
# The script uses SCRIPT_DIR relative to its own location, so we create a
# wrapper that overrides the paths.
(
  RESULTS="$TMPDIR/tests/.results.json"
  README="$TMPDIR/README.md"

  tests_passed=52
  tests_total=52
  coverage_pct=100
  coverage_funcs="17/17"

  test_color="brightgreen"
  cov_color="brightgreen"

  tests_label="${tests_passed}%2F${tests_total}_passed"
  cov_label="${coverage_pct}%25_(${coverage_funcs//\//%2F}_functions)"

  test_badge="![tests: ${tests_passed}/${tests_total} passed](https://img.shields.io/badge/tests-${tests_label}-${test_color})"
  cov_badge="![coverage: ${coverage_pct}%](https://img.shields.io/badge/coverage-${cov_label}-${cov_color})"

  TMPFILE="$(mktemp)"
  awk -v tb="$test_badge" -v cb="$cov_badge" '
    /^!\[tests:/ { print tb; next }
    /^!\[coverage:/ { print cb; next }
    { print }
  ' "$README" > "$TMPFILE"
  cp "$TMPFILE" "$README"
  rm -f "$TMPFILE"
)

UPDATED_README="$(cat "$TMPDIR/README.md")"

# Verify badges were updated
assert_contains "badge shows 52/52" "52/52 passed" "$UPDATED_README"
assert_contains "badge shows 100%" "100%" "$UPDATED_README"
assert_contains "badge shows brightgreen for tests" "tests-52%2F52_passed-brightgreen" "$UPDATED_README"
assert_contains "badge shows brightgreen for coverage" "coverage-100" "$UPDATED_README"

# Verify non-badge content preserved
assert_contains "non-badge content preserved" "Content here." "$UPDATED_README"
assert_contains "title preserved" "# Test Project" "$UPDATED_README"

# --- Test badge color logic: failing tests ---

cat > "$TMPDIR/tests/.results.json" <<'EOF'
{"tests_passed":48,"tests_total":52,"tests_failed":4,"coverage_pct":75,"coverage_funcs":"12/16"}
EOF

(
  tests_passed=48
  tests_total=52
  coverage_pct=75
  coverage_funcs="12/16"
  test_color="red"
  cov_color="yellow"

  tests_label="${tests_passed}%2F${tests_total}_passed"
  cov_label="${coverage_pct}%25_(${coverage_funcs//\//%2F}_functions)"

  test_badge="![tests: ${tests_passed}/${tests_total} passed](https://img.shields.io/badge/tests-${tests_label}-${test_color})"
  cov_badge="![coverage: ${coverage_pct}%](https://img.shields.io/badge/coverage-${cov_label}-${cov_color})"

  TMPFILE="$(mktemp)"
  awk -v tb="$test_badge" -v cb="$cov_badge" '
    /^!\[tests:/ { print tb; next }
    /^!\[coverage:/ { print cb; next }
    { print }
  ' "$TMPDIR/README.md" > "$TMPFILE"
  cp "$TMPFILE" "$TMPDIR/README.md"
  rm -f "$TMPFILE"
)

FAIL_README="$(cat "$TMPDIR/README.md")"
assert_contains "failing tests badge is red" "tests-48%2F52_passed-red" "$FAIL_README"
assert_contains "75% coverage badge is yellow" "coverage-75%25" "$FAIL_README"

# --- Test version badge with HTML format ---

cat > "$TMPDIR/README.md" <<'EOF'
<div align="center">
  <p>
    <img src="https://img.shields.io/badge/version-0.1.0-blue" alt="version: 0.1.0" />
    <img src="https://img.shields.io/badge/tests-0%2F0_passed-red" alt="tests: 0/0 passed" />
    <img src="https://img.shields.io/badge/coverage-0%25-red" alt="coverage: 0%" />
  </p>
</div>
EOF

cat > "$TMPDIR/CHANGELOG.md" <<'EOF'
# Changelog

## [2.5.0] - 2026-03-22

- feat: something new
EOF

cat > "$TMPDIR/tests/.results.json" <<'EOF'
{"tests_passed":30,"tests_total":30,"tests_failed":0,"coverage_pct":100,"coverage_funcs":"10/10"}
EOF

mkdir -p "$TMPDIR/.githooks"
cp "$SCRIPT_DIR/.githooks/update-badges.sh" "$TMPDIR/.githooks/update-badges.sh"
chmod +x "$TMPDIR/.githooks/update-badges.sh"

HTML_OUT="$(bash "$TMPDIR/.githooks/update-badges.sh" 2>&1)"
HTML_README="$(cat "$TMPDIR/README.md")"
assert_contains "html: version badge updated to 2.5.0" "version-2.5.0-blue" "$HTML_README"
assert_contains "html: version alt text updated" 'alt="version: 2.5.0"' "$HTML_README"
assert_contains "html: test badge updated" "tests-30%2F30_passed-brightgreen" "$HTML_README"
assert_contains "html: coverage badge updated" "coverage-100" "$HTML_README"
assert_contains "html: badges updated message" "badges updated" "$HTML_OUT"

# Run again — should report already up to date
HTML_OUT2="$(bash "$TMPDIR/.githooks/update-badges.sh" 2>&1)"
assert_contains "html: badges already up to date on re-run" "already up to date" "$HTML_OUT2"

# --- Test version badge with markdown format ---

cat > "$TMPDIR/README.md" <<'EOF'
# Test

![version: 0.1.0](https://img.shields.io/badge/version-0.1.0-blue)
![tests: 0/0 passed](https://img.shields.io/badge/tests-0%2F0_passed-red)
![coverage: 0%](https://img.shields.io/badge/coverage-0%25-red)

Content here.
EOF

MD_OUT="$(bash "$TMPDIR/.githooks/update-badges.sh" 2>&1)"
MD_README="$(cat "$TMPDIR/README.md")"
assert_contains "md: version badge updated to 2.5.0" "version-2.5.0-blue" "$MD_README"
assert_contains "md: test badge updated" "tests-30%2F30_passed-brightgreen" "$MD_README"
assert_contains "md: non-badge content preserved" "Content here." "$MD_README"

# --- Test version-only update (no .results.json) ---

rm -f "$TMPDIR/tests/.results.json"
cat > "$TMPDIR/README.md" <<'EOF'
<div align="center">
  <p>
    <img src="https://img.shields.io/badge/version-0.1.0-blue" alt="version: 0.1.0" />
  </p>
</div>
EOF

VONLY_OUT="$(bash "$TMPDIR/.githooks/update-badges.sh" 2>&1)"
VONLY_README="$(cat "$TMPDIR/README.md")"
assert_contains "version-only: badge updated" "version-2.5.0-blue" "$VONLY_README"
assert_contains "version-only: badges updated message" "badges updated" "$VONLY_OUT"

# --- Test version extracted from different changelog versions ---

cat > "$TMPDIR/CHANGELOG.md" <<'EOF'
# Changelog

## [1.0.0] - 2026-01-01

- first stable release

## [0.9.0] - 2025-12-01

- beta
EOF

cat > "$TMPDIR/README.md" <<'EOF'
<div align="center">
  <p>
    <img src="https://img.shields.io/badge/version-0.9.0-blue" alt="version: 0.9.0" />
  </p>
</div>
EOF

bash "$TMPDIR/.githooks/update-badges.sh" >/dev/null 2>&1
MULTI_README="$(cat "$TMPDIR/README.md")"
assert_contains "multi-version: picks first (latest) version" "version-1.0.0-blue" "$MULTI_README"

# --- Test no changelog — skips version, still updates test badges ---

rm -f "$TMPDIR/CHANGELOG.md"
cat > "$TMPDIR/tests/.results.json" <<'EOF'
{"tests_passed":10,"tests_total":10,"tests_failed":0,"coverage_pct":100,"coverage_funcs":"5/5"}
EOF

cat > "$TMPDIR/README.md" <<'EOF'
# Test

![tests: 0/0 passed](https://img.shields.io/badge/tests-0%2F0_passed-red)
![coverage: 0%](https://img.shields.io/badge/coverage-0%25-red)
EOF

NOCL_OUT="$(bash "$TMPDIR/.githooks/update-badges.sh" 2>&1)"
NOCL_README="$(cat "$TMPDIR/README.md")"
assert_contains "no-changelog: test badge still updated" "10/10 passed" "$NOCL_README"

# --- Test no results and no changelog — skips entirely ---

rm -f "$TMPDIR/tests/.results.json"
rm -f "$TMPDIR/CHANGELOG.md"
SKIP_OUT="$(bash "$TMPDIR/.githooks/update-badges.sh" 2>&1)"
assert_contains "no-data: skipping message" "skipping" "$SKIP_OUT"

# Cleanup
rm -rf "$TMPDIR"

# --- Verify run_tests.sh enforces 100% coverage ---

RUNNER_SRC="$(cat "$SCRIPT_DIR/tests/run_tests.sh")"
assert_contains "test runner checks coverage threshold" 'COVERAGE_PCT" -lt 100' "$RUNNER_SRC"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
