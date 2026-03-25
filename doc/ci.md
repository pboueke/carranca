# CI/CD Integration

Carranca runs headless in CI pipelines without special flags. This guide
covers the patterns for using it in automated environments.

## Headless execution

`carranca run` auto-detects non-TTY environments and adjusts container
flags accordingly (omits `-t`). No `--non-interactive` flag is needed.

For CI use, configure the agent with the `stdin` adapter or pass the
prompt as part of the command:

```yaml
agents:
  - name: codex
    adapter: codex
    command: "codex --quiet --approval-mode full-auto"
```

The agent receives its command from `.carranca.yml` and runs to
completion. When stdin is not a TTY, agents that support non-interactive
mode (like codex with `--quiet`) work without modification.

## Timeout

Use `--timeout <seconds>` to enforce a wall-clock budget:

```bash
carranca run --agent codex --timeout 600
```

When both `--timeout` and `policy.max_duration` in `.carranca.yml` are
set, the minimum wins. This lets the project config set a ceiling while
the CI job sets a tighter per-run limit.

## Exit codes

Pipeline branching should use these exit codes:

| Code | Meaning |
|------|---------|
| 0 | Agent succeeded, no policy violations |
| 1–125 | Agent exit code (pass-through) |
| 71 | Logger lost — audit trail interrupted (EX_OSERR) |
| 124 | Session timed out (max_duration exceeded) |

Exit code 71 means the audit trail was interrupted. The agent may have
succeeded, but the session is not verifiable. Treat this as a failure
in compliance-sensitive pipelines.

Exit code 124 matches the `timeout(1)` convention. The session was
killed after the configured duration.

## Session logs as CI artifacts

After `carranca run`, export the session log as a signed archive:

```bash
# Parse repo ID from carranca status (first line: "Repo: <name> (<id>)")
REPO_ID=$(carranca status 2>/dev/null | head -1 | grep -oE '[a-f0-9]{12}')

# Find the latest session log by modification time
SESSION_ID=$(basename "$(ls -t ~/.local/state/carranca/sessions/"$REPO_ID"/*.jsonl 2>/dev/null | head -1)" .jsonl)

# Export as .tar + .tar.sig
carranca log --export --session "$SESSION_ID"
```

The export produces two files next to the session log:
- `<session-id>.tar` — contains the JSONL log, HMAC key, and checksums
- `<session-id>.tar.sig` — HMAC-SHA256 signature of the archive

## Session ID discovery

The session ID is a 16-character hex string generated at session start.
To discover it after a run, parse the repo ID from `carranca status` and
list session logs by modification time:

```bash
REPO_ID=$(carranca status 2>/dev/null | head -1 | grep -oE '[a-f0-9]{12}')
ls -t ~/.local/state/carranca/sessions/"$REPO_ID"/*.jsonl | head -1

# Or inspect recent sessions interactively
carranca status
```

## Example: GitHub Actions workflow

```yaml
name: Agent task
on: [workflow_dispatch]

jobs:
  agent-run:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install carranca
        run: |
          git clone https://github.com/pboueke/carranca ~/.local/share/carranca
          ln -s ~/.local/share/carranca/cli/carranca ~/.local/bin/carranca

      - name: Run agent
        run: carranca run --agent codex --timeout 600

      - name: Export session log
        if: always()
        run: |
          REPO_ID=$(carranca status 2>/dev/null | head -1 | grep -oE '[a-f0-9]{12}' || true)
          SESSION=$(basename "$(ls -t ~/.local/state/carranca/sessions/"$REPO_ID"/*.jsonl 2>/dev/null | head -1)" .jsonl || true)
          if [ -n "$SESSION" ]; then
            carranca log --export --session "$SESSION"
          fi

      - name: Upload session archive
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: carranca-session
          path: ~/.local/state/carranca/sessions/**/*.tar*
          if-no-files-found: ignore
```

## Recommended policy for CI

For unattended runs, set explicit limits in `.carranca.yml`:

```yaml
policy:
  max_duration: 1800        # 30 minute ceiling
  resource_limits:
    memory: 4g
    cpus: "2.0"
    pids: 256
  docs_before_code: warn    # or enforce
  tests_before_impl: warn   # or enforce

runtime:
  network:
    default: deny
    allow:
      - "registry.npmjs.org:443"
      - "*.anthropic.com:443"
```

This ensures the agent cannot run indefinitely, consume unbounded
resources, or make unexpected network connections.

## Verification

To verify a session log after a CI run (e.g., in a follow-up audit
step):

```bash
carranca log --verify --session "$SESSION_ID"
```

This replays the HMAC chain and checksums, reporting any tampering.
