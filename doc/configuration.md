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
| `runtime.seccomp_profile` | No | `default` | Seccomp profile for agent container. `default` uses carranca's built-in profile blocking dangerous syscalls (ptrace, mount, unshare, etc.). `unconfined` disables seccomp. Absolute path for custom profile. Linux only |
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
| `observability.execve_tracing` | No | `false` | Enable strace-based execve tracing; adds `CAP_SYS_PTRACE` to logger |
| `observability.network_logging` | No | `false` | Enable `/proc/net/tcp` polling for outbound connections; requires PID namespace sharing |
| `observability.network_interval` | No | `5` | Seconds between network connection polls |
| `observability.secret_monitoring` | No | `false` | Enable fanotify-based file read monitoring on `watched_paths`; adds `CAP_SYS_ADMIN` to logger |
| `observability.independent_observer` | No | `false` | Run execve tracer and network monitor in an independent sidecar container outside the agent's PID/mount namespace. Agent cannot see or interfere with observer. Cross-references events at session end |

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

## Configuration examples

The examples below map the roles in [vision.md](vision.md) to concrete Carranca
setups. Each one includes both `.carranca.yml` and `.carranca/Containerfile`
because operator intent affects both runtime policy and the tools installed in
the agent image.

### DevOps operator: restricted package access and enforceable workflow

Use this when a platform or DevOps team wants an agent that can work on build
and deployment files while restricting outbound network access to a small
allow-list.

`.carranca.yml`

```yaml
agents:
  - name: codex
    adapter: codex
    command: codex

runtime:
  engine: podman
  network:
    default: deny
    allow:
      - registry.npmjs.org:443
      - pypi.org:443
      - files.pythonhosted.org:443
      - api.github.com:443

volumes:
  cache: true
  extra:
    - ~/.ssh:/home/carranca/.ssh:ro

policy:
  docs_before_code: enforce
  tests_before_impl: enforce
  max_duration: 1800
  resource_limits:
    memory: 2g
    cpus: "2.0"
    pids: 256

watched_paths:
  - .env
  - .github/
  - deploy/
  - secrets/

observability:
  resource_interval: 10
  execve_tracing: true
  network_logging: true
  network_interval: 5
  secret_monitoring: true
```

`.carranca/Containerfile`

```Dockerfile
FROM alpine:3.21

RUN apk add --no-cache \
    bash \
    ca-certificates \
    coreutils \
    curl \
    git \
    jq \
    make \
    nodejs \
    npm \
    openssh-client \
    python3 \
    py3-pip \
    yq

RUN npm install -g @openai/codex

COPY shell-wrapper.sh /usr/local/bin/shell-wrapper.sh
RUN chmod +x /usr/local/bin/shell-wrapper.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/shell-wrapper.sh"]
```

### Agent developer: trace unexpected timeline events

Use this when an engineer is debugging surprising `carranca log --timeline`
output and wants higher-fidelity process and resource visibility while keeping
policies permissive enough for investigation.

`.carranca.yml`

```yaml
agents:
  - name: debugger
    adapter: stdin
    command: bash /usr/local/bin/agent-debug-session.sh

runtime:
  engine: auto
  network: true
  cap_add:
    - SYS_PTRACE

volumes:
  cache: false
  extra:
    - ~/scratch/captures:/captures:rw

policy:
  docs_before_code: off
  tests_before_impl: warn
  max_duration: 0
  resource_limits:
    memory: 4g
    cpus: "4.0"
    pids: 512

watched_paths:
  - .carranca.yml
  - runtime/
  - cli/
  - tests/

observability:
  resource_interval: 2
  execve_tracing: true
  network_logging: true
  network_interval: 2
  secret_monitoring: false
```

`.carranca/Containerfile`

```Dockerfile
FROM alpine:3.21

RUN apk add --no-cache \
    bash \
    coreutils \
    curl \
    git \
    jq \
    procps \
    strace \
    tree \
    yq

RUN printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'exec codex "$@"' \
  > /usr/local/bin/agent-debug-session.sh \
  && chmod +x /usr/local/bin/agent-debug-session.sh

RUN apk add --no-cache nodejs npm && npm install -g @openai/codex

COPY shell-wrapper.sh /usr/local/bin/shell-wrapper.sh
RUN chmod +x /usr/local/bin/shell-wrapper.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/shell-wrapper.sh"]
```

### Forensic analyst: offline replay and evidence review

Use this when the goal is post-session investigation rather than active coding.
The agent image is minimal, the network is disabled, and the workspace can be
mounted with reference material for analysis.

`.carranca.yml`

```yaml
agents:
  - name: analyst
    adapter: stdin
    command: bash /usr/local/bin/review-session.sh

runtime:
  engine: podman
  network: false

volumes:
  cache: false
  extra:
    - ~/cases:/cases:ro
    - ~/.local/state/carranca/sessions:/session-archive:ro

policy:
  docs_before_code: off
  tests_before_impl: off
  max_duration: 7200
  filesystem:
    enforce_watched_paths: true

watched_paths:
  - reports/
  - findings/
  - /session-archive

observability:
  resource_interval: 30
  execve_tracing: true
  network_logging: false
  secret_monitoring: true
```

`.carranca/Containerfile`

```Dockerfile
FROM alpine:3.21

RUN apk add --no-cache \
    bash \
    coreutils \
    git \
    jq \
    less \
    python3 \
    py3-pip \
    yq

RUN printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'exec bash' \
  > /usr/local/bin/review-session.sh \
  && chmod +x /usr/local/bin/review-session.sh

COPY shell-wrapper.sh /usr/local/bin/shell-wrapper.sh
RUN chmod +x /usr/local/bin/shell-wrapper.sh

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/shell-wrapper.sh"]
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
