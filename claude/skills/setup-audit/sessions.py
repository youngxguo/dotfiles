#!/usr/bin/env python3
"""Print every session in the audit window with the person's prompts.

Reads cseat's history database and each session's Claude Code transcript.
Read-only. Usage: sessions.py [--since 2026-11-02T09:00]
"""

import argparse
import datetime as dt
import json
import re
import sqlite3
from collections import Counter, defaultdict
from pathlib import Path

STATE = Path("~/.local/state").expanduser()
HISTORY = STATE / "cseat/history.sqlite3"
RUNS = STATE / "setup-audit/runs"
# Sessions that tools start: temp dirs, scratchpads, eval judges and run output.
SUBSESSION = re.compile(
    r"^/(private/)?(tmp|var/folders)/|scratchpad|eval-judge|-judge-|test_output|runlogs|batches"
)
MODEL_SWITCH = re.compile(r"Set model to\W*([\w .-]+?)\W* and saved")
# A transcript quiet for longer than this counts as idle until its next record.
IDLE_GAP = 30 * 60


def window_start(since):
    if since:
        return dt.datetime.fromisoformat(since).timestamp()
    today = dt.date.today().isoformat()
    stamps = (
        sorted(p for p in RUNS.glob("????-??-??") if p.name < today)
        if RUNS.is_dir()
        else []
    )
    if stamps:
        return stamps[-1].stat().st_mtime
    return (dt.datetime.now() - dt.timedelta(hours=24)).timestamp()


def epoch(timestamp):
    return dt.datetime.fromisoformat(timestamp.replace("Z", "+00:00")).timestamp()


def local(seconds):
    return dt.datetime.fromtimestamp(seconds).strftime("%m-%d %H:%M")


def classify(text):
    """(kind, text) for a user record's string content."""
    body = text.strip()
    if body.startswith("<command-name>"):
        name = re.search(r"<command-name>(.*?)</command-name>", body, re.S)
        args = re.search(r"<command-args>(.*?)</command-args>", body, re.S)
        return (
            "command",
            f"{name.group(1) if name else '?'} {args.group(1) if args else ''}".strip(),
        )
    if body.startswith("This session is being continued"):
        return "compaction", ""
    if body.startswith("<pasted_content"):
        inner = re.sub(r"^<pasted_content[^>]*>\s*", "", body)
        if inner.startswith("This branch starts from"):
            return "kickoff", inner
        if inner.startswith("Handoff from"):
            return "handoff", inner
        return "typed", body
    if body.startswith("<"):
        return None, ""
    return "typed", body


def read_transcript(path, since):
    out = {
        "prompts": [],
        "prs": set(),
        "titles": [],
        "models": [],
        "compactions": 0,
        "stamps": [],
    }
    for line in path.open(errors="replace"):
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = record.get("type")
        if kind == "ai-title" and record.get("aiTitle"):
            out["titles"].append(record["aiTitle"])
        if kind == "pr-link" and record.get("prUrl"):
            out["prs"].add(record["prUrl"])
        stamp = record.get("timestamp")
        if not stamp or epoch(stamp) < since:
            continue
        out["stamps"].append(epoch(stamp))
        if kind != "user" or record.get("isMeta"):
            continue
        content = (record.get("message") or {}).get("content")
        if not isinstance(content, str):
            continue
        switch = MODEL_SWITCH.search(content)
        if switch:
            out["models"].append(switch.group(1))
        what, text = classify(content)
        if what == "compaction":
            out["compactions"] += 1
        elif what:
            out["prompts"].append((epoch(stamp), what, text))
    return out


def active_spans(stamps):
    """(start, end) stretches of a transcript's records, split at idle gaps."""
    spans = []
    for stamp in sorted(stamps):
        if spans and stamp - spans[-1][1] <= IDLE_GAP:
            spans[-1][1] = stamp
        else:
            spans.append([stamp, stamp])
    return spans


def peak_concurrency(spans):
    """(when, how many) at the moment the most transcripts were active at once."""
    events = sorted([(a, 1) for a, _ in spans] + [(b, -1) for _, b in spans])
    live, best = 0, (None, 0)
    for when, step in events:
        live += step
        if live > best[1]:
            best = (when, live)
    return best


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--since", help="window start, local ISO time; default: last run"
    )
    parser.add_argument("--width", type=int, default=1500, help="characters per prompt")
    args = parser.parse_args()
    since = window_start(args.since)

    db = sqlite3.connect(f"file:{HISTORY}?mode=ro", uri=True)
    rows = db.execute(
        "select session_id, name, cwd, first_seen, last_seen, last_seat, transcript "
        "from session_info where last_seen >= ? order by first_seen",
        (since,),
    ).fetchall()
    output = defaultdict(int)
    for session_id, model, out in db.execute(
        "select session_id, model, sum(output) from session_tokens where at >= ? "
        "group by session_id, model",
        (since,),
    ):
        output[session_id] += out or 0
    by_model = db.execute(
        "select model, sum(output) from session_tokens where at >= ? group by model",
        (since,),
    ).fetchall()

    # One transcript can back several session rows (a handoff between seats).
    sessions = defaultdict(list)
    skipped, missing = 0, []
    for row in rows:
        session_id, name, cwd, *_, transcript = row
        if SUBSESSION.search(cwd or ""):
            skipped += 1
        elif not transcript or not Path(transcript).is_file():
            missing.append(f"{name} ({session_id}): {transcript or 'no path'}")
        else:
            sessions[transcript].append(row)

    totals = Counter()
    blocks = []
    spans = []
    for transcript, group in sessions.items():
        read = read_transcript(Path(transcript), since)
        spans += active_spans(read["stamps"])
        kinds = Counter(kind for _, kind, _ in read["prompts"])
        totals.update(kinds)
        totals["compaction"] += read["compactions"]
        name, cwd = group[0][1], group[0][2]
        seats = ",".join(sorted({row[5] for row in group if row[5]}))
        tokens = sum(output[row[0]] for row in group)
        blocks.append(
            f"## {name} [{seats}] {local(group[0][3])}–{local(group[-1][4])} {cwd}\n"
            f"   titles: {' → '.join(dict.fromkeys(read['titles'])) or '-'}\n"
            f"   prs: {' '.join(sorted(read['prs'])) or '-'}   output: {tokens:,}"
            f"   compactions: {read['compactions']}   models: {', '.join(read['models']) or '-'}"
        )
        for when, kind, text in read["prompts"]:
            text = text if kind == "typed" else text[:300]
            blocks.append(f"  - {local(when)} {kind}: {text[: args.width]}")

    print(f"window: {local(since)} to {local(dt.datetime.now().timestamp())}")
    print(
        f"sessions: {len(sessions)} with a transcript, {len(missing)} missing, "
        f"{skipped} tool sub-sessions left out"
    )
    print(
        f"records: {totals['typed']} typed, {totals['kickoff']} kickoffs, "
        f"{totals['handoff']} handoffs, {totals['command']} slash commands, "
        f"{totals['compaction']} compactions"
    )
    when, most = peak_concurrency(spans)
    if most:
        print(
            f"peak concurrency: {most} sessions at {local(when)} "
            f"(transcripts with a record in the same stretch, idle after {IDLE_GAP // 60} min)"
        )
    print("output tokens: " + ", ".join(f"{m} {o:,}" for m, o in by_model))
    for line in missing:
        print(f"missing transcript: {line}")
    print()
    print("\n".join(blocks))


if __name__ == "__main__":
    main()
