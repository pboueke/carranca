# Objective

Carranca is a local agent runtime for engineers and teams that want coding
agents to run inside operator-controlled containers with reviewable evidence and
enforceable guardrails.

Its objective is not just to make agent sessions visible after the fact. It is
to make them easier to constrain, inspect, and reason about while they run:

- with isolated agent execution through Podman or Docker
- with tamper-evident session logs and signed exports
- with policy controls for network, filesystem, runtime duration, and resource usage
- with optional independent observation outside the agent's namespaces

## Current position

Carranca already provides:

- **Verified audit evidence**: HMAC-signed session logs, checksum hardening,
  exportable archives, and provenance-tagged events
- **Deep observability**: shell-command capture, file mutation events, execve
  tracing, network connection logging, resource sampling, and secret-read
  monitoring
- **Technical policy enforcement**: network filtering, resource limits,
  time-boxed sessions, read-only overlays for watched paths, and pre-commit
  policy hooks
- **Adversarial hardening**: all capabilities dropped, read-only root
  filesystem, seccomp filtering, FIFO forgery detection, and an independent
  observer sidecar for cross-referencing agent-reported events against
  kernel-observed activity
- **Operational isolation**: dedicated agent/logger/observer containers,
  fail-closed session shutdown, and per-project agent images and configuration

This means Carranca is beyond a transparency-only wrapper. The current product
is a local runtime for people who need coding agents to stay useful without
becoming opaque.

## Who Carranca is for

Carranca is a strong fit when the operator wants to keep control over the
runtime rather than outsource that control to a hosted sandbox provider.

- **Security and compliance teams**: need tamper-evident audit records and a
  tighter execution boundary around AI-assisted development
- **Platform and developer-experience engineers**: want explicit resource,
  network, filesystem, and image controls around local agent workflows
- **Engineering managers and tech leads**: need sessions to be reviewable,
  reproducible, and bounded by technical policy
- **Regulated or client-sensitive teams**: need signed logs, bounded runtime
  behavior, and traceable operator activity
- **Security-conscious individual engineers**: want local coding agents with a
  smaller blast radius than a normal unrestricted shell session

## Who Carranca is not for

Carranca is not the best fit when the main problem is something other than
local, auditable, policy-aware agent execution.

- Teams that want a fully managed cloud execution platform instead of operating
  agent containers on their own machines or infrastructure
- Users who need strong non-Linux parity today; macOS and Windows support
  remain experimental, especially for file-event coverage
- Teams looking for a generic browser, desktop, or VM sandbox rather than a
  code-in-repository runtime
- Workflows that need formal remote attestation, centralized control planes, or
  fleet orchestration out of the box; those sit in Carranca's future ecosystem
  layer rather than the current runtime core
- Users who mainly want faster remote compute or disposable preview
  environments and do not care much about local auditability or guardrails

## Comparison with other agent sandboxes

Carranca fits a different operating model from most cloud-first agent
sandboxes.

- **Carranca vs hosted code sandboxes**: products such as E2B, Daytona, and
  Modal Sandboxes emphasize disposable remote environments, API-driven
  provisioning, and hosted execution. Carranca instead centers on
  operator-controlled local or self-hosted container execution with persistent
  repo context, signed local evidence, and repo-specific policy controls.
- **Carranca vs simple container wrappers around an agent CLI**: Carranca adds
  a separate logger, optional observer sidecar, fail-closed logging, HMAC-based
  tamper detection, and policy enforcement rather than only "run the agent in a
  container."
- **Carranca vs general-purpose VM or browser isolation**: Carranca is narrower
  and more opinionated. It is optimized for coding agents working inside a real
  repository, not for broad desktop isolation or remote browsing tasks.

The tradeoff is deliberate: Carranca gives up some convenience and cloud-scale
abstractions in exchange for stronger operator control over a local coding
workflow.

## Personas That See Value

- **A platform engineer** hardens agent access to production deployment repos
  with network allow-lists, read-only secret paths, and session duration caps
- **A security engineer** reviews signed session logs and cross-references them
  against observer events during an incident or policy exception review
- **A regulated-team lead** needs AI-assisted changes to remain attributable and
  reviewable before code enters a controlled delivery process
- **A consultant working on client code** wants local agent assistance without
  giving a third-party hosted sandbox direct access to the client repository
- **An open-source maintainer** wants external agent-generated patches to be
  reviewable with more context than a bare git diff
- **A forensic analyst or incident responder** replays prior sessions from log
  exports to understand what an agent ran, touched, or attempted to access

## What remains ahead

The remaining roadmap is about ecosystem and integration work rather than core
runtime capabilities. See [roadmap.md](roadmap.md) for planned future work.
