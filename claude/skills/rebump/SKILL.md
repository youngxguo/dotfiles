---
name: rebump
description: Check every Claude subscription's usage (cusage across ~/.claude and the c2/c3/c4 config dirs) and move rate-limited Claude Code sessions running in herdr onto a subscription with headroom, resuming each one there and nudging it to carry on. Use when a session hit its session, 5-hour or weekly usage limit, when asked to rebump, rebalance or move sessions to another sub or account, or when asked which claude account has headroom.
allowed-tools: Bash(python3 ${CLAUDE_SKILL_DIR}/rebump.py *)
---

# Rebump

`rebump.py` beside this file does the work. It runs `cusage --json` for every
account, lists the claude panes herdr knows about, reads each pane's account
from its process environment, and for every pane whose transcript ends on a
rate-limit message (or whose account is spent) it: copies the transcript into
the target config dir (`claude --resume` only searches its own
`CLAUDE_CONFIG_DIR`), quits claude in the pane with two Ctrl-C, relaunches the
same command line under the target account with `--resume`, answers the
folder-trust and other first-run dialogs the target account may show for that
folder, waits for herdr to see it settle, and prompts it to continue.

Needs `herdr` on PATH with the server running (this session should have
`HERDR_ENV=1`) and the hsys `cusage` helper sourced by the shell.

## Steps

1. Always start read-only:

   ```bash
   python3 ${CLAUDE_SKILL_DIR}/rebump.py plan
   ```

   Show the user the accounts table and the pane list as printed. It takes
   about half a minute because cusage asks every account for `/usage`.

2. If the user only asked to check usage or headroom, stop there.

3. Otherwise apply the plan. Pass `--to` when the user named an account (any of
   the cusage label, `c3`, `claude3` or a config dir works) and `--pane` to
   limit it to specific panes:

   ```bash
   python3 ${CLAUDE_SKILL_DIR}/rebump.py apply
   python3 ${CLAUDE_SKILL_DIR}/rebump.py apply --to c3 --pane w2E:p1
   ```

   Each pane takes 20-60 seconds (quit, relaunch, wait for the resume). Report
   the per-pane result lines it prints.

4. A pane marked `cannot move (this pane)` is the one running this skill; the
   script prints the command to run there. Tell the user to quit claude in this
   pane and paste that command, or to run the skill from another pane.

## Rules

- Only move panes the plan marks as limited. Moving a healthy pane needs the
  user to ask for it explicitly; then use `apply --force --pane <id>`.
- `--nudge ""` resumes without sending the follow-up prompt; use it when the
  user wants to look at a session before it continues.
- The old config dir keeps its copy of the transcript, and the project's
  `memory/` directory does not move with the session. Mention both only if the
  user asks where the session went.
