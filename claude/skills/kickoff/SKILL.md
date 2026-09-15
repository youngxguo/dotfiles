---
name: kickoff
description: "Create a new Herdr worktree, start an agent there, give it the user's task, and return. Use when asked to kick off, spin up, delegate, farm out, or put an agent on work in parallel."
allowed-tools: Bash(python3 ${CLAUDE_SKILL_DIR}/kickoff.py *)
---

# Kickoff

Run `kickoff.py` as the first tool call:

```bash
python3 ${CLAUDE_SKILL_DIR}/kickoff.py signup-rate-limit "the user's task"
```

The slug names the new branch, workspace, and agent. Use `--brief-file` for a
long task. Use `--repo <name>` when the work belongs to another open repository.

Pass the user's task close to verbatim. Add only earlier conversation context
that it depends on. Do not inspect the codebase or plan the work first.

The script creates a new worktree from the repository's main checkout, chooses
a Claude account with headroom, starts the agent, sends the task, and returns.
When it prints the final line, report that line and stop. Do not inspect the
agent in the same turn.
