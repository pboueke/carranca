# Carranca

![tests: 191/191 passed](https://img.shields.io/badge/tests-191%2F191_passed-brightgreen)
![coverage: 100%](https://img.shields.io/badge/coverage-100%25_(27%2F27_functions)-brightgreen)

**Containerized agent runtime with session logging.**

Named after the carved figureheads on boats in Brazil's São Francisco river, believed to protect sailors. Carranca protects engineers from coding agents — by running them in isolated containers with structured session logging.

## Quick start

```bash
# Install
git clone https://github.com/pboueke/carranca.git ~/.local/share/carranca
export PATH="$HOME/.local/share/carranca/cli:$PATH"

# Initialize a project
cd your-project
carranca init --codex     # or bare

# Ask carranca to propose runtime updates for this repo
carranca config

# Run an agent session
carranca run
```

## How it works

Two containers share a FIFO on a tmpfs volume. The agent gets an interactive TTY. The logger writes a structured JSONL session log that the agent cannot access.
On Linux, the agent container runs as the invoking host UID:GID, so edits to the bind-mounted workspace keep host ownership instead of becoming `root`-owned.

```
  carranca run
       │
       ├── docker run -d  (logger: reads FIFO + inotifywait → JSONL)
       └── docker run -it (agent: shell-wrapper → FIFO)
```

See [doc/architecture.md](doc/architecture.md) for the full picture.

## Commands

- `carranca init`: scaffold `.carranca.yml`, `.carranca/Containerfile`, and default skills
- `carranca config`: launch the bound agent in its normal TUI, ask it to use Carranca `confiskill`, and propose updates to `.carranca.yml` and `.carranca/Containerfile`
- `carranca log`: pretty-print the latest session for the current repo, or a selected session via `--session <exact-id>`
- `carranca run`: start an interactive agent session with structured logging

`carranca config` mounts Carranca-managed skills and user skills into separate directories inside the agent container, launches the configured agent with the same interactive TTY behavior as `carranca run`, asks it to use `confiskill`, then shows its rationale and diff before applying changes. Use `--dangerously-skip-confirmation` only when you want to bypass the confirmation prompt and accept the proposal immediately.

## Documentation

| Doc | What it covers |
|-----|---------------|
| [Architecture](doc/architecture.md) | Container layout, data flow, directory structure |
| [Configuration](doc/configuration.md) | `.carranca.yml` reference, Containerfile, init flags |
| [Session log](doc/session-log.md) | JSONL schema, event types, `jq` query examples |
| [Trust model](doc/trust-model.md) | Threat table, failure behavior, honest scope |
| [Versioning](doc/versioning.md) | Semver policy, changelog format |

## Platform support

- **Linux**: Full support (shell logging + file events)
- **macOS/Windows**: Experimental (shell logging only)

## License

MIT
