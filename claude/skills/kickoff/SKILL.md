---
name: kickoff
description: "Create a new Herdr worktree, start an agent there with a seed brief, and return; the agent settles the task's shape with the user itself before building. Use when asked to kick off, spin up, delegate, farm out, or put an agent on work in parallel."
allowed-tools: Read Glob Grep Write Bash(python3 ${CLAUDE_SKILL_DIR}/kickoff.py *)
---

# Kickoff

Launch fast and let the worker settle the shape. By default the new agent
grills the user with the `grilling` skill in its own pane before building, so
the questions, the answers and the reasons behind them stay in the context of
the session that does the work, instead of being compressed into a brief.

## Decide whether the worker grills

The worker grills by default. Pass `--no-grill` only when the request already
pins the shape: a named PR to rebase or merge, a one-line fix, a brief the user
wrote out themselves, or a shape already settled in this conversation. With
`--no-grill` the workspace opens in the background; otherwise it opens focused,
so the user lands in the worker's pane to answer.

When the user asks for several kickoffs at once, check whether any of them
touch the same code or turn on the same open question. If they do, say so and
propose one worker, or a design pass that settles the question first; launch
them separately only once the user chooses. Parallel workers on an unsettled
design each find the question on their own, and their work gets thrown away.

## Write the seed brief

The brief carries what only this session knows; the worker will find facts and
ask the questions itself. Start from the user's request and keep their intent,
explicit constraints and useful wording. Add context from this conversation the
worker cannot rebuild: why the task exists, decisions or preferences the user
already stated, related work in flight, and starting points you already know.
Pass this as raw context, not a finished spec, and don't research the task to
fill it out: no codebase tour, no root-cause tracing, no design comparison.

With `--no-grill` the brief must stand on its own: add the scope, non-goals and
what done looks like, labelling hypotheses as hypotheses.

Scale it to the task: a sentence or two for a clear request, a few short
paragraphs when the conversation carried real context. Launch without an
approval round.

## Launch

Run `kickoff.py` with the seed brief:

```bash
python3 ${CLAUDE_SKILL_DIR}/kickoff.py --size M signup-rate-limit "the scoped task brief"
```

The slug names the new branch, workspace, and agent. Add `--no-grill` when the
shape is pinned. Use `--brief-file` for a long task. Use `--repo <name>` when
the work belongs to another open repository.

Always pass `--size`; use `M` unless the user names a task size. Pass
`--model` only when the user names a model: otherwise cseat's own policy picks
it (Opus for every task kind on this machine), which keeps Fable for the
sessions a person drives. When the user names a Claude account, pass `--to`
instead of leaving the selection only in the brief:

```bash
python3 ${CLAUDE_SKILL_DIR}/kickoff.py --to yc1 --model opus --size S comment-cleanup "the user's task"
```

The script checks `cseat` before changing the repository, creates a new
worktree (via the repo's parent Herdr workspace, which Herdr requires) based on
the current checkout's committed HEAD, and launches Claude with cseat's
native seat picker and automatic handoffs. It passes the same task size to the
preflight and launched session, leaves the model to cseat's policy when
`--model` is omitted, honors `--to` as a cseat seat name exactly as
`cseat list` shows it (no aliases, so an unknown name fails before anything
changes), sends the task (prefixed with the grilling instruction unless `--no-grill`),
and returns. The brief it sends tells the worker that links in
the task (Slack threads, issues, PRs) are context to read, never to reply to,
so leave that out of your brief. On a machine without cseat it falls back to a
directly launched, explicitly pinned Claude session.

Before pinning that commit it fetches the parent branch's upstream and
fast-forwards the branch (and its checkout, when one has it open), so a new
worktree never starts behind what has already merged. When it is offline, the
branch has diverged, or local edits block the move, it keeps the local tip and
prints why.

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
agent in the same turn; when it grills, the user answers it in its own pane.
