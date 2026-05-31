#!/usr/bin/env python3

import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


IDLE_THRESHOLD = 15
# Canonical agent CLIs. The bash scripts share TMUX_AGENT_COMMANDS via
# ~/.tmux-lib.sh; this Python can't source bash, so keep these two in sync (the
# pre-push hook fails if they drift).
AGENT_COMMANDS = ("claude", "codex", "agent", "cursor-agent")
AI_COMMAND_RE = re.compile(
    r"(^|[\s/])(" + "|".join(AGENT_COMMANDS) + r")([\s/]|$)", re.IGNORECASE
)


def tmux_binary():
    # Python twin of tmux_resolve_bin in ~/.tmux-lib.sh; keep them in sync.
    tmux_env = os.environ.get("TMUX", "")
    if tmux_env:
        parts = tmux_env.split(",")
        if len(parts) > 1 and parts[1]:
            proc_exe = Path("/proc") / parts[1] / "exe"
            if proc_exe.exists():
                try:
                    return str(proc_exe.resolve())
                except OSError:
                    pass
    return shutil.which("tmux") or "tmux"


TMUX_BIN = tmux_binary()


def run_tmux(*args, check=False):
    return subprocess.run(
        [TMUX_BIN, *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=check,
    )


def tmux_lines(*args):
    result = run_tmux(*args)
    if result.returncode != 0:
        return []
    return result.stdout.splitlines()


def recreate_tmux_socket_dir():
    # Python twin of tmux_recreate_socket_dir in ~/.tmux-lib.sh; keep in sync.
    tmux_env = os.environ.get("TMUX", "")
    if not tmux_env:
        return
    socket = tmux_env.split(",", 1)[0]
    if socket:
        Path(socket).parent.mkdir(parents=True, exist_ok=True)


def is_ai_window(cmd, tty):
    if cmd in AGENT_COMMANDS:
        return True
    if not tty:
        return False
    # pane_current_command is unreliable for these CLIs: Claude Code reports its
    # version string (e.g. "2.1.150"), others report "node". Fall back to scanning
    # the tty's processes for a known agent command in every non-matching case.

    tty_name = tty[5:] if tty.startswith("/dev/") else tty
    result = subprocess.run(
        ["ps", "-t", tty_name, "-o", "args="],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0 and bool(AI_COMMAND_RE.search(result.stdout))


def capture_hash(pane_id):
    result = run_tmux("capture-pane", "-p", "-t", pane_id)
    return hashlib.md5(result.stdout.encode("utf-8", "replace")).hexdigest()


def git_branch(path):
    result = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        cwd=path,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode == 0:
        return result.stdout.strip()
    return ""


def set_session_option(session_id, option, value=None):
    if value is None:
        run_tmux("set-option", "-q", "-u", "-t", session_id, option)
    else:
        run_tmux("set-option", "-q", "-t", session_id, option, value)


def main():
    recreate_tmux_socket_dir()
    now = int(time.time())
    uid = os.getuid() if hasattr(os, "getuid") else os.environ.get("UID", "user")
    state_dir = Path(os.environ.get("TMPDIR") or tempfile.gettempdir()) / f"tmux-ai-idle-{uid}"
    state_dir.mkdir(parents=True, exist_ok=True)

    session_display_idx = {}
    session_names = {}
    for idx, line in enumerate(tmux_lines("list-sessions", "-F", "#{session_id}|#{session_name}"), start=1):
        sid, _, name = line.partition("|")
        sid_num = sid.lstrip("$")
        session_display_idx[sid_num] = idx
        session_names[sid_num] = name

    idle_windows = {}
    thinking_windows = {}
    idle_paths = {}
    active_states = set()
    prev_idle_sessions = set()
    for line in tmux_lines("list-sessions", "-F", "#{session_id}|#{?#{@session_ai_idle},1,0}"):
        sid, _, flag = line.partition("|")
        if flag == "1":
            prev_idle_sessions.add(sid)

    pane_format = "#{window_id}|#{session_id}|#{pane_id}|#{pane_current_command}|#{pane_tty}|#{pane_current_path}"
    for line in tmux_lines("list-panes", "-a", "-F", pane_format):
        parts = line.split("|", 5)
        if len(parts) != 6:
            continue
        window_id, session_id, pane_id, cmd, tty, pane_path = parts
        if window_id in idle_windows or window_id in thinking_windows:
            continue
        if not is_ai_window(cmd, tty):
            continue

        current_hash = capture_hash(pane_id)
        state_key = re.sub(r"[^a-zA-Z0-9]", "_", pane_id)
        state_file = state_dir / state_key
        active_states.add(state_key)

        stored_hash = ""
        stored_time = now
        if state_file.exists():
            stored_hash = state_file.read_text(encoding="utf-8", errors="ignore")
            stored_time = int(state_file.stat().st_mtime)

        if current_hash != stored_hash:
            state_file.write_text(current_hash, encoding="utf-8")
            thinking_windows[window_id] = session_id
        elif now - stored_time > IDLE_THRESHOLD:
            idle_windows[window_id] = session_id
            idle_paths[window_id] = pane_path
        else:
            thinking_windows[window_id] = session_id

    for path in state_dir.iterdir():
        if path.is_file() and path.name not in active_states:
            try:
                path.unlink()
            except FileNotFoundError:
                pass

    idle_sessions = set(idle_windows.values())
    thinking_sessions = set(thinking_windows.values())
    for sid_num in session_display_idx:
        sid = f"${sid_num}"
        set_session_option(sid, "@session_ai_idle", "1" if sid in idle_sessions else None)
        set_session_option(sid, "@session_ai_thinking", "1" if sid in thinking_sessions else None)

    newly_idle = idle_sessions - prev_idle_sessions
    if newly_idle:
        idle_labels = []
        seen_sessions = set()
        for window_id, session_id in idle_windows.items():
            if session_id not in newly_idle or session_id in seen_sessions:
                continue
            seen_sessions.add(session_id)
            sid_num = session_id.lstrip("$")
            display_idx = session_display_idx.get(sid_num, sid_num)
            name = session_names.get(sid_num, "")
            branch = git_branch(idle_paths[window_id])
            label = f"({display_idx}) {name}{(' ' + branch) if branch else ''}"
            idle_labels.append(label)

        notif_lines = ["❕ AI Idle", *(f" • {label}" for label in idle_labels)]
        notif_msg = "\n".join(notif_lines)
        for ctty in tmux_lines("list-clients", "-F", "#{client_tty}"):
            try:
                Path(ctty).write_text(f"\033]9;{notif_msg}\a", encoding="utf-8")
            except OSError:
                pass

    return 0


if __name__ == "__main__":
    sys.exit(main())
