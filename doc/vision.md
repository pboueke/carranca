# Vision

Carranca protects engineers from coding agents by running them in isolated containers with structured session logging.

## Today

Carranca provides transparency and isolation for coding agents:

- **Audit trail**: Structured session logs capture every command and file mutation
- **Host protection**: Container isolation prevents accidental or harmful filesystem operations
- **Reproducibility**: Cache volumes persist agent state across runs

## Tomorrow

As features mature, Carranca evolves into a full agent runtime platform for organizations that treat AI coding assistants as production systems:

| Phase | Capability | Benefit |
|-------|------------|---------|
| Verified audit | HMAC-signed event chains, append-only logs | Cryptographically tamper-proof logs for compliance and forensics |
| Deep observability | eBPF/strace execve tracing, network connection logging | See what the agent *actually* runs, not just what it reports |
| Policy enforcement | Fine-grained network allowlists, filesystem ACLs, resource limits | Technical controls the agent cannot bypass |
| Adversarial hardening | Independent event verification, capability dropping, seccomp profiles | Protection against deliberately malicious agents |
| Ecosystem | Central log aggregation, CI/CD integration, session diffing | Team-scale operations and reproducible pipelines |

## Who Benefits

Organizations with security, compliance, or governance requirements will benefit most from the full vision:

- **Security & compliance teams**: Need tamper-proof audit trails for AI-assisted development
- **DevOps / platform engineers**: Run agents in CI/CD with resource limits and policy enforcement
- **Engineering managers**: Review agent sessions and enforce team workflows
- **Regulated industries**: Legal and compliance need signed logs as evidence
- **Security-conscious organizations**: Prevent exfiltration of internal code and IP

See [roadmap.md](roadmap.md) for the complete phased plan.
