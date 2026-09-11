---
name: rebump
description: Check every Claude subscription's usage (cusage across ~/.claude and the c2/c3/c4/c5/c6 config dirs) and get rate-limited Claude Code sessions running in herdr going again - on a subscription with headroom, or on another model when the cap binds only the one they run - resuming each one and nudging it to carry on. Also picks the account and model a new Claude Code agent should start on. Use when a session hit its session, 5-hour, weekly or per-model usage limit, when asked to rebump, rebalance or move sessions to another sub, account or model, when asked which claude account has headroom, and before starting any claude agent in a herdr pane.
allowed-tools: Bash(python3 ${CLAUDE_SKILL_DIR}/rebump.py *)
---

# Rebump

`rebump.py` beside this file does the work, in two flows that share one
planner:

- **One session, automatically.** The `StopFailure` hook runs `rebump.py hook`
  inside the session that hit the limit. It plans that session alone, from the
  session id and transcript Claude Code hands the hook and the environment the
  hook inherits, and never looks at the rest of herdr. See "Rebumping
  automatically" below; this is how nearly every rebump happens now.
- **Every pane, by hand.** `plan` and `apply` sweep the claude panes herdr
  knows about, reading each pane's account off its process environment. They
  exist for sessions the hook cannot reach: ones started before the hook was
  added (Claude Code reads hooks at startup), and ones the hook left alone
  because no account had headroom at the time.

Both flows do the same thing to a limited session: `cusage --json` for every
account, then, when the transcript ends on a rate-limit message (or the account
is spent), copy the transcript into the target config dir (`claude --resume`
only searches its own `CLAUDE_CONFIG_DIR`), quit claude in the pane with two
Ctrl-C, relaunch the same command line under the target account with
`--resume`, answer the folder-trust and other first-run dialogs the target
account may show for that folder, wait for herdr to see it settle, confirm the
pane is running the resumed session, and prompt it to continue.

A cap that binds only the model a session runs - a spent Fable weekly cap, or
"You're out of usage credits. /model to switch models." at the end of the
transcript - is not a reason to move it. Those sessions are relaunched where
they are, on `opus`, which leaves the account's 5-hour window and weekly cap to
carry them.

Needs `herdr` on PATH with the server running (this session should have
`HERDR_ENV=1`) and the hsys `cusage` helper sourced by the shell.

## Steps

Before sweeping, check `~/.cache/rebump/hook.log`: a session inside herdr that
hit its limit has usually rebumped itself already, and the log says where it
went or why it stayed. The sweep is for what the log does not cover.

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
   the per-pane result lines it prints. A line reading `restart here on opus`
   is a model switch, not a move: the session stays on its own account. A
   `failed: the pane runs session <id>` line means something else took the
   pane over between the quit and the nudge - typically the user restarting
   claude by hand in it - so the resumed session was not nudged; the
   transcript is still in the target config dir and `claude --resume <id>`
   there brings it back.

4. A pane whose plan line says it `cannot do it to itself` is the one running
   this skill; the script prints the command to run there. Tell the user to
   quit claude in this pane and paste that command, or to run the skill from
   another pane.

## Starting a new claude agent in herdr

Never start claude in a herdr pane without picking the account first: the
default `~/.claude` account is often the one that is out of limits, and a
session started on a spent subscription just stalls on the rate-limit message.

```bash
python3 ${CLAUDE_SKILL_DIR}/rebump.py pick
```

It prints the environment the session should start under on stdout (the
accounts table goes to stderr) and exits 1 when no account has headroom; stop
and tell the user in that case instead of launching anyway. Headroom means the
5-hour window is under 90% and the weekly cap is not blocked; a spent Fable
weekly cap does not disqualify an account, it only decides the model. Fable is
the model we want running, and its weekly cap cannot be waited out like a
5-hour window, so among usable accounts it prefers the most Fable headroom,
then the emptiest 5-hour window. `--to c3` insists on a named account and fails
if it is spent. `pick` reuses a cusage report younger than five minutes, so
starting several agents in a row only pays for cusage once; `--max-age 0`
forces a fresh read.

What it prints is a shell prefix, not a `KEY=VALUE` pair. It is one of
`CLAUDE_CONFIG_DIR=<dir>` or `env -u CLAUDE_CONFIG_DIR` (the default account is
only reachable with the variable unset; setting it, even to `~/.claude`, sends
that account to a login prompt), followed by `ANTHROPIC_MODEL=<model>` when the
account's Fable cap is spent and its own `settings.json` default is Fable. `--env` cannot express the `env -u` form, so
start claude with `pane run` and let herdr detect it, rather than splitting
with `--env` and `agent start`:

```bash
env=$(python3 ${CLAUDE_SKILL_DIR}/rebump.py pick) || exit 1
herdr pane split --current --direction right --cwd "$PWD" --no-focus
herdr pane run <returned-pane-id> "$env claude --chrome"
herdr agent wait <pane-id> --timeout 90000
herdr agent rename <pane-id> <name>
```

## Rebumping automatically

`claude/settings.json` registers `rebump.py hook` as a Claude Code
`StopFailure` hook with the `rate_limit` matcher, in every config dir, so a
herdr session that hits a usage limit rebumps itself without anyone running
this skill. The hook forks the single-session flow into its own process group
and returns at once. That flow builds the session from the hook payload
(session id, transcript path, cwd) and the hook's own environment
(`CLAUDE_CONFIG_DIR`, `ANTHROPIC_MODEL`, `HERDR_PANE_ID`), asks herdr only for
the pane's claude command line, and then does exactly what step 3 does for
that one pane - or nothing when no account has headroom, which leaves Claude
Code's own wait-for-reset in place. It never lists or touches other panes.
Each run appends to `~/.cache/rebump/hook.log` (`XDG_CACHE_HOME` respected);
a `hook-<pane>.pid` beside it stops a second limit hit from starting a second
rebump while one is still running. Outside herdr, or for any other API error,
the hook does nothing. Sessions started before the hook was added do not have
it: Claude Code reads hooks at startup.

The rebump takes 20-60 seconds and works the pane from outside, so leave the
pane alone once the limit message shows. Quitting claude or starting it again
by hand in that pane while the hook is mid-flight races it: the hook's
relaunch gets cut short, and the fresh session started by hand ends up with
whatever was pasted next as its first prompt. The hook notices this (the
pane's session id no longer matches) and logs it as a failure instead of
nudging the wrong session.

## Rules

- A spent Fable weekly cap only troubles a session that runs Fable. rebump
  reads the pin (`--model` or `ANTHROPIC_MODEL`) first, then the model that
  last answered in the transcript, then the account's own `settings.json`
  default - `~/.claude` runs `opus[1m]`, `~/.claude2` runs Fable - so panes
  already off Fable are left alone.
- The switch rides in `ANTHROPIC_MODEL` and drops any `--model` from the old
  command line, so it also beats a pin the pane's shell already carried. Going
  the other way, when the target can run Fable and its own default is Fable,
  rebump unsets the pin instead of writing one, which keeps the `[1m]` suffix
  the default carries. `--fallback-model` changes what it switches to.
- Only move or switch panes the plan marks as limited. Touching a healthy pane
  needs the user to ask for it explicitly; then use `apply --force --pane <id>`.
- `--nudge ""` resumes without sending the follow-up prompt; use it when the
  user wants to look at a session before it continues.
- The old config dir keeps its copy of the transcript, and the project's
  `memory/` directory does not move with the session. Mention both only if the
  user asks where the session went.
