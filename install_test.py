import json
import sys
import tempfile
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
            lens_config = repo / "pi/pi-lens-config.json"
            lens_config.write_text("{}\n", encoding="utf-8")
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
            (repo / "pi/pi-lens-config.json").write_text("{}\n", encoding="utf-8")

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


class HerdrInstallTest(unittest.TestCase):
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
            '{"permissions": {"defaultMode": "plan"}, "statusLine": {"type": "command"}}\n',
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
                mock.patch.object(
                    install.subprocess, "check_output", return_value=self.SKILL
                ) as skill_mock,
            ):
                install.install_claude()

                config_dirs = install.claude_config_dirs()
                self.assertEqual(
                    [d.name for d in config_dirs],
                    [".claude", ".claude2", ".claude3", ".claude4", ".claude5"],
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

                skill_path = home / ".claude/skills/herdr/SKILL.md"
                before = skill_path.stat().st_mtime_ns
                install.install_claude()
                self.assertEqual(skill_path.stat().st_mtime_ns, before)

                skill_mock.return_value = self.SKILL + "\n## New section\n"
                install.install_claude()
                self.assertTrue(
                    skill_path.read_text(encoding="utf-8").endswith("## New section\n")
                )

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

            for config_dir in (".claude", ".claude2", ".claude3", ".claude4", ".claude5"):
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
