#!/usr/bin/env bash
# Shared helpers for runtime-backed integration and failure tests.

integration_init() {
  TEST_ROOT="$(mktemp -d)"
  TMPSTATE="$TEST_ROOT/state"
  TMPDIR="$TEST_ROOT/repo"
  mkdir -p "$TMPSTATE" "$TMPDIR"
  export CARRANCA_STATE="$TMPSTATE"
  export CARRANCA_HOME="${CARRANCA_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  RUNTIME="${CARRANCA_CONTAINER_RUNTIME:-podman}"
}

integration_require_runtime() {
  if ! "$RUNTIME" info >/dev/null 2>&1; then
    echo "  SKIP: $RUNTIME not available"
    exit 0
  fi
}

integration_create_repo() {
  cd "$TMPDIR"
  git init --quiet
}

integration_init_project() {
  bash "$CARRANCA_HOME/cli/init.sh"
}

integration_repo_id() {
  source "$CARRANCA_HOME/cli/lib/common.sh"
  source "$CARRANCA_HOME/cli/lib/identity.sh"
  carranca_repo_id
}

integration_latest_log() {
  local repo_id="${1:-$(integration_repo_id)}"
  find "$TMPSTATE/sessions/$repo_id" -maxdepth 1 -type f -name '*.jsonl' 2>/dev/null | sort | tail -1
}

integration_session_ids() {
  find "$TMPSTATE/sessions" -maxdepth 2 -type f -name '*.jsonl' 2>/dev/null | \
    sed -n 's#.*/\([0-9a-f][0-9a-f]*\)\.jsonl$#\1#p' | sort -u
}

integration_cleanup_runtime_artifacts() {
  local session_id

  while IFS= read -r session_id; do
    [ -z "$session_id" ] && continue
    "$RUNTIME" rm -f "carranca-$session_id-agent" >/dev/null 2>&1 || true
    "$RUNTIME" rm -f "carranca-$session_id-logger" >/dev/null 2>&1 || true
    "$RUNTIME" volume rm "carranca-$session_id-fifo" >/dev/null 2>&1 || true
    "$RUNTIME" rmi "carranca-$session_id-agent" "carranca-$session_id-logger" >/dev/null 2>&1 || true
  done < <(integration_session_ids)
}

integration_cleanup_files() {
  if command -v chattr >/dev/null 2>&1; then
    find "$TMPSTATE" -type f -exec chattr -a {} \; 2>/dev/null || true
  fi

  rm -rf "$TEST_ROOT" 2>/dev/null || true
}

integration_cleanup() {
  integration_cleanup_runtime_artifacts
  integration_cleanup_files
}
