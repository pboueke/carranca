# Security Engineer

## Usage case

This setup is aimed at a security engineer reviewing a sensitive repository or
investigating a questionable agent session. The agent works with local evidence
and case material, networking is disabled, and the independent observer sidecar
is enabled so process and network events can be cross-checked against what the
agent reports.

The image stays intentionally small because the task is evidence review and
policy verification, not broad dependency installation or open-ended
development.

## Why Carranca is useful

Carranca is useful here because the security engineer needs tamper-evident logs,
cross-source observability, and a bounded runtime they can explain during an
incident review or policy exception investigation.

That makes it easier to answer what the agent ran, what files it touched, and
whether the session stayed inside the allowed operating envelope.
