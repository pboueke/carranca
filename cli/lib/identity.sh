#!/usr/bin/env bash
# carranca/cli/lib/identity.sh — Repo identity computation

carranca_repo_id() {
  local remote_url
  remote_url="$(git remote get-url origin 2>/dev/null || true)"
  if [ -n "$remote_url" ]; then
    printf '%s' "$remote_url" | sha256sum | cut -c1-12
  else
    printf '%s' "$(realpath .)" | sha256sum | cut -c1-12
  fi
}

carranca_repo_name() {
  basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
}
