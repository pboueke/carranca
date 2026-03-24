# Changelog

## [0.15.0] - 2026-03-24

- feat: **capability drop** — `runtime.cap_drop_all: true` (default) adds `--cap-drop ALL` to the agent container; `runtime.cap_add` becomes a strict allowlist applied after the drop
- feat: **read-only root filesystem** — `runtime.read_only: true` (default) adds `--read-only` with explicit tmpfs mounts for `/tmp`, `/var/tmp`, `/run`; when cache is disabled, `/home/carranca` gets a tmpfs mount
- feat: **seccomp filtering** — default seccomp profile at `runtime/security/seccomp-agent.json` blocks dangerous syscalls (ptrace, mount, unshare, reboot, module loading, pivot_root, swapon/swapoff, sethostname/setdomainname, setns); configurable via `runtime.seccomp_profile`
- feat: **AppArmor reference profile** — `runtime/security/apparmor-agent.profile` shipped as opt-in reference; configurable via `runtime.apparmor_profile`
- feat: **FIFO forgery detection** — `_validate_fifo_event()` in logger validates every FIFO event: required fields, timestamp bounds (before session, future, regression), seq/hmac injection stripping, source impersonation detection; emits `integrity_event` entries
- feat: **independent observer sidecar** — `observability.independent_observer: true` launches a third container with `--pid=host` and `CAP_SYS_PTRACE` that runs execve tracing and network monitoring outside the agent's namespaces; agent cannot see or interfere with observation
- feat: **cross-referencing** — logger compares shell_command and execve_event timestamps at session end; flags `shell_command_without_execve` and `unmatched_execve_activity` as integrity events
- feat: **shared strace parser** — `runtime/lib/strace-parser.sh` extracted from logger.sh; sourced by both logger (legacy path) and observer (independent path)
- feat: `integrity_event` JSONL event type with `reason` and `raw_source` fields; `!` glyph in `--timeline`
- feat: observer lifecycle events (`observer_start`, `observer_stop`) in session log
- feat: session cleanup updated to stop observer container between agent and logger teardown
- docs: all Phase 5 roadmap items (5.1–5.5) marked complete
- docs: trust model updated — design assumption expanded for untrusted agents; threat table entries upgraded from "Partially mitigated" to "Mitigated"
- docs: architecture updated with observer sidecar and agent hardening flags
- docs: session-log updated with `integrity_event` type, observer source provenance, and cross-reference reasons
- docs: configuration updated with `runtime.cap_drop_all`, `runtime.read_only`, `runtime.seccomp_profile`, `runtime.apparmor_profile`, `observability.independent_observer`
- test: 562 tests, 28 unit suites, 0 failures
- test: new suites — `test_cap_drop.sh`, `test_seccomp_profile.sh`, `test_fifo_validation.sh`, `test_observer.sh`, `test_strace_parser.sh`
- test: updated suites — `test_session.sh` (observer cleanup), `test_execve_parser.sh` (shared parser)

## [0.14.0] - 2026-03-23

- feat: **resource limits** — `policy.resource_limits.{memory,cpus,pids}` passed as `--memory`, `--cpus`, `--pids-limit` container runtime flags; kernel enforces via cgroup limits
- feat: **OOM kill detection** — resource sampler polls cgroup `memory.events` for `oom_kill` counter increments; emits `policy_event` with `action: oom_kill`
- feat: **time-boxed sessions** — `policy.max_duration` (seconds) triggers FIFO removal after the wall-clock limit, which activates the agent's fail-closed watchdog and terminates the session
- feat: **filesystem access control** — `policy.filesystem.enforce_watched_paths: true` bind-mounts `watched_paths` directories and files as read-only overlays; glob patterns degrade gracefully (monitored but not enforced)
- feat: **technical policy hooks** — `policy.docs_before_code` and `policy.tests_before_impl` now accept `enforce` (block commit), `warn` (allow + log), or `off`; enforced via git `core.hooksPath` pointing to carranca-managed pre-commit hook injected into the agent container
- feat: **fine-grained network policies** — `runtime.network` supports an object form (`default: deny` + `allow:` list) alongside the existing boolean; implemented via iptables OUTPUT DROP + per-IP allow rules in `network-setup.sh`, a privilege-dropping entrypoint wrapper
- feat: **`policy_event` event type** — new JSONL event for all enforcement actions with `policy`, `action`, and `detail` fields; `P` glyph in `--timeline`; counted in session summary
- feat: **`network-setup.sh`** — agent entrypoint wrapper that runs as root, applies iptables rules, creates a matching user via `adduser`, then drops privileges with `su` before exec-ing shell-wrapper
- feat: rootless Podman graceful degradation for network policies (falls back to `--network=none`; clears policy env vars so logger does not emit false-positive enforcement events)
- feat: `policy.*` keys added to global config fallback alongside `runtime.*`, `volumes.*`, and `observability.*`
- docs: `policy_event` documented in session-log.md with field reference and provenance table entries for `pre-commit-hook` and `network-setup` sources
- docs: all Phase 4 policy fields documented in configuration.md; `runtime.network.default` restricted to `deny` only
- docs: trust model updated — "Technical policy enforcement" moved from "Not provided" to "Provided"
- docs: architecture.md updated with `network-setup.sh` conditional entrypoint
- docs: all Phase 4 roadmap items (4.1–4.5) marked complete
- docs: move the changelog to `doc/CHANGELOG.md` and update contributor/versioning docs to use the new canonical path
- test: 504 tests, 23 unit suites, 100% function coverage
- test: new suites — `test_policy_resource_limits.sh`, `test_policy_timer.sh`, `test_policy_filesystem.sh`, `test_policy_hooks.sh`, `test_policy_network.sh`
- test: updated suites — `test_timeline.sh` (policy P glyph), `test_resource_sampler.sh` (policy_event counting in summary), `test_config.sh` (policy global fallback)

## [0.13.0] - 2026-03-23

- feat: add `carranca log --timeline` for ASCII timeline rendering of session events
- feat: add `execve` tracing via strace — captures all process execution in agent PID namespace (`observability.execve_tracing`)
- feat: add network connection logging by polling `/proc/net/tcp` (`observability.network_logging`)
- feat: add secret read monitoring via fanotify C binary — detects file reads on `watched_paths` (`observability.secret_monitoring`)
- feat: add resource consumption tracking via cgroup v2 stats (`observability.resource_interval`)
- feat: add `observability.*` config namespace with global fallback support
- feat: PID namespace sharing (`--pid=container`) when execve tracing or network logging is enabled
- feat: multi-stage Containerfile.logger build for fanotify-watcher C binary
- docs: add Phase 3 event types to session-log.md (execve_event, network_event, resource_event, file_access_event)
- docs: update trust model with deep observability capabilities and updated threat table
- docs: add observability config keys to configuration.md
- docs: mark all Phase 3 roadmap items (3.1–3.5) as complete
- test: add coverage for timeline rendering, strace parser, network monitor, resource sampler, and fanotify integration
- test: 392 tests, 17 suites, 0 failures

## [0.12.0] - 2026-03-23

- feat: add HMAC-signed event chain — per-session key signs each JSONL event with chained HMAC-SHA256; `carranca log --verify` validates the chain
- feat: add parallel SHA-256 checksum file for tamper detection when `chattr +a` is unavailable (rootless Podman, macOS)
- feat: add event provenance tagging — `source` field on all events distinguishes ground-truth observations from agent-reported data
- feat: add `carranca log --export` to produce self-contained signed archive (tar + HMAC signature) for compliance, forensics, and external storage
- feat: add `opencode` as a supported starter agent for `carranca init`
- feat: accept `opencode` as an explicit adapter and infer it from `adapter: default` when the command starts with `opencode`
- feat: run config agents with the `opencode` adapter through the argument-based prompt path
- fix: `carranca log --verify` now resolves the session log before verification (previously used unset variable)
- fix: install OpenCode from the official release binary instead of the broken npm wrapper package
- docs: update trust model with verified audit evidence, HMAC chain, checksum hardening, and log export
- docs: add event provenance trust table to session-log.md
- docs: mark all Phase 2 roadmap items as complete
- docs: document `opencode` starter and adapter support across README and configuration docs
- docs: add `doc/vision.md` and link it from the README documentation index
- test: add coverage for HMAC functions, checksum verification, export archive, and provenance tagging
- test: add init, config, and help coverage for `opencode` starter and adapter flows
- test: 294 tests, 12 suites, 100% function coverage

## [0.11.0] - 2026-03-23

- feat: add `runtime.cap_add` config — list of Linux capabilities passed as `--cap-add` flags to the agent container
- feat: wire up `watched_paths` — file events matching watched patterns are tagged with `"watched":true` in session logs
- feat: add agent, adapter, and engine metadata to session start events and log/status summary
- feat: add `--files-only`, `--commands-only`, and `--top N` filters to `carranca log`
- feat: add fswatch fallback for cross-platform file event monitoring
- feat: add global config at `~/.config/carranca/config.yml` for user-wide runtime and volume defaults
- feat: use `yq` as primary YAML parser when available, with awk fallback and schema compatibility warnings
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
