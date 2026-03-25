#!/usr/bin/env bash
# Update README.md badge lines from test results and changelog version.
# Called by the pre-commit hook after tests pass.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS="$SCRIPT_DIR/tests/.results.json"
README="$SCRIPT_DIR/README.md"
CHANGELOG="$SCRIPT_DIR/doc/CHANGELOG.md"

if [ ! -f "$README" ]; then
  echo "badge-update: no README.md found, skipping"
  exit 0
fi

# --- Version badge from changelog ---

version=""
if [ -f "$CHANGELOG" ]; then
  version="$(grep -m1 '^## [0-9]' "$CHANGELOG" | awk '{print $2}')"
fi

if [ -n "$version" ]; then
  version_src="https://img.shields.io/badge/version-${version}-blue"

  # HTML <img> format
  version_html="    <img src=\"${version_src}\" alt=\"version: ${version}\" />"
  # Markdown format
  version_md="![version: ${version}](${version_src})"
fi

# --- Test/coverage badges from results ---

tests_badge_ready=false
if [ -f "$RESULTS" ]; then
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
  tests_label="${tests_passed}%2F${tests_total}_passed"
  cov_label="${coverage_pct}%25_(${coverage_funcs//\//%2F}_functions)"

  test_src="https://img.shields.io/badge/tests-${tests_label}-${test_color}"
  cov_src="https://img.shields.io/badge/coverage-${cov_label}-${cov_color}"

  # HTML <img> format
  test_html="    <img src=\"${test_src}\" alt=\"tests: ${tests_passed}/${tests_total} passed\" />"
  cov_html="    <img src=\"${cov_src}\" alt=\"coverage: ${coverage_pct}%\" />"

  # Markdown format
  test_md="![tests: ${tests_passed}/${tests_total} passed](${test_src})"
  cov_md="![coverage: ${coverage_pct}%](${cov_src})"

  tests_badge_ready=true
fi

# --- Replace badges in README ---

TMPFILE="$(mktemp)"

if [ -n "$version" ] && [ "$tests_badge_ready" = true ]; then
  awk \
    -v vh="$version_html" -v vm="$version_md" \
    -v th="$test_html" -v tm="$test_md" \
    -v ch="$cov_html" -v cm="$cov_md" '
    /img.*shields\.io\/badge\/version-/  { print vh; next }
    /!\[version:/                        { print vm; next }
    /img.*shields\.io\/badge\/tests-/    { print th; next }
    /!\[tests:/                          { print tm; next }
    /img.*shields\.io\/badge\/coverage-/ { print ch; next }
    /!\[coverage:/                       { print cm; next }
    { print }
  ' "$README" > "$TMPFILE"
elif [ -n "$version" ]; then
  awk \
    -v vh="$version_html" -v vm="$version_md" '
    /img.*shields\.io\/badge\/version-/  { print vh; next }
    /!\[version:/                        { print vm; next }
    { print }
  ' "$README" > "$TMPFILE"
elif [ "$tests_badge_ready" = true ]; then
  awk \
    -v th="$test_html" -v tm="$test_md" \
    -v ch="$cov_html" -v cm="$cov_md" '
    /img.*shields\.io\/badge\/tests-/    { print th; next }
    /!\[tests:/                          { print tm; next }
    /img.*shields\.io\/badge\/coverage-/ { print ch; next }
    /!\[coverage:/                       { print cm; next }
    { print }
  ' "$README" > "$TMPFILE"
else
  echo "badge-update: no results or changelog found, skipping"
  rm -f "$TMPFILE"
  exit 0
fi

if ! diff -q "$README" "$TMPFILE" >/dev/null 2>&1; then
  cp "$TMPFILE" "$README"
  echo "badge-update: README.md badges updated"
else
  echo "badge-update: badges already up to date"
fi

rm -f "$TMPFILE"
