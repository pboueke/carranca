# Configuration

## `.carranca.yml`

Per-project configuration file created by `carranca init`. Lives in the project root.

```yaml
# Agent settings
agent:
  adapter: default              # Agent adapter (currently only "default")
  command: claude               # CLI command to run inside the container

# Container runtime settings
runtime:
  network: true                 # Container network access (false = --network=none)
  # extra_flags: --gpus all     # Extra docker run flags for the agent
  # logger_extra_flags:         # Extra docker run flags for the logger

# Persistent volumes for the agent container
volumes:
  cache: true                   # Cache agent memory, config, session across runs
  # extra:                      # Custom volume mounts (host:container[:mode])
  #   - ~/.ssh:/home/user/.ssh:ro
  #   - ~/docs:/reference:ro

# Policy guidance levels ("warn" or "off")
policy:
  docs_before_code: warn        # Suggest docs-first workflow via skills
  tests_before_impl: warn       # Suggest test-first workflow via skills

# Paths to flag in the session log when mutated
# NOTE: only mutations (CREATE, MODIFY, DELETE) are captured, not reads
watched_paths:
  - .env
  - secrets/
  - "*.key"
```

### Required fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `agent.command` | Yes | — | The CLI command to run as the agent |
| `agent.adapter` | No | `default` | Agent adapter type |
| `runtime.network` | No | `true` | Enable/disable container networking |
| `runtime.extra_flags` | No | — | Additional `docker run` flags for agent |
| `runtime.logger_extra_flags` | No | — | Additional `docker run` flags for logger |
| `volumes.cache` | No | `true` | Persistent cache for agent memory/config/session |
| `volumes.extra` | No | — | Custom volume mounts (`host:container[:mode]`) |

### Examples

**Claude Code:**
```yaml
agent:
  command: claude
```

**Codex CLI:**
```yaml
agent:
  command: codex
```

**GPU-enabled agent:**
```yaml
agent:
  command: my-agent
runtime:
  extra_flags: --gpus all
```

**Fully isolated (no network):**
```yaml
agent:
  command: claude
runtime:
  network: false
```

**Agent with SSH keys and extra reference code:**
```yaml
agent:
  command: claude
volumes:
  cache: true
  extra:
    - ~/.ssh:/home/user/.ssh:ro
    - ~/projects/shared-lib:/reference/shared-lib:ro
    - ~/docs/api-specs:/reference/api-specs:ro
```

**Disable cache (ephemeral sessions only):**
```yaml
agent:
  command: claude
volumes:
  cache: false
```

### Cache volume

When `volumes.cache` is `true` (the default), carranca persists the agent container's
home directory (`/root`) across sessions by bind-mounting a host directory:

| Host path | Container path | Purpose |
|-----------|---------------|---------|
| `~/.local/state/carranca/cache/<repo-id>/home/` | `/root` | Agent home directory (auth, config, session history) |

This means agent-specific data — credentials (`~/.claude/.credentials.json`),
session history, configuration — survives container teardown and is reused on
subsequent `carranca run` invocations for the same repo. Each repo gets its own
isolated cache.

### Custom volumes

The `volumes.extra` list accepts entries in Docker bind-mount format: `host:container[:mode]`.
The `~` prefix in host paths is expanded to `$HOME`. Common use cases:

- **Git SSH keys**: `~/.ssh:/home/user/.ssh:ro` — lets the agent push/pull via SSH
- **Reference docs**: `~/docs:/reference:ro` — give the agent read access to specs, docs, or other repos
- **Shared data**: `~/data:/data:rw` — bidirectional data exchange

Custom volumes are only mounted in the agent container, not the logger.

## `.carranca/Containerfile`

User-configurable Containerfile for the agent container. Created by `carranca init`,
customized by the user. The last lines (shell wrapper injection) must not be removed.

```
FROM alpine:3.21

RUN apk add --no-cache bash coreutils curl git ca-certificates

# Your dependencies here:
RUN apk add --no-cache nodejs npm && \
    npm install -g @anthropic-ai/claude-code

# Do not remove below this line
COPY shell-wrapper.sh /usr/local/bin/shell-wrapper.sh
RUN chmod +x /usr/local/bin/shell-wrapper.sh
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/shell-wrapper.sh"]
```

### Quick-start with `--claude` or `--codex`

```bash
carranca init --claude    # Pre-configures Claude Code
carranca init --codex     # Pre-configures Codex CLI
carranca init             # Bare container — edit Containerfile yourself
```

## `.carranca/skills/`

SKILL.md files that provide policy guidance to the agent. These are prompt-level
instructions — they shape behavior, they don't enforce it technically.

Skills are copied from `carranca/skills/` on `carranca init` and can be customized
per project.
