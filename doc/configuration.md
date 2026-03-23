# Configuration

## What Carranca reads today

Carranca currently reads configuration from:

- `.carranca.yml` in the project root
- `.carranca/Containerfile` in the project root
- `CARRANCA_CONTAINER_RUNTIME` as an environment override for runtime selection
- `~/.config/carranca/config.yml` for user-wide runtime and volume defaults (overridden by project config)

## Global config

Carranca reads user-wide defaults from:

```text
~/.config/carranca/config.yml
```

Override the directory with `CARRANCA_CONFIG_DIR`.

Only `runtime.*`, `volumes.*`, and `observability.*` settings are read from global config.
Project-level `.carranca.yml` always takes precedence. Lists (like
`runtime.cap_add` and `volumes.extra`) are not merged — the project list
replaces the global list entirely when present.

Example global config:

```yaml
runtime:
  engine: podman
  network: false
  cap_add:
    - SYS_PTRACE

volumes:
  cache: true
  extra:
    - ~/.ssh:/home/carranca/.ssh:ro
```

## `.carranca.yml`

Carranca supports only the ordered `agents:` format for project config.

```yaml
agents:
  - name: codex
    adapter: codex
    command: codex

runtime:
  engine: auto
  network: true
  # extra_flags: --gpus all
  # logger_extra_flags:

volumes:
  cache: true
  # extra:
  #   - ~/.ssh:/home/carranca/.ssh:ro
  #   - ~/docs:/reference:ro

policy:
  docs_before_code: warn
  tests_before_impl: warn

watched_paths:
  - .env
  - secrets/
  - "*.key"

observability:
  resource_interval: 10
  execve_tracing: false
  network_logging: false
  network_interval: 5
  secret_monitoring: false
```

### Field reference

| Field | Required | Default | Current behavior |
|-------|----------|---------|------------------|
| `agents` | Yes | — | Ordered configured agents; the first entry is the default for `run` and `config` |
| `agents[].name` | Yes | — | Stable selector used by `--agent <name>` |
| `agents[].command` | Yes | — | Command executed inside the agent container |
| `agents[].adapter` | No | `default` | Adapter selection: `default`, `claude`, `codex`, `opencode`, or `stdin` |
| `runtime.engine` | No | `auto` | Runtime engine: `auto`, `docker`, or `podman` |
| `runtime.network` | No | `true` | `false` adds `--network=none` to the agent and config-agent container |
| `runtime.extra_flags` | No | — | Extra flags appended to the agent container `run` command |
| `runtime.logger_extra_flags` | No | — | Extra flags appended to the logger container `run` command |
| `runtime.cap_add` | No | — | List of Linux capabilities added to the agent container via `--cap-add` |
| `volumes.cache` | No | `true` | Persists `/home/carranca` under `~/.local/state/carranca/cache/<repo-id>/home/` |
| `volumes.extra` | No | — | Extra bind mounts added only to the agent container |
| `policy.docs_before_code` | No | — | Parsed and scaffolded, but not enforced by the current CLI |
| `policy.tests_before_impl` | No | — | Parsed and scaffolded, but not enforced by the current CLI |
| `watched_paths` | No | — | File events matching watched patterns are tagged with `"watched":true` in session logs |
| `observability.resource_interval` | No | `10` | Seconds between cgroup resource samples; `0` disables |
| `observability.execve_tracing` | No | `false` | Enable strace-based execve tracing; adds `CAP_SYS_PTRACE` to logger |
| `observability.network_logging` | No | `false` | Enable `/proc/net/tcp` polling for outbound connections; requires PID namespace sharing |
| `observability.network_interval` | No | `5` | Seconds between network connection polls |
| `observability.secret_monitoring` | No | `false` | Enable fanotify-based file read monitoring on `watched_paths`; adds `CAP_SYS_ADMIN` to logger |

### Runtime resolution

Runtime selection precedence is:

1. `CARRANCA_CONTAINER_RUNTIME`, if set
2. `.carranca.yml` `runtime.engine`, if set
3. `auto`, which detects a local runtime and prefers Podman before Docker

If `runtime.engine` or `CARRANCA_CONTAINER_RUNTIME` is set to an unsupported
value, Carranca fails fast.

### Agent adapters

Carranca resolves the effective driver for an agent like this:

- `adapter: claude` uses the configured command in Claude-style interactive mode
- `adapter: codex` uses the configured command in Codex-style interactive mode
- `adapter: opencode` uses the configured command in OpenCode-style interactive mode
- `adapter: stdin` pipes the generated prompt to the command on stdin
- `adapter: default` infers `claude`, `codex`, or `opencode` only when the command itself
  starts with `claude`, `codex`, or `opencode`; otherwise it falls back to `stdin`

### Starter agents

`carranca init --agent <name>` only scaffolds supported starters:

- `codex`
- `claude`
- `opencode`

The generated config still uses the general `agents:` format, so you can add or
rename agents afterward.

### Examples

Claude:

```yaml
agents:
  - name: claude
    adapter: claude
    command: claude
```

Codex:

```yaml
agents:
  - name: codex
    adapter: codex
    command: codex
```

OpenCode:

```yaml
agents:
  - name: opencode
    adapter: opencode
    command: opencode
```

Custom stdin-driven agent:

```yaml
agents:
  - name: shell
    adapter: stdin
    command: bash /usr/local/bin/my-agent.sh
```

Podman plus GPU flags:

```yaml
agents:
  - name: gpu-agent
    adapter: stdin
    command: my-agent
runtime:
  engine: podman
  extra_flags: --gpus all
```

No network:

```yaml
agents:
  - name: codex
    adapter: codex
    command: codex
runtime:
  network: false
```

Multiple agents and extra mounts:

```yaml
agents:
  - name: codex
    adapter: codex
    command: codex
  - name: claude
    adapter: claude
    command: claude
volumes:
  extra:
    - ~/.ssh:/home/carranca/.ssh:ro
    - ~/projects/shared-lib:/reference/shared-lib:ro
```

Ephemeral home directory:

```yaml
agents:
  - name: codex
    adapter: codex
    command: codex
volumes:
  cache: false
```

Agent with extra capabilities:

```yaml
agents:
  - name: debugger
    adapter: stdin
    command: my-debugger
runtime:
  cap_add:
    - SYS_PTRACE
```

## `carranca config`

`carranca config` uses the selected configured agent to inspect the workspace and
propose updates to:

- `.carranca.yml`
- `.carranca/Containerfile`

It does not let the agent edit the workspace directly. Instead it requires the
agent to write complete proposed files into a proposal directory under:

```text
~/.local/state/carranca/config/<repo-id>/<session-id>/proposal/
```

The config prompt requires the agent to:

- read `/carranca-skills/confiskill/SKILL.md`
- inspect user skills under `/user-skills/`
- write rationale and detected stack summaries alongside the proposal

Mount behavior differs from `carranca run`:

- Carranca-managed skills come from the Carranca install and are mounted at
  `/carranca-skills`
- user-managed skills come from `.carranca/skills/user/` when present and are
  mounted at `/user-skills`
- the workspace is mounted read-only

`carranca config` uses the same TTY rule as `run`: `-it` when stdin is a TTY,
`-i` otherwise.

Useful commands:

```bash
carranca config
carranca config --agent claude
carranca config --prompt "install repo dev tools"
carranca config --dangerously-skip-confirmation
```

By default, `config` is propose-only until you confirm. It prints:

- detected workspace profile
- rationale for the proposal
- unified diffs for `.carranca.yml` and `.carranca/Containerfile`

Audit events for proposal rejection, bypassed confirmation, and applied changes
are recorded in:

```text
~/.local/state/carranca/config/<repo-id>/history.jsonl
```

## Cache volume

When `volumes.cache` is `true`, Carranca bind-mounts a repo-scoped home
directory into the agent container:

| Host path | Container path | Purpose |
|-----------|---------------|---------|
| `~/.local/state/carranca/cache/<repo-id>/home/` | `/home/carranca` | Agent auth, config, history, and other CLI home-state |

This cache is used by both `run` and `config` when enabled.

## Custom volumes

`volumes.extra` accepts bind mount entries in `host:container[:mode]` form. The
host path expands `~` to `$HOME`.

Examples:

- `~/.ssh:/home/carranca/.ssh:ro`
- `~/docs:/reference:ro`
- `~/data:/data:rw`

These extra mounts are added only to the agent container used by `run`. They are
not mounted into the logger, and `config` currently uses its own fixed mount set.

## `.carranca/Containerfile`

`carranca init` creates `.carranca/Containerfile`. You own the dependency and
tool installation steps above the shell-wrapper block; Carranca depends on the
shell-wrapper block remaining intact.

```Dockerfile
FROM alpine:3.21

RUN apk add --no-cache bash coreutils curl git ca-certificates

# Your agent and project dependencies here
RUN apk add --no-cache nodejs npm

COPY shell-wrapper.sh /usr/local/bin/shell-wrapper.sh
RUN chmod +x /usr/local/bin/shell-wrapper.sh
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/shell-wrapper.sh"]
```

`carranca config` validates that proposed Containerfiles still contain:

- `COPY shell-wrapper.sh /usr/local/bin/shell-wrapper.sh`
- `ENTRYPOINT ["/usr/local/bin/shell-wrapper.sh"]`

## `.carranca/skills/`

`carranca init` scaffolds two repo-local skill directories:

- `.carranca/skills/carranca/`
- `.carranca/skills/user/`

Current behavior:

- `carranca run` mounts `.carranca/skills/carranca/` to `/carranca-skills` when
  present
- `carranca run` mounts `.carranca/skills/user/` to `/user-skills` when present
- `carranca config` mounts install-managed Carranca skills from
  `~/.local/share/carranca/skills/` to `/carranca-skills`
- `carranca config` mounts `.carranca/skills/user/` to `/user-skills` when
  present

That split lets `config` reliably use the shipped `confiskill` while still
honoring repo-local user skills.
