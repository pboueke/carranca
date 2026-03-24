# Persona Examples

These examples move the persona-specific Carranca setups out of the main
configuration reference and into standalone directories you can inspect or copy
from.

Each persona directory includes:

- `.carranca.yml`
- `.carranca/Containerfile`
- `README.md` with the operating context, likely workflow, and why Carranca is
  useful for that persona

Available examples:

- [platform-engineer/](platform-engineer/): harden deployment and infrastructure
  repos with network allow-lists, watched paths, and enforceable workflow
  checks
- [security-engineer/](security-engineer/): review sensitive repositories with
  aggressive observability and an independent observer sidecar
- [regulated-team-lead/](regulated-team-lead/): keep AI-assisted changes
  attributable and bounded before they enter a controlled delivery process
- [consultant-client-code/](consultant-client-code/): work inside a client repo
  locally without granting a hosted sandbox broad access to that codebase
- [open-source-maintainer/](open-source-maintainer/): review external patches
  and constrain what an agent can touch in community-maintained repos
- [forensic-analyst/](forensic-analyst/): replay prior sessions and inspect
  exported evidence with networking disabled
