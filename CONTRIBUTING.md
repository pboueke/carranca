# Carranca — Project Instructions

## What is this

Carranca is a containerized agent runtime with session logging. It runs coding agents inside Docker containers with host isolation and structured JSONL session logs.

## Architecture

```
carranca/
├── cli/              # CLI entry point and commands (bash)
│   ├── carranca      # Main dispatcher
│   ├── init.sh       # carranca init
│   ├── run.sh        # carranca run
│   └── lib/          # Shared libraries (common, config, identity)
├── runtime/          # Container definitions
│   ├── Containerfile.logger  # Logger container image
│   ├── shell-wrapper.sh     # Runs inside agent container
│   └── logger.sh         # Runs inside logger container
├── skills/           # Default SKILL.md policy files
├── templates/        # Config templates for carranca init
└── tests/            # Unit, integration, and failure tests
```

Two containers connected by a FIFO:
- **Agent container**: runs the coding agent with repo mounted read-write
- **Logger container**: reads FIFO events + inotifywait, writes JSONL session log

## Commands

```bash
make help        # List all targets
make lint        # shellcheck + hadolint + yamllint
make test        # Unit tests only (fast, no Docker)
make test-all    # All tests (requires Docker)
make check       # Lint + unit tests (what pre-commit runs)
make build       # Build logger image
make version     # Print current version from CHANGELOG.md
make hooks       # Set up git pre-commit hooks
make install     # Symlink CLI to ~/.local/bin/
```

## Versioning

Version is derived from the first `## [X.Y.Z]` header in `CHANGELOG.md`. This is the single source of truth. Use `make version` to read it. When bumping version, update CHANGELOG.md only.

## Testing

Three test layers:
1. **Unit** (`tests/unit/`): test pure functions, no Docker needed
2. **Integration** (`tests/integration/`): full `init` + `run` lifecycle, requires Docker
3. **Failure** (`tests/failure/`): precondition checks, degraded mode, fail-closed behavior

Run with: `bash tests/run_tests.sh` or `make test-all`

## Conventions

- All source code is bash (no Python, no Node)
- Use `set -euo pipefail` in all scripts
- Functions prefixed with `carranca_` in library files
- 2-space indentation for shell scripts
- Tab indentation in Makefile only
- YAML uses 2-space indentation
- Keep the trust model honest — don't overclaim security properties
