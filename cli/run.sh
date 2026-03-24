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
TRUST_REPO_FLAGS="false"
while [ "$#" -gt 0 ]; do
  case "$1" in
    help)
      echo "Usage: carranca run [--agent <name>] [--trust-repo-flags]"
      echo "  Start an agent session in a containerized runtime."
      echo "  Requires .carranca.yml in the current directory."
      echo ""
      echo "Options:"
      echo "  --agent <name>       Run the named configured agent instead of the default first agent"
      echo "  --trust-repo-flags   Skip validation of runtime.extra_flags and runtime.logger_extra_flags"
      exit 0
      ;;
    -h|--help)
      echo "Usage: carranca run [--agent <name>] [--trust-repo-flags]"
      echo "  Start an agent session in a containerized runtime."
      echo "  Requires .carranca.yml in the current directory."
      echo ""
      echo "Options:"
      echo "  --agent <name>       Run the named configured agent instead of the default first agent"
      echo "  --trust-repo-flags   Skip validation of runtime.extra_flags and runtime.logger_extra_flags"
      exit 0
      ;;
    --agent)
      shift
      [ "$#" -gt 0 ] || carranca_die "Missing value for --agent"
      SELECTED_AGENT="$1"
      ;;
    --trust-repo-flags)
      TRUST_REPO_FLAGS="true"
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
AGENT_ADAPTER="$(carranca_config_agent_driver_for "$SELECTED_AGENT_NAME")"
NETWORK="$(carranca_config_get_with_global runtime.network)"
[ -z "$NETWORK" ] && NETWORK="true"
NETWORK_MODE="$(carranca_config_network_mode)"
EXTRA_FLAGS="$(carranca_config_get_with_global runtime.extra_flags)"
LOGGER_EXTRA_FLAGS="$(carranca_config_get_with_global runtime.logger_extra_flags)"

# Validate extra flags against allowlist (D1 hardening)
if [ "$TRUST_REPO_FLAGS" != "true" ]; then
  if [ -n "$EXTRA_FLAGS" ]; then
    carranca_validate_extra_flags "runtime.extra_flags" "$EXTRA_FLAGS" || \
      carranca_die "Unsafe runtime flag in .carranca.yml — use --trust-repo-flags to override"
  fi
  if [ -n "$LOGGER_EXTRA_FLAGS" ]; then
    carranca_validate_extra_flags "runtime.logger_extra_flags" "$LOGGER_EXTRA_FLAGS" || \
      carranca_die "Unsafe runtime flag in .carranca.yml — use --trust-repo-flags to override"
  fi
else
  if [ -n "$EXTRA_FLAGS" ] || [ -n "$LOGGER_EXTRA_FLAGS" ]; then
    carranca_log warn "Skipping extra_flags validation (--trust-repo-flags)"
  fi
fi

RESOURCE_INTERVAL="$(carranca_config_get_with_global observability.resource_interval)"
SECRET_MONITORING="$(carranca_config_get_with_global observability.secret_monitoring)"

# Parse capability drop-all for the agent container (Phase 5.5)
CAP_DROP_ALL="$(carranca_config_get_with_global runtime.cap_drop_all)"
[ -z "$CAP_DROP_ALL" ] && CAP_DROP_ALL="true"

CAP_DROP_FLAG=""
if [ "$CAP_DROP_ALL" = "true" ]; then
  CAP_DROP_FLAG="--cap-drop ALL"
fi

# Parse capability additions for the agent container
CAP_ADD_FLAGS=""
while IFS= read -r cap; do
  [ -z "$cap" ] && continue
  CAP_ADD_FLAGS="$CAP_ADD_FLAGS --cap-add $cap"
done < <(carranca_config_get_list_with_global runtime.cap_add 2>/dev/null || true)

# Read-only root filesystem (Phase 5.4)
READ_ONLY="$(carranca_config_get_with_global runtime.read_only)"
[ -z "$READ_ONLY" ] && READ_ONLY="true"

READ_ONLY_FLAGS=""
if [ "$READ_ONLY" = "true" ]; then
  READ_ONLY_FLAGS="--read-only --tmpfs /tmp --tmpfs /var/tmp --tmpfs /run"
fi

# Seccomp and AppArmor profiles (Phase 5.3)
SECCOMP_PROFILE="$(carranca_config_get_with_global runtime.seccomp_profile)"
[ -z "$SECCOMP_PROFILE" ] && SECCOMP_PROFILE="default"
APPARMOR_PROFILE="$(carranca_config_get_with_global runtime.apparmor_profile)"

SECCOMP_FLAG=""
APPARMOR_FLAG=""
if [ "$(uname -s)" = "Linux" ]; then
  case "$SECCOMP_PROFILE" in
    default)
      SECCOMP_FLAG="--security-opt seccomp=$CARRANCA_HOME/runtime/security/seccomp-agent.json"
      ;;
    unconfined)
      SECCOMP_FLAG="--security-opt seccomp=unconfined"
      ;;
    /*)
      # Absolute path to custom profile
      SECCOMP_FLAG="--security-opt seccomp=$SECCOMP_PROFILE"
      ;;
  esac
  if [ -n "$APPARMOR_PROFILE" ] && [ "$APPARMOR_PROFILE" != "unconfined" ]; then
    APPARMOR_FLAG="--security-opt apparmor=$APPARMOR_PROFILE"
  elif [ "$APPARMOR_PROFILE" = "unconfined" ]; then
    APPARMOR_FLAG="--security-opt apparmor=unconfined"
  fi
else
  if [ "$SECCOMP_PROFILE" != "default" ] && [ "$SECCOMP_PROFILE" != "unconfined" ]; then
    carranca_log info "Seccomp profiles not supported on $(uname -s) — skipping"
  fi
fi

EXECVE_TRACING="$(carranca_config_get_with_global observability.execve_tracing)"
NETWORK_LOGGING="$(carranca_config_get_with_global observability.network_logging)"
NETWORK_INTERVAL="$(carranca_config_get_with_global observability.network_interval)"
INDEPENDENT_OBSERVER="$(carranca_config_get_with_global observability.independent_observer)"

# --- Policy: resource limits (4.4) ---
RESOURCE_MEMORY="$(carranca_config_get_with_global policy.resource_limits.memory)"
RESOURCE_CPUS="$(carranca_config_get_with_global policy.resource_limits.cpus)"
RESOURCE_PIDS="$(carranca_config_get_with_global policy.resource_limits.pids)"

RESOURCE_LIMIT_FLAGS=""
if [ -n "$RESOURCE_MEMORY" ]; then
  RESOURCE_LIMIT_FLAGS="$RESOURCE_LIMIT_FLAGS --memory $RESOURCE_MEMORY"
fi
if [ -n "$RESOURCE_CPUS" ]; then
  RESOURCE_LIMIT_FLAGS="$RESOURCE_LIMIT_FLAGS --cpus $RESOURCE_CPUS"
fi
if [ -n "$RESOURCE_PIDS" ]; then
  RESOURCE_LIMIT_FLAGS="$RESOURCE_LIMIT_FLAGS --pids-limit $RESOURCE_PIDS"
fi

# --- Policy: time-boxed sessions (4.5) ---
MAX_DURATION="$(carranca_config_get_with_global policy.max_duration)"

# --- Policy: filesystem access control (4.2) ---
ENFORCE_WATCHED_PATHS="$(carranca_config_get_with_global policy.filesystem.enforce_watched_paths)"
FILESYSTEM_RO_FLAGS=""
ENFORCED_PATHS=""
DEGRADED_GLOBS=""

if [ "$ENFORCE_WATCHED_PATHS" = "true" ]; then
  while IFS= read -r wp; do
    [ -z "$wp" ] && continue
    case "$wp" in
      \*.*)
        # Glob patterns cannot be bind-mounted; degrade gracefully
        if [ -z "$DEGRADED_GLOBS" ]; then
          DEGRADED_GLOBS="$wp"
        else
          DEGRADED_GLOBS="$DEGRADED_GLOBS,$wp"
        fi
        ;;
      */)
        # Directory: overlay bind mount as read-only
        if [ -d "$WORKSPACE/$wp" ]; then
          # D3: Resolve symlinks in watched paths
          local_resolved="$(realpath "$WORKSPACE/$wp" 2>/dev/null || true)"
          if [ -z "$local_resolved" ]; then
            carranca_log warn "watched_paths: could not resolve '$wp' — skipping"
            continue
          fi
          if [ -L "$WORKSPACE/$wp" ]; then
            carranca_log info "watched_paths: '$wp' is a symlink -> $local_resolved"
          fi
          # Ensure resolved path is within the workspace
          case "$local_resolved" in
            "$WORKSPACE"/*)
              ;;
            "$WORKSPACE")
              ;;
            *)
              carranca_log warn "watched_paths: '$wp' resolves to '$local_resolved' which is outside the workspace — skipping"
              continue
              ;;
          esac
          FILESYSTEM_RO_FLAGS="$FILESYSTEM_RO_FLAGS -v $local_resolved:/workspace/$wp:ro"
          if [ -z "$ENFORCED_PATHS" ]; then
            ENFORCED_PATHS="$wp"
          else
            ENFORCED_PATHS="$ENFORCED_PATHS,$wp"
          fi
        fi
        ;;
      *)
        # Specific file: overlay bind mount as read-only
        if [ -e "$WORKSPACE/$wp" ]; then
          # D3: Resolve symlinks in watched paths
          local_resolved="$(realpath "$WORKSPACE/$wp" 2>/dev/null || true)"
          if [ -z "$local_resolved" ]; then
            carranca_log warn "watched_paths: could not resolve '$wp' — skipping"
            continue
          fi
          if [ -L "$WORKSPACE/$wp" ]; then
            carranca_log info "watched_paths: '$wp' is a symlink -> $local_resolved"
          fi
          # Ensure resolved path is within the workspace
          case "$local_resolved" in
            "$WORKSPACE"/*)
              ;;
            "$WORKSPACE")
              ;;
            *)
              carranca_log warn "watched_paths: '$wp' resolves to '$local_resolved' which is outside the workspace — skipping"
              continue
              ;;
          esac
          FILESYSTEM_RO_FLAGS="$FILESYSTEM_RO_FLAGS -v $local_resolved:/workspace/$wp:ro"
          if [ -z "$ENFORCED_PATHS" ]; then
            ENFORCED_PATHS="$wp"
          else
            ENFORCED_PATHS="$ENFORCED_PATHS,$wp"
          fi
        fi
        ;;
    esac
  done < <(carranca_config_get_list watched_paths 2>/dev/null || true)
fi

# --- Policy: technical policy hooks (4.3) ---
DOCS_BEFORE_CODE="$(carranca_config_get_with_global policy.docs_before_code)"
TESTS_BEFORE_IMPL="$(carranca_config_get_with_global policy.tests_before_impl)"

POLICY_HOOKS="false"
POLICY_HOOKS_FLAGS=""
POLICY_HOOKS_ENV=""
if [ "$DOCS_BEFORE_CODE" = "warn" ] || [ "$DOCS_BEFORE_CODE" = "enforce" ] || \
   [ "$TESTS_BEFORE_IMPL" = "warn" ] || [ "$TESTS_BEFORE_IMPL" = "enforce" ]; then
  POLICY_HOOKS="true"
  POLICY_HOOKS_FLAGS="-v $CARRANCA_HOME/runtime/hooks:/carranca-hooks:ro"
  POLICY_HOOKS_ENV="-e POLICY_HOOKS=true -e POLICY_DOCS_BEFORE_CODE=${DOCS_BEFORE_CODE:-off} -e POLICY_TESTS_BEFORE_IMPL=${TESTS_BEFORE_IMPL:-off}"
fi

# --- Policy: fine-grained network policies (4.1) ---
NETWORK_POLICY_FLAGS=""
NETWORK_POLICY_ENV=""
NETWORK_POLICY_ENTRYPOINT=""

if [ "$NETWORK_MODE" = "filtered" ]; then
  # Resolve DNS for allow-list entries and build iptables rules
  NETWORK_POLICY_RULES=""
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    local_host="${entry%%:*}"
    local_port="${entry##*:}"
    [ -z "$local_port" ] && continue

    # Strip wildcard prefix for DNS resolution
    resolve_host="$local_host"
    case "$resolve_host" in
      \*.*) resolve_host="${resolve_host#\*.}" ;;
    esac

    # Resolve hostname to IP(s)
    resolved_ips="$(getent ahosts "$resolve_host" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    if [ -z "$resolved_ips" ]; then
      carranca_log warn "Network policy: could not resolve $local_host — skipping"
      continue
    fi

    while IFS= read -r ip; do
      [ -z "$ip" ] && continue
      if [ -z "$NETWORK_POLICY_RULES" ]; then
        NETWORK_POLICY_RULES="$ip:$local_port"
      else
        NETWORK_POLICY_RULES="$NETWORK_POLICY_RULES,$ip:$local_port"
      fi
    done <<< "$resolved_ips"
  done < <(carranca_config_get_list runtime.network.allow 2>/dev/null || true)

  if [ -n "$NETWORK_POLICY_RULES" ]; then
    NETWORK_POLICY_FLAGS="--cap-add NET_ADMIN -v $CARRANCA_HOME/runtime/network-setup.sh:/usr/local/bin/network-setup.sh:ro"
    NETWORK_POLICY_ENV="-e NETWORK_POLICY_RULES=$NETWORK_POLICY_RULES -e NETWORK_POLICY_USER=$HOST_UID:$HOST_GID"
    NETWORK_POLICY_ENTRYPOINT="--entrypoint /usr/local/bin/network-setup.sh"
    carranca_log info "Network policy: filtered (${NETWORK_POLICY_RULES})"
  else
    carranca_log warn "Network policy: no resolvable allow-list entries — falling back to full deny"
    NETWORK="false"
  fi
fi

CONTAINER_RUNTIME="$(carranca_runtime_cmd)"
LOGGER_CAP_FLAGS="$(carranca_runtime_logger_cap_flags)"
AGENT_IDENTITY_FLAGS="$(carranca_runtime_agent_identity_flags "$HOST_UID" "$HOST_GID")"

# Degrade network policy for rootless Podman (cannot run iptables)
if [ -n "$NETWORK_POLICY_FLAGS" ] && \
   [ "$CONTAINER_RUNTIME" = "podman" ] && carranca_runtime_is_rootless "$CONTAINER_RUNTIME"; then
  carranca_log warn "Network policy: rootless Podman cannot enforce allow-list — falling back to --network=none"
  NETWORK="false"
  NETWORK_MODE="none"
  NETWORK_POLICY_RULES=""
  NETWORK_POLICY_FLAGS=""
  NETWORK_POLICY_ENV=""
  NETWORK_POLICY_ENTRYPOINT=""
fi

# --- Volume config ---

CACHE_ENABLED="$(carranca_config_get_with_global volumes.cache)"
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
done < <(carranca_config_get_list_with_global volumes.extra 2>/dev/null || true)

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
OBSERVER_NAME="$(carranca_session_observer_name "$SESSION_ID")"

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

# When read-only root FS is on and cache is off, agent home needs a writable tmpfs
if [ "$READ_ONLY" = "true" ] && [ "$CACHE_ENABLED" != "true" ]; then
  READ_ONLY_FLAGS="$READ_ONLY_FLAGS --tmpfs $AGENT_HOME"
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

# When independent observer is active, the agent gets its own PID namespace
# and the logger doesn't need SYS_PTRACE (observer handles tracing).
PID_NS_FLAG=""
PTRACE_CAP_FLAG=""
if [ "$INDEPENDENT_OBSERVER" = "true" ]; then
  # Agent gets default PID namespace — no sharing with logger
  : # PID_NS_FLAG stays empty
else
  if [ "$EXECVE_TRACING" = "true" ] || [ "$NETWORK_LOGGING" = "true" ]; then
    PID_NS_FLAG="--pid=container:$LOGGER_NAME"
  fi
  if [ "$EXECVE_TRACING" = "true" ]; then
    PTRACE_CAP_FLAG="--cap-add SYS_PTRACE"
  fi
fi

SECRETMON_CAP_FLAG=""
if [ "${SECRET_MONITORING:-}" = "true" ]; then
  SECRETMON_CAP_FLAG="--cap-add SYS_ADMIN"
fi

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
  $PTRACE_CAP_FLAG \
  -v "$FIFO_VOLUME:/fifo" \
  -v "$WORKSPACE:/workspace:ro" \
  -v "$STATE_DIR:/state" \
  -e "SESSION_ID=$SESSION_ID" \
  -e "REPO_ID=$REPO_ID" \
  -e "REPO_NAME=$REPO_NAME" \
  -e "REPO_PATH=$WORKSPACE" \
  -e "WATCHED_PATHS=$WATCHED_PATHS_ENV" \
  -e "AGENT_NAME=$SELECTED_AGENT_NAME" \
  -e "AGENT_ADAPTER=$AGENT_ADAPTER" \
  -e "ENGINE=$CONTAINER_RUNTIME" \
  -e "EXECVE_TRACING=${EXECVE_TRACING:-}" \
  -v /sys/fs/cgroup:/hostcgroup:ro \
  -e "RESOURCE_INTERVAL=${RESOURCE_INTERVAL:-}" \
  -e "AGENT_CONTAINER_NAME=$AGENT_CONTAINER_NAME" \
  -e "SECRET_MONITORING=${SECRET_MONITORING:-}" \
  -e "NETWORK_LOGGING=${NETWORK_LOGGING:-}" \
  -e "NETWORK_INTERVAL=${NETWORK_INTERVAL:-}" \
  -e "MAX_DURATION=${MAX_DURATION:-}" \
  -e "RESOURCE_MEMORY_LIMIT=${RESOURCE_MEMORY:-}" \
  -e "ENFORCE_WATCHED_PATHS=${ENFORCE_WATCHED_PATHS:-}" \
  -e "ENFORCED_PATHS=${ENFORCED_PATHS:-}" \
  -e "DEGRADED_GLOBS=${DEGRADED_GLOBS:-}" \
  -e "NETWORK_MODE=${NETWORK_MODE:-full}" \
  -e "NETWORK_POLICY_RULES=${NETWORK_POLICY_RULES:-}" \
  -e "INDEPENDENT_OBSERVER=${INDEPENDENT_OBSERVER:-}" \
  $SECRETMON_CAP_FLAG \
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
  carranca_die "Logger FIFO not ready after 15s — fail closed (session cannot proceed without logging)"
fi

# --- Start observer sidecar (Phase 5.1, optional) ---

if [ "$INDEPENDENT_OBSERVER" = "true" ]; then
  carranca_log info "Starting independent observer..."
  # Observer reuses the logger image (already has strace, bash, tools).
  # It gets --pid=host to see all host processes and CAP_SYS_PTRACE for strace.
  # It shares the FIFO volume and state directory but no namespace with the agent.
  # shellcheck disable=SC2086
  carranca_runtime_run -d --rm \
    --name "$OBSERVER_NAME" \
    --pid=host \
    --cap-add SYS_PTRACE \
    -v "$FIFO_VOLUME:/fifo" \
    -v "$STATE_DIR:/state" \
    -e "SESSION_ID=$SESSION_ID" \
    -e "AGENT_CONTAINER_NAME=$AGENT_CONTAINER_NAME" \
    -e "NETWORK_LOGGING=${NETWORK_LOGGING:-}" \
    -e "NETWORK_INTERVAL=${NETWORK_INTERVAL:-}" \
    --entrypoint /usr/local/bin/observer.sh \
    "$LOGGER_IMAGE" >/dev/null
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

# Resolve agent container ID in background for resource sampler cgroup lookup.
# The logger polls /state/agent-container-id for the resolved full ID.
_resolve_agent_container_id() {
  local attempts=0
  while [ "$attempts" -lt 30 ]; do
    local cid
    cid="$(carranca_runtime_call inspect --format '{{.Id}}' "$AGENT_CONTAINER_NAME" 2>/dev/null || true)"
    if [ -n "$cid" ]; then
      printf '%s' "$cid" > "$STATE_DIR/agent-container-id"
      return 0
    fi
    sleep 1
    attempts=$((attempts + 1))
  done
} &

# shellcheck disable=SC2086
AGENT_EXIT_CODE=0
# When network-setup entrypoint is active, the container must start as root
# for iptables. network-setup.sh drops privileges before exec-ing shell-wrapper.
EFFECTIVE_IDENTITY_FLAGS="$AGENT_IDENTITY_FLAGS"
if [ -n "$NETWORK_POLICY_ENTRYPOINT" ]; then
  EFFECTIVE_IDENTITY_FLAGS=""
fi

carranca_runtime_run $TTY_FLAGS --rm \
  --name "$AGENT_CONTAINER_NAME" \
  $EFFECTIVE_IDENTITY_FLAGS \
  $PID_NS_FLAG \
  -v "$FIFO_VOLUME:/fifo" \
  -v "$WORKSPACE:/workspace:rw" \
  -e "HOME=$AGENT_HOME" \
  -e "USER=carranca" \
  $CACHE_FLAGS \
  $CUSTOM_VOLUME_FLAGS \
  $SKILL_MOUNT_FLAGS \
  $EXTRA_GROUP_FLAGS \
  $SECCOMP_FLAG \
  $APPARMOR_FLAG \
  $CAP_DROP_FLAG \
  $CAP_ADD_FLAGS \
  -e "AGENT_COMMAND=$AGENT_COMMAND" \
  -e "SESSION_ID=$SESSION_ID" \
  $NETWORK_FLAG \
  $RESOURCE_LIMIT_FLAGS \
  $READ_ONLY_FLAGS \
  $FILESYSTEM_RO_FLAGS \
  $POLICY_HOOKS_FLAGS \
  $POLICY_HOOKS_ENV \
  $NETWORK_POLICY_FLAGS \
  $NETWORK_POLICY_ENV \
  $NETWORK_POLICY_ENTRYPOINT \
  $EXTRA_FLAGS \
  "$AGENT_IMAGE" || AGENT_EXIT_CODE=$?

# Detect logger loss — if the logger container is gone but the agent exited
# non-zero, the session lost its audit trail and must fail closed.
if [ "$AGENT_EXIT_CODE" -ne 0 ]; then
  LOGGER_RUNNING="$(carranca_runtime_call inspect --format '{{.State.Running}}' "$LOGGER_NAME" 2>/dev/null || true)"
  if [ "$LOGGER_RUNNING" != "true" ]; then
    carranca_log error "Logger lost during session — fail closed (audit trail interrupted)"
  fi
fi

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
