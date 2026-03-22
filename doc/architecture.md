# Architecture

## Overview

Carranca runs coding agents inside Docker containers with host isolation and
structured session logging. No docker-compose — just `docker run`.

Projects are configured through `.carranca.yml` using an ordered `agents:` list.
The first configured agent is the default execution target for `run` and
`config`, and `--agent <name>` selects a different configured agent explicitly.

```
  carranca run
       │
       ├── docker build (logger image from runtime/Containerfile.logger)
       ├── docker build (agent image from .carranca/Containerfile)
       ├── docker volume create (shared tmpfs for FIFO)
       │
       ├── docker run -d (logger)
       │     ├── creates FIFO on shared volume
       │     ├── starts inotifywait on /workspace (read-only)
       │     ├── reads FIFO events
       │     └── writes JSONL to /state/{session}.jsonl
       │
       └── docker run -it (agent)
             ├── shell-wrapper opens FIFO
             ├── writes shell events to FIFO
             ├── heartbeat every 30s
             └── runs agent command interactively
```

## Containers

Two containers share a tmpfs volume containing a Unix FIFO:

**Logger** (`runtime/Containerfile.logger`):
- Managed by carranca, not user-configurable
- Alpine-based, minimal (~7MB)
- Mounts: FIFO volume (rw), workspace (ro), state dir (rw)
- Capabilities: `CAP_LINUX_IMMUTABLE` for `chattr +a`

**Agent** (`.carranca/Containerfile`):
- User-configurable per project
- Copied to `.carranca/` on `carranca init`
- The user installs their agent CLI, language runtimes, tools
- Mounts: FIFO volume (rw), workspace (rw), cache dirs (rw), custom volumes, Carranca skills (ro), user skills (ro)
- Runs as the invoking host UID:GID on Linux so bind-mounted workspace writes keep host ownership
- The shell wrapper is always injected as the entrypoint

## Data flow

```
  Agent container                    Logger container
  ┌──────────────────┐              ┌──────────────────┐
  │ shell-wrapper.sh │              │ logger.sh        │
  │   │              │              │   │              │
  │   ├─ agent cmd   │   FIFO      │   ├─ read FIFO ──┤──► session.jsonl
  │   ├─ heartbeat ──┼──────►──────┼───┤              │    (append-only)
  │   └─ exit code   │  (tmpfs)    │   ├─ inotifywait─┤
  │                  │              │   │  /workspace  │
  │ /workspace (rw)  │              │ /workspace (ro)  │
  └──────────────────┘              └──────────────────┘
```

## Directory layout

| Path | Mutable | Owner | Purpose |
|------|---------|-------|---------|
| `~/.local/share/carranca/` | No | Install | CLI, runtime images, templates, default skills |
| `~/.local/state/carranca/sessions/<repo-id>/` | Yes | Carranca | Session JSONL logs |
| `~/.local/state/carranca/cache/<repo-id>/home/` | Yes | Agent | Persistent agent home dir mounted at `/home/carranca` (auth, config, history) |
| `~/.config/carranca/config.yml` | Yes | User | Global settings (future) |
| `.carranca.yml` | Yes | User | Per-project configuration, including the ordered `agents:` list |
| `.carranca/Containerfile` | Yes | User | Agent container definition |
| `.carranca/shell-wrapper.sh` | No | Carranca | Injected into agent image at build |
| `.carranca/skills/carranca/` | No | Carranca | Carranca-managed project skills copied on init |
| `.carranca/skills/user/` | Yes | User | Per-project user-authored skills |

## Repo identity

`repo_id = sha256(git remote get-url origin)[:12]`

Falls back to `sha256(realpath(.))[:12]` for repos without a remote. Two repos
with the same name at different paths get distinct IDs. Moving a repo orphans
old sessions (documented, not a bug).
