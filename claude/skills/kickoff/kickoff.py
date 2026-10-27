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

DEFAULT_CONFIG_DIR = Path.home() / ".claude"
MODEL_ENV = "ANTHROPIC_MODEL"


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


def normalize_config_dir(raw: str | None) -> str:
    if not raw:
        return str(DEFAULT_CONFIG_DIR.resolve())
    return str(Path(os.path.expandvars(os.path.expanduser(raw))).resolve())


def launch_prefix(config_dir: str, model: str | None = None) -> str:
    """The environment a claude session starts under. The default account is
    only reachable with CLAUDE_CONFIG_DIR unset: setting it, even to ~/.claude,
    gives claude its own .claude.json inside the dir and its own `Claude
    Code-credentials-<hash>` keychain entry, so the session lands on a login
    prompt instead of the subscription."""
    default = not config_dir or config_dir == normalize_config_dir(None)
    unset = ["CLAUDE_CONFIG_DIR"] if default else []
    assign = [] if unset else [f"CLAUDE_CONFIG_DIR={shlex.quote(config_dir)}"]
    if model:
        assign.append(f"{MODEL_ENV}={shlex.quote(model)}")
    parts = ["env " + " ".join(f"-u {name}" for name in unset)] if unset else []
    return " ".join([*parts, *assign])


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
    args = ["cseat", subcommand, "--size", task_size]
    if requested_model:
        args.extend(["--model", requested_model])
    if subcommand == "run":
        args.append("--handoff")
    else:
        args.extend(["--json", "--dry-run"])
    if to_label:
        args.extend(["--seat", cseat_name(to_label)])
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
        seat = cseat_name(to_label) if to_label else "claude"
        if seat != "claude" and not re.fullmatch(r"claude\d+", seat):
            raise SystemExit(
                f"account {to_label!r} needs cseat, but cseat is unavailable"
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


def plain_claude_command(to_label: str | None, requested_model: str | None) -> str:
    """Portable single-account fallback for machines without cseat."""
    seat = cseat_name(to_label) if to_label else "claude"
    if seat == "claude":
        config_dir = normalize_config_dir(None)
    else:
        number = re.fullmatch(r"claude(\d+)", seat)
        if not number:
            raise SystemExit(f"account {to_label!r} needs cseat")
        config_dir = normalize_config_dir(f"~/.claude{number.group(1)}")
    prefix = launch_prefix(config_dir, requested_model)
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
    parser.add_argument(
        "--base", help="local parent branch (default: current checkout's branch)"
    )
    parser.add_argument(
        "--to",
        help="Claude account to use, by cusage label or alias such as c3",
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

    status = settle_agent(pane_id, log)
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
