#!/usr/bin/env python3
"""Move rate-limited Claude Code sessions in herdr onto a subscription with headroom.

zsh/.zshrc aliases c2/c3/c4 to their own CLAUDE_CONFIG_DIR (~/.claude2/3/4) so
several subscriptions run side by side. When one of them hits its 5-hour or
weekly limit, every Claude Code session running under it stalls on
"You've hit your session limit". Getting each one going again by hand means:
find the pane, note the session id, copy the transcript into another config
dir (claude --resume only searches its own CLAUDE_CONFIG_DIR), quit claude,
relaunch it under the other alias with --resume, click through the first-run
dialogs that dir shows for a folder it has never opened, and tell it to carry on.

This script does that for every claude pane herdr knows about:

    rebump.py plan            # read-only: usage per account, panes, proposed moves
    rebump.py plan --json
    rebump.py apply           # perform every proposed move
    rebump.py apply --to claude3 --pane w2E:p1
    rebump.py apply --force --pane w2E:p1 --to c4   # move a pane that is not stuck

Usage comes from `cusage` (claude-usage-all in the hsys checkout, sourced by the
shell), herdr state from the `herdr` CLI, and each pane's account from the
CLAUDE_CONFIG_DIR in its claude process's environment. The pane running this
script is never restarted: it would kill the caller.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path

HOME = Path.home()
DEFAULT_CONFIG_DIR = HOME / ".claude"
# Accounts whose 5-hour window is past this are not offered as a destination:
# moving a session there just moves the stall.
SESSION_FULL_PERCENT = 90.0
NUDGE = (
    "This session hit a Claude usage limit and was resumed under another "
    "subscription. Pick up exactly where you left off and finish the task that "
    "was in progress."
)
# Flags that pin a session; the relaunch supplies its own --resume.
SESSION_FLAGS_WITH_VALUE = {"--resume", "-r", "--session-id", "--teleport"}
SESSION_FLAGS = {"--continue", "-c", "--fork-session"}


# --------------------------------------------------------------------------
# Accounts (cusage)
# --------------------------------------------------------------------------


@dataclass
class Account:
    label: str
    config_dir: str  # resolved path, default account included
    email: str | None = None
    error: str | None = None
    weekly_blocked: bool = False
    session_used: float | None = None
    session_resets: str | None = None
    week_used: float | None = None
    fable_used: float | None = None
    fable_resets: str | None = None

    @property
    def usable(self) -> bool:
        return (
            self.error is None
            and not self.weekly_blocked
            and (self.session_used or 0.0) < SESSION_FULL_PERCENT
        )


def normalize_config_dir(raw: str | None) -> str:
    """Resolve a CLAUDE_CONFIG_DIR value; unset means ~/.claude."""
    if not raw:
        return str(DEFAULT_CONFIG_DIR.resolve())
    return str(Path(os.path.expandvars(os.path.expanduser(raw))).resolve())


def account_email(config_dir: str) -> str | None:
    # The default account keeps its state file beside the dir, not inside it.
    state = (
        HOME / ".claude.json"
        if Path(config_dir) == DEFAULT_CONFIG_DIR.resolve()
        else Path(config_dir) / ".claude.json"
    )
    try:
        data = json.loads(state.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return (data.get("oauthAccount") or {}).get("emailAddress")


def run_cusage(timeout: int) -> dict:
    """`cusage --json` via an interactive zsh, where the hsys helpers are sourced.

    The shell rc may print to stdout before the JSON, so parse from the first
    line that opens an object.
    """
    shell = os.environ.get("SHELL") or "/bin/zsh"
    try:
        proc = subprocess.run(
            [shell, "-ic", "claude-usage-all --json --no-color"],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            stdin=subprocess.DEVNULL,
        )
    except subprocess.TimeoutExpired:
        raise SystemExit(f"cusage timed out after {timeout}s")
    except OSError as exc:
        raise SystemExit(f"could not run {shell}: {exc}")
    lines = proc.stdout.splitlines()
    for i, line in enumerate(lines):
        if line.startswith("{"):
            try:
                return json.loads("\n".join(lines[i:]))
            except ValueError:
                break
    detail = (proc.stderr or proc.stdout).strip().splitlines()
    raise SystemExit(
        "cusage produced no JSON (is zsh-helpers.zsh from the hsys checkout "
        "sourced by the shell?)" + (f": {detail[-1]}" if detail else "")
    )


def accounts_from_usage(report: dict) -> list[Account]:
    accounts = []
    for entry in report.get("accounts", []):
        config_dir = normalize_config_dir(entry.get("config_dir"))
        account = Account(
            label=entry.get("label") or Path(config_dir).name.lstrip("."),
            config_dir=config_dir,
            email=account_email(config_dir),
            error=entry.get("error"),
            weekly_blocked=bool(entry.get("weekly_blocked")),
        )
        for limit in entry.get("limits", []):
            used = limit.get("used_percent")
            resets = limit.get("resets_at")
            if limit.get("id") == "session":
                account.session_used, account.session_resets = used, resets
            elif limit.get("id") == "week_all":
                account.week_used = used
            elif limit.get("id") == "week_fable":
                account.fable_used, account.fable_resets = used, resets
        accounts.append(account)
    return accounts


def resolve_account(accounts: list[Account], name: str) -> Account:
    """Match --to by cusage label, alias-style name (claude3, c3) or config dir.

    cusage labels an account after whichever alias sorts first, so the same
    subscription can read `c3` one day and `claude3` the next; the config dir is
    the stable identity.
    """
    for account in accounts:
        if account.label == name:
            return account
    candidates = {normalize_config_dir(name)}
    match = re.fullmatch(r"[A-Za-z]*(\d+)", name)
    if match:
        candidates.add(normalize_config_dir(f"~/.claude{match.group(1)}"))
    elif name in ("claude", "claude1", "default"):
        candidates.add(normalize_config_dir(None))
    for account in accounts:
        if account.config_dir in candidates:
            return account
    raise SystemExit(
        f"no account matches {name!r}; cusage knows "
        + ", ".join(f"{a.label} ({a.config_dir})" for a in accounts)
    )


def choose_target(accounts: list[Account], exclude: str) -> Account | None:
    """The account to move to: emptiest 5-hour window, then most Fable left."""
    candidates = [a for a in accounts if a.usable and a.config_dir != exclude]
    candidates.sort(
        key=lambda a: (a.session_used or 0.0, -(100.0 - (a.fable_used or 0.0)))
    )
    return candidates[0] if candidates else None


# --------------------------------------------------------------------------
# herdr
# --------------------------------------------------------------------------


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
    if check and (proc.returncode != 0 or "error" in data):
        message = (data.get("error") or {}).get("message") or payload
        raise SystemExit(f"herdr {' '.join(args)} failed: {message}")
    return data


def claude_panes() -> list[dict]:
    agents = herdr("agent", "list")["result"]["agents"]
    return [
        a
        for a in agents
        if a.get("agent") == "claude" and (a.get("agent_session") or {}).get("value")
    ]


def pane_claude_process(pane_id: str) -> dict | None:
    info = herdr("pane", "process-info", "--pane", pane_id)["result"]["process_info"]
    for proc in info.get("foreground_processes", []):
        argv = proc.get("argv") or []
        if argv and Path(argv[0]).name == "claude":
            return proc
    return None


def process_env(pid: int) -> dict[str, str]:
    """The environment of a live process, on Linux (procfs) or macOS (ps eww)."""
    environ = Path(f"/proc/{pid}/environ")
    if environ.exists():
        try:
            raw = environ.read_bytes().split(b"\0")
        except OSError:
            raw = []
        pairs = (item.decode("utf-8", "replace").partition("=") for item in raw if item)
        return {k: v for k, _, v in pairs}
    if platform.system() != "Darwin":
        return {}
    try:
        out = subprocess.check_output(
            ["ps", "eww", "-o", "command=", "-p", str(pid)], text=True
        )
    except (subprocess.CalledProcessError, OSError):
        return {}
    env = {}
    for token in out.split():
        key, sep, value = token.partition("=")
        if sep and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            env[key] = value
    return env


# --------------------------------------------------------------------------
# Transcripts
# --------------------------------------------------------------------------


def find_transcript(config_dir: str, session_id: str) -> Path | None:
    hits = glob.glob(str(Path(config_dir) / "projects" / "*" / f"{session_id}.jsonl"))
    return Path(hits[0]) if hits else None


def limit_message(transcript: Path) -> str | None:
    """The rate-limit text if the transcript's last assistant turn is one.

    Claude Code records the limit as a synthetic assistant message carrying
    error=rate_limit and quotaLimits.status=rejected; a later real assistant
    turn means the session got going again.
    """
    try:
        with transcript.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - 262144))
            tail = handle.read().decode("utf-8", "replace")
    except OSError:
        return None
    lines = tail.splitlines()
    if len(lines) > 1:
        lines = lines[1:]  # the first line is cut mid-record
    for line in reversed(lines):
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if record.get("type") != "assistant":
            continue
        quota = record.get("quotaLimits") or {}
        if record.get("error") == "rate_limit" or quota.get("status") == "rejected":
            content = (record.get("message") or {}).get("content") or []
            for part in content:
                if isinstance(part, dict) and part.get("type") == "text":
                    return part["text"]
            return "rate limit"
        return None
    return None


def copy_transcript(source: Path, target_dir: str) -> Path:
    """Copy the transcript and its sidecar dir into the same project slug."""
    dest = Path(target_dir) / "projects" / source.parent.name / source.name
    dest.parent.mkdir(parents=True, exist_ok=True)
    if not dest.exists() or source.stat().st_mtime > dest.stat().st_mtime:
        shutil.copy2(source, dest)
    sidecar = source.with_suffix("")
    if sidecar.is_dir():
        shutil.copytree(sidecar, dest.with_suffix(""), dirs_exist_ok=True)
    return dest


# --------------------------------------------------------------------------
# Plan
# --------------------------------------------------------------------------


@dataclass
class Move:
    pane_id: str
    session_id: str
    cwd: str
    title: str
    status: str
    from_label: str
    from_dir: str
    to_label: str | None
    to_dir: str | None
    reason: str
    transcript: str | None
    argv: list[str] = field(default_factory=list)
    pid: int | None = None
    is_self: bool = False

    @property
    def actionable(self) -> bool:
        return (
            self.to_dir is not None and self.transcript is not None and not self.is_self
        )


def relaunch_argv(argv: list[str], session_id: str) -> list[str]:
    """The original command line, minus session flags, plus --resume <id>."""
    out: list[str] = []
    skip = False
    for token in argv:
        if skip:
            skip = False
            continue
        if token in SESSION_FLAGS_WITH_VALUE:
            skip = True
            continue
        if token in SESSION_FLAGS or any(
            token.startswith(f"{flag}=") for flag in SESSION_FLAGS_WITH_VALUE
        ):
            continue
        if token not in out[1:]:  # the alias adds --chrome again; keep one
            out.append(token)
    return [*out, "--resume", session_id]


def build_plan(
    accounts: list[Account],
    panes: list[dict],
    to_label: str | None,
    force: bool = False,
) -> list[Move]:
    by_dir = {a.config_dir: a for a in accounts}
    forced = resolve_account(accounts, to_label) if to_label else None
    own_pane = os.environ.get("HERDR_PANE_ID")
    moves = []
    for pane in panes:
        pane_id = pane["pane_id"]
        session_id = pane["agent_session"]["value"]
        proc = pane_claude_process(pane_id)
        env = process_env(proc["pid"]) if proc else {}
        from_dir = normalize_config_dir(env.get("CLAUDE_CONFIG_DIR"))
        account = by_dir.get(from_dir)
        from_label = account.label if account else Path(from_dir).name.lstrip(".")
        transcript = find_transcript(from_dir, session_id)

        reasons = []
        if transcript is not None:
            text = limit_message(transcript)
            if text:
                reasons.append(f"transcript ends with: {text}")
        if account is not None:
            if account.weekly_blocked:
                reasons.append(f"{account.label} weekly cap is spent")
            elif (account.session_used or 0.0) >= 100.0:
                reasons.append(f"{account.label} 5h window is at 100%")
        if force and not reasons:
            reasons.append("--force")
        if not reasons:
            reason = "not limited"
            target = None
        else:
            reason = "; ".join(reasons)
            target = forced or choose_target(accounts, exclude=from_dir)
            if target is not None and target.config_dir == from_dir:
                target = None
                reason += "; target is the account it is already on"
            elif target is None:
                reason += "; no account has headroom"
            if transcript is None:
                reason += f"; transcript not found under {from_dir}"

        moves.append(
            Move(
                pane_id=pane_id,
                session_id=session_id,
                cwd=pane.get("cwd") or "",
                title=pane.get("terminal_title_stripped") or "",
                status=pane.get("agent_status") or "",
                from_label=from_label,
                from_dir=from_dir,
                to_label=target.label if target else None,
                to_dir=target.config_dir if target else None,
                reason=reason,
                transcript=str(transcript) if transcript else None,
                argv=(proc or {}).get("argv") or ["claude"],
                pid=(proc or {}).get("pid"),
                is_self=pane_id == own_pane,
            )
        )
    return moves


def relaunch_command(move: Move) -> str:
    argv = relaunch_argv(move.argv, move.session_id)
    return f"CLAUDE_CONFIG_DIR={shlex.quote(move.to_dir or '')} " + " ".join(
        shlex.quote(a) for a in argv
    )


# --------------------------------------------------------------------------
# Apply
# --------------------------------------------------------------------------


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
    """Click through the first-run dialogs a config dir shows for a folder it
    has never opened: the folder-trust question, the bypass-permissions
    warning, the Chrome extension notice. The session's old account had
    already been through them. herdr classifies these as idle, so the screen
    is the only signal. Returns True when any dialog was answered."""
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


def quit_claude(move: Move, log) -> bool:
    """Ctrl-C twice exits Claude Code; a first press only clears typed input."""
    for attempt in range(3):
        herdr("agent", "send-keys", move.pane_id, "ctrl+c", "ctrl+c", check=False)
        if wait_for(lambda: pane_claude_process(move.pane_id) is None, timeout=6):
            return True
        log(f"  claude still running in {move.pane_id} (attempt {attempt + 1})")
    return False


def apply_move(move: Move, nudge: str | None, log) -> str:
    log(f"{move.pane_id} {move.session_id[:8]} {move.from_label} -> {move.to_label}")
    dest = copy_transcript(Path(move.transcript or ""), move.to_dir or "")
    log(f"  transcript copied to {dest}")

    if not quit_claude(move, log):
        return "failed: could not quit claude in the pane"
    command = relaunch_command(move)
    herdr("pane", "run", move.pane_id, command)
    log(f"  ran: {command}")

    if not wait_for(
        lambda: (
            (herdr("agent", "get", move.pane_id, check=False).get("result") or {})
            .get("agent", {})
            .get("agent")
            == "claude"
        ),
        timeout=45,
    ):
        return "failed: herdr did not detect claude after the relaunch"
    settled = herdr(
        "agent", "wait", move.pane_id, "--timeout", "90000", check=False, timeout=120
    )
    if dismiss_startup_dialogs(move.pane_id, log):
        settled = herdr(
            "agent",
            "wait",
            move.pane_id,
            "--timeout",
            "90000",
            check=False,
            timeout=120,
        )
    status = ((settled.get("result") or {}).get("agent") or {}).get("agent_status")
    if status is None:
        status = ((settled.get("result") or {}).get("status")) or "unknown"
    log(f"  agent {status}")
    if status == "blocked" or "Enter to confirm" in pane_screen(move.pane_id):
        return "resumed, but claude is waiting on a dialog; nudge skipped"
    if nudge:
        herdr("agent", "prompt", move.pane_id, nudge, check=False)
        log("  nudged")
        return "resumed and nudged"
    return "resumed"


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------


def fmt_pct(value: float | None) -> str:
    return "-" if value is None else f"{value:.0f}%"


def fmt_resets(iso: str | None) -> str:
    if not iso:
        return ""
    try:
        target = datetime.fromisoformat(iso)
    except ValueError:
        return iso
    secs = int((target - datetime.now(target.tzinfo)).total_seconds())
    if secs <= 0:
        return "due"
    hours, rem = divmod(secs, 3600)
    return f"{hours}h{rem // 60:02d}m"


def render(accounts: list[Account], moves: list[Move]) -> str:
    lines = ["accounts"]
    for a in accounts:
        if a.error:
            lines.append(f"  {a.label:<8} {a.email or '':<28} ! {a.error}")
            continue
        flags = " blocked" if a.weekly_blocked else ""
        lines.append(
            f"  {a.label:<8} {a.email or '':<28} "
            f"5h {fmt_pct(a.session_used):>4} ({fmt_resets(a.session_resets)})  "
            f"week {fmt_pct(a.week_used):>4}  fable {fmt_pct(a.fable_used):>4}"
            f"{flags}"
        )
    lines.append("")
    lines.append("claude panes in herdr")
    if not moves:
        lines.append("  none")
    for m in moves:
        where = Path(m.cwd).name
        lines.append(
            f"  {m.pane_id:<8} {m.session_id[:8]} {m.from_label:<8} {m.status:<8} "
            f"{where}: {m.title}"
        )
        if m.to_label:
            verb = "would move" if not m.is_self else "cannot move (this pane)"
            lines.append(f"           {verb} to {m.to_label}: {m.reason}")
            if m.is_self:
                lines.append("           run in the pane after quitting claude:")
                lines.append(f"             {relaunch_command(m)}")
        elif m.reason != "not limited":
            lines.append(f"           stuck: {m.reason}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "action",
        nargs="?",
        choices=("plan", "apply"),
        default="plan",
        help="plan is read-only (default); apply performs the moves",
    )
    parser.add_argument(
        "--to",
        help="account to move to, by cusage label, alias (claude3, c3) or config "
        "dir (default: the emptiest 5-hour window)",
    )
    parser.add_argument(
        "--pane", action="append", help="only these pane ids (repeatable)"
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="move the selected panes even when they are not rate limited",
    )
    parser.add_argument(
        "--usage",
        help="read cusage --json output from this file instead of running it",
    )
    parser.add_argument("--json", action="store_true", help="machine-readable plan")
    parser.add_argument(
        "--nudge",
        default=NUDGE,
        help="prompt sent after the resume; empty string sends nothing",
    )
    parser.add_argument("--timeout", type=int, default=240, help="cusage timeout")
    args = parser.parse_args(argv)

    if shutil.which("herdr") is None:
        raise SystemExit("herdr is not on PATH")
    if args.usage:
        report = json.loads(Path(args.usage).read_text(encoding="utf-8"))
    else:
        report = run_cusage(args.timeout)
    accounts = accounts_from_usage(report)
    if not accounts:
        raise SystemExit("cusage reported no accounts")

    panes = claude_panes()
    if args.pane:
        panes = [p for p in panes if p["pane_id"] in set(args.pane)]
    if args.force and not args.pane:
        raise SystemExit("--force needs --pane: it would restart every claude pane")
    moves = build_plan(accounts, panes, args.to, force=args.force)

    if args.json:
        print(
            json.dumps(
                {
                    "accounts": [asdict(a) for a in accounts],
                    "moves": [
                        {**asdict(m), "command": relaunch_command(m)} for m in moves
                    ],
                },
                indent=2,
            )
        )
    else:
        print(render(accounts, moves))

    if args.action == "plan":
        return 0

    todo = [m for m in moves if m.actionable]
    if not todo:
        print("\nnothing to apply")
        return 0
    print()
    results = {}
    for move in todo:
        try:
            results[move.pane_id] = apply_move(move, args.nudge or None, print)
        except SystemExit as exc:
            results[move.pane_id] = f"failed: {exc}"
        print(f"  {results[move.pane_id]}")
    return 0 if all(not r.startswith("failed") for r in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
