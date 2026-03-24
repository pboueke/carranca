# Multi-agent orchestration

Carranca supports running multiple agents in a single session. Each agent
gets its own container, FIFO, logger, and security boundary. The
orchestrator manages the session lifecycle and workspace isolation.

## Config

Add an `orchestration` section to `.carranca.yml`:

```yaml
agents:
  - name: coder
    adapter: claude
    command: "claude --dangerously-skip-permissions"
  - name: reviewer
    adapter: claude
    command: "claude --dangerously-skip-permissions"

orchestration:
  mode: pipeline       # pipeline | parallel
  workspace: isolated  # isolated | shared
  merge: carry         # carry | discard (pipeline only)
```

Orchestration activates automatically when `orchestration.mode` is set
and at least 2 agents are configured.

## Modes

### Pipeline

Agents run sequentially in the order they are declared in `agents:`.
Each agent must exit before the next starts. The pipeline aborts on
first failure (fail-fast).

Exit code: the first non-zero agent exit code, or 0 if all succeed.

### Parallel

All agents start concurrently. The orchestrator waits for all agents to
complete before proceeding to cleanup.

Exit code: the maximum (worst) exit code across all agents.

## Workspace isolation

### `isolated` (default)

Each agent gets its own copy of the workspace. Changes from one agent
are not visible to others unless explicitly merged.

In pipeline mode, the `merge` option controls what happens between
stages:

- `carry` (default): the next agent's workspace starts from the
  previous agent's final state. This is useful for code generation
  followed by review — the reviewer sees the coder's changes.
- `discard`: each agent starts from the original workspace. Useful for
  independent tasks like parallel linting and testing.

Workspace copies use `cp -a` for portability across all container
runtimes including rootless Podman.

### `shared`

All agents share the same `/workspace` mount. Changes are immediately
visible to other agents. This requires careful coordination and is
not recommended for untrusted agents.

## Security model

Each agent runs with its own:

- Container with independent seccomp, AppArmor, and capability profiles
- FIFO and logger (independent HMAC chains and audit trails)
- Network namespace and policy enforcement
- PID namespace (agents cannot see each other's processes)

Agents share **nothing** by default. The only shared resource is the
workspace when `workspace: shared` is explicitly configured.

## Log structure

A multi-agent session produces:

```
~/.local/state/carranca/sessions/<repo-id>/
  <session-id>.orchestrator.jsonl   # Orchestration events
  <session-id>.jsonl                # Per-agent session log
  <session-id>.hmac-key             # Per-agent HMAC key
  <session-id>.checksums            # Per-agent checksums
```

The orchestrator log records:

- `orchestration_event` with `event: session_start` — mode, workspace config
- `orchestration_event` with `event: agent_start` — per agent
- `orchestration_event` with `event: agent_stop` — per agent with exit code
- `orchestration_event` with `event: pipeline_abort` — if pipeline fails
- `orchestration_event` with `event: session_stop` — overall exit code

Use `carranca log` and `carranca status` as normal — they detect
orchestrated sessions and show the per-agent breakdown.

## Examples

### Code generation + review pipeline

```yaml
agents:
  - name: coder
    adapter: codex
    command: "codex --quiet --approval-mode full-auto"
  - name: reviewer
    adapter: claude
    command: "claude --dangerously-skip-permissions -p 'review the changes in /workspace and report issues'"

orchestration:
  mode: pipeline
  workspace: isolated
  merge: carry
```

The coder writes code, then the reviewer sees the changes and reviews
them. If the coder fails, the reviewer never starts.

### Parallel linting + testing

```yaml
agents:
  - name: linter
    adapter: stdin
    command: "npm run lint"
  - name: tester
    adapter: stdin
    command: "npm test"

orchestration:
  mode: parallel
  workspace: isolated
```

Both agents run concurrently on independent workspace copies. Neither
can interfere with the other's results.
