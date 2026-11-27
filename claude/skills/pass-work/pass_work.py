#!/usr/bin/env python3
"""Pass this worktree's work to the Orca on another machine and start Claude on it there."""

from __future__ import annotations

import argparse
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "kickoff"))

from kickoff import close_passed_setup, git, orca  # noqa: E402

BRANCH_NAME = re.compile(r"^[A-Za-z0-9._/-]+$")
SYNC_TIMEOUT = 180
HEAD_MARK = "PASS-HEAD"
HEAD_LINE = re.compile(rf"^{HEAD_MARK} ([0-9a-f]{{40}})$")
DELIVERED = {"journaled", "handed-to-terminal"}
OPENING = (
    "This work was passed to you from the Orca on {source}. Branch {branch} is at"
    " {head} here and on origin: continue on it and push to it.\n\n"
    "This machine may lack a tool, a service or an access the other one has. When"
    " a step needs something missing here, leave that step, say so, and carry on"
    " with the rest.\n\n"
)


def environment(asked: str) -> str:
    """The paired Orca the person means, by its name or any part only it has."""
    names = [e["name"] for e in orca("environment", "list").get("environments") or []]
    close = [n for n in names if n.lower() == asked.lower()] or [
        n for n in names if asked.lower() in n.lower()
    ]
    if len(close) != 1:
        raise SystemExit(
            f"{asked!r} names {'more than one' if close else 'no'} paired Orca;"
            f" the paired ones are: {', '.join(names) or 'none'}"
        )
    return close[0]


def this_machine() -> str:
    hosts = orca("host", "list").get("hosts") or []
    local = next((h for h in hosts if h.get("kind") == "local"), {})
    return local.get("machineName") or "another machine"


def gates(branch: str, is_primary: bool) -> list[str]:
    unmet = []
    if not branch:
        unmet.append("HEAD is detached: check out the branch to pass")
    elif not BRANCH_NAME.match(branch):
        unmet.append(f"branch {branch!r} has characters a pass cannot carry")
    if is_primary:
        unmet.append("this is the main checkout: pass a worktree, not it")
    dirty = git("status", "--porcelain").splitlines()
    if dirty:
        unmet.append(f"{len(dirty)} uncommitted paths: commit what should travel")
    return unmet


def remote_head(branch: str) -> str:
    return git("ls-remote", "origin", f"refs/heads/{branch}").split("\t")[0]


def publish(branch: str, head: str) -> None:
    if remote_head(branch) == head:
        return
    push = subprocess.run(
        ["git", "push", "--quiet", "origin", f"HEAD:refs/heads/{branch}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if push.returncode != 0 or remote_head(branch) != head:
        why = (push.stderr.strip().splitlines() or ["no reason given"])[-1]
        raise SystemExit(
            f"origin/{branch} is not at {head[:12]} and a push failed: {why}"
        )


def run_there(to: str, worktree_id: str, title: str, command: str) -> str | None:
    """Runs `command` in a terminal of that worktree on `to` and returns the commit
    the worktree is on afterwards, or None when it never answered.

    The terminal stays open and prints the commit itself, read from its screen:
    Orca drops a terminal's output once it exits, and its worktree list can lag
    git by more than twenty seconds after a merge."""
    target = ("--environment", to)
    handle = orca(
        "terminal",
        "create",
        "--worktree",
        f"id:{worktree_id}",
        "--title",
        title,
        "--command",
        f'{command}; echo "{HEAD_MARK} $(git rev-parse HEAD)"',
        *target,
    )["terminal"]["handle"]
    deadline = time.monotonic() + SYNC_TIMEOUT
    try:
        while True:
            read = orca("terminal", "read", "--terminal", handle, "--screen", *target)
            for line in reversed((read.get("terminal") or {}).get("tail") or []):
                if answered := HEAD_LINE.match(line.strip()):
                    return answered.group(1)
            if time.monotonic() >= deadline:
                return None
            time.sleep(1)
    finally:
        try:
            orca("terminal", "close", "--terminal", handle, *target)
        except SystemExit:
            pass


def fetch(branch: str) -> str:
    """Another session's git can hold a lock for a moment, so a fetch gets three tries."""
    once = f"git fetch origin {shlex.quote(branch)}"
    return f"({once} || (sleep 3; {once}) || (sleep 3; {once}))"


def sync_command(branch: str, has_worktree: bool) -> str:
    if has_worktree:
        return f"{fetch(branch)} && git diff --quiet HEAD && git merge --ff-only FETCH_HEAD"
    return f"{fetch(branch)} && {drop_if_merged(branch)}"


def drop_if_merged(branch: str) -> str:
    """Deletes a local branch only when the fetched head already holds all of it."""
    ref = shlex.quote(f"refs/heads/{branch}")
    return (
        f"git merge-base --is-ancestor {ref} FETCH_HEAD"
        f" && git branch -D {shlex.quote(branch)}"
    )


def destination(to: str, project: str, branch: str) -> tuple[dict, dict | None]:
    trees = [
        t
        for t in orca("worktree", "list", "--environment", to).get("worktrees") or []
        if t.get("projectId") == project and not t.get("isArchived")
    ]
    primary = next((t for t in trees if t.get("isMainWorktree")), None)
    if primary is None:
        raise SystemExit(f"{to} has no checkout of {project} in Orca")
    on_branch = next(
        (t for t in trees if t.get("branch") == f"refs/heads/{branch}"), None
    )
    return primary, on_branch


def bring(
    to: str, project: str, branch: str, head: str, note: str
) -> tuple[dict, bool]:
    """The worktree on `to` that holds the branch at `head`, and whether it is new."""
    primary, on_branch = destination(to, project, branch)
    target = on_branch or primary
    reached = run_there(
        to, target["id"], f"pass {branch}", sync_command(branch, bool(on_branch))
    )
    if on_branch is not None:
        if reached != head:
            raise SystemExit(
                f"{on_branch['path']} on {to} did not fast-forward to {head[:12]}:"
                " it has commits or changes of its own on this branch, or could not"
                " fetch. Settle it there first"
            )
        there = on_branch
        orca(
            "worktree",
            "set",
            "--worktree",
            f"id:{there['id']}",
            "--comment",
            note,
            "--environment",
            to,
        )
        return there, False
    made = orca(
        "worktree",
        "create",
        "--repo",
        f"id:{primary['repoId']}",
        "--name",
        branch.rsplit("/", 1)[-1],
        "--no-parent",
        "--branch",
        branch,
        "--base-branch",
        f"origin/{branch}",
        "--comment",
        note,
        "--environment",
        to,
        timeout=600,
    )["worktree"]
    opened = (made.get("branch") or "").removeprefix("refs/heads/")
    if opened != branch or made.get("head") != head:
        orca("worktree", "rm", "--worktree", f"id:{made['id']}", "--environment", to)
        if opened != branch and BRANCH_NAME.match(opened):
            run_there(to, primary["id"], f"pass {branch}", drop_if_merged(opened))
        raise SystemExit(
            f"{to} could not open {branch} at {head[:12]}: it has a local branch of"
            " that name with commits of its own, or could not fetch. Settle it"
            " there first"
        )
    return made, True


def launch(to: str, there: dict, prompt: str) -> dict:
    started = orca(
        "agent",
        "launch",
        "--agent",
        "claude",
        "--worktree",
        f"id:{there['id']}",
        "--prompt",
        prompt,
        "--environment",
        to,
        timeout=600,
    )
    outcome = started.get("outcome") or {}
    if not outcome.get("kind"):
        raise SystemExit(f"Claude did not start on {to}; {there['path']} is left there")
    if (started.get("prompt") or {}).get("outcome") not in DELIVERED:
        raise SystemExit(
            f"Claude started on {to} in {there['path']} but the brief did not reach"
            " it: open that session and paste the brief"
        )
    return outcome


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--to", required=True, help="the paired Orca: its name or a part of it"
    )
    parser.add_argument(
        "--brief-file", type=Path, help="the handover, for the next Claude"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="say what a pass would do, and do nothing",
    )
    args = parser.parse_args(argv)
    if not args.dry_run and args.brief_file is None:
        parser.error("--brief-file is required")

    to = environment(args.to)
    current = orca("worktree", "current")["worktree"]
    project = current.get("projectId")
    if not project:
        raise SystemExit(
            "Orca names no project for this checkout, so no other machine can match it"
        )
    branch = git("symbolic-ref", "--short", "-q", "HEAD")
    head = git("rev-parse", "HEAD")
    unmet = gates(branch, bool(current.get("isMainWorktree")))

    if args.dry_run:
        for gate in unmet:
            print(f"not ready: {gate}")
        primary, on_branch = destination(to, project, branch)
        where = (
            on_branch["path"] if on_branch else f"a new worktree of {primary['path']}"
        )
        push = "" if not branch or remote_head(branch) == head else ", after a push"
        print(f"would pass {branch} at {head[:12]} to {to}, in {where}{push}")
        return 0
    if unmet:
        raise SystemExit("; ".join(unmet))
    brief = args.brief_file.read_text().strip()
    if not brief:
        raise SystemExit(f"{args.brief_file} is empty: the brief is the handover")

    source = this_machine()
    publish(branch, head)
    there, created = bring(to, project, branch, head, f"passed from {source}")
    outcome = launch(
        to, there, OPENING.format(source=source, branch=branch, head=head) + brief
    )
    orca(
        "worktree",
        "set",
        "--worktree",
        f"id:{current['id']}",
        "--comment",
        f"passed to {to}",
    )
    # Orca calls a chat a structured session.
    surface = "chat" if outcome["kind"] == "structured" else outcome["kind"]
    if created and surface == "chat":
        close_passed_setup(there["path"], target=("--environment", to))
    print(f"passed {branch} at {head[:12]} to {to}")
    print(f"  worktree: {there['path']}")
    print(f"  {surface}: {outcome.get('sessionId') or outcome.get('handle') or ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
