# Phase 5 — Adversarial Hardening: Implementation Plan

## Context

Phases 1–4 are complete. Carranca currently assumes a cooperative agent — one that is buggy but not malicious. Phase 5 shifts the trust model to "untrusted agent" by hardening container isolation, adding kernel-level verification independent of the agent, and detecting FIFO event forgery. Dependencies (Phase 2 HMAC signing, Phase 3 execve tracing) are already in place.

---

## Implementation Order

```
5.5 Capability Drop           ← simplest, no arch changes, reduces attack surface first
5.4 Read-Only Root Filesystem  ← additive container flag, pairs with 5.5
5.3 Seccomp + AppArmor         ← static profiles + flag wiring
5.2 FIFO Forgery Detection     ← logger-internal validation, no new containers
5.1 Independent Ground Truth   ← most complex, namespace restructure + observer sidecar
```

Rationale: 5.5/5.4 are small flag additions that immediately reduce agent capabilities. 5.3 ships profiles. 5.2 is logger-internal. 5.1 is the deepest architectural change and benefits from the reduced attack surface of 5.5/5.4/5.3 being in place.

---

## 5.5 Capability Drop

**What**: Add `--cap-drop ALL` to agent container. `runtime.cap_add` becomes a strict allowlist applied after the drop.

**Config key**: `runtime.cap_drop_all: true` (1-level nesting, awk-compatible, consistent with existing `runtime.cap_add`)

**Design notes**:
- Docker/Podman process `--cap-drop ALL` before `--cap-add`, so `--cap-drop ALL --cap-add NET_ADMIN` correctly yields only NET_ADMIN
- `network-setup.sh` already gets `--cap-add NET_ADMIN` via `NETWORK_POLICY_FLAGS` — no change needed there
- Default `true` in template; `false` to opt out

**Files to modify**:
- `cli/run.sh` — read config, build `CAP_DROP_FLAG="--cap-drop ALL"`, insert before `$CAP_ADD_FLAGS` in agent run command
- `templates/carranca.yml.tmpl` — add commented key
- `doc/configuration.md` — field reference row
- `doc/trust-model.md` — update capability drop row

**Tests**:
- Unit: flag generation returns `--cap-drop ALL` when true, empty when false
- Integration: agent with dropped caps cannot run `chown`; combined with `runtime.network: filtered` still works

---

## 5.4 Read-Only Root Filesystem

**What**: Add `--read-only` to agent container with explicit `--tmpfs` mounts for writable paths.

**Config key**: `runtime.read_only: true`

**Writable tmpfs paths**: `/tmp`, `/var/tmp`, `/run`. The `/workspace` bind-mount (`:rw`), `/fifo` tmpfs volume, and `/home/carranca` cache bind-mount already override the root FS. When `volumes.cache: false`, add `--tmpfs /home/carranca`.

**Files to modify**:
- `cli/run.sh` — read config, build `READ_ONLY_FLAGS`, handle cache-disabled case
- `templates/carranca.yml.tmpl` — add commented key
- `doc/configuration.md` — field reference row
- `doc/trust-model.md` — update row

**Tests**:
- Integration: write to `/tmp` succeeds, write to `/usr/local/bin` fails with EROFS
- Integration: `volumes.cache: false` + `read_only: true` — agent home still writable
- Integration: `read_only: false` — root FS writes succeed

---

## 5.3 Seccomp and AppArmor Profiles

**What**: Ship a seccomp JSON profile blocking dangerous syscalls. AppArmor as opt-in reference profile.

**Config keys**: `runtime.seccomp_profile: default` ("default" = carranca's built-in, "unconfined" = disable, or absolute path to custom). `runtime.apparmor_profile: ""` (empty = runtime default, profile name if loaded by user, "unconfined" to disable).

**Seccomp blocklist** (additions to Docker's default): `ptrace`, `mount`, `umount2`, `reboot`, `init_module`, `finit_module`, `delete_module`, `pivot_root`, `swapon`, `swapoff`, `sethostname`, `setdomainname`, `unshare`, `setns`

**AppArmor**: Reference profile at `runtime/security/apparmor-agent.profile`. Documented loading procedure (`apparmor_parser -r`). Not applied by default — user must load and set config.

**macOS**: Skip seccomp/apparmor flags with log message (Docker Desktop VM handles this differently).

**Files to create**:
- `runtime/security/seccomp-agent.json` — seccomp profile JSON
- `runtime/security/apparmor-agent.profile` — reference AppArmor profile

**Files to modify**:
- `cli/run.sh` — read config, build `--security-opt seccomp=<path>` and optionally `--security-opt apparmor=<name>` flags
- `templates/carranca.yml.tmpl` — add commented keys
- `doc/configuration.md` — field reference rows + AppArmor loading docs
- `doc/trust-model.md` — update seccomp/apparmor rows

**Tests**:
- Unit: `test_seccomp_profile.sh` — validate JSON is well-formed (jq/python3)
- Integration: agent with default profile cannot call `unshare`; with `unconfined` it can

---

## 5.2 FIFO Forgery Detection

**What**: Structural and temporal validation of every FIFO event before logging.

**No new config key** — always on, zero performance cost.

**Validation rules**:
1. **Required fields**: `type`, `source`, `ts`, `session_id` must be present. Missing → `integrity_event` reason `missing_required_fields`
2. **Timestamp bounds**: `ts` before `SESSION_START_TS` → `timestamp_before_session`. `ts` > 5s in future → `timestamp_future`. `ts` regresses > 60s from previous event → `timestamp_regression`
3. **Seq injection**: If FIFO event contains `seq` or `hmac` fields, strip them and flag as `seq_injection_attempt` (logger is sole authority on seq/hmac)
4. **Source impersonation**: FIFO events claiming `source` other than `shell-wrapper` (e.g., `strace`, `inotifywait`, `carranca`) → `source_impersonation`. Those sources write directly to the log, never through FIFO

**Design**: New `_validate_fifo_event()` function in logger.sh, called before `write_log()` in the FIFO main loop. Flagged events still get logged (we log everything, annotate with integrity_event). `write_log()` also strips `seq`/`hmac` from incoming events before injecting real values.

**Files to modify**:
- `runtime/logger.sh` — add `SESSION_START_TS` tracking, `_validate_fifo_event()`, field stripping in `write_log()`
- `doc/session-log.md` — document `integrity_event` type and reason values
- `doc/trust-model.md` — update "Agent forges shell events via FIFO" to "Mitigated"

**Tests**:
- Unit: `test_fifo_validation.sh` — test each validation rule: valid event passes, missing type flagged, future timestamp flagged, seq injection stripped and flagged, source impersonation flagged
- Integration: inject malformed event into FIFO from agent, verify `integrity_event` in log

---

## 5.1 Independent Event Ground Truth

**What**: Run execve tracer and network monitor outside the agent's PID/mount namespace. Cross-reference agent-reported events against kernel observations. Flag discrepancies.

**Config key**: `observability.independent_observer: false` (opt-in initially; becomes default in future)

### Architecture: Observer Sidecar

Current model: agent joins logger's PID namespace (`--pid=container:$LOGGER_NAME`) — agent can see/interfere with logger processes.

New model: **third sidecar container** (the "observer"):
- Uses `--pid=host` to see all host processes
- Has `CAP_SYS_PTRACE` for strace
- Mounts `/fifo` (same tmpfs) to write events
- Mounts `/state` to read agent container ID
- Does NOT share any namespace with the agent
- Reuses the logger image (already has strace, bash, tools)

The agent gets its own default PID namespace (no `--pid` flag). It cannot see observer or logger processes.

### Observer lifecycle (`runtime/observer.sh`)

1. Wait for `/state/agent-container-id` (written by existing background resolver in `cli/run.sh`)
2. Find agent's host PID via `/proc/*/cgroup` matching against container ID
3. Run `strace -f -e trace=execve -p <host_pid>` — parse with shared strace parser
4. Poll `/proc/<host_pid>/net/tcp` for network connections
5. Write `execve_event` and `network_event` to FIFO with `source: "observer"`
6. Exit when agent PID disappears

### Cross-referencing (`_cross_reference_events()` in logger.sh)

Runs during `_cleanup()` before writing `logger_stop`. Scans the JSONL log:
- `shell_command` with zero corresponding `execve_event` in time window → `integrity_event` reason `shell_command_without_execve`
- `execve_event` with no corresponding `shell_command` → `integrity_event` reason `unmatched_execve_activity`

### Shared code extraction

Extract `_strace_to_event()` from `runtime/logger.sh` into `runtime/lib/strace-parser.sh`. Both logger.sh (fallback path) and observer.sh source it.

### When `independent_observer: true`

- Logger skips `_start_execve_tracer()` and `_start_network_monitor()` (observer handles these)
- Agent container launched without `--pid=container:$LOGGER_NAME`
- Observer container launched between logger and agent

### When `independent_observer: false` (default, backward compat)

- Existing behavior: agent joins logger PID ns, logger runs strace internally

**Files to create**:
- `runtime/observer.sh` — observer entrypoint
- `runtime/lib/strace-parser.sh` — extracted shared parser

**Files to modify**:
- `cli/run.sh` — conditional PID ns flag removal, observer container launch, env vars
- `cli/lib/session.sh` — `carranca_session_observer_name()`, update `carranca_session_stop()` to stop observer
- `runtime/logger.sh` — skip internal tracers when observer active, add `_cross_reference_events()`, allow `source: "observer"` in FIFO validation (5.2 allowlist update)
- `templates/carranca.yml.tmpl` — add commented key
- `doc/configuration.md` — field reference row
- `doc/trust-model.md` — update rows for independent ground truth

**Tests**:
- Unit: `test_observer.sh` — PID discovery function with mock `/proc`, cross-reference function with canned JSONL (matching → no integrity_event, mismatching → integrity_event)
- Unit: `test_strace_parser.sh` — verify extracted parser still works (port existing test_execve_parser.sh tests)
- Integration: session with `independent_observer: true` — observer starts, execve events in log, agent `ps aux` shows no strace, observer cleaned up on exit

---

## File Change Map

| File | 5.5 | 5.4 | 5.3 | 5.2 | 5.1 |
|------|-----|-----|-----|-----|-----|
| `cli/run.sh` | M | M | M | | M |
| `runtime/logger.sh` | | | | M | M |
| `runtime/observer.sh` | | | | | NEW |
| `runtime/lib/strace-parser.sh` | | | | | NEW |
| `runtime/security/seccomp-agent.json` | | | NEW | | |
| `runtime/security/apparmor-agent.profile` | | | NEW | | |
| `cli/lib/session.sh` | | | | | M |
| `templates/carranca.yml.tmpl` | M | M | M | | M |
| `doc/configuration.md` | M | M | M | | M |
| `doc/trust-model.md` | M | M | M | M | M |
| `doc/session-log.md` | | | | M | M |
| `doc/roadmap.md` | M | M | M | M | M |
| `tests/unit/test_cap_drop.sh` | NEW | | | | |
| `tests/unit/test_seccomp_profile.sh` | | | NEW | | |
| `tests/unit/test_fifo_validation.sh` | | | | NEW | |
| `tests/unit/test_observer.sh` | | | | | NEW |

---

## Verification

After each sub-item:
1. `make test` — all existing 504+ tests pass
2. New unit tests pass for the sub-item
3. `make integration` — integration tests pass including new cases
4. Manual smoke test: `carranca run` with the new config keys enabled, verify session completes and log contains expected events
5. `shellcheck` passes on all modified/new shell scripts

After all five:
- Run a session with all Phase 5 features enabled simultaneously
- Verify `integrity_event` entries appear when injecting test forgeries
- Verify agent cannot `ptrace`, `unshare`, write to root FS, or see observer processes
- `carranca log --verify` passes on the resulting session
- `carranca log --timeline` renders integrity events (new glyph: `!`)
