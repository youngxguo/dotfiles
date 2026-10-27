import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import tomllib

SCRIPT = Path(__file__).with_name("statusline-command.sh")
REPO = Path(__file__).resolve().parent.parent


def setUpModule():
    # The script falls back to CLAUDE_CONFIG_DIR when a transcript path names
    # no account, so a run from a numbered Claude login would report that login.
    patcher = mock.patch.dict(os.environ)
    patcher.start()
    os.environ.pop("CLAUDE_CONFIG_DIR", None)
    unittest.addModuleCleanup(patcher.stop)


class StatuslineTest(unittest.TestCase):
    @staticmethod
    def fake_herdr(root):
        fake = root / "herdr"
        fake.write_text(
            "#!/bin/sh\n"
            'if [ "$1 $2" = "pane get" ]; then\n'
            '  printf \'{"result":{"pane":{"cwd":"%s","foreground_cwd":"%s"}}}\\n\' "$HERDR_PANE_CWD" "$HERDR_FOREGROUND_CWD"\n'
            "  exit\n"
            "fi\n"
            "source=unknown\n"
            "previous=\n"
            "for arg do\n"
            '  [ "$previous" = --source ] && source=$arg\n'
            "  previous=$arg\n"
            "done\n"
            'printf \'%s\\n\' "$@" > "$HERDR_REPORT_PATH.$source"\n',
            encoding="utf-8",
        )
        fake.chmod(0o755)
        return fake

    @staticmethod
    def wait_for_report(path, expected=3):
        for _ in range(100):
            reports = sorted(path.parent.glob(f"{path.name}.*"))
            if len(reports) == expected:
                return [
                    arg
                    for report in reports
                    for arg in report.read_text(encoding="utf-8").splitlines()
                ]
            time.sleep(0.01)
        raise AssertionError("statusline did not report all Herdr metadata")

    def statusline_environment(self, root, fake, report):
        env = os.environ.copy()
        env.update(
            {
                "HOME": str(root / "home"),
                "HERDR_BIN_PATH": str(fake),
                "HERDR_SOCKET_PATH": str(root / "herdr.sock"),
                "HERDR_PANE_ID": "w1:p1",
                "HERDR_PANE_CWD": str(root),
                "HERDR_FOREGROUND_CWD": "",
                "HERDR_REPORT_PATH": str(report),
            }
        )
        return env

    def test_clear_mode_removes_every_owned_token(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir:
            root = Path(tmpdir)
            report = root / "report"
            fake = self.fake_herdr(root)
            subprocess.run(
                ["sh", str(SCRIPT), "--clear-herdr-metadata"],
                check=True,
                cwd=root,
                env=self.statusline_environment(root, fake, report),
            )

            args = self.wait_for_report(report)
            self.assertEqual(args[:3], ["pane", "report-metadata", "w1:p1"])
            for token in (
                "title1",
                "title2",
                "title3",
                "repo",
                "repo_color_1",
                "repo_color_2",
                "repo_color_3",
                "repo_color_4",
                "repo_color_5",
                "repo_color_6",
                "branch",
                "model",
                "subscription",
                "model_fable",
                "model_opus",
                "model_sonnet",
                "model_haiku",
                "model_sol",
                "model_terra",
                "model_luna",
                "model_other",
                *(f"subscription_color_{n}" for n in range(1, 8)),
                "subscription_codex",
                "pr_open",
                "pr_draft",
                "pr_merged",
                "pr_closed",
            ):
                index = args.index(token)
                self.assertEqual(args[index - 1], "--clear-token")

    def test_new_subscriptions_are_reported_and_renderable(self):
        config = tomllib.loads((REPO / "herdr/config.toml").read_text())
        self.assertEqual(len(config["ui"]["sidebar"]["agents"]["rows"]), 6)
        for row in config["ui"]["sidebar"]["agents"]["rows"]:
            self.assertLessEqual(len(row), 16, "Herdr limits sidebar rows to 16 tokens")
        sidebar_tokens = {
            cell["token"]
            for row in config["ui"]["sidebar"]["agents"]["rows"]
            for cell in row
            if isinstance(cell, dict)
        }
        for account in (
            "c1",
            "c7",
            "c8",
            "c9",
            "c99",
            "c1000",
            ".claude-test",
            ".claude-é",
        ):
            with self.subTest(account=account), tempfile.TemporaryDirectory() as tmpdir:
                root = Path(tmpdir)
                report = root / "report"
                fake = self.fake_herdr(root)
                payload = {
                    "model": {"display_name": "Fable 5.1"},
                    "transcript_path": str(
                        root
                        / (
                            f".claude{account[1:]}"
                            if account.startswith("c")
                            else account
                        )
                        / "projects"
                        / "test.jsonl"
                    ),
                    "workspace": {"current_dir": str(root)},
                }
                subprocess.run(
                    ["sh", str(SCRIPT)],
                    input=json.dumps(payload),
                    text=True,
                    check=True,
                    capture_output=True,
                    env=self.statusline_environment(root, fake, report),
                )
                args = self.wait_for_report(report)
                published = [
                    arg
                    for arg in args
                    if arg.startswith("subscription_color_") and "=" in arg
                ]
                self.assertEqual(len(published), 1)
                token, label = published[0].split("=", 1)
                self.assertEqual(label, account)
                self.assertIn(f"${token}", sidebar_tokens)
                for other in [
                    *(f"subscription_color_{n}" for n in range(1, 8)),
                    "subscription_codex",
                ]:
                    if other != token:
                        self.assertEqual(args[args.index(other) - 1], "--clear-token")

    def test_pane_shows_account_email_but_sidebar_keeps_label(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir:
            root = Path(tmpdir)
            report = root / "report"
            fake = self.fake_herdr(root)
            config_dir = root / ".claude8"
            config_dir.mkdir()
            (config_dir / ".claude.json").write_text(
                json.dumps({"oauthAccount": {"emailAddress": "young@example.com"}}),
                encoding="utf-8",
            )
            payload = {
                "model": {"display_name": "Fable 5.1"},
                "transcript_path": str(config_dir / "projects" / "test.jsonl"),
                "workspace": {"current_dir": str(root)},
            }
            result = subprocess.run(
                ["sh", str(SCRIPT)],
                input=json.dumps(payload),
                text=True,
                check=True,
                capture_output=True,
                env=self.statusline_environment(root, fake, report),
            )
            self.assertIn("c8", result.stdout)
            self.assertIn("young@example.com", result.stdout)
            args = self.wait_for_report(report)
            self.assertIn("subscription_color_1=c8", args)
            self.assertFalse(any("example.com" in arg for arg in args))

    def test_unnamed_task_does_not_clear_parent_title_rows(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir:
            root = Path(tmpdir)
            report = root / "report"
            fake = self.fake_herdr(root)
            payload = {
                "cost": {"total_cost_usd": 0},
                "context_window": {},
                "model": {"display_name": "test"},
                "session_id": "transient-task",
                "transcript_path": str(root / "missing.jsonl"),
                "workspace": {"current_dir": str(root)},
            }
            subprocess.run(
                ["sh", str(SCRIPT)],
                input=json.dumps(payload),
                text=True,
                check=True,
                capture_output=True,
                env=self.statusline_environment(root, fake, report),
            )

            args = self.wait_for_report(report)
            self.assertFalse(
                any(arg.startswith("title") for arg in args),
                "an unnamed task must leave the parent session title alone",
            )

    def test_named_session_sets_title_and_clears_unused_rows(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir:
            root = Path(tmpdir)
            report = root / "report"
            fake = self.fake_herdr(root)
            payload = {
                "cost": {"total_cost_usd": 0},
                "context_window": {},
                "model": {"display_name": "Fable 5.1"},
                "session_id": "parent",
                "session_name": "Adversarial review",
                "transcript_path": str(root / "missing.jsonl"),
                "workspace": {"current_dir": str(root)},
            }
            subprocess.run(
                ["sh", str(SCRIPT)],
                input=json.dumps(payload),
                text=True,
                check=True,
                capture_output=True,
                env=self.statusline_environment(root, fake, report),
            )

            args = self.wait_for_report(report)
            self.assertIn("title1=Adversarial review", args)
            self.assertIn("model_fable=Fable 5.1", args)
            self.assertIn("subscription_color_1=c1", args)
            for token in ("title2", "title3"):
                index = args.index(token)
                self.assertEqual(args[index - 1], "--clear-token")

    def test_pr_is_reported_to_herdr_but_left_out_of_custom_statusline(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir:
            root = Path(tmpdir)
            workspace = root / "workspace"
            branch = "young/ui-design-system-guidance"
            subprocess.run(["git", "init", "-q", str(workspace)], check=True)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(workspace),
                    "symbolic-ref",
                    "HEAD",
                    f"refs/heads/{branch}",
                ],
                check=True,
            )
            (workspace / "tracked").write_text("test\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(workspace), "add", "tracked"], check=True)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(workspace),
                    "-c",
                    "user.name=test",
                    "-c",
                    "user.email=test@example.com",
                    "commit",
                    "-qm",
                    "initial",
                ],
                check=True,
            )

            report = root / "report"
            fake = self.fake_herdr(root)
            fake_gh = root / "gh"
            fake_gh.write_text("#!/bin/sh\nexit 99\n", encoding="utf-8")
            fake_gh.chmod(0o755)
            repo_root = subprocess.run(
                ["git", "-C", str(workspace), "rev-parse", "--show-toplevel"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            cache_name = "".join(
                char if char.isalnum() or char in "._-" else "_"
                for char in f"{repo_root}/{branch}"
            )
            pr_cache = root / "home/.claude/pr-cache" / cache_name
            pr_cache.parent.mkdir(parents=True)
            pr_cache.write_text(
                "open 4426 https://github.com/example/repo/pull/4426\n",
                encoding="utf-8",
            )

            payload = {
                "cost": {"total_cost_usd": 0},
                "context_window": {},
                "model": {"display_name": "Fable 5.1"},
                "session_id": "pr-session",
                "session_name": "PR session",
                "transcript_path": str(root / "missing.jsonl"),
                "workspace": {"current_dir": str(workspace)},
            }
            env = self.statusline_environment(root, fake, report)
            env["PATH"] = f"{root}{os.pathsep}{env['PATH']}"
            result = subprocess.run(
                ["sh", str(SCRIPT)],
                input=json.dumps(payload),
                text=True,
                check=True,
                capture_output=True,
                env=env,
            )

            self.assertNotIn("#4426", result.stdout)
            args = self.wait_for_report(report)
            self.assertIn("repo_color_5=📁 workspace", args)
            repo_index = args.index("repo")
            self.assertEqual(args[repo_index - 1], "--clear-token")
            self.assertIn("pr_open= #4426", args)

    def test_pr_lookup_skips_a_finished_pr_from_a_reused_branch_name(self):
        unrelated_oid = "a75bdd4d5307a5a327d277dcb0732f889f8aa713"
        cases = [
            ("open PR off this branch's history", "open", unrelated_oid, "open 7"),
            ("merged PR at this branch's head", "merged", "HEAD", "merged 7"),
            ("merged PR from a reused branch name", "merged", unrelated_oid, ""),
            ("closed PR from a reused branch name", "closed", unrelated_oid, ""),
        ]
        for name, state, head_oid, expected in cases:
            with (
                self.subTest(name),
                tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir,
            ):
                root = Path(tmpdir)
                workspace = root / "workspace"
                subprocess.run(["git", "init", "-q", str(workspace)], check=True)
                subprocess.run(
                    [
                        "git",
                        "-C",
                        str(workspace),
                        "-c",
                        "user.name=test",
                        "-c",
                        "user.email=test@example.com",
                        "commit",
                        "-q",
                        "--allow-empty",
                        "-m",
                        "initial",
                    ],
                    check=True,
                )
                if head_oid == "HEAD":
                    head_oid = subprocess.run(
                        ["git", "-C", str(workspace), "rev-parse", "HEAD"],
                        check=True,
                        capture_output=True,
                        text=True,
                    ).stdout.strip()

                report = root / "report"
                fake = self.fake_herdr(root)
                refresher_pid = root / "refresher-pid"
                fake_gh = root / "gh"
                fake_gh.write_text(
                    f"#!/bin/sh\necho $PPID $(ps -o ppid= -p $PPID) > '{refresher_pid}'\necho '{state} 7 {head_oid}'\n",
                    encoding="utf-8",
                )
                fake_gh.chmod(0o755)
                payload = {
                    "cost": {"total_cost_usd": 0},
                    "context_window": {},
                    "model": {"display_name": "Opus 5.5"},
                    "session_id": "pr-session",
                    "session_name": "PR session",
                    "transcript_path": str(root / "missing.jsonl"),
                    "workspace": {"current_dir": str(workspace)},
                }
                env = self.statusline_environment(root, fake, report)
                env["PATH"] = f"{root}{os.pathsep}{env['PATH']}"
                subprocess.run(
                    ["sh", str(SCRIPT)],
                    input=json.dumps(payload),
                    text=True,
                    check=True,
                    capture_output=True,
                    env=env,
                )

                self.wait_for_exit(refresher_pid)
                caches = list((root / "home/.claude/pr-cache").iterdir())
                self.assertEqual(
                    [cache.read_text(encoding="utf-8").strip() for cache in caches],
                    [expected],
                )

    @staticmethod
    def wait_for_exit(pid_file):
        def running(pid):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return False
            return True

        for _ in range(500):
            pids = (
                pid_file.read_text(encoding="utf-8").split()
                if pid_file.exists()
                else []
            )
            if pids and not any(running(int(pid)) for pid in pids if int(pid) > 1):
                return
            time.sleep(0.01)
        raise AssertionError("the PR cache refresh did not finish")

    def test_pr_cache_rechecks_a_live_pr_sooner_than_a_finished_one(self):
        cases = [
            ("open PR", "open 7", True),
            ("no PR yet", "", True),
            ("merged PR", "merged 7", False),
        ]
        for name, cached, expect_refresh in cases:
            with (
                self.subTest(name),
                tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir,
            ):
                root = Path(tmpdir)
                workspace = root / "workspace"
                subprocess.run(
                    ["git", "init", "-q", "-b", "feature", str(workspace)], check=True
                )
                subprocess.run(
                    [
                        "git",
                        "-C",
                        str(workspace),
                        "-c",
                        "user.name=test",
                        "-c",
                        "user.email=test@example.com",
                        "commit",
                        "-q",
                        "--allow-empty",
                        "-m",
                        "initial",
                    ],
                    check=True,
                )
                repo_root = subprocess.run(
                    ["git", "-C", str(workspace), "rev-parse", "--show-toplevel"],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.strip()
                cache_name = "".join(
                    char if char.isalnum() or char in "._-" else "_"
                    for char in f"{repo_root}/feature"
                )
                pr_cache = root / "home/.claude/pr-cache" / cache_name
                pr_cache.parent.mkdir(parents=True)
                pr_cache.write_text(cached and f"{cached}\n", encoding="utf-8")
                half_a_minute_ago = time.time() - 30
                os.utime(pr_cache, (half_a_minute_ago, half_a_minute_ago))

                report = root / "report"
                fake = self.fake_herdr(root)
                refresher_pid = root / "refresher-pid"
                fake_gh = root / "gh"
                fake_gh.write_text(
                    f"#!/bin/sh\necho $PPID $(ps -o ppid= -p $PPID) > '{refresher_pid}'\necho 'open 7 abc'\n",
                    encoding="utf-8",
                )
                fake_gh.chmod(0o755)
                payload = {
                    "cost": {"total_cost_usd": 0},
                    "context_window": {},
                    "model": {"display_name": "Opus 5.5"},
                    "session_id": "pr-session",
                    "transcript_path": str(root / "missing.jsonl"),
                    "workspace": {"current_dir": str(workspace)},
                }
                env = self.statusline_environment(root, fake, report)
                env["PATH"] = f"{root}{os.pathsep}{env['PATH']}"
                subprocess.run(
                    ["sh", str(SCRIPT)],
                    input=json.dumps(payload),
                    text=True,
                    check=True,
                    capture_output=True,
                    env=env,
                )

                if expect_refresh:
                    self.wait_for_exit(refresher_pid)
                    self.assertEqual(pr_cache.read_text(encoding="utf-8"), "open 7\n")
                else:
                    self.assertLess(time.time() - pr_cache.stat().st_mtime, 300 - 30)
                    self.assertFalse(refresher_pid.exists())

    def test_shared_daemon_does_not_report_to_another_workspace(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir:
            root = Path(tmpdir)
            wrong_workspace = root / "wrong"
            current_dir = root / "right" / "product"
            wrong_workspace.mkdir()
            current_dir.mkdir(parents=True)
            report = root / "report"
            fake = self.fake_herdr(root)
            payload = {
                "cost": {"total_cost_usd": 0},
                "context_window": {},
                "model": {"display_name": "test"},
                "session_id": "forked-session",
                "session_name": "Right workspace",
                "transcript_path": str(root / "missing.jsonl"),
                "workspace": {"current_dir": str(current_dir)},
            }
            env = self.statusline_environment(root, fake, report)
            env["HERDR_PANE_CWD"] = str(wrong_workspace)
            subprocess.run(
                ["sh", str(SCRIPT)],
                input=json.dumps(payload),
                text=True,
                check=True,
                capture_output=True,
                env=env,
            )

            self.assertFalse(list(root.glob("report.*")))

    def test_resumed_session_uses_the_panes_foreground_cwd(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir:
            root = Path(tmpdir)
            pane_cwd = root / "herdr-worktree"
            resumed_cwd = root / "claude-worktree"
            pane_cwd.mkdir()
            resumed_cwd.mkdir()
            report = root / "report"
            fake = self.fake_herdr(root)
            payload = {
                "cost": {"total_cost_usd": 0},
                "context_window": {},
                "model": {"display_name": "Fable 5.1"},
                "session_id": "resumed-session",
                "session_name": "Resumed session",
                "transcript_path": str(
                    root / "home/.claude4/projects/repo/session.jsonl"
                ),
                "workspace": {"current_dir": str(resumed_cwd)},
            }
            env = self.statusline_environment(root, fake, report)
            env["HERDR_PANE_CWD"] = str(pane_cwd)
            env["HERDR_FOREGROUND_CWD"] = str(resumed_cwd)
            subprocess.run(
                ["sh", str(SCRIPT)],
                input=json.dumps(payload),
                text=True,
                check=True,
                capture_output=True,
                env=env,
            )

            args = self.wait_for_report(report)
            self.assertIn("title1=Resumed session", args)
            self.assertIn("model_fable=Fable 5.1", args)
            self.assertIn("subscription_color_4=c4", args)


if __name__ == "__main__":
    unittest.main()
