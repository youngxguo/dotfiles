---
name: kickoff
description: "Create a new Herdr worktree, start an agent there, give it the user's task, and return. Use when asked to kick off, spin up, delegate, farm out, or put an agent on work in parallel."
allowed-tools: Bash(python3 ${CLAUDE_SKILL_DIR}/kickoff.py *)
---

# Kickoff

Run `kickoff.py` as the first tool call:

```bash
python3 ${CLAUDE_SKILL_DIR}/kickoff.py --model fable signup-rate-limit "the user's task"
```

The slug names the new branch, workspace, and agent. Use `--brief-file` for a
long task. Use `--repo <name>` when the work belongs to another open repository.

Always pass `--model`. Use `fable` unless the user explicitly requests another
model. When the user names a Claude account, pass `--to` instead of leaving the
selection only in the brief:

```bash
python3 ${CLAUDE_SKILL_DIR}/kickoff.py --to c3 --model opus comment-cleanup "the user's task"
```

Pass the user's task close to verbatim. Add only earlier conversation context
that it depends on. Do not inspect the codebase or plan the work first.

The script creates a new worktree from the repository's main checkout, chooses
or honors the requested Claude account, starts the requested model, sends the
task, and returns. It pins Fable when `--model` is omitted so the account's
configured default cannot change the model. With no requested account, it uses
the eligible subscription whose overall weekly quota resets soonest. Model
eligibility is applied before ranking, so a default Fable kickoff skips accounts
without Fable headroom.
When it prints the final line, report that line and stop. Do not inspect the
agent in the same turn.
