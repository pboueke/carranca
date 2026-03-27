<div align="center">
  <img src="doc/page/carranca.jpg" alt="Carranca" width="600" />
  <p><em>A Carranca photographed by Marcel Gautherot in 1946. Instituto Moreira Salles collection.</em></p>

  <h1>Carranca</h1>

  <p>
    <img src="https://img.shields.io/badge/version-0.17.3-blue" alt="version: 0.17.3" />
    <img src="https://img.shields.io/badge/tests-931%2F931_passed-brightgreen" alt="tests: 931/931 passed" />
    <img src="https://img.shields.io/badge/coverage-100%25_(147%2F147_functions)-brightgreen" alt="coverage: 100%" />
    <img src="https://img.shields.io/badge/license-MIT-green" alt="license: MIT" />
  </p>

  <p><strong>Isolated agent runtime with verified audits, deep observability, policy enforcement, and adversarial hardening.</strong> Named after the carved figureheads on boats in Brazil's São Francisco river, believed to protect sailors. Carranca protects engineers from coding agents by running them in hardened containers with tamper-evident logs, kernel-level tracing, enforceable guardrails, and forgery detection.
</p>
</div>

## Documentation

| Doc | What it covers |
|-----|---------------|
| [Objective](doc/objective.md) | Current product position, intended users, non-goals, and comparison with other sandbox models |
| [Technical reference](doc/page/index.html) | Primary browsable reference (open locally after cloning) for architecture, configuration, session log schema, trust model, roadmap, versioning, and changelog |
| [Usage](doc/usage.md) | Detailed CLI command reference, options, and operator workflows |
| [Architecture](doc/architecture.md) | Container layout, data flow, directory structure |
| [CI/CD integration](doc/ci.md) | Headless execution, timeouts, exit codes, session artifacts, and GitHub Actions patterns |
| [Configuration](doc/configuration.md) | `.carranca.yml` reference, Containerfile, init flags |
| [Examples](doc/examples/README.md) | Persona-based example `.carranca.yml` and `.carranca/Containerfile` setups |
| [Session log](doc/session-log.md) | JSONL schema, event types, `jq` query examples |
| [Trust model](doc/trust-model.md) | Threat table, failure behavior, honest scope |
| [Versioning](doc/versioning.md) | Semver policy, changelog format |

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

Carranca invokes the container runtime CLI directly. Supported engines are
Podman and Docker, selected by `CARRANCA_CONTAINER_RUNTIME` or
`runtime.engine`; `auto` prefers Podman and falls back to Docker.

Each `carranca run` session creates a small set of runtime resources:

- an **agent container** built from `.carranca/Containerfile`
- a **logger container** that receives events and writes audit artifacts
- an optional **observer container** for independent execve and network tracing
- a shared **tmpfs volume** containing a Unix FIFO for event transport

The user-controlled surface is the project configuration:
`.carranca.yml` defines the agent command, runtime settings, and policy;
`.carranca/Containerfile` defines the toolchain available inside the agent
container. Carranca manages the logger, observer, transient images, and session
state.

During execution, the agent container receives the workspace as a bind mount and
runs with a hardened baseline: read-only root filesystem, all capabilities
dropped, and seccomp filtering. On Linux, it runs as the invoking host UID:GID,
or with `--userns keep-id` on rootless Podman, so workspace writes retain
usable host ownership.

The shell wrapper inside the agent container emits events to the FIFO. The
logger consumes those events and writes a structured JSONL session log, a
checksum file, and a per-session HMAC key that the agent cannot access. When
enabled, the independent observer records a second view of process execution and
network activity from outside the agent's namespaces.

```
  carranca run
       │
       ├── <runtime> run -d  (logger: FIFO + file observation + JSONL/HMAC)
       ├── <runtime> run -d  (observer: strace + /proc/net/tcp, optional)
       └── <runtime> run -it (agent: shell-wrapper + configured agent command)
```

After the session, `carranca log` inspects, verifies, or exports the resulting
artifacts, and `carranca status` shows active and recent sessions for the
current repository.

Open [doc/page/index.html](doc/page/index.html) for the full technical
reference. The markdown files in [`doc/`](doc/) remain the source chapters and
companion guides.

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

## Platform support

- **Linux**: Full support for current logging model, including `inotifywait`
  file mutation events.
- **macOS/Windows**: Experimental. Container runtime behavior varies, and file
  mutation logging is Linux-only today.

## License

MIT
