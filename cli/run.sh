#!/usr/bin/env bash
# carranca run — start an agent session in a containerized runtime
# No docker-compose — uses docker run directly for both logger and agent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/identity.sh"
source "$SCRIPT_DIR/lib/log.sh"

CARRANCA_HOME="${CARRANCA_HOME:-$HOME/.local/share/carranca}"
STATE_BASE="${CARRANCA_STATE:-$HOME/.local/state/carranca}"

# --- Parse args ---

for arg in "$@"; do
  case "$arg" in
    help)
      echo "Usage: carranca run"
      echo "  Start an agent session in a containerized runtime."
      echo "  Requires .carranca.yml in the current directory."
      exit 0
      ;;
    -h|--help)
      echo "Usage: carranca run"
      echo "  Start an agent session in a containerized runtime."
      echo "  Requires .carranca.yml in the current directory."
      exit 0
      ;;
  esac
done

# --- Precondition checks ---

carranca_require_cmd docker
docker info >/dev/null 2>&1 || carranca_die "Docker is not running. Start Docker and try again."
[ -f ".carranca.yml" ] || carranca_die "No .carranca.yml found. Run 'carranca init' first."
[ -f ".carranca/Containerfile" ] || carranca_die "No .carranca/Containerfile found. Run 'carranca init' to create one."
carranca_config_validate

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

AGENT_COMMAND="$(carranca_config_get agent.command)"
NETWORK="$(carranca_config_get runtime.network)"
[ -z "$NETWORK" ] && NETWORK="true"
EXTRA_FLAGS="$(carranca_config_get runtime.extra_flags)"
LOGGER_EXTRA_FLAGS="$(carranca_config_get runtime.logger_extra_flags)"

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

# --- Naming ---

PREFIX="carranca-${SESSION_ID}"
LOGGER_NAME="${PREFIX}-logger"
AGENT_NAME="${PREFIX}-agent"
FIFO_VOLUME="${PREFIX}-fifo"
LOGGER_IMAGE="${PREFIX}-logger"
AGENT_IMAGE="${PREFIX}-agent"

carranca_log info "Starting carranca session $SESSION_ID"
carranca_log info "Repo: $REPO_NAME ($REPO_ID)"
carranca_log info "Agent: $AGENT_COMMAND"
carranca_log info "Log: $STATE_DIR/$SESSION_ID.jsonl"

# --- Build images ---

carranca_log info "Building images..."
docker build -q -t "$LOGGER_IMAGE" -f "$CARRANCA_HOME/runtime/Containerfile.logger" "$CARRANCA_HOME/runtime" >/dev/null
docker build -q -t "$AGENT_IMAGE" -f ".carranca/Containerfile" ".carranca" >/dev/null

# --- Create shared FIFO volume ---

docker volume create "$FIFO_VOLUME" --driver local --opt type=tmpfs --opt device=tmpfs >/dev/null

# --- Create persistent cache (survives across sessions) ---
#
# Agents store auth, config, and session data in their home directory
# (e.g. ~/.claude/, ~/.codex/). We persist the container home across runs so agents
# don't lose credentials or context between sessions.

CACHE_FLAGS=""
if [ "$CACHE_ENABLED" = "true" ]; then
  mkdir -p "$CACHE_DIR"
  CACHE_FLAGS="-v $CACHE_DIR/home:$AGENT_HOME"
  mkdir -p "$CACHE_DIR/home"
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

_cleanup() {
  carranca_log info "Stopping session..."
  docker rm -f "$AGENT_NAME" 2>/dev/null || true
  # Graceful stop: SIGTERM lets the logger flush remaining events and write logger_stop
  docker stop --timeout 5 "$LOGGER_NAME" 2>/dev/null || true
  docker rm -f "$LOGGER_NAME" 2>/dev/null || true
  docker volume rm "$FIFO_VOLUME" 2>/dev/null || true
  docker rmi "$AGENT_IMAGE" "$LOGGER_IMAGE" 2>/dev/null || true
}
trap _cleanup SIGINT SIGTERM EXIT

# --- Start logger (detached) ---

carranca_log info "Starting logger..."
# shellcheck disable=SC2086
docker run -d --rm \
  --name "$LOGGER_NAME" \
  --cap-add LINUX_IMMUTABLE \
  -v "$FIFO_VOLUME:/fifo" \
  -v "$WORKSPACE:/workspace:ro" \
  -v "$STATE_DIR:/state" \
  -e "SESSION_ID=$SESSION_ID" \
  -e "REPO_ID=$REPO_ID" \
  -e "REPO_NAME=$REPO_NAME" \
  -e "REPO_PATH=$WORKSPACE" \
  $LOGGER_EXTRA_FLAGS \
  "$LOGGER_IMAGE" >/dev/null

# --- Wait for FIFO (logger healthcheck equivalent) ---

WAIT=0
while [ "$WAIT" -lt 30 ]; do
  # Check if FIFO exists by running test -p inside the logger container
  if docker exec "$LOGGER_NAME" test -p /fifo/events 2>/dev/null; then
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
DOCKER_TTY_FLAGS="-i"
if [ -t 0 ]; then
  DOCKER_TTY_FLAGS="-it"
fi

# shellcheck disable=SC2086
docker run $DOCKER_TTY_FLAGS --rm \
  --name "$AGENT_NAME" \
  --user "$HOST_UID:$HOST_GID" \
  -v "$FIFO_VOLUME:/fifo" \
  -v "$WORKSPACE:/workspace:rw" \
  -e "HOME=$AGENT_HOME" \
  -e "USER=carranca" \
  $CACHE_FLAGS \
  $CUSTOM_VOLUME_FLAGS \
  $SKILL_MOUNT_FLAGS \
  $EXTRA_GROUP_FLAGS \
  -e "AGENT_COMMAND=$AGENT_COMMAND" \
  -e "SESSION_ID=$SESSION_ID" \
  $NETWORK_FLAG \
  $EXTRA_FLAGS \
  "$AGENT_IMAGE" || true

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
