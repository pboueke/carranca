#!/usr/bin/env bash
# carranca init — scaffold carranca config in the current repo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/identity.sh"

CARRANCA_HOME="${CARRANCA_HOME:-$HOME/.local/share/carranca}"
STATE_BASE="${CARRANCA_STATE:-$HOME/.local/state/carranca}"

supported_agent_names() {
  printf '%s\n' "codex" "claude" "opencode"
}

supported_agent_exists() {
  case "$1" in
    codex|claude|opencode) return 0 ;;
    *) return 1 ;;
  esac
}

FORCE=false
AGENT="codex"
while [ "$#" -gt 0 ]; do
  case "$1" in
    help)
      echo "Usage: carranca init [--agent <name>] [--force]"
      echo ""
      echo "  Scaffolds carranca config in the current directory."
      echo ""
      echo "Options:"
      echo "  --agent <name>  Supported: codex, claude, opencode"
      echo "  --force   Overwrite existing .carranca.yml and Containerfile"
      exit 0
      ;;
    --agent)
      shift
      [ "$#" -gt 0 ] || carranca_die "Missing value for --agent"
      AGENT="$1"
      ;;
    --force) FORCE=true ;;
    -h|--help)
      echo "Usage: carranca init [--agent <name>] [--force]"
      echo ""
      echo "  Scaffolds carranca config in the current directory."
      echo ""
      echo "Options:"
      echo "  --agent <name>  Supported: codex, claude, opencode"
      echo "  --force   Overwrite existing .carranca.yml and Containerfile"
      exit 0
      ;;
    *) carranca_die "Unknown argument: $1" ;;
  esac
  shift
done

supported_agent_exists "$AGENT" || carranca_die "Unsupported agent for init: $AGENT (supported: codex, claude, opencode)"

# Check for existing config
if [ -f ".carranca.yml" ] && [ "$FORCE" = false ]; then
  carranca_die "Already initialized. Use 'carranca config' to update the setup, or re-run with '--force' to overwrite."
fi

if [ -f ".carranca.yml" ] && [ "$FORCE" = true ]; then
  printf 'Overwrite existing carranca initialization? [y/N] '
  read -r reply
  case "$reply" in
    y|Y|yes|YES)
      ;;
    *)
      carranca_log info "Initialization aborted."
      exit 0
      ;;
  esac
fi

# Copy config template
cp "$CARRANCA_HOME/templates/carranca.yml.tmpl" ".carranca.yml"
carranca_log info "Created .carranca.yml"

# Create skills directories and copy defaults
mkdir -p ".carranca/skills/carranca/confiskill"
mkdir -p ".carranca/skills/user"
cp "$CARRANCA_HOME/skills/confiskill/SKILL.md" ".carranca/skills/carranca/confiskill/SKILL.md"
carranca_log info "Created .carranca/skills/"

# Copy agent Containerfile, shell wrapper, and shared libraries
cp "$CARRANCA_HOME/templates/Containerfile" ".carranca/Containerfile"
cp "$CARRANCA_HOME/runtime/shell-wrapper.sh" ".carranca/shell-wrapper.sh"
mkdir -p ".carranca/lib"
cp "$CARRANCA_HOME/runtime/lib/json.sh" ".carranca/lib/json.sh"

# Inject agent snippet into Containerfile and set command in config
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

sed -i "s/^  - name: .*/  - name: $AGENT/" ".carranca.yml"
sed -i "s/^    adapter: .*/    adapter: $AGENT/" ".carranca.yml"
sed -i "s/^    command: .*/    command: $AGENT/" ".carranca.yml"

carranca_log ok "Configured for $AGENT agent"

# Create state directory on host
REPO_ID="$(carranca_repo_id)"
REPO_NAME="$(carranca_repo_name)"
SESSION_DIR="$STATE_BASE/sessions/$REPO_ID"
mkdir -p "$SESSION_DIR"

carranca_log ok "Initialized carranca in $(pwd)"
carranca_log info "Repo ID: $REPO_ID ($REPO_NAME)"
carranca_log info "Session logs: $SESSION_DIR"
