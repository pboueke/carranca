# Session Log Format

## Overview

Each carranca session produces a single JSONL file at:
```
~/.local/state/carranca/sessions/<repo-id>/<session-id>.jsonl
```

One JSON object per line. Events are ordered by `seq` (monotonic integer).

## Event types

### `session_event`

Session lifecycle events produced by carranca itself.

```json
{"type":"session_event","source":"carranca","event":"start","ts":"2026-03-22T09:45:00Z","session_id":"abc12345","repo_id":"a1b2c3d4e5f6","repo_name":"my-app","repo_path":"/home/user/my-app","adapter":"default","seq":1}
{"type":"session_event","source":"carranca","event":"degraded","ts":"2026-03-22T09:45:00Z","session_id":"abc12345","reason":"append_only_unavailable","seq":2}
{"type":"session_event","event":"agent_start","ts":"2026-03-22T09:45:02Z","session_id":"abc12345","seq":3}
{"type":"session_event","event":"agent_stop","ts":"2026-03-22T09:57:34Z","session_id":"abc12345","exit_code":0,"seq":10}
{"type":"session_event","source":"carranca","event":"logger_stop","ts":"2026-03-22T09:57:35Z","session_id":"abc12345","seq":11}
```

Events: `start`, `degraded`, `agent_start`, `agent_stop`, `logger_stop`

### `shell_command`

Commands executed through the shell wrapper.

```json
{"type":"shell_command","source":"shell-wrapper","ts":"2026-03-22T09:45:02Z","session_id":"abc12345","command":"npm test","exit_code":0,"duration_ms":3420,"cwd":"/workspace/src","seq":4}
```

**Limitation:** Only captures commands that flow through the shell wrapper.
Agent-native operations (file writes, edits via tool APIs) bypass the wrapper.

### `file_event`

File mutations detected by `inotifywait` (Linux only, best-effort).

```json
{"type":"file_event","source":"inotifywait","ts":"2026-03-22T09:45:03Z","event":"MODIFY","path":"/workspace/src/index.ts","session_id":"abc12345","seq":5}
{"type":"file_event","source":"inotifywait","ts":"2026-03-22T09:45:03Z","event":"CREATE","path":"/workspace/.env","session_id":"abc12345","seq":6}
```

Events: `CREATE`, `MODIFY`, `DELETE`

**Limitation:** No attribution — `inotifywait` sees the event but cannot
identify which process caused it. Reads are not captured.

### `heartbeat`

Periodic liveness check from the shell wrapper (every 30s).

```json
{"type":"heartbeat","ts":"2026-03-22T09:45:32Z","session_id":"abc12345","seq":7}
```

### `invalid_event`

Malformed data received on the FIFO.

```json
{"type":"invalid_event","source":"fifo","ts":"2026-03-22T09:45:05Z","session_id":"abc12345","raw":"not valid json","seq":8}
```

## Schema fields

| Field | Type | Description |
|-------|------|-------------|
| `seq` | int | Monotonic sequence number — enables ordering and gap detection |
| `ts` | string | ISO 8601 UTC timestamp |
| `type` | string | Event type (see above) |
| `source` | string | Component that produced the event |
| `session_id` | string | 8-char hex session identifier |
| `repo_id` | string | 12-char hex repo identifier |

## Querying

```bash
# All shell commands
jq 'select(.type=="shell_command")' session.jsonl

# Failed commands
jq 'select(.type=="shell_command" and .exit_code != 0)' session.jsonl

# File mutations
jq 'select(.type=="file_event")' session.jsonl

# Session timeline
jq '{seq, type, event, command, path}' session.jsonl

# Count commands
jq -s '[.[] | select(.type=="shell_command")] | length' session.jsonl
```

## `carranca log`

`carranca log` reads one session JSONL file and prints a compact summary for
developers:

- session and repo identifiers
- start/end timestamps
- unique paths touched
- file-event totals split by create, modify, and delete
- top touched paths ranked by event count
- command totals, failures, and ordered command list

Examples:

```bash
# Latest session for the current repo
carranca log

# Exact session id for the current repo
carranca log --session abc12345
```

Important nuance: file counts shown by `carranca log` distinguish between
`Unique paths touched` and raw `File events`. Repeated writes to the same path
increase the event count without increasing the unique-path count.

If a session shows file activity but `Commands run: 0`, that usually means the
agent changed files through native tool APIs or edits that bypassed shell-wrapper
command capture.
