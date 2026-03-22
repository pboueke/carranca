# Versioning

## Single source of truth

The current version is the first `## [X.Y.Z]` header in `CHANGELOG.md`.
All tooling derives from this. There is no `VERSION` file, no `package.json`,
no other version declaration.

```bash
# Read current version
make version

# Programmatically
grep -m1 '## \[' CHANGELOG.md | sed 's/.*\[\(.*\)\].*/\1/'
```

## Semantic versioning

Carranca follows [semver](https://semver.org/):

- **MAJOR** (X.0.0): Breaking changes to CLI interface, config format, or session log schema
- **MINOR** (0.X.0): New features, new config fields, new event types
- **PATCH** (0.0.X): Bug fixes, documentation, internal improvements

## Changelog format

Each entry uses conventional commit prefixes:

```markdown
## [X.Y.Z] - YYYY-MM-DD

- feat: description of new feature
- fix: description of bug fix
- chore: description of maintenance task
- test: description of test change
```

Prefixes: `feat:`, `fix:`, `chore:`, `test:`, `docs:`, `refactor:`

## Bumping version

1. Add a new `## [X.Y.Z] - YYYY-MM-DD` header at the top of CHANGELOG.md
2. List changes under it with conventional prefixes
3. Commit

The pre-commit hook validates that the first version header is valid semver.
