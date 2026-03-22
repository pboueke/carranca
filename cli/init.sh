#!/usr/bin/env bash
# carranca init — scaffold carranca config in the current repo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/identity.sh"

CARRANCA_HOME="${CARRANCA_HOME:-$HOME/.local/share/carranca}"
STATE_BASE="${CARRANCA_STATE:-$HOME/.local/state/carranca}"

FORCE=false
AGENT=""
for arg in "$@"; do
  case "$arg" in
    help)
      echo "Usage: carranca init [--force] [--claude|--codex]"
      echo ""
      echo "  Scaffolds carranca config in the current directory."
      echo ""
      echo "Options:"
      echo "  --force   Overwrite existing .carranca.yml and Containerfile"
      echo "  --claude  Pre-configure for Claude Code agent"
      echo "  --codex   Pre-configure for OpenAI Codex CLI agent"
      exit 0
      ;;
    --force) FORCE=true ;;
    --claude) AGENT="claude" ;;
    --codex)  AGENT="codex" ;;
    -h|--help)
      echo "Usage: carranca init [--force] [--claude|--codex]"
      echo ""
      echo "  Scaffolds carranca config in the current directory."
      echo ""
      echo "Options:"
      echo "  --force   Overwrite existing .carranca.yml and Containerfile"
      echo "  --claude  Pre-configure for Claude Code agent"
      echo "  --codex   Pre-configure for OpenAI Codex CLI agent"
      exit 0
      ;;
    *) carranca_die "Unknown argument: $arg" ;;
  esac
done

# Check for existing config
if [ -f ".carranca.yml" ] && [ "$FORCE" = false ]; then
  carranca_die "Already initialized. Use 'carranca init --force' to overwrite."
fi

# Copy config template
cp "$CARRANCA_HOME/templates/carranca.yml.tmpl" ".carranca.yml"
carranca_log info "Created .carranca.yml"

# Create skills directories and copy defaults
mkdir -p ".carranca/skills/carranca/plan"
mkdir -p ".carranca/skills/carranca/confiskill"
mkdir -p ".carranca/skills/user"
cp "$CARRANCA_HOME/skills/plan/SKILL.md" ".carranca/skills/carranca/plan/SKILL.md"
cp "$CARRANCA_HOME/skills/confiskill/SKILL.md" ".carranca/skills/carranca/confiskill/SKILL.md"
carranca_log info "Created .carranca/skills/"

# Copy agent Containerfile and shell wrapper
if [ ! -f ".carranca/Containerfile" ] || [ "$FORCE" = true ]; then
  cp "$CARRANCA_HOME/templates/Containerfile" ".carranca/Containerfile"
fi
cp "$CARRANCA_HOME/runtime/shell-wrapper.sh" ".carranca/shell-wrapper.sh"

# Inject agent snippet into Containerfile and set command in config
if [ -n "$AGENT" ]; then
  SNIPPET="$CARRANCA_HOME/templates/agents/${AGENT}.containerfile"
  if [ ! -f "$SNIPPET" ]; then
    carranca_die "Unknown agent template: $AGENT"
  fi

  # Inject snippet into Containerfile at the marker line
  MARKER="# Add your agent and project dependencies below:"
  if grep -q "$MARKER" ".carranca/Containerfile"; then
    sed -i "/$MARKER/r $SNIPPET" ".carranca/Containerfile"
  else
    carranca_die "Containerfile missing injection marker. Re-run with --force to reset."
  fi

  # Set agent command in .carranca.yml
  case "$AGENT" in
    claude) sed -i 's/^  command: .*/  command: claude/' ".carranca.yml" ;;
    codex)  sed -i 's/^  command: .*/  command: codex/' ".carranca.yml" ;;
  esac

  carranca_log ok "Configured for $AGENT agent"
else
  carranca_log info "Created .carranca/Containerfile — edit this to install your agent CLI"
fi

# Create state directory on host
REPO_ID="$(carranca_repo_id)"
REPO_NAME="$(carranca_repo_name)"
SESSION_DIR="$STATE_BASE/sessions/$REPO_ID"
mkdir -p "$SESSION_DIR"

carranca_log ok "Initialized carranca in $(pwd)"
carranca_log info "Repo ID: $REPO_ID ($REPO_NAME)"
carranca_log info "Session logs: $SESSION_DIR"
