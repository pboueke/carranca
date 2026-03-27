#!/usr/bin/env bash
# Unit tests for doc page generation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/../lib/assert.sh"

suite_header "test_build_doc_page.sh"

TMPDIR="$(mktemp -d)"
mkdir -p "$TMPDIR/.githooks" "$TMPDIR/doc/page"

cp "$SCRIPT_DIR/.githooks/build-doc-page.sh" "$TMPDIR/.githooks/build-doc-page.sh"
chmod +x "$TMPDIR/.githooks/build-doc-page.sh"

cat > "$TMPDIR/doc/CHANGELOG.md" <<'EOF'
# Changelog

## 9.9.9

- docs: synthetic test version
EOF

cat > "$TMPDIR/doc/objective.md" <<'EOF'
# Objective

See [usage](usage.md) and [examples](examples/README.md).
EOF

cat > "$TMPDIR/doc/architecture.md" <<'EOF'
# Architecture

Architecture content.
EOF

cat > "$TMPDIR/doc/configuration.md" <<'EOF'
# Configuration

Start with [examples](examples/README.md).
EOF

cat > "$TMPDIR/doc/usage.md" <<'EOF'
# Usage

Open [examples](examples/README.md) and [session log](session-log.md#events).
EOF

cat > "$TMPDIR/doc/ci.md" <<'EOF'
# CI/CD Integration

CI content.
EOF

cat > "$TMPDIR/doc/session-log.md" <<'EOF'
# Session Log

Session content.
EOF

cat > "$TMPDIR/doc/trust-model.md" <<'EOF'
# Trust Model

Trust content.
EOF

OUT="$(cd "$TMPDIR" && bash .githooks/build-doc-page.sh 2>&1)"
HTML="$(cat "$TMPDIR/doc/page/index.html")"

assert_contains "builder reports output path" "doc-page: built" "$OUT"
assert_contains "page title uses reviewable evidence wording" "reviewable evidence, deep observability" "$HTML"
assert_contains "page intro describes workflow layer framing" "workflow, policy, and audit layer around" "$HTML"
assert_contains "page intro mentions complementary substrates" "gVisor, Kata" "$HTML"
assert_contains "usage section carries source path" 'data-source-path="doc/usage.md"' "$HTML"
assert_contains "configuration section carries source path" 'data-source-path="doc/configuration.md"' "$HTML"
assert_contains "github blob base embedded in script" 'const repoBlobBase = '"'"'https://github.com/pboueke/carranca/blob/main'"'"';' "$HTML"
assert_contains "link resolver rewrites markdown links via repo blob base" 'link.setAttribute('"'"'href'"'"', `${repoBlobBase}/${resolved.path}${resolved.hash}`);' "$HTML"
assert_contains "relative markdown links are resolved from source path" 'const resolved = resolveRelativeDocPath(sourcePath, cleanHref);' "$HTML"

print_results
