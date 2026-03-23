# Trust Model

## Design assumption

Carranca assumes a **cooperative agent** — one that is buggy or careless but not
actively adversarial. The logging system provides value through visibility and
structure, not through verified guarantees.

## What carranca provides

| Property | Strength | Mechanism |
|----------|----------|-----------|
| Host isolation | Hard boundary | Container runtime boundary through Podman or Docker; the agent only sees mounted paths |
| Session logging | Transparency tool | Shell wrapper writes events to FIFO, logger writes JSONL |
| Event provenance | Transparency tool | Each event tagged with origin source for trust-level analysis |
| Fail-closed logging | Hard boundary | Broken FIFO pipe kills the shell wrapper → agent stops |
| Append-only log | Best-effort | `chattr +a` when `CAP_LINUX_IMMUTABLE` is available |
| HMAC event chain | Verified evidence | Per-session HMAC key signs each event; chain detects tampering |
| Checksum hardening | Verified evidence | Parallel SHA-256 checksum file for tamper detection without `chattr +a` |
| Log export | Archival | Self-contained signed tar archive for compliance and forensics |

## What carranca does NOT provide

| Property | Status | Path to resolution |
|----------|--------|--------------------|
| Verified audit evidence | Provided | HMAC-signed event chain + checksum file (Phase 2) |
| Complete operation capture | Not provided | Phase 3: `execve` tracing, adapter hooks |
| Forgery resistance | Partially mitigated | Agent can forge FIFO events, but provenance tags and HMAC chain expose inconsistencies |
| Secret read monitoring | Not provided | `inotifywait` captures mutations, not reads |
| Technical policy enforcement | Not provided | Phase 4: pre-commit hooks, blocked paths |
| Cross-platform file events | Supported | inotifywait (Linux) with fswatch fallback |

## Threat table

| Threat | Status | Notes |
|--------|--------|-------|
| Agent edits/deletes session log | Mitigated | Agent container has no mount to log directory |
| Agent forges shell events via FIFO | Not mitigated | No independent ground truth to verify events |
| Agent suppresses events (kills FIFO) | Mitigated | Shell wrapper exits on broken pipe → agent stops |
| Agent bypasses shell wrapper | Not mitigated | Native tool APIs, child processes bypass the wrapper |
| Agent reads secrets from repo | Not mitigated | `inotifywait` only captures mutations, not reads |
| Agent exfiltrates over network | Possible | Set `runtime.network: false` to disable |
| Agent writes malicious code | Allowed by design | Review via session log + git diff |
| User tampers with log after session | Mitigated | HMAC chain + checksum file detect post-session tampering; `chattr +a` when available |

## Failure behavior

| Scenario | Behavior |
|----------|----------|
| Shell logging unavailable (FIFO not created) | Fail closed — refuse to start agent |
| File event logging unavailable (no file watcher) | Degraded mode — shell logging continues |
| Logger dies mid-session | Fail closed — broken pipe kills agent |
| `chattr +a` unavailable | Degraded mode — log still written, not append-only |

## Summary

Carranca is a transparency tool with verified audit capabilities. It makes agent
sessions reviewable with cryptographic tamper detection. An adversarial agent with
arbitrary code execution inside the container can forge events through the FIFO, but
provenance tagging and the HMAC event chain make such forgery detectable through
cross-referencing. Post-session log tampering is detectable via the HMAC chain and
parallel checksum file. The value proposition is: structured visibility with
verifiable integrity is better than blind trust.
