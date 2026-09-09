#!/usr/bin/env python3
"""herdr plugin action: open the focused pane's pull request in the browser.

resolves the pane herdr invoked the action for (HERDR_PANE_ID, else the
current pane), takes its foreground working directory, and runs
`gh pr view --web` there, which opens the PR for the checked-out branch. a
pane with no PR gets a herdr notification instead of a browser tab.
"""

import json
import os
import subprocess
import sys

HERDR = os.environ.get("HERDR_BIN_PATH", "herdr")
# herdr launches plugin commands with a minimal PATH; gh lives in one of these.
EXTRA_PATH = (
    os.path.expanduser("~/.local/bin"),
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/home/linuxbrew/.linuxbrew/bin",
)


def notify(title, body):
    subprocess.run(
        [HERDR, "notification", "show", title, "--body", body],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def herdr_json(*args):
    out = subprocess.check_output([HERDR, *args], text=True, stderr=subprocess.DEVNULL)
    return json.loads(out)


def find_key(node, keys):
    """Depth-first search for the first present key in a herdr JSON reply."""
    if isinstance(node, dict):
        for key in keys:
            if node.get(key):
                return node[key]
        for value in node.values():
            found = find_key(value, keys)
            if found:
                return found
    elif isinstance(node, list):
        for value in node:
            found = find_key(value, keys)
            if found:
                return found
    return None


def pane_cwd():
    """The invoked pane's working directory.

    herdr sets HERDR_PANE_ID when the action runs against a pane (its
    right-click menu). from a keybinding or the CLI there is only the context
    JSON, whose focused_pane_cwd is the pane the user is looking at.
    """
    pane_id = os.environ.get("HERDR_PANE_ID")
    if pane_id:
        try:
            reply = herdr_json("pane", "get", pane_id)
        except (subprocess.CalledProcessError, OSError, ValueError):
            reply = {}
        cwd = find_key(reply, ("foreground_cwd", "cwd"))
        if cwd:
            return cwd
    try:
        context = json.loads(os.environ.get("HERDR_PLUGIN_CONTEXT_JSON") or "{}")
    except ValueError:
        context = {}
    cwd = find_key(context, ("focused_pane_cwd", "workspace_cwd"))
    if cwd:
        return cwd
    try:
        reply = herdr_json("pane", "current")
    except (subprocess.CalledProcessError, OSError, ValueError):
        return None
    return find_key(reply, ("foreground_cwd", "cwd"))


def main():
    cwd = pane_cwd()
    if not cwd or not os.path.isdir(cwd):
        notify("Open PR", "Could not find the pane's working directory")
        return 1
    os.environ["PATH"] = os.pathsep.join((*EXTRA_PATH, os.environ.get("PATH", "")))
    cmd = ["gh", "pr", "view", "--web"]
    if os.environ.get("OPEN_PR_PRINT"):
        cmd = ["gh", "pr", "view", "--json", "url", "--jq", ".url"]
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()
        notify("Open PR", detail[0] if detail else f"No pull request for {cwd}")
        print(result.stderr, file=sys.stderr, end="")
        return result.returncode
    print(result.stdout, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
