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


if __name__ == "__main__":
    unittest.main()
