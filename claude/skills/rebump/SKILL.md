---
name: rebump
description: Check every Claude subscription's usage (cusage across ~/.claude and the c2/c3/c4/c5/c6 config dirs) and move rate-limited Claude Code sessions running in herdr onto a subscription that can continue the same model, resuming each one there and nudging it to carry on. Also picks the account and model a new Claude Code agent should start on. Use when a session hit its session, 5-hour, weekly or per-model usage limit, when asked to rebump, rebalance or move sessions to another sub or account, when asked which claude account has headroom, and before starting any claude agent in a herdr pane.
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
is spent), find another account with headroom for the session's current model,
copy the transcript into its config dir (`claude --resume` only searches its
own `CLAUDE_CONFIG_DIR`), quit claude in the pane with two Ctrl-C, relaunch the
same command line under the target account with `--resume`, answer the
folder-trust and other first-run dialogs the target account may show for that
folder, wait for herdr to see it settle, confirm the pane is running the resumed
session, and prompt it to continue.

**Rebump never changes the model of an existing session.** A spent Fable weekly
cap or a per-model limit moves a Fable session to another account with Fable
headroom. If none exists, the session is left at the limit instead of being
relaunched on Opus. When account defaults differ, rebump carries an explicit
pin for the model already running.

Needs `herdr` on PATH with the server running (this session should have
`HERDR_ENV=1`) and the hsys `cusage` helper sourced by the shell.

## Steps

When the user identifies a target as `chat N` or `agent N`, `N` is the Herdr
agent index shown in the UI. Pass it directly to `plan` and `apply` as
`--agent-index N` (also accepted as `--chat N`); the script resolves the live
agent's `tokens.num` and rejects missing, ambiguous, or non-Claude indexes. It
is not a Herdr workspace number and not a Claude account label such as `cN`.
When the user also names a project or branch, pass it as `--expect-project` so
the script rejects a conflicting index instead of inferring or forcing another
pane.

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
   python3 ${CLAUDE_SKILL_DIR}/rebump.py apply --agent-index 4
   python3 ${CLAUDE_SKILL_DIR}/rebump.py apply --agent-index 4 --expect-project young/logging-middleware
   ```

   Each pane takes 20-60 seconds (quit, relaunch, wait for the resume). Report
   the per-pane result lines it prints. A `preserving <model>` suffix means the
   target account has a different default, so the relaunch explicitly keeps the
   session's existing model. A `failed: the pane runs session <id>` line means
   something else took the pane over between the quit and the nudge - typically
   the user restarting claude by hand in it - so the resumed session was not
   nudged; the
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
weekly cap does not disqualify an account, it only decides the model. It always
spends the subscription whose overall weekly quota resets soonest, because
unused quota is lost at reset while a later-resetting account can still serve
work afterward. Model selection does not affect this ordering: Fable
availability only determines whether an existing Fable session can use the
account, or whether a new session needs the Opus fallback. A spent Fable cap
never pushes an otherwise earlier-expiring subscription to the back. Equal
weekly resets prefer an open (under 80%) 5-hour window; crowded ties prefer the
one whose 5-hour window resets sooner, then the emptier window. `--to c3`
insists on a named account and fails if it is spent. `pick` reuses a cusage
report younger than five minutes, so starting several agents in a row only
pays for cusage once; `--max-age 0` forces a fresh read. Only this
brand-new-session flow may choose Opus as a fallback; it never changes a model
after a session has started.

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
that one pane - or nothing when no account can continue the same model, which
leaves Claude Code's own wait-for-reset in place. It never lists or touches
other panes.
Each run appends to `~/.cache/rebump/hook.log` (`XDG_CACHE_HOME` respected),
including the runs it skipped and why; a `hook-<pane>.pid` beside it stops a
second limit hit from starting a second rebump while one is still running.
When it is done it shows a herdr notification with the outcome, silent for a
clean resume and with a sound (and the log path) for anything less, so a
session that stayed put or was resumed without its nudge does not go
unnoticed. Outside herdr, or for any other API error, the hook does nothing.
Sessions started before the hook was added do not have it: Claude Code reads
hooks at startup.

The rebump takes 20-60 seconds and works the pane from outside, so leave the
pane alone once the limit message shows. Quitting claude or starting it again
by hand in that pane while the hook is mid-flight races it: the hook's
relaunch gets cut short, and the fresh session started by hand ends up with
whatever was pasted next as its first prompt. The hook notices this (the
pane's session id no longer matches) and logs it as a failure instead of
nudging the wrong session.

After the relaunch the script waits for a claude with a new pid (herdr keeps
the quit one on record as `done` for a moment), retries the nudge while herdr
catches up, and presses esc on Claude Code's own "continuing automatically"
wait, which a resumed transcript re-arms for the old account's reset.

## Rules

- A spent Fable weekly cap only troubles a session that runs Fable. rebump
  reads the pin (`--model` or `ANTHROPIC_MODEL`) first, then the model that
  last answered in the transcript, then the account's own `settings.json`
  default. It excludes accounts whose Fable cap is spent from that session's
  targets, even though those accounts can still start new Opus sessions.
- An existing model pin is preserved. If the session was unpinned but the
  target account defaults to another model, rebump pins the source account's
  default (including a `[1m]` suffix) or the transcript model. The planner
  cannot produce a same-account restart, and a move to the same config dir is
  not actionable.
- `--fallback-model` applies only to `pick` for a brand-new session.
- Only move panes the plan marks as limited. Touching a healthy pane
  needs the user to ask for it explicitly; then use `apply --force --pane <id>`.
- `--nudge ""` resumes without sending the follow-up prompt; use it when the
  user wants to look at a session before it continues.
- The old config dir keeps its copy of the transcript, and the project's
  `memory/` directory does not move with the session. Mention both only if the
  user asks where the session went.
