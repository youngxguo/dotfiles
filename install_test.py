import tempfile
import unittest
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
