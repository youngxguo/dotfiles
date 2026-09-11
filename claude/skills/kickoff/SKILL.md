---
name: kickoff
description: "Kick off a piece of work in its own herdr worktree workspace - branch off a repo's main checkout, open it as a workspace, start a claude agent on an account with headroom, and hand it the brief. Use when asked to kick off, spin up, delegate or farm out a task to a new worktree, branch or workspace, or to put an agent on a task in parallel with the current one. Not for work in the current checkout: that is a sibling pane, see the herdr skill."
allowed-tools: Bash(python3 ${CLAUDE_SKILL_DIR}/kickoff.py *)
---

# Kickoff

`kickoff.py` beside this file runs the whole sequence: resolve the repo's main
checkout workspace, `herdr worktree create` a branch and open it as its own
workspace, wait for the root pane's shell, ask the rebump skill which account
and model have headroom, launch claude there, answer the folder-trust dialog a
fresh worktree path shows, name the agent, and send the brief.

Needs `herdr` on PATH and the rebump skill beside this one; this session should
have `HERDR_ENV=1`.

## Use it

```bash
python3 ${CLAUDE_SKILL_DIR}/kickoff.py signup-rate-limit --brief-file /tmp/brief.md
```

The slug is the only required argument. It becomes the branch
(`<git user>/<slug>`), the workspace label and the agent name. Pass a
one-line brief as the trailing positional; write a longer one to a file in
the scratchpad and pass `--brief-file`.

Worth knowing:

- `--repo <name>` kicks off in another repo's main checkout, so this works from
  any pane. Without it the source is the current workspace, resolved up to the
  repo's parent checkout if you are already inside a linked worktree.
- `--base <ref>` branches off that ref instead of HEAD. In a top-level
  workspace HEAD is usually what you want.
- A branch that already has a worktree is opened rather than created, and the
  run stops if an agent is already living in it (`--force` overrides).
- `--focus` switches the user to the new workspace; the default leaves their
  focus alone.
- `--no-agent` just opens the worktree workspace. `--kind codex` starts a
  different agent (rebump only applies to claude). `--to c3` pins the account.
  `--wait` blocks until the agent settles on the brief instead of returning as
  soon as it is sent. `--trust-repository` is for a repo herdr has not been
  pointed at before. Anything after `--` is passed to the agent itself.
- `--dry-run` prints the branch and source workspace it resolved and stops.

Report the final line it prints: agent name, branch, workspace id, path.

## Pass the ask straight through

Do not read the codebase, search for entry points or plan the work before
kicking off. The agent does its own reasoning in the worktree; anything you
work out here is wasted and delays the launch. Run `kickoff.py` as the first
tool call.

The brief is the user's request, close to verbatim. The only additions are
what the agent cannot get from the request itself because it starts fresh and
cannot see this conversation: something the user said earlier in the session
that the request depends on, and, if the user said so, whether to commit, push
or open a PR. Say its branch is already created and checked out. Do not ask
it to write its answer to a file; read the pane.

## Afterwards

Check on it, or send it more work, with the herdr skill's `agent list`,
`agent get`, `agent read` and `agent prompt` - the agent answers to the name
this printed.

A finished worktree is cleaned up with
`herdr worktree remove --workspace <id>`, which closes the workspace - only on
an explicit ask, and never for a workspace this skill did not create.
