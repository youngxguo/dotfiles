---
name: kickoff
description: "Settle the shape of the user's task with them, write it into a useful handoff, create a new Herdr worktree, start an agent there, and return. Use when asked to kick off, spin up, delegate, farm out, or put an agent on work in parallel."
allowed-tools: Read Glob Grep Write Bash(python3 ${CLAUDE_SKILL_DIR}/kickoff.py *)
---

# Kickoff

## Settle the shape first

Before writing a brief, grill the user until you share an understanding of the
change. Map it as a design tree: each decision branches into the decisions that
hang off it. Cover what a reviewer would need settled: what changes and what
stays, the design choice it turns on, what done looks like, and how it relates
to work already in flight (an open PR, another worker in the same area). Leave
choices the worker can make while implementing to the worker.

Work the tree in rounds. The frontier is every decision whose prerequisites are
already settled. Ask the whole frontier in one round, then wait for the user's
answers. A question that depends on another one still open belongs to a later
round. Each round of answers pushes the frontier outward; recompute it and ask
the next round. Number each question, give the answer you'd recommend, and word
it so "yes" accepts that answer:

```
❓ **Q1** - **<title>**: <question, with the options if there are several>

➡️ <recommended answer>

---

❓ **Q2** - ...
```

Facts are yours to find; decisions are the user's. Look up whatever the repo, a
PR or a tool can answer instead of asking. For anything broader than a few
reads, dispatch a subagent and ask the rest of the frontier while it runs; only
the questions that depend on its answer wait.

The grilling is done when the frontier is empty: every branch visited, nothing
silently assumed. Then state the agreed shape in a few lines and ask the user to
confirm it. Their confirmation is the go-ahead to launch.

Skip the questions only when the request already pins the shape: a named PR to
rebase or merge, a one-line fix, or a brief the user wrote out themselves.

When the user asks for several kickoffs at once, check whether any of them
touch the same code or turn on the same open question. If they do, say so and
propose one worker, or a design pass that settles the question first; launch
them separately only once the user chooses. Parallel workers on an unsettled
design each find the question on their own, and their work gets thrown away.

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
Don't invent requirements or fill every category mechanically.

Prefer existing context. If one missing fact would materially improve the
handoff, make a few targeted, read-only searches or file reads. Don't conduct a
broad codebase tour, trace the full root cause, compare architectures in depth,
edit project files, or run tests. Stop once the worker can understand the goal,
where to start, and how to recognize success. If more research is needed to
choose a solution, make that part of the delegated task instead.

Pass the resulting brief to `kickoff.py`; don't merely describe it to the user
and then send the raw request. Once the shape is agreed, launch without another
approval round.

## Launch

Run `kickoff.py` after preparing the brief:

```bash
python3 ${CLAUDE_SKILL_DIR}/kickoff.py --size M signup-rate-limit "the scoped task brief"
```

The slug names the new branch, workspace, and agent. Use `--brief-file` for a
long task. Use `--repo <name>` when the work belongs to another open repository.

Always pass `--size`; use `M` unless the user names a task size. Pass
`--model` only when the user names a model: otherwise cseat's own policy picks
it (Opus for every task kind on this machine), which keeps Fable for the
sessions a person drives. When the user names a Claude account, pass `--to`
instead of leaving the selection only in the brief:

```bash
python3 ${CLAUDE_SKILL_DIR}/kickoff.py --to c3 --model opus --size S comment-cleanup "the user's task"
```

The script checks `cseat` before changing the repository, creates a new
worktree (via the repo's parent Herdr workspace, which Herdr requires) based on
the current checkout's committed HEAD, and launches Claude with cseat's
native seat picker and automatic handoffs. It passes the same task size to the
preflight and launched session, leaves the model to cseat's policy when
`--model` is omitted, honors `--to` by translating short aliases such as `c3` to cseat's `claude3` seat,
sends the task, and returns. The brief it sends tells the worker that links in
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
agent in the same turn.
