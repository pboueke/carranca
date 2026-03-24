#!/usr/bin/env bash
# Integration tests for carranca config (requires a supported container runtime)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export CARRANCA_HOME="$SCRIPT_DIR"
source "$SCRIPT_DIR/tests/lib/integration.sh"

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

integration_init
trap integration_cleanup EXIT

echo "=== test_config.sh (requires $RUNTIME) ==="

integration_require_runtime
integration_create_repo
integration_init_project
rm -rf ".carranca/skills/carranca"

mkdir -p ".carranca/skills/user/custom"
cat > ".carranca/skills/user/custom/SKILL.md" <<'EOF'
---
name: custom-user-skill
description: Test-only user skill
---

Prefer pnpm when a pnpm lockfile is present.
EOF

cat > ".carranca/fake-config-agent.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PROMPT="$(cat)"
printf '%s' "$PROMPT" > /proposal/request.txt

test -f /carranca-skills/confiskill/SKILL.md
test -f /user-skills/custom/SKILL.md

cp /workspace/.carranca.yml /proposal/.carranca.yml
awk '
  BEGIN {
    replaced_name=0
    replaced_adapter=0
    replaced_command=0
  }
  !replaced_name && /^  - name: / {
    print "  - name: claude"
    replaced_name=1
    next
  }
  replaced_name && !replaced_adapter && /^    adapter: / {
    print "    adapter: claude"
    replaced_adapter=1
    next
  }
  replaced_adapter && !replaced_command && /^    command: / {
    print "    command: claude"
    replaced_command=1
    next
  }
  { print }
' /proposal/.carranca.yml > /proposal/.carranca.yml.next
mv /proposal/.carranca.yml.next /proposal/.carranca.yml

awk '
  {
    print
    if ($0 == "# Add your agent and project dependencies below:") {
      print "# carranca-config:start"
      print "# Managed by fake config agent for test coverage."
      print "RUN apk add --no-cache nodejs npm"
      print "RUN npm install -g pnpm"
      print "# carranca-config:end"
    }
  }
' /workspace/.carranca/Containerfile > /proposal/Containerfile

printf '%s\n' "node pnpm" > /proposal/detected-stack.txt
printf '%s\n' "Used confiskill from the carranca skill mount and considered user skills." > /proposal/rationale.txt
EOF
chmod +x ".carranca/fake-config-agent.sh"

cat > ".carranca/fake-arg-config-agent.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PROMPT="${1:-}"
printf '%s' "$PROMPT" > /proposal/request.txt

test -f /carranca-skills/confiskill/SKILL.md
test -f /user-skills/custom/SKILL.md

cp /workspace/.carranca.yml /proposal/.carranca.yml
awk '
  BEGIN {
    replaced_name=0
    replaced_adapter=0
    replaced_command=0
  }
  !replaced_name && /^  - name: / {
    print "  - name: claude"
    replaced_name=1
    next
  }
  replaced_name && !replaced_adapter && /^    adapter: / {
    print "    adapter: claude"
    replaced_adapter=1
    next
  }
  replaced_adapter && !replaced_command && /^    command: / {
    print "    command: claude"
    replaced_command=1
    next
  }
  { print }
' /proposal/.carranca.yml > /proposal/.carranca.yml.next
mv /proposal/.carranca.yml.next /proposal/.carranca.yml

cp /workspace/.carranca/Containerfile /proposal/Containerfile
printf '%s\n' "node pnpm" > /proposal/detected-stack.txt
printf '%s\n' "Used arg-style config agent invocation." > /proposal/rationale.txt
EOF
chmod +x ".carranca/fake-arg-config-agent.sh"

awk '
  {
    if ($0 == "COPY shell-wrapper.sh /usr/local/bin/shell-wrapper.sh") {
      print "COPY fake-config-agent.sh /usr/local/bin/fake-config-agent.sh"
      print "RUN chmod +x /usr/local/bin/fake-config-agent.sh"
      print "COPY fake-arg-config-agent.sh /usr/local/bin/fake-arg-config-agent.sh"
      print "RUN chmod +x /usr/local/bin/fake-arg-config-agent.sh"
    }
    print
  }
' .carranca/Containerfile > .carranca/Containerfile.next
mv .carranca/Containerfile.next .carranca/Containerfile

cat > package.json <<'EOF'
{
  "name": "config-test",
  "private": true
}
EOF
touch pnpm-lock.yaml

cat > ".carranca.yml" <<'EOF'
agents:
  - name: codex
    adapter: codex
    command: codex
  - name: shell
    adapter: stdin
    command: bash /usr/local/bin/fake-config-agent.sh
runtime:
  engine: auto
  network: true
volumes:
  cache: true
policy:
  docs_before_code: warn
  tests_before_impl: warn
EOF

ORIGINAL_CONFIG="$(cat .carranca.yml)"
ORIGINAL_CONTAINERFILE="$(cat .carranca/Containerfile)"

REJECT_OUTPUT="$(printf 'n\n' | bash "$CARRANCA_HOME/cli/config.sh" --agent shell --prompt "install claude" 2>&1)" || true
assert_contains "proposal asks for confirmation" "Apply these changes" "$REJECT_OUTPUT"
assert_contains "proposal references confiskill" "confiskill" "$REJECT_OUTPUT"
assert_contains "config command reports selected agent" "Config agent: shell" "$REJECT_OUTPUT"
assert_contains "config command reports stdin driver" "Config agent driver: stdin -> stdin" "$REJECT_OUTPUT"
assert_eq "rejected proposal keeps config unchanged" "$ORIGINAL_CONFIG" "$(cat .carranca.yml)"
assert_eq "rejected proposal keeps Containerfile unchanged" "$ORIGINAL_CONTAINERFILE" "$(cat .carranca/Containerfile)"
assert_eq "config reject does not recreate carranca-managed skills in workspace" "missing" "$(test -d .carranca/skills/carranca && echo present || echo missing)"

APPLY_OUTPUT="$(bash "$CARRANCA_HOME/cli/config.sh" --agent shell --prompt "install claude" --dangerously-skip-confirmation 2>&1)" || true
assert_contains "dangerous apply prints strict warning" "WARNING: applying configurator-generated changes without user confirmation" "$APPLY_OUTPUT"
assert_contains "config command applied proposal" "Applied configurator proposal" "$APPLY_OUTPUT"
assert_contains "config file switches selected agent to claude" "command: claude" "$(cat .carranca.yml)"
assert_contains "Containerfile has managed config block" "# carranca-config:start" "$(cat .carranca/Containerfile)"
assert_contains "Containerfile adds pnpm" "pnpm" "$(cat .carranca/Containerfile)"
assert_eq "config apply still avoids workspace carranca skill writes" "missing" "$(test -d .carranca/skills/carranca && echo present || echo missing)"

REPO_ID="$(integration_repo_id)"
AUDIT_LOG="$TMPSTATE/config/$REPO_ID/history.jsonl"
REQUEST_FILE="$(find "$TMPSTATE/config/$REPO_ID" -name request.txt | sort | tail -1)"
assert_contains "agent prompt instructs use of confiskill" "/carranca-skills/confiskill/SKILL.md" "$(cat "$REQUEST_FILE")"
assert_contains "agent prompt includes selected executor name" "Selected config agent name: shell" "$(cat "$REQUEST_FILE")"
assert_contains "agent prompt includes operator request" "Operator request:" "$(cat "$REQUEST_FILE")"
assert_contains "agent prompt includes exact operator request text" "install claude" "$(cat "$REQUEST_FILE")"
assert_contains "audit log records confirmation bypass" '"event":"confirmation_bypassed"' "$(cat "$AUDIT_LOG")"
assert_contains "audit log records apply event" '"event":"applied"' "$(cat "$AUDIT_LOG")"

cat > ".carranca.yml" <<'EOF'
agents:
  - name: opencode
    adapter: opencode
    command: bash /usr/local/bin/fake-arg-config-agent.sh
runtime:
  engine: auto
  network: true
volumes:
  cache: true
policy:
  docs_before_code: warn
  tests_before_impl: warn
EOF

OPENCODE_OUTPUT="$(printf 'n\n' | bash "$CARRANCA_HOME/cli/config.sh" --agent opencode --prompt "install opencode deps" 2>&1)" || true
assert_contains "config command reports opencode driver" "Config agent driver: opencode -> opencode" "$OPENCODE_OUTPUT"
OPENCODE_REQUEST_FILE="$(find "$TMPSTATE/config/$REPO_ID" -name request.txt -exec grep -l "install opencode deps" {} + 2>/dev/null | head -1 || true)"
assert_contains "opencode config agent receives exact operator request text" "install opencode deps" "$(cat "$OPENCODE_REQUEST_FILE")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
