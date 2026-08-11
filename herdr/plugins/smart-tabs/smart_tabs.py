#!/usr/bin/env python3
"""Create Herdr tabs that continue the active coding agent."""

import json
import os
import shlex
import subprocess
import sys


def herdr(*args):
    output = subprocess.check_output(
        [os.environ.get("HERDR_BIN_PATH", "herdr"), *args], text=True
    )
    return json.loads(output) if output else {}


def foreground_command(pane_id):
    """Return the shell-safe command running at the front of a pane."""
    try:
        process_info = herdr(
            "pane", "process-info", "--pane", pane_id
        )["result"]["process_info"]
    except (KeyError, subprocess.CalledProcessError):
        return None

    processes = process_info.get("foreground_processes") or []
    if not processes:
        return None

    group_id = process_info.get("foreground_process_group_id")
    process = next(
        (process for process in processes if process.get("pid") == group_id),
        processes[0],
    )
    argv = process.get("argv")
    if isinstance(argv, list) and argv and all(isinstance(arg, str) for arg in argv):
        return shlex.join(argv)

    argv0 = process.get("argv0")
    return shlex.quote(argv0) if isinstance(argv0, str) and argv0 else None


def create_tab():
    """Create a tab, continuing whichever agent occupies the source pane."""
    context = json.loads(os.environ["HERDR_PLUGIN_CONTEXT_JSON"])
    source_pane_id = context["focused_pane_id"]
    source_pane = herdr(
        "pane", "current", "--pane", source_pane_id
    )["result"]["pane"]
    agent = context.get("focused_pane_agent")
    command = foreground_command(source_pane_id) if agent else None
    cwd = source_pane.get("foreground_cwd") or source_pane["cwd"]
    tab = herdr(
        "tab", "create", "--workspace", context["workspace_id"],
        "--cwd", cwd, "--focus",
    )

    if agent:
        herdr(
            "pane", "run", tab["result"]["root_pane"]["pane_id"],
            command or shlex.quote(agent),
        )


def main():
    if sys.argv[1:] == ["new-tab"]:
        create_tab()
    else:
        raise SystemExit(f"unknown command: {' '.join(sys.argv[1:])}")


if __name__ == "__main__":
    main()
