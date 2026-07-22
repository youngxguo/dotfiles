# AGENTS.md

## Git

- Leave changes uncommitted unless the user explicitly asks to commit, and do not push without separate approval.
- Before committing, review `git status`, run relevant checks, and keep the commit focused.
- Keep repo hooks enabled with `git config core.hooksPath .githooks`.
- Prefer a feature branch for larger changes; direct pushes to `main` are fine when the repository allows them.

## Agent Skills

- Keep each skill in `skills/<skill-name>` with aligned `agents/openai.yaml` metadata.
- Validate changed skills with the skill creator's `quick_validate.py` and `npx skills add . --list`.
