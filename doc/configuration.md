# Configuration

## What Carranca reads

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

Only `runtime.*`, `volumes.*`, `observability.*`, and `policy.*` settings are read from global config.
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
  independent_observer: false

# orchestration:
#   mode: pipeline       # pipeline | parallel
#   workspace: isolated  # isolated | shared
#   merge: carry         # carry | discard (pipeline only)

# environment:
#   passthrough:
#     - ANTHROPIC_API_KEY
#   env_file: .env.carranca
#   vars:
#     REGION: us-east-1
```

### Field reference

| Field | Required | Default | Current behavior |
|-------|----------|---------|------------------|
| `agents` | Yes | — | Ordered configured agents; the first entry is the default for `run` and `config` |
| `agents[].name` | Yes | — | Stable selector used by `--agent <name>` |
| `agents[].command` | Yes | — | Command executed inside the agent container |
| `agents[].adapter` | No | `default` | Adapter selection: `default`, `claude`, `codex`, `opencode`, or `stdin` |
| `runtime.engine` | No | `auto` | Runtime engine: `auto`, `docker`, or `podman` |
| `runtime.network` | No | `true` | Boolean `true`/`false` or object with `default`/`allow` keys. `false` adds `--network=none`. Object form enables fine-grained network filtering via iptables |
| `runtime.network.default` | No | — | Network policy default: must be `deny`. Presence of this key switches to filtered mode with iptables OUTPUT DROP + allow-list. Requires yq |
| `runtime.network.allow` | No | — | List of `host:port` entries allowed through the firewall (e.g., `*.anthropic.com:443`). Requires yq |
| `runtime.extra_flags` | No | — | Extra flags appended to the agent container `run` command |
| `runtime.logger_extra_flags` | No | — | Extra flags appended to the logger container `run` command |
| `runtime.seccomp_profile` | No | `default` | Seccomp profile for agent container. `default` (denylist — blocks dangerous syscalls, auto-permits new ones). `strict` (allowlist — only permits needed syscalls, tighter but may need operator tuning). `unconfined` disables seccomp. Absolute path for custom profile. Linux only |
| `runtime.apparmor_profile` | No | — | AppArmor profile name for agent container. Must be pre-loaded via `apparmor_parser -r`. `unconfined` to disable. Empty (default) uses runtime default. Linux only |
| `runtime.cap_drop_all` | No | `true` | When `true`, drops all Linux capabilities from the agent container via `--cap-drop ALL`. `cap_add` becomes a strict allowlist applied after the drop |
| `runtime.read_only` | No | `true` | When `true`, runs agent container with `--read-only` root filesystem. `/tmp`, `/var/tmp`, `/run` get tmpfs mounts. `/workspace`, `/fifo`, and cache home are unaffected. When cache is disabled, `/home/carranca` gets a tmpfs mount |
| `runtime.cap_add` | No | — | List of Linux capabilities added to the agent container via `--cap-add`. When `cap_drop_all` is `true` (default), these are the only capabilities the agent has |
| `volumes.cache` | No | `true` | Persists `/home/carranca` under `~/.local/state/carranca/cache/<repo-id>/home/` |
| `volumes.extra` | No | — | Extra bind mounts added only to the agent container |
| `policy.docs_before_code` | No | — | `warn`, `enforce`, or `off`. When `warn` or `enforce`, injects git pre-commit hooks. `enforce` blocks commits that modify code without documentation |
| `policy.tests_before_impl` | No | — | `warn`, `enforce`, or `off`. When `warn` or `enforce`, injects git pre-commit hooks. `enforce` blocks commits that modify implementation without tests |
| `policy.max_duration` | No | — | Seconds; logger removes FIFO after this wall-clock limit, triggering agent fail-closed exit. `0` or absent means no limit |
| `policy.resource_limits.memory` | No | — | Container memory limit (e.g., `2g`, `512m`). Passed as `--memory` to agent container. Requires yq |
| `policy.resource_limits.cpus` | No | — | CPU limit (e.g., `2.0`). Passed as `--cpus` to agent container. Requires yq |
| `policy.resource_limits.pids` | No | — | Max number of processes. Passed as `--pids-limit` to agent container. Requires yq |
| `policy.filesystem.enforce_watched_paths` | No | `false` | When `true`, `watched_paths` directories and files are bind-mounted read-only. Requires yq |
| `watched_paths` | No | — | File events matching watched patterns are tagged with `"watched":true` in session logs |
| `observability.resource_interval` | No | `10` | Seconds between cgroup resource samples; `0` disables |
| `observability.execve_tracing` | No | `false` | Enable strace-based execve tracing in the logger; adds `CAP_SYS_PTRACE` to logger. Not required when `independent_observer` is enabled (the observer always traces) |
| `observability.network_logging` | No | `false` | Enable `/proc/net/tcp` polling for outbound connections; requires PID namespace sharing |
| `observability.network_interval` | No | `5` | Seconds between network connection polls |
| `observability.secret_monitoring` | No | `false` | Enable fanotify-based file read monitoring on `watched_paths`; adds `CAP_SYS_ADMIN` to logger |
| `observability.independent_observer` | No | `false` | Run execve tracer and network monitor in an independent sidecar container outside the agent's PID/mount namespace. Observer events are authenticated via a shared token on `/state/` (inaccessible to the agent). Always enables execve tracing regardless of `execve_tracing` setting. Cross-references events at session end as a best-effort heuristic |
| `orchestration.mode` | No | — | Multi-agent mode: `pipeline` (sequential, fail-fast) or `parallel` (concurrent). Requires 2+ agents. See [multi-agent.md](multi-agent.md) |
| `orchestration.workspace` | No | `isolated` | Workspace isolation: `isolated` (per-agent copy) or `shared` (single mount) |
| `orchestration.merge` | No | `carry` | Pipeline workspace merge: `carry` (next agent sees previous changes) or `discard` (each agent gets original workspace) |
| `environment.passthrough` | No | — | List of host environment variable names to forward to the agent container. Only vars that exist in the host env are passed; missing vars are skipped with a warning |
| `environment.env_file` | No | — | Path to a `.env` file on the host. Supports `~` expansion. Standard format: `KEY=VALUE`, optional `export` prefix, `#` comments, quoted values. File must exist if configured |
| `environment.vars` | No | — | Map of environment variables defined directly in the config (e.g., `MY_VAR: value`). Requires yq for map parsing; awk fallback supports simple `key: value` pairs |

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

Agent with environment variables:

```yaml
agents:
  - name: claude
    adapter: claude
    command: claude

environment:
  # Forward these host env vars into the agent container
  passthrough:
    - ANTHROPIC_API_KEY
    - GITHUB_TOKEN
  # Load additional vars from a .env file
  env_file: .env.carranca
  # Define vars directly (lowest priority for duplicates)
  vars:
    REGION: us-east-1
    LOG_LEVEL: debug
```

Priority when the same variable appears in multiple sources: `vars` overrides `env_file` overrides `passthrough`.

## Configuration examples

Persona-specific examples live under [examples/](examples/). Each persona from
[objective.md](objective.md) has its own directory with:

- `.carranca.yml`
- `.carranca/Containerfile`
- a `README.md` describing the operating context and why Carranca helps

Start with [examples/README.md](examples/README.md), then open the persona that
matches your operating model:

- [examples/platform-engineer/](examples/platform-engineer/)
- [examples/security-engineer/](examples/security-engineer/)
- [examples/regulated-team-lead/](examples/regulated-team-lead/)
- [examples/consultant-client-code/](examples/consultant-client-code/)
- [examples/open-source-maintainer/](examples/open-source-maintainer/)
- [examples/forensic-analyst/](examples/forensic-analyst/)
- [examples/ci-reviewer/](examples/ci-reviewer/)

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
tool installation steps between the marker comments; Carranca depends on the
shell-wrapper block at the bottom remaining intact.

The template Containerfile pins the Alpine base image by digest. To override,
pass `--build-arg ALPINE_IMAGE=alpine:3.22` (or any image) when building.

```Dockerfile
ARG ALPINE_IMAGE=alpine:3.21@sha256:...
FROM ${ALPINE_IMAGE}

RUN apk add --no-cache \
      bash \
      coreutils \
      curl \
      git \
      ca-certificates \
      iptables

RUN mkdir -p /home/carranca && chmod 0777 /home/carranca

# Your agent and project dependencies here
RUN apk add --no-cache nodejs npm

# Carranca shell wrapper (do not remove)
COPY lib/json.sh /usr/local/bin/lib/json.sh
COPY shell-wrapper.sh /usr/local/bin/shell-wrapper.sh
RUN chmod +x /usr/local/bin/shell-wrapper.sh
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/shell-wrapper.sh"]
```

`carranca config` validates that proposed Containerfiles still contain:

- `COPY lib/json.sh /usr/local/bin/lib/json.sh`
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
