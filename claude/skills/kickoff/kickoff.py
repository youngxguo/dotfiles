#!/usr/bin/env python3
"""Create a Herdr worktree, start an agent, and hand it the user's task."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "rebump"))
try:
    import rebump
except ImportError as exc:  # the account picker lives there
    raise SystemExit(f"the rebump skill must sit beside this one: {exc}")

herdr = rebump.herdr
wait_for = rebump.wait_for

NAME_RE = re.compile(r"[a-z][a-z0-9_-]{0,31}\Z")


def slugify(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:32].strip("-")


def agent_name(slug: str) -> str:
    name = slug if NAME_RE.match(slug) else f"a{slug}"[:32].strip("-")
    live = {a.get("name") for a in herdr("agent", "list")["result"]["agents"]}
    if name not in live:
        return name
    for n in range(2, len(live) + 3):  # only live agents can collide
        candidate = f"{name[: 30 - len(str(n))]}-{n}"
        if candidate not in live:
            return candidate
    raise SystemExit(f"no free agent name near {name!r}")


def workspaces() -> list[dict]:
    return herdr("workspace", "list")["result"]["workspaces"]


def main_checkout(repo: str | None) -> tuple[list[str], str]:
    """Resolve worktree actions to the repo's main checkout."""
    if repo:
        hits = [
            w
            for w in workspaces()
            if (w.get("worktree") or {}).get("repo_name") == repo
            and not (w.get("worktree") or {}).get("is_linked_worktree")
        ]
        if not hits:
            raise SystemExit(f"no open workspace holds the main checkout of {repo!r}")
        workspace = hits[0]
        return (
            ["--workspace", workspace["workspace_id"]],
            (workspace.get("worktree") or {})["repo_root"],
        )

    listing = herdr("worktree", "list", "--cwd", str(Path.cwd()))["result"]
    root = listing["source"]["repo_root"]
    for workspace in workspaces():
        worktree = workspace.get("worktree") or {}
        if worktree.get("checkout_path") == root and not worktree.get(
            "is_linked_worktree"
        ):
            return ["--workspace", workspace["workspace_id"]], root
    return ["--cwd", root], root


def branch_prefix(root: str) -> str:
    email = subprocess.run(
        ["git", "-C", root, "config", "user.email"],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()
    return slugify(email.split("@")[0]) if email else ""


def shell_ready(pane_id: str) -> bool:
    info = (
        herdr("pane", "process-info", "--pane", pane_id, check=False).get("result")
        or {}
    ).get("process_info") or {}
    shell = info.get("shell_pid")
    running = [
        p for p in info.get("foreground_processes") or [] if p.get("pid") != shell
    ]
    return bool(shell) and not running


def pane_agent(pane_id: str) -> str | None:
    got = herdr("agent", "get", pane_id, check=False).get("result") or {}
    return (got.get("agent") or {}).get("agent")


def launch_claude(pane_id: str, log) -> str:
    """Start Claude on the account rebump chooses."""
    account, model, prefix = rebump.launch_choice(rebump.read_accounts(), None)
    command = " ".join([prefix, "claude"])
    log(f"  account {account.label}{f' on {model}' if model else ''}")
    herdr("pane", "run", pane_id, command)
    log(f"  ran: {command}")
    return account.label


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("slug", help="short name for the worktree and agent")
    parser.add_argument("brief", nargs="*", help="the user's task")
    parser.add_argument("--brief-file", help="read the task from a file")
    parser.add_argument("--repo", help="use another open repository")

    args = parser.parse_args(argv)
    brief = (
        Path(args.brief_file).read_text() if args.brief_file else " ".join(args.brief)
    )
    slug = slugify(args.slug)
    if not slug:
        raise SystemExit("the slug needs at least one letter or digit")
    if not brief.strip():
        raise SystemExit("kickoff needs a task")

    target, root = main_checkout(args.repo)
    prefix = branch_prefix(root)
    branch = f"{prefix}/{slug}" if prefix else slug
    log = print

    print(f"{Path(root).name}: {branch} ({' '.join(target)})")
    opened = herdr(
        "worktree",
        "create",
        *target,
        "--branch",
        branch,
        "--no-focus",
    )["result"]

    workspace_id = opened["workspace"]["workspace_id"]
    pane_id = opened["root_pane"]["pane_id"]
    path = opened["worktree"]["path"]
    log(f"  workspace {workspace_id} pane {pane_id} at {path}")

    if not wait_for(lambda: shell_ready(pane_id), 20):
        raise SystemExit(
            f"the shell in {pane_id} never reached a prompt; {workspace_id} is open at {path}"
        )

    name = agent_name(slug)
    launch_claude(pane_id, log)
    if not wait_for(lambda: pane_agent(pane_id) == "claude", 60):
        raise SystemExit(
            f"herdr never detected claude in {pane_id}; {workspace_id} is open at {path}"
        )

    status = rebump.settle_agent(pane_id, log)
    herdr("agent", "rename", pane_id, name, check=False)
    log(f"  agent {name} is {status}")

    if status == "blocked":
        raise SystemExit(f"agent {name} is blocked; task not sent")
    herdr("agent", "prompt", pane_id, brief, check=False)
    log("  brief sent")

    print(f"\n{name}  {branch}  {workspace_id}  {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
