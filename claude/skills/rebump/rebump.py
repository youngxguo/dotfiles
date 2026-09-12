#!/usr/bin/env python3
"""Move rate-limited Claude Code sessions in herdr onto a subscription, or a
model, with headroom.

Two flows share the planning: `plan`/`apply` sweep every claude pane herdr
knows about, and `hook` (the StopFailure hook) rebumps only the session it
fired in, from what Claude Code hands the hook."""

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
import traceback
from dataclasses import asdict, dataclass, field
from datetime import datetime
from functools import partial
from pathlib import Path

HOME = Path.home()
DEFAULT_CONFIG_DIR = HOME / ".claude"
SESSION_FULL_PERCENT = 90.0
USAGE_MAX_AGE = 300
CUSAGE_TIMEOUT = 240
NUDGE = (
    "This session hit a Claude usage limit and was resumed on a subscription or "
    "model with headroom. Pick up exactly where you left off and finish the task "
    "that was in progress."
)
SESSION_FLAGS_WITH_VALUE = {"--resume", "-r", "--session-id", "--teleport"}
SESSION_FLAGS = {"--continue", "-c", "--fork-session"}
PREFERRED_MODEL = "fable"
FALLBACK_MODEL = "opus"
MODEL_FLAG = "--model"
MODEL_ENV = "ANTHROPIC_MODEL"
TAIL_BYTES = 262144
SESSION_CONFIRM_SECONDS = 15
NUDGE_RETRY_SECONDS = 20
# Claude Code's own wait for the reset, which it re-arms when it resumes a
# transcript that ends on a limit; "esc or type to cancel".
AUTO_CONTINUE_MARK = "continuing automatically"


@dataclass
class Account:
    label: str
    config_dir: str
    email: str | None = None
    error: str | None = None
    weekly_blocked: bool = False
    session_used: float | None = None
    session_resets: str | None = None
    week_used: float | None = None
    fable_used: float | None = None
    fable_resets: str | None = None

    @property
    def fable_spent(self) -> bool:
        return (self.fable_used or 0.0) >= 100.0

    @property
    def spent(self) -> str | None:
        """Why no session at all can run on this account right now, or None. A
        spent Fable cap is not a reason: the account still runs other models,
        so a session there switches model instead of subscription."""
        if self.error:
            return self.error
        if self.weekly_blocked:
            return "weekly cap is spent"
        if (self.session_used or 0.0) >= SESSION_FULL_PERCENT:
            return f"5h window is at {fmt_pct(self.session_used)}"
        return None

    @property
    def usable(self) -> bool:
        return self.spent is None


def normalize_config_dir(raw: str | None) -> str:
    if not raw:
        return str(DEFAULT_CONFIG_DIR.resolve())
    return str(Path(os.path.expandvars(os.path.expanduser(raw))).resolve())


def launch_prefix(
    config_dir: str, model: str | None = None, unpin: bool = False
) -> str:
    """The environment a claude session starts under. The default account is
    only reachable with CLAUDE_CONFIG_DIR unset: setting it, even to ~/.claude,
    gives claude its own .claude.json inside the dir and its own `Claude
    Code-credentials-<hash>` keychain entry, so the session lands on a login
    prompt instead of the subscription. `unpin` drops an inherited
    ANTHROPIC_MODEL so the account's own default model applies again."""
    default = not config_dir or config_dir == normalize_config_dir(None)
    unset = ["CLAUDE_CONFIG_DIR"] if default else []
    assign = [] if unset else [f"CLAUDE_CONFIG_DIR={shlex.quote(config_dir)}"]
    if unpin:
        unset.append(MODEL_ENV)
    if model:
        assign.append(f"{MODEL_ENV}={shlex.quote(model)}")
    parts = ["env " + " ".join(f"-u {name}" for name in unset)] if unset else []
    return " ".join([*parts, *assign])


def settings_model(config_dir: str) -> str | None:
    """The account's own default model. It differs per config dir and carries
    the context-window suffix (`opus[1m]`), which is why rebump unsets its pin
    rather than writing a bare alias back."""
    for name in ("settings.local.json", "settings.json"):
        try:
            data = json.loads((Path(config_dir) / name).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        model = data.get("model")
        if isinstance(model, str):
            return model
    return None


def is_model(model: str | None, alias: str) -> bool:
    """`opus` matches `opus[1m]` and `claude-opus-5`: the forms a pin, a
    settings default and a transcript record use for the same model."""
    return bool(model) and alias.lower() in model.lower()


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
    """cusage is a function sourced by the interactive zsh rc, which may print
    to stdout before the JSON."""
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


def usage_cache_path() -> Path:
    base = os.environ.get("XDG_CACHE_HOME") or str(HOME / ".cache")
    return Path(base) / "rebump" / "usage.json"


def report_readable(report: dict) -> bool:
    """Whether the report says anything usable. The usage API rate-limits a
    caller that asks twice in quick succession, and every account then comes
    back with an error - which reads as `spent` and would quietly turn a plan
    into `no account has headroom`."""
    accounts = report.get("accounts") or []
    return any(not entry.get("error") for entry in accounts)


def read_cache(cache: Path) -> tuple[dict | None, float]:
    try:
        return json.loads(cache.read_text(encoding="utf-8")), cache.stat().st_mtime
    except (OSError, ValueError):
        return None, 0.0


def load_usage(usage_file: str | None, max_age: int, timeout: int) -> dict:
    """Every action reuses the last report while it is younger than max_age, so
    a plan followed by an apply - or several agents starting in a row - asks
    the usage API once rather than tripping its rate limit."""
    if usage_file:
        return json.loads(Path(usage_file).read_text(encoding="utf-8"))
    cache = usage_cache_path()
    cached, cached_at = read_cache(cache)
    if cached is not None and max_age > 0 and time.time() - cached_at < max_age:
        return cached
    report = run_cusage(timeout)
    if not report_readable(report):
        # A rate-limited read tells us nothing; the last real one still does.
        if cached is not None and report_readable(cached):
            cached["stale_since"] = cached_at
            return cached
        return report
    try:
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(json.dumps(report), encoding="utf-8")
    except OSError:
        pass
    return report


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


def read_accounts(
    usage_file: str | None = None,
    max_age: int = USAGE_MAX_AGE,
    timeout: int = CUSAGE_TIMEOUT,
) -> list[Account]:
    return read_usage(usage_file, max_age, timeout)[0]


def read_usage(
    usage_file: str | None = None,
    max_age: int = USAGE_MAX_AGE,
    timeout: int = CUSAGE_TIMEOUT,
) -> tuple[list[Account], str | None]:
    """The accounts, and a note when they did not come from a fresh read."""
    report = load_usage(usage_file, max_age, timeout)
    accounts = accounts_from_usage(report)
    if not accounts:
        raise SystemExit("cusage reported no accounts")
    note = None
    stale_since = report.get("stale_since")
    if stale_since:
        age = max(0, int(time.time() - stale_since))
        note = (
            f"the usage API would not answer; showing the last reading, "
            f"{age // 60}m{age % 60:02d}s old"
        )
    return accounts, note


def resolve_account(accounts: list[Account], name: str) -> Account:
    """cusage labels an account after whichever alias sorts first, so the same
    subscription can read `c3` one day and `claude3` the next."""
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


def choose_target(accounts: list[Account], exclude: str = "") -> Account | None:
    """Fable is the model we want to run, and its weekly cap cannot be waited
    out the way a 5-hour window can, so Fable headroom ranks first; an account
    whose Fable cap is spent still qualifies, on the fallback model."""
    candidates = [a for a in accounts if a.usable and a.config_dir != exclude]
    candidates.sort(key=lambda a: (a.fable_used or 0.0, a.session_used or 0.0))
    return candidates[0] if candidates else None


def pick_account(accounts: list[Account], to_label: str | None) -> Account:
    """The account a new claude session should start on, or exit 1 so the
    caller does not launch claude into a spent subscription."""
    if to_label:
        account = resolve_account(accounts, to_label)
        if account.usable:
            return account
        raise SystemExit(f"{account.label} has no headroom: {account.spent}")
    account = choose_target(accounts)
    if account is None:
        raise SystemExit("no account has headroom; wait for a window to reset")
    return account


def launch_choice(
    accounts: list[Account], to_label: str | None, fallback: str = FALLBACK_MODEL
) -> tuple[Account, str | None, str]:
    """Everything a new claude session needs to start somewhere with
    headroom: the account, the model to pin, and the shell prefix."""
    account = pick_account(accounts, to_label)
    model, _ = model_switch(account, fallback)
    return account, model, launch_prefix(account.config_dir, model)


def model_switch(
    account: Account,
    fallback: str,
    running: str | None = None,
    pinned: str | None = None,
    model_limited: bool = False,
) -> tuple[str | None, bool]:
    """How a relaunch on this account should set the model: a model to pin, and
    whether to drop a pin the session inherited from its pane. A Fable weekly
    cap cannot be waited out the way a 5-hour window can, so a session whose
    model is out of quota switches model rather than subscription; once the
    account can run Fable again, dropping our own pin hands the session back to
    the account's default, suffix (`[1m]`) and all."""
    default = settings_model(account.config_dir)
    running = running or default
    if model_limited or (account.fable_spent and is_model(running, PREFERRED_MODEL)):
        return (None, False) if is_model(running, fallback) else (fallback, False)
    if is_model(pinned, fallback) and is_model(default, PREFERRED_MODEL):
        return None, True
    return None, False


def session_model(argv: list[str], env: dict[str, str]) -> str | None:
    """The model a running session is pinned to, by flag or environment; None
    means it follows the account's configured default."""
    for index, token in enumerate(argv):
        if token == MODEL_FLAG and index + 1 < len(argv):
            return argv[index + 1]
        if token.startswith(f"{MODEL_FLAG}="):
            return token.split("=", 1)[1]
    return env.get(MODEL_ENV)


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


def herdr_error(data: dict) -> str | None:
    if "error" not in data:
        return None
    return (data.get("error") or {}).get("message") or "unknown error"


def pane_agent(pane_id: str) -> dict:
    """What herdr knows about the agent in a pane; empty when there is none."""
    result = herdr("agent", "get", pane_id, check=False).get("result") or {}
    return result.get("agent") or {}


def pane_session(pane_id: str) -> tuple[str | None, str | None]:
    """The session reference herdr reads off the agent in a pane, as (kind,
    value); the kind is `id` when herdr could read the session id itself."""
    ref = pane_agent(pane_id).get("agent_session") or {}
    return ref.get("kind"), ref.get("value")


def runs_session(pane_id: str, session_id: str) -> bool:
    """Whether the pane runs the session we resumed. A reference herdr could
    not read as an id (an older integration reports the title) cannot
    contradict us, so only a different id counts against."""
    kind, value = pane_session(pane_id)
    return value == session_id or (value is not None and kind != "id")


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


def find_transcript(config_dir: str, session_id: str) -> Path | None:
    hits = glob.glob(str(Path(config_dir) / "projects" / "*" / f"{session_id}.jsonl"))
    return Path(hits[0]) if hits else None


def tail_records(transcript: Path) -> list[dict]:
    """The end of a transcript, oldest first."""
    try:
        with transcript.open("rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            start = max(0, size - TAIL_BYTES)
            handle.seek(start)
            tail = handle.read().decode("utf-8", "replace")
    except OSError:
        return []
    lines = tail.splitlines()
    if start and len(lines) > 1:
        lines = lines[1:]  # a tail that starts mid-file cuts its first record
    records = []
    for line in lines:
        try:
            records.append(json.loads(line))
        except ValueError:
            continue
    return records


@dataclass
class Limit:
    text: str
    kind: str | None

    @property
    def model_only(self) -> bool:
        """Claude Code writes "/model to switch models" and leaves quotaLimits
        empty when the cap binds the current model rather than the whole
        subscription, which is exactly the case a model switch fixes."""
        return self.kind is None and "/model" in self.text


def limit_message(records: list[dict]) -> Limit | None:
    """Claude Code records a limit as a synthetic assistant message carrying
    error=rate_limit; quotaLimits names the window when a whole subscription
    one is spent (`five_hour`) and is empty for a per-model cap."""
    for record in reversed(records):
        if record.get("type") != "assistant":
            continue
        quota = record.get("quotaLimits") or {}
        if record.get("error") == "rate_limit" or quota.get("status") == "rejected":
            text = "rate limit"
            for part in (record.get("message") or {}).get("content") or []:
                if isinstance(part, dict) and part.get("type") == "text":
                    text = part["text"]
                    break
            return Limit(text=text, kind=quota.get("rateLimitType"))
        return None
    return None


def transcript_model(records: list[dict]) -> str | None:
    """The model the session was last answered by; the synthetic messages that
    carry a limit say `<synthetic>` instead of a model."""
    for record in reversed(records):
        model = (record.get("message") or {}).get("model")
        if record.get("type") == "assistant" and model and model != "<synthetic>":
            return model
    return None


def copy_transcript(source: Path, target_dir: str) -> Path:
    dest = Path(target_dir) / "projects" / source.parent.name / source.name
    dest.parent.mkdir(parents=True, exist_ok=True)
    if not dest.exists() or source.stat().st_mtime > dest.stat().st_mtime:
        shutil.copy2(source, dest)
    sidecar = source.with_suffix("")
    if sidecar.is_dir():
        shutil.copytree(sidecar, dest.with_suffix(""), dirs_exist_ok=True)
    return dest


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
    model: str | None = None
    unpin: bool = False
    argv: list[str] = field(default_factory=list)
    pid: int | None = None
    is_self: bool = False

    @property
    def actionable(self) -> bool:
        return (
            self.to_dir is not None and self.transcript is not None and not self.is_self
        )

    @property
    def change(self) -> str:
        """What the relaunch changes: the account, the model, or both."""
        if self.to_dir is None:
            return ""
        where = (
            "restart here"
            if self.to_dir == self.from_dir
            else f"move to {self.to_label}"
        )
        if self.model:
            return f"{where} on {self.model}"
        return f"{where} on its default model" if self.unpin else where


def relaunch_argv(
    argv: list[str], session_id: str, drop_model: bool = False
) -> list[str]:
    out: list[str] = []
    skip = False
    for token in argv:
        if skip:
            skip = False
            continue
        if token in SESSION_FLAGS_WITH_VALUE or (drop_model and token == MODEL_FLAG):
            skip = True
            continue
        if (
            token in SESSION_FLAGS
            or any(token.startswith(f"{flag}=") for flag in SESSION_FLAGS_WITH_VALUE)
            or (drop_model and token.startswith(f"{MODEL_FLAG}="))
        ):
            continue
        if token not in out[1:]:  # the alias adds --chrome again; keep one
            out.append(token)
    return [*out, "--resume", session_id]


@dataclass
class Session:
    """What rebump needs to know about one running Claude Code session."""

    pane_id: str
    session_id: str
    argv: list[str]
    env: dict[str, str]
    transcript: Path | None
    cwd: str = ""
    title: str = ""
    status: str = ""
    pid: int | None = None

    @property
    def config_dir(self) -> str:
        return normalize_config_dir(self.env.get("CLAUDE_CONFIG_DIR"))


def session_from_pane(pane: dict) -> Session:
    """A session herdr listed: its account and pin have to be read off the
    claude process running in the pane."""
    pane_id = pane["pane_id"]
    session_id = pane["agent_session"]["value"]
    proc = pane_claude_process(pane_id)
    env = process_env(proc["pid"]) if proc else {}
    config_dir = normalize_config_dir(env.get("CLAUDE_CONFIG_DIR"))
    return Session(
        pane_id=pane_id,
        session_id=session_id,
        argv=(proc or {}).get("argv") or ["claude"],
        env=env,
        transcript=find_transcript(config_dir, session_id),
        cwd=pane.get("cwd") or "",
        title=pane.get("terminal_title_stripped") or "",
        status=pane.get("agent_status") or "",
        pid=(proc or {}).get("pid"),
    )


def session_from_hook(payload: dict, pane_id: str, env: dict[str, str]) -> Session:
    """The session a StopFailure hook fired in. Claude Code hands the hook its
    session id and transcript, and the hook inherits the environment the
    session runs under, so only the command line has to come from herdr."""
    session_id = payload.get("session_id") or ""
    proc = pane_claude_process(pane_id)
    transcript: Path | None = Path(payload.get("transcript_path") or "")
    if not transcript.is_file():
        config_dir = normalize_config_dir(env.get("CLAUDE_CONFIG_DIR"))
        transcript = find_transcript(config_dir, session_id)
    return Session(
        pane_id=pane_id,
        session_id=session_id,
        argv=(proc or {}).get("argv") or ["claude"],
        env=dict(env),
        transcript=transcript,
        cwd=payload.get("cwd") or "",
        pid=(proc or {}).get("pid"),
    )


def plan_move(
    accounts: list[Account],
    session: Session,
    forced: Account | None = None,
    force: bool = False,
    fallback: str = FALLBACK_MODEL,
    own_pane: str | None = None,
) -> Move:
    by_dir = {a.config_dir: a for a in accounts}
    from_dir = session.config_dir
    account = by_dir.get(from_dir)
    from_label = account.label if account else Path(from_dir).name.lstrip(".")
    transcript = session.transcript
    records = tail_records(transcript) if transcript else []
    limit = limit_message(records)
    pinned = session_model(session.argv, session.env)
    # What the session actually runs: its pin, else the model that answered
    # it last, else the account's default - which differs per config dir.
    running = pinned or transcript_model(records) or settings_model(from_dir)
    # A spent Fable cap only troubles a session that runs Fable; a model
    # cap Claude Code reported troubles it whatever cusage says.
    model_limited = bool(limit and limit.model_only) or (
        account is not None
        and account.fable_spent
        and is_model(running, PREFERRED_MODEL)
    )

    reasons = []
    if limit is not None:
        reasons.append(f"transcript ends with: {limit.text}")
    if account is not None:
        if account.weekly_blocked:
            reasons.append(f"{account.label} weekly cap is spent")
        elif (account.session_used or 0.0) >= 100.0:
            reasons.append(f"{account.label} 5h window is at 100%")
        elif model_limited:
            reasons.append(
                f"{account.label} fable weekly cap is spent and this session "
                f"runs {running}"
            )
    if force and not reasons:
        reasons.append("--force")
    if not reasons:
        reason = "not limited"
        target, model, unpin = None, None, False
    else:
        reason = "; ".join(reasons)
        # Switching model is cheaper than switching subscription and keeps
        # the session where its memory is, so the account it is already on
        # gets the first try whenever a model switch could fix the limit.
        candidates = [forced] if forced else []
        if not forced:
            if model_limited and account is not None and account.usable:
                candidates.append(account)
            other = choose_target(accounts, exclude=from_dir)
            if other is not None:
                candidates.append(other)
        target, model, unpin = None, None, False
        for candidate in candidates:
            model, unpin = model_switch(
                candidate,
                fallback,
                running=running,
                pinned=pinned,
                model_limited=model_limited and candidate is account,
            )
            if candidate.config_dir != from_dir or model or unpin:
                target = candidate
                break
        if target is None:
            model, unpin = None, False
            reason += (
                f"; already on {from_label} with nothing to switch"
                if any(c.config_dir == from_dir for c in candidates)
                else "; no account has headroom"
            )
        elif target.config_dir == from_dir:
            reason += f"; {from_label} can still run {model or 'its default'}"
        if transcript is None:
            reason += f"; transcript not found under {from_dir}"

    return Move(
        pane_id=session.pane_id,
        session_id=session.session_id,
        cwd=session.cwd,
        title=session.title,
        status=session.status,
        from_label=from_label,
        from_dir=from_dir,
        to_label=target.label if target else None,
        to_dir=target.config_dir if target else None,
        reason=reason,
        transcript=str(transcript) if transcript else None,
        model=model,
        unpin=unpin,
        argv=session.argv,
        pid=session.pid,
        is_self=session.pane_id == own_pane,
    )


def build_plan(
    accounts: list[Account],
    panes: list[dict],
    to_label: str | None,
    force: bool = False,
    fallback: str = FALLBACK_MODEL,
) -> list[Move]:
    """The sweep: every claude session herdr knows about, planned together."""
    forced = resolve_account(accounts, to_label) if to_label else None
    own_pane = os.environ.get("HERDR_PANE_ID")
    return [
        plan_move(accounts, session_from_pane(pane), forced, force, fallback, own_pane)
        for pane in panes
    ]


def relaunch_command(move: Move) -> str:
    """The model rides in the environment rather than on `--model`, so it also
    overrides an ANTHROPIC_MODEL the pane's shell already carries."""
    argv = relaunch_argv(
        move.argv, move.session_id, drop_model=bool(move.model) or move.unpin
    )
    prefix = launch_prefix(move.to_dir or "", move.model, move.unpin)
    return prefix + " " + " ".join(shlex.quote(a) for a in argv)


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


def quit_claude(move: Move, log) -> bool:
    """Ctrl-C twice exits Claude Code; a first press only clears typed input."""
    for attempt in range(3):
        herdr("agent", "send-keys", move.pane_id, "ctrl+c", "ctrl+c", check=False)
        if wait_for(lambda: pane_claude_process(move.pane_id) is None, timeout=6):
            return True
        log(f"  claude still running in {move.pane_id} (attempt {attempt + 1})")
    return False


def relaunched(move: Move) -> bool:
    """Whether a claude other than the one that quit runs in the pane. herdr's
    agent record cannot tell: it keeps the old process - same label, same
    session id, status `done` - until it detects the new one."""
    proc = pane_claude_process(move.pane_id)
    return proc is not None and proc.get("pid") != move.pid


def nudge_agent(pane_id: str, nudge: str) -> str | None:
    """Prompt the resumed session, retrying while herdr refuses: right after
    a relaunch it can still hold the record of the process that quit and
    answer that the agent is no longer the pane's foreground process."""
    deadline = time.monotonic() + NUDGE_RETRY_SECONDS
    while True:
        error = herdr_error(herdr("agent", "prompt", pane_id, nudge, check=False))
        if error is None or time.monotonic() >= deadline:
            return error
        time.sleep(1)


def apply_move(move: Move, nudge: str | None, log) -> str:
    log(f"{move.pane_id} {move.session_id[:8]} {move.from_label}: {move.change}")
    if move.to_dir != move.from_dir:
        dest = copy_transcript(Path(move.transcript or ""), move.to_dir or "")
        log(f"  transcript copied to {dest}")

    if not quit_claude(move, log):
        return "failed: could not quit claude in the pane"
    command = relaunch_command(move)
    herdr("pane", "run", move.pane_id, command)
    log(f"  ran: {command}")

    if not wait_for(lambda: relaunched(move), timeout=45):
        return "failed: claude did not come back after the relaunch"
    status = settle_agent(move.pane_id, log)
    log(f"  agent {status}")
    # The relaunch can be cut short - by someone quitting and restarting
    # claude by hand in the same pane, say - and the nudge would then land
    # in whatever session the pane runs now, so make sure it is ours.
    if not wait_for(
        lambda: runs_session(move.pane_id, move.session_id),
        timeout=SESSION_CONFIRM_SECONDS,
    ):
        _, running = pane_session(move.pane_id)
        if pane_agent(move.pane_id).get("agent") != "claude":
            return "failed: claude exited again after the relaunch"
        return (
            f"failed: the pane runs session {running[:8] if running else 'unknown'}, "
            f"not {move.session_id[:8]}; nudge skipped"
        )
    screen = pane_screen(move.pane_id)
    if status == "blocked" or "Enter to confirm" in screen:
        return "resumed, but claude is waiting on a dialog; nudge skipped"
    if AUTO_CONTINUE_MARK in screen:
        # The resumed session would otherwise sit until the old account's
        # window resets, headroom or not; typing cancels it too, but the
        # nudge may be empty or refused.
        herdr("pane", "send-keys", move.pane_id, "esc", check=False)
        log("  cancelled claude's own wait for the old account's reset")
    if nudge:
        error = nudge_agent(move.pane_id, nudge)
        if error:
            return f"resumed, but the nudge failed: {error}"
        log("  nudged")
        return "resumed and nudged"
    return "resumed"


HOOK_ERRORS = {"rate_limit"}
HOOK_SETTLE_SECONDS = 3


def hook_skip_reason(payload: dict, env: dict[str, str]) -> str | None:
    """Why a StopFailure hook should do nothing, or None when it should rebump
    its own session. Claude Code reports a spent claude.ai limit as
    `rate_limit`, the same value the transcript record carries; every other
    failure is not ours to fix."""
    error = payload.get("error")
    if error not in HOOK_ERRORS:
        return f"error is {error!r}, not a usage limit"
    if not payload.get("session_id"):
        return "no session id in the hook payload"
    if not env.get("HERDR_PANE_ID"):
        return "not in a herdr pane"
    if shutil.which("herdr") is None:
        return "herdr is not on PATH"
    return None


def hook_lock_path(pane: str) -> Path:
    slug = re.sub(r"[^A-Za-z0-9_-]", "_", pane)
    return usage_cache_path().parent / f"hook-{slug}.pid"


def hook_log_path() -> Path:
    return usage_cache_path().parent / "hook.log"


def hook_log_write(text: str) -> None:
    path = hook_log_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(text)


def notify(move: Move, result: str) -> None:
    """Show the outcome in herdr: the pane itself only shows the resumed
    session, and a hook that gave up shows nothing at all."""
    fine = result.startswith("resumed and nudged") or result == "resumed"
    title = f"rebump {move.pane_id}: {move.change or 'left where it is'}"
    body = result if fine else f"{result}\nsee {hook_log_path()}"
    herdr(
        "notification",
        "show",
        title,
        "--body",
        body,
        "--sound",
        "none" if fine else "request",
        check=False,
    )


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def running_hook(lock: Path) -> int | None:
    try:
        pid = int(lock.read_text().strip())
    except (OSError, ValueError):
        return None
    return pid if pid_alive(pid) else None


def rebump_session(payload: dict, pane: str, env: dict[str, str], log) -> str:
    """The single-session flow: plan and apply the move for the one session a
    hook fired in, without looking at the rest of herdr."""
    # herdr commands from here on act on the pane from outside it.
    os.environ.pop("HERDR_PANE_ID", None)
    accounts, usage_note = read_usage(None, USAGE_MAX_AGE, CUSAGE_TIMEOUT)
    log(render_accounts(accounts))
    if usage_note:
        log(f"  ! {usage_note}")
    move = plan_move(accounts, session_from_hook(payload, pane, env))
    if move.actionable:
        result = apply_move(move, NUDGE, log)
    else:
        result = f"left where it is: {move.reason}"
    log(result)
    notify(move, result)
    return result


def detach(log: Path, work) -> int:
    """Fork `work` into its own session so it outlives the hook and the claude
    process the hook is running under, and return the child's pid."""
    log.parent.mkdir(parents=True, exist_ok=True)
    pid = os.fork()
    if pid:
        return pid
    code = 1
    try:
        os.setsid()
        devnull = os.open(os.devnull, os.O_RDONLY)
        out = os.open(str(log), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        os.dup2(devnull, 0)
        os.dup2(out, 1)
        os.dup2(out, 2)
        # The hook fires as the turn ends; give Claude Code a moment to flush
        # the limit record the plan reads from the transcript.
        time.sleep(HOOK_SETTLE_SECONDS)
        work()
        code = 0
    except SystemExit as exc:
        print(f"failed: {exc}")
    except Exception:
        traceback.print_exc()
    finally:
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(code)


def run_hook(stdin, log) -> int:
    """The StopFailure hook: rebump this session in the background and return
    at once. Claude Code ignores the exit code, so nothing here raises."""
    try:
        payload = json.load(stdin)
    except ValueError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    stamp = datetime.now().isoformat(timespec="seconds")
    pane = os.environ.get("HERDR_PANE_ID", "")
    session_id = payload.get("session_id", "")
    skip = hook_skip_reason(payload, dict(os.environ))
    if skip is not None:
        # Claude Code swallows what a hook prints, so the log is the only
        # place a skipped rebump can be seen afterwards.
        hook_log_write(f"\n== {stamp} {pane} {session_id} skipped: {skip}\n")
        log(f"rebump hook: {skip}")
        return 0
    lock = hook_lock_path(pane)
    running = running_hook(lock)
    if running is not None:
        hook_log_write(
            f"\n== {stamp} {pane} {session_id} skipped: a rebump is already "
            f"running (pid {running})\n"
        )
        log(f"rebump hook: a rebump of {pane} is already running (pid {running})")
        return 0
    lock.parent.mkdir(parents=True, exist_ok=True)
    hook_log_write(f"\n== {stamp} {pane} {session_id}\n")
    work = partial(rebump_session, payload, pane, dict(os.environ), print)
    pid = detach(hook_log_path(), work)
    lock.write_text(str(pid), encoding="utf-8")
    log(f"rebump hook: rebumping {pane} in the background (pid {pid})")
    return 0


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


def render_accounts(accounts: list[Account]) -> str:
    lines = ["accounts"]
    for a in accounts:
        if a.error:
            lines.append(f"  {a.label:<8} {a.email or '':<28} ! {a.error}")
            continue
        flags = " blocked" if a.weekly_blocked else ""
        if a.fable_spent and not a.weekly_blocked:
            flags += f"  (default {settings_model(a.config_dir) or PREFERRED_MODEL})"
        lines.append(
            f"  {a.label:<8} {a.email or '':<28} "
            f"5h {fmt_pct(a.session_used):>4} ({fmt_resets(a.session_resets)})  "
            f"week {fmt_pct(a.week_used):>4}  fable {fmt_pct(a.fable_used):>4}"
            f"{flags}"
        )
    return "\n".join(lines)


def render_panes(moves: list[Move]) -> str:
    lines = ["claude panes in herdr"]
    if not moves:
        lines.append("  none")
    for m in moves:
        where = Path(m.cwd).name
        lines.append(
            f"  {m.pane_id:<8} {m.session_id[:8]} {m.from_label:<8} {m.status:<8} "
            f"{where}: {m.title}"
        )
        if m.to_dir:
            lines.append(f"           would {m.change}: {m.reason}")
            if m.is_self:
                lines.append(
                    "           this pane cannot do it to itself; quit claude "
                    "here and run:"
                )
                lines.append(f"             {relaunch_command(m)}")
        elif m.reason != "not limited":
            lines.append(f"           stuck: {m.reason}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "action",
        nargs="?",
        choices=("plan", "apply", "pick", "hook"),
        default="plan",
        help="plan is read-only (default); apply performs the moves and model "
        "switches; pick prints the env prefix (CLAUDE_CONFIG_DIR=<dir>, or `env "
        "-u CLAUDE_CONFIG_DIR` for the default account, plus ANTHROPIC_MODEL "
        "when Fable is spent) a new session should start under; hook is the "
        "Claude Code StopFailure hook and rebumps the one session it fired in, "
        "in the background",
    )
    parser.add_argument(
        "--to",
        help="account to move to or pick, by cusage label, alias (claude3, c3) or "
        "config dir (default: the most Fable headroom, then the emptiest 5-hour "
        "window)",
    )
    parser.add_argument(
        "--pane", action="append", help="only these pane ids (repeatable)"
    )
    parser.add_argument(
        "--fallback-model",
        default=FALLBACK_MODEL,
        help="model to run when the account's Fable weekly cap is spent "
        f"(default: {FALLBACK_MODEL})",
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
    parser.add_argument(
        "--max-age",
        type=int,
        help="reuse the last cusage report if it is younger than this many "
        f"seconds (default: {USAGE_MAX_AGE}; 0 forces a fresh read)",
    )
    parser.add_argument(
        "--timeout", type=int, default=CUSAGE_TIMEOUT, help="cusage timeout"
    )
    args = parser.parse_args(argv)

    if args.action == "hook":
        return run_hook(sys.stdin, print)
    if args.max_age is None:
        args.max_age = USAGE_MAX_AGE
    accounts, usage_note = read_usage(args.usage, args.max_age, args.timeout)

    if args.action == "pick":
        account, model, prefix = launch_choice(accounts, args.to, args.fallback_model)
        if args.json:
            print(
                json.dumps(
                    {
                        "accounts": [asdict(a) for a in accounts],
                        "pick": asdict(account),
                        "model": model,
                    },
                    indent=2,
                )
            )
        else:
            print(render_accounts(accounts), file=sys.stderr)
            if usage_note:
                print(f"  ! {usage_note}", file=sys.stderr)
            note = f" on {model} (its fable weekly cap is spent)" if model else ""
            print(f"  -> {account.label}{note}", file=sys.stderr)
            print(prefix)
        return 0

    if shutil.which("herdr") is None:
        raise SystemExit("herdr is not on PATH")
    panes = claude_panes()
    if args.pane:
        panes = [p for p in panes if p["pane_id"] in set(args.pane)]
    if args.force and not args.pane:
        raise SystemExit("--force needs --pane: it would restart every claude pane")
    moves = build_plan(
        accounts, panes, args.to, force=args.force, fallback=args.fallback_model
    )

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
        print(render_accounts(accounts))
        if usage_note:
            print(f"  ! {usage_note}")
        print()
        print(render_panes(moves))

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
