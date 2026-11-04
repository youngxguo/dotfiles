---
name: setup-audit
description: "Daily read-only audit of the person's actual work (their prompts across every session, the PRs and commits it produced, how they drove Herdr) and of the setup it runs through (Claude seats, Herdr, GitHub, Slack, Linear, cloud routines, launchd jobs, dotfiles, the laptop), ending in a ranked list of improvements. Triggers: 'audit my setup', 'what is wrong with my setup', '/setup-audit'."
---

# Setup Audit

The audit has two halves, and the work comes first.

**The work** is what the person did since the last report: what they asked
for in every session, what shipped, what was thrown away, and where they had
to steer by hand. That's where most of the cost is: a fan-out that overlaps
itself, a correction typed for the fifth time, a PR closed after an evening of
work.

**The setup** is everything the work runs through: the Claude seats, Herdr
workers, GitHub, Slack, Linear, the cloud routines, launchd jobs, dotfiles and
this machine. It drifts a little every day. A seat sits idle while another runs
dry, a worker outlives its PR, a job fails quietly, a branch waits on nobody.

The skill reads both once a day and ends in suggestions ranked by what each
costs. It changes nothing: no fix, no kill, no cleanup, no PR, no commit. A fix
is a line the person runs or a kickoff they order. It belongs to no project:
it reads every repository on the machine the same way and never applies one
repository's rules to the rest.

Budget: about 45 minutes. Skip a read only when its tool is missing from this
seat, and say so in the report.

## 1. What came before

- Read `~/.local/state/setup-audit/declined.md`: one line per suggestion the
  person turned down. Never raise one of those again.
- Read the last seven reports in `~/.local/state/setup-audit/reports/` dated
  before today, so a second run on the same day reads fresh. A finding
  that is still true carries its first date (`since 10-24`). One that has stood
  unacted for seven days moves to the Standing list at the end, one line each,
  and never leads the report.

## 2. Read the work

The window runs from the previous run (the newest stamp in
`~/.local/state/setup-audit/runs/` dated before today) to now, or the last 24
hours when there is none. Quote the person's own words as the evidence.
Paraphrase loses what they meant.

**Sessions.** Run `python3 ${CLAUDE_SKILL_DIR}/sessions.py`. It reads cseat's
history and every session's transcript, leaves out the sessions tools start,
and prints the window's numbers (sessions, peak concurrency, output by model,
compactions, transcripts that are gone), then each session: its seats, topics,
PRs, output, the models the person switched to, and every prompt marked
`typed`, `kickoff`, `handoff` or `command`. Read all of it, not a sample.

Not every `typed` prompt is the person's. A dispatcher session or devbot typing
into a pane through Herdr leaves the same record; those read like a brief about
the person ("Young says go…", "Reply with the single word…"), so count them
apart. Name the sessions whose transcript is gone.

**What it produced.** Use `gh search prs --author=@me --created=">=<window
start>"` across every org, not only the repos Herdr has open, and note each
PR's state. For every PR closed unmerged, find the prompt that closed it and
the ones before it. Also read `git log --author` since the window start in
every repository under `~/Documents/code` (once per repository: sibling
checkouts share one history), the Linear issues the person moved or created,
and the Slack messages they sent (`from:me`, leaving out this audit's own DMs).
When the person files work by tagging themselves in Slack, check each of those
asks against what shipped.

**How they drove Herdr.** Look at how many workers ran at once and what each
was for, how the person addressed workers ("herdr 2"), handoffs between
workers, kickoffs from dispatcher sessions, and workers torn down with no PR.
The script's kickoff and handoff records and a session's topic changes show
these; Herdr keeps no history of what was typed into its panes.

**What the guidance already says.** Before calling a correction unwritten,
grep the places it could live: the skills and rules in dotfiles
(`agents/global-rules.md`, `claude/skills/*`), the repository's `AGENTS.md`
files (a monorepo has several), its skills and the docs they include, and the
seat's memories. Name the place that comes closest.

## 3. Read the setup

Every command here is read-only. Quote the line that is the evidence.

**Claude seats** (`cseat usage --table`, `cseat doctor`, `cseat list`,
`cseat history`, `cseat sessions`, `~/.config/cseat/config.toml`): will the
seats as a whole run out before their resets; a seat with most of its week
unspent while another is near its cap; a seat whose login or `doctor` warns; a
`cseat run` alive for days with no work; the model policy against what the
sessions actually did (the script's model switches, and the `model` in each
seat's `settings.json`); `claude --version` against the newest release.

**Memory** (`~/.claude/projects/*/memory/`): a `MEMORY.md` over the size a
session loads (the session prints the warning); a memory that sends a session
to a file, flag, routine or branch that no longer exists (a `How to apply`
line, or a fact stated as current). Dated history that names something since
deleted ("PR 4745 rewrote `test-perf-cleanup.md`") is still true: leave it.

**Herdr** (`herdr workspace list`, `~/.herdr/worktrees/`): a workspace whose
branch has a merged or closed PR (`gh pr list --head <branch> --state all` in
its repository), or no commits and no agent activity for two days; a worktree
on disk with no workspace; `herdr --version` against the newest release; the
plugins the dotfiles link in.

**Git and GitHub**, for every repository Herdr has open (`gh pr list --author
@me --state open` with checks, review and mergeable state; `gh search prs
--review-requested=@me --state=open`; `gh api notifications`; `git branch
--merged`; `git worktree list`; the person's remote branches with no open PR):
a PR red or stale for days, one waiting on a reviewer who never came, a review
request unanswered, branches and worktrees nothing references, SSH to GitHub
failing (the launchd logs show it).

**Cloud routines** (they live on the login that owns them, `~/.claude` here,
so list them through a headless session on that login):

```bash
env -u CLAUDE_CONFIG_DIR claude -p --dangerously-skip-permissions --model claude-opus-5-5 \
  'Load the RemoteTrigger tool and list every routine: name, enabled, cron, environment, last run time and how it ended. Reply with a table only.'
```

A routine disabled by accident, one failing for days, two on the same minute,
one nobody reads.

**launchd** (every job in `~/Library/LaunchAgents` that is not Apple's or a
vendor updater: `launchctl list`, its log, its run stamps under
`~/.local/state/`): a job with a nonzero last exit, a job that did not run
today, a log repeating the same error, a job that lives only on this machine.

**Slack**, when the Slack tools are loaded in this seat: the last day of every
channel whose name says it carries failures (`*-fail`); mentions of the person
and DMs with no reply; posts of their merged PRs still without the merged mark.

**Linear**, when the Linear tools are loaded: issues assigned to the person in
progress for over two weeks, unread notifications.

**Dotfiles** (the checkout the `~/.claude*/skills` links point into):
`git status -sb` dirty or unpushed; `env -u CLAUDE_CONFIG_DIR python3
install.py --verify-idempotent`; a seat whose settings or rules differ from the
shared copy (`cseat doctor` says `own`).

**The machine** (`df -h /`, `du -sh ~/.cache ~/.herdr/worktrees
~/.claude*/projects`, `docker system df`, the databases in the dev Postgres
containers, `pgrep -fl claude`, `brew outdated`): disk going, databases named
for branches or worktrees that are gone, dev servers and ports held by finished
work, Claude processes nobody owns, tools behind.

## 4. Judge

A finding is something that costs time, money, attention or risk every day it
stays: a seat paid for and unused, an hour a worker loses to a failing job, a PR
rotting, a disk filling. Rank by that cost. A tidy that costs nothing is not a
finding. One cause behind several symptoms is one finding.

In the work, look for patterns across sessions, not single events:
- **A repeated correction:** the person types the same correction in several
  sessions ("deeper cut", "too much machinery", "did we qa?") and no skill,
  rule or memory holds it.
- **Thrown-away work:** a closed PR, or a worker torn down with no PR. Note
  what came before it: an unsettled design, workers overlapping, the person
  losing track.
- **Smooth against rough:** how a well-specified ask went, set against an
  exploratory one.
- **Waiting on the person:** a decision only they can make, or an ask of
  theirs that never landed.

The cost is their attention (prompts and hours spent steering), tokens spent,
and work discarded. Put what went well in two or three lines, so the findings
read against it.

Each finding carries its evidence (the quoted line), what it costs, since when,
and one fix: a command the person runs, a decision they make, or what a kickoff
would do. Prefer the fix that removes the cause (a job, a rule, a default) over
one that clears today's instance.

## 5. Report

Write the report to `~/.local/state/setup-audit/reports/<YYYY-MM-DD>.md`
(`<YYYY-MM-DD>-2.md` when today's exists), then print it in full as the last
message, in this order:

1. **Verdict.** One line on how the work and the setup went, and the one thing
   to do today. It comes from whichever half costs more.
2. **The work.** The window's numbers: prompts, sessions, peak concurrency,
   PRs opened, merged and closed unmerged, and compactions. Then what landed,
   in a few lines, then a ranked table of work findings (`W1`, `W2`, …):
   finding, evidence, cost, fix, since.
3. **The setup.** The same table for the setup.
4. **Notes.** A short paragraph per finding, only where the table row can't
   carry it.
5. **Standing**, then the surfaces skipped and why.
When the Slack tools are loaded, DM the person the verdict, the top three rows
and the report's path.

When the person declines a finding in the pane, append one line to
`~/.local/state/setup-audit/declined.md` with the date and the finding.
