# Contributing to Carranca

Thanks for contributing.

Carranca is a Bash-based CLI for running coding agents inside container
runtimes with structured session logging. This guide covers how to propose
changes, run the project locally, and keep contributions aligned with the
current scope of the tool.

## Before you start

- Read the README and the docs under `doc/` first.
- Check existing issues or open one before starting larger changes.
- Keep the trust model honest. Carranca is a transparency tool with isolation
  and logging, not a complete security boundary against adversarial agents.
- Prefer focused pull requests. Small, reviewable changes move faster.

## What we accept

Contributions are welcome for:

- bug fixes
- docs improvements
- tests
- runtime compatibility work for supported container engines
- new CLI behavior that fits the current product direction
- internal refactors that simplify the Bash code without changing behavior

If you want to add a larger feature or change the trust model, open an issue
first so the design can be discussed before implementation.

## Development setup

Carranca is intentionally lightweight. You only need a shell environment plus a
supported container runtime for integration coverage.

Recommended local dependencies:

- `bash`
- `git`
- `shellcheck`
- `yamllint`
- `hadolint`
- either `podman` or `docker`

Install the CLI locally:

```bash
make install
```

That creates `~/.local/bin/carranca` pointing at this checkout.

## Project layout

```text
carranca/
├── cli/          # Main CLI entry point, commands, and shared Bash libraries
├── runtime/      # Logger image, shell wrapper, config runner
├── templates/    # Files scaffolded by carranca init
├── skills/       # Built-in Carranca skills shipped with the install
├── doc/          # User-facing documentation
└── tests/        # Unit, integration, and failure-mode coverage
```

## Workflow

1. Fork the repo and create a feature branch.
2. Make the smallest change that fully solves the problem.
3. Update tests and docs when behavior changes.
4. Run the relevant checks locally.
5. Open a pull request with a clear description of the change and why it is
   needed.

## Running checks

Fast local checks:

```bash
make lint
make test
make check
```

Full test run:

```bash
bash tests/run_tests.sh
```

Notes:

- `make test` runs unit tests only.
- `bash tests/run_tests.sh` auto-detects `podman` first, then `docker`, for
  integration and failure suites.
- `make test-all` currently delegates to `tests/run_tests.sh`, but its help text
  still says "requires Docker". In practice, either supported runtime works.
- `make build` and `make clean` are still Docker-specific helper targets.

If you only changed docs, say so in the PR. You do not need to invent code
changes or unrelated test edits.

## Coding conventions

- All project code is Bash.
- Use `set -euo pipefail` in scripts.
- Prefer small, composable `carranca_*` functions in shared libraries.
- Keep scripts portable and readable over clever shell tricks.
- Use 2-space indentation in shell and YAML files.
- Use tabs only where Make requires them.
- Keep comments brief and factual.

When touching runtime behavior:

- keep Podman and Docker support in mind
- avoid hard-coding Docker-only terminology unless a path is truly Docker-only
- preserve fail-closed behavior around session logging
- do not overstate what the logger or trust model can prove

## Tests and docs

Behavior changes should usually include:

- unit coverage for library helpers
- integration or failure coverage when CLI/runtime behavior changes
- README and `doc/` updates when user-visible behavior changes

Doc updates should describe what the code does today, including any current
limitations. Do not document TODOs as if they already shipped.

## Pull requests

A good pull request includes:

- the user-visible problem
- the chosen fix
- any behavior or compatibility tradeoffs
- the tests you ran
- doc updates, if applicable

If a change is intentionally incomplete or leaves follow-up work, call that out
explicitly in the PR description.

## Versioning

Versioning is driven by `doc/CHANGELOG.md`.
The first `## [X.Y.Z]` entry is the current version, and `make version` reads it
from there. If a contribution changes shipped behavior, update the changelog in
the same pull request.

## Reporting bugs and proposing features

When opening an issue, include:

- your OS
- whether you are using Podman or Docker
- the Carranca version or commit
- the command you ran
- the relevant `.carranca.yml` snippet if configuration matters
- the observed error or unexpected behavior

For feature requests, describe the problem first. Proposed solutions are useful,
but the motivating use case matters more.
