import unittest
from pathlib import Path

import tomllib

CONFIG = Path(__file__).with_name("config.toml")


class SidebarPaletteTest(unittest.TestCase):
    def test_color_namespaces_do_not_reuse_shades(self):
        rows = tomllib.loads(CONFIG.read_text())["ui"]["sidebar"]["agents"]["rows"]
        self.assertEqual(len(rows), 6)
        colors = {}
        for row in rows:
            self.assertLessEqual(len(row), 16, "Herdr limits sidebar rows to 16 tokens")
            for cell in row:
                if not isinstance(cell, dict) or "fg" not in cell:
                    continue
                token, color = cell["token"], cell["fg"].lower()
                self.assertNotIn(
                    color,
                    colors,
                    f"{token} reuses the shade assigned to {colors.get(color)}",
                )
                colors[color] = token
        namespaces = {token.split("_")[0] for token in colors.values()}
        self.assertEqual(namespaces, {"$repo", "$pr", "$subscription", "$model"})


if __name__ == "__main__":
    unittest.main()
