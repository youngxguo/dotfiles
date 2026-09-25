#!/usr/bin/env python3
"""Create a Herdr worktree, start an agent, and hand it the user's task."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
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


def source_checkout(repo: str | None) -> tuple[list[str], str]:
    """Keep the caller's checkout, including when --repo names this repository."""
    current = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True, text=True, check=False,
    )
    if current.returncode == 0:
        path = current.stdout.strip()
        listing = herdr("worktree", "list", "--cwd", path)["result"]
        if not repo or Path(listing["source"]["repo_root"]).name == repo:
            return ["--cwd", path], path
    if repo:
        return main_checkout(repo)
    raise SystemExit("kickoff needs a Git checkout, or --repo for another open repository")


def starting_point(path: str, base: str | None) -> tuple[str, str]:
    """Resolve a local parent branch and pin its commit before creating anything."""
    if not base:
        result = subprocess.run(
            ["git", "-C", path, "symbolic-ref", "--quiet", "--short", "HEAD"],
            capture_output=True, text=True, check=False,
        )
        if result.returncode:
            raise SystemExit("detached HEAD: pass --base with a local parent branch")
        base = result.stdout.strip()
    result = subprocess.run(
        ["git", "-C", path, "rev-parse", "--verify", f"refs/heads/{base}^{{commit}}"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode:
        raise SystemExit(f"base {base!r} must name an existing local branch")
    dirty = subprocess.run(
        ["git", "-C", path, "status", "--porcelain"],
        capture_output=True, text=True, check=True,
    )
    if dirty.stdout:
        print("Note: uncommitted changes stay in the source checkout; only commits are inherited.", file=sys.stderr)
    return base, result.stdout.strip()


def record_parent(path: str, branch: str, parent: str) -> None:
    # Native gh pr create setting; separate from the push/pull upstream, which
    # changes when the child is first pushed with git push -u.
    subprocess.run(
        ["git", "-C", path, "config", "--local", f"branch.{branch}.gh-merge-base", parent],
        check=True,
    )


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


def cseat_name(label: str) -> str:
    """Translate the short account aliases the skill has historically accepted."""
    if label in {"c1", "claude1", "default"}:
        return "claude"
    match = re.fullmatch(r"c(\d+)", label)
    return f"claude{match.group(1)}" if match else label


def cseat_args(
    subcommand: str,
    to_label: str | None,
    requested_model: str | None,
    task_size: str = "M",
) -> list[str]:
    model = requested_model or "fable"
    args = ["cseat", subcommand, "--model", model, "--size", task_size]
    if subcommand == "run":
        args.append("--handoff")
    else:
        args.extend(["--json", "--dry-run"])
    if to_label:
        args.extend(["--seat", cseat_name(to_label)])
    return args


def run_in_login_shell(args: list[str], timeout: int = 20) -> subprocess.CompletedProcess:
    """Run a command that may be provided by the user's interactive shell."""
    shell = os.environ.get("SHELL") or "/bin/zsh"
    try:
        return subprocess.run(
            [shell, "-ic", shlex.join(args)],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            stdin=subprocess.DEVNULL,
        )
    except subprocess.TimeoutExpired:
        raise SystemExit(f"{' '.join(args[:2])} timed out after {timeout}s")
    except OSError as exc:
        raise SystemExit(f"could not run {shell}: {exc}")


def cseat_available() -> bool:
    return run_in_login_shell(["command", "-v", "cseat"]).returncode == 0


def preflight_cseat(
    to_label: str | None, requested_model: str | None, task_size: str = "M"
) -> bool:
    """Check cseat before changing the repo; false uses the portable fallback."""
    if not cseat_available():
        seat = cseat_name(to_label) if to_label else "claude"
        if seat != "claude" and not re.fullmatch(r"claude\d+", seat):
            raise SystemExit(f"account {to_label!r} needs cseat, but cseat is unavailable")
        return False

    args = cseat_args("pick", to_label, requested_model, task_size)
    proc = run_in_login_shell(args)
    if proc.returncode == 0:
        return True
    detail = ""
    try:
        detail = json.loads(proc.stdout).get("reason", "")
    except (AttributeError, json.JSONDecodeError):
        pass
    if not detail:
        lines = (proc.stderr or proc.stdout).strip().splitlines()
        detail = lines[-1] if lines else f"exit {proc.returncode}"
    raise SystemExit(f"cseat cannot start the agent: {detail}")


def plain_claude_command(to_label: str | None, requested_model: str | None) -> str:
    """Portable single-account fallback for machines without cseat."""
    seat = cseat_name(to_label) if to_label else "claude"
    if seat == "claude":
        config_dir = rebump.normalize_config_dir(None)
    else:
        number = re.fullmatch(r"claude(\d+)", seat)
        if not number:
            raise SystemExit(f"account {to_label!r} needs cseat")
        config_dir = rebump.normalize_config_dir(f"~/.claude{number.group(1)}")
    prefix = rebump.launch_prefix(config_dir, requested_model or "fable")
    return " ".join([prefix, "claude"])


def launch_claude(
    pane_id: str,
    log,
    to_label: str | None = None,
    requested_model: str | None = None,
    use_cseat: bool = True,
    task_size: str = "M",
) -> None:
    """Start Claude with cseat handoffs, or directly when cseat is absent."""
    command = (
        shlex.join(cseat_args("run", to_label, requested_model, task_size))
        if use_cseat
        else plain_claude_command(to_label, requested_model)
    )
    herdr("pane", "run", pane_id, command)
    log(f"  ran: {command}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("slug", help="short name for the worktree and agent")
    parser.add_argument("brief", nargs="*", help="the user's task")
    parser.add_argument("--brief-file", help="read the task from a file")
    parser.add_argument("--repo", help="use another open repository")
    parser.add_argument("--base", help="local parent branch (default: current checkout's branch)")
    parser.add_argument(
        "--to",
        help="Claude account to use, by cusage label or alias such as c3",
    )
    parser.add_argument(
        "--model",
        choices=("fable", "opus"),
        help="Claude model to pin for the new session (default: fable)",
    )
    parser.add_argument(
        "--size",
        type=str.upper,
        choices=("S", "M", "L"),
        default="M",
        help="task size passed to cseat (default: M)",
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

    use_cseat = preflight_cseat(args.to, args.model, args.size)
    target, root = source_checkout(args.repo)
    parent, base_oid = starting_point(root, args.base)
    prefix = branch_prefix(root)
    branch = f"{prefix}/{slug}" if prefix else slug
    log = print

    print(f"{Path(root).name}: {branch} from {parent} ({base_oid[:12]}; {' '.join(target)})")
    opened = herdr(
        "worktree",
        "create",
        *target,
        "--branch",
        branch,
        "--base",
        base_oid,
        "--no-focus",
    )["result"]

    workspace_id = opened["workspace"]["workspace_id"]
    pane_id = opened["root_pane"]["pane_id"]
    path = opened["worktree"]["path"]
    record_parent(path, branch, parent)
    brief = f"This branch starts from {parent} ({base_oid}). Use {parent} as the PR base unless the task requires otherwise.\n\n{brief}"
    log(f"  workspace {workspace_id} pane {pane_id} at {path}")

    if not wait_for(lambda: shell_ready(pane_id), 20):
        raise SystemExit(
            f"the shell in {pane_id} never reached a prompt; {workspace_id} is open at {path}"
        )

    name = agent_name(slug)
    launch_claude(pane_id, log, args.to, args.model, use_cseat, args.size)
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
