---
name: kickoff
description: "Create a new Orca worktree, start an agent there with a seed brief, and return; the agent settles the task's shape with the user itself before building. Use when asked to kick off, spin up, delegate, farm out, or put an agent on work in parallel."
allowed-tools: Read Glob Grep Write Bash(python3 ${CLAUDE_SKILL_DIR}/kickoff.py *)
---

# Kickoff

Launch fast and let the worker settle the shape. By default the new agent
grills the user with the `grilling` skill in its own Orca session before building, so
the questions, the answers and the reasons behind them stay in the context of
the session that does the work, instead of being compressed into a brief.

## Decide whether the worker grills

The worker grills by default. Pass `--no-grill` only when the request already
pins the shape: a named PR to rebase or merge, a one-line fix, a brief the user
wrote out themselves, or a shape already settled in this conversation. Either
way the worktree opens in the background and focus stays where the user is;
they switch to the worker's session in Orca to answer when they're ready.

When the user asks for several kickoffs at once, check whether any of them
touch the same code or turn on the same open question. If they do, say so and
propose one worker, or a design pass that settles the question first; launch
them separately only once the user chooses. Parallel workers on an unsettled
design each find the question on their own, and their work gets thrown away.
When the kickoffs come from a list of tickets, also leave out any ticket that
is assigned to someone else or sits in an area a memory routes to someone
else, and name what you left out in the reply.

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
python3 ${CLAUDE_SKILL_DIR}/kickoff.py signup-rate-limit "the scoped task brief"
```

The slug names the new worktree and, under Orca's branch prefix, its branch. Add
`--no-grill` when the shape is pinned. Use `--brief-file` for a long task. Use
`--repo <name>` when the work belongs to another repository, by the name Orca
lists it under.

The script asks Orca for a new worktree of the current repository with Claude
started on the brief, and returns. Orca decides the rest. Its Claude command
picks the login and the model, so there is no seat or task size to pass. Its
Chat or CLI setting picks the surface; a chat stays on the login it started on.
Pass `--model` only when the user names a model:

```bash
python3 ${CLAUDE_SKILL_DIR}/kickoff.py --model opus comment-cleanup "the user's task"
```

The brief it sends tells the worker which branch it started from, and that
links in the task (Slack threads, issues, PRs) are context to read, never to
reply to, so leave both out of your brief. Unless `--no-grill` is given, the
grilling instruction comes before the task. When Orca is not installed or not
running the script stops and says so; there is no other launcher to fall back
to.

The new branch starts from the default branch on origin,
whatever branch this session is on. Use `--base <branch>` only when the user
wants the work stacked on a branch: the worktree then starts from that local
branch, and the script records `branch.<child>.gh-merge-base`, which both
`gh pr create` and `<leader>gD` use without changing the child's push/pull
upstream. Uncommitted changes never carry over; commit what the worker needs
first, with the user's authorization. The recorded parent is intent, not a
stack manager: after merging, deleting or rebasing the parent, retarget or
rebase the child as appropriate. An existing PR's base takes precedence in
`<leader>gD`.

When the task is a ticket (Linear or another tracker the session can write),
start it in the same turn as the launch: assign it to the person you work for
and move it to In Progress, in one write. A grilling worker can sit for hours
before it touches the ticket, and the board should show the work as started
from the moment an agent owns it. Tell the worker in the brief that this is
done, so it does not repeat it.

When it prints the final line, report that line and stop. Do not inspect the
agent in the same turn; when it grills, the user answers it in its own session.
