<div align="center">
  <img src="doc/carranca.jpg" alt="Carranca" width="600" />
  <p><em>Carranca photographed by Marcel Gautherot in 1946. Instituto Moreira Salles collection.</em></p>
</div>

# Carranca

![tests: 214/214 passed](https://img.shields.io/badge/tests-214%2F214_passed-brightgreen)
![coverage: 100%](https://img.shields.io/badge/coverage-100%25_(35%2F35_functions)-brightgreen)

**Containerized agent runtime with session logging.**

Named after the carved figureheads on boats in Brazil's São Francisco river, believed to protect sailors. Carranca protects engineers from coding agents — by running them in isolated containers with structured session logging.

## Quick start

```bash
# Install
git clone https://github.com/pboueke/carranca.git ~/.local/share/carranca
export PATH="$HOME/.local/share/carranca/cli:$PATH"

# Initialize a project
cd your-project
carranca init --agent codex

# Ask carranca to propose runtime updates for this repo
carranca config --prompt "install claude"

# Run an agent session
carranca run --agent codex

# Inspect the latest session
carranca log

# Show active and recent sessions for this repo
carranca status

# Show command-specific help
carranca help run
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
- `carranca config`: launch the selected configured agent in its normal TUI, ask it to use Carranca `confiskill`, and propose updates to `.carranca.yml` and `.carranca/Containerfile`
- `carranca log`: pretty-print the latest session for the current repo, or a selected session via `--session <exact-id>`
- `carranca run`: start an interactive session with the default first agent or a named agent via `--agent <name>`
- `carranca status`: show active sessions and the 5 most recent session logs for the current repo, or inspect a specific session via `--session <exact-id>`

Each command also exposes command-specific help through either `carranca help <command>` or `carranca <command> help`.

Carranca config is forward-only on the `agents:` format. `carranca init` scaffolds a supported agent (`codex` or `claude`) as the first/default entry, `carranca run --agent <name>` selects any configured agent, and `carranca config --agent <name> --prompt "..."` chooses which configured agent executes the config workflow while passing free-form operator intent into the prompt.

`carranca config` mounts Carranca-managed skills and user skills into separate directories inside the agent container, launches the selected configured agent with the same interactive TTY behavior as `carranca run`, asks it to use `confiskill`, then shows its rationale and diff before applying changes. Use `--dangerously-skip-confirmation` only when you want to bypass the confirmation prompt and accept the proposal immediately.

`carranca log` reports the latest or selected session in a developer-readable summary: duration, unique touched paths, file-event totals, top touched paths, command counts, and the ordered command list when shell-wrapper command capture exists.

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
