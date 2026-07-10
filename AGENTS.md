# AGENTS.md

## Git Hygiene

- Do not commit or push changes automatically. Leave changes uncommitted so the user can review them, then wait for explicit approval before committing or pushing; approval to make a change is not approval to commit it.
- Keep commits small and focused. One logical change per commit.
- Write clear commit messages that explain what changed and why.
- After the user approves committing, commit at meaningful checkpoints so progress is easy to review and recover.
- Push only after the user explicitly approves pushing.
- Keep repo hooks enabled (`git config core.hooksPath .githooks`) so pre-push checks run.
- Pull/rebase before pushing if the remote branch has moved.
- Run relevant checks/tests before committing when possible.
- Do not commit secrets, local env files, or machine-specific generated files.
- Review `git status` before every commit to avoid accidental file adds.
- Prefer feature branches for larger changes instead of committing directly to shared branches.
- Do not require PRs by default. Direct pushes to `main` are acceptable in personal or shared automation repos when that repo's policy allows it, such as `~/claude-code-shared`.
- Avoid force-pushing shared branches unless everyone involved agrees.

## Suggested Workflow

1. Create or switch to a branch for the task.
2. Make a small, testable change.
3. Leave the changes uncommitted so the user can review `git diff` and `git status`.
4. Wait for explicit approval to commit, then commit with a descriptive message.
5. Wait for explicit approval to push, then push the branch to remote (let `pre-push` checks run).
6. Repeat in small increments.
