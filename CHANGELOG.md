# Changelog

## [0.1.0] - 2026-03-22

- feat: add `carranca init` to scaffold project config with `--claude` and `--codex` flags
- feat: add `carranca run` to start interactive containerized agent sessions
- feat: two-container architecture (agent + logger) connected via FIFO, no compose
- feat: structured JSONL session logging with monotonic sequence numbers
- feat: shell command capture via instrumented shell wrapper
- feat: file mutation capture via `inotifywait` (best-effort, Linux)
- feat: fail-closed logging — agent stops if logger dies (broken pipe detection)
- feat: append-only log protection via `chattr +a` (when `CAP_LINUX_IMMUTABLE` available)
- feat: heartbeat mechanism (30s interval) to detect dead logger between commands
- feat: logger healthcheck gates agent startup (no FIFO race condition)
- feat: repo identity via git remote URL hash (12-char, with path fallback)
- feat: user-configurable agent Containerfile per project (`.carranca/Containerfile`)
- feat: `.carranca.yml` per-project configuration with runtime, policy, and watched paths
- feat: default `/plan` skill for docs-before-code workflow
- feat: install/state/config separation (`~/.local/share/`, `~/.local/state/`, `~/.config/`)
- feat: Alpine-based container images (~7MB base)
- feat: interactive agent TTY via `docker run -it` (supports TUI agents like Claude Code)
- chore: add Makefile with lint, test, check, build, install, hooks, version targets
- chore: add ShellCheck linting for all bash scripts
- chore: add git pre-commit hook (validates semver + runs lint + unit tests)
- chore: add GitHub Actions CI (lint, unit tests, integration tests)
- chore: add `.gitignore`, `.editorconfig`, `.shellcheckrc`, `.yamllint.yml`
- docs: add `doc/` with architecture, configuration, session-log, trust-model, versioning
- docs: add CONTRIBUTING.md with project conventions
- test: add unit tests for config parsing, identity, and utilities
- test: add integration tests for init and run lifecycle
- test: add failure mode tests for preconditions and degraded mode
