# Usage

`page/index.html` is the primary technical reference. This document is the
task-oriented CLI guide: what each command does, which flags it accepts, and
how operators typically use it.

## Command summary

| Command | Purpose |
|---------|---------|
| `carranca init` | Scaffold `.carranca.yml` and `.carranca/Containerfile` for a supported starter agent |
| `carranca config` | Ask a configured agent to propose container and config updates for the current repo |
| `carranca run` | Start an interactive agent session in the configured runtime |
| `carranca log` | Inspect, filter, verify, export, or timeline-render session logs |
| `carranca diff` | Compare two session logs across multiple dimensions |
| `carranca status` | Show active sessions and recent logs for the current repository |
| `carranca kill` | Stop one active session or all active sessions after confirmation |
| `carranca help` | Show top-level or command-specific help |

## Global help

```text
Usage: carranca <command>
       carranca help <command>
```

Carranca also accepts `carranca <command> help` as command-specific help.

## `carranca init`

```text
Usage: carranca init [--agent <name>] [--force]
```

Scaffolds the project-local Carranca files in the current directory.

Options:

- `--agent <name>`: supported starters are `codex`, `claude`, and `opencode`
- `--force`: overwrite an existing `.carranca.yml` or `.carranca/Containerfile`

Typical use:

```bash
carranca init --agent codex
```

## `carranca config`

```text
Usage: carranca config [--agent <name>] [--prompt <text>] [--dangerously-skip-confirmation]
```

Runs the selected configured agent in config mode. The agent inspects the
workspace and proposes updates to `.carranca.yml` and `.carranca/Containerfile`
instead of editing the workspace directly.

Options:

- `--agent <name>`: choose a configured agent other than the first/default entry
- `--prompt <text>`: pass operator intent into the config workflow prompt
- `--dangerously-skip-confirmation`: apply the proposed diff without the final prompt

Typical use:

```bash
carranca config --prompt "install claude and add uv to the image"
```

## `carranca run`

```text
Usage: carranca run [--agent <name>] [--trust-repo-flags] [--timeout <seconds>]
```

Starts an interactive session for the selected configured agent. Carranca
builds the transient logger and agent images, starts the logger container, and
then launches the agent container with the shell wrapper and configured policy
controls.

Options:

- `--agent <name>`: run a named configured agent instead of the default first entry
- `--trust-repo-flags`: skip validation of `runtime.extra_flags` and `runtime.logger_extra_flags`
- `--timeout <seconds>`: maximum session duration in seconds. When both
  `--timeout` and `policy.max_duration` are set, the minimum wins.

Exit codes:

| Code | Meaning |
|------|---------|
| 0 | Agent succeeded, no policy violations |
| 1–125 | Agent exit code (pass-through) |
| 71 | Logger lost — audit trail interrupted (EX_OSERR) |
| 124 | Session timed out (max_duration exceeded) |

Typical use:

```bash
carranca run --agent codex
carranca run --agent codex --timeout 600
```

## `carranca log`

```text
Usage: carranca log [--session <exact-id>] [--files-only] [--commands-only] [--top <n>]
```

Prints the latest session log for the current repository by default. The same
command also exposes integrity verification, export, and timeline rendering.

Options:

- `--session <id>`: inspect a specific session by exact id
- `--files-only`: print only touched file paths
- `--commands-only`: print only captured commands
- `--top <n>`: limit the top-touched-path summary
- `--verify`: verify HMAC chain integrity and detect tampering
- `--export`: create a signed archive (`.tar` and `.tar.sig`) next to the session log
- `--timeline`: render a compact ASCII timeline of session events

Typical uses:

```bash
# latest session for this repo
carranca log

# exact session
carranca log --session abc12345

# integrity check
carranca log --verify --session abc12345

# event timeline
carranca log --timeline --session abc12345
```

## `carranca diff`

```text
Usage: carranca diff <session-a> <session-b> [--pretty] [--repo-a <id>] [--repo-b <id>]
```

Compares two session logs across multiple dimensions: duration, agent,
commands, files touched, resource usage, network activity, and policy
violations.

Options:

- `--pretty`: human-readable formatted output (default is compact tab-separated)
- `--repo-a <id>`: repository id for session A (default: current repo)
- `--repo-b <id>`: repository id for session B (default: current repo)

Typical uses:

```bash
# compact comparison of two sessions
carranca diff abc12345 def67890

# human-readable comparison
carranca diff abc12345 def67890 --pretty

# cross-repo comparison
carranca diff abc12345 def67890 --repo-a aaa111 --repo-b bbb222
```

## `carranca status`

```text
Usage: carranca status [--session <exact-id>]
```

Shows active sessions and the five most recent session logs for the current
repository. With `--session`, it switches to a detailed view for one exact
session id.

Options:

- `--session <id>`: show detailed status for one exact session

Typical uses:

```bash
# repo overview
carranca status

# one session
carranca status --session abc12345
```

## `carranca kill`

```text
Usage: carranca kill [--session <exact-id>]
```

Stops active Carranca sessions after confirmation. Without `--session`, the
command targets all active sessions globally.

Options:

- `--session <id>`: stop one exact session after confirmation

Typical uses:

```bash
# stop one session
carranca kill --session abc12345

# stop every active session
carranca kill
```

## Operator workflows

### Bootstrap a repository

```bash
carranca init --agent codex
carranca config --prompt "install project dev tools"
carranca run --agent codex
```

### Review a completed session

```bash
carranca status
carranca log --session abc12345
carranca log --timeline --session abc12345
carranca log --verify --session abc12345
```

### Enforce a tighter runtime

Define the policy in `.carranca.yml`, then run normally:

```yaml
runtime:
  network:
    default: deny
    allow:
      - registry.npmjs.org:443
  # Hardening defaults (shown for clarity)
  cap_drop_all: true
  read_only: true
  seccomp_profile: default

policy:
  docs_before_code: enforce
  tests_before_impl: warn
  max_duration: 1800
  resource_limits:
    memory: 2g
    cpus: "2.0"
    pids: 256
  filesystem:
    enforce_watched_paths: true

observability:
  independent_observer: true
  execve_tracing: true
```

```bash
carranca run --agent codex
```

## Related docs

- [page/index.html](page/index.html): primary technical reference
- [ci.md](ci.md): CI/CD integration guide
- [multi-agent.md](multi-agent.md): multi-agent orchestration guide
- [configuration.md](configuration.md): configuration schema and container reference
- [examples/README.md](examples/README.md): persona-based example configs and images
- [session-log.md](session-log.md): event types and log semantics
- [trust-model.md](trust-model.md): guarantees, limitations, and degraded modes
