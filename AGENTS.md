# AGENTS.md

## Workflow

- Make changes on a focused branch and open a pull request into `master`.
- Do not push changes directly to `master`.
- Treat GitHub CI as the required validation; local checks are optional for faster feedback.

## Agent Skills

- Keep each skill in `skills/<skill-name>` with aligned `agents/openai.yaml` metadata.
- Let GitHub CI validate skill metadata and Skills CLI discovery.
