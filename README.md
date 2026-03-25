<div align="center">
  <img src="doc/carranca.jpg" alt="Carranca" width="600" />
  <p><em>A Carranca photographed by Marcel Gautherot in 1946. Instituto Moreira Salles collection.</em></p>

  <h1>Carranca</h1>

  <p>
    <img src="https://img.shields.io/badge/version-0.17.2-blue" alt="version: 0.17.2" />
    <img src="https://img.shields.io/badge/tests-918%2F918_passed-brightgreen" alt="tests: 918/918 passed" />
    <img src="https://img.shields.io/badge/coverage-100%25_(147%2F147_functions)-brightgreen" alt="coverage: 100%" />
    <img src="https://img.shields.io/badge/license-MIT-green" alt="license: MIT" />
  </p>

  <p><strong>Isolated agent runtime with verified audits, deep observability, policy enforcement, and adversarial hardening.</strong> Named after the carved figureheads on boats in Brazil's São Francisco river, believed to protect sailors. Carranca protects engineers from coding agents by running them in hardened containers with tamper-evident logs, kernel-level tracing, enforceable guardrails, and forgery detection.
</p>
</div>


## Quick start

```bash
# Install
git clone https://github.com/pboueke/carranca.git ~/.local/share/carranca
export PATH="$HOME/.local/share/carranca/cli:$PATH"
# Add the export line to ~/.bashrc or ~/.zshrc to persist across sessions

# Initialize a project
cd your-project
carranca init --agent codex

# Ask carranca to propose container/runtime setup updates for this repo
carranca config --prompt "install claude"

# Run an agent session
carranca run --agent codex

# Inspect the latest session
carranca log

# Show active and recent sessions for this repo
carranca status

# Stop a specific session or all active sessions
carranca kill --session <id>

# Show command-specific help
carranca help run
```

## How it works

Carranca uses a container runtime CLI directly. Today that means Podman or
Docker, selected by `CARRANCA_CONTAINER_RUNTIME` or `runtime.engine`; `auto`
prefers Podman and falls back to Docker.

Two (or three) runtime-managed containers share a FIFO on a tmpfs volume. The
agent gets an interactive TTY with a hardened container (read-only root FS, all
capabilities dropped, seccomp filtering). The logger writes a structured JSONL
session log plus a parallel checksum file and per-session HMAC key that the
agent cannot access. An optional independent observer sidecar runs execve
tracing and network monitoring outside the agent's namespaces.
On Linux, the agent container runs as the invoking host UID:GID, or with
`--userns keep-id` on rootless Podman, so workspace writes keep usable host
ownership.

```
  carranca run
       │
       ├── <runtime> run -d  (logger: FIFO + inotifywait + cgroup + fanotify → JSONL)
       ├── <runtime> run -d  (observer: strace + /proc/net/tcp, optional)
       └── <runtime> run -it (agent: shell-wrapper → FIFO)
```

Open [doc/page/index.html](doc/page/index.html) for the full technical reference.
The markdown files in [`doc/`](doc/) remain the source chapters and companion
guides.

## Commands

| Command | Purpose |
|---------|---------|
| `carranca init` | Scaffold `.carranca.yml`, `.carranca/Containerfile`, and skill directories |
| `carranca config` | Ask an agent to propose config and Containerfile updates |
| `carranca run` | Start an interactive agent session |
| `carranca log` | Inspect, verify, export, or timeline-render session logs |
| `carranca status` | Show active sessions and recent logs |
| `carranca kill` | Stop one or all active sessions |

Run `carranca help <command>` for command-specific options. See
[usage.md](doc/usage.md) for the full CLI reference and
[configuration.md](doc/configuration.md) for the `.carranca.yml` schema.
Persona-oriented example setups live under [doc/examples/](doc/examples/).

## Documentation

| Doc | What it covers |
|-----|---------------|
| [Technical reference](doc/page/index.html) | Primary browsable reference (open locally after cloning) for architecture, configuration, session log schema, trust model, roadmap, versioning, and changelog |
| [Usage](doc/usage.md) | Detailed CLI command reference, options, and operator workflows |
| [Architecture](doc/architecture.md) | Container layout, data flow, directory structure |
| [Configuration](doc/configuration.md) | `.carranca.yml` reference, Containerfile, init flags |
| [Examples](doc/examples/README.md) | Persona-based example `.carranca.yml` and `.carranca/Containerfile` setups |
| [Session log](doc/session-log.md) | JSONL schema, event types, `jq` query examples |
| [Trust model](doc/trust-model.md) | Threat table, failure behavior, honest scope |
| [Objective](doc/objective.md) | Current product position, intended users, non-goals, and comparison with other sandbox models |
| [Versioning](doc/versioning.md) | Semver policy, changelog format |

## Platform support

- **Linux**: Full support for current logging model, including `inotifywait`
  file mutation events.
- **macOS/Windows**: Experimental. Container runtime behavior varies, and file
  mutation logging is Linux-only today.

## License

MIT
