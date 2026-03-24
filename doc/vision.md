# Vision

Carranca is a containerized agent runtime for teams that want isolated
execution, reviewable sessions, and technical controls around AI-assisted code
changes.

## Current position

Phases 1 through 4 are now implemented. Carranca already provides:

- **Verified audit evidence**: HMAC-signed session logs, checksum hardening,
  exportable archives, and provenance-tagged events
- **Deep observability**: shell-command capture, file mutation events, execve
  tracing, network connection logging, resource sampling, and secret-read
  monitoring
- **Technical policy enforcement**: network filtering, resource limits,
  time-boxed sessions, read-only overlays for watched paths, and pre-commit
  policy hooks
- **Operational isolation**: dedicated agent/logger containers, fail-closed
  session shutdown, and per-project agent images and configuration

This means Carranca is already beyond a transparency-only wrapper. The current
product is a local runtime for engineers who need auditability and enforceable
guardrails around coding agents.

## Next phases

The remaining roadmap is about hardening and scale rather than basic
capability:

| Phase | Focus | Outcome |
|-------|-------|---------|
| Phase 5 | Adversarial hardening | Reduce trust in the agent by moving more ground truth outside the agent's control |
| Phase 6 | Ecosystem and integration | Support team workflows such as CI execution, central log collection, and richer comparisons |

## Who benefits

Carranca is most useful for organizations that need agent sessions to be both
productive and reviewable:

- **Security and compliance teams**: need tamper-evident audit records for AI-assisted development
- **Platform engineers**: want containerized execution with explicit resource, network, and filesystem controls
- **Engineering managers**: need reviewable sessions and technical enforcement for team workflows
- **Regulated industries**: need signed logs and traceable operator behavior
- **Security-conscious engineering teams**: want to reduce the blast radius of local coding agents

See [roadmap.md](roadmap.md) for the remaining phases.
