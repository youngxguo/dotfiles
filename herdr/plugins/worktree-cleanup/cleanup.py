#!/usr/bin/env python3
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

# herdr's worktrees.directory default; herdr/config.toml does not override it.
WORKTREES_DIR = Path("~/.herdr/worktrees").expanduser()
# Dev stacks started inside a worktree (Temporal workers, servers, bundlers)
# outlive the herdr panes, so give them a moment to shut down cleanly first.
TERM_GRACE_SECONDS = 5.0
KILL_GRACE_SECONDS = 2.0
POLL_INTERVAL_SECONDS = 0.1


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


def process_cwds():
    """Yield (pid, cwd) for every process whose cwd we can read."""
    proc = Path("/proc")
    if proc.is_dir():
        for entry in proc.iterdir():
            if not entry.name.isdigit():
                continue
            try:
                yield int(entry.name), os.readlink(entry / "cwd")
            except OSError:
                continue
        return
    result = subprocess.run(
        ["lsof", "-a", "-d", "cwd", "-F", "pn", "-w"],
        capture_output=True,
        text=True,
        check=False,
    )
    pid = None
    for line in result.stdout.splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("n") and pid is not None:
            yield pid, line[1:]


def parent_pid(pid):
    result = subprocess.run(
        ["ps", "-o", "ppid=", "-p", str(pid)],
        capture_output=True,
        text=True,
        check=False,
    )
    try:
        return int(result.stdout.strip())
    except ValueError:
        return None


def protected_pids():
    """This process and its ancestors: the plugin runner and the herdr server."""
    pids = {os.getpid(), os.getppid()}
    pid = parent_pid(os.getppid())
    while pid and pid > 1 and pid not in pids:
        pids.add(pid)
        pid = parent_pid(pid)
    pids.discard(0)
    return pids


def pids_inside(checkout, entries, protected=frozenset()):
    """Pids from (pid, cwd) entries whose cwd is the checkout or below it."""
    root = os.path.realpath(checkout)
    prefix = root.rstrip(os.sep) + os.sep
    return sorted(
        pid
        for pid, cwd in entries
        if pid not in protected and (cwd == root or cwd.startswith(prefix))
    )


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def send(pids, sig):
    for pid in pids:
        try:
            os.kill(pid, sig)
        except ProcessLookupError:
            continue
        except PermissionError:
            log(f"no permission to signal {pid}")


def wait_for_exit(pids, timeout):
    deadline = time.monotonic() + timeout
    remaining = [pid for pid in pids if alive(pid)]
    while remaining and time.monotonic() < deadline:
        time.sleep(POLL_INTERVAL_SECONDS)
        remaining = [pid for pid in remaining if alive(pid)]
    return remaining


def stop_processes(checkout):
    """Stop everything running inside checkout; return the pids still alive."""
    protected = protected_pids()
    pids = pids_inside(checkout, process_cwds(), protected)
    if not pids:
        return []
    log(f"stopping {len(pids)} process(es) in {checkout}: {pids}")
    send(pids, signal.SIGTERM)
    survivors = wait_for_exit(pids, TERM_GRACE_SECONDS)
    if survivors:
        log(f"killing {survivors}")
        send(survivors, signal.SIGKILL)
        wait_for_exit(survivors, KILL_GRACE_SECONDS)
    # Re-scan so anything spawned meanwhile keeps the checkout alive too.
    return pids_inside(checkout, process_cwds(), protected)


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

    survivors = stop_processes(checkout)
    if survivors:
        reason = f"still running: pids {' '.join(map(str, survivors))}"
        log(f"kept {checkout}: {reason}")
        notify("Worktree kept", f"{checkout.name}: {reason}")
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
