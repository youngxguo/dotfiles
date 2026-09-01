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
        """Patch install.py down to the two things a pi install depends on:
        an npm on PATH and the prefix it installs into."""
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

            # npm is missing, so node has to be bootstrapped before the install.
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

            # pi lands in npm's global prefix, which is not necessarily on PATH
            # in the shell running install.py; a second run must not reinstall it.
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

                # the installer drops the binary in ~/.local/bin, which is not
                # necessarily on PATH yet; a second run must not re-download it.
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

        # the herdr-side copy must be pinned to the commit lazy-lock.json already
        # pins the neovim-side to, so the two halves cannot drift apart.
        commit = install.lazy_lock_commit(repo.rsplit("/", 1)[-1])
        self.assertIsNotNone(commit, "herdr-splits is missing from lazy-lock.json")
        commands = [call.args[0] for call in run_mock.mock_calls]
        self.assertIn(
            ["herdr", "plugin", "install", repo, "--ref", commit, "-y"], commands
        )

        # a plugin id already in `herdr plugin list` must not be reinstalled;
        # the reload still runs so a live server picks up the keybindings.
        with (
            mock.patch.object(install, "herdr_command", return_value="herdr"),
            mock.patch.object(
                install.subprocess,
                "check_output",
                side_effect=[
                    f"- {plugin_id} (Herdr Splits) enabled\n",
                    "status: running\n",
                ],
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


class NeovimPluginCommandTest(unittest.TestCase):
    def test_install_pins_plugins_to_the_lockfile(self):
        lua = " ".join(
            " ".join(command) for command in install.neovim_plugin_commands()
        )

        # lazy.sync() is clean + install + *update*, and update rewrites
        # lazy-lock.json to whatever it just fetched. A setup run must not move
        # the pins, or the committed lockfile stops describing what a new
        # machine gets.
        self.assertNotIn("sync(", lua)
        self.assertIn("install({wait = true, lockfile = true})", lua)
        # restore only touches already-installed plugins, so install must run
        # first for this to work on a machine with an empty plugin dir.
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

            # verify mode runs against a temporary HOME, but nvim would read the
            # real $HOME from the environment and mutate the actual plugin dir.
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
