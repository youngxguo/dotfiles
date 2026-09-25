---
name: kickoff
description: "Briefly scope the user's task into a useful handoff, create a new Herdr worktree, start an agent there, and return. Use when asked to kick off, spin up, delegate, farm out, or put an agent on work in parallel."
allowed-tools: Read Glob Grep Write Bash(python3 ${CLAUDE_SKILL_DIR}/kickoff.py *)
---

# Kickoff

## Prepare the handoff

Do a brief scoping pass before launching. The originating session may have
stronger reasoning and richer context than the worker; use that advantage to
frame the right task, not to solve it before delegating.

Start from the user's request and existing conversation. Preserve their intent,
explicit constraints, and useful wording. Add only context the new session
needs to work independently:

- The goal and why it matters, if known.
- Scope boundaries and non-goals, especially where the request could balloon.
- Relevant prior decisions, known facts, and starting points (paths or symbols
  when already known or cheaply verified).
- Observable completion criteria and appropriate validation expectations.
- Important uncertainties or pitfalls; label hypotheses as hypotheses and
  leave investigation and implementation choices to the worker.

Scale this to the task: a clear, small request may need only a sentence or two;
most handoffs should be a few short paragraphs or bullets, not a design doc.
Don't invent requirements or fill every category mechanically. Ask a question
only if ambiguity would materially change the task and cannot safely be left
for the worker to resolve.

Prefer existing context. If one missing fact would materially improve the
handoff, make a few targeted, read-only searches or file reads. Don't conduct a
broad codebase tour, trace the full root cause, compare architectures in depth,
edit project files, or run tests. Stop once the worker can understand the goal,
where to start, and how to recognize success. If more research is needed to
choose a solution, make that part of the delegated task instead.

Pass the resulting brief to `kickoff.py`; don't merely describe it to the user
and then send the raw request. No approval round is needed unless clarification
is genuinely blocking.

## Launch

Run `kickoff.py` after preparing the brief:

```bash
python3 ${CLAUDE_SKILL_DIR}/kickoff.py --model fable --size M signup-rate-limit "the scoped task brief"
```

The slug names the new branch, workspace, and agent. Use `--brief-file` for a
long task. Use `--repo <name>` when the work belongs to another open repository.

Always pass `--model` and `--size`. Use `fable` and `M` unless the user
explicitly requests another model or task size. When the user names a Claude
account, pass `--to` instead of leaving the selection only in the brief:

```bash
python3 ${CLAUDE_SKILL_DIR}/kickoff.py --to c3 --model opus --size S comment-cleanup "the user's task"
```

The script checks `cseat` before changing the repository, creates a new
worktree from the current checkout's committed HEAD, and launches Claude with cseat's
native seat picker and automatic handoffs. It passes the same task size to the
preflight and launched session, pins Fable when `--model` is omitted, honors
`--to` by translating short aliases such as `c3` to cseat's `claude3` seat,
sends the task, and returns. On a machine without cseat it falls back to a
directly launched, explicitly pinned Claude session.

Run it from the checkout whose work the new task should build on. From a linked
worktree, this stacks the new branch on that worktree's current branch—not main.
Uncommitted changes stay in the source checkout; commit needed changes first
with the user's authorization. The script prints the parent and exact starting
commit and records `branch.<child>.gh-merge-base`, which both `gh pr create` and
`<leader>gD` use without changing the child's push/pull upstream.

Use `--base main` (or another local branch) when the user wants an independent
start instead of stacking. Detached HEAD requires an explicit `--base`.
`--repo` keeps the current checkout when it names the current repository;
for a different repository it uses that repository's open main checkout.
The recorded parent is intent, not a stack manager: after merging/deleting or
rebasing the parent, retarget/rebase the child as appropriate. An existing PR's
base takes precedence in `<leader>gD`.

When it prints the final line, report that line and stop. Do not inspect the
agent in the same turn.
