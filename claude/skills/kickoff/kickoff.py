#!/usr/bin/env python3
"""Create an Orca worktree, start Claude in it, and hand it the user's task."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ORCA_APP_BIN = "/Applications/Orca.app/Contents/Resources/bin/orca"
GRILL = (
    "Before building, settle the shape of this task with the user: invoke the "
    "grilling skill. Cover what a reviewer would need settled: what changes and "
    "what stays, the design choice it turns on, what done looks like, and how it "
    "relates to work already in flight (an open PR, another worker in the same "
    "area). When it touches another person's work in flight, name the conflict "
    "to the user and keep going. If the area is one the user hasn't worked in, open with a short "
    "explainer of how it works today, built from the real code and UI, before "
    "the first question. Leave choices you can make while implementing to "
    "yourself. Word each "
    "question for someone who hasn't read the code: name things by what the "
    "product does, not by file, line or internal name, and explain a term the "
    "first time it appears. Hold each recommended answer to the bar for a change "
    "in your rules: recommend the change that removes the cause with the least "
    "machinery, and say what you are choosing not to add. Once the user confirms "
    "the shape, build it, and carry the agreed shape into the PR description."
)


def orca_command() -> str:
    """Orca's CLI. A session Orca started names it in ORCA_CLI_COMMAND. On Linux
    the CLI is `orca-ide`: a bare `orca` there is the GNOME screen reader."""
    name = "orca-ide" if sys.platform.startswith("linux") else "orca"
    found = os.environ.get("ORCA_CLI_COMMAND") or shutil.which(name)
    if not found and Path(ORCA_APP_BIN).is_file():
        found = ORCA_APP_BIN
    if not found:
        raise SystemExit(f"kickoff starts its workers in Orca, and `{name}` is missing")
    return found


def orca(*args: str, timeout: int = 60) -> dict:
    try:
        proc = subprocess.run(
            [orca_command(), *args, "--json"],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        raise SystemExit(f"orca {' '.join(args[:2])} timed out after {timeout}s")
    try:
        answer = json.loads(proc.stdout)
    except ValueError:
        answer = None
    if isinstance(answer, dict) and answer.get("ok"):
        return answer.get("result") or {}
    error = answer.get("error") if isinstance(answer, dict) else None
    why = (
        error.get("message") or error.get("code")
        if isinstance(error, dict)
        else (proc.stderr or proc.stdout).strip()[:300]
    )
    raise SystemExit(
        f"orca {' '.join(args[:2])} failed: {why or f'exit status {proc.returncode}'}"
    )


# What Orca prints in a setup terminal when the repository's setup script
# ends, here with exit status 0.
SETUP_PASSED = re.compile(r"^__ORCA_SETUP_COMPLETE__:[\w-]+:0\s*$", re.MULTILINE)


def close_passed_setup(path: str, wait: float = 10) -> None:
    """Close the Setup tab of a new chat worktree once its setup has passed.

    Orca runs a repository's setup script in a terminal tab, and a worktree
    made through its CLI opens on that tab instead of the chat; the CLI has no
    option for which tab to open on. A setup that fails, or is still running
    after `wait` seconds, keeps its tab."""
    deadline = time.monotonic() + wait
    try:
        while True:
            listed = orca("terminal", "list", "--worktree", f"path:{path}")
            terminals = listed.get("terminals") or []
            for terminal in terminals:
                handle = terminal["handle"]
                read = orca("terminal", "read", "--terminal", handle)
                tail = (read.get("terminal") or {}).get("tail") or []
                if SETUP_PASSED.search("\n".join(tail)):
                    orca("terminal", "close", "--terminal", handle, "--tab")
                    return
            if not terminals or time.monotonic() >= deadline:
                return
            time.sleep(1)
    except (SystemExit, KeyError):
        # The worktree and its agent are already running; the tab just stays.
        return


def slugify(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:32].strip("-")


def git(*args: str) -> str:
    """A git answer about the current checkout, or "" when git has none."""
    proc = subprocess.run(["git", *args], capture_output=True, text=True, check=False)
    return proc.stdout.strip() if proc.returncode == 0 else ""


def repo_selector(repo: str | None) -> str:
    """Another repository by the name Orca knows it by; otherwise the current
    one by its main checkout, the only path of a repository Orca resolves."""
    if repo:
        return f"name:{repo}"
    common = git("rev-parse", "--path-format=absolute", "--git-common-dir")
    if not common:
        raise SystemExit("kickoff needs a Git checkout, or --repo for another one")
    return f"path:{Path(common).parent}"


def default_branch() -> str:
    """The branch Orca starts a worktree from when none is named."""
    return git("symbolic-ref", "--short", "refs/remotes/origin/HEAD").removeprefix(
        "origin/"
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("slug", help="short name for the worktree and its branch")
    parser.add_argument("brief", nargs="*", help="the user's task")
    parser.add_argument("--brief-file", help="read the task from a file")
    parser.add_argument("--repo", help="another repository, by its name in Orca")
    parser.add_argument(
        "--base",
        help="branch to stack on (default: the repository's default branch)",
    )
    parser.add_argument(
        "--model",
        help="Claude model for the new session (default: Orca's Claude command picks)",
    )
    parser.add_argument(
        "--grill",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="have the agent settle the task's shape with the user first "
        "(default: on; --no-grill when the shape is pinned)",
    )

    args = parser.parse_args(argv)
    brief = (
        Path(args.brief_file).read_text() if args.brief_file else " ".join(args.brief)
    )
    slug = slugify(args.slug)
    if not slug:
        raise SystemExit("the slug needs at least one letter or digit")
    if not brief.strip():
        raise SystemExit("kickoff needs a task")

    repo = repo_selector(args.repo)
    if not (orca("status", timeout=30).get("runtime") or {}).get("reachable"):
        raise SystemExit("Orca is not running; open it and run kickoff again")

    parent = args.base or (not args.repo and default_branch()) or ""
    start = (
        f"This branch starts from {parent}. Use {parent} as the PR base"
        if parent
        else "This branch starts from the repository's default branch. Use it as the PR base"
    )
    prompt = (
        f"{start} unless the task requires otherwise. "
        "Links in this task (Slack threads, issues, PRs) are context: read them, never reply to them.\n\n"
        + (f"{GRILL}\n\n" if args.grill else "")
        + brief
    )
    # A stacked worktree keeps Orca's own lineage to the checkout it came from.
    # Without --surface, the person's Orca setting picks chat or terminal.
    create = ["worktree", "create", "--repo", repo, "--name", slug]
    create += ["--base-branch", args.base] if args.base else ["--no-parent"]
    create += ["--model", args.model] if args.model else []
    opened = orca(*create, "--agent", "claude", "--prompt", prompt, timeout=600)

    worktree = opened.get("worktree") or {}
    path = worktree.get("path")
    branch = (worktree.get("branch") or "").removeprefix("refs/heads/")
    started = ((opened.get("launch") or {}).get("outcome") or {}).get("kind")
    if not started:
        raise SystemExit(f"Claude did not start in Orca; the worktree is at {path}")
    if args.base:
        # Native gh pr create setting, separate from the push/pull upstream.
        subprocess.run(
            ["git", "-C", path, "config", f"branch.{branch}.gh-merge-base", args.base],
            check=True,
        )

    # Orca calls a chat a structured session.
    surface = "chat" if started == "structured" else started
    if surface == "chat":
        close_passed_setup(path)
    print(f"{surface}  {branch} from {parent or 'the default branch'}  {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
