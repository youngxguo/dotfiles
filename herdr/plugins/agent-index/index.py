#!/usr/bin/env python3
"""Keep Agent sidebar numbers aligned with cmd+1..9 (Herdr's focus_agent).

focus_agent indexes agents in Herdr's raw workspace order, but the sidebar
draws linked worktrees under their source workspace. A worktree created for
any workspace other than the last one is therefore shown in one place and
bound to a key somewhere else. Moving each worktree group back behind its
parent makes the raw order match what the sidebar shows, so the numbers below,
cmd+N and prefix+shift+N all agree.
"""

import fcntl
import json
import os
import socket
import subprocess
import tempfile
import time

SOURCE = "young.agent-index"
FAILURES = (
    OSError,
    RuntimeError,
    subprocess.CalledProcessError,
    KeyError,
    TypeError,
    ValueError,
)
TOKEN = "num"


def herdr_bin():
    return os.environ.get("HERDR_BIN_PATH", "herdr")


def herdr_json(*args):
    output = subprocess.check_output(
        [herdr_bin(), *args], text=True, stderr=subprocess.DEVNULL
    )
    return json.loads(output)["result"]


def socket_call(method, params):
    # The CLI has no workspace move command, so this one goes over the socket.
    with socket.socket(socket.AF_UNIX) as conn:
        conn.settimeout(5)
        conn.connect(os.environ["HERDR_SOCKET_PATH"])
        request = {"id": SOURCE, "method": method, "params": params}
        conn.sendall((json.dumps(request) + "\n").encode())
        with conn.makefile() as reader:
            response = json.loads(reader.readline())
    if "error" in response:
        raise RuntimeError(response["error"])
    return response["result"]


def group_parent(workspace, workspaces):
    """The workspace the sidebar nests a linked worktree under, if it is open."""
    worktree = workspace.get("worktree") or {}
    if not worktree.get("is_linked_worktree"):
        return None
    for candidate in workspaces:
        info = candidate.get("worktree") or {}
        if not info.get("is_linked_worktree") and info.get("repo_key") == worktree.get(
            "repo_key"
        ):
            return candidate["workspace_id"]
    return None


def next_regroup(workspaces):
    """The first move_block that brings a worktree group back behind its parent.

    Returns (children, anchor) or None once every group is contiguous. An anchor
    of None means the end of the list.
    """
    ids = [w["workspace_id"] for w in workspaces]
    children = {}
    for workspace in workspaces:
        parent = group_parent(workspace, workspaces)
        if parent is not None:
            children.setdefault(parent, []).append(workspace["workspace_id"])
    for parent in ids:
        block = children.get(parent)
        if not block:
            continue
        start = ids.index(parent) + 1
        if ids[start : start + len(block)] == block:
            continue
        rest = [i for i in ids if i not in block]
        after = rest.index(parent) + 1
        return block, rest[after] if after < len(rest) else None
    return None


def regroup_worktrees():
    workspaces = herdr_json("workspace", "list")["workspaces"]
    # Each move fixes one group; the bound only guards against a server that
    # will not take the order we ask for.
    for _ in range(len(workspaces)):
        move = next_regroup(workspaces)
        if move is None:
            return
        block, anchor = move
        params = {"workspace_ids": block}
        if anchor is not None:
            params["before_workspace_id"] = anchor
        workspaces = socket_call("workspace.move_block", params)["workspaces"]


def wanted_numbers(agents, panes):
    """Map pane id -> number, or None to clear a stale one."""
    wanted = {}
    for index, agent in enumerate(agents, 1):
        if agent.get("pane_id"):
            wanted[agent["pane_id"]] = str(index) if index <= 9 else None
    # Panes whose agent exited keep the number they last had; clear those too.
    for pane in panes:
        if pane["pane_id"] not in wanted:
            wanted[pane["pane_id"]] = None
    current = {p["pane_id"]: (p.get("tokens") or {}).get(TOKEN) for p in panes}
    for agent in agents:
        current.setdefault(agent.get("pane_id"), (agent.get("tokens") or {}).get(TOKEN))
    return {
        pane_id: number
        for pane_id, number in wanted.items()
        if current.get(pane_id) != number
    }


def renumber():
    agents = herdr_json("agent", "list")["agents"]
    panes = herdr_json("pane", "list")["panes"]
    seq = str(time.time_ns())
    for pane_id, number in wanted_numbers(agents, panes).items():
        command = [herdr_bin(), "pane", "report-metadata", pane_id]
        command += ["--source", SOURCE, "--seq", seq]
        if number is None:
            command += ["--clear-token", TOKEN]
        else:
            command += ["--token", f"{TOKEN}={number}"]
        subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )


def locked():
    """Serialize runs: events arrive in bursts and each run must see the last
    run's result, or an older listing can overwrite a newer one."""
    state_dir = os.environ.get("HERDR_PLUGIN_STATE_DIR") or tempfile.gettempdir()
    os.makedirs(state_dir, exist_ok=True)
    handle = open(os.path.join(state_dir, "index.lock"), "w")
    fcntl.flock(handle, fcntl.LOCK_EX)
    return handle


def main():
    with locked():
        for step in (regroup_worktrees, renumber):
            try:
                step()
            except FAILURES:
                continue


if __name__ == "__main__":
    main()
