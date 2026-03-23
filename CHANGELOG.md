# Changelog

## [0.11.0] - 2026-03-23

- feat: add `runtime.cap_add` config — list of Linux capabilities passed as `--cap-add` flags to the agent container
- feat: wire up `watched_paths` — file events matching watched patterns are tagged with `"watched":true` in session logs
- feat: add agent, adapter, and engine metadata to session start events and log/status summary
- chore: replace TODOS.md with doc/roadmap.md for phased feature planning

## [0.10.0] - 2026-03-22

- fix: detect and warn on cache ownership mismatch when switching between Docker and rootless Podman
- docs: rewrite CONTRIBUTING.md, README, architecture, configuration, session-log, and trust-model docs for accuracy and Podman-era terminology

## [0.9.0] - 2026-03-22

- feat: add Podman and OCI runtime support with auto-detection (prefers Podman, falls back to Docker)
- feat: add `runtime.engine` config (`auto`, `docker`, `podman`) and `CARRANCA_CONTAINER_RUNTIME` env override
- feat: rootless Podman support with `--userns keep-id` for both logger and agent containers
- feat: add FIFO watchdog in agent shell-wrapper to fail closed when the logger disappears mid-session
- feat: version badge from CHANGELOG and HTML badge format in README
- fix: logger FIFO read loop exited on first timeout due to `!` inverting `$?` — sessions now survive slow container startup
- fix: logger and agent share the same user namespace on rootless Podman so the shared FIFO volume is accessible
- fix: use portable `-t` flag for container stop (replaces `--timeout` which Podman rejects)
- fix: test cleanup falls back to direct `rm` when `--cap-add LINUX_IMMUTABLE` is unavailable on rootless runtimes
- fix: `init --force` confirmation in fail-closed test so the agent Containerfile is actually created
- refactor: extract `cli/lib/runtime.sh` — all container commands go through runtime helpers with cached resolution
- refactor: rename `DOCKER_TTY_FLAGS` to `TTY_FLAGS` across `run.sh` and `config.sh`
- docs: update architecture, configuration, and README for runtime-agnostic terminology
- test: add unit coverage for runtime resolution, rootless detection, engine validation, and `fifo_is_healthy`
- test: update all integration and failure tests for runtime-agnostic container commands
- test: 316 tests, 18 suites, 100% function coverage (69/69)

## [0.8.0] - 2026-03-22

- feat: add `carranca kill` to stop one exact session or all active Carranca sessions after confirmation
- feat: add shared session lifecycle helpers so `run`, `status`, and `kill` use the same container teardown logic
- fix: stop interrupted `carranca run` sessions cleanly so agent and logger containers do not remain running after `Ctrl+C`
- docs: update README, architecture, configuration, and session-log docs for session lifecycle and `kill` behavior
- test: add unit and Docker integration coverage for session helpers and `carranca kill`
- test: 278 tests, 18 suites, 100% function coverage (48/48)

## [0.7.0] - 2026-03-22

- feat: add `carranca status` to show active sessions and the 5 most recent session logs for the current repo
- feat: add `carranca status --session <exact-id>` for detailed per-session status, including active state, summary, touched paths, and commands
- docs: update README command docs for the new `status` command and detailed session mode
- test: add unit and Docker integration coverage for status overview, detailed session output, recent-session limits, and missing-session failures
- test: 253 tests, 15 suites, 100% function coverage (39/39)

## [0.6.0] - 2026-03-22

- feat: move project config to ordered `agents:` entries only and drop legacy single-agent config support
- feat: add canonical `--agent <name>` selection for `carranca init`, `carranca run`, and `carranca config`
- feat: add `carranca config --prompt <text>` so free-form operator requests are passed into the config-agent prompt
- fix: report the actual selected agent name in `carranca run` session output instead of the container name
- fix: install the Codex CLI in this repo's Carranca agent container so the configured `codex` agent runs successfully
- docs: update README, configuration, architecture, and session-log docs for multi-agent config, command help, and improved `carranca log` output
- docs: add repository `LICENSE` and Carranca artwork used in the README header
- test: expand unit, integration, and failure coverage for agent selection, prompt plumbing, and `agents:` validation
- test: 214 tests, 13 suites, 100% function coverage (35/35)

## [0.5.0] - 2026-03-22

- feat: add `carranca log` to pretty-print the latest or selected session log for the current repo
- feat: improve `carranca log` with unique-path counts, file-event totals, top touched paths, and clearer agent-native edit summaries
- feat: add command-specific help routing via both `carranca help <command>` and `carranca <command> help`
- test: add unit, failure-mode, and Docker integration coverage for `carranca log`
- test: add coverage for help routing, sparse-session summaries, and log parsing helpers
- test: 191 tests, 13 suites, 100% function coverage (27/27)

## [0.4.0] - 2026-03-22

- feat: add `carranca config` to launch the bound agent, apply `confiskill`, and propose `.carranca.yml` and `.carranca/Containerfile` updates
- feat: run `carranca config` with the same interactive TTY flow as `carranca run` so cached agent auth/session state is reused
- feat: mount Carranca-managed and user-managed skills separately inside the agent container
- fix: keep `carranca config` propose-only by sourcing built-in skills from the Carranca install instead of mutating the workspace before confirmation
- fix: validate unsupported `agent.adapter` values early and require a detected stack summary in generated proposals
- docs: document the `config` workflow, skill mounts, and interactive adapter behavior
- test: add integration, failure-mode, and unit coverage for `carranca config` and adapter resolution
- test: 132 tests, 10 suites, 100% function coverage (18/18)

## [0.3.0] - 2026-03-22

- feat: switch the default agent command and project scaffold to Codex
- feat: run the agent container as the invoking host user and preserve supplemental groups
- feat: move the default agent home and cache mount to `/home/carranca`
- fix: make the shared logger FIFO writable across container user boundaries
- fix: install `bubblewrap` in Codex agent images for sandboxed execution
- test: cover host uid/gid mapping, supplemental groups, agent home, and FIFO permissions
- test: 108 tests, 9 suites, 100% function coverage (17/17)
- docs: update configuration and architecture docs for the Codex-based runtime defaults

## [0.2.0] - 2026-03-22

- feat: persistent agent home directory across sessions (`volumes.cache` config)
- feat: custom volume mounts via `volumes.extra` config (e.g. SSH keys, reference docs)
- feat: YAML list parsing in config (`carranca_config_get_list`)
- feat: auto-detect TTY for non-interactive environments (tests/CI)
- fix: inline YAML comments no longer break config value parsing
- fix: logger graceful shutdown — `docker stop` (SIGTERM) instead of `docker rm -f` (SIGKILL)
- fix: logger read timeout allows SIGTERM trap to fire between reads
- fix: shell_command and agent_stop events now reliably appear in session logs
- feat: pre-commit hook auto-updates README test/coverage badges
- feat: test runner enforces 100% function coverage
- test: add unit tests for `carranca_log`, `carranca_die`, runtime helpers, hooks, badge update
- test: 93 tests, 9 suites, 100% function coverage (17/17)
- docs: document cache volumes, custom volumes, and badge workflow

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
