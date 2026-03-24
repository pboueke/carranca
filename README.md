<div align="center">
  <img src="doc/carranca.jpg" alt="Carranca" width="600" />
  <p><em>A Carranca photographed by Marcel Gautherot in 1946. Instituto Moreira Salles collection.</em></p>

  <h1>Carranca</h1>

  <p>
    <img src="https://img.shields.io/badge/version-0.14.0-blue" alt="version: 0.14.0" />
    <img src="https://img.shields.io/badge/tests-610%2F610_passed-brightgreen" alt="tests: 610/610 passed" />
    <img src="https://img.shields.io/badge/coverage-100%25_(99%2F99_functions)-brightgreen" alt="coverage: 100%" />
  </p>

  <p><strong>Isolated agent runtime with verified audits, deep observability, and policy enforcement.</strong> Named after the carved figureheads on boats in Brazil's São Francisco river, believed to protect sailors. Carranca protects engineers from coding agents by running them in isolated containers with tamper-evident logs, kernel-level tracing, and enforceable guardrails.
</p>
</div>


## Quick start

```bash
# Install
git clone https://github.com/pboueke/carranca.git ~/.local/share/carranca
export PATH="$HOME/.local/share/carranca/cli:$PATH"

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

Two runtime-managed containers share a FIFO on a tmpfs volume. The agent gets an
interactive TTY. The logger writes a structured JSONL session log plus a
parallel checksum file and per-session HMAC key that the agent cannot access.
On Linux, the agent container runs as the invoking host UID:GID, or with
`--userns keep-id` on rootless Podman, so workspace writes keep usable host
ownership.

```
  carranca run
       │
       ├── <runtime> run -d  (logger: FIFO + inotifywait + strace + cgroup + fanotify → JSONL)
       └── <runtime> run -it (agent: shell-wrapper → FIFO)
```

Open [doc/page/index.html](doc/page/index.html) for the full technical reference.
The markdown files in [`doc/`](doc/) remain the source chapters and companion
guides.

## Commands

- `carranca init`: scaffold `.carranca.yml`, `.carranca/Containerfile`, and repo-local skill directories under `.carranca/skills/`
- `carranca kill`: stop one active session by exact id or all active sessions globally after confirmation
- `carranca config`: launch the selected configured agent, require it to use Carranca `confiskill`, and propose updates to `.carranca.yml` and `.carranca/Containerfile`
- `carranca log`: pretty-print the latest session, verify integrity (`--verify`), export a signed archive (`--export`), or render an ASCII timeline (`--timeline`)
- `carranca run`: start an interactive session with the default first agent or a named agent via `--agent <name>`
- `carranca status`: show active sessions and the 5 most recent session logs for the current repo, or inspect a specific session via `--session <exact-id>`

Each command also exposes command-specific help through either `carranca help <command>` or `carranca <command> help`.

Carranca reads per-project config from `.carranca.yml` and optional user-wide
defaults from `~/.config/carranca/config.yml` for `runtime.*`, `volumes.*`,
`observability.*`, and `policy.*` keys. Runtime selection precedence is `CARRANCA_CONTAINER_RUNTIME`, then
`.carranca.yml` `runtime.engine`, then global `runtime.engine`, then
auto-detection.

Carranca config is forward-only on the `agents:` format. `carranca init`
scaffolds a supported starter agent (`codex`, `claude`, or `opencode`) as the
first/default entry, `carranca run --agent <name>` selects any configured
agent, and
`carranca config --agent <name> --prompt "..."` chooses which configured agent
executes the config workflow while passing free-form operator intent into the
prompt.

`carranca run` mounts repo-local Carranca skills from
`.carranca/skills/carranca/` and user skills from `.carranca/skills/user/` when
those directories exist. `carranca config` always mounts install-managed
Carranca skills from the Carranca installation plus repo-local user skills, then
shows rationale and a diff before applying any proposal. Use
`--dangerously-skip-confirmation` only when you want to bypass the confirmation
prompt and accept the proposal immediately.

`carranca log` reports the latest or selected session in a developer-readable
summary: duration, unique touched paths, file-event totals, top touched paths,
command counts, and the shell-wrapper command list when command capture exists.
With `observability.execve_tracing: true`, all process execution is captured
independently of the shell wrapper. `--timeline` renders a compact ASCII view
of every event in chronological order.

## Documentation

| Doc | What it covers |
|-----|---------------|
| [Technical reference](doc/page/index.html) | Primary browsable reference for architecture, configuration, session log schema, trust model, roadmap, versioning, and changelog |
| [Usage](doc/usage.md) | Detailed CLI command reference, options, and operator workflows |
| [Architecture](doc/architecture.md) | Container layout, data flow, directory structure |
| [Configuration](doc/configuration.md) | `.carranca.yml` reference, Containerfile, init flags |
| [Session log](doc/session-log.md) | JSONL schema, event types, `jq` query examples |
| [Trust model](doc/trust-model.md) | Threat table, failure behavior, honest scope |
| [Vision](doc/vision.md) | Current product position, future phases, and target audiences |
| [Versioning](doc/versioning.md) | Semver policy, changelog format |

## Platform support

- **Linux**: Full support for current logging model, including `inotifywait`
  file mutation events.
- **macOS/Windows**: Experimental. Container runtime behavior varies, and file
  mutation logging is Linux-only today.

## License

MIT
