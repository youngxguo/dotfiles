#!/usr/bin/env python3
"""Kick off a piece of work in its own Herdr worktree workspace: branch off the
repo's main checkout, start a coding agent there, hand it the brief."""

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


def split_agent_args(argv: list[str]) -> tuple[list[str], list[str]]:
    """Everything past a bare `--` belongs to the agent. argparse cannot do
    this itself: REMAINDER after a variadic positional swallows our own
    options too, which silently turns a --dry-run into a real run."""
    if "--" in argv:
        split = argv.index("--")
        return argv[:split], argv[split + 1 :]
    return argv, []


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


def main_checkout(
    repo: str | None, workspace: str | None, cwd: str | None
) -> tuple[list[str], str, list[dict]]:
    """Worktree actions must start from the repo's parent workspace, never from
    a linked worktree. Returns the herdr target flags, the repo root, and the
    repo's worktrees - they belong to the repo, so one listing serves every
    workspace in it."""
    if repo:
        hits = [
            w
            for w in workspaces()
            if (w.get("worktree") or {}).get("repo_name") == repo
            and not (w.get("worktree") or {}).get("is_linked_worktree")
        ]
        if not hits:
            raise SystemExit(f"no open workspace holds the main checkout of {repo!r}")
        target = ["--workspace", hits[0]["workspace_id"]]
        listing = herdr("worktree", "list", *target)["result"]
        return (
            target,
            (hits[0].get("worktree") or {})["repo_root"],
            listing["worktrees"],
        )

    where = (
        ["--workspace", workspace] if workspace else ["--cwd", cwd or str(Path.cwd())]
    )
    listing = herdr("worktree", "list", *where)["result"]
    root = listing["source"]["repo_root"]
    for w in workspaces():
        wt = w.get("worktree") or {}
        if wt.get("checkout_path") == root and not wt.get("is_linked_worktree"):
            return ["--workspace", w["workspace_id"]], root, listing["worktrees"]
    return ["--cwd", root], root, listing["worktrees"]


def branch_prefix(root: str) -> str:
    email = subprocess.run(
        ["git", "-C", root, "config", "user.email"],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()
    return slugify(email.split("@")[0]) if email else ""


def existing_worktree(worktrees: list[dict], branch: str) -> dict | None:
    return next((wt for wt in worktrees if wt.get("branch") == branch), None)


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


def launch_claude(pane_id: str, to: str | None, extra: list[str], log) -> str:
    """Never start claude on the default account without asking rebump: it is
    often the spent one, and the session would stall on the limit message."""
    account, model, prefix = rebump.launch_choice(rebump.read_accounts(), to)
    command = " ".join([prefix, "claude", *extra])
    log(f"  account {account.label}{f' on {model}' if model else ''}")
    herdr("pane", "run", pane_id, command)
    log(f"  ran: {command}")
    return account.label


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "slug", help="short name for the work; becomes the branch and agent name"
    )
    parser.add_argument("brief", nargs="*", help="the first prompt for the agent")
    parser.add_argument("--brief-file", help="read the brief from a file instead")
    parser.add_argument(
        "--repo",
        help="kick off in this repo's main checkout instead of the current one",
    )
    parser.add_argument(
        "--workspace", help="source workspace id (default: the current one)"
    )
    parser.add_argument("--cwd", help="source path instead of a workspace")
    parser.add_argument("--branch", help="full branch name (default: <user>/<slug>)")
    parser.add_argument("--base", help="branch off this ref instead of HEAD")
    parser.add_argument("--name", help="agent name (default: the slug)")
    parser.add_argument("--kind", default="claude", help="agent kind (default: claude)")
    parser.add_argument(
        "--no-agent", action="store_true", help="open the worktree workspace only"
    )
    parser.add_argument("--to", help="pin the claude account rebump picks")
    parser.add_argument(
        "--focus", action="store_true", help="switch to the new workspace"
    )
    parser.add_argument(
        "--trust-repository",
        action="store_true",
        help="trust a repo herdr has not been pointed at before",
    )
    parser.add_argument(
        "--wait",
        action="store_true",
        help="wait for the agent to settle after the brief",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="reuse a worktree that already hosts an agent",
    )
    parser.add_argument("--dry-run", action="store_true")

    argv, extra = split_agent_args(list(sys.argv[1:]) if argv is None else list(argv))
    args = parser.parse_args(argv)
    brief = (
        Path(args.brief_file).read_text() if args.brief_file else " ".join(args.brief)
    )
    slug = slugify(args.slug)
    if not slug:
        raise SystemExit("the slug needs at least one letter or digit")

    target, root, worktrees = main_checkout(args.repo, args.workspace or None, args.cwd)
    prefix = branch_prefix(root)
    branch = args.branch or (f"{prefix}/{slug}" if prefix else slug)
    log = print

    print(f"{Path(root).name}: {branch} ({' '.join(target)})")
    if args.dry_run:
        print(
            f"  would create the worktree and start {args.kind} as {args.name or slug}"
        )
        return 0

    flags = [
        *target,
        "--branch",
        branch,
        "--focus" if args.focus else "--no-focus",
        *(["--trust-repository"] if args.trust_repository else []),
    ]
    known = existing_worktree(worktrees, branch)
    if known:
        log(f"  worktree exists at {known['path']}; opening it")
        opened = herdr("worktree", "open", *flags)["result"]
    else:
        base = ["--base", args.base] if args.base else []
        opened = herdr("worktree", "create", *flags, *base)["result"]

    workspace_id = opened["workspace"]["workspace_id"]
    pane_id = opened["root_pane"]["pane_id"]
    path = opened["worktree"]["path"]
    log(f"  workspace {workspace_id} pane {pane_id} at {path}")

    occupant = pane_agent(pane_id)
    if occupant and not args.force:
        raise SystemExit(
            f"{occupant} is already running in {pane_id}; prompt it directly or pass --force"
        )

    if not wait_for(lambda: shell_ready(pane_id), 20):
        raise SystemExit(
            f"the shell in {pane_id} never reached a prompt; {workspace_id} is open at {path}"
        )

    if args.no_agent:
        print(f"\n{branch}  {workspace_id}  {pane_id}  {path}")
        return 0

    name = args.name or agent_name(slug)
    if args.kind == "claude":
        launch_claude(pane_id, args.to, extra, log)
        if not wait_for(lambda: pane_agent(pane_id) == "claude", 60):
            raise SystemExit(
                f"herdr never detected claude in {pane_id}; {workspace_id} is open at {path}"
            )
    else:
        herdr(
            "agent",
            "start",
            name,
            "--kind",
            args.kind,
            "--pane",
            pane_id,
            *(["--", *extra] if extra else []),
            check=False,
            timeout=120,
        )

    status = rebump.settle_agent(pane_id, log)
    herdr("agent", "rename", pane_id, name, check=False)
    log(f"  agent {name} is {status}")

    if brief.strip():
        if status == "blocked":
            log("  agent is waiting on a dialog; brief not sent")
        else:
            herdr(
                "agent",
                "prompt",
                pane_id,
                brief,
                *(["--wait", "--timeout", "600000"] if args.wait else []),
                check=False,
                timeout=660,
            )
            log("  brief sent")

    print(f"\n{name}  {branch}  {workspace_id}  {path}")
    print(
        f"check on it: herdr agent get {name} | herdr agent read {name} --source recent-unwrapped --lines 120"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
