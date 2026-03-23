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
| Fail-closed logging | Hard boundary | Broken FIFO pipe kills the shell wrapper → agent stops |
| Append-only log | Best-effort | `chattr +a` when `CAP_LINUX_IMMUTABLE` is available |

## What carranca does NOT provide

| Property | Status | Path to resolution |
|----------|--------|--------------------|
| Verified audit evidence | Not provided | Phase 2: HMAC-signed events |
| Complete operation capture | Not provided | Phase 2: `execve` tracing, adapter hooks |
| Forgery resistance | Not provided | Agent can write fake events to FIFO |
| Secret read monitoring | Not provided | `inotifywait` captures mutations, not reads |
| Technical policy enforcement | Not provided | Phase 2: pre-commit hooks, blocked paths |
| Cross-platform file events | Linux only | Phase 2: `fswatch` adapter |

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
| User tampers with log after session | Partially mitigated | `chattr +a` when available |

## Failure behavior

| Scenario | Behavior |
|----------|----------|
| Shell logging unavailable (FIFO not created) | Fail closed — refuse to start agent |
| File event logging unavailable (no inotifywait) | Degraded mode — shell logging continues |
| Logger dies mid-session | Fail closed — broken pipe kills agent |
| `chattr +a` unavailable | Degraded mode — log still written, not append-only |

## Summary

Carranca is a transparency tool, not a security control. It makes agent sessions
reviewable — not provably correct. An adversarial agent with arbitrary code execution
inside the container can bypass most logging controls. The value proposition is:
structured visibility is better than blind trust.
