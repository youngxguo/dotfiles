import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import rebump  # noqa: E402

USAGE = {
    "accounts": [
        {
            "label": "claude1",
            "config_dir": None,
            "error": None,
            "weekly_blocked": False,
            "limits": [
                {"id": "session", "used_percent": 100.0, "resets_at": None},
                {"id": "week_all", "used_percent": 57.0},
                {"id": "week_fable", "used_percent": 75.0},
            ],
        },
        {
            "label": "c2",
            "config_dir": "~/.claude2",
            "error": None,
            "weekly_blocked": False,
            "limits": [
                {"id": "session", "used_percent": 40.0},
                {"id": "week_all", "used_percent": 37.0},
                {"id": "week_fable", "used_percent": 25.0},
            ],
        },
        {
            "label": "c3",
            "config_dir": "~/.claude3",
            "error": None,
            "weekly_blocked": True,
            "limits": [
                {"id": "session", "used_percent": 10.0},
                {"id": "week_all", "used_percent": 100.0},
            ],
        },
        {
            "label": "c4",
            "config_dir": "~/.claude4",
            "error": None,
            "weekly_blocked": False,
            "limits": [
                {"id": "session", "used_percent": 12.0},
                {"id": "week_all", "used_percent": 17.0},
                {"id": "week_fable", "used_percent": 23.0},
            ],
        },
    ]
}

LIMIT_RECORD = {
    "type": "assistant",
    "error": "rate_limit",
    "isApiErrorMessage": True,
    "quotaLimits": {"status": "rejected", "rateLimitType": "five_hour"},
    "message": {
        "role": "assistant",
        "content": [{"type": "text", "text": "You've hit your session limit"}],
    },
}


def write_jsonl(path, records):
    path.write_text("".join(json.dumps(r) + "\n" for r in records), encoding="utf-8")


class AccountTest(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(rebump, "account_email", return_value=None)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.accounts = rebump.accounts_from_usage(USAGE)

    def test_default_account_resolves_to_dot_claude(self):
        self.assertEqual(
            self.accounts[0].config_dir, rebump.normalize_config_dir("~/.claude")
        )
        self.assertEqual(self.accounts[0].session_used, 100.0)
        self.assertEqual(self.accounts[0].fable_used, 75.0)

    def test_target_is_emptiest_session_window_that_is_not_blocked(self):
        # c3 has the emptiest 5h window but its weekly cap is spent; c4 is next.
        target = rebump.choose_target(
            self.accounts, exclude=self.accounts[0].config_dir
        )
        self.assertEqual(target.label, "c4")

    def test_target_excludes_the_source_account(self):
        c4 = self.accounts[3]
        target = rebump.choose_target(self.accounts, exclude=c4.config_dir)
        self.assertEqual(target.label, "c2")

    def test_full_session_window_is_not_a_target(self):
        for account in self.accounts:
            account.session_used = 95.0
        self.assertIsNone(rebump.choose_target(self.accounts, exclude=""))

    def test_resolve_account_by_label_alias_or_dir(self):
        self.assertEqual(rebump.resolve_account(self.accounts, "c2").label, "c2")
        self.assertEqual(rebump.resolve_account(self.accounts, "claude2").label, "c2")
        self.assertEqual(
            rebump.resolve_account(self.accounts, "~/.claude4").label, "c4"
        )
        self.assertEqual(
            rebump.resolve_account(self.accounts, "claude").label, "claude1"
        )
        with self.assertRaises(SystemExit):
            rebump.resolve_account(self.accounts, "claude9")


class RelaunchTest(unittest.TestCase):
    def test_strips_session_flags_and_duplicate_chrome(self):
        argv = ["claude", "--chrome", "--chrome", "--resume", "old", "-c"]
        self.assertEqual(
            rebump.relaunch_argv(argv, "new"),
            ["claude", "--chrome", "--resume", "new"],
        )

    def test_keeps_other_flags(self):
        argv = ["/usr/local/bin/claude", "--model", "opus", "--session-id=abc"]
        self.assertEqual(
            rebump.relaunch_argv(argv, "new"),
            ["/usr/local/bin/claude", "--model", "opus", "--resume", "new"],
        )


class TranscriptTest(unittest.TestCase):
    def test_limit_message_when_last_assistant_turn_is_rate_limited(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "s.jsonl"
            write_jsonl(
                path,
                [
                    {"type": "user"},
                    LIMIT_RECORD,
                    {"type": "system"},
                    {"type": "last-prompt"},
                ],
            )
            self.assertEqual(
                rebump.limit_message(path), "You've hit your session limit"
            )

    def test_no_limit_once_a_real_turn_follows(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "s.jsonl"
            ok = {
                "type": "assistant",
                "message": {"content": [{"type": "text", "text": "hi"}]},
            }
            write_jsonl(path, [LIMIT_RECORD, {"type": "user"}, ok])
            self.assertIsNone(rebump.limit_message(path))

    def test_copy_transcript_keeps_slug_and_sidecar(self):
        with tempfile.TemporaryDirectory() as tmp:
            src_dir = Path(tmp) / "a/projects/-repo"
            src_dir.mkdir(parents=True)
            src = src_dir / "sid.jsonl"
            write_jsonl(src, [{"type": "user"}])
            (src_dir / "sid/tool-results").mkdir(parents=True)
            (src_dir / "sid/tool-results/x.txt").write_text("x")
            dest = rebump.copy_transcript(src, str(Path(tmp) / "b"))
            self.assertEqual(dest, Path(tmp) / "b/projects/-repo/sid.jsonl")
            self.assertTrue(dest.is_file())
            self.assertTrue((dest.parent / "sid/tool-results/x.txt").is_file())


class PlanTest(unittest.TestCase):
    def test_plan_moves_limited_panes_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            with (
                mock.patch.object(rebump, "HOME", home),
                mock.patch.object(rebump, "DEFAULT_CONFIG_DIR", home / ".claude"),
                mock.patch.object(rebump, "account_email", return_value=None),
            ):
                accounts = rebump.accounts_from_usage(
                    {
                        "accounts": [
                            {
                                **a,
                                "config_dir": str(home / a["config_dir"].lstrip("~/")),
                            }
                            if a["config_dir"]
                            else a
                            for a in USAGE["accounts"]
                        ]
                    }
                )
                default_dir = accounts[0].config_dir
                c2_dir = accounts[1].config_dir
                for sid, cfg in (("stuck", default_dir), ("fine", c2_dir)):
                    slug = Path(cfg) / "projects/-repo"
                    slug.mkdir(parents=True)
                    records = [LIMIT_RECORD] if sid == "stuck" else [{"type": "user"}]
                    write_jsonl(slug / f"{sid}.jsonl", records)

                panes = [
                    {
                        "pane_id": "w1:p1",
                        "agent_session": {"value": "stuck"},
                        "cwd": "/repo",
                        "terminal_title_stripped": "A",
                        "agent_status": "idle",
                    },
                    {
                        "pane_id": "w1:p2",
                        "agent_session": {"value": "fine"},
                        "cwd": "/repo",
                        "terminal_title_stripped": "B",
                        "agent_status": "idle",
                    },
                ]
                envs = {1: {}, 2: {"CLAUDE_CONFIG_DIR": c2_dir}}
                with (
                    mock.patch.object(
                        rebump,
                        "pane_claude_process",
                        side_effect=lambda pane: {
                            "pid": int(pane[-1]),
                            "argv": ["claude", "--chrome"],
                        },
                    ),
                    mock.patch.object(
                        rebump, "process_env", side_effect=lambda pid: envs[pid]
                    ),
                    mock.patch.dict(os.environ, {"HERDR_PANE_ID": "w9:p9"}),
                ):
                    moves = rebump.build_plan(accounts, panes, None)
                    forced = rebump.build_plan(accounts, panes, "c2", force=True)

                stuck, fine = moves
                self.assertEqual(stuck.from_label, "claude1")
                self.assertEqual(stuck.to_label, "c4")
                self.assertIn("hit your session limit", stuck.reason)
                self.assertIn("5h window is at 100%", stuck.reason)
                self.assertTrue(stuck.actionable)
                self.assertEqual(
                    rebump.relaunch_command(stuck),
                    f"CLAUDE_CONFIG_DIR={accounts[3].config_dir} claude --chrome --resume stuck",
                )
                self.assertIsNone(fine.to_label)
                self.assertEqual(fine.reason, "not limited")
                self.assertFalse(fine.actionable)

                # --force moves a healthy pane, but never onto its own account.
                self.assertEqual(forced[0].to_label, "c2")
                self.assertIsNone(forced[1].to_label)
                self.assertIn("already on", forced[1].reason)


if __name__ == "__main__":
    unittest.main()
