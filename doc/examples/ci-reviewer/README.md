# CI Reviewer

## Usage case

This setup fits a team that wants automated AI-powered code review on pull
requests, running inside a CI pipeline (GitHub Actions, GitLab CI, etc.)
with the same sandbox guarantees as local carranca sessions.

The agent receives a PR diff, produces a structured review, and the CI
workflow posts it back as a PR comment. Only the AI provider API key enters
the container; the CI platform token stays on the runner.

Carranca's own PR review workflow (``.github/workflows/pr-review.yml``)
uses this pattern in production.

## Why Carranca is useful

CI-triggered agent tasks run unattended, making sandbox isolation and
session evidence especially important. Carranca adds:

- **Bounded execution**: ``--timeout`` and ``policy.max_duration`` prevent
  runaway sessions from blocking pipelines or burning API credits
- **Secret surface control**: ``environment.passthrough`` passes only the
  named API key into the container; other CI secrets (deploy keys, tokens)
  never enter the agent's namespace
- **Auditable sessions**: the session log captures what the agent ran,
  touched, and produced, even in headless mode
- **Reproducible reviews**: the same container image, policy, and prompt
  produce consistent behavior across runs
