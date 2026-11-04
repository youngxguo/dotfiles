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
import time
from pathlib import Path

MODEL_ENV = "ANTHROPIC_MODEL"
GRILL = (
    "Before building, settle the shape of this task with the user: invoke the "
    "grilling skill. Cover what a reviewer would need settled: what changes and "
    "what stays, the design choice it turns on, what done looks like, and how it "
    "relates to work already in flight (an open PR, another worker in the same "
    "area). Leave choices you can make while implementing to yourself. Word each "
    "question for someone who hasn't read the code: name things by what the "
    "product does, not by file, line or internal name, and explain a term the "
    "first time it appears. Hold each recommended answer to the bar for a change "
    "in your rules: recommend the change that removes the cause with the least "
    "machinery, and say what you are choosing not to add. Once the user confirms "
    "the shape, build it, and carry the agreed shape into the PR description."
)


def herdr(*args: str, check: bool = True, timeout: int = 60) -> dict:
    proc = subprocess.run(
        ["herdr", *args],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    payload = proc.stdout.strip() or proc.stderr.strip()
    try:
        data = json.loads(payload) if payload else {}
    except ValueError:
        data = {"error": {"message": payload}}
    if proc.returncode != 0 and "error" not in data:
        data["error"] = {"message": payload or f"exit status {proc.returncode}"}
    if check and "error" in data:
        message = (data.get("error") or {}).get("message") or payload
        raise SystemExit(f"herdr {' '.join(args)} failed: {message}")
    return data


def wait_for(predicate, timeout: float, interval: float = 0.5) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False


def pane_screen(pane_id: str) -> str:
    proc = subprocess.run(
        ["herdr", "pane", "read", pane_id, "--source", "visible", "--lines", "60"],
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.stdout


def dismiss_startup_dialogs(pane_id: str, log) -> bool:
    """A config dir shows folder-trust, bypass-permissions and Chrome-extension
    dialogs for a folder it has never opened; herdr classifies them as idle, so
    the screen is the only signal."""
    answered = False
    for _ in range(5):
        screen = pane_screen(pane_id)
        if "Enter to confirm" not in screen:
            return answered
        if "No, exit" in screen:
            # Trust and bypass dialogs start on "No, exit"; the yes is below.
            herdr("pane", "send-keys", pane_id, "down", check=False)
            time.sleep(0.3)
            what = "the folder trust dialog" if "trust" in screen else "a yes/no dialog"
        else:
            what = "a notice"
        herdr("pane", "send-keys", pane_id, "enter", check=False)
        log(f"  confirmed {what}")
        answered = True
        wait_for(lambda: pane_screen(pane_id) != screen, 5)
        time.sleep(1)
    return answered


def settle_agent(pane_id: str, log) -> str:
    """Wait for a freshly launched agent to come to rest, answering the
    first-run dialogs a config dir shows for a folder it has never opened.
    Only idle and blocked count: herdr keeps the record of the claude that
    just quit, marked `done`, until it detects the new one, and a plain wait
    would return that at once."""

    def wait() -> dict:
        return herdr(
            "agent",
            "wait",
            pane_id,
            "--until",
            "idle",
            "--until",
            "blocked",
            "--timeout",
            "90000",
            check=False,
            timeout=120,
        )

    settled = wait()
    if dismiss_startup_dialogs(pane_id, log):
        settled = wait()
    result = settled.get("result") or {}
    status = (result.get("agent") or {}).get("agent_status")
    return status or result.get("status") or "unknown"


def submit_brief(pane_id: str, brief: str, log) -> None:
    """A claude that is still starting up can take the pasted brief but drop
    the Enter after it, leaving the brief unsent in its input box. herdr then
    reports the prompt stalled, and one more Enter sends it."""
    sent = herdr(
        "agent",
        "prompt",
        pane_id,
        brief,
        "--wait",
        "--until",
        "working",
        "--until",
        "blocked",
        "--timeout",
        "15000",
        check=False,
    )
    if "error" not in sent:
        log("  brief sent")
        return
    herdr("pane", "send-keys", pane_id, "enter", check=False)
    if wait_for(lambda: pane_status(pane_id) in ("working", "blocked"), 10):
        log("  brief sent (resubmitted with Enter)")
        return
    message = (sent.get("error") or {}).get("message", "")
    raise SystemExit(f"the brief never started a turn in {pane_id}: {message}")


def pane_status(pane_id: str) -> str | None:
    got = herdr("agent", "get", pane_id, check=False).get("result") or {}
    return (got.get("agent") or {}).get("agent_status")


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
    return parent_workspace(listing["source"]["repo_root"])


def parent_workspace(root: str) -> tuple[list[str], str]:
    """Herdr creates worktrees only from the repo's parent workspace, never a linked one."""
    for workspace in workspaces():
        worktree = workspace.get("worktree") or {}
        if worktree.get("checkout_path") == root and not worktree.get(
            "is_linked_worktree"
        ):
            return ["--workspace", workspace["workspace_id"]], root
    return ["--cwd", root], root


def source_checkout(repo: str | None) -> tuple[list[str], str]:
    """Keep the caller's checkout as the git source, including when --repo names
    this repository; Herdr still creates the worktree from the parent workspace."""
    current = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=False,
    )
    if current.returncode == 0:
        path = current.stdout.strip()
        listing = herdr("worktree", "list", "--cwd", path)["result"]
        root = listing["source"]["repo_root"]
        if not repo or Path(root).name == repo:
            return parent_workspace(root)[0], path
    if repo:
        return main_checkout(repo)
    raise SystemExit(
        "kickoff needs a Git checkout, or --repo for another open repository"
    )


def catch_up(path: str, base: str) -> None:
    """Fast-forward the parent branch to its upstream, so a new worktree never
    starts behind what has already merged. Offline, diverged, or blocked by
    local edits, the local tip stands and the reason goes to stderr."""

    def git(*args: str, cwd: str = path) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["git", "-C", cwd, *args],
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )

    def note(message: str) -> None:
        print(f"Note: {message}; starting from the local {base}.", file=sys.stderr)

    remote = git("config", f"branch.{base}.remote").stdout.strip()
    merge = git("config", f"branch.{base}.merge").stdout.strip()
    if not remote or not merge:
        return
    try:
        fetched = git("fetch", "--quiet", remote, merge).returncode == 0
    except subprocess.TimeoutExpired:
        fetched = False
    if not fetched:
        return note(f"could not fetch {base} from {remote}")
    upstream = git("rev-parse", "FETCH_HEAD").stdout.strip()
    local = git("rev-parse", f"refs/heads/{base}").stdout.strip()
    if git("merge-base", "--is-ancestor", upstream, local).returncode == 0:
        return  # already current, or ahead with unpushed commits
    if git("merge-base", "--is-ancestor", local, upstream).returncode:
        return note(f"{base} has diverged from {remote}")
    listing = git("worktree", "list", "--porcelain").stdout.split("\n\n")
    checkout = next(
        (
            block.split("\n", 1)[0].removeprefix("worktree ")
            for block in listing
            if f"\nbranch refs/heads/{base}\n" in f"{block}\n"
        ),
        None,
    )
    if checkout:
        # The branch is checked out: move its working tree too, which git
        # refuses when local edits touch the incoming files.
        moved = git("merge", "--ff-only", "--quiet", upstream, cwd=checkout)
    else:
        moved = git("update-ref", f"refs/heads/{base}", upstream, local)
    if moved.returncode:
        return note(f"could not fast-forward {base} in {checkout or path}")
    print(f"Fast-forwarded {base} to {upstream[:12]} from {remote}.", file=sys.stderr)


def starting_point(path: str, base: str | None) -> tuple[str, str]:
    """Resolve a local parent branch and pin its commit before creating anything."""
    if not base:
        result = subprocess.run(
            ["git", "-C", path, "symbolic-ref", "--quiet", "--short", "HEAD"],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode:
            raise SystemExit("detached HEAD: pass --base with a local parent branch")
        base = result.stdout.strip()
    catch_up(path, base)
    result = subprocess.run(
        ["git", "-C", path, "rev-parse", "--verify", f"refs/heads/{base}^{{commit}}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode:
        raise SystemExit(f"base {base!r} must name an existing local branch")
    dirty = subprocess.run(
        ["git", "-C", path, "status", "--porcelain"],
        capture_output=True,
        text=True,
        check=True,
    )
    if dirty.stdout:
        print(
            "Note: uncommitted changes stay in the source checkout; only commits are inherited.",
            file=sys.stderr,
        )
    return base, result.stdout.strip()


def record_parent(path: str, branch: str, parent: str) -> None:
    # Native gh pr create setting; separate from the push/pull upstream, which
    # changes when the child is first pushed with git push -u.
    subprocess.run(
        [
            "git",
            "-C",
            path,
            "config",
            "--local",
            f"branch.{branch}.gh-merge-base",
            parent,
        ],
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


def cseat_args(
    subcommand: str,
    to_label: str | None,
    requested_model: str | None,
    task_size: str = "M",
) -> list[str]:
    args = ["cseat", subcommand, "--size", task_size]
    if requested_model:
        args.extend(["--model", requested_model])
    if subcommand == "run":
        args.append("--handoff")
    else:
        args.extend(["--json", "--dry-run"])
    if to_label:
        args.extend(["--seat", to_label])
    return args


def run_in_login_shell(
    args: list[str], timeout: int = 20
) -> subprocess.CompletedProcess:
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
        if to_label:
            raise SystemExit(
                f"--to {to_label!r} names a cseat seat, but cseat is unavailable"
            )
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
    if to_label and "watch only" in detail:
        # cseat pick never lands on a watch-only seat, but cseat run --seat still
        # launches there when a person names it.
        return True
    if not detail:
        lines = (proc.stderr or proc.stdout).strip().splitlines()
        detail = lines[-1] if lines else f"exit {proc.returncode}"
    raise SystemExit(f"cseat cannot start the agent: {detail}")


def plain_claude_command(requested_model: str | None) -> str:
    """Portable fallback for machines without cseat: the default account. Its
    login is only reachable with CLAUDE_CONFIG_DIR unset: setting it, even to
    ~/.claude, gives claude its own .claude.json inside the dir and its own
    `Claude Code-credentials-<hash>` keychain entry, so the session lands on a
    login prompt instead of the subscription."""
    parts = ["env", "-u", "CLAUDE_CONFIG_DIR"]
    if requested_model:
        parts.append(f"{MODEL_ENV}={shlex.quote(requested_model)}")
    return " ".join([*parts, "claude"])


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
        else plain_claude_command(requested_model)
    )
    herdr("pane", "run", pane_id, command)
    log(f"  ran: {command}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("slug", help="short name for the worktree and agent")
    parser.add_argument("brief", nargs="*", help="the user's task")
    parser.add_argument("--brief-file", help="read the task from a file")
    parser.add_argument("--repo", help="use another open repository")
    parser.add_argument(
        "--base", help="local parent branch (default: current checkout's branch)"
    )
    parser.add_argument(
        "--to",
        help="cseat seat to launch on, by the name `cseat list` shows",
    )
    parser.add_argument(
        "--model",
        choices=("fable", "opus"),
        help="Claude model to pin for the new session (default: cseat's policy)",
    )
    parser.add_argument(
        "--size",
        type=str.upper,
        choices=("S", "M", "L"),
        default="M",
        help="task size passed to cseat (default: M)",
    )
    parser.add_argument(
        "--grill",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="have the agent settle the task's shape with the user first, "
        "in a focused workspace (default: on; --no-grill when the shape is pinned)",
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

    print(
        f"{Path(root).name}: {branch} from {parent} ({base_oid[:12]}; {' '.join(target)})"
    )
    opened = herdr(
        "worktree",
        "create",
        *target,
        "--branch",
        branch,
        "--base",
        base_oid,
        "--focus" if args.grill else "--no-focus",
    )["result"]

    workspace_id = opened["workspace"]["workspace_id"]
    pane_id = opened["root_pane"]["pane_id"]
    path = opened["worktree"]["path"]
    record_parent(path, branch, parent)
    brief = (
        f"This branch starts from {parent} ({base_oid}). Use {parent} as the PR base unless the task requires otherwise. "
        "Links in this task (Slack threads, issues, PRs) are context: read them, never reply to them.\n\n"
        + (f"{GRILL}\n\n" if args.grill else "")
        + brief
    )
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

    status = settle_agent(pane_id, log)
    herdr("agent", "rename", pane_id, name, check=False)
    log(f"  agent {name} is {status}")

    if status == "blocked":
        raise SystemExit(f"agent {name} is blocked; task not sent")
    submit_brief(pane_id, brief, log)

    print(f"\n{name}  {branch}  {workspace_id}  {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
