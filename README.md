# Carranca

![tests: 93/93 passed](https://img.shields.io/badge/tests-93%2F93_passed-brightgreen)
![coverage: 100%](https://img.shields.io/badge/coverage-100%25_(17%2F17_functions)-brightgreen)

**Containerized agent runtime with session logging.**

Named after the carved figureheads on boats in Brazil's São Francisco river, believed to protect sailors. Carranca protects engineers from coding agents — by running them in isolated containers with structured session logging.

## Quick start

```bash
# Install
git clone https://github.com/pboueke/carranca.git ~/.local/share/carranca
export PATH="$HOME/.local/share/carranca/cli:$PATH"

# Initialize a project
cd your-project
carranca init --claude    # or --codex, or bare

# Run an agent session
carranca run
```

## How it works

Two containers share a FIFO on a tmpfs volume. The agent gets an interactive TTY. The logger writes a structured JSONL session log that the agent cannot access.

```
  carranca run
       │
       ├── docker run -d  (logger: reads FIFO + inotifywait → JSONL)
       └── docker run -it (agent: shell-wrapper → FIFO)
```

See [doc/architecture.md](doc/architecture.md) for the full picture.

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
