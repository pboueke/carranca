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

## Current limitations and non-goals

| Limitation | Status | Notes |
|------------|--------|-------|
| Formal proof of agent honesty | Not provided | FIFO validation, token-authenticated observer events, and cross-referencing raise evidence quality, but the end-of-session matching remains a best-effort heuristic for human review |
| Remote attestation of the host, kernel, or container runtime | Not provided | Carranca trusts the operator-controlled machine and runtime; it does not produce third-party-verifiable attestation today |
| Complete semantic capture of every file change | Not provided | Carranca logs shell activity, execve events, file mutations, and watched-path reads, but it does not record a syscall-level proof of every byte written |
| Guaranteed fine-grained egress filtering in every runtime mode | Partially provided | Filtered allow-lists use iptables and require a mode that can apply those rules; rootless Podman falls back to `--network=none` instead of filtered allow-list enforcement |
| Strong cross-platform parity | Not provided | Linux has the most complete observability and enforcement model; macOS and Windows remain experimental |
| Protection from a malicious host operator or host root | Not provided | A host user with sufficient privilege can alter the runtime environment, inspect mounts, or interfere with containers outside Carranca's boundary |
| Prevention of bad code or bad intent | Not provided | Carranca constrains and records agent behavior; it does not decide whether the resulting code is safe or correct |

## Threat table

| Threat | Status | Notes |
|--------|--------|-------|
| Agent edits/deletes session log | Mitigated | Agent container has no mount to log directory |
| Agent forges shell events via FIFO | Partially mitigated | Structural/temporal validation detects malformed forgeries; observer events are token-authenticated; cross-referencing flags timing anomalies but uses a ±3s heuristic |
| Agent suppresses events (kills FIFO) | Mitigated | Shell wrapper exits on broken pipe → agent stops |
| Agent bypasses shell wrapper | Partially mitigated | Independent observer captures execve calls from outside agent namespace; cross-referencing flags unreported activity as a heuristic for review. Observer must attach to the container init process to trace all descendants |
| Agent reads secrets from repo | Mitigated | fanotify captures file reads on `watched_paths` when `observability.secret_monitoring: true` |
| Agent exfiltrates over network | Partially mitigated | Network logging records outbound connections; set `runtime.network: false` to disable entirely |
| Agent connects via IPv6 to bypass allow-list | Mitigated | ip6tables rules mirror iptables allow-list for IPv6 destinations. Degraded mode if ip6tables unavailable |
| Agent exfiltrates via DNS tunneling | Known limitation | DNS queries to configured resolvers are unrestricted. Data can be encoded in DNS subdomains. Use `runtime.network: false` or a DNS filtering proxy for high-security environments |
| Agent writes malicious code | Allowed by design | Review via session log + git diff |
| Malicious `.carranca.yml` (repo compromise) | Operator-scoped risk | `.carranca.yml` is operator-authored trusted input; `eval` of `AGENT_COMMAND` is by design to support shell syntax. If an attacker controls `.carranca.yml` they control the agent command — same as controlling any shell script in the repo. Config is hidden from the agent at runtime via `/dev/null` bind mount |
| Agent reads runtime policy config | Mitigated | `.carranca.yml` and `.carranca/` are hidden from the agent container via bind-mount overlays; `carranca config` redacts policy-sensitive fields before exposing config to the config agent |
| User tampers with log after session | Partially mitigated | HMAC chain + checksum file detect post-session tampering; `chattr +a` when available. Without `chattr +a` (rootless Podman), truncation and re-append with a valid HMAC chain is possible. Run `carranca log --verify` after sessions; consider external log shipping for high-assurance environments |

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

For details on the container UID model and user namespace isolation, see
[architecture.md — UID and user namespace model](architecture.md#uid-and-user-namespace-model).

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
