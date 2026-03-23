# TODOs

## log and status command info
log and status commands should provide agent/engine information for that session

## Fine-grained network isolation
`runtime.network` is a boolean (on/off). Add support for fine-grained network policies
(e.g., allow only specific domains or ports).

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
