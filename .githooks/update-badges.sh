#!/usr/bin/env bash
# Update README.md badge lines from test results.
# Called by the pre-commit hook after tests pass.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS="$SCRIPT_DIR/tests/.results.json"
README="$SCRIPT_DIR/README.md"

if [ ! -f "$RESULTS" ]; then
  echo "badge-update: no .results.json found, skipping"
  exit 0
fi

if [ ! -f "$README" ]; then
  echo "badge-update: no README.md found, skipping"
  exit 0
fi

# Parse values from JSON (no jq dependency — use grep/sed)
tests_passed="$(grep -o '"tests_passed":[0-9]*' "$RESULTS" | cut -d: -f2)"
tests_total="$(grep -o '"tests_total":[0-9]*' "$RESULTS" | cut -d: -f2)"
coverage_pct="$(grep -o '"coverage_pct":[0-9]*' "$RESULTS" | cut -d: -f2)"
coverage_funcs="$(grep -o '"coverage_funcs":"[^"]*"' "$RESULTS" | cut -d'"' -f4)"

# Determine badge colors
if [ "$tests_passed" -eq "$tests_total" ] && [ "$tests_total" -gt 0 ]; then
  test_color="brightgreen"
else
  test_color="red"
fi

if [ "$coverage_pct" -ge 100 ]; then
  cov_color="brightgreen"
elif [ "$coverage_pct" -ge 80 ]; then
  cov_color="green"
elif [ "$coverage_pct" -ge 60 ]; then
  cov_color="yellow"
else
  cov_color="red"
fi

# URL-encode special characters for shields.io
# %2F = /, %25 = %, space = _
tests_label="${tests_passed}%2F${tests_total}_passed"
cov_label="${coverage_pct}%25_(${coverage_funcs//\//%2F}_functions)"

test_badge="![tests: ${tests_passed}/${tests_total} passed](https://img.shields.io/badge/tests-${tests_label}-${test_color})"
cov_badge="![coverage: ${coverage_pct}%](https://img.shields.io/badge/coverage-${cov_label}-${cov_color})"

# Replace existing badge lines in README (lines 3 and 4, after "# Carranca")
# Match any line starting with ![tests: or ![coverage:
TMPFILE="$(mktemp)"
awk -v tb="$test_badge" -v cb="$cov_badge" '
  /^!\[tests:/ { print tb; next }
  /^!\[coverage:/ { print cb; next }
  { print }
' "$README" > "$TMPFILE"

if ! diff -q "$README" "$TMPFILE" >/dev/null 2>&1; then
  cp "$TMPFILE" "$README"
  echo "badge-update: README.md badges updated"
else
  echo "badge-update: badges already up to date"
fi

rm -f "$TMPFILE"
