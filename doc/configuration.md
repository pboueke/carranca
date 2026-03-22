# Configuration

## `.carranca.yml`

Per-project configuration file created by `carranca init`. Lives in the project root.

```yaml
# Agent settings
agent:
  adapter: default              # Agent adapter (currently only "default")
  command: codex                # CLI command to run inside the container

# Container runtime settings
runtime:
  network: true                 # Container network access (false = --network=none)
  # extra_flags: --gpus all     # Extra docker run flags for the agent
  # logger_extra_flags:         # Extra docker run flags for the logger

# Persistent volumes for the agent container
volumes:
  cache: true                   # Cache agent memory, config, session across runs
  # extra:                      # Custom volume mounts (host:container[:mode])
  #   - ~/.ssh:/home/carranca/.ssh:ro
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
| `agent.adapter` | No | `default` | Agent adapter type (`default`, `claude`, `codex`, or `stdin`) |
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
    - ~/.ssh:/home/carranca/.ssh:ro
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

## `carranca config`

`carranca config` runs the bound agent inside the sandboxed Carranca container and
asks it to use Carranca's `confiskill` before proposing updates to both
`.carranca.yml` and `.carranca/Containerfile`.

The command mounts skills into the agent container in two separate locations:

- Carranca-managed skills: `/carranca-skills`
- User-managed skills: `/user-skills`

The proposal prompt explicitly requires the agent to:

- read and follow `/carranca-skills/confiskill/SKILL.md`
- inspect any user-provided skills under `/user-skills/`
- write complete proposed files to `/proposal` instead of editing the workspace directly

`carranca config` allocates a TTY exactly like `carranca run` when stdin is a
terminal, so the agent can reuse the same interactive auth/session flow.

Adapter handling remains explicit:

- `agent.adapter: claude` runs the configured Claude command in its normal interactive mode with the config prompt as the initial request
- `agent.adapter: codex` runs the configured Codex command in its normal interactive mode with the config prompt as the initial request
- `agent.adapter: stdin` pipes the generated config prompt to the command on stdin
- `agent.adapter: default` infers `claude` or `codex` only when the command itself starts with `claude` or `codex`; otherwise it falls back to `stdin`

By default, `carranca config` is propose-only until you confirm:

```bash
carranca config
```

It prints:

- detected workspace profile
- rationale for each proposed change
- unified diff for `.carranca.yml` and `.carranca/Containerfile`

To bypass the prompt and apply immediately, use:

```bash
carranca config --dangerously-skip-confirmation
```

This still prints the rationale and diff first, emits a strict warning, and records
that confirmation was bypassed in the config audit log under
`~/.local/state/carranca/config/<repo-id>/history.jsonl`.

### Cache volume

When `volumes.cache` is `true` (the default), carranca persists the agent container's
home directory (`/home/carranca`) across sessions by bind-mounting a host directory:

| Host path | Container path | Purpose |
|-----------|---------------|---------|
| `~/.local/state/carranca/cache/<repo-id>/home/` | `/home/carranca` | Agent home directory (auth, config, session history) |

This means agent-specific data — credentials (`~/.claude/.credentials.json`),
session history, configuration — survives container teardown and is reused on
subsequent `carranca run` invocations for the same repo. Each repo gets its own
isolated cache. On Linux, the agent container runs as the invoking host UID:GID so
files created on bind-mounted paths keep host ownership instead of becoming `root`-owned.

### Custom volumes

The `volumes.extra` list accepts entries in Docker bind-mount format: `host:container[:mode]`.
The `~` prefix in host paths is expanded to `$HOME`. Common use cases:

- **Git SSH keys**: `~/.ssh:/home/carranca/.ssh:ro` — lets the agent push/pull via SSH
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

Carranca separates toolkit-managed skills from user-managed skills inside the repo:

- `.carranca/skills/carranca/` — skills copied from the Carranca install, such as `plan` and `confiskill`
- `.carranca/skills/user/` — user-authored project-specific skills

Both directories are mounted into the agent container during `carranca run` and
`carranca config`:

- `.carranca/skills/carranca/` → `/carranca-skills`
- `.carranca/skills/user/` → `/user-skills`

This keeps Carranca's built-in workflow skills separate from repo-local user guidance
while still making both available to the agent.
