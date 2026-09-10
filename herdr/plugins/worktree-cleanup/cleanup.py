#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from pathlib import Path

# herdr's worktrees.directory default; herdr/config.toml does not override it.
WORKTREES_DIR = Path("~/.herdr/worktrees").expanduser()


def log(message):
    print(message, flush=True)


def notify(title, body):
    herdr = os.environ.get("HERDR_BIN_PATH", "herdr")
    subprocess.run(
        [herdr, "notification", "show", title, "--body", body],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def find_worktree(node):
    if isinstance(node, dict):
        if "checkout_path" in node and "is_linked_worktree" in node:
            return node
        for value in node.values():
            found = find_worktree(value)
            if found:
                return found
    elif isinstance(node, list):
        for value in node:
            found = find_worktree(value)
            if found:
                return found
    return None


def main():
    try:
        event = json.loads(os.environ.get("HERDR_PLUGIN_EVENT_JSON", ""))
    except json.JSONDecodeError:
        log("no event json")
        return 0

    worktree = find_worktree(event)
    if not worktree:
        log("no worktree provenance on closed workspace")
        return 0
    if not worktree.get("is_linked_worktree"):
        log("primary checkout, not a linked worktree")
        return 0

    checkout = Path(worktree["checkout_path"])
    repo_root = Path(worktree.get("repo_root") or checkout)
    try:
        checkout.resolve().relative_to(WORKTREES_DIR.resolve())
    except ValueError:
        log(f"{checkout} is outside {WORKTREES_DIR}, leaving it")
        return 0
    if not checkout.exists():
        log(f"{checkout} already gone")
        return 0

    result = subprocess.run(
        ["git", "-C", str(repo_root), "worktree", "remove", str(checkout)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        log(f"removed {checkout}")
        notify("Worktree removed", str(checkout))
        return 0
    reason = (result.stderr or result.stdout).strip().splitlines()
    reason = reason[-1] if reason else f"git exited {result.returncode}"
    log(f"kept {checkout}: {reason}")
    notify("Worktree kept", f"{checkout.name}: {reason}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
