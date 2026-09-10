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
        "model": "<synthetic>",
        "content": [{"type": "text", "text": "You've hit your session limit"}],
    },
}
MODEL_LIMIT_RECORD = {
    "type": "assistant",
    "error": "rate_limit",
    "isApiErrorMessage": True,
    "quotaLimits": {},
    "message": {
        "role": "assistant",
        "model": "<synthetic>",
        "content": [
            {
                "type": "text",
                "text": "You're out of usage credits. /model to switch models.",
            }
        ],
    },
}
FABLE_TURN = {
    "type": "assistant",
    "message": {
        "model": "claude-fable-5-1",
        "content": [{"type": "text", "text": "hi"}],
    },
}
OPUS_TURN = {
    "type": "assistant",
    "message": {"model": "claude-opus-5", "content": [{"type": "text", "text": "hi"}]},
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

    def test_target_has_the_most_fable_headroom_and_is_not_blocked(self):
        target = rebump.choose_target(
            self.accounts, exclude=self.accounts[0].config_dir
        )
        self.assertEqual(target.label, "c4")

    def test_fable_headroom_outranks_the_session_window(self):
        c2, c4 = self.accounts[1], self.accounts[3]
        c2.session_used, c2.fable_used = 70.0, 20.0
        c4.session_used, c4.fable_used = 10.0, 60.0
        self.assertEqual(rebump.choose_target(self.accounts).label, "c2")

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


class PickTest(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(rebump, "account_email", return_value=None)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.accounts = rebump.accounts_from_usage(USAGE)

    def test_picks_the_emptiest_usable_account(self):
        self.assertEqual(rebump.pick_account(self.accounts, None).label, "c4")

    def test_named_account_is_honoured_only_with_headroom(self):
        self.assertEqual(rebump.pick_account(self.accounts, "c2").label, "c2")
        with self.assertRaises(SystemExit) as caught:
            rebump.pick_account(self.accounts, "c3")
        self.assertIn("weekly cap", str(caught.exception))
        with self.assertRaises(SystemExit) as caught:
            rebump.pick_account(self.accounts, "claude")
        self.assertIn("100%", str(caught.exception))

    def test_spent_fable_cap_only_deprioritises_an_account(self):
        c4 = self.accounts[3]
        c4.fable_used = 100.0
        self.assertEqual(rebump.pick_account(self.accounts, None).label, "c2")
        self.assertEqual(rebump.pick_account(self.accounts, "c4").label, "c4")

    def test_last_account_standing_keeps_its_spent_fable_cap(self):
        for account in self.accounts[:3]:
            account.session_used = 100.0
        self.accounts[3].fable_used = 100.0
        self.assertEqual(rebump.pick_account(self.accounts, None).label, "c4")

    def test_refuses_when_every_account_is_spent(self):
        for account in self.accounts:
            account.session_used = 100.0
        with self.assertRaises(SystemExit) as caught:
            rebump.pick_account(self.accounts, None)
        self.assertIn("no account has headroom", str(caught.exception))

    def run_pick(self, usage, defaults=None):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "usage.json"
            path.write_text(json.dumps(usage))
            with (
                mock.patch.object(rebump.shutil, "which", return_value=None),
                mock.patch.object(
                    rebump,
                    "settings_model",
                    side_effect=lambda d: (defaults or {}).get(d),
                ),
                mock.patch("sys.stdout") as out,
                mock.patch("sys.stderr"),
            ):
                code = rebump.main(["pick", "--usage", str(path)])
        self.assertEqual(code, 0)
        return "".join(c.args[0] for c in out.write.call_args_list).strip()

    def test_pick_prints_env_assignment_and_skips_herdr(self):
        self.assertEqual(
            self.run_pick(USAGE),
            f"CLAUDE_CONFIG_DIR={rebump.normalize_config_dir('~/.claude4')}",
        )

    def only_fable_spent_account_left(self):
        """Every other subscription is out of its 5-hour window and the one
        left has spent its Fable cap: the account still runs another model."""
        usage = json.loads(json.dumps(USAGE))
        usage["accounts"][0]["limits"] = [
            {"id": "session", "used_percent": 63.0},
            {"id": "week_all", "used_percent": 77.0},
            {"id": "week_fable", "used_percent": 100.0},
        ]
        for account in usage["accounts"][1:]:
            account["weekly_blocked"] = False
            account["limits"] = [{"id": "session", "used_percent": 100.0}]
        return usage, rebump.normalize_config_dir("~/.claude")

    def test_pick_pins_the_fallback_when_the_account_defaults_to_fable(self):
        usage, default_dir = self.only_fable_spent_account_left()
        self.assertEqual(
            self.run_pick(usage, {default_dir: "claude-fable-5-1[1m]"}),
            "env -u CLAUDE_CONFIG_DIR ANTHROPIC_MODEL=opus",
        )

    def test_pick_leaves_an_account_that_already_defaults_off_fable(self):
        usage, default_dir = self.only_fable_spent_account_left()
        self.assertEqual(
            self.run_pick(usage, {default_dir: "opus[1m]"}),
            "env -u CLAUDE_CONFIG_DIR",
        )


class ModelSwitchTest(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(rebump, "account_email", return_value=None)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.account = rebump.accounts_from_usage(USAGE)[1]
        self.defaults = {}
        defaults = mock.patch.object(
            rebump, "settings_model", side_effect=lambda d: self.defaults.get(d)
        )
        defaults.start()
        self.addCleanup(defaults.stop)

    def switch(self, **kwargs):
        return rebump.model_switch(self.account, "opus", **kwargs)

    def test_spent_fable_cap_pins_the_fallback_for_a_fable_session(self):
        self.account.fable_used = 100.0
        self.assertEqual(self.switch(running="claude-fable-5-1"), ("opus", False))

    def test_a_session_already_off_fable_is_left_alone(self):
        self.account.fable_used = 100.0
        self.assertEqual(self.switch(running="claude-opus-5"), (None, False))
        self.assertEqual(self.switch(running="claude-sonnet-5"), (None, False))

    def test_the_accounts_own_default_decides_when_nothing_is_pinned(self):
        self.account.fable_used = 100.0
        self.defaults[self.account.config_dir] = "opus[1m]"
        self.assertEqual(self.switch(), (None, False))
        self.defaults[self.account.config_dir] = "claude-fable-5-1[1m]"
        self.assertEqual(self.switch(), ("opus", False))

    def test_a_reported_model_cap_pins_the_fallback_whatever_cusage_says(self):
        self.assertEqual(
            self.switch(running="claude-fable-5-1", model_limited=True),
            ("opus", False),
        )

    def test_fable_headroom_drops_a_pin_we_added_earlier(self):
        self.defaults[self.account.config_dir] = "claude-fable-5-1[1m]"
        self.assertEqual(self.switch(pinned="opus", running="opus"), (None, True))
        self.defaults[self.account.config_dir] = "opus[1m]"
        self.assertEqual(self.switch(pinned="opus", running="opus"), (None, False))

    def test_launch_prefix_unsets_what_it_has_to(self):
        default_dir = rebump.normalize_config_dir(None)
        self.assertEqual(
            rebump.launch_prefix(default_dir, "opus"),
            "env -u CLAUDE_CONFIG_DIR ANTHROPIC_MODEL=opus",
        )
        self.assertEqual(
            rebump.launch_prefix("/cfg/c2", None, unpin=True),
            "env -u ANTHROPIC_MODEL CLAUDE_CONFIG_DIR=/cfg/c2",
        )

    def test_session_model_reads_the_flag_then_the_environment(self):
        self.assertEqual(
            rebump.session_model(["claude", "--model", "opus"], {}), "opus"
        )
        self.assertEqual(
            rebump.session_model(["claude", "--model=sonnet"], {}), "sonnet"
        )
        self.assertEqual(
            rebump.session_model(["claude"], {"ANTHROPIC_MODEL": "opus"}), "opus"
        )
        self.assertIsNone(rebump.session_model(["claude", "--chrome"], {}))


class UsageCacheTest(unittest.TestCase):
    def test_fresh_cache_is_reused_and_stale_cache_is_refreshed(self):
        with tempfile.TemporaryDirectory() as tmp:
            calls = []

            def fake_cusage(timeout):
                calls.append(timeout)
                return {"accounts": [{"label": f"run{len(calls)}"}]}

            with (
                mock.patch.dict(os.environ, {"XDG_CACHE_HOME": tmp}),
                mock.patch.object(rebump, "run_cusage", side_effect=fake_cusage),
            ):
                first = rebump.load_usage(None, 300, 1)
                cached = rebump.load_usage(None, 300, 1)
                fresh = rebump.load_usage(None, 0, 1)
            self.assertEqual(first["accounts"][0]["label"], "run1")
            self.assertEqual(cached, first)
            self.assertEqual(fresh["accounts"][0]["label"], "run2")
            self.assertEqual(len(calls), 2)
            self.assertTrue((Path(tmp) / "rebump/usage.json").is_file())


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

    def test_drops_the_model_flag_when_the_environment_sets_one(self):
        argv = ["claude", "--model", "opus", "--chrome"]
        self.assertEqual(
            rebump.relaunch_argv(argv, "new", drop_model=True),
            ["claude", "--chrome", "--resume", "new"],
        )
        self.assertEqual(
            rebump.relaunch_argv(["claude", "--model=opus"], "new", drop_model=True),
            ["claude", "--resume", "new"],
        )


class TranscriptTest(unittest.TestCase):
    def records(self, records):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "s.jsonl"
            write_jsonl(path, records)
            return rebump.tail_records(path)

    def test_limit_message_when_last_assistant_turn_is_rate_limited(self):
        limit = rebump.limit_message(
            self.records(
                [
                    {"type": "user"},
                    FABLE_TURN,
                    LIMIT_RECORD,
                    {"type": "system"},
                    {"type": "last-prompt"},
                ]
            )
        )
        self.assertEqual(limit.text, "You've hit your session limit")
        self.assertEqual(limit.kind, "five_hour")
        self.assertFalse(limit.model_only)

    def test_a_per_model_cap_is_the_one_a_model_switch_fixes(self):
        limit = rebump.limit_message(self.records([FABLE_TURN, MODEL_LIMIT_RECORD]))
        self.assertIsNone(limit.kind)
        self.assertTrue(limit.model_only)

    def test_transcript_model_skips_the_synthetic_limit_messages(self):
        records = self.records([{"type": "user"}, FABLE_TURN, MODEL_LIMIT_RECORD])
        self.assertEqual(rebump.transcript_model(records), "claude-fable-5-1")
        self.assertIsNone(rebump.transcript_model(self.records([{"type": "user"}])))

    def test_no_limit_once_a_real_turn_follows(self):
        ok = {
            "type": "assistant",
            "message": {"content": [{"type": "text", "text": "hi"}]},
        }
        self.assertIsNone(
            rebump.limit_message(self.records([LIMIT_RECORD, {"type": "user"}, ok]))
        )

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
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        home = Path(tmp.name)
        for patcher in (
            mock.patch.object(rebump, "HOME", home),
            mock.patch.object(rebump, "DEFAULT_CONFIG_DIR", home / ".claude"),
            mock.patch.object(rebump, "account_email", return_value=None),
            mock.patch.dict(os.environ, {"HERDR_PANE_ID": "w9:p9"}),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.accounts = rebump.accounts_from_usage(
            {
                "accounts": [
                    {**a, "config_dir": str(home / a["config_dir"].lstrip("~/"))}
                    if a["config_dir"]
                    else a
                    for a in USAGE["accounts"]
                ]
            }
        )
        self.by_label = {a.label: a for a in self.accounts}
        self.panes = []
        self.envs = {}
        self.settings("claude1", "opus[1m]")
        self.settings("c2", "claude-fable-5-1[1m]")

    def settings(self, label, model):
        config_dir = Path(self.by_label[label].config_dir)
        config_dir.mkdir(parents=True, exist_ok=True)
        (config_dir / "settings.json").write_text(json.dumps({"model": model}))

    def dir_of(self, label):
        return self.by_label[label].config_dir

    def add_pane(self, session_id, label, records, env=None):
        config_dir = self.dir_of(label)
        slug = Path(config_dir) / "projects/-repo"
        slug.mkdir(parents=True, exist_ok=True)
        write_jsonl(slug / f"{session_id}.jsonl", records)
        pid = len(self.panes) + 1
        self.panes.append(
            {
                "pane_id": f"w1:p{pid}",
                "agent_session": {"value": session_id},
                "cwd": "/repo",
                "terminal_title_stripped": session_id,
                "agent_status": "idle",
            }
        )
        self.envs[pid] = dict(env or {})
        if config_dir != self.dir_of("claude1"):
            self.envs[pid]["CLAUDE_CONFIG_DIR"] = config_dir

    def plan(self, to_label=None, **kwargs):
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
                rebump, "process_env", side_effect=lambda pid: self.envs[pid]
            ),
        ):
            return rebump.build_plan(self.accounts, self.panes, to_label, **kwargs)

    def test_a_five_hour_limit_moves_the_session(self):
        self.add_pane("stuck", "claude1", [{"type": "user"}, OPUS_TURN, LIMIT_RECORD])
        (move,) = self.plan()
        self.assertEqual((move.from_label, move.to_label), ("claude1", "c4"))
        self.assertIn("hit your session limit", move.reason)
        self.assertIn("5h window is at 100%", move.reason)
        self.assertTrue(move.actionable)
        self.assertEqual(move.change, "move to c4")
        self.assertEqual(
            rebump.relaunch_command(move),
            f"CLAUDE_CONFIG_DIR={self.dir_of('c4')} claude --chrome --resume stuck",
        )

    def test_a_healthy_pane_is_left_alone(self):
        self.add_pane("fine", "c2", [{"type": "user"}, FABLE_TURN])
        (move,) = self.plan()
        self.assertIsNone(move.to_label)
        self.assertEqual(move.reason, "not limited")
        self.assertFalse(move.actionable)

    def test_a_spent_fable_cap_switches_model_where_the_session_is(self):
        self.by_label["c2"].fable_used = 100.0
        self.add_pane("fine", "c2", [{"type": "user"}, FABLE_TURN])
        (move,) = self.plan()
        self.assertEqual(move.to_dir, self.dir_of("c2"))
        self.assertEqual(move.model, "opus")
        self.assertIn("fable weekly cap is spent", move.reason)
        self.assertIn("runs claude-fable-5-1", move.reason)
        self.assertEqual(move.change, "restart here on opus")
        self.assertTrue(move.actionable)
        self.assertEqual(
            rebump.relaunch_command(move),
            f"CLAUDE_CONFIG_DIR={self.dir_of('c2')} ANTHROPIC_MODEL=opus "
            "claude --chrome --resume fine",
        )

    def test_a_spent_fable_cap_is_no_trouble_for_a_session_off_fable(self):
        claude1 = self.by_label["claude1"]
        claude1.session_used, claude1.fable_used = 63.0, 100.0
        self.add_pane("opus", "claude1", [{"type": "user"}, OPUS_TURN])
        (move,) = self.plan()
        self.assertIsNone(move.to_label)
        self.assertEqual(move.reason, "not limited")

    def test_a_reported_model_cap_switches_model_whatever_cusage_says(self):
        self.add_pane(
            "credits", "c4", [{"type": "user"}, FABLE_TURN, MODEL_LIMIT_RECORD]
        )
        (move,) = self.plan()
        self.assertEqual(move.to_dir, self.dir_of("c4"))
        self.assertEqual(move.model, "opus")
        self.assertIn("out of usage credits", move.reason)

    def test_a_model_cap_with_nowhere_left_to_switch_moves_instead(self):
        claude1 = self.by_label["claude1"]
        claude1.session_used = 63.0
        self.add_pane(
            "credits", "claude1", [{"type": "user"}, OPUS_TURN, MODEL_LIMIT_RECORD]
        )
        (move,) = self.plan()
        self.assertEqual(move.to_label, "c4")
        self.assertIsNone(move.model)

    def test_fable_headroom_on_the_target_drops_a_pin_we_added_earlier(self):
        self.settings("c4", "claude-fable-5-1[1m]")
        self.add_pane(
            "pinned",
            "c2",
            [{"type": "user"}, OPUS_TURN, LIMIT_RECORD],
            env={"ANTHROPIC_MODEL": "opus"},
        )
        (move,) = self.plan()
        self.assertEqual(move.to_label, "c4")
        self.assertTrue(move.unpin)
        self.assertEqual(move.change, "move to c4 on its default model")
        self.assertEqual(
            rebump.relaunch_command(move),
            f"env -u ANTHROPIC_MODEL CLAUDE_CONFIG_DIR={self.dir_of('c4')} "
            "claude --chrome --resume pinned",
        )

    def test_forced_target_moves_a_healthy_pane_but_not_onto_itself(self):
        self.add_pane("fine", "c2", [{"type": "user"}, FABLE_TURN])
        self.assertEqual(self.plan("c4", force=True)[0].to_label, "c4")
        stay = self.plan("c2", force=True)[0]
        self.assertIsNone(stay.to_label)
        self.assertIn("already on", stay.reason)


if __name__ == "__main__":
    unittest.main()
