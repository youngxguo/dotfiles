---
name: pickup
description: "Pick up paused work from an existing GitHub pull request: from the main chat, restore or reopen its branch as a Herdr worktree workspace, refresh the PR refs safely, and start a Claude agent on an account with headroom for a read-only reorientation pass. Wait for its PR, review, and CI report, relay that to the user, and do not resume implementation until the user recenters the work. Use when the user says /pickup with a PR link, asks to resume or continue a PR after its worktree was removed, or wants an agent put back on an existing PR branch. Not for a branch with no PR; use kickoff for new work."
allowed-tools: Bash(python3 ${CLAUDE_SKILL_DIR}/pickup.py *)
---

# Pickup

`pickup.py` beside this file restores paused PR work from a main chat, much like
kickoff does for new work. It resolves the repository from the PR URL, finds
that repository's main checkout among open Herdr workspaces, fetches the exact
PR head and base branch, recreates or reopens the PR branch as its own worktree
workspace, asks rebump for a Claude account with headroom, and starts the agent.

Pickup deliberately stops after orientation. The worktree agent inspects the
diff, PR body, reviews, inline comments, checks and relationship to the base
branch without editing anything. The script waits for that first pass and
prints the agent's re-centering report so the main chat can relay it to the
user. No implementation begins until the user responds with direction.

It needs `gh` and `herdr` on PATH, authenticated GitHub and git remotes, and the
`kickoff` and `rebump` skills beside this one. This session must have
`HERDR_ENV=1`.

## Use it immediately

For the normal request, run this as the first tool call:

```bash
python3 ${CLAUDE_SKILL_DIR}/pickup.py https://github.com/OWNER/REPO/pull/123
```

Do not inspect the PR or codebase first. The script refreshes the checkout and
the worktree agent does its own reorientation. Wait for the command to finish,
then send the user a concise message based on the printed reorientation report.
Include the agent name, branch and workspace id, and end by asking what direction
they want to take. Do not prompt the worktree agent again yet.

Pass any direction after the link. Keep it close to the user's words:

```bash
python3 ${CLAUDE_SKILL_DIR}/pickup.py <pr-url> "focus on the review feedback"
```

For a longer note, write only that note to a scratch file and use
`--brief-file`. Do not duplicate the script's standard reorientation brief.

## Safety and refresh behavior

The PR head is fetched through the base repository's GitHub pull ref. The base
branch is fetched but never merged or rebased automatically.

- A missing local branch is recreated at the PR head.
- A local branch behind the PR is fast-forwarded when it is not checked out.
- Local commits ahead of the PR are preserved.
- Diverged history is preserved and called out to the agent for reconciliation.
- An existing checked-out branch is not moved behind its worktree's back.
- A closed or merged PR is rejected unless the user explicitly asks to pick it
  up anyway; then pass `--allow-closed`.

Never add `--allow-closed` merely to make a mistaken or stale link work.

## Options

- The PR URL normally identifies the repository from any current pane. If no
  open Herdr workspace has that repository's main checkout, ask the user to
  open it or pass its path with `--cwd <path>`.
- `--focus` switches the user to the restored workspace; the default leaves
  focus alone.
- `--no-agent` restores the workspace without launching an agent.
- `--kind codex` starts another agent kind. Rebump account selection applies
  only to Claude. `--to c3` pins the Claude account.
- `--branch <name>` chooses a different local branch name. The default is the
  PR head branch.
- Pickup waits for the orientation report by default. `--no-wait` is only for
  an explicit request to leave that first pass running in the background.
- `--trust-repository` is for a repository Herdr has not seen before.
- `--dry-run` resolves the PR and checkout without fetching or opening it.
- Anything after a bare `--` is passed to the agent command.

If a worktree already hosts an agent, the script leaves it alone and tells you
to prompt that agent directly.

## Re-center before continuing

The first response to `/pickup` is a report to the user, not the resumption of
implementation. Relay what the worktree agent found and let the user correct the
context, priorities or desired next step. Only after the user answers should
you send that direction to the named agent with `herdr agent prompt`.

If `--no-wait` was explicitly requested, check on the named agent with
`herdr agent get` and `herdr agent read`; still relay its orientation before
sending implementation work.

A finished worktree is cleaned up with
`herdr worktree remove --workspace <id>` only on an explicit ask, and never for
a workspace this skill did not create or restore.
