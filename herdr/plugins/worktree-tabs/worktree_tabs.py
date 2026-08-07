#!/usr/bin/env python3
"""Open new Herdr worktrees with Vim and Pi tabs."""

import json
import os
import subprocess


def herdr(*args):
    output = subprocess.check_output(
        [os.environ.get("HERDR_BIN_PATH", "herdr"), *args], text=True
    )
    return json.loads(output) if output else {}


def configure_worktree():
    event = json.loads(os.environ["HERDR_PLUGIN_EVENT_JSON"])["data"]
    workspace = event["workspace"]
    workspace_id = workspace["workspace_id"]
    vim_tab_id = workspace["active_tab_id"]

    panes = herdr("pane", "list", "--workspace", workspace_id)["result"]["panes"]
    vim_pane_id = next(pane["pane_id"] for pane in panes if pane["tab_id"] == vim_tab_id)

    herdr("tab", "rename", vim_tab_id, "vim")
    chat = herdr(
        "tab", "create", "--workspace", workspace_id,
        "--cwd", event["worktree"]["path"], "--label", "chat", "--focus",
    )
    herdr("pane", "run", vim_pane_id, "nvim")
    herdr("pane", "run", chat["result"]["root_pane"]["pane_id"], "pi")


if __name__ == "__main__":
    configure_worktree()
