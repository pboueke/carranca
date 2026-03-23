# Roadmap

Phased plan for evolving carranca from a transparency tool into a
comprehensive agent runtime with strong observability, verified audits,
security controls, and deep isolation.

Each phase builds on the previous one. Items within a phase are independent
unless noted.

---

## Phase 1 — Finish the foundation

Complete partially-wired features and fill cross-platform gaps so the
existing architecture is solid before adding new subsystems.

### ~~1.1 Wire up `cap_add` config~~ ✓
`runtime.cap_add` list is parsed and passed as `--cap-add` flags to the
agent container in both `run` and `config` commands.

### ~~1.2 Wire up `watched_paths` config~~ ✓
File events matching `watched_paths` patterns are tagged with
`"watched":true` in session logs. Summary displays watched event count.

### ~~1.3 Agent/engine metadata in logs~~ ✓
Session start events now include `agent`, `adapter`, and `engine` fields.
`carranca log` and `carranca status` display them in the summary.

### ~~1.4 Log command filters~~ ✓
`carranca log` supports `--files-only`, `--commands-only`, and `--top N`
flags for focused inspection.

### ~~1.5 Cross-platform file events~~ ✓
Logger auto-detects inotifywait (Linux) or fswatch (macOS) at startup.
Both produce the same `file_event` JSON schema with `source` identifying
which watcher was used.

### ~~1.6 Global config~~ ✓
`~/.config/carranca/config.yml` provides user-wide defaults for `runtime.*`
and `volumes.*` keys. Project config always overrides. Lists are replaced,
not merged.

### ~~1.7 Robust YAML parser~~ ✓
`yq` is used as the primary YAML parser when available, with the awk
parser as fallback. Schema validation warns about YAML features (multi-line
strings, anchors, deep nesting) that the awk fallback cannot handle.

---

## Phase 2 — Verified audit trail

Move session logs from transparency tools to cryptographically verifiable
evidence. This is the prerequisite for compliance and forensic use.

### ~~2.1 HMAC-signed event chain~~ ✓
Generate a per-session HMAC key (stored outside the agent container).
Each JSONL event includes an `hmac` field computed over
`previous_hmac || seq || timestamp || payload`. Verification:
`carranca log --verify` walks the chain and reports breaks.

### ~~2.2 Append-only enforcement hardening~~ ✓
On systems where `chattr +a` is not available (rootless Podman, macOS),
fall back to a logger-side checksum file written in parallel. The
checksum file lives outside the agent container and can detect
post-session tampering even without kernel immutability.

### ~~2.3 Event provenance tagging~~ ✓
Tag each event with its source (`shell-wrapper`, `inotifywait`,
`logger-internal`) so consumers can distinguish ground-truth events
from agent-reported ones. This makes forgery analysis possible without
changing the trust model.

### ~~2.4 Log export and archival~~ ✓
`carranca log --export <session>` produces a self-contained signed
archive (tar + detached signature) suitable for external storage,
compliance review, or incident postmortem.

---

## Phase 3 — Deep observability

Capture what the agent actually does at the kernel level, not just what
it reports through the shell wrapper.

### 3.1 `execve` tracing via eBPF/strace
Run a lightweight tracer (eBPF where available, strace fallback) inside
the logger container that attaches to the agent PID namespace. Log all
`execve` calls with argv, cwd, uid, and parent PID. Merge into the
session JSONL stream as `execve_event` entries.

### 3.2 Network connection logging
When `runtime.network: true`, log outbound connections (dest IP, port,
protocol) via eBPF or conntrack. Emit `network_event` entries. This
does not block traffic — it records it.

### 3.3 Secret read monitoring
Use `fanotify` (Linux) to capture file open events (not just mutations)
on paths listed in `watched_paths`. Emit `file_access_event` for reads
on sensitive files. Requires `CAP_SYS_ADMIN` in the logger container.

### 3.4 Resource consumption tracking
Periodically sample agent container CPU, memory, disk I/O, and network
bytes via cgroup stats. Emit `resource_event` entries. Enables
post-session cost estimation and anomaly detection.

### 3.5 Session timeline visualization
`carranca log --timeline <session>` renders an ASCII or HTML timeline
of events: commands, file mutations, execve calls, network connections.
Makes session review fast and intuitive.

---

## Phase 4 — Policy enforcement

Move from advisory policies (prompt-level guidance) to technical
enforcement that the agent cannot bypass.

### 4.1 Fine-grained network policies
Replace the boolean `runtime.network` with a policy object:

```yaml
runtime:
  network:
    default: deny
    allow:
      - "*.anthropic.com:443"
      - "registry.npmjs.org:443"
```

Implement via container network namespace + nftables rules or a
userspace proxy. Log all blocked attempts.

### 4.2 Filesystem access control
Enforce read-only or deny access to paths listed in `watched_paths`.
Use bind-mount options (`:ro`) and seccomp profiles to prevent the
agent from writing outside allowed directories.

### 4.3 Technical policy hooks
Replace prompt-level `docs_before_code` and `tests_before_impl` with
enforceable pre-commit hooks injected into the agent container. The
agent cannot commit code that violates the policy. Log violations as
`policy_event` entries.

### 4.4 Resource limits
Enforce CPU, memory, and disk quotas per session via cgroup limits.
Kill or pause the agent when limits are exceeded. Prevents runaway
agents from exhausting host resources.

### 4.5 Time-boxed sessions
Add `policy.max_duration` config. The logger kills the agent after the
configured wall-clock limit. Useful for unattended runs.

---

## Phase 5 — Adversarial hardening

Harden the runtime against a deliberately malicious agent. This phase
changes the trust model from "cooperative" to "untrusted".

### 5.1 Independent event ground truth
Run the execve tracer (Phase 3.1) and file watcher outside the agent's
PID/mount namespace so the agent cannot interfere. Cross-reference
agent-reported shell events against kernel-observed execve events.
Flag discrepancies as `integrity_event` entries.

### 5.2 FIFO forgery detection
Validate FIFO event structure and timing in the logger. Detect and flag
events with impossible timestamps, duplicate sequence numbers, or
payloads that don't match execve observations.

### 5.3 Seccomp and AppArmor profiles
Ship default seccomp and AppArmor profiles for the agent container that
block dangerous syscalls (ptrace, mount, reboot, module loading).
Configurable via `runtime.security_profile`.

### 5.4 Read-only root filesystem
Run the agent container with `--read-only` and explicit tmpfs mounts
for writable paths. Prevents the agent from modifying its own runtime
environment.

### 5.5 Capability drop
Drop all Linux capabilities from the agent container by default.
`cap_add` in config becomes an explicit allowlist, not an addition to
defaults.

---

## Phase 6 — Ecosystem and integration

Make carranca useful beyond single-engineer local runs.

### 6.1 Central log aggregation
`carranca log --push` sends session logs to a remote endpoint (S3,
GCS, or a custom receiver). Enables team-wide session review and
compliance dashboards.

### 6.2 CI/CD integration
Provide a `carranca run --non-interactive` mode for headless agent
execution in CI pipelines. Session logs become CI artifacts. Exit code
reflects agent success + policy compliance.

### 6.3 Multi-agent orchestration
Support running multiple agents in a single session with independent
logging streams. Useful for pipelines where one agent generates code
and another reviews it.

### 6.4 Session diff and comparison
`carranca diff <session-a> <session-b>` compares two sessions: files
touched, commands run, duration, resource usage. Useful for
reproducibility checks and regression analysis.

### 6.5 Plugin / extension API
Define a hook interface (`on_event`, `on_session_start`,
`on_session_end`) that external scripts can implement. Enables custom
alerting, metrics export, or integration with internal tools without
forking carranca.

---

## Sequencing and dependencies

```
Phase 1  ──────────────────────────────────────────────►
           Foundation (all items independent)

Phase 2  ────────────────────────────────────►
           Verified audits (2.1 before 2.4)

Phase 3        ──────────────────────────────────────►
                Deep observability (3.1 before 5.1)

Phase 4              ──────────────────────────────►
                      Policy enforcement (independent of 2/3)

Phase 5                    ──────────────────────────►
                            Adversarial (requires 3.1, 2.1)

Phase 6                          ──────────────────────────►
                                  Ecosystem (requires 2.4)
```

Phases 1–2 can begin immediately. Phase 3 and 4 can run in parallel
once Phase 1 is done. Phase 5 depends on kernel-level tracing from
Phase 3 and signing from Phase 2. Phase 6 depends on exportable logs
from Phase 2.
