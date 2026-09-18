---
name: kickoff
description: "Create a new Herdr worktree, start an agent there, give it the user's task, and return. Use when asked to kick off, spin up, delegate, farm out, or put an agent on work in parallel."
allowed-tools: Bash(python3 ${CLAUDE_SKILL_DIR}/kickoff.py *)
---

# Kickoff

Run `kickoff.py` as the first tool call:

```bash
python3 ${CLAUDE_SKILL_DIR}/kickoff.py --model fable --size M signup-rate-limit "the user's task"
```

The slug names the new branch, workspace, and agent. Use `--brief-file` for a
long task. Use `--repo <name>` when the work belongs to another open repository.

Always pass `--model` and `--size`. Use `fable` and `M` unless the user
explicitly requests another model or task size. When the user names a Claude
account, pass `--to` instead of leaving the selection only in the brief:

```bash
python3 ${CLAUDE_SKILL_DIR}/kickoff.py --to c3 --model opus --size S comment-cleanup "the user's task"
```

Pass the user's task close to verbatim. Add only earlier conversation context
that it depends on. Do not inspect the codebase or plan the work first.

The script checks `cseat` before changing the repository, creates a new
worktree from the repository's main checkout, and launches Claude with cseat's
native seat picker and automatic handoffs. It passes the same task size to the
preflight and launched session, pins Fable when `--model` is omitted, honors
`--to` by translating short aliases such as `c3` to cseat's `claude3` seat,
sends the task, and returns. On a machine without cseat it falls back to a
directly launched, explicitly pinned Claude session.

When it prints the final line, report that line and stop. Do not inspect the
agent in the same turn.
