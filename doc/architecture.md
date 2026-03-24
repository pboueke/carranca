# Architecture

## Overview

Carranca runs coding agents inside containers with host isolation and structured
session logging. There is no compose layer; the CLI talks directly to a
supported container runtime command.

Today the supported runtime engines are:

- `podman`
- `docker`

Runtime selection precedence is:

1. `CARRANCA_CONTAINER_RUNTIME`
2. `.carranca.yml` `runtime.engine`
3. `auto` detection, which prefers Podman and falls back to Docker

Projects are configured through `.carranca.yml` using an ordered `agents:` list.
The first configured agent is the default execution target for `run` and
`config`, and `--agent <name>` selects a different configured agent explicitly.
Session ids are 8-char hex values and name all ephemeral runtime resources for a
single run: the agent container, logger container, FIFO tmpfs volume, and
transient images.

```
  carranca run
       │
       ├── <runtime> build (logger image from runtime/Containerfile.logger)
       ├── <runtime> build (agent image from .carranca/Containerfile)
       ├── <runtime> volume create (shared tmpfs for FIFO)
       │
       ├── <runtime> run -d (logger)
       │     ├── creates FIFO on shared volume
       │     ├── starts inotifywait (or fswatch fallback) on /workspace (read-only)
       │     ├── reads FIFO events
       │     └── writes JSONL, checksum, and HMAC key files to /state/
       │
       └── <runtime> run -it (agent)
             ├── shell-wrapper opens FIFO
             ├── writes shell events to FIFO
             ├── heartbeat every 30s
             └── runs agent command interactively
```

## Session lifecycle

A `carranca run` session owns a small set of runtime resources:

- `carranca-<session>-agent` container
- `carranca-<session>-logger` container
- `carranca-<session>-fifo` tmpfs volume
- `carranca-<session>-agent` and `carranca-<session>-logger` transient images

Lifecycle is explicit:

1. Carranca computes a fresh `session_id`
2. It builds the transient logger and agent images
3. It creates the shared FIFO volume
4. It starts the logger container
5. It starts the interactive agent container
6. On normal exit, `SIGINT`, `SIGTERM`, or `carranca kill`, it stops the agent,
   stops the logger gracefully so it can flush `logger_stop`, then removes the
   FIFO volume and transient images

This teardown path is idempotent. Interrupted interactive sessions should not
leave the logger container behind.

## Session management commands

Carranca exposes two complementary session-management commands:

- `carranca status` shows active sessions for the current repo and recent logs
- `carranca kill` stops either one exact session (`--session <id>`) or all
  active sessions globally after confirmation

`status` is repo-scoped because logs are stored under the current repo's
`repo_id`. `kill` is global because active container resources are not tied to
the current working directory once they are running.

## Containers

Two containers share a tmpfs volume containing a Unix FIFO:

**Logger** (`runtime/Containerfile.logger`):
- Managed by carranca, not user-configurable
- Alpine-based, minimal (~7MB)
- Mounts: FIFO volume (rw), workspace (ro), state dir (rw)
- Capabilities: requests `CAP_LINUX_IMMUTABLE` for `chattr +a`; rootless Podman
  degrades to `--userns keep-id`, so append-only is best-effort there too
- Owns the per-session `.jsonl`, `.checksums`, and `.hmac-key` files used by
  `carranca log --verify` and `carranca log --export`

**Agent** (`.carranca/Containerfile`):
- User-configurable per project
- Copied to `.carranca/` on `carranca init`
- The user installs their agent CLI, language runtimes, tools
- Mounts: FIFO volume (rw), workspace (rw), optional cache dir (rw), optional custom volumes, repo-local Carranca skills during `run`, repo-local user skills, and install-managed Carranca skills during `config`
- Runs as the invoking host UID:GID on Linux, or `--userns keep-id` on rootless Podman, so bind-mounted workspace writes keep usable host ownership
- The shell wrapper is always injected as the entrypoint
- When fine-grained network policies are active (`runtime.network` object form),
  the entrypoint is overridden to `network-setup.sh` which applies iptables rules
  before exec-ing the shell wrapper

## Data flow

```
  Agent container                    Logger container
  ┌──────────────────┐              ┌──────────────────┐
  │ shell-wrapper.sh │              │ logger.sh        │
  │   │              │              │   │              │
  │   ├─ agent cmd   │   FIFO      │   ├─ read FIFO ──┤──► session.jsonl
  │   ├─ heartbeat ──┼──────►──────┼───┤              │    + .checksums
  │   └─ exit code   │  (tmpfs)    │   ├─ inotifywait─┤ (or fswatch)
  │                  │              │   └─ HMAC chain ─┤──► .hmac-key
  │                  │              │   │  /workspace  │
  │ /workspace (rw)  │              │ /workspace (ro)  │
  └──────────────────┘              └──────────────────┘
```

## Directory layout

| Path | Mutable | Owner | Purpose |
|------|---------|-------|---------|
| `~/.local/share/carranca/` | No | Install | CLI, runtime assets, templates, and shipped skills |
| `~/.local/state/carranca/sessions/<repo-id>/` | Yes | Carranca | Session JSONL logs plus per-session `.checksums`, `.hmac-key`, `.tar`, and `.tar.sig` files |
| `~/.local/state/carranca/config/<repo-id>/` | Yes | Carranca | Config workflow proposals and audit history |
| `~/.local/state/carranca/cache/<repo-id>/home/` | Yes | Agent | Persistent agent home dir mounted at `/home/carranca` (auth, config, history) |
| `~/.config/carranca/config.yml` | Yes | User | Optional user-wide defaults for `runtime.*`, `volumes.*`, `observability.*`, and `policy.*` |
| `.carranca.yml` | Yes | User | Per-project configuration, including the ordered `agents:` list |
| `.carranca/Containerfile` | Yes | User | Agent container definition |
| `.carranca/shell-wrapper.sh` | No | Carranca | Injected into agent image at build |
| `.carranca/skills/carranca/` | Yes | User/Repo | Repo-local Carranca workflow skills scaffolded by `init` and mounted by `run` when present |
| `.carranca/skills/user/` | Yes | User | Per-project user-authored skills |

## Repo identity

`repo_id = sha256(git remote get-url origin)[:12]`

Falls back to `sha256(realpath(.))[:12]` for repos without a remote. Two repos
with the same name at different paths get distinct IDs. Moving a repo orphans
old sessions (documented, not a bug).
