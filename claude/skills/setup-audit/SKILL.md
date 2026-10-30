---
name: setup-audit
description: "Daily read-only audit of the whole work setup (Claude seats, Herdr, GitHub, Slack, Linear, cloud routines, launchd jobs, dotfiles, the laptop) that ends in a ranked list of improvements. Triggers: 'audit my setup', 'what is wrong with my setup', '/setup-audit'."
---

# Setup Audit

Everything the work runs through (the Claude seats, Herdr workers, GitHub,
Slack, Linear, the cloud routines, launchd jobs, dotfiles, this machine) drifts
a little every day: a seat sits idle while another runs dry, a worker outlives
its PR, a job fails quietly, a branch waits on nobody. This skill reads all of
it once a day and ends in suggestions ranked by what each costs. It changes
nothing: no fix, no kill, no cleanup, no PR, no commit. A fix is a line the
person runs or a kickoff they order. It belongs to no project: it reads every
repository on the machine the same way and never applies one repository's
rules to the rest.

Budget: about 30 minutes. Every read below is cheap; skip one only when its
tool is missing from this seat, and say so in the report.

## 1. What came before

- Read `~/.local/state/setup-audit/declined.md`: one line per suggestion the
  person turned down. Never raise one of those again.
- Read the last seven files in `~/.local/state/setup-audit/reports/`. A finding
  that is still true carries its first date (`since 10-24`). One that has stood
  unacted for seven days moves to the Standing list at the end, one line each,
  and never leads the report.

## 2. Read every surface

Every command here is read-only. Quote the line that is the evidence.

**Claude seats** (`cseat usage --table`, `cseat doctor`, `cseat list`,
`cseat history`, `cseat sessions`, `~/.config/cseat/config.toml`): will the
seats as a whole run out before their resets; a seat with most of its week
unspent while another is near its cap; a seat whose login or `doctor` warns; a
`cseat run` alive for days with no work; the model policy against what the
sessions actually did; `claude --version` against the newest release.

**Memory** (`~/.claude/projects/*/memory/`): a `MEMORY.md` over the size a
session loads (the session prints the warning); memories naming files, flags,
routines or branches that no longer exist.

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

## 3. Judge

A finding is something that costs time, money, attention or risk every day it
stays: a seat paid for and unused, an hour a worker loses to a failing job, a PR
rotting, a disk filling. Rank by that cost. A tidy that costs nothing is not a
finding. One cause behind several symptoms is one finding.

Each finding carries its evidence (the quoted line), what it costs, since when,
and one fix: a command the person runs, a decision they make, or what a kickoff
would do. Prefer the fix that removes the cause (a job, a rule, a default) over
one that clears today's instance.

## 4. Report

Write the report to `~/.local/state/setup-audit/reports/<YYYY-MM-DD>.md`, then
print it in full as the last message. Verdict first (one line: how healthy, the
one thing to do today). Then a table, one row per finding, ranked: finding,
evidence, cost, fix, since. Then a short paragraph per finding only where the
table row cannot carry it. Then Standing, then the surfaces skipped and why.
When the Slack tools are loaded, DM the person the verdict, the top three rows
and the report's path.

When the person declines a finding in the pane, append one line to
`~/.local/state/setup-audit/declined.md` with the date and the finding.
