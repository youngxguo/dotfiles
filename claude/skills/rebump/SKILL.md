---
name: rebump
description: "Inspect Claude seat usage and move a rate-limited Claude Code session to another subscription without changing its model. Use when asked to rebump, rebalance, move, or check the headroom of Claude sessions or accounts. Prefer cseat for sessions launched through cseat; use the bundled legacy script only for older plain-Claude sessions."
allowed-tools: Bash(cseat *) Bash(python3 ${CLAUDE_SKILL_DIR}/rebump.py *)
---

# Rebump

Use cseat for current sessions. It owns the usage cache, account picker, and
safe handoff flow.

## Check usage

```bash
cseat usage
cseat handoff --list
```

If the user only asks about headroom, report `cseat usage` and stop.

## Move a cseat-managed session

Identify the run with `cseat handoff --list`, then request a handoff by pid or
working directory:

```bash
cseat handoff <pid>
cseat handoff --cwd <path>
cseat handoff --cwd <path> --to claude3
```

Short account labels such as `c3` mean cseat seat `claude3`. Do not stop,
restart, or prompt the Claude child yourself; cseat waits for a safe idle point,
resumes the same session under the new account, and preserves its model.

## Start a new session

Start new Claude sessions under cseat rather than the legacy picker:

```bash
cseat run --handoff --model fable
cseat run --handoff --model opus
cseat run --handoff --model fable --seat claude3
```

The kickoff skill performs this automatically.

## Move a legacy plain-Claude session

A plain Claude session started inside Herdr self-rebumps through the
`StopFailure` hook. That hook exits immediately when `CSEAT_SEAT` is set, so it
cannot race cseat's supervisor. Otherwise it uses the bundled script, which
reads cseat's shared usage cache and performs the legacy transcript-copy and
relaunch flow.

Use the commands below when the automatic hook could not move the session or
when inspecting an older session. Always inspect first:

```bash
python3 ${CLAUDE_SKILL_DIR}/rebump.py plan
```

If a move is requested, apply only the relevant pane or agent when possible:

```bash
python3 ${CLAUDE_SKILL_DIR}/rebump.py apply --pane w2E:p1
python3 ${CLAUDE_SKILL_DIR}/rebump.py apply --agent-index 4
python3 ${CLAUDE_SKILL_DIR}/rebump.py apply --agent-index 4 --expect-project young/logging-middleware
python3 ${CLAUDE_SKILL_DIR}/rebump.py apply --to claude3 --pane w2E:p1
```

`N` in `agent N` is Herdr's live agent index, not an account label. Pass a
named project or branch with `--expect-project` so the script rejects a
conflicting index.

The legacy flow never changes an existing session's model. It copies the
transcript to the target config directory, quits Claude in the pane, resumes
the same session there, handles first-run dialogs, and prompts it to continue.
Do not touch that pane while the move is in progress.

Only move panes marked limited unless the user explicitly requests a healthy
session move; use `apply --force` for that exception. If the script says the
current pane cannot move itself, report the printed command for the user to run
after quitting Claude there.
