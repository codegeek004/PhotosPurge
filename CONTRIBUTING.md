# Contributing to PhotoPurge

Thanks for your interest in contributing. This document covers how to set up your environment, the conventions we follow, and how to get a change merged.

## Table of contents

- [Getting started](#getting-started)
- [Project structure](#project-structure)
- [Development workflow](#development-workflow)
- [Code style](#code-style)
- [Testing](#testing)
- [Database migrations](#database-migrations)
- [Commit messages](#commit-messages)
- [Pull requests](#pull-requests)
- [Reporting issues](#reporting-issues)
- [Security issues](#security-issues)

## Getting started

### Prerequisites

- Python 3.11+
- [uv](https://docs.astral.sh/uv/) for dependency management
- Docker and Docker Compose
- Git

### Local setup

```bash
git clone https://github.com/<org>/photopurge.git
cd photopurge

# Copy env template and fill in values
cp .env.example .env

# Install dependencies (includes dev tooling)
uv sync --group dev

# Start backing services
docker compose up -d db redis

# Run migrations
uv run manage.py migrate

# Run the dev server
uv run manage.py runserver
```

In a separate terminal, start Celery workers for local testing:

```bash
uv run celery -A config worker -Q photos -l info
uv run celery -A config worker -Q drive -l info
uv run celery -A config worker -Q gmail -l info
```

Never commit your `.env` file. If you add a new required environment variable, add it to `.env.example` with a placeholder value and a one-line comment explaining what it's for.

## Project structure

```
config/          # settings, URL root, Celery app definition, WSGI/ASGI
core/            # shared utilities (JWT verification, Google token refresh, common exceptions)
photos/          # photo migration domain app
drive/           # drive migration domain app
gmailapp/        # gmail cleanup/recovery domain app
```

Each domain app owns its own models, tasks, views, and tests. Shared logic that more than one domain app needs belongs in `core/`, not copy-pasted between apps.

## Branch protection rules

- **Never push directly to `main`.** All changes, no matter how small, go through a pull request from a feature/fix/chore branch into `main` (or into a `develop`/`review` integration branch if the project uses one — check the repo's default branch settings before pushing).
- `main` should always be deployable. If a change isn't ready, keep it on its branch.
- Push your work to your own branch and open a PR for review — even for docs typos or config tweaks. This keeps history clean and gives CI a chance to run before anything lands on `main`.
- If you're unsure whether a change is "too small" to need a PR, it isn't — open the PR.

## Database changes require discussion first

- **Never change the database schema (models, migrations, field types, indexes, constraints) without discussing it first** — open an issue or raise it in the PR description *before* writing the migration, not after.
- This includes seemingly small changes: renaming a field, changing a field's type, adding a `unique` constraint, or altering `null`/`blank` behavior can all break existing data or running migrations for other contributors.
- Get explicit sign-off from a maintainer before merging any PR that includes a new or modified migration.
- This project already has one history of unreviewed, repeated schema tweaks (see the squashed `gmailapp` migrations) — the goal going forward is to avoid recreating that by treating every schema change as a deliberate, discussed decision rather than an incidental one.

## Development workflow

1. Check the [Issues](../../issues) board and the linked Project for open, unassigned tickets. Each ticket is tagged with a `phase-N` label matching the project's phased roadmap.
2. Comment on the issue to claim it before starting work, to avoid duplicate effort.
3. Create a branch off `main`:
   ```bash
   git checkout -b phase-2/jwt-verification-middleware
   ```
   Use a short, descriptive branch name prefixed with the relevant phase if applicable.
4. Make your changes in small, focused commits, following the [branch naming](#branch-naming) and [commit type](#commit-types) conventions below.
5. Run linting and tests locally before opening a PR (see below).
6. Open a pull request against `main`.

### Branch naming

Branches follow the pattern `type/short-description`, and `phase-N/type/short-description` when the work maps to a specific phase in the roadmap.

| Type | Used for |
|---|---|
| `feature/` | New functionality (a new endpoint, a new task, a new UI flow) |
| `fix/` | Bug fixes |
| `chore/` | Repo hygiene, dependency bumps, config changes — no behavior change |
| `refactor/` | Restructuring existing code with no functional change (e.g., consolidating duplicated auth logic) |
| `docs/` | Documentation-only changes |
| `test/` | Adding or fixing tests only, no production code change |
| `perf/` | Performance improvements (e.g., queue redesign, rate limiting, batching) |
| `security/` | Security fixes or hardening |

Examples:
```
phase-2/feature/jwt-verification-middleware
phase-3/perf/split-celery-queues
fix/drive-folder-map-duplicate-key
chore/remove-staticfiles-from-git
docs/update-readme-uv-setup
```

Keep the description short (3–5 words), lowercase, hyphen-separated.

### Commit types

Commit messages should start with one of the following type prefixes, similar to [Conventional Commits](https://www.conventionalcommits.org/):

| Type | Meaning |
|---|---|
| `feat:` | A new feature or capability |
| `fix:` | A bug fix |
| `chore:` | Maintenance work — dependency updates, config, tooling, cleanup |
| `refactor:` | Code change that neither fixes a bug nor adds a feature (restructuring, renaming, consolidating) |
| `docs:` | Documentation changes only |
| `test:` | Adding or correcting tests, no production code change |
| `perf:` | A change that improves performance |
| `security:` | A change that fixes or hardens a security issue |
| `ci:` | Changes to CI/CD configuration (GitHub Actions, etc.) |
| `build:` | Changes to build tooling, Docker, or dependency management (uv, pyproject.toml) |

Examples:
```
feat: add JWT verification middleware for SSO integration
fix: prevent duplicate uploads on retried photo migration chunks
perf: replace hardcoded sleep with Redis token-bucket rate limiter
refactor: consolidate gmailapp and photos auth logic into core module
chore: squash gmailapp migration history
docs: document required env vars in README
test: add regression test for drive folder_map collision
security: rotate JWT signing key and add key ID to token header
```

Use the imperative mood ("add", not "added" or "adds") and keep the summary line under ~72 characters. Add a longer explanation in the commit body if the change needs more context than the summary line allows.

## Code style

- Formatting and linting are handled by [ruff](https://docs.astral.sh/ruff/). Run before committing:
  ```bash
  uv run ruff check .
  uv run ruff format .
  ```
- Follow Django's own coding style conventions for models, views, and templates.
- No secrets, credentials, or environment-specific values hardcoded anywhere in source — use `settings/base.py` + environment variables.
- Keep domain logic inside its owning app. If you find yourself duplicating logic across `photos`, `drive`, or `gmailapp`, that logic likely belongs in `core/` instead.
- Celery tasks must be idempotent — assume any task can and will be retried. Do not write a task that produces duplicate side effects (e.g., duplicate uploads) if it runs twice.

Consider setting up `pre-commit` locally so these checks run automatically before each commit:

```bash
uv run pre-commit install
```

## Testing

```bash
uv run pytest
```

- New features require accompanying tests. Bug fixes should include a regression test where practical.
- Tests that touch Celery tasks should test task logic directly (not just via `.delay()`), and should not depend on real Google API calls — mock external HTTP calls.
- If you're changing anything in the token refresh, rate-limiting, or job state machine logic, add tests covering the failure paths, not just the happy path — this project deals with irreversible operations (file deletion, email trashing) and failure handling matters as much as success handling.

## Database migrations

- Run `uv run manage.py makemigrations` after any model change, and commit the generated migration file with your PR.
- Avoid multiple migrations that repeatedly alter the same field within a single PR — squash them into one clean migration before submitting (`manage.py squashmigrations` if needed).
- Never edit a migration that has already been merged to `main`; add a new migration instead.

## Commit messages

Keep commits focused and messages descriptive. Prefer:

```
Add JWT verification middleware for SSO integration
```

over:

```
fix stuff
```

Reference the issue number where relevant, e.g. `Fixes #12` or `Refs #12`, so GitHub links the commit to the ticket automatically.

## Pull requests

- **Never push directly to `main`.** All changes, no matter how small, go through a feature branch and a pull request — this includes docs typos and config tweaks. `main` should always reflect a reviewed, working state.
- Push your branch to the remote and open a PR for review rather than merging locally:
  ```bash
  git push origin phase-2/feature/jwt-verification-middleware
  ```
  Then open the pull request on GitHub against `main`.
- Keep PRs scoped to a single issue/ticket where possible — small, reviewable PRs merge faster than large ones.
- Fill in the PR description: what changed, why, and how it was tested.
- Link the related issue(s).
- Ensure CI (lint + tests) passes before requesting review.
- Be responsive to review feedback — if a requested change doesn't make sense to you, ask rather than silently disagreeing or silently complying.

## Reporting issues

- Search existing issues before opening a new one, to avoid duplicates.
- Include reproduction steps, expected vs actual behavior, and relevant logs/tracebacks.
- Tag the issue with the appropriate `phase-N` label if it relates to a specific part of the roadmap, or `bug` if it's an unplanned defect.

## Security issues

Please do **not** open a public issue for security vulnerabilities (e.g., anything involving token handling, auth bypass, or exposure of user Google account data). Instead, report it privately to the maintainer directly. Given this project handles OAuth tokens for real Google accounts, please give us reasonable time to address the issue before any public disclosure.

---

Thanks again for contributing — whether it's a typo fix, a bug report, or a full feature, it's appreciated.
