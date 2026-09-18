import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest import mock

import install


class PiConfigInstallTest(unittest.TestCase):
    def test_install_pi_links_settings_themes_and_is_idempotent(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-pi-test-") as tmpdir:
            root = Path(tmpdir)
            home = root / "home"
            repo = root / "repo"
            source = repo / "pi/settings.json"
            source.parent.mkdir(parents=True)
            source.write_text('{"theme": "dark"}\n', encoding="utf-8")
            theme = repo / "pi/themes/custom.json"
            theme.parent.mkdir()
            theme.write_text('{"name": "custom"}\n', encoding="utf-8")

            target = home / ".pi/agent/settings.json"
            target.parent.mkdir(parents=True)
            target.write_text('{"theme": "stale"}\n', encoding="utf-8")

            with (
                mock.patch.object(install, "HOME", home),
                mock.patch.object(install, "REPO_ROOT", repo),
                mock.patch.object(install, "install_pi_cli"),
                mock.patch.object(install, "install_pi_herdr_integration"),
                mock.patch.object(install, "pi_installed", return_value=True),
            ):
                install.install_pi()
                self.assertTrue(target.is_symlink())
                self.assertEqual(target.resolve(), source.resolve())
                self.assertEqual(
                    len(list(target.parent.glob("settings.json.bak.*"))), 1
                )
                self.assertEqual(
                    (home / ".pi/agent/themes/custom.json").resolve(), theme.resolve()
                )

                target.write_text('{"theme": "custom"}\n', encoding="utf-8")
                self.assertEqual(source.read_text(encoding="utf-8"), target.read_text())

                install.install_pi()
                self.assertTrue(target.is_symlink())
                self.assertEqual(
                    len(list(target.parent.glob("settings.json.bak.*"))), 1
                )

    def test_latest_claude_synced_bundle_gets_a_stable_pi_path(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-pi-test-") as tmpdir:
            home = Path(tmpdir) / "home"
            synced = home / ".claude/skills/synced"
            older = synced / "older/docs"
            newer = synced / "newer/docs"
            older.mkdir(parents=True)
            newer.mkdir(parents=True)
            (older / "SKILL.md").write_text("old", encoding="utf-8")
            (newer / "SKILL.md").write_text("new", encoding="utf-8")
            os.utime(older.parent, (1, 1))
            os.utime(newer.parent, (2, 2))

            with mock.patch.object(install, "HOME", home):
                install.link_pi_claude_synced_skills()

            target = home / ".pi/agent/claude-synced-skills"
            self.assertTrue(target.is_symlink())
            self.assertEqual(target.resolve(), newer.parent.resolve())


class PiCliInstallTest(unittest.TestCase):
    @staticmethod
    def pi_patches(home, repo, prefix, npm_installed):
        return (
            mock.patch.object(install, "HOME", home),
            mock.patch.object(install, "REPO_ROOT", repo),
            mock.patch.object(install, "npm_global_prefix", return_value=prefix),
            mock.patch.object(install, "node_version", return_value=(22, 19, 0)),
            mock.patch.object(
                install,
                "command_exists",
                side_effect=lambda cmd: npm_installed and cmd == "npm",
            ),
        )

    def test_install_pi_installs_the_cli_once(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-pi-cli-test-") as tmpdir:
            root = Path(tmpdir)
            home = root / "home"
            repo = root / "repo"
            prefix = root / "prefix"
            (prefix / "bin").mkdir(parents=True)
            source = repo / "pi/settings.json"
            source.parent.mkdir(parents=True)
            source.write_text('{"theme": "dark"}\n', encoding="utf-8")

            with ExitStack() as stack:
                for patch in self.pi_patches(home, repo, prefix, npm_installed=False):
                    stack.enter_context(patch)
                package_mock = stack.enter_context(
                    mock.patch.object(install, "install_package")
                )
                run_mock = stack.enter_context(mock.patch.object(install, "run"))
                install.install_pi()

            self.assertIn(mock.call("node"), package_mock.mock_calls)
            run_mock.assert_not_called()

            with ExitStack() as stack:
                for patch in self.pi_patches(home, repo, prefix, npm_installed=True):
                    stack.enter_context(patch)
                run_mock = stack.enter_context(mock.patch.object(install, "run"))
                install.install_pi()

            self.assertEqual(
                [call.args[0] for call in run_mock.mock_calls],
                [["npm", "install", "-g", "--ignore-scripts", install.PI_NPM_PACKAGE]],
            )
            self.assertEqual(
                (home / ".pi/agent/settings.json").resolve(), source.resolve()
            )

            (prefix / "bin/pi").touch()
            with ExitStack() as stack:
                for patch in self.pi_patches(home, repo, prefix, npm_installed=True):
                    stack.enter_context(patch)
                run_mock = stack.enter_context(mock.patch.object(install, "run"))
                install.install_pi()
            run_mock.assert_not_called()

    def test_install_pi_cli_skips_an_old_node(self):
        with (
            mock.patch.object(install, "command_exists", return_value=True),
            mock.patch.object(install, "node_version", return_value=(20, 19, 0)),
            mock.patch.object(install, "run") as run_mock,
        ):
            install.install_pi_cli()
        run_mock.assert_not_called()

    def test_install_pi_herdr_integration_when_missing_or_outdated(self):
        with (
            mock.patch.object(install, "herdr_command", return_value="herdr"),
            mock.patch.object(
                install.subprocess,
                "check_output",
                return_value="pi: not installed (~/.pi/agent/extensions/herdr-agent-state.ts)\n",
            ),
            mock.patch.object(install, "run") as run_mock,
        ):
            install.install_pi_herdr_integration()

        run_mock.assert_called_once_with(["herdr", "integration", "install", "pi"])

    def test_install_pi_skips_current_herdr_integration(self):
        with (
            mock.patch.object(install, "herdr_command", return_value="herdr"),
            mock.patch.object(
                install.subprocess,
                "check_output",
                return_value="pi: current (v8) (~/.pi/agent/extensions/herdr-agent-state.ts)\n",
            ),
            mock.patch.object(install, "run") as run_mock,
        ):
            install.install_pi_herdr_integration()

        run_mock.assert_not_called()


class HerdrInstallTest(unittest.TestCase):
    def test_agent_sidebar_color_namespaces_do_not_reuse_shades(self):
        config_path = Path(__file__).parent / "herdr/config.toml"
        config = config_path.read_text(encoding="utf-8")
        prefixes = ("$repo_color_", "$pr_", "$subscription_", "$model_")
        colors = {}

        for line in config.splitlines():
            token_match = re.search(r'token = "(\$[^"]+)"', line)
            color_match = re.search(r'fg = "(#[0-9a-fA-F]{6})"', line)
            if not token_match or not color_match:
                continue
            token = token_match.group(1)
            if not token.startswith(prefixes):
                continue
            color = color_match.group(1).lower()
            self.assertNotIn(
                color,
                colors,
                f"{token} reuses the shade assigned to {colors.get(color)}",
            )
            colors[color] = token

        self.assertTrue(
            any(token.startswith("$repo_color_") for token in colors.values())
        )
        self.assertTrue(
            any(token.startswith("$subscription_") for token in colors.values())
        )
        self.assertTrue(any(token.startswith("$model_") for token in colors.values()))

    def test_install_herdr_downloads_once_then_links_config(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-herdr-test-") as tmpdir:
            root = Path(tmpdir)
            home = root / "home"
            repo = root / "repo"
            source = repo / "herdr/config.toml"
            source.parent.mkdir(parents=True)
            source.write_text("onboarding = false\n", encoding="utf-8")
            auto_title_source = repo / "herdr/auto-title.env"
            auto_title_source.write_text(
                "HERDR_AUTO_TITLE_POSITION=false\n", encoding="utf-8"
            )

            target = home / ".config/herdr/config.toml"

            with (
                mock.patch.object(install, "HOME", home),
                mock.patch.object(install, "REPO_ROOT", repo),
                mock.patch.object(install, "command_exists", return_value=False),
                mock.patch.object(install, "run") as run_mock,
            ):
                install.install_herdr()
                self.assertEqual(len(run_mock.mock_calls), 1)
                self.assertIn(
                    install.HERDR_INSTALL_URL, run_mock.mock_calls[0].args[0][-1]
                )
                self.assertEqual(target.resolve(), source.resolve())
                auto_title_target = install.herdr_auto_title_config_path()
                self.assertTrue(auto_title_target.is_relative_to(home))
                if sys.platform == "darwin":
                    self.assertEqual(
                        auto_title_target,
                        home
                        / "Library/Application Support/herdr-auto-title/config.env",
                    )
                else:
                    self.assertEqual(
                        auto_title_target, home / ".config/herdr-auto-title/config.env"
                    )
                self.assertEqual(
                    auto_title_target.resolve(), auto_title_source.resolve()
                )

                binary = home / ".local/bin/herdr"
                binary.parent.mkdir(parents=True, exist_ok=True)
                binary.touch()

                run_mock.reset_mock()
                install.install_herdr()
                run_mock.assert_not_called()
                self.assertTrue(target.is_symlink())


class HerdrPluginInstallTest(unittest.TestCase):
    def test_install_herdr_plugins_installs_missing_then_skips_installed(self):
        repo, plugin_id = install.HERDR_PLUGINS[0]

        with (
            mock.patch.object(install, "herdr_command", return_value="herdr"),
            mock.patch.object(
                install.subprocess, "check_output", return_value="No plugins installed."
            ),
            mock.patch.object(install, "run") as run_mock,
        ):
            install.install_herdr_plugins()

        commit = install.lazy_lock_commit(repo.rsplit("/", 1)[-1])
        self.assertIsNotNone(commit, "herdr-splits is missing from lazy-lock.json")
        commands = [call.args[0] for call in run_mock.mock_calls]
        self.assertIn(
            ["herdr", "plugin", "install", repo, "--ref", commit, "-y"], commands
        )
        for other_repo, _ in install.HERDR_PLUGINS[1:]:
            self.assertIn(["herdr", "plugin", "install", other_repo, "-y"], commands)
        for relative_path, _ in install.HERDR_LOCAL_PLUGINS:
            plugin_dir = install.REPO_ROOT / relative_path
            self.assertTrue((plugin_dir / "herdr-plugin.toml").is_file())
            self.assertIn(["herdr", "plugin", "link", str(plugin_dir)], commands)

        installed = "".join(
            f"- {installed_id} enabled\n"
            for _, installed_id in (
                *install.HERDR_PLUGINS,
                *install.HERDR_LOCAL_PLUGINS,
            )
        )
        with (
            mock.patch.object(install, "herdr_command", return_value="herdr"),
            mock.patch.object(
                install.subprocess,
                "check_output",
                side_effect=[installed, "status: running\n"],
            ),
            mock.patch.object(install, "run") as run_mock,
        ):
            install.install_herdr_plugins()

        commands = [call.args[0] for call in run_mock.mock_calls]
        self.assertEqual(commands, [["herdr", "server", "reload-config"]])

    def test_install_herdr_plugins_skips_without_herdr(self):
        with (
            mock.patch.object(install, "herdr_command", return_value=None),
            mock.patch.object(install, "run") as run_mock,
        ):
            install.install_herdr_plugins()
        run_mock.assert_not_called()


class ClaudeInstallTest(unittest.TestCase):
    SKILL = "---\nname: herdr\ndescription: control herdr\n---\n\n# Herdr\n"

    @staticmethod
    def make_repo(root):
        repo = root / "repo"
        (repo / "claude/hooks").mkdir(parents=True)
        (repo / "claude/CLAUDE.md").write_text("# rules\n", encoding="utf-8")
        (repo / "claude/statusline-command.sh").write_text("", encoding="utf-8")
        (repo / "claude/settings.json").write_text(
            json.dumps(
                {
                    "permissions": {"defaultMode": "plan"},
                    "statusLine": {"type": "command"},
                    "hooks": {
                        "StopFailure": [
                            {"matcher": "rate_limit", "hooks": [{"type": "command"}]}
                        ]
                    },
                }
            )
            + "\n",
            encoding="utf-8",
        )
        return repo

    def test_install_claude_covers_every_config_dir(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir:
            root = Path(tmpdir)
            home = root / "home"
            repo = self.make_repo(root)

            with (
                mock.patch.object(install, "HOME", home),
                mock.patch.object(install, "REPO_ROOT", repo),
                mock.patch.object(install, "herdr_command", return_value="herdr"),
                mock.patch.object(install, "install_claude_herdr_integrations"),
                mock.patch.object(
                    install.subprocess, "check_output", return_value=self.SKILL
                ) as skill_mock,
            ):
                install.install_claude()

                config_dirs = install.claude_config_dirs()
                self.assertEqual(
                    [d.name for d in config_dirs],
                    [
                        ".claude",
                        ".claude2",
                        ".claude3",
                        ".claude4",
                        ".claude5",
                        ".claude6",
                    ],
                )
                for config_dir in config_dirs:
                    self.assertEqual(
                        (config_dir / "CLAUDE.md").resolve(),
                        (repo / "claude/CLAUDE.md").resolve(),
                    )
                    skill = config_dir / "skills/herdr/SKILL.md"
                    self.assertFalse(skill.is_symlink())
                    self.assertEqual(skill.read_text(encoding="utf-8"), self.SKILL)
                skill_mock.assert_called_once()
                self.assertEqual(skill_mock.call_args.args[0], ["herdr", "--skill"])
                primary = json.loads(
                    (home / ".claude/settings.json").read_text(encoding="utf-8")
                )
                secondary = json.loads(
                    (home / ".claude2/settings.json").read_text(encoding="utf-8")
                )
                self.assertIn("permissions", primary)
                self.assertEqual(
                    secondary.get("permissions"), primary.get("permissions")
                )
                self.assertEqual(secondary.get("statusLine"), primary.get("statusLine"))
                for config_dir in config_dirs:
                    global_config = json.loads(
                        install.claude_global_config_path(config_dir).read_text(
                            encoding="utf-8"
                        )
                    )
                    self.assertIs(global_config.get("lspRecommendationDisabled"), True)
                template = json.loads(
                    (repo / "claude/settings.json").read_text(encoding="utf-8")
                )
                self.assertEqual(primary.get("hooks"), template["hooks"])
                self.assertEqual(secondary.get("hooks"), template["hooks"])

                skill_path = home / ".claude/skills/herdr/SKILL.md"
                before = skill_path.stat().st_mtime_ns
                install.install_claude()
                self.assertEqual(skill_path.stat().st_mtime_ns, before)

                skill_mock.return_value = self.SKILL + "\n## New section\n"
                install.install_claude()
                self.assertTrue(
                    skill_path.read_text(encoding="utf-8").endswith("## New section\n")
                )

    def test_merge_claude_settings_supports_cseat_shared_logins(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir:
            root = Path(tmpdir)
            home = root / "home"
            repo = root / "repo"
            (repo / "claude").mkdir(parents=True)
            conditional_hook = [
                {
                    "hooks": [
                        {
                            "type": "command",
                            "command": 'test -n "$CSEAT_SEAT" || rebump',
                        }
                    ]
                }
            ]
            (repo / "claude/settings.json").write_text(
                json.dumps(
                    {
                        "permissions": {},
                        "hooks": {"Stop": [], "StopFailure": conditional_hook},
                    }
                ),
                encoding="utf-8",
            )
            primary = home / ".claude/settings.json"
            primary.parent.mkdir(parents=True)
            primary.write_text(
                json.dumps(
                    {
                        "hooks": {
                            "SessionStart": [{"hooks": []}],
                            "StopFailure": [{"matcher": "rate_limit"}],
                        }
                    }
                ),
                encoding="utf-8",
            )
            secondary = home / ".claude2/settings.json"
            secondary.parent.mkdir(parents=True)
            secondary.symlink_to(primary)

            with (
                mock.patch.object(install, "HOME", home),
                mock.patch.object(install, "REPO_ROOT", repo),
            ):
                install.merge_claude_settings()

            settings = json.loads(primary.read_text(encoding="utf-8"))
            self.assertIn("SessionStart", settings["hooks"])
            self.assertIn("Stop", settings["hooks"])
            self.assertEqual(settings["hooks"]["StopFailure"], conditional_hook)
            self.assertTrue(secondary.is_symlink())

    def test_merge_claude_global_config_preserves_account_state(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir:
            home = Path(tmpdir) / "home"
            state_path = home / ".claude3/.claude.json"
            state_path.parent.mkdir(parents=True)
            state_path.write_text(
                json.dumps({"oauthAccount": {"emailAddress": "young@example.com"}}),
                encoding="utf-8",
            )

            with mock.patch.object(install, "HOME", home):
                install.merge_claude_global_config()

            state = json.loads(state_path.read_text(encoding="utf-8"))
            self.assertEqual(
                state.get("oauthAccount"), {"emailAddress": "young@example.com"}
            )
            self.assertIs(state.get("lspRecommendationDisabled"), True)
            self.assertIs(
                json.loads((home / ".claude.json").read_text(encoding="utf-8")).get(
                    "lspRecommendationDisabled"
                ),
                True,
            )

    def test_install_claude_herdr_integrations_cover_every_config_dir(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir:
            home = Path(tmpdir) / "home"
            with (
                mock.patch.object(install, "HOME", home),
                mock.patch.object(install, "herdr_command", return_value="herdr"),
                mock.patch.object(
                    install.subprocess,
                    "check_output",
                    return_value="claude: not installed (~/.claude/hooks/herdr-agent-state.sh)\n",
                ) as status_mock,
                mock.patch.object(install, "run") as run_mock,
            ):
                install.install_claude_herdr_integrations()

            config_dirs = [home / ".claude"] + [
                home / f".claude{number}" for number in (2, 3, 4, 5, 6)
            ]
            self.assertEqual(len(run_mock.mock_calls), 6)
            self.assertEqual(status_mock.call_count, 6)
            for status_call, run_call, config_dir in zip(
                status_mock.mock_calls, run_mock.mock_calls, config_dirs, strict=True
            ):
                self.assertEqual(
                    status_call.kwargs["env"]["CLAUDE_CONFIG_DIR"], str(config_dir)
                )
                self.assertEqual(
                    run_call.args[0], ["herdr", "integration", "install", "claude"]
                )
                self.assertEqual(
                    run_call.kwargs["env"]["CLAUDE_CONFIG_DIR"], str(config_dir)
                )

    def test_remove_cross_account_claude_herdr_hooks(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir:
            home = Path(tmpdir) / "home"
            config_dir = home / ".claude2"
            config_dir.mkdir(parents=True)
            settings_path = config_dir / "settings.json"
            own_hook = f"bash '{config_dir}/hooks/herdr-agent-state.sh' session"
            settings_path.write_text(
                json.dumps(
                    {
                        "hooks": {
                            "SessionStart": [
                                {
                                    "hooks": [
                                        {
                                            "type": "command",
                                            "command": f"bash '{home}/.claude/hooks/herdr-agent-state.sh' session",
                                        },
                                        {"type": "command", "command": own_hook},
                                        {"type": "command", "command": "echo keep-me"},
                                    ]
                                }
                            ]
                        }
                    }
                ),
                encoding="utf-8",
            )

            install.remove_cross_account_claude_herdr_hooks(config_dir)

            settings = json.loads(settings_path.read_text(encoding="utf-8"))
            commands = [
                hook["command"]
                for group in settings["hooks"]["SessionStart"]
                for hook in group["hooks"]
            ]
            self.assertEqual(commands, [own_hook, "echo keep-me"])

    def test_install_claude_herdr_integrations_skip_current_accounts(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir:
            home = Path(tmpdir) / "home"
            with (
                mock.patch.object(install, "HOME", home),
                mock.patch.object(install, "herdr_command", return_value="herdr"),
                mock.patch.object(
                    install.subprocess,
                    "check_output",
                    return_value="claude: current (v9) (~/.claude/hooks/herdr-agent-state.sh)\n",
                ) as status_mock,
                mock.patch.object(install, "run") as run_mock,
            ):
                install.install_claude_herdr_integrations()

            self.assertEqual(status_mock.call_count, 6)
            run_mock.assert_not_called()

    def test_install_claude_herdr_skill_skips_without_herdr(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir:
            root = Path(tmpdir)
            home = root / "home"
            with (
                mock.patch.object(install, "HOME", home),
                mock.patch.object(install, "herdr_command", return_value=None),
                mock.patch.object(install.subprocess, "check_output") as skill_mock,
            ):
                install.install_claude_herdr_skill()
            skill_mock.assert_not_called()
            self.assertFalse((home / ".claude/skills").exists())

    def test_install_claude_herdr_skill_rejects_non_skill_output(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir:
            root = Path(tmpdir)
            home = root / "home"
            with (
                mock.patch.object(install, "HOME", home),
                mock.patch.object(install, "herdr_command", return_value="herdr"),
                mock.patch.object(
                    install.subprocess, "check_output", return_value="usage: herdr\n"
                ),
            ):
                install.install_claude_herdr_skill()
            self.assertFalse((home / ".claude/skills").exists())


class ClaudeStatuslineTest(unittest.TestCase):
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
            script = Path(__file__).parent / "claude/statusline-command.sh"
            subprocess.run(
                ["sh", str(script), "--clear-herdr-metadata"],
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
                "subscription_codex",
                "subscription_c1",
                "subscription_c2",
                "subscription_c3",
                "subscription_c4",
                "subscription_c5",
                "subscription_c6",
                "pr_open",
                "pr_draft",
                "pr_merged",
                "pr_closed",
            ):
                index = args.index(token)
                self.assertEqual(args[index - 1], "--clear-token")

    def test_unnamed_task_does_not_clear_parent_title_rows(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir:
            root = Path(tmpdir)
            report = root / "report"
            fake = self.fake_herdr(root)
            script = Path(__file__).parent / "claude/statusline-command.sh"
            payload = {
                "cost": {"total_cost_usd": 0},
                "context_window": {},
                "model": {"display_name": "test"},
                "session_id": "transient-task",
                "transcript_path": str(root / "missing.jsonl"),
                "workspace": {"current_dir": str(root)},
            }
            subprocess.run(
                ["sh", str(script)],
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
            script = Path(__file__).parent / "claude/statusline-command.sh"
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
                ["sh", str(script)],
                input=json.dumps(payload),
                text=True,
                check=True,
                capture_output=True,
                env=self.statusline_environment(root, fake, report),
            )

            args = self.wait_for_report(report)
            self.assertIn("title1=Adversarial review", args)
            self.assertIn("model_fable=Fable 5.1", args)
            self.assertIn("subscription_c1=c1", args)
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
                ["sh", str(Path(__file__).parent / "claude/statusline-command.sh")],
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

    def test_shared_daemon_does_not_report_to_another_workspace(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir:
            root = Path(tmpdir)
            wrong_workspace = root / "wrong"
            current_dir = root / "right" / "product"
            wrong_workspace.mkdir()
            current_dir.mkdir(parents=True)
            report = root / "report"
            fake = self.fake_herdr(root)
            script = Path(__file__).parent / "claude/statusline-command.sh"
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
                ["sh", str(script)],
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
            script = Path(__file__).parent / "claude/statusline-command.sh"
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
                ["sh", str(script)],
                input=json.dumps(payload),
                text=True,
                check=True,
                capture_output=True,
                env=env,
            )

            args = self.wait_for_report(report)
            self.assertIn("title1=Resumed session", args)
            self.assertIn("model_fable=Fable 5.1", args)
            self.assertIn("subscription_c4=c4", args)


class ClaudeSkillLinksTest(unittest.TestCase):
    def test_repo_skills_are_linked_into_every_config_dir(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-claude-test-") as tmpdir:
            root = Path(tmpdir)
            home = root / "home"
            repo = ClaudeInstallTest.make_repo(root)
            skill = repo / "claude/skills/rebump"
            skill.mkdir(parents=True)
            (skill / "SKILL.md").write_text(
                "---\nname: rebump\n---\n", encoding="utf-8"
            )
            (skill / "rebump.py").write_text("", encoding="utf-8")
            (repo / "claude/skills/notes").mkdir()

            with (
                mock.patch.object(install, "HOME", home),
                mock.patch.object(install, "REPO_ROOT", repo),
            ):
                links = install.links_for("claude")
                install.apply_links(links)

            for config_dir in (
                ".claude",
                ".claude2",
                ".claude3",
                ".claude4",
                ".claude5",
                ".claude6",
            ):
                link = home / config_dir / "skills/rebump"
                self.assertTrue(link.is_symlink())
                self.assertEqual(link.resolve(), skill.resolve())
                self.assertTrue((link / "rebump.py").is_file())
                self.assertFalse((home / config_dir / "skills/notes").exists())


class NeovimPluginCommandTest(unittest.TestCase):
    def test_install_pins_plugins_to_the_lockfile(self):
        lua = " ".join(
            " ".join(command) for command in install.neovim_plugin_commands()
        )

        self.assertNotIn("sync(", lua)
        self.assertIn("install({wait = true, lockfile = true})", lua)
        self.assertIn("restore({wait = true})", lua)

    def test_update_plugins_uses_sync(self):
        lua = " ".join(
            " ".join(command) for command in install.neovim_plugin_commands(update=True)
        )

        self.assertIn("sync({wait = true})", lua)
        self.assertNotIn("restore(", lua)

    def test_treesitter_parsers_update_in_both_modes(self):
        for update in (False, True):
            commands = install.neovim_plugin_commands(update=update)
            self.assertEqual(
                commands[-1],
                ["nvim", "--headless", "-c", "TSUpdateSync", "-c", "quitall"],
            )

    def test_verify_mode_does_not_run_neovim(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-nvim-test-") as tmpdir:
            root = Path(tmpdir)
            repo = root / "repo"
            config = repo / "neovim/.config/nvim"
            config.mkdir(parents=True)
            (config / "init.lua").write_text("", encoding="utf-8")

            with (
                mock.patch.object(install, "HOME", root / "home"),
                mock.patch.object(install, "REPO_ROOT", repo),
                mock.patch.object(install, "VERIFY_MODE", True),
                mock.patch.object(install, "run") as run_mock,
            ):
                install.install_neovim()

            run_mock.assert_not_called()


if __name__ == "__main__":
    unittest.main()
