#!/usr/bin/env bash
# carranca/cli/lib/runtime.sh — Container runtime resolution and helpers

_CARRANCA_RESOLVED_RUNTIME=""
_CARRANCA_RESOLVED_ROOTLESS=""

carranca_runtime_validate_engine() {
  case "$1" in
    auto|docker|podman) return 0 ;;
    *) return 1 ;;
  esac
}

carranca_runtime_configured_engine() {
  local file="${1:-${CARRANCA_CONFIG_FILE:-.carranca.yml}}"
  local engine=""

  if declare -F carranca_config_get >/dev/null 2>&1 && [ -f "$file" ]; then
    engine="$(carranca_config_get runtime.engine "$file")"
  fi

  printf '%s' "$engine"
}

carranca_runtime_engine_setting() {
  local configured_engine=""
  local engine=""

  if [ -n "${CARRANCA_CONTAINER_RUNTIME:-}" ]; then
    engine="$CARRANCA_CONTAINER_RUNTIME"
  else
    configured_engine="$(carranca_runtime_configured_engine)"
    engine="${configured_engine:-auto}"
  fi

  carranca_runtime_validate_engine "$engine" || \
    carranca_die "Unsupported runtime.engine: $engine (expected auto, docker, or podman)"
  printf '%s' "$engine"
}

carranca_runtime_is_available() {
  local runtime="$1"

  command -v "$runtime" >/dev/null 2>&1 || return 1
  "$runtime" info >/dev/null 2>&1
}

carranca_runtime_is_rootless() {
  local runtime="$1"

  if [ -n "$_CARRANCA_RESOLVED_ROOTLESS" ]; then
    [ "$_CARRANCA_RESOLVED_ROOTLESS" = "yes" ]
    return
  fi

  local rootless=""
  rootless="$("$runtime" info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)"
  case "$rootless" in
    true|True|TRUE)
      _CARRANCA_RESOLVED_ROOTLESS="yes"
      return 0
      ;;
    *)
      _CARRANCA_RESOLVED_ROOTLESS="no"
      return 1
      ;;
  esac
}

carranca_runtime_cmd() {
  if [ -n "$_CARRANCA_RESOLVED_RUNTIME" ]; then
    printf '%s' "$_CARRANCA_RESOLVED_RUNTIME"
    return 0
  fi

  local setting runtime

  setting="$(carranca_runtime_engine_setting)"

  if [ "$setting" = "auto" ]; then
    for runtime in podman docker; do
      if carranca_runtime_is_available "$runtime"; then
        _CARRANCA_RESOLVED_RUNTIME="$runtime"
        printf '%s' "$runtime"
        return 0
      fi
    done
    carranca_die "No supported container runtime is available. Install or start Podman or Docker."
  fi

  if ! carranca_runtime_is_available "$setting"; then
    carranca_die "Configured container runtime is not available: $setting"
  fi

  _CARRANCA_RESOLVED_RUNTIME="$setting"
  printf '%s' "$setting"
}

carranca_runtime_logger_cap_flags() {
  local runtime
  runtime="$(carranca_runtime_cmd)"

  if [ "$runtime" = "podman" ] && carranca_runtime_is_rootless "$runtime"; then
    # Rootless podman cannot grant LINUX_IMMUTABLE; logger degrades gracefully
    printf '%s' "--userns keep-id"
    return 0
  fi

  printf '%s' "--cap-add LINUX_IMMUTABLE"
}

carranca_runtime_agent_identity_flags() {
  local runtime host_uid host_gid
  runtime="$(carranca_runtime_cmd)"
  host_uid="${1:-$(id -u)}"
  host_gid="${2:-$(id -g)}"

  if [ "$runtime" = "podman" ] && carranca_runtime_is_rootless "$runtime"; then
    printf '%s' "--userns keep-id"
    return 0
  fi

  printf '%s' "--user $host_uid:$host_gid"
}

carranca_runtime_call() {
  local runtime
  runtime="$(carranca_runtime_cmd)"
  "$runtime" "$@"
}

carranca_runtime_build() {
  carranca_runtime_call build "$@"
}

carranca_runtime_run() {
  carranca_runtime_call run "$@"
}

carranca_runtime_exec() {
  carranca_runtime_call exec "$@"
}

carranca_runtime_ps() {
  carranca_runtime_call ps "$@"
}

carranca_runtime_rm() {
  carranca_runtime_call rm "$@"
}

carranca_runtime_stop() {
  carranca_runtime_call stop "$@"
}

carranca_runtime_rmi() {
  carranca_runtime_call rmi "$@"
}

carranca_runtime_volume() {
  carranca_runtime_call volume "$@"
}

carranca_runtime_require() {
  carranca_runtime_cmd >/dev/null
}
