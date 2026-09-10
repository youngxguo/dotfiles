---
name: rebump
description: Check every Claude subscription's usage (cusage across ~/.claude and the c2/c3/c4 config dirs) and move rate-limited Claude Code sessions running in herdr onto a subscription with headroom, resuming each one there and nudging it to carry on. Also picks the account a new Claude Code agent should start on. Use when a session hit its session, 5-hour or weekly usage limit, when asked to rebump, rebalance or move sessions to another sub or account, when asked which claude account has headroom, and before starting any claude agent in a herdr pane.
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

## Starting a new claude agent in herdr

Never start claude in a herdr pane without picking the account first: the
default `~/.claude` account is often the one that is out of limits, and a
session started on a spent subscription just stalls on the rate-limit message.

```bash
python3 ${CLAUDE_SKILL_DIR}/rebump.py pick
```

It prints `CLAUDE_CONFIG_DIR=<dir>` on stdout (the accounts table goes to
stderr) and exits 1 when no account has headroom; stop and tell the user in
that case instead of launching anyway. Headroom means the 5-hour window is
under 90%, the weekly cap is not blocked and the Fable weekly cap is under
100%. Fable is the model we want running, and its weekly cap cannot be waited
out like a 5-hour window, so among usable accounts it prefers the most Fable
headroom, then the emptiest 5-hour window. `--to c3` insists on a named account
and fails if it is spent. `pick` reuses a cusage report younger than five
minutes, so starting several agents in a row only pays for cusage once;
`--max-age 0` forces a fresh read.

Pass the result to the pane that will host the agent, then start it as the
herdr skill describes:

```bash
env=$(python3 ${CLAUDE_SKILL_DIR}/rebump.py pick) || exit 1
herdr pane split --current --direction right --cwd "$PWD" --env "$env" --no-focus
herdr agent start <name> --kind claude --pane <returned-pane-id> -- --chrome
```

`workspace create` and `tab create` take the same `--env`; `worktree create`
does not, and a pane that already exists cannot change its environment. Put
the account on the command line in that case, then wait for herdr to detect
claude and give it its name:

```bash
herdr pane run <pane-id> "$env claude --chrome"
herdr agent wait <pane-id> --timeout 90000
herdr agent rename <pane-id> <name>
```

## Rules

- A spent Fable weekly cap counts as limited: the plan moves those sessions
  even if the account could still run other models.
- Only move panes the plan marks as limited. Moving a healthy pane needs the
  user to ask for it explicitly; then use `apply --force --pane <id>`.
- `--nudge ""` resumes without sending the follow-up prompt; use it when the
  user wants to look at a session before it continues.
- The old config dir keeps its copy of the transcript, and the project's
  `memory/` directory does not move with the session. Mention both only if the
  user asks where the session went.
