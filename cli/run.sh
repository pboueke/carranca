#!/usr/bin/env bash
# carranca run — start an agent session in a containerized runtime
# No compose layer — uses the selected container runtime directly for logger and agent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/identity.sh"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/runtime.sh"
source "$SCRIPT_DIR/lib/session.sh"

CARRANCA_HOME="${CARRANCA_HOME:-$HOME/.local/share/carranca}"
STATE_BASE="${CARRANCA_STATE:-$HOME/.local/state/carranca}"

# --- Parse args ---

SELECTED_AGENT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    help)
      echo "Usage: carranca run [--agent <name>]"
      echo "  Start an agent session in a containerized runtime."
      echo "  Requires .carranca.yml in the current directory."
      echo ""
      echo "Options:"
      echo "  --agent <name>  Run the named configured agent instead of the default first agent"
      exit 0
      ;;
    -h|--help)
      echo "Usage: carranca run [--agent <name>]"
      echo "  Start an agent session in a containerized runtime."
      echo "  Requires .carranca.yml in the current directory."
      echo ""
      echo "Options:"
      echo "  --agent <name>  Run the named configured agent instead of the default first agent"
      exit 0
      ;;
    --agent)
      shift
      [ "$#" -gt 0 ] || carranca_die "Missing value for --agent"
      SELECTED_AGENT="$1"
      ;;
    *)
      carranca_die "Unknown argument: $1"
      ;;
  esac
  shift
done

# --- Precondition checks ---

[ -f ".carranca.yml" ] || carranca_die "No .carranca.yml found. Run 'carranca init' first."
[ -f ".carranca/Containerfile" ] || carranca_die "No .carranca/Containerfile found. Run 'carranca init' to create one."
carranca_config_validate
carranca_runtime_require

# --- Compute identifiers ---

REPO_ID="$(carranca_repo_id)"
REPO_NAME="$(carranca_repo_name)"
SESSION_ID="$(carranca_random_hex)"
STATE_DIR="$STATE_BASE/sessions/$REPO_ID"
WORKSPACE="$(realpath .)"
mkdir -p "$STATE_DIR"

HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
HOST_GROUPS="$(id -G)"
AGENT_HOME="/home/carranca"

# --- Read config ---

SELECTED_AGENT_NAME="$(carranca_config_resolve_agent_name "$SELECTED_AGENT")" || \
  carranca_die "Configured agent not found in .carranca.yml: ${SELECTED_AGENT:-<default>}"
AGENT_COMMAND="$(carranca_config_agent_field "$SELECTED_AGENT_NAME" command)"
NETWORK="$(carranca_config_get runtime.network)"
[ -z "$NETWORK" ] && NETWORK="true"
EXTRA_FLAGS="$(carranca_config_get runtime.extra_flags)"
LOGGER_EXTRA_FLAGS="$(carranca_config_get runtime.logger_extra_flags)"

# Parse capability additions for the agent container
CAP_ADD_FLAGS=""
while IFS= read -r cap; do
  [ -z "$cap" ] && continue
  CAP_ADD_FLAGS="$CAP_ADD_FLAGS --cap-add $cap"
done < <(carranca_config_get_list runtime.cap_add 2>/dev/null || true)

CONTAINER_RUNTIME="$(carranca_runtime_cmd)"
LOGGER_CAP_FLAGS="$(carranca_runtime_logger_cap_flags)"
AGENT_IDENTITY_FLAGS="$(carranca_runtime_agent_identity_flags "$HOST_UID" "$HOST_GID")"

# --- Volume config ---

CACHE_ENABLED="$(carranca_config_get volumes.cache)"
[ -z "$CACHE_ENABLED" ] && CACHE_ENABLED="true"

CACHE_VOLUME="carranca-cache-${REPO_ID}"
CACHE_DIR="$STATE_BASE/cache/$REPO_ID"

# Parse custom volume mounts
CUSTOM_VOLUME_FLAGS=""
while IFS= read -r mount; do
  [ -z "$mount" ] && continue
  # Expand ~ to $HOME in host path
  mount="${mount/#\~/$HOME}"
  CUSTOM_VOLUME_FLAGS="$CUSTOM_VOLUME_FLAGS -v $mount"
done < <(carranca_config_get_list volumes.extra 2>/dev/null || true)

# Build watched_paths env for the logger
WATCHED_PATHS_ENV=""
while IFS= read -r wp; do
  [ -z "$wp" ] && continue
  if [ -z "$WATCHED_PATHS_ENV" ]; then
    WATCHED_PATHS_ENV="$wp"
  else
    WATCHED_PATHS_ENV="$WATCHED_PATHS_ENV:$wp"
  fi
done < <(carranca_config_get_list watched_paths 2>/dev/null || true)

# --- Naming ---

PREFIX="$(carranca_session_prefix "$SESSION_ID")"
LOGGER_NAME="$(carranca_session_logger_name "$SESSION_ID")"
AGENT_CONTAINER_NAME="$(carranca_session_agent_name "$SESSION_ID")"
FIFO_VOLUME="$(carranca_session_fifo_volume "$SESSION_ID")"
LOGGER_IMAGE="$(carranca_session_logger_image "$SESSION_ID")"
AGENT_IMAGE="$(carranca_session_agent_image "$SESSION_ID")"

carranca_log info "Starting carranca session $SESSION_ID"
carranca_log info "Repo: $REPO_NAME ($REPO_ID)"
carranca_log info "Agent: $SELECTED_AGENT_NAME ($AGENT_COMMAND)"
carranca_log info "Runtime: $CONTAINER_RUNTIME"
carranca_log info "Log: $STATE_DIR/$SESSION_ID.jsonl"

# --- Build images ---

carranca_log info "Building images..."
carranca_runtime_build -q -t "$LOGGER_IMAGE" -f "$CARRANCA_HOME/runtime/Containerfile.logger" "$CARRANCA_HOME/runtime" >/dev/null
carranca_runtime_build -q -t "$AGENT_IMAGE" -f ".carranca/Containerfile" ".carranca" >/dev/null

# --- Create shared FIFO volume ---

carranca_runtime_volume create "$FIFO_VOLUME" --driver local --opt type=tmpfs --opt device=tmpfs >/dev/null

# --- Create persistent cache (survives across sessions) ---
#
# Agents store auth, config, and session data in their home directory
# (e.g. ~/.claude/, ~/.codex/). We persist the container home across runs so agents
# don't lose credentials or context between sessions.

CACHE_FLAGS=""
if [ "$CACHE_ENABLED" = "true" ]; then
  mkdir -p "$CACHE_DIR/home"
  # Detect cache files with wrong ownership (e.g. created by Docker, now using
  # rootless Podman). These appear as nobody-owned inside --userns keep-id and
  # the agent cannot read or write credentials, config, etc.
  _misowned="$(find "$CACHE_DIR/home" -maxdepth 1 -not -user "$HOST_UID" -print -quit 2>/dev/null || true)"
  if [ -n "$_misowned" ]; then
    if chown -R "$HOST_UID:$HOST_GID" "$CACHE_DIR/home" 2>/dev/null; then
      carranca_log info "Fixed cache ownership for current runtime"
    else
      carranca_log warn "Cache has files owned by a different runtime (e.g. Docker)."
      carranca_log warn "The agent may not be able to persist credentials or config."
      carranca_log warn "To fix: sudo chown -R \$(id -u):\$(id -g) $CACHE_DIR/home"
      carranca_log warn "Or to reset: rm -rf $CACHE_DIR/home && mkdir -p $CACHE_DIR/home"
    fi
  fi
  CACHE_FLAGS="-v $CACHE_DIR/home:$AGENT_HOME"
  carranca_log info "Cache: $CACHE_DIR"
fi

EXTRA_GROUP_FLAGS=""
for gid in $HOST_GROUPS; do
  [ "$gid" = "$HOST_GID" ] && continue
  EXTRA_GROUP_FLAGS="$EXTRA_GROUP_FLAGS --group-add $gid"
done

SKILL_MOUNT_FLAGS=""
if [ -d "$WORKSPACE/.carranca/skills/carranca" ]; then
  SKILL_MOUNT_FLAGS="$SKILL_MOUNT_FLAGS -v $WORKSPACE/.carranca/skills/carranca:/carranca-skills:ro"
fi
if [ -d "$WORKSPACE/.carranca/skills/user" ]; then
  SKILL_MOUNT_FLAGS="$SKILL_MOUNT_FLAGS -v $WORKSPACE/.carranca/skills/user:/user-skills:ro"
fi

# --- Cleanup handler ---

SESSION_CLEANED_UP=0

_cleanup() {
  if [ "$SESSION_CLEANED_UP" -eq 1 ]; then
    return
  fi
  SESSION_CLEANED_UP=1
  carranca_log info "Stopping session..."
  carranca_session_stop "$SESSION_ID"
}
trap _cleanup SIGINT SIGTERM EXIT

# --- Start logger (detached) ---

carranca_log info "Starting logger..."
# shellcheck disable=SC2086
carranca_runtime_run -d --rm \
  --name "$LOGGER_NAME" \
  $LOGGER_CAP_FLAGS \
  -v "$FIFO_VOLUME:/fifo" \
  -v "$WORKSPACE:/workspace:ro" \
  -v "$STATE_DIR:/state" \
  -e "SESSION_ID=$SESSION_ID" \
  -e "REPO_ID=$REPO_ID" \
  -e "REPO_NAME=$REPO_NAME" \
  -e "REPO_PATH=$WORKSPACE" \
  -e "WATCHED_PATHS=$WATCHED_PATHS_ENV" \
  $LOGGER_EXTRA_FLAGS \
  "$LOGGER_IMAGE" >/dev/null

# --- Wait for FIFO (logger healthcheck equivalent) ---

WAIT=0
while [ "$WAIT" -lt 30 ]; do
  # Check if FIFO exists by running test -p inside the logger container
  if carranca_runtime_exec "$LOGGER_NAME" test -p /fifo/events 2>/dev/null; then
    break
  fi
  sleep 0.5
  WAIT=$((WAIT + 1))
done

if [ "$WAIT" -ge 30 ]; then
  carranca_die "Logger FIFO not ready after 15s"
fi

# --- Run agent interactively ---

NETWORK_FLAG=""
if [ "$NETWORK" = "false" ]; then
  NETWORK_FLAG="--network=none"
fi

carranca_log ok "Agent ready — entering interactive session"
echo ""

# Use -it when stdin is a TTY, -i only otherwise (e.g. in tests/CI)
TTY_FLAGS="-i"
if [ -t 0 ]; then
  TTY_FLAGS="-it"
fi

# shellcheck disable=SC2086
AGENT_EXIT_CODE=0
carranca_runtime_run $TTY_FLAGS --rm \
  --name "$AGENT_CONTAINER_NAME" \
  $AGENT_IDENTITY_FLAGS \
  -v "$FIFO_VOLUME:/fifo" \
  -v "$WORKSPACE:/workspace:rw" \
  -e "HOME=$AGENT_HOME" \
  -e "USER=carranca" \
  $CACHE_FLAGS \
  $CUSTOM_VOLUME_FLAGS \
  $SKILL_MOUNT_FLAGS \
  $EXTRA_GROUP_FLAGS \
  $CAP_ADD_FLAGS \
  -e "AGENT_COMMAND=$AGENT_COMMAND" \
  -e "SESSION_ID=$SESSION_ID" \
  $NETWORK_FLAG \
  $EXTRA_FLAGS \
  "$AGENT_IMAGE" || AGENT_EXIT_CODE=$?

if carranca_session_is_active "$SESSION_ID"; then
  _cleanup
fi

# Give the logger time to flush remaining FIFO events (shell_command, agent_stop)
sleep 1

echo ""

# --- Session summary ---

LOG_FILE="$STATE_DIR/$SESSION_ID.jsonl"
if [ -f "$LOG_FILE" ]; then
  carranca_log ok "Session $SESSION_ID complete"

  echo ""
  carranca_session_print_summary "$LOG_FILE"
  echo ""
else
  carranca_log warn "Session $SESSION_ID — no log file found"
fi

exit "$AGENT_EXIT_CODE"
