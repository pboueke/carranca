# Quickstart

Get from zero to a running agent session in under five minutes.

## Prerequisites

- **Container runtime**: [Podman](https://podman.io/) (preferred) or
  [Docker](https://www.docker.com/). Carranca auto-detects which is available;
  set `CARRANCA_CONTAINER_RUNTIME` to force one.
- **Bash 4+** (ships with most Linux distributions; on macOS use `brew install bash`).
- An **agent CLI** already installed on your host (e.g. `codex`, `claude`, or
  `opencode`). Carranca runs the agent inside a container, but `carranca init`
  needs to know which starter to scaffold.

## Install

```bash
git clone https://github.com/pboueke/carranca.git ~/.local/share/carranca
export PATH="$HOME/.local/share/carranca/cli:$PATH"
```

Add the `export` line to `~/.bashrc` or `~/.zshrc` so it persists across
sessions.

Verify the install:

```bash
carranca help
```

## Initialize a project

```bash
cd your-project
carranca init --agent codex      # or claude, opencode
```

This creates two files in the project root:

| File | Purpose |
|------|---------|
| `.carranca.yml` | Runtime settings, policy, observability, and agent config |
| `.carranca/Containerfile` | Container image definition — add project deps here |

## Customize the container (optional)

Let Carranca's config agent inspect your repo and propose container and config
updates:

```bash
carranca config --prompt "install project dev tools"
```

Carranca shows a diff of proposed changes and waits for confirmation before
applying.

## Run an agent session

```bash
carranca run --agent codex
```

Carranca builds transient images, starts the logger, and launches the agent
inside a hardened container (read-only root, all capabilities dropped, seccomp
filtering). Your workspace is bind-mounted at `/workspace`.

## Inspect the session

```bash
# Latest session summary
carranca log

# Compact event timeline
carranca log --timeline

# Verify HMAC chain integrity
carranca log --verify

# Show active and recent sessions
carranca status
```

## What happens under the hood

```
  carranca run
       |
       +-- logger   (FIFO consumer, JSONL + HMAC chain, file watcher)
       +-- observer  (optional: independent execve + network tracing)
       +-- agent     (shell-wrapper + your agent command)
```

Every shell command, file mutation, network connection, and resource sample is
recorded in a structured JSONL log with an HMAC-signed event chain. The agent
cannot access the signing key.

## Next steps

| Topic | Doc |
|-------|-----|
| Full CLI reference | [usage.md](usage.md) |
| `.carranca.yml` schema | [configuration.md](configuration.md) |
| CI/CD integration | [ci.md](ci.md) |
| Example configs by persona | [examples/README.md](examples/README.md) |
| Security boundaries | [trust-model.md](trust-model.md) |
