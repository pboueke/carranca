# Roadmap

Phased plan for extending carranca from foundation through adversarial
hardening and into broader operational integration.

Phases 1 through 6 are complete. The remaining items describe platform
integration work. Items within a phase are independent unless noted.

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

Move session logs from plain transparency features to cryptographically
verifiable evidence. This is the prerequisite for compliance and forensic use.

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

### ~~3.1 `execve` tracing via strace~~ ✓
Run strace inside the logger container attached to the agent PID namespace
via `--pid=container`. Log all `execve` calls with argv and PID. Merge
into the session JSONL stream as `execve_event` entries.

### ~~3.2 Network connection logging~~ ✓
When `runtime.network: true`, poll `/proc/net/tcp` to detect outbound
connections (dest IP, port, protocol). Emit `network_event` entries.
Records traffic without blocking it.

### ~~3.3 Secret read monitoring~~ ✓
Use `fanotify` (Linux) via a small C binary compiled against musl to
capture file open events on `watched_paths`. Emit `file_access_event`
for reads on sensitive files. Requires `CAP_SYS_ADMIN` in the logger.

### ~~3.4 Resource consumption tracking~~ ✓
Periodically sample agent container CPU, memory, and PID count via
cgroup v2 stats mounted at `/hostcgroup`. Emit `resource_event` entries.
Enables post-session cost estimation and anomaly detection.

### ~~3.5 Session timeline visualization~~ ✓
`carranca log --timeline` renders an ASCII timeline of all session
events: commands, file mutations, execve calls, network connections,
resource samples. Makes session review fast and intuitive.

---

## Phase 4 — Policy enforcement

Move from advisory policies (prompt-level guidance) to technical
enforcement that the agent cannot bypass.

### ~~4.1 Fine-grained network policies~~ ✓
Replace the boolean `runtime.network` with a policy object:

```yaml
runtime:
  network:
    default: deny
    allow:
      - "*.anthropic.com:443"
      - "registry.npmjs.org:443"
```

Implemented via container network namespace + iptables rules in
`network-setup.sh`. Blocked attempts logged as policy events.

### ~~4.2 Filesystem access control~~ ✓
Enforce read-only or deny access to paths listed in `watched_paths`.
Use bind-mount options (`:ro`) and seccomp profiles to prevent the
agent from writing outside allowed directories.

### ~~4.3 Technical policy hooks~~ ✓
Replace prompt-level `docs_before_code` and `tests_before_impl` with
enforceable pre-commit hooks injected into the agent container. The
agent cannot commit code that violates the policy. Log violations as
`policy_event` entries.

### ~~4.4 Resource limits~~ ✓
Enforce CPU, memory, and disk quotas per session via cgroup limits.
Kill or pause the agent when limits are exceeded. Prevents runaway
agents from exhausting host resources.

### ~~4.5 Time-boxed sessions~~ ✓
Add `policy.max_duration` config. The logger removes the FIFO after the
configured wall-clock limit, triggering the agent's fail-closed exit.
Useful for unattended runs.

---

## Phase 5 — Adversarial hardening

Harden the runtime against a deliberately malicious agent. This phase
changes the trust model from "cooperative" to "untrusted".

### ~~5.1 Independent event ground truth~~ ✓
Run the execve tracer (Phase 3.1) and file watcher outside the agent's
PID/mount namespace so the agent cannot interfere. Cross-reference
agent-reported shell events against kernel-observed execve events.
Flag discrepancies as `integrity_event` entries.

### ~~5.2 FIFO forgery detection~~ ✓
Validate FIFO event structure and timing in the logger. Detect and flag
events with impossible timestamps, duplicate sequence numbers, or
payloads that don't match execve observations.

### ~~5.3 Seccomp and AppArmor profiles~~ ✓
Ship default seccomp and AppArmor profiles for the agent container that
block dangerous syscalls (ptrace, mount, reboot, module loading).
Configurable via `runtime.seccomp_profile` and `runtime.apparmor_profile`.

### ~~5.4 Read-only root filesystem~~ ✓
Run the agent container with `--read-only` and explicit tmpfs mounts
for writable paths. Prevents the agent from modifying its own runtime
environment.

### ~~5.5 Capability drop~~ ✓
Drop all Linux capabilities from the agent container by default.
`cap_add` in config becomes an explicit allowlist, not an addition to
defaults.

---

## Phase 6 — Ecosystem and integration

Make carranca useful beyond single-engineer local runs.

### ~~6.1 CI/CD integration~~ ✓
`carranca run` auto-detects non-TTY environments and adjusts container
flags accordingly — no `--non-interactive` flag needed. `--timeout`
serves as a CLI convenience for `policy.max_duration` (minimum wins).
Session logs become CI artifacts via `carranca log --export`. Exit code
reflects agent success + policy compliance: 0 success, 71 logger loss,
124 timeout. CI usage patterns documented in `doc/ci.md`.

### ~~6.2 Multi-agent orchestration~~ ✓
Multiple agents run in a single session with independent logging
streams. `orchestration.mode: pipeline` runs agents sequentially
(fail-fast); `orchestration.mode: parallel` runs them concurrently.
Each agent gets its own container, FIFO, logger, and security boundary.
Workspace isolation via `cp -a` with configurable merge strategy.
Documented in `doc/multi-agent.md`.

### ~~6.3 Session diff and comparison~~ ✓
`carranca diff <session-a> <session-b>` compares two sessions: files
touched, commands run, duration, resource usage, network activity, and
policy violations. Default output is compact tab-separated; `--pretty`
flag for human-readable formatted display. Supports cross-repo
comparison via `--repo-a`/`--repo-b`.

---

## Phase 7 — Platform integration

Extend carranca into a team-wide platform with remote storage and
extensibility.

### 7.1 Central log aggregation
`carranca log --push` sends session logs to a remote endpoint (S3,
GCS, or a custom receiver). Enables team-wide session review and
compliance dashboards.

### 7.2 Plugin / extension API
Define a hook interface (`on_event`, `on_session_start`,
`on_session_end`) that external scripts can implement. Enables custom
alerting, metrics export, or integration with internal tools without
forking carranca.

---

## Sequencing and dependencies

Phases 1–6 are complete. Phase 7 (platform integration) depends on
exportable logs from Phase 2 and CI integration from Phase 6.
