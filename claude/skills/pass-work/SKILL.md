---
name: pass-work
description: "Pass this session's work to the Orca on another of the user's machines: its branch, and a fresh Claude there that starts from a brief. Use when asked to pass, hand over or move this work or this session to the other Mac, the work laptop, the personal machine, or 'before I leave'."
allowed-tools: Read Write Bash(python3 ${CLAUDE_SKILL_DIR}/pass_work.py *)
---

# Pass work

Two machines each run Orca and are paired to each other. A pass moves this
worktree's branch to the other one and starts a fresh Claude on it there. The
conversation does not move: the next Claude has the code and your brief, and
nothing else you know.

## Before the pass

Stop what only this session keeps alive, so two machines never work the same
branch: end any loop or scheduled job this session runs, stop background tasks,
and stop a dev server it started. The brief says how to start again what the
next session needs.

Commit everything that should travel. A work-in-progress commit is fine; say in
the brief that it is one. The script refuses a tree with uncommitted paths, and
pushes the branch itself when origin is behind. Ignored files (an env file, a
scratch note) do not travel, so put what matters from them in the brief.

## Write the brief

Write it to a file outside the worktree (your scratch directory), so it does
not count as an uncommitted path, for a reader who was never in this
conversation:

- what the work is for, in the user's words where they gave them
- what is done, and how you checked it
- what is left, in the order you would do it
- decisions and preferences the user stated, and anything they are waiting on
  or you are waiting on them for
- what you learned that the code does not show: a dead end, a flaky step, a
  command that only works one way
- links to the PR, the ticket and the thread, and anything this work has
  running elsewhere
- a loop or scheduled job you ended, with the exact command that starts it again

The script puts two sentences in front of your brief: which machine the work
came from, with the branch and commit, and that this machine may lack
something the other has. Leave those out.

## Pass

```bash
python3 ${CLAUDE_SKILL_DIR}/pass_work.py --to <machine> --brief-file <file>
```

`--to` takes the other machine's name in `orca environment list`, or any part
only it has, such as `work` or `personal`. `--dry-run`, which needs no brief,
says what a pass would do and changes nothing.

The other Orca gets the branch in a new worktree, or fast-forwarded in the one
it already has on that branch, and Claude starts there with the brief. The
script prints that worktree and session; report both.

Then stop working on this branch here. This worktree stays, and a pass back
lands in it.

## When it refuses

- **The other machine has commits or changes of its own on the branch.** It was
  worked on there since the last pass. Nothing was started. Tell the user: that
  side pushes or passes back first.
- **No checkout of the project there.** The repository is not in that Orca yet.
- **The brief did not reach Claude.** The session exists there; the user pastes
  the brief into it.

To pass several sessions, each one passes itself: only it can write its brief.
