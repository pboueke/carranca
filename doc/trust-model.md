# Trust Model

## Design assumption

Carranca is designed to handle both **cooperative agents** (buggy or careless)
and **untrusted agents** (potentially adversarial). The default configuration
applies adversarial hardening: all capabilities dropped, read-only root
filesystem, seccomp filtering, and FIFO forgery detection. With
`observability.independent_observer: true`, the runtime provides independent
kernel-level ground truth that the agent cannot interfere with, enabling
cross-referencing to detect unreported or forged activity.

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
| execve tracing | Ground truth | strace captures all process execution in agent PID namespace |
| Independent observer | Ground truth | Execve/network monitoring in separate sidecar outside agent's namespaces; observer events authenticated via shared token on `/state/` (agent cannot access). Cross-referencing at session end is a best-effort heuristic (±3s window, greedy 1:1 match) that flags anomalies for human review |
| Network logging | Ground truth | `/proc/net/tcp` polling captures outbound connections |
| Secret read monitoring | Ground truth | fanotify captures file reads on watched paths |
| Resource tracking | Transparency tool | cgroup v2 stats sample CPU, memory, and PID count |
| Resource limits | Hard boundary | Container runtime enforces `--memory`, `--cpus`, `--pids-limit` via cgroup limits |
| Time-boxed sessions | Hard boundary | Logger removes FIFO after `policy.max_duration` seconds, triggering agent fail-closed exit |
| Filesystem access control | Hard boundary | Bind-mount `:ro` overlays prevent writes to `watched_paths` entries |
| Policy hooks | Enforcement tool | Git `core.hooksPath` injects pre-commit hooks; `enforce` mode blocks policy-violating commits |
| Network policies | Hard boundary | iptables rules restrict outbound traffic to allow-listed destinations (rootful mode only) |
| Capability drop | Hard boundary | `--cap-drop ALL` removes all Linux capabilities; `runtime.cap_add` is a strict allowlist |
| Read-only root FS | Hard boundary | `--read-only` prevents agent from modifying its own runtime environment; explicit tmpfs for writable paths |
| Seccomp filtering | Hard boundary | Default seccomp profile blocks dangerous syscalls (ptrace, mount, unshare, module loading, etc.) |
| AppArmor confinement | Opt-in hardening | Reference AppArmor profile restricts file access, mounts, and ptrace; user must load and configure |

## What carranca does NOT provide

| Property | Status | Path to resolution |
|----------|--------|--------------------|
| Verified audit evidence | Provided | HMAC-signed event chain + checksum file (Phase 2) |
| Complete operation capture | Provided | execve tracing via strace (Phase 3); requires `observability.execve_tracing: true` |
| Forgery resistance | Provided | FIFO validation detects structural/temporal forgery; observer events authenticated via token; cross-referencing is best-effort anomaly detection for human review (Phase 5) |
| Secret read monitoring | Provided | fanotify captures file reads on `watched_paths` (Phase 3); requires `observability.secret_monitoring: true` |
| Technical policy enforcement | Provided | Resource limits, time-boxed sessions, filesystem access control, git policy hooks, network filtering (Phase 4) |
| Capability hardening | Provided | All Linux capabilities dropped by default; agent runs with minimal privileges (Phase 5) |
| Cross-platform file events | Supported | inotifywait (Linux) with fswatch fallback |

## Threat table

| Threat | Status | Notes |
|--------|--------|-------|
| Agent edits/deletes session log | Mitigated | Agent container has no mount to log directory |
| Agent forges shell events via FIFO | Partially mitigated | Structural/temporal validation detects malformed forgeries (Phase 5); observer events are token-authenticated; cross-referencing flags timing anomalies but uses a ±3s heuristic |
| Agent suppresses events (kills FIFO) | Mitigated | Shell wrapper exits on broken pipe → agent stops |
| Agent bypasses shell wrapper | Partially mitigated | Independent observer captures execve calls from outside agent namespace; cross-referencing flags unreported activity as a heuristic for review (Phase 5). Observer must attach to the container init process to trace all descendants |
| Agent reads secrets from repo | Mitigated | fanotify captures file reads on `watched_paths` when `observability.secret_monitoring: true` |
| Agent exfiltrates over network | Partially mitigated | Network logging records outbound connections; set `runtime.network: false` to disable entirely |
| Agent writes malicious code | Allowed by design | Review via session log + git diff |
| User tampers with log after session | Mitigated | HMAC chain + checksum file detect post-session tampering; `chattr +a` when available |

## Failure behavior

| Scenario | Behavior |
|----------|----------|
| Shell logging unavailable (FIFO not created) | Fail closed — refuse to start agent |
| File event logging unavailable (no file watcher) | Degraded mode — shell logging continues |
| Logger dies mid-session | Fail closed — broken pipe kills agent |
| `chattr +a` unavailable | Degraded mode — log still written, not append-only |
| strace unavailable or `SYS_PTRACE` denied | Degraded mode — session proceeds without execve tracing |
| cgroup mount unreadable | Degraded mode — session proceeds without resource tracking |
| fanotify unavailable or `SYS_ADMIN` denied | Degraded mode — session proceeds without secret read monitoring |
| `/proc/net/tcp` unreadable (no PID ns sharing) | Degraded mode — session proceeds without network logging |

## Summary

Carranca is an isolation, audit, policy-enforcement, and adversarial-hardening
runtime. It makes sessions reviewable with cryptographic tamper detection,
kernel-observed telemetry, and technical controls such as resource limits, time
bounds, read-only root filesystem, capability drop, seccomp filtering, and
network restrictions. FIFO forgery detection validates event structure and
timing. The independent observer sidecar provides kernel-level ground truth
outside the agent's namespaces, with observer events authenticated via a shared
token on `/state/` that the agent cannot access. Cross-referencing at session
end is a best-effort heuristic (±3s timestamp window, greedy 1:1 matching)
that flags anomalies for human review — it is not a proof of forgery.
Post-session log tampering is detectable via the HMAC chain and parallel
checksum file. The current value proposition is not blind trust, but observable
execution with enforceable guardrails, adversarial hardening, and verifiable
evidence.
