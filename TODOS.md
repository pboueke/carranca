# TODOs

## init and config updates for multi agent setup
- multi agent setup. Carranca config file must support multiple agents, first is used by default during run and config executions
- run command can receive extra --[claude|codex|etc] param that has it launch the selected agent instead of the default one
- config command must allow for user request. When provided, agent focus on user request. For example: 'carranca config codex', has config agent run to update configs in order to add claude agent
- init command must check for init status. If already inited, suggest use of config command. If --force is used, ask for confirmation of possibly ovewrite


## `carranca status` — Show active/recent sessions
List running carranca sessions (via compose project listing) and 5 most recent
JSONL files from the state directory. Depends on: core MVP.

## HMAC-signed events — Verified audit trail
Session logs are currently transparency tools, not tamper-proof evidence. `chattr +a`
append-only protection is best-effort and degrades silently. Add HMAC signing to
produce cryptographically verified event chains. Phase 2.

## `execve` tracing — Complete operation capture
Only shell commands invoked through the wrapper are logged. Direct syscalls, library
calls, or subprocesses spawned by the agent bypass the wrapper. Add kernel-level
execve tracing for full operation capture. Phase 2.

## Cross-platform file events — `fswatch` adapter
`inotifywait` is Linux-only. macOS/Windows get shell logging but no file mutation
tracking. Add a `fswatch` adapter for cross-platform support.

## Robust YAML parser
`config.sh` uses awk to parse YAML with only one level of nesting supported. Complex
YAML (lists-of-objects, multi-line strings, anchors) will break. Replace with a proper
parser or validate against a schema.

## Global config support
`~/.config/carranca/` is referenced in docs but unused in v0.1.0. Implement global
config for user-wide defaults (e.g., default agent, network policy).

## Advisory-only policy enforcement
`docs_before_code` and `tests_before_impl` policies are prompt-level guidance via
SKILL.md files, not technically enforced. Add optional technical enforcement (e.g.,
pre-commit hooks, blocked paths). Phase 2.

## Multi-session management
No mechanism to list, stop, or manage concurrent sessions. Each `carranca run` is
independent. Add session tracking and lifecycle management.

## Podman / OCI runtime support
Hardcoded `docker` commands throughout. Add support for Podman and other OCI-compliant
container runtimes.

## Fine-grained network isolation
`runtime.network` is a boolean (on/off). Add support for fine-grained network policies
(e.g., allow only specific domains or ports).

## Wire up `cap_add` config
The `cap_add` config field is parsed but never passed to `docker run`. Implement
capability injection or remove the field.

## Wire up `watched_paths` config
`watched_paths` is listed in config but not used to restrict or alert on access to
sensitive paths. Implement alerting or access control for watched paths.

## Adversarial agent hardening
The trust model assumes cooperative (buggy, not adversarial) agents. A malicious agent
could tamper with logging (e.g., write garbage to the FIFO, manipulate timestamps).
Harden the runtime for adversarial scenarios if needed.

## `carranca log` follow-ups
- add filters for files-only and commands-only views
- add `--top <n>` for top touched paths
- add a full touched-path list mode for a session
