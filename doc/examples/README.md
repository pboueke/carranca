# Persona Examples

These examples move the persona-specific Carranca setups out of the main
configuration reference and into standalone directories you can inspect or copy
from.

Each persona directory includes:

- `.carranca.yml`
- `.carranca/Containerfile`
- `README.md` with the operating context, likely workflow, and why Carranca is
  useful for that persona

The examples also demonstrate different `environment` mechanisms for passing
variables into agent containers:

| Mechanism | Used by |
|-----------|---------|
| `passthrough` (forward host env vars) | platform-engineer, open-source-maintainer |
| `env_file` (load from a dotfile) | consultant-client-code, regulated-team-lead |
| `vars` (define inline in config) | security-engineer, forensic-analyst, regulated-team-lead |

Available examples:

- [platform-engineer/](platform-engineer/): harden deployment and infrastructure
  repos with network allow-lists, watched paths, and enforceable workflow
  checks (`passthrough` for CI tokens)
- [security-engineer/](security-engineer/): review sensitive repositories with
  aggressive observability and an independent observer sidecar (`vars` for
  investigation parameters)
- [regulated-team-lead/](regulated-team-lead/): keep AI-assisted changes
  attributable and bounded before they enter a controlled delivery process
  (`env_file` + `vars` for compliance settings)
- [consultant-client-code/](consultant-client-code/): work inside a client repo
  locally without granting a hosted sandbox broad access to that codebase
  (`env_file` for client-specific credentials)
- [open-source-maintainer/](open-source-maintainer/): review external patches
  and constrain what an agent can touch in community-maintained repos
  (`passthrough` for GitHub API access)
- [forensic-analyst/](forensic-analyst/): replay prior sessions and inspect
  exported evidence with networking disabled (`vars` for case metadata)
