import json
import os
import plistlib
import sys
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest import mock

import install


def setUpModule():
    # claude_config_dirs() adds CLAUDE_CONFIG_DIR, so a run from a Claude
    # session would link test files into that real account.
    patcher = mock.patch.dict(os.environ)
    patcher.start()
    os.environ.pop("CLAUDE_CONFIG_DIR", None)
    unittest.addModuleCleanup(patcher.stop)


class RepoHooksInstallTest(unittest.TestCase):
    def test_installs_hooks_in_repo_not_callers_directory(self):
        with (
            mock.patch.object(install, "VERIFY_MODE", False),
            mock.patch.object(install, "install_package") as package,
            mock.patch.object(install, "command_exists", return_value=True),
            mock.patch.object(install.subprocess, "run") as run,
        ):
            install.install_repo_hooks()
        package.assert_called_once_with("pre-commit")
        run.assert_called_once_with(
            ["pre-commit", "install"], cwd=install.REPO_ROOT, check=True
        )


class ConfigOwnershipTest(unittest.TestCase):
    def test_retired_links_prune_only_unchanged_repo_links(self):
        with (
            tempfile.TemporaryDirectory() as tmpdir,
            mock.patch.object(install, "managed_links") as managed,
        ):
            root = Path(tmpdir)
            home = root / "home"
            source = root / "repo-config"
            source.touch()
            retired, replaced, active = (
                home / name for name in ("old", "local", "new")
            )
            managed.return_value = [
                ("config", source, target) for target in (retired, replaced, active)
            ]

            with mock.patch.object(install, "HOME", home):
                install.apply_links(install.links_for("config"))
                install.reconcile_repo_links()
                replaced.unlink()
                replaced.write_text("local")
                removed_source = root / "removed-config"
                source.rename(removed_source)
                managed.return_value = [("config", removed_source, active)]
                install.apply_links(install.links_for("config"))
                install.reconcile_repo_links()
                install.reconcile_repo_links()

            self.assertFalse(retired.is_symlink())
            self.assertEqual(replaced.read_text(), "local")
            self.assertEqual(active.resolve(), removed_source.resolve())

    def test_retired_settings_keep_local_changes_and_unmanaged_hook_events(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            home = Path(tmpdir)
            target = home / ".claude/settings.json"
            target.parent.mkdir()
            target.write_text('{"theme":"local","hooks":{"SessionStart":[]}}')
            original = {
                "model": "example",
                "statusLine": {"type": "command"},
                "hooks": {"Stop": []},
            }
            keys = ("model", "statusLine")

            with mock.patch.object(install, "HOME", home):
                install.merge_claude_settings_into(original, target, keys)
                settings = json.loads(target.read_text())
                settings["model"] = "locally changed"
                target.write_text(json.dumps(settings))
                install.merge_claude_settings_into({}, target, keys)
                after = target.read_bytes()
                install.merge_claude_settings_into({}, target, keys)

            self.assertEqual(target.read_bytes(), after)
            self.assertEqual(
                json.loads(after),
                {
                    "theme": "local",
                    "model": "locally changed",
                    "hooks": {"SessionStart": []},
                },
            )

    def test_orca_settings_apply_once_and_retire_only_unchanged_values(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            home = root / "home"
            repo = root / "repo"
            source = repo / "orca/settings.json"
            desired = {"defaultTuiAgent": "claude", "nativeChatQueueFollowUps": False}
            install.write_json_object(source, desired)
            live = {
                "defaultTuiAgent": "codex",
                "nativeChatQueueFollowUps": True,
                "agentCmdOverrides": {"claude": "local-claude"},
            }
            runtime = object()

            def update_runtime(_runtime, _method, updates):
                live.update(updates)
                return live

            with (
                mock.patch.object(install, "HOME", home),
                mock.patch.object(install, "REPO_ROOT", repo),
                mock.patch.object(install, "orca_data_dir", return_value=home / "orca"),
                mock.patch.object(
                    install, "read_or_start_orca_settings", return_value=(runtime, live)
                ),
                mock.patch.object(
                    install, "orca_settings_request", side_effect=update_runtime
                ) as request,
            ):
                install.merge_orca_settings()
                install.merge_orca_settings()
                request.assert_called_once_with(runtime, "settings.update", desired)

                live["defaultTuiAgent"] = "pi"
                source.unlink()
                install.merge_orca_settings()
                install.merge_orca_settings()

            self.assertEqual(
                request.call_args_list,
                [
                    mock.call(runtime, "settings.update", desired),
                    mock.call(
                        runtime, "settings.update", {"nativeChatQueueFollowUps": True}
                    ),
                ],
            )
            self.assertEqual(live["defaultTuiAgent"], "pi")
            self.assertEqual(live["agentCmdOverrides"], {"claude": "local-claude"})


class PiConfigInstallTest(unittest.TestCase):
    def test_install_pi_merges_settings_and_keeps_runtime_state(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-pi-test-") as tmpdir:
            root = Path(tmpdir)
            home = root / "home"
            repo = root / "repo"
            source = repo / "pi/settings.json"
            source.parent.mkdir(parents=True)
            source.write_text('{"theme": "dark"}\n', encoding="utf-8")
            target = home / ".pi/agent/settings.json"
            target.parent.mkdir(parents=True)
            target.write_text(
                '{"theme": "stale", "lastChangelogVersion": "0.87.1"}\n',
                encoding="utf-8",
            )

            with (
                mock.patch.object(install, "HOME", home),
                mock.patch.object(install, "REPO_ROOT", repo),
                mock.patch.object(install, "install_pi_cli"),
                mock.patch.object(install, "pi_installed", return_value=True),
            ):
                install.install_pi()
                settings = json.loads(target.read_text(encoding="utf-8"))
                self.assertEqual(settings["theme"], "dark")
                self.assertEqual(settings["lastChangelogVersion"], "0.87.1")

                # Earlier installs linked the live file into the repo.
                target.unlink()
                target.symlink_to(source)
                install.install_pi()
                self.assertFalse(target.is_symlink())
                self.assertEqual(json.loads(target.read_text()), {"theme": "dark"})
                self.assertEqual(json.loads(source.read_text()), {"theme": "dark"})

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
                json.loads((home / ".pi/agent/settings.json").read_text()),
                {"theme": "dark"},
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


class ClaudeInstallTest(unittest.TestCase):
    @staticmethod
    def make_repo(root):
        repo = root / "repo"
        (repo / "claude/hooks").mkdir(parents=True)
        (repo / "agents").mkdir()
        (repo / "agents/global-rules.md").write_text("# rules\n", encoding="utf-8")
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
            for name in (".claude2", ".claude99", ".claude-test"):
                (home / name).mkdir(parents=True)
            (home / ".claude-test/.claude.json").write_text("{}")

            with (
                mock.patch.object(install, "HOME", home),
                mock.patch.object(install, "REPO_ROOT", repo),
                mock.patch.object(install, "install_claude_external_skills"),
            ):
                install.install_claude()

                config_dirs = install.claude_config_dirs()
                self.assertEqual(
                    [d.name for d in config_dirs],
                    [
                        ".claude",
                        ".claude-test",
                        ".claude2",
                        ".claude99",
                    ],
                )
                for config_dir in config_dirs:
                    self.assertEqual(
                        (config_dir / "rules/dotfiles-agents.md").resolve(),
                        (repo / "agents/global-rules.md").resolve(),
                    )
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

    def test_config_discovery_has_no_account_limit(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            home = Path(tmpdir)
            with (
                mock.patch.object(install, "HOME", home),
                mock.patch.dict(os.environ, {}, clear=True),
            ):
                self.assertEqual(install.claude_config_dirs(), [home / ".claude"])
                for name in (".claude99", ".claude1000", ".claude-backup"):
                    (home / name).mkdir()
                (home / ".claude101").touch()  # Not a directory.
                self.assertEqual(
                    set(install.claude_config_dirs()),
                    {home / ".claude", home / ".claude99", home / ".claude1000"},
                )
                custom = home / "custom login"
                with mock.patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": str(custom)}):
                    self.assertIn(custom, install.claude_config_dirs())

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


class CseatSettingsTemplateTest(unittest.TestCase):
    def point(self, home, text=None):
        config = home / ".config/cseat/config.toml"
        if text is not None:
            config.parent.mkdir(parents=True)
            config.write_text(text, encoding="utf-8")
        with (
            mock.patch.object(install, "HOME", home),
            mock.patch.object(install, "REPO_ROOT", home / "dotfiles"),
            mock.patch.dict(os.environ),
        ):
            os.environ.pop("CSEAT_CONFIG", None)
            os.environ.pop("XDG_CONFIG_HOME", None)
            install.point_cseat_at_claude_settings()
        return config.read_text(encoding="utf-8")

    def test_leaves_a_machine_without_cseat_config_alone(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            home = Path(tmpdir)
            with self.assertRaises(FileNotFoundError):
                self.point(home)
            self.assertFalse((home / ".config").exists())

    def test_puts_the_key_before_the_first_table(self):
        seats = '[seats.yc1]\ndir = "~/.claude-yc1"\nsettings_template = "x"\n'
        with tempfile.TemporaryDirectory() as tmpdir:
            text = self.point(Path(tmpdir), seats)
        self.assertEqual(
            text,
            f'settings_template = "~/dotfiles/claude/settings.json"\n\n{seats}',
        )

    def test_replaces_an_old_value_and_is_idempotent(self):
        old = 'settings_template = "~/old.json"\n\n[models]\npr = "opus"\n'
        with tempfile.TemporaryDirectory() as tmpdir:
            home = Path(tmpdir)
            first = self.point(home, old)
            second = self.point(home)
        expected = old.replace("~/old.json", "~/dotfiles/claude/settings.json")
        self.assertEqual(first, expected)
        self.assertEqual(second, expected)


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
            for name in (".claude2", ".claude99"):
                (home / name).mkdir(parents=True)

            with (
                mock.patch.object(install, "HOME", home),
                mock.patch.object(install, "REPO_ROOT", repo),
            ):
                links = install.links_for("claude")
                install.apply_links(links)

            for config_dir in (".claude", ".claude2", ".claude99"):
                link = home / config_dir / "skills/rebump"
                self.assertTrue(link.is_symlink())
                self.assertEqual(link.resolve(), skill.resolve())
                self.assertTrue((link / "rebump.py").is_file())
                self.assertFalse((home / config_dir / "skills/notes").exists())


class SetupAuditJobInstallTest(unittest.TestCase):
    def install_job(self, home, platform, **patches):
        with (
            mock.patch.object(install, "HOME", home),
            mock.patch.object(install, "VERIFY_MODE", False),
            mock.patch.object(install.sys, "platform", platform),
            mock.patch.object(install, "brew_prefix", return_value="/opt/brew"),
            mock.patch.object(install, "run") as run_mock,
            ExitStack() as stack,
        ):
            for name, value in patches.items():
                stack.enter_context(mock.patch.object(install, name, value))
            install.install_setup_audit_job()
        return [call.args[0] for call in run_mock.mock_calls]

    def test_macos_loads_a_launchd_agent_once(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-audit-test-") as tmpdir:
            home = Path(tmpdir) / "home"
            script = home / ".local/bin/setup-audit-kickoff"
            plist = home / "Library/LaunchAgents/com.young.setup-audit-kickoff.plist"
            launchctl_print = mock.Mock(return_value=mock.Mock(returncode=113))
            with mock.patch.object(install.subprocess, "run", launchctl_print):
                commands = self.install_job(home, "darwin")

            self.assertEqual(
                script.resolve(),
                install.REPO_ROOT / "claude/skills/setup-audit/setup-audit-kickoff",
            )
            self.assertTrue(os.access(script, os.X_OK))
            job = plistlib.loads(plist.read_bytes())
            self.assertEqual(job["ProgramArguments"][0], sys.executable)
            self.assertEqual(job["ProgramArguments"][-1], str(script))
            self.assertEqual(job["StartCalendarInterval"], {"Hour": 9, "Minute": 0})
            self.assertEqual(job["StartInterval"], 600)
            self.assertTrue(job["RunAtLoad"])
            self.assertTrue(
                job["EnvironmentVariables"]["PATH"].startswith(
                    f"{home}/.local/bin:/opt/brew/bin:"
                )
            )
            self.assertTrue(job["StandardOutPath"].startswith(str(home)))
            self.assertTrue((home / ".local/state/setup-audit").is_dir())
            self.assertEqual(
                commands,
                [["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist)]],
            )

            loaded = mock.Mock(return_value=mock.Mock(returncode=0))
            with mock.patch.object(install.subprocess, "run", loaded):
                self.assertEqual(self.install_job(home, "darwin"), [])

    def test_linux_enables_a_persistent_systemd_timer(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-audit-test-") as tmpdir:
            home = Path(tmpdir) / "home"
            units = home / ".config/systemd/user"
            commands = self.install_job(
                home, "linux", command_exists=mock.Mock(return_value=True)
            )

            service = (units / "setup-audit-kickoff.service").read_text()
            timer = (units / "setup-audit-kickoff.timer").read_text()
            self.assertIn(f"ExecStart={home}/.local/bin/setup-audit-kickoff\n", service)
            self.assertIn(f'Environment="PATH={home}/.local/bin:', service)
            self.assertIn("OnCalendar=*:0/10\n", timer)
            self.assertIn("Persistent=true\n", timer)
            enable = [
                "systemctl",
                "--user",
                "enable",
                "--now",
                "setup-audit-kickoff.timer",
            ]
            self.assertEqual(
                commands, [["systemctl", "--user", "daemon-reload"], enable]
            )

            commands = self.install_job(
                home, "linux", command_exists=mock.Mock(return_value=True)
            )
            self.assertEqual(commands, [enable])

    def test_linux_without_systemd_writes_units_and_skips(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-audit-test-") as tmpdir:
            home = Path(tmpdir) / "home"
            commands = self.install_job(
                home, "linux", command_exists=mock.Mock(return_value=False)
            )
            self.assertEqual(commands, [])
            self.assertTrue(
                (home / ".config/systemd/user/setup-audit-kickoff.timer").is_file()
            )


class NeovimPluginCommandTest(unittest.TestCase):
    def test_install_pins_to_the_lockfile_and_update_rewrites_it(self):
        pinned = " ".join(" ".join(c) for c in install.neovim_plugin_commands())
        updated = " ".join(
            " ".join(c) for c in install.neovim_plugin_commands(update=True)
        )
        self.assertIn("install({wait = true, lockfile = true})", pinned)
        self.assertIn("restore(", pinned)
        self.assertNotIn("sync(", pinned)
        self.assertIn("sync(", updated)
        self.assertNotIn("restore(", updated)
        for commands in (pinned, updated):
            self.assertIn("TSUpdateSync", commands)

    def test_verify_mode_does_not_run_neovim(self):
        with tempfile.TemporaryDirectory(prefix="dotfiles-nvim-test-") as tmpdir:
            root = Path(tmpdir)
            repo = root / "repo"
            config = repo / "neovim"
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
