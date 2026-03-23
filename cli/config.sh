#!/usr/bin/env bash
# carranca config — inspect the workspace and propose .carranca updates
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/identity.sh"
source "$SCRIPT_DIR/lib/runtime.sh"

CARRANCA_HOME="${CARRANCA_HOME:-$HOME/.local/share/carranca}"
STATE_BASE="${CARRANCA_STATE:-$HOME/.local/state/carranca}"

SKIP_CONFIRMATION=false
SELECTED_AGENT=""
USER_PROMPT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    help)
      echo "Usage: carranca config [--agent <name>] [--prompt <text>] [--dangerously-skip-confirmation]"
      echo ""
      echo "  Inspect the current workspace and propose updates to .carranca.yml"
      echo "  and .carranca/Containerfile so the container has the repo's dev tools."
      echo ""
      echo "Options:"
      echo "  --agent <name>                    Use the named configured agent instead of the default first agent"
      echo "  --prompt <text>                   Pass a free-form request to the config agent"
      echo "  --dangerously-skip-confirmation  Apply proposed changes without prompting"
      exit 0
      ;;
    --agent)
      shift
      [ "$#" -gt 0 ] || carranca_die "Missing value for --agent"
      SELECTED_AGENT="$1"
      ;;
    --prompt)
      shift
      [ "$#" -gt 0 ] || carranca_die "Missing value for --prompt"
      USER_PROMPT="$1"
      ;;
    --dangerously-skip-confirmation)
      SKIP_CONFIRMATION=true
      ;;
    -h|--help)
      echo "Usage: carranca config [--agent <name>] [--prompt <text>] [--dangerously-skip-confirmation]"
      echo ""
      echo "  Inspect the current workspace and propose updates to .carranca.yml"
      echo "  and .carranca/Containerfile so the container has the repo's dev tools."
      echo ""
      echo "Options:"
      echo "  --agent <name>                    Use the named configured agent instead of the default first agent"
      echo "  --prompt <text>                   Pass a free-form request to the config agent"
      echo "  --dangerously-skip-confirmation  Apply proposed changes without prompting"
      exit 0
      ;;
    *)
      carranca_die "Unknown argument: $1"
      ;;
  esac
  shift
done

[ -f ".carranca.yml" ] || carranca_die "No .carranca.yml found. Run 'carranca init' first."
[ -f ".carranca/Containerfile" ] || carranca_die "No .carranca/Containerfile found. Run 'carranca init' first."
carranca_config_validate
carranca_runtime_require

REPO_ID="$(carranca_repo_id)"
REPO_NAME="$(carranca_repo_name)"
SESSION_ID="$(carranca_random_hex)"
WORKSPACE="$(realpath .)"
CONFIG_STATE_DIR="$STATE_BASE/config/$REPO_ID/$SESSION_ID"
PROPOSAL_DIR="$CONFIG_STATE_DIR/proposal"
AUDIT_LOG="$STATE_BASE/config/$REPO_ID/history.jsonl"
CONFIG_IMAGE="carranca-config-${SESSION_ID}"
PROMPT_FILE="$CONFIG_STATE_DIR/prompt.txt"
AGENT_NAME="$(carranca_config_resolve_agent_name "$SELECTED_AGENT")" || \
  carranca_die "Configured agent not found in .carranca.yml: ${SELECTED_AGENT:-<default>}"
AGENT_COMMAND="$(carranca_config_agent_field "$AGENT_NAME" command)"
AGENT_ADAPTER="$(carranca_config_agent_field "$AGENT_NAME" adapter)"
AGENT_DRIVER="$(carranca_config_agent_driver_for "$AGENT_NAME")"
CONTAINER_RUNTIME="$(carranca_runtime_cmd)"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
HOST_GROUPS="$(id -G)"
AGENT_HOME="/home/carranca"
AGENT_IDENTITY_FLAGS="$(carranca_runtime_agent_identity_flags "$HOST_UID" "$HOST_GID")"
NETWORK="$(carranca_config_get runtime.network)"
CACHE_ENABLED="$(carranca_config_get volumes.cache)"
CACHE_DIR="$STATE_BASE/cache/$REPO_ID"
USER_SKILLS_DIR="$CONFIG_STATE_DIR/user-skills"
CARRANCA_SKILLS_DIR="$CARRANCA_HOME/skills"

mkdir -p "$PROPOSAL_DIR"
mkdir -p "$USER_SKILLS_DIR"
mkdir -p "$(dirname "$AUDIT_LOG")"

trap 'carranca_runtime_rmi "$CONFIG_IMAGE" 2>/dev/null || true' EXIT

carranca_log info "Inspecting workspace for carranca config updates"
carranca_log info "Repo: $REPO_NAME ($REPO_ID)"
carranca_log info "Proposal dir: $PROPOSAL_DIR"
carranca_log info "Runtime: $CONTAINER_RUNTIME"
carranca_log info "Config agent: $AGENT_NAME"
carranca_log info "Config agent driver: ${AGENT_ADAPTER:-default} -> $AGENT_DRIVER"

[ -z "$NETWORK" ] && NETWORK="true"
[ -z "$CACHE_ENABLED" ] && CACHE_ENABLED="true"

CACHE_FLAGS=""
if [ "$CACHE_ENABLED" = "true" ]; then
  mkdir -p "$CACHE_DIR/home"
  _misowned="$(find "$CACHE_DIR/home" -maxdepth 1 -not -user "$HOST_UID" -print -quit 2>/dev/null || true)"
  if [ -n "$_misowned" ]; then
    if ! chown -R "$HOST_UID:$HOST_GID" "$CACHE_DIR/home" 2>/dev/null; then
      carranca_log warn "Cache has files owned by a different runtime (e.g. Docker)."
      carranca_log warn "To fix: sudo chown -R \$(id -u):\$(id -g) $CACHE_DIR/home"
      carranca_log warn "Or to reset: rm -rf $CACHE_DIR/home && mkdir -p $CACHE_DIR/home"
    fi
  fi
  CACHE_FLAGS="-v $CACHE_DIR/home:$AGENT_HOME"
fi

EXTRA_GROUP_FLAGS=""
for gid in $HOST_GROUPS; do
  [ "$gid" = "$HOST_GID" ] && continue
  EXTRA_GROUP_FLAGS="$EXTRA_GROUP_FLAGS --group-add $gid"
done

# Parse capability additions for the agent container
CAP_ADD_FLAGS=""
while IFS= read -r cap; do
  [ -z "$cap" ] && continue
  CAP_ADD_FLAGS="$CAP_ADD_FLAGS --cap-add $cap"
done < <(carranca_config_get_list runtime.cap_add 2>/dev/null || true)

NETWORK_FLAG=""
if [ "$NETWORK" = "false" ]; then
  NETWORK_FLAG="--network=none"
fi

USER_SKILLS_MOUNT="$USER_SKILLS_DIR"
if [ -d "$WORKSPACE/.carranca/skills/user" ]; then
  USER_SKILLS_MOUNT="$WORKSPACE/.carranca/skills/user"
fi

TTY_FLAGS="-i"
if [ -t 0 ]; then
  TTY_FLAGS="-it"
fi

cat > "$PROMPT_FILE" <<'EOF'
You are the carranca-bound configuration agent.

Mandatory instruction:
- Read and follow `/carranca-skills/confiskill/SKILL.md`.
- Also inspect any user-provided skills mounted under `/user-skills/`.

Task:
- Review the workspace at `/workspace`.
- Propose updates for `/workspace/.carranca.yml` and `/workspace/.carranca/Containerfile`.
- Do not modify `/workspace` directly.
- Write complete proposed files to:
  - `/proposal/.carranca.yml`
  - `/proposal/Containerfile`
- Write a concise explanation of the proposed changes to `/proposal/rationale.txt`.
- Write a short detected stack summary to `/proposal/detected-stack.txt`.

Constraints:
- Only propose changes to `.carranca.yml` and `.carranca/Containerfile`.
- Preserve the shell-wrapper contract in the Containerfile.
- If no changes are needed, still copy the current files into `/proposal` and explain why.
EOF

{
  echo ""
  echo "Execution context:"
  echo "- Selected config agent name: $AGENT_NAME"
  echo "- Selected config agent adapter: ${AGENT_ADAPTER:-default}"
  echo "- Selected config agent command: $AGENT_COMMAND"
} >> "$PROMPT_FILE"

if [ -n "$USER_PROMPT" ]; then
  {
    echo ""
    echo "Operator request:"
    echo "- $USER_PROMPT"
  } >> "$PROMPT_FILE"
fi

carranca_log info "Building agent image..."
carranca_runtime_build -q -t "$CONFIG_IMAGE" -f ".carranca/Containerfile" ".carranca" >/dev/null

carranca_log info "Generating proposal with the bound agent and confiskill..."
# shellcheck disable=SC2086
carranca_runtime_run $TTY_FLAGS --rm \
  --name "carranca-config-${SESSION_ID}" \
  $AGENT_IDENTITY_FLAGS \
  -v "$WORKSPACE:/workspace:ro" \
  -v "$PROPOSAL_DIR:/proposal:rw" \
  -v "$PROMPT_FILE:/carranca-config/prompt.txt:ro" \
  -v "$CARRANCA_SKILLS_DIR:/carranca-skills:ro" \
  -v "$USER_SKILLS_MOUNT:/user-skills:ro" \
  -v "$CARRANCA_HOME/runtime/config-runner.sh:/tmp/carranca-config-runner.sh:ro" \
  -e "HOME=$AGENT_HOME" \
  -e "USER=carranca" \
  $CACHE_FLAGS \
  $EXTRA_GROUP_FLAGS \
  $CAP_ADD_FLAGS \
  -e "CARRANCA_AGENT_COMMAND=$AGENT_COMMAND" \
  -e "CARRANCA_AGENT_DRIVER=$AGENT_DRIVER" \
  -e "CARRANCA_CONFIG_PROMPT_FILE=/carranca-config/prompt.txt" \
  $NETWORK_FLAG \
  --entrypoint /bin/bash \
  "$CONFIG_IMAGE" /tmp/carranca-config-runner.sh

[ -f "$PROPOSAL_DIR/.carranca.yml" ] || carranca_die "Configurator did not produce a proposed .carranca.yml"
[ -f "$PROPOSAL_DIR/Containerfile" ] || carranca_die "Configurator did not produce a proposed Containerfile"
[ -f "$PROPOSAL_DIR/rationale.txt" ] || carranca_die "Configurator did not produce a rationale"
[ -f "$PROPOSAL_DIR/detected-stack.txt" ] || carranca_die "Configurator did not produce a detected stack summary"

carranca_config_validate "$PROPOSAL_DIR/.carranca.yml" >/dev/null
grep -q 'COPY shell-wrapper.sh /usr/local/bin/shell-wrapper.sh' "$PROPOSAL_DIR/Containerfile" || \
  carranca_die "Proposed Containerfile is invalid: missing shell-wrapper copy step"
grep -q 'ENTRYPOINT \["/usr/local/bin/shell-wrapper.sh"\]' "$PROPOSAL_DIR/Containerfile" || \
  carranca_die "Proposed Containerfile is invalid: missing shell-wrapper entrypoint"

CONFIG_DIFF="$(diff -u .carranca.yml "$PROPOSAL_DIR/.carranca.yml" || true)"
CONTAINER_DIFF="$(diff -u .carranca/Containerfile "$PROPOSAL_DIR/Containerfile" || true)"

echo ""
echo "Detected workspace profile:"
cat "$PROPOSAL_DIR/detected-stack.txt"
echo ""
echo "Rationale:"
cat "$PROPOSAL_DIR/rationale.txt"

if [ -z "$CONFIG_DIFF$CONTAINER_DIFF" ]; then
  echo ""
  carranca_log ok "No configuration changes proposed."
  printf '{"type":"config_event","event":"no_changes","ts":"%s","repo_id":"%s","session_id":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REPO_ID" "$SESSION_ID" >> "$AUDIT_LOG"
  exit 0
fi

echo ""
echo "Proposed changes:"
if [ -n "$CONFIG_DIFF" ]; then
  echo "$CONFIG_DIFF"
fi
if [ -n "$CONTAINER_DIFF" ]; then
  echo "$CONTAINER_DIFF"
fi

if [ "$SKIP_CONFIRMATION" = true ]; then
  carranca_log warn "WARNING: applying configurator-generated changes without user confirmation (--dangerously-skip-confirmation)"
  printf '{"type":"config_event","event":"confirmation_bypassed","ts":"%s","repo_id":"%s","session_id":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REPO_ID" "$SESSION_ID" >> "$AUDIT_LOG"
else
  echo ""
  printf 'Apply these changes? [y/N] '
  read -r reply
  case "$reply" in
    y|Y|yes|YES)
      ;;
    *)
      carranca_log info "No changes applied."
      printf '{"type":"config_event","event":"proposal_rejected","ts":"%s","repo_id":"%s","session_id":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REPO_ID" "$SESSION_ID" >> "$AUDIT_LOG"
      exit 0
      ;;
  esac
fi

cp "$PROPOSAL_DIR/.carranca.yml" ".carranca.yml"
cp "$PROPOSAL_DIR/Containerfile" ".carranca/Containerfile"

carranca_log ok "Applied configurator proposal."
printf '{"type":"config_event","event":"applied","ts":"%s","repo_id":"%s","session_id":"%s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REPO_ID" "$SESSION_ID" >> "$AUDIT_LOG"
